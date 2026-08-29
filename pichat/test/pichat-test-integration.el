;;; pichat-test-integration.el --- Pichat Test Integration -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(when pichat-test-include-integration
  (ert-deftest pichat-integration-mutation-timing-requires-pre-execution-hook ()
    (let* ((specs
            '((:id "immediate-1" :mode "immediate"
               :before "before-immediate-1" :content "after-immediate-1")
              (:id "immediate-2" :mode "immediate"
               :before "before-immediate-2" :content "after-immediate-2")
              (:id "immediate-3" :mode "immediate"
               :before "before-immediate-3" :content "after-immediate-3")
              (:id "delayed" :mode "delayed"
               :before "before-delayed" :content "after-delayed"
               :delayMs 300)
              (:id "failed" :mode "fail"
               :before "before-failed" :content "unused" :delayMs 200)
              (:id "external" :mode "external-window"
               :before "before-external" :content "tool-external"
               :delayMs 200 :postDelayMs 600)))
           (turns
            (vconcat
             (mapcan
              (lambda (spec)
                (let ((arguments
                       (list :path "timing.txt"
                             :mode (plist-get spec :mode)
                             :content (plist-get spec :content)
                             :delayMs (plist-get spec :delayMs)
                             :postDelayMs (plist-get spec :postDelayMs))))
                  (list
                   (list :toolCall
                         (list :id (plist-get spec :id)
                               :name "pichat_timing_mutate"
                               :arguments arguments))
                   (list :text (format "completed:%s" (plist-get spec :id))))))
              specs))))
      (pichat-test-with-integration-session
          (session :no-session t
                   :extensions (list pichat-test-mutation-timing-extension)
                   :script (list :turns turns))
        (let ((path (expand-file-name "timing.txt" project-dir))
              (paths (make-hash-table :test #'equal))
              (at-start (make-hash-table :test #'equal))
              (at-end (make-hash-table :test #'equal))
              (end-events (make-hash-table :test #'equal)))
          (cl-labels
              ((read-target ()
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))
               (run (spec &optional external-p)
                 (with-temp-file path (insert (plist-get spec :before)))
                 (let ((settled
                        (pichat-test-count-raw-events session "agent_settled")))
                   (pichat-test-rpc-call
                    session "prompt"
                    (list :message (format "run:%s" (plist-get spec :id))))
                   (when external-p
                     (pichat-test-wait-until
                      (lambda ()
                        (and (file-exists-p path)
                             (equal "tool-external" (read-target))))
                      4 "timing tool to open its post-mutation window")
                     (with-temp-file path (insert "external-change")))
                   (pichat-test-wait-for-raw-event
                    session "agent_settled" 8 settled))))
            (pichat-on
             'rpc-event
             (lambda (_session _event payload)
               (let* ((raw (plist-get payload :raw))
                      (type (plist-get raw :type))
                      (id (plist-get raw :toolCallId)))
                 (when (and (stringp id)
                            (equal "pichat_timing_mutate"
                                   (plist-get raw :toolName)))
                   (pcase type
                     ("tool_execution_start"
                      (puthash id (plist-get (plist-get raw :args) :path) paths)
                      (puthash id (read-target) at-start))
                     ("tool_execution_end"
                      (puthash id (read-target) at-end)
                      (puthash id raw end-events))))))
             session)
            (dolist (spec specs)
              (run spec (equal "external" (plist-get spec :id))))

            ;; Immediate mutation wins the race with the RPC client: all three
            ;; start-event observations already contain post-state.  Pi's
            ;; tool_call hook, however, saw the real pre-state before execute.
            (dolist (spec (seq-take specs 3))
              (let* ((id (plist-get spec :id))
                     (event (gethash id end-events))
                     (details (plist-get (plist-get event :result) :details)))
                (should (equal (plist-get spec :content)
                               (gethash id at-start)))
                (should (equal (plist-get spec :before)
                               (plist-get details :preflightText)))
                (should (equal (plist-get spec :content)
                               (gethash id at-end)))))

            ;; A deliberate delay happens to leave enough time for an RPC
            ;; start observer, but that is a property of this tool, not a
            ;; protocol barrier.
            (should (equal "before-delayed" (gethash "delayed" at-start)))
            (should (equal "after-delayed" (gethash "delayed" at-end)))
            (should
             (equal "before-delayed"
                    (plist-get
                     (plist-get (plist-get (gethash "delayed" end-events)
                                           :result)
                                :details)
                     :preflightText)))

            ;; Failed execution must not be presented as a mutation.
            (should (equal "before-failed" (gethash "failed" at-start)))
            (should (equal "before-failed" (gethash "failed" at-end)))
            (should (plist-get (gethash "failed" end-events) :isError))

            ;; State observed at end can include a concurrent external change,
            ;; so even a start/end pair cannot be attributed solely to the tool.
            (should (equal "before-external" (gethash "external" at-start)))
            (should (equal "external-change" (gethash "external" at-end)))
            (should-not (plist-get (gethash "external" end-events) :isError))
            (should (= 6 (hash-table-count paths))))))))

  (ert-deftest pichat-integration-get-state-uses-real-pi-and-fake-model ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns []))
      (let* ((response (pichat-test-rpc-call session "get_state"))
             (data (plist-get response :data))
             (model (plist-get data :model)))
        (should (equal "pichat-fake" (plist-get model :provider)))
        (should (equal "pichat-fake" (plist-get model :id)))
        (should (eq (pichat-session-state session) 'idle)))))

  (ert-deftest pichat-integration-context-usage-refreshes-at-each-tool-turn ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns
                           [(:toolCall
                             (:id "usage-tool-1"
                              :name "pichat-test-usage-echo"
                              :arguments (:value "observed"))
                             :usage (:input 100 :output 10))
                            (:expectContextIncludes "usage-result: observed"
                             :text "usage complete"
                             :delayMs 400
                             :usage (:input 300 :output 20))]))
      (let ((pichat-chat-stop-session-on-kill nil)
            stats-responses
            buffer handler)
        (pichat-define-tool pichat-test-usage-echo
            (:label "Usage Echo"
             :description "Return a deterministic context-usage marker"
             :parameters
             (:type "object"
              :properties (:value (:type "string"))
              :required ["value"]))
          (format "usage-result: %s" (plist-get params :value)))
        (setq handler
              (lambda (event-session _event plist)
                (let ((response (plist-get plist :response)))
                  (when (and (eq event-session session)
                             (equal "get_session_stats"
                                    (plist-get response :command))
                             (plist-get response :success))
                    (setq stats-responses
                          (append
                           stats-responses
                           (list
                            (list
                             :usage
                             (plist-get (plist-get response :data)
                                        :contextUsage)
                             :state (pichat-session-state session)))))))))
        (unwind-protect
            (progn
              (pichat-on 'response-received handler session)
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait
               session buffer "measure each tool turn" 8)
              (pichat-test-wait-until
               (lambda ()
                 (and (= 2 (length stats-responses))
                      (with-current-buffer buffer
                        (not pichat-chat--stats-in-flight))))
               4 "two bounded context-usage refreshes")
              (let* ((first (car stats-responses))
                     (second (cadr stats-responses))
                     (first-tokens
                      (plist-get (plist-get first :usage) :tokens))
                     (second-tokens
                      (plist-get (plist-get second :usage) :tokens)))
                (should (eq 'running (plist-get first :state)))
                (should (numberp first-tokens))
                (should (numberp second-tokens))
                (should (> second-tokens first-tokens))
                (should (equal (plist-get second :usage)
                               (pichat-session-context-usage session)))))
          (when handler (pichat-off 'response-received handler session))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-compaction-clears-then-restores-context-usage ()
    (pichat-test-with-integration-session
        (session
         :settings '(:compaction
                     (:enabled t :reserveTokens 1000 :keepRecentTokens 100))
         :script '(:turns
                   [(:text "history one" :usage (:input 500 :output 20))
                    (:text "history two" :usage (:input 700 :output 20))
                    (:text "compacted summary" :usage (:input 200 :output 30))
                    (:text "after compaction" :usage (:input 150 :output 15))]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait
               session buffer (concat "first history " (make-string 2000 ?a)) 8)
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (not pichat-chat--stats-in-flight)))
               3 "first turn stats")
              (pichat-test-chat-send-and-wait
               session buffer (concat "second history " (make-string 2000 ?b)) 8)
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (not pichat-chat--stats-in-flight)))
               3 "second turn stats")
              (should
               (numberp
                (plist-get (pichat-session-context-usage session) :tokens)))
              (pichat-test-rpc-call session "compact" nil 8)
              (pichat-test-wait-until
               (lambda ()
                 (let ((usage (pichat-session-context-usage session)))
                   (and usage
                        (null (plist-get usage :tokens))
                        (null (plist-get usage :percent))
                        (with-current-buffer buffer
                          (not pichat-chat--stats-in-flight)))))
               4 "unknown context usage after compaction")
              (with-current-buffer buffer
                (should (string-match-p
                         "?/128k" (pichat-chat--mode-line-status))))
              (pichat-test-chat-send-and-wait
               session buffer "measure after compaction" 8)
              (pichat-test-wait-until
               (lambda ()
                 (numberp
                  (plist-get (pichat-session-context-usage session) :tokens)))
               4 "numeric post-compaction context usage"))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-failed-compaction-keeps-context-usage ()
    (pichat-test-with-integration-session
        (session
         :settings '(:compaction
                     (:enabled t :reserveTokens 1000 :keepRecentTokens 100))
         :script '(:turns
                   [(:text "failure history one"
                     :usage (:input 500 :output 20))
                    (:text "failure history two"
                     :usage (:input 700 :output 20))
                    (:error "compaction summary failed")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            (stats-count 0)
            response-handler buffer)
        (setq response-handler
              (lambda (_session _event plist)
                (when (equal "get_session_stats"
                             (plist-get (plist-get plist :response) :command))
                  (cl-incf stats-count))))
        (unwind-protect
            (progn
              (pichat-on 'response-received response-handler session)
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait
               session buffer (concat "failure history "
                                      (make-string 2000 ?x)) 8)
              (pichat-test-chat-send-and-wait
               session buffer (concat "more failure history "
                                      (make-string 2000 ?y)) 8)
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (not pichat-chat--stats-in-flight)))
               3 "pre-failure context usage")
              (let ((usage-before
                     (copy-tree (pichat-session-context-usage session)))
                    (stats-before stats-count)
                    failed-result)
                (pichat-rpc-send
                 session "compact" nil
                 (lambda (response _session)
                   (setq failed-result (list :success response)))
                 (lambda (response _session)
                   (setq failed-result (list :failure response))))
                (pichat-test-wait-until
                 (lambda () failed-result) 8 "failed compaction response")
                (should (plist-get failed-result :failure))
                (let ((event
                       (pichat-test-wait-for-raw-event
                        session "compaction_end" 4)))
                  (should (string-match-p
                           "compaction summary failed"
                           (or (plist-get event :errorMessage) ""))))
                (should (equal usage-before
                               (pichat-session-context-usage session)))
                (should (= stats-before stats-count))))
          (when response-handler
            (pichat-off 'response-received response-handler session))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-stats-recovers-after-provider-failure ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns
                           [(:error "intentional usage failure"
                             :usage (:input 20 :output 1))
                            (:text "recovered usage"
                             :usage (:input 80 :output 10))]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "fail once" 8)
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (not pichat-chat--stats-in-flight)))
               3 "failed-run stats coordinator release")
              (pichat-test-chat-send-and-wait session buffer "recover" 8)
              (pichat-test-wait-until
               (lambda ()
                 (and (numberp
                       (plist-get (pichat-session-context-usage session)
                                  :tokens))
                      (with-current-buffer buffer
                        (not pichat-chat--stats-in-flight))))
               3 "post-failure context usage refresh"))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-archive-capability-provenance-and-relations ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-archive-extension)
                 :script '(:turns []))
      (let* ((commands-response (pichat-test-rpc-call session "get_commands"))
             (commands (plist-get (plist-get commands-response :data) :commands))
             (marker (cl-find-if
                      (lambda (command)
                        (equal "pi-archive-status-v1" (plist-get command :name)))
                      commands))
             capability failure recent info relations)
        (should marker)
        (should (equal "extension" (plist-get marker :source)))
        (should (equal (file-truename pichat-test-archive-extension)
                       (file-truename
                        (or (plist-get (plist-get marker :sourceInfo) :path)
                            (plist-get marker :path)))))
        (pichat-archive-discover
         session (current-buffer)
         (lambda (value) (setq capability value))
         (lambda (value) (setq failure value)))
        (pichat-test-wait-until (lambda () (or capability failure)) 5
                                "real-Pi archive capability discovery")
        (should capability)
        (should-not failure)
        (should (equal (file-truename pichat-test-archive-extension)
                       (file-truename (plist-get capability :source))))
        (should (equal (pichat-archive-standard-database)
                       (pichat-archive--normalize-path
                        (plist-get (plist-get capability :status) :database))))
        (pichat-archive-request
         capability 'recent '(:cwd "/fixture/project" :limit 10)
         (lambda (value) (setq recent value))
         (lambda (value) (setq failure value)))
        (pichat-test-wait-until (lambda () (or recent failure)) 5
                                "real-Pi archive recent sessions")
        (should (= 1 (length recent)))
        (let ((child (car recent)))
          (should (equal "Continue archive child work"
                         (plist-get child :branch-first-user-prompt)))
          (should (equal "Continue archive child work"
                         (plist-get child :display-title)))
          (should (equal "archive-parent"
                         (plist-get child :parent-session-id)))
          (should (eq 'resolved (plist-get child :parent-resolution)))
          (should (= 0 (plist-get child :child-count))))
        (setq failure nil)
        (pichat-archive-request
         capability 'session-info '(:id "archive-child")
         (lambda (value) (setq info value))
         (lambda (value) (setq failure value)))
        (pichat-test-wait-until (lambda () (or info failure)) 5
                                "real-Pi archive session-info")
        (should (eq 'observed (plist-get info :fork-point-status)))
        (should (equal "selected-entry" (plist-get info :selected-entry-id)))
        (should (equal (plist-get (car recent) :display-title)
                       (plist-get info :display-title)))
        (should (equal (plist-get (car recent) :parent-session-id)
                       (plist-get info :parent-session-id)))
        (should (= (plist-get (car recent) :child-count)
                   (plist-get info :child-count)))
        (setq failure nil)
        (pichat-archive-request
         capability 'relations
         '(:id "archive-child" :direction "both" :limit 20)
         (lambda (value) (setq relations value))
         (lambda (value) (setq failure value)))
        (pichat-test-wait-until (lambda () (or relations failure)) 5
                                "real-Pi archive relations")
        (should (= 1 (length relations)))
        (should (eq 'resolved
                    (plist-get (car relations) :parent-resolution)))
        (let ((parent (plist-get (car relations) :related-session)))
          (should (equal "archive-parent" (plist-get parent :session-id)))
          (should (equal "Archive parent" (plist-get parent :display-title)))
          (should (eq 'none (plist-get parent :parent-resolution)))
          (should (= 1 (plist-get parent :child-count))))
        (let (switched)
          (cl-letf (((symbol-function 'pichat-session-for-directory)
                     (lambda (&optional _directory) session))
                    ((symbol-function 'pichat-sessions-switch-file)
                     (lambda (file cwd &optional _ready)
                       (setq switched (list file cwd)))))
            (pichat-consult-load-session
             (pichat-consult--relation-candidate
              (car relations) capability (car recent) nil)))
          (should (equal '("/fixture/sessions/archive-parent.jsonl"
                           "/fixture/project")
                         switched))))))

  (ert-deftest pichat-integration-custom-archive-fixture-does-not-advertise-marker ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-archive-custom-extension)
                 :script '(:turns []))
      (let* ((response (pichat-test-rpc-call session "get_commands"))
             (commands (plist-get (plist-get response :data) :commands)))
        (should (cl-find-if
                 (lambda (command)
                   (equal "pi-archive-custom-status" (plist-get command :name)))
                 commands))
        (should-not
         (cl-find-if
          (lambda (command)
            (equal "pi-archive-status-v1" (plist-get command :name)))
          commands)))))

  (ert-deftest pichat-integration-steer-follow-up-and-queue-modes-round-trip-through-pi ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns
                           [(:expectContextIncludes "initial prompt"
                             :text "initial" :delayMs 150)
                            (:expectContextIncludes "steer message" :text "steered")
                            (:expectContextIncludes "follow-up message" :text "followed")]))
      (pichat-test-rpc-call session "set_steering_mode" (list :mode "all"))
      (pichat-test-rpc-call session "set_follow_up_mode" (list :mode "one-at-a-time"))
      (let ((settled (pichat-test-count-raw-events session "agent_settled")))
        (pichat-test-rpc-call session "prompt" (list :message "initial prompt"))
        (pichat-test-wait-for-raw-event session "agent_start")
        (pichat-test-rpc-call session "steer" (list :message "steer message"))
        (pichat-test-rpc-call session "follow_up" (list :message "follow-up message"))
        (pichat-test-wait-for-raw-event session "agent_settled" 8 settled))
      (let* ((state (plist-get (pichat-test-rpc-call session "get_state") :data))
             (messages (plist-get (plist-get
                                   (pichat-test-rpc-call session "get_messages") :data)
                                  :messages))
             (users (mapcar #'pichat-render-message-text
                            (cl-remove-if-not
                             (lambda (message) (equal "user" (plist-get message :role)))
                             messages))))
        (should (equal "all" (plist-get state :steeringMode)))
        (should (equal "one-at-a-time" (plist-get state :followUpMode)))
        (should (equal '("initial prompt" "steer message" "follow-up message") users)))))

  (ert-deftest pichat-integration-simple-prompt-streams-through-real-pi ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:text ["hel" "lo"])]))
      (pichat-test-prompt-and-wait session "say hello")
      (let* ((response (pichat-test-rpc-call session "get_messages"))
             (messages (plist-get (plist-get response :data) :messages))
             (assistant (cl-find-if (lambda (message)
                                      (equal "assistant" (plist-get message :role)))
                                    messages))
             (content (plist-get assistant :content))
             (text-block (cl-find-if (lambda (block)
                                       (equal "text" (plist-get block :type)))
                                     content)))
        (should assistant)
        (should (equal "hello" (plist-get text-block :text))))))

  (ert-deftest pichat-integration-chat-renders-rpc-deltas-before-message-end ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:text ["hel" "lo"] :delayMs 150)]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "stream before end")
                (pichat-chat-send-input))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (let* ((node
                           (cl-find 'assistant
                                    (pichat-live-draft-nodes
                                     pichat-chat--live-draft)
                                    :key #'pichat-transcript-node-role))
                          (content (and node
                                        (pichat-transcript-node-content node)))
                          (prose (cl-find 'prose content
                                          :key #'pichat-transcript-content-kind)))
                     (and prose
                          (equal "hel"
                                 (pichat-transcript-content-text prose))))))
               8 "first real-Pi text delta before completion")
              (should-not
               (cl-some
                (lambda (event)
                  (and (equal "message_end" (plist-get event :type))
                       (equal "assistant"
                              (plist-get (plist-get event :message) :role))))
                (pichat-test-recent-rpc-events session)))
              (with-current-buffer buffer
                (pichat-chat--flush-live-projection))
              (should (string-match-p "hel" (pichat-test-buffer-text buffer)))
              (pichat-test-wait-for-raw-event session "agent_settled" 8)
              (let ((updates
                     (cl-remove-if-not
                      (lambda (event)
                        (equal "message_update" (plist-get event :type)))
                      (pichat-test-recent-rpc-events session))))
                (should (equal '("text_start" "text_delta" "text_delta"
                                 "text_end")
                               (mapcar
                                (lambda (event)
                                  (plist-get
                                   (plist-get event :assistantMessageEvent)
                                   :type))
                                updates)))
                ;; Pi 0.84's JSON boundary strips both cumulative snapshots.
                (when (string-match-p "0\\.84"
                                      (pichat-test-pi-version))
                  (should-not (cl-some
                               (lambda (event) (plist-member event :message))
                               updates))
                  (should-not
                   (cl-some
                    (lambda (event)
                      (plist-member (plist-get event :assistantMessageEvent)
                                    :partial))
                    updates)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-chat-send-input-renders-user-and-assistant ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:text ["hel" "lo"])]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "say hello")
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p (regexp-quote "say hello") text))
                  (should (string-match-p (regexp-quote "hello") text))
                  (should (pichat-chat--prompt-live-p))
                  (should (string-empty-p (pichat-chat--input-text))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-chat-image-attachment-reaches-real-pi-context ()
    (let* ((raw "phase-seven-image")
           (encoded (base64-encode-string raw t)))
      (pichat-test-with-integration-session
          (session :no-session t
                   :script (list :turns
                                 (vector
                                  (list :expectContextIncludes
                                        (vector "\"mimeType\":\"image/png\""
                                                encoded)
                                        :text "image received"))))
        (let ((pichat-chat-render-markdown nil)
              (pichat-chat-stop-session-on-kill nil)
              (path (expand-file-name "phase-seven.png" default-directory))
              buffer)
          (with-temp-file path (insert raw))
          (unwind-protect
              (progn
                (setq buffer (pichat-chat-open session))
                (with-current-buffer buffer
                  (pichat-chat-attach-image-file path)
                  (should (= 1 (length pichat-chat--pending-attachments))))
                (pichat-test-chat-send-and-wait
                 session buffer "describe attachment")
                (with-current-buffer buffer
                  (should-not pichat-chat--pending-attachments)
                  (should (zerop (hash-table-count
                                  pichat-chat--in-flight-attachments)))
                  (should-not (assq 'attachments pichat-chat--status-lines))
                  (should (string-match-p
                           "image received" (pichat-test-buffer-text buffer)))))
            (when (buffer-live-p buffer) (kill-buffer buffer)))))))

  (ert-deftest pichat-integration-chat-repeated-prompts-append-transcript ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:text "first answer") (:text "second answer")]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "first prompt")
              (pichat-test-chat-send-and-wait session buffer "second prompt")
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p (regexp-quote "first prompt") text))
                  (should (string-match-p (regexp-quote "first answer") text))
                  (should (string-match-p (regexp-quote "second prompt") text))
                  (should (string-match-p (regexp-quote "second answer") text))
                  (should (= 1 (pichat-test-count-substring "first prompt" text)))
                  (should (= 1 (pichat-test-count-substring "second prompt" text)))
                  (should (< (string-match-p (regexp-quote "first answer") text)
                             (string-match-p (regexp-quote "second prompt") text))))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-rejects-invalid-tool-definitions ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:expectToolAbsent "invalid tool" :text "safe")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'pichat-tool-bridge-definitions-json)
                         (lambda ()
                           "{\"protocolVersion\":1,\"tools\":[{\"name\":\"invalid tool\"}]}")))
                (pichat-test-prompt-and-wait session "validate tools"))
              (with-current-buffer buffer
                (should (equal "sync-error:invalid-tool-definition"
                               (gethash "pichat-bridge"
                                        pichat-chat--extension-statuses)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-refreshes-changed-tool-schema ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns
                           [(:expectTool
                             (:name "pichat-test-changing"
                              :parameters (:type "object"
                                           :properties (:value (:type "string"))))
                             :text "old")
                            (:expectTool
                             (:name "pichat-test-changing"
                              :parameters (:type "object"
                                           :properties (:value (:type "integer"))))
                             :text "new")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (pichat-define-tool pichat-test-changing
                  (:description "Changing schema"
                   :parameters (:type "object"
                                :properties (:value (:type "string"))))
                "old")
              (setq buffer (pichat-chat-open session))
              (pichat-test-prompt-and-wait session "old schema")
              (pichat-define-tool pichat-test-changing
                  (:description "Changing schema"
                   :parameters (:type "object"
                                :properties (:value (:type "integer"))))
                "new")
              (pichat-test-prompt-and-wait session "new schema")
              (with-current-buffer buffer
                (should (equal "synchronized:1"
                               (gethash "pichat-bridge"
                                        pichat-chat--extension-statuses)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-reports-versioned-synchronization-health ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-rpc-call session "prompt"
                                    (list :message "/pichat-sync-tools"))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (equal "synchronized:0"
                          (gethash "pichat-bridge"
                                   pichat-chat--extension-statuses))))
               3 "versioned bridge synchronization health"))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-rejects-incompatible-protocol-version ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            (original (symbol-function 'pichat-bridge-transport-handle))
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'pichat-bridge-transport-handle)
                         (lambda (s raw)
                           (if (equal pichat-bridge-transport-handshake-title
                                      (plist-get raw :title))
                               (progn
                                 (pichat-rpc-extension-ui-value
                                  s (plist-get raw :id)
                                  "{\"protocolVersion\":999}")
                                 t)
                             (funcall original s raw)))))
                (pichat-test-rpc-call session "prompt"
                                      (list :message "/pichat-sync-tools")))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (equal "incompatible-protocol"
                          (gethash "pichat-bridge"
                                   pichat-chat--extension-statuses))))
               3 "bridge protocol rejection"))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-preserves-emacs-tool-schema ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:expectTool
                                    (:name "pichat-test-schema"
                                     :parameters
                                     (:type "object"
                                      :properties (:value (:type "string" :minLength 2))
                                      :required ["value"]
                                      :additionalProperties :json-false))
                                    :text "schema observed")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (pichat-define-tool pichat-test-schema
            (:label "Schema Test"
             :description "Validate exact bridge schema preservation"
             :parameters (:type "object"
                          :properties (:value (:type "string" :minLength 2))
                          :required ["value"]
                          :additionalProperties :json-false))
          "unused")
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-prompt-and-wait session "inspect tool schema")
              (let* ((response (pichat-test-rpc-call session "get_messages"))
                     (messages (plist-get (plist-get response :data) :messages)))
                (should (string-match-p "schema observed" (format "%S" messages)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-deactivates-stale-tools-on-resync ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:expectTool (:name "pichat-test-stale")
                                    :text "tool active")
                                   (:expectToolAbsent "pichat-test-stale"
                                    :text "tool inactive")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (pichat-define-tool pichat-test-stale
            (:label "Stale Test" :description "Tool removed between prompts")
          "unused")
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-prompt-and-wait session "first sync")
              (remhash "pichat-test-stale" pichat-tools-registry)
              (pichat-test-prompt-and-wait session "second sync")
              (let* ((response (pichat-test-rpc-call session "get_messages"))
                     (messages (plist-get (plist-get response :data) :messages))
                     (rendered (format "%S" messages)))
                (should (string-match-p "tool active" rendered))
                (should (string-match-p "tool inactive" rendered))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-tool-errors-become-pi-tool-errors ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:toolCall (:id "error-1"
                                               :name "pichat-test-error"
                                               :arguments ()))
                                   (:expectToolResultError "pichat-test-error"
                                    :expectContextIncludes "intentional Emacs failure"
                                    :text "failure observed")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (pichat-define-tool pichat-test-error
            (:label "Error Test" :description "Always fail in Emacs")
          (error "intentional Emacs failure"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-prompt-and-wait session "call failing tool")
              (let* ((response (pichat-test-rpc-call session "get_messages"))
                     (messages (plist-get (plist-get response :data) :messages))
                     (tool-result (cl-find-if
                                   (lambda (message)
                                     (and (equal "toolResult" (plist-get message :role))
                                          (equal "pichat-test-error" (plist-get message :toolName))))
                                   messages)))
                (should tool-result)
                (should (plist-get tool-result :isError))
                (should (string-match-p "intentional Emacs failure"
                                        (format "%S" (plist-get tool-result :content))))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-emacs-tool-result-reaches-next-provider-turn ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:toolCall (:id "tool-1"
                                               :name "pichat-test-echo"
                                               :arguments (:value "bridge")))
                                   (:expectContextIncludes "echoed: bridge"
                                    :text "tool result observed")]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (pichat-define-tool pichat-test-echo
            (:label "Test Echo"
             :description "Echo a value from Emacs for PiChat integration tests"
             :parameters (:type "object" :properties (:value (:type "string")) :required ["value"]))
          (format "echoed: %s" (plist-get params :value)))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "call emacs tool")
              (let* ((response (pichat-test-rpc-call session "get_messages"))
                     (messages (plist-get (plist-get response :data) :messages))
                     (tool-result (cl-find-if
                                   (lambda (message)
                                     (and (equal "toolResult" (plist-get message :role))
                                          (equal "pichat-test-echo" (plist-get message :toolName))))
                                   messages)))
                (should tool-result)
                (should (string-match-p
                         (regexp-quote "echoed: bridge")
                         (format "%S" (plist-get tool-result :content)))))
              (with-current-buffer buffer
                (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                  (should (string-match-p (regexp-quote "call emacs tool") text))
                  (should (string-match-p (regexp-quote "pichat-test-echo") text))
                  (should (string-match-p (regexp-quote "tool result observed") text)))))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-bridge-denied-mutating-tool-does-not-execute ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-bridge-extension)
                 :script '(:turns [(:toolCall (:id "mutate-1"
                                               :name "pichat-test-mutate"
                                               :arguments (:value "blocked")))
                                   (:expectContextIncludes "Denied by user"
                                    :text "denial observed")]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            (pichat-approval-policy-file (expand-file-name "approvals.el" project-dir))
            (executions 0)
            buffer)
        (setq pichat-approval-rules '(("pichat-test-mutate" . deny)))
        (pichat-approval-save)
        (pichat-define-tool pichat-test-mutate
            (:label "Test Mutate"
             :description "A mutating tool that must not run when denied"
             :mutating t
             :parameters (:type "object" :properties (:value (:type "string")) :required ["value"]))
          (cl-incf executions)
          (format "mutated: %s" (plist-get params :value)))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "try mutation")
              (should (= 0 executions))
              (let* ((response (pichat-test-rpc-call session "get_messages"))
                     (messages (plist-get (plist-get response :data) :messages))
                     (tool-result (cl-find-if
                                   (lambda (message)
                                     (and (equal "toolResult" (plist-get message :role))
                                          (equal "pichat-test-mutate" (plist-get message :toolName))))
                                   messages)))
                (should tool-result)
                (should (string-match-p
                         (regexp-quote "Denied by user")
                         (format "%S" (plist-get tool-result :content)))))
              (pichat-test-wait-for-buffer-contains buffer "denial observed"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-abort-active-prompt-settles-session ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:delayMs 1000 :text ["slow" " response"])]))
      (pichat-test-rpc-call session "prompt" (list :message "slow prompt"))
      (pichat-test-wait-for-raw-event session "agent_start")
      (pichat-test-rpc-call session "abort")
      (pichat-test-wait-for-raw-event session "agent_settled")
      (should (eq (pichat-session-state session) 'idle))))

  (ert-deftest pichat-integration-successful-retry-remains-running-until-settled ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:error "WebSocket error")
                                   (:text "recovered")]))
      (let (retry-end-state settled-state)
        (pichat-on 'retry-end
                   (lambda (event-session _event _plist)
                     (setq retry-end-state
                           (pichat-session-state event-session)))
                   session)
        (pichat-on 'agent-settled
                   (lambda (event-session _event _plist)
                     (setq settled-state
                           (pichat-session-state event-session)))
                   session)
        (pichat-test-rpc-call session "set_auto_retry" (list :enabled t))
        (pichat-test-prompt-and-wait session "retry once" 10)
        (should (eq retry-end-state 'running))
        (should (eq settled-state 'idle))
        (should (eq (pichat-session-state session) 'idle)))))

  (ert-deftest pichat-integration-provider-error-is-recorded-in-session-messages ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:error "fake provider failed")]))
      (pichat-test-prompt-and-wait session "fail provider")
      (let* ((response (pichat-test-rpc-call session "get_messages"))
             (messages (plist-get (plist-get response :data) :messages))
             (assistant (cl-find-if (lambda (message)
                                      (equal "assistant" (plist-get message :role)))
                                    messages)))
        (should assistant)
        (should (equal "error" (plist-get assistant :stopReason)))
        (should (equal "fake provider failed" (plist-get assistant :errorMessage))))))

  (ert-deftest pichat-integration-session-persistence-uses-isolated-session-dir ()
    (pichat-test-with-integration-session
        (session :script '(:turns [(:text "persisted")]))
      (pichat-test-prompt-and-wait session "persist this")
      (pichat-test-rpc-call session "get_state")
      (let ((session-file (pichat-session-session-file session)))
        (should (stringp session-file))
        (should (file-exists-p session-file))
        (should (file-in-directory-p session-file session-dir)))))

  (ert-deftest pichat-integration-extension-input-request-responds-and-renders-notify ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _args) "typed value")))
                (pichat-test-rpc-call session "prompt" (list :message "/pichat-test-input")))
              (pichat-test-wait-for-buffer-contains buffer "[extension info]\ninput:typed value"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-extension-input-waits-for-owning-chat-selection ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            (other (generate-new-buffer " *pichat-integration-unrelated*"))
            buffer response
            (reader-calls 0))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (switch-to-buffer other)
              (cl-letf (((symbol-function 'read-string)
                         (lambda (&rest _args)
                           (cl-incf reader-calls)
                           "deferred value")))
                (pichat-rpc-send
                 session "prompt" (list :message "/pichat-test-input")
                 (lambda (value _session) (setq response value)))
                (pichat-test-wait-until
                 (lambda ()
                   (= 1 (pichat-chat-pending-user-input-count session)))
                 3 "background extension input request")
                (should (= 0 reader-calls))
                (should (string-suffix-p
                         "!"
                         (substring-no-properties
                          (pichat-session-manager--status-label session))))
                (switch-to-buffer buffer)
                (with-current-buffer buffer
                  (pichat-chat--maybe-start-next-ui-request session))
                (pichat-test-wait-for-buffer-contains
                 buffer "[extension info]\ninput:deferred value")
                (pichat-test-wait-until
                 (lambda () response) 3 "deferred command response")
                (should (= 1 reader-calls))
                (should (zerop
                         (pichat-chat-pending-user-input-count session)))
                (should-not
                 (string-suffix-p
                  "!"
                  (substring-no-properties
                   (pichat-session-manager--status-label session))))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (buffer-live-p other) (kill-buffer other))))))

  (ert-deftest pichat-integration-extension-dialog-cancels-through-real-pi-on-buffer-death ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer response)
        (setq buffer (pichat-chat-open session))
        (pichat-rpc-send
         session "prompt" (list :message "/pichat-test-input")
         (lambda (value _session) (setq response value)))
        (pichat-test-wait-until
         (lambda ()
           (cl-find-if
            (lambda (event)
              (and (equal "extension_ui_request" (plist-get event :type))
                   (equal "input" (plist-get event :method))))
            (pichat-session-event-log session)))
         3 "real Pi extension input request")
        (kill-buffer buffer)
        (pichat-test-wait-until (lambda () response) 3 "cancelled command response")
        (should (plist-get response :success))
        (pichat-test-wait-until
         (lambda ()
           (cl-find-if
            (lambda (event)
              (and (equal "extension_ui_request" (plist-get event :type))
                   (equal "notify" (plist-get event :method))
                   (equal "input:<cancelled>" (plist-get event :message))))
            (pichat-session-event-log session)))
         3 "extension observed buffer-death cancellation"))))

  (ert-deftest pichat-integration-extension-confirm-request-responds-and-renders-notify ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _args) t)))
                (pichat-test-rpc-call session "prompt" (list :message "/pichat-test-confirm")))
              (pichat-test-wait-for-buffer-contains buffer "[extension info]\nconfirm:yes"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-extension-editor-request-responds-and-renders-notify ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'read-from-minibuffer)
                         (lambda (&rest _args) "edited text")))
                (pichat-test-rpc-call session "prompt" (list :message "/pichat-test-editor")))
              (pichat-test-wait-for-buffer-contains buffer "[extension info]\neditor:edited text"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-extension-select-request-responds-and-renders-notify ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _args) "beta")))
                (pichat-test-rpc-call session "prompt" (list :message "/pichat-test-select")))
              (pichat-test-wait-for-buffer-contains buffer "[extension info]\nselect:beta"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-extension-fire-and-forget-ui-updates-chat-state ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-rpc-call session "prompt"
                                    (list :message "/pichat-test-fire-ui"))
              (pichat-test-wait-for-buffer-contains buffer "[extension info]\nfire-ui:done")
              (with-current-buffer buffer
                (should (equal "PiChat extension title" pichat-chat--extension-title))
                (should (gethash "pichat-test" pichat-chat--extension-widgets))
                (should (string-match-p "widget line one"
                                        (pichat-test-buffer-text buffer)))
                (should (equal "extension draft" (pichat-chat--input-text)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-extension-status-request-updates-chat-state ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-rpc-call session "prompt" (list :message "/pichat-test-status"))
              (pichat-test-wait-for-buffer-contains buffer "[status:pichat-test] working")
              (with-current-buffer buffer
                (should (equal "working"
                               (gethash "pichat-test" pichat-chat--extension-statuses)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-notify-only-extension-command-restores-chat-prompt ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (eq pichat-chat-completion--status 'ready)))
               nil "extension command discovery")
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "/pichat-test-status")
                (pichat-chat-send-input)
                (should-not (pichat-chat--prompt-live-p)))
              (pichat-test-wait-for-buffer-contains
               buffer "[extension info]\nstatus:set")
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (pichat-chat--prompt-live-p)))
               nil "prompt restored after notify-only extension command")
              (with-current-buffer buffer
                (should (string-empty-p (pichat-chat--input-text)))
                (should-not
                 (cl-find-if
                  (lambda (event)
                    (equal "agent_settled" (plist-get event :type)))
                  (pichat-session-event-log session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-command-discovery-lists-extension-command ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let* ((response (pichat-test-rpc-call session "get_commands"))
             (commands (plist-get (plist-get response :data) :commands)))
        (should (cl-find-if (lambda (cmd)
                              (equal "pichat-test-input" (plist-get cmd :name)))
                            commands)))))

  (ert-deftest pichat-integration-slash-completion-refreshes-from-pi ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :extensions (list pichat-test-rpc-extension)
                 :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-wait-until
               (lambda ()
                 (with-current-buffer buffer
                   (memq pichat-chat-completion--status '(ready failed))))
               nil "slash-command refresh")
              (with-current-buffer buffer
                (should (eq 'ready pichat-chat-completion--status))
                (should (cl-find-if
                         (lambda (command)
                           (equal "pichat-test-input"
                                  (plist-get command :name)))
                         pichat-chat-completion--commands))
                (goto-char (point-max))
                (insert "/pichat-test-i")
                (let ((capf (pichat-chat--slash-command-capf)))
                  (should capf)
                  (should (member "pichat-test-input"
                                  (all-completions
                                   "pichat-test-i" (nth 2 capf)))))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-thinking-controls-use-supported-levels ()
    (pichat-test-with-integration-session
        (session :no-session t :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (let ((status (pichat-chat--mode-line-status)))
                  (should (string-match-p "pichat-fake" status))
                  (should-not (string-match-p "pichat-fake\\." status))))
              (pichat-test-rpc-call
               session "set_model"
               (list :provider "pichat-fake"
                     :modelId "pichat-fake-reasoning"))
              (pichat-test-rpc-call session "get_state")
              (let* ((levels
                      (pichat-chat--model-thinking-levels
                       (pichat-session-model session)))
                     (before (pichat-session-thinking-level session))
                     (next (nth (mod (1+ (cl-position before levels :test #'equal))
                                     (length levels))
                                levels)))
                (should (equal '("off" "low" "high" "max") levels))
                (with-current-buffer buffer
                  (let* ((status (pichat-chat--mode-line-status))
                         (suffix (concat "."
                                         (pichat-chat--compact-thinking-level
                                          before)))
                         (pos (string-match (regexp-quote suffix) status))
                         (command
                          (and pos
                               (lookup-key
                                (get-text-property pos 'local-map status)
                                [mode-line mouse-1]))))
                    (should command)
                    (funcall command nil)))
                (pichat-test-wait-until
                 (lambda ()
                   (equal next (pichat-session-thinking-level session)))
                 nil "mode-line thinking cycle state refresh")
                (with-current-buffer buffer
                  (should
                   (string-match-p
                    (regexp-quote
                     (concat "pichat-fake-reasoning."
                             (pichat-chat--compact-thinking-level next)))
                    (pichat-chat--mode-line-status))))))
              (with-current-buffer buffer
                (pichat-chat-set-thinking-level "max"))
              (pichat-test-wait-until
               (lambda ()
                 (equal "max" (pichat-session-thinking-level session)))
               nil "direct thinking selection state refresh")
              (with-current-buffer buffer
                (should (string-match-p "pichat-fake-reasoning\\.MAX"
                                        (pichat-chat--mode-line-status))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-model-selection-session-name-and-stats-round-trip ()
    (pichat-test-with-integration-session
        (session :script '(:turns []))
      (pichat-test-rpc-call session "set_model"
                            (list :provider "pichat-fake" :modelId "pichat-fake"))
      (pichat-test-rpc-call session "set_session_name" (list :name "Retirement Test"))
      (let* ((state-response (pichat-test-rpc-call session "get_state"))
             (state (plist-get state-response :data))
             (stats-response (pichat-test-rpc-call session "get_session_stats")))
        (should (equal "pichat-fake" (plist-get (plist-get state :model) :id)))
        (should (equal "Retirement Test" (plist-get state :sessionName)))
        (should (plist-get stats-response :success))
        (should (equal "Retirement Test" (pichat-session-name session))))))

  (ert-deftest pichat-integration-model-list-and-thinking-level-use-fake-model ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns []))
      (let* ((models-response (pichat-test-rpc-call session "get_available_models"))
             (models (plist-get (plist-get models-response :data) :models)))
        (should (cl-find-if (lambda (model)
                              (and (equal "pichat-fake" (plist-get model :provider))
                                   (equal "pichat-fake" (plist-get model :id))))
                            models))
        ;; Pi 0.84 serves and validates models from the same cache snapshot.
        (dolist (model models)
          (should
           (plist-get
            (pichat-test-rpc-call
             session "set_model"
             (list :provider (plist-get model :provider)
                   :modelId (plist-get model :id)))
            :success)))
        (pichat-test-rpc-call
         session "set_model"
         (list :provider "pichat-fake" :modelId "pichat-fake")))
      (pichat-test-rpc-call session "set_thinking_level" (list :level "high"))
      (let* ((state-response (pichat-test-rpc-call session "get_state"))
             (state (plist-get state-response :data)))
        ;; The fake model declares no reasoning support, so Pi clamps thinking off.
        (should (equal "off" (plist-get state :thinkingLevel))))))

  (ert-deftest pichat-integration-reference-text-reaches-fake-provider-context ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :script '(:turns [(:expectContextIncludes ["References for the Pi agent to inspect:"
                                                            "sample.el"
                                                            "What does this code do?"]
                                   :text "reference observed")]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer source-buffer source-file)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (setq source-file (expand-file-name "sample.el" project-dir))
              (with-temp-file source-file
                (insert "(defun sample ()\n  42)\n"))
              (setq source-buffer (find-file-noselect source-file))
              (with-current-buffer source-buffer
                (goto-char (point-min))
                (set-mark (point-max))
                (setq mark-active t)
                (let ((pichat-current-session session))
                  (pichat-add-reference nil)))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "What does this code do?"))
              (pichat-test-chat-send-current-and-wait session buffer)
              (pichat-test-wait-for-buffer-contains buffer "reference observed"))
          (when (buffer-live-p source-buffer)
            (kill-buffer source-buffer))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))))))

  (ert-deftest pichat-integration-tree-display-fork-clone-and-saved-switch ()
    (pichat-test-with-integration-session
        (session :script '(:turns [(:text "branch answer")
                                   (:expectContextIncludes "fork work"
                                    :text "fork answer")]))
      (pichat-test-prompt-and-wait session "branch prompt")
      (let* ((state (plist-get (pichat-test-rpc-call session "get_state") :data))
             (original-file (plist-get state :sessionFile))
             (entries (plist-get (plist-get
                                  (pichat-test-rpc-call session "get_entries") :data)
                                 :entries))
             (user-entry (cl-find-if
                          (lambda (entry)
                            (and (equal "message" (plist-get entry :type))
                                 (equal "user"
                                        (plist-get (plist-get entry :message) :role))))
                          entries))
             (tree-response (pichat-test-rpc-call session "get_tree"))
             (tree-buffer (generate-new-buffer " *pichat-tree-test*"))
             clone-file fork-file chat-buffer)
        (unwind-protect
            (progn
              (pichat-sessions--refresh-from-response tree-response session tree-buffer)
              (with-current-buffer tree-buffer
                (should (> (length pichat-sessions--visible-rows) 0))
                (should (text-property-not-all
                         (point-min) (point-max)
                         'pichat-session-entry-id nil)))
              (pichat-test-rpc-call session "clone")
              (setq clone-file
                    (plist-get (plist-get (pichat-test-rpc-call session "get_state") :data)
                               :sessionFile))
              (should (file-exists-p clone-file))
              (should-not (equal original-file clone-file))
              (pichat-test-rpc-call session "switch_session"
                                    (list :sessionPath original-file))
              (pichat-test-rpc-call session "fork"
                                    (list :entryId (plist-get user-entry :id)))
              (setq fork-file
                    (plist-get (plist-get (pichat-test-rpc-call session "get_state") :data)
                               :sessionFile))
              (pichat-test-prompt-and-wait session "fork work")
              (should (file-exists-p fork-file))
              (should-not (member fork-file (list original-file clone-file)))
              (pichat-test-rpc-call session "switch_session"
                                    (list :sessionPath original-file))
              (pichat-test-rpc-call session "get_state")
              (let ((pichat-chat-stop-session-on-kill nil))
                (setq chat-buffer (pichat-chat-open session))
                (with-current-buffer chat-buffer (pichat-chat-repaint))
                (pichat-test-wait-for-buffer-contains chat-buffer "branch answer")))
          (when (buffer-live-p tree-buffer) (kill-buffer tree-buffer))
          (when (buffer-live-p chat-buffer) (kill-buffer chat-buffer))))))

  (ert-deftest pichat-integration-manual-run-local-model-is-managed-file-free-and-not-global ()
    (pichat-test-require-pi)
    (pichat-test-with-clean-state
      (pichat-test-with-temp-dir project-dir
        (pichat-test-with-temp-dir agent-dir
          (pichat-test-with-temp-dir session-dir
            (let* ((manual-model "pichat-fake/vendor/unlisted-model")
                   (script-file
                    (expand-file-name "fake-provider-script.json" project-dir))
                   (status-file
                    (expand-file-name "fake-provider-status.json" project-dir))
                   (settings-file (expand-file-name "settings.json" agent-dir))
                   (process-environment
                    (append
                     (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1"
                           "PI_TELEMETRY=0"
                           (concat "PI_CODING_AGENT_DIR=" agent-dir)
                           (concat "PI_CODING_AGENT_SESSION_DIR=" session-dir)
                           (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" script-file)
                           (concat "PICHAT_FAKE_PROVIDER_STATUS=" status-file))
                     process-environment))
                   (pichat-rpc-command nil)
                   (pichat-pi-executable pichat-test-pi-executable)
                   (pichat-pi-default-args
                    '("--mode" "rpc" "--offline" "--no-approve"
                      "--no-builtin-tools" "--no-context-files" "--no-skills"
                      "--no-prompt-templates" "--no-themes" "--no-extensions"))
                   (pichat-default-model nil)
                   (pichat-pi-session-dir session-dir)
                   (pichat-bridge-extension-file nil)
                   (pichat-pi-extra-args
                    (list "-e" pichat-test-fake-provider-extension))
                   (scope (list (concat "project:" project-dir)
                                project-dir "ephemeral@test"))
                   session)
              (with-temp-file script-file
                (insert
                 (json-serialize '(:turns [(:text "ephemeral reply")])
                                 :false-object :json-false :null-object nil)))
              (with-temp-file settings-file
                (insert
                 (json-serialize
                  '(:defaultProvider "sentinel-provider"
                    :defaultModel "sentinel-model")
                  :false-object :json-false :null-object nil)))
              (unwind-protect
                  (let ((default-directory project-dir))
                    (cl-letf (((symbol-function 'completing-read)
                               (lambda (_prompt choices _predicate require-match
                                        &rest _args)
                                 (should-not require-match)
                                 (should-not (assoc manual-model choices))
                                 manual-model))
                              ((symbol-function 'pichat-rpc-set-model)
                               (lambda (&rest _args)
                                 (ert-fail "manual launch used RPC set_model"))))
                      (should-not
                       (pichat--open-launch-profile
                        (list :scope scope :reuse 'new
                              :persistence 'ephemeral :model 'prompt
                              :display-function #'ignore)
                        project-dir))
                      (pichat-test-wait-until
                       (lambda ()
                         (cl-find-if
                          (lambda (candidate)
                            (equal manual-model
                                   (pichat-session-startup-model candidate)))
                          (pichat-session-list)))
                       10 "run-local selected-model runtime")
                      (setq session
                            (cl-find-if
                             (lambda (candidate)
                               (equal manual-model
                                      (pichat-session-startup-model candidate)))
                             (pichat-session-list)))
                    (let* ((state-response
                            (pichat-test-rpc-call session "get_state"))
                           (model (plist-get (plist-get state-response :data)
                                             :model)))
                      (should (equal "pichat-fake" (plist-get model :provider)))
                      (should (equal "vendor/unlisted-model"
                                     (plist-get model :id))))
                    (pichat-test-rpc-call
                     session "set_auto_retry" (list :enabled :json-false))
                    (pichat-test-rpc-call
                     session "set_auto_compaction" (list :enabled :json-false))
                    (should (= 1 (cl-count "--no-session"
                                           (pichat-session-rpc-command session)
                                           :test #'equal)))
                    (should (= 1 (cl-count "--model"
                                           (pichat-session-rpc-command session)
                                           :test #'equal)))
                    (should (equal (list "--model" manual-model)
                                   (last (pichat-session-rpc-command session) 2)))
                    (should (equal manual-model
                                   (pichat-session-startup-model session)))
                    (should (eq 'ephemeral
                                (pichat-session-persistence session)))
                    (should (eq session
                                (pichat-session-by-runtime-id
                                 (pichat-session-runtime-id session))))
                    (pichat-test-prompt-and-wait session "ephemeral prompt")
                    (pichat-test-rpc-call session "get_state")
                    (should-not (pichat-session-session-file session))
                    (should-not
                     (directory-files session-dir nil
                                      directory-files-no-dot-files-regexp))
                    (pichat-test-assert-provider-script-consumed status-file)
                    (let ((settings
                           (with-temp-buffer
                             (insert-file-contents settings-file)
                             (json-parse-buffer
                              :object-type 'plist :array-type 'list
                              :null-object nil :false-object nil))))
                      (should (equal "sentinel-provider"
                                     (plist-get settings :defaultProvider)))
                      (should (equal "sentinel-model"
                                     (plist-get settings :defaultModel))))
                    (pichat-rpc-stop session)
                    (pichat-forget-session session)
                    (should-not
                     (pichat-session-by-runtime-id
                      (pichat-session-runtime-id session)))))
                (when session
                  (ignore-errors (pichat-rpc-stop session))
                  (ignore-errors (pichat-forget-session session))))))))))

  (ert-deftest pichat-integration-new-session-and-switch-repaints-from-persisted-session ()
    (pichat-test-with-integration-session
        (session :script '(:turns [(:text "before switch")]))
      (let ((pichat-chat-render-markdown nil)
            (pichat-chat-stop-session-on-kill nil)
            buffer old-file)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer "old prompt")
              (setq old-file (pichat-session-session-file session))
              (pichat-test-rpc-call session "new_session")
              (pichat-test-rpc-call session "get_state")
              (should-not (equal old-file (pichat-session-session-file session)))
              (pichat-test-rpc-call session "switch_session" (list :sessionPath old-file))
              (pichat-test-rpc-call session "get_state")
              (with-current-buffer buffer
                (pichat-chat-repaint))
              (pichat-test-wait-for-buffer-contains buffer "old prompt")
              (pichat-test-wait-for-buffer-contains buffer "before switch"))
          (when (buffer-live-p buffer)
            (kill-buffer buffer)))))))

(provide 'pichat-test-integration)
;;; pichat-test-integration.el ends here
