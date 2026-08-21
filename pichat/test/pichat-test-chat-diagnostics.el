;;; pichat-test-chat-diagnostics.el --- PiChat diagnostic tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for conservative classification, bounded status, retained raw
;; transport data, explicit inspection, and setup command policy.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-chat-diagnostics)

(ert-deftest pichat-diagnostics-classification-fixtures-avoid-false-credentials ()
  (dolist (fixture
           (pichat-test-read-json-fixture "diagnostic-classification.json"))
    (let* ((origin (intern (plist-get fixture :origin)))
           (actual (pichat-chat-diagnostics-classify
                    origin (plist-get fixture :text)))
           (expected-text (plist-get fixture :expectedCategory))
           (expected (and expected-text (intern expected-text))))
      (ert-info ((plist-get fixture :name))
        (should (eq expected actual))))))

(ert-deftest pichat-diagnostics-local-start-classification-uses-condition-context ()
  (should
   (eq 'permission-denied
       (pichat-chat-diagnostics-classify
        'process-start "Spawning child process: Permission denied"
        '(file-error "Spawning child process" "Permission denied") "/opt/pi")))
  (should-not
   (pichat-chat-diagnostics-classify
    'process-start "Setting current directory: No such file or directory"
    '(file-missing "Setting current directory" "No such file or directory")
    "/opt/pi")))

(ert-deftest pichat-diagnostics-normal-summary-is-redacted-and-bounded ()
  (let ((pichat-diagnostics-summary-width 120))
    (let ((summary
           (pichat-chat-diagnostics-summary
            :origin 'rpc-response
            :message
            (concat "Request detail token=super-secret Bearer abc.def "
                    "sk-live-secret " (make-string 300 ?x)))))
      (should (<= (string-width summary) 120))
      (should (string-match-p "REDACTED" summary))
      (should-not (string-match-p "super-secret\|abc\\.def\|sk-live-secret"
                                  summary)))))

(ert-deftest pichat-diagnostics-records-and-raw-values-are-bounded ()
  (let ((pichat-diagnostics-record-limit 2)
        (pichat-diagnostics-stderr-limit 12))
    (let ((session (pichat-session-make)))
      (dotimes (index 3)
        (pichat-chat-diagnostics-record
         session :origin 'process-exit
         :message (format "failure-%d" index)
         :stderr (concat (make-string 30 ?s) (number-to-string index))))
      (should (= 2 (length (pichat-session-diagnostics session))))
      (should (string-match-p
               "truncated by PiChat"
               (plist-get (car (pichat-session-diagnostics session)) :stderr)))
      (should (equal "failure-2"
                     (plist-get (car (pichat-session-diagnostics session))
                                :message))))))

(ert-deftest pichat-diagnostics-startup-failure-is-local-and-inspectable ()
  (pichat-test-with-clean-state
    (let* ((missing (expand-file-name
                     "definitely-missing-pichat-pi" temporary-file-directory))
           (pichat-rpc-command (list missing "--mode" "rpc"))
           (session (pichat-session-make :cwd default-directory))
           emitted)
      (pichat-on 'error
                 (lambda (_session _event plist) (setq emitted plist)) session)
      (should (eq session (pichat-rpc-start session)))
      (should (eq 'error (pichat-session-state session)))
      (should-not (pichat-session-process session))
      (let ((record (pichat-chat-diagnostics-latest session)))
        (should (eq 'process-start (plist-get record :origin)))
        (should (eq 'executable-not-found (plist-get record :category)))
        (should (eq record (plist-get emitted :diagnostic)))
        (should-not (plist-member emitted :condition))
        (should (string-match-p "pichat-rpc-command"
                                (plist-get emitted :message)))))))

(ert-deftest pichat-diagnostics-valid-pi-response-is-not-a-process-failure ()
  (pichat-test-with-unit-session (session proc)
    (let (error-response)
      (let ((id (pichat-rpc-send
                 session "prompt" '(:message "hello") nil
                 (lambda (response _session) (setq error-response response)))))
        (pichat-rpc--process-filter
         proc
         (format
          "{\"type\":\"response\",\"id\":%S,\"command\":\"prompt\",\"success\":false,\"error\":\"No API key found for \\\"anthropic\\\". Run /login.\"}\n"
          id)))
      (should error-response)
      (should-not (plist-get error-response :pichat-failure-kind))
      (let ((record (plist-get error-response :pichat-diagnostic)))
        (should (eq 'rpc-response (plist-get record :origin)))
        (should (eq 'missing-credential (plist-get record :category)))
        (should-not (plist-get record :exit-status))
        (should-not
         (plist-get (plist-get record :response) :pichat-diagnostic)))
      (should (process-live-p proc)))))

(ert-deftest pichat-diagnostics-process-exit-hides-raw-stderr-from-normal-event ()
  (pichat-test-with-clean-state
    (let* ((secret "stderr-token=raw-secret")
           (pichat-rpc-command
            (list "sh" "-c" (format "printf %s >&2; exit 9" secret)))
           (session (pichat-session-make :cwd default-directory))
           emitted)
      (pichat-on 'error
                 (lambda (_session _event plist) (setq emitted plist)) session)
      (pichat-rpc-start session)
      (pichat-test-wait-until (lambda () emitted) 2 "safe process failure")
      (let ((record (pichat-chat-diagnostics-latest session)))
        (should (eq 'process-exit (plist-get record :origin)))
        (should (= 9 (plist-get record :exit-status)))
        (should (equal secret (plist-get record :stderr)))
        (should-not (plist-member emitted :stderr))
        (should-not (string-match-p "raw-secret" (plist-get emitted :message)))))))

(ert-deftest pichat-diagnostics-explicit-view-shows-retained-stderr-and-events ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :state 'error
                                        :rpc-command '("wrapper" "secret-arg"))))
      (pichat-chat-diagnostics-record
       session :origin 'process-exit :message "failed"
       :stderr "raw stderr secret" :exit-status 7)
      (setf (pichat-session-event-log session)
            '((:type "newest" :private "event secret")
              (:type "oldest")))
      (save-window-excursion
        (let ((buffer (pichat-show-transport-diagnostics session)))
          (unwind-protect
              (with-current-buffer buffer
                (should (derived-mode-p 'pichat-view-mode))
                (let ((text (buffer-substring-no-properties
                             (point-min) (point-max))))
                  (should (string-match-p "WARNING" text))
                  (should (string-match-p "raw stderr secret" text))
                  (should (string-match-p "event secret" text))
                  (should (< (string-match "oldest" text)
                             (string-match "newest" text)))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest pichat-diagnostics-chat-open-projects-only-safe-existing-summary ()
  (pichat-test-with-clean-state
    (let* ((pichat-chat-stop-session-on-kill nil)
           (session (pichat-session-make :cwd default-directory))
           buffer)
      (pichat-chat-diagnostics-record
       session :origin 'process-exit :message "failed"
       :stderr "token=must-not-render" :exit-status 4)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((text (pichat-test-buffer-text buffer)))
              (should (string-match-p "process exited unexpectedly" text))
              (should-not (string-match-p "must-not-render" text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-diagnostics-top-level-chat-opens-after-startup-failure ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command
           (list (expand-file-name "missing-pi-for-chat"
                                   temporary-file-directory)))
          (pichat-chat-stop-session-on-kill nil)
          session buffer)
      (unwind-protect
          (progn
            (setq session (pichat)
                  buffer (pichat-session-buffer session))
            (should (eq 'error (pichat-session-state session)))
            (should (buffer-live-p buffer))
            (should (string-match-p
                     "executable was not found"
                     (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-diagnostics-interactive-setup-policy-covers-plain-and-wrapper ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/custom/pi")
        (pichat-diagnostics-interactive-command nil))
    (should (eq 'plain-executable (pichat-chat-diagnostics-setup-kind)))
    (should (equal '("/opt/custom/pi")
                   (pichat-chat-diagnostics-interactive-argv))))
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (pichat-diagnostics-interactive-command nil))
    (should (eq 'wrapper-command (pichat-chat-diagnostics-setup-kind)))
    (should-not (pichat-chat-diagnostics-interactive-argv)))
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (pichat-diagnostics-interactive-command
         '("docker" "run" "-it" "image" "pi")))
    (should (equal '("docker" "run" "-it" "image" "pi")
                   (pichat-chat-diagnostics-interactive-argv)))))

(ert-deftest pichat-diagnostics-interactive-pi-applies-extra-environment ()
  (pichat-test-with-clean-state
    (let ((process-environment
           (cons "PICHAT_INTERACTIVE_ENV=inherited" process-environment))
          (pichat-pi-extra-env
           '(("PICHAT_INTERACTIVE_ENV" . "interactive")))
          (pichat-rpc-command nil)
          (pichat-pi-executable "/opt/pi")
          captured)
      (unwind-protect
          (cl-letf (((symbol-function 'make-term)
                     (lambda (&rest _args)
                       (setq captured (getenv "PICHAT_INTERACTIVE_ENV"))
                       (error "Stop after environment capture"))))
            (should-error (pichat-diagnostics-open-interactive-pi))
            (should (equal "interactive" captured)))
        (when-let ((buffer (get-buffer "*PiChat Pi Setup*")))
          (kill-buffer buffer))))))

(ert-deftest pichat-diagnostics-probe-applies-extra-pi-environment ()
  (let ((process-environment
         (cons "PICHAT_PROBE_ENV=inherited" process-environment))
        (pichat-pi-extra-env '(("PICHAT_PROBE_ENV" . "probe")))
        captured output)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (_transport _runtime-cwd &rest args)
                     (setq captured (getenv "PICHAT_PROBE_ENV")
                           output (plist-get args :buffer))
                     'fake-process)))
          (pichat-diagnostics-probe-pi)
          (should (equal "probe" captured)))
      (when (buffer-live-p output) (kill-buffer output)))))

(ert-deftest pichat-diagnostics-settings-path-honors-extra-pi-environment ()
  (pichat-test-with-temp-dir inherited-dir
    (pichat-test-with-temp-dir configured-dir
      (let ((process-environment
             (cons (concat "PI_CODING_AGENT_DIR=" inherited-dir)
                   process-environment))
            (pichat-pi-extra-env
             `(("PI_CODING_AGENT_DIR" . ,configured-dir)))
            visited)
        (cl-letf (((symbol-function 'find-file)
                   (lambda (path &rest _args) (setq visited path))))
          (pichat-diagnostics-open-settings))
        (should (equal (expand-file-name "settings.json" configured-dir)
                       visited))))))

(provide 'pichat-test-chat-diagnostics)
;;; pichat-test-chat-diagnostics.el ends here
