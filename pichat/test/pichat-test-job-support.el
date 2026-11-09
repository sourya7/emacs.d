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
                 (insert (decode-coding-string
                          (json-serialize ,script :null-object nil :false-object :json-false)
                          'utf-8))))
             (unwind-protect (save-window-excursion ,@body)
               (pichat-job-executor-schedule-stop executor)
               (dolist (id (hash-table-keys (pichat-job-executor-conversations executor)))
                 (pichat-job-executor--conversation-forget executor id))
               (maphash (lambda (_id execution) (pichat-job-executor--retire execution))
                        (pichat-job-executor-contexts executor))
               (dolist (runtime (pichat-session-list))
                 (ignore-errors (pichat-rpc-stop runtime))
                 (when-let* ((buffer (pichat-session-buffer runtime)))
                   (when (buffer-live-p buffer) (kill-buffer buffer))))
               (when (boundp 'pichat-jobs--owner)
                 (dolist (buffer (buffer-list))
                   (when (and (not (memq buffer initial-buffers))
                              (or (eq (buffer-local-value 'pichat-jobs--owner buffer) executor)
                                  (with-current-buffer buffer
                                    (derived-mode-p 'pichat-job-definition-ui-mode
                                                     'pichat-job-definitions-mode))))
                     (kill-buffer buffer)))))))))))

(defmacro pichat-test-with-conversation-job (&rest body)
  "Run BODY with an inert, synchronized chat and data-only capture fixture."
  (declare (indent 0) (debug t))
  `(pichat-test-with-job-executor ()
     (let* ((session (pichat-session-make
                      :cwd project-dir :id "conversation-source" :process-generation 1 :state 'idle
                      :model '(:provider "pichat-fake" :id "pichat-fake")
                      :preset-spec (pichat-presets-resolve 'review)))
            (process (pichat-test--make-unit-process session))
            (transport-buffer (process-buffer process))
            (buffer (pichat-chat-ensure session))
            (entries '((:type "message" :id "old" :parentId nil
                        :message (:role "assistant" :stopReason "error" :errorMessage "Earlier quota error"
                                  :content ((:type "text" :text "Old response")))))))
       (with-current-buffer buffer
         (setq pichat-chat--source-bound-p t
               pichat-chat--source-session-id "conversation-source"
               pichat-chat--source-session-file nil
               pichat-chat--entry-cache (pichat-pi-entry-cache-full "conversation-source" nil entries "old")))
       (unwind-protect (progn ,@body)
         (when (process-live-p process) (delete-process process))
         (when (buffer-live-p transport-buffer) (kill-buffer transport-buffer))
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (setq pichat-job-executor--buffer-execution nil))
           (kill-buffer buffer))))))

(defmacro pichat-test-with-conversation-rpc (&rest body)
  "Run BODY with synchronous state/prompt replies and a COMMANDS log."
  (declare (indent 0) (debug t))
  `(let (commands)
     (cl-letf (((symbol-function 'pichat-rpc-send)
                (lambda (session type _payload &optional success _failure)
                  (pichat-rpc--require-operation-ownership session type)
                  (push type commands)
                  (when success
                    (funcall success
                             (if (equal type "prompt") '(:success t :data (:disposition "started"))
                               (pichat-test-job-conversation-reply session type)) session)))))
       ,@body)))

(defun pichat-test-job-conversation-schedule (executor session &optional due)
  "Schedule SESSION with synchronous fixture RPC; return the accepted ID."
  (let (id)
    (pichat-job-executor-conversation-schedule
     executor (pichat-job-conversation-capture session) "continue" (or due (+ (float-time) 3600)) nil
     (lambda (value) (setq id value)) (lambda (reason) (ert-fail reason)))
    (or id (ert-fail "No accepted schedule"))))

(defun pichat-test-job-conversation-due (executor id)
  "Consume ID at its explicit fixture clock and pump ordinary admission."
  (let* ((store (pichat-job-executor-store executor)) (run (pichat-job-record store 'runs id)))
    (pichat-job-conversation-dispatch store id run (plist-get (plist-get run :trigger) :due))
    (pichat-job-executor-schedule-refresh executor)
    (pichat-job-executor-pump executor)))

(defun pichat-test-job-conversation-start (directory)
  "Start an ordinary real offline Pi chat in isolated fixture DIRECTORY."
  (let ((session (pichat-prepare-session directory nil '(:preset review :model "pichat-fake/pichat-fake"))))
    (pichat-chat-ensure session)
    (pichat-start-prepared-session session t)
    (pichat-test-rpc-call session "get_state")
    (pichat-test-rpc-call session "set_auto_retry" '(:enabled :json-false))
    (pichat-test-rpc-call session "set_auto_compaction" '(:enabled :json-false))
    (pichat-test-job-conversation-ready session)
    session))

(defun pichat-test-job-conversation-ready (session)
  "Wait for SESSION's exact idle canonical capture, not just prompt ack."
  (pichat-test-wait-until
   (lambda () (condition-case nil (pichat-job-conversation-capture session) (user-error nil)))
   10 "ordinary conversation synchronization"))

(defun pichat-test-job-conversation-reply (session type)
  "Return a fresh inert conversation fixture reply for TYPE."
  (list :success t :data
        (pcase type
          ("get_entries" (let ((cache (pichat-chat-canonical-entry-cache session)))
                           (list :entries (pichat-job-conversation--entries cache)
                                 :leafId (pichat-entry-cache-leaf-id cache))))
          ("get_state" (list :sessionId (pichat-session-id session)
                              :sessionFile (pichat-session-session-file session)
                              :model (pichat-session-model session) :isStreaming nil
                              :isCompacting nil :pendingMessageCount 0)))))

(defun pichat-test-job-spec (directory &optional access)
  "Capture work in DIRECTORY; optional ACCESS adds inert legacy metadata."
  (let ((spec (pichat-job-launch-capture
               "Review files" "Inspect the supplied files." directory
               '(:preset review :model "pichat-fake/pichat-fake" :target local))))
    (when access
      (setf (plist-get spec :resources)
            (vector (list :key directory :access access))))
    spec))

(defun pichat-test-job-composer-spec (scope)
  "Capture SCOPE's staged work through the ordinary submission boundary."
  (with-current-buffer (plist-get scope :origin)
    (let ((pichat-job--draft (plist-get scope :draft))
          (pichat-jobs--owner (plist-get scope :owner)))
      (pichat-job--submission-spec))))

(defun pichat-test-start-bridge-chat (directory script status emacs-tools)
  "Start and open a real offline chat in DIRECTORY with inline provider SCRIPT.
STATUS records script consumption; EMACS-TOOLS are the selected Emacs-defined
tools, loaded through the repository bridge.  Return the runtime session."
  (let* ((pichat-bridge-extension-file pichat-test-bridge-extension)
         (process-environment
          (append (list (concat "PICHAT_FAKE_PROVIDER_STATUS=" status)
                        (concat "PICHAT_FAKE_PROVIDER_SCRIPT_JSON=" (json-serialize script)))
                  process-environment))
         (chat (pichat-start-session
                directory nil
                `(:preset review :tools (:builtins nil :emacs ,emacs-tools)))))
    (pichat-test-rpc-call chat "get_state")
    (pichat-test-rpc-call chat "set_auto_retry" (list :enabled :json-false))
    (pichat-test-rpc-call chat "set_auto_compaction" (list :enabled :json-false))
    (pichat-chat-open chat)
    chat))

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


(defun pichat-test-job-goto-button (label)
  "Put point at the start of the visible button containing LABEL."
  (goto-char (point-min))
  (should (search-forward label nil t))
  (let ((button (button-at (1- (point)))))
    (should button)
    (goto-char (button-start button))
    button))

(defun pichat-test-job-actions ()
  "Return the inspected report's available command labels without running work."
  (let (scope)
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (prefix _layout _edit &rest args)
                 (should (eq prefix 'pichat-jobs-actions-menu))
                 (setq scope (plist-get args :scope)))))
      (pichat-jobs-actions))
    (mapcar (lambda (item) (nth 2 item))
            (pichat-jobs--action-items (plist-get scope :owner)
                                      (car (plist-get scope :detail))
                                      (pichat-jobs--actions-current scope)))))

(defun pichat-test-job-command (label)
  "Invoke LABEL through report Actions; live Emacs drives the actual menu key."
  (if noninteractive (pichat-test-job-actions)
    (execute-kbd-macro (kbd (if (pichat-view-evil-normal-p) "g a" "a"))))
  (let ((item (seq-find (lambda (entry) (equal (nth 2 entry) label))
                        (pichat-jobs--action-items pichat-jobs--owner (car pichat-jobs--detail)
                                                  (pichat-jobs--actions-current pichat-jobs--actions)))))
    (should item)
    (if noninteractive (pichat-jobs--action pichat-jobs--actions (nth 3 item))
      (execute-kbd-macro (kbd (nth 1 item))))))

(defun pichat-test-job-press (label)
  "Activate a visible job button or a contextual Actions command LABEL.
Use `pichat-test-job-goto-button' when asserting that a control is inline."
  (goto-char (point-min))
  (let* ((found (search-forward label nil t))
         (button (and found (button-at (1- (point))))))
    (if button (button-activate button)
      (pichat-test-job-command label))))

(defun pichat-test-job-author (directory &rest changes)
  "Write an isolated project definition in DIRECTORY with plist CHANGES.
Return its fresh discovery record.  No import, store or executor initialization."
  (require 'pichat-job-definition)
  (let* ((data (with-temp-buffer
                 (insert-file-contents (expand-file-name
                                       "job-definitions/project-review.json"
                                       pichat-test-fixture-directory))
                 (json-parse-buffer :object-type 'plist)))
         (file (expand-file-name ".pi/jobs/job.json" directory)))
    (setf (plist-get data :model) "pichat-fake/pichat-fake")
    (while changes (setq data (plist-put data (pop changes) (pop changes))))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert (decode-coding-string (json-serialize data) 'utf-8)))
    (or (aref (plist-get (pichat-job-definition-discover nil directory) :definitions) 0)
        (error "Invalid authored test fixture"))))

(provide 'pichat-test-job-support)
;;; pichat-test-job-support.el ends here
