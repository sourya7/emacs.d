;;; pichat-chat-input.el --- PiChat prompt and attachment lifecycle -*- lexical-binding: t; -*-

;;; Commentary:

;; Prompt history, submission recovery, and bounded image attachment state.
;; The chat orchestration layer supplies prompt markers and presentation helpers;
;; this module does not require `pichat-chat'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pichat-rpc)
(require 'pichat-backend)
(require 'pichat-attachments)
(require 'pichat-chat-completion)

(defvar pichat-chat-session)
(defvar pichat-chat--input-start)
(defvar pichat-chat--source-generation)
(defvar pichat-chat--editor-generation)
(defvar pichat-chat-ret-sends)

(defvar-local pichat-chat--pending-submissions nil
  "Submission recovery records keyed by Pi RPC request ID.")

(defvar-local pichat-chat--recoverable-submissions nil
  "Ambiguous submissions available for explicit manual recovery.")

(defvar-local pichat-chat--held-submissions nil
  "FIFO submissions owned by this chat until compaction succeeds.")

(defvar-local pichat-chat--held-release nil
  "Release phase: nil, `barrier', `ready', `sending', or `wait-start'.")

(defvar-local pichat-chat--held-start-seen nil
  "Whether an authoritative agent start crossed the current request barrier.")

(defvar-local pichat-chat--held-started-p nil
  "Whether any run has started since this compaction release began.")

(defvar-local pichat-chat--held-awaiting-start nil
  "Recovery-only copy of an acknowledged prompt awaiting agent_start.")

(defvar-local pichat-chat--held-timer nil
  "Owned deferred release/start-barrier timeout timer.")

(defvar-local pichat-chat--held-cycle nil
  "Identity invalidating callbacks when a release is abandoned.")

(defvar-local pichat-chat--held-external-prompt nil
  "Whether another compaction-end listener already submitted a prompt.")

(defvar-local pichat-chat--prompt-history nil
  "Previously submitted textual prompts, newest first.")

(defvar-local pichat-chat--history-index nil
  "Current zero-based position in `pichat-chat--prompt-history'.")

(defvar-local pichat-chat--history-draft ""
  "Draft saved before navigating prompt history.")

(defvar-local pichat-chat--submission-sequence 0
  "Monotonic identity source for pre-invocation submission bookkeeping.")

(defvar-local pichat-chat--pending-attachments nil
  "Bounded image records attached to the next prompt.")

(defvar-local pichat-chat--in-flight-attachments nil
  "Hash table mapping request IDs to immutable submitted image records.")

(declare-function pichat-chat-draft-capture "pichat-chat" (&optional buffer source-token))
(declare-function pichat-chat-draft-current-p "pichat-chat" (target))
(declare-function pichat-chat--clear-input "pichat-chat")
(declare-function pichat-chat--insert-prompt "pichat-chat")
(declare-function pichat-chat--input-text "pichat-chat")
(declare-function pichat-chat--set-input-text "pichat-chat" (text))
(declare-function pichat-chat--set-status "pichat-chat" (key text))

(defun pichat-chat-input-initialize ()
  "Initialize buffer-local prompt lifecycle and attachment state."
  (setq-local pichat-chat--pending-submissions
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--recoverable-submissions nil)
  (setq-local pichat-chat--prompt-history nil)
  (setq-local pichat-chat--history-index nil)
  (setq-local pichat-chat--history-draft "")
  (setq-local pichat-chat--submission-sequence 0)
  (setq-local pichat-chat--pending-attachments nil)
  (setq-local pichat-chat--in-flight-attachments
              (make-hash-table :test #'equal)))

(defun pichat-chat--record-prompt-history (message)
  "Record submitted MESSAGE and reset history navigation."
  (unless (or (string-empty-p message)
              (equal message (car pichat-chat--prompt-history)))
    (push message pichat-chat--prompt-history))
  (setq pichat-chat--history-index nil
        pichat-chat--history-draft ""))

;;;###autoload
(defun pichat-chat-history-previous ()
  "Restore the previous submitted prompt into the editable input area."
  (interactive)
  (unless pichat-chat--prompt-history
    (user-error "No previous PiChat prompts"))
  (if (null pichat-chat--history-index)
      (setq pichat-chat--history-draft (pichat-chat--input-text)
            pichat-chat--history-index 0)
    (setq pichat-chat--history-index
          (min (1+ pichat-chat--history-index)
               (1- (length pichat-chat--prompt-history)))))
  (pichat-chat--set-input-text
   (nth pichat-chat--history-index pichat-chat--prompt-history)))

;;;###autoload
(defun pichat-chat-history-next ()
  "Move toward newer prompt history, restoring the original draft at the end."
  (interactive)
  (when (null pichat-chat--history-index)
    (user-error "Already at current PiChat draft"))
  (if (> pichat-chat--history-index 0)
      (progn
        (cl-decf pichat-chat--history-index)
        (pichat-chat--set-input-text
         (nth pichat-chat--history-index pichat-chat--prompt-history)))
    (setq pichat-chat--history-index nil)
    (pichat-chat--set-input-text pichat-chat--history-draft)))

(defun pichat-chat--submission-response-id (response fallback)
  "Return RESPONSE request ID or FALLBACK."
  (or (plist-get response :id) fallback))

(defun pichat-chat--in-flight-attachment-count ()
  "Return the number of images retained by active prompt requests."
  (let ((count 0))
    (when (hash-table-p pichat-chat--in-flight-attachments)
      (maphash (lambda (_request-id attachments)
                 (cl-incf count (length attachments)))
               pichat-chat--in-flight-attachments))
    count))

(defun pichat-chat--refresh-attachment-status ()
  "Project compact pending and in-flight image state near the prompt."
  (pichat-chat--set-status
   'attachments
   (pichat-attachments-summary
    pichat-chat--pending-attachments
    (pichat-chat--in-flight-attachment-count))))

(defun pichat-chat--remove-submission-state (request-id response)
  "Remove and return submission state for REQUEST-ID and RESPONSE."
  (let* ((response-id (pichat-chat--submission-response-id response request-id))
         (record (or (gethash response-id pichat-chat--pending-submissions)
                     (gethash request-id pichat-chat--pending-submissions))))
    (remhash response-id pichat-chat--pending-submissions)
    (remhash request-id pichat-chat--pending-submissions)
    (remhash response-id pichat-chat--in-flight-attachments)
    (remhash request-id pichat-chat--in-flight-attachments)
    record))

(defun pichat-chat--submission-success (buffer request-id response)
  "Release accepted REQUEST-ID state in BUFFER using RESPONSE identity."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((record (pichat-chat--remove-submission-state
                     request-id response)))
        (pichat-chat--refresh-attachment-status)
        ;; Handled prompts (including input handlers without a slash command)
        ;; may never emit agent_settled.  Older Pi releases omit disposition;
        ;; retain the cached extension-command fallback for those responses.
        (let ((disposition (plist-get (plist-get response :data) :disposition)))
          (when (and record
                     (or (equal disposition "handled")
                         (and (null disposition)
                              (plist-get record :extension-command-p)))
                     (= (plist-get record :source-generation)
                        pichat-chat--source-generation))
            (pichat-chat--insert-prompt)))))))

(defun pichat-chat--attachment-ids (attachments)
  "Return identities from ATTACHMENTS."
  (mapcar (lambda (attachment) (plist-get attachment :id)) attachments))

(defun pichat-chat--new-pending-attachments-p (submitted)
  "Return non-nil when pending state contains images not in SUBMITTED."
  (let ((submitted-ids (pichat-chat--attachment-ids submitted)))
    (seq-some (lambda (attachment)
                (not (member (plist-get attachment :id) submitted-ids)))
              pichat-chat--pending-attachments)))

(defun pichat-chat--submission-failure (buffer request-id response)
  "Recover or retain rejected REQUEST-ID in BUFFER from RESPONSE."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((record (pichat-chat--remove-submission-state request-id response))
             (kind (plist-get response :pichat-failure-kind))
             (attachments (plist-get record :attachments)))
        (when record
          (if (or (plist-get record :held-p) kind
                  (/= (plist-get record :source-generation)
                      pichat-chat--source-generation)
                  (/= (plist-get record :editor-generation)
                      pichat-chat--editor-generation)
                  (not (string-empty-p (pichat-chat--input-text)))
                  (pichat-chat--new-pending-attachments-p attachments))
              (push record pichat-chat--recoverable-submissions)
            (pichat-chat--set-input-text (plist-get record :text))
            (setq pichat-chat--pending-attachments
                  (pichat-attachments-merge-unique
                   attachments pichat-chat--pending-attachments)))
          (pichat-chat--refresh-attachment-status)
          (pichat-chat--update-recovery-status))))))

(defun pichat-chat--update-recovery-status ()
  "Display the current recoverable submission count."
  (pichat-chat--set-status
   'recovery
   (when pichat-chat--recoverable-submissions
     (format "[%d submission%s available for recovery]"
             (length pichat-chat--recoverable-submissions)
             (if (= 1 (length pichat-chat--recoverable-submissions))
                 "" "s")))))

(defun pichat-chat--recovery-choices ()
  "Return completion choices for recoverable submission records."
  (cl-loop for record in pichat-chat--recoverable-submissions
           for index from 1
           for text = (string-trim (or (plist-get record :text) ""))
           for image-count = (length (plist-get record :attachments))
           for preview = (if (string-empty-p text)
                             (format "[%d image%s]" image-count
                                     (if (= image-count 1) "" "s"))
                           (truncate-string-to-width
                            (replace-regexp-in-string "[[:space:]]+" " " text)
                            60 nil nil "…"))
           collect (cons (format "%d: %s" index preview) record)))

;;;###autoload
(defun pichat-chat-recover-submission ()
  "Restore a failed submission without automatically resending it."
  (interactive)
  (unless pichat-chat--recoverable-submissions
    (user-error "No recoverable PiChat submission"))
  (unless (string-empty-p (pichat-chat--input-text))
    (user-error "Current PiChat editor is not empty"))
  (let* ((choices (pichat-chat--recovery-choices))
         (record (if (cdr choices)
                     (cdr (assoc (completing-read
                                  "Recover submission: " choices nil t)
                                 choices))
                   (cdar choices)))
         (attachments
          (pichat-attachments-merge-unique
           (plist-get record :attachments)
           pichat-chat--pending-attachments)))
    (pichat-attachments-validate-set attachments)
    (setq pichat-chat--recoverable-submissions
          (delq record pichat-chat--recoverable-submissions)
          pichat-chat--pending-attachments attachments)
    (pichat-chat--set-input-text (plist-get record :text))
    (pichat-chat--refresh-attachment-status)
    (pichat-chat--update-recovery-status)))

;;;###autoload
(defun pichat-chat-discard-recoverable-submissions ()
  "Discard all manually recoverable submissions and their retained images."
  (interactive)
  (setq pichat-chat--recoverable-submissions nil)
  (pichat-chat--update-recovery-status)
  (message "Discarded recoverable PiChat submissions"))

;;;###autoload
(defun pichat-chat-input-restore-fork-text (text)
  "Restore fork response TEXT into the current editable prompt.
When the prompt is empty, insert TEXT and return `inserted'.  When a current
prompt exists, ask before replacing it; return `replaced' when accepted.  If
replacement is declined, preserve the prompt, copy TEXT to the kill ring, and
return `copied'.  Pending, in-flight, and recoverable attachment state is never
changed by this operation."
  (unless (stringp text)
    (error "Fork prompt text must be a string"))
  (let ((current (pichat-chat--input-text)))
    (cond
     ((string-empty-p current)
      (pichat-chat--set-input-text text)
      'inserted)
     ((yes-or-no-p "Replace draft? ")
      (pichat-chat--set-input-text text)
      'replaced)
     (t
      (kill-new text)
      'copied))))

(defun pichat-chat-input-abandon-in-flight ()
  "Move held and in-flight submissions to manual recovery exactly once."
  (pichat-chat-input-abandon-held)
  (when (hash-table-p pichat-chat--pending-submissions)
    (maphash
     (lambda (_id record)
       (unless (memq record pichat-chat--recoverable-submissions)
         (push record pichat-chat--recoverable-submissions)))
     pichat-chat--pending-submissions)
    (clrhash pichat-chat--pending-submissions))
  (when (hash-table-p pichat-chat--in-flight-attachments)
    (clrhash pichat-chat--in-flight-attachments))
  (pichat-chat--refresh-attachment-status)
  (pichat-chat--update-recovery-status))

(defun pichat-chat--retained-attachments ()
  "Return unique pending, in-flight, and recoverable image records."
  (let ((attachments pichat-chat--pending-attachments))
    (dolist (record (append pichat-chat--held-submissions
                            (when pichat-chat--held-awaiting-start
                              (list pichat-chat--held-awaiting-start))))
      (setq attachments
            (pichat-attachments-merge-unique
             attachments (plist-get record :attachments))))
    (when (hash-table-p pichat-chat--in-flight-attachments)
      (maphash (lambda (_request-id records)
                 (setq attachments
                       (pichat-attachments-merge-unique attachments records)))
               pichat-chat--in-flight-attachments))
    (dolist (record pichat-chat--recoverable-submissions attachments)
      (setq attachments
            (pichat-attachments-merge-unique
             attachments (plist-get record :attachments))))))

(defun pichat-chat--add-attachment (attachment)
  "Add ATTACHMENT to pending state and refresh compact presentation."
  (setq pichat-chat--pending-attachments
        (pichat-attachments-add pichat-chat--pending-attachments attachment))
  (pichat-chat--refresh-attachment-status))

(defun pichat-chat--require-image-input ()
  "Require image input before acquiring or consuming attachment data."
  (unless pichat-chat-session
    (user-error "No PiChat session for this buffer"))
  (pichat-backend-require-capability
   pichat-chat-session 'image-input "Image input"))

;;;###autoload
(defun pichat-chat-attach-image-file (path)
  "Attach image PATH to the next PiChat prompt."
  (interactive "fAttach image file: ")
  (pichat-chat--require-image-input)
  (pichat-chat--add-attachment
   (pichat-attachments-read-image-file
    path (pichat-chat--retained-attachments)))
  (message "PiChat: attached %s" (file-name-nondirectory path)))

(defun pichat-chat--attachment-choices ()
  "Return completion choices for pending attachments."
  (cl-loop for attachment in pichat-chat--pending-attachments
           for index from 1
           collect
           (cons (format "%d: %s (%d bytes)" index
                         (or (plist-get attachment :name) "image")
                         (or (plist-get attachment :bytes) 0))
                 attachment)))

;;;###autoload
(defun pichat-chat-remove-attachment ()
  "Select and remove one pending PiChat image attachment."
  (interactive)
  (unless pichat-chat--pending-attachments
    (user-error "No pending PiChat attachments"))
  (let* ((choices (pichat-chat--attachment-choices))
         (attachment
          (if (cdr choices)
              (cdr (assoc (completing-read
                           "Remove attachment: " choices nil t)
                          choices))
            (cdar choices))))
    (setq pichat-chat--pending-attachments
          (pichat-attachments-remove
           pichat-chat--pending-attachments
           (plist-get attachment :id)))
    (pichat-chat--refresh-attachment-status)
    (message "PiChat: removed %s" (plist-get attachment :name))))

;;;###autoload
(defun pichat-chat-clear-attachments ()
  "Discard all pending PiChat attachments without touching in-flight images."
  (interactive)
  (setq pichat-chat--pending-attachments nil)
  (pichat-chat--refresh-attachment-status)
  (message "PiChat: cleared pending attachments"))

;;;###autoload
(defun pichat-chat-paste-clipboard-image ()
  "Attach a bounded image acquired from the system clipboard."
  (interactive)
  (pichat-chat--require-image-input)
  (let* ((origin (current-buffer))
         (session pichat-chat-session)
         (target (pichat-chat-draft-capture))
         (editor-generation pichat-chat--editor-generation)
         (attachment (pichat-attachments-read-clipboard
                      (pichat-chat--retained-attachments))))
    (unless (and (pichat-chat-draft-current-p target)
                 (eq (pichat-session-buffer session) origin)
                 (= editor-generation
                    (buffer-local-value 'pichat-chat--editor-generation origin)))
      (user-error "PiChat clipboard destination changed; acquire again"))
    (with-current-buffer origin
      ;; Output waits can run timers: validate all retained records again,
      ;; not only the pending list used by `pichat-chat--add-attachment'.
      (pichat-chat--require-image-input)
      (pichat-attachments--validate-capacity
       (pichat-chat--retained-attachments) (plist-get attachment :bytes))
      (pichat-chat--add-attachment attachment)))
  (message "PiChat: attached clipboard image"))

;;;###autoload
(defun pichat-chat-screenshot ()
  "Capture and attach a bounded screenshot."
  (interactive)
  (pichat-chat--require-image-input)
  (pichat-chat--add-attachment
   (pichat-attachments-capture-screenshot
    (pichat-chat--retained-attachments)))
  (message "PiChat: attached screenshot"))

;;;###autoload
(defun pichat-chat-ret ()
  "Send input or insert newline according to `pichat-chat-ret-sends'."
  (interactive)
  (if pichat-chat-ret-sends
      (pichat-chat-send-input)
    (newline)))

;;;###autoload
(defun pichat-chat-send-input ()
  "Send current text and pending images as one Pi prompt."
  (interactive)
  (unless pichat-chat-session
    (user-error "No PiChat session for this buffer"))
  (pichat-backend-require-capability
   pichat-chat-session 'submit "Prompt submission")
  (let* ((text (buffer-substring-no-properties
                pichat-chat--input-start (point-max)))
         (message (string-trim text))
         (attachments pichat-chat--pending-attachments))
    (when (and (string-empty-p message)
               (or (null attachments)
                   (not pichat-attachments-allow-image-only-prompts)))
      (user-error (if attachments
                      "Image-only PiChat prompts are disabled"
                    "Empty prompt")))
    (pichat-attachments-validate-set attachments)
    ;; Dynamic backend state (busy/uncertain) and image support must be checked
    ;; before prompt history, editor, or attachment ownership changes.
    (pichat-backend-check-submit
     pichat-chat-session message attachments nil)
    (when (pichat-chat-input-hold-p)
      (pichat-rpc--require-operation-ownership pichat-chat-session "prompt"))
    (pichat-chat--record-prompt-history message)
    (pichat-session-note-user-input pichat-chat-session)
    (let ((record (list :text text
                        :attachments attachments
                        :source-generation pichat-chat--source-generation
                        :editor-generation pichat-chat--editor-generation
                        :extension-command-p
                        (pichat-chat-completion-extension-command-p message))))
      (pichat-chat--clear-input)
      (setq pichat-chat--pending-attachments nil)
      (if (pichat-chat-input-hold-p)
          (pichat-chat-input-hold record "followUp")
        (condition-case err
            (pichat-chat-input-submit record nil)
          (error
           (pichat-chat--set-input-text text)
           (setq pichat-chat--pending-attachments attachments)
           (pichat-chat--refresh-attachment-status)
           (signal (car err) (cdr err))))))))

(defun pichat-chat-input-submit (record behavior &optional success failure)
  "Transfer RECORD to one request with BEHAVIOR and completion callbacks.
Install ownership before invoking providers, including inline providers."
  (let* ((buffer (current-buffer))
         (attachments (plist-get record :attachments))
         (message (string-trim (plist-get record :text)))
         (placeholder
          (format "local-submission:%d:%d"
                  pichat-chat--source-generation
                  (cl-incf pichat-chat--submission-sequence)))
         (request-id placeholder))
    ;; Install recovery ownership before invoking a backend: native providers
    ;; are allowed to complete or reject inline.
    (puthash placeholder record pichat-chat--pending-submissions)
    (puthash placeholder (copy-sequence attachments)
             pichat-chat--in-flight-attachments)
    (condition-case err
        (let ((returned
               (pichat-backend-submit-prompt
                pichat-chat-session message
                (and attachments
                     (pichat-attachments-wire-images attachments))
                behavior
                (lambda (response _session)
                  (when (and (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (gethash request-id pichat-chat--pending-submissions)))
                    (pichat-chat--submission-success buffer request-id response)
                    (when success (funcall success response))))
                (lambda (response _session)
                  (when (and (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (gethash request-id pichat-chat--pending-submissions)))
                    (pichat-chat--submission-failure buffer request-id response)
                    (when failure (funcall failure response)))))))
          (when (and (gethash placeholder pichat-chat--pending-submissions)
                     (null returned))
            (error "PiChat backend returned no submission identity"))
          (when (gethash placeholder pichat-chat--pending-submissions)
            (remhash placeholder pichat-chat--pending-submissions)
            (remhash placeholder pichat-chat--in-flight-attachments)
            (setq request-id returned)
            (puthash request-id record pichat-chat--pending-submissions)
            (puthash request-id (copy-sequence attachments)
                     pichat-chat--in-flight-attachments)))
      (error
       (remhash placeholder pichat-chat--pending-submissions)
       (remhash placeholder pichat-chat--in-flight-attachments)
       (signal (car err) (cdr err))))
    (pichat-chat--refresh-attachment-status)))

(defun pichat-chat-input-hold-p ()
  "Whether submissions must join this chat's compaction FIFO."
  (or pichat-chat--held-release
      (and (eq (pichat-session-backend pichat-chat-session) 'pi)
           (pichat-session-compacting-p pichat-chat-session)
           (not (pichat-session-streaming-p pichat-chat-session)))))

(defun pichat-chat-input-hold (record behavior)
  "Retain RECORD with intended BEHAVIOR until a successful compaction."
  (setq record (plist-put record :held-p t))
  (setq record (plist-put record :behavior behavior))
  (setq pichat-chat--held-submissions
        (nconc pichat-chat--held-submissions (list record)))
  (pichat-chat--insert-prompt)
  (pichat-chat--refresh-attachment-status))

(defun pichat-chat-input-hold-message (text behavior)
  "Hold minibuffer TEXT with BEHAVIOR, leaving the editor and images alone."
  (pichat-rpc--require-operation-ownership pichat-chat-session
                                          (if (equal behavior "steer") "steer" "prompt"))
  (pichat-chat-input-hold
   (list :text (substring-no-properties text) :attachments nil
         :source-generation pichat-chat--source-generation
         :editor-generation pichat-chat--editor-generation)
   behavior))

(defun pichat-chat-input-cancel-held-timer ()
  "Cancel the release's owned timer."
  (when (timerp pichat-chat--held-timer)
    (cancel-timer pichat-chat--held-timer))
  (setq pichat-chat--held-timer nil))

(defun pichat-chat-input-abandon-held ()
  "Move unsent held messages to recovery; invalidate release callbacks."
  (pichat-chat-input-cancel-held-timer)
  (setq pichat-chat--held-cycle nil
        pichat-chat--held-release nil)
  (dolist (record pichat-chat--held-submissions)
    (push record pichat-chat--recoverable-submissions))
  (when pichat-chat--held-awaiting-start
    (push pichat-chat--held-awaiting-start pichat-chat--recoverable-submissions))
  (setq pichat-chat--held-submissions nil
        pichat-chat--held-awaiting-start nil)
  (pichat-chat--update-recovery-status))

(defun pichat-chat-input-held-timer (seconds function)
  "Run FUNCTION after SECONDS only for the current buffer/release cycle."
  (pichat-chat-input-cancel-held-timer)
  (let ((buffer (current-buffer))
        (cycle pichat-chat--held-cycle))
    (setq pichat-chat--held-timer
          (run-at-time
           seconds nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq cycle pichat-chat--held-cycle)
                   (setq pichat-chat--held-timer nil)
                   (funcall function)))))))))

(defun pichat-chat-input-held-timeout ()
  "Recover instead of guessing whether a release submission started."
  (pichat-chat-input-abandon-in-flight))

(defun pichat-chat-input-compaction-end (raw)
  "Release held messages after successful RAW compaction, otherwise recover."
  (when pichat-chat--held-submissions
    (if (or (plist-get raw :aborted) (plist-get raw :errorMessage)
            (not (plist-get raw :result)))
        (pichat-chat-input-abandon-in-flight)
      (setq pichat-chat--held-cycle (make-symbol "held-release")
            pichat-chat--held-release 'barrier
            pichat-chat--held-start-seen nil
            pichat-chat--held-started-p (pichat-session-streaming-p pichat-chat-session)
            pichat-chat--held-external-prompt
            (pichat-chat-input-prompt-pending-p))
      ;; All compaction-end listeners must run first.  In particular an
      ;; unchanged chain finish waiter can already own an idle prompt.  Its
      ;; acknowledgment is NOT a start barrier: wait for agent_start instead.
      (pichat-chat-input-held-timer 0 #'pichat-chat-input-held-barrier))))

(defun pichat-chat-input-prompt-pending-p ()
  "Whether an external prompt still has an outstanding response."
  (cl-loop for pending being the hash-values of
           (pichat-session-pending-responses pichat-chat-session)
           thereis (equal "prompt" (pichat-rpc--pending-command pending))))

(defun pichat-chat-input-held-barrier ()
  "Serialize release behind any prompt issued by compaction-end listeners."
  (cond
   ((or pichat-chat--held-start-seen
        (pichat-session-streaming-p pichat-chat-session))
    (setq pichat-chat--held-release 'ready)
    (pichat-chat-input-release-next))
   ((or pichat-chat--held-external-prompt
        (pichat-chat-input-prompt-pending-p))
    (setq pichat-chat--held-release 'wait-start)
    (pichat-chat-input-held-timer 30 #'pichat-chat-input-held-timeout))
   (t
    (setq pichat-chat--held-release 'ready)
    (pichat-chat-input-release-next))))

(defun pichat-chat-input-agent-start ()
  "Advance the held FIFO only after an authoritative agent start."
  (when pichat-chat--held-release
    (setq pichat-chat--held-start-seen t
          pichat-chat--held-started-p t
          pichat-chat--held-awaiting-start nil)
    (when (eq pichat-chat--held-release 'wait-start)
      (pichat-chat-input-cancel-held-timer)
      (setq pichat-chat--held-release 'ready)
      (pichat-chat-input-release-next))))

(defun pichat-chat-input-release-next ()
  "Send one held message, serializing ownership, acknowledgment and start."
  (when (eq pichat-chat--held-release 'ready)
    (if (null pichat-chat--held-submissions)
        (progn
          (pichat-chat-input-cancel-held-timer)
          (setq pichat-chat--held-release nil pichat-chat--held-cycle nil))
      (let* ((record (car pichat-chat--held-submissions))
             (buffer (current-buffer))
             (cycle pichat-chat--held-cycle))
        (if (or (/= (plist-get record :source-generation)
                    pichat-chat--source-generation)
                (not (pichat-backend-session-alive-p pichat-chat-session))
                (pichat-session-compacting-p pichat-chat-session))
            (pichat-chat-input-abandon-in-flight)
          (pop pichat-chat--held-submissions)
          (setq pichat-chat--held-release 'sending
                pichat-chat--held-start-seen nil)
          (pichat-chat-input-held-timer 30 #'pichat-chat-input-held-timeout)
          (condition-case nil
              (pichat-chat-input-submit
               record
               ;; An idle steering-only FIFO must start a run, not strand a
               ;; queue-only steer.  Once running, Pi's atomic prompt/steer
               ;; operation preserves steering semantics even at settlement.
               (when (or pichat-chat--held-started-p
                         (pichat-session-streaming-p pichat-chat-session))
                 (plist-get record :behavior))
               (lambda (response)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (eq cycle pichat-chat--held-cycle)
                       (pichat-chat-input-cancel-held-timer)
                       (if (and (not (member (plist-get (plist-get response :data) :disposition)
                                             '("queued" "handled")))
                                (not pichat-chat--held-start-seen))
                           (progn
                             (setq pichat-chat--held-release 'wait-start
                                   pichat-chat--held-awaiting-start record)
                             (pichat-chat-input-held-timer 30 #'pichat-chat-input-held-timeout))
                         (setq pichat-chat--held-release 'ready)
                         (pichat-chat-input-release-next))))))
               (lambda (_response)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (eq cycle pichat-chat--held-cycle)
                       (pichat-chat-input-abandon-held))))))
            (error
             ;; Invocation failure has no acknowledgment; retain rather than
             ;; automatically retrying or replacing a concurrently edited draft.
             (push record pichat-chat--recoverable-submissions)
             (pichat-chat-input-abandon-held))))))))

(defun pichat-chat-input-confirm-close ()
  "Ask before closing a chat that owns held or releasing submissions."
  (or (not (or pichat-chat--held-submissions pichat-chat--held-release))
      (yes-or-no-p "Close chat and retain held submissions for manual recovery? ")))

(defun pichat-chat-input-close ()
  "Stop release and retain manual recovery on the runtime when chat closes."
  (when pichat-chat-session
    (pichat-chat-input-abandon-in-flight)
    (setf (pichat-session-input-recovery pichat-chat-session)
          pichat-chat--recoverable-submissions)))

(provide 'pichat-chat-input)
;;; pichat-chat-input.el ends here
