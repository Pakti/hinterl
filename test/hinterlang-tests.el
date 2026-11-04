;;; hinterlang-tests.el --- Integration tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'erlang)
(require 'hinterlang)

(defun hinterlang-test--wait (predicate)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro hinterlang-test--buffer (source &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (erlang-mode)
     (insert ,source)
     (unwind-protect
         (progn
           (hinterlang-mode 1)
           (hinterlang-test--wait (lambda () (not (equal hinterlang--status "analyzing"))))
           ,@body)
       (hinterlang-mode -1))))

(defun hinterlang-test--hints ()
  (cl-remove-if-not (lambda (o) (overlay-get o 'after-string)) hinterlang--overlays))
(ert-deftest hinterlang-unsaved-overlays-without-tooltips ()
  (let ((source "-spec birthday(#person{}) -> #person{}.\nbirthday(P) -> P#person{}.\n"))
    (hinterlang-test--buffer source
      (should (equal hinterlang--status "ok"))
      (should-not buffer-file-name)
      (should (= 2 (length (hinterlang-test--hints))))
      (should (equal source (buffer-string)))
      (dolist (o (hinterlang-test--hints))
        (should (= (overlay-start o) (overlay-end o)))
        (should (equal " :: #person{}" (substring-no-properties (overlay-get o 'after-string))))
        (should-not (overlay-get o 'help-echo))
        (should-not (get-text-property 0 'help-echo (overlay-get o 'after-string))))
      (goto-char (point-min))
      (search-forward "birthday(P)")
      (hinterlang-jump-to-spec)
      (should (= 2 (point))))))

(ert-deftest hinterlang-leaves-export-highlighting-to-erlang-mode ()
  (hinterlang-test--buffer "-compile(export_all). -export([f/1]). f(X) -> X; f(Y) -> Y."
    (should (equal hinterlang--status "ok"))
    (should-not hinterlang--overlays)))

(ert-deftest hinterlang-overload-mismatch-keeps-spec ()
  (let ((source "-export([f/1]). -spec f(integer()) -> atom(); (atom()) -> integer().\nf(X) -> X."))
    (hinterlang-test--buffer source
      (should (= 0 (length (hinterlang-test--hints))))
      (should (equal source (buffer-string))))))

(ert-deftest hinterlang-incomplete-retains-and-recovers ()
  (hinterlang-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((process hinterlang--process))
      (should (= 2 (length (hinterlang-test--hints))))
      (goto-char (point-max))
      (delete-char -1)
      (should hinterlang--overlays)
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (not (equal hinterlang--status "analyzing"))))
      (should hinterlang--overlays)
      (should (string-match-p "Parsing failed" hinterlang--status))
      (insert ".")
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should (eq process hinterlang--process))
      (should (= 2 (length (hinterlang-test--hints)))))))

(ert-deftest hinterlang-stale-version-and-request-rejected ()
  (hinterlang-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((old (copy-tree hinterlang--analysis)))
      ;; A response for an older request must not replace a current analysis.
      (setf (alist-get 'id old) (1- hinterlang--sequence))
      (hinterlang--clear)
      (hinterlang--accept old)
      (should-not hinterlang--overlays)
      ;; Even the latest request cannot decorate text changed after it was sent.
      (setf (alist-get 'id old) hinterlang--sequence)
      (goto-char (point-max))
      (insert "\n% changed unsaved text")
      (hinterlang--accept old)
      (should-not hinterlang--overlays)
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should (= 2 (length (hinterlang-test--hints)))))))

(ert-deftest hinterlang-unicode-tabs-and-narrowing ()
  (hinterlang-test--buffer "% 😀\n-spec 'hé😀'(binary(), atom()) -> ok.\n'hé😀'(<<\"😀\"/utf8>>,\t'å') -> ok."
    (should (= 3 (length (hinterlang-test--hints))))
    (let ((points (sort (mapcar #'overlay-start (hinterlang-test--hints)) #'<)))
      (save-excursion
        (goto-char (point-min))
        (forward-line 2)
        (forward-char 18)
        (should (= (point) (nth 0 points)))
        (forward-char 5)
        (should (= (point) (nth 1 points)))
        (forward-char 1)
        (should (= (point) (nth 2 points)))))
    (narrow-to-region (line-beginning-position) (point-max))
    (hinterlang-refresh)
    (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
    (should (= 3 (length (hinterlang-test--hints))))))

(ert-deftest hinterlang-disable-cleans-process-and-overlays ()
  (hinterlang-test--buffer "-compile(export_all). -spec f() -> ok. f() -> ok."
    (let ((process hinterlang--process))
      (should hinterlang--overlays)
      (hinterlang-mode -1)
      (should-not hinterlang--overlays)
      (should-not (process-live-p process))
      (should-not hinterlang--timer)
      (should-not (memq #'hinterlang--changed after-change-functions)))))

(ert-deftest hinterlang-fragmented-json-lines ()
  (hinterlang-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((reply (json-encode hinterlang--analysis)))
      (hinterlang--clear)
      (hinterlang--filter hinterlang--process (substring reply 0 10))
      (should-not hinterlang--overlays)
      (hinterlang--filter hinterlang--process (concat (substring reply 10) "\n"))
      (should (= 1 (length (hinterlang-test--hints)))))))

(ert-deftest hinterlang-conditional-and-include-uncertainty ()
  (hinterlang-test--buffer "-ifdef(TEST). -export([f/0]). -endif. -spec f() -> ok. f() -> ok."
    (should-not hinterlang--overlays))
  (hinterlang-test--buffer "-include(\"unknown.hrl\"). -export([f/0]). -spec f() -> ok. f() -> ok."
    (should (= 1 (length (hinterlang-test--hints))))))

(ert-deftest hinterlang-two-buffers-isolated ()
  (hinterlang-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((outer (current-buffer)) (process hinterlang--process))
      (hinterlang-test--buffer "-spec g(atom()) -> atom(). g(X) -> X."
        (should-not (eq process hinterlang--process))
        (should (= 2 (length (hinterlang-test--hints)))))
      (with-current-buffer outer
        (should (process-live-p process))
        (should (= 1 (length (hinterlang-test--hints))))))))

(ert-deftest hinterlang-overloaded-types-render-by-position ()
  (hinterlang-test--buffer "-spec f(integer()) -> atom(); (atom()) -> integer().\nf(1) -> a;\nf(a) -> 1."
    (let ((hints (sort (copy-sequence (hinterlang-test--hints))
                       (lambda (a b) (< (overlay-start a) (overlay-start b))))))
      (should (equal '(" :: integer()" " :: atom()" " :: atom()" " :: integer()")
                     (mapcar (lambda (o) (substring-no-properties (overlay-get o 'after-string)))
                             hints))))))

(ert-deftest hinterlang-unsaved-spec-changes-through-idle-callback ()
  (hinterlang-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((process hinterlang--process))
      (goto-char (point-min))
      (search-forward "integer()")
      (replace-match "binary()")
      (should hinterlang--overlays)
      (should (timerp hinterlang--timer))
      ;; Batch Emacs has no command-loop idle transition. Invoke the callback
      ;; registered by the real idle timer, then wait for the real backend.
      (let ((timer hinterlang--timer))
        (cancel-timer timer)
        (apply (timer--function timer) (timer--args timer)))
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should (eq process hinterlang--process))
      (should (cl-some (lambda (o) (equal " :: binary()"
                                         (substring-no-properties (overlay-get o 'after-string))))
                       (hinterlang-test--hints))))))

(ert-deftest hinterlang-major-mode-change-stops-backend ()
  (hinterlang-test--buffer "f() -> ok."
    (let ((process hinterlang--process))
      (fundamental-mode)
      (should-not (process-live-p process))
      (should-not hinterlang--overlays))))

(ert-deftest hinterlang-local-record-hints-and-option ()
  (hinterlang-test--buffer "new() -> P = #person{}, Alias = P, Older = birthday(Alias), Older#person.age."
    (should (= 2 (length (hinterlang-test--hints))))
    (dolist (o (hinterlang-test--hints))
      (should-not (overlay-get o 'help-echo))
      (should-not (get-text-property 0 'help-echo (overlay-get o 'after-string)))
      (save-excursion
        (goto-char (overlay-start o))
        (should (looking-at " ="))))
    (let ((hinterlang-record-hints nil))
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should-not (hinterlang-test--hints)))))

(ert-deftest hinterlang-local-record-edit-retains-until-refreshed ()
  (hinterlang-test--buffer "f() -> P = unknown(), P#person.age."
    (should (= 1 (length (hinterlang-test--hints))))
    (let ((old hinterlang--analysis))
      (goto-char (point-min))
      (search-forward "person")
      (replace-match "animal")
      (hinterlang--accept old)
      (should hinterlang--overlays)
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should (equal " :: #animal{}" (substring-no-properties
                    (overlay-get (car (hinterlang-test--hints)) 'after-string)))))))

(ert-deftest hinterlang-collapse-record-access-editing-and-option ()
  (let ((source "f(P) -> P#person.age."))
    (hinterlang-test--buffer source
      (let ((overlay (cl-find-if (lambda (o) (overlay-get o 'hinterlang-record-access))
                                hinterlang--overlays)))
        (should overlay)
        (should (equal "." (overlay-get overlay 'display)))
        (should (eq 'hinterlang-record-access-face
                    (get-text-property 0 'face (overlay-get overlay 'display))))
        (should (equal "P#person.age" (overlay-get overlay 'help-echo)))
        (should (equal source (buffer-string)))
        (should (equal "#person." (buffer-substring-no-properties
                                   (overlay-start overlay) (overlay-end overlay))))
        (goto-char (1+ (overlay-start overlay)))
        (run-hooks 'post-command-hook)
        (should-not (overlay-get overlay 'display))
        (goto-char (point-max))
        (run-hooks 'post-command-hook)
        (should (equal "." (overlay-get overlay 'display)))
        (should (eq 'hinterlang-record-access-face
                    (get-text-property 0 'face (overlay-get overlay 'display))))
        (let ((hinterlang-collapse-record-access nil))
          (hinterlang-refresh)
          (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
          (should-not hinterlang--overlays))))))

(ert-deftest hinterlang-collapse-access-stale-and-disable ()
  (hinterlang-test--buffer "f(P) -> P#person.age."
    (let ((old hinterlang--analysis))
      (should hinterlang--overlays)
      (goto-char (point-max))
      (insert "\n")
      (should hinterlang--overlays)
      (hinterlang--accept old)
      (should hinterlang--overlays)
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should hinterlang--overlays)
      (hinterlang-mode -1)
      (should-not hinterlang--overlays)
      (should-not (memq #'hinterlang--reveal-record-access post-command-hook)))))

(ert-deftest hinterlang-optional-spec-dimming ()
  (let ((source "-spec f(integer()) -> atom();\n       (atom()) -> integer(). % trailing\nf(X) -> X."))
    (hinterlang-test--buffer source
      (should-not (cl-find-if (lambda (o) (eq (overlay-get o 'face) 'hinterlang-spec-face))
                             hinterlang--overlays))
      (let ((hinterlang-dim-specs t))
        (hinterlang-refresh)
        (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
        (let ((overlay (cl-find-if (lambda (o) (eq (overlay-get o 'face) 'hinterlang-spec-face))
                                  hinterlang--overlays)))
          (should overlay)
          (should (equal "-spec f(integer()) -> atom();\n       (atom()) -> integer()."
                         (buffer-substring-no-properties (overlay-start overlay) (overlay-end overlay))))
          (should (equal source (buffer-string)))
          (should-not (overlay-get overlay 'display))
          (should-not (overlay-get overlay 'invisible))
          (goto-char (overlay-start overlay))
          (insert " ")
          (should hinterlang--overlays)
          (hinterlang-refresh)
          (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
          (should hinterlang--overlays)
          (hinterlang-mode -1)
          (should-not hinterlang--overlays))))))

(ert-deftest hinterlang-unused-macros-keep-inlay-hints ()
  (hinterlang-test--buffer "-module(otp).\n-include(\"graphql_client.hrl\").\n-define(DEFAULT_CONNECT_TIMEOUT_MSECS, 5_000).\n-define(DEFAULT_RECV_TIMEOUT_MSECS, 5_000).\n-spec local_server_url() -> binary().\nlocal_server_url() -> <<\"http://localhost:8080/otp/gtfs/v1\">>."
    (should (equal hinterlang--status "ok"))
    (should (= 1 (length (hinterlang-test--hints))))
    (should (equal " :: binary()" (substring-no-properties
                                  (overlay-get (car (hinterlang-test--hints)) 'after-string))))))

(ert-deftest hinterlang-macro-usage-preserves-other-function-hints ()
  (hinterlang-test--buffer "-define(TIMEOUT, 5_000).\n-spec url() -> binary(). url() -> <<\"url\">>.\n-spec client() -> result:type(#client{}). client() -> fun(T) -> #client{timeout = ?TIMEOUT, transport = T} end."
    (should (equal hinterlang--status "ok"))
    (should (= 1 (length (hinterlang-test--hints))))
    (should (equal " :: binary()" (substring-no-properties
                                  (overlay-get (car (hinterlang-test--hints)) 'after-string))))))

(ert-deftest hinterlang-failure-lighter-retention-and-recovery ()
  (hinterlang-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((previous (copy-sequence hinterlang--overlays))
          (valid (copy-tree hinterlang--analysis)))
      (hinterlang--accept `((protocol . 1) (id . ,hinterlang--sequence)
                        (version . ,hinterlang--requested-version)
                        (status . "invalid") (message . "Parsing failed")))
      (should (equal previous hinterlang--overlays))
      (should (eq 'hinterlang-mode-line-error-face
                  (plist-get (cddr (hinterlang--lighter)) 'face)))
      (should (equal "Hinterlang: Parsing failed\nClick to switch to the backend log"
                     (plist-get (cddr (hinterlang--lighter)) 'help-echo)))
      ;; A rendering error after producing partial overlays rolls back fully.
      (let ((broken (copy-tree valid)))
        (setf (alist-get 'record_hints broken)
              '(((position . ((line . 0) (character . 0))) (type . "#r{}"))
                ((position . ((line . 999) (character . 0))) (type . "#r{}"))))
        (hinterlang--accept broken))
      (should (equal previous hinterlang--overlays))
      (should hinterlang--failed)
      (hinterlang--filter hinterlang--process "not-json\n")
      (should (equal previous hinterlang--overlays))
      (should (string-match-p "protocol error" hinterlang--status))
      (hinterlang--accept valid)
      (should hinterlang--overlays)
      (should-not hinterlang--failed)
      (should-not (plist-get (cddr (hinterlang--lighter)) 'face))
      (should (equal "Hinterlang: ok" (plist-get (cddr (hinterlang--lighter)) 'help-echo))))))

(ert-deftest hinterlang-backend-exit-retains-decorations ()
  (hinterlang-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((previous (copy-sequence hinterlang--overlays)))
      (delete-process hinterlang--process)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "backend stopped")))
      (should (equal previous hinterlang--overlays))
      (should hinterlang--failed)
      (let ((hinterlang-backend-command '("/nonexistent/hinterlang-backend")))
        (hinterlang-refresh)
        (should hinterlang--failed)
        (should (equal previous hinterlang--overlays)))
      (hinterlang-refresh)
      (hinterlang-test--wait (lambda () (equal hinterlang--status "ok")))
      (should-not hinterlang--failed)
      (should hinterlang--overlays))))

(ert-deftest hinterlang-error-mode-line-tooltip-and-log-binding ()
  (let* ((hinterlang--status "Parsing failed")
         (hinterlang--failed t)
         (lighter (hinterlang--lighter))
         (properties (cddr lighter)))
    (should (eq :propertize (car lighter)))
    (should (equal " Hinterl" (cadr lighter)))
    (should (equal "Hinterlang: Parsing failed\nClick to switch to the backend log" (plist-get properties 'help-echo)))
    (should (eq 'mode-line-highlight (plist-get properties 'mouse-face)))
    (should (eq #'hinterlang-show-backend-log
                (lookup-key (plist-get properties 'local-map) [mode-line mouse-1])))
    (save-window-excursion
      (call-interactively
       (lookup-key (plist-get properties 'local-map) [mode-line mouse-1]))
      (should (equal "*Hinterlang backend errors*" (buffer-name))))))

(ert-deftest hinterlang-healthy-mode-line-has-no-click-binding ()
  (let* ((hinterlang--failed nil)
         (hinterlang--status "ok")
         (properties (cddr (hinterlang--lighter))))
    (should (equal "Hinterlang: ok" (plist-get properties 'help-echo)))
    (should-not (plist-get properties 'local-map))))

(ert-deftest hinterlang-copy-whole-buffer-with-hints ()
  (let ((source "-spec f(integer()) -> atom().\nf(X) -> ok.")
        (kill-ring nil) (interprogram-cut-function nil))
    (hinterlang-test--buffer source
      (let ((tick (buffer-chars-modified-tick))
            (modified (buffer-modified-p)))
        (call-interactively #'hinterlang-copy-buffer)
        (should (equal "-spec f(integer()) -> atom().\nf(X :: integer()) :: atom() -> ok."
                       (car kill-ring)))
        (should-not (text-properties-at 0 (car kill-ring)))
        (should (equal source (buffer-string)))
        (should (= tick (buffer-chars-modified-tick)))
        (should (eq modified (buffer-modified-p)))))))

(ert-deftest hinterlang-copy-region-boundary-hints ()
  (let ((kill-ring nil) (interprogram-cut-function nil) (transient-mark-mode t))
    (hinterlang-test--buffer "-spec f(integer()) -> atom().\nf(X) -> ok."
      (goto-char (point-min))
      (search-forward "f(X")
      (let ((end (point)))
        (set-mark (1- end))
        (setq mark-active t)
        (call-interactively #'hinterlang-copy-region)
        (should (equal "X :: integer()" (car kill-ring)))
        (should (equal ") :: atom()" (hinterlang--text-with-hints end (1+ end))))))))

(ert-deftest hinterlang-copy-collapsed-and-revealed-record-access ()
  (hinterlang-test--buffer "f(P) -> P#'å'.age."
    (should (equal "f(P) -> P.age." (hinterlang--text-with-hints (point-min) (point-max))))
    (goto-char (point-min))
    (search-forward "#")
    (let ((start (1- (point))))
      ;; Do not substitute an entire dot for a partial source selection.
      (should (equal "#'" (hinterlang--text-with-hints start (+ start 2)))))
    (run-hooks 'post-command-hook)
    (should (equal (buffer-string) (hinterlang--text-with-hints (point-min) (point-max))))))

(ert-deftest hinterlang-copy-whole-buffer-when-narrowed ()
  (let ((kill-ring nil) (interprogram-cut-function nil))
    (hinterlang-test--buffer "-spec f() -> ok.\nf() -> ok."
      (goto-char (point-max))
      (narrow-to-region (line-beginning-position) (point-max))
      (call-interactively #'hinterlang-copy-buffer)
      (should (equal "-spec f() -> ok.\nf() :: ok -> ok." (car kill-ring))))))

(ert-deftest hinterlang-copy-region-requires-selection ()
  (let ((kill-ring '("unchanged")) (interprogram-cut-function nil))
    (with-temp-buffer
      (insert "source")
      (should-error (call-interactively #'hinterlang-copy-region) :type 'user-error)
      (should (equal '("unchanged") kill-ring)))))
