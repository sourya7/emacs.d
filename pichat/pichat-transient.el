;;; pichat-transient.el --- Narrow-frame layout for PiChat menus -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat's Transient menus place groups side by side.  In a narrow frame
;; (for example terminal Emacs on a phone) the right-hand groups end up off
;; screen, so PiChat menus switch to one column there.  Other packages'
;; menus are left alone: `transient-force-single-column' is set only
;; buffer-locally in the Transient buffer of a PiChat menu.

;;; Code:

(require 'transient)

(defcustom pichat-transient-single-column-width 80
  "Frame width, in columns, below which PiChat menus use one column.
When a PiChat Transient menu opens in a frame narrower than this, its
groups are stacked instead of placed side by side.  Wider frames keep
the normal layout.  Set to 0 to never force one column.  Other
packages' menus are not affected."
  :type 'natnum
  :group 'pichat)

(defconst pichat-transient-prefixes
  '(pichat-launch pichat-reconfigure-menu pichat-reconfigure-recovery
    pichat-jobs-actions-menu pichat-job-edit-menu pichat-job-definition-menu
    pichat-job-schedule-menu
    pichat-tool-picker pichat-tool-picker-server pichat-tool-picker-emacs-group)
  "PiChat Transient prefixes that follow `pichat-transient-single-column-width'.")

(defun pichat-transient--setup-buffer ()
  "Use one column in this Transient buffer for a PiChat menu in a narrow frame.
Runs from `transient-setup-buffer-hook' each time the Transient buffer is
created.  PiChat sub-menus opened in place share the buffer and so the
decision; any exit kills the buffer, so later menus decide afresh."
  (when (and transient--prefix
             (memq (oref transient--prefix command) pichat-transient-prefixes)
             (< (frame-width) pichat-transient-single-column-width))
    (setq-local transient-force-single-column t)))

(add-hook 'transient-setup-buffer-hook #'pichat-transient--setup-buffer)

(provide 'pichat-transient)
;;; pichat-transient.el ends here
