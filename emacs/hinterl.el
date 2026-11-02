;;; hinterl.el --- Spec inlay hints for ordinary Erlang -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.1.0

;;; Commentary:
;; Enable `hinterl-mode' in `erlang-mode'.  A persistent Erlang backend analyzes
;; unsaved text.  All annotations are overlays; specs and source stay intact.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup hinterl nil "Spec inlay hints for Erlang." :group 'languages)

(defconst hinterl--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name default-directory)))))

(defcustom hinterl-backend-command
  (list (expand-file-name "bin/hinterl" hinterl--root))
  "Command starting the persistent Hinterl JSON backend.  Run make first."
  :type '(repeat string) :group 'hinterl)

(defcustom hinterl-idle-delay 0.3
  "Idle seconds before analyzing changed buffer contents."
  :type 'number :group 'hinterl)

(defcustom hinterl-record-hints t
  "Show heuristic record hints at local bindings, independently of spec hints.
Toggle this option and run `hinterl-refresh' to update existing decorations."
  :type 'boolean :group 'hinterl)

(defcustom hinterl-collapse-record-access t
  "Display record field reads as dotted access without modifying source.
Original syntax is revealed while point is inside it.  Run `hinterl-refresh'
after changing this option."
  :type 'boolean :group 'hinterl)

(defface hinterl-type-face
  '((t (:inherit shadow)))
  "Face for virtual argument and return types."
  :group 'hinterl)

(defconst hinterl--mapping-help
  "Spec-derived hint; specs remain authoritative. One signature applies to all clauses. Multiple signatures map by position only when counts match. This is a display convention, not semantic validation or type inference.")

(defvar-local hinterl--process nil)
(defvar-local hinterl--timer nil)
(defvar-local hinterl--overlays nil)
(defvar-local hinterl--sequence 0)
(defvar-local hinterl--requested-version nil)
(defvar-local hinterl--analysis nil)
(defvar-local hinterl--status "idle")
(defvar hinterl-mode nil)

(defun hinterl--get (key object)
  "Read string KEY from JSON alist OBJECT."
  (alist-get (intern key) object))

(defun hinterl--clear ()
  "Remove only Hinterl decorations and navigation data."
  (mapc #'delete-overlay hinterl--overlays)
  (setq hinterl--overlays nil hinterl--analysis nil))

(defun hinterl--cancel-timer ()
  (when (timerp hinterl--timer) (cancel-timer hinterl--timer))
  (setq hinterl--timer nil))

(defun hinterl--changed (&rest _)
  ;; Never leave decorations from the previous version visible during debounce.
  (hinterl--clear)
  (hinterl--cancel-timer)
  (setq hinterl--status "pending")
  (setq hinterl--timer
        (run-with-idle-timer hinterl-idle-delay nil
                             #'hinterl--idle-refresh (current-buffer))))

(defun hinterl--idle-refresh (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq hinterl--timer nil)
      (when hinterl-mode (hinterl-refresh)))))

(defun hinterl--start ()
  (unless (process-live-p hinterl--process)
    (let ((buffer (current-buffer)))
      (setq hinterl--process
            (make-process
             :name (generate-new-buffer-name "hinterl")
             :command hinterl-backend-command :connection-type 'pipe
             :coding 'utf-8-unix :noquery t :buffer nil
             :stderr (get-buffer-create "*Hinterl backend errors*")
             :filter (lambda (process output)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (eq process hinterl--process)
                             (hinterl--filter process output)))))
             :sentinel (lambda (process _event)
                         (when (and (not (process-live-p process))
                                    (buffer-live-p buffer))
                           (with-current-buffer buffer
                             (when (eq process hinterl--process)
                               (hinterl--clear)
                               (setq hinterl--status "backend stopped"))))))))))

(defun hinterl--filter (process output)
  "Decode complete JSON lines from PROCESS, retaining partial OUTPUT."
  (let ((pending (concat (or (process-get process 'hinterl-pending) "") output))
        end)
    (while (setq end (string-match "\n" pending))
      (let ((line (substring pending 0 end)))
        (setq pending (substring pending (1+ end)))
        (condition-case err
            (hinterl--accept
             (json-parse-string line :object-type 'alist :array-type 'list
                                :null-object nil :false-object nil))
          (error
           (hinterl--clear)
           (setq hinterl--status (format "protocol error: %s" (error-message-string err)))))))
    (process-put process 'hinterl-pending pending)))

(defun hinterl-refresh ()
  "Analyze the current unsaved buffer; restart the backend if necessary."
  (interactive)
  (unless hinterl-mode (user-error "Hinterl mode is disabled"))
  (hinterl--cancel-timer)
  (condition-case err
      (progn
        (hinterl--start)
        (cl-incf hinterl--sequence)
        (setq hinterl--requested-version (buffer-chars-modified-tick)
              hinterl--status "analyzing")
        (save-restriction
          (widen)
          (process-send-string
           hinterl--process
           (concat
            (json-serialize
             `((protocol . 1) (method . "analyze") (id . ,hinterl--sequence)
               (version . ,hinterl--requested-version)
               (source . ,(buffer-substring-no-properties (point-min) (point-max)))))
            "\n"))))
    (error
     (hinterl--clear)
     (setq hinterl--status (format "backend error: %s" (error-message-string err)))
     (message "Hinterl: %s" hinterl--status))))

(defun hinterl--position (position)
  "Convert protocol POSITION (zero-based Unicode scalars) into an Emacs point."
  (let ((line (hinterl--get "line" position))
        (column (hinterl--get "character" position)))
    (unless (and (integerp line) (>= line 0) (integerp column) (>= column 0))
      (error "Invalid source position"))
    (save-excursion
      (goto-char (point-min))
      (unless (zerop (forward-line line)) (error "Line outside buffer"))
      (when (> column (- (line-end-position) (point)))
        (error "Column outside buffer"))
      (forward-char column)
      (point))))

(defun hinterl--overlay (start end &rest properties)
  (let ((overlay (make-overlay start end nil nil nil)))
    (while properties
      (overlay-put overlay (pop properties) (pop properties)))
    (overlay-put overlay 'hinterl t)
    (push overlay hinterl--overlays)
    overlay))

(defun hinterl--hint (position text help)
  (let* ((at (hinterl--position position))
         ;; A single line even when Erlang's pretty printer wraps a nested type.
         (display (propertize (concat " :: " (replace-regexp-in-string "[\n\r]+[ \t]*" " " text))
                              'face 'hinterl-type-face 'help-echo help)))
    (hinterl--overlay at at 'after-string display 'help-echo help)))

(defun hinterl--spec-for (function specs)
  (cl-find-if (lambda (spec)
                (and (equal (hinterl--get "name" function) (hinterl--get "name" spec))
                     (equal (hinterl--get "arity" function) (hinterl--get "arity" spec))
                     (not (hinterl--get "module" spec))))
              specs))

(defun hinterl--reveal-record-access ()
  "Reveal collapsed syntax containing point; collapse other record reads."
  (dolist (overlay hinterl--overlays)
    (when (overlay-get overlay 'hinterl-record-access)
      (overlay-put overlay 'display
                   (unless (and (<= (overlay-start overlay) (point))
                                (< (point) (overlay-end overlay)))
                     ".")))))

(defun hinterl--render (response)
  (when hinterl-collapse-record-access
    (dolist (access (hinterl--get "record_accesses" response))
      (let* ((range (hinterl--get "range" access))
             (start (hinterl--position (hinterl--get "start" range)))
             (end (hinterl--position (hinterl--get "end" range)))
             (text (hinterl--get "text" access)))
        (unless (equal text (buffer-substring-no-properties start end))
          (error "Record access source does not match"))
        (hinterl--overlay start end 'display "." 'hinterl-record-access t
                          'help-echo (concat "Original Erlang syntax: " text)))))
  (hinterl--reveal-record-access)
  (when hinterl-record-hints
    (dolist (hint (hinterl--get "record_hints" response))
      (hinterl--hint
       (hinterl--get "position" hint) (hinterl--get "type" hint)
       (concat "Record association, not a verified type. Specs remain authoritative.\n"
               (mapconcat
                (lambda (evidence)
                  (let ((location (hinterl--get "location" evidence)))
                    (format "%s at line %d, column %d"
                            (hinterl--get "kind" evidence)
                            (1+ (hinterl--get "line" location))
                            (1+ (hinterl--get "character" location)))))
                (hinterl--get "evidence" hint) "\n")))))
  (let ((specs (hinterl--get "specs" response)))
    (dolist (function (hinterl--get "functions" response))
      (let* ((spec (hinterl--spec-for function specs))
             (help (concat hinterl--mapping-help
                           (when spec (concat "\n\n" (hinterl--get "text" spec))))))
        (dolist (clause (hinterl--get "clauses" function))
          (let ((alternative (hinterl--get "alternative" clause)))
            (when alternative
              (cl-mapc (lambda (range type)
                         (hinterl--hint (hinterl--get "end" range) type help))
                       (hinterl--get "arguments" clause)
                       (hinterl--get "arguments" alternative))
              (hinterl--hint (hinterl--get "head_end" clause)
                             (hinterl--get "return" alternative) help))))))))

(defun hinterl--accept (response)
  "Apply RESPONSE only to the exact buffer version and most recent request."
  (when (and hinterl-mode
             (equal (hinterl--get "protocol" response) 1)
             (equal (hinterl--get "id" response) hinterl--sequence)
             (equal (hinterl--get "version" response) hinterl--requested-version)
             (equal hinterl--requested-version (buffer-chars-modified-tick)))
    (hinterl--clear)
    (setq hinterl--status (or (hinterl--get "message" response)
                             (hinterl--get "status" response)))
    (when (equal (hinterl--get "status" response) "ok")
      (save-restriction
        (widen)
        (condition-case err
            (progn (hinterl--render response) (setq hinterl--analysis response))
          (error
           (hinterl--clear)
           (setq hinterl--status (format "invalid response: %s" (error-message-string err)))))))))

(defun hinterl-jump-to-spec ()
  "Jump to the current function's authoritative spec."
  (interactive)
  (let ((origin (point)) best target)
    (save-restriction
      (widen)
      (dolist (function (hinterl--get "functions" hinterl--analysis))
        (dolist (clause (hinterl--get "clauses" function))
          (let ((start (hinterl--position
                        (hinterl--get "start" (hinterl--get "name_range" clause)))))
            (when (and (<= start origin)
                       (<= origin (hinterl--position (hinterl--get "end" (hinterl--get "range" clause))))
                       (or (null best) (> start best)))
              (setq best start
                    target (hinterl--spec-for function (hinterl--get "specs" hinterl--analysis)))))))
      (unless target (user-error "No spec available for this function"))
      (push-mark)
      (goto-char (hinterl--position (hinterl--get "location" target))))))

(defun hinterl-status ()
  "Show analysis or backend status for the current buffer."
  (interactive)
  (message "Hinterl: %s" hinterl--status))

(defun hinterl--stop ()
  (hinterl--cancel-timer)
  (hinterl--clear)
  (when (processp hinterl--process)
    (let ((process hinterl--process))
      (setq hinterl--process nil)
      (delete-process process))))

;;;###autoload
(define-minor-mode hinterl-mode
  "Show spec types without modifying Erlang text.
Signatures map to clauses by convention, not inference; hover hints for details."
  :lighter " Hinterl" :group 'hinterl
  (if hinterl-mode
      (if (not (derived-mode-p 'erlang-mode))
          (progn (setq hinterl-mode nil)
                 (user-error "Hinterl requires ordinary erlang-mode"))
        (add-hook 'after-change-functions #'hinterl--changed nil t)
        (add-hook 'post-command-hook #'hinterl--reveal-record-access nil t)
        (add-hook 'kill-buffer-hook #'hinterl--stop nil t)
        (add-hook 'change-major-mode-hook #'hinterl--stop nil t)
        (hinterl-refresh))
    (remove-hook 'after-change-functions #'hinterl--changed t)
    (remove-hook 'post-command-hook #'hinterl--reveal-record-access t)
    (remove-hook 'kill-buffer-hook #'hinterl--stop t)
    (remove-hook 'change-major-mode-hook #'hinterl--stop t)
    (hinterl--stop)))

(provide 'hinterl)
;;; hinterl.el ends here
