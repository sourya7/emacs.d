;;; pichat-events.el --- Internal event bus for PiChat -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Small event dispatcher used by PiChat modules.  Handlers may be global or
;; session-local.  Event payloads are plists.

;;; Code:

(require 'cl-lib)
(require 'pichat-session)

(defvar pichat--global-handlers (make-hash-table :test #'eq)
  "Global PiChat event handlers keyed by event symbol.")

(defun pichat--event-table (session)
  "Return SESSION's event handler table, creating it when needed."
  (if session
      (or (pichat-session-event-handlers session)
          (let ((table (make-hash-table :test #'eq)))
            (setf (pichat-session-event-handlers session) table)
            table))
    pichat--global-handlers))

;;;###autoload
(defun pichat-on (event handler &optional session)
  "Register HANDLER for EVENT.
When SESSION is non-nil, register a session-local handler.  HANDLER is called
as (HANDLER SESSION EVENT PLIST)."
  (let* ((table (pichat--event-table session))
         (handlers (gethash event table)))
    (puthash event (cl-adjoin handler handlers :test #'eq) table)
    handler))

;;;###autoload
(defun pichat-off (event handler &optional session)
  "Unregister HANDLER for EVENT.
When SESSION is non-nil, unregister from SESSION's local handlers."
  (let* ((table (pichat--event-table session))
         (handlers (remove handler (gethash event table))))
    (if handlers
        (puthash event handlers table)
      (remhash event table))))

(defun pichat--handlers-for (event session)
  "Return handlers for EVENT applying to SESSION."
  (append (and session (gethash event (pichat--event-table session)))
          (gethash event pichat--global-handlers)))

;;;###autoload
(defun pichat-emit (session event &rest plist)
  "Emit EVENT for SESSION with PLIST payload."
  (dolist (handler (pichat--handlers-for event session))
    (condition-case err
        (funcall handler session event plist)
      (error
       (message "PiChat event handler error for %S: %S" event err)))))

(provide 'pichat-events)
;;; pichat-events.el ends here
