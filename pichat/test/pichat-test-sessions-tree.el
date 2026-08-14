;;; pichat-test-sessions-tree.el --- Session history tree-model tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused observable tests for the pure session-history tree model.

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

(ert-deftest pichat-sessions-tree-model-handles-empty-and-linear-history ()
  (let ((empty (pichat-sessions--tree-model-from-data
                '(:tree nil :leafId nil))))
    (should-not (pichat-sessions--model-root-ids empty))
    (should-not (pichat-sessions--model-ordered-ids empty)))
  (let* ((assistant (pichat-test-sessions-tree--message
                     "assistant" "assistant" "answer" "user"))
         (user (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "user" "user" "question")
                (list assistant)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list user) :leafId "assistant"))))
    (should (equal '("user") (pichat-sessions--model-root-ids model)))
    (should (equal '("user" "assistant")
                   (pichat-sessions--model-ordered-ids model)))
    (should-not (pichat-sessions--model-parent-id model "user"))
    (should (equal "user"
                   (pichat-sessions--model-parent-id model "assistant")))
    (should (pichat-sessions--model-active-p model "user"))
    (should (pichat-sessions--model-active-p model "assistant"))))

(ert-deftest pichat-sessions-tree-model-orders-active-branch-first-only-for-display ()
  (let* ((old-leaf (pichat-test-sessions-tree--message
                    "old-leaf" "assistant" "old answer" "old"))
         (active-leaf (pichat-test-sessions-tree--message
                       "active-leaf" "assistant" "active answer" "active"))
         (old (pichat-test-sessions-tree--set-children
               (pichat-test-sessions-tree--message "old" "user" "old branch" "root")
               (list old-leaf)))
         (active (pichat-test-sessions-tree--set-children
                  (pichat-test-sessions-tree--message
                   "active" "user" "active branch" "root")
                  (list active-leaf)))
         (root (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "root" "user" "root")
                (list old active)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list root) :leafId "active-leaf"))))
    (should (equal '("old" "active")
                   (pichat-sessions--model-child-ids model "root")))
    (should (equal '("root" "active" "active-leaf" "old" "old-leaf")
                   (pichat-sessions--model-ordered-ids model)))
    (should (equal "root" (pichat-sessions--model-parent-id model "old")))
    (should (equal "root" (pichat-sessions--model-parent-id model "active")))))

(ert-deftest pichat-sessions-tree-model-preserves-roots-and-promotes-active-root ()
  (let* ((first (pichat-test-sessions-tree--message "first" "user" "first"))
         (second (pichat-test-sessions-tree--message "second" "user" "second"))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list first second) :leafId "second"))))
    (should (equal '("first" "second")
                   (pichat-sessions--model-root-ids model)))
    (should (equal '("second" "first")
                   (pichat-sessions--model-ordered-ids model)))))

(ert-deftest pichat-sessions-tree-model-uses-nesting-for-orphan-and-self-parent-roots ()
  (let* ((orphan (pichat-test-sessions-tree--message
                  "orphan" "user" "orphan" "missing"))
         (self (pichat-test-sessions-tree--message
                "self" "user" "self" "self"))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list orphan self) :leafId "orphan"))))
    (should (equal '("orphan" "self")
                   (pichat-sessions--model-root-ids model)))
    (should-not (pichat-sessions--model-parent-id model "orphan"))
    (should-not (pichat-sessions--model-parent-id model "self"))))

(ert-deftest pichat-sessions-tree-model-attaches-resolved-label-metadata ()
  (let* ((node (append
                (pichat-test-sessions-tree--message "labeled" "user" "keep")
                '(:label "checkpoint" :labelTimestamp 12345)))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree (list node) :leafId "labeled"))))
    (should (equal "checkpoint"
                   (pichat-sessions--model-node-label model "labeled")))
    (should (equal 12345
                   (pichat-sessions--model-node-label-timestamp
                    model "labeled")))))

(ert-deftest pichat-sessions-tree-model-recognizes-pi-v3-shapes-and-tools ()
  (let* ((assistant
          (pichat-test-sessions-tree--entry
           "assistant" "message"
           :message '(:role "assistant"
                      :content ((:type "text" :text "checking")
                                (:type "toolCall" :id "call-1" :name "read"
                                 :arguments (:path "README.md"))))))
         (result
          (pichat-test-sessions-tree--entry
           "result" "message"
           :message '(:role "toolResult" :toolCallId "call-1"
                      :toolName "read" :content ((:type "text" :text "ok")))))
         (nodes
          (append
           (list (pichat-test-sessions-tree--message "user" "user" "prompt")
                 assistant result
                 (pichat-test-sessions-tree--message
                  "bash" "bashExecution" "command output")
                 (pichat-test-sessions-tree--message
                  "custom-role" "reviewer" "review note"))
           (mapcar (lambda (spec)
                     (apply #'pichat-test-sessions-tree--entry spec))
                   '(("custom-message" "custom_message" :customType "notice"
                      :content "custom text")
                     ("compaction" "compaction" :summary "compact summary")
                     ("branch" "branch_summary" :summary "branch summary")
                     ("model" "model_change" :provider "p" :modelId "m")
                     ("thinking" "thinking_level_change" :thinkingLevel "high")
                     ("custom" "custom" :customType "state" :data (:ok t))
                     ("label-entry" "label" :targetId "user" :label "raw")
                     ("session-info" "session_info" :name "named")))))
         (model (pichat-sessions--tree-model-from-data
                 (list :tree nodes :leafId "result"))))
    (dolist (id '("user" "assistant" "result" "bash" "custom-role"
                  "custom-message" "compaction" "branch" "model" "thinking" "custom"
                  "label-entry" "session-info"))
      (should (stringp (pichat-sessions--model-node-kind model id)))
      (should (stringp (pichat-sessions--model-node-summary model id))))
    (should (equal '((:id "call-1" :name "read"
                      :arguments (:path "README.md")))
                   (pichat-sessions--model-node-tool-calls model "assistant")))
    (should (equal '(:id "call-1" :name "read"
                     :arguments (:path "README.md"))
                   (pichat-sessions--model-node-tool-call model "result")))
    (should (string-match-p "read"
                            (pichat-sessions--model-node-summary
                             model "result")))
    (should (equal "reviewer"
                   (pichat-sessions--model-node-kind model "custom-role")))))

(ert-deftest pichat-sessions-tree-model-indexes-deep-history-iteratively ()
  (let ((node (pichat-test-sessions-tree--message
               "deep-0" "assistant" "leaf")))
    (dotimes (index 1500)
      (setq node
            (pichat-test-sessions-tree--set-children
             (pichat-test-sessions-tree--message
              (format "deep-%d" (1+ index)) "user" "ancestor")
             (list node))))
    (let* ((model (pichat-sessions--tree-model-from-data
                   (list :tree (list node) :leafId "deep-0")))
           (ordered (pichat-sessions--model-ordered-ids model)))
      (should (= 1501 (length ordered)))
      (should (equal "deep-1500" (car ordered)))
      (should (equal "deep-0" (car (last ordered)))))))

(defun pichat-test-sessions-tree--response (roots leaf-id)
  "Return a get_tree response for ROOTS and LEAF-ID."
  (list :data (list :tree roots :leafId leaf-id)))

(defun pichat-test-sessions-tree--line-for-id (id)
  "Return the rendered history line carrying ID."
  (pichat-sessions--goto-id id)
  (buffer-substring-no-properties (line-beginning-position)
                                  (line-end-position)))

(ert-deftest pichat-sessions-tree-render-marks-active-path-and-real-branches ()
  (let* ((old-leaf (pichat-test-sessions-tree--message
                    "old-leaf" "assistant" "old answer"))
         (old (pichat-test-sessions-tree--set-children
               (pichat-test-sessions-tree--message "old" "user" "old branch")
               (list old-leaf)))
         (active (pichat-test-sessions-tree--message
                  "active" "user" "active branch"))
         (root (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "root" "user" "root")
                (list old active))))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list root) "old-leaf")
       (pichat-session-make) (current-buffer))
      (should (string-match-p "•.*root" (pichat-test-sessions-tree--line-for-id "root")))
      (should (string-match-p "├─.*•.*old branch"
                              (pichat-test-sessions-tree--line-for-id "old")))
      (should (string-match-p "│.*•.*old answer"
                              (pichat-test-sessions-tree--line-for-id "old-leaf")))
      (should (string-match-p "└─.*active branch"
                              (pichat-test-sessions-tree--line-for-id "active"))))))

(ert-deftest pichat-sessions-tree-render-does-not-indent-linear-history ()
  (let* ((third (pichat-test-sessions-tree--message "third" "user" "third"))
         (second (pichat-test-sessions-tree--set-children
                  (pichat-test-sessions-tree--message "second" "assistant" "second")
                  (list third)))
         (first (pichat-test-sessions-tree--set-children
                 (pichat-test-sessions-tree--message "first" "user" "first")
                 (list second))))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list first) "third")
       (pichat-session-make) (current-buffer))
      (let (columns)
        (dolist (id '("first" "second" "third"))
          (pichat-sessions--goto-id id)
          (search-forward (concat (if (equal id "second") "assistant" "user") ":"))
          (goto-char (match-beginning 0))
          (push (current-column) columns))
        (should (apply #'= columns))))))

(ert-deftest pichat-sessions-tree-render-attaches-row-ids-at-boundaries-and-labels ()
  (let ((node (append
               (pichat-test-sessions-tree--message "labeled" "user" "keep")
               '(:label "checkpoint"))))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list node) "labeled")
       (pichat-session-make) (current-buffer))
      (pichat-sessions--goto-id "labeled")
      (should (equal "labeled" (pichat-sessions--entry-id-at-point)))
      (end-of-line)
      (should (equal "labeled" (pichat-sessions--entry-id-at-point)))
      (should (string-match-p "\\[checkpoint\\]"
                              (pichat-test-sessions-tree--line-for-id "labeled")))
      (should-not (string-match-p "labeled"
                                  (pichat-test-sessions-tree--line-for-id "labeled"))))))

(ert-deftest pichat-sessions-tree-selection-highlight-follows-point ()
  (let ((first (pichat-test-sessions-tree--message "first" "user" "first"))
        (second (pichat-test-sessions-tree--message "second" "user" "second")))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response
       (pichat-test-sessions-tree--response (list first second) "second")
       (pichat-session-make) (current-buffer))
      (should hl-line-mode)
      (pichat-sessions--goto-id "second")
      (hl-line-highlight)
      (should (= (line-beginning-position) (overlay-start hl-line-overlay)))
      (pichat-sessions--goto-id "first")
      (hl-line-highlight)
      (should (= (line-beginning-position) (overlay-start hl-line-overlay))))))

(ert-deftest pichat-sessions-tree-rerender-preserves-view-state-and-selection ()
  (let* ((session (pichat-session-make))
         (first (pichat-test-sessions-tree--message "first" "user" "first"))
         (second (pichat-test-sessions-tree--message "second" "user" "second"))
         (response (pichat-test-sessions-tree--response
                    (list first second) "second")))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response response session (current-buffer))
      (pichat-sessions--goto-id "first")
      (setq pichat-sessions--filter 'all
            pichat-sessions--query "first")
      (puthash "second" t pichat-sessions--folded)
      (pichat-sessions--refresh-from-response response session (current-buffer))
      (should (eq 'all pichat-sessions--filter))
      (should (equal "first" pichat-sessions--query))
      (should (gethash "second" pichat-sessions--folded))
      (should (equal "first" (pichat-sessions--entry-id-at-point)))
      (should (equal "first" pichat-sessions--selected-id)))))

(ert-deftest pichat-sessions-tree-rerender-is-transactional-on-render-error ()
  (let* ((session (pichat-session-make))
         (first (pichat-test-sessions-tree--message "first" "user" "first"))
         (initial (pichat-test-sessions-tree--response (list first) "first")))
    (with-temp-buffer
      (pichat-sessions--refresh-from-response initial session (current-buffer))
      (let ((before (buffer-string))
            (old-nodes pichat-sessions--nodes))
        (cl-letf (((symbol-function 'pichat-sessions--render-entry-line)
                   (lambda (&rest _args) (error "render failed"))))
          (should-error
           (pichat-sessions--refresh-from-response initial session
                                                   (current-buffer))))
        (should (equal before (buffer-string)))
        (should (eq old-nodes pichat-sessions--nodes))))))

(ert-deftest pichat-sessions-tree-details-bounds-deep-raw-node-printing ()
  (let ((node (pichat-test-sessions-tree--message
               "deep-leaf" "assistant" "leaf"))
        (details-buffer-name "*PiChat Session Entry*"))
    (dotimes (index 220)
      (setq node
            (pichat-test-sessions-tree--set-children
             (pichat-test-sessions-tree--message
              (format "deep-parent-%d" index) "user" "ancestor")
             (list node))))
    (unwind-protect
        (with-temp-buffer
          (pichat-sessions--refresh-from-response
           (pichat-test-sessions-tree--response (list node) "deep-leaf")
           (pichat-session-make) (current-buffer))
          (pichat-sessions--goto-id "deep-parent-219")
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (pichat-sessions-show-details-at-point))
          (with-current-buffer details-buffer-name
            (should (derived-mode-p 'pichat-view-mode))
            (should (string-match-p "ID: deep-parent-219" (buffer-string)))
            (should (string-match-p "Entry:" (buffer-string)))
            (should (string-match-p "Node:" (buffer-string)))
            (should-not (string-match-p "deep-parent-0" (buffer-string)))))
      (when-let ((buffer (get-buffer details-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest pichat-sessions-tree-model-skips-invalid-duplicates-and-nesting-cycles ()
  (let* ((first (pichat-test-sessions-tree--message "duplicate" "user" "first"))
         (duplicate (pichat-test-sessions-tree--message
                     "duplicate" "assistant" "second"))
         (missing (pichat-test-sessions-tree--entry nil "custom" :data nil))
         (cycle (pichat-test-sessions-tree--message "cycle" "user" "cycle")))
    (setf (plist-get cycle :children) (list cycle))
    (let ((model (pichat-sessions--tree-model-from-data
                  (list :tree (list first duplicate missing cycle)
                        :leafId "cycle"))))
      (should (equal '("cycle" "duplicate")
                     (sort (copy-sequence
                            (pichat-sessions--model-ordered-ids model))
                           #'string<)))
      (should (<= 3 (length (pichat-sessions--model-diagnostics model))))
      (dolist (diagnostic (pichat-sessions--model-diagnostics model))
        (should (<= (length diagnostic) 240))))))

(ert-deftest pichat-sessions-tree-active-path-is-bounded-on-malformed-parent-cycle ()
  (let ((nodes (make-hash-table :test #'equal))
        (parents (make-hash-table :test #'equal)))
    (puthash "a" t nodes)
    (puthash "b" t nodes)
    (puthash "a" "b" parents)
    (puthash "b" "a" parents)
    (let ((active (pichat-sessions--build-active-path nodes parents "a")))
      (should (= 2 (hash-table-count active)))
      (should (gethash "a" active))
      (should (gethash "b" active)))))

(provide 'pichat-test-sessions-tree)
;;; pichat-test-sessions-tree.el ends here
