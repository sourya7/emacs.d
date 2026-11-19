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

(ert-deftest pichat-diagnostics-ssh-start-classifies-connection-errors-only ()
  (dolist (text '("TRAMP: connection refused token=private"
                  "Could not resolve hostname example.invalid"
                  "connection timed out" "connection failed"))
    (ert-info (text)
      (should (eq 'connection-failed
                  (pichat-chat-diagnostics-classify
                   'process-start text '(file-error "Could not start" text)
                   "/remote/pi")))
      (let ((summary (pichat-chat-diagnostics-summary
                      :origin 'process-start :category 'connection-failed
                      :message text :setup-kind 'ssh)))
        (should (string-match-p "SSH target" summary))
        (should-not (string-match-p "private\\|example.invalid" summary)))))
  (dolist (text '("trampoline is unavailable" "unrelated file error"
                  "Could not resolve hostnames in output"))
    (ert-info (text)
      (should-not (pichat-chat-diagnostics-classify
                   'process-start text '(file-error "Could not start")
                   "/remote/pi"))))
  (should-not (pichat-chat-diagnostics-classify
               'rpc-response "connection refused" nil "/remote/pi"))
  (should-not (pichat-chat-diagnostics-classify
               'process-start "connection refused" '(error "not a file error")
               "/remote/pi")))

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
        (let ((buffer (pichat-show-diagnostics session)))
          (unwind-protect
              (with-current-buffer buffer
                (should (derived-mode-p 'pichat-view-mode))
                (goto-char (point-min))
                (search-forward "Retained incoming events")
                (beginning-of-line)
                (forward-char 2)
                (call-interactively (key-binding (kbd "RET")))
                (let ((text (buffer-substring-no-properties
                             (point-min) (point-max))))
                  (should-not (string-match-p "Review before sharing" text))
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
    (let ((pichat-default-preset 'standard)
          (pichat-rpc-command
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
        (when-let* ((buffer (get-buffer "*PiChat Pi Setup*")))
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

(ert-deftest pichat-diagnostics-shared-records-deduplicate-with-a-bound ()
  (let* ((record (pichat-diagnostic-create
                  :domain 'compatibility :category 'unknown-entry
                  :entry-id "entry" :type "context_edit"))
         (records (pichat-diagnostic-append nil record 1)))
    (should (equal records (pichat-diagnostic-append records record 1)))
    (should (equal records (pichat-diagnostic-append records '(:category other) 1)))
    (should (equal (pichat-diagnostic-summary record)
                   "unknown-entry at entry (context_edit)"))))

(ert-deftest pichat-diagnostics-report-preserves-collectors-and-separates-sensitive-evidence ()
  (let* ((session (pichat-session-make))
         (pichat-diagnostics-section-functions
          (list (lambda (_session)
                  (list (cons "Canonical transcript"
                              (list (pichat-diagnostic-create
                                     :domain 'compatibility
                                     :category 'unknown-entry :entry-id "entry"
                                     :type "context_edit")))
                        (cons "Live tail" nil)))))
         buffer)
    (pichat-chat-diagnostics-record
     session :origin 'rpc-response :message "token=secret-value"
     :stderr "raw-private-output")
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
          (setq buffer (pichat-show-diagnostics session))
          (with-current-buffer buffer
            (let ((text (buffer-string)))
              (should (string-match-p "unknown-entry at entry (context_edit)" text))
              (should (string-match-p "^  none retained (Live tail)$" text))
              (should (string-match-p "^Unavailable .*Session History snapshot$" text))
              (should (string-match-p "secret-value" text))
              (should (string-match-p "raw-private-output" text))
              ;; Only explicit evidence, not the overview or ordinary chat,
              ;; exposes the bounded retained payload.
              (should-not (string-match-p
                           "secret-value\\|raw-private-output"
                           pichat-diagnostics-report--overview))
              (should (string-prefix-p pichat-diagnostics-report--overview text))))
          (should (= 1 (length (pichat-session-diagnostics session)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest pichat-diagnostics-history-provider-rejects-stale-sources ()
  (require 'pichat-sessions)
  (let ((session (pichat-session-make)))
    (with-temp-buffer
      (setq major-mode 'pichat-sessions-mode)
      (setq-local pichat-sessions-session session)
      (setq-local pichat-sessions--source-token
                  (pichat-sessions--session-source-token session))
      (setq-local pichat-sessions--diagnostics
                  (list (pichat-diagnostic-create :domain 'history :summary "warning")))
      (should (assoc "Session History" (pichat-sessions--diagnostic-sections session)))
      (setq-local pichat-sessions--stale-p t)
      (should-not (pichat-sessions--diagnostic-sections session)))))

(ert-deftest pichat-diagnostics-chat-provider-rejects-rebinding-and-other-runtimes ()
  (require 'pichat-chat)
  (let ((session (pichat-session-make))
        (other (pichat-session-make)))
    (with-temp-buffer
      (setq major-mode 'pichat-chat-mode)
      (setq-local pichat-chat-session session)
      (setf (pichat-session-buffer session) (current-buffer))
      (setq-local pichat-chat--source-bound-p t)
      (setq-local pichat-chat--source-session-id (pichat-session-id session))
      (setq-local pichat-chat--source-session-file (pichat-session-session-file session))
      (setq-local pichat-chat--canonical-transcript
                  (pichat-transcript-create :diagnostics nil))
      (should (assoc "Canonical transcript" (pichat-chat--diagnostic-sections session)))
      (should-not (pichat-chat--diagnostic-sections other))
      (setq-local pichat-chat--restart-staging '(:snapshot t))
      (should-not (pichat-chat--diagnostic-sections session))
      (setq-local pichat-chat--restart-staging nil)
      (setf (pichat-session-buffer session) nil)
      (should-not (pichat-chat--diagnostic-sections session))
      (setf (pichat-session-buffer session) (current-buffer))
      (setq-local pichat-chat--source-rebinding-p t)
      (should-not (pichat-chat--diagnostic-sections session)))))

(ert-deftest pichat-diagnostics-customization-alias-opens-the-pichat-group ()
  (dolist (command '(pichat-diagnostics-customize
                     pichat-diagnostics-customize-transport))
    (let (group)
      (cl-letf (((symbol-function 'customize-group)
                 (lambda (value &rest _) (setq group value))))
        (call-interactively command))
      (should (eq group 'pichat)))))

(ert-deftest pichat-diagnostics-setup-terminals-reuse-only-matching-contexts ()
  (pichat-test-with-temp-dir directory
    (let* ((session (pichat-session-make :cwd directory))
           (other (pichat-session-make :cwd directory))
           (pichat-diagnostics-interactive-command '("sh" "-c" "cat >/dev/null"))
           (pichat-pi-extra-env nil)
           (process-environment (copy-sequence process-environment))
           (buffers nil)
           first)
      (unwind-protect
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _) (cl-pushnew buffer buffers) buffer)))
            ;; Real inert terminal processes: never invoke Pi or user config.
            (setq first (pichat-diagnostics-open-interactive-pi session))
            (should (process-live-p (get-buffer-process first)))
            (should (eq first (pichat-diagnostics-open-interactive-pi session)))
            (should (eq first (pichat-diagnostics-open-interactive-pi other)))
            (let ((pichat-diagnostics-interactive-command '("sh" "-c" "cat > /dev/null")))
              (should-not (eq first (pichat-diagnostics-open-interactive-pi session))))
            (let ((pichat-pi-extra-env '(("PICHAT_TEST_SETUP" . "changed"))))
              (should-not (eq first (pichat-diagnostics-open-interactive-pi session))))
            (let ((exec-path (cons directory exec-path)))
              (should-not (eq first (pichat-diagnostics-open-interactive-pi session))))
            (setf (pichat-session-transport other)
                  (pichat-transport--create :id 'different-target :kind 'local))
            (should-not (eq first (pichat-diagnostics-open-interactive-pi other)))
            (setf (pichat-session-emacs-cwd session) temporary-file-directory)
            (should-not (eq first (pichat-diagnostics-open-interactive-pi session)))
            (setf (pichat-session-emacs-cwd session) directory)
            (should (eq first (pichat-diagnostics-open-interactive-pi session)))
            (should (= 6 (length buffers)))
            (dolist (buffer buffers)
              (should (process-live-p (get-buffer-process buffer))))
            ;; Stopped and untracked buffers are never treated as live matches.
            (delete-process (get-buffer-process first))
            (should-not (eq first (pichat-diagnostics-open-interactive-pi session)))
            (should (= 7 (length buffers))))
        (dolist (buffer buffers)
          (when-let* ((process (get-buffer-process buffer)))
            (delete-process process))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-diagnostics-setup-uses-ssh-context-without-local-fallback ()
  (let* ((transport (pichat-transport--create
                     :id 'remote :kind 'ssh :label "remote"
                     :tramp-prefix "/ssh:setup.invalid:"
                     :pi-executable "/remote/bin/pi"
                     :remote-path '("/remote/bin")))
         (session (pichat-session-make :transport transport :cwd "/tmp/"
                                       :runtime-cwd "/remote/project/"))
         (pichat-pi-extra-env '(("PICHAT_TEST_SETUP_ENV" . "remote")))
         captured buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'make-term)
                   (lambda (name program _startfile &rest args)
                     (push (list default-directory tramp-remote-path program args
                                 (getenv "PICHAT_TEST_SETUP_ENV")) captured)
                     (let ((buffer (generate-new-buffer (format "*%s*" name))))
                       (push buffer buffers)
                       ;; Test only launch context, not SSH connectivity.
                       (with-current-buffer buffer (term-mode))
                       buffer)))
                  ((symbol-function 'term-char-mode) #'ignore)
                  ((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) buffer)))
          (pichat-diagnostics-open-interactive-pi session)
          (should (equal (car captured)
                         '("/ssh:setup.invalid:/remote/project/"
                           ("/remote/bin") "/remote/bin/pi" nil "remote"))))
      (mapc #'kill-buffer buffers))))

(ert-deftest pichat-diagnostics-setup-honors-target-executable-and-explicit-wrapper-policy ()
  (let* ((session (pichat-session-make
                   :transport (pichat-transport--create
                               :id 'local-target :kind 'local
                               :pi-executable "/target/pi")))
         (pichat-rpc-command nil)
         (pichat-pi-executable "/global/pi")
         (pichat-diagnostics-interactive-command nil))
    (should (equal (pichat-chat-diagnostics-interactive-argv session) '("/target/pi")))
    (let ((pichat-rpc-command '("wrapper" "--mode" "rpc")))
      (should-error (pichat-diagnostics-open-interactive-pi session) :type 'user-error)
      (let ((pichat-diagnostics-interactive-command '("wrapper" "interactive")))
        (should (equal (pichat-chat-diagnostics-interactive-argv session)
                       '("wrapper" "interactive")))))))

(ert-deftest pichat-diagnostics-version-probe-is-not-rpc-wrapper-health ()
  (let* ((session (pichat-session-make
                   :transport (pichat-transport--create
                               :id 'version-target :kind 'local :label "version-target"
                               :pi-executable "/target/pi")))
         (pichat-rpc-command '("wrapper" "--mode" "rpc"))
         output sentinel command result)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (transport cwd &rest args)
                     (should (eq transport (pichat-session-transport session)))
                     (should (equal cwd (pichat-session-runtime-cwd session)))
                     (setq output (plist-get args :buffer)
                           sentinel (plist-get args :sentinel)
                           command (plist-get args :command))))
                  ((symbol-function 'pichat-rpc-send)
                   (lambda (&rest _) (ert-fail "Version check issued RPC"))))
          (pichat-diagnostics-probe-pi session)
          (should (equal command '("/target/pi" "--version")))
          (with-current-buffer output (insert "1.4.0\n"))
          (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 0))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq result (apply #'format format-string args)))))
            (funcall sentinel 'fake-process "finished"))
          (should (string-match-p "Pi executable/version on version-target" result))
          (should (string-match-p "not RPC/auth/model health" result))
          (should-not (buffer-live-p output)))
      (when (buffer-live-p output) (kill-buffer output)))))

(ert-deftest pichat-diagnostics-capture-bounds-strings-and-detaches-properties ()
  (let* ((session (pichat-session-make))
         (secret (propertize (concat "token=private " (make-string 1000000 ?界))
                             'display (make-string 1000000 ?x)))
         (record (pichat-chat-diagnostics-record
                  session :origin 'rpc-response :message secret
                  :condition (list 'error secret) :program secret
                  :stderr secret :response (vector secret secret secret))))
    (should-not (string-match-p "private" (plist-get record :summary)))
    (let ((text (plist-get record :message)))
      (should (<= (string-bytes text)
                  (+ pichat-diagnostic-raw-string-limit 30)))
      (should (string-suffix-p "[truncated by PiChat]" text))
      (should-not (text-properties-at 0 text))
      (aset secret 0 ?X)
      (should (string-prefix-p "token=" text)))
    ;; Later values share a byte allowance, not one allowance per field.
    (cl-labels ((bytes (value)
                  (cond
                   ((stringp value)
                    (string-bytes
                     (string-remove-suffix "[truncated by PiChat]" value)))
                   ((consp value) (+ (bytes (car value)) (bytes (cdr value))))
                   ((vectorp value) (apply #'+ (mapcar #'bytes value)))
                   (t 0))))
      (should (<= (apply #'+
                         (mapcar (lambda (key) (bytes (plist-get record key)))
                                 '(:message :condition :program :stderr
                                   :response :command)))
                  pichat-diagnostic-raw-byte-limit)))
    (should (string-match-p "pichat-omitted\\|truncated by PiChat"
                            (prin1-to-string (plist-get record :response))))))

(ert-deftest pichat-diagnostics-capture-handles-deep-wide-vector-and-cyclic-values ()
  (let* ((cycle (list "cycle"))
         (deep "leaf")
         (session (pichat-session-make)))
    (setcdr cycle cycle)
    (dotimes (_ 1000) (setq deep (vector deep)))
    (dolist (value (list cycle deep (make-vector 100000 "v")
                         (make-list 100000 "wide")
                         (make-hash-table :test #'equal)))
      ;; No full serialization/copy-tree is allowed before applying budgets.
      (let* ((record (cl-letf (((symbol-function 'copy-tree)
                               (lambda (&rest _) (error "Unbounded copy")))
                              ((symbol-function 'pp-to-string)
                               (lambda (&rest _) (error "Premature print"))))
                       (pichat-chat-diagnostics-record
                        session :origin 'rpc-dispatch :response value)))
             (raw (plist-get record :response))
             (printed (prin1-to-string raw)))
        (should (< (length printed) 20000))
        (should (string-match-p "pichat-omitted" printed))
        (should (string-match-p "pichat-omitted"
                                (pichat-chat-diagnostics--print-value value)))))))

(ert-deftest pichat-diagnostics-small-raw-values-are-independent-and-unchanged ()
  (let* ((text (copy-sequence "original"))
         (input (list :data (vector (list :text text))))
         (record (pichat-chat-diagnostics-record
                  nil :origin 'rpc-response :response input)))
    (should (equal input (plist-get record :response)))
    (aset text 0 ?X)
    (aset (plist-get input :data) 0 nil)
    (should (equal '(:data [(:text "original")])
                   (plist-get record :response)))))

(ert-deftest pichat-diagnostics-event-capture-does-not-trim-consumer-data ()
  (pichat-test-with-unit-session (session _proc)
    (let* ((text (make-string 1000000 ?x))
           (event (list :type "message_update" :payload (vector text)))
           received)
      (pichat-on 'rpc-event
                 (lambda (_session _kind plist)
                   (setq received (plist-get plist :raw))) session)
      (pichat-rpc--dispatch-public-event session event)
      (should (eq event received))
      (should (= 1000000 (length (aref (plist-get received :payload) 0))))
      (let ((raw (car (pichat-session-event-log session))))
        (should (string-match-p "truncated by PiChat" (prin1-to-string raw)))
        (setcar event :changed)
        (should (equal "message_update" (plist-get raw :type)))))))

(ert-deftest pichat-diagnostics-safety-ceilings-survive-unlimited-count-settings ()
  (pichat-test-with-unit-session (session _proc)
    (let ((pichat-rpc-event-log-limit nil)
          (pichat-diagnostics-record-limit 10000))
      (dotimes (index 520)
        (pichat-rpc--dispatch-public-event
         session (list :type "test_event" :index index)))
      (dotimes (index 25)
        (pichat-chat-diagnostics-record session :origin 'rpc-response
                                        :message (number-to-string index)))
      (should (= pichat-diagnostic-event-slots
                 (length (pichat-session-event-log session))))
      (should (= 519 (plist-get (car (pichat-session-event-log session)) :index)))
      (should (= pichat-diagnostic-record-slots
                 (length (pichat-session-diagnostics session))))
      (should (equal "24" (plist-get (pichat-chat-diagnostics-latest session)
                                    :message))))))

(ert-deftest pichat-diagnostics-evidence-exhaustion-does-not-change-notice-lifetimes ()
  (let* ((session (pichat-session-make))
         (pichat-diagnostics-notice-timeout nil)
         (record (pichat-chat-diagnostics-record
                  session :origin 'rpc-response :command "compact"
                  :message "No model selected."
                  :condition (make-list 100000 "detail")
                  :response (make-vector 100000 "response")))
         (capture (pichat-chat-notices-recovery session nil "compact")))
    (should (eq 'provider-not-configured (plist-get record :category)))
    (should (equal (list record) (plist-get capture :records)))
    (pichat-chat-notices-resolve session capture)
    (should-not (pichat-chat-notices-current session))
    (should (eq record (pichat-chat-diagnostics-latest session)))
    (dolist (epoch '(source process))
      (let ((later (pichat-chat-diagnostics-record
                    session :origin 'rpc-response :message "later")))
        (if (eq epoch 'source)
            (cl-incf (pichat-session-diagnostic-source-generation session))
          (setf (pichat-session-process-generation session) 'replacement))
        (should-not (pichat-chat-notices-current session))
        (should (eq later (pichat-chat-diagnostics-latest session)))))))

(provide 'pichat-test-chat-diagnostics)
;;; pichat-test-chat-diagnostics.el ends here
