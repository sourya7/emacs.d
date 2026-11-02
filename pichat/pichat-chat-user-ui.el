;;; pichat-chat-user-ui.el --- Submitted user-message disclosures -*- lexical-binding: t; -*-

;;; Commentary:
;; Non-destructive display of renderer-tagged prose, never the editable prompt.
;; Source scope and projection boundaries are supplied by chat orchestration.

;;; Code:
(require 'pichat-disclosure)

(defvar-local pichat-chat-user-ui--overlays nil)
(defvar-local pichat-chat-user-ui--choices nil)
(defvar-local pichat-chat-user-ui--source nil)
(defvar-local pichat-chat-user-ui--width nil)

(defvar pichat-chat-user-ui-map
  (let ((map (make-sparse-keymap)))
    (dolist (key '("RET" "TAB" "<tab>"))
      (define-key map (kbd key) #'pichat-chat-user-ui-toggle))
    (define-key map [mouse-1] #'pichat-chat-user-ui-toggle)
    (define-key map (kbd "w") #'pichat-chat-user-ui-copy)
    map)
  "Native disclosure bindings; the editable prompt never receives this map.")

(defun pichat-chat-user-ui-clear ()
  "Remove derived overlays without changing explicit choices."
  (mapc #'delete-overlay pichat-chat-user-ui--overlays)
  (setq pichat-chat-user-ui--overlays nil))

(defun pichat-chat-user-ui-reset ()
  "Discard this buffer's source-scoped choices and presentation."
  (pichat-chat-user-ui-clear)
  (setq pichat-chat-user-ui--choices (make-hash-table :test #'equal)
        pichat-chat-user-ui--source nil pichat-chat-user-ui--width nil))

(defun pichat-chat-user-ui--at-point ()
  "Return a submitted-message disclosure at point."
  (cl-find-if (lambda (overlay) (overlay-get overlay 'pichat-user-choice))
              (overlays-at (point))))

(defun pichat-chat-user-ui-copy ()
  "Copy the complete original submitted message text, without display bars.
Image data is not text and is not placed on the kill ring."
  (interactive)
  (let ((overlay (pichat-chat-user-ui--at-point)))
    (unless overlay (user-error "No submitted-message disclosure at point"))
    (kill-new (substring-no-properties (overlay-get overlay 'pichat-user-original)))
    (message "Copied original user message text")))

(defun pichat-chat-user-ui--present (overlay expanded)
  "Apply EXPANDED presentation to OVERLAY without editing its source."
  (let ((properties (list 'face 'button 'keymap pichat-chat-user-ui-map
                          'mouse-face 'highlight 'pichat-user-owner overlay)))
    (overlay-put overlay 'pichat-user-expanded expanded)
    (overlay-put (overlay-get overlay 'pichat-user-suffix) 'display
                 (unless expanded (apply #'propertize "…" properties)))
    (overlay-put overlay 'after-string
                 (when expanded (apply #'propertize "  Show less" properties)))))

(defun pichat-chat-user-ui-toggle (&optional event)
  "Toggle only the read-only submitted-message disclosure at point or EVENT."
  (interactive (list (and (listp last-command-event) last-command-event)))
  (let* ((position (and event (event-end event)))
         (string (and position (posn-string position)))
         (clicked (and string (get-text-property (cdr string) 'pichat-user-owner (car string)))))
    (when position (posn-set-point position))
    (let ((overlay (or clicked (pichat-chat-user-ui--at-point))))
      (unless (and overlay (eq (overlay-buffer overlay) (current-buffer)))
        (user-error "No submitted-message disclosure at point"))
      (let* ((key (overlay-get overlay 'pichat-user-choice))
             (cut (overlay-start (overlay-get overlay 'pichat-user-suffix)))
             (expanded (not (overlay-get overlay 'pichat-user-expanded))))
        (puthash key expanded pichat-chat-user-ui--choices)
        (pichat-chat-user-ui--present overlay expanded)
        ;; A collapsed hidden suffix must not strand point in invisible text.
        (when (and (not expanded) (> (point) cut)) (goto-char cut))))))

(defun pichat-chat-user-ui-refresh (start end source)
  "Derive overlays on submitted prose in START..END for exact SOURCE.
Choices use the user-message ordinal, complete normalized content, and part
index.  Thus live-to-canonical reconciliation requires the same ordinal and
exact original content, not equality of unrelated live/canonical node keys.
Ordinals include skill messages and duplicates remain independent.  Rebinding
must reset SOURCE even when returning to the same Pi session."
  (unless (equal source pichat-chat-user-ui--source)
    (pichat-chat-user-ui-reset)
    (setq pichat-chat-user-ui--source source))
  (pichat-chat-user-ui-clear)
  (let* ((window (pichat-disclosure-window))
         (position start) (ordinal 0))
    (setq pichat-chat-user-ui--width (and window (window-body-width window)))
    (save-excursion
      (while (< position end)
        (let ((node-end (next-single-property-change position 'pichat-node-key nil end)))
          (when (eq (get-text-property position 'pichat-node-role) 'user)
            (cl-incf ordinal)
            (let ((part-position position)
                  (signature (get-text-property position 'pichat-user-signature))
                  (original (get-text-property position 'pichat-user-original)))
              (while (< part-position node-end)
                (let* ((part (get-text-property part-position 'pichat-user-part))
                       (part-end (next-single-property-change
                                  part-position 'pichat-user-part nil node-end))
                       (cut (and part (pichat-disclosure-cut part-position part-end window))))
                  (when cut
                    (let* ((key (list ordinal (copy-tree signature t) part))
                           (expanded (gethash key pichat-chat-user-ui--choices))
                           (overlay (make-overlay part-position part-end nil t nil))
                           (suffix (make-overlay cut part-end nil t nil)))
                      (overlay-put overlay 'pichat-user-choice key)
                      (overlay-put overlay 'pichat-user-original original)
                      (overlay-put overlay 'pichat-user-suffix suffix)
                      (overlay-put overlay 'keymap pichat-chat-user-ui-map)
                      (overlay-put overlay 'mouse-face 'highlight)
                      (overlay-put overlay 'help-echo "RET/TAB/click: fold message; w: copy full text")
                      (pichat-chat-user-ui--present overlay expanded)
                      (push overlay pichat-chat-user-ui--overlays)
                      (push suffix pichat-chat-user-ui--overlays)))
                  (setq part-position part-end)))))
          (setq position node-end))))))

(provide 'pichat-chat-user-ui)
;;; pichat-chat-user-ui.el ends here
