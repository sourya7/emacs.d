;;; pichat-transient.el --- Narrow-frame layout for PiChat menus -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat's Transient menus place groups side by side.  In a narrow frame
;; (for example terminal Emacs on a phone) the right-hand groups end up off
;; screen, so PiChat menus switch to one column there.  Other packages'
;; menus are left alone: `transient-force-single-column' is set only
;; buffer-locally in the Transient buffer of a PiChat menu.
;;
;; A tall menu is moved through with <down> and <up> (a phone terminal
;; sends those for a swipe).  Transient wraps from the last entry to the
;; first, which looks like the view jumping back to the top; PiChat menus
;; stop at either end instead.  They also skip Transient's echo-area
;; summary of the entry reached, which the menu line already describes.

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
    pichat-chat-actions pichat-session-manager-actions
    pichat-jobs-actions-menu pichat-job-edit-menu pichat-job-definition-menu
    pichat-job-schedule-menu
    pichat-tool-picker pichat-tool-picker-server pichat-tool-picker-emacs-group
    pichat-tool-picker-extension-group)
  "PiChat Transient prefixes that follow `pichat-transient-single-column-width'.")

(defvar-local pichat-transient--no-wrap nil
  "Non-nil in the Transient buffer of a PiChat menu.
There, moving past the last or first entry stops instead of wrapping.")

(defun pichat-transient--setup-buffer ()
  "Prepare this Transient buffer when it shows a PiChat menu.
Stop entry navigation from wrapping, and use one column in a narrow
frame.  Runs from `transient-setup-buffer-hook' each time the Transient
buffer is created.  PiChat sub-menus opened in place share the buffer
and so the decision; any exit kills the buffer, so later menus decide
afresh."
  (when (and transient--prefix
             (memq (oref transient--prefix command) pichat-transient-prefixes))
    (setq-local pichat-transient--no-wrap t)
    (when (< (frame-width) pichat-transient-single-column-width)
      (setq-local transient-force-single-column t))))

(add-hook 'transient-setup-buffer-hook #'pichat-transient--setup-buffer)

(defun pichat-transient--move-without-wrap (fn n)
  "Call FN with N, or move N entries without wrapping in a PiChat menu.
FN is Transient's forward entry navigation with its count already
signed: negative N moves backward.  In a PiChat menu, moving past the
last entry stops at the end of the menu and moving before the first
stops at its start, and no summary of the entry is echoed (Transient
does that when `transient-enable-menu-navigation' is `verbose').  Other
menus call FN unchanged."
  (if (not (and (window-live-p transient--window)
                (buffer-local-value 'pichat-transient--no-wrap
                                    (window-buffer transient--window))))
      (funcall fn n)
    (with-selected-window transient--window
      (condition-case nil
          (forward-button n nil)
        (error (goto-char (if (< n 0) (point-min) (point-max))))))))

(defun pichat-transient--forward-without-wrap (fn n)
  "Around advice for `transient-forward-button' (FN), moving N entries."
  (pichat-transient--move-without-wrap fn n))

(defun pichat-transient--backward-without-wrap (fn n)
  "Around advice for `transient-backward-button' (FN), moving N entries."
  (pichat-transient--move-without-wrap (lambda (m) (funcall fn (- m))) (- n)))

(advice-add 'transient-forward-button :around
            #'pichat-transient--forward-without-wrap)
(advice-add 'transient-backward-button :around
            #'pichat-transient--backward-without-wrap)

(defun pichat-transient-fill (text)
  "Fill each line of TEXT to fit a menu line in the selected frame.
For headings that carry a sentence, such as a blocking reason.  The
wording is the same at every width; only where lines break differs.
A terminal keeps the last column for the continuation glyph, so lines
end one column before the frame edge."
  (mapconcat (lambda (line)
               (with-temp-buffer
                 (insert line)
                 (let ((fill-column (max 20 (1- (frame-width)))))
                   (fill-region (point-min) (point-max)))
                 (buffer-string)))
             (split-string text "\n")
             "\n"))

(defun pichat-transient-truncate-left (text width)
  "Return TEXT shortened to WIDTH columns by dropping its start.
For paths, whose end says the most."
  (let ((total (string-width text)))
    (if (<= total width) text
      (concat "…" (truncate-string-to-width text total (- total (1- width)))))))

(provide 'pichat-transient)
;;; pichat-transient.el ends here
