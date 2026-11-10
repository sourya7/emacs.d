;;; pichat-bridge-transport.el --- Sentinel transport for PiChat bridge -*- lexical-binding: t; -*-

;;; Code:

(require 'json)
(require 'pichat-rpc)
(require 'pichat-backend)
(require 'pichat-tool-bridge)

(defconst pichat-bridge-transport-handshake-title "__pichat_handshake__")
(defconst pichat-bridge-transport-tools-title "__pichat_tools_request__")
(defconst pichat-bridge-transport-tool-call-title "__pichat_tool_call__")

(defun pichat-bridge-transport-handle-p (raw)
  "Return non-nil if RAW extension UI request is a PiChat sentinel request."
  (let ((title (plist-get raw :title)))
    (member title (list pichat-bridge-transport-handshake-title
                        pichat-bridge-transport-tools-title
                        pichat-bridge-transport-tool-call-title))))

(defun pichat-bridge-transport-user-input-required-p (session raw)
  "Return non-nil when bridge sentinel RAW needs interactive SESSION input."
  (and (equal pichat-bridge-transport-tool-call-title
              (plist-get raw :title))
       (pichat-tool-bridge-approval-required-p
        (or (plist-get raw :prefill) "{}") session)))

(defun pichat-bridge-transport-startup-request-p (raw)
  "Return non-nil if RAW is a handshake or definitions request.
These are answered by `pichat-bridge-transport-startup-reply' without user
input."
  (member (plist-get raw :title)
          (list pichat-bridge-transport-handshake-title
                pichat-bridge-transport-tools-title)))

(defconst pichat-bridge-transport-empty-tools-reply
  "{\"protocolVersion\":1,\"tools\":[]}"
  "Definitions reply declaring no Emacs-defined tools.")

(defun pichat-bridge-transport-startup-reply (raw &optional session)
  "Return a noninteractive startup reply for RAW owned by SESSION, or nil.
Only handshake and definitions are supported here; never execute a tool.
Definitions contain only SESSION's selected Emacs-defined tools; without a
runtime (for example a catalogue probe) none are declared.  A failure while
building definitions declares none and records a diagnostic for SESSION, so
the bridge's request is always answered."
  (cond
   ((equal (plist-get raw :title) pichat-bridge-transport-handshake-title)
    "{\"protocolVersion\":1,\"capabilities\":[\"tools\",\"tool-errors\",\"dynamic-tool-refresh\"]}")
   ((equal (plist-get raw :title) pichat-bridge-transport-tools-title)
    (condition-case err
        (pichat-tool-bridge-definitions-json session)
      (error
       (when session
         (pichat-chat-diagnostics-record
          session :origin 'bridge-definitions :condition err
          :message (format "Emacs-defined tools were not declared: %s"
                           (error-message-string err))))
       pichat-bridge-transport-empty-tools-reply)))))

(defun pichat-bridge-transport-handle (session raw)
  "Handle bridge sentinel RAW for SESSION.  Return non-nil if handled."
  (pichat-backend-require-capability
   session 'extension-ui "Pi extension bridge")
  (let* ((id (plist-get raw :id))
         (title (plist-get raw :title))
         (startup-reply (pichat-bridge-transport-startup-reply raw session))
         (operation (pichat-session-restart-operation session))
         (restarting (and operation
                          (memq (plist-get operation :phase)
                                '(starting loading synchronizing))))
         ;; Only the current process's bridge handshake/definitions may send
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
     ((string= title pichat-bridge-transport-tool-call-title)
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
