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
