;;; pichat-test-chat-core.el --- Pichat Test Chat Core -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-mode-wraps-at-window-edge-with-visual-lines ()
  (let ((pichat-chat-stop-session-on-kill nil))
    (with-temp-buffer
      (setq-local truncate-lines t)
      (visual-line-mode -1)
      (pichat-chat-mode)
      (should (local-variable-p 'truncate-lines))
      (should-not truncate-lines)
      (should visual-line-mode)
      (should word-wrap)
      (should-not (featurep 'visual-fill-column))
      (should-not (local-variable-p 'visual-fill-column-width))
      (should-not (local-variable-p 'visual-fill-column-center-text)))))

(ert-deftest pichat-chat-agent-settlement-requests-current-context-usage ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
            (let (commands)
              (maphash
               (lambda (_id pending)
                 (push (pichat-rpc--pending-command pending) commands))
               (pichat-session-pending-responses session))
              (should (member "get_session_stats" commands))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-turn-end-refreshes-stats-while-running ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional error-callback)
                         (push (list callback error-callback) calls)
                         (format "stats-%d" (length calls)))))
              (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
              (pichat-rpc--process-filter proc "{\"type\":\"turn_end\"}\n"))
            (should (eq 'running (pichat-session-state session)))
            (should (= 1 (length calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-stats-refresh-is-single-flight-with-one-follow-up ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional error-callback)
                         (setq calls
                               (append calls
                                       (list (list callback error-callback))))
                         (format "stats-%d" (length calls)))))
              (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
              (dotimes (_ 3)
                (pichat-rpc--process-filter proc "{\"type\":\"turn_end\"}\n"))
              (should (= 1 (length calls)))
              (funcall (caar calls) '(:success t :data (:contextUsage nil))
                       session)
              (should (= 2 (length calls)))
              (funcall (car (cadr calls))
                       '(:success t :data (:contextUsage nil)) session)
              (with-current-buffer buffer
                (should-not pichat-chat--stats-in-flight)
                (should-not pichat-chat--stats-pending))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-final-settlement-does-not-duplicate-turn-refresh ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional _error-callback)
                         (push callback calls)
                         (format "stats-%d" (length calls))))
                      ((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "entries")))
              (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
              (pichat-rpc--process-filter proc "{\"type\":\"turn_end\"}\n")
              (setf (pichat-session-context-usage session)
                    '(:tokens 10 :contextWindow 100 :percent 10))
              (funcall (car calls) '(:success t) session)
              (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
              (should (= 1 (length calls)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-state-follow-up-preserves-turn-coverage ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                         (lambda (_session callback &optional error-callback)
                           (setq calls
                                 (append calls
                                         (list (list callback error-callback))))
                           (format "stats-%d" (length calls))))
                        ((symbol-function 'pichat-rpc-get-entries)
                         (lambda (&rest _args) "entries")))
                (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
                (pichat-rpc--process-filter proc "{\"type\":\"turn_end\"}\n")
                (pichat-chat--refresh-stats session 'state)
                (should (= 1 (length calls)))
                (funcall (car (nth 0 calls)) '(:success t) session)
                (should (= 2 (length calls)))
                (should pichat-chat--stats-run-covered-p)
                (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
                (should-not pichat-chat--stats-pending)
                (funcall (car (nth 1 calls)) '(:success t) session)
                (should (= 2 (length calls)))
                (should-not pichat-chat--stats-in-flight))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-stats-updates-mode-line-only-when-usage-changes ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          callbacks
          (mode-line-updates 0)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (setf (pichat-session-context-usage session)
                  '(:tokens 10 :contextWindow 100 :percent 10))
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                         (lambda (_session callback &optional _error-callback)
                           (push callback callbacks)
                           "stats"))
                        ((symbol-function 'force-mode-line-update)
                         (lambda (&rest _args) (cl-incf mode-line-updates))))
                (pichat-chat--refresh-stats session 'state)
                (funcall (car callbacks) '(:success t) session)
                (should (= 0 mode-line-updates))
                (pichat-chat--refresh-stats session 'state)
                (setf (pichat-session-context-usage session)
                      '(:tokens 20 :contextWindow 100 :percent 20))
                (funcall (car callbacks) '(:success t) session)
                (should (= 1 mode-line-updates)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-stats-failure-releases-slot-and-runs-pending-refresh ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                         (lambda (_session callback &optional error-callback)
                           (setq calls
                                 (append calls
                                         (list (list callback error-callback))))
                           (format "stats-%d" (length calls)))))
                (pichat-chat--refresh-stats session 'turn)
                (pichat-chat--refresh-stats session 'turn)
                (should (= 1 (length calls)))
                (funcall (cadr (car calls))
                         '(:success nil :error "stats failed") session)
                (should (= 2 (length calls)))
                (funcall (car (cadr calls)) '(:success t) session)
                (should-not pichat-chat--stats-in-flight))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-buffer-death-cancels-owned-stats-request ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer request-id)
      (setq buffer (pichat-chat-open session))
      (with-current-buffer buffer
        (pichat-chat--refresh-stats session 'state)
        (setq request-id pichat-chat--stats-request-id))
      (should (gethash request-id (pichat-session-pending-responses session)))
      (kill-buffer buffer)
      (should-not (gethash request-id
                           (pichat-session-pending-responses session))))))

(ert-deftest pichat-chat-rebind-invalidates-old-stats-and-starts-new-source-refresh ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer old-callback old-token)
      (unwind-protect
          (progn
            (setf (pichat-session-id session) "old-source"
                  (pichat-session-context-usage session)
                  '(:tokens 40 :contextWindow 100 :percent 40))
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--refresh-stats session 'state)
              (setq old-token pichat-chat--stats-in-flight
                    old-callback
                    (pichat-rpc--pending-callback
                     (gethash pichat-chat--stats-request-id
                              (pichat-session-pending-responses session)))))
            (let ((rebind-id
                   (pichat-rpc-switch-session
                    session "/sanitized/new.jsonl" nil)))
              (pichat-rpc--process-filter
               proc
               (format "{\"type\":\"response\",\"id\":%S,\"command\":\"switch_session\",\"success\":true,\"data\":{}}\n"
                       rebind-id)))
            (should-not (pichat-session-context-usage session))
            (with-current-buffer buffer
              (should-not pichat-chat--stats-in-flight)
              (should-not pichat-chat--stats-pending))
            (let ((state-id (pichat-rpc-get-state session nil)))
              (pichat-rpc--process-filter
               proc
               (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"new-source\",\"isStreaming\":false}}\n"
                       state-id)))
            (with-current-buffer buffer
              (should pichat-chat--stats-in-flight)
              (should-not (eq old-token pichat-chat--stats-in-flight))
              (let ((new-token pichat-chat--stats-in-flight))
                (funcall old-callback '(:success t) session)
                (should (eq new-token pichat-chat--stats-in-flight)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-default-model-parser-requires-header-and-parses-rows ()
  (let ((output
         (concat
          "provider      model             context  max-out  thinking  images\n"
          "anthropic     claude-sonnet-4   200K     64K      yes       yes\n"
          "openai-codex  gpt-5.6           200K     128K     yes       yes\n")))
    (should
     (equal '(("anthropic" . "claude-sonnet-4")
              ("openai-codex" . "gpt-5.6"))
            (pichat--parse-model-table output)))
    (should-not
     (pichat--parse-model-table
      "No models matching \"unavailable\"\n"))))

(ert-deftest pichat-default-model-prompt-sets-qualified-model ()
  (let ((pichat-default-model nil)
        marked)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _args)
                 (should (equal '("test/model") (mapcar #'car choices)))
                 "test/model"))
              ((symbol-function 'customize-mark-as-set)
               (lambda (symbol) (setq marked symbol))))
      (pichat--prompt-and-set-default-model '(("test" . "model")))
      (should (equal "test/model" pichat-default-model))
      (should (eq 'pichat-default-model marked)))))

(ert-deftest pichat-nonlaunch-model-selectors-remain-catalog-only ()
  (let (require-match-values)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices _predicate require-match &rest _args)
                 (push require-match require-match-values)
                 (caar choices))))
      (should (equal "test/model"
                     (pichat--read-model-table-choice
                      "Default model: " '(("test" . "model")))))
      (should
       (equal '("test/model" :provider "test" :id "model")
              (pichat--read-model-choice
               '((:provider "test" :id "model"))))))
    (should (equal '(t t) (nreverse require-match-values)))))

(ert-deftest pichat-default-model-selector-omits-empty-search-argument ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat--project-root)
                   (lambda (&optional _directory) nil))
                  ((symbol-function 'make-process)
                   (lambda (&rest arguments)
                     (setq captured arguments)
                     'fake-process)))
          (let ((default-directory temporary-file-directory))
            (pichat-select-default-model nil))
          (should (equal '("/opt/pi" "--list-models")
                         (plist-get captured :command))))
      (dolist (key '(:buffer :stderr))
        (let ((buffer (plist-get captured key)))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(ert-deftest pichat-default-model-selector-universal-argument-clears-override ()
  (let ((current-prefix-arg '(4))
        (pichat-default-model "test/model")
        (pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        marked)
    (cl-letf (((symbol-function 'customize-mark-as-set)
               (lambda (symbol) (setq marked symbol))))
      (call-interactively #'pichat-select-default-model)
      (should-not pichat-default-model)
      (should (eq 'pichat-default-model marked)))))

(ert-deftest pichat-default-model-selector-rejects-complete-rpc-command ()
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc")))
    (should-error (pichat-select-default-model nil) :type 'user-error)))

(ert-deftest pichat-select-model-defers-prompt-and-refreshes-session-model-cache ()
  (pichat-test-with-unit-session (session proc)
    (let (chosen scheduled)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _args)
                   (setq chosen (caar choices))))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (setq scheduled (cons function args)))))
        (pichat-select-model session)
        (let ((id (car (pichat-test--hash-table-keys
                        (pichat-session-pending-responses session)))))
          (pichat-rpc--process-filter
           proc
           (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_available_models\",\"success\":true,\"data\":{\"models\":[{\"provider\":\"test\",\"id\":\"new-model\",\"name\":\"New Model\"}]}}\n" id)))
        (should scheduled)
        (should-not chosen)
        (apply (car scheduled) (cdr scheduled))
        (should (equal "test/new-model" chosen))
        (let ((id (car (pichat-test--hash-table-keys
                        (pichat-session-pending-responses session)))))
          (pichat-rpc--process-filter
           proc
           (format "{\"type\":\"response\",\"id\":%S,\"command\":\"set_model\",\"success\":true,\"data\":{}}\n" id)))
        (should-not (equal "new-model" (plist-get (pichat-session-model session) :id)))
        (let ((id (car (pichat-test--hash-table-keys
                        (pichat-session-pending-responses session)))))
          (pichat-rpc--process-filter
           proc
           (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"s1\",\"model\":{\"provider\":\"test\",\"id\":\"new-model\"},\"thinkingLevel\":\"off\",\"isStreaming\":false}}\n" id)))
        (should (equal "new-model" (plist-get (pichat-session-model session) :id)))))))

(ert-deftest pichat-select-model-quit-does-not-send-selection ()
  (pichat-test-with-unit-session (session)
    (let (sent)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) (signal 'quit nil)))
                ((symbol-function 'pichat-rpc-set-model)
                 (lambda (&rest _args) (setq sent t))))
        (pichat--prompt-and-select-model
         session '((:provider "test" :id "model")))
        (should-not sent)))))

(ert-deftest pichat-command-run-defers-minibuffer-prompts ()
  (pichat-test-with-unit-session (session proc)
    (let (scheduled prompted)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (setq scheduled (cons function args))))
                ((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _args)
                   (setq prompted t)
                   (caar choices)))
                ((symbol-function 'read-string)
                 (lambda (&rest _args) "topic")))
        (pichat-command-run session)
        (let ((id (car (pichat-test--hash-table-keys
                        (pichat-session-pending-responses session)))))
          (pichat-rpc--process-filter
           proc
           (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_commands\",\"success\":true,\"data\":{\"commands\":[{\"name\":\"help\",\"source\":\"extension\",\"description\":\"Help\"}]}}\n" id)))
        (should scheduled)
        (should-not prompted)
        (apply (car scheduled) (cdr scheduled))
        (should prompted)
        (let* ((id (car (pichat-test--hash-table-keys
                         (pichat-session-pending-responses session))))
               (pending (gethash id (pichat-session-pending-responses session))))
          (should (equal "prompt" (pichat-rpc--pending-command pending))))))))

(ert-deftest pichat-command-run-quit-at-either-prompt-sends-nothing ()
  (pichat-test-with-unit-session (session)
    (let ((commands '((:name "help" :source "extension" :description "Help")))
          sent)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) (signal 'quit nil)))
                ((symbol-function 'pichat-rpc-prompt)
                 (lambda (&rest _args) (setq sent t))))
        (pichat-command--prompt-and-run session commands))
      (should-not sent)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt choices &rest _args) (caar choices)))
                ((symbol-function 'read-string)
                 (lambda (&rest _args) (signal 'quit nil)))
                ((symbol-function 'pichat-rpc-prompt)
                 (lambda (&rest _args) (setq sent t))))
        (pichat-command--prompt-and-run session commands))
      (should-not sent))))

(ert-deftest pichat-chat-mode-line-displays-model-id-or-model-id-field ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-session session))
      (setf (pichat-session-model session)
            '(:modelId "fallback-model" :reasoning t)
            (pichat-session-thinking-level session) "off")
      (let ((status (pichat-chat--mode-line-status)))
        (should (string-match-p "fallback-model\\.0" status))
        (should-not (string-match-p "model:\\|thinking:" status))))))

(ert-deftest pichat-chat-tool-state-cycle-skips-inline-output ()
  (should (eq 'args (pichat-chat--cycle-tool-state 'summary)))
  (should (eq 'summary (pichat-chat--cycle-tool-state 'args)))
  (should (eq 'summary (pichat-chat--cycle-tool-state 'output))))

(ert-deftest pichat-render-thinking-texts-extracts-thinking-without-normal-content ()
  (let ((content '((:type "thinking" :thinking "private reasoning")
                   (:type "text" :text "final answer"))))
    (should (equal '("private reasoning") (pichat-render-thinking-texts content)))
    (should (equal "final answer" (pichat-render-content content)))))

(ert-deftest pichat-render-unknown-data-never-uses-raw-printer-fallback ()
  (let ((secret '(:future "must-not-render")))
    (should (equal "[unsupported content]"
                   (pichat-render-content (list secret))))
    (should-not (string-match-p
                 "must-not-render"
                 (pichat-render-entry-text
                  '(:type "future" :data (:secret "must-not-render"))))))
  (let ((circular (list "value")))
    (setcdr circular circular)
    (should (equal "[unavailable arguments]"
                   (pichat-render-tool-args circular)))))

(ert-deftest pichat-chat-thinking-toggle-reprojects-without-source-fetch ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking t)
          calls buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((node (pichat-transcript-node-create
                            :kind 'message :key "thinking-node"
                            :role 'assistant
                            :content
                            (list
                             (pichat-transcript-content-create
                              :kind 'thinking :index 0 :text "private")
                             (pichat-transcript-content-create
                              :kind 'prose :index 1 :text "answer"))))
                     (transcript (pichat-transcript-create
                                  :nodes (list node)
                                  :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context)))
                (pichat-chat--project-canonical
                 nil transcript (pichat-render-canonical transcript context)
                 context))
              (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                         (lambda (&rest _args) (cl-incf calls))))
                (pichat-chat-toggle-thinking-display))
              (should-not calls)
              (should-not (string-match-p "private"
                                          (pichat-test-buffer-text buffer)))
              (should (string-match-p "answer"
                                      (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-thinking-display-defaults-to-shown-and-toggles ()
  (should pichat-chat-show-thinking)
  (let ((pichat-chat-show-thinking pichat-chat-show-thinking))
    (pichat-chat-toggle-thinking-display)
    (should-not pichat-chat-show-thinking)
    (pichat-chat-toggle-thinking-display)
    (should pichat-chat-show-thinking)))

(ert-deftest pichat-chat-obsolete-direct-event-mutators-are-removed ()
  (dolist (symbol '(pichat-chat--on-message-start
                    pichat-chat--on-message-update
                    pichat-chat--on-message-end
                    pichat-chat--on-tool-start
                    pichat-chat--on-tool-update
                    pichat-chat--on-tool-end))
    (should-not (fboundp symbol)))
  (dolist (symbol '(pichat-chat--append-prose
                    pichat-chat--append-thinking
                    pichat-chat--markdown-render-response
                    pichat-chat--normalize-streamed-thinking-region
                    pichat-chat--sync-tool-call-placeholders-from-message
                    pichat-chat--insert-tool-block
                    pichat-chat--tool-call-content-raw
                    pichat-chat--canonical-tool-raw
                    pichat-chat--merge-tool-raw
                    pichat-chat--append-user-block
                    pichat-chat--append
                    pichat-chat--append-at-end
                    pichat-chat--append-system-message
                    pichat-chat--replace-region
                    pichat-chat--insert-assistant-text-for-repaint
                    pichat-chat--assistant-renderable-part-text
                    pichat-chat--insert-assistant-message-for-repaint
                    pichat-chat--insert-message-for-repaint
                    pichat-chat--message-tool-calls
                    pichat-chat--tool-call-raw
                    pichat-chat--tool-result-raw
                    pichat-chat--insert-tool-for-repaint
                    pichat-chat--thinking-display-text
                    pichat-chat--message-display-text
                    pichat-chat--repaint-turn
                    pichat-chat--repaint-entries
                    pichat-chat--user-block-text
                    pichat-chat--insert-user-block
                    pichat-chat--normalize-thinking-text
                    pichat-chat--plist-first
                    pichat-chat--tool-id
                    pichat-chat--tool-display-raw))
    (should-not (fboundp symbol)))
  (dolist (symbol '(pichat-chat--assistant-streamed-p
                    pichat-chat--assistant-label-inserted-p
                    pichat-chat--assistant-response-beg
                    pichat-chat--assistant-response-end
                    pichat-chat--thinking-streamed-p
                    pichat-chat--thinking-response-beg
                    pichat-chat--thinking-response-end))
    (should-not (boundp symbol))))

(provide 'pichat-test-chat-core)
;;; pichat-test-chat-core.el ends here
