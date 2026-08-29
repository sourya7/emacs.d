;;; pichat-test-chat-tools.el --- Pichat Test Chat Tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-live-markdown-finalizes-only-after-message-end ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer fontified)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-chat--markdown-fontify-region)
                       (lambda (beg end) (push (cons beg end) fontified))))
              (with-current-buffer buffer
                (setq pichat-chat-markdown-mode t))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"**partial**\"}]}}\n")
              (with-current-buffer buffer
                (pichat-chat--flush-live-projection))
              (should-not fontified)
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"**final**\"}]}}\n")
              (should (= 1 (length fontified)))
              (with-current-buffer buffer
                (let ((range (car fontified)))
                  (should (= (marker-position pichat-chat--live-start)
                             (car range)))
                  (should (= (marker-position pichat-chat--live-end)
                             (cdr range)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-completed-tool-folds-at-configured-default ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"default-fold\",\"name\":\"read_example\",\"arguments\":{\"path\":\"visible-while-running.txt\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"default-fold\",\"toolName\":\"read_example\",\"args\":{\"path\":\"visible-while-running.txt\"}}\n")
            (with-current-buffer buffer
              (should (string-match-p "visible-while-running.txt"
                                      (pichat-test-buffer-text buffer))))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"default-fold\",\"toolName\":\"read_example\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"completed output\"}]},\"isError\":false}\n")
            (with-current-buffer buffer
              (let ((block (gethash "default-fold" pichat-chat--tool-blocks)))
                (should (eq 'summary (plist-get block :display-state))))
              (should-not (string-match-p "completed output"
                                          (pichat-test-buffer-text buffer)))
              (should-not (gethash "default-fold"
                                   pichat-chat--tool-view-states))
              (should (= 0 (hash-table-count
                            pichat-chat--tool-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-fallback-tool-statuses-fold-by-default ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-collapse-tools-by-default t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"orphan-fold\",\"toolName\":\"orphan\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"orphan output\"}]},\"isError\":true}\n")
            (with-current-buffer buffer
              (should (eq 'summary
                          (plist-get (gethash "orphan-fold"
                                             pichat-chat--tool-blocks)
                                     :display-state))))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"error-fold\",\"name\":\"failing\",\"arguments\":{\"value\":\"error arg\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"error-fold\",\"toolName\":\"failing\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"error output\"}]},\"isError\":true}\n")
            (with-current-buffer buffer
              (should (eq 'summary
                          (plist-get (gethash "error-fold"
                                             pichat-chat--tool-blocks)
                                     :display-state))))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"incomplete-fold\",\"name\":\"pending\",\"arguments\":{\"value\":\"pending arg\"}}]}}\n")
            (with-current-buffer buffer
              (should (eq 'output
                          (plist-get (gethash "incomplete-fold"
                                             pichat-chat--tool-blocks)
                                     :display-state))))
            (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
            (with-current-buffer buffer
              (should (eq 'summary
                          (plist-get (gethash "incomplete-fold"
                                             pichat-chat--tool-blocks)
                                     :display-state)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-details-use-source-buffer-auxiliary-data ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (details-buffer-name "*PiChat Tool Details*")
          buffer)
      (unwind-protect
          (progn
            (when-let ((details-buffer (get-buffer details-buffer-name)))
              (kill-buffer details-buffer))
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"details-tool\",\"name\":\"read_example\",\"arguments\":{\"path\":\"safe.txt\"}}]}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"details-tool\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\",\"line\":7}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"details-tool\",\"toolName\":\"read_example\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"tool output\"}],\"details\":{\"kind\":\"live-only\"},\"fullOutputPath\":\"/sanitized/output.txt\"},\"isError\":false}\n")
            (with-current-buffer buffer
              (let ((block (gethash "details-tool" pichat-chat--tool-blocks)))
                (should block)
                (goto-char (marker-position (plist-get block :start)))
                (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                  (pichat-chat-show-tool-details))))
            (with-current-buffer details-buffer-name
              (should (derived-mode-p 'pichat-view-mode))
              (let ((text (buffer-string)))
                (should (string-match-p "Kind: read" text))
                (should (string-match-p "Title: safe.txt:7" text))
                (should (string-match-p "Location: safe.txt:7" text))
                (should (string-match-p "live-only" text))
                (should (string-match-p
                         (regexp-quote "/sanitized/output.txt") text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when-let ((details-buffer (get-buffer details-buffer-name)))
          (kill-buffer details-buffer))))))

(ert-deftest pichat-chat-tool-location-overlay-preserves-source-and-fold-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"located\",\"name\":\"read\",\"arguments\":{\"path\":\"src/a.el\",\"line\":9}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"located\",\"toolName\":\"read\",\"args\":{\"path\":\"src/a.el\",\"line\":9}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"located\",\"toolName\":\"read\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]},\"isError\":false}\n")
            (with-current-buffer buffer
              (let* ((block (gethash "located" pichat-chat--tool-blocks))
                     (overlay (plist-get block :overlay))
                     (source (buffer-substring-no-properties
                              (plist-get block :start) (plist-get block :end))))
                (should (eq 'summary (plist-get block :display-state)))
                (should (overlayp overlay))
                (should-not (overlay-get overlay 'after-string))
                (should (equal "src/a.el:9"
                               (buffer-substring-no-properties
                                (overlay-start overlay) (overlay-end overlay))))
                (should (string-match-p (regexp-quote "src/a.el:9") source))
                (goto-char (marker-position (plist-get block :start)))
                (pichat-chat-toggle-tool-at-point)
                (setq block (gethash "located" pichat-chat--tool-blocks)
                      overlay (plist-get block :overlay))
                (should (eq 'args (plist-get block :display-state)))
                (should (overlayp overlay))
                (should (string-match-p
                         (regexp-quote "src/a.el")
                         (buffer-substring-no-properties
                          (plist-get block :start) (plist-get block :end)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-location-decoration-survives-projection-rollback ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"rollback-location\",\"name\":\"read\",\"arguments\":{\"path\":\"rollback.el\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"rollback-location\",\"toolName\":\"read\",\"args\":{\"path\":\"rollback.el\"}}\n")
            (with-current-buffer buffer
              (let ((before (buffer-substring (point-min) (point-max))))
                (should-error
                 (pichat-chat--with-projection-rollback
                   (pichat-chat--release-tool-blocks)
                   (error "forced rollback")))
                (should (equal before
                               (buffer-substring (point-min) (point-max))))
                (let* ((block (gethash "rollback-location"
                                       pichat-chat--tool-blocks))
                       (overlay (plist-get block :overlay)))
                  (should (overlayp overlay))
                  (should-not (overlay-get overlay 'after-string))
                  (should (equal "rollback.el"
                                 (buffer-substring-no-properties
                                  (overlay-start overlay)
                                  (overlay-end overlay))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-location-actions-visit-copy-path-and-location ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (target (generate-new-buffer " *pichat-location-target*"))
          copied visited buffer)
      (unwind-protect
          (progn
            (with-current-buffer target (insert "one\nabcdef\nthree\n"))
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"actions\",\"name\":\"read\",\"arguments\":{\"path\":\"safe.txt\",\"line\":2,\"column\":3}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"actions\",\"toolName\":\"read\",\"args\":{\"path\":\"safe.txt\",\"line\":2,\"column\":3}}\n")
            (with-current-buffer buffer
              (goto-char (marker-position
                          (plist-get (gethash "actions" pichat-chat--tool-blocks)
                                     :start)))
              (cl-letf (((symbol-function 'kill-new)
                         (lambda (text &optional _) (setq copied text))))
                (pichat-chat-copy-tool-location)
                (should (equal "safe.txt:2:3" copied))
                (pichat-chat-copy-tool-path)
                (should (equal "safe.txt" copied)))
              (cl-letf (((symbol-function 'find-file)
                         (lambda (path)
                           (setq visited path)
                           (set-buffer target))))
                (pichat-chat-visit-tool-location)))
            (should (equal "safe.txt" visited))
            (with-current-buffer target
              (should (= 2 (line-number-at-pos)))
              (should (= 2 (current-column)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p target) (kill-buffer target))))))

(ert-deftest pichat-chat-live-tool-fold-survives-whole-tail-reprojection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"fold-tool\",\"name\":\"read_example\",\"arguments\":{\"path\":\"safe.txt\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"fold-tool\",\"toolName\":\"read_example\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"safe output\"}]},\"isError\":false}\n")
            (with-current-buffer buffer
              (let ((block (gethash "fold-tool" pichat-chat--tool-blocks)))
                (should (eq 'output (plist-get block :display-state)))
                (goto-char (marker-position (plist-get block :start)))
                (pichat-chat-toggle-tool-at-point)
                (should (eq 'summary (plist-get block :display-state))))
              (pichat-chat--project-live-tail)
              (let ((block (gethash "fold-tool" pichat-chat--tool-blocks)))
                (should (eq 'summary (plist-get block :display-state)))
                (should (< (marker-position pichat-chat--live-start)
                           (marker-position pichat-chat--live-end)))
                (should (<= (marker-position pichat-chat--live-end)
                            (marker-position pichat-chat--status-start)))
                (should (<= (marker-position pichat-chat--status-end)
                            (marker-position pichat-chat--prompt-start))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-tool-fold-transfers-to-canonical-settlement ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (pichat-chat-collapse-tools-by-default nil)
           (pichat-chat-tool-default-display 'output)
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
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"tool-1\",\"name\":\"read_example\",\"arguments\":{\"path\":\"safe.txt\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"tool-1\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\",\"line\":5}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"tool-1\",\"toolName\":\"read_example\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"temporary output\"}],\"details\":{\"kind\":\"live-only\"},\"fullOutputPath\":\"/sanitized/output.txt\"},\"isError\":false}\n")
            (with-current-buffer buffer
              (should (gethash "tool-1"
                               pichat-chat--tool-auxiliary-details))
              (let ((block (gethash "tool-1" pichat-chat--tool-blocks)))
                (goto-char (marker-position (plist-get block :start)))
                (pichat-chat-toggle-tool-at-point)))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since callback _error)
                         (funcall (pichat-test--rpc-get-entries-callback
                                   since callback)
                                  (list :data data) session))))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (with-current-buffer buffer
              (let* ((node
                      (cl-find-if
                       (lambda (candidate)
                         (cl-find "tool-1"
                                  (pichat-transcript-node-content candidate)
                                  :key #'pichat-transcript-content-tool-call-id
                                  :test #'equal))
                       (pichat-transcript-nodes
                        pichat-chat--canonical-transcript)))
                     (canonical-view-key
                      (pichat-chat--canonical-tool-view-key
                       (pichat-transcript-node-key node) "tool-1"))
                     (activity
                      (cl-find-if
                       (lambda (key)
                         (member "tool-1"
                                 (plist-get
                                  (gethash key pichat-chat--activity-blocks)
                                  :tool-ids)))
                       (pichat-test--hash-table-keys
                        pichat-chat--activity-blocks))))
                (should-not (gethash "tool-1" pichat-chat--tool-blocks))
                (should (eq 'summary
                            (gethash canonical-view-key
                                     pichat-chat--tool-view-states)))
                (should-not
                 (gethash (pichat-chat--live-tool-view-key "tool-1")
                          pichat-chat--tool-view-states))
                (should (eq 'collapsed
                            (plist-get (gethash activity
                                               pichat-chat--activity-blocks)
                                       :display-state)))
                (goto-char
                 (marker-position
                  (plist-get (gethash activity pichat-chat--activity-blocks)
                             :start)))
                (pichat-chat-toggle-activity-at-point)
                (let ((block (gethash "tool-1" pichat-chat--tool-blocks)))
                  (should block)
                  (should (eq 'summary (plist-get block :display-state)))
                  (should (equal "safe.txt:5"
                                 (pichat-chat-tool-ui-location-string
                                  (gethash "tool-1"
                                           pichat-chat--tool-enrichments))))
                  (should (overlayp (plist-get block :overlay)))
                  (should-not
                   (overlay-get (plist-get block :overlay) 'after-string))
                  (goto-char (marker-position (plist-get block :start)))
                  (let (copied)
                    (cl-letf (((symbol-function 'kill-new)
                               (lambda (text &optional _) (setq copied text))))
                      (pichat-chat-copy-tool-location))
                    (should (equal "safe.txt:5" copied)))))
              (should-not (gethash "tool-1"
                                   pichat-chat--tool-auxiliary-details))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-tool-view-transfer-rolls-back-with-projection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((node-key "rollback-entry")
                     (tool-id "rollback-tool")
                     (tool (pichat-transcript-content-create
                            :kind 'tool :index 0 :tool-call-id tool-id
                            :name "rollback" :arguments nil :status 'done
                            :output nil))
                     (transcript
                      (pichat-transcript-create
                       :nodes (list (pichat-transcript-node-create
                                     :kind 'message :key node-key
                                     :role 'assistant :content (list tool)))
                       :diagnostics nil :metadata nil))
                     (live-key (pichat-chat--live-tool-view-key tool-id))
                     (canonical-key
                      (pichat-chat--canonical-tool-view-key node-key tool-id))
                     context fragment)
                (puthash live-key 'args pichat-chat--tool-view-states)
                (setq context (pichat-chat--canonical-render-context transcript)
                      fragment (pichat-render-canonical transcript context))
                (cl-letf (((symbol-function
                            'pichat-chat--commit-live-tool-view-transfers)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--commit-live-tool-view-transfers)))
                             (lambda ()
                               (funcall original)
                               (error "forced transfer rollback")))))
                  (should-error
                   (pichat-chat--project-canonical
                    nil transcript fragment context t)))
                (should (eq 'args
                            (gethash live-key
                                     pichat-chat--tool-view-states)))
                (should-not (gethash canonical-key
                                     pichat-chat--tool-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-adjacent-live-tools-keep-independent-fold-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"adjacent-1\",\"name\":\"one\",\"arguments\":{}},{\"type\":\"toolCall\",\"id\":\"adjacent-2\",\"name\":\"two\",\"arguments\":{}}]}}\n")
            (dolist (id '("adjacent-1" "adjacent-2"))
              (pichat-rpc--process-filter
               proc
               (format "{\"type\":\"tool_execution_end\",\"toolCallId\":%S,\"toolName\":\"tool\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"output\"}]},\"isError\":false}\n"
                       id)))
            (with-current-buffer buffer
              (let ((first (gethash "adjacent-1" pichat-chat--tool-blocks))
                    edited)
                (goto-char (marker-position (plist-get first :start)))
                (cl-letf (((symbol-function
                            'pichat-chat-tool-ui-replace-region)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat-tool-ui-replace-region)))
                             (lambda (block text tracked-markers edit-function)
                               (push (plist-get (plist-get block :raw)
                                                :toolCallId)
                                     edited)
                               (funcall original block text tracked-markers
                                        edit-function)))))
                  (pichat-chat-toggle-tool-at-point))
                (should (equal '("adjacent-1") edited)))
              (pichat-chat--project-live-tail)
              (should (eq 'summary
                          (plist-get (gethash "adjacent-1"
                                              pichat-chat--tool-blocks)
                                     :display-state)))
              (should (eq 'output
                          (plist-get (gethash "adjacent-2"
                                              pichat-chat--tool-blocks)
                                     :display-state)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-transition-clears-tool-view-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (puthash "old-tool" 'summary pichat-chat--tool-view-states)
              (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                         (lambda (&rest _args) nil)))
                (pichat-chat--reset-for-source "new-source" nil))
              (should (= 0 (hash-table-count
                            pichat-chat--tool-view-states)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-ui-concise-headers-cover-enriched-kinds-and-fallback ()
  (dolist (case '(("bash" (:command "printf hello") "✓ run    printf hello")
                  ("read" (:path "src/read.el" :line 8)
                   "✓ read   src/read.el:8")
                  ("write" (:path "src/new.el") "✓ write  src/new.el:1")
                  ("edit" (:path "src/edit.el") "✓ edit   src/edit.el")
                  ("grep" (:pattern "needle" :path "pichat/")
                   "✓ search needle in pichat/")
                  ("fetch" (:url "https://example.test/data")
                   "✓ fetch  https://example.test/data")
                  ("extension_tool" (:value "opaque")
                   "✓ tool   extension_tool")))
    (pcase-let ((`(,name ,args ,expected) case))
      (let* ((raw (list :toolCallId (concat "id-" name)
                        :toolName name :args args))
             (text (pichat-chat-tool-ui-text
                    raw "done" "output" 'summary 300 4000
                    pichat-chat-tool-truncation-notice-format)))
        (should (string-match-p (regexp-quote expected) text))
        (should-not (string-match-p "opaque" text)))))
  (let* ((raw '(:toolCallId "bad" :toolName "bash"
                :args (:command "make test")))
         (enrichment (pichat-tool-enrichment-build
                      "bad" "bash" '(:command "make test")))
         (enrichment
          (plist-put enrichment :shell-outcome '(:kind exit :exit-code 2)))
         (text (pichat-chat-tool-ui-text
                raw "error" "failed" 'summary 300 4000
                pichat-chat-tool-truncation-notice-format enrichment)))
    (should (string-match-p
             (regexp-quote "✗ run    make test · exit 2") text))))

(provide 'pichat-test-chat-tools)
;;; pichat-test-chat-tools.el ends here
