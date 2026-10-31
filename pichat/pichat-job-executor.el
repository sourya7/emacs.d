;;; pichat-job-executor.el --- Manual independent job execution -*- lexical-binding: t; -*-

;;; Commentary:
;; No schedules or plan adapter.  All callbacks belong to one attempt, process
;; generation and source.  Acknowledging a prompt is not completion.  Only an
;; agent-settled boundary followed by authoritative transcript/state verification
;; can release ordinary work.  Uncertainty keeps durable claims and never retries.

;;; Code:
(require 'pichat-job-launch)
(require 'pichat-chat)
(require 'pichat-process-lifetime)

(defgroup pichat-jobs nil "Independent background jobs." :group 'pichat)
(defcustom pichat-jobs-max-concurrency 3
  "Maximum admitted job attempts, including uncertain executions."
  :type 'natnum :group 'pichat-jobs)
(defcustom pichat-jobs-queue-limit 20
  "Maximum queued manual attempts."
  :type 'natnum :group 'pichat-jobs)
(defcustom pichat-jobs-control-timeout 30
  "Seconds to wait for readiness, settlement sync or cancellation.
Running work and user interaction have no implicit timeout."
  :type 'number :group 'pichat-jobs)

(cl-defstruct (pichat-job-executor (:constructor pichat-job-executor--create))
  store contexts pumping)
(cl-defstruct (pichat-job-execution (:constructor pichat-job-execution--create))
  executor id token session process generation source handlers timer watch
  submitted accepted started settled settlement cancelling retired failure)
(defvar pichat-job-executor--input-owner nil
  "Dynamic execution ownership; never supplied by stored instructions.")
(defvar pichat-job-executor-changed-hook nil
  "Hook called with an executor after a durable change.  UI handlers read caches.")

(defun pichat-job-executor-open (store)
  "Own STORE for execution and explicitly reconcile interrupted work.
Do not call while another executor owns STORE.  No queued work is replayed."
  (pichat-job-reconcile store)
  (pichat-job-executor--create :store store :contexts (make-hash-table :test #'equal)))

(defun pichat-job-executor--changed (executor)
  "Notify cached consumers of EXECUTOR."
  (dolist (handler pichat-job-executor-changed-hook)
    (condition-case err (funcall handler executor)
      (error (message "PiChat Jobs view update failed: %s" (error-message-string err))))))

(defun pichat-job-executor--run (execution)
  "Return EXECUTION's detached durable run."
  (pichat-job-record (pichat-job-executor-store
                      (pichat-job-execution-executor execution))
                     'runs (pichat-job-execution-id execution)))

(defun pichat-job-executor--owned-p (execution)
  "Whether callbacks still belong to EXECUTION's exact process lifetime."
  (let ((session (pichat-job-execution-session execution)))
    (and (not (pichat-job-execution-retired execution))
         (eq execution (gethash (pichat-job-execution-id execution)
                               (pichat-job-executor-contexts
                                (pichat-job-execution-executor execution))))
         (or (null (pichat-job-execution-process execution))
             (and (eq (pichat-job-execution-process execution)
                      (pichat-session-process session))
                  (eql (pichat-job-execution-generation execution)
                       (pichat-session-process-generation session)))))))

(defun pichat-job-executor--source-p (execution)
  "Whether EXECUTION still hosts its captured Pi source."
  (let ((session (pichat-job-execution-session execution)))
    (and (pichat-job-executor--owned-p execution)
         (equal (pichat-job-execution-source execution)
                (list (pichat-session-id session) (pichat-session-session-file session))))))

(defun pichat-job-executor--clear-timer (execution)
  "Cancel EXECUTION's bounded control timer."
  (when-let* ((timer (pichat-job-execution-timer execution))) (cancel-timer timer))
  (setf (pichat-job-execution-timer execution) nil))

(defun pichat-job-executor--retire (execution)
  "Retire EXECUTION's callbacks, preserving its inspection-only runtime."
  (pichat-job-executor--clear-timer execution)
  (when-let* ((cancel (pichat-job-execution-watch execution))) (funcall cancel))
  (setf (pichat-job-execution-watch execution) nil
        (pichat-job-execution-retired execution) t)
  (dolist (pair (pichat-job-execution-handlers execution))
    (pichat-off (car pair) (cdr pair) (pichat-job-execution-session execution)))
  (setf (pichat-job-execution-handlers execution) nil))

(defun pichat-job-executor--advance (execution state &optional details)
  "Durably advance EXECUTION to STATE with DETAILS."
  (when (pichat-job-executor--owned-p execution)
    (let ((run (pichat-job-advance
                (pichat-job-executor-store (pichat-job-execution-executor execution))
                (pichat-job-execution-id execution) (pichat-job-execution-token execution)
                state details)))
      (when run
        (when (member state '("finished" "uncertain"))
          (pichat-job-executor--retire execution))
        (pichat-job-executor--changed (pichat-job-execution-executor execution)))
      run)))

(defun pichat-job-executor--uncertain (execution reason)
  "Retain EXECUTION's claims with bounded redacted REASON; never replay."
  (pichat-job-executor--advance execution "uncertain"
                               (list :reason (pichat-chat-diagnostics-safe-summary-text reason))))

(defun pichat-job-executor--deadline (execution reason)
  "Start a bounded control wait for EXECUTION, using REASON on timeout."
  (pichat-job-executor--clear-timer execution)
  (setf (pichat-job-execution-timer execution)
        (run-at-time pichat-jobs-control-timeout nil
                     (lambda ()
                       (when (pichat-job-executor--owned-p execution)
                         (pichat-job-executor--uncertain execution reason))))))

(defun pichat-job-executor--failed (execution reason)
  "Handle a control failure with REASON, not as successful completion."
  (when (pichat-job-executor--owned-p execution)
    (if (pichat-job-execution-submitted execution)
        (pichat-job-executor--uncertain execution reason)
      (pichat-job-executor--stop-before-prompt execution "failed" reason))))

(defun pichat-job-executor--stop-before-prompt (execution result reason)
  "Stop EXECUTION before model submission and finish only on exit evidence.
RESULT and REASON describe startup failure or cancellation.  SSH reuses the
existing verified-lifetime observer, never the local endpoint's sentinel."
  (let* ((session (pichat-job-execution-session execution))
         (process (pichat-session-process session)))
    ;; Suppress sentinel/control failure handling while the stop barrier owns it.
    (setf (pichat-job-execution-cancelling execution) t)
    (pichat-job-executor--clear-timer execution)
    (cl-labels
        ((finish ()
           (pichat-job-executor--advance
            execution "finished" (list :result result :safe-to-release t :reason reason))
           (pichat-job-executor-pump (pichat-job-execution-executor execution))))
      (if (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
          (if (not (pichat-process-lifetime-supported-p process))
              (progn
                (ignore-errors (pichat-backend-stop-session session))
                (pichat-job-executor--uncertain execution
                                                "SSH startup stopped without verified Pi identity"))
            (condition-case err
                (setf (pichat-job-execution-watch execution)
                      (pichat-process-lifetime-watch
                       (pichat-session-transport session) (pichat-session-runtime-cwd session)
                       process pichat-jobs-control-timeout nil
                       (lambda ()
                         (when (pichat-job-executor--owned-p execution)
                           (pichat-backend-stop-session session)))
                       (lambda (success failure)
                         (when (pichat-job-executor--owned-p execution)
                           (if success
                               (progn (pichat-process-lifetime-confirm process)
                                      (finish)
                                      (pichat-process-lifetime-cleanup process))
                             (pichat-job-executor--uncertain execution failure))))))
              (error (pichat-job-executor--uncertain execution (error-message-string err)))))
        (pichat-backend-stop-session session)
        (if (pichat-session-alive-p session)
            (pichat-job-executor--uncertain execution "Local process did not stop")
          (finish))))))

(defun pichat-job-executor--guard (execution command)
  "Permit owned input or read-only COMMAND for EXECUTION's inspection chat."
  (unless (or (eq pichat-job-executor--input-owner execution)
              pichat-rpc--internal-request
              (and (stringp command) (string-prefix-p "get_" command))
              (equal command "extension_ui_response"))
    (user-error "This is a job-owned chat; use Jobs to run, repeat or cancel work")))

(defun pichat-job-executor--guard-kill ()
  "Keep an active job chat owner alive until job cancellation is resolved."
  (if-let* ((execution (bound-and-true-p pichat-job-executor--buffer-execution)))
      (if (pichat-job-execution-retired execution) t
        (message "Active job owns this chat; cancel it through Jobs before killing") nil)
    t))

(defvar-local pichat-job-executor--buffer-execution nil)

(defun pichat-job-executor--call (execution type payload continuation)
  "Send owned control TYPE/PAYLOAD for EXECUTION; invoke CONTINUATION on success."
  (when (pichat-job-executor--owned-p execution)
    (let ((pichat-job-executor--input-owner execution)
          (pichat-rpc-request-timeout pichat-jobs-control-timeout))
      (pichat-rpc-send
       (pichat-job-execution-session execution) type payload
       (lambda (response _session)
         (when (and (pichat-job-executor--owned-p execution)
                    (not (and (pichat-job-execution-cancelling execution)
                              (not (pichat-job-execution-submitted execution)))))
           (condition-case err (funcall continuation response)
             (error (pichat-job-executor--failed execution (error-message-string err))))))
       (lambda (response _session)
         (unless (pichat-job-execution-cancelling execution)
           (pichat-job-executor--failed execution (or (plist-get response :error)
                                                     "Job control request failed"))))))))

(defun pichat-job-executor--ready (execution response)
  "Validate initial state RESPONSE, disable retry/compaction, then submit work."
  (let* ((session (pichat-job-execution-session execution))
         (data (plist-get response :data))
         (model (plist-get data :model))
         (actual (and model (concat (plist-get model :provider) "/" (plist-get model :id))))
         (expected (pichat-session-startup-model session)))
    (unless (and (pichat-job--text-p (pichat-session-id session))
                 (pichat-job--text-p (pichat-session-session-file session))
                 (equal expected actual)
                 (not (pichat-session-streaming-p session)))
      (error "Job startup did not confirm a fresh saved session and selected model"))
    (setf (pichat-job-execution-source execution)
          (list (pichat-session-id session) (pichat-session-session-file session)))
    (pichat-job-executor--call
     execution "set_auto_retry" '(:enabled :json-false)
     (lambda (_response)
       (pichat-job-executor--call
        execution "set_auto_compaction" '(:enabled :json-false)
        (lambda (_response)
          (pichat-job-executor--clear-timer execution)
          (pichat-job-executor--advance
           execution "running" (list :runtime-id (pichat-session-runtime-id session)
                                      :session-file (pichat-session-session-file session)))
          ;; Write running before the possibly ambiguous external submission.
          (setf (pichat-job-execution-submitted execution) t)
          (let ((pichat-job-executor--input-owner execution))
            (pichat-backend-submit-prompt
             session (plist-get (plist-get (pichat-job-executor--run execution) :spec)
                                 :instructions) nil nil
             (lambda (ack _session)
               (when (pichat-job-executor--owned-p execution)
                 (if (member (plist-get (plist-get ack :data) :disposition)
                             '(nil "started"))
                     (setf (pichat-job-execution-accepted execution) t)
                   (pichat-job-executor--uncertain execution "Prompt was not accepted as agent work"))))
             (lambda (_response _session)
               (unless (pichat-job-execution-cancelling execution)
                 (pichat-job-executor--failed execution "Job submission failed or was ambiguous")))))))))))

(defun pichat-job-executor--cache-result (cache)
  "Extract bounded outcome/summary from authoritative fresh-session CACHE.
No structured domain success or plan completion is inferred from prose."
  (let (assistant)
    (maphash (lambda (_id entry)
               (let ((message (plist-get entry :message)))
                 (when (equal (plist-get message :role) "assistant")
                   (push message assistant))))
             (pichat-entry-cache-entries-by-id cache))
    (unless assistant (error "Settled job has no authoritative assistant result"))
    (let* ((bad (seq-find (lambda (message)
                           (member (plist-get message :stopReason) '("error" "aborted"))) assistant))
           (transcript (pichat-pi-build-canonical-transcript cache))
           (prose (cl-loop for node in (pichat-transcript-nodes transcript)
                           when (and (eq (pichat-transcript-node-kind node) 'message)
                                     (eq (pichat-transcript-node-role node) 'assistant))
                           append (cl-loop for content in (pichat-transcript-node-content node)
                                           when (eq (pichat-transcript-content-kind content) 'prose)
                                           collect (pichat-transcript-content-text content)))))
      (list :result (if bad "failed" "completed")
            :reason (when bad
                      (pichat-chat-diagnostics-safe-summary-text
                       (or (plist-get bad :errorMessage) "Agent stopped abnormally")))
            :summary (truncate-string-to-width (string-join prose "\n\n") 2000 nil nil "…")))))

(defun pichat-job-executor--synchronized (execution payload)
  "Validate settled synchronized PAYLOAD and fresh idle state for EXECUTION."
  (when (and (pichat-job-execution-settled execution)
             (eql (plist-get payload :settlement-sequence)
                  (pichat-job-execution-settlement execution))
             (pichat-job-executor--source-p execution)
             (eql (plist-get payload :process-generation)
                  (pichat-job-execution-generation execution))
             (equal (list (plist-get payload :session-id) (plist-get payload :session-file))
                    (pichat-job-execution-source execution)))
    (let ((outcome (pichat-job-executor--cache-result (plist-get payload :cache))))
      (pichat-job-executor--call
       execution "get_state" nil
       (lambda (_response)
         (unless (and (pichat-job-executor--source-p execution)
                      (eq (pichat-session-state (pichat-job-execution-session execution)) 'idle))
           (error "Settled job source/state changed before completion"))
         (let* ((run (pichat-job-executor--run execution))
                (modifying (seq-some
                            (lambda (claim) (equal (plist-get claim :access) "write"))
                            (plist-get (plist-get run :spec) :resources))))
           (if (and modifying (or (pichat-job-execution-cancelling execution)
                                 (equal (plist-get outcome :result) "failed")))
               (pichat-job-executor--uncertain
                execution "Agent stopped abnormally; modifying tool descendants need inspection")
             (pichat-job-executor--advance
              execution "finished"
              (append (if (pichat-job-execution-cancelling execution)
                          '(:result "cancelled" :reason "Agent abort settled and synchronized")
                        outcome)
                      '(:synchronized t :safe-to-release t)))
             (pichat-job-executor-pump (pichat-job-execution-executor execution)))))))))

(defun pichat-job-executor--event (execution event payload)
  "Handle an owned runtime EVENT/PAYLOAD for EXECUTION."
  (when (pichat-job-executor--owned-p execution)
    (condition-case err
        (pcase event
          ('rpc-event
           (pcase (plist-get payload :normalized-event)
             ('agent-start
              (if (pichat-job-execution-settled execution)
                  (pichat-job-executor--uncertain execution "Unexpected new agent work after settlement")
                (setf (pichat-job-execution-started execution) t)))
             ('agent-settled
              (when (pichat-job-execution-submitted execution)
                (if (not (pichat-job-executor--source-p execution))
                    (pichat-job-executor--uncertain execution "Job conversation source changed")
                  (setf (pichat-job-execution-settled execution) t
                        (pichat-job-execution-settlement execution)
                        (1+ (buffer-local-value
                             'pichat-chat--settlement-sequence
                             (pichat-session-buffer (pichat-job-execution-session execution)))))
                  (pichat-job-executor--advance execution "settling")
                  (pichat-job-executor--deadline execution "Result not synchronized after settlement"))))))
          ('transcript-synchronized (pichat-job-executor--synchronized execution payload))
          ('transcript-sync-failed
           (when (and (pichat-job-execution-settled execution)
                      (eql (plist-get payload :settlement-sequence)
                           (pichat-job-execution-settlement execution)))
             (pichat-job-executor--uncertain execution "Result not synchronized")))
          ('session-rebinding
           (pichat-job-executor--uncertain execution "Job conversation cannot be rebound"))
          ('user-input-pending-changed
           (pichat-job-executor--changed (pichat-job-execution-executor execution)))
          ('session-ended
           (unless (pichat-job-execution-cancelling execution)
             (pichat-job-executor--failed execution "Job runtime ended before verified completion"))))
      (error (pichat-job-executor--uncertain execution (error-message-string err))))))

(defun pichat-job-executor--start (executor run)
  "Start admitted RUN through EXECUTOR without displaying or selecting a chat."
  (let* ((non-essential t)
         (id (plist-get run :id))
         (execution (pichat-job-execution--create :executor executor :id id
                                                 :token (plist-get run :attempt))))
    (puthash id execution (pichat-job-executor-contexts executor))
    (condition-case err
        (pcase-let* ((`(,session ,command) (pichat-job-launch-prepare (plist-get run :spec))))
          (setf (pichat-job-execution-session execution) session
                (pichat-session-input-guard session)
                (lambda (command) (pichat-job-executor--guard execution command)))
          (let ((buffer (pichat-chat-ensure session)))
            (with-current-buffer buffer
              (setq-local pichat-chat-stop-session-on-kill nil)
              (setq-local pichat-job-executor--buffer-execution execution)
              (add-hook 'kill-buffer-query-functions #'pichat-job-executor--guard-kill nil t)))
          (dolist (event '(rpc-event transcript-synchronized transcript-sync-failed
                          session-rebinding session-ended user-input-pending-changed))
            (let ((handler (lambda (_session event payload)
                             (pichat-job-executor--event execution event payload))))
              (push (cons event handler) (pichat-job-execution-handlers execution))
              (pichat-on event handler session)))
          (pichat-start-prepared-session session t command)
          (setf (pichat-job-execution-process execution) (pichat-session-process session)
                (pichat-job-execution-generation execution) (pichat-session-process-generation session))
          (when (pichat-job-executor--owned-p execution)
            (pichat-job-executor--deadline execution "Job startup did not become ready")
            (pichat-job-executor--call execution "get_state" nil
                                       (lambda (response) (pichat-job-executor--ready execution response)))))
      ((error quit)
       (if (pichat-job-execution-session execution)
           (pichat-job-executor--failed execution (error-message-string err))
         (pichat-job-executor--advance execution "finished"
                                       (list :result "failed" :safe-to-release t
                                             :reason (pichat-chat-diagnostics-safe-summary-text
                                                      (error-message-string err)))))))
    execution))

(defun pichat-job-executor-pump (executor)
  "Dispatch eligible queued work from EXECUTOR through the shared admission path."
  (unless (pichat-job-executor-pumping executor)
    (setf (pichat-job-executor-pumping executor) t)
    (unwind-protect
        (let ((progress t))
          ;; Synchronous transport setup may process a completion while a pump
          ;; is already active.  Revisit earlier waits after any dispatch so
          ;; the suppressed nested pump cannot leave eligible work stranded.
          (while progress
            (setq progress nil)
            (seq-doseq (run (pichat-job-records (pichat-job-executor-store executor) 'runs))
              (when (equal (plist-get run :state) "queued")
                (let* ((store (pichat-job-executor-store executor))
                       (id (plist-get run :id))
                       (admission (pichat-job-admission store id pichat-jobs-max-concurrency)))
                  (when (eq (plist-get admission :ready) t)
                    (setq progress t)
                    (pichat-job-executor--start
                     executor (pichat-job-claim store id pichat-jobs-max-concurrency))))))))
      (setf (pichat-job-executor-pumping executor) nil))))

(defun pichat-job-executor-submit (executor spec &optional job-id repeat-of)
  "Persist manual SPEC or saved JOB-ID in EXECUTOR before dispatching it.
Return the new run ID without selecting its runtime or displaying a chat."
  (let ((id (pichat-job-enqueue (pichat-job-executor-store executor) spec job-id
                               pichat-jobs-queue-limit repeat-of)))
    (pichat-job-executor--changed executor)
    (pichat-job-executor-pump executor)
    id))

(defun pichat-job-executor-cancel (executor id)
  "Request cancellation of exact ID owned by EXECUTOR; never equate ack with exit."
  (let* ((run (pichat-job-record (pichat-job-executor-store executor) 'runs id))
         (execution (gethash id (pichat-job-executor-contexts executor))))
    (cond
     ((equal (plist-get run :state) "queued")
      (pichat-job-cancel-queued (pichat-job-executor-store executor) id)
      (pichat-job-executor--changed executor)
      (pichat-job-executor-pump executor))
     ((and execution (pichat-job-executor--owned-p execution))
      (if (not (pichat-job-execution-submitted execution))
          (pichat-job-executor--stop-before-prompt execution "cancelled" "Cancelled before prompt")
        (setf (pichat-job-execution-cancelling execution) t)
        (pichat-job-executor--deadline execution "Cancellation did not establish settled execution")
        (pichat-job-executor--call execution "abort" nil (lambda (_ack) nil))
        (pichat-job-executor--changed executor)))
     (t (user-error "This run is not cancellable; inspect its recorded state")))))

(defun pichat-job-executor-recheck-exit (executor id callback)
  "Recheck exact SSH Pi exit for uncertain ID; call CALLBACK (SUCCESS REASON).
Never releases claims: Pi exit does not prove tool descendants stopped."
  (let* ((execution (gethash id (pichat-job-executor-contexts executor)))
         (session (and execution (pichat-job-execution-session execution)))
         (process (and execution (pichat-job-execution-process execution))))
    (unless (and session (equal (plist-get (pichat-job-executor--run execution) :state) "uncertain")
                 (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
                 (pichat-process-lifetime-supported-p process))
      (user-error "No retained verified SSH lifetime is available for this run"))
    (pichat-process-lifetime-watch
     (pichat-session-transport session) (pichat-session-runtime-cwd session)
     process pichat-jobs-control-timeout nil #'ignore
     (lambda (success reason)
       (when success (pichat-process-lifetime-confirm process)
             (pichat-process-lifetime-cleanup process))
       (funcall callback success reason)))))

(defun pichat-job-executor-resolve (executor id acknowledgement)
  "Release uncertain ID after explicit human inspection ACKNOWLEDGEMENT.
Do not stop or resume remote work; preserve that this is not verified shutdown."
  (unless (equal (plist-get (pichat-job-record (pichat-job-executor-store executor)
                                               'runs id) :state) "uncertain")
    (user-error "Only uncertain executions can be manually resolved"))
  (when-let* ((execution (gethash id (pichat-job-executor-contexts executor))))
    (pichat-job-executor--retire execution))
  (pichat-job-resolve-uncertain (pichat-job-executor-store executor) id acknowledgement)
  (pichat-job-executor--changed executor)
  (pichat-job-executor-pump executor))

(provide 'pichat-job-executor)
;;; pichat-job-executor.el ends here
