;;; pichat-test-chat-projection-incremental.el --- Incremental live projection tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Behavioral and structural coverage for logical live-fragment replacement.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-incremental--assistant-event (type content)
  "Return assistant event TYPE containing CONTENT."
  (list :type type
        :message (list :role "assistant" :content content)))

(defun pichat-test-incremental--text-content (text)
  "Return one normalized wire text item containing TEXT."
  (list (list :type "text" :text text)))

(defun pichat-test-incremental--start-two-nodes (draft second-text)
  "Populate DRAFT with a stable node and a live SECOND-TEXT node."
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event
    "message_end" (pichat-test-incremental--text-content "stable node")))
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event "message_start" nil))
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event
    "message_update" (pichat-test-incremental--text-content second-text))))

(defun pichat-test-incremental--update-current-text (draft text)
  "Replace DRAFT's current assistant content with TEXT."
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event
    "message_update" (pichat-test-incremental--text-content text))))

(defun pichat-test-incremental--fragment-for-node (node-key &optional tool-id)
  "Return committed fragment for NODE-KEY and optional TOOL-ID."
  (cl-find-if
   (lambda (fragment)
     (and (equal node-key (plist-get fragment :node-key))
          (if tool-id
              (equal tool-id (plist-get fragment :tool-id))
            (null (plist-get fragment :tool-id)))))
   pichat-chat--live-projection-fragments))

(defun pichat-test-incremental--fragment-start (fragment)
  "Return start marker owned by FRAGMENT."
  (plist-get fragment :start))

(defun pichat-test-incremental--tool-call (id name arguments)
  "Return a wire tool call with ID, NAME, and ARGUMENTS."
  (list :type "toolCall" :id id :name name :arguments arguments))

(ert-deftest pichat-chat-incremental-prose-reuses-unchanged-node-and-revises-current ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-incremental--start-two-nodes
               pichat-chat--live-draft "draft")
              (pichat-chat--project-live-tail)
              (let* ((nodes (pichat-live-draft-nodes pichat-chat--live-draft))
                     (stable-key (pichat-transcript-node-key (car nodes)))
                     (stable-fragment
                      (pichat-test-incremental--fragment-for-node stable-key))
                     (stable-start
                      (pichat-test-incremental--fragment-start stable-fragment)))
                (pichat-test-incremental--update-current-text
                 pichat-chat--live-draft "draft appended")
                (pichat-chat--project-live-tail)
                (should (eq stable-fragment
                            (pichat-test-incremental--fragment-for-node
                             stable-key)))
                (should (eq stable-start
                            (pichat-test-incremental--fragment-start
                             (pichat-test-incremental--fragment-for-node
                              stable-key))))
                (should (string-match-p "draft appended"
                                        (pichat-test-buffer-text buffer)))
                (pichat-test-incremental--update-current-text
                 pichat-chat--live-draft "fully revised")
                (pichat-chat--project-live-tail)
                (should (eq stable-fragment
                            (pichat-test-incremental--fragment-for-node
                             stable-key)))
                (should (string-match-p "fully revised"
                                        (pichat-test-buffer-text buffer)))
                (should-not (string-match-p "draft appended"
                                            (pichat-test-buffer-text buffer))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-incremental-write-change-preserves-earlier-tool-and-prose ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event
                "message_end"
                (list (pichat-test-incremental--tool-call
                       "exec-old" "bash" '(:command "printf old")))))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "tool_execution_end" :toolCallId "exec-old"
                 :toolName "bash" :args (:command "printf old")
                 :isError nil :result (:content ((:type "text" :text "old")))))
              (let ((record
                     (pichat-tool-enrichment-build
                      "exec-old" "bash" '(:command "printf old"))))
                (setq record
                      (plist-put record :source-generation
                                 pichat-chat--source-generation)
                      record (plist-put record :host-path "/tmp/old-command"))
                (puthash "exec-old" record pichat-chat--tool-enrichments))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event "message_start" nil))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event
                "message_update"
                (list (list :type "text" :text "writing")
                      (pichat-test-incremental--tool-call
                       "write-active" "write"
                       (list :path "out" :content (make-string 4000 ?a))))))
              (pichat-chat--project-live-tail)
              (let* ((current-node
                      (car (last (pichat-live-draft-nodes
                                  pichat-chat--live-draft))))
                     (current-key (pichat-transcript-node-key current-node))
                     (prose-fragment
                      (pichat-test-incremental--fragment-for-node current-key))
                     (prose-marker (plist-get prose-fragment :start))
                     (old-block (gethash "exec-old"
                                         pichat-chat--live-tool-blocks))
                     (old-start (plist-get old-block :start))
                     (old-end (plist-get old-block :end))
                     (old-overlay (plist-get old-block :overlay))
                     (write-block (gethash "write-active"
                                           pichat-chat--live-tool-blocks)))
                (should (overlayp old-overlay))
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 (pichat-test-incremental--assistant-event
                  "message_update"
                  (list (list :type "text" :text "writing")
                        (pichat-test-incremental--tool-call
                         "write-active" "write"
                         (list :path "out" :content (make-string 8000 ?b))))))
                (pichat-chat--project-live-tail)
                (let ((new-old-block
                       (gethash "exec-old" pichat-chat--live-tool-blocks))
                      (new-write-block
                       (gethash "write-active" pichat-chat--live-tool-blocks)))
                  (should (eq old-block new-old-block))
                  (should (eq old-start (plist-get new-old-block :start)))
                  (should (eq old-end (plist-get new-old-block :end)))
                  (should (eq old-overlay (plist-get new-old-block :overlay)))
                  (should (eq prose-fragment
                              (pichat-test-incremental--fragment-for-node
                               current-key)))
                  (should (eq prose-marker
                              (plist-get
                               (pichat-test-incremental--fragment-for-node
                                current-key)
                               :start)))
                  (should-not (eq write-block new-write-block))
                  (should (= 8000
                             (length
                              (plist-get
                               (plist-get
                                (plist-get new-write-block :raw) :args)
                               :content))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-incremental-tool-insert-reattach-remove-and-orphan ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          buffer standalone-key)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "tool_execution_start" :toolCallId "moving-tool"
                 :toolName "read" :args (:path "moving.el")))
              (setq standalone-key
                    (pichat-transcript-node-key
                     (car (pichat-live-draft-nodes pichat-chat--live-draft))))
              (pichat-chat--project-live-tail)
              (should (gethash "moving-tool" pichat-chat--live-tool-blocks))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event "message_start" nil))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event
                "message_update"
                (list (pichat-test-incremental--tool-call
                       "moving-tool" "read" '(:path "moving.el")))))
              (pichat-chat--project-live-tail)
              (let* ((block (gethash "moving-tool"
                                     pichat-chat--live-tool-blocks))
                     (attached-key (car (plist-get block :canonical-key))))
                (should block)
                (should-not (equal standalone-key attached-key))
                (should (= 1 (how-many (regexp-quote "… read   moving.el")
                                       (point-min) (point-max)))))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               (pichat-test-incremental--assistant-event
                "message_update" nil))
              (pichat-chat--project-live-tail)
              (should-not (gethash "moving-tool"
                                   pichat-chat--live-tool-blocks))
              (should-not (string-match-p
                           (regexp-quote "[tool:read")
                           (buffer-substring-no-properties
                            pichat-chat--live-start pichat-chat--live-end)))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "tool_execution_end" :toolCallId "moving-tool"
                 :toolName "read" :args (:path "moving.el") :isError nil
                 :result (:content ((:type "text" :text "contents")))))
              (pichat-chat--project-live-tail)
              (let ((block (gethash "moving-tool"
                                    pichat-chat--live-tool-blocks)))
                (should block)
                (should (equal "orphan" (plist-get block :status)))
                (should (string-match-p
                         (regexp-quote "? read   moving.el")
                         (buffer-substring-no-properties
                          pichat-chat--live-start pichat-chat--live-end))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-incremental-preserves-points-in-changed-and-unchanged-nodes ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-follow-bottom-threshold 0)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-incremental--start-two-nodes
               pichat-chat--live-draft "second draft")
              (pichat-chat--project-live-tail)
              (let* ((nodes (pichat-live-draft-nodes pichat-chat--live-draft))
                     (stable-key (pichat-transcript-node-key (car nodes)))
                     (changed-key (pichat-transcript-node-key (cadr nodes)))
                     (stable-position
                      (+ 3 (text-property-any
                            pichat-chat--live-start pichat-chat--live-end
                            'pichat-node-key stable-key))))
                (goto-char stable-position)
                (pichat-test-incremental--update-current-text
                 pichat-chat--live-draft "second draft extended")
                (pichat-chat--project-live-tail)
                (should (= stable-position (point)))
                (should (equal stable-key
                               (get-text-property (point) 'pichat-node-key)))
                (let* ((changed-position
                        (+ 4 (text-property-any
                              pichat-chat--live-start pichat-chat--live-end
                              'pichat-node-key changed-key)))
                       (anchor (pichat-chat--logical-anchor-at changed-position)))
                  (goto-char changed-position)
                  (pichat-test-incremental--update-current-text
                   pichat-chat--live-draft "SECOND revised text")
                  (pichat-chat--project-live-tail)
                  (should (equal changed-key
                                 (get-text-property (point)
                                                    'pichat-node-key)))
                  (should (= (cadr anchor)
                             (cadr (pichat-chat--logical-anchor-at
                                    (point)))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-incremental-fallback-matches-incremental-result ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer incremental full (full-count 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-incremental--start-two-nodes
               pichat-chat--live-draft "before")
              (pichat-chat--project-live-tail)
              (pichat-test-incremental--update-current-text
               pichat-chat--live-draft "after with more text")
              (pichat-chat--project-live-tail)
              (setq incremental
                    (buffer-substring pichat-chat--live-start
                                      pichat-chat--live-end))
              (pichat-chat--release-live-projection-fragments)
              (setq pichat-chat--live-projection-fragments nil
                    pichat-chat--live-projection-fingerprint nil)
              (cl-letf (((symbol-function 'pichat-chat--replace-live-full)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--replace-live-full)))
                           (lambda (candidate)
                             (cl-incf full-count)
                             (funcall original candidate)))))
                (pichat-chat--project-live-tail))
              (setq full (buffer-substring pichat-chat--live-start
                                            pichat-chat--live-end))
              (should (= 1 full-count))
              (should (equal-including-properties incremental full))
              ;; An unexpected source property makes the cached boundaries
              ;; ambiguous and must choose the same exact full fallback.
              (let ((inhibit-read-only t)
                    (inhibit-modification-hooks t))
                (add-text-properties
                 (marker-position pichat-chat--live-start)
                 (1+ (marker-position pichat-chat--live-start))
                 '(pichat-test-ambiguous t)))
              (pichat-test-incremental--update-current-text
               pichat-chat--live-draft "another revision")
              (cl-letf (((symbol-function 'pichat-chat--replace-live-full)
                         (let ((original
                                (symbol-function
                                 'pichat-chat--replace-live-full)))
                           (lambda (candidate)
                             (cl-incf full-count)
                             (funcall original candidate)))))
                (pichat-chat--project-live-tail))
              (should (= 2 full-count))
              (should-not
               (text-property-any pichat-chat--live-start
                                  pichat-chat--live-end
                                  'pichat-test-ambiguous t))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-render-logical-strings-compose-exact-canonical-text ()
  (let* ((tool (pichat-transcript-content-create
                :kind 'tool :index 1 :tool-call-id "logical-tool"
                :name "read" :arguments '(:path "a.el") :status 'running))
         (node (pichat-transcript-node-create
                :kind 'message :key "logical-node" :role 'assistant
                :content
                (list (pichat-transcript-content-create
                       :kind 'prose :index 0 :text "before")
                      tool
                      (pichat-transcript-content-create
                       :kind 'prose :index 2 :text "after"))))
         (transcript (pichat-transcript-create :nodes (list node)))
         (context (pichat-render-default-context))
         (canonical
          (pichat-render-fragment-propertized-string
           (pichat-render-canonical transcript context)))
         (logical (pichat-render-logical-strings transcript context))
         (composed
          (mapconcat (lambda (fragment) (plist-get fragment :text))
                     logical "")))
    (should (equal-including-properties canonical composed))
    (should (equal '("logical-tool")
                   (delq nil (mapcar (lambda (fragment)
                                      (plist-get fragment :tool-id))
                                    logical))))))

(provide 'pichat-test-chat-projection-incremental)
;;; pichat-test-chat-projection-incremental.el ends here
