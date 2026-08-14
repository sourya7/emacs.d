;;; pichat-test-sessions-integration.el --- Real-Pi history integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused Phase 11 coverage for persisted branches and rebind compatibility.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-sessions-integration--user (id parent text timestamp)
  "Return a persisted user entry with ID, PARENT, TEXT, and TIMESTAMP."
  (list :type "message" :id id :parentId parent :timestamp timestamp
        :message (list :role "user"
                       :content (vector (list :type "text" :text text))
                       :timestamp 1760000000000)))

(defun pichat-test-sessions-integration--assistant (id parent text timestamp)
  "Return a persisted assistant entry with ID, PARENT, TEXT, and TIMESTAMP."
  (list :type "message" :id id :parentId parent :timestamp timestamp
        :message
        (list :role "assistant"
              :content (vector (list :type "text" :text text))
              :api "pichat-fake-api"
              :provider "pichat-fake"
              :model "pichat-fake"
              :usage (list :input 1 :output 1 :cacheRead 0 :cacheWrite 0
                           :totalTokens 2
                           :cost (list :input 0 :output 0 :cacheRead 0
                                       :cacheWrite 0 :total 0))
              :stopReason "stop"
              :timestamp 1760000000001)))

(defun pichat-test-sessions-integration--write-fixture
    (file project-dir &optional session-id)
  "Write a valid branched Pi session to FILE for PROJECT-DIR.
SESSION-ID defaults to a stable Phase 11 fixture identity."
  (let* ((session-id (or session-id "pichat-phase11-fixture"))
         (entries
          (list
           (list :type "session" :version 3 :id session-id
                 :timestamp "2026-07-25T16:00:00.000Z" :cwd project-dir)
           (pichat-test-sessions-integration--user
            "phase11-root-user" nil "Phase 11 root prompt"
            "2026-07-25T16:00:01.000Z")
           (pichat-test-sessions-integration--assistant
            "phase11-root-assistant" "phase11-root-user"
            "Phase 11 root answer" "2026-07-25T16:00:02.000Z")
           (pichat-test-sessions-integration--user
            "phase11-abandoned-user" "phase11-root-assistant"
            "Phase 11 abandoned prompt" "2026-07-25T16:00:03.000Z")
           (pichat-test-sessions-integration--assistant
            "phase11-abandoned-assistant" "phase11-abandoned-user"
            "Phase 11 abandoned answer" "2026-07-25T16:00:04.000Z")
           (list :type "label" :id "phase11-label"
                 :parentId "phase11-abandoned-assistant"
                 :timestamp "2026-07-25T16:00:05.000Z"
                 :targetId "phase11-abandoned-user"
                 :label "abandoned-label")
           (pichat-test-sessions-integration--user
            "phase11-active-user" "phase11-root-assistant"
            "Phase 11 active prompt" "2026-07-25T16:00:06.000Z")
           (pichat-test-sessions-integration--assistant
            "phase11-active-assistant" "phase11-active-user"
            "Phase 11 active answer" "2026-07-25T16:00:07.000Z"))))
    (with-temp-file file
      (dolist (entry entries)
        (insert (json-serialize entry
                                :false-object :json-false
                                :null-object nil)
                "\n")))
    file))

(defun pichat-test-sessions-integration--kill-buffers ()
  "Kill shared history/preview/detail buffers left by an integration test."
  (dolist (name '("*PiChat Session History*"
                  "*PiChat Branch Preview*"
                  "*PiChat Session Entry*"))
    (when-let ((buffer (get-buffer name)))
      (kill-buffer buffer))))

(defun pichat-test-sessions-integration--wait-for-chat-source
    (buffer file needle)
  "Wait until BUFFER owns FILE, is synchronized, and displays NEEDLE."
  (pichat-test-wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (equal file pichat-chat--source-session-file)
                 (not pichat-chat--sync-in-flight)
                 (string-match-p (regexp-quote needle)
                                 (pichat-test-buffer-text buffer))))))
   5
   (format "chat source %s containing %s" file needle)))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-history-forks-abandoned-branch-and-navigates-sources ()
    (pichat-test-with-integration-session
        (session :script '(:turns []))
      (let* ((fixture-file
              (expand-file-name "pichat-phase11-branched.jsonl" session-dir))
             (pichat-chat-render-markdown nil)
             (pichat-chat-stop-session-on-kill nil)
             chat-buffer history-buffer original-id original-file fork-id fork-file)
        (pichat-test-sessions-integration--write-fixture
         fixture-file project-dir)
        (unwind-protect
            (progn
              (pichat-test-rpc-call
               session "switch_session" (list :sessionPath fixture-file))
              (pichat-test-rpc-call session "get_state")
              (setq original-id (pichat-session-id session)
                    original-file (pichat-session-session-file session)
                    chat-buffer (pichat-chat-open session t))
              (pichat-test-sessions-integration--wait-for-chat-source
               chat-buffer original-file "Phase 11 active answer")

              ;; Open and inspect the tree through the public history command.
              (pichat-sessions-list session)
              (setq history-buffer (get-buffer "*PiChat Session History*"))
              (pichat-test-wait-until
               (lambda ()
                 (and (buffer-live-p history-buffer)
                      (with-current-buffer history-buffer
                        (member "phase11-abandoned-user"
                                pichat-sessions--visible-rows))))
               5 "branched fixture in Session History")
              (with-current-buffer history-buffer
                (let ((text (pichat-test-buffer-text history-buffer)))
                  (should (string-match-p "[├└]─" text))
                  (should (string-match-p "•" text))
                  (should (string-match-p "\\[abandoned-label\\]" text))
                  (should (string-match-p "Phase 11 abandoned prompt" text)))
                (pichat-sessions--goto-id "phase11-abandoned-user")
                (call-interactively #'pichat-sessions-fork-at-point))

              ;; Pi 0.80.6 accepts the abandoned user ID and restores its text.
              (pichat-test-wait-until
               (lambda ()
                 (let ((file (pichat-session-session-file session)))
                   (and (stringp file) (not (equal file original-file)))))
               5 "forked session identity")
              (setq fork-id (pichat-session-id session)
                    fork-file (pichat-session-session-file session))
              (should-not (equal original-id fork-id))
              (should (file-exists-p fork-file))
              (should (equal (list original-file)
                             (pichat-session-session-file-back-stack session)))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer chat-buffer
                   (equal "Phase 11 abandoned prompt"
                          (pichat-chat--input-text))))
               5 "fork text restored to the PiChat prompt")
              (pichat-test-sessions-integration--wait-for-chat-source
               chat-buffer fork-file "Phase 11 root answer")
              (with-current-buffer chat-buffer
                (let ((text (pichat-test-buffer-text chat-buffer)))
                  (should (string-match-p "Phase 11 root prompt" text))
                  (should-not (string-match-p "Phase 11 active prompt" text))))

              ;; Public back/forward commands preserve exact persisted identities.
              (call-interactively #'pichat-sessions-return-to-origin)
              (pichat-test-wait-until
               (lambda ()
                 (equal original-file (pichat-session-session-file session)))
               5 "return to original source")
              (pichat-test-sessions-integration--wait-for-chat-source
               chat-buffer original-file "Phase 11 active answer")
              (should (equal (list fork-file)
                             (pichat-session-session-file-forward-stack session)))
              (call-interactively #'pichat-sessions-forward-to-fork)
              (pichat-test-wait-until
               (lambda ()
                 (equal fork-file (pichat-session-session-file session)))
               5 "move forward to fork source")
              (pichat-test-sessions-integration--wait-for-chat-source
               chat-buffer fork-file "Phase 11 root answer")
              (should (equal fork-id (pichat-session-id session))))
          (pichat-test-sessions-integration--kill-buffers)
          (when (buffer-live-p chat-buffer) (kill-buffer chat-buffer))))))

  (ert-deftest pichat-integration-history-rebind-cancellation-preserves-ui-and-stacks ()
    (pichat-test-with-integration-session
        (session :script '(:turns [])
                 :extensions (list pichat-test-session-cancellation-extension))
      (let* ((fixture-file
              (expand-file-name "pichat-phase11-cancel-source.jsonl" session-dir))
             (cancel-target
              (expand-file-name "pichat-cancel-target.jsonl" session-dir))
             (pichat-chat-render-markdown nil)
             (pichat-chat-stop-session-on-kill nil)
             chat-buffer history-buffer messages rebind-handler
             (rebinds 0))
        (pichat-test-sessions-integration--write-fixture
         fixture-file project-dir "pichat-phase11-cancel-source")
        (pichat-test-sessions-integration--write-fixture
         cancel-target project-dir "pichat-phase11-cancel-target")
        (unwind-protect
            (progn
              (pichat-test-rpc-call
               session "switch_session" (list :sessionPath fixture-file))
              (pichat-test-rpc-call session "get_state")
              (setq chat-buffer (pichat-chat-open session t))
              (pichat-test-sessions-integration--wait-for-chat-source
               chat-buffer fixture-file "Phase 11 active answer")
              (with-current-buffer chat-buffer
                (goto-char (point-max))
                (insert "keep cancellation draft"))
              (pichat-sessions-list session)
              (setq history-buffer (get-buffer "*PiChat Session History*"))
              (pichat-test-wait-until
               (lambda ()
                 (and (buffer-live-p history-buffer)
                      (with-current-buffer history-buffer
                        (member "phase11-abandoned-user"
                                pichat-sessions--visible-rows))))
               5 "cancellation fixture history")
              (setf (pichat-session-session-file-back-stack session)
                    (list cancel-target)
                    (pichat-session-session-file-forward-stack session)
                    '("forward-sentinel"))
              (setq rebind-handler
                    (lambda (&rest _args) (cl-incf rebinds)))
              (pichat-on 'session-rebinding rebind-handler session)
              (cl-letf (((symbol-function 'message)
                         (lambda (&rest args) (push (apply #'format args) messages))))
                (with-current-buffer history-buffer
                  (pichat-sessions--goto-id "phase11-abandoned-user")
                  (call-interactively #'pichat-sessions-fork-at-point))
                (pichat-test-wait-until
                 (lambda ()
                   (cl-find-if (lambda (text)
                                 (string-match-p "fork cancelled" text))
                               messages))
                 5 "fork cancellation result")
                (call-interactively #'pichat-sessions-return-to-origin)
                (pichat-test-wait-until
                 (lambda ()
                   (cl-find-if (lambda (text)
                                 (string-match-p "navigation cancelled" text))
                               messages))
                 5 "switch cancellation result"))
              (should (= 0 rebinds))
              (should (equal fixture-file
                             (pichat-session-session-file session)))
              (should (equal (list cancel-target)
                             (pichat-session-session-file-back-stack session)))
              (should (equal '("forward-sentinel")
                             (pichat-session-session-file-forward-stack session)))
              (with-current-buffer chat-buffer
                (should (equal "keep cancellation draft"
                               (pichat-chat--input-text))))
              (should-not
               (cl-find-if
                (lambda (text)
                  (or (string-match-p "Forked from" text)
                      (string-match-p "moved back" text)))
                messages)))
          (when rebind-handler
            (pichat-off 'session-rebinding rebind-handler session))
          (pichat-test-sessions-integration--kill-buffers)
          (when (buffer-live-p chat-buffer) (kill-buffer chat-buffer)))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-independent-open-restores-saved-transcript ()
    (pichat-test-require-pi)
    (pichat-test-with-clean-state
      (pichat-test-with-temp-dir project-dir
        (pichat-test-with-temp-dir agent-dir
          (pichat-test-with-temp-dir session-dir
            (let* ((script (expand-file-name "script.json" project-dir))
                   (status (expand-file-name "status.json" project-dir))
                   (file (expand-file-name "independent-saved.jsonl" session-dir))
                   (pichat-rpc-command
                    (list pichat-test-pi-executable "--mode" "rpc" "--offline"
                          "--no-approve" "--no-builtin-tools"
                          "--no-context-files" "--no-skills"
                          "--no-prompt-templates" "--no-themes"
                          "--no-extensions" "--session-dir" session-dir
                          "-e" pichat-test-fake-provider-extension
                          "--model" "pichat-fake/pichat-fake"))
                   (pichat-chat-render-markdown nil)
                   (pichat-chat-stop-session-on-kill nil)
                   session ready chat-buffer)
              (with-temp-file script (insert "{\"turns\":[]}"))
              (pichat-test-sessions-integration--write-fixture
               file project-dir "independent-saved")
              (unwind-protect
                  (let ((default-directory project-dir)
                        (process-environment
                         (append
                          (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1"
                                "PI_TELEMETRY=0"
                                (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script)
                                (concat "PICHAT_FAKE_PROVIDER_STATUS=" status))
                          process-environment)))
                    (setq session
                          (pichat-sessions-open-file-independently
                           file :cwd project-dir :owner-directory project-dir
                           :display-function #'pichat-chat-open
                           :ready (lambda (s) (setq ready s))))
                    (pichat-test-wait-until
                     (lambda () ready) 5 "independent saved session ready")
                    (should (eq session ready))
                    (setq chat-buffer (pichat-session-buffer session))
                    (pichat-test-sessions-integration--wait-for-chat-source
                     chat-buffer file "Phase 11 active answer"))
                (when (buffer-live-p chat-buffer) (kill-buffer chat-buffer))
                (when session
                  (ignore-errors (pichat-stop-session session))
                  (ignore-errors (pichat-forget-session session))
                  (when-let ((process (pichat-session-process session)))
                    (when (process-live-p process) (delete-process process))
                    (when-let ((buffer (process-buffer process)))
                      (when (buffer-live-p buffer) (kill-buffer buffer))))))))))))

  (ert-deftest pichat-integration-independent-runtimes-isolate-switch-and-stop ()
    (pichat-test-require-pi)
    (pichat-test-with-clean-state
      (pichat-test-with-temp-dir project-one
        (pichat-test-with-temp-dir project-two
          (pichat-test-with-temp-dir agent-dir
            (pichat-test-with-temp-dir session-dir
              (let* ((script-one (expand-file-name "script-one.json" project-one))
                     (script-two (expand-file-name "script-two.json" project-two))
                     (status-one (expand-file-name "status-one.json" project-one))
                     (status-two (expand-file-name "status-two.json" project-two))
                     (file-one (expand-file-name "independent-one.jsonl" session-dir))
                     (file-two (expand-file-name "independent-two.jsonl" session-dir))
                     (pichat-rpc-command
                      (list pichat-test-pi-executable "--mode" "rpc" "--offline"
                            "--no-approve" "--no-builtin-tools"
                            "--no-context-files" "--no-skills"
                            "--no-prompt-templates" "--no-themes"
                            "--no-extensions" "--session-dir" session-dir
                            "-e" pichat-test-fake-provider-extension
                            "--model" "pichat-fake/pichat-fake"))
                     first second)
                (with-temp-file script-one (insert "{\"turns\":[]}"))
                (with-temp-file script-two (insert "{\"turns\":[]}"))
                (pichat-test-sessions-integration--write-fixture
                 file-one project-one "independent-one")
                (pichat-test-sessions-integration--write-fixture
                 file-two project-two "independent-two")
                (unwind-protect
                    (progn
                      (let ((default-directory project-one)
                            (process-environment
                             (append
                              (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1"
                                    "PI_TELEMETRY=0"
                                    (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                    (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                    (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-one)
                                    (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-one))
                              process-environment)))
                        (setq first (pichat-start-session project-one)))
                      (let ((default-directory project-two)
                            (process-environment
                             (append
                              (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1"
                                    "PI_TELEMETRY=0"
                                    (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                    (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                    (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-two)
                                    (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-two))
                              process-environment)))
                        (setq second (pichat-start-session project-two)))
                      (pichat-test-rpc-call first "get_state")
                      (pichat-test-rpc-call second "get_state")
                      (pichat-test-rpc-call
                       first "switch_session" (list :sessionPath file-one))
                      (pichat-test-rpc-call
                       second "switch_session" (list :sessionPath file-two))
                      (pichat-test-rpc-call first "get_state")
                      (pichat-test-rpc-call second "get_state")
                      (should (equal "independent-one"
                                     (pichat-session-id first)))
                      (should (equal "independent-two"
                                     (pichat-session-id second)))
                      (should (= 2 (length (pichat-session-list))))
                      (pichat-stop-session first)
                      (should (pichat-session-alive-p second))
                      (should (plist-get
                               (pichat-test-rpc-call second "get_state")
                               :success))
                      (pichat-forget-session first)
                      (should (eq second
                                  (pichat-session-by-runtime-id
                                   (pichat-session-runtime-id second)))))
                  (dolist (session (list first second))
                    (when session
                      (ignore-errors (pichat-stop-session session))
                      (ignore-errors (pichat-forget-session session))
                      (when-let ((process (pichat-session-process session)))
                        (when (process-live-p process) (delete-process process))
                        (when-let ((buffer (process-buffer process)))
                          (when (buffer-live-p buffer) (kill-buffer buffer)))))))))))))))

(provide 'pichat-test-sessions-integration)
;;; pichat-test-sessions-integration.el ends here
