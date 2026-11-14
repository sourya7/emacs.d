;;; pichat-test-chat-support.el --- Chat fixture mechanics -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared lifecycle and wire-event builders.  Scenarios own their assertions,
;; display policies, and window layouts.

;;; Code:
(require 'pichat-test-support)

(cl-defmacro pichat-test-with-chat-buffer ((buffer session) &rest body)
  "Open BUFFER for SESSION, run BODY there, and always kill BUFFER.
The caller owns SESSION and any process.  Disable Markdown and stop-on-kill
for this fixture; window layout and tool display remain the caller's policy."
  (declare (indent 1))
  `(let ((pichat-chat-stop-session-on-kill nil)
         (pichat-chat-render-markdown nil)
         ,buffer)
     (unwind-protect
         (progn
           (setq ,buffer (pichat-chat-open ,session))
           (with-current-buffer ,buffer ,@body))
       (when (buffer-live-p ,buffer) (kill-buffer ,buffer)))))

(cl-defmacro pichat-test-counting-projection-snapshots ((full focused) &rest body)
  "Run BODY with FULL and FOCUSED counting projection transactions.
FULL counts complete projection snapshots and FOCUSED counts focused live
snapshots taken while BODY runs; both are bound to integers in BODY.  This is
the one place tests observe which rollback transaction a projection used."
  (declare (indent 1))
  (let ((full-original (make-symbol "full-original"))
        (focused-original (make-symbol "focused-original")))
    `(let ((,full 0) (,focused 0)
           (,full-original (symbol-function 'pichat-chat--projection-snapshot))
           (,focused-original
            (symbol-function 'pichat-chat--focused-live-snapshot)))
       (cl-letf (((symbol-function 'pichat-chat--projection-snapshot)
                  (lambda (&rest args)
                    (cl-incf ,full)
                    (apply ,full-original args)))
                 ((symbol-function 'pichat-chat--focused-live-snapshot)
                  (lambda (&rest args)
                    (cl-incf ,focused)
                    (apply ,focused-original args))))
         ,@body))))

(defun pichat-test-tool-event (id name args &optional stop-reason)
  "Return a message-end event declaring tool ID NAME ARGS and STOP-REASON."
  (list :type "message_end"
        :message (append (list :role "assistant"
                               :content (list (list :type "toolCall" :id id
                                                    :name name :arguments args)))
                         (and stop-reason (list :stopReason stop-reason)))))

(defun pichat-test-tool-finish-event (id name output)
  "Return a successful tool execution event for ID NAME with OUTPUT."
  (list :type "tool_execution_end" :toolCallId id :toolName name
        :isError nil
        :result (list :content (list (list :type "text" :text output)))))

(defun pichat-test-apply-live-events (draft &rest events)
  "Apply EVENTS to DRAFT, then project the current chat's live tail."
  (dolist (event events) (pichat-pi-live-draft-apply draft event))
  (pichat-chat--project-live-tail))

(provide 'pichat-test-chat-support)
;;; pichat-test-chat-support.el ends here
