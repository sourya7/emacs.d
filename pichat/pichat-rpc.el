;;; pichat-rpc.el --- Pi JSONL RPC client -*- lexical-binding: t; -*-

;;; Commentary:

;; Strict LF-delimited JSONL client for `pi --mode rpc'.  This module owns
;; process startup, request/response correlation, and raw event normalization.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-events)
(require 'pichat-path)
(require 'pichat-transport)
(require 'pichat-chat-diagnostics)

(defcustom pichat-pi-executable "pi"
  "Pi executable used when `pichat-rpc-command' is nil."
  :type 'string
  :group 'pichat)

(defcustom pichat-pi-default-args '("--mode" "rpc")
  "Default arguments for starting Pi RPC."
  :type '(repeat string)
  :group 'pichat)

(defcustom pichat-default-model nil
  "Default Pi model passed to plain Pi RPC processes at startup.
The value is passed as the argument to `--model'.  A provider-qualified value,
such as `anthropic/claude-sonnet-4-5', avoids ambiguous model matches.

This setting is ignored when `pichat-rpc-command' is non-nil because that
variable supplies the complete process command.  A later `--model' in
`pichat-pi-extra-args' takes precedence according to Pi's argument parsing."
  :type '(choice (const :tag "Use Pi's configured default" nil)
                 (string :tag "Provider/model"))
  :group 'pichat)

(defcustom pichat-pi-session-dir nil
  "Optional Pi session directory."
  :type '(choice (const :tag "Default" nil) directory)
  :group 'pichat)

(defcustom pichat-pi-extra-args nil
  "Additional arguments passed to Pi after `pichat-pi-default-args'."
  :type '(repeat string)
  :group 'pichat)

(defcustom pichat-bridge-extension-file nil
  "Optional path to the PiChat bridge extension loaded with `-e'."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'pichat)

(defcustom pichat-rpc-command nil
  "Complete argv list used to start Pi RPC.
When non-nil, this overrides `pichat-pi-executable' and related Pi argument
customizations.  This is a legacy hook for Docker and custom local wrappers;
use `pichat-targets' for SSH/TRAMP runtimes.

Example value:
  docker run --rm -i -v HOST:CONTAINER -w /workspace IMAGE pi --mode rpc.

Do not allocate a TTY for JSONL transports."
  :type '(choice (const :tag "Build from Pi settings" nil)
                 (repeat string))
  :group 'pichat)

(defcustom pichat-rpc-request-timeout nil
  "Optional timeout in seconds for Pi RPC command responses.
When nil, requests do not time out.  Timed-out requests are removed from the
pending table and dispatch their error callback, or emit an error event when no
error callback was supplied."
  :type '(choice (const :tag "No timeout" nil) number)
  :group 'pichat)

(defcustom pichat-rpc-remote-startup-delay 0.75
  "Maximum grace period before sending queued RPC input to a new SSH process.
The shared-shell TRAMP process handler can return just before the remote `exec'
is consuming stdin.  Any earlier process output releases the queue immediately."
  :type 'number
  :group 'pichat)

(defcustom pichat-rpc-event-log-limit 500
  "Maximum number of recent raw Pi events retained per session.
Set to nil to retain all events."
  :type '(choice (const :tag "Unlimited" nil) positive-integer)
  :group 'pichat)

(defconst pichat-rpc--event-map
  '(("agent_start" . agent-start)
    ("agent_end" . agent-end)
    ("agent_settled" . agent-settled)
    ("turn_start" . turn-start)
    ("turn_end" . turn-end)
    ("message_start" . message-start)
    ("message_update" . message-update)
    ("message_end" . message-end)
    ("tool_execution_start" . tool-start)
    ("tool_execution_update" . tool-update)
    ("tool_execution_end" . tool-end)
    ("queue_update" . queue-update)
    ("compaction_start" . compaction-start)
    ("compaction_end" . compaction-end)
    ("auto_retry_start" . retry-start)
    ("auto_retry_end" . retry-end)
    ("extension_ui_request" . extension-ui-request)
    ("extension_error" . extension-error))
  "Mapping from Pi RPC event type strings to PiChat event symbols.")

(defun pichat-rpc-normalize-launch-options (&optional launch-options)
  "Return validated low-level LAUNCH-OPTIONS.
Supported keys are `:persistence' and the optional exact `:model' reference.
A complete `pichat-rpc-command' cannot safely be amended for either option."
  (let ((persistence (or (plist-get launch-options :persistence) 'persistent))
        (model (plist-get launch-options :model))
        (structured-p (plist-get launch-options :structured-transport)))
    (unless (memq persistence '(persistent ephemeral))
      (user-error "Invalid PiChat persistence: %S" persistence))
    (unless (or (null model)
                (and (stringp model) (not (string-blank-p model))))
      (user-error "Invalid PiChat startup model: %S" model))
    (when (and (eq persistence 'ephemeral) pichat-rpc-command
               (not structured-p))
      (user-error
       "Ephemeral PiChat runtimes are not yet supported with `pichat-rpc-command'"))
    (when (and model pichat-rpc-command (not structured-p))
      (user-error
       "Run-local PiChat models are not yet supported with `pichat-rpc-command'"))
    (list :persistence persistence :model model)))

(defun pichat-rpc-build-command (&optional session)
  "Return argv list for starting Pi RPC for optional SESSION.
The exact session metadata controls `--no-session' and a run-local `--model'.
User extra arguments remain late, while a run-local model remains authoritative."
  (let* ((persistence (if session
                          (pichat-session-persistence session)
                        'persistent))
         (startup-model (and session (pichat-session-startup-model session)))
         (transport (and session (pichat-session-transport session)))
         (remote-p (and transport
                        (eq (pichat-transport-kind transport) 'ssh)))
         (executable (or (and transport
                              (pichat-transport-pi-executable transport))
                         pichat-pi-executable)))
    (pichat-rpc-normalize-launch-options
     (list :persistence persistence :model startup-model
           :structured-transport remote-p))
    (or (and (not remote-p) pichat-rpc-command)
        (append (list executable)
                pichat-pi-default-args
                (and transport (pichat-transport-pi-args transport))
                (when (and (not remote-p)
                           (not startup-model)
                           (stringp pichat-default-model)
                           (not (string-blank-p pichat-default-model)))
                  (list "--model" pichat-default-model))
                (when (and (not remote-p) pichat-pi-session-dir)
                  (list "--session-dir" pichat-pi-session-dir))
                (when (and (not remote-p) pichat-bridge-extension-file)
                  (list "-e" pichat-bridge-extension-file))
                (when (eq persistence 'ephemeral)
                  (list "--no-session"))
                (unless remote-p pichat-pi-extra-args)
                ;; The per-run selection must override any generic model in
                ;; `pichat-pi-extra-args' without changing that customization.
                (when startup-model
                  (list "--model" startup-model))))))

(defun pichat-rpc--json-encode (object)
  "Encode OBJECT as compact JSON."
  (json-serialize object :false-object :json-false :null-object nil))

(defun pichat-rpc--json-decode (string)
  "Decode JSON STRING into plists/lists."
  (json-parse-string string
                     :object-type 'plist
                     :array-type 'list
                     :null-object nil
                     :false-object nil))

(defun pichat-rpc--next-id (session)
  "Return next request id for SESSION."
  (let ((n (1+ (or (pichat-session-rpc-seq session) 0))))
    (setf (pichat-session-rpc-seq session) n)
    (format "pichat-%d" n)))

(defun pichat-rpc--mark-ready (session process)
  "Mark PROCESS ready for SESSION and flush queued JSONL in order."
  (when (and (eq process (pichat-session-process session))
             (process-live-p process)
             (not (pichat-session-rpc-ready-p session)))
    (when (timerp (pichat-session-rpc-ready-timer session))
      (cancel-timer (pichat-session-rpc-ready-timer session)))
    (let ((queue (nreverse (pichat-session-rpc-send-queue session))))
      (setf (pichat-session-rpc-ready-p session) t
            (pichat-session-rpc-ready-timer session) nil
            (pichat-session-rpc-send-queue session) nil)
      (dolist (line queue)
        (process-send-string process line)))))

(defun pichat-rpc--remote-ready-timeout (session process)
  "Release SESSION's startup queue for still-current remote PROCESS."
  (pichat-rpc--mark-ready session process))

(defun pichat-rpc-start (session)
  "Start the Pi RPC process for SESSION and return SESSION.
A local startup failure is retained as an inspectable diagnostic and leaves
SESSION in `error' state rather than being confused with a Pi RPC response."
  (let* ((argv (pichat-rpc-build-command session))
         (program (car argv))
         (args (cdr argv))
         (transport (pichat-session-transport session))
         (runtime-cwd (or (pichat-session-runtime-cwd session)
                          (pichat-session-cwd session)
                          default-directory))
         buffer stderr-buffer)
    (setf (pichat-session-stop-requested-p session) nil
          (pichat-session-rpc-command session) argv
          (pichat-session-rpc-ready-p session)
          (not (eq (pichat-transport-kind transport) 'ssh))
          (pichat-session-rpc-send-queue session) nil
          (pichat-session-rpc-ready-timer session) nil
          (pichat-session-state session) 'starting)
    (condition-case condition
        (progn
          (unless (and (stringp program) (not (string-empty-p program)))
            (signal 'file-error '("Empty Pi RPC command")))
          (setq buffer (generate-new-buffer " *pichat-rpc*")
                stderr-buffer (generate-new-buffer " *pichat-rpc-stderr*"))
          (let ((proc (pichat-transport-make-process
                       transport runtime-cwd
                       :name "pichat-rpc"
                       :buffer buffer
                       :stderr stderr-buffer
                       :command argv
                       :filter #'pichat-rpc--process-filter
                       :sentinel #'pichat-rpc--process-sentinel)))
            (set-process-query-on-exit-flag proc nil)
            (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
            (process-put proc 'pichat-session session)
            (setf (pichat-session-process session) proc
                  (pichat-session-stderr-buffer session) stderr-buffer)
            (when (eq (pichat-transport-kind transport) 'ssh)
              (setf (pichat-session-rpc-ready-timer session)
                    (run-at-time pichat-rpc-remote-startup-delay nil
                                 #'pichat-rpc--remote-ready-timeout
                                 session proc)))
            (pichat-emit session 'session-started
                         :command argv :program program :args args)))
      (error
       (dolist (transport-buffer (list buffer stderr-buffer))
         (when (buffer-live-p transport-buffer) (kill-buffer transport-buffer)))
       (setf (pichat-session-process session) nil
             (pichat-session-stderr-buffer session) nil
             (pichat-session-state session) 'error)
       (let ((diagnostic
              (pichat-chat-diagnostics-record
               session :origin 'process-start
               :message (error-message-string condition)
               :condition condition :program program :command argv)))
         (pichat-emit session 'error
                      :message (plist-get diagnostic :summary)
                      :diagnostic diagnostic)
         (pichat-emit session 'session-ended
                      :reason 'error :diagnostic diagnostic))))
    session))

(defun pichat-rpc-stop (session)
  "Stop SESSION's Pi RPC process."
  (when (timerp (pichat-session-rpc-ready-timer session))
    (cancel-timer (pichat-session-rpc-ready-timer session)))
  (setf (pichat-session-stop-requested-p session) t
        (pichat-session-rpc-ready-timer session) nil
        (pichat-session-rpc-send-queue session) nil)
  (if-let ((proc (pichat-session-process session)))
      (if (process-live-p proc)
          ;; The process sentinel emits `session-ended'.
          (delete-process proc)
        (unless (eq (pichat-session-state session) 'error)
          (setf (pichat-session-state session) 'stopped)
          (pichat-emit session 'session-ended :reason 'stopped)))
    (setf (pichat-session-state session) 'stopped)
    (pichat-emit session 'session-ended :reason 'stopped)))

(defun pichat-rpc--buffer-string (buffer &optional limit)
  "Return trimmed contents of live BUFFER, or nil when empty.
When LIMIT is non-nil, copy at most LIMIT leading characters."
  (when (buffer-live-p buffer)
    (let ((text
           (string-trim
            (with-current-buffer buffer
              (buffer-substring-no-properties
               (point-min)
               (if limit
                   (min (point-max) (+ (point-min) limit))
                 (point-max)))))))
      (unless (string-empty-p text) text))))

(defun pichat-rpc--process-sentinel (process event)
  "Handle PROCESS lifecycle EVENT and clean its hidden transport buffers."
  (unless (process-live-p process)
    (when-let ((session (process-get process 'pichat-session)))
      (when (timerp (pichat-session-rpc-ready-timer session))
        (cancel-timer (pichat-session-rpc-ready-timer session)))
      (setf (pichat-session-rpc-ready-timer session) nil
            (pichat-session-rpc-send-queue session) nil)
      (let* ((intentional (pichat-session-stop-requested-p session))
             (stderr (pichat-rpc--buffer-string
                      (pichat-session-stderr-buffer session)
                      (1+ pichat-diagnostics-stderr-limit)))
             (reason (if intentional 'stopped 'error))
             (exit-status (process-exit-status process))
             (diagnostic
              (unless intentional
                (pichat-chat-diagnostics-record
                 session :origin 'process-exit
                 :message (format "Pi RPC process %s" (string-trim event))
                 :stderr stderr :exit-status exit-status
                 :command (pichat-session-rpc-command session)))))
        (pichat-rpc--fail-pending
         session
         (format "Pi RPC process %s" (string-trim event))
         (if intentional 'cancelled 'process))
        (setf (pichat-session-state session) reason)
        (unless intentional
          (pichat-emit session 'error
                       :message (plist-get diagnostic :summary)
                       :diagnostic diagnostic))
        (pichat-emit session 'session-ended
                     :reason reason :event (string-trim event)
                     :diagnostic diagnostic)))
    (dolist (buffer (list (process-buffer process)
                          (when-let ((session (process-get process 'pichat-session)))
                            (pichat-session-stderr-buffer session))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun pichat-rpc--process-filter (process chunk)
  "Handle PROCESS output CHUNK.
Records are split only on LF, preserving JSON strings containing Unicode line
separator characters.  A trailing CR is stripped for CRLF compatibility."
  (when-let ((session (process-get process 'pichat-session)))
    (pichat-rpc--mark-ready session process)
    (let ((buf (concat (or (pichat-session-rpc-receive-buffer session) "") chunk))
          line)
      (while (string-match "\n" buf)
        (setq line (substring buf 0 (match-beginning 0))
              buf (substring buf (match-end 0)))
        (when (string-suffix-p "\r" line)
          (setq line (substring line 0 -1)))
        (unless (string-empty-p line)
          (pichat-rpc--handle-line session line)))
      (setf (pichat-session-rpc-receive-buffer session) buf))))

(defun pichat-rpc--handle-line (session line)
  "Parse and dispatch one JSONL LINE for SESSION."
  (condition-case err
      (pichat-rpc--dispatch-object session (pichat-rpc--json-decode line))
    (error
     (let ((diagnostic
            (pichat-chat-diagnostics-record
             session :origin 'rpc-parse :message "Failed to parse Pi RPC output"
             :condition err :response line)))
       (pichat-emit session 'error
                    :message (plist-get diagnostic :summary)
                    :diagnostic diagnostic)))))

(defun pichat-rpc--dispatch-object (session object)
  "Dispatch decoded RPC OBJECT for SESSION."
  (let ((type (plist-get object :type)))
    (cond
     ((string= type "response")
      (pichat-rpc--dispatch-response session object))
     (t
      (pichat-rpc--dispatch-event session object)))))

(defun pichat-rpc--pending-plist-p (pending)
  "Return non-nil when PENDING is the current plist request entry shape."
  (and (consp pending) (keywordp (car pending))))

(defun pichat-rpc--pending-callback (pending)
  "Return success callback from PENDING request entry."
  (if (pichat-rpc--pending-plist-p pending)
      (plist-get pending :callback)
    (car pending)))

(defun pichat-rpc--pending-error-callback (pending)
  "Return error callback from PENDING request entry."
  (if (pichat-rpc--pending-plist-p pending)
      (plist-get pending :error-callback)
    (cdr pending)))

(defun pichat-rpc--pending-command (pending)
  "Return command name from PENDING request entry."
  (and (pichat-rpc--pending-plist-p pending)
       (plist-get pending :command)))

(defun pichat-rpc--pending-timer (pending)
  "Return timeout timer from PENDING request entry."
  (and (pichat-rpc--pending-plist-p pending)
       (plist-get pending :timer)))

(defun pichat-rpc--cancel-pending-timer (pending)
  "Cancel PENDING request timeout timer, if any."
  (when-let ((timer (pichat-rpc--pending-timer pending)))
    (when (timerp timer)
      (cancel-timer timer))))

(defun pichat-rpc--dispatch-failure (session response pending)
  "Dispatch failed RESPONSE for PENDING request in SESSION."
  (if-let ((error-callback (pichat-rpc--pending-error-callback pending)))
      (funcall error-callback response session)
    (let ((diagnostic (plist-get response :pichat-diagnostic)))
      (pichat-emit session 'error
                   :message (or (plist-get diagnostic :summary)
                                (pichat-chat-diagnostics-safe-summary-text
                                 (plist-get response :error)))
                   :response response
                   :diagnostic diagnostic))))

(defun pichat-rpc-cancel-request (session id)
  "Silently cancel pending request ID and its timer in SESSION."
  (when-let ((pending (and id
                           (gethash id
                                    (pichat-session-pending-responses
                                     session)))))
    (remhash id (pichat-session-pending-responses session))
    (pichat-rpc--cancel-pending-timer pending)
    t))

(defun pichat-rpc--timeout-request (session id)
  "Fail pending request ID in SESSION because it timed out."
  (when-let ((pending (gethash id (pichat-session-pending-responses session))))
    (remhash id (pichat-session-pending-responses session))
    (let* ((response (list :type "response"
                           :id id
                           :command (pichat-rpc--pending-command pending)
                           :success nil
                           :pichat-failure-kind 'timeout
                           :error (format "Pi RPC request %s timed out" id)))
           (diagnostic
            (pichat-chat-diagnostics-record
             session :origin 'rpc-timeout :message (plist-get response :error)
             :response response :command (pichat-rpc--pending-command pending))))
      (setq response (plist-put response :pichat-diagnostic diagnostic))
      (pichat-emit session 'response-received :response response)
      (pichat-rpc--dispatch-failure session response pending))))

(defun pichat-rpc--fail-pending (session reason &optional failure-kind)
  "Fail all pending SESSION requests with REASON.
FAILURE-KIND is the machine-readable local failure cause."
  (let (pending-entries)
    (maphash (lambda (id pending)
               (push (cons id pending) pending-entries))
             (pichat-session-pending-responses session))
    (clrhash (pichat-session-pending-responses session))
    (dolist (entry pending-entries)
      (let* ((id (car entry))
             (pending (cdr entry))
             (response (list :type "response"
                             :id id
                             :command (pichat-rpc--pending-command pending)
                             :success nil
                             :pichat-failure-kind failure-kind
                             :error reason)))
        (pichat-rpc--cancel-pending-timer pending)
        (pichat-emit session 'response-received :response response)
        (pichat-rpc--dispatch-failure session response pending)))))

(defun pichat-rpc--cancel-pending-command (session command except-id)
  "Cancel pending COMMAND requests in SESSION other than EXCEPT-ID."
  (let (entries)
    (maphash
     (lambda (id pending)
       (when (and (not (equal id except-id))
                  (equal command (pichat-rpc--pending-command pending)))
         (push (cons id pending) entries)))
     (pichat-session-pending-responses session))
    (dolist (entry entries)
      (let* ((id (car entry))
             (pending (cdr entry))
             (response (list :type "response" :id id :command command
                             :success nil
                             :pichat-failure-kind 'cancelled
                             :error "Superseded by session rebind")))
        (remhash id (pichat-session-pending-responses session))
        (pichat-rpc--cancel-pending-timer pending)
        (pichat-emit session 'response-received :response response)
        (when-let ((error-callback
                    (pichat-rpc--pending-error-callback pending)))
          (funcall error-callback response session))))))

(defun pichat-rpc--dispatch-response (session response)
  "Dispatch RPC RESPONSE for SESSION."
  (unless (plist-get response :success)
    (let ((diagnostic
           (pichat-chat-diagnostics-record
            session :origin 'rpc-response
            :message (plist-get response :error) :response response
            :command (plist-get response :command))))
      (setq response (plist-put response :pichat-diagnostic diagnostic))))
  (let* ((id (plist-get response :id))
         (pending (and id (gethash id (pichat-session-pending-responses session))))
         (success (plist-get response :success)))
    (when id
      (remhash id (pichat-session-pending-responses session)))
    (when pending
      (pichat-rpc--cancel-pending-timer pending))
    (pichat-emit session 'response-received :response response)
    (let ((command (or (plist-get response :command)
                       (pichat-rpc--pending-command pending))))
      (when (and success
                 (not (plist-get (plist-get response :data) :cancelled))
                 (member command '("new_session" "switch_session"
                                   "fork" "clone")))
        ;; Stale state and stats replies from before the rebind must neither
        ;; mutate the session nor satisfy consumers waiting for the new
        ;; identity.
        (pichat-rpc--cancel-pending-command session "get_state" id)
        (pichat-rpc--cancel-pending-command session "get_session_stats" id)
        (setf (pichat-session-context-usage session) nil)
        ;; Invalidate consumers before command callbacks can request state for
        ;; the newly rebound session.
        (pichat-emit session 'session-rebinding :command command
                     :response response)))
    (when (and success pending)
      (pcase (or (plist-get response :command)
                 (pichat-rpc--pending-command pending))
        ("get_state"
         (pichat-session-apply-rpc-state session (plist-get response :data))
         (pichat-emit session 'session-state-changed :state (plist-get response :data)))
        ("get_session_stats"
         (pichat-session-apply-rpc-stats session (plist-get response :data)))))
    (when pending
      (if success
          (let ((callback (pichat-rpc--pending-callback pending)))
            (when callback
              (funcall callback response session)))
        (pichat-rpc--dispatch-failure session response pending)))))

(defun pichat-rpc--dispatch-event (session event)
  "Normalize and emit RPC EVENT for SESSION."
  (let* ((type (plist-get event :type))
         (event-symbol
          (if (stringp type)
              (or (cdr (assoc type pichat-rpc--event-map))
                  (intern (replace-regexp-in-string "_" "-" type)))
            'unknown-rpc-event))
         ;; Reserve `rpc-event' for the exactly-once generic notification.
         (normalized (if (eq event-symbol 'rpc-event)
                         'pi-rpc-event
                       event-symbol)))
    (push event (pichat-session-event-log session))
    (when (and pichat-rpc-event-log-limit
               (> (length (pichat-session-event-log session))
                  pichat-rpc-event-log-limit))
      (setcdr (nthcdr (1- pichat-rpc-event-log-limit)
                      (pichat-session-event-log session))
              nil))
    (pcase normalized
      ('agent-start
       (setf (pichat-session-streaming-p session) t
             (pichat-session-state session) 'running))
      ('agent-settled
       (setf (pichat-session-streaming-p session) nil
             (pichat-session-compacting-p session) nil
             (pichat-session-retrying-p session) nil
             (pichat-session-state session) 'idle))
      ('compaction-start
       (setf (pichat-session-compacting-p session) t
             (pichat-session-state session) 'compacting))
      ('compaction-end
       (setf (pichat-session-compacting-p session) nil
             (pichat-session-state session)
             (if (pichat-session-streaming-p session) 'running 'idle)))
      ('retry-start
       (setf (pichat-session-retrying-p session) t
             (pichat-session-state session) 'retrying))
      ('retry-end
       (setf (pichat-session-retrying-p session) nil
             (pichat-session-state session)
             (if (pichat-session-streaming-p session) 'running 'idle))))
    ;; Generic consumers see updated session state before the compatibility
    ;; event.  A consumer must subscribe to one form, never both.
    (pichat-emit session 'rpc-event
                 :raw event :normalized-event normalized)
    (pichat-emit session normalized :raw event)))

;;;###autoload
(defun pichat-rpc-send (session type payload callback &optional error-callback)
  "Send RPC command TYPE with PAYLOAD for SESSION.
CALLBACK and ERROR-CALLBACK receive (RESPONSE SESSION).  Return request id."
  (unless (pichat-session-alive-p session)
    (error "PiChat RPC process is not alive"))
  (let* ((id (pichat-rpc--next-id session))
         (command (append (list :id id :type type) payload))
         (line (concat (pichat-rpc--json-encode command) "\n"))
         (pending (list :callback callback
                        :error-callback error-callback
                        :command type)))
    (when (and pichat-rpc-request-timeout (> pichat-rpc-request-timeout 0))
      (setq pending (plist-put pending :timer
                               (run-at-time pichat-rpc-request-timeout nil
                                            #'pichat-rpc--timeout-request
                                            session id))))
    (puthash id pending (pichat-session-pending-responses session))
    (if (pichat-session-rpc-ready-p session)
        (process-send-string (pichat-session-process session) line)
      (push line (pichat-session-rpc-send-queue session)))
    id))

(defun pichat-rpc-send-notification (session payload)
  "Send raw notification PAYLOAD without request id to SESSION."
  (unless (pichat-session-alive-p session)
    (error "PiChat RPC process is not alive"))
  (let ((line (concat (pichat-rpc--json-encode payload) "\n")))
    (if (pichat-session-rpc-ready-p session)
        (process-send-string (pichat-session-process session) line)
      (push line (pichat-session-rpc-send-queue session)))))

(defun pichat-rpc-extension-ui-value (session request-id value)
  "Respond to extension UI REQUEST-ID with string VALUE."
  (pichat-rpc-send-notification session (list :type "extension_ui_response"
                                              :id request-id
                                              :value value)))

(defun pichat-rpc-extension-ui-confirm (session request-id confirmed)
  "Respond to extension UI REQUEST-ID with CONFIRMED boolean."
  (pichat-rpc-send-notification session (list :type "extension_ui_response"
                                              :id request-id
                                              :confirmed (if confirmed t :json-false))))

(defun pichat-rpc-extension-ui-cancel (session request-id)
  "Cancel extension UI REQUEST-ID."
  (pichat-rpc-send-notification session (list :type "extension_ui_response"
                                              :id request-id
                                              :cancelled t)))

;; Convenience command wrappers.

(defun pichat-rpc-prompt (session message &optional images streaming-behavior cb error-callback)
  "Send MESSAGE prompt to SESSION.
CB and ERROR-CALLBACK receive (RESPONSE SESSION)."
  (pichat-rpc-send session "prompt"
                   (append (list :message message)
                           (when images (list :images images))
                           (when streaming-behavior (list :streamingBehavior streaming-behavior)))
                   cb error-callback))

(defun pichat-rpc-steer (session message &optional images cb)
  "Queue steering MESSAGE for SESSION."
  (pichat-rpc-send session "steer" (append (list :message message) (when images (list :images images))) cb))

(defun pichat-rpc-follow-up (session message &optional images cb)
  "Queue follow-up MESSAGE for SESSION."
  (pichat-rpc-send session "follow_up" (append (list :message message) (when images (list :images images))) cb))

(defun pichat-rpc-set-steering-mode (session mode cb)
  "Set SESSION steering queue MODE to `all' or `one-at-a-time'."
  (pichat-rpc-send session "set_steering_mode" (list :mode mode) cb))

(defun pichat-rpc-set-follow-up-mode (session mode cb)
  "Set SESSION follow-up queue MODE to `all' or `one-at-a-time'."
  (pichat-rpc-send session "set_follow_up_mode" (list :mode mode) cb))

(defun pichat-rpc-abort (session &optional cb)
  "Abort current SESSION run."
  (pichat-rpc-send session "abort" nil cb))

(defun pichat-rpc-abort-retry (session &optional cb)
  "Abort SESSION's active automatic retry delay."
  (pichat-rpc-send session "abort_retry" nil cb))

(defun pichat-rpc-new-session (session &optional cb parent-session)
  "Start a new Pi session."
  (pichat-rpc-send session "new_session" (when parent-session (list :parentSession parent-session)) cb))

(defun pichat-rpc-cycle-model (session cb)
  "Cycle SESSION model."
  (pichat-rpc-send session "cycle_model" nil cb))

(defun pichat-rpc-get-state (session callback &optional error-callback)
  "Get state for SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "get_state" nil callback error-callback))

(defun pichat-rpc-get-messages (session cb)
  "Get messages for SESSION."
  (pichat-rpc-send session "get_messages" nil cb))

(defun pichat-rpc-get-entries (session &optional since cb error-callback)
  "Get session entries for SESSION since SINCE.
CB and ERROR-CALLBACK receive (RESPONSE SESSION).  When called as
(pichat-rpc-get-entries SESSION CALLBACK), SINCE is omitted."
  (when (functionp since)
    (setq error-callback cb
          cb since
          since nil))
  (pichat-rpc-send session "get_entries" (when since (list :since since))
                   cb error-callback))

(defun pichat-rpc-get-tree (session callback &optional error-callback)
  "Get session tree for SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "get_tree" nil callback error-callback))

(defun pichat-rpc-switch-session (session path callback &optional error-callback)
  "Switch SESSION to session file PATH.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "switch_session" (list :sessionPath path)
                   callback error-callback))

(defun pichat-rpc-fork (session entry-id callback &optional error-callback)
  "Fork SESSION at ENTRY-ID.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "fork" (list :entryId entry-id)
                   callback error-callback))

(defun pichat-rpc-clone (session callback &optional error-callback)
  "Clone current SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "clone" nil callback error-callback))

(defun pichat-rpc-get-session-stats (session callback &optional error-callback)
  "Get session stats for SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "get_session_stats" nil callback error-callback))

(defun pichat-rpc-compact (session &optional instructions cb)
  "Compact SESSION with optional INSTRUCTIONS.
When called as (pichat-rpc-compact SESSION CALLBACK), INSTRUCTIONS is omitted."
  (when (and (functionp instructions) (null cb))
    (setq cb instructions
          instructions nil))
  (pichat-rpc-send session "compact" (when instructions (list :customInstructions instructions)) cb))

(defun pichat-rpc-set-model
    (session provider model-id callback &optional error-callback)
  "Set SESSION model to PROVIDER/MODEL-ID.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "set_model"
                   (list :provider provider :modelId model-id)
                   callback error-callback))

(defun pichat-rpc-get-available-models
    (session callback &optional error-callback)
  "Get available models for SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "get_available_models" nil
                   callback error-callback))

(defun pichat-rpc-set-thinking-level
    (session level callback &optional error-callback)
  "Set SESSION thinking LEVEL.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "set_thinking_level" (list :level level)
                   callback error-callback))

(defun pichat-rpc-cycle-thinking-level
    (session callback &optional error-callback)
  "Cycle SESSION thinking level.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "cycle_thinking_level" nil
                   callback error-callback))

(defun pichat-rpc-set-session-name (session name cb)
  "Set SESSION display NAME."
  (pichat-rpc-send session "set_session_name" (list :name name) cb))

(defun pichat-rpc-get-commands (session callback &optional error-callback)
  "Get slash commands/templates/skills available to SESSION.
Dispatch success to CALLBACK and failure to optional ERROR-CALLBACK."
  (pichat-rpc-send session "get_commands" nil callback error-callback))

(provide 'pichat-rpc)
;;; pichat-rpc.el ends here
