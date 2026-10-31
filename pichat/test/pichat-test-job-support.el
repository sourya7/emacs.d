;;; pichat-test-job-support.el --- Isolated job executor fixtures -*- lexical-binding: t; -*-

;;; Code:
(require 'pichat-test-support)
(require 'pichat-job-executor)

(cl-defmacro pichat-test-with-job-executor ((&key script) &rest body)
  "Run BODY with isolated executor, project-dir, store and optional SCRIPT.
SCRIPT enables a real offline Pi fixture, never user state.  No runtime starts
until BODY submits work.  Fixture teardown retires handlers before stopping."
  (declare (indent 1))
  `(pichat-test-with-clean-state
     (pichat-test-with-temp-dir project-dir
       (pichat-test-with-temp-dir agent-dir
         (pichat-test-with-temp-dir session-dir
           (let* ((pichat-default-model "pichat-fake/pichat-fake")
                  (pichat-default-preset 'review)
                  (pichat-targets nil) (pichat-project-target-alist nil)
                  (pichat-path-mappings nil)
                  (pichat-rpc-command nil)
                  (pichat-bridge-extension-file nil)
                  (pichat-auto-use-repo-bridge nil)
                  (pichat-pi-extra-env nil)
                  (pichat-pi-executable pichat-test-pi-executable)
                  (pichat-pi-session-dir session-dir)
                  (pichat-jobs-control-timeout 5)
                  (pichat-pi-default-args
                   '("--mode" "rpc" "--offline" "--no-approve"
                     "--no-context-files" "--no-skills" "--no-prompt-templates"
                     "--no-themes" "--no-extensions"))
                  (pichat-pi-extra-args (list "-e" pichat-test-fake-provider-extension))
                  (script-file (expand-file-name "provider.json" project-dir))
                  (status-file (expand-file-name "provider-status.json" project-dir))
                  (process-environment
                   (append (list "PI_OFFLINE=1" "PI_TELEMETRY=0" "PI_SKIP_VERSION_CHECK=1"
                                 (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                 (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                 (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-file)
                                 (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-file))
                           process-environment))
                  (store (pichat-job-store-open (expand-file-name "jobs.json" agent-dir)))
                  (executor (pichat-job-executor-open store))
                  (initial-buffers (buffer-list))
                  (default-directory project-dir))
             (when ,script
               (pichat-test-require-pi)
               (with-temp-file script-file
                 (insert (json-serialize ,script :null-object nil :false-object :json-false))))
             (unwind-protect (save-window-excursion ,@body)
               (maphash (lambda (_id execution) (pichat-job-executor--retire execution))
                        (pichat-job-executor-contexts executor))
               (dolist (runtime (pichat-session-list))
                 (ignore-errors (pichat-rpc-stop runtime))
                 (when-let* ((buffer (pichat-session-buffer runtime)))
                   (when (buffer-live-p buffer) (kill-buffer buffer))))
               (when (boundp 'pichat-jobs--owner)
                 (dolist (buffer (buffer-list))
                   (when (and (not (memq buffer initial-buffers))
                              (eq (buffer-local-value 'pichat-jobs--owner buffer) executor))
                     (kill-buffer buffer)))))))))))

(defun pichat-test-job-spec (directory &optional access)
  "Capture a deterministic job rooted in DIRECTORY with ACCESS."
  (pichat-job-launch-capture
   "Review files" "Inspect the supplied files." directory
   '(:preset review :model "pichat-fake/pichat-fake" :target local) access))

(defun pichat-test-job-wait (store id state)
  "Wait for run ID to reach STATE in STORE with failure diagnostics."
  (pichat-test-wait-until
   (lambda () (equal (plist-get (pichat-job-record store 'runs id) :state) state))
   12 (format "job %s to reach %s" id state)))

(defmacro pichat-test-with-owned-job (&rest body)
  "Run BODY with one inert process owned by a claimed job execution."
  (declare (indent 0) (debug t))
  `(pichat-test-with-job-executor ()
     (let* ((id (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
            (claim (pichat-job-claim store id))
            (session (pichat-session-make :cwd project-dir :id "pi-source"
                                          :session-file "/example/session.jsonl"
                                          :process-generation 1))
            (process (pichat-test--make-unit-process session))
            (transport-buffer (process-buffer process))
            (initial-buffers (buffer-list))
            (execution (pichat-job-execution--create
                        :executor executor :id id :token (plist-get claim :attempt)
                        :session session :process process :generation 1
                        :source '("pi-source" "/example/session.jsonl"))))
       (process-put process 'pichat-process-generation 1)
       (puthash id execution (pichat-job-executor-contexts executor))
       (unwind-protect (save-window-excursion ,@body)
         (pichat-job-executor--retire execution)
         (ignore-errors (pichat-rpc-stop session))
         (when (process-live-p process) (delete-process process))
         (when (buffer-live-p transport-buffer) (kill-buffer transport-buffer))
         (dolist (buffer (buffer-list))
           (when (and (not (memq buffer initial-buffers))
                      (or (eq buffer (pichat-session-buffer session))
                          (eq (buffer-local-value 'pichat-jobs--owner buffer) executor)))
             (kill-buffer buffer)))))))


(defun pichat-test-job-press (label)
  "Activate the visible job button LABEL, failing if absent."
  (goto-char (point-min))
  (should (search-forward label nil t))
  (let ((button (button-at (1- (point)))))
    (should button)
    (button-activate button)))

(provide 'pichat-test-job-support)
;;; pichat-test-job-support.el ends here
