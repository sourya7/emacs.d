;;; pichat-test-chat-activity.el --- Activity group interaction tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Marker-backed disclosure and live policy behavior for Stage 1 tool groups.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-chat-activity--tool-event (id name args &optional stop-reason)
  "Return an assistant message-end event declaring tool ID NAME ARGS.
STOP-REASON, when non-nil, is attached to the assistant message."
  (list :type "message_end"
        :message (append (list :role "assistant"
                                :content (list (list :type "toolCall" :id id
                                               :name name :arguments args)))
                         (and stop-reason (list :stopReason stop-reason)))))

(defun pichat-test-chat-activity--finish-event (id name output)
  "Return a successful execution-end event for ID NAME with OUTPUT."
  (list :type "tool_execution_end" :toolCallId id :toolName name
        :isError nil
        :result (list :content (list (list :type "text" :text output)))))

(defun pichat-test-chat-activity--thinking-tool-event (id name thinking)
  "Return a tool-use assistant event with THINKING and tool ID NAME."
  (list :type "message_end"
        :message (list :role "assistant"
                       :content (list (list :type "thinking"
                                             :thinking thinking)
                                      (list :type "toolCall" :id id
                                            :name name :arguments nil))
                       :stopReason "toolUse")))

(defun pichat-test-chat-activity--prose-event (text)
  "Return assistant message-end prose event containing TEXT."
  (list :type "message_end"
        :message (list :role "assistant"
                       :content (list (list :type "text" :text text)))))

(defun pichat-test-chat-activity--thinking-event (text &optional stop-reason)
  "Return assistant message-end thinking event containing TEXT.
STOP-REASON, when non-nil, is attached to the assistant message."
  (list :type "message_end"
        :message (append (list :role "assistant"
                               :content (list (list :type "thinking"
                                                    :thinking text)))
                         (and stop-reason (list :stopReason stop-reason)))))

(defun pichat-test-chat-activity--apply (draft &rest events)
  "Apply EVENTS to DRAFT and project its live tail."
  (dolist (event events) (pichat-pi-live-draft-apply draft event))
  (pichat-chat--project-live-tail))

(defun pichat-test-chat-activity--ordered-blocks ()
  "Return current activity blocks ordered by buffer position."
  (let (blocks)
    (maphash (lambda (_key block) (push block blocks))
             pichat-chat--activity-blocks)
    (sort blocks
          (lambda (first second)
            (< (marker-position (plist-get first :start))
               (marker-position (plist-get second :start)))))))

(ert-deftest pichat-chat-activity-tool-use-continuations-share-one-live-group ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-show-thinking t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--thinking-tool-event
                "continuation-1" "read" "inspect one")
               (pichat-test-chat-activity--finish-event
                "continuation-1" "read" "one")
               (pichat-test-chat-activity--thinking-tool-event
                "continuation-2" "edit" "inspect two")
               (pichat-test-chat-activity--finish-event
                "continuation-2" "edit" "two")
               (pichat-test-chat-activity--thinking-tool-event
                "continuation-3" "bash" "inspect three"))
              (let ((blocks (pichat-test-chat-activity--ordered-blocks)))
                (should (= 1 (length blocks)))
                (should (equal '("continuation-1" "continuation-2"
                                 "continuation-3")
                               (plist-get (car blocks) :tool-ids)))
                (should (string-match-p "Thought"
                                        (pichat-test-buffer-text buffer)))
                (should (string-match-p "Read a file"
                                        (pichat-test-buffer-text buffer)))
                (should (string-match-p "edited a file"
                                        (pichat-test-buffer-text buffer)))
                (should (string-match-p "ran a command"
                                        (pichat-test-buffer-text buffer))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-tool-use-group-preserves-child-view-and-starts-new-prose-item ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "view-one" "read" '(:path "one") "toolUse")
               (pichat-test-chat-activity--finish-event
                "view-one" "read" "one")
               (pichat-test-chat-activity--tool-event
                "view-two" "edit" '(:path "two") "toolUse"))
              (let ((tool (gethash "view-one" pichat-chat--tool-blocks)))
                (goto-char (marker-position (plist-get tool :start)))
                (pichat-chat-toggle-tool-at-point))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--finish-event
                "view-two" "edit" "two")
               (pichat-test-chat-activity--prose-event "Final answer."))
              (let ((groups (pichat-test-chat-activity--ordered-blocks))
                    (text (pichat-test-buffer-text buffer)))
                (should (= 1 (length groups)))
                (should (eq 'args
                            (plist-get (gethash "view-one"
                                                pichat-chat--tool-blocks)
                                       :display-state)))
                (should (string-match-p "Final answer" text))
                (should (< (string-match-p "read" text)
                           (string-match-p "Final answer" text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-latest-collapses-when-prose-begins ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'latest)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "latest" "read" '(:path "latest.el"))
               (pichat-test-chat-activity--finish-event
                "latest" "read" "contents"))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (should (eq 'expanded (plist-get group :display-state)))
                (should (gethash "latest" pichat-chat--tool-blocks)))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--prose-event "Answer follows."))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (should (eq 'collapsed (plist-get group :display-state)))
                (should-not (gethash "latest" pichat-chat--tool-blocks))
                (should (string-match-p "Answer follows"
                                        (pichat-test-buffer-text buffer))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-toggle-reprojects-cached-state-and-preserves-tool-view ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'latest)
          (pichat-chat-collapse-tools-by-default t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "choice" "read" '(:path "choice.el"))
               (pichat-test-chat-activity--finish-event
                "choice" "read" "contents"))
              (let ((tool (gethash "choice" pichat-chat--tool-blocks)))
                (should (eq 'summary (plist-get tool :display-state)))
                (goto-char (marker-position (plist-get tool :start)))
                (pichat-chat-toggle-tool-at-point)
                (should (eq 'args
                            (plist-get (gethash "choice"
                                               pichat-chat--tool-blocks)
                                       :display-state))))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (goto-char (marker-position (plist-get group :start)))
                (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                           (lambda (&rest _args)
                             (error "group toggle fetched source"))))
                  (pichat-chat-toggle-activity-at-point)))
              (should-not (gethash "choice" pichat-chat--tool-blocks))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (should (eq 'collapsed (plist-get group :display-state)))
                (goto-char (marker-position (plist-get group :start)))
                (pichat-chat-toggle-activity-at-point))
              (should (eq 'args
                          (plist-get (gethash "choice"
                                             pichat-chat--tool-blocks)
                                     :display-state)))
              (should (= 1 (hash-table-count
                            pichat-chat--activity-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-collapsed-live-choice-survives-tool-growth ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'latest)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "growth-one" "read" '(:path "one.el") "toolUse"))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (goto-char (marker-position (plist-get group :start)))
                (pichat-chat-toggle-activity-at-point))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--finish-event
                "growth-one" "read" "one")
               (pichat-test-chat-activity--tool-event
                "growth-two" "edit" '(:path "two.el") "toolUse"))
              (let* ((group (car (pichat-test-chat-activity--ordered-blocks)))
                     (state (gethash (plist-get group :view-state-key)
                                     pichat-chat--activity-view-states)))
                (should (eq 'collapsed (plist-get group :display-state)))
                (should (equal '("growth-one" "growth-two")
                               (plist-get group :tool-ids)))
                (should (equal (plist-get group :tool-ids)
                               (plist-get state :tool-ids)))
                (should-not (gethash "growth-two" pichat-chat--tool-blocks)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-collapsed-choice-survives-stream-tool-id-refinement ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'latest)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "stream-one" "read" '(:path "one.el") "toolUse"))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (goto-char (marker-position (plist-get group :start)))
                (pichat-chat-toggle-activity-at-point))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               '(:type "message_start"
                 :message (:role "assistant" :content nil))
               '(:type "message_update"
                 :assistantMessageEvent
                 (:type "toolcall_start" :contentIndex 0)))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (should (eq 'collapsed (plist-get group :display-state)))
                (should (string-match-p "-stream-tool-0\\'"
                                        (car (last (plist-get group :tool-ids))))))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :assistantMessageEvent
                 (:type "toolcall_end" :contentIndex 0
                  :toolCall (:type "toolCall" :id "stream-two" :name "edit"
                             :arguments (:path "two.el")))))
              (let* ((group (car (pichat-test-chat-activity--ordered-blocks)))
                     (state (gethash (plist-get group :view-state-key)
                                     pichat-chat--activity-view-states)))
                (should (eq 'collapsed (plist-get group :display-state)))
                (should (equal '("stream-one" "stream-two")
                               (plist-get group :tool-ids)))
                (should (equal (plist-get group :tool-ids)
                               (plist-get state :tool-ids)))
                (should (equal (plist-get group :tool-source-keys)
                               (plist-get state :tool-source-keys))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-collapsed-thinking-choice-survives-first-tool ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-show-thinking t)
          (pichat-chat-activity-group-display 'latest)
          buffer old-state-key)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--thinking-event
                "Planning" "toolUse"))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (goto-char (marker-position (plist-get group :start)))
                (pichat-chat-toggle-activity-at-point)
                (setq group (car (pichat-test-chat-activity--ordered-blocks))
                      old-state-key (plist-get group :view-state-key)))
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "planned-tool" "read" '(:path "planned.el") "toolUse"))
              (let* ((group (car (pichat-test-chat-activity--ordered-blocks)))
                     (state-key (plist-get group :view-state-key))
                     (state (gethash state-key
                                     pichat-chat--activity-view-states)))
                (should (eq 'collapsed (plist-get group :display-state)))
                (should (equal '("planned-tool")
                               (plist-get group :tool-ids)))
                (should-not (equal old-state-key state-key))
                (should-not (gethash old-state-key
                                     pichat-chat--activity-view-states))
                (should (eq 'collapsed (plist-get state :view)))
                (should (equal '("planned-tool")
                               (plist-get state :tool-ids))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-indexing-navigation-and-header-keymap ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "first" "read" '(:path "first.el"))
               (pichat-test-chat-activity--prose-event "Boundary.")
               (pichat-test-chat-activity--tool-event
                "second" "edit" '(:path "second.el")))
              (let* ((blocks (pichat-test-chat-activity--ordered-blocks))
                     (first (car blocks))
                     (second (cadr blocks))
                     (before (buffer-substring (point-min) (point-max))))
                (should (= 2 (length blocks)))
                (should (eq pichat-chat-activity-ui-header-map
                            (get-text-property
                             (marker-position (plist-get first :start))
                             'keymap)))
                (goto-char (marker-position (plist-get first :start)))
                (pichat-chat-next-activity)
                (should (= (point)
                           (marker-position (plist-get second :start))))
                (pichat-chat-previous-activity)
                (should (= (point)
                           (marker-position (plist-get first :start))))
                (pichat-chat--index-activity-groups
                 (marker-position pichat-chat--live-start)
                 (marker-position pichat-chat--live-end) t)
                (should (equal before
                               (buffer-substring (point-min) (point-max)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-source-reset-clears-blocks-and-explicit-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "old" "read" '(:path "old.el")))
              (let ((group (car (pichat-test-chat-activity--ordered-blocks))))
                (pichat-chat-activity-ui-store-view
                 group pichat-chat--activity-view-states 'collapsed))
              (cl-letf (((symbol-function 'pichat-rpc-get-entries) #'ignore))
                (pichat-chat--reset-for-source "new-source" nil))
              (should (= 0 (hash-table-count pichat-chat--activity-blocks)))
              (should (= 0 (hash-table-count
                            pichat-chat--activity-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun pichat-test-chat-activity--block-with-tool (tool-id)
  "Return current activity block whose evidence contains TOOL-ID."
  (let (found)
    (maphash (lambda (_key block)
               (when (member tool-id (plist-get block :tool-ids))
                 (setq found block)))
             pichat-chat--activity-blocks)
    found))

(ert-deftest pichat-chat-activity-live-choice-transfers-to-canonical-settlement ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "tool-1" "read_example" '(:path "safe.txt")))
              (let ((group (pichat-test-chat-activity--block-with-tool "tool-1")))
                (goto-char (marker-position (plist-get group :start)))
                (pichat-chat-toggle-activity-at-point)
                (should (eq 'collapsed
                            (plist-get
                             (pichat-test-chat-activity--block-with-tool "tool-1")
                             :display-state)))))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (with-current-buffer buffer
              (let* ((group (pichat-test-chat-activity--block-with-tool "tool-1"))
                     (state-key (plist-get group :view-state-key))
                     (state (gethash state-key
                                     pichat-chat--activity-view-states)))
                (should group)
                (should (eq 'canonical (car state-key)))
                (should (eq 'collapsed (plist-get state :view)))
                (should-not
                 (gethash
                  (pichat-chat-activity-ui-live-view-key
                   pichat-chat--source-generation "tool-1")
                  pichat-chat--activity-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-manual-repaint-preserves-choice-and-rebuilds-markers ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           buffer old-start before)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer
                (pichat-chat-repaint)
                (let ((group
                       (pichat-test-chat-activity--block-with-tool "tool-1")))
                  (goto-char (marker-position (plist-get group :start)))
                  (pichat-chat-toggle-activity-at-point)
                  (setq group
                        (pichat-test-chat-activity--block-with-tool "tool-1")
                        old-start (plist-get group :start)
                        before (buffer-substring-no-properties
                                pichat-chat--canonical-start
                                pichat-chat--canonical-end))
                  (should (eq 'expanded (plist-get group :display-state))))
                (pichat-chat-repaint)))
            (with-current-buffer buffer
              (let ((group
                     (pichat-test-chat-activity--block-with-tool "tool-1")))
                (should (eq 'expanded (plist-get group :display-state)))
                (should (gethash "tool-1" pichat-chat--tool-blocks))
                (should-not (eq old-start (plist-get group :start)))
                (should-not (marker-position old-start))
                (should (equal before
                               (buffer-substring-no-properties
                                pichat-chat--canonical-start
                                pichat-chat--canonical-end))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-live-update-reuses-unrelated-earlier-group ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "old-group" "read" '(:path "old.el"))
               (pichat-test-chat-activity--finish-event
                "old-group" "read" "old")
               (pichat-test-chat-activity--prose-event "Boundary.")
               (pichat-test-chat-activity--tool-event
                "current-group" "write" '(:path "new.el")))
              (let* ((old (pichat-test-chat-activity--block-with-tool
                           "old-group"))
                     (old-marker (plist-get old :start)))
                (pichat-test-chat-activity--apply
                 pichat-chat--live-draft
                 (pichat-test-chat-activity--finish-event
                  "current-group" "write" "new"))
                (let ((new-old (pichat-test-chat-activity--block-with-tool
                                "old-group")))
                  (should (eq old new-old))
                  (should (eq old-marker (plist-get new-old :start)))
                  (should (string-match-p "Wrote a file"
                                          (pichat-test-buffer-text buffer)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-transfer-rolls-back-with-canonical-projection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-activity--apply
               pichat-chat--live-draft
               (pichat-test-chat-activity--tool-event
                "rollback-group" "read" '(:path "rollback.el")))
              (let* ((live-group
                      (pichat-test-chat-activity--block-with-tool
                       "rollback-group"))
                     (live-key (plist-get live-group :view-state-key))
                     (tool (pichat-transcript-content-create
                            :kind 'tool :index 0
                            :tool-call-id "rollback-group" :name "read"
                            :arguments '(:path "rollback.el")
                            :status 'done :output nil))
                     (transcript
                      (pichat-transcript-create
                       :nodes
                       (list (pichat-transcript-node-create
                              :kind 'message :key "canonical-rollback"
                              :role 'assistant :content (list tool)))
                       :diagnostics nil :metadata nil))
                     context fragment)
                (pichat-chat-activity-ui-store-view
                 live-group pichat-chat--activity-view-states 'collapsed)
                (setq context (pichat-chat--canonical-render-context transcript)
                      fragment (pichat-render-canonical transcript context))
                (cl-letf (((symbol-function
                            'pichat-chat--commit-live-activity-view-transfers)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--commit-live-activity-view-transfers)))
                             (lambda ()
                               (funcall original)
                               (error "forced activity transfer rollback")))))
                  (should-error
                   (pichat-chat--project-canonical
                    nil transcript fragment context t)))
                (should (eq 'collapsed
                            (plist-get
                             (gethash live-key
                                      pichat-chat--activity-view-states)
                             :view)))
                (should-not
                 (cl-loop for key being the hash-keys
                          of pichat-chat--activity-view-states
                          thereis (eq (car-safe key) 'canonical))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-activity-legacy-session-load-and-repaint-need-no-migration ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture
                     "canonical-session-legacy.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           (fixture-file
            (expand-file-name "canonical-session-legacy.json"
                              pichat-test-fixture-directory))
           (fixture-before
            (with-temp-buffer
              (insert-file-contents-literally fixture-file)
              (buffer-string)))
           buffer first)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer
                (pichat-chat-repaint)
                (setq first
                      (buffer-substring-no-properties
                       pichat-chat--canonical-start pichat-chat--canonical-end))
                (should (string-match-p "Read a file" first))
                (should (string-match-p "Legacy context" first))
                (should (pichat-test-chat-activity--block-with-tool
                         "legacy-tool"))
                (pichat-chat-repaint)))
            (with-current-buffer buffer
              (should (equal first
                             (buffer-substring-no-properties
                              pichat-chat--canonical-start
                              pichat-chat--canonical-end))))
            (should
             (equal fixture-before
                    (with-temp-buffer
                      (insert-file-contents-literally fixture-file)
                      (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-activity)
;;; pichat-test-chat-activity.el ends here
