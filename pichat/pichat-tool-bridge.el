;;; pichat-tool-bridge.el --- Emacs tool bridge helpers -*- lexical-binding: t; -*-

;;; Code:

(require 'pichat-tools)

(defun pichat-tool-bridge-definitions-json ()
  "Return Emacs tool definitions for the Pi bridge."
  (pichat-tools-definitions-json))

(defun pichat-tool-bridge-approval-required-p (json &optional session)
  "Return non-nil when bridge tool JSON needs interactive SESSION approval."
  (pichat-tools-approval-required-json-p json session))

(defun pichat-tool-bridge-execute-json (json &optional session)
  "Execute an Emacs tool request JSON from the Pi bridge for SESSION."
  (pichat-tools-execute-json json session))

(provide 'pichat-tool-bridge)
;;; pichat-tool-bridge.el ends here
