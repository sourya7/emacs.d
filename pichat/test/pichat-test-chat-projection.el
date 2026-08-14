;;; pichat-test-chat-projection.el --- Pichat Test Chat Projection -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-canonical-projection-preserves-stable-shell-and-prompt-undo ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer stable-markers)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (puthash "phase-2" "persistent extension status"
                       pichat-chat--extension-statuses)
              (pichat-chat--project-extension-statuses)
              (pichat-chat--set-status 'phase-2 "[stable transient status]")
              (puthash "phase-2"
                       '(:lines ["stable widget text"]
                         :placement "aboveEditor")
                       pichat-chat--extension-widgets)
              (pichat-chat--render-extension-widgets)
              (buffer-enable-undo)
              (setq buffer-undo-list nil)
              (goto-char (point-max))
              (insert "draft survives canonical sync")
              (undo-boundary)
              (dolist (text '("persistent extension status"
                              "stable transient status"
                              "stable widget text"
                              "draft survives canonical sync"))
                (goto-char (point-min))
                (search-forward text)
                (push (cons text (copy-marker (match-beginning 0)))
                      stable-markers))
              (set-buffer-modified-p t)
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-transcript-node-create
                         :kind 'message :key "phase-2-entry" :role 'assistant
                         :content
                         (list
                          (pichat-transcript-content-create
                           :kind 'prose :index 0
                           :text "A canonical response with changed length."))))
                       :diagnostics nil :metadata nil))
                     (context
                      (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (dolist (entry stable-markers)
                (let ((text (car entry))
                      (position (marker-position (cdr entry))))
                  (should position)
                  (should (equal text
                                 (buffer-substring-no-properties
                                  position (+ position (length text)))))))
              (should (equal "draft survives canonical sync"
                             (pichat-chat--input-text)))
              (should (buffer-modified-p))
              (let ((inhibit-message t))
                (undo 1))
              (should (string-empty-p (pichat-chat--input-text))))
        (dolist (entry stable-markers)
          (set-marker (cdr entry) nil))
        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-state-change-refreshes-only-header-title ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer before-rest)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-status 'phase-2 "[stable status]")
              (buffer-enable-undo)
              (setq buffer-undo-list nil)
              (goto-char (point-max))
              (insert "stable draft")
              (undo-boundary)
              (goto-char (point-min))
              (forward-line 1)
              (setq before-rest
                    (buffer-substring (point) (point-max)))
              (set-buffer-modified-p t))
            (setf (pichat-session-cwd session) "/changed/project")
            (cl-letf (((symbol-function 'pichat-chat--refresh-stats)
                       #'ignore))
              (with-current-buffer buffer
                (pichat-chat--on-state-changed session nil nil)))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should (equal "PiChat — /changed/project"
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))
              (should (get-text-property (point-min) 'read-only))
              (forward-line 1)
              (should (equal before-rest
                             (buffer-substring (point) (point-max))))
              (should (buffer-modified-p))
              (let ((inhibit-message t))
                (undo 1))
              (should (string-empty-p (pichat-chat--input-text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-repaint-preserves-current-draft-input ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer expected-offset)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "unsent draft")
              (backward-char 5)
              (setq expected-offset
                    (- (point)
                       (marker-position pichat-chat--input-start))))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  '(:data (:entries nil)) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (with-current-buffer buffer
              (should (equal "unsent draft" (pichat-chat--input-text)))
              (should (= expected-offset
                         (- (point)
                            (marker-position pichat-chat--input-start))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-identity-change-resets-cache-and-full-syncs ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (old-data (list :entries (plist-get fixture :entries)
                           :leafId (plist-get fixture :leafId)))
           (new-data
            '(:entries
              ((:type "message" :id "new-entry" :parentId nil
                :message (:role "user" :content "New session content.")))
              :leafId "new-entry"))
           calls buffer)
      (setf (pichat-session-id session) "old-session"
            (pichat-session-session-file session) "/sanitized/old.jsonl"
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data old-data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (setf (pichat-session-id session) "new-session"
                  (pichat-session-session-file session)
                  "/sanitized/new.jsonl")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (push (and (not (functionp since)) since) calls)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data new-data) session))))
              (with-current-buffer buffer
                (pichat-chat--on-state-changed session nil nil)))
            (with-current-buffer buffer
              (should (= 1 pichat-chat--source-generation))
              (should (equal "new-session" pichat-chat--source-session-id))
              (should (equal '(nil) calls))
              (should (equal "new-session"
                             (pichat-entry-cache-session-id
                              pichat-chat--entry-cache)))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "New session content" text))
                (should-not (string-match-p "Final persisted answer" text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-rebind-invalidates-source-before-get-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-id session) "old-session"
            (pichat-session-session-file session) "/sanitized/old.jsonl"
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setq pichat-chat--entry-cache 'old-cache))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf calls))))
              (pichat-emit session 'session-rebinding
                           :command "switch_session")
              (with-current-buffer buffer
                (should pichat-chat--source-rebinding-p)
                (should (= 1 pichat-chat--source-generation))
                (should-not pichat-chat--source-bound-p)
                (should-not pichat-chat--entry-cache)
                (should-not calls))
              (pichat-emit
               session 'rpc-event
               :raw '(:type "message_start"
                      :message (:role "assistant" :content nil)))
              (with-current-buffer buffer
                (should-not (pichat-live-draft-nodes
                             pichat-chat--live-draft))))
            (setf (pichat-session-id session) "new-session"
                  (pichat-session-session-file session)
                  "/sanitized/new.jsonl")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (setq calls (1+ (or calls 0)))
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  '(:data
                                    (:entries
                                     ((:type "message" :id "new-root"
                                       :parentId nil
                                       :message (:role "user"
                                                 :content "New source.")))
                                     :leafId "new-root"))
                                  session))))
              (with-current-buffer buffer
                (pichat-chat--on-state-changed session nil nil)))
            (with-current-buffer buffer
              (should-not pichat-chat--source-rebinding-p)
              (should pichat-chat--source-bound-p)
              (should (equal "new-session" pichat-chat--source-session-id))
              (should (= 1 calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-change-ignores-stale-sync-callback ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (old-data (list :entries (plist-get fixture :entries)
                           :leafId (plist-get fixture :leafId)))
           (new-data
            '(:entries
              ((:type "message" :id "new-root" :parentId nil
                :message (:role "user" :content "Authoritative new source.")))
              :leafId "new-root"))
           stale-success buffer)
      (setf (pichat-session-id session) "old-session"
            (pichat-session-session-file session) "/sanitized/old.jsonl"
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data old-data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session _since callback &optional _error)
                         (setq stale-success callback))))
              (with-current-buffer buffer
                (pichat-chat--request-sync nil)))
            (should stale-success)
            (setf (pichat-session-id session) "new-session"
                  (pichat-session-session-file session)
                  "/sanitized/new.jsonl")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data new-data) session))))
              (with-current-buffer buffer
                (pichat-chat--on-state-changed session nil nil)))
            (funcall stale-success
                     '(:data
                       (:entries
                        ((:type "message" :id "stale-entry"
                          :parentId "entry-final"
                          :message (:role "assistant"
                                    :content "Stale callback content.")))
                        :leafId "stale-entry"))
                     session)
            (with-current-buffer buffer
              (should (equal "new-session"
                             (pichat-entry-cache-session-id
                              pichat-chat--entry-cache)))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "Authoritative new source" text))
                (should-not (string-match-p "Stale callback content" text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-file-materialization-keeps-same-session-generation ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-id session) "same-session"
            (pichat-session-session-file session) nil
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (setf (pichat-session-session-file session)
                  "/sanitized/materialized.jsonl")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf calls))))
              (with-current-buffer buffer
                (pichat-chat--on-state-changed session nil nil)))
            (with-current-buffer buffer
              (should (= 0 pichat-chat--source-generation))
              (should (equal "/sanitized/materialized.jsonl"
                             pichat-chat--source-session-file))
              (should-not calls)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-settlement-sync-clears-recovered-parse-notice ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (setf (pichat-session-state session) 'running)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc "{\"type\":\"message_update\",\"assistantMessag\n")
            (with-current-buffer buffer
              (should (assq 'rpc-parse pichat-chat--status-lines))
              (should (string-match-p
                       "malformed RPC output"
                       (pichat-test-buffer-text buffer))))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional _since callback _error)
                         (funcall callback
                                  '(:data (:entries nil :leafId nil))
                                  session))))
              (pichat-rpc--process-filter
               proc "{\"type\":\"agent_settled\"}\n"))
            (with-current-buffer buffer
              (should-not (assq 'rpc-parse pichat-chat--status-lines))
              (should-not (string-match-p
                           "malformed RPC output"
                           (pichat-test-buffer-text buffer)))
              (should-not pichat-chat--sync-in-flight))
            (should (eq 'rpc-parse
                        (plist-get
                         (pichat-chat-diagnostics-latest session) :origin))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-settlement-sync-failure-preserves-final-live-tail ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (setf (pichat-session-state session) 'running)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"final live answer\"}]}}\n")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session _since _success error)
                         (funcall error
                                  '(:success nil
                                    :pichat-failure-kind timeout
                                    :error "timed out")
                                  session))))
              (pichat-rpc--process-filter
               proc "{\"type\":\"agent_settled\"}\n"))
            (with-current-buffer buffer
              (should (string-match-p "final live answer"
                                      (buffer-substring-no-properties
                                       pichat-chat--live-start
                                       pichat-chat--live-end)))
              (should (pichat-live-draft-nodes pichat-chat--live-draft))
              (should (string-match-p
                       "not synchronized with Pi session"
                       (buffer-substring-no-properties
                        pichat-chat--status-start pichat-chat--status-end)))
              (should-not pichat-chat--sync-in-flight)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-settlement-full-sync-replaces-transient-live-output ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           calls buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"temporary live output\"}]}}\n")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (push (and (not (functionp since)) since) calls)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer
                (pichat-chat--on-agent-settled
                 session 'agent-settled '(:raw (:type "agent_settled")))))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should-not (string-match-p "temporary live output" text))
                (should (string-match-p "Final persisted answer" text)))
              (should (equal '(nil) calls))
              (should (pichat-entry-cache-p pichat-chat--entry-cache))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-coalesces-identical-full-sync-while-one-is-in-flight ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           callback
           (calls 0)
           buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session _since success &optional _error)
                         (cl-incf calls)
                         (setq callback success))))
              (with-current-buffer buffer
                (pichat-chat-repaint)
                (pichat-chat-repaint))
              (should (= 1 calls))
              (funcall callback (list :data data) session)
              (should (= 1 calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-full-repaint-defers-during-run-and-dominates-settlement-sync ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           calls buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'running)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (push (and (not (functionp since)) since) calls)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer
                (pichat-chat-repaint)
                (should-not calls)
                (setf (pichat-session-state session) 'idle)
                (pichat-chat--on-agent-settled
                 session 'agent-settled '(:raw (:type "agent_settled")))))
            (should (equal '(nil) calls)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-settlement-incrementally-syncs-from-last-append-id ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (full-data (list :entries (plist-get fixture :entries)
                            :leafId (plist-get fixture :leafId)))
           (incremental-data
            '(:entries
              ((:type "message" :id "entry-after-settlement"
                :parentId "entry-final"
                :message (:role "assistant"
                          :content ((:type "text"
                                     :text "Settled incremental answer."))
                          :stopReason "stop")))
              :leafId "entry-after-settlement"))
           captured-since buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data full-data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"stale live preview\"}]}}\n")
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session since callback &optional _error)
                         (setq captured-since since)
                         (funcall callback (list :data incremental-data) session))))
              (with-current-buffer buffer
                (pichat-chat--on-agent-settled
                 session 'agent-settled '(:raw (:type "agent_settled")))))
            (with-current-buffer buffer
              (should (equal "entry-final" captured-since))
              (should (equal "entry-after-settlement"
                             (pichat-entry-cache-last-seen-id
                              pichat-chat--entry-cache)))
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "Settled incremental answer" text))
                (should-not (string-match-p "stale live preview" text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-settlement-invalid-cursor-retries-one-full-sync ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (full-data (list :entries (plist-get fixture :entries)
                            :leafId (plist-get fixture :leafId)))
           calls buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data full-data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback error)
                         (push (and (not (functionp since)) since) calls)
                         (if (and since (not (functionp since)))
                             (funcall error
                                      '(:success nil :error "Entry not found")
                                      session)
                           (funcall (pichat-test--rpc-get-entries-callback
                                     since callback)
                                    (list :data full-data) session)))))
              (with-current-buffer buffer
                (pichat-chat--on-agent-settled
                 session 'agent-settled '(:raw (:type "agent_settled")))))
            (should (equal '("entry-final" nil) (nreverse calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-manual-repaint-uses-canonical-active-branch-pipeline ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (pichat-chat-show-thinking nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "unsent draft")
              (set-buffer-modified-p nil))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "Check the example" text))
                (should (string-match-p "Final persisted answer" text))
                (should-not (string-match-p "Abandoned response" text))
                (should-not (string-match-p "must-not-render" text))
                (should (string-match-p "Pi compatibility" text)))
              (should (pichat-entry-cache-p pichat-chat--entry-cache))
              (should (pichat-transcript-p pichat-chat--canonical-transcript))
              (should (equal "unsent draft" (pichat-chat--input-text)))
              (should-not (buffer-modified-p))
              (goto-char (point-min))
              (search-forward "Check the example")
              (should (equal "entry-user"
                             (get-text-property (match-beginning 0)
                                                'pichat-node-key)))
              (search-forward "tool:read_example")
              (should (pichat-chat--tool-at-point))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-unchanged-status-does-not-reproject ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer (projections 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-status 'test "same")
              (cl-letf (((symbol-function 'pichat-chat--render-status-region)
                         (lambda () (cl-incf projections))))
                (pichat-chat--set-status 'test "same")
                (should (= 0 projections)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-projection-preserves-canonical-tool-index ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer canonical-id canonical-block)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((transcript (pichat-test--canonical-fixture-transcript))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (maphash (lambda (id block)
                         (unless canonical-id
                           (setq canonical-id id canonical-block block)))
                       pichat-chat--tool-blocks)
              (should canonical-id)
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :message (:role "assistant"
                           :content ((:type "text" :text "live")))))
              (pichat-chat--project-live-tail)
              (should (eq canonical-block
                          (gethash canonical-id pichat-chat--tool-blocks)))
              (should (marker-position (plist-get canonical-block :start)))
              (should (marker-position (plist-get canonical-block :end)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-projection-errors-roll-back-complete-buffer-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer before)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-status 'test "[existing status]")
              (setq before (buffer-substring (point-min) (point-max)))
              (let* ((pichat-chat-markdown-mode t)
                     (transcript (pichat-transcript-create
                                  :nodes nil :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context))
                     (fragment (pichat-render-canonical transcript context)))
                (cl-letf (((symbol-function
                            'pichat-chat--markdown-fontify-region)
                           (lambda (&rest _args) (error "fontify failed"))))
                  (should-error
                   (pichat-chat--project-canonical
                    nil transcript fragment context))))
              (should (equal before
                             (buffer-substring (point-min) (point-max))))
              (should (equal '((test . "[existing status]"))
                             pichat-chat--status-lines))
              (cl-letf (((symbol-function 'pichat-chat--protect-region)
                         (lambda (&rest _args) (error "status failed"))))
                (should-error (pichat-chat--set-status 'new "new")))
              (should (equal before
                             (buffer-substring (point-min) (point-max))))
              (should (equal '((test . "[existing status]"))
                             pichat-chat--status-lines))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_end"
                 :message (:role "assistant"
                           :content ((:type "text" :text "final")))))
              (let ((pichat-chat-markdown-mode t))
                (cl-letf (((symbol-function
                            'pichat-chat--markdown-fontify-region)
                           (lambda (&rest _args) (error "live failed"))))
                  (should-error (pichat-chat--project-live-tail))))
              (should (equal before
                             (buffer-substring (point-min) (point-max))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-manual-repaint-preserves-display-on-invalid-candidate ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer before old-input-offset old-draft old-status)
      (setf (pichat-session-id session) "session-1")
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_end"
                 :message (:role "assistant"
                           :content ((:type "text"
                                      :text "live before invalid")))))
              (pichat-chat--project-live-tail)
              (pichat-chat--set-status 'test "[status before invalid]")
              (puthash "fold-before-invalid" 'summary
                       pichat-chat--tool-view-states)
              (goto-char (point-max))
              (insert "draft before invalid repaint")
              (backward-char 5)
              (set-buffer-modified-p t)
              (setq pichat-chat--entry-cache 'existing-cache
                    pichat-chat--canonical-transcript 'existing-transcript
                    old-input-offset
                    (- (point) (marker-position pichat-chat--input-start))
                    old-draft pichat-chat--live-draft
                    old-status (copy-tree pichat-chat--status-lines)
                    before (buffer-substring (point-min) (point-max))))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall
                          (pichat-test--rpc-get-entries-callback since callback)
                          '(:data (:entries
                                   ((:type "message" :id "entry-1"
                                     :parentId nil
                                     :message (:role "user"
                                               :content "visible")))
                                   :leafId "missing"))
                          session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (with-current-buffer buffer
              (let ((text (buffer-substring-no-properties
                           (point-min) (point-max))))
                (should (string-match-p "live before invalid" text))
                (should (string-match-p "status before invalid" text))
                (should (string-match-p "not synchronized with Pi session"
                                        text))
                (should (string-match-p "draft before invalid repaint" text)))
              (should (eq 'existing-cache pichat-chat--entry-cache))
              (should (eq 'existing-transcript
                          pichat-chat--canonical-transcript))
              (should (eq old-draft pichat-chat--live-draft))
              (should (equal old-status
                             (cl-remove 'synchronization
                                        pichat-chat--status-lines
                                        :key #'car)))
              (should (eq 'summary
                          (gethash "fold-before-invalid"
                                   pichat-chat--tool-view-states)))
              (should (= old-input-offset
                         (- (point)
                            (marker-position pichat-chat--input-start))))
              (should (buffer-modified-p))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-projection)
;;; pichat-test-chat-projection.el ends here
