;;; pichat-test-sessions-visibility.el --- History visibility tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for session-history filtering, search, and folding.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-sessions-tree)

(defun pichat-test-sessions-visibility--ids (model filter &optional query folded)
  "Return visible IDs from MODEL under FILTER, QUERY, and FOLDED."
  (plist-get (pichat-sessions--project-visible
              model filter query
              (or folded (make-hash-table :test #'equal)))
             :ordered-ids))

(defun pichat-test-sessions-visibility--sorted (ids)
  "Return a sorted copy of IDS."
  (sort (copy-sequence ids) #'string<))

(defun pichat-test-sessions-visibility--fixture ()
  "Return a model containing every Phase 4 visibility category."
  (let* ((labeled (append
                   (pichat-test-sessions-tree--message
                    "labeled" "assistant" "labeled answer")
                   '(:label "checkpoint")))
         (nodes
          (list
           (pichat-test-sessions-tree--message "user" "user" "question")
           (pichat-test-sessions-tree--message
            "assistant" "assistant" "answer")
           (pichat-test-sessions-tree--entry
            "tool-result" "message"
            :message '(:role "toolResult" :toolCallId "call"
                       :content ((:type "text" :text "tool output"))))
           (pichat-test-sessions-tree--entry
            "compaction" "compaction" :summary "compact summary")
           (pichat-test-sessions-tree--entry
            "branch" "branch_summary" :summary "branch summary")
           (pichat-test-sessions-tree--entry
            "custom-message" "custom_message" :customType "notice"
            :content "visible custom text")
           labeled
           (pichat-test-sessions-tree--entry
            "raw-label" "label" :targetId "user" :label "raw bookkeeping")
           (pichat-test-sessions-tree--entry "custom" "custom" :customType "state")
           (pichat-test-sessions-tree--entry
            "model" "model_change" :provider "provider" :modelId "model-x")
           (pichat-test-sessions-tree--entry
            "thinking" "thinking_level_change" :thinkingLevel "high")
           (pichat-test-sessions-tree--entry
            "session" "session_info" :name "named session"))))
    (pichat-sessions--tree-model-from-data
     (list :tree nodes :leafId "user"))))

(ert-deftest pichat-sessions-visibility-matches-exact-filter-matrix ()
  (let ((model (pichat-test-sessions-visibility--fixture)))
    (should
     (equal
      '("assistant" "branch" "compaction" "custom-message" "labeled"
        "tool-result" "user")
      (pichat-test-sessions-visibility--sorted
       (pichat-test-sessions-visibility--ids model 'default))))
    (should
     (equal
      '("assistant" "branch" "compaction" "custom-message" "labeled" "user")
      (pichat-test-sessions-visibility--sorted
       (pichat-test-sessions-visibility--ids model 'no-tools))))
    (should (equal '("user")
                   (pichat-test-sessions-visibility--ids model 'user-only)))
    ;; The otherwise-hidden active leaf remains visible by the documented
    ;; current-position fallback policy.
    (should (equal '("user" "labeled")
                   (pichat-test-sessions-visibility--ids model 'labeled-only)))
    (should (= 12 (length
                   (pichat-test-sessions-visibility--ids model 'all))))))

(ert-deftest pichat-sessions-visibility-handles-tool-only-assistants-and-current-leaf ()
  (let* ((tool-content
          '((:type "toolCall" :id "call" :name "read"
             :arguments (:path "README.md"))))
         (old (pichat-test-sessions-tree--entry
               "old" "message" :message
               (list :role "assistant" :content tool-content)))
         (errored (pichat-test-sessions-tree--entry
                   "errored" "message" :error "failed" :message
                   (list :role "assistant" :content tool-content)))
         (current (pichat-test-sessions-tree--entry
                   "current" "message" :message
                   (list :role "assistant" :content tool-content)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list old errored current) :leafId "current"))))
    (should (equal '("current" "errored")
                   (pichat-test-sessions-visibility--ids model 'default)))
    (should (equal '("current")
                   (pichat-test-sessions-visibility--ids model 'user-only)))
    (should (equal '("current" "errored" "old")
                   (pichat-test-sessions-visibility--sorted
                    (pichat-test-sessions-visibility--ids model 'all))))))

(ert-deftest pichat-sessions-visibility-labeled-mode-uses-resolved-targets ()
  (let ((model (pichat-test-sessions-visibility--fixture)))
    (should (equal '("user" "labeled")
                   (pichat-test-sessions-visibility--ids model 'labeled-only)))
    (should-not (member "raw-label"
                        (pichat-test-sessions-visibility--ids
                         model 'labeled-only)))))

(ert-deftest pichat-sessions-search-requires-case-insensitive-and-tokens ()
  (let* ((assistant
          (pichat-test-sessions-tree--entry
           "assistant" "message"
           :message '(:role "assistant"
                      :content ((:type "text" :text "Checking project")
                                (:type "toolCall" :id "call-1" :name "Read"
                                 :arguments (:path "SecretFile.el"))))))
         (result
          (pichat-test-sessions-tree--entry
           "result" "message"
           :message '(:role "toolResult" :toolCallId "call-1"
                      :content ((:type "text" :text "Unique Output")))))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list assistant result) :leafId "result"))))
    (should (equal '("result" "assistant")
                   (pichat-test-sessions-visibility--ids
                    model 'default "read SECRETfile")))
    (should (equal '("result")
                   (pichat-test-sessions-visibility--ids
                    model 'default "toolresult unique")))
    (should-not (pichat-test-sessions-visibility--ids
                 model 'default "checking missing"))))

(ert-deftest pichat-sessions-search-indexes-required-visible-metadata ()
  (let ((model (pichat-test-sessions-visibility--fixture)))
    (dolist (case '((default "checkpoint" "labeled")
                    (default "compact summary" "compaction")
                    (default "branch summary" "branch")
                    (default "notice visible" "custom-message")
                    (all "provider model-x" "model")
                    (all "thinking high" "thinking")
                    (all "named session" "session")))
      (pcase-let ((`(,filter ,query ,id) case))
        (should (equal (list id)
                       (pichat-test-sessions-visibility--ids
                        model filter query)))))))

(ert-deftest pichat-sessions-search-empty-input-clears-query-and-updates-header ()
  (let* ((session (pichat-session-make))
         (node (pichat-test-sessions-tree--message "user" "user" "question"))
         (response (pichat-test-sessions-tree--response (list node) "user")))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response response session (current-buffer))
      (setq pichat-sessions--query "old query")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _args) "  ")))
        (call-interactively #'pichat-sessions-search))
      (should-not pichat-sessions--query)
      (should-not (string-match-p "query:" (buffer-string))))))

(ert-deftest pichat-sessions-folding-retains-root-and-hides-descendants ()
  (let* ((leaf (pichat-test-sessions-tree--message "leaf" "assistant" "answer"))
         (root (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "root" "user" "question")
                (list leaf)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list root) :leafId "leaf")))
         (folded (make-hash-table :test #'equal)))
    (puthash "root" t folded)
    (should (equal '("root")
                   (pichat-test-sessions-visibility--ids
                    model 'default nil folded)))))

(ert-deftest pichat-sessions-visible-geometry-reparents-after-filter-and-fold ()
  (let* ((a-leaf (pichat-test-sessions-tree--message
                  "a-leaf" "assistant" "A answer"))
         (a (pichat-test-sessions-tree--set-children
             (pichat-test-sessions-tree--message "a" "user" "A")
             (list a-leaf)))
         (b (pichat-test-sessions-tree--message "b" "user" "B"))
         (branch-root (pichat-test-sessions-tree--set-children
                       (pichat-test-sessions-tree--message
                        "branch-root" "user" "choose")
                       (list a b)))
         (hidden-root (pichat-test-sessions-tree--set-children
                       (pichat-test-sessions-tree--entry
                        "hidden" "custom" :customType "state")
                       (list branch-root)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list hidden-root) :leafId "a-leaf")))
         (projection (pichat-sessions--project-visible
                      model 'default nil (make-hash-table :test #'equal)))
         (prefixes (pichat-sessions--tree-prefixes projection))
         (folded (make-hash-table :test #'equal)))
    (should-not (gethash "branch-root" (plist-get projection :parents)))
    (should (equal "branch-root"
                   (gethash "a" (plist-get projection :parents))))
    (should (equal "branch-root"
                   (gethash "b" (plist-get projection :parents))))
    (should (equal "├─" (gethash "a" prefixes)))
    (should (equal "└─" (gethash "b" prefixes)))
    (should (gethash "a" (plist-get projection :foldable)))
    (puthash "a" t folded)
    (setq projection (pichat-sessions--project-visible
                      model 'default nil folded))
    (should (equal '("branch-root" "a" "b")
                   (plist-get projection :ordered-ids)))
    (should-not (member "a-leaf" (plist-get projection :ordered-ids)))))

(ert-deftest pichat-sessions-folds-survive-refresh-only-while-ids-exist ()
  (let* ((session (pichat-session-make))
         (keep (pichat-test-sessions-tree--message "keep" "user" "keep"))
         (stale (pichat-test-sessions-tree--message "stale" "user" "stale")))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list keep stale) "keep")
       session (current-buffer))
      (puthash "keep" t pichat-sessions--folded)
      (puthash "stale" t pichat-sessions--folded)
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list keep) "keep")
       session (current-buffer))
      (should (gethash "keep" pichat-sessions--folded))
      (should-not (gethash "stale" pichat-sessions--folded)))))

(ert-deftest pichat-sessions-filter-cycle-and-fold-bindings-match-phase-four ()
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "/"))
              #'pichat-sessions-search))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "F"))
              #'pichat-sessions-cycle-filter))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "TAB"))
              #'pichat-sessions-toggle-fold-at-point))
  (with-temp-buffer
    (pichat-sessions-mode)
    (setq pichat-sessions--filter 'default)
    (cl-letf (((symbol-function 'pichat-sessions--rerender) #'ignore))
      (dotimes (_ 5)
        (pichat-sessions-cycle-filter))
      (should (eq pichat-sessions--filter 'default)))))

(provide 'pichat-test-sessions-visibility)
;;; pichat-test-sessions-visibility.el ends here
