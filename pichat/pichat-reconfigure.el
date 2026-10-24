;;; pichat-reconfigure.el --- Guarded Pi runtime restart transaction -*- lexical-binding: t; -*-

;;; Commentary:

;; Exact-process preflight, bounded local shutdown and RPC phases, verified
;; saved-source or verified empty-source commit, and retained recovery state.  The launcher
;; exposes these only through its explicit reconfiguration Transient mode.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-backend)
(require 'pichat-rpc)
(require 'pichat-presets)
(require 'pichat-tool-selection)
(require 'pichat-chat)
(require 'pichat-pi)

(defcustom pichat-reconfigure-shutdown-timeout 5
  "Maximum seconds to wait for the old local Pi process to terminate."
  :type 'positive-integer
  :group 'pichat)

(defcustom pichat-reconfigure-preflight-timeout 10
  "Seconds to wait for an authoritative Pi state response during preflight."
  :type 'positive-integer
  :group 'pichat)

(defun pichat-reconfigure-captured-configuration (session)
  "Return detached resolved preset and Tools configuration of SESSION.
Never re-resolve an unchanged named preset against the current registry."
  (let ((spec (pichat-session-preset-spec session)))
    (unless (and (listp spec) (symbolp (plist-get spec :name)))
      (user-error "This runtime has no captured resolved preset"))
    (list :preset-spec (pichat-presets--copy spec)
          :tool-selection
          (pichat-presets--copy (pichat-session-tool-selection session)))))

(defun pichat-reconfigure-select-preset (configuration name)
  "Select current registry preset NAME for CONFIGURATION, resetting Tools.
An explicit selection resolves NAME even when it matches the captured name;
a missing registry preset can only be retained, never selected anew."
  (unless (plist-get configuration :preset-spec)
    (user-error "No captured PiChat preset configuration"))
  (let* ((spec (pichat-presets-resolve name))
         (tools (pichat-tool-selection-resolve spec)))
    (list :preset-spec spec :tool-selection tools)))

(defun pichat-reconfigure-select-tools (configuration selection)
  "Return CONFIGURATION with validated raw Tools SELECTION.
SELECTION is a plist containing :builtins and :mcp as accepted by the launch
Tools picker.  Reuse the captured preset specification rather than looking
up a mutable registry definition."
  (let ((spec (plist-get configuration :preset-spec)))
    (unless spec (user-error "No captured PiChat preset configuration"))
    (list :preset-spec (pichat-presets--copy spec)
          :tool-selection (pichat-tool-selection-resolve spec selection))))

(defun pichat-reconfigure-effective-change-p (previous requested)
  "Return non-nil if REQUESTED changes effective prompt or tool configuration.
PREVIOUS and REQUESTED are detached resolved configurations.  Changing only a
preset name or description is not a reason to restart the process."
  (let ((before (plist-get previous :preset-spec))
        (after (plist-get requested :preset-spec)))
    (unless (and before after)
      (user-error "Both PiChat preset configurations must be resolved"))
    (or (not (equal (plist-get before :system-prompt)
                    (plist-get after :system-prompt)))
        (not (equal (plist-get before :append-system-prompt)
                    (plist-get after :append-system-prompt)))
        (not (equal (pichat-tool-selection-args
                     (pichat-tool-selection-resolve
                      before (plist-get previous :tool-selection)))
                    (pichat-tool-selection-args
                     (pichat-tool-selection-resolve
                      after (plist-get requested :tool-selection))))))))

(defun pichat-reconfigure-capture-origin (session)
  "Capture the exact runtime, process lifetime, source and chat for SESSION."
  (let ((buffer (pichat-session-buffer session)))
    (list :session session
          :process (pichat-session-process session)
          :generation (pichat-session-process-generation session)
          :session-id (pichat-session-id session)
          :session-file (pichat-session-session-file session)
          :chat buffer
          :source-generation
          (and (buffer-live-p buffer)
               (buffer-local-value 'pichat-chat--source-generation buffer)))))

(defun pichat-reconfigure-origin-current-p (origin)
  "Return non-nil when ORIGIN still identifies the exact captured runtime."
  (let* ((session (plist-get origin :session))
         (buffer (plist-get origin :chat)))
    (and (pichat-session-p session)
         (eq (plist-get origin :process) (pichat-session-process session))
         (eql (plist-get origin :generation)
              (pichat-session-process-generation session))
         (equal (plist-get origin :session-id) (pichat-session-id session))
         (equal (plist-get origin :session-file)
                (pichat-session-session-file session))
         (eq buffer (pichat-session-buffer session))
         (or (null buffer)
             (and (buffer-live-p buffer)
                  (eq session (buffer-local-value 'pichat-chat-session buffer))
                  (eql (plist-get origin :source-generation)
                       (buffer-local-value 'pichat-chat--source-generation
                                           buffer)))))))

(defun pichat-reconfigure--chat-blockers (session)
  "Return blockers for unresolved work in SESSION's existing chat."
  (let ((buffer (pichat-session-buffer session)))
    (if (not (buffer-live-p buffer))
        '("The runtime has no live chat buffer to retain")
      (with-current-buffer buffer
        (let ((cache (pichat-chat-canonical-entry-cache session))
              blockers)
          (unless (and (derived-mode-p 'pichat-chat-mode)
                       (eq pichat-chat-session session))
            (push "The chat buffer is not owned by this runtime" blockers))
          (when (or (and (hash-table-p pichat-chat--pending-submissions)
                         (> (hash-table-count pichat-chat--pending-submissions) 0))
                    (and (hash-table-p pichat-chat--in-flight-attachments)
                         (> (hash-table-count pichat-chat--in-flight-attachments) 0)))
            (push "A prompt submission is pending or in flight" blockers))
          (when (> (or pichat-chat--pending-ui-count 0) 0)
            (push "An extension interaction is awaiting a response" blockers))
          (when (or pichat-chat--sync-in-flight pichat-chat--sync-pending
                    pichat-chat--restart-staging
                    pichat-chat--source-rebinding-p
                    (not pichat-chat--source-bound-p)
                    (not cache))
            (push "Canonical conversation synchronization is incomplete" blockers))
          ;; Pi's SessionManager.open reloads at the last appended entry; its
          ;; RPC contract does not expose setLeaf.  A historical active leaf
          ;; cannot be silently replaced by that last entry on restart.
          (when (and cache
                     (not (equal (pichat-entry-cache-leaf-id cache)
                                 (pichat-entry-cache-last-seen-id cache))))
            (push "The active branch cannot be restored by Pi RPC after reload"
                  blockers))
          (when (or (> (or (car pichat-chat--queue-counts) 0) 0)
                    (> (or (cdr pichat-chat--queue-counts) 0) 0))
            (push "A steering or follow-up message is queued" blockers))
          (nreverse blockers))))))

(defun pichat-reconfigure--unwritten-file-p (file)
  "Return non-nil when FILE is absent and Pi could create it locally."
  (condition-case nil
      (and (stringp file) (file-name-absolute-p file)
           (not (file-exists-p file))
           (file-directory-p (file-name-directory file))
           (file-writable-p (file-name-directory file)))
    (error nil)))

(defun pichat-reconfigure--empty-unwritten-source-p (origin)
  "Return non-nil if ORIGIN is a settled, empty, as-yet-unwritten local Pi session.
The fresh RPC entry check still has to confirm this before any process stops."
  (let* ((session (plist-get origin :session))
         (file (plist-get origin :session-file))
         (cache (and (pichat-session-p session)
                     (pichat-chat-canonical-entry-cache session))))
    (and (pichat-session-p session)
         (eq (pichat-session-persistence session) 'persistent)
         (eq (pichat-transport-kind (pichat-session-transport session)) 'local)
         (stringp file) (file-name-absolute-p file)
         (pichat-entry-cache-p cache)
         (equal (pichat-entry-cache-session-id cache)
                (plist-get origin :session-id))
         (equal (pichat-entry-cache-session-file cache) file)
         (pichat-pi-entry-cache-startup-metadata-only-p cache)
         (null (pichat-session-session-file-back-stack session))
         (null (pichat-session-session-file-forward-stack session))
         (pichat-reconfigure--unwritten-file-p file))))

(defun pichat-reconfigure--empty-entries-p (entries)
  "Return non-nil if fresh authoritative Pi ENTRIES have no conversation."
  (and (listp entries)
       (plist-member entries :entries)
       (plist-member entries :leafId)
       (pichat-pi-startup-metadata-only-p
        (plist-get entries :entries) (plist-get entries :leafId))))

(defun pichat-reconfigure-preflight-blockers (origin state &optional source-kind)
  "Return reasons why captured ORIGIN cannot restart given authoritative STATE.
STATE must be a successful, fresh Pi `get_state' data plist from the captured
process.  SOURCE-KIND is `saved' or `unwritten'; the latter still requires
separate fresh-entry verification.  This check has no side effects.
It must be repeated immediately before a restart transaction stops Pi."
  (let ((session (plist-get origin :session))
        blockers)
    (unless (pichat-reconfigure-origin-current-p origin)
      (push "The originating runtime, process, or conversation changed" blockers))
    (when (pichat-session-p session)
      (unless (eq (pichat-backend-id (pichat-session-backend session)) 'pi)
        (push "Only the Pi RPC backend supports restart" blockers))
      (unless (pichat-session-alive-p session)
        (push "The Pi process is not running" blockers))
      (when (and (pichat-session-restart-operation session)
                 (not (eq (plist-get origin :restart-token)
                          (plist-get (pichat-session-restart-operation session)
                                     :token))))
        (push "A runtime restart or recovery is already pending" blockers))
      ;; Deleting an SSH transport process does not prove that its remote Pi
      ;; child has exited.  Without that proof a replacement could create two
      ;; writers for the same saved session file.
      (unless (eq (pichat-transport-kind
                   (pichat-session-transport session)) 'local)
        (push "Remote Pi shutdown cannot yet be confirmed; restart is unavailable on SSH"
              blockers))
      (unless (eq (pichat-session-persistence session) 'persistent)
        (push "Ephemeral conversations cannot be restarted" blockers))
      (unless (eq (pichat-session-state session) 'idle)
        (push "The runtime is not idle" blockers))
      (when (or (pichat-session-streaming-p session)
                (pichat-session-compacting-p session)
                (pichat-session-retrying-p session))
        (push "A Pi run, retry, or compaction is active" blockers))
      (when (and pichat-rpc-command
                 (eq (pichat-transport-kind
                      (pichat-session-transport session)) 'local))
        (push "A complete local Pi command wrapper cannot be safely reconfigured"
              blockers))
      (let ((path (pichat-session-session-file session)))
        (if (not (and (stringp path) (file-name-absolute-p path)))
            (push "The conversation has no reloadable saved file" blockers)
          (unless (if (eq source-kind 'unwritten)
                      (pichat-reconfigure--empty-unwritten-source-p origin)
                    (condition-case nil
                        (let ((host-file
                               (pichat-transport-runtime-file-name
                                (pichat-session-transport session) path)))
                          (and (file-regular-p host-file)
                               (file-readable-p host-file)))
                      (error nil)))
            (push "The saved conversation file is inaccessible on the runtime target"
                  blockers))))
      (setq blockers (append (pichat-reconfigure--chat-blockers session)
                             blockers))
      (unless (and (listp state)
                   (equal (plist-get origin :session-id)
                          (plist-get state :sessionId))
                   (equal (plist-get origin :session-file)
                          (plist-get state :sessionFile)))
        (push "Pi reported a different or unknown conversation source" blockers))
      (when (or (plist-get state :isStreaming)
                (plist-get state :isCompacting)
                (not (plist-member state :pendingMessageCount))
                (not (eql 0 (plist-get state :pendingMessageCount))))
        (push "Pi is busy or its pending-message count is unknown" blockers))
      (unless (and (member (plist-get state :steeringMode)
                           '("all" "one-at-a-time"))
                   (member (plist-get state :followUpMode)
                           '("all" "one-at-a-time"))
                   (plist-member state :autoCompactionEnabled)
                   (memq (plist-get state :autoCompactionEnabled) '(nil t))
                   (let ((level (plist-get state :thinkingLevel)))
                     (and (stringp level) (not (string-blank-p level))))
                   (let* ((model (plist-get state :model))
                          (provider (and (listp model)
                                         (plist-get model :provider)))
                          (id (and (listp model) (plist-get model :id))))
                     (and (stringp provider) (not (string-blank-p provider))
                          (stringp id) (not (string-blank-p id)))))
        (push "Pi did not supply all settings required for safe restoration"
              blockers)))
    (unless (pichat-session-p session)
      (push "The originating runtime is unavailable" blockers))
    (nreverse blockers)))

(defun pichat-reconfigure-cancel-operation (session reason)
  "Retire active restart callbacks for SESSION and retain failure REASON.
Retain the operation's captured snapshots for explicit recovery.  Do not
clear a previously failed operation simply because the runtime is stopped."
  (when-let* ((operation (pichat-session-restart-operation session)))
    (unless (memq (plist-get operation :phase) '(failed committed))
      ;; Copy: old asynchronous callbacks retain OPERATION's former identity
      ;; and can no longer pass `eq' ownership checks even if they fire late.
      (setf (pichat-session-restart-operation session)
            (plist-put (plist-put (copy-sequence operation) :phase 'failed)
                       :failure reason))
      t)))

(defun pichat-reconfigure-stop-and-wait (session operation callback)
  "Stop local SESSION and call CALLBACK once after confirmed shutdown.
OPERATION must be the current restart operation in its stopping phase.  Call
CALLBACK with (SUCCESS REASON); cancellation or a replaced process suppresses
late callbacks.  Never start a replacement while the old process is live."
  (unless (and (eq operation (pichat-session-restart-operation session))
               (eq 'stopping (plist-get operation :phase))
               (eq 'local (pichat-transport-kind
                           (pichat-session-transport session)))
               (pichat-session-alive-p session))
    (user-error "No eligible local Pi process to stop for restart"))
  (let ((process (pichat-session-process session))
        (generation (pichat-session-process-generation session))
        (deadline (+ (float-time) pichat-reconfigure-shutdown-timeout))
        (finished nil)
        (timer nil))
    (cl-labels
        ((current ()
           (and (eq operation (pichat-session-restart-operation session))
                (eq 'stopping (plist-get operation :phase))
                (eq process (pichat-session-process session))
                (eql generation (pichat-session-process-generation session))))
         (finish (success reason)
           (unless finished
             (setq finished t)
             (when (timerp timer) (cancel-timer timer))
             (when (current) (funcall callback success reason))))
         (poll ()
           (when (and (not finished) (current))
             (cond
              ((and (not (process-live-p process))
                    (eq 'stopped (pichat-session-state session)))
               (finish t nil))
              ((>= (float-time) deadline)
               (finish nil "Timed out confirming old Pi process shutdown; replacement was not started"))
              (t (setq timer (run-at-time 0.05 nil #'poll)))))))
      (condition-case err
          (progn
            (pichat-rpc-stop session)
            (poll))
        (error (finish nil (format "Could not stop old Pi process: %s"
                                   (error-message-string err))))))))

(defun pichat-reconfigure-validated-command (session configuration state)
  "Resolve replacement argv without changing SESSION's committed configuration.
CONFIGURATION is a captured/selected resolved preset and Tools snapshot;
STATE is fresh, validated Pi get_state data for the active run-local model.
Recheck all settings and the command before stopping the original process."
  (let* ((preset (plist-get configuration :preset-spec))
         (tools (plist-get configuration :tool-selection))
         (model (plist-get state :model))
         (provider (and (listp model) (plist-get model :provider)))
         (id (and (listp model) (plist-get model :id))))
    (unless (and (pichat-session-p session)
                 (listp preset) (symbolp (plist-get preset :name))
                 (stringp provider) (not (string-blank-p provider))
                 (stringp id) (not (string-blank-p id)))
      (user-error "Replacement command lacks a resolved preset or active model"))
    (let ((snapshot (copy-pichat-session session)))
      (setf (pichat-session-preset-spec snapshot) (pichat-presets--copy preset)
            (pichat-session-tool-selection snapshot)
            (pichat-tool-selection-resolve preset tools)
            (pichat-session-startup-model snapshot)
            (concat provider "/" id))
      (let ((argv (pichat-rpc-build-command snapshot)))
        (unless (and (consp argv) (cl-every #'stringp argv))
          (user-error "Replacement Pi command is invalid"))
        (copy-sequence argv)))))

(defun pichat-reconfigure-settings-mismatches (expected actual)
  "List settings that differ between captured EXPECTED and fresh ACTUAL state.
Both values are Pi get_state data plists.  Treat absent fields as mismatches,
including fields whose valid value may be nil."
  (let (mismatches)
    (dolist (key '(:model :thinkingLevel :steeringMode :followUpMode
                          :autoCompactionEnabled))
      (unless (and (plist-member expected key) (plist-member actual key)
                   (equal (if (eq key :model)
                              (let ((model (plist-get expected key)))
                                (list (plist-get model :provider)
                                      (plist-get model :id)))
                            (plist-get expected key))
                          (if (eq key :model)
                              (let ((model (plist-get actual key)))
                                (list (plist-get model :provider)
                                      (plist-get model :id)))
                            (plist-get actual key))))
        (push key mismatches)))
    (nreverse mismatches)))

(defun pichat-reconfigure-validate-reload (origin retained state entries)
  "Build a verified replacement cache without mutating RETAINED or the chat.
ORIGIN identifies the saved source; STATE is fresh get_state data and ENTRIES
is full get_entries data from the replacement process.  Reject source, branch,
or entry changes rather than committing an unexpected conversation.  The
caller must separately verify the replacement process generation."
  (let ((id (plist-get origin :session-id))
        (file (plist-get origin :session-file)))
    (unless (and (stringp id) (not (string-blank-p id))
                 (stringp file) (file-name-absolute-p file)
                 (pichat-entry-cache-p retained)
                 (equal id (pichat-entry-cache-session-id retained))
                 (equal file (pichat-entry-cache-session-file retained)))
      (user-error "No synchronized snapshot of the original conversation"))
    (unless (and (listp state)
                 (equal id (plist-get state :sessionId))
                 (equal file (plist-get state :sessionFile)))
      (user-error "Reloaded Pi session identity differs from the original"))
    (unless (and (listp entries)
                 (plist-member entries :entries)
                 (plist-member entries :leafId))
      (user-error "Pi returned no authoritative entries or active leaf"))
    (let ((cache (pichat-pi-entry-cache-full
                  id file (plist-get entries :entries)
                  (plist-get entries :leafId))))
      (unless (and (equal (pichat-entry-cache-leaf-id retained)
                          (pichat-entry-cache-leaf-id cache))
                   (equal (pichat-entry-cache-append-order retained)
                          (pichat-entry-cache-append-order cache))
                   (cl-every
                    (lambda (entry-id)
                      (equal (gethash entry-id
                                      (pichat-entry-cache-entries-by-id retained))
                             (gethash entry-id
                                      (pichat-entry-cache-entries-by-id cache))))
                    (pichat-entry-cache-append-order retained)))
        (user-error "Reloaded conversation changed; retained snapshot was not replaced"))
      cache)))

(defun pichat-reconfigure-validate-empty-replacement (origin state entries)
  "Build an authoritative new empty Pi session cache after an unwritten restart.
The new Pi session must differ from ORIGIN; the PiChat runtime stays the same."
  (let ((id (plist-get state :sessionId))
        (file (plist-get state :sessionFile)))
    (unless (and (stringp id) (not (string-blank-p id))
                 (not (equal id (plist-get origin :session-id)))
                 (stringp file) (file-name-absolute-p file)
                 (not (equal file (plist-get origin :session-file)))
                 (pichat-reconfigure--empty-entries-p entries))
      (user-error "Replacement did not start a distinct empty Pi session"))
    (pichat-pi-entry-cache-full id file (plist-get entries :entries)
                                (plist-get entries :leafId))))

(defun pichat-reconfigure-request-preflight (origin callback)
  "Check ORIGIN against a fresh bounded `get_state' response.
Call CALLBACK with (BLOCKERS RESULT), where RESULT is a plist containing
raw :state and :source-kind (`saved' or `unwritten').  BLOCKERS is nil only
when the source and state are safe for the next stage.  This never stops Pi or changes its configuration.
An operation must recheck the origin and state before stopping the process."
  (let ((session (plist-get origin :session))
        (timer nil)
        (request-id nil)
        (finished nil))
    (cl-labels
        ((finish (blockers &optional state)
           (unless finished
             (setq finished t)
             (when (timerp timer) (cancel-timer timer))
             (funcall callback blockers state)))
         (expired ()
           (when (and request-id (not finished))
             (pichat-rpc-cancel-request session request-id))
           (finish '("Timed out waiting for Pi state; the runtime was not stopped")))
         (failed (response _session)
           (finish (list (format "Pi state request failed: %s"
                                 (or (plist-get response :error) "unknown error")))))
         (succeeded (response _session)
           (if (pichat-reconfigure-origin-current-p origin)
               (let* ((state (plist-get response :data))
                      (kind (if (pichat-reconfigure--empty-unwritten-source-p origin)
                                'unwritten 'saved))
                      (blockers (pichat-reconfigure-preflight-blockers
                                 origin state kind))
                      (result (list :state state :source-kind kind)))
                 (if (and (eq kind 'unwritten) (null blockers))
                     (let ((pichat-rpc--operation-token
                            (plist-get origin :restart-token)))
                       (setq request-id
                             (pichat-rpc-get-entries
                              session nil
                              (lambda (entries _session)
                                (if (and (pichat-reconfigure-origin-current-p origin)
                                         (pichat-reconfigure--empty-unwritten-source-p origin)
                                         (pichat-reconfigure--empty-entries-p
                                          (plist-get entries :data)))
                                    (finish (pichat-reconfigure-preflight-blockers
                                             origin state 'unwritten)
                                            result)
                                  (finish '("The unwritten Pi session is not empty or changed during preflight"))))
                              #'failed)))
                   (finish blockers result)))
             (finish '("The originating runtime, process, or conversation changed")))))
      (cond
       ((not (pichat-reconfigure-origin-current-p origin))
        (finish '("The originating runtime, process, or conversation changed")))
       ((not (and (eq (pichat-session-backend-id session) 'pi)
                  (pichat-session-alive-p session)))
        (finish '("The Pi RPC process is not available for preflight")))
       (t
        (condition-case err
            (progn
              (setq timer (run-at-time pichat-reconfigure-preflight-timeout
                                       nil #'expired))
              (setq request-id (pichat-rpc-get-state
                                session #'succeeded #'failed))
              ;; Some test transports call back before returning a request id.
              (when (and finished (timerp timer))
                (cancel-timer timer)))
          (error
           (finish (list (format "Pi state request could not start: %s"
                                 (error-message-string err)))))))))))

(defcustom pichat-reconfigure-phase-timeout 15
  "Maximum seconds for each Pi RPC readiness, reload, or sync request."
  :type 'positive-integer
  :group 'pichat)

(declare-function pichat--suspend-default-for-restart "pichat" (session))
(declare-function pichat--restore-default-after-restart "pichat" (session ticket))
(declare-function pichat-note-session-updated "pichat" (session))
(declare-function pichat--selected-file-key "pichat" (transport file))
(declare-function pichat--selected-file-conflict "pichat" (key))
(declare-function pichat--selected-file-reserved-p "pichat" (key))

(defun pichat-reconfigure--owned-p (operation &optional phase)
  "Return non-nil if OPERATION still owns its runtime and process lifetime.
PHASE, when non-nil, must match.  Before replacement startup there is no new
process generation to check."
  (let* ((session (plist-get operation :session))
         (buffer (plist-get operation :chat))
         (generation (plist-get operation :replacement-generation)))
    (and (eq operation (pichat-session-restart-operation session))
         (or (not phase) (eq phase (plist-get operation :phase)))
         (buffer-live-p buffer)
         (eq buffer (pichat-session-buffer session))
         (eq session (buffer-local-value 'pichat-chat-session buffer))
         (or (null generation)
             (and (eql generation (pichat-session-process-generation session))
                  (eq (plist-get operation :replacement-process)
                      (pichat-session-process session)))))))

(defun pichat-reconfigure--finish (operation success reason)
  "Complete OPERATION, delivering SUCCESS and REASON once."
  (let ((session (plist-get operation :session))
        (callback (plist-get operation :callback)))
    (when (pichat-reconfigure--owned-p operation)
      (cond
       ((and success (eq (plist-get operation :phase) 'preflight))
        ;; A no-op does not change the preferred designation or registry.
        (setf (pichat-session-restart-operation session) nil)
        (when callback (funcall callback t reason)))
       (success
        (setf (pichat-session-restart-operation session) nil)
        (pichat--restore-default-after-restart
         session (plist-get operation :preferred-ticket))
        (pichat-note-session-updated session)
        (when callback (funcall callback t reason)))
       ((eq (plist-get operation :phase) 'preflight)
        ;; Preflight failures must never stop or alter the original process.
        (setf (pichat-session-restart-operation session) nil)
        (when callback (funcall callback nil reason)))
       (t
        ;; Retain both configuration snapshots and the failure for explicit
        ;; recovery.  Copy the plist so all old callbacks lose `eq' ownership.
        (pichat-reconfigure-cancel-operation session reason)
        (when (pichat-session-alive-p session)
          (pichat-rpc-stop session))
        (when-let* ((buffer (plist-get operation :chat)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (pichat-chat--set-status
               'restart (format "[restart failed: %s; snapshot retained]"
                                (truncate-string-to-width reason 140 nil nil t))))))
        (when callback (funcall callback nil reason)))))))

(defun pichat-reconfigure--send (operation phase type payload continuation)
  "Send bounded TYPE/PAYLOAD for owned OPERATION in PHASE.
CONTINUATION receives the authoritative response data on success."
  (when (pichat-reconfigure--owned-p operation phase)
    (let* ((session (plist-get operation :session))
           (pichat-rpc--operation-token (plist-get operation :token))
           (pichat-rpc-request-timeout pichat-reconfigure-phase-timeout))
      (condition-case err
          (pichat-rpc-send
           session type payload
           (lambda (response _session)
             (when (pichat-reconfigure--owned-p operation phase)
               (condition-case condition
                   (funcall continuation (plist-get response :data))
                 (error
                  (pichat-reconfigure--finish
                   operation nil (error-message-string condition))))))
           (lambda (response _session)
             (when (pichat-reconfigure--owned-p operation phase)
               (pichat-reconfigure--finish
                operation nil
                (format "Pi %s failed: %s" type
                        (or (plist-get response :error) "no response"))))))
        (error (pichat-reconfigure--finish
                operation nil (format "Could not send Pi %s: %s"
                                      type (error-message-string err))))))))

(defun pichat-reconfigure--verify-idle-state (operation state)
  "Require a fresh idle STATE with OPERATION's expected source identity."
  (let ((origin (plist-get operation :origin)))
    (unless (and (if (plist-get operation :empty-unwritten)
                     (and (stringp (plist-get state :sessionId))
                          (not (equal (plist-get state :sessionId)
                                      (plist-get origin :session-id)))
                          (stringp (plist-get state :sessionFile))
                          (file-name-absolute-p (plist-get state :sessionFile))
                          (not (equal (plist-get state :sessionFile)
                                      (plist-get origin :session-file))))
                   (and (equal (plist-get state :sessionId)
                               (plist-get origin :session-id))
                        (equal (plist-get state :sessionFile)
                               (plist-get origin :session-file))))
                 (not (plist-get state :isStreaming))
                 (not (plist-get state :isCompacting))
                 (eql 0 (plist-get state :pendingMessageCount)))
      (user-error "Reloaded Pi session changed identity or is not idle"))))

(defun pichat-reconfigure--synchronize (operation state)
  "Fetch authoritative entries and commit OPERATION only when verified."
  (pichat-reconfigure--verify-idle-state operation state)
  (when-let* ((mismatches
               (pichat-reconfigure-settings-mismatches
                (plist-get operation :expected-state) state)))
    (user-error "Reloaded Pi settings differ: %s" mismatches))
  (plist-put operation :phase 'synchronizing)
  (pichat-reconfigure--send
   operation 'synchronizing "get_entries" nil
   (lambda (entries)
     (let* ((session (plist-get operation :session))
            (buffer (plist-get operation :chat))
            (cache (if (plist-get operation :empty-unwritten)
                       (pichat-reconfigure-validate-empty-replacement
                        (plist-get operation :origin) state entries)
                     (pichat-reconfigure-validate-reload
                      (plist-get operation :origin)
                      (plist-get operation :retained) state entries)))
            (requested (plist-get operation :active-configuration))
            (previous (plist-get operation :previous))
            (old-model (pichat-session-startup-model session)))
       (pichat-session-set-configuration
        session
        (pichat-presets--copy (plist-get requested :preset-spec))
        (pichat-presets--copy (plist-get requested :tool-selection)))
       (setf (pichat-session-startup-model session)
             (plist-get operation :active-model))
       (condition-case err
           (with-current-buffer buffer
             (if (plist-get operation :empty-unwritten)
                 (pichat-chat-commit-staged-empty-restart session cache)
               (pichat-chat-commit-staged-restart session cache)))
         (error
          (pichat-session-set-configuration
           session (plist-get previous :preset-spec)
           (plist-get previous :tool-selection))
          (setf (pichat-session-startup-model session) old-model)
          (signal (car err) (cdr err))))
       (pichat-reconfigure--finish operation t nil)))))

(defun pichat-reconfigure--restore-settings (operation state)
  "Restore supported settings of OPERATION, then verify state and entries."
  (pichat-reconfigure--verify-idle-state operation state)
  (let* ((expected (plist-get operation :expected-state))
         (mismatches (pichat-reconfigure-settings-mismatches expected state))
         (key (car mismatches))
         (command (pcase key
                    (:thinkingLevel "set_thinking_level")
                    (:steeringMode "set_steering_mode")
                    (:followUpMode "set_follow_up_mode")
                    (:autoCompactionEnabled "set_auto_compaction"))))
    (cond
     ((null key) (pichat-reconfigure--synchronize operation state))
     ((null command)
      ;; set_model changes Pi's persistent preference.  It is not a run-local
      ;; restoration mechanism and must not be used for this transaction.
      (user-error "Active model was not preserved by Pi session reload"))
     (t
      (pichat-reconfigure--send
       operation 'loading command
       (pcase key
         (:thinkingLevel (list :level (plist-get expected key)))
         ((or :steeringMode :followUpMode)
          (list :mode (plist-get expected key)))
         (:autoCompactionEnabled
          (list :enabled (if (plist-get expected key) t :json-false))))
       (lambda (_data)
         (pichat-reconfigure--send
          operation 'loading "get_state" nil
          (lambda (next)
            (when (equal (plist-get next key) (plist-get state key))
              (user-error "Pi did not restore %s" key))
            (pichat-reconfigure--restore-settings operation next)))))))))

(defun pichat-reconfigure--start-replacement (operation)
  "Start OPERATION's validated replacement after confirmed old-process exit."
  (let* ((session (plist-get operation :session))
         (old (plist-get (plist-get operation :origin) :process)))
    (when (process-live-p old)
      (user-error "Old Pi process remains live; replacement was not started"))
    (plist-put operation :phase 'starting)
    (pichat-rpc-start session (plist-get operation :command))
    (unless (pichat-session-alive-p session)
      (user-error "Replacement Pi process could not start"))
    (plist-put operation :replacement-process (pichat-session-process session))
    (plist-put operation :replacement-generation
               (pichat-session-process-generation session))
    (pichat-reconfigure--send
     operation 'starting "get_state" nil
     (lambda (ready-state)
       (plist-put operation :phase 'loading)
       (if (plist-get operation :empty-unwritten)
           (pichat-reconfigure--restore-settings operation ready-state)
         (pichat-reconfigure--send
          operation 'loading "switch_session"
        (list :sessionPath
              (plist-get (plist-get operation :origin) :session-file))
        (lambda (data)
          (when (plist-get data :cancelled)
            (user-error "Pi extension cancelled reloading the saved session"))
          (pichat-reconfigure--send
           operation 'loading "get_state" nil
           (lambda (state)
             (pichat-reconfigure--restore-settings operation state))))))))))

(defun pichat-reconfigure--stop-then-start (operation &optional allow-stopped)
  "Stop the owned local process, then start OPERATION's replacement.
Only recovery may pass ALLOW-STOPPED for an already-confirmed stopped runtime."
  (when (pichat-reconfigure--owned-p operation 'stopping)
    (cl-labels ((start ()
                  (when (pichat-reconfigure--owned-p operation 'stopping)
                    (condition-case err
                        (pichat-reconfigure--start-replacement operation)
                      (error (pichat-reconfigure--finish
                              operation nil (error-message-string err)))))))
      (if (pichat-session-alive-p (plist-get operation :session))
          (condition-case err
              (pichat-reconfigure-stop-and-wait
               (plist-get operation :session) operation
               (lambda (success reason)
                 (when (pichat-reconfigure--owned-p operation 'stopping)
                   (if success (start)
                     (pichat-reconfigure--finish operation nil reason)))))
            (error (pichat-reconfigure--finish
                    operation nil (error-message-string err))))
        (if allow-stopped (start)
          (pichat-reconfigure--finish
           operation nil "Old Pi process was not live; replacement was not started"))))))

(defun pichat-reconfigure--continue-after-preflight (operation requested result)
  "Validate REQUESTED and begin stopping OPERATION after fresh safe RESULT."
  (let* ((session (plist-get operation :session))
         (origin (plist-get operation :origin))
         (buffer (plist-get operation :chat))
         (state (plist-get result :state))
         (unwritten (eq (plist-get result :source-kind) 'unwritten)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Conversation changed during preflight"))
    (when (and unwritten
               (not (pichat-reconfigure--empty-unwritten-source-p origin)))
      (user-error "The unwritten Pi session changed before restart"))
    (when-let* ((blockers (pichat-reconfigure-preflight-blockers
                           origin state (plist-get result :source-kind))))
      (user-error "%s" (string-join blockers "; ")))
    (let* ((previous (pichat-reconfigure-captured-configuration session))
           (command (pichat-reconfigure-validated-command
                     session requested state))
           (retained (with-current-buffer buffer
                       (pichat-chat-canonical-entry-cache session))))
      (if (not (pichat-reconfigure-effective-change-p previous requested))
          (pichat-reconfigure--finish
           operation t "No effective configuration changes")
        (plist-put operation :previous previous)
        (plist-put operation :requested (pichat-presets--copy requested))
        (plist-put operation :active-configuration
                   (pichat-presets--copy requested))
        (plist-put operation :expected-state (copy-tree state t))
        (plist-put operation :empty-unwritten unwritten)
        (plist-put operation :retained retained)
        (plist-put operation :command command)
        (plist-put operation :active-model
                   (concat (plist-get (plist-get state :model) :provider)
                           "/" (plist-get (plist-get state :model) :id)))
        (with-current-buffer buffer (pichat-chat-stage-restart session))
        (plist-put operation :preferred-ticket
                   (pichat--suspend-default-for-restart session))
        (plist-put operation :phase 'stopping)
        (pichat-reconfigure--stop-then-start operation)))))

(defun pichat-reconfigure-restart (origin requested callback)
  "Restart ORIGIN with resolved REQUESTED preset/Tools, reporting to CALLBACK.
CALLBACK receives (SUCCESS REASON).  Post-stop failures retain the canonical
snapshot and both captured configuration choices for recovery.  An unwritten,
verified conversation-free source starts a new Pi session with a new ID.
The launcher enters this operation only after explicit confirmation."
  (let* ((session (plist-get origin :session))
         (token (make-symbol "pichat-restart"))
         (owned-origin (plist-put (copy-sequence origin) :restart-token token))
         ;; Captured fields survive retry/restore.  Attempt-local fields
         ;; (:phase, :callback, :command, :active-configuration and replacement
         ;; identity) are set anew before each stop/start attempt.  Cancelling
         ;; copies the plist to retire callbacks by object identity.
         (operation (list :token token :phase 'preflight :session session
                          :chat (plist-get origin :chat) :origin owned-origin
                          :owner-scope-key
                          (and (pichat-session-p session)
                               (pichat-session-owner-scope-key session))
                          :transport
                          (and (pichat-session-p session)
                               (pichat-session-transport session))
                          :callback callback)))
    (unless (and (pichat-session-p session)
                 (not (pichat-session-restart-operation session))
                 (pichat-reconfigure-origin-current-p origin))
      (user-error "Runtime or conversation changed; reopen reconfiguration"))
    (setf (pichat-session-restart-operation session) operation)
    (let ((pichat-rpc--operation-token token))
      (pichat-reconfigure-request-preflight
       owned-origin
       (lambda (blockers result)
         (when (pichat-reconfigure--owned-p operation 'preflight)
           (condition-case err
               (if blockers
                   (pichat-reconfigure--finish
                    operation nil (string-join blockers "; "))
                 (pichat-reconfigure--continue-after-preflight
                  operation requested result))
             (error (pichat-reconfigure--finish
                     operation nil (error-message-string err))))))))
    operation))

(defun pichat-reconfigure--recovery-attempt (failed configuration command callback)
  "Return a fresh attempt from FAILED with CONFIGURATION, COMMAND and CALLBACK.
Copying retires any late callbacks owned by the previous attempt."
  (let ((operation (copy-sequence failed)))
    (plist-put operation :phase 'stopping)
    (plist-put operation :failure nil)
    (plist-put operation :callback callback)
    (plist-put operation :active-configuration
               (pichat-presets--copy configuration))
    (plist-put operation :command command)
    (plist-put operation :replacement-generation nil)
    (plist-put operation :replacement-process nil)
    operation))

(defun pichat-reconfigure-recover (session choice callback)
  "Recover failed SESSION by retrying REQUESTED or restoring PREVIOUS config.
CHOICE is `retry' or `restore'; CALLBACK receives (SUCCESS REASON).  The
original saved source (or unwritten empty source) and retained canonical snapshot
are revalidated before stopping any failed replacement process.  Never load a
second writer while the failed process remains live."
  (let* ((failed (pichat-session-restart-operation session))
         (buffer (plist-get failed :chat))
         (origin (plist-get failed :origin))
         (requested (pcase choice
                      ('retry (plist-get failed :requested))
                      ('restore (plist-get failed :previous))
                      (_ (user-error "Choose retry or restore for recovery"))))
         (file (plist-get origin :session-file)))
    (unless (and (memq (plist-get failed :phase) '(failed left-stopped))
                 (pichat-entry-cache-p (plist-get failed :retained))
                 (buffer-live-p buffer)
                 (eq buffer (pichat-session-buffer session))
                 (eq session (buffer-local-value 'pichat-chat-session buffer))
                 (with-current-buffer buffer pichat-chat--restart-staging)
                 (eq 'local (pichat-transport-kind
                             (pichat-session-transport session)))
                 (equal (pichat-session-owner-scope-key session)
                        (plist-get failed :owner-scope-key))
                 (eq (pichat-session-transport session)
                     (plist-get failed :transport))
                 (stringp file) (file-name-absolute-p file)
                 (if (plist-get failed :empty-unwritten)
                     (and (pichat-pi-entry-cache-startup-metadata-only-p
                           (plist-get failed :retained))
                          (pichat-reconfigure--unwritten-file-p file))
                   (and (file-regular-p file) (file-readable-p file))))
      (user-error "Failed restart no longer has a safe saved source to recover"))
    (unless (plist-get failed :empty-unwritten)
      (let* ((key (pichat--selected-file-key
                    (pichat-session-transport session) file))
             (other (pichat--selected-file-conflict key)))
        (when (and other (not (eq other session)))
          (user-error "Another PiChat runtime is already writing this saved conversation"))
        (when (pichat--selected-file-reserved-p key)
          (user-error "Another PiChat launch is loading this saved conversation"))))
    (let* ((command (pichat-reconfigure-validated-command
                     session requested (plist-get failed :expected-state)))
           (operation (pichat-reconfigure--recovery-attempt
                       failed requested command callback)))
      (setf (pichat-session-restart-operation session) operation)
      (pichat-reconfigure--stop-then-start operation t)
      operation)))

(defun pichat-reconfigure-leave-stopped (session)
  "Leave failed SESSION stopped with its retained snapshot and recovery info.
A live failed replacement must first be stopped and confirmed by the user;
never silently permit an unowned writer to remain active."
  (let ((operation (pichat-session-restart-operation session)))
    (unless (and (memq (plist-get operation :phase) '(failed left-stopped))
                 (not (pichat-session-alive-p session)))
      (user-error "Stop the failed Pi process before leaving it stopped"))
    (setf (pichat-session-restart-operation session)
          (plist-put (copy-sequence operation) :phase 'left-stopped))
    (when-let* ((buffer (pichat-session-buffer session)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (pichat-chat--set-status
           'restart "[runtime stopped; last synchronized snapshot retained]"))))
    t))

(provide 'pichat-reconfigure)
;;; pichat-reconfigure.el ends here
