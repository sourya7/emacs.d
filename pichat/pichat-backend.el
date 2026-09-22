;;; pichat-backend.el --- Backend contract for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Small backend boundary shared by session lifecycle and chat orchestration.
;; Backends own their transport/provider state; the UI asks only for explicit
;; operations and capabilities.  This module has no Pi RPC or llm dependency.

;;; Code:

(require 'cl-lib)

(declare-function pichat-session-backend "pichat-session" (session))

(defconst pichat-backend-pi 'pi
  "Backend identity used by existing Pi RPC sessions.")

(cl-defgeneric pichat-backend-id (backend)
  "Return stable identity symbol for BACKEND.")

(cl-defgeneric pichat-backend-label (backend)
  "Return a human-readable label for BACKEND.")

(cl-defgeneric pichat-backend-capabilities (backend)
  "Return operation capability symbols advertised by BACKEND.")

(cl-defgeneric pichat-backend-session-capabilities (backend session)
  "Return capabilities currently available from BACKEND for SESSION.
The default is `pichat-backend-capabilities'.  Backends with provider-specific
features may refine the result without exposing provider objects to the UI.")

(cl-defgeneric pichat-backend-start (backend session)
  "Start BACKEND for SESSION and return SESSION.")

(cl-defgeneric pichat-backend-stop (backend session)
  "Stop BACKEND for SESSION and return SESSION.")

(cl-defgeneric pichat-backend-alive-p (backend session)
  "Return non-nil when BACKEND considers SESSION alive.")

(cl-defgeneric pichat-backend-submit-preflight
    (backend session message images streaming-behavior)
  "Validate a prompt submission without mutating BACKEND or SESSION.")

(cl-defgeneric pichat-backend-submit
    (backend session message images streaming-behavior callback error-callback)
  "Submit one prompt through BACKEND for SESSION.")

(cl-defgeneric pichat-backend-abort (backend session retrying-p callback)
  "Abort SESSION through BACKEND.
RETRYING-P distinguishes an active retry delay from an active model run.")

(cl-defgeneric pichat-backend-clear-queue
    (backend session callback error-callback)
  "Clear queued messages for SESSION through BACKEND.")

(cl-defgeneric pichat-backend-new-conversation
    (backend session callback)
  "Start a new conversation for SESSION through BACKEND.")

(cl-defgeneric pichat-backend-request-state
    (backend session callback error-callback)
  "Request current SESSION state through BACKEND.")

(cl-defgeneric pichat-backend-request-transcript
    (backend session cursor callback error-callback)
  "Request SESSION transcript entries after optional CURSOR through BACKEND.")

(cl-defgeneric pichat-backend-request-stats
    (backend session callback error-callback)
  "Request usage statistics for SESSION through BACKEND.")

(cl-defgeneric pichat-backend-set-name (backend session name callback)
  "Set SESSION's local or remote display NAME through BACKEND.")

(cl-defgeneric pichat-backend-cancel-request (backend session request)
  "Cancel one backend-owned REQUEST for SESSION without aborting its run.")

(cl-defmethod pichat-backend-id ((backend t))
  (if (symbolp backend) backend (intern (format "%s" (type-of backend)))))

(cl-defmethod pichat-backend-label ((backend t))
  (format "%s" (pichat-backend-id backend)))

(cl-defmethod pichat-backend-capabilities ((_backend t)) nil)

(cl-defmethod pichat-backend-session-capabilities ((backend t) _session)
  (pichat-backend-capabilities backend))

(cl-defmethod pichat-backend-submit-preflight
  ((_backend t) _session _message _images _streaming-behavior)
  t)

(defun pichat-session-backend-object (session)
  "Return SESSION's backend object, defaulting legacy sessions to Pi."
  (or (pichat-session-backend session) pichat-backend-pi))

(defun pichat-session-backend-id (session)
  "Return stable backend identity for SESSION."
  (pichat-backend-id (pichat-session-backend-object session)))

(defun pichat-backend-capable-p (session capability)
  "Return non-nil when SESSION advertises CAPABILITY."
  (and session
       (memq capability
             (pichat-backend-session-capabilities
              (pichat-session-backend-object session) session))))

(defun pichat-backend-require-capability (session capability &optional operation)
  "Require SESSION to advertise CAPABILITY for OPERATION.
Signal a `user-error' before any backend side effect when unavailable."
  (unless session (user-error "No PiChat session"))
  (unless (pichat-backend-capable-p session capability)
    (user-error "%s is unavailable for the %s backend"
                (or operation (format "%s" capability))
                (pichat-backend-label
                 (pichat-session-backend-object session))))
  session)

(defun pichat-backend-scope-key (session scope-key)
  "Return backend-qualified registry key for SESSION and SCOPE-KEY.
Pi retains its historical key representation for compatibility."
  (let ((backend-id (pichat-session-backend-id session)))
    (if (eq backend-id 'pi)
        scope-key
      (list backend-id scope-key))))

(defun pichat-backend-start-session (session)
  "Start SESSION through its backend."
  (pichat-backend-start (pichat-session-backend-object session) session))

(defun pichat-backend-stop-session (session)
  "Stop SESSION through its backend."
  (pichat-backend-stop (pichat-session-backend-object session) session))

(defun pichat-backend-session-alive-p (session)
  "Return non-nil when SESSION is alive according to its backend."
  (and session
       (pichat-backend-alive-p
        (pichat-session-backend-object session) session)))

(defun pichat-backend-check-submit
    (session message &optional images streaming-behavior)
  "Validate submitting MESSAGE and optional IMAGES without side effects."
  (pichat-backend-require-capability session 'submit "Prompt submission")
  (when images
    (pichat-backend-require-capability session 'image-input "Image input"))
  (pichat-backend-submit-preflight
   (pichat-session-backend-object session) session message images
   streaming-behavior))

(defun pichat-backend-submit-prompt
    (session message &optional images streaming-behavior callback error-callback)
  "Submit MESSAGE and optional IMAGES for SESSION through its backend."
  (pichat-backend-check-submit session message images streaming-behavior)
  (pichat-backend-submit
   (pichat-session-backend-object session) session message images
   streaming-behavior callback error-callback))

(defun pichat-backend-abort-session (session &optional retrying-p callback)
  "Abort SESSION through its backend."
  (pichat-backend-require-capability session 'abort "Abort")
  (pichat-backend-abort
   (pichat-session-backend-object session) session retrying-p callback))

(defun pichat-backend-clear-session-queue
    (session callback &optional error-callback)
  "Clear SESSION's queued messages through its backend."
  (pichat-backend-require-capability session 'queue-clear "Queue clearing")
  (pichat-backend-clear-queue
   (pichat-session-backend-object session) session callback error-callback))

(defun pichat-backend-start-new-conversation (session &optional callback)
  "Start a new conversation for SESSION through its backend."
  (pichat-backend-require-capability
   session 'new-conversation "New conversation")
  (pichat-backend-new-conversation
   (pichat-session-backend-object session) session callback))

(defun pichat-backend-get-state (session callback &optional error-callback)
  "Request SESSION state through its backend."
  (pichat-backend-require-capability session 'state "State refresh")
  (pichat-backend-request-state
   (pichat-session-backend-object session) session callback error-callback))

(defun pichat-backend-get-transcript
    (session cursor callback &optional error-callback)
  "Request SESSION transcript after optional CURSOR through its backend."
  (pichat-backend-require-capability
   session 'transcript "Transcript synchronization")
  (pichat-backend-request-transcript
   (pichat-session-backend-object session) session cursor callback
   error-callback))

(defun pichat-backend-get-stats (session callback &optional error-callback)
  "Request SESSION usage statistics through its backend."
  (pichat-backend-require-capability session 'stats "Usage statistics")
  (pichat-backend-request-stats
   (pichat-session-backend-object session) session callback error-callback))

(defun pichat-backend-name-session (session name &optional callback)
  "Set SESSION's display NAME through its backend."
  (pichat-backend-require-capability session 'naming "Session naming")
  (pichat-backend-set-name
   (pichat-session-backend-object session) session name callback))

(defun pichat-backend-cancel-owned-request (session request)
  "Cancel SESSION's backend-owned REQUEST without aborting its active run."
  (when (and session request)
    (pichat-backend-cancel-request
     (pichat-session-backend-object session) session request)))

(provide 'pichat-backend)
;;; pichat-backend.el ends here
