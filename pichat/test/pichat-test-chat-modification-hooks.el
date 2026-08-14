;;; pichat-test-chat-modification-hooks.el --- PiChat edit-hook tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused behavior tests for PiChat-owned and user-owned buffer edits.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-chat-modification-hooks--transcript ()
  "Return a small transcript with prose and one executable tool."
  (pichat-transcript-create
   :nodes
   (list
    (pichat-transcript-node-create
     :kind 'message :key "phase-1-node" :role 'assistant
     :content
     (list
      (pichat-transcript-content-create
       :kind 'prose :index 0 :text "Phase one projected prose.")
      (pichat-transcript-content-create
       :kind 'tool :index 1 :tool-call-id "phase-1-tool"
       :name "bash" :arguments '(:command "printf phase-1")
       :status 'done
       :output
       (list (pichat-transcript-content-create
              :kind 'prose :index 0 :text "phase-1 output"))))))
   :diagnostics nil :metadata nil))

(ert-deftest pichat-chat-owned-projections-silence-foreign-change-hooks ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          operation before-calls after-calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (add-hook 'before-change-functions
                        (lambda (&rest _args) (push operation before-calls))
                        nil t)
              (add-hook 'after-change-functions
                        (lambda (&rest _args) (push operation after-calls))
                        nil t)
              (let* ((transcript
                      (pichat-test-chat-modification-hooks--transcript))
                     (context
                      (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (setq operation 'canonical)
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (let ((prose (text-property-any
                            (marker-position pichat-chat--canonical-start)
                            (marker-position pichat-chat--canonical-end)
                            'pichat-content-kind 'prose))
                    (tool (text-property-any
                           (marker-position pichat-chat--canonical-start)
                           (marker-position pichat-chat--canonical-end)
                           'pichat-content-kind 'tool)))
                (should prose)
                (should tool)
                (should (get-text-property prose 'read-only))
                (should (get-text-property prose 'pichat-transcript))
                (should (equal "phase-1-node"
                               (get-text-property prose 'pichat-node-key)))
                (should (eq 'assistant
                            (get-text-property prose 'pichat-node-role)))
                (should (eq 'prose
                            (get-text-property prose 'pichat-content-kind)))
                (should (equal '("phase-1-node" . "phase-1-tool")
                               (get-text-property tool 'pichat-tool-key)))
                (should (eq 'pichat-tool-label-face
                            (get-text-property tool 'font-lock-face))))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :message (:role "assistant"
                           :content ((:type "text"
                                      :text "Phase one live prose.")))))
              (setq operation 'live)
              (pichat-chat--project-live-tail)
              (setq operation 'status)
              (pichat-chat--set-status 'phase-1 "[phase one status]")
              (let ((block (gethash "phase-1-tool"
                                    pichat-chat--canonical-tool-blocks)))
                (should block)
                (setf (plist-get block :display-state) 'args)
                (setq operation 'tool)
                (pichat-chat--render-tool-block block))
              (dolist (owner '(canonical live status tool))
                (should-not (memq owner before-calls))
                (should-not (memq owner after-calls)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-user-prompt-edit-runs-hooks-generation-and-styling ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (before-calls 0)
          (after-calls 0)
          buffer generation)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (add-hook 'before-change-functions
                        (lambda (&rest _args) (cl-incf before-calls)) nil t)
              (add-hook 'after-change-functions
                        (lambda (&rest _args) (cl-incf after-calls)) nil t)
              (buffer-enable-undo)
              (setq buffer-undo-list nil
                    generation pichat-chat--editor-generation)
              (set-buffer-modified-p nil)
              (goto-char (point-max))
              (insert "user edit")
              (should (= 1 before-calls))
              (should (= 1 after-calls))
              (should (= (1+ generation) pichat-chat--editor-generation))
              (should (eq 'pichat-input-block-face
                          (get-text-property (1- (point))
                                             'font-lock-face)))
              (should (buffer-modified-p))
              (should (listp buffer-undo-list))
              (should buffer-undo-list)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-modification-hooks)
;;; pichat-test-chat-modification-hooks.el ends here
