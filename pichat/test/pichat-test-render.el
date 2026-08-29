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

(defun pichat-test-render--grouping-transcript ()
  "Return a compact transcript with two tool groups and prose boundaries."
  (pichat-transcript-create
   :nodes
   (list
    (pichat-transcript-node-create
     :kind 'message :key "assistant-one" :role 'assistant
     :content
     (list
      (pichat-transcript-content-create
       :kind 'tool :index 0 :tool-call-id "read-one" :name "read"
       :arguments '(:path "one.el") :status 'done
       :output (list (pichat-transcript-content-create
                      :kind 'prose :index 0 :text "first output")))
      (pichat-transcript-content-create
       :kind 'tool :index 1 :tool-call-id "edit-two" :name "edit"
       :arguments '(:path "two.el") :status 'incomplete :output nil)
      (pichat-transcript-content-create
       :kind 'prose :index 2 :text "Assistant **answer**.")))
    (pichat-transcript-node-create
     :kind 'message :key "user" :role 'user
     :content (list (pichat-transcript-content-create
                     :kind 'prose :index 0 :text "Next question")))
    (pichat-transcript-node-create
     :kind 'message :key "assistant-two" :role 'assistant
     :content (list (pichat-transcript-content-create
                     :kind 'tool :index 0 :tool-call-id "fetch-three"
                     :name "fetch" :arguments '(:url "https://example.test")
                     :status 'done :output nil))))
   :diagnostics nil :metadata nil))

(defun pichat-test-render--activity-context (display &optional live latest view)
  "Return an activity render context for DISPLAY, LIVE, LATEST, and VIEW."
  (pichat-render-context-create
   :show-thinking t :tool-view (or view 'summary)
   :max-tool-args 200 :max-tool-output 200
   :activity-member-kinds '(tool) :activity-display display
   :activity-latest-key latest :activity-live-p live))

(ert-deftest pichat-render-activity-collapsed-group-emits-only-bounded-header ()
  (let* ((transcript (pichat-test-render--grouping-transcript))
         (text (pichat-render-fragment-text
                (pichat-render-canonical
                 transcript (pichat-test-render--activity-context 'collapsed)))))
    (should (string-match-p "Read a file and edited a file" text))
    (should (string-match-p "Fetched data" text))
    (should-not (string-match-p (regexp-quote "[tool:") text))
    (should-not (string-match-p (regexp-opt '("one.el" "two.el" "example.test"))
                                text))
    (should (< (string-match-p "Read a file" text)
               (string-match-p (regexp-quote "Assistant **answer**.") text)
               (string-match-p "Next question" text)
               (string-match-p "Fetched data" text)))))

(ert-deftest pichat-render-activity-expanded-groups-preserve-properties-and-indents ()
  (let* ((transcript (pichat-test-render--grouping-transcript))
         (context (pichat-test-render--activity-context 'expanded nil nil 'output))
         (fragment (pichat-render-canonical transcript context))
         (text (pichat-render-fragment-propertized-string fragment))
         (header (string-match "Read a file" text))
         (tool (string-match "tool:read done" text))
         (body (string-match "first output" text))
         (prose (string-match (regexp-quote "Assistant **answer**.") text))
         (user (string-match "▌ Next question" text)))
    (should header)
    (should tool)
    (should (get-text-property header 'pichat-activity-key text))
    (should (get-text-property tool 'pichat-activity-member text))
    (should (equal "  " (get-text-property tool 'line-prefix text)))
    (should (equal "  " (get-text-property tool 'wrap-prefix text)))
    (should (equal "    " (get-text-property body 'line-prefix text)))
    (should (equal "  " (get-text-property prose 'line-prefix text)))
    (should-not (get-text-property header 'line-prefix text))
    (should-not (get-text-property user 'line-prefix text))))

(ert-deftest pichat-render-activity-latest-expands-only-current-live-tail-group ()
  (let* ((transcript (pichat-test-render--grouping-transcript))
         (presentation (pichat-activity-build-presentation
                        transcript '(tool) t))
         (groups (pichat-activity-groups presentation))
         (latest (pichat-activity-group-key (car (last groups))))
         (context (pichat-test-render--activity-context
                   'latest t latest 'summary))
         (text (pichat-render-fragment-text
                (pichat-render-canonical transcript context))))
    (should-not (string-match-p "tool:read" text))
    (should-not (string-match-p "tool:edit" text))
    (should (string-match-p "tool:fetch done" text))))

(ert-deftest pichat-render-logical-activity-records-equal-canonical-exactly ()
  (let* ((transcript (pichat-test-render--grouping-transcript))
         (context (pichat-test-render--activity-context 'expanded nil nil 'output))
         (canonical
          (pichat-render-fragment-propertized-string
           (pichat-render-canonical transcript context)))
         (records (pichat-render-logical-strings transcript context))
         (logical (mapconcat (lambda (record) (plist-get record :text))
                             records "")))
    (should (equal-including-properties canonical logical))
    (should (= 2 (cl-count-if
                  (lambda (record) (plist-get record :activity-key))
                  (seq-filter (lambda (record)
                                (eq 'activity (car-safe (plist-get record :key))))
                              records))))
    (should (= 3 (cl-count-if (lambda (record) (plist-get record :tool-id))
                              records)))
    (should (equal (substring-no-properties canonical)
                   (pichat-render-fragment-text
                    (pichat-render-canonical transcript context))))))

(provide 'pichat-test-render)
;;; pichat-test-render.el ends here
