;;; pichat-test-render.el --- Pichat Test Render -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

;;; Pure canonical rendering tests

(ert-deftest pichat-render-canonical-fragment-respects-visibility-and-order ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (context (pichat-render-context-create
                   :show-thinking nil :tool-view 'summary
                   :max-tool-args 200 :max-tool-output 200))
         (fragment (pichat-render-canonical transcript context))
         (text (pichat-render-fragment-text fragment)))
    (dolist (visible '("Check the example."
                       "[tool:read_example done]"
                       "The example is valid.[image]"
                       "[context:fixture-visible]"
                       "Visible extension note.[image]"
                       "[compaction: 120 tokens]"
                       "[unsupported content: futureContent]"
                       "Final persisted answer."
                       "[assistant aborted: Stopped by fixture.]"))
      (should (string-match-p (regexp-quote visible) text)))
    (should-not (string-match-p "Inspecting the fixture" text))
    (should-not (string-match-p "Sanitized compact summary" text))
    (should-not (string-match-p
                 (regexp-opt '("Abandoned response."
                               "hidden custom text"
                               "must-not-render"))
                 text))
    (should (< (string-match-p "Check the example" text)
               (string-match-p "tool:read_example" text)
               (string-match-p "Final persisted answer" text)))))

(ert-deftest pichat-render-canonical-fragment-context-controls-thinking-tools-and-truncation ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (context (pichat-render-context-create
                   :show-thinking t :tool-view 'output
                   :max-tool-args 18 :max-tool-output 8))
         (text (pichat-render-fragment-text
                (pichat-render-canonical transcript context))))
    (should (string-match-p "Inspecting the fixture" text))
    (should (string-match-p (regexp-quote "[tool:read_example done]") text))
    (should (string-match-p "chars omitted" text))
    (should (string-match-p "sanitize" text))
    (should-not (string-match-p "sanitized output" text))))

(ert-deftest pichat-render-canonical-fragment-carries-logical-node-and-tool-properties ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (fragment (pichat-render-canonical
                    transcript
                    (pichat-render-context-create
                     :show-thinking t :tool-view 'summary
                     :max-tool-args 200 :max-tool-output 200)))
         (text (pichat-render-fragment-propertized-string fragment))
         user-position tool-position thinking-position)
    (setq user-position (string-match "Check the example" text)
          tool-position (string-match "tool:read_example" text)
          thinking-position (string-match "Inspecting the fixture" text))
    (should (equal "entry-user"
                   (get-text-property user-position 'pichat-node-key text)))
    (should (equal '("entry-tool-call" . "tool-1")
                   (get-text-property tool-position 'pichat-tool-key text)))
    (should (eq 'thinking
                (get-text-property thinking-position 'pichat-content-kind text)))
    (should (eq 'pichat-thinking-face
                (get-text-property thinking-position 'font-lock-face text)))))

(ert-deftest pichat-render-summary-does-not-serialize-tool-arguments ()
  (let* ((tool (pichat-transcript-content-create
                :kind 'tool :index 0 :tool-call-id "large-write"
                :name "write" :arguments '(:path ".tmp/plan" :content "large")
                :status 'done :output nil))
         (transcript
          (pichat-transcript-create
           :nodes (list (pichat-transcript-node-create
                         :kind 'message :key "node" :role 'assistant
                         :content (list tool)))
           :diagnostics nil :metadata nil))
         (context (pichat-render-context-create
                   :show-thinking nil :tool-view 'summary
                   :max-tool-args 10 :max-tool-output 10)))
    (cl-letf (((symbol-function 'pichat-render-tool-args)
               (lambda (_args) (error "arguments serialized"))))
      (should (string-match-p
               (regexp-quote "[tool:write done]")
               (pichat-render-fragment-text
                (pichat-render-canonical transcript context)))))))

(ert-deftest pichat-render-canonical-fragment-is-pure-and-idempotent ()
  (let* ((transcript (pichat-test--canonical-fixture-transcript))
         (before (copy-tree transcript t))
         (context (pichat-render-context-create
                   :show-thinking t :tool-view 'args
                   :max-tool-args 200 :max-tool-output 200))
         (first (pichat-render-canonical transcript context))
         (second (pichat-render-canonical transcript context)))
    (should (equal before transcript))
    (should (equal first second))))

(provide 'pichat-test-render)
;;; pichat-test-render.el ends here
