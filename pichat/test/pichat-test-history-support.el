;;; pichat-test-history-support.el --- History fixtures -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared data builders and buffer mechanics, without ERT test definitions.
;; Existing helper names are retained so scenario diffs stay focused.

;;; Code:
(require 'pichat-test-support)

(defun pichat-test-sessions-tree--message (id role text &optional parent-id)
  "Return a Pi tree node for message ID with ROLE and TEXT.
PARENT-ID is deliberately raw protocol metadata; model parents come from nesting."
  (list :entry (append (list :type "message" :id id)
                       (when parent-id (list :parentId parent-id))
                       (list :message (list :role role :content text)))
        :children nil))

(defun pichat-test-sessions-tree--entry (id type &rest properties)
  "Return a Pi tree node carrying ID, TYPE, and PROPERTIES."
  (list :entry (append (list :type type :id id) properties)
        :children nil))

(defun pichat-test-sessions-tree--set-children (node children)
  "Set NODE's Pi tree CHILDREN and return NODE."
  (plist-put node :children children))

(defun pichat-test-sessions-tree--response (roots leaf-id)
  "Return a get_tree response for ROOTS and LEAF-ID."
  (list :data (list :tree roots :leafId leaf-id)))

(defun pichat-test-sessions-tree--line-for-id (id)
  "Return the rendered history line carrying ID."
  (pichat-sessions--goto-id id)
  (buffer-substring-no-properties (line-beginning-position)
                                  (line-end-position)))

(cl-defmacro pichat-test-with-history ((session response) &rest body)
  "Install RESPONSE for SESSION in a temporary history buffer and run BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (pichat-sessions--refresh-from-response ,response ,session (current-buffer))
     ,@body))

(defun pichat-test-sessions-preview--response ()
  "Return a branched response with explicit tool activity."
  (let* ((active-leaf
          (pichat-test-sessions-tree--message
           "active-leaf" "assistant" "Active answer"))
         (active-user
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--message
            "active-user" "user" "Active prompt")
           (list active-leaf)))
         (alternate-leaf
          (pichat-test-sessions-tree--entry
           "alternate-leaf" "message" :timestamp "2026-07-25T18:42:00Z"
           :message '(:role "assistant" :content "Alternate answer")))
         (alternate-user
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "alternate-user" "message"
            :message '(:role "user"
                       :content ((:type "text" :text "Alternate prompt")
                                 (:type "image" :mediaType "image/png"
                                  :data "omitted"))))
           (list alternate-leaf)))
         (result
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "result" "message"
            :message '(:role "toolResult" :toolCallId "call-1"
                       :toolName "read"
                       :content ((:type "text" :text "tool output"))))
           (list active-user alternate-user)))
         (assistant
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "assistant" "message"
            :message '(:role "assistant"
                       :content ((:type "text" :text "Checking")
                                 (:type "toolCall" :id "call-1" :name "read"
                                  :arguments (:path "README.md")))))
           (list result)))
         (root
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--message
            "root" "user" "Initial prompt")
           (list assistant))))
    (list :data (list :tree (list root) :leafId "active-leaf"))))

(defun pichat-test-sessions-preview--kill-buffers ()
  "Kill auxiliary history buffers when present."
  (dolist (name '("*PiChat Branch Preview*" "*PiChat Session Entry*"))
    (when-let* ((buffer (get-buffer name)))
      (kill-buffer buffer))))

(defmacro pichat-test-sessions-fork--with-origin (&rest body)
  "Install a forkable history fixture and run BODY in its origin buffer."
  (declare (indent 0) (debug body))
  `(let ((session (pichat-session-make :id "source" :session-file "/source")))
     (pichat-test-with-history (session (pichat-test-sessions-preview--response))
       ,@body)))

(provide 'pichat-test-history-support)
;;; pichat-test-history-support.el ends here
