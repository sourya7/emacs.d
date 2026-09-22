;;; pichat-backend-pi.el --- Pi RPC backend for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Thin delegation from the backend contract to the existing Pi RPC runtime.
;; Keeping these methods separate ensures the backend contract itself has no
;; process, transport, or provider dependency.

;;; Code:

(require 'cl-lib)
(require 'pichat-backend)

(declare-function pichat-session-process "pichat-session" (session))
(declare-function pichat-rpc-start "pichat-rpc" (session))
(declare-function pichat-rpc-stop "pichat-rpc" (session))
(declare-function pichat-rpc-prompt "pichat-rpc"
                  (session message &optional images streaming-behavior callback
                           error-callback))
(declare-function pichat-rpc-abort "pichat-rpc" (session &optional callback))
(declare-function pichat-rpc-abort-retry "pichat-rpc"
                  (session &optional callback))
(declare-function pichat-rpc-clear-queue "pichat-rpc"
                  (session callback &optional error-callback))
(declare-function pichat-rpc-new-session "pichat-rpc"
                  (session &optional callback parent-session))
(declare-function pichat-rpc-get-state "pichat-rpc"
                  (session callback &optional error-callback))
(declare-function pichat-rpc-get-entries "pichat-rpc"
                  (session &optional since callback error-callback))
(declare-function pichat-rpc-get-session-stats "pichat-rpc"
                  (session callback &optional error-callback))
(declare-function pichat-rpc-set-session-name "pichat-rpc"
                  (session name &optional callback))
(declare-function pichat-rpc-cancel-request "pichat-rpc" (session request-id))

(defconst pichat-backend-pi-capabilities
  '(submit abort state transcript stats image-input
    lifecycle events process transport diagnostics diagnostic-view
    queue queue-clear compact new-conversation naming models thinking commands extension-ui
    session-history saved-sessions archive branching)
  "Capabilities supplied by the Pi RPC backend.")

(cl-defmethod pichat-backend-id ((_backend (eql pi))) 'pi)

(cl-defmethod pichat-backend-label ((_backend (eql pi))) "Pi")

(cl-defmethod pichat-backend-capabilities ((_backend (eql pi)))
  pichat-backend-pi-capabilities)

(cl-defmethod pichat-backend-start ((_backend (eql pi)) session)
  (pichat-rpc-start session))

(cl-defmethod pichat-backend-stop ((_backend (eql pi)) session)
  (pichat-rpc-stop session))

(cl-defmethod pichat-backend-alive-p ((_backend (eql pi)) session)
  (let ((process (pichat-session-process session)))
    (and process (process-live-p process))))

(cl-defmethod pichat-backend-submit
  ((_backend (eql pi)) session message images streaming-behavior callback
   error-callback)
  (pichat-rpc-prompt session message images streaming-behavior callback
                     error-callback))

(cl-defmethod pichat-backend-abort
  ((_backend (eql pi)) session retrying-p callback)
  (if retrying-p
      (pichat-rpc-abort-retry session callback)
    (pichat-rpc-abort session callback)))

(cl-defmethod pichat-backend-clear-queue
  ((_backend (eql pi)) session callback error-callback)
  (pichat-rpc-clear-queue session callback error-callback))

(cl-defmethod pichat-backend-new-conversation
  ((_backend (eql pi)) session callback)
  (pichat-rpc-new-session session callback))

(cl-defmethod pichat-backend-request-state
  ((_backend (eql pi)) session callback error-callback)
  (pichat-rpc-get-state session callback error-callback))

(cl-defmethod pichat-backend-request-transcript
  ((_backend (eql pi)) session cursor callback error-callback)
  (pichat-rpc-get-entries session cursor callback error-callback))

(cl-defmethod pichat-backend-request-stats
  ((_backend (eql pi)) session callback error-callback)
  (pichat-rpc-get-session-stats session callback error-callback))

(cl-defmethod pichat-backend-set-name
  ((_backend (eql pi)) session name callback)
  (pichat-rpc-set-session-name session name callback))

(cl-defmethod pichat-backend-cancel-request
  ((_backend (eql pi)) session request)
  (pichat-rpc-cancel-request session request))

(provide 'pichat-backend-pi)
;;; pichat-backend-pi.el ends here
