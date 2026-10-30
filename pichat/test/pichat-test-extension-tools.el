;;; pichat-test-extension-tools.el --- Discovery-backed configuration -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-tool-picker)
(require 'pichat-tool-runtime)
(require 'pichat-reconfigure)

(defconst pichat-test-extension-tools-fixture
  (expand-file-name "fixtures/tool-control-extension.ts" pichat-test-directory))

(ert-deftest pichat-extension-tools-presets-are-explicit-and-pass-through-is-unchanged ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'custom :tools '("read") :extensions '("child"))
    (should (equal '("--tools" "read,child" "--no-mcp")
                   (pichat-tool-selection-args (pichat-tool-selection-resolve (pichat-presets-resolve 'custom)))))
    (dolist (names '(("read") ("powershell") ("child" "child") ("wild*") ("comma,name") ("")))
      (should-error (pichat-make-preset 'bad :tools nil :extensions names) :type 'user-error))
    (should-error (pichat-make-preset 'bad :extensions '("child")) :type 'user-error)
    (should-error (pichat-make-preset 'bad :tools :default :extensions '("child")) :type 'user-error)
    (should-not (plist-get (pichat-tool-selection-resolve (pichat-presets-resolve 'manual)) :extensions))
    (should-not (pichat-tool-selection-args (pichat-tool-selection-resolve (pichat-presets-resolve 'standard))))))

(ert-deftest pichat-extension-tools-selections-preserve-boundaries-and-effective-identity ()
  (let* ((before (list :preset-spec (pichat-presets-resolve 'manual)
                       :tool-selection '(:builtins ("read") :mcp nil :extensions ("child"))))
         (after (pichat-reconfigure-select-tools before '(:builtins ("read") :extensions ("other")))))
    (should (pichat-reconfigure-effective-change-p before after))
    (should (equal '("child") (plist-get (plist-get before :tool-selection) :extensions)))
    (should (equal '("--tools" "read,other" "--no-mcp")
                   (pichat-tool-selection-args (plist-get after :tool-selection))))
    (should-error (pichat-reconfigure-select-tools before '(:builtins ("bash") :extensions ("child"))))
    (should-error (pichat-tool-selection-resolve
                   (pichat-presets-resolve 'standard) '(:extensions ("child"))))
    (should-error (pichat-reconfigure-select-tools
                   before '(:builtins nil :mcp (("s" . "t")) :extensions ("mcp__s__t")))))
  (let* ((spec (pichat-presets-resolve 'manual))
         (a (list :preset-spec spec :tool-selection '(:builtins nil :extensions ("b" "a"))))
         (b (list :preset-spec spec :tool-selection '(:builtins nil :extensions ("a" "b")))))
    (should-not (pichat-reconfigure-effective-change-p a b))))

(ert-deftest pichat-extension-tools-picker-checks-descriptions-eligibility-reset-and-cancel ()
  (let* ((spec (append (list :extensions '("child")) (pichat-presets-resolve 'manual)))
         (cache (pichat-tool-discovery-draft-create
                 :status 'ready :tools '((:name "child" :description "Useful child" :eligible t)
                                         (:name "hidden" :description "Hidden" :eligible nil))))
         (pichat-tool-picker--state
          (list :preset spec :baseline '("read") :draft '(:builtins ("read") :extensions ("child"))
                :discovery cache :servers nil :loaded t :page 0))
         (transient--prefix (transient--init-prefix 'pichat-tool-picker))
         (transient--layout (transient--init-suffixes 'pichat-tool-picker))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (with-temp-buffer
      (transient--insert-groups)
      (should (string-match-p "Extension tools" (buffer-string)))
      (should (string-match-p "Useful child" (buffer-string)))
      (should (string-match-p "\\[✓\\] child" (buffer-string)))
      (should-not (string-match-p "inactive" (buffer-string))))
    (let ((hidden (cl-find "e2" transient--suffixes :key (lambda (suffix) (oref suffix key)) :test #'equal)))
      (should hidden)
      (should-error (funcall (oref hidden command)) :type 'user-error))
    (pichat-tool-picker-none)
    (should-not (plist-get (pichat-tool-picker--selection) :extensions))
    (pichat-tool-picker-reset)
    (should (equal '("child") (plist-get (pichat-tool-picker--selection) :extensions)))
    (let (result)
      (setf (plist-get pichat-tool-picker--state :callback) (lambda (value) (setq result value)))
      (pichat-tool-picker--toggle :extensions "child")
      (pichat-tool-picker-cancel)
      (should (eq result :cancel))
      (should (equal '("child") (plist-get spec :extensions))))))

(ert-deftest pichat-extension-tools-picker-partitions-exact-known-names-without-prefix-guesses ()
  (let ((pichat-tool-picker--state
         (list :servers '((:name "known" :tools ((:name "tool"))))
               :discovery
               (pichat-tool-discovery-draft-create
                :status 'ready
                :tools '((:name "read") (:name "powershell")
                         (:name "mcp__known__tool") (:name "mcp__unlisted__tool")
                         (:name "codemode") (:name "child"))))))
    (should (equal '("mcp__unlisted__tool" "codemode" "child")
                   (mapcar (lambda (tool) (plist-get tool :name))
                           (pichat-tool-picker--extension-tools))))))

(ert-deftest pichat-extension-tools-picker-fails-closed-on-stale-or-hidden-selection ()
  (let ((pichat-tool-picker--state
         (list :preset (pichat-presets-resolve 'manual) :baseline '("read")
               :draft '(:builtins ("read") :extensions ("missing"))
               :discovery (pichat-tool-discovery-draft-create :status 'ready :tools nil))))
    (should-error (pichat-tool-picker-apply) :type 'user-error)
    (setf (pichat-tool-discovery-draft-status (plist-get pichat-tool-picker--state :discovery)) 'failed)
    (should-error (pichat-tool-picker-apply) :type 'user-error)))

(ert-deftest pichat-extension-tools-picker-reuses-draft-and-invalidates-model-and-prompt-context ()
  (let ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
        (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
        (pichat-bridge-extension-file nil) (pichat-tool-picker--state nil)
        (cache (pichat-tool-discovery-draft-create))
        (spec '(:name test :tools ("read") :append-system-prompt "Captured instructions\n"))
        (calls 0) captured)
    (cl-letf (((symbol-function 'transient-setup) #'ignore)
              ((symbol-function 'pichat-tool-picker--refresh-display) #'ignore)
              ((symbol-function 'pichat-tool-picker--refresh-children) #'ignore)
              ((symbol-function 'pichat-mcp-discovery-start)
               (lambda (_transport _cwd _exe callback) (funcall callback nil nil) #'ignore))
              ((symbol-function 'pichat-tool-discovery-start)
               (lambda (_transport _cwd _exe callback &rest options)
                 (cl-incf calls) (setq captured (plist-get options :args))
                 (funcall callback '((:name "child" :description "Child" :eligible t)) nil) #'ignore)))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/a" cache)
      (should (= calls 1))
      (should (member "provider/a" captured))
      (should (member "Captured instructions\n" captured))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/a" cache)
      (should (= calls 1))
      (pichat-tool-picker-refresh)
      (should (= calls 2))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/b" cache)
      (should (= calls 3))
      (should (member "provider/b" captured))
      (pichat-tool-picker--abandoned)
      (should-not pichat-tool-picker--state))))

(defun pichat-test-extension-tools-active (session)
  "Query the fixture's real observed active names in SESSION, without a model."
  (let ((count (pichat-test-count-raw-events session "extension_ui_request")))
    (pichat-test-rpc-call session "prompt" '(:message "/probe-report"))
    (let ((event (pichat-test-wait-for-raw-event session "extension_ui_request" nil count)))
      (should (string-prefix-p "probe-active:" (plist-get event :message)))
      (json-parse-string (substring (plist-get event :message) (length "probe-active:")) :array-type 'list))))

(when pichat-test-include-integration
  (ert-deftest pichat-extension-tools-real-launch-enables-before-readiness-without-model-turns ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child" "probe_session"))
                 :extensions (list pichat-test-extension-tools-fixture pichat-test-bridge-extension) :script '(:turns []))
      (should (plist-get (pichat-session-rpc-startup-control session) :verified))
      (should (member "--extension" (pichat-session-rpc-command session)))
      (let ((active (pichat-test-extension-tools-active session)))
        (should (member "probe_child" active))
        (should (member "probe_session" active))
        (should-not (member "probe_loader" active)))
      (should-not (cl-find-if (lambda (event) (equal (plist-get event :title) pichat-tool-discovery--title))
                              (pichat-session-event-log session)))
      (let ((entries (plist-get (pichat-test-rpc-call session "get_entries") :data)))
        (should (pichat-pi-startup-metadata-only-p (plist-get entries :entries) (plist-get entries :leafId))))
      (pichat-test-rpc-call session "prompt" '(:message "/probe-deactivate"))
      (pichat-test-rpc-call session "get_state")
      (should-not (member "probe_child" (pichat-test-extension-tools-active session)))))

  (ert-deftest pichat-extension-tools-real-probe-supports-bridge-startup-without-executing-tools ()
    (pichat-test-with-integration-session
        (session :preset 'manual :script '(:turns []))
      (let (result)
        (pichat-tool-discovery-start
         pichat-transport-local project-dir pichat-test-pi-executable
         (lambda (tools error) (setq result (list tools error)))
         :args (list "--offline" "--no-approve" "--no-context-files" "--no-skills"
                     "--no-prompt-templates" "--no-themes" "--no-extensions" "--no-mcp"
                     "-e" pichat-test-fake-provider-extension "-e" pichat-test-bridge-extension
                     "-e" pichat-test-extension-tools-fixture "--model" "pichat-fake/pichat-fake"))
        (pichat-test-wait-until (lambda () result) 10 "probe with optional Emacs bridge")
        (should-not (cadr result))
        (should (cl-find "probe_child" (car result) :key (lambda (tool) (plist-get tool :name)) :test #'equal)))))

  (ert-deftest pichat-extension-tools-real-launch-rejects-missing-hidden-and-absent-helper ()
    (pichat-test-with-integration-session
        (session :preset 'manual :extensions (list pichat-test-extension-tools-fixture) :script '(:turns []))
      (dolist (choice '("missing" "probe_hidden" "helper-absent"))
        (let* ((pichat-tool-discovery-helper
                (if (equal choice "helper-absent") pichat-test-fake-provider-extension pichat-tool-discovery-helper))
               (failed (pichat-start-session
                        project-dir nil (list :preset 'manual :tools
                                              (list :builtins '("read") :extensions
                                                    (list (if (equal choice "helper-absent") "probe_child" choice))))))
               response)
          (unwind-protect
              (progn
                (pichat-rpc-get-state failed (lambda (value _s) (setq response value))
                                      (lambda (value _s) (setq response value)))
                (pichat-test-wait-until (lambda () response) 10 "failed selected tool startup")
                (should-not (plist-get response :success))
                (should-not (pichat-session-alive-p failed))
                (should-not (pichat-session-rpc-startup-control failed)))
            (pichat-rpc-stop failed)
            (pichat-forget-session failed))))))

  (ert-deftest pichat-extension-tools-real-saved-restart-and-independent-open-verify-after-reload ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child"))
                 :extensions (list pichat-test-extension-tools-fixture)
                 :script '(:turns [(:text "Saved source before extension restart")]))
      (let ((pichat-chat-stop-session-on-kill nil) buffer opened result)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session t))
              (pichat-test-chat-send-and-wait session buffer "Create a saved source")
              (pichat-test-assert-provider-script-consumed status-file)
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache session)) 5 "saved source cache")
              ;; Subsequent processes must not request any model turn.  The
              ;; initial explicit fake-model turn exists only to persist Pi's file.
              (with-temp-file script-file (insert "{\"turns\":[]}"))
              (let ((id (pichat-session-id session)) (file (pichat-session-session-file session)))
                (pichat-reconfigure-restart
                 (pichat-reconfigure-capture-origin session)
                 (pichat-reconfigure-select-tools
                  (pichat-reconfigure-captured-configuration session)
                  '(:builtins ("read") :extensions ("probe_child" "probe_session")))
                 (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "saved source extension restart")
                (should (car result))
                (should (equal id (pichat-session-id session)))
                (should (member "probe_child" (pichat-test-extension-tools-active session)))
                (should (member "probe_session" (pichat-test-extension-tools-active session)))
                (pichat-rpc-stop session)
                (setq result nil)
                (setq opened
                      (pichat-sessions-open-file-independently
                       file :cwd project-dir :owner-directory project-dir :source-session session
                       :readiness 'transcript-ready :expected-session-id id
                       :launch-options '(:preset manual :tools (:builtins ("read") :extensions ("probe_child")))
                       :ready (lambda (_session) (setq result '(t)))
                       :error-callback (lambda (response _session) (setq result (list nil response)))))
                (pichat-test-wait-until (lambda () result) 15 "independent saved-source extension verification")
                (should (car result))
                (should (equal id (pichat-session-id opened)))
                (should (member "probe_child" (pichat-test-extension-tools-active opened)))))
          (when (pichat-session-p opened)
            (when-let* ((chat (pichat-session-buffer opened))) (when (buffer-live-p chat) (kill-buffer chat)))
            (pichat-rpc-stop opened) (pichat-forget-session opened))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-extension-tools-real-restart-keeps-snapshots-and-restores-after-failure ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child"))
                 :extensions (list pichat-test-extension-tools-fixture) :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil) buffer result)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session t))
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache session)) 5 "initial empty cache")
              (let* ((before (pichat-reconfigure-captured-configuration session))
                     (requested (pichat-reconfigure-select-tools
                                 before '(:builtins ("read") :extensions ("missing"))))
                     (runtime-id (pichat-session-runtime-id session)))
                (pichat-reconfigure-restart (pichat-reconfigure-capture-origin session) requested
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "missing-tool replacement failure")
                (should-not (car result))
                (should-not (pichat-session-alive-p session))
                (should (equal before (pichat-reconfigure-captured-configuration session)))
                (should (equal '("missing")
                               (plist-get (plist-get (plist-get (pichat-session-restart-operation session) :requested)
                                                     :tool-selection) :extensions)))
                (setq result nil)
                (pichat-reconfigure-recover session 'retry
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "retry preserves requested extension snapshot")
                (should-not (car result))
                (setq result nil)
                (pichat-reconfigure-recover session 'restore
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "restore previous extension selection")
                (should (car result))
                (should (equal runtime-id (pichat-session-runtime-id session)))
                (should (equal before (pichat-reconfigure-captured-configuration session)))
                (should (member "probe_child" (pichat-test-extension-tools-active session)))
                (setq result nil)
                (pichat-reconfigure-restart
                 (pichat-reconfigure-capture-origin session)
                 (pichat-reconfigure-select-tools before '(:builtins ("read") :extensions ("probe_session")))
                 (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "successful changed extension selection")
                (should (car result))
                (should (equal '("probe_session") (plist-get (pichat-session-tool-selection session) :extensions)))
                (should-not (member "probe_child" (pichat-test-extension-tools-active session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-extension-tools)
;;; pichat-test-extension-tools.el ends here
