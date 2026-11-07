;;; pichat-chat-notices.el --- Diagnostic notice lifetime -*- lexical-binding: t; -*-

;;; Commentary:
;; Retained diagnostic records have independent, ephemeral notice state.  This
;; module owns no buffers: RPC and chat orchestration supply lifecycle boundaries.

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'pichat-chat-diagnostics)

(defun pichat-chat-notices-current (session &optional origin command)
  "Return active SESSION records, optionally restricted to ORIGIN and COMMAND.
Process failures are runtime-wide within one process generation.  Other
failures belong to the source that produced them.  Expired notices stay hidden
on reopen, independently of timer delivery.  History is never removed."
  (let ((context (pichat-chat-diagnostics-context session))
        (now (float-time)))
    (seq-filter
     (lambda (record)
       (let ((owner (plist-get record :notice-context)))
         (and (not (plist-get record :notice-state))
              (or (null (plist-get record :notice-expires-at))
                  (< now (plist-get record :notice-expires-at)))
              (if (memq (plist-get record :origin) '(process-start process-exit))
                  (equal (car owner) (car context))
                (equal owner context))
              (or (null origin) (eq origin (plist-get record :origin)))
              (or (null command) (equal command (plist-get record :command))))))
     (pichat-session-diagnostics session))))

(defun pichat-chat-notices-retire (records state)
  "Set notice STATE on exactly RECORDS, preserving their retained history."
  (dolist (record records)
    (unless (plist-get record :notice-state)
      (setf (plist-get record :notice-state) state))))

(defun pichat-chat-notices-recovery (session &optional origin command)
  "Capture SESSION notices eligible for recovery of ORIGIN and COMMAND."
  (list :context (pichat-chat-diagnostics-context session)
        :records (pichat-chat-notices-current session origin command)))

(defun pichat-chat-notices-resolve (session recovery)
  "Resolve captured RECOVERY only in its original SESSION context.
A later failure, even with identical text, is not part of this capture."
  (when (equal (plist-get recovery :context)
               (pichat-chat-diagnostics-context session))
    (pichat-chat-notices-retire (plist-get recovery :records) 'resolved)))

(provide 'pichat-chat-notices)
;;; pichat-chat-notices.el ends here
