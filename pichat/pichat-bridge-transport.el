;;; pichat-bridge-transport.el --- Sentinel transport for PiChat bridge -*- lexical-binding: t; -*-

;;; Code:

(require 'pichat-rpc)
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

(defun pichat-bridge-transport-handle (session raw)
  "Handle bridge sentinel RAW for SESSION.  Return non-nil if handled."
  (let ((id (plist-get raw :id))
        (title (plist-get raw :title)))
    (cond
     ((string= title pichat-bridge-transport-handshake-title)
      (pichat-rpc-extension-ui-value
       session id
       "{\"protocolVersion\":1,\"capabilities\":[\"tools\",\"tool-errors\",\"dynamic-tool-refresh\"]}")
      t)
     ((string= title pichat-bridge-transport-tools-title)
      (pichat-rpc-extension-ui-value session id (pichat-tool-bridge-definitions-json)) t)
     ((string= title pichat-bridge-transport-tool-call-title)
      (pichat-rpc-extension-ui-value
       session id (pichat-tool-bridge-execute-json
                   (or (plist-get raw :prefill) "{}") session))
      t)
     (t nil))))

(provide 'pichat-bridge-transport)
;;; pichat-bridge-transport.el ends here
