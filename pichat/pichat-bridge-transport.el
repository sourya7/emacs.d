;;; pichat-bridge-transport.el --- Sentinel transport for PiChat bridge -*- lexical-binding: t; -*-

;;; Commentary:

;; The only place that recognises PiChat bridge requests.  The RPC
;; dispatcher and the startup barrier pass every extension UI request to
;; `pichat-bridge-transport-dispatch', which answers definitions and every
;; tool call that needs no prompt.  Only a call that needs approval reaches the
;; chat, which queues it and answers it with `pichat-bridge-transport-handle'.

;;; Code:

(require 'json)
(require 'pichat-rpc)
(require 'pichat-backend)
(require 'pichat-tool-bridge)

(defconst pichat-bridge-transport-tools-title "__pichat_tools_request__")
(defconst pichat-bridge-transport-tool-call-title "__pichat_tool_call__")

(defun pichat-bridge-transport--kind (raw &optional any-method)
  "Return `definitions' or `tool-call' for bridge request RAW, else nil.
The bridge sends both as `editor' dialogs; anything else is an ordinary
extension dialog, unless ANY-METHOD (for a request already known to be the
bridge's).  There is no handshake: the definitions reply's protocolVersion
is the bridge's compatibility check."
  (when (or any-method (equal (plist-get raw :method) "editor"))
    (let ((title (plist-get raw :title)))
      (cond ((equal title pichat-bridge-transport-tools-title) 'definitions)
            ((equal title pichat-bridge-transport-tool-call-title) 'tool-call)))))

(defun pichat-bridge-transport-request-p (raw)
  "Return non-nil if extension UI request RAW comes from the PiChat bridge."
  (and (pichat-bridge-transport--kind raw) t))

(defconst pichat-bridge-transport-empty-tools-reply
  "{\"protocolVersion\":1,\"tools\":[]}"
  "Definitions reply declaring no Emacs-defined tools.")

(defun pichat-bridge-transport-startup-reply (raw &optional session)
  "Return a noninteractive startup reply for RAW owned by SESSION, or nil.
Only definitions are supported here; never execute a tool.
Definitions contain only SESSION's selected Emacs-defined tools; without a
runtime (for example a catalogue probe) none are declared.  A failure while
building definitions declares none and records a diagnostic for SESSION, so
the bridge's request is always answered.  RAW's method is not checked here;
`pichat-bridge-transport-dispatch' decides which requests are the bridge's."
  (when (eq 'definitions (pichat-bridge-transport--kind raw t))
    (condition-case err
        (pichat-tool-bridge-definitions-json session)
      (error
       (when session
         (pichat-chat-diagnostics-record
          session :origin 'bridge-definitions :condition err
          :message (format "Emacs-defined tools were not declared: %s"
                           (error-message-string err))))
       pichat-bridge-transport-empty-tools-reply))))

(defun pichat-bridge-transport-dispatch (session raw &optional definitions-only)
  "Answer bridge request RAW for SESSION unless it needs approval.
Return nil when RAW is not a bridge request, `answered' once a reply was
sent, or `approval' for a tool call that must wait for the user; the chat
queues that one and answers it with `pichat-bridge-transport-handle'.  During
a restart no call waits: it is answered as restarting.  With
DEFINITIONS-ONLY (the startup barrier, where no model runs), tool calls
return nil too."
  (pcase (pichat-bridge-transport--kind raw)
    ('definitions
     (pichat-bridge-transport-handle session raw)
     'answered)
    ((and 'tool-call (guard (not definitions-only)))
     (if (and (not (pichat-session-restart-operation session))
              (pichat-tool-bridge-approval-required-p
               (or (plist-get raw :prefill) "{}") session))
         'approval
       (pichat-bridge-transport-handle session raw)
       'answered))))

(defun pichat-bridge-transport-handle (session raw)
  "Answer bridge request RAW for SESSION now.  Return non-nil if handled.
A tool call runs here, prompting first when it needs approval; use
`pichat-bridge-transport-dispatch' to defer such a call instead."
  (pichat-backend-require-capability
   session 'extension-ui "Pi extension bridge")
  (let* ((id (plist-get raw :id))
         (startup-reply (pichat-bridge-transport-startup-reply raw session))
         (operation (pichat-session-restart-operation session))
         (restarting (and operation
                          (memq (plist-get operation :phase)
                                '(starting loading synchronizing))))
         ;; Only the current process's bridge definitions request may send
         ;; operation-owned UI replies.  Never accept a previous process's
         ;; delayed event or execute a tool against a staged old snapshot.
         (pichat-rpc--operation-token
          (if (and restarting pichat-rpc--dispatch-process
                   (pichat-rpc--dispatch-current-p session))
              (plist-get operation :token)
            pichat-rpc--operation-token)))
    (when (and operation pichat-rpc--dispatch-process
               (not (pichat-rpc--dispatch-current-p session)))
      (user-error "Obsolete bridge process cannot rebind this runtime"))
    (cond
     (startup-reply
      (pichat-rpc-extension-ui-value session id startup-reply) t)
     ((eq 'tool-call (pichat-bridge-transport--kind raw t))
      (pichat-rpc-extension-ui-value
       session id
       (if operation
           (json-serialize
            '(:isError t :content [(:type "text"
                                     :text "PiChat runtime is restarting")]))
         (condition-case err
             (pichat-tool-bridge-execute-json
              (or (plist-get raw :prefill) "{}") session)
           ;; Even a malformed/unencodable result must resolve Pi's dialog.
           ;; Do not retry the tool: it may already have changed state.
           (error
            (json-serialize
             (list :isError t
                   :content (vector (list :type "text"
                                          :text (format "Emacs tool reply failed: %s"
                                                        (error-message-string err))))))))))
      t)
     (t nil))))

(provide 'pichat-bridge-transport)
;;; pichat-bridge-transport.el ends here
