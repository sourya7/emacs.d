;;; pichat-test-activity-presentation.el --- Activity presentation tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure grouping tests for presentation-only agent activity.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-activity-presentation)

(defun pichat-test-activity--content (kind index &rest properties)
  "Return normalized KIND content at INDEX with PROPERTIES."
  (apply #'pichat-transcript-content-create
         :kind kind :index index properties))

(defun pichat-test-activity--assistant (key contents &optional stop-reason)
  "Return assistant node KEY with CONTENTS and optional STOP-REASON."
  (pichat-transcript-node-create
   :kind 'message :key key :role 'assistant :content contents
   :stop-reason stop-reason))

(defun pichat-test-activity--tool (index id name status &optional output)
  "Return tool content at INDEX with ID, NAME, STATUS, and OUTPUT."
  (pichat-test-activity--content
   'tool index :tool-call-id id :name name
   :arguments '(:secret "must-not-serialize") :status status
   :output (and output
                (list (pichat-test-activity--content
                       'prose 0 :text output)))))

(defun pichat-test-activity--transcript (&rest nodes)
  "Return a transcript containing NODES."
  (pichat-transcript-create :nodes nodes :diagnostics nil :metadata nil))

(ert-deftest pichat-activity-groups-adjacent-tools-across-node-boundaries ()
  (let* ((first (pichat-test-activity--tool 0 "one" "bash" 'done "one out"))
         (second (pichat-test-activity--tool 0 "two" "read" 'incomplete))
         (transcript
          (pichat-test-activity--transcript
           (pichat-test-activity--assistant "a" (list first))
           (pichat-test-activity--assistant "b" (list second))))
         (before (copy-tree transcript t))
         (presentation
          (pichat-activity-build-presentation transcript '(tool) t))
         (groups (pichat-activity-groups presentation))
         (group (car groups)))
    (should (= 1 (length presentation)))
    (should (= 1 (length groups)))
    (should (equal '("one" "two")
                   (pichat-activity-group-tool-ids group)))
    (should (equal "one" (pichat-activity-group-anchor group)))
    (should (eq 'active (pichat-activity-group-status group)))
    (should (= 1 (pichat-activity-group-complete-count group)))
    (should (equal before transcript))
    (should (equal presentation
                   (pichat-activity-build-presentation transcript '(tool) t)))))

(ert-deftest pichat-activity-visible-boundaries-split-tool-runs ()
  (let* ((tool (lambda (node id)
                 (pichat-test-activity--assistant
                  node (list (pichat-test-activity--tool
                              0 id "read" 'done)))))
         (nodes
          (list
           (funcall tool "tool-a" "a")
           (pichat-test-activity--assistant
            "prose" (list (pichat-test-activity--content
                           'prose 0 :text "visible")))
           (funcall tool "tool-b" "b")
           (pichat-transcript-node-create
            :kind 'message :key "user" :role 'user
            :content (list (pichat-test-activity--content
                            'prose 0 :text "question")))
           (funcall tool "tool-c" "c")
           (pichat-transcript-node-create
            :kind 'message :key "custom" :role 'custom :custom-type "note"
            :content (list (pichat-test-activity--content
                            'prose 0 :text "context")))
           (funcall tool "tool-d" "d")
           (pichat-transcript-node-create
            :kind 'activity :key "compact" :activity-type 'compaction
            :tokens-before 42)
           (funcall tool "tool-e" "e")
           (pichat-test-activity--assistant "annotation" nil "aborted")
           (funcall tool "tool-f" "f")))
         (groups
          (pichat-activity-groups
           (pichat-activity-build-presentation
            (apply #'pichat-test-activity--transcript nodes) '(tool) t))))
    (should (equal '(("a") ("b") ("c") ("d") ("e") ("f"))
                   (mapcar #'pichat-activity-group-tool-ids groups)))))

(ert-deftest pichat-activity-hidden-thinking-does-not-split-stage-one-tools ()
  (let* ((node
          (pichat-test-activity--assistant
           "assistant"
           (list (pichat-test-activity--tool 0 "first" "read" 'done)
                 (pichat-test-activity--content
                  'thinking 1 :text "private thought")
                 (pichat-test-activity--tool 2 "second" "edit" 'done))))
         (transcript (pichat-test-activity--transcript node)))
    (should (= 2 (length
                  (pichat-activity-groups
                   (pichat-activity-build-presentation
                    transcript '(tool) t)))))
    (let ((groups (pichat-activity-groups
                   (pichat-activity-build-presentation
                    transcript '(tool) nil))))
      (should (= 1 (length groups)))
      (should (equal '("first" "second")
                     (pichat-activity-group-tool-ids (car groups)))))))

(ert-deftest pichat-activity-generic-member-policy-can-include-thinking ()
  (let* ((node
          (pichat-test-activity--assistant
           "assistant"
           (list (pichat-test-activity--content
                  'thinking 0 :text "inspect")
                 (pichat-test-activity--tool 1 "read" "read" 'done))))
         (group
          (car (pichat-activity-groups
                (pichat-activity-build-presentation
                 (pichat-test-activity--transcript node)
                 '(thinking tool) t)))))
    (should (equal '(thinking tool)
                   (mapcar #'pichat-activity-member-kind
                           (pichat-activity-group-members group))))))

(ert-deftest pichat-activity-group-identity-ignores-status-output-and-arguments ()
  (let* ((make
          (lambda (status output args)
            (let ((tool (pichat-test-activity--tool
                         0 "stable" "bash" status output)))
              (setf (pichat-transcript-content-arguments tool) args)
              (pichat-test-activity--transcript
               (pichat-test-activity--assistant "node" (list tool))))))
         (first (car (pichat-activity-groups
                      (pichat-activity-build-presentation
                       (funcall make 'incomplete "partial" '(:command "one"))
                       '(tool) t))))
         (second (car (pichat-activity-groups
                       (pichat-activity-build-presentation
                        (funcall make 'done "complete" '(:command "two"))
                        '(tool) t)))))
    (should (equal (pichat-activity-group-key first)
                   (pichat-activity-group-key second)))
    (should (equal (pichat-activity-group-anchor first)
                   (pichat-activity-group-anchor second)))
    (should (eq 'active (pichat-activity-group-status first)))
    (should (eq 'complete (pichat-activity-group-status second)))))

(ert-deftest pichat-activity-malformed-ids-use-noncolliding-source-anchors ()
  (let* ((transcript
          (pichat-test-activity--transcript
           (pichat-test-activity--assistant
            "one" (list (pichat-test-activity--tool 0 nil "unknown" 'orphan)))
           (pichat-test-activity--assistant
            "boundary" (list (pichat-test-activity--content
                              'prose 0 :text "split")))
           (pichat-test-activity--assistant
            "two" (list (pichat-test-activity--tool 0 "" "unknown" 'orphan)))))
         (groups (pichat-activity-groups
                  (pichat-activity-build-presentation transcript '(tool) t))))
    (should (= 2 (length groups)))
    (should-not (equal (pichat-activity-group-key (car groups))
                       (pichat-activity-group-key (cadr groups))))
    (should (eq 'orphaned
                (pichat-activity-group-status (car groups))))))

(ert-deftest pichat-activity-summary-is-bounded-and-does-not-read-arguments ()
  (let* ((tool (pichat-test-activity--tool
                0 "summary" "unknown-extension-tool" 'error "huge output"))
         (group
          (car (pichat-activity-groups
                (pichat-activity-build-presentation
                 (pichat-test-activity--transcript
                  (pichat-test-activity--assistant "node" (list tool)))
                 '(tool) t))))
         (before-args (pichat-transcript-content-arguments tool))
         (summary (pichat-activity-format-summary group)))
    (should (string-match-p "Used unknown-extension-tool" summary))
    (should (string-match-p "failed" summary))
    (should-not (string-match-p "must-not-serialize" summary))
    (should (eq before-args (pichat-transcript-content-arguments tool)))
    (should (<= (string-width summary) 160))))

(provide 'pichat-test-activity-presentation)
;;; pichat-test-activity-presentation.el ends here
