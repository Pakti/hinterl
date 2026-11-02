;;; hinterl-tests.el --- Integration tests -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
(require 'ert)
(require 'erlang)
(require 'hinterl)

(defun hinterl-test--wait (predicate)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should (funcall predicate))))

(defmacro hinterl-test--buffer (source &rest body)
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (erlang-mode)
     (insert ,source)
     (unwind-protect
         (progn
           (hinterl-mode 1)
           (hinterl-test--wait (lambda () (not (equal hinterl--status "analyzing"))))
           ,@body)
       (hinterl-mode -1))))

(defun hinterl-test--hints ()
  (cl-remove-if-not (lambda (o) (overlay-get o 'after-string)) hinterl--overlays))
(ert-deftest hinterl-unsaved-overlays-and-hover ()
  (let ((source "-spec birthday(#person{}) -> #person{}.\nbirthday(P) -> P#person{}.\n"))
    (hinterl-test--buffer source
      (should (equal hinterl--status "ok"))
      (should-not buffer-file-name)
      (should (= 2 (length (hinterl-test--hints))))
      (should (equal source (buffer-string)))
      (dolist (o (hinterl-test--hints))
        (should (= (overlay-start o) (overlay-end o)))
        (should (equal " :: #person{}" (substring-no-properties (overlay-get o 'after-string))))
        (should (string-match-p "not semantic validation" (overlay-get o 'help-echo))))
      (goto-char (point-min))
      (search-forward "birthday(P)")
      (hinterl-jump-to-spec)
      (should (= 2 (point))))))

(ert-deftest hinterl-leaves-export-highlighting-to-erlang-mode ()
  (hinterl-test--buffer "-compile(export_all). -export([f/1]). f(X) -> X; f(Y) -> Y."
    (should (equal hinterl--status "ok"))
    (should-not hinterl--overlays)))

(ert-deftest hinterl-overload-mismatch-keeps-spec ()
  (let ((source "-export([f/1]). -spec f(integer()) -> atom(); (atom()) -> integer().\nf(X) -> X."))
    (hinterl-test--buffer source
      (should (= 0 (length (hinterl-test--hints))))
      (should (equal source (buffer-string))))))

(ert-deftest hinterl-incomplete-clears-and-recovers ()
  (hinterl-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((process hinterl--process))
      (should (= 2 (length (hinterl-test--hints))))
      (goto-char (point-max))
      (delete-char -1)
      (should-not hinterl--overlays)
      (hinterl-refresh)
      (hinterl-test--wait (lambda () (not (equal hinterl--status "analyzing"))))
      (should-not hinterl--overlays)
      (should (string-match-p "Parsing failed" hinterl--status))
      (insert ".")
      (hinterl-refresh)
      (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
      (should (eq process hinterl--process))
      (should (= 2 (length (hinterl-test--hints)))))))

(ert-deftest hinterl-stale-version-and-request-rejected ()
  (hinterl-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((old (copy-tree hinterl--analysis)))
      ;; A response for an older request must not replace a current analysis.
      (setf (alist-get 'id old) (1- hinterl--sequence))
      (hinterl--clear)
      (hinterl--accept old)
      (should-not hinterl--overlays)
      ;; Even the latest request cannot decorate text changed after it was sent.
      (setf (alist-get 'id old) hinterl--sequence)
      (goto-char (point-max))
      (insert "\n% changed unsaved text")
      (hinterl--accept old)
      (should-not hinterl--overlays)
      (hinterl-refresh)
      (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
      (should (= 2 (length (hinterl-test--hints)))))))

(ert-deftest hinterl-unicode-tabs-and-narrowing ()
  (hinterl-test--buffer "% 😀\n-spec 'hé😀'(binary(), atom()) -> ok.\n'hé😀'(<<\"😀\"/utf8>>,\t'å') -> ok."
    (should (= 3 (length (hinterl-test--hints))))
    (let ((points (sort (mapcar #'overlay-start (hinterl-test--hints)) #'<)))
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
    (hinterl-refresh)
    (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
    (should (= 3 (length (hinterl-test--hints))))))

(ert-deftest hinterl-disable-cleans-process-and-overlays ()
  (hinterl-test--buffer "-compile(export_all). -spec f() -> ok. f() -> ok."
    (let ((process hinterl--process))
      (should hinterl--overlays)
      (hinterl-mode -1)
      (should-not hinterl--overlays)
      (should-not (process-live-p process))
      (should-not hinterl--timer)
      (should-not (memq #'hinterl--changed after-change-functions)))))

(ert-deftest hinterl-fragmented-json-lines ()
  (hinterl-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((reply (json-encode hinterl--analysis)))
      (hinterl--clear)
      (hinterl--filter hinterl--process (substring reply 0 10))
      (should-not hinterl--overlays)
      (hinterl--filter hinterl--process (concat (substring reply 10) "\n"))
      (should (= 1 (length (hinterl-test--hints)))))))

(ert-deftest hinterl-conditional-and-include-uncertainty ()
  (hinterl-test--buffer "-ifdef(TEST). -export([f/0]). -endif. -spec f() -> ok. f() -> ok."
    (should-not hinterl--overlays))
  (hinterl-test--buffer "-include(\"unknown.hrl\"). -export([f/0]). -spec f() -> ok. f() -> ok."
    (should (= 1 (length (hinterl-test--hints))))))

(ert-deftest hinterl-two-buffers-isolated ()
  (hinterl-test--buffer "-spec f() -> ok. f() -> ok."
    (let ((outer (current-buffer)) (process hinterl--process))
      (hinterl-test--buffer "-spec g(atom()) -> atom(). g(X) -> X."
        (should-not (eq process hinterl--process))
        (should (= 2 (length (hinterl-test--hints)))))
      (with-current-buffer outer
        (should (process-live-p process))
        (should (= 1 (length (hinterl-test--hints))))))))

(ert-deftest hinterl-overloaded-types-render-by-position ()
  (hinterl-test--buffer "-spec f(integer()) -> atom(); (atom()) -> integer().\nf(1) -> a;\nf(a) -> 1."
    (let ((hints (sort (copy-sequence (hinterl-test--hints))
                       (lambda (a b) (< (overlay-start a) (overlay-start b))))))
      (should (equal '(" :: integer()" " :: atom()" " :: atom()" " :: integer()")
                     (mapcar (lambda (o) (substring-no-properties (overlay-get o 'after-string)))
                             hints))))))

(ert-deftest hinterl-unsaved-spec-changes-through-idle-callback ()
  (hinterl-test--buffer "-spec f(integer()) -> atom(). f(X) -> ok."
    (let ((process hinterl--process))
      (goto-char (point-min))
      (search-forward "integer()")
      (replace-match "binary()")
      (should-not hinterl--overlays)
      (should (timerp hinterl--timer))
      ;; Batch Emacs has no command-loop idle transition. Invoke the callback
      ;; registered by the real idle timer, then wait for the real backend.
      (let ((timer hinterl--timer))
        (cancel-timer timer)
        (apply (timer--function timer) (timer--args timer)))
      (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
      (should (eq process hinterl--process))
      (should (cl-some (lambda (o) (equal " :: binary()"
                                         (substring-no-properties (overlay-get o 'after-string))))
                       (hinterl-test--hints))))))

(ert-deftest hinterl-major-mode-change-stops-backend ()
  (hinterl-test--buffer "f() -> ok."
    (let ((process hinterl--process))
      (fundamental-mode)
      (should-not (process-live-p process))
      (should-not hinterl--overlays))))

(ert-deftest hinterl-local-record-hints-and-option ()
  (hinterl-test--buffer "new() -> P = #person{}, Alias = P, Older = birthday(Alias), Older#person.age."
    (should (= 2 (length (hinterl-test--hints))))
    (dolist (o (hinterl-test--hints))
      (should (string-match-p "not a verified type" (overlay-get o 'help-echo)))
      (save-excursion
        (goto-char (overlay-start o))
        (should (looking-at " ="))))
    (let ((hinterl-record-hints nil))
      (hinterl-refresh)
      (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
      (should-not hinterl--overlays))))

(ert-deftest hinterl-local-record-edit-clears-stale ()
  (hinterl-test--buffer "f() -> P = unknown(), P#person.age."
    (should (= 1 (length (hinterl-test--hints))))
    (let ((old hinterl--analysis))
      (goto-char (point-min))
      (search-forward "person")
      (replace-match "animal")
      (hinterl--accept old)
      (should-not hinterl--overlays)
      (hinterl-refresh)
      (hinterl-test--wait (lambda () (equal hinterl--status "ok")))
      (should (equal " :: #animal{}" (substring-no-properties
                    (overlay-get (car (hinterl-test--hints)) 'after-string)))))))
