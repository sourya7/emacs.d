;;; pichat-test-support.el --- Test helpers for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared helpers for PiChat ERT tests.  Keep behavior expectations in tests;
;; this file should only contain mechanics.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'subr-x)
(require 'pichat)

(defvar pichat-test-include-integration nil
  "When non-nil, load and run real Pi integration tests.")

(defvar pichat-test-pi-executable "pi"
  "Pi executable used by integration tests.")

(defvar pichat-test-timeout 10
  "Default timeout in seconds for asynchronous test waits.")

(defvar pichat-test-keep-temp-dirs nil
  "When non-nil, do not delete integration test temp directories.")

(defconst pichat-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing PiChat tests.")

(defconst pichat-test-pichat-directory
  (file-name-directory (directory-file-name pichat-test-directory))
  "Directory containing PiChat source files.")

(defconst pichat-test-fixture-directory
  (expand-file-name "fixtures/" pichat-test-directory)
  "Directory containing sanitized PiChat test fixtures.")

(defun pichat-test-read-json-fixture (name)
  "Read sanitized JSON fixture NAME as plists and lists."
  (with-temp-buffer
    (insert-file-contents (expand-file-name name pichat-test-fixture-directory))
    (json-parse-buffer :object-type 'plist
                       :array-type 'list
                       :null-object nil
                       :false-object :json-false)))

(defun pichat-test--canonical-fixture-transcript ()
  "Return canonical transcript built from the sanitized session fixture."
  (let* ((fixture (pichat-test-read-json-fixture "canonical-session.json"))
         (cache (pichat-pi-entry-cache-full
                 (plist-get fixture :sessionId)
                 (plist-get fixture :sessionFile)
                 (plist-get fixture :entries)
                 (plist-get fixture :leafId))))
    (pichat-pi-build-canonical-transcript cache)))

(defun pichat-test--rpc-get-entries-callback (since callback)
  "Return callback from a shorthand or explicit get-entries call."
  (if (functionp since) since callback))

(defconst pichat-test-repository-directory
  (file-name-directory (directory-file-name pichat-test-pichat-directory))
  "Repository root directory.")

(defconst pichat-test-fake-provider-extension
  (expand-file-name "fixtures/fake-provider.ts" pichat-test-directory)
  "Fake provider extension fixture path.")

(defconst pichat-test-bridge-extension
  (expand-file-name "bridge/pichat-bridge.ts" pichat-test-pichat-directory)
  "Real PiChat bridge extension path.")

(defconst pichat-test-rpc-extension
  (expand-file-name "fixtures/rpc-test-extension.ts" pichat-test-directory)
  "Generic RPC extension fixture path.")

(defconst pichat-test-mutation-timing-extension
  (expand-file-name "fixtures/mutation-timing-extension.ts"
                    pichat-test-directory)
  "Real-Pi file-mutation timing fixture path.")

(defconst pichat-test-session-cancellation-extension
  (expand-file-name "fixtures/session-cancellation-extension.ts"
                    pichat-test-directory)
  "Real-Pi fork and switch cancellation fixture path.")

(defconst pichat-test-archive-extension
  (expand-file-name "fixtures/archive-package/extensions/archive.ts"
                    pichat-test-directory)
  "Standard-path archive capability integration fixture.")

(defconst pichat-test-archive-custom-extension
  (expand-file-name "fixtures/archive-package/extensions/archive-custom.ts"
                    pichat-test-directory)
  "Custom-path archive fixture which exposes no query marker.")

(defun pichat-test--hash-table-keys (table)
  "Return keys from hash TABLE."
  (let (keys)
    (maphash (lambda (key _value) (push key keys)) table)
    (nreverse keys)))

(defun pichat-test-reset-globals ()
  "Reset mutable PiChat global state between tests."
  (when-let ((manager (get-buffer "*PiChat Sessions*")))
    (kill-buffer manager))
  (when-let ((preview (get-buffer "*PiChat Runtime Preview*")))
    (kill-buffer preview))
  (setq pichat-current-session nil)
  (when (boundp 'pichat--manual-session-counter)
    (setq pichat--manual-session-counter 0))
  (when (boundp 'pichat--sessions-by-scope)
    (setq pichat--sessions-by-scope (make-hash-table :test #'equal)))
  (when (boundp 'pichat--sessions-by-id)
    (setq pichat--sessions-by-id (make-hash-table :test #'equal)))
  (when (boundp 'pichat--session-order)
    (setq pichat--session-order nil))
  (when (boundp 'pichat-session--runtime-counter)
    (setq pichat-session--runtime-counter 0))
  (when (boundp 'pichat--global-handlers)
    (setq pichat--global-handlers (make-hash-table :test #'eq)))
  (when (boundp 'pichat-tools-registry)
    (setq pichat-tools-registry (make-hash-table :test #'equal)))
  (when (boundp 'pichat-approval-rules)
    (setq pichat-approval-rules nil))
  (when (boundp 'pichat-approval-session-rules)
    (setq pichat-approval-session-rules
          (make-hash-table :test #'eq :weakness 'key)))
  (when (fboundp 'pichat-archive-reset)
    (pichat-archive-reset))
  (when (boundp 'pichat-sessions--summary-cache)
    (setq pichat-sessions--summary-cache (make-hash-table :test #'equal))))

(defmacro pichat-test-with-clean-state (&rest body)
  "Run BODY with PiChat globals reset before and after."
  (declare (indent 0) (debug t))
  `(unwind-protect
       (progn
         (pichat-test-reset-globals)
         ,@body)
     (pichat-test-reset-globals)))

(defmacro pichat-test-with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory while running BODY."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,var (file-name-as-directory (make-temp-file "pichat-test-" t))))
     (unwind-protect
         (progn ,@body)
       (unless pichat-test-keep-temp-dirs
         (ignore-errors (delete-directory ,var t))))))

(defun pichat-test--make-unit-process (session)
  "Return a live inert process associated with SESSION."
  (let ((proc (make-process :name "pichat-test-unit-rpc"
                            :buffer (generate-new-buffer " *pichat-test-unit-rpc*")
                            :command (list "sh" "-c" "cat >/dev/null")
                            :connection-type 'pipe
                            :sentinel #'pichat-rpc--process-sentinel
                            :noquery t)))
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'pichat-session session)
    (setf (pichat-session-process session) proc)
    proc))

(cl-defmacro pichat-test-with-unit-session ((session-var &optional process-var) &rest body)
  "Create an isolated SESSION-VAR for unit tests.
When PROCESS-VAR is non-nil, also create a live inert process."
  (declare (indent 1))
  `(pichat-test-with-clean-state
     (let* ((,session-var (pichat-session-make :cwd default-directory))
            ,@(when process-var
                `((,process-var (pichat-test--make-unit-process ,session-var)))))
       ,(if process-var
            `(unwind-protect
                 (progn ,@body)
               (when (process-live-p ,process-var)
                 (delete-process ,process-var))
               (when-let ((buf (process-buffer ,process-var)))
                 (when (buffer-live-p buf) (kill-buffer buf))))
          `(progn ,@body)))))

(defun pichat-test-wait-until (predicate &optional timeout description)
  "Wait until PREDICATE returns non-nil or TIMEOUT elapses.
DESCRIPTION is included in timeout failures."
  (let* ((deadline (+ (float-time) (or timeout pichat-test-timeout)))
         value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (unless value
      (ert-fail (format "Timed out waiting for %s" (or description "condition"))))
    value))

(defun pichat-test-recent-rpc-events (session &optional count)
  "Return recent raw RPC events for SESSION."
  (let ((events (reverse (or (pichat-session-event-log session) nil))))
    (if count (last events (min count (length events))) events)))

(defun pichat-test-count-raw-events (session type)
  "Return the number of raw RPC events of TYPE in SESSION."
  (cl-count-if (lambda (event) (equal (plist-get event :type) type))
               (or (pichat-session-event-log session) nil)))

(defun pichat-test-wait-for-raw-event (session type &optional timeout after-count)
  "Wait for raw RPC event TYPE in SESSION and return it.
When AFTER-COUNT is non-nil, wait until more than AFTER-COUNT matching events
have been seen."
  (pichat-test-wait-until
   (lambda ()
     (let ((seen 0)
           found)
       (dolist (event (pichat-test-recent-rpc-events session))
         (when (equal (plist-get event :type) type)
           (cl-incf seen)
           (when (> seen (or after-count 0))
             (setq found event))))
       found))
   timeout
   (format "raw event %s after %S; recent events=%S pending=%S remainder=%S state=%S"
           type after-count
           (pichat-test-recent-rpc-events session 10)
           (pichat-test--hash-table-keys (pichat-session-pending-responses session))
           (pichat-session-rpc-receive-buffer session)
           (pichat-session-state session))))

(defun pichat-test-rpc-call (session type &optional payload timeout)
  "Send TYPE/PAYLOAD to SESSION and wait for the RPC response."
  (let (result)
    (pichat-rpc-send
     session type payload
     (lambda (response _session)
       (setq result (list :ok response)))
     (lambda (response _session)
       (setq result (list :error response))))
    (pichat-test-wait-until
     (lambda () result)
     timeout
     (format "RPC response for %s; recent events=%S pending=%S remainder=%S state=%S"
             type
             (pichat-test-recent-rpc-events session 10)
             (pichat-test--hash-table-keys (pichat-session-pending-responses session))
             (pichat-session-rpc-receive-buffer session)
             (pichat-session-state session)))
    (pcase (plist-get result :ok)
      ((and response (pred identity)) response)
      (_ (ert-fail (format "RPC %s failed: %S" type (plist-get result :error)))))))

(defun pichat-test-prompt-and-wait (session message &optional timeout)
  "Prompt SESSION with MESSAGE and wait until the run is settled."
  (let ((settled-count (pichat-test-count-raw-events session "agent_settled"))
        (response (pichat-test-rpc-call session "prompt" (list :message message) timeout)))
    (pichat-test-wait-for-raw-event session "agent_settled" timeout settled-count)
    response))

(defun pichat-test-chat-send-current-and-wait (session buffer &optional timeout)
  "Send current input in PiChat BUFFER and wait for SESSION to settle."
  (let ((settled-count (pichat-test-count-raw-events session "agent_settled")))
    (with-current-buffer buffer
      (goto-char (point-max))
      (pichat-chat-send-input))
    (pichat-test-wait-for-raw-event session "agent_settled" timeout settled-count)))

(defun pichat-test-chat-send-and-wait (session buffer text &optional timeout)
  "Insert TEXT in PiChat BUFFER, send it, and wait for SESSION to settle."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text))
  (pichat-test-chat-send-current-and-wait session buffer timeout))

(defun pichat-test-buffer-text (buffer)
  "Return BUFFER text without properties."
  (with-current-buffer buffer
    (buffer-substring-no-properties (point-min) (point-max))))

(defun pichat-test-wait-for-buffer-contains (buffer needle &optional timeout)
  "Wait until BUFFER contains NEEDLE."
  (pichat-test-wait-until
   (lambda ()
     (and (buffer-live-p buffer)
          (string-match-p (regexp-quote needle) (pichat-test-buffer-text buffer))))
   timeout
   (format "buffer %S to contain %S; text=%S" buffer needle
           (and (buffer-live-p buffer) (pichat-test-buffer-text buffer)))))

(defun pichat-test-require-pi ()
  "Fail unless the configured Pi executable is available."
  (unless (executable-find pichat-test-pi-executable)
    (ert-fail (format "Full integration requested but Pi executable is unavailable: %s"
                      pichat-test-pi-executable))))

(defun pichat-test-pi-version ()
  "Return `pi --version' output for diagnostics."
  (with-temp-buffer
    (let ((status (call-process pichat-test-pi-executable nil t nil "--version")))
      (format "status=%S output=%s" status (string-trim (buffer-string))))))

(defun pichat-test-count-substring (needle haystack)
  "Return number of non-overlapping NEEDLE occurrences in HAYSTACK."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) haystack start)
      (setq start (match-end 0))
      (cl-incf count))
    count))

(defun pichat-test-provider-status (status-file)
  "Return parsed fake-provider STATUS-FILE, or nil while unavailable."
  (when (file-exists-p status-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents status-file)
          (json-parse-buffer :object-type 'plist
                             :array-type 'list
                             :null-object nil
                             :false-object nil))
      (error nil))))

(defun pichat-test-assert-provider-script-consumed (status-file)
  "Assert fake provider STATUS-FILE reports a fully consumed clean script."
  (let ((status
         (pichat-test-wait-until
          (lambda ()
            (let ((value (pichat-test-provider-status status-file)))
              (when (or (plist-get value :consumedAll)
                        (> (or (plist-get value :unexpectedCalls) 0) 0))
                value)))
          2
          (format "fake provider script consumption in %s" status-file))))
    (should (plist-get status :consumedAll))
    (should (= 0 (or (plist-get status :unexpectedCalls) 0)))))

(cl-defmacro pichat-test-with-integration-session
    ((session-var &key script no-session extensions settings) &rest body)
  "Start real Pi RPC bound to SESSION-VAR and run BODY.
SCRIPT is a Lisp object encoded as the fake provider script JSON.
When NO-SESSION is nil, persistent sessions are enabled in an isolated dir.
EXTENSIONS is a list of additional extension file paths loaded after the fake
provider.  SETTINGS, when non-nil, is written to the isolated Pi agent dir."
  (declare (indent 1))
  `(progn
     (pichat-test-require-pi)
     (pichat-test-with-clean-state
       (pichat-test-with-temp-dir project-dir
         (pichat-test-with-temp-dir agent-dir
           (pichat-test-with-temp-dir session-dir
             (let* ((script-file (expand-file-name "fake-provider-script.json" project-dir))
                    (status-file (expand-file-name "fake-provider-status.json" project-dir))
                    (process-environment
                     (append (list "PI_OFFLINE=1"
                                   "PI_SKIP_VERSION_CHECK=1"
                                   "PI_TELEMETRY=0"
                                   (concat "PI_CODING_AGENT_DIR=" agent-dir)
                                   (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                                   (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-file)
                                   (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-file))
                             process-environment))
                    (pichat-rpc-command
                     (append (list pichat-test-pi-executable
                                   "--mode" "rpc"
                                   "--offline"
                                   "--no-approve"
                                   "--no-builtin-tools"
                                   "--no-context-files"
                                   "--no-skills"
                                   "--no-prompt-templates"
                                   "--no-themes"
                                   "--no-extensions")
                             (when ,no-session (list "--no-session"))
                             (unless ,no-session (list "--session-dir" session-dir))
                             (list "-e" pichat-test-fake-provider-extension)
                             (cl-mapcan (lambda (extension) (list "-e" extension))
                                        ,extensions)
                             (list "--model" "pichat-fake/pichat-fake")))
                    (,session-var nil))
               (with-temp-file script-file
                 (insert (json-serialize ,script
                                         :false-object :json-false
                                         :null-object nil)))
               (when ,settings
                 (with-temp-file (expand-file-name "settings.json" agent-dir)
                   (insert (json-serialize ,settings
                                           :false-object :json-false
                                           :null-object nil))))
               (unwind-protect
                   (let ((default-directory project-dir))
                     (message "PiChat integration using %s" (pichat-test-pi-version))
                     (setq ,session-var (pichat-start-session project-dir))
                     (pichat-test-rpc-call ,session-var "get_state")
                     (pichat-test-rpc-call ,session-var "set_auto_retry" (list :enabled :json-false))
                     (pichat-test-rpc-call ,session-var "set_auto_compaction" (list :enabled :json-false))
                     (prog1 (progn ,@body)
                       (pichat-test-assert-provider-script-consumed status-file)))
                 (when ,session-var
                   (ignore-errors (pichat-rpc-stop ,session-var))
                   (when-let ((proc (pichat-session-process ,session-var)))
                     (when (process-live-p proc) (delete-process proc))
                     (when-let ((buf (process-buffer proc)))
                       (when (buffer-live-p buf) (kill-buffer buf)))))))))))))

(provide 'pichat-test-support)
;;; pichat-test-support.el ends here
