;;; pichat-test-ssh.el --- Opt-in real SSH transport test -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-artifact-runner)

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
           (remote-saved (expand-file-name "selected.jsonl" remote-root))
           (runtime-script (expand-file-name "script.json" runtime-root))
           (remote-status (expand-file-name "status.json" remote-root))
           (runtime-status (expand-file-name "status.json" runtime-root))
           (pi (or (getenv "PICHAT_TEST_SSH_PI") "pi"))
           (pichat-default-preset 'standard)
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
           session selected)
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
                              (string-empty-p (string-trim (buffer-string)))))))
              ;; Launch a saved conversation on the same captured SSH target
              ;; after the original writer has stopped.  No fallback to local
              ;; paths or a different target is permitted.
              (with-temp-file remote-saved
                (insert (json-serialize
                         (list :type "session" :version 3
                               :id "pichat-ssh-selected"
                               :timestamp "2026-07-25T16:00:00.000Z"
                               :cwd runtime-project)) "\n"))
              (setq selected
                    (pichat--open-launch-profile
                     (list :scope 'current :target 'pichat-test-ssh
                           :reuse 'new :persistence 'persistent
                           :preset 'standard :model 'default
                           :display-function #'pichat-chat-open
                           :conversation
                           (list :kind 'saved
                                 :selection
                                 (list :file remote-saved :cwd runtime-project
                                       :session-id "pichat-ssh-selected"
                                       :transport (pichat-session-transport session)
                                       :transport-id 'pichat-test-ssh
                                       :source-session session)))
                     remote-project))
              (pichat-test-wait-until
               (lambda () (and (pichat-session-p selected)
                               (equal "pichat-ssh-selected"
                                      (pichat-session-id selected))
                               (pichat-chat-canonical-entry-cache selected)))
               25 "selected SSH session fully synchronized")
              (should (eq 'ssh (pichat-transport-kind
                                (pichat-session-transport selected))))
              (should (equal (file-local-name remote-saved)
                             (pichat-session-session-file selected)))))
        (when (and selected (pichat-session-alive-p selected))
          (ignore-errors (pichat-rpc-stop selected)))
        (when-let* ((buffer (and selected (pichat-session-buffer selected))))
          (when (buffer-live-p buffer)
            (let ((pichat-chat-stop-session-on-kill nil)) (kill-buffer buffer))))
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

(ert-deftest pichat-integration-ssh-reference-creates-readable-remote-temp-file ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (pichat-targets
            `((pichat-test-reference :kind ssh :tramp-prefix ,prefix
                                     :path-mappings ((,base . "/isolated")))))
           (pichat-reference--transport
            (pichat-transport-resolve base 'pichat-test-reference))
           (pichat-reference--path-context
            (pichat-transport-path-context pichat-reference--transport))
           (pichat-reference-temp-directory nil)
           (temporary-file-directory "/tmp/")
           file)
      (unwind-protect
          (let ((text (pichat-reference--write-temp-reference
                       "ssh test" "remote reference content")))
            (should (string-match "- `\\([^`]+\\)`" text))
            (setq file (match-string 1 text))
            (should (string-prefix-p "/tmp/pichat-reference-" file))
            (with-temp-buffer
              (insert-file-contents (concat prefix file))
              (should (equal (buffer-string) "remote reference content"))))
        (when file (ignore-errors (delete-file (concat prefix file))))))))

(ert-deftest pichat-integration-ssh-runner-executes-on-pi-host-and-publishes-output ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (project (expand-file-name
                     (format "pichat-runner-test-%d-%06x/"
                             (emacs-pid) (random #xFFFFFF)) base))
           (runtime-cwd (file-local-name project))
           (transport (pichat-transport--create
                       :id 'runner-test :kind 'ssh :label "runner-test"
                       :tramp-prefix prefix
                       :remote-path '(tramp-own-remote-path)))
           (session (pichat-session-make :transport transport
                                         :cwd "/mounted/project/"
                                         :runtime-cwd runtime-cwd))
           (pichat-artifact-runner-output-limit 4)
           (chat (generate-new-buffer " *pichat-ssh-runner-chat*"))
           view output script)
      (unwind-protect
          (progn
            (make-directory project t)
            (with-current-buffer chat
              (pichat-chat-mode)
              (setq-local pichat-chat-session session)
              ;; A locally mounted origin still runs in the remote cwd.
              (setq view (pichat-artifact-runner-run
                          "printf 'abcdef'; pwd; exit 7\n" "sh"
                          "/mounted/project/" session)))
            (with-current-buffer view (setq script pichat-artifact-runner--file))
            (pichat-test-wait-until
             (lambda () (with-current-buffer view
                          (not (memq pichat-artifact-runner--status
                                     '(running publishing)))))
             20 "remote code run and output publication")
            (with-current-buffer view
              (setq output pichat-artifact-runner--output-file)
              (should (equal 'exit pichat-artifact-runner--status))
              (should (= 7 pichat-artifact-runner--exit))
              (should (equal runtime-cwd pichat-artifact-runner--directory))
              (should (string-prefix-p "/tmp/pichat-output-" output))
              (should (string-match-p (regexp-quote output)
                                      (pichat-artifact-runner--report))))
            (should-not (file-exists-p script))
            (should (= #o600 (file-modes (concat prefix output))))
            (with-temp-buffer
              (insert-file-contents (concat prefix output))
              (should (equal (buffer-string)
                             (format "abcdef%s\n" (directory-file-name runtime-cwd))))))
        (when (buffer-live-p view) (kill-buffer view))
        (when output (ignore-errors (delete-file (concat prefix output))))
        (when (buffer-live-p chat) (kill-buffer chat))
        (ignore-errors (delete-directory project t))))))

(ert-deftest pichat-integration-ssh-runner-share-truncation-publishes-remote-file ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (project (expand-file-name
                     (format "pichat-runner-share-%d-%06x/"
                             (emacs-pid) (random #xFFFFFF)) base))
           (transport (pichat-transport--create
                       :id 'runner-test :kind 'ssh :label "runner-test"
                       :tramp-prefix prefix
                       :remote-path '(tramp-own-remote-path)))
           (session (pichat-session-make :transport transport
                                         :cwd "/mounted/project/"
                                         :runtime-cwd (file-local-name project)))
           (pichat-artifact-result-share-limit 4000)
           (pichat-artifact-runner-output-limit 65536)
           (chat (generate-new-buffer " *pichat-ssh-share-chat*"))
           view output script)
      (unwind-protect
          (progn
            (make-directory project t)
            (with-current-buffer chat
              (pichat-chat-mode)
              (setq-local pichat-chat-session session)
              (pichat-chat--set-input-text "draft")
              (setq view (pichat-artifact-runner-run
                          "printf '%010000d' 0; exit 7\n" "sh"
                          "/mounted/project/" session)))
            (with-current-buffer view (setq script pichat-artifact-runner--file))
            (pichat-test-wait-until
             (lambda () (with-current-buffer view
                          (not (memq pichat-artifact-runner--status
                                     '(running publishing)))))
             20 "remote share-only spill and publication")
            (with-current-buffer view
              (setq output pichat-artifact-runner--output-file)
              (should (string-prefix-p "/tmp/pichat-output-" output))
              (should (eq 'exit pichat-artifact-runner--status))
              (should (= 7 pichat-artifact-runner--exit))
              (should (= 10000 (length pichat-artifact-runner--captured-output)))
              (should-not pichat-artifact-runner--preview-truncated)
              (should (string-match-p (regexp-quote output)
                                      (pichat-artifact-runner--report)))
              (pichat-artifact-result-share))
            (should-not (buffer-live-p view))
            (should-not (file-exists-p script))
            (should (= #o600 (file-modes (concat prefix output))))
            (with-current-buffer chat
              (should (string-match-p (regexp-quote output)
                                      (pichat-chat--input-text)))
              (should (string-match-p "Ran with sh — exit 7" (pichat-chat--input-text)))
              (should (string-match-p "```\n0000"
                                      (pichat-chat--input-text))))
            (with-temp-buffer
              (insert-file-contents (concat prefix output))
              (should (equal (buffer-string) (make-string 10000 ?0)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when output (ignore-errors (delete-file (concat prefix output))))
        (when (buffer-live-p chat) (kill-buffer chat))
        (ignore-errors (delete-directory project t))))))

(ert-deftest pichat-integration-ssh-runner-python-uses-remote-interpreter ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (project (expand-file-name
                     (format "pichat-runner-python-%d-%06x/"
                             (emacs-pid) (random #xFFFFFF)) base))
           (transport (pichat-transport--create
                       :id 'runner-test :kind 'ssh :label "runner-test"
                       :tramp-prefix prefix
                       :remote-path '(tramp-own-remote-path)))
           (session (pichat-session-make :transport transport
                                         :cwd project
                                         :runtime-cwd (file-local-name project)))
           (chat (generate-new-buffer " *pichat-ssh-python-chat*"))
           view)
      (unwind-protect
          (progn
            (let ((default-directory base))
              (unless (executable-find "python3" t)
                (ert-skip "SSH test host has no python3 interpreter")))
            (make-directory project t)
            (with-current-buffer chat
              (pichat-chat-mode)
              (setq-local pichat-chat-session session)
              (setq view (pichat-artifact-runner-run
                          "import os\nprint(os.getcwd())\n" "python"
                          project session)))
            (pichat-test-wait-until
             (lambda () (with-current-buffer view
                          (not (memq pichat-artifact-runner--status
                                     '(running publishing)))))
             20 "remote Python run")
            (with-current-buffer view
              (should (eq 'exit pichat-artifact-runner--status))
              (should (= 0 pichat-artifact-runner--exit))
              (should (equal (concat (directory-file-name
                                      (file-local-name project)) "\n")
                             pichat-artifact-runner--captured-output))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))
        (ignore-errors (delete-directory project t))))))

(ert-deftest pichat-integration-ssh-runner-timeout-kills-remote-process ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (project (expand-file-name
                     (format "pichat-runner-timeout-%d-%06x/"
                             (emacs-pid) (random #xFFFFFF)) base))
           (pid-file (expand-file-name "runner.pid" project))
           (transport (pichat-transport--create
                       :id 'runner-test :kind 'ssh :label "runner-test"
                       :tramp-prefix prefix
                       :remote-path '(tramp-own-remote-path)))
           (session (pichat-session-make :transport transport
                                         :cwd project
                                         :runtime-cwd (file-local-name project)))
           (pichat-artifact-runner-output-limit 2)
           (chat (generate-new-buffer " *pichat-ssh-timeout-chat*"))
           view output script pid)
      (unwind-protect
          (progn
            (make-directory project t)
            (with-current-buffer chat
              (pichat-chat-mode)
              (setq-local pichat-chat-session session)
              (setq view (pichat-artifact-runner-run
                          (format "printf 'initial'; echo $$ > %s; exec sleep 30\n"
                                  (shell-quote-argument (file-local-name pid-file)))
                          "sh" project session)))
            (with-current-buffer view (setq script pichat-artifact-runner--file))
            (pichat-test-wait-until
             (lambda ()
               (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents pid-file)
                   (let ((text (string-trim (buffer-string))))
                     (when (string-match-p "\\`[0-9]+\\'" text)
                       (setq pid text))))))
             10 "remote child PID")
            (pichat-test-wait-until
             (lambda () (with-current-buffer view
                          (and pichat-artifact-runner--staging
                               (> pichat-artifact-runner--output-bytes 0))))
             10 "streamed remote output before timeout")
            (with-current-buffer view
              (pichat-artifact-runner--timeout pichat-artifact-runner--process))
            (pichat-test-wait-until
             (lambda () (with-current-buffer view
                          (not (memq pichat-artifact-runner--status
                                     '(running publishing)))))
             20 "remote timeout and output publication")
            (with-current-buffer view
              (should (eq 'timeout pichat-artifact-runner--status))
              (setq output pichat-artifact-runner--output-file)
              (should (string-prefix-p "/tmp/pichat-output-" output)))
            (should-not (file-exists-p script))
            (pichat-test-wait-until
             (lambda ()
               (let ((default-directory project))
                 (not (zerop (process-file "sh" nil nil nil "-c"
                                           (format "kill -0 %s 2>/dev/null" pid))))))
             10 "remote interpreter termination after timeout"))
        (when (buffer-live-p view) (kill-buffer view))
        (when output (ignore-errors (delete-file (concat prefix output))))
        (when (buffer-live-p chat) (kill-buffer chat))
        (ignore-errors (delete-directory project t))))))

(ert-deftest pichat-integration-ssh-runner-quit-kills-remote-child ()
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a TRAMP directory"))
    (let* ((prefix (file-remote-p base))
           (project (expand-file-name
                     (format "pichat-runner-quit-%d-%06x/"
                             (emacs-pid) (random #xFFFFFF)) base))
           (pid-file (expand-file-name "child.pid" project))
           (transport (pichat-transport--create
                       :id 'runner-test :kind 'ssh :label "runner-test"
                       :tramp-prefix prefix
                       :remote-path '(tramp-own-remote-path)))
           (session (pichat-session-make :transport transport
                                         :cwd project
                                         :runtime-cwd (file-local-name project)))
           (chat (generate-new-buffer " *pichat-ssh-quit-chat*"))
           view script pid)
      (unwind-protect
          (progn
            (make-directory project t)
            (with-current-buffer chat
              (pichat-chat-mode)
              (setq-local pichat-chat-session session)
              (setq view (pichat-artifact-runner-run
                          (format "sleep 30 & child=$!; echo $child > %s; wait $child\n"
                                  (shell-quote-argument (file-local-name pid-file)))
                          "sh" project session)))
            (with-current-buffer view (setq script pichat-artifact-runner--file))
            (pichat-test-wait-until
             (lambda ()
               (ignore-errors
                 (with-temp-buffer
                   (insert-file-contents pid-file)
                   (let ((text (string-trim (buffer-string))))
                     (when (string-match-p "\\`[0-9]+\\'" text)
                       (setq pid text))))))
             10 "remote child PID before quit")
            (kill-buffer view)
            (should-not (file-exists-p script))
            (pichat-test-wait-until
             (lambda ()
               (let ((default-directory project))
                 (not (zerop (process-file "sh" nil nil nil "-c"
                                           (format "kill -0 %s 2>/dev/null" pid))))))
             10 "remote child termination after quit"))
        (when (buffer-live-p view) (kill-buffer view))
        (when pid
          (ignore-errors
            (let ((default-directory project))
              (process-file "sh" nil nil nil "-c"
                            (format "kill %s 2>/dev/null" pid)))))
        (when (buffer-live-p chat) (kill-buffer chat))
        (ignore-errors (delete-directory project t))))))

(provide 'pichat-test-ssh)
;;; pichat-test-ssh.el ends here
