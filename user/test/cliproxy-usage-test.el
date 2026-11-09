;;; cliproxy-usage-test.el --- Offline local quota integration tests -*- lexical-binding: t; -*-

;; Run from the repository root:
;; emacs -Q --batch -L pichat -l user/test/cliproxy-usage-test.el \
;;   -f ert-run-tests-batch-and-exit
;; Also supports a separate non-batch Emacs for the live-window scenario.

(require 'ert)
(require 'cl-lib)
(require 'pichat)

(defconst cliproxy-test-user-directory
  (expand-file-name "../" (file-name-directory (or load-file-name buffer-file-name))))

(defun cliproxy-test-load-pichat-config ()
  "Load the real user module, stubbing only unrelated configuration DSLs."
  (cl-letf (((symbol-function 'use-package) (cons 'macro (lambda (&rest _) nil)))
            ((symbol-function 'my/add-all-to-list) #'ignore)
            ((symbol-function 'sharmaso/leader-keys) #'ignore)
            ((symbol-function 'sharmaso/mode-keys) #'ignore)
            ((symbol-function 'general-define-key)
             (cons 'macro (lambda (&rest _) nil))))
    (load (expand-file-name "pichat.el" cliproxy-test-user-directory) nil t)))

;; The configured module order is PiChat first, CLIProxy second.  Neither may
;; access auth/network, even with existing chats.  Reload in the opposite order
;; is exercised below too.
(cl-letf (((symbol-function 'auth-source-search)
           (lambda (&rest _) (ert-fail "Auth access during module load")))
          ((symbol-function 'url-retrieve)
           (lambda (&rest _) (ert-fail "Network access during module load"))))
  (cliproxy-test-load-pichat-config)
  (load (expand-file-name "cliproxy-usage.el" cliproxy-test-user-directory) nil t))

(defconst cliproxy-test-credentials
  '((files . (((provider . "codex") (auth_index . "fixture-index")
               (chatgpt_account_id . "fixture-account"))))))

(defun cliproxy-test-body (&optional used secondary-only)
  "Make a quota payload with USED percent used, optionally SECONDARY-ONLY."
  `((rate_limit
     . ((,(if secondary-only 'secondary_window 'primary_window)
         . ((used_percent . ,(or used 25))
            (reset_at . 1900000000)
            (limit_window_seconds . ,(if secondary-only 604800 18000))))))
    (account_id . "must-not-be-cached") (plan_type . "fixture-plan")))

(cl-defmacro cliproxy-test-with-requests (&rest body)
  "Run BODY with isolated cache and captured, entirely offline requests.
REQUESTS are ordered plists containing :path, :data and :callback."
  (declare (indent 0))
  `(let ((my/cliproxy-usage--snapshot nil)
         (my/cliproxy-usage--generation 0)
         (my/cliproxy-usage-updated-hook nil)
         (my/cliproxy-usage-display-policy 'report)
         requests displays)
     (cl-letf (((symbol-function 'auth-source-search)
                (lambda (&rest _) '((:host "quota.invalid" :secret "fixture-key"))))
               ((symbol-function 'my/cliproxy-usage--request)
                (lambda (base path key data callback)
                  (should (equal base "https://quota.invalid/v8/management"))
                  (should (equal key "fixture-key"))
                  (setq requests (append requests
                                         (list (list :path path :data data
                                                     :callback callback))))))
               ((symbol-function 'display-buffer)
                (lambda (buffer &rest _) (push buffer displays))))
       (unwind-protect (progn ,@body)
         (when-let* ((buffer (get-buffer "*CLIProxyAPI Usage*")))
           (kill-buffer buffer))))))

(defun cliproxy-test-reply (request response)
  "Deliver RESPONSE to captured REQUEST."
  (funcall (plist-get request :callback) response))

(defun cliproxy-test-quota-reply (request body &optional status)
  "Deliver quota BODY with STATUS through REQUEST."
  (cliproxy-test-reply request `((status_code . ,(or status 200)) (body . ,body))))

(ert-deftest cliproxy-command-report-publishes-normalized-account-wide-cache ()
  (cliproxy-test-with-requests
    (let ((updates 0))
      (add-hook 'my/cliproxy-usage-updated-hook (lambda () (cl-incf updates)))
      (call-interactively #'my/cliproxy-usage)
      (should (equal (plist-get (car requests) :path) "/credentials"))
      (should-not (my/cliproxy-usage-snapshot))
      (cliproxy-test-reply (car requests) cliproxy-test-credentials)
      (should (equal (plist-get (cadr requests) :path) "/requests/api-call"))
      (cliproxy-test-quota-reply (cadr requests)
                                (json-encode (cliproxy-test-body)))
      (let* ((snapshot (my/cliproxy-usage-snapshot))
             (window (car (plist-get snapshot :windows))))
        (should (= updates 1))
        (should (= (plist-get window :remaining) 75))
        (should (equal (plist-get window :label) "5-hour"))
        (should (plist-get snapshot :updated-at))
        (should-not (string-match-p "fixture-\\|must-not-be-cached"
                                           (prin1-to-string snapshot)))
        ;; Callers cannot corrupt the cache through the accessor.
        (setf (plist-get window :remaining) 0)
        (should (= 75 (plist-get (car (plist-get (my/cliproxy-usage-snapshot)
                                               :windows)) :remaining))))
      (should (= (length displays) 1))
      (with-current-buffer (car displays)
        (should buffer-read-only)
        (should (string-match-p "75.0% remaining" (buffer-string)))
        (should (string-match-p "account-wide, last fetched" (buffer-string)))))))

(ert-deftest cliproxy-command-captures-presentation-before-asynchronous-delivery ()
  (cliproxy-test-with-requests
    (with-temp-buffer
      (pichat-chat-mode)
      (call-interactively #'my/cliproxy-usage))
    (cliproxy-test-reply (car requests) cliproxy-test-credentials)
    ;; Origin has died, selected/current buffer is unrelated, and its policy is
    ;; report.  Late completion must still obey the captured chat policy.
    (cliproxy-test-quota-reply (cadr requests) (cliproxy-test-body 60 t))
    (should-not displays)
    (should (equal "Weekly" (plist-get (car (plist-get
                                             (my/cliproxy-usage-snapshot)
                                             :windows)) :label)))
    (with-temp-buffer (my/cliproxy-usage))
    (cliproxy-test-reply (nth 2 requests) cliproxy-test-credentials)
    (with-temp-buffer
      (pichat-chat-mode)
      (cliproxy-test-quota-reply (nth 3 requests) (cliproxy-test-body)))
    (should (= (length displays) 1))))

(ert-deftest cliproxy-chat-completion-messages-each-reset-time ()
  (cliproxy-test-with-requests
    (with-temp-buffer
      (pichat-chat-mode)
      (call-interactively #'my/cliproxy-usage))
    (cliproxy-test-reply (car requests) cliproxy-test-credentials)
    (let ((primary (alist-get 'rate_limit (cliproxy-test-body)))
          (secondary (alist-get 'rate_limit (cliproxy-test-body 60 t)))
          messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        ;; Completion runs after the originating chat has died.
        (cliproxy-test-quota-reply
         (cadr requests) `((rate_limit . ,(append primary secondary)))))
      (let ((reset (format-time-string "%Y-%m-%d %H:%M %Z"
                                       (seconds-to-time 1900000000))))
        (should (equal messages
                       (list (format "Codex resets: 5-hour: %s; Weekly: %s"
                                     reset reset))))))
    (should-not displays)))

(ert-deftest cliproxy-chat-completion-does-not-invent-missing-reset-times ()
  (cliproxy-test-with-requests
    (with-temp-buffer
      (pichat-chat-mode)
      (call-interactively #'my/cliproxy-usage))
    (cliproxy-test-reply (car requests) cliproxy-test-credentials)
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (cliproxy-test-quota-reply
         (cadr requests)
         '((rate_limit . ((secondary_window . ((used_percent . 0))))))))
      (should (equal messages '("Codex resets: Secondary: not reported"))))
    (should-not displays)))

(ert-deftest cliproxy-newest-request-alone-may-publish-at-both-stages ()
  (cliproxy-test-with-requests
    (my/cliproxy-usage 'header-only) ; request 0, old credentials
    (my/cliproxy-usage 'header-only) ; request 1
    (cliproxy-test-reply (car requests) cliproxy-test-credentials)
    (should (= (length requests) 2))
    (cliproxy-test-reply (cadr requests) cliproxy-test-credentials) ; request 2
    (my/cliproxy-usage 'header-only) ; request 3
    (cliproxy-test-reply (nth 3 requests) cliproxy-test-credentials) ; request 4
    (cliproxy-test-quota-reply (nth 4 requests) (cliproxy-test-body 10))
    (let ((snapshot (my/cliproxy-usage-snapshot)))
      (cliproxy-test-quota-reply (nth 2 requests) (cliproxy-test-body 90))
      (should (equal snapshot (my/cliproxy-usage-snapshot))))))

(ert-deftest cliproxy-failed-or-malformed-fetch-keeps-last-good-value-and-time ()
  (cliproxy-test-with-requests
    (my/cliproxy-usage--publish (cliproxy-test-body))
    (let ((snapshot (my/cliproxy-usage-snapshot)) (updates 0))
      (add-hook 'my/cliproxy-usage-updated-hook (lambda () (cl-incf updates)))
      (dolist (response (list '((status_code . 503))
                             '((status_code . "sensitive-server-payload"))
                             '((status_code . 200) (body . "not json: secret"))
                             '((status_code . 200) (body . nil))
                             `((status_code . 200)
                               (body . ,(cliproxy-test-body -1)))
                             `((status_code . 200)
                               (body . ,(cliproxy-test-body 101)))))
        (setq requests nil)
        (my/cliproxy-usage 'header-only)
        (cliproxy-test-reply (car requests) cliproxy-test-credentials)
        (let (messages)
          (cl-letf (((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (cliproxy-test-reply (cadr requests) response))
          (should messages)
          (should-not (string-match-p "sensitive-server-payload\\|secret"
                                             (mapconcat #'identity messages ""))))
        (should (equal snapshot (my/cliproxy-usage-snapshot))))
      (should (= updates 0))
      (should-not displays))))

(ert-deftest cliproxy-partial-windows-are-independent-and-not-fabricated ()
  (cliproxy-test-with-requests
    (should-not (my/pichat-cliproxy-header nil nil))
    (my/cliproxy-usage--publish
     '((rate_limit . ((secondary_window . ((used_percent . 0)))))))
    (let* ((segment (my/pichat-cliproxy-header nil nil))
           (full (plist-get segment :text))
           (help (get-text-property 0 'help-echo full)))
      (should (equal "100% secondary" full))
      (should-not (string-match-p "Primary\\|5-hour\\|Weekly" full))
      (should (string-match-p "Secondary resets: not reported" help))
      (should (string-match-p "Last successful refresh:" help))
      (should (string-match-p "account-wide" help)))
    (let ((snapshot (my/cliproxy-usage-snapshot)))
      (dolist (window '(((used_percent . "secret"))
                        ((used_percent . 20) (reset_at . "secret"))
                        ((used_percent . 20) (limit_window_seconds . -1))))
        (should-error (my/cliproxy-usage--publish
                       `((rate_limit . ((primary_window . ,window))))))
        (should (equal snapshot (my/cliproxy-usage-snapshot)))))))

(ert-deftest cliproxy-two-window-header-matches-pi-usage-presentation ()
  (cliproxy-test-with-requests
    (let ((primary (alist-get 'rate_limit (cliproxy-test-body 25)))
          (secondary (alist-get 'rate_limit (cliproxy-test-body 60 t))))
      (my/cliproxy-usage--publish
       `((rate_limit . ,(append primary secondary)))))
    (let* ((segment (my/pichat-cliproxy-header nil nil))
           (full (plist-get segment :text))
           (help (get-text-property 0 'help-echo full)))
      (should (equal full "75% 5h 40% wk"))
      (should (eq (plist-get segment :side) 'right))
      (should (string-match-p "5-hour resets: [0-9]" help))
      (should (string-match-p "Weekly resets: [0-9]" help))
      ;; Compare the real header layouts, not just the integration's string.
      (let ((session (pichat-session-make :cwd default-directory))
            (pichat-chat--extension-statuses nil)
            (pichat-chat-header-functions '(my/pichat-cliproxy-header)))
        (setf (pichat-session-context-usage session)
              '(:tokens 0 :contextWindow 500000 :percent 0))
        (let ((quota-header (pichat-chat--header-text session (selected-window)))
              (pichat-chat-header-functions nil)
              (pichat-chat--extension-statuses (make-hash-table :test #'equal)))
          (puthash "usage" "codex 75% 5h 40% wk" pichat-chat--extension-statuses)
          (should (equal quota-header
                         (pichat-chat--header-text session (selected-window)))))))))

(ert-deftest cliproxy-ambiguous-accounts-and-newer-auth-failure-cannot-publish ()
  (cliproxy-test-with-requests
    (my/cliproxy-usage--publish (cliproxy-test-body))
    (let ((snapshot (my/cliproxy-usage-snapshot)))
      (dolist (files (list nil
                          '(((provider . "codex") (disabled . t)))
                          '(((provider . "codex")) ((provider . "codex")))))
        (setq requests nil)
        (my/cliproxy-usage 'header-only)
        (cliproxy-test-reply (car requests) `((files . ,files)))
        (should (= (length requests) 1))
        (should (equal snapshot (my/cliproxy-usage-snapshot))))
      (setq requests nil)
      (my/cliproxy-usage 'header-only)
      (cliproxy-test-reply (car requests) cliproxy-test-credentials)
      (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
        (should-error (my/cliproxy-usage 'header-only) :type 'user-error))
      (cliproxy-test-quota-reply (cadr requests) (cliproxy-test-body 90))
      (should (equal snapshot (my/cliproxy-usage-snapshot))))
    (should-not displays)))

(ert-deftest cliproxy-management-transport-failures-do-not-publish-or-leak ()
  ;; Exercise the real request boundary, not just the mocked orchestration.
  (let ((my/cliproxy-usage--snapshot nil) callbacks messages)
    (dolist (case '((503 nil "secret server payload")
                    (200 (:error "secret network error") "{}")
                    (200 nil "secret malformed response")
                    (200 nil "{\"files\":[]}")))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages)))
                ((symbol-function 'url-retrieve)
                 (lambda (_url callback &rest _)
                   (with-current-buffer (generate-new-buffer " *quota-response*")
                     (setq-local url-http-response-status (car case))
                     (insert "headers\n\n" (nth 2 case))
                     (setq-local url-http-end-of-headers 10)
                     (funcall callback (cadr case))))))
        (my/cliproxy-usage--request "https://quota.invalid" "/test" "inert" nil
                                   (lambda (response) (push response callbacks))))
      (should-not (get-buffer " *quota-response*")))
    (should (equal callbacks '(((files)))))
    (should-not (my/cliproxy-usage-snapshot))
    (should (= (length messages) 3))
    (should-not (string-match-p "secret" (mapconcat #'identity messages "")))))

(ert-deftest cliproxy-headers-refresh-shared-owners-and-reload-idempotently ()
  (cliproxy-test-with-requests
    (let* ((sessions (list (pichat-session-make :cwd default-directory)
                           (pichat-session-make :cwd default-directory)))
           (pichat-chat-stop-session-on-kill nil)
           (first (pichat-chat-ensure (car sessions)))
           (second (pichat-chat-ensure (cadr sessions)))
           refreshed)
      (unwind-protect
          (cl-letf (((symbol-function 'auth-source-search)
                     (lambda (&rest _) (ert-fail "Unexpected auth access")))
                    ((symbol-function 'url-retrieve)
                     (lambda (&rest _) (ert-fail "Unexpected network access")))
                    ((symbol-function 'pichat-chat-refresh-header)
                     (lambda (session) (push session refreshed))))
            (cl-mapc (lambda (buffer session)
                       (with-current-buffer buffer
                         (should (eq pichat-chat-session session))
                         (goto-char (point-max))
                         (insert "unchanged draft")
                         ;; Simulate a chat predating integration setup.
                         (kill-local-variable 'my/cliproxy-usage-display-policy)))
                     (list first second) sessions)
            (dotimes (_ 2) (cliproxy-test-load-pichat-config))
            (should (= 1 (cl-count #'my/pichat-cliproxy-header
                                  pichat-chat-header-functions)))
            (should (= 1 (cl-count #'my/pichat-cliproxy-chat-policy
                                  pichat-chat-mode-hook)))
            (should (= 1 (cl-count #'my/pichat-cliproxy-refresh-headers
                                  my/cliproxy-usage-updated-hook)))
            (setq refreshed nil)
            (my/cliproxy-usage--publish (cliproxy-test-body))
            (should (= (length refreshed) 2))
            (dolist (session sessions) (should (memq session refreshed)))
            (dolist (buffer (list first second))
              (with-current-buffer buffer
                (should (eq my/cliproxy-usage-display-policy 'header-only))
                (should (string-suffix-p "unchanged draft" (buffer-string)))
                (should (my/pichat-cliproxy-header pichat-chat-session
                                                    (selected-window)))))
            (with-temp-buffer
              (pichat-chat-mode)
              (should (eq my/cliproxy-usage-display-policy 'header-only))
              (should (my/pichat-cliproxy-header nil nil))))
        (kill-buffer first)
        (kill-buffer second)))))

(ert-deftest cliproxy-live-windows-preserve-focus-draft-and-context-priority ()
  ;; Run in batch too; non-batch terminal invocation verifies real redisplay.
  (cliproxy-test-with-requests
    (let* ((session (pichat-session-make :cwd default-directory))
           (pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (buffer (pichat-chat-ensure session)))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buffer)
            (delete-other-windows)
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "unsent quota fixture draft")
              (let ((text (buffer-string)) (point (point))
                    (window (selected-window)))
                (add-hook 'my/cliproxy-usage-updated-hook
                          #'my/pichat-cliproxy-refresh-headers)
                (call-interactively #'my/cliproxy-usage)
                (cliproxy-test-reply (car requests) cliproxy-test-credentials)
                (cliproxy-test-quota-reply (cadr requests)
                                          (cliproxy-test-body 25))
                (should (equal text (buffer-string)))
                (should (= point (point)))
                (should (eq window (selected-window)))
                (should-not displays)
                (let ((wide (pichat-chat--header-text session window)))
                  (should (string-match-p "75% 5h" wide))
                  (should (get-text-property
                           (string-match "75% 5h" wide) 'help-echo wide))
                  (unless noninteractive
                    (should (equal wide (format-mode-line
                                         header-line-format nil window buffer)))))
                (let ((narrow (split-window window -24 'right)))
                  (set-window-buffer narrow buffer)
                  (let ((text (pichat-chat--header-text session narrow)))
                    (should-not (string-match-p "75% 5h" text))
                    (should (string-match-p "unavailable" text))))
                (redisplay t)
                (should (= (length requests) 2))
                (should (eq window (selected-window)))
                (should (equal text (buffer-string))))))
        (kill-buffer buffer)))))

;;; cliproxy-usage-test.el ends here
