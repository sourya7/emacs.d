;;; pichat-test-shell-presentation.el --- PiChat shell presentation tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused execute-tool presentation and action tests.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-shell-presentation)

(ert-deftest pichat-shell-outcome-normalizes-distinct-terminal-causes ()
  (dolist (case
           '(((:type "tool_execution_end" :isError t
              :result (:content ((:type "text" :text
                                 "out\n\nCommand exited with code 7"))))
              exit 7)
             ((:type "tool_execution_end" :isError t
               :result (:content ((:type "text" :text
                                  "Command timed out after 2.5 seconds"))))
              timeout nil)
             ((:type "tool_execution_end" :isError t
               :result (:details (:signal "SIGTERM") :content nil))
              signal "SIGTERM")
             ((:type "tool_execution_end" :isError t
               :result (:content ((:type "text" :text "ordinary failure"))))
              tool-error nil)
             ((:type "tool_execution_end" :isError nil :result (:content nil))
              success nil)))
    (let* ((outcome (pichat-shell-presentation-normalize-outcome (car case)))
           (kind (cadr case))
           (value (caddr case)))
      (should (eq kind (plist-get outcome :kind)))
      (pcase kind
        ('exit (should (= value (plist-get outcome :exit-code))))
        ('signal (should (equal value (plist-get outcome :signal)))))))
  ;; A requested timeout is not evidence that execution timed out.
  (should
   (eq 'running
       (plist-get
        (pichat-shell-presentation-normalize-outcome
         '(:type "tool_execution_start" :args (:timeout 3)))
        :kind))))

(ert-deftest pichat-shell-outcome-rejects-stale-and-duplicate-downgrades ()
  (let* ((record (pichat-tool-enrichment-build
                  "shell-1" "bash" '(:command "false")))
         (ended (pichat-shell-presentation-observe
                 record
                 '(:type "tool_execution_end" :isError t
                   :result (:content ((:type "text" :text
                                      "Command exited with code 9"))))))
         (stale (pichat-shell-presentation-observe
                 ended '(:type "tool_execution_update" :partialResult nil)))
         (duplicate (pichat-shell-presentation-observe
                     stale '(:type "tool_execution_end" :isError t
                             :result (:content ((:type "text" :text
                                                "ordinary tool error")))))))
    (should (equal '(:kind exit :exit-code 9)
                   (plist-get ended :shell-outcome)))
    (should (equal (plist-get ended :shell-outcome)
                   (plist-get stale :shell-outcome)))
    (should (equal (plist-get ended :shell-outcome)
                   (plist-get duplicate :shell-outcome)))))

(ert-deftest pichat-shell-layout-has-title-command-output-and-no-terminal-claim ()
  (let* ((record (pichat-tool-enrichment-build
                  "shell-layout" "bash" '(:command "printf hello")))
         (record (plist-put record :shell-outcome '(:kind success)))
         (text (pichat-shell-presentation-text
                record "done" "hello" 'output 100 100 "[%d omitted]")))
    (should (string-match-p
             (regexp-quote "[execute: printf hello — completed]") text))
    (should (string-match-p
             (regexp-quote "Command (non-interactive):\nprintf hello") text))
    (should (string-match-p (regexp-quote "Output:\nhello") text))
    (should-not (string-match-p "terminal\|pty\|interactive shell" text))))

(defun pichat-test-shell--canonical-transcript ()
  "Return one persisted execute tool for projection tests."
  (let ((tool
         (pichat-transcript-content-create
          :kind 'tool :index 0 :tool-call-id "one-pass-shell"
          :name "bash" :arguments '(:command "printf one-pass")
          :status 'done
          :output
          (list (pichat-transcript-content-create
                 :kind 'prose :index 0 :text "one-pass output")))))
    (pichat-transcript-create
     :nodes
     (list (pichat-transcript-node-create
            :kind 'message :key "one-pass-node" :role 'assistant
            :content (list tool)))
     :diagnostics nil :metadata nil)))

(ert-deftest pichat-chat-execute-fragment-is-final-before-indexing ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((transcript (pichat-test-shell--canonical-transcript))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context))
                     (second (pichat-render-canonical transcript context))
                     (text (pichat-render-fragment-propertized-string fragment))
                     (header-position (string-match "\\[execute:" text))
                     (output-position (string-match "one-pass output" text)))
                (should (equal fragment second))
                (should (= 0 (hash-table-count
                              pichat-chat--tool-enrichments)))
                (should (string-match-p
                         (regexp-quote
                          "[execute: printf one-pass — completed]")
                         text))
                (should (string-match-p
                         (regexp-quote
                          "Command (non-interactive):\nprintf one-pass")
                         text))
                (should header-position)
                (should (eq 'pichat-tool-label-face
                            (get-text-property header-position
                                               'font-lock-face text)))
                (should output-position)
                (should (equal '("one-pass-node" . "one-pass-shell")
                               (get-text-property output-position
                                                  'pichat-tool-key text)))
                (should (equal "one-pass-node"
                               (get-text-property output-position
                                                  'pichat-node-key text)))
                (should (eq 'assistant
                            (get-text-property output-position
                                               'pichat-node-role text)))
                (should (eq 'tool
                            (get-text-property output-position
                                               'pichat-content-kind text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-indexing-does-not-edit-rendered-text ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer indexed)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((transcript (pichat-test-shell--canonical-transcript))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context)
                (let ((before (buffer-chars-modified-tick)))
                  (setq indexed
                        (pichat-chat--index-canonical-tools
                         transcript
                         (marker-position pichat-chat--canonical-start)
                         (marker-position pichat-chat--canonical-end)
                         context))
                  (should (= before (buffer-chars-modified-tick)))))))
        (when indexed (pichat-chat-tool-ui-release-blocks indexed))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-update-does-not-rewrite-earlier-execute-blocks ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer rendered)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (dolist
                  (event
                   '((:type "message_end"
                      :message (:role "assistant"
                                :content
                                ((:type "toolCall" :id "earlier-1" :name "bash"
                                  :arguments (:command "printf first")))))
                     (:type "tool_execution_end" :toolCallId "earlier-1"
                      :toolName "bash" :args (:command "printf first")
                      :isError nil
                      :result (:content ((:type "text" :text "first"))))
                     (:type "message_end"
                      :message (:role "toolResult" :toolCallId "earlier-1"
                                :toolName "bash" :isError nil
                                :content ((:type "text" :text "first"))))
                     (:type "message_end"
                      :message (:role "assistant"
                                :content
                                ((:type "toolCall" :id "earlier-2" :name "bash"
                                  :arguments (:command "printf second")))))
                     (:type "tool_execution_end" :toolCallId "earlier-2"
                      :toolName "bash" :args (:command "printf second")
                      :isError nil
                      :result (:content ((:type "text" :text "second"))))
                     (:type "message_end"
                      :message (:role "toolResult" :toolCallId "earlier-2"
                                :toolName "bash" :isError nil
                                :content ((:type "text" :text "second"))))
                     (:type "message_start"
                      :message (:role "assistant" :content nil))
                     (:type "message_update"
                      :message (:role "assistant"
                                :content ((:type "text" :text "first draft"))))))
                (pichat-pi-live-draft-apply pichat-chat--live-draft event))
              (pichat-chat--project-live-tail)
              (should (gethash "earlier-1" pichat-chat--live-tool-blocks))
              (should (gethash "earlier-2" pichat-chat--live-tool-blocks))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :message (:role "assistant"
                           :content ((:type "text" :text "second draft")))))
              (cl-letf (((symbol-function 'pichat-chat-tool-ui-render-block)
                         (let ((original
                                (symbol-function
                                 'pichat-chat-tool-ui-render-block)))
                           (lambda (block context)
                             (push (plist-get (plist-get block :raw)
                                              :toolCallId)
                                   rendered)
                             (funcall original block context)))))
                (pichat-chat--project-live-tail))
              (should-not rendered)
              (should (string-match-p
                       "second draft" (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-shell-cumulative-updates-replace-without-duplication ()
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
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"shell-live\",\"name\":\"bash\",\"arguments\":{\"command\":\"printf lines\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"shell-live\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"shell-live\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"alpha\"}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"shell-live\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"alpha\\nbeta\"}]}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection)
              (let* ((block (gethash "shell-live" pichat-chat--tool-blocks))
                     (text (buffer-substring-no-properties
                            (plist-get block :start) (plist-get block :end))))
                (should (string-match-p
                         (regexp-quote "— running]") text))
                (should (string-match-p "Output:\nalpha\nbeta" text))
                (let ((start 0) (count 0))
                  (while (string-match "alpha" text start)
                    (cl-incf count)
                    (setq start (match-end 0)))
                  (should (= 1 count)))
                (should-not (string-match-p "alphaalpha\|alpha\nalpha" text))))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"shell-live\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"alpha\\nbeta\\n\\nCommand exited with code 7\"}]},\"isError\":true}\n")
            (with-current-buffer buffer
              (let* ((block (gethash "shell-live" pichat-chat--tool-blocks))
                     (text (buffer-substring-no-properties
                            (plist-get block :start) (plist-get block :end))))
                (should (string-match-p
                         (regexp-quote "— exit 7]") text))
                (should (string-match-p
                         (regexp-quote "Command (non-interactive):") text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-shell-actions-copy-full-values-and-gate-host-rerun ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          (command "printf 'exact command'")
          copied compilation-command buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             (format "{\"type\":\"tool_execution_start\",\"toolCallId\":\"shell-actions\",\"toolName\":\"bash\",\"args\":{\"command\":%S}}\n" command))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"shell-actions\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"complete output\"}]},\"isError\":false}\n")
            (with-current-buffer buffer
              (goto-char (marker-position
                          (plist-get (gethash "shell-actions"
                                             pichat-chat--tool-blocks)
                                     :start)))
              (cl-letf (((symbol-function 'kill-new)
                         (lambda (text &optional _) (setq copied text))))
                (pichat-chat-copy-shell-command)
                (should (equal command copied))
                (pichat-chat-copy-shell-output)
                (should (equal "complete output" copied)))
              (let ((pichat-shell-presentation-enable-compilation-rerun nil))
                (should-error (pichat-chat-rerun-shell-in-compilation)
                              :type 'user-error))
              (let ((pichat-shell-presentation-enable-compilation-rerun t))
                (require 'compile)
                (cl-letf (((symbol-function 'compilation-start)
                           (lambda (cmd &rest _)
                             (setq compilation-command cmd))))
                  (pichat-chat-rerun-shell-in-compilation)))
              (should (equal command compilation-command))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-shell-details-retain-full-output-and-output-path ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          (pichat-chat-max-tool-output-chars 5)
          (details-buffer-name "*PiChat Tool Details*")
          copied buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"shell-full\",\"toolName\":\"bash\",\"args\":{\"command\":\"long-command\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"shell-full\",\"toolName\":\"bash\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"0123456789\"}],\"details\":{\"fullOutputPath\":\"/tmp/pi-full-output\"}},\"isError\":false}\n")
            (with-current-buffer buffer
              (let* ((block (gethash "shell-full" pichat-chat--tool-blocks))
                     (visible (buffer-substring-no-properties
                               (plist-get block :start) (plist-get block :end))))
                (should (string-match-p "01234" visible))
                (should-not (string-match-p "0123456789" visible))
                (goto-char (marker-position (plist-get block :start)))
                (cl-letf (((symbol-function 'kill-new)
                           (lambda (text &optional _) (setq copied text))))
                  (pichat-chat-copy-shell-output))
                (should (equal "0123456789" copied))
                (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
                  (pichat-chat-show-tool-details))))
            (with-current-buffer details-buffer-name
              (should (string-match-p "0123456789" (buffer-string)))
              (should (string-match-p
                       (regexp-quote "/tmp/pi-full-output")
                       (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when-let ((details-buffer (get-buffer details-buffer-name)))
          (kill-buffer details-buffer))))))

(ert-deftest pichat-chat-canonical-shell-without-live-enrichment-uses-command-layout ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((tool
                      (pichat-transcript-content-create
                       :kind 'tool :index 0 :tool-call-id "canonical-shell"
                       :name "bash" :arguments '(:command "echo persisted")
                       :status 'done
                       :output
                       (list (pichat-transcript-content-create
                              :kind 'prose :index 0 :text "persisted output"))))
                     (transcript
                      (pichat-transcript-create
                       :nodes
                       (list (pichat-transcript-node-create
                              :kind 'message :key "canonical-node"
                              :role 'assistant :content (list tool)))
                       :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (should (= 0 (hash-table-count pichat-chat--tool-enrichments)))
                (pichat-chat--project-canonical
                 nil transcript fragment context)
                (let* ((block (gethash "canonical-shell"
                                       pichat-chat--tool-blocks))
                       (text (buffer-substring-no-properties
                              (plist-get block :start) (plist-get block :end))))
                  (should (string-match-p
                           (regexp-quote "[execute: echo persisted — completed]")
                           text))
                  (should (string-match-p
                           (regexp-quote
                            "Command (non-interactive):\necho persisted")
                           text))
                  (should (string-match-p "Output:\npersisted output" text))
                  (should (equal "canonical-node"
                                 (get-text-property
                                  (marker-position (plist-get block :start))
                                  'pichat-node-key)))
                  (should (equal '("canonical-node" . "canonical-shell")
                                 (get-text-property
                                  (marker-position (plist-get block :start))
                                  'pichat-tool-key)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-shell-presentation)
;;; pichat-test-shell-presentation.el ends here
