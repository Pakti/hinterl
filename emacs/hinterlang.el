;;; hinterlang.el --- Spec inlay hints for ordinary Erlang -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Package-Requires: ((emacs "27.1"))
;; Version: 0.1.0

;;; Commentary:
;; Enable `hinterlang-mode' in `erlang-mode'.  A persistent Erlang backend analyzes
;; unsaved text.  All annotations are overlays; specs and source stay intact.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup hinterlang nil "Spec inlay hints for Erlang." :group 'languages)

(defconst hinterlang--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name default-directory)))))

(defcustom hinterlang-backend-command
  (list (expand-file-name "bin/hinterlang" hinterlang--root))
  "Command starting the persistent Hinterlang JSON backend.  Run make first."
  :type '(repeat string) :group 'hinterlang)

(defcustom hinterlang-idle-delay 0.3
  "Idle seconds before analyzing changed buffer contents."
  :type 'number :group 'hinterlang)

(defcustom hinterlang-record-hints t
  "Show heuristic record hints at local bindings, independently of spec hints.
Toggle this option and run `hinterlang-refresh' to update existing decorations."
  :type 'boolean :group 'hinterlang)

(defcustom hinterlang-collapse-record-access t
  "Display record field reads as dotted access without modifying source.
Original syntax is revealed while point is inside it.  Run `hinterlang-refresh'
after changing this option."
  :type 'boolean :group 'hinterlang)

(defcustom hinterlang-dim-specs nil
  "Dim specs with `hinterlang-spec-face' while keeping them visible and editable.
Run `hinterlang-refresh' after changing this option."
  :type 'boolean :group 'hinterlang)

(defface hinterlang-spec-face
  '((t (:inherit shadow)))
  "Face for specs when `hinterlang-dim-specs' is enabled."
  :group 'hinterlang)

(defface hinterlang-record-access-face
  '((t (:inherit default)))
  "Face for the dot replacing collapsed record field access syntax."
  :group 'hinterlang)

(defface hinterlang-type-face
  '((t (:inherit shadow)))
  "Face for virtual argument and return types."
  :group 'hinterlang)

(defface hinterlang-mode-line-error-face
  '((t (:inherit error)))
  "Face for the Hinterlang mode-line indicator after an analysis failure."
  :group 'hinterlang)

(defvar-local hinterlang--failed nil)
(defvar-local hinterlang--process nil)
(defvar-local hinterlang--timer nil)
(defvar-local hinterlang--overlays nil)
(defvar-local hinterlang--sequence 0)
(defvar-local hinterlang--requested-version nil)
(defvar-local hinterlang--analysis nil)
(defvar-local hinterlang--status "idle")
(defvar hinterlang-mode nil)

(defun hinterlang--get (key object)
  "Read string KEY from JSON alist OBJECT."
  (alist-get (intern key) object))

(defun hinterlang--clear ()
  "Remove only Hinterlang decorations and navigation data."
  (mapc #'delete-overlay hinterlang--overlays)
  (setq hinterlang--overlays nil hinterlang--analysis nil))

(defun hinterlang--cancel-timer ()
  (when (timerp hinterlang--timer) (cancel-timer hinterlang--timer))
  (setq hinterlang--timer nil))

(defun hinterlang--set-status (status &optional outcome)
  (setq hinterlang--status status)
  (cond ((eq outcome 'error) (setq hinterlang--failed t))
        ((eq outcome 'success) (setq hinterlang--failed nil)))
  (force-mode-line-update))

(defun hinterlang-show-backend-log ()
  "Switch to the Hinterlang backend error log."
  (interactive)
  (pop-to-buffer (get-buffer-create "*Hinterlang backend errors*")))

(defvar hinterlang--error-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'hinterlang-show-backend-log)
    map)
  "Mouse bindings for Hinterlang's error-state mode-line indicator.")

(defun hinterlang--lighter ()
  ;; A :propertize construct overrides mode-line-modes' enclosing minor-mode
  ;; tooltip/map. Properties on a returned string alone are overridden by it.
  (list :propertize " Hinterl"
        'face (when hinterlang--failed 'hinterlang-mode-line-error-face)
        'help-echo (concat (format "Hinterlang: %s" hinterlang--status)
                           (when hinterlang--failed
                             "\nClick to switch to the backend log"))
        'mouse-face 'mode-line-highlight
        'local-map (when hinterlang--failed hinterlang--error-mode-line-map)))

(defun hinterlang--changed (&rest _)
  ;; Overlays track edits until a successful replacement is available. Cached
  ;; absolute navigation positions, however, are no longer safe after an edit.
  (setq hinterlang--analysis nil)
  (hinterlang--cancel-timer)
  (hinterlang--set-status "pending; retaining previous decorations")
  (setq hinterlang--timer
        (run-with-idle-timer hinterlang-idle-delay nil
                             #'hinterlang--idle-refresh (current-buffer))))

(defun hinterlang--idle-refresh (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq hinterlang--timer nil)
      (when hinterlang-mode (hinterlang-refresh)))))

(defun hinterlang--start ()
  (unless (process-live-p hinterlang--process)
    (let ((buffer (current-buffer)))
      (setq hinterlang--process
            (make-process
             :name (generate-new-buffer-name "hinterlang")
             :command hinterlang-backend-command :connection-type 'pipe
             :coding 'utf-8-unix :noquery t :buffer nil
             :stderr (get-buffer-create "*Hinterlang backend errors*")
             :filter (lambda (process output)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (eq process hinterlang--process)
                             (hinterlang--filter process output)))))
             :sentinel (lambda (process _event)
                         (when (and (not (process-live-p process))
                                    (buffer-live-p buffer))
                           (with-current-buffer buffer
                             (when (eq process hinterlang--process)
                               (hinterlang--set-status "backend stopped" 'error))))))))))

(defun hinterlang--filter (process output)
  "Decode complete JSON lines from PROCESS, retaining partial OUTPUT."
  (let ((pending (concat (or (process-get process 'hinterlang-pending) "") output))
        end)
    (while (setq end (string-match "\n" pending))
      (let ((line (substring pending 0 end)))
        (setq pending (substring pending (1+ end)))
        (condition-case err
            (hinterlang--accept
             (json-parse-string line :object-type 'alist :array-type 'list
                                :null-object nil :false-object nil))
          (error
           (hinterlang--set-status (format "protocol error: %s" (error-message-string err)) 'error)))))
    (process-put process 'hinterlang-pending pending)))

(defun hinterlang-refresh ()
  "Analyze the current unsaved buffer; restart the backend if necessary."
  (interactive)
  (unless hinterlang-mode (user-error "Hinterlang mode is disabled"))
  (hinterlang--cancel-timer)
  (condition-case err
      (progn
        (hinterlang--start)
        (cl-incf hinterlang--sequence)
        (setq hinterlang--requested-version (buffer-chars-modified-tick))
        (hinterlang--set-status "analyzing")
        (save-restriction
          (widen)
          (process-send-string
           hinterlang--process
           (concat
            (json-serialize
             `((protocol . 1) (method . "analyze") (id . ,hinterlang--sequence)
               (version . ,hinterlang--requested-version)
               (source . ,(buffer-substring-no-properties (point-min) (point-max)))))
            "\n"))))
    (error
     (hinterlang--set-status (format "backend error: %s" (error-message-string err)) 'error)
     (message "Hinterlang: %s" hinterlang--status))))

(defun hinterlang--position (position)
  "Convert protocol POSITION (zero-based Unicode scalars) into an Emacs point."
  (let ((line (hinterlang--get "line" position))
        (column (hinterlang--get "character" position)))
    (unless (and (integerp line) (>= line 0) (integerp column) (>= column 0))
      (error "Invalid source position"))
    (save-excursion
      (goto-char (point-min))
      (unless (zerop (forward-line line)) (error "Line outside buffer"))
      (when (> column (- (line-end-position) (point)))
        (error "Column outside buffer"))
      (forward-char column)
      (point))))

(defun hinterlang--overlay (start end &rest properties)
  (let ((overlay (make-overlay start end nil nil nil)))
    (while properties
      (overlay-put overlay (pop properties) (pop properties)))
    (overlay-put overlay 'hinterlang t)
    (push overlay hinterlang--overlays)
    overlay))

(defun hinterlang--hint (position text)
  (let* ((at (hinterlang--position position))
         ;; A single line even when Erlang's pretty printer wraps a nested type.
         (display (propertize (concat " :: " (replace-regexp-in-string "[\n\r]+[ \t]*" " " text))
                              'face 'hinterlang-type-face)))
    (hinterlang--overlay at at 'after-string display)))

(defun hinterlang--spec-for (function specs)
  (cl-find-if (lambda (spec)
                (and (equal (hinterlang--get "name" function) (hinterlang--get "name" spec))
                     (equal (hinterlang--get "arity" function) (hinterlang--get "arity" spec))
                     (not (hinterlang--get "module" spec))))
              specs))

(defun hinterlang--reveal-record-access ()
  "Reveal collapsed syntax containing point; collapse other record reads."
  (dolist (overlay hinterlang--overlays)
    (when (overlay-get overlay 'hinterlang-record-access)
      (overlay-put overlay 'display
                   (unless (and (<= (overlay-start overlay) (point))
                                (< (point) (overlay-end overlay)))
                     (propertize "." 'face 'hinterlang-record-access-face))))))

(defun hinterlang--render (response)
  (when hinterlang-dim-specs
    (dolist (spec (hinterlang--get "specs" response))
      (let ((range (hinterlang--get "range" spec)))
        (when range
          (hinterlang--overlay (hinterlang--position (hinterlang--get "start" range))
                            (hinterlang--position (hinterlang--get "end" range))
                            'face 'hinterlang-spec-face)))))
  (when hinterlang-collapse-record-access
    (dolist (access (hinterlang--get "record_accesses" response))
      (let* ((range (hinterlang--get "range" access))
             (start (hinterlang--position (hinterlang--get "start" range)))
             (end (hinterlang--position (hinterlang--get "end" range)))
             (text (hinterlang--get "text" access)))
        (unless (equal text (buffer-substring-no-properties start end))
          (error "Record access source does not match"))
        (hinterlang--overlay start end 'hinterlang-record-access t
                          'help-echo (hinterlang--get "expression" access)))))
  (hinterlang--reveal-record-access)
  (when hinterlang-record-hints
    (dolist (hint (hinterlang--get "record_hints" response))
      (hinterlang--hint (hinterlang--get "position" hint) (hinterlang--get "type" hint))))
  (dolist (function (hinterlang--get "functions" response))
    (dolist (clause (hinterlang--get "clauses" function))
      (let ((alternative (hinterlang--get "alternative" clause)))
        (when alternative
          (cl-mapc (lambda (range type)
                     (hinterlang--hint (hinterlang--get "end" range) type))
                   (hinterlang--get "arguments" clause)
                   (hinterlang--get "arguments" alternative))
          (hinterlang--hint (hinterlang--get "head_end" clause)
                         (hinterlang--get "return" alternative)))))))

(defun hinterlang--accept (response)
  "Apply RESPONSE only to the exact buffer version and most recent request."
  (when (and hinterlang-mode (equal (hinterlang--get "status" response) "error")
             (null (hinterlang--get "id" response)))
    (hinterlang--set-status (or (hinterlang--get "message" response) "protocol error") 'error))
  (when (and hinterlang-mode
             (equal (hinterlang--get "protocol" response) 1)
             (equal (hinterlang--get "id" response) hinterlang--sequence)
             (equal (hinterlang--get "version" response) hinterlang--requested-version)
             (equal hinterlang--requested-version (buffer-chars-modified-tick)))
    (if (not (equal (hinterlang--get "status" response) "ok"))
        (hinterlang--set-status (or (hinterlang--get "message" response)
                                (hinterlang--get "status" response) "analysis failed") 'error)
      ;; Build a replacement transactionally. A malformed response must not
      ;; discard the previous overlays or leave half-rendered new decorations.
      (let ((previous hinterlang--overlays))
        (setq hinterlang--overlays nil)
        (save-restriction
          (widen)
          (condition-case err
              (progn
                (hinterlang--render response)
                (mapc #'delete-overlay previous)
                (setq hinterlang--analysis response)
                (hinterlang--set-status (or (hinterlang--get "message" response) "ok") 'success))
            (error
             (mapc #'delete-overlay hinterlang--overlays)
             (setq hinterlang--overlays previous)
             (hinterlang--set-status (format "invalid response: %s" (error-message-string err)) 'error))))))))

(defun hinterlang-jump-to-spec ()
  "Jump to the current function's authoritative spec."
  (interactive)
  (let ((origin (point)) best target)
    (save-restriction
      (widen)
      (dolist (function (hinterlang--get "functions" hinterlang--analysis))
        (dolist (clause (hinterlang--get "clauses" function))
          (let ((start (hinterlang--position
                        (hinterlang--get "start" (hinterlang--get "name_range" clause)))))
            (when (and (<= start origin)
                       (<= origin (hinterlang--position (hinterlang--get "end" (hinterlang--get "range" clause))))
                       (or (null best) (> start best)))
              (setq best start
                    target (hinterlang--spec-for function (hinterlang--get "specs" hinterlang--analysis)))))))
      (unless target (user-error "No spec available for this function"))
      (push-mark)
      (goto-char (hinterlang--position (hinterlang--get "location" target))))))

(defun hinterlang--text-with-hints (beg end)
  "Return plain text from BEG to END with current Hinterlang decorations.
A hint at END belongs to the copied text; a hint at BEG belongs to preceding
text. Partially selected collapsed accesses retain their selected source text."
  (save-restriction
    (widen)
    (let (edits chunks (cursor beg))
      (dolist (overlay hinterlang--overlays)
        (when (eq (overlay-buffer overlay) (current-buffer))
          (let ((start (overlay-start overlay))
                (finish (overlay-end overlay))
                (hint (overlay-get overlay 'after-string))
                (display (overlay-get overlay 'display)))
            (cond
             ((and (= start finish) (stringp hint) (< beg start) (<= start end))
              (push (list start start hint) edits))
             ((and (< start finish) (<= beg start) (<= finish end)
                   (overlay-get overlay 'hinterlang-record-access) (stringp display))
              (push (list start finish display) edits))))))
      (setq edits (sort edits (lambda (a b)
                               (if (= (car a) (car b))
                                   (< (cadr a) (cadr b))
                                 (< (car a) (car b))))))
      (dolist (edit edits)
        (pcase-let ((`(,start ,finish ,text) edit))
          (when (>= start cursor)
            (push (buffer-substring-no-properties cursor start) chunks)
            (push (substring-no-properties text) chunks)
            (setq cursor finish))))
      (push (buffer-substring-no-properties cursor end) chunks)
      (apply #'concat (nreverse chunks)))))

(defun hinterlang-copy-region (beg end)
  "Copy the active region including Hinterlang hints.
The result is plain text in the kill ring and clipboard, subject to Emacs's
clipboard settings. Record reads are copied as currently displayed. Source
text is never modified. Copies current decorations, which may be stale when
Hinterlang is reporting a failure."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "No active region")))
  (kill-new (hinterlang--text-with-hints beg end))
  (message "Copied text with Hinterlang hints"))

(defun hinterlang-copy-buffer ()
  "Copy the entire buffer including current Hinterlang hints.
Includes text outside narrowing. Does not require or change the active region."
  (interactive)
  (save-restriction
    (widen)
    (hinterlang-copy-region (point-min) (point-max))))

(defun hinterlang-status ()
  "Show analysis or backend status for the current buffer."
  (interactive)
  (message "Hinterlang: %s" hinterlang--status))

(defun hinterlang--stop ()
  (hinterlang--cancel-timer)
  (hinterlang--clear)
  (when (processp hinterlang--process)
    (let ((process hinterlang--process))
      (setq hinterlang--process nil)
      (delete-process process))))

;;;###autoload
(define-minor-mode hinterlang-mode
  "Show spec types without modifying Erlang text.
Signatures map to clauses by convention, not inference; see README for details."
  :lighter (:eval (hinterlang--lighter)) :group 'hinterlang
  (if hinterlang-mode
      (if (not (derived-mode-p 'erlang-mode))
          (progn (setq hinterlang-mode nil)
                 (user-error "Hinterlang requires ordinary erlang-mode"))
        (add-hook 'after-change-functions #'hinterlang--changed nil t)
        (add-hook 'post-command-hook #'hinterlang--reveal-record-access nil t)
        (add-hook 'kill-buffer-hook #'hinterlang--stop nil t)
        (add-hook 'change-major-mode-hook #'hinterlang--stop nil t)
        (hinterlang-refresh))
    (remove-hook 'after-change-functions #'hinterlang--changed t)
    (remove-hook 'post-command-hook #'hinterlang--reveal-record-access t)
    (remove-hook 'kill-buffer-hook #'hinterlang--stop t)
    (remove-hook 'change-major-mode-hook #'hinterlang--stop t)
    (hinterlang--stop)))

(provide 'hinterlang)
;;; hinterlang.el ends here
