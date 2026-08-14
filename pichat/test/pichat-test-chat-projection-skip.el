;;; pichat-test-chat-projection-skip.el --- Live no-op projection tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused behavior tests for skipping unchanged live candidates.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-projection-skip--start-prose (draft text)
  "Start DRAFT with transient assistant TEXT."
  (pichat-pi-live-draft-apply
   draft '(:type "message_start" :message (:role "assistant" :content nil)))
  (pichat-pi-live-draft-apply
   draft
   (list :type "message_update"
         :message (list :role "assistant"
                        :content (list (list :type "text" :text text))))))

(defun pichat-test-projection-skip--start-tool (draft)
  "Start DRAFT with one running read tool and return that tool."
  (pichat-pi-live-draft-apply
   draft
   '(:type "message_end"
     :message (:role "assistant"
               :content ((:type "toolCall" :id "phase-3-tool" :name "read"
                          :arguments (:path "initial.el"))))))
  (pichat-pi-live-draft-apply
   draft
   '(:type "tool_execution_update" :toolCallId "phase-3-tool"
     :toolName "read" :args (:path "initial.el")
     :partialResult (:content ((:type "text" :text "first output")))))
  (gethash "phase-3-tool" (pichat-live-draft-tools draft)))

(defun pichat-test-projection-skip--output (text)
  "Return normalized tool output containing TEXT."
  (list (pichat-transcript-content-create
         :kind 'prose :index 0 :text text)))

(ert-deftest pichat-chat-identical-live-candidate-skips-edit-after-reduction ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer (reductions 0) (full-snapshots 0) (focused-snapshots 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-projection-skip--start-prose
               pichat-chat--live-draft "same cumulative text")
              (pichat-chat--project-live-tail)
              (let ((before-tick (buffer-chars-modified-tick))
                    (before-text (buffer-substring (point-min) (point-max))))
                (cl-letf (((symbol-function 'pichat-pi-live-draft-apply)
                           (let ((original
                                  (symbol-function
                                   'pichat-pi-live-draft-apply)))
                             (lambda (draft event)
                               (cl-incf reductions)
                               (funcall original draft event))))
                          ((symbol-function 'pichat-chat--projection-snapshot)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--projection-snapshot)))
                             (lambda ()
                               (cl-incf full-snapshots)
                               (funcall original))))
                          ((symbol-function 'pichat-chat--focused-live-snapshot)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--focused-live-snapshot)))
                             (lambda (&rest args)
                               (cl-incf focused-snapshots)
                               (apply original args)))))
                  (pichat-chat--on-rpc-event
                   session 'rpc-event
                   '(:raw (:type "message_update"
                            :message
                            (:role "assistant"
                             :content
                             ((:type "text"
                               :text "same cumulative text"))))))
                  (pichat-chat--cancel-live-projection)
                  (pichat-chat--project-live-tail))
                (should (= 1 reductions))
                (should (zerop full-snapshots))
                (should (zerop focused-snapshots))
                (should (= before-tick (buffer-chars-modified-tick)))
                (should (equal before-text
                               (buffer-substring (point-min) (point-max)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-candidate-detects-all-tool-visible-changes ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer tool (full-snapshots 0) (focused-snapshots 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setq tool (pichat-test-projection-skip--start-tool
                          pichat-chat--live-draft))
              (pichat-chat--project-live-tail)
              (cl-letf (((symbol-function 'pichat-chat--projection-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--projection-snapshot)))
                           (lambda ()
                             (cl-incf full-snapshots)
                             (funcall original))))
                        ((symbol-function 'pichat-chat--focused-live-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--focused-live-snapshot)))
                           (lambda (&rest args)
                             (cl-incf focused-snapshots)
                             (apply original args)))))
                ;; Status-only change.
                (setf (pichat-transcript-content-status tool) 'done)
                (pichat-chat--project-live-tail)
                (should (string-match-p
                         (regexp-quote "[tool:read done]")
                         (pichat-test-buffer-text buffer)))
                ;; Output-only change.
                (setf (pichat-transcript-content-output tool)
                      (pichat-test-projection-skip--output "second output"))
                (pichat-chat--project-live-tail)
                (should (string-match-p
                         "second output" (pichat-test-buffer-text buffer)))
                ;; Argument-only change.
                (setf (pichat-transcript-content-arguments tool)
                      '(:path "changed.el"))
                (pichat-chat--project-live-tail)
                (should (string-match-p
                         "changed.el" (pichat-test-buffer-text buffer)))
                ;; Enrichment-only location decoration change.
                (let ((record
                       (pichat-tool-enrichment-build
                        "phase-3-tool" "read"
                        '(:path "derived.el" :line 7))))
                  (puthash
                   "phase-3-tool"
                   (plist-put record :source-generation
                              pichat-chat--source-generation)
                   pichat-chat--tool-enrichments))
                (pichat-chat--project-live-tail)
                (let* ((block (gethash "phase-3-tool"
                                       pichat-chat--live-tool-blocks))
                       (overlay (plist-get block :overlay)))
                  (should (overlayp overlay))
                  (should (equal " [derived.el:7]"
                                 (substring-no-properties
                                  (overlay-get overlay 'after-string)))))
                (should (= 4 focused-snapshots))
                (should (zerop full-snapshots)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-candidate-detects-property-only-change ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer (full-snapshots 0) (focused-snapshots 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-projection-skip--start-prose
               pichat-chat--live-draft "same source text")
              (pichat-chat--project-live-tail)
              (let* ((node (car (pichat-live-draft-nodes
                                 pichat-chat--live-draft)))
                     (content (car (pichat-transcript-node-content node))))
                (setf (pichat-transcript-content-kind content) 'unknown)
                (cl-letf (((symbol-function 'pichat-chat--projection-snapshot)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--projection-snapshot)))
                             (lambda ()
                               (cl-incf full-snapshots)
                               (funcall original))))
                          ((symbol-function 'pichat-chat--focused-live-snapshot)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--focused-live-snapshot)))
                             (lambda (&rest args)
                               (cl-incf focused-snapshots)
                               (apply original args)))))
                  (pichat-chat--project-live-tail))
                (should (= 1 focused-snapshots))
                (should (zerop full-snapshots))
                (let ((position (text-property-any
                                 (marker-position pichat-chat--live-start)
                                 (marker-position pichat-chat--live-end)
                                 'pichat-content-kind 'unknown)))
                  (should position)
                  (should (eq 'warning
                              (get-text-property position
                                                 'font-lock-face)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-terminal-candidate-commits-after-identical-update ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer callback callback-args
          (full-snapshots 0) (focused-snapshots 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-projection-skip--start-prose
               pichat-chat--live-draft "terminal text")
              (pichat-chat--project-live-tail)
              (cl-letf (((symbol-function 'run-with-idle-timer)
                         (lambda (_delay _repeat function &rest args)
                           (setq callback function callback-args args)
                           'phase-3-timer))
                        ((symbol-function 'pichat-chat--projection-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--projection-snapshot)))
                           (lambda ()
                             (cl-incf full-snapshots)
                             (funcall original))))
                        ((symbol-function 'pichat-chat--focused-live-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--focused-live-snapshot)))
                           (lambda (&rest args)
                             (cl-incf focused-snapshots)
                             (apply original args)))))
                (pichat-chat--on-rpc-event
                 session 'rpc-event
                 '(:raw (:type "message_update"
                          :message
                          (:role "assistant"
                           :content
                           ((:type "text" :text "terminal text"))))))
                (should callback)
                (apply callback callback-args)
                (should (zerop full-snapshots))
                (should (zerop focused-snapshots))
                (pichat-chat--on-rpc-event
                 session 'rpc-event
                 '(:raw (:type "message_end"
                          :message
                          (:role "assistant"
                           :content
                           ((:type "text" :text "terminal text"))))))
                (should (= 1 focused-snapshots))
                (should (zerop full-snapshots))
                (should (pichat-live-draft-message-final-p
                         pichat-chat--live-draft)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-fingerprint-rolls-back-with-failed-candidate ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer before-text before-fingerprint)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-projection-skip--start-prose
               pichat-chat--live-draft "committed text")
              (pichat-chat--project-live-tail)
              (setq before-text (buffer-substring (point-min) (point-max))
                    before-fingerprint
                    pichat-chat--live-projection-fingerprint)
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :message
                 (:role "assistant"
                  :content ((:type "text" :text "candidate text")))))
              (cl-letf (((symbol-function
                          'pichat-chat--index-canonical-tools)
                         (lambda (&rest _args)
                           (error "forced candidate failure"))))
                (should-error (pichat-chat--project-live-tail)))
              (should (equal before-text
                             (buffer-substring (point-min) (point-max))))
              (should (eq before-fingerprint
                          pichat-chat--live-projection-fingerprint))
              (pichat-chat--project-live-tail)
              (should (string-match-p
                       "candidate text" (pichat-test-buffer-text buffer)))
              (should-not (eq before-fingerprint
                              pichat-chat--live-projection-fingerprint))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-reset-invalidates-live-candidate ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer (full-snapshots 0) (focused-snapshots 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-projection-skip--start-prose
               pichat-chat--live-draft "old source live text")
              (pichat-chat--project-live-tail)
              (should (bound-and-true-p
                       pichat-chat--live-projection-fingerprint))
              (pichat-chat--reset-for-source "new-source" nil t)
              (should-not pichat-chat--live-projection-fingerprint)
              (cl-letf (((symbol-function 'pichat-chat--projection-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--projection-snapshot)))
                           (lambda ()
                             (cl-incf full-snapshots)
                             (funcall original))))
                        ((symbol-function 'pichat-chat--focused-live-snapshot)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--focused-live-snapshot)))
                           (lambda (&rest args)
                             (cl-incf focused-snapshots)
                             (apply original args)))))
                (pichat-chat--project-live-tail))
              (should (= 1 focused-snapshots))
              (should (zerop full-snapshots))
              (should-not (string-match-p
                           "old source live text"
                           (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-projection-skip)
;;; pichat-test-chat-projection-skip.el ends here
