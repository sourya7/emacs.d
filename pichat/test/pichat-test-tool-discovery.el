;;; pichat-test-tool-discovery.el --- Tool probe boundaries -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-tool-discovery)

(defconst pichat-test-tool-control-fixture
  (expand-file-name "fixtures/tool-control-extension.ts" pichat-test-directory))

(ert-deftest pichat-tool-discovery-validates-catalogue-and-selection-safety ()
  (let* ((raw "{\"protocolVersion\":1,\"requestId\":\"test\",\"ok\":true,\"tools\":[{\"name\":\"okay\",\"description\":\"Tool\",\"exposure\":\"direct\"},{\"name\":\"hidden\",\"description\":\"\",\"exposure\":\"hidden\"},{\"name\":\"wild*\",\"description\":\"\",\"exposure\":\"deferred\"}],\"activeTools\":[\"okay\"]}")
         (data (json-parse-string raw))
         (tools (pichat-tool-discovery--catalogue data "test")))
    (should (plist-get (car tools) :eligible))
    (should (plist-get (car tools) :active))
    (should-not (plist-get (cadr tools) :eligible))
    (should-not (plist-get (caddr tools) :eligible))
    (should-error (pichat-tool-discovery--catalogue data "stale"))
    (puthash "activeTools" ["missing"] data)
    (should-error (pichat-tool-discovery--catalogue data "test"))
    (puthash "tools" nil data)
    (should-error (pichat-tool-discovery--catalogue data "test"))))

(ert-deftest pichat-tool-discovery-draft-invalidates-without-implicit-probes ()
  (let ((draft (pichat-tool-discovery-draft-create)) callbacks cancelled)
    (cl-letf (((symbol-function 'pichat-tool-discovery-start)
               (lambda (_transport _cwd _executable callback &rest _)
                 (push callback callbacks)
                 (lambda () (setq cancelled t)))))
      (pichat-tool-discovery-draft-reset draft '(:cwd "/first" :environment ("VAR=one")))
      (should-not callbacks)
      (pichat-tool-discovery-draft-refresh draft nil)
      (let ((stale (car callbacks)))
        (pichat-tool-discovery-draft-reset draft '(:cwd "/first" :environment ("VAR=two")))
        (should cancelled)
        (funcall stale '((:name "stale")) nil)
        (should-not (pichat-tool-discovery-draft-tools draft)))
      (pichat-tool-discovery-draft-refresh draft nil)
      (funcall (car callbacks) '((:name "fresh")) nil)
      (should (eq (pichat-tool-discovery-draft-status draft) 'ready))
      (should (equal (pichat-tool-discovery-draft-tools draft) '((:name "fresh"))))
      (let ((stale (car callbacks)))
        (pichat-tool-discovery-draft-refresh draft nil)
        (funcall stale '((:name "obsolete-refresh")) nil)
        (should-not (pichat-tool-discovery-draft-tools draft))))))

(ert-deftest pichat-tool-discovery-rejects-unsafe-generic-configuration ()
  (dolist (args '(("--tools" "read") ("--exclude-tools=probe_*")
                  ("--session" "/saved.jsonl") ("--continue")))
    (should-error (pichat-tool-discovery--validate-args args)))
  (dolist (args '(("Hello model") ("--mode" "json") ("--unknown-extension-flag" "value")))
    (should-error (pichat-tool-discovery--validate-args args)))
  (let ((pichat-rpc-command '("wrapper")))
    (should-error (pichat-tool-discovery--args pichat-transport-local nil))))

(ert-deftest pichat-tool-discovery-captures-target-resources-model-and-environment ()
  (let* ((pichat-rpc-command nil)
         (pichat-pi-default-args '("--mode" "rpc"))
         (pichat-pi-extra-args '("--no-approve"))
         (pichat-default-model "host/default")
         (pichat-bridge-extension-file "/host/bridge.ts")
         (pichat-pi-extra-env '(("PICHAT_DISCOVERY_CONTEXT" . "captured")))
         (remote (pichat-transport--create :id 'remote :kind 'ssh
                                          :pi-args '("--model" "remote/default")))
         (context (pichat-tool-discovery-context remote "/remote/cwd" "/remote/pi" "remote/selected"))
         (args (plist-get context :args)))
    (should (equal (plist-get context :cwd) "/remote/cwd"))
    (should (equal (plist-get context :executable) "/remote/pi"))
    (should (equal args '("--mode" "rpc" "--model" "remote/default" "--model" "remote/selected")))
    (should-not (member "/host/bridge.ts" args))
    (should (member "PICHAT_DISCOVERY_CONTEXT=captured" (plist-get context :environment)))
    (let ((process-environment (copy-sequence process-environment)))
      (setenv "PICHAT_DISCOVERY_CONTEXT" "changed"))
    (should (member "PICHAT_DISCOVERY_CONTEXT=captured" (plist-get context :environment)))))

(ert-deftest pichat-tool-discovery-parser-fails-on-malformed-and-oversized-output ()
  (dolist (output '("not JSON\n" "[]\n"))
    (let (result)
      (cl-letf (((symbol-function 'pichat-transport-make-process)
                 (lambda (_transport _cwd &rest args)
                   (apply #'make-process
                          (plist-put args :command (list "printf" "%s" output))))))
        (pichat-tool-discovery-start
         pichat-transport-local temporary-file-directory "pi"
         (lambda (tools error) (setq result (list tools error))) :args nil)
        (pichat-test-wait-until (lambda () result) 5 "invalid probe output")
        (should-not (car result))
        (should (cadr result)))))
  (let ((pichat-tool-discovery--limit 32) result)
    (cl-letf (((symbol-function 'pichat-transport-make-process)
               (lambda (_transport _cwd &rest args)
                 (apply #'make-process
                        (plist-put args :command (list "printf" "%s" (make-string 100 ?x)))))))
      (pichat-tool-discovery-start
       pichat-transport-local temporary-file-directory "pi"
       (lambda (tools error) (setq result (list tools error))) :args nil)
      (pichat-test-wait-until (lambda () result) 5 "oversized probe output")
      (should-not (car result))
      (should (cadr result)))))

(ert-deftest pichat-tool-discovery-handles-dialog-before-process-start-returns ()
  (let (result)
    (cl-letf (((symbol-function 'pichat-transport-make-process)
               (lambda (_transport _cwd &rest args)
                 (funcall (plist-get args :filter) nil
                          "{\"type\":\"extension_ui_request\",\"id\":\"early\",\"method\":\"confirm\"}\n")
                 (apply #'make-process
                        (plist-put args :command '("sh" "-c" "cat >/dev/null"))))))
      (pichat-tool-discovery-start
       pichat-transport-local temporary-file-directory "pi"
       (lambda (tools error) (setq result (list tools error))) :args nil)
      (pichat-test-wait-until (lambda () result) 5 "early startup dialog cleanup")
      (should-not (car result))
      (should (string-match-p "user interaction" (cadr result))))))

(ert-deftest pichat-tool-discovery-stages-private-target-helper-and-removes-it ()
  (pichat-test-with-temp-dir remote-dir
    (let ((transport (pichat-transport--create :id 'test :kind 'ssh))
          prepared)
      (cl-letf (((symbol-function 'pichat-transport-runtime-file-name)
                 (lambda (_transport _path) (expand-file-name "staged-" remote-dir))))
        (setq prepared (pichat-tool-discovery-prepare-helper transport)))
      (let* ((path (plist-get prepared :path))
             (directory (file-name-directory path)))
        (should (file-exists-p path))
        (should (= (file-modes directory) #o700))
        (should (= (file-modes path) #o600))
        (should-not (equal path pichat-tool-discovery-helper))
        (funcall (plist-get prepared :cleanup))
        (should-not (file-exists-p directory))))))

(defun pichat-test-tool-control-call (session operation &optional names)
  "Call the real internal control command in SESSION with OPERATION and NAMES."
  (let ((count (pichat-test-count-raw-events session "extension_ui_request")) response)
    (pichat-rpc-send
     session "prompt"
     (list :message (concat "/pichat-tool-control-v1 "
                            (json-serialize (list :protocolVersion 1 :requestId "test"
                                                  :operation operation :names (vconcat names)))))
     (lambda (value _session) (setq response value)))
    (let* ((event (pichat-test-wait-for-raw-event session "extension_ui_request" nil count))
           (data (json-parse-string (plist-get event :placeholder))))
      (should (equal (plist-get event :title) pichat-tool-discovery--title))
      (pichat-rpc-extension-ui-value session (plist-get event :id) "ack")
      (pichat-test-wait-until (lambda () response) nil "internal command acceptance")
      (should (equal (plist-get (plist-get response :data) :disposition) "handled"))
      data)))

(cl-defmacro pichat-test-with-tool-probe ((&key scenario) &rest body)
  "Run BODY with isolated real-Pi discovery configuration and SCENARIO."
  (declare (indent 1))
  `(progn
     (pichat-test-require-pi)
     (pichat-test-with-temp-dir project-dir
       (pichat-test-with-temp-dir agent-dir
         (pichat-test-with-temp-dir session-dir
           (let* ((status-file (expand-file-name "provider-status.json" project-dir))
                  (script-file (expand-file-name "script.json" project-dir))
                  (shutdown-file (expand-file-name "shutdown" project-dir))
                  (pichat-pi-extra-env nil)
                  (process-environment
                   (append (list (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                 (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                 "PI_OFFLINE=1" "PI_TELEMETRY=0" "PI_SKIP_VERSION_CHECK=1"
                                 (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-file)
                                 (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-file)
                                 (concat "PICHAT_TOOL_FIXTURE_SCENARIO=" ,scenario)
                                 (concat "PICHAT_TOOL_FIXTURE_SHUTDOWN=" shutdown-file))
                           process-environment))
                  (args (list "--offline" "--no-approve" "--no-context-files"
                              "--no-skills" "--no-prompt-templates" "--no-themes"
                              "--no-extensions" "--no-mcp"
                              "-e" pichat-test-fake-provider-extension
                              "-e" pichat-test-tool-control-fixture
                              "--model" "pichat-fake/pichat-fake")))
             (with-temp-file script-file (insert "{\"turns\":[]}"))
             ,@body))))))

(when pichat-test-include-integration
  (ert-deftest pichat-tool-discovery-real-pi-catalogue-and-orderly-cleanup ()
    (pichat-test-with-tool-probe (:scenario "normal")
      (let ((pichat-pi-extra-env '(("PICHAT_TOOL_PROBE_MARKER" . "captured"))) result cancel)
        (unwind-protect
            (progn
              (setq cancel (pichat-tool-discovery-start
                            pichat-transport-local project-dir pichat-test-pi-executable
                            (lambda (tools error) (setq result (list tools error))) :args args))
              (pichat-test-wait-until (lambda () result) 15 "real tool probe completion")
              (should-not (cadr result))
              (let* ((tools (car result))
                     (context-tool (cl-find "probe_context" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal))
                     (context (json-parse-string (plist-get context-tool :description))))
                (should (equal (gethash "cwd" context) (directory-file-name project-dir)))
                (should (equal (gethash "marker" context) "captured"))
                (should (cl-find "probe_session" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal))
                (let ((child (cl-find "probe_child" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal)))
                  (should child)
                  (should-not (plist-get child :active)))
                (should-not (plist-get (cl-find "probe_hidden" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal) :eligible)))
              (should (file-exists-p shutdown-file))
              (pichat-test-assert-provider-script-consumed status-file)
              (should-not (directory-files session-dir nil "\\.jsonl\\'")))
          (when cancel (funcall cancel))))))

  (ert-deftest pichat-tool-discovery-real-pi-helper-absence-never-prompts-model ()
    (pichat-test-with-tool-probe (:scenario "normal")
      (let ((pichat-tool-discovery-helper pichat-test-fake-provider-extension)
            result)
        (pichat-tool-discovery-start
         pichat-transport-local project-dir pichat-test-pi-executable
         (lambda (tools error) (setq result (list tools error))) :args args)
        (pichat-test-wait-until (lambda () result) 15 "missing helper failure")
        (should-not (car result))
        (should (string-match-p "helper unavailable" (cadr result)))
      (pichat-test-assert-provider-script-consumed status-file))))

  (ert-deftest pichat-tool-discovery-real-pi-without-model-or-provider ()
    (pichat-test-with-tool-probe (:scenario "normal")
      (let ((minimal '("--offline" "--no-approve" "--no-context-files" "--no-skills"
                       "--no-prompt-templates" "--no-themes" "--no-extensions" "--no-mcp"))
            result)
        (pichat-tool-discovery-start
         pichat-transport-local project-dir pichat-test-pi-executable
         (lambda (tools error) (setq result (list tools error))) :args minimal)
        (pichat-test-wait-until (lambda () result) 15 "no-model tool probe")
        (should-not (cadr result))
        (should (car result)))))

  (ert-deftest pichat-tool-discovery-real-pi-dialog-and-startup-errors-fail ()
    (dolist (scenario '("dialog" "error"))
      (pichat-test-with-tool-probe (:scenario scenario)
        (let (result cancel)
          (unwind-protect
              (progn
                (setq cancel (pichat-tool-discovery-start
                              pichat-transport-local project-dir pichat-test-pi-executable
                              (lambda (tools error) (setq result (list tools error))) :args args))
                (pichat-test-wait-until (lambda () result) 15 "failed probe")
                (should-not (car result))
                (should (cadr result)))
            (when cancel (funcall cancel)))))))

  (ert-deftest pichat-tool-discovery-real-pi-timeout-and-cancel ()
    (pichat-test-with-tool-probe (:scenario "hang")
      (let ((pichat-tool-discovery-timeout 0.5) result cancel)
        (unwind-protect
            (progn
              (setq cancel (pichat-tool-discovery-start
                            pichat-transport-local project-dir pichat-test-pi-executable
                            (lambda (tools error) (setq result (list tools error))) :args args))
              (pichat-test-wait-until (lambda () result) 5 "probe deadline")
              (should (string-match-p "timed out" (cadr result)))
              (setq result nil)
              (setq cancel (pichat-tool-discovery-start
                            pichat-transport-local project-dir pichat-test-pi-executable
                            (lambda (&rest _) (setq result t)) :args args))
              (funcall cancel)
              (pichat-test-wait-until
               (lambda () (not (cl-find-if
                                (lambda (proc) (and (process-live-p proc)
                                                    (string-prefix-p "pichat-tool-probe" (process-name proc))))
                                (process-list)))) 5 "cancelled probe cleanup")
              (should-not result))
          (when cancel (funcall cancel))))))

  (ert-deftest pichat-tool-control-real-pi-activation-exposures-and-startup-barrier ()
    (pichat-test-with-integration-session
        (session :no-session t :script '(:turns [])
                 :extensions (list pichat-tool-discovery-helper pichat-test-tool-control-fixture))
      (let* ((initial (pichat-test-tool-control-call session "catalogue"))
             (tools (pichat-tool-discovery--catalogue initial "test")))
        (should (cl-find "probe_session" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal))
        (should-not (plist-get (cl-find "probe_child" tools :key (lambda (tool) (plist-get tool :name)) :test #'equal) :active)))
      (let ((enabled (pichat-test-tool-control-call
                      session "enable" '("probe_child" "probe_model_only" "probe_codemode" "probe_deferred"))))
        (should (eq (gethash "ok" enabled) t))
        (dolist (name '("probe_child" "probe_model_only" "probe_codemode" "probe_deferred"))
          (should (member name (append (gethash "activeTools" enabled) nil)))))
      (let ((failed (pichat-test-tool-control-call session "enable" '("probe_hidden"))))
        (should-not (eq (gethash "ok" failed) t)))
      (pichat-test-rpc-call session "prompt" '(:message "/probe-deactivate"))
      (let ((later (pichat-test-tool-control-call session "catalogue")))
        (should-not (member "probe_child" (append (gethash "activeTools" later) nil))))
      (should-not (plist-get (plist-get (pichat-test-rpc-call session "get_messages") :data) :messages))))

  (ert-deftest pichat-tool-control-real-pi-cannot-bypass-startup-allowlist ()
    (dolist (allowlist '("read" "read,probe_loader" "read,probe_loader,probe_child"))
      (pichat-test-with-integration-session
          (session :no-session t :script '(:turns []) :tools allowlist
                   :extensions (list pichat-tool-discovery-helper pichat-test-tool-control-fixture))
        (let* ((data (pichat-test-tool-control-call session "catalogue"))
               (names (mapcar (lambda (tool) (gethash "name" tool)) (append (gethash "tools" data) nil)))
               (allowed (member "probe_child" (split-string allowlist ","))))
          (should (eq (not (null (member "probe_child" names))) (not (null allowed))))
          (let ((enabled (pichat-test-tool-control-call session "enable" '("probe_child"))))
            (should (eq (eq (gethash "ok" enabled) t) (not (null allowed))))))))))

(provide 'pichat-test-tool-discovery)
;;; pichat-test-tool-discovery.el ends here
