;;; pichat-test-chat-projection-skip.el --- Live no-op projection tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused behavior tests for skipping unchanged live candidates.  Failed
;; candidates keep the committed fingerprint, so a retry is not skipped; see
;; `pichat-chat-prompt-undo-survives-projection-failure-and-retry'.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-chat-support)

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

(defun pichat-test-projection-skip--text-event (type text)
  "Return a wrapped RPC event of TYPE with assistant TEXT."
  (list :raw (list :type type
                   :message (list :role "assistant"
                                  :content (list (list :type "text"
                                                       :text text))))))

(ert-deftest pichat-chat-identical-live-candidate-skips-edit-after-reduction ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-chat-buffer (buffer session)
      (pichat-test-projection-skip--start-prose
       pichat-chat--live-draft "same cumulative text")
      (pichat-chat--project-live-tail)
      (let ((before-tick (buffer-chars-modified-tick))
            (before-text (buffer-substring (point-min) (point-max)))
            (reductions 0)
            (reduce (symbol-function 'pichat-pi-live-draft-apply)))
        (pichat-test-counting-projection-snapshots (full focused)
          (cl-letf (((symbol-function 'pichat-pi-live-draft-apply)
                     (lambda (draft event)
                       (cl-incf reductions)
                       (funcall reduce draft event))))
            (pichat-chat--on-rpc-event
             session 'rpc-event
             (pichat-test-projection-skip--text-event
              "message_update" "same cumulative text"))
            (pichat-chat--cancel-live-projection)
            (pichat-chat--project-live-tail))
          (should (= 1 reductions))
          (should (equal '(0 0) (list full focused))))
        (should (= before-tick (buffer-chars-modified-tick)))
        (should (equal before-text
                       (buffer-substring (point-min) (point-max))))))))

(ert-deftest pichat-chat-live-candidate-detects-all-tool-visible-changes ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-activity-group-display 'latest)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output))
      (pichat-test-with-chat-buffer (buffer session)
        (let ((tool (pichat-test-projection-skip--start-tool
                     pichat-chat--live-draft)))
          (pichat-chat--project-live-tail)
          (pichat-test-counting-projection-snapshots (full focused)
            ;; Status-only change.
            (setf (pichat-transcript-content-status tool) 'done)
            (pichat-chat--project-live-tail)
            (should (string-match-p
                     (regexp-quote "✓ read   initial.el")
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
              (should-not (overlay-get overlay 'after-string))
              (should (equal "derived.el:7"
                             (buffer-substring-no-properties
                              (overlay-start overlay)
                              (overlay-end overlay)))))
            (should (equal '(0 4) (list full focused)))))))))

(ert-deftest pichat-chat-live-candidate-detects-property-only-change ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-chat-buffer (buffer session)
      (pichat-test-projection-skip--start-prose
       pichat-chat--live-draft "same source text")
      (pichat-chat--project-live-tail)
      (let* ((node (car (pichat-live-draft-nodes pichat-chat--live-draft)))
             (content (car (pichat-transcript-node-content node))))
        (setf (pichat-transcript-content-kind content) 'unknown)
        (pichat-test-counting-projection-snapshots (full focused)
          (pichat-chat--project-live-tail)
          (should (equal '(0 1) (list full focused))))
        (let ((position (text-property-any
                         (marker-position pichat-chat--live-start)
                         (marker-position pichat-chat--live-end)
                         'pichat-content-kind 'unknown)))
          (should position)
          (should (eq 'warning
                      (get-text-property position 'font-lock-face))))))))

(ert-deftest pichat-chat-terminal-candidate-commits-after-identical-update ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-chat-buffer (buffer session)
      (pichat-test-projection-skip--start-prose
       pichat-chat--live-draft "terminal text")
      (pichat-chat--project-live-tail)
      (let (callback callback-args)
        (pichat-test-counting-projection-snapshots (full focused)
          (cl-letf (((symbol-function 'run-with-idle-timer)
                     (lambda (_delay _repeat function &rest args)
                       (setq callback function callback-args args)
                       'phase-3-timer)))
            (pichat-chat--on-rpc-event
             session 'rpc-event
             (pichat-test-projection-skip--text-event
              "message_update" "terminal text"))
            (should callback)
            (apply callback callback-args)
            (should (equal '(0 0) (list full focused)))
            (pichat-chat--on-rpc-event
             session 'rpc-event
             (pichat-test-projection-skip--text-event
              "message_end" "terminal text"))
            (should (equal '(0 1) (list full focused)))
            (should (pichat-live-draft-message-final-p
                     pichat-chat--live-draft))))))))

(ert-deftest pichat-chat-source-reset-invalidates-live-candidate ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-chat-buffer (buffer session)
      (pichat-test-projection-skip--start-prose
       pichat-chat--live-draft "old source live text")
      (pichat-chat--project-live-tail)
      (should (bound-and-true-p pichat-chat--live-projection-fingerprint))
      (pichat-chat--reset-for-source "new-source" nil t)
      (should-not pichat-chat--live-projection-fingerprint)
      (pichat-test-counting-projection-snapshots (full focused)
        (pichat-chat--project-live-tail)
        (should (equal '(0 1) (list full focused))))
      (should-not (string-match-p
                   "old source live text"
                   (pichat-test-buffer-text buffer))))))

(provide 'pichat-test-chat-projection-skip)
;;; pichat-test-chat-projection-skip.el ends here
