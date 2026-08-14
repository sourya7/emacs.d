;;; pichat-test-transcript.el --- Pichat Test Transcript -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

;;; Authoritative entry-cache unit tests

(ert-deftest pichat-pi-entry-cache-selects-active-branch-not-append-order ()
  (let* ((entries '((:type "message" :id "root" :parentId nil)
                    (:type "message" :id "active-1" :parentId "root")
                    (:type "message" :id "abandoned" :parentId "root")
                    (:type "message" :id "active-2" :parentId "active-1")))
         (cache (pichat-pi-entry-cache-full
                 "session-1" "/sanitized/session.jsonl" entries "active-2")))
    (should (equal '("root" "active-1" "abandoned" "active-2")
                   (pichat-entry-cache-append-order cache)))
    (should (equal "active-2" (pichat-entry-cache-last-seen-id cache)))
    (should (equal '("root" "active-1" "active-2")
                   (mapcar (lambda (entry) (plist-get entry :id))
                           (pichat-pi-entry-cache-active-branch cache))))))

(ert-deftest pichat-pi-entry-cache-incrementally-merges-with-durable-cursor ()
  (let* ((cache (pichat-pi-entry-cache-full
                 "session-1" nil
                 '((:type "message" :id "root" :parentId nil))
                 "root"))
         (updated (pichat-pi-entry-cache-merge
                   cache
                   '((:type "message" :id "next" :parentId "root"))
                   "next")))
    (should (equal '("root") (pichat-entry-cache-append-order cache)))
    (should (equal '("root" "next")
                   (pichat-entry-cache-append-order updated)))
    (should (equal "next" (pichat-entry-cache-last-seen-id updated)))
    (should (equal '("root" "next")
                   (mapcar (lambda (entry) (plist-get entry :id))
                           (pichat-pi-entry-cache-active-branch updated))))))

(ert-deftest pichat-pi-entry-cache-applies-leaf-movement-with-no-new-entries ()
  (let* ((cache (pichat-pi-entry-cache-full
                 "session-1" nil
                 '((:type "message" :id "root" :parentId nil)
                   (:type "message" :id "left" :parentId "root")
                   (:type "message" :id "right" :parentId "root"))
                 "left"))
         (updated (pichat-pi-entry-cache-merge cache nil "right")))
    (should (equal "right" (pichat-entry-cache-leaf-id updated)))
    (should (equal "right" (pichat-entry-cache-last-seen-id updated)))
    (should (equal '("root" "right")
                   (mapcar (lambda (entry) (plist-get entry :id))
                           (pichat-pi-entry-cache-active-branch updated))))))

(ert-deftest pichat-pi-entry-cache-rejects-invalid-active-branches ()
  (dolist (case
           '((((:type "message" :id "one" :parentId nil)
               (:type "message" :id "one" :parentId nil))
              "one")
             (((:type "message" :id "one" :parentId "missing"))
              "one")
             (((:type "message" :id "one" :parentId "two")
               (:type "message" :id "two" :parentId "one"))
              "two")
             (((:type "message" :id "one" :parentId nil))
              "unknown")
             (((:type "message" :id "one" :parentId nil))
              nil)))
    (should-error
     (pichat-pi-entry-cache-full "session-1" nil (car case) (cadr case))
     :type 'pichat-pi-invalid-session))
  (should-error
   (pichat-pi-entry-cache-full "session-1" nil nil "unknown")
   :type 'pichat-pi-invalid-session))

(ert-deftest pichat-pi-entry-cache-merge-is-atomic-on-conflict ()
  (let ((cache (pichat-pi-entry-cache-full
                "session-1" nil
                '((:type "message" :id "root" :parentId nil :value "original"))
                "root")))
    (should-error
     (pichat-pi-entry-cache-merge
      cache
      '((:type "message" :id "root" :parentId nil :value "changed"))
      "root")
     :type 'pichat-pi-invalid-session)
    (should (equal "original"
                   (plist-get
                    (gethash "root" (pichat-entry-cache-entries-by-id cache))
                    :value)))
    (should (equal '("root") (pichat-entry-cache-append-order cache)))))

(ert-deftest pichat-pi-canonical-transcript-projects-only-visible-active-branch ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (nodes (pichat-transcript-nodes transcript)))
    (should (equal '("entry-user"
                     "entry-tool-call"
                     "entry-answer"
                     "entry-custom-message"
                     "entry-compaction"
                     "entry-final")
                   (mapcar #'pichat-transcript-node-key nodes)))
    (should-not (string-match-p
                 (regexp-opt '("Abandoned response."
                               "hidden custom text"
                               "must-not-render"))
                 (format "%S" transcript)))))

(ert-deftest pichat-pi-canonical-transcript-preserves-assistant-content-order-and-tool-result ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (node (cl-find "entry-tool-call" (pichat-transcript-nodes transcript)
                        :key #'pichat-transcript-node-key :test #'equal))
         (content (pichat-transcript-node-content node))
         (tool (nth 2 content)))
    (should (eq 'assistant (pichat-transcript-node-role node)))
    (should (equal '(thinking prose tool)
                   (mapcar #'pichat-transcript-content-kind content)))
    (should (equal '(0 1 2)
                   (mapcar #'pichat-transcript-content-index content)))
    (should (equal "tool-1" (pichat-transcript-content-tool-call-id tool)))
    (should (eq 'done (pichat-transcript-content-status tool)))
    (should-not (pichat-transcript-content-is-error tool))
    (should (equal "entry-tool-result"
                   (pichat-transcript-content-result-entry-id tool)))
    (should (equal "sanitized output"
                   (pichat-transcript-content-text
                    (car (pichat-transcript-content-output tool)))))))

(ert-deftest pichat-pi-canonical-transcript-normalizes-custom-activity-metadata-and-errors ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (nodes (pichat-transcript-nodes transcript))
         (custom (cl-find "entry-custom-message" nodes
                          :key #'pichat-transcript-node-key :test #'equal))
         (activity (cl-find "entry-compaction" nodes
                            :key #'pichat-transcript-node-key :test #'equal))
         (final (cl-find "entry-final" nodes
                         :key #'pichat-transcript-node-key :test #'equal))
         (metadata (pichat-transcript-metadata transcript)))
    (should (eq 'custom (pichat-transcript-node-role custom)))
    (should (equal "fixture-visible"
                   (pichat-transcript-node-custom-type custom)))
    (should (equal '(prose image)
                   (mapcar #'pichat-transcript-content-kind
                           (pichat-transcript-node-content custom))))
    (should (eq 'activity (pichat-transcript-node-kind activity)))
    (should (eq 'compaction (pichat-transcript-node-activity-type activity)))
    (should (equal "Sanitized compact summary."
                   (pichat-transcript-node-summary activity)))
    (should (= 120 (pichat-transcript-node-tokens-before activity)))
    (should (equal '(:provider "fixture-provider" :model-id "fixture-model")
                   (plist-get metadata :model)))
    (should (equal "medium" (plist-get metadata :thinking-level)))
    (should (equal "aborted" (pichat-transcript-node-stop-reason final)))
    (should (equal "Stopped by fixture."
                   (pichat-transcript-node-error-message final)))))

(ert-deftest pichat-pi-canonical-transcript-bounds-unknown-protocol-data ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (final (cl-find "entry-final" (pichat-transcript-nodes transcript)
                         :key #'pichat-transcript-node-key :test #'equal))
         (unknown (car (pichat-transcript-node-content final)))
         (diagnostics (pichat-transcript-diagnostics transcript)))
    (should (eq 'unknown (pichat-transcript-content-kind unknown)))
    (should (equal "[unsupported content: futureContent]"
                   (pichat-transcript-content-text unknown)))
    (should (equal '(unknown-entry unknown-content)
                   (mapcar (lambda (diagnostic)
                             (plist-get diagnostic :category))
                           diagnostics)))
    (should-not (string-match-p "must-not-render" (format "%S" transcript)))))

(ert-deftest pichat-pi-canonical-transcript-supports-sanitized-legacy-shape ()
  (let* ((fixture (pichat-test-read-json-fixture
                   "canonical-session-legacy.json"))
         (cache (pichat-pi-entry-cache-full
                 (plist-get fixture :sessionId)
                 (plist-get fixture :sessionFile)
                 (plist-get fixture :entries)
                 (plist-get fixture :leafId)))
         (transcript (pichat-pi-build-canonical-transcript cache))
         (nodes (pichat-transcript-nodes transcript))
         (assistant (cl-find "legacy-assistant" nodes
                             :key #'pichat-transcript-node-key
                             :test #'equal))
         (tool (car (pichat-transcript-node-content assistant)))
         (custom (cl-find "legacy-custom" nodes
                          :key #'pichat-transcript-node-key
                          :test #'equal)))
    (should (equal "0.79-compatible-shape"
                   (plist-get fixture :piVersion)))
    (should (eq 'done (pichat-transcript-content-status tool)))
    (should (equal "Legacy output."
                   (pichat-transcript-content-text
                    (car (pichat-transcript-content-output tool)))))
    (should (eq 'custom (pichat-transcript-node-role custom)))))

(ert-deftest pichat-pi-canonical-transcript-marks-error-incomplete-and-orphan-tools ()
  (let* ((entries
          '((:type "message" :id "assistant" :parentId nil
             :message
             (:role "assistant"
              :content
              ((:type "toolCall" :id "tool-error" :name "failing" :arguments nil)
               (:type "toolCall" :id "tool-pending" :name "pending" :arguments nil))))
            (:type "message" :id "error-result" :parentId "assistant"
             :message
             (:role "toolResult" :toolCallId "tool-error" :toolName "failing"
              :isError t :content ((:type "text" :text "failure"))))
            (:type "message" :id "orphan-result" :parentId "error-result"
             :message
             (:role "toolResult" :toolCallId "tool-orphan" :toolName "orphan"
              :isError nil :content ((:type "text" :text "orphan output"))))))
         (cache (pichat-pi-entry-cache-full
                 "tool-session" nil entries "orphan-result"))
         (transcript (pichat-pi-build-canonical-transcript cache))
         (nodes (pichat-transcript-nodes transcript))
         (assistant (car nodes))
         (tools (pichat-transcript-node-content assistant))
         (orphan (cadr nodes)))
    (should (equal '(error incomplete)
                   (mapcar #'pichat-transcript-content-status tools)))
    (should (pichat-transcript-content-is-error (car tools)))
    (should (eq 'tool (pichat-transcript-node-kind orphan)))
    (should (eq 'orphan
                (pichat-transcript-content-status
                 (car (pichat-transcript-node-content orphan)))))))

;;; Transient live-draft reducer tests

(ert-deftest pichat-live-draft-uses-authoritative-user-message-lifecycle ()
  (let ((draft (pichat-live-draft-empty 7)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_start"
       :message (:role "user" :content "submitted preview")))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_end"
       :message (:role "user"
                 :content ((:type "text" :text "authoritative user text")))))
    (let ((nodes (pichat-live-draft-nodes draft)))
      (should (= 1 (length nodes)))
      (should (eq 'user (pichat-transcript-node-role (car nodes))))
      (should (string-prefix-p "live-7-"
                               (pichat-transcript-node-key (car nodes))))
      (should (equal "authoritative user text"
                     (pichat-transcript-content-text
                      (car (pichat-transcript-node-content
                            (car nodes)))))))))

(defun pichat-test--apply-assistant-stream (draft updates &optional snapshots)
  "Apply UPDATES to DRAFT, optionally adding 0.83 cumulative SNAPSHOTS."
  (pichat-pi-live-draft-apply
   draft '(:type "message_start"
           :message (:role "assistant" :content nil)))
  (cl-mapc
   (lambda (update snapshot)
     (pichat-pi-live-draft-apply
      draft
      (append (list :type "message_update")
              (and snapshot (list :message snapshot))
              (list :assistantMessageEvent update))))
   updates (or snapshots (make-list (length updates) nil)))
  draft)

(ert-deftest pichat-live-draft-assembles-delta-only-interleaved-content ()
  (let ((draft (pichat-live-draft-empty 8)))
    (pichat-test--apply-assistant-stream
     draft
     '((:type "thinking_start" :contentIndex 0)
       (:type "thinking_delta" :contentIndex 0 :delta "consider")
       (:type "text_start" :contentIndex 1)
       (:type "text_delta" :contentIndex 1 :delta "Hello")
       (:type "thinking_delta" :contentIndex 0 :delta " carefully")
       (:type "text_delta" :contentIndex 1 :delta " world")
       (:type "thinking_end" :contentIndex 0 :content "consider carefully")
       (:type "text_end" :contentIndex 1 :content "Hello world")))
    (let ((content (pichat-transcript-node-content
                    (car (pichat-live-draft-nodes draft)))))
      (should (equal '(thinking prose)
                     (mapcar #'pichat-transcript-content-kind content)))
      (should (equal '(0 1)
                     (mapcar #'pichat-transcript-content-index content)))
      (should (equal '("consider carefully" "Hello world")
                     (mapcar #'pichat-transcript-content-text content))))))

(ert-deftest pichat-live-draft-pi-083-and-084-streams-are-equivalent ()
  (let* ((updates '((:type "text_start" :contentIndex 0)
                    (:type "text_delta" :contentIndex 0 :delta "Hel")
                    (:type "text_delta" :contentIndex 0 :delta "lo")
                    (:type "text_end" :contentIndex 0 :content "Hello")))
         (snapshots '((:role "assistant" :content nil)
                      (:role "assistant"
                       :content ((:type "text" :text "Hel")))
                      (:role "assistant"
                       :content ((:type "text" :text "Hello")))
                      (:role "assistant"
                       :content ((:type "text" :text "Hello")))))
         (old (pichat-test--apply-assistant-stream
               (pichat-live-draft-empty 9) updates snapshots))
         (new (pichat-test--apply-assistant-stream
               (pichat-live-draft-empty 9) updates)))
    (should (equal (pichat-live-draft-nodes old)
                   (pichat-live-draft-nodes new)))
    (should (equal "Hello"
                   (pichat-transcript-content-text
                    (car (pichat-transcript-node-content
                          (car (pichat-live-draft-nodes old)))))))
    (should-not (string-match-p "HelHello" (format "%S" old)))))

(ert-deftest pichat-live-draft-assembles-tool-call-fragments-and-completion ()
  (let ((draft (pichat-live-draft-empty 10)))
    (pichat-test--apply-assistant-stream
     draft
     '((:type "toolcall_start" :contentIndex 0)
       (:type "toolcall_delta" :contentIndex 0 :delta "{\"path\":")
       (:type "toolcall_delta" :contentIndex 0 :delta "\"safe.txt\"}")
       (:type "toolcall_end" :contentIndex 0
        :toolCall (:type "toolCall" :id "call-10" :name "read"
                   :arguments (:path "safe.txt")))))
    (let* ((node (car (pichat-live-draft-nodes draft)))
           (tool (car (pichat-transcript-node-content node))))
      (should (eq 'tool (pichat-transcript-content-kind tool)))
      (should (equal "call-10" (pichat-transcript-content-tool-call-id tool)))
      (should (equal "read" (pichat-transcript-content-name tool)))
      (should (equal '(:path "safe.txt")
                     (pichat-transcript-content-arguments tool)))
      (should (eq tool (gethash "call-10" (pichat-live-draft-tools draft))))
      (should (= 0 (hash-table-count
                    (pichat-live-draft-tool-argument-buffers draft)))))))

(ert-deftest pichat-live-draft-malformed-and-control-deltas-are-safe-no-ops ()
  (let ((draft (pichat-live-draft-empty 11)))
    (pichat-test--apply-assistant-stream
     draft
     '((:type "start")
       (:type "text_delta" :contentIndex "bad" :delta "unsafe")
       (:type "future_delta" :contentIndex 0 :delta "unsafe")
       (:type "done")))
    (should-not (pichat-transcript-node-content
                 (car (pichat-live-draft-nodes draft))))
    (should-not (pichat-live-draft-event-changed-p draft))
    (should (= 2 (length (pichat-live-draft-diagnostics draft))))))

(ert-deftest pichat-live-draft-duplicate-terminal-events-and-settlement-clear-scratch ()
  (let ((draft (pichat-live-draft-empty 12)))
    (pichat-test--apply-assistant-stream
     draft
     '((:type "text_start" :contentIndex 0)
       (:type "text_delta" :contentIndex 0 :delta "partial")
       (:type "text_end" :contentIndex 0 :content "complete")
       (:type "text_end" :contentIndex 0 :content "complete")
       (:type "toolcall_start" :contentIndex 1)
       (:type "toolcall_delta" :contentIndex 1 :delta "{")))
    (should (> (hash-table-count
                (pichat-live-draft-tool-argument-buffers draft)) 0))
    (pichat-pi-live-draft-apply draft '(:type "agent_settled"))
    (should (= 0 (hash-table-count
                  (pichat-live-draft-tool-argument-buffers draft))))
    (should (equal "complete"
                   (pichat-transcript-content-text
                    (car (pichat-transcript-node-content
                          (car (pichat-live-draft-nodes draft)))))))))

(ert-deftest pichat-live-draft-final-assistant-message-repairs-preview-content ()
  (let ((draft (pichat-live-draft-empty 2)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_start"
       :message (:role "assistant" :content nil)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_update"
       :message (:role "assistant"
                 :content ((:type "text" :text "partial partial")))
       :assistantMessageEvent
       (:type "text_delta" :contentIndex 0 :delta "partial")))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_end"
       :message (:role "assistant"
                 :content ((:type "thinking" :thinking "final thought")
                           (:type "text" :text "repaired final"))
                 :stopReason "stop")))
    (let* ((node (car (pichat-live-draft-nodes draft)))
           (content (pichat-transcript-node-content node)))
      (should (equal '(thinking prose)
                     (mapcar #'pichat-transcript-content-kind content)))
      (should (equal "repaired final"
                     (pichat-transcript-content-text (cadr content))))
      (should-not (string-match-p "partial partial" (format "%S" draft)))
      (should-not (pichat-live-draft-current-node draft)))))

(ert-deftest pichat-live-draft-message-end-reconciles-streamed-tool-in-place ()
  (let ((draft (pichat-live-draft-empty 13)))
    (pichat-test--apply-assistant-stream
     draft
     '((:type "toolcall_start" :contentIndex 0)
       (:type "toolcall_delta" :contentIndex 0 :delta "{\"path\":\"preview\"}")
       (:type "toolcall_end" :contentIndex 0
        :toolCall (:type "toolCall" :id "call-13" :name "read"
                   :arguments (:path "preview")))))
    (let ((tool (gethash "call-13" (pichat-live-draft-tools draft))))
      (pichat-pi-live-draft-apply
       draft
       '(:type "tool_execution_start" :toolCallId "call-13"
         :toolName "read" :args (:path "authoritative")))
      (pichat-pi-live-draft-apply
       draft
       '(:type "message_end"
         :message
         (:role "assistant" :stopReason "toolUse"
          :content ((:type "toolCall" :id "call-13" :name "read"
                     :arguments (:path "authoritative"))))))
      (let ((reconciled
             (car (pichat-transcript-node-content
                   (car (pichat-live-draft-nodes draft))))))
        (should (eq tool reconciled))
        (should (eq 'running (pichat-transcript-content-status reconciled)))
        (should (equal '(:path "authoritative")
                       (pichat-transcript-content-arguments reconciled)))
        (should (= 0 (hash-table-count
                      (pichat-live-draft-tool-argument-buffers draft))))))))

(ert-deftest pichat-live-draft-correlates-tool-before-declaration-and-final-result ()
  (let ((draft (pichat-live-draft-empty 3)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_start" :toolCallId "tool-early"
       :toolName "early_tool" :args (:value "safe")))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_update" :toolCallId "tool-early"
       :partialResult (:content ((:type "text" :text "first output")))))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_update" :toolCallId "tool-early"
       :partialResult (:content ((:type "text" :text "replacement output")))))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_start"
       :message (:role "assistant" :content nil)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_update"
       :message
       (:role "assistant"
        :content ((:type "toolCall" :id "tool-early"
                   :name "early_tool" :arguments (:value "safe"))))))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_end"
       :message
       (:role "assistant"
        :content ((:type "toolCall" :id "tool-early"
                   :name "early_tool" :arguments (:value "safe")))
        :stopReason "toolUse")))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_end" :toolCallId "tool-early"
       :toolName "early_tool" :isError nil
       :result (:content ((:type "text" :text "final output")))))
    (pichat-pi-live-draft-apply
     draft
     '(:type "message_end"
       :message (:role "toolResult" :toolCallId "tool-early"
                 :toolName "early_tool" :isError nil
                 :content ((:type "text" :text "final output")))))
    (let* ((nodes (pichat-live-draft-nodes draft))
           (tool (car (pichat-transcript-node-content (car nodes)))))
      (should (= 1 (length nodes)))
      (should (eq 'assistant (pichat-transcript-node-role (car nodes))))
      (should (eq 'done (pichat-transcript-content-status tool)))
      (should (equal "final output"
                     (pichat-transcript-content-text
                      (car (pichat-transcript-content-output tool)))))
      (should-not (string-match-p "replacement output" (format "%S" draft))))))

(ert-deftest pichat-live-draft-completed-undeclared-tool-remains-orphan ()
  (let ((draft (pichat-live-draft-empty 5)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_start" :toolCallId "undeclared"
       :toolName "undeclared_tool" :args nil))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_end" :toolCallId "undeclared"
       :toolName "undeclared_tool" :isError nil
       :result (:content ((:type "text" :text "orphan result")))))
    (let ((tool (gethash "undeclared" (pichat-live-draft-tools draft))))
      (should (eq 'orphan (pichat-transcript-content-status tool)))
      (should (eq 'tool
                  (pichat-transcript-node-kind
                   (car (pichat-live-draft-nodes draft))))))))

(ert-deftest pichat-live-draft-settlement-marks-unresolved-tools-incomplete ()
  (let ((draft (pichat-live-draft-empty 4)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "tool_execution_start" :toolCallId "unfinished"
       :toolName "unfinished_tool" :args nil))
    (pichat-pi-live-draft-apply draft '(:type "agent_settled"))
    (let ((tool (gethash "unfinished" (pichat-live-draft-tools draft))))
      (should (eq 'incomplete (pichat-transcript-content-status tool)))
      (should (pichat-live-draft-settled-p draft)))))

(provide 'pichat-test-transcript)
;;; pichat-test-transcript.el ends here
