;;; pichat-test-compaction-characterization.el --- Current Pi transfer probes -*- lexical-binding: t; -*-

;; Characterization only: these tests describe current behavior, not the planned
;; held-message feature.  No real provider or normal user state is used.
(require 'pichat-test-support)

(when pichat-test-include-integration
  (defconst pichat-test-compaction-image
    '(:id "probe-image" :type "image" :mimeType "image/png"
      :data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
      :name "probe.png" :bytes 68))

  (ert-deftest pichat-integration-characterize-manual-compaction-input-paths ()
    (dolist (outcome '(success failure abort))
        (ert-info ((format "manual / %s" outcome))
          (pichat-test-with-integration-session
              (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                       :script (list :turns
                                     (vector '(:text "h1") '(:text "h2")
                                             (if (eq outcome 'failure)
                                                 '(:error "probe summary failed" :delayMs 1500)
                                               '(:text "summary" :delayMs 1500)))))
            (pichat-test-prompt-and-wait session (concat "one " (make-string 2000 ?a)))
            (pichat-test-prompt-and-wait session (concat "two " (make-string 2000 ?b)))
            (let ((pichat-chat-stop-session-on-kill nil)
                  (buffer (pichat-chat-open session)))
              (unwind-protect
                  (progn
                    (with-current-buffer buffer
                      (pichat-chat-compact ""))
                    (let ((start (pichat-test-wait-for-raw-event session "compaction_start")))
                      (message "PROBE start manual/%s: %S" outcome start)
                      (should (equal '(:type "compaction_start" :reason "manual") start)))
                    (let ((state (plist-get (pichat-test-rpc-call session "get_state") :data)))
                      (should (plist-get state :isCompacting))
                      (should-not (plist-get state :isStreaming)))
                    ;; Characterize Pi directly now that the chat commands
                    ;; hold instead of invoking these rejected/stranded paths.
                    (with-current-buffer buffer
                      (pichat-test-set-draft "RET during compact")
                      (setq pichat-chat--pending-attachments (list pichat-test-compaction-image)))
                    (let (refused)
                      (pichat-rpc-prompt session "RET during compact"
                                        (pichat-attachments-wire-images (list pichat-test-compaction-image)) nil
                                        #'ignore (lambda (r _s) (setq refused r)))
                      (pichat-test-wait-until (lambda () refused) 3 "ordinary prompt refusal")
                      (should (string-match-p "compaction is in progress" (plist-get refused :error))))
                    (pichat-rpc-steer session "steer during compact")
                    ;; Barrier: every earlier command on the same stdin has run.
                    (pichat-test-rpc-call session "get_state")
                    (let (refused)
                      (pichat-rpc-prompt session "direct followUp during compact"
                                         (pichat-attachments-wire-images (list pichat-test-compaction-image)) "followUp"
                                         #'ignore (lambda (r _s) (setq refused r)))
                      (pichat-test-wait-until (lambda () refused) 3 "followUp refusal")
                      (should (string-match-p "compaction is in progress" (plist-get refused :error)))
                    (should (equal "queued" (plist-get (plist-get
                             (pichat-test-rpc-call session "follow_up"
                               (list :message "queue-only during compact"
                                     :images (pichat-attachments-wire-images (list pichat-test-compaction-image))))
                             :data) :disposition)))
                    (message "PROBE queue: %S"
                             (car (last (cl-remove-if-not
                                         (lambda (e) (equal "queue_update" (plist-get e :type)))
                                         (pichat-test-recent-rpc-events session)))))
                    (let ((cleared (plist-get (pichat-test-rpc-call session "clear_queue") :data)))
                      (message "PROBE clear: %S" cleared)
                      (should (equal '(:steering ("steer during compact")
                                       :followUp ("queue-only during compact")) cleared)))
                    (when (eq outcome 'abort) (pichat-test-rpc-call session "abort"))
                    (let ((end (pichat-test-wait-for-raw-event session "compaction_end" 8)))
                      (message "PROBE end manual/%s: %S" outcome end)
                      (should (equal "manual" (plist-get end :reason)))
                      (pcase outcome
                        ('success (should (plist-get end :result)))
                        ('failure (should (string-match-p "probe summary failed" (plist-get end :errorMessage))))
                        ('abort (should (plist-get end :aborted)))))
                    (dolist (user (pichat-test-compaction-users session))
                      (should-not (string-match-p "during compact" (pichat-render-message-text user))))
                    (with-current-buffer buffer
                      ;; Direct RPC probes do not consume the chat draft.
                      (should-not pichat-chat--recoverable-submissions)
                      (should (equal "RET during compact" (pichat-chat--input-text)))
                      (should (equal (list pichat-test-compaction-image)
                                     pichat-chat--pending-attachments)))))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))))

  (ert-deftest pichat-integration-characterize-prompt-followup-transfer-order ()
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :no-session t
                   :script (list :turns
                                 (vconcat
                                  '((:text "first reply" :delayMs 600))
                                  (if (equal mode "all")
                                      '((:text "combined reply" :expectContextIncludes ["second held" "third held"]))
                                    '((:text "second reply" :expectContextIncludes "second held")
                                      (:text "third reply" :expectContextIncludes "third held"))))))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (should (equal "started" (plist-get (plist-get
                  (pichat-test-rpc-call session "prompt" '(:message "first held")) :data) :disposition)))
        ;; Acknowledgment alone is not evidence of streaming (see chain probe).
        (pichat-test-wait-for-raw-event session "agent_start")
        (dolist (text '("second held" "third held"))
          (should (equal "queued" (plist-get (plist-get
                    (pichat-test-rpc-call session "prompt"
                      (list :message text :images (pichat-attachments-wire-images
                                               (list pichat-test-compaction-image))
                            :streamingBehavior "followUp")) :data) :disposition))))
        (message "PROBE transfer queue %s: %S" mode
                 (car (last (cl-remove-if-not
                             (lambda (e) (equal "queue_update" (plist-get e :type)))
                             (pichat-test-recent-rpc-events session)))))
        (pichat-test-wait-for-raw-event session "agent_settled" 8)
        (let ((users (pichat-test-compaction-users session)))
          (should (equal '("first held" "second held[image]" "third held[image]")
                         (mapcar #'pichat-render-message-text users)))
          (dolist (user (cdr users))
            (should (cl-find "image" (plist-get user :content)
                             :key (lambda (c) (plist-get c :type)) :test #'equal)))))))

  (ert-deftest pichat-integration-characterize-slash-compact-is-an-ordinary-prompt ()
    (pichat-test-with-integration-session
        (session :no-session t :script '(:turns [(:text "ordinary reply" :expectContextIncludes "/compact")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            (buffer (pichat-chat-open session)))
        (unwind-protect
            (progn
              (with-current-buffer buffer
                (setq pichat-chat--pending-attachments (list pichat-test-compaction-image)))
              (pichat-test-chat-send-and-wait session buffer "/compact")
              (should (= 0 (pichat-test-count-raw-events session "compaction_start")))
              (should (equal '("/compact[image]") (mapcar #'pichat-render-message-text
                                                    (pichat-test-compaction-users session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))
  (ert-deftest pichat-integration-characterize-busy-ret-and-clear-queue-images ()
    (pichat-test-with-integration-session
        (session :no-session t :script '(:turns [(:text "busy reply" :delayMs 1200)]))
      (let ((pichat-chat-stop-session-on-kill nil)
            (buffer (pichat-chat-open session)))
        (unwind-protect
            (progn
              (pichat-test-rpc-call session "prompt" '(:message "busy"))
              (pichat-test-wait-for-raw-event session "agent_start")
              ;; Characterize Pi's ordinary busy-prompt refusal directly.
              ;; PiChat RET now deliberately supplies followUp instead.
              (let (refused)
                (pichat-rpc-prompt
                 session "RET while busy"
                 (pichat-attachments-wire-images (list pichat-test-compaction-image)) nil
                 #'ignore (lambda (response _session) (setq refused response)))
                (pichat-test-wait-until (lambda () refused) 3 "busy prompt refusal")
                (should (stringp (plist-get refused :error))))
              (dolist (command '("follow_up" "steer" "follow_up"))
                (pichat-test-rpc-call session command
                  (list :message command :images (pichat-attachments-wire-images
                                                  (list pichat-test-compaction-image)))))
              (let ((queue (pichat-test-wait-for-raw-event session "queue_update" 3 2))
                    (clear (plist-get (pichat-test-rpc-call session "clear_queue") :data)))
                (message "PROBE image queue=%S clear=%S" queue clear)
                (should (equal '("steer") (plist-get queue :steering)))
                (should (equal '("follow_up" "follow_up") (plist-get queue :followUp)))
                (should (equal '(:steering ("steer") :followUp ("follow_up" "follow_up")) clear)))
              (pichat-test-wait-for-raw-event session "agent_settled" 8)
              (should (equal '("busy") (mapcar #'pichat-render-message-text
                                                (pichat-test-compaction-users session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-characterize-auto-compaction-events ()
    (dolist (reason '(threshold overflow))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:enabled t :reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (if (eq reason 'threshold)
                                     [(:text "h1" :usage (:input 500 :output 20))
                                      (:text "h2" :usage (:input 127500 :output 20))
                                      (:text "summary" :delayMs 600)]
                                   [(:text "h1") (:text "h2")
                                    (:error "maximum context length exceeded")
                                    (:text "summary" :delayMs 600)
                                    (:text "after overflow")])))
        (pichat-test-prompt-and-wait session (make-string 5000 ?a))
        (when (eq reason 'overflow)
          (pichat-test-prompt-and-wait session (make-string 5000 ?b)))
        (pichat-test-rpc-call session "set_auto_compaction" '(:enabled t))
        (let ((settled (pichat-test-count-raw-events session "agent_settled")))
          (pichat-test-rpc-call session "prompt"
                                (list :message (if (eq reason 'threshold)
                                                   (make-string 5000 ?c)
                                                 "overflow me")))
          (let ((start (pichat-test-wait-for-raw-event session "compaction_start" 8)))
            (message "PROBE auto start %s: %S" reason start)
            (should (equal (if (eq reason 'threshold) "threshold" "overflow")
                           (plist-get start :reason))))
          (let ((state (plist-get (pichat-test-rpc-call session "get_state") :data)))
            (should (plist-get state :isStreaming))
            (should (plist-get state :isCompacting)))
          (let ((end (pichat-test-wait-for-raw-event session "compaction_end" 8)))
            (message "PROBE auto end %s: %S" reason end)
            (should (plist-get end :result))
            (should (eq (eq reason 'overflow) (plist-get end :willRetry))))
          (pichat-test-wait-for-raw-event session "agent_settled" 8 settled)))))

  (ert-deftest pichat-integration-characterize-manual-queue-does-not-start-a-run ()
    (pichat-test-with-integration-session
        (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                 :script '(:turns [(:text "h1") (:text "h2")
                                   (:text "summary" :delayMs 600)]))
      (pichat-test-prompt-and-wait session (make-string 2000 ?a))
      (pichat-test-prompt-and-wait session (make-string 2000 ?b))
      (let ((starts (pichat-test-count-raw-events session "agent_start")))
        (pichat-rpc-compact session nil #'ignore)
        (pichat-test-wait-for-raw-event session "compaction_start")
        (dolist (command '("steer" "follow_up"))
          (pichat-test-rpc-call session command
            (list :message command :images (pichat-attachments-wire-images
                                            (list pichat-test-compaction-image)))))
        (pichat-test-wait-for-raw-event session "compaction_end" 8)
        (let ((state (plist-get (pichat-test-rpc-call session "get_state") :data)))
          (message "PROBE post-compaction queue: %S" state)
          (should-not (plist-get state :isStreaming))
          (should (= starts (pichat-test-count-raw-events session "agent_start")))
          (should (= 2 (plist-get state :pendingMessageCount))))
        (should-not (cl-intersection '("steer[image]" "follow_up[image]")
                                    (mapcar #'pichat-render-message-text (pichat-test-compaction-users session))
                                    :test #'equal))
        (should (equal '(:steering ("steer") :followUp ("follow_up"))
                       (plist-get (pichat-test-rpc-call session "clear_queue") :data))))))

  (ert-deftest pichat-integration-characterize-chain-before-serialized-transfer ()
    ;; Probe a supported ordering without changing chain-send: let its first
    ;; prompt reach agent_start, then queue the held messages one ack at a time.
    (require 'pichat-job-tools)
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vconcat [(:text "h1") (:text "h2")
                                           (:text "summary" :delayMs 400)
                                           (:text "notice reply" :delayMs 600)]
                                          (if (equal mode "all")
                                              [(:text "combined reply")]
                                            [(:text "held one reply") (:text "held two reply")]))))
        (pichat-test-prompt-and-wait session (make-string 2000 ?a))
        (pichat-test-prompt-and-wait session (make-string 2000 ?b))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (let* ((pichat-chat-stop-session-on-kill nil)
               (buffer (pichat-chat-open session))
               (executor (pichat-job-executor--create))
               (delivery (list :state "sending" :handlers nil))
               (entry (list :root "probe" :chat (pichat-job-conversation-address session)
                            :delivery delivery))
               (starts (pichat-test-count-raw-events session "agent_start"))
               (settled (pichat-test-count-raw-events session "agent_settled")))
          (unwind-protect
              (cl-letf (((symbol-function 'pichat-job-executor--changed) #'ignore))
                (puthash "probe" entry (pichat-job-executor-chains executor))
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (pichat-job-tools--chain-send executor entry delivery "chain notice")
                (should (equal "waiting" (plist-get delivery :state)))
                (pichat-test-wait-for-raw-event session "agent_start" 8 starts)
                (dolist (text '("held one" "held two"))
                  (should (equal "queued" (plist-get (plist-get
                            (pichat-test-rpc-call session "prompt"
                              (list :message text :streamingBehavior "followUp")) :data)
                                                     :disposition))))
                (pichat-test-wait-for-raw-event session "agent_settled" 8 settled)
                (should (equal '("chain notice" "held one" "held two")
                               (last (mapcar #'pichat-render-message-text
                                             (pichat-test-compaction-users session)) 3)))
                (should (equal "sent" (plist-get delivery :state))))
            (pichat-job-tools--chain-unwait delivery)
            (when (buffer-live-p buffer) (kill-buffer buffer)))))))

) ; pichat-test-include-integration
(provide 'pichat-test-compaction-characterization)
;;; pichat-test-compaction-characterization.el ends here
