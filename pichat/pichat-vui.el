;;; pichat-vui.el --- Optional VUI entry points for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Core PiChat does not depend on VUI.  These commands currently delegate to
;; standard Emacs UIs so the optional entry points exist without adding a hard
;; dependency.  Rich VUI components can replace these bodies later.

;;; Code:

(require 'pichat-reference)
(require 'pichat-sessions)
(require 'pichat-approval)

(declare-function pichat-status "pichat")

;;;###autoload
(defun pichat-vui-status-dashboard ()
  "Show PiChat status dashboard fallback."
  (interactive)
  (call-interactively #'pichat-status))

;;;###autoload
(defun pichat-vui-context-manager ()
  "Insert a DWIM reference into a PiChat prompt."
  (interactive)
  (call-interactively #'pichat-add-reference))

;;;###autoload
(defun pichat-vui-approval-ui ()
  "Open PiChat approval policy file fallback."
  (interactive)
  (find-file pichat-approval-policy-file))

;;;###autoload
(defun pichat-vui-session-tree ()
  "Show PiChat session history fallback."
  (interactive)
  (call-interactively #'pichat-sessions-list))

(provide 'pichat-vui)
;;; pichat-vui.el ends here
