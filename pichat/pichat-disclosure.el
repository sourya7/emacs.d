;;; pichat-disclosure.el --- Visual-line disclosure measurement -*- lexical-binding: t; -*-

;;; Commentary:
;; Presentation-only measurements shared by chat and Jobs.  No view state.

;;; Code:
(require 'cl-lib)

(defun pichat-disclosure-window ()
  "Return the narrowest window displaying the current buffer, or nil."
  (car (sort (get-buffer-window-list (current-buffer) nil t)
             (lambda (a b) (< (window-body-width a) (window-body-width b))))))

(defun pichat-disclosure-cut (start end &optional window lines)
  "Return cutoff for START..END after LINES visual lines, or nil if short.
Measure in WINDOW (default the narrowest displaying window).  Account for an
ellipsis replacing the hidden suffix, including prefixes and wide characters.
Do not edit text, point, undo, or existing overlays."
  (setq window (or window (pichat-disclosure-window) (selected-window))
        lines (or lines 5))
  (save-excursion
    ;; A prose part may follow an image on the same screen line.  Include
    ;; that line's occupied width in measurement, but never in the fold.
    (goto-char start)
    (vertical-motion 0 window)
    (let ((measure-start (point)))
      (save-restriction
        (narrow-to-region measure-start end)
        (goto-char measure-start)
        (vertical-motion lines window)
        (when (< (point) end)
          (let ((cut (point)))
            (when (and (> cut start) (eq (char-before cut) ?\n))
              (setq cut (1- cut)))
            ;; `vertical-motion' over a replacement display overlay can stop
            ;; at its start rather than its end.  Measure a presentation copy.
            (let ((preview (buffer-substring measure-start cut))
                  (wrapping word-wrap)
                  (tabs tab-width)
                  (remapping face-remapping-alist)
                  (display-table buffer-display-table))
              (with-temp-buffer
                (setq truncate-lines nil truncate-partial-width-windows nil
                      word-wrap wrapping tab-width tabs inhibit-read-only t
                      face-remapping-alist remapping buffer-display-table display-table)
                (insert preview)
                (let ((properties (and (> (point) (point-min))
                                       (text-properties-at (1- (point))))))
                  (insert (apply #'propertize "…" properties)))
                (while (and (> (point-max) 2)
                            (save-excursion
                              (goto-char (point-min))
                              (vertical-motion lines window)
                              (< (point) (point-max))))
                  (delete-region (- (point-max) 2) (1- (point-max)))
                  (setq cut (1- cut)))))
            (and (> cut start) cut)))))))

(provide 'pichat-disclosure)
;;; pichat-disclosure.el ends here
