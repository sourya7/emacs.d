;;; pichat-test-ssh.el --- Opt-in real SSH transport test -*- lexical-binding: t; -*-

(require 'pichat-test-support)

(ert-deftest pichat-integration-ssh-rpc-streams-and-stops-cleanly ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((base (file-name-as-directory base))
           (remote-root
            (file-name-as-directory
             (expand-file-name
              (format "pichat-ssh-test-%d-%06x"
                      (emacs-pid) (random #xFFFFFF))
              base)))
           (prefix (file-remote-p remote-root))
           (runtime-root (file-local-name remote-root))
           (remote-project (expand-file-name "project/" remote-root))
           (runtime-project (expand-file-name "project/" runtime-root))
           (remote-agent (expand-file-name "agent/" remote-root))
           (runtime-agent (expand-file-name "agent/" runtime-root))
           (runtime-sessions (expand-file-name "sessions/" runtime-root))
           (remote-extension (expand-file-name "fake-provider.ts" remote-root))
           (runtime-extension (expand-file-name "fake-provider.ts" runtime-root))
           (remote-script (expand-file-name "script.json" remote-root))
           (runtime-script (expand-file-name "script.json" runtime-root))
           (remote-status (expand-file-name "status.json" remote-root))
           (runtime-status (expand-file-name "status.json" runtime-root))
           (pi (or (getenv "PICHAT_TEST_SSH_PI") "pi"))
           (pichat-targets
            `((pichat-test-ssh
               :kind ssh :tramp-prefix ,prefix :pi-executable ,pi
               :runtime-home ,runtime-root
               :path-mappings ((,remote-root . ,runtime-root))
               :pi-args
               ("--offline" "--no-approve" "--no-builtin-tools"
                "--no-context-files" "--no-skills" "--no-prompt-templates"
                "--no-themes" "--no-extensions"
                "-e" ,runtime-extension
                "--model" "pichat-fake/pichat-fake"))))
           (process-environment
            (append
             (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1" "PI_TELEMETRY=0"
                   (concat "PI_CODING_AGENT_DIR=" runtime-agent)
                   (concat "PI_CODING_AGENT_SESSION_DIR=" runtime-sessions)
                   (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" runtime-script)
                   (concat "PICHAT_FAKE_PROVIDER_STATUS=" runtime-status))
             process-environment))
           session)
      (unwind-protect
          (progn
            (make-directory remote-project t)
            (make-directory remote-agent t)
            (copy-file pichat-test-fake-provider-extension remote-extension t)
            (with-temp-file remote-script
              (insert (json-serialize
                       '(:turns [(:text ["ssh " "stream ok"])])
                       :false-object :json-false :null-object nil)))
            (let ((default-directory remote-project))
              (setq session
                    (pichat-start-session
                     remote-project nil
                     '(:persistence ephemeral :target pichat-test-ssh)))
              (should (pichat-session-alive-p session))
              (let ((state (pichat-test-rpc-call session "get_state" nil 20)))
                (should-not (plist-get (plist-get state :data) :sessionFile))
                (should (equal runtime-project
                               (pichat-session-runtime-cwd session))))
              (pichat-test-prompt-and-wait session "SSH transport test" 30)
              (let* ((response
                      (pichat-test-rpc-call session "get_entries" nil 15))
                     (text (prin1-to-string (plist-get response :data))))
                (should (string-match-p "stream ok" text)))
              (pichat-test-assert-provider-script-consumed remote-status)
              (pichat-rpc-stop session)
              (pichat-test-wait-until
               (lambda () (not (pichat-session-alive-p session)))
               10 "remote Pi process stop")
              (with-temp-buffer
                (let ((status
                       (process-file
                        "pgrep" nil t nil "-af"
                        (concat "[p]" (substring
                                      (file-name-nondirectory
                                       (directory-file-name runtime-root))
                                      1)))))
                  (should (or (= status 1)
                              (string-empty-p (string-trim (buffer-string)))))))))
        (when (and session (pichat-session-alive-p session))
          (ignore-errors (pichat-rpc-stop session)))
        (ignore-errors (delete-directory remote-root t))))))

(ert-deftest pichat-integration-ssh-consult-archive-process-streams-remotely ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((base (file-name-as-directory base))
           (remote-root
            (file-name-as-directory
             (expand-file-name
              (format "pichat-ssh-archive-test-%d-%06x"
                      (emacs-pid) (random #xFFFFFF))
              base)))
           (prefix (file-remote-p remote-root))
           (runtime-root (file-local-name remote-root))
           (remote-helper (expand-file-name "archive-helper.mjs" remote-root))
           (runtime-helper (expand-file-name "archive-helper.mjs" runtime-root))
           (pichat-targets
            `((pichat-test-ssh-archive
               :kind ssh :tramp-prefix ,prefix
               :runtime-home ,runtime-root
               :remote-path (tramp-own-remote-path)
               :path-mappings ((,remote-root . ,runtime-root)))))
           (transport
            (pichat-transport-resolve remote-root 'pichat-test-ssh-archive))
           (capability (list :transport transport :runtime-cwd runtime-root))
           events stage)
      (unwind-protect
          (progn
            (make-directory remote-root t)
            (with-temp-file remote-helper
              (insert "console.log(JSON.stringify({sessionId:'remote-consult'}));\n"))
            (setq stage
                  (funcall
                   (pichat-consult--async-archive-process
                    (lambda (_input) (list "node" runtime-helper)) capability)
                   (lambda (action) (push action events))))
            (with-temp-buffer (funcall stage 'setup))
            (funcall stage "query")
            (pichat-test-wait-until
             (lambda ()
               (cl-find-if
                (lambda (event)
                  (and (vectorp event) (eq (aref event 1) 'finished)))
                events))
             15 "remote Consult archive helper")
            (should
             (cl-find-if
              (lambda (event)
                (and (listp event)
                     (cl-some
                      (lambda (line)
                        (and (stringp line)
                             (string-match-p "remote-consult" line)))
                      event)))
              events)))
        (when stage (ignore-errors (funcall stage 'destroy)))
        (ignore-errors (delete-directory remote-root t))))))

(provide 'pichat-test-ssh)
;;; pichat-test-ssh.el ends here
