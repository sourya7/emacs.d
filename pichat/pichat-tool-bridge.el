;;; pichat-tool-bridge.el --- Emacs tool bridge helpers -*- lexical-binding: t; -*-

;;; Commentary:
;; The bridge declares and dispatches only the owning runtime's captured
;; Emacs-defined tool selection.  Registration makes a tool selectable, never
;; exposed; an absent session or selection exposes nothing.

;;; Code:

(require 'pichat-tools)

(declare-function pichat-session-p "pichat-session" (object))
(declare-function pichat-session-tool-selection "pichat-session" (session))
(declare-function pichat-session-restart-operation "pichat-session" (session))

(defun pichat-tool-bridge-selected-names (session)
  "Return exact Emacs-defined tool names selected for SESSION's process.
During a restart's replacement phases the requested configuration owns the
bridge; otherwise the committed runtime snapshot does.  Return `none' when no
tool is selected, never an unrestricted value."
  (let* ((operation (and (pichat-session-p session)
                         (pichat-session-restart-operation session)))
         (snapshot
          (cond
           ((not (pichat-session-p session)) nil)
           ((and operation
                 (memq (plist-get operation :phase) '(starting loading synchronizing)))
            (plist-get (plist-get operation :active-configuration) :tool-selection))
           (t (pichat-session-tool-selection session))))
         (names (plist-get snapshot :emacs)))
    (if names (copy-sequence names) 'none)))

(defun pichat-tool-bridge-definitions-json (&optional session)
  "Return SESSION's selected Emacs tool definitions for the Pi bridge.
Selected tools that are no longer registered are omitted; unselected
registered tools are never declared."
  (pichat-tools-definitions-json (pichat-tool-bridge-selected-names session)))

(defun pichat-tool-bridge-approval-required-p (json &optional session)
  "Return non-nil when bridge tool JSON needs interactive SESSION approval."
  (pichat-tools-approval-required-json-p
   json session (pichat-tool-bridge-selected-names session)))

(defun pichat-tool-bridge-execute-json (json &optional session)
  "Execute an Emacs tool request JSON from the Pi bridge for SESSION.
Calls to tools outside SESSION's selection fail before approval."
  (pichat-tools-execute-json
   json session (pichat-tool-bridge-selected-names session)))

(provide 'pichat-tool-bridge)
;;; pichat-tool-bridge.el ends here
