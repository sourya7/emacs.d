;;; pichat-view.el --- Read-only PiChat views -*- lexical-binding: t; -*-

;;; Commentary:

;; Common semantic parent and display lifecycle for read-only PiChat buffers.
;; The lifecycle records only the window used to present a view and relies on
;; `quit-window' metadata to undo that presentation.  It intentionally avoids
;; restoring whole window configurations, which could discard later user
;; changes.

;;; Code:

(require 'cl-lib)

(cl-defstruct (pichat-view-presentation
               (:constructor pichat-view-presentation--create))
  "Display state owned by one PiChat auxiliary view."
  origin-buffer
  origin-window
  view-buffer
  view-window
  close-policy)

(defvar-local pichat-view--presentation nil
  "Presentation currently owned by this auxiliary view buffer.")

(defun pichat-view-capture-origin ()
  "Capture the live non-minibuffer origin at command invocation time.
The returned value is opaque and may be passed to `pichat-view-display'."
  (let* ((selected (selected-window))
         (window (if (window-minibuffer-p selected)
                     (minibuffer-selected-window)
                   selected)))
    (list :buffer (and (window-live-p window) (window-buffer window))
          :window window)))

(defun pichat-view-presentation (&optional buffer)
  "Return the auxiliary presentation owned by BUFFER.
BUFFER defaults to the current buffer."
  (let ((buffer (or buffer (current-buffer))))
    (and (buffer-live-p buffer)
         (buffer-local-value 'pichat-view--presentation buffer))))

(defun pichat-view-display (buffer &optional origin close-policy)
  "Display BUFFER as an auxiliary view and record its ORIGIN.
ORIGIN should come from `pichat-view-capture-origin'; when nil, capture the
current origin.  CLOSE-POLICY is one of `quit', `bury', or `kill', and defaults
to `bury'.  Return BUFFER after selecting its display window."
  (unless (buffer-live-p buffer)
    (error "Cannot display dead PiChat view buffer"))
  (let* ((origin (or origin (pichat-view-capture-origin)))
         (origin-buffer (plist-get origin :buffer))
         (origin-window (plist-get origin :window))
         (policy (or close-policy 'bury)))
    (unless (memq policy '(quit bury kill))
      (error "Unknown PiChat view close policy: %S" policy))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (setq-local
       pichat-view--presentation
       (pichat-view-presentation--create
        :origin-buffer origin-buffer
        :origin-window origin-window
        :view-buffer buffer
        :view-window (selected-window)
        :close-policy policy)))
    buffer))

(defun pichat-view--focus-buffer (buffer &optional fallback-window)
  "Select live BUFFER, preferring an existing window.
When BUFFER is dead, select FALLBACK-WINDOW if it is still live."
  (cond
   ((buffer-live-p buffer)
    (if-let ((window (get-buffer-window buffer t)))
        (select-window window)
      (pop-to-buffer buffer)))
   ((window-live-p fallback-window)
    (select-window fallback-window))))

(defun pichat-view--close-presentation
    (presentation &optional close-policy active-window)
  "Close the display owned by PRESENTATION and return its origin buffer.
CLOSE-POLICY overrides the recorded policy.  ACTIVE-WINDOW may identify a
later display from which the user explicitly invoked the close command."
  (let* ((buffer (pichat-view-presentation-view-buffer presentation))
         (recorded-window (pichat-view-presentation-view-window presentation))
         (window (cond
                  ((and (window-live-p recorded-window)
                        (eq (window-buffer recorded-window) buffer))
                   recorded-window)
                  ((and (window-live-p active-window)
                        (eq (window-buffer active-window) buffer))
                   active-window)))
         (policy (or close-policy
                     (pichat-view-presentation-close-policy presentation))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq pichat-view--presentation presentation)
          (setq pichat-view--presentation nil))))
    ;; Only alter the recorded window while it still presents this view.  If a
    ;; user repurposed or deleted it, that later window change is not ours.
    (if (window-live-p window)
        (quit-window (eq policy 'kill) window)
      ;; With no owned display left, preserve later user window changes.  A
      ;; kill policy still owns the view buffer itself; quit/bury policies do
      ;; not reclaim a buffer that the user may have displayed elsewhere.
      (when (and (eq policy 'kill) (buffer-live-p buffer))
        (kill-buffer buffer)))
    (pichat-view-presentation-origin-buffer presentation)))

(defun pichat-view-return (&optional target close-policy)
  "Close the current auxiliary view and focus TARGET or its recorded origin.
CLOSE-POLICY may override the view's normal quit policy.  Only the current
presentation is closed; use `pichat-view-complete' for an operation that should
leave a nested chain of auxiliary views."
  (interactive)
  (let* ((presentation (pichat-view-presentation))
         (origin (and presentation
                      (pichat-view-presentation-origin-buffer presentation)))
         (origin-window
          (and presentation
               (pichat-view-presentation-origin-window presentation))))
    (if presentation
        (pichat-view--close-presentation
         presentation close-policy (selected-window))
      ;; Legacy/untracked views can still focus an explicit target; with no
      ;; target, retain the ordinary `quit-window' fallback.
      (unless (buffer-live-p target)
        (quit-window)))
    (pichat-view--focus-buffer (or target origin) origin-window)))

(defun pichat-view-complete (target &optional source)
  "Complete an action from SOURCE into TARGET.
Close SOURCE and each recorded auxiliary ancestor, then focus live TARGET.
SOURCE defaults to the current buffer.  Buffers or windows changed by the user
since presentation are left alone."
  (let ((buffer (or source (current-buffer)))
        fallback-window
        seen)
    (while (and (buffer-live-p buffer)
                (not (eq buffer target))
                (not (memq buffer seen)))
      (push buffer seen)
      (let ((presentation (pichat-view-presentation buffer)))
        (if (not presentation)
            (setq buffer nil)
          (unless fallback-window
            (setq fallback-window
                  (pichat-view-presentation-origin-window presentation)))
          (setq buffer (pichat-view--close-presentation presentation)))))
    (pichat-view--focus-buffer target fallback-window)))

(defun pichat-view-quit ()
  "Quit the current PiChat view according to its presentation policy."
  (interactive)
  (pichat-view-return))

(defvar pichat-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "q") #'pichat-view-quit)
    map)
  "Base keymap for read-only PiChat views.")

(define-derived-mode pichat-view-mode special-mode "PiChat-View"
  "Base major mode for read-only PiChat views.")

(provide 'pichat-view)
;;; pichat-view.el ends here
