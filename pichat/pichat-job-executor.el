;;; pichat-job-executor.el --- Owned and borrowed job execution -*- lexical-binding: t; -*-

;;; Commentary:
;; Native timers submit through ordinary durable admission; no plan adapter.
;; All execution callbacks belong to one attempt, process
;; generation and source.  Acknowledging a prompt is not completion.  Only an
;; agent-settled boundary followed by authoritative transcript/state verification
;; can release ordinary work.  Uncertainty keeps its global slot and never retries.

;;; Code:
(require 'pichat-job-launch)
(require 'pichat-chat)
(require 'pichat-process-lifetime)
(require 'pichat-job-conversation)

(declare-function pichat-session-by-runtime-id "pichat" (runtime-id))

(defgroup pichat-jobs nil "Reviewed background and existing-conversation jobs." :group 'pichat)
(defcustom pichat-jobs-max-concurrency 3
  "Maximum admitted job attempts, including uncertain executions."
  :type 'natnum :group 'pichat-jobs)
(defcustom pichat-jobs-queue-limit 20
  "Maximum queued attempts, shared by manual, scheduled and lifecycle submissions."
  :type 'natnum :group 'pichat-jobs)
(defcustom pichat-jobs-max-chain-runs 8
  "Maximum runs in a run chain before job tools may not start another.
Runs you start from Jobs (Run job, Repeat, Continue work) are never refused.
The default fits three review rounds of a worker and a reviewer, plus spares."
  :type 'natnum :group 'pichat-jobs)
(defcustom pichat-jobs-control-timeout 30
  "Seconds to wait for readiness, settlement sync or cancellation.
Running work and user interaction have no implicit timeout."
  :type 'number :group 'pichat-jobs)

(cl-defstruct (pichat-job-executor (:constructor pichat-job-executor--create))
  store contexts pumping schedules schedule-error schedules-closed
  (conversations (make-hash-table :test #'equal)))
(cl-defstruct (pichat-job-execution (:constructor pichat-job-execution--create))
  executor id token session process generation source handlers timer watch
  submitted accepted started settled settlement cancelling cleanup retired failure
  borrowed previous-guard guard previous-buffer-execution)
(defvar-local pichat-job-executor--buffer-execution nil)
(defvar pichat-job-executor--input-owner nil
  "Dynamic execution ownership; never supplied by stored instructions.")
(defvar pichat-job-executor-changed-hook nil
  "Hook called with an executor after a durable change.  UI handlers read caches.")

(defun pichat-job-executor-open (store)
  "Own STORE for execution and explicitly reconcile interrupted work.
Do not call while another executor owns STORE.  No queued work is replayed."
  (pichat-job-reconcile store)
  (let ((executor (pichat-job-executor--create
                   :store store :contexts (make-hash-table :test #'equal)
                   :schedules (make-hash-table :test #'equal))))
    (pichat-job-executor-schedule-refresh executor)
    executor))

(defun pichat-job-executor--changed (executor)
  "Notify cached consumers of EXECUTOR."
  (dolist (handler pichat-job-executor-changed-hook)
    (condition-case err (funcall handler executor)
      (error (message "PiChat Jobs view update failed: %s" (error-message-string err))))))

(defun pichat-job-executor-schedule-stop (executor)
  "Retire EXECUTOR's timing callbacks without cancelling runs or saved rules."
  (when (pichat-job-executor-schedules executor)
    (maphash (lambda (_id entry) (cancel-timer (cdr entry)))
             (pichat-job-executor-schedules executor))
    (clrhash (pichat-job-executor-schedules executor)))
  (setf (pichat-job-executor-schedules-closed executor) t))

(defun pichat-job-executor-schedule-refresh (executor)
  "Synchronize owned native one-shot timers with EXECUTOR's durable definitions.
Call explicitly after definition/timing changes, never from a UI redraw or hook.
Retain identical timers: refreshing a late timer must not skip its due work."
  (unless (or (pichat-job-executor-schedules-closed executor)
              (pichat-job-executor-schedule-error executor))
    (let ((timers (or (pichat-job-executor-schedules executor)
                      (setf (pichat-job-executor-schedules executor)
                            (make-hash-table :test #'equal))))
          (wanted (make-hash-table :test #'equal)))
      (seq-doseq (job (pichat-job-records (pichat-job-executor-store executor) 'jobs))
        (let ((schedule (plist-get job :schedule)))
          (when (eq (plist-get schedule :enabled) t)
            (puthash (plist-get job :id) schedule wanted))))
      (seq-doseq (run (pichat-job-records (pichat-job-executor-store executor) 'runs))
        (when (and (pichat-job-conversation-p run) (equal (plist-get run :state) "scheduled"))
          (puthash (plist-get run :id)
                   (list :conversation run :next (plist-get (plist-get run :trigger) :due)) wanted)))
      (maphash (lambda (id entry)
                 (unless (equal (car entry) (gethash id wanted))
                   (cancel-timer (cdr entry))
                   (remhash id timers))) timers)
      (maphash
       (lambda (id schedule)
         (unless (gethash id timers)
           (let ((entry (cons schedule nil)))
             (setcdr entry
                     (run-at-time
                      (seconds-to-time (plist-get schedule :next)) nil
                      (lambda ()
                        (when (and (not (pichat-job-executor-schedules-closed executor))
                                   (eq entry (gethash id timers)))
                          (remhash id timers)
                          (condition-case err
                              (progn
                                (if-let* ((run (plist-get schedule :conversation)))
                                    (pichat-job-executor--conversation-dispatch executor id run)
                                  (pichat-job-schedule-dispatch
                                   (pichat-job-executor-store executor) id schedule
                                   (float-time) pichat-jobs-queue-limit))
                                ;; Rearm before runtime startup can process nested events.
                                (pichat-job-executor-schedule-refresh executor)
                                (pichat-job-executor--changed executor)
                                (pichat-job-executor-pump executor))
                            (error
                             ;; Storage failure must not create an unrecorded attempt
                             ;; or spin/retry the same overdue occurrence.
                             (pichat-job-executor-schedule-stop executor)
                             (setf (pichat-job-executor-schedule-error executor)
                                   (format "Scheduling stopped (%s); inspect storage and restart Emacs"
                                           (car err)))
                             (pichat-job-executor--changed executor)
                             (message "%s" (pichat-job-executor-schedule-error executor))))))))
             (puthash id entry timers)))) wanted))))

(defun pichat-job-executor-schedule-change (executor id rule)
  "Save ID's RULE disabled, then update EXECUTOR's timer ownership."
  (pichat-job-schedule-set (pichat-job-executor-store executor) id rule)
  (pichat-job-executor-schedule-refresh executor)
  (pichat-job-executor--changed executor))

(defun pichat-job-executor-schedule-enable (executor id enabled)
  "Explicitly ENABLED or disable ID's future submissions in EXECUTOR."
  (when (and enabled (pichat-job-executor-schedule-error executor))
    (user-error "%s" (pichat-job-executor-schedule-error executor)))
  (pichat-job-schedule-enable (pichat-job-executor-store executor) id enabled)
  (pichat-job-executor-schedule-refresh executor)
  (pichat-job-executor--changed executor))

(defun pichat-job-executor-schedule-run-now (executor id expected)
  "Explicitly consume ID's authorized one-shot owned by EXPECTED in EXECUTOR.
Retire its original timer before hooks or startup can process nested events."
  (when (or (pichat-job-executor-schedules-closed executor)
            (pichat-job-executor-schedule-error executor))
    (user-error "Scheduling is stopped; inspect storage and restart Emacs"))
  (unless (and (equal expected (plist-get (pichat-job-record (pichat-job-executor-store executor) 'jobs id)
                                        :schedule))
               (pichat-job-schedule-run-now-p expected))
    (user-error "Schedule changed; reopen its report"))
  (let ((run
         (condition-case err
             (pichat-job-schedule-dispatch
              (pichat-job-executor-store executor) id expected
              (float-time) pichat-jobs-queue-limit t)
           (error
            ;; Never let the original timer send later after a failed write.
            (pichat-job-executor-schedule-stop executor)
            (setf (pichat-job-executor-schedule-error executor)
                  (format "Scheduling stopped (%s); inspect storage and restart Emacs" (car err)))
            (pichat-job-executor--changed executor)
            (signal (car err) (cdr err))))))
    (pichat-job-executor-schedule-refresh executor)
    (pichat-job-executor--changed executor)
    (when run (pichat-job-executor-pump executor))
    (unless run (user-error "Not submitted; inspect the schedule's current reason"))
    run))

(defun pichat-job-executor--conversation-dispatch (executor id expected &optional run-now)
  "Consume EXPECTED conversation ID using live authority in EXECUTOR.
RUN-NOW authorizes early consumption, not a new attempt or conversation."
  (let* ((store (pichat-job-executor-store executor))
         (run (pichat-job-record store 'runs id))
         (capture (gethash id (pichat-job-executor-conversations executor))))
    (when (and (equal run expected) (pichat-job-conversation-p run)
               (equal (plist-get run :state) "scheduled"))
      (prog1
          (if (not (and capture (pichat-job-conversation-current-p capture)))
              (progn (pichat-job-executor--conversation-invalidated executor id nil) nil)
            (pichat-job-conversation-dispatch
             store id expected (float-time) pichat-jobs-queue-limit nil run-now))
        (when (equal "finished" (plist-get (pichat-job-record store 'runs id) :state))
          (pichat-job-executor--conversation-notice executor id capture)
          (pichat-job-executor--conversation-forget executor id))))))

(defun pichat-job-executor-conversation-run-now (executor id expected)
  "Explicitly consume pending conversation ID early in EXECUTOR.
EXPECTED must be the exact run reviewed by the caller.  Existing live authority,
queue limits and fresh pre-submission verification remain mandatory."
  (when (or (pichat-job-executor-schedules-closed executor)
            (pichat-job-executor-schedule-error executor))
    (user-error "Scheduling is stopped; inspect storage and restart Emacs"))
  (unless (and (equal expected (pichat-job-record (pichat-job-executor-store executor) 'runs id))
               (pichat-job-conversation-p expected)
               (equal (plist-get expected :state) "scheduled"))
    (user-error "Scheduled continuation changed; reopen its report"))
  (let ((run
         (condition-case err
             (pichat-job-executor--conversation-dispatch executor id expected t)
           (error
            ;; A failed commit must not leave the old timer able to send later.
            (pichat-job-executor-schedule-stop executor)
            (setf (pichat-job-executor-schedule-error executor)
                  (format "Scheduling stopped (%s); inspect storage and restart Emacs" (car err)))
            (pichat-job-executor--changed executor)
            (signal (car err) (cdr err))))))
    ;; Remove the original callback before hooks or startup can process events.
    (pichat-job-executor-schedule-refresh executor)
    (pichat-job-executor--changed executor)
    (when run (pichat-job-executor-pump executor))
    (unless run (user-error "Not sent; inspect the continuation's current reason"))
    run))

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
                (list (pichat-session-id session) (pichat-session-session-file session)))
         (or (not (pichat-job-execution-borrowed execution))
             (and (pichat-job-conversation-source-p (pichat-job-execution-borrowed execution))
                  (eq (pichat-job-execution-guard execution) (pichat-session-input-guard session)))))))

(defun pichat-job-executor--clear-timer (execution)
  "Cancel EXECUTION's bounded control timer."
  (when-let* ((timer (pichat-job-execution-timer execution))) (cancel-timer timer))
  (setf (pichat-job-execution-timer execution) nil))

(defun pichat-job-executor--retire (execution &optional release)
  "Retire EXECUTION's callbacks, preserving its readable transcript.
Restore borrowed uncertain ownership only on explicit RELEASE after
inspection."
  (pichat-job-executor--clear-timer execution)
  (when-let* ((cancel (pichat-job-execution-watch execution))) (funcall cancel))
  (setf (pichat-job-execution-watch execution) nil
        (pichat-job-execution-retired execution) t)
  (dolist (pair (pichat-job-execution-handlers execution))
    (pichat-off (car pair) (cdr pair) (pichat-job-execution-session execution)))
  (setf (pichat-job-execution-handlers execution) nil)
  (when (pichat-job-execution-borrowed execution)
    (pichat-job-executor--conversation-forget
     (pichat-job-execution-executor execution) (pichat-job-execution-id execution))
    (when (or release
              (not (equal (condition-case nil (plist-get (pichat-job-executor--run execution) :state)
                            (pichat-job-error nil))
                          "uncertain")))
      (let* ((session (pichat-job-execution-session execution))
             (buffer (plist-get (pichat-job-execution-borrowed execution) :buffer)))
        (when (eq (pichat-session-input-guard session) (pichat-job-execution-guard execution))
          (setf (pichat-session-input-guard session) (pichat-job-execution-previous-guard execution)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (eq pichat-job-executor--buffer-execution execution)
              (setq pichat-job-executor--buffer-execution (pichat-job-execution-previous-buffer-execution execution))
              (unless pichat-job-executor--buffer-execution
                (remove-hook 'kill-buffer-query-functions #'pichat-job-executor--guard-kill t)))))))))

(defun pichat-job-executor--advance (execution state &optional details)
  "Durably advance EXECUTION to STATE with DETAILS."
  (when (pichat-job-executor--owned-p execution)
    (let ((run (pichat-job-advance
                (pichat-job-executor-store (pichat-job-execution-executor execution))
                (pichat-job-execution-id execution) (pichat-job-execution-token execution)
                state details pichat-jobs-queue-limit)))
      (when run
        (when (member state '("finished" "uncertain"))
          (pichat-job-executor--retire execution))
        (pichat-job-executor--changed (pichat-job-execution-executor execution))
        (when (member state '("finished" "uncertain"))
          (pichat-job-executor-pump (pichat-job-execution-executor execution))))
      run)))

(defun pichat-job-executor--uncertain (execution reason)
  "Retain EXECUTION's global slot with bounded redacted REASON; never replay."
  ;; Retain the last synchronized cache where available, never live UI text.
  ;; It may predate the stop, so the event remains explicitly partial.
  (when (pichat-job-executor--owned-p execution)
    (let* ((session (pichat-job-execution-session execution))
           (store (pichat-job-executor-store (pichat-job-execution-executor execution)))
           (cache (and session (not (pichat-job-execution-borrowed execution))
                       (pichat-chat-canonical-entry-cache session)))
           (digest (or (plist-get (pichat-job-executor--run execution) :evidence)
                       (and cache
                            (condition-case nil
                                (pichat-job-evidence-save
                                 store (plist-get (pichat-job-executor--cache-result cache) :capture))
                              (error nil))))))
      (pichat-job-executor--advance
       execution "uncertain"
       (append (list :reason (pichat-chat-diagnostics-safe-summary-text reason))
               (when digest (list :evidence digest)))))))

(defun pichat-job-executor--deadline (execution reason)
  "Start a bounded control wait for EXECUTION, using REASON on timeout."
  (pichat-job-executor--clear-timer execution)
  (setf (pichat-job-execution-timer execution)
        (run-at-time pichat-jobs-control-timeout nil
                     (lambda ()
                       (when (pichat-job-executor--owned-p execution)
                         (if (and (pichat-job-execution-borrowed execution)
                                  (not (pichat-job-execution-submitted execution)))
                             (pichat-job-executor--failed execution reason)
                           (pichat-job-executor--uncertain execution reason)))))))

(defun pichat-job-executor--failed (execution reason)
  "Handle a control failure with REASON, not as successful completion."
  (when (pichat-job-executor--owned-p execution)
    (cond
     ((pichat-job-execution-submitted execution)
      (pichat-job-executor--uncertain execution reason))
     ((pichat-job-execution-borrowed execution)
      (pichat-job-executor--conversation-invalidated
       (pichat-job-execution-executor execution) (pichat-job-execution-id execution) reason))
     (t (pichat-job-executor--stop-before-prompt execution "failed" reason)))))

(defun pichat-job-executor--stop-before-prompt (execution result reason &optional captured)
  "Stop EXECUTION's exact owned lifetime and finish only on exit evidence.
RESULT and REASON describe startup failure, cancellation or captured completion.
CAPTURED is already durable synchronized evidence for a settled run.
SSH reuses the verified-lifetime observer, never the local endpoint's sentinel."
  (if (pichat-job-execution-borrowed execution)
      ;; Borrowing never invokes a worker's stop/read-only cleanup policy.
      (pichat-job-executor--advance
       execution "finished" (append (list :result (if captured result "cancelled")
                                          :safe-to-release t :reason reason) captured))
    (let* ((session (pichat-job-execution-session execution))
           (process (pichat-session-process session)))
    ;; Suppress sentinel/control failure handling while the stop barrier owns it.
    (setf (pichat-job-execution-cancelling execution) t
          (pichat-job-execution-cleanup execution) (and captured t))
    (pichat-job-executor--clear-timer execution)
    (cl-labels
        ((finish ()
           (when (buffer-live-p (pichat-session-buffer session))
             (with-current-buffer (pichat-session-buffer session)
               (setq buffer-read-only t)))
           (pichat-job-executor--advance
            execution "finished" (append (list :result result :safe-to-release t :reason reason)
                                         captured))
           (pichat-job-executor-pump (pichat-job-execution-executor execution))))
      (if (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
          (if (not (pichat-process-lifetime-supported-p process))
              (progn
                (ignore-errors (pichat-backend-stop-session session))
                (pichat-job-executor--uncertain execution
                                                "SSH stop lacks verified Pi identity"))
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
          (finish)))))))

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
             session (pichat-job-prompt (pichat-job-executor--run execution)) nil nil
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
  "Extract final response and run-bounded transcript from authoritative CACHE.
Use active-branch order, not hash order or accumulated commentary.  An empty
last response stays empty.  No domain success is inferred from prose."
  (let* ((entries (pichat-pi-entry-cache-active-branch cache))
         (assistant (cl-loop for entry in entries
                             for message = (plist-get entry :message)
                             when (equal (plist-get message :role) "assistant")
                             collect message))
         (bad (seq-find (lambda (message)
                          (member (plist-get message :stopReason) '("error" "aborted")))
                        (reverse assistant)))
         (transcript (pichat-pi-build-canonical-transcript cache))
         (response (pichat-chat-navigation-select-response transcript nil nil)))
    (unless response (error "Settled job has no authoritative assistant result"))
    (let ((markdown (pichat-chat-navigation-response-markdown response)))
      (list :result (if bad "failed" "completed")
            :reason (when bad
                      (pichat-chat-diagnostics-safe-summary-text
                       (or (plist-get bad :errorMessage) "Agent stopped abnormally")))
            :summary (truncate-string-to-width markdown 2000 nil nil "…")
            :capture (list :version 2 :response markdown
                           :response-entry (pichat-chat-navigation-response-node-key response)
                           :leaf (pichat-entry-cache-leaf-id cache)
                           :captured-at (pichat-job--now)
                           ;; RPC uses plist/list JSON.  Evidence uses vectors for
                           ;; arrays so json-serialize cannot mistake content or
                           ;; tool arguments for object property lists.
                           :entries (pichat-job-evidence-value
                                     (vconcat entries)))))))

(defun pichat-job-executor--synchronized (execution payload)
  "Validate settled synchronized PAYLOAD and fresh idle state for EXECUTION."
  (when (and (pichat-job-execution-settled execution)
             (not (pichat-job-execution-cleanup execution))
             (eql (plist-get payload :settlement-sequence)
                  (pichat-job-execution-settlement execution))
             (pichat-job-executor--source-p execution)
             (eql (plist-get payload :process-generation)
                  (pichat-job-execution-generation execution))
             (equal (list (plist-get payload :session-id) (plist-get payload :session-file))
                    (pichat-job-execution-source execution)))
    (let* ((qualified (when (pichat-job-execution-borrowed execution)
                        (pichat-job-conversation-outcome
                         (pichat-job-execution-borrowed execution) (plist-get payload :cache)
                         (pichat-job-prompt (pichat-job-executor--run execution)))))
           (outcome (pichat-job-executor--cache-result (plist-get payload :cache))))
      (when qualified
        (setf (plist-get outcome :result) (plist-get qualified :result)
              (plist-get outcome :reason) (plist-get qualified :reason)
              (plist-get (plist-get outcome :capture) :boundary) (plist-get qualified :boundary)
              (plist-get (plist-get outcome :capture) :prompt-entry) (plist-get qualified :prompt-entry)))
      (pichat-job-executor--call
       execution "get_state" nil
       (lambda (response)
        ;; Several qualified sync notifications can race their idle-state replies.
        ;; The first completion owns cleanup; later replies must not start a
        ;; second stop observer or turn the stopping runtime into a sync failure.
        (unless (pichat-job-execution-cleanup execution)
         (unless (and (pichat-job-executor--source-p execution)
                      (or (not (pichat-job-execution-borrowed execution))
                          (and (pichat-job-execution-accepted execution)
                               (pichat-job-conversation-state-p
                                (pichat-job-execution-borrowed execution) (plist-get response :data))
                               (eq (plist-get payload :cache)
                                   (pichat-chat-canonical-entry-cache (pichat-job-execution-session execution)))))
                      (eq (pichat-session-state (pichat-job-execution-session execution)) 'idle))
           (error "Settled job source/state changed before completion"))
         (when (> (pichat-chat-pending-user-input-count
                   (pichat-job-execution-session execution)) 0)
           (error "Settled job still has pending user input"))
         (let* ((store (pichat-job-executor-store (pichat-job-execution-executor execution)))
                (capture (append (plist-get outcome :capture)
                                 (list :source (vconcat (pichat-job-execution-source execution)))))
                (digest (pichat-job-evidence-save store capture))
                (captured (list :summary (plist-get outcome :summary)
                                :evidence digest :synchronized t)))
           ;; Persist evidence before stopping.  A crash/failed stop leaves
           ;; settling/uncertain with the report intact and its slot still held.
           (pichat-job-advance store (pichat-job-execution-id execution)
                               (pichat-job-execution-token execution) "settling" captured)
           ;; Without declared access modes, no job can assert that descendants
           ;; are harmless.  Keep the existing conservative abnormal-stop guard.
           (if (or (pichat-job-execution-cancelling execution)
                   (equal (plist-get outcome :result) "failed"))
               (pichat-job-executor--uncertain
                execution "Agent stopped abnormally; tool descendants need inspection")
             (pichat-job-executor--stop-before-prompt
              execution (plist-get outcome :result) (plist-get outcome :reason) captured)))))))))

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

(defun pichat-job-executor--conversation-forget (executor id)
  "Retire live authority for ID, without stopping or changing its runtime."
  (when-let* ((capture (gethash id (pichat-job-executor-conversations executor))))
    (setf (plist-get capture :invalidated) t)
    (remhash id (pichat-job-executor-conversations executor))
    (dolist (pair (plist-get capture :handlers))
      (pichat-off (car pair) (cdr pair) (plist-get capture :session)))
    (when (buffer-live-p (plist-get capture :buffer))
      (with-current-buffer (plist-get capture :buffer)
        (remove-hook 'kill-buffer-hook (plist-get capture :kill-hook) t)))))

(defvar-local pichat-job-executor--continuation-notice nil
  "Source-qualified last invalidated attempt for explicit review/rescheduling.")

(defun pichat-job-executor--conversation-clear-notice ()
  "Discard source-qualified feedback and actions in the current chat."
  (setq pichat-job-executor--continuation-notice nil)
  (condition-case nil (pichat-chat--set-status 'scheduled-continuation nil)
    (error (pichat-chat--set-status-state 'scheduled-continuation nil))))

(defun pichat-job-executor--conversation-notice (executor id capture)
  "Notify only CAPTURE's still-owned source, without selecting its chat."
  (when (and capture (not (plist-get capture :notified))
             (pichat-job-conversation-notice-p capture))
    (setf (plist-get capture :notified) t)
    ;; Presentation failure must not prevent retiring cancelled live authority.
    (condition-case nil
        (let ((run (pichat-job-record (pichat-job-executor-store executor) 'runs id)))
          (with-current-buffer (plist-get capture :buffer)
            (setq pichat-job-executor--continuation-notice (list executor id capture))
            (add-hook 'pichat-chat-source-reset-hook #'pichat-job-executor--conversation-clear-notice nil t)
            (pichat-chat--set-status
             'scheduled-continuation
             (format "Scheduled continuation · Pi session %s: %s. M-x pichat-job-review-continuation / pichat-job-reschedule-continuation"
                     (plist-get (plist-get capture :destination) :session-id)
                     (or (plist-get run :reason) "Not sent")))))
      (error nil))))

(defun pichat-job-executor--conversation-invalidated (executor id reason &optional evidence)
  "Persist ID's loss of authority before allowing any later callback to send."
  (let* ((capture (gethash id (pichat-job-executor-conversations executor)))
         (store (pichat-job-executor-store executor))
         (run (pichat-job-record store 'runs id))
         (execution (gethash id (pichat-job-executor-contexts executor)))
         (evidence (or evidence (pichat-job-conversation-invalidation capture)))
         (reason (or reason (pichat-job-conversation-invalidation-text evidence))))
    (when capture (setf (plist-get capture :invalidated) t))
    (when (and (pichat-job-conversation-p run)
               (member (plist-get run :state) '("scheduled" "queued" "starting" "running" "settling")))
      (condition-case err
          (progn
            (cond
             ((member (plist-get run :state) '("scheduled" "queued"))
              (pichat-job-cancel-queued store id nil reason evidence))
             ((member (plist-get run :state) '("starting" "running" "settling"))
              (pichat-job-advance
               store id (plist-get run :attempt)
               (if (and execution (not (pichat-job-execution-submitted execution))) "finished" "uncertain")
               (list :reason reason :result "cancelled" :safe-to-release t :invalidation evidence))))
            (pichat-job-executor--conversation-notice executor id capture)
            (if execution (pichat-job-executor--retire execution)
              (pichat-job-executor--conversation-forget executor id))
            (pichat-job-executor-schedule-refresh executor)
            (pichat-job-executor--changed executor)
            (pichat-job-executor-pump executor))
        (error
         ;; In-memory invalidation is final even if storage cannot record it.
         (pichat-job-executor-schedule-stop executor)
         (setf (pichat-job-executor-schedule-error executor)
               (format "Conversation scheduling stopped (%s); inspect storage" (car err)))
         (pichat-job-executor--changed executor))))))

(defun pichat-job-executor--conversation-observe (executor id capture)
  "Observe changes to CAPTURE while pending, without locking ordinary chat use."
  (let* ((session (plist-get capture :session))
         (handler
          (lambda (_session event payload)
            (let* ((execution (gethash id (pichat-job-executor-contexts executor)))
                   (submitted (and execution (pichat-job-execution-submitted execution)))
                   (own (and execution (eq pichat-job-executor--input-owner execution))))
              (when (and (eq capture (gethash id (pichat-job-executor-conversations executor)))
                         (or (memq event '(session-rebinding session-ended))
                             (and (eq event 'rpc-input-sending) (not own)
                                  (eq (pichat-rpc-command-intent (plist-get payload :command)) 'input)
                                  (not (and submitted (equal (plist-get payload :command) "extension_ui_response"))))
                             (and (eq event 'rpc-event) (not submitted)
                                  (memq (plist-get payload :normalized-event)
                                        '(agent-start compaction-start retry-start queue-update)))
                             (not (if submitted (pichat-job-conversation-source-p capture)
                                    (pichat-job-conversation-unchanged-p capture)))))
                (pichat-job-executor--conversation-invalidated
                 executor id (and submitted "Conversation ownership lost after possible submission; inspect before release")
                 (pichat-job-conversation-invalidation capture event (plist-get payload :command)))))))
         (kill (lambda () (pichat-job-executor--conversation-invalidated
                           executor id "Originating chat closed; scheduled prompt not sent or completion uncertain"
                           '(:code "ownership" :event "chat-closed" :fields ["chat-owner"])))))
    (setf (plist-get capture :handlers) nil (plist-get capture :kill-hook) kill)
    (dolist (event '(rpc-input-sending rpc-event session-rebinding session-ended
                    session-state-changed transcript-synchronized))
      (push (cons event handler) (plist-get capture :handlers))
      (pichat-on event handler session))
    (with-current-buffer (plist-get capture :buffer) (add-hook 'kill-buffer-hook kill nil t))))

(defun pichat-job-executor-conversation-schedule (executor capture prompt due replace accepted failure &optional current)
  "Verify and schedule reviewed CAPTURE/PROMPT/DUE in EXECUTOR.
REPLACE is an explicitly confirmed exact pending record.  ACCEPTED gets the
committed ID; FAILURE receives a bounded reason.  CURRENT guards a UI
invocation.
Nothing is sent and no runtime is acquired while preparing the schedule.

An error or quit before the durable commit calls FAILURE once; a quit then
propagates.  After the commit the run stays authorized: ACCEPTED is called
once and the run is observed even if a later step exits non-locally.  A later
error only reaches FAILURE as a report; a quit propagates."
  (when (or (pichat-job-executor-schedules-closed executor)
            (pichat-job-executor-schedule-error executor))
    (user-error "Scheduling is stopped; inspect storage and restart Emacs"))
  (unless (pichat-job--text-p prompt) (user-error "Enter a continuation prompt first"))
  (let ((session (plist-get capture :session)) (completing nil))
    (pichat-job-conversation-verify
     capture
     (lambda (type success failed)
       (let ((pichat-rpc-request-timeout pichat-jobs-control-timeout))
         (pichat-rpc-send
          session type nil
          (lambda (response _session)
            ;; Verification checks run in this RPC callback, after the
            ;; invoking command returned; retire them on error or quit.
            (condition-case err (funcall success response)
              ((error quit)
               (unless completing
                 (funcall failed "Cannot verify conversation; prompt not sent"))
               (when (eq (car err) 'quit) (signal (car err) (cdr err))))))
          (lambda (_response _session) (funcall failed "Cannot verify conversation; prompt not sent")))))
     (lambda ()
       (setq completing t)
       (let (id)
         (condition-case err
             (progn
               (unless (and (or (not current) (funcall current))
                            (pichat-job-conversation-current-p capture))
                 (user-error "Composer or conversation changed; reopen scheduling"))
               (setq id (pichat-job-conversation-schedule
                         (pichat-job-executor-store executor)
                         (pichat-job-conversation-spec capture prompt)
                         (plist-get capture :destination) due replace)))
           ((error quit)
            (funcall failure (pichat-chat-diagnostics-safe-summary-text (error-message-string err)))
            (when (eq (car err) 'quit) (signal (car err) (cdr err)))))
         (when id
           (condition-case err
               ;; Durable authorization precedes observers/timers; any missed
               ;; mutation still invalidates the captured input generation.
               (unwind-protect
                   (unwind-protect
                       (progn
                         (puthash id capture (pichat-job-executor-conversations executor))
                         (when replace
                           (pichat-job-executor--conversation-forget executor (plist-get replace :id))))
                     (funcall accepted id))
                 (if (pichat-job-conversation-current-p capture)
                     (progn
                       (pichat-job-executor--conversation-observe executor id capture)
                       (pichat-job-executor-schedule-refresh executor)
                       (pichat-job-executor--changed executor))
                   (pichat-job-executor--conversation-invalidated
                    executor id "Conversation changed after authorization; scheduled prompt not sent")))
             (error (funcall failure (pichat-chat-diagnostics-safe-summary-text (error-message-string err))))))))
     failure)))

(defun pichat-job-executor--conversation-start (executor run)
  "Borrow RUN's captured runtime only after durable ordinary admission."
  (let* ((id (plist-get run :id))
         (capture (gethash id (pichat-job-executor-conversations executor)))
         (session (plist-get capture :session))
         (execution (pichat-job-execution--create
                     :executor executor :id id :token (plist-get run :attempt)
                     :borrowed capture :session session :process (plist-get capture :process)
                     :generation (plist-get (plist-get run :destination) :process-generation)
                     :source (list (plist-get (plist-get run :destination) :session-id)
                                   (plist-get (plist-get run :destination) :session-file)))))
    (if (not (and capture (pichat-job-conversation-current-p capture)))
        (pichat-job-executor--conversation-invalidated executor id nil)
      (puthash id execution (pichat-job-executor-contexts executor))
      (setf (pichat-job-execution-previous-guard execution) (pichat-session-input-guard session)
            (pichat-job-execution-guard execution)
            (lambda (command)
              (unless (or (eq pichat-job-executor--input-owner execution)
                          (eq (pichat-rpc-command-intent command) 'inspection)
                          (equal command "extension_ui_response"))
                (user-error "A scheduled attempt owns this chat; use Jobs to cancel or inspect it")))
            (pichat-session-input-guard session) (pichat-job-execution-guard execution))
      (with-current-buffer (plist-get capture :buffer)
        (setf (pichat-job-execution-previous-buffer-execution execution) pichat-job-executor--buffer-execution)
        (setq pichat-job-executor--buffer-execution execution)
        (add-hook 'kill-buffer-query-functions #'pichat-job-executor--guard-kill nil t))
      (pichat-job-executor--listen execution)
      (pichat-job-executor--deadline execution "Scheduled attempt could not verify current conversation")
      (pichat-job-conversation-verify
       capture (lambda (type success _failure) (pichat-job-executor--call execution type nil success))
       (lambda ()
         ;; Pin verified execution evidence before transition hooks can reenter.
         (setf (plist-get capture :execution-model) (plist-get capture :verified-model))
         (unless (pichat-job-conversation-current-p capture (pichat-job-execution-guard execution))
           (pichat-job-executor--conversation-invalidated executor id nil))
         (when (and (pichat-job-executor--owned-p execution)
                    (pichat-job-executor--advance
                     execution "running" (list :runtime-id (pichat-session-runtime-id session)
                                               :session-file (pichat-session-session-file session)
                                               :execution-model (plist-get capture :verified-model))))
           (if (not (pichat-job-conversation-current-p capture (pichat-job-execution-guard execution)))
               (pichat-job-executor--conversation-invalidated executor id nil)
             (pichat-job-executor--clear-timer execution)
             (setf (pichat-job-execution-submitted execution) t)
             (let ((pichat-job-executor--input-owner execution)
                   (pichat-rpc-request-timeout pichat-jobs-control-timeout))
               (condition-case nil
                   (pichat-backend-submit-prompt
                    session (pichat-job-prompt run) nil nil
                    (lambda (response _session)
                      (when (pichat-job-executor--owned-p execution)
                        (if (equal (plist-get (plist-get response :data) :disposition) "started")
                            (setf (pichat-job-execution-accepted execution) t)
                          (pichat-job-executor--uncertain execution "Scheduled prompt was handled or queued, not attributable agent work"))))
                    (lambda (_response _session)
                      (pichat-job-executor--uncertain execution "Scheduled prompt submission failed or was ambiguous")))
                 (error (pichat-job-executor--uncertain execution "Scheduled prompt submission failed or was ambiguous")))))))
       (lambda (reason) (pichat-job-executor--conversation-invalidated executor id reason))
       (pichat-job-execution-guard execution)))
    execution))

(defun pichat-job-executor--listen (execution)
  "Subscribe EXECUTION before any prompt can produce fast events."
  (dolist (event '(rpc-event transcript-synchronized transcript-sync-failed
                  session-rebinding session-ended user-input-pending-changed))
    (let ((handler (lambda (_session event payload) (pichat-job-executor--event execution event payload))))
      (push (cons event handler) (pichat-job-execution-handlers execution))
      (pichat-on event handler (pichat-job-execution-session execution)))))

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
          (pichat-job-executor--listen execution)
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
                ;; A busy/invalid destination is not polled until it becomes idle,
                ;; even when shared capacity would otherwise delay admission.
                (when (and (pichat-job-conversation-p run)
                           (not (pichat-job-conversation-current-p
                                 (gethash (plist-get run :id) (pichat-job-executor-conversations executor)))))
                  (pichat-job-executor--conversation-invalidated
                   executor (plist-get run :id) nil))
                (let* ((store (pichat-job-executor-store executor))
                       (id (plist-get run :id))
                       (admission (pichat-job-admission store id pichat-jobs-max-concurrency)))
                  (when (eq (plist-get admission :ready) t)
                    (setq progress t)
                    (if (pichat-job-conversation-p run)
                        (pichat-job-executor--conversation-start
                         executor (pichat-job-claim store id pichat-jobs-max-concurrency))
                      (pichat-job-executor--start
                       executor (pichat-job-claim store id pichat-jobs-max-concurrency)))))))))
      (setf (pichat-job-executor-pumping executor) nil))))

(defun pichat-job-executor-submit (executor spec &optional job-id repeat-of continue-of guidance capture accepted)
  "Persist manual SPEC or saved JOB-ID in EXECUTOR before dispatching it.
CONTINUE-OF, GUIDANCE and CAPTURE describe a reviewed background continuation.
Optional ACCEPTED receives the durable run ID before refresh or dispatch, so a
composer can retire its submission even if a later presentation/pump step fails.
Return the new run ID without selecting its runtime or displaying a chat."
  (pichat-job-executor-submit-options
   executor (list :spec spec :job-id job-id :repeat-of repeat-of
                  :continue-of continue-of :guidance guidance :capture capture)
   accepted))

(defun pichat-job-executor-submit-options (executor options &optional accepted)
  "Persist OPTIONS before admission in EXECUTOR; notify ACCEPTED after commit."
  (let ((id (pichat-job-enqueue-options
             (pichat-job-executor-store executor)
             (plist-put (copy-sequence options) :queue-limit pichat-jobs-queue-limit))))
    (when accepted (funcall accepted id))
    (pichat-job-executor--changed executor)
    (pichat-job-executor-pump executor)
    id))

(defun pichat-job-executor-delete-run (executor id)
  "Delete finished run ID from EXECUTOR without dispatching any work."
  (pichat-job-run-delete (pichat-job-executor-store executor) id)
  (when-let* ((execution (gethash id (pichat-job-executor-contexts executor))))
    (pichat-job-executor--retire execution)
    (remhash id (pichat-job-executor-contexts executor)))
  (pichat-job-executor--changed executor))

(defun pichat-job-executor-delete-chain (executor id expected)
  "Delete the finished run chain of ID, confirmed as EXPECTED, from EXECUTOR.
Retire the members' executions only after the store commits."
  (dolist (member (pichat-job-chain-delete (pichat-job-executor-store executor) id expected))
    (when-let* ((execution (gethash member (pichat-job-executor-contexts executor))))
      (pichat-job-executor--retire execution)
      (remhash member (pichat-job-executor-contexts executor))))
  (pichat-job-executor--changed executor))

(defun pichat-job-executor-cancel (executor id)
  "Request cancellation of exact ID owned by EXECUTOR; never equate ack with exit."
  (let* ((run (pichat-job-record (pichat-job-executor-store executor) 'runs id))
         (execution (gethash id (pichat-job-executor-contexts executor))))
    (cond
     ((member (plist-get run :state) '("scheduled" "queued"))
      (pichat-job-cancel-queued (pichat-job-executor-store executor) id pichat-jobs-queue-limit)
      (pichat-job-executor--conversation-forget executor id)
      (pichat-job-executor-schedule-refresh executor)
      (pichat-job-executor--changed executor)
      (pichat-job-executor-pump executor))
     ((and execution (pichat-job-execution-cleanup execution)
           (pichat-job-executor--owned-p execution))
      (user-error "Completion captured; runtime cleanup is in progress"))
     ((and execution (pichat-job-executor--owned-p execution))
      (when (and (pichat-job-execution-borrowed execution)
                 (not (pichat-job-executor--source-p execution)))
        (user-error "Captured conversation changed; abort will not target another source"))
      (if (not (pichat-job-execution-submitted execution))
          (pichat-job-executor--stop-before-prompt execution "cancelled" "Cancelled before prompt")
        (setf (pichat-job-execution-cancelling execution) t)
        (pichat-job-executor--deadline execution "Cancellation did not establish settled execution")
        (pichat-job-executor--call execution "abort" nil (lambda (_ack) nil))
        (pichat-job-executor--changed executor)))
     (t (user-error "This run is not cancellable; inspect its recorded state")))))

(defun pichat-job-executor-session-run (executor session)
  "Return the ID of EXECUTOR's job run now executing in SESSION, or nil.
Retired executions (finished or uncertain runs) do not count."
  (when session
    (catch 'found
      (maphash (lambda (id execution)
                 (when (and (eq session (pichat-job-execution-session execution))
                            (not (pichat-job-execution-retired execution)))
                   (throw 'found id)))
               (pichat-job-executor-contexts executor))
      nil)))

(defun pichat-job-executor-run-session (executor run)
  "Return the retained runtime session that executed RUN for EXECUTOR, or nil.
Runtime IDs restart with each Emacs session, so a recorded ID alone may name
an unrelated runtime.  The session must still be the run's execution session
or still be bound to the run's recorded session file."
  (when-let* ((session (pichat-session-by-runtime-id (plist-get run :runtime-id))))
    (let ((execution (gethash (plist-get run :id) (pichat-job-executor-contexts executor)))
          (file (plist-get run :session-file)))
      (and (or (and execution (eq session (pichat-job-execution-session execution)))
               (and file (equal file (pichat-session-session-file session))))
           session))))

(defun pichat-job-executor-session-last-run (executor session)
  "Return the ID of EXECUTOR's latest job run executed in retained SESSION, or nil.
A run executing in SESSION comes first; otherwise the most recently created
run for which `pichat-job-executor-run-session' returns SESSION."
  (when session
    (or (pichat-job-executor-session-run executor session)
        (let ((runtime (pichat-session-runtime-id session))
              latest)
          (mapc (lambda (run)
                  (when (and (equal runtime (plist-get run :runtime-id))
                             (or (null latest)
                                 (string< (plist-get latest :created-at)
                                          (plist-get run :created-at)))
                             (eq session (pichat-job-executor-run-session executor run)))
                    (setq latest run)))
                (pichat-job-records (pichat-job-executor-store executor) 'runs))
          (plist-get latest :id)))))

(defun pichat-job-executor-recheck-exit (executor id callback)
  "Recheck exact SSH Pi exit for uncertain ID; call CALLBACK (SUCCESS REASON).
Never releases the slot: Pi exit does not prove tool descendants stopped."
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
  (when-let* ((execution (gethash id (pichat-job-executor-contexts executor))))
    (pichat-job-executor--retire execution t))
  (pichat-job-executor--changed executor)
  (pichat-job-executor-pump executor))

(provide 'pichat-job-executor)
;;; pichat-job-executor.el ends here
