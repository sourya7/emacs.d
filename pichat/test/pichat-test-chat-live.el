;;; pichat-test-chat-live.el --- Pichat Test Chat Live -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-live-tail-coalesces-high-frequency-updates ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer callback callback-args
          (scheduled 0)
          (projections 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_start"
                 :message (:role "assistant" :content nil))))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest args)
                         (cl-incf scheduled)
                         (setq callback function callback-args args)
                         'fake-live-timer))
                      ((symbol-function 'pichat-chat--project-live-tail)
                       (lambda () (cl-incf projections))))
              (with-current-buffer buffer
                (dolist (assistant-event
                         '((:type "text_start" :contentIndex 0)
                           (:type "text_delta" :contentIndex 0 :delta "one")
                           (:type "text_delta" :contentIndex 0 :delta " two")))
                  (pichat-chat--on-rpc-event
                   session 'rpc-event
                   (list :raw
                         (list :type "message_update"
                               :assistantMessageEvent assistant-event)))))
              (should (= 1 scheduled))
              (should (= 0 projections))
              (apply callback callback-args)
              (should (= 1 projections))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-delta-only-text-is-visible-before-message-end ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_start\",\"contentIndex\":0}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"text_delta\",\"contentIndex\":0,\"delta\":\"visible partial\"}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection)
              (should-not (pichat-live-draft-message-final-p
                           pichat-chat--live-draft)))
            (should (string-match-p "visible partial"
                                    (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-ignored-deltas-schedule-no-projection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer
          (scheduled 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_start"
                 :message (:role "assistant" :content nil))))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (&rest _args)
                         (cl-incf scheduled)
                         'unexpected-timer)))
              (with-current-buffer buffer
                (dolist (assistant-event
                         '((:type "start")
                           (:type "text_delta" :contentIndex "bad"
                            :delta "ignored")
                           (:type "future_delta" :contentIndex 0
                            :delta "ignored")))
                  (pichat-chat--on-rpc-event
                   session 'rpc-event
                   (list :raw
                         (list :type "message_update"
                               :assistantMessageEvent assistant-event))))
                (should (= 0 scheduled))
                (should-not (pichat-transcript-node-content
                             (car (pichat-live-draft-nodes
                                   pichat-chat--live-draft)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tool-argument-deltas-use-throttled-projection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-tool-call-update-delay 0.25)
          buffer delays)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_start"
                 :message (:role "assistant" :content nil)))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :assistantMessageEvent
                 (:type "toolcall_start" :contentIndex 0))))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (delay _repeat _function &rest _args)
                         (push delay delays)
                         'fake-tool-delta-timer)))
              (with-current-buffer buffer
                (dolist (fragment '("{\"path\":\".tmp/plan\",\"content\":"
                                    "\"one two " "three\"}"))
                  (pichat-chat--on-rpc-event
                   session 'rpc-event
                   (list :raw
                         (list :type "message_update"
                               :assistantMessageEvent
                               (list :type "toolcall_delta"
                                     :contentIndex 0 :delta fragment)))))
                (should (equal '(0.25) delays))
                (let* ((node (car (pichat-live-draft-nodes
                                   pichat-chat--live-draft)))
                       (tool (car (pichat-transcript-node-content node))))
                  (should (equal "one two three"
                                 (plist-get
                                  (pichat-transcript-content-arguments tool)
                                  :content)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-terminal-event-burst-coalesces-to-one-projection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer callback callback-args
          (timer (timer-create))
          (scheduled 0)
          (projections 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_start"
                 :message (:role "assistant" :content nil)))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :assistantMessageEvent
                 (:type "toolcall_start" :contentIndex 0))))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest args)
                         (cl-incf scheduled)
                         (setq callback function callback-args args)
                         timer))
                      ((symbol-function 'cancel-timer) #'ignore)
                      ((symbol-function 'pichat-chat--project-live-tail)
                       (lambda () (cl-incf projections))))
              (with-current-buffer buffer
                (dolist
                    (raw
                     '((:type "message_update"
                        :assistantMessageEvent
                        (:type "toolcall_delta" :contentIndex 0
                         :delta "{\"path\":\".tmp/plan\",\"content\":\"large\"}"))
                       (:type "message_update"
                        :assistantMessageEvent
                        (:type "toolcall_end" :contentIndex 0
                         :toolCall
                         (:type "toolCall" :id "write-1" :name "write"
                          :arguments (:path ".tmp/plan" :content "large"))))
                       (:type "message_end"
                        :message
                        (:role "assistant"
                         :content
                         ((:type "toolCall" :id "write-1" :name "write"
                           :arguments (:path ".tmp/plan" :content "large")))))
                       (:type "tool_execution_start" :toolCallId "write-1"
                        :toolName "write"
                        :args (:path ".tmp/plan" :content "large"))
                       (:type "tool_execution_end" :toolCallId "write-1"
                        :toolName "write" :isError nil
                        :result (:content ((:type "text" :text "written"))))
                       (:type "message_start"
                        :message (:role "toolResult" :toolCallId "write-1"
                                  :toolName "write" :content nil))
                       (:type "message_end"
                        :message
                        (:role "toolResult" :toolCallId "write-1"
                         :toolName "write" :isError nil
                         :content ((:type "text" :text "written"))))
                       (:type "message_start"
                        :message (:role "assistant" :content nil))))
                  (pichat-chat--on-rpc-event
                   session 'rpc-event (list :raw raw))))
              (should (= 2 scheduled))
              (should (= 0 projections))
              (apply callback callback-args)
              (should (= 1 projections))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-transition-cancels-owned-sync-request ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer cancelled)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "owned-sync"))
                      ((symbol-function 'pichat-rpc-cancel-request)
                       (lambda (_session id) (push id cancelled))))
              (with-current-buffer buffer
                (pichat-chat--request-sync t)
                (should (equal "owned-sync"
                               pichat-chat--sync-request-id))
                (pichat-chat--reset-for-source "new-source" nil t)
                (should (equal '("owned-sync") cancelled))
                (should-not pichat-chat--sync-request-id))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-source-transition-cancels-and-rejects-stale-live-timer ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer callback callback-args cancelled
          (timer (timer-create))
          (projections 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest args)
                         (setq callback function callback-args args)
                         timer))
                      ((symbol-function 'cancel-timer)
                       (lambda (value) (push value cancelled)))
                      ((symbol-function 'pichat-chat--project-live-tail)
                       (lambda () (cl-incf projections))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"stale\"}]}}\n")
              (should callback)
              (pichat-emit session 'session-rebinding
                           :command "switch_session")
              (should (memq timer cancelled))
              (with-current-buffer buffer
                (should pichat-chat--source-rebinding-p)
                (should-not (pichat-live-draft-nodes
                             pichat-chat--live-draft)))
              (apply callback callback-args)
              (should (= 0 projections))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-buffer-kill-cancels-live-projection-timer ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer cancelled
          (timer (timer-create)))
      (setq buffer (pichat-chat-open session))
      (cl-letf (((symbol-function 'run-with-idle-timer)
                 (lambda (&rest _args) timer))
                ((symbol-function 'cancel-timer)
                 (lambda (value) (push value cancelled))))
        (pichat-rpc--process-filter
         proc
         "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"pending\"}]}}\n")
        (kill-buffer buffer)
        (should (memq timer cancelled))))))

(ert-deftest pichat-chat-live-tail-renders-user-only-from-authoritative-event ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (&rest _args) "request-id")))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "authoritative event prompt")
                (pichat-chat-send-input)))
            (should-not (string-match-p
                         "authoritative event prompt"
                         (pichat-test-buffer-text buffer)))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"authoritative event prompt\"}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"authoritative event prompt\"}]}}\n")
            (should (= 1 (pichat-test-count-substring
                          "authoritative event prompt"
                          (pichat-test-buffer-text buffer))))
            (with-current-buffer buffer
              (should (pichat-live-draft-p pichat-chat--live-draft))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-streaming-thinking-hidden-renders-nothing ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"private\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\" reasoning\"}}\n")
            (let ((text (pichat-test-buffer-text buffer)))
              (should-not (string-match-p (regexp-quote "[thinking") text))
              (should-not (string-match-p (regexp-quote "private reasoning") text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-streaming-thinking-shown-omits-label ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"private reasoning\"}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection))
            (let ((text (pichat-test-buffer-text buffer)))
              (should-not (string-match-p (regexp-quote "[thinking") text))
              (should (string-match-p (regexp-quote "private reasoning") text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-streaming-thinking-before-tool-is-compact ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--clear-input))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"live plan\\n\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"live plan\"},{\"type\":\"toolCall\",\"id\":\"call-1\",\"name\":\"test_tool\",\"arguments\":{}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_end\",\"toolCallId\":\"call-1\",\"toolName\":\"test_tool\",\"isError\":false,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"tool output\"}]}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection))
            (let ((text (pichat-test-buffer-text buffer)))
              (should (string-match-p (regexp-quote "live plan\n[tool:test_tool done]") text))
              (should-not (string-match-p
                           (regexp-quote "live plan\n\n[tool:test_tool done]")
                           text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-streaming-thinking-before-final-text-has-separator ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--clear-input))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"live plan\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"live plan\"},{\"type\":\"text\",\"text\":\"Final answer\"}]}}\n")
            (let ((text (pichat-test-buffer-text buffer)))
              (should (string-match-p (regexp-quote "live plan\n\nFinal answer") text))
              (should-not (string-match-p (regexp-quote "live planFinal answer") text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-streaming-thinking-compacts-internal-blank-lines ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-show-thinking t)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--clear-input))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_update\",\"assistantMessageEvent\":{\"type\":\"thinking_delta\",\"contentIndex\":0,\"delta\":\"first\\n\\nsecond\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"first\\n\\nsecond\"}]}}\n")
            (let ((text (pichat-test-buffer-text buffer)))
              (should (string-match-p (regexp-quote "first\nsecond") text))
              (should-not (string-match-p (regexp-quote "first\n\nsecond") text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-live)
;;; pichat-test-chat-live.el ends here
