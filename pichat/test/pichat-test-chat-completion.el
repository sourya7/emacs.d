;;; pichat-test-chat-completion.el --- PiChat slash completion tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for generation-scoped command discovery and prompt completion.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-completion-capf-preserves-pi-order-and-annotations ()
  (with-temp-buffer
    (let ((input-start (make-marker)))
      (set-marker input-start (point))
      (setq-local pichat-chat-completion--status 'ready
                  pichat-chat-completion--commands
                  '((:name "Review.Exact" :source "template"
                     :description "Review code")
                    (:name "reset-now" :source "builtin"
                     :description "Reset session")))
      (insert "/")
      (let* ((capf (pichat-chat-completion-capf input-start))
             (table (nth 2 capf)))
        (should capf)
        (should (equal '("Review.Exact" "reset-now")
                       (all-completions "" table)))
        (should (eq #'identity
                    (completion-metadata-get
                     (completion-metadata "" table nil)
                     'display-sort-function)))
        (should (equal "  [template] Review code"
                       (funcall (plist-get (nthcdr 3 capf)
                                           :annotation-function)
                                "Review.Exact"))))
      (erase-buffer)
      (set-marker input-start (point))
      (insert "text /Rev")
      (should-not (pichat-chat-completion-capf input-start))
      (erase-buffer)
      (set-marker input-start (point))
      (insert "/Review.Exact argument")
      (should-not (pichat-chat-completion-capf input-start)))))

(ert-deftest pichat-chat-completion-identifies-only-exact-extension-commands ()
  (with-temp-buffer
    (setq-local pichat-chat-completion--status 'ready
                pichat-chat-completion--commands
                '((:name "codex-status" :source "extension")
                  (:name "review" :source "prompt")
                  (:name "skill:search" :source "skill")))
    (should (pichat-chat-completion-extension-command-p "/codex-status"))
    (should (pichat-chat-completion-extension-command-p
             "/codex-status --refresh"))
    (should-not (pichat-chat-completion-extension-command-p "/codex"))
    ;; Match Pi's parser: only a literal space separates command arguments.
    (should-not (pichat-chat-completion-extension-command-p
                 "/codex-status\t--refresh"))
    (should-not (pichat-chat-completion-extension-command-p
                 "/codex-status\n--refresh"))
    (should-not (pichat-chat-completion-extension-command-p "/review"))
    (should-not (pichat-chat-completion-extension-command-p
                 "/skill:search query"))
    (setq pichat-chat-completion--status 'loading)
    (should-not (pichat-chat-completion-extension-command-p
                 "/codex-status"))))

(ert-deftest pichat-chat-completion-inserts-without-submitting ()
  (with-temp-buffer
    (let ((input-start (make-marker))
          submitted)
      (set-marker input-start (point))
      (setq-local pichat-chat-completion--status 'ready
                  pichat-chat-completion--commands
                  '((:name "review" :source "template"
                     :description "Review code"))
                  completion-at-point-functions
                  (list (lambda ()
                          (pichat-chat-completion-capf input-start))))
      (insert "/rev")
      (cl-letf (((symbol-function 'pichat-rpc-prompt)
                 (lambda (&rest _args) (setq submitted t))))
        (completion-at-point))
      (should (equal "/review" (buffer-string)))
      (should-not submitted))))

(ert-deftest pichat-chat-completion-refresh-handles-success-empty-and-failure ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (let (success failure)
        (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                   (lambda (_session callback &optional error-callback)
                     (setq success callback failure error-callback)
                     "commands-request")))
          (pichat-chat-completion-reset 3 '(:session-id "source"))
          (should (equal "commands-request"
                         (pichat-chat-completion-refresh
                          session 3 '(:session-id "source"))))
          (should (eq 'loading pichat-chat-completion--status))
          (funcall success
                   '(:data (:commands
                            ((:name "first" :source "builtin")
                             (:name "Second" :source "extension")
                             (:name "" :source "invalid"))))
                   session)
          (should (eq 'ready pichat-chat-completion--status))
          (should (equal '("first" "Second")
                         (mapcar (lambda (command) (plist-get command :name))
                                 pichat-chat-completion--commands)))
          (pichat-chat-completion-refresh
           session 3 '(:session-id "source"))
          (funcall success '(:data (:commands nil)) session)
          (should (eq 'ready pichat-chat-completion--status))
          (should-not pichat-chat-completion--commands)
          (insert "/")
          (should-not (pichat-chat-completion-capf (copy-marker (point-min))))
          (pichat-chat-completion-refresh
           session 3 '(:session-id "source"))
          (funcall failure '(:success nil :error "commands unavailable") session)
          (should (eq 'failed pichat-chat-completion--status))
          (should-not pichat-chat-completion--commands)
          (should (equal "commands unavailable"
                         (plist-get pichat-chat-completion--last-error
                                    :error))))))))

(ert-deftest pichat-chat-completion-rejects-reordered-and-stale-source-callbacks ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (let (requests)
        (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                   (lambda (_session callback &optional error-callback)
                     (push (cons callback error-callback) requests)
                     (format "request-%d" (length requests)))))
          (pichat-chat-completion-reset 1 '(:session-id "one"))
          (pichat-chat-completion-refresh session 1 '(:session-id "one"))
          (let ((old-success (caar requests)))
            (pichat-chat-completion-refresh session 1 '(:session-id "one"))
            (let ((new-success (caar requests)))
              (funcall new-success
                       '(:data (:commands ((:name "new")))) session)
              (funcall old-success
                       '(:data (:commands ((:name "old")))) session)
              (should (equal "new"
                             (plist-get
                              (car pichat-chat-completion--commands) :name)))
              (pichat-chat-completion-reset 2 '(:session-id "two"))
              (funcall new-success
                       '(:data (:commands ((:name "stale")))) session)
              (should (eq 'unavailable pichat-chat-completion--status))
              (should-not pichat-chat-completion--commands))))))))

(ert-deftest pichat-chat-completion-clears-and-refreshes-during-source-rebind ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          requests buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                     (lambda (_session callback &optional error-callback)
                       (push (cons callback error-callback) requests)
                       (format "request-%d" (length requests)))))
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (funcall (caar requests)
                       '(:data (:commands ((:name "before")))) session)
              (should (equal "before"
                             (plist-get
                              (car pichat-chat-completion--commands) :name)))
              (pichat-chat--on-session-rebinding session nil nil)
              (should (eq 'unavailable pichat-chat-completion--status))
              (should-not pichat-chat-completion--commands)
              (setf (pichat-session-id session) "rebound")
              (pichat-chat--on-state-changed session nil nil)
              (should (eq 'loading pichat-chat-completion--status))
              (should (= 2 (length requests)))
              (funcall (caar requests)
                       '(:data (:commands ((:name "after")))) session)
              (should (equal "after"
                             (plist-get
                              (car pichat-chat-completion--commands) :name)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-completion)
;;; pichat-test-chat-completion.el ends here
