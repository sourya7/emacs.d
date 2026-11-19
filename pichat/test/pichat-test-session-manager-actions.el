;;; pichat-test-session-manager-actions.el --- Runtime manager Actions tests -*- lexical-binding: t; -*-

;;; Code:

(require 'pichat-test-support)
(require 'pichat-session-manager-actions)

(defun pichat-test-manager-actions--close ()
  "Run Transient's exit hooks and discard the fixture popup."
  (when transient--prefix
    (transient--pre-exit)
    (transient--post-exit))
  (when-let* ((buffer (get-buffer transient--buffer-name)))
    (kill-buffer buffer)))

(defmacro pichat-test-manager-actions--with-manager (&rest body)
  "Run BODY in a disposable manager displaying the live runtime `session'."
  (declare (indent 0))
  `(pichat-test-with-unit-session (session proc)
     (with-temp-buffer
       (save-window-excursion
         (switch-to-buffer (current-buffer))
         (setf (pichat-session-id session) "source-a"
               (pichat-session-state session) 'ready
               (pichat-session-persistence session) 'persistent)
         (pichat-register-session session '("actions" "/tmp/" "Actions fixture"))
         (pichat-session-manager-mode)
         (pichat-session-manager-refresh)
         (pichat-test-manager-actions--select session)
         (unwind-protect (progn ,@body)
           (pichat-test-manager-actions--close))))))

(defun pichat-test-manager-actions--select (session)
  "Select the tabulated row for SESSION in the fixture manager."
  (let ((row (text-property-any (point-min) (point-max) 'tabulated-list-id
                                (pichat-session-runtime-id session))))
    (should row)
    (goto-char row)))

(defun pichat-test-manager-actions--key (key)
  "Return the binding for KEY in the open Actions popup."
  (lookup-key transient--transient-map (kbd key)))

(defun pichat-test-manager-actions--suffix (key)
  "Open Actions, find the command for KEY, and exit as before a suffix runs."
  (pichat-session-manager-actions)
  (let ((command (pichat-test-manager-actions--key key)))
    (should (commandp command))
    (pichat-test-manager-actions--close)
    command))

(ert-deftest pichat-manager-actions-offers-only-applicable-commands ()
  (dolist (case '((idle       ("m" "k" "D") "Stop")
                  (streaming  ("m" "k" "D") "Stop…")
                  (ephemeral  ("m" "k" "D") "Stop…")
                  (preferred  ("k" "D")     "Stop")
                  (stopped    ("d" "D")     nil)
                  (failed     ("d" "D")     nil)
                  (no-diag    ("m" "k")     "Stop")
                  (no-row     nil           nil)))
    (pcase-let ((`(,state ,conditional-keys ,stop-label) case))
      (ert-info ((format "Runtime manager Actions: %s" state))
        (pichat-test-manager-actions--with-manager
          (pcase state
            ('streaming (setf (pichat-session-streaming-p session) t
                              (pichat-session-state session) 'running))
            ('ephemeral (setf (pichat-session-persistence session) 'ephemeral))
            ('preferred (pichat-set-default-session session))
            ((or 'stopped 'failed)
             (setf (pichat-session-process session) nil
                   (pichat-session-state session) (if (eq state 'failed) 'error 'stopped)))
            ('no-row (goto-char (point-max))))
          (let ((capabilities (symbol-function 'pichat-backend-session-capabilities))
                (row-keys '("o" "e" "p" "N"))
                (expected (append conditional-keys
                                  (unless (eq state 'no-row) '("o" "e" "p" "N")))))
            (cl-letf (((symbol-function 'pichat-backend-session-capabilities)
                       (lambda (backend target)
                         (let ((actual (funcall capabilities backend target)))
                           (if (eq state 'no-diag) (remq 'diagnostics actual) actual)))))
              (pichat-session-manager-actions))
            (dolist (key '("n" "+" "b" "q"))
              (should (commandp (pichat-test-manager-actions--key key))))
            (dolist (key (append row-keys '("m" "k" "d" "D")))
              (if (member key expected)
                  (should (commandp (pichat-test-manager-actions--key key)))
                (should-not (pichat-test-manager-actions--key key))))
            (with-current-buffer transient--buffer-name
              (when (eq state 'no-row)
                (should-not (string-match-p "^Runtime\\|^Inspect" (buffer-string)))
                (should (string-match-p "^Start" (buffer-string))))
              (if stop-label
                  (progn
                    (goto-char (point-min))
                    (should (re-search-forward "^[ \t]*k[ \t]+\\(Stop…?\\)" nil t))
                    (should (equal (match-string-no-properties 1) stop-label)))
                (should-not (string-match-p "^[ \t]*k[ \t]+Stop" (buffer-string)))))))))))

(ert-deftest pichat-manager-actions-native-a-opens-without-rpc ()
  (pichat-test-manager-actions--with-manager
    (when (bound-and-true-p evil-local-mode) (evil-local-mode -1))
    (let ((open (key-binding (kbd "a")))
          (seq (pichat-session-rpc-seq session)))
      (should (eq open 'pichat-session-manager-actions))
      (dolist (position (list (point) (point-max)))
        (goto-char position)
        (call-interactively open)
        (should (eq (pichat-test-manager-actions--key "q") 'transient-quit-one))
        (should (equal seq (pichat-session-rpc-seq session)))
        (pichat-test-manager-actions--close)
        (should (equal seq (pichat-session-rpc-seq session)))))))

(ert-deftest pichat-manager-actions-dispatches-to-captured-runtime-after-point-moves ()
  (pichat-test-manager-actions--with-manager
    (let* ((other (pichat-register-session
                   (pichat-session-make :state 'stopped) '("other" "/tmp/" "Other")))
           (open (pichat-test-manager-actions--suffix "o"))
           (stop (pichat-test-manager-actions--suffix "k"))
           opened stopped
           (pichat-session-manager-display-chat-function
            (lambda (target) (setq opened target))))
      (pichat-session-manager-refresh)
      (pichat-test-manager-actions--select other)
      (cl-letf (((symbol-function 'pichat-stop-session)
                 (lambda (target) (setq stopped target))))
        (call-interactively open)
        (call-interactively stop))
      (should (eq opened session))
      (should (eq stopped session)))))

(defun pichat-test-manager-actions--assert-stale (command)
  "Assert COMMAND refuses a stale capture and asks to reopen Actions."
  (let ((err (should-error (call-interactively command) :type 'user-error)))
    (should (string-suffix-p "; reopen Actions" (cadr err)))))

(ert-deftest pichat-manager-actions-refuses-runtime-forgotten-after-opening ()
  (pichat-test-manager-actions--with-manager
    (let ((command (pichat-test-manager-actions--suffix "o"))
          (pichat-session-manager-display-chat-function
           (lambda (&rest _) (ert-fail "Opened a forgotten runtime"))))
      (setf (pichat-session-process session) nil
            (pichat-session-state session) 'stopped)
      (pichat-session-manager-forget session)
      (pichat-test-manager-actions--assert-stale command))))

(ert-deftest pichat-manager-actions-refuses-stop-after-process-replacement ()
  (pichat-test-manager-actions--with-manager
    (let ((command (pichat-test-manager-actions--suffix "k"))
          (replacement (make-pipe-process :name "actions-replacement" :noquery t)))
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-stop-session)
                     (lambda (&rest _) (ert-fail "Stopped a replacement process"))))
            (setf (pichat-session-process session) replacement)
            (pichat-test-manager-actions--assert-stale command))
        (delete-process replacement)))))

(ert-deftest pichat-manager-actions-revalidates-stop-after-confirmation ()
  (pichat-test-manager-actions--with-manager
    (setf (pichat-session-persistence session) 'ephemeral)
    (let ((command (pichat-test-manager-actions--suffix "k")) prompted)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (_prompt)
                   (setq prompted t)
                   (setf (pichat-session-process-generation session) 'replacement)
                   t))
                ((symbol-function 'pichat-stop-session)
                 (lambda (&rest _) (ert-fail "Stopped after generation changed"))))
        (pichat-test-manager-actions--assert-stale command)
        (should prompted)))))

(ert-deftest pichat-manager-actions-refuses-name-after-source-change ()
  (dolist (during-prompt '(nil t))
    (pichat-test-manager-actions--with-manager
      (let ((command (pichat-test-manager-actions--suffix "e")) prompted)
        (unless during-prompt (setf (pichat-session-id session) "source-b"))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _)
                     (setq prompted t)
                     (setf (pichat-session-id session) "source-b")
                     "new name"))
                  ((symbol-function 'pichat-backend-name-session)
                   (lambda (&rest _) (ert-fail "Named a different Pi session"))))
          (pichat-test-manager-actions--assert-stale command)
          (should (eq prompted during-prompt)))))))

(ert-deftest pichat-manager-actions-renders-at-narrow-and-wide-widths ()
  (pichat-test-manager-actions--with-manager
    (setf (pichat-session-persistence session) 'ephemeral)
    (dolist (case '((42 80 t) (80 80 nil) (120 80 nil) (42 0 nil)))
      (pcase-let ((`(,width ,pichat-transient-single-column-width ,stacked) case))
        (ert-info ((format "%d columns, threshold %d"
                           width pichat-transient-single-column-width))
          (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) width)))
            (pichat-session-manager-actions)
            (with-selected-window transient--window
              (let ((case-fold-search nil)
                    (text (buffer-string)))
                (should (eq (not (null transient-force-single-column)) stacked))
                (unless (zerop pichat-transient-single-column-width)
                  (dolist (line (split-string text "\n"))
                    (should (<= (string-width line) width))))
                (if stacked
                    (progn
                      (should (string-match-p
                               "^Runtime\n\\(?:.*\n\\)*?Inspect\n\\(?:.*\n\\)*?Start\n\\(?:.*\n\\)*? q +Close"
                               text))
                      (should pichat-transient--no-wrap)
                      (goto-char (point-max))
                      (backward-button 1)
                      (transient-forward-button 1)
                      (should (= (point) (point-max)))
                      (goto-char (point-min))
                      (forward-button 1)
                      (transient-backward-button 1)
                      (should (= (point) (point-min))))
                  (should (string-match-p "^Runtime.*Inspect.*Start" text)))))
            (pichat-test-manager-actions--close)))))))

(provide 'pichat-test-session-manager-actions)
;;; pichat-test-session-manager-actions.el ends here
