;;; pichat-job-conversation.el --- Exact existing-conversation captures -*- lexical-binding: t; -*-

;;; Commentary:
;; Data provenance is separate from live authority.  Never resolve a runtime by
;; stored ID, open a saved file, change startup settings, or reconnect here.

;;; Code:
(require 'pichat-job-launch)
(require 'pichat-chat)

(defun pichat-job-conversation--model (session)
  "Return SESSION's concrete provider/model reference."
  (let ((model (pichat-session-model session)))
    (when (and (pichat-job--text-p (plist-get model :provider))
               (pichat-job--text-p (plist-get model :id)))
      (concat (plist-get model :provider) "/" (plist-get model :id)))))

(defun pichat-job-conversation--digest (entries)
  "Hash complete append-ordered RPC ENTRIES without Lisp serialization."
  (pichat-job-data-digest (pichat-job-evidence-value (vconcat entries))))

(defun pichat-job-conversation--entries (cache)
  "Return CACHE's entries in append order, not just its active branch."
  (mapcar (lambda (id) (gethash id (pichat-entry-cache-entries-by-id cache)))
          (pichat-entry-cache-append-order cache)))

(defun pichat-job-conversation-source-p (capture &optional inspection)
  "Whether CAPTURE names its exact live process, chat, source and model.
INSPECTION permits retired authority, never a different process or source."
  (let ((session (plist-get capture :session)) (buffer (plist-get capture :buffer))
        (destination (plist-get capture :destination)))
    (and (or inspection (not (plist-get capture :invalidated))) (pichat-session-p session)
         (eq (pichat-backend-id (pichat-session-backend session)) 'pi)
         (memq (pichat-transport-kind (pichat-session-transport session)) '(local ssh))
         (pichat-job--text-p (pichat-session-id session))
         (integerp (pichat-session-process-generation session))
         (pichat-session-alive-p session)
         (eq (plist-get capture :process) (pichat-session-process session))
         (eql (plist-get destination :process-generation) (pichat-session-process-generation session))
         (equal (plist-get destination :runtime-id) (pichat-session-runtime-id session))
         (equal (plist-get destination :session-id) (pichat-session-id session))
         (equal (plist-get destination :session-file) (pichat-session-session-file session))
         (buffer-live-p buffer) (eq buffer (pichat-chat-owned-buffer session))
         (eql (plist-get destination :source-generation)
              (buffer-local-value 'pichat-chat--source-generation buffer))
         (equal (plist-get destination :model) (pichat-job-conversation--model session)))))

(defun pichat-job-conversation-unchanged-p (capture)
  "Whether CAPTURE's input intent and complete canonical history are unchanged."
  (and (pichat-job-conversation-source-p capture)
       (let* ((session (plist-get capture :session))
              (destination (plist-get capture :destination))
              (cache (pichat-chat-canonical-entry-cache session)))
         (and cache
              (eql (plist-get destination :input-generation) (pichat-session-input-generation session))
              (equal (plist-get destination :leaf) (pichat-entry-cache-leaf-id cache))
              (equal (plist-get destination :entries-digest)
                     (pichat-job-conversation--digest (pichat-job-conversation--entries cache)))))))

(defun pichat-job-conversation-current-p (capture &optional guard)
  "Whether CAPTURE can be sent now, optionally under exact owned GUARD."
  (and (pichat-job-conversation-unchanged-p capture)
       (let ((session (plist-get capture :session)))
         (and (eq guard (pichat-session-input-guard session))
              (not (pichat-session-restart-operation session))
              (eq (pichat-session-state session) 'idle)
              (not (pichat-session-streaming-p session))
              (not (pichat-session-compacting-p session))
              (not (pichat-session-retrying-p session))
              (with-current-buffer (plist-get capture :buffer)
                (and (not pichat-chat--sync-in-flight) (not pichat-chat--sync-pending)
                     (= 0 pichat-chat--pending-ui-count)
                     (= 0 (or (car pichat-chat--queue-counts) 0))
                     (= 0 (or (cdr pichat-chat--queue-counts) 0))
                     (= 0 (hash-table-count pichat-chat--pending-submissions))
                     (= 0 (hash-table-count pichat-chat--in-flight-attachments))))))))

(defun pichat-job-conversation-capture (session)
  "Capture synchronized SESSION for review, with no RPC or runtime mutation."
  (let* ((buffer (pichat-chat-owned-buffer session))
         (cache (pichat-chat-canonical-entry-cache session))
         (model (pichat-job-conversation--model session))
         (capture
          (and buffer cache model
               (list :session session :process (pichat-session-process session) :buffer buffer
                     :invalidated nil :handlers nil :kill-hook nil
                     :destination
                     (list :version 1 :kind "conversation"
                           :runtime-id (pichat-session-runtime-id session)
                           :session-id (pichat-session-id session)
                           :session-file (pichat-session-session-file session)
                           :process-generation (pichat-session-process-generation session)
                           :source-generation (buffer-local-value 'pichat-chat--source-generation buffer)
                           :input-generation (pichat-session-input-generation session)
                           :model model :leaf (pichat-entry-cache-leaf-id cache)
                           :last-entry (pichat-entry-cache-last-seen-id cache)
                           :entries-digest (pichat-job-conversation--digest
                                            (pichat-job-conversation--entries cache)))))))
    (unless (and capture (pichat-job-conversation-current-p capture))
      (user-error "Schedule from an idle, synchronized, unowned Pi chat with no pending input"))
    capture))

(defun pichat-job-conversation-spec (capture prompt)
  "Capture read-only settings for reviewed PROMPT, never a launch command."
  (let ((session (plist-get capture :session)))
    (pichat-job--copy
     (list :title "Scheduled continuation" :instructions prompt
           :directory (pichat-session-emacs-cwd session)
           :configuration
           (list :version 1 :mode "conversation"
                 :model (plist-get (plist-get capture :destination) :model)
                 :preset (pichat-job-launch--preset (pichat-session-preset-spec session))
                 :tools (pichat-job-launch--tools (pichat-session-tool-selection session))
                 :transport (pichat-job-launch--transport (pichat-session-transport session)))))))

(defun pichat-job-conversation-state-p (capture state)
  "Whether fresh authoritative STATE confirms CAPTURE's idle destination."
  (let ((destination (plist-get capture :destination)) (model (plist-get state :model)))
    (and (equal (plist-get state :sessionId) (plist-get destination :session-id))
         (equal (plist-get state :sessionFile) (plist-get destination :session-file))
         (equal (and (plist-get model :provider) (plist-get model :id)
                     (concat (plist-get model :provider) "/" (plist-get model :id)))
                (plist-get destination :model))
         (plist-member state :isStreaming) (not (plist-get state :isStreaming))
         (plist-member state :isCompacting) (not (plist-get state :isCompacting))
         (eql 0 (plist-get state :pendingMessageCount)))))

(defun pichat-job-conversation-verify (capture send success failure &optional guard)
  "Use SEND for fresh entries/state checks, then call SUCCESS or FAILURE.
SEND accepts (TYPE SUCCESS FAILURE); callbacks receive one response.  The caller
owns any guard, timeout and stale-invocation handling.  No settings are changed."
  (let ((phase 'entries))
    (cl-labels ((fail (reason)
                  (unless (eq phase 'done)
                    (setq phase 'done)
                    (funcall failure reason))))
      (funcall send "get_entries"
           (lambda (response)
            (when (eq phase 'entries)
             (setq phase 'state)
             (condition-case nil
                 (let ((data (plist-get response :data))
                       (destination (plist-get capture :destination)))
                   (unless (and (pichat-job-conversation-current-p capture guard)
                                (plist-member data :entries) (plist-member data :leafId)
                                (equal (plist-get data :leafId) (plist-get destination :leaf))
                                (equal (pichat-job-conversation--digest (plist-get data :entries))
                                       (plist-get destination :entries-digest)))
                     (error "Changed conversation"))
                   (funcall send "get_state"
                            (lambda (state)
                              (when (eq phase 'state)
                                (if (and (pichat-job-conversation-current-p capture guard)
                                         (pichat-job-conversation-state-p capture (plist-get state :data)))
                                    (progn (setq phase 'completing) (funcall success) (setq phase 'done))
                                  (fail "Conversation changed, busy, or queued; prompt not sent"))))
                            #'fail))
               (error (fail "Conversation history changed or could not be verified; prompt not sent")))))
           #'fail))))

(defun pichat-job-conversation-outcome (capture cache prompt)
  "Extract an attributable outcome from CACHE after CAPTURE and exact PROMPT.
Earlier assistant errors cannot label a successful retry/continuation as failed.
No old assistant response can be used when the new prompt produced no response."
  (let* ((branch (pichat-pi-entry-cache-active-branch cache))
         (boundary (plist-get (plist-get capture :destination) :leaf))
         (tail (if boundary (cdr (member (seq-find (lambda (entry) (equal boundary (plist-get entry :id)))
                                                  branch) branch)) branch))
         (users (seq-filter (lambda (entry) (equal "user" (plist-get (plist-get entry :message) :role))) tail))
         (assistant (car (last (seq-filter
                               (lambda (entry) (equal "assistant" (plist-get (plist-get entry :message) :role))) tail)))))
    (unless (and (or (not boundary) (seq-some (lambda (entry) (equal boundary (plist-get entry :id))) branch))
                 (= 1 (length users)) assistant
                 (equal prompt (let ((content (plist-get (plist-get (car users) :message) :content)))
                                 (if (stringp content) content
                                   (mapconcat (lambda (part) (or (plist-get part :text) "")) content ""))))
                 (member assistant (cdr (member (car users) tail))))
      (error "Settled response cannot be attributed to this scheduled prompt"))
    (let ((bad (member (plist-get (plist-get assistant :message) :stopReason) '("error" "aborted"))))
      (list :result (if bad "failed" "completed")
            :reason (and bad "Scheduled agent stopped abnormally")
            :boundary boundary :prompt-entry (plist-get (car users) :id)))))

(provide 'pichat-job-conversation)
;;; pichat-job-conversation.el ends here
