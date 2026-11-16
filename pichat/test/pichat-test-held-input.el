;;; pichat-test-held-input.el --- Compaction submission ownership -*- lexical-binding: t; -*-

(require 'pichat-test-support)

(defconst pichat-test-held-image
  '(:id "held-image" :type "image" :mimeType "image/png"
    :data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    :name "held.png" :bytes 68))

(defmacro pichat-test-with-held-chat (&rest body)
  "Run BODY in an isolated unit chat compacting outside a run."
  (declare (indent 0))
  `(pichat-test-with-unit-session (session proc)
     (let ((pichat-chat-stop-session-on-kill nil)
           (buffer (pichat-chat-open session)))
       (unwind-protect
           (with-current-buffer buffer
             (setf (pichat-session-compacting-p session) t)
             ,@body)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer (pichat-chat-input-abandon-in-flight))
           (kill-buffer buffer))))))

(defun pichat-test-held-item-position (text)
  "Find held panel item containing TEXT in the current chat."
  (save-excursion
    (goto-char (point-min))
    (search-forward text)
    (line-beginning-position)))

(ert-deftest pichat-held-input-panel-recall-delete-and-recovery-priority ()
  (pichat-test-with-held-chat
    (pichat-test-set-draft "first\nline")
    (setq pichat-chat--pending-attachments (list pichat-test-held-image))
    (pichat-chat-send-input)
    (pichat-chat-steer "second")
    (let ((pos (pichat-test-held-item-position "first line")))
      (should (< pos pichat-chat--prompt-start))
      (should (get-text-property pos 'read-only))
      (should (eq (key-binding (kbd "RET") nil nil pos)
                  'pichat-chat-input-recall-held-at-point))
      (should (string-match-p "1 held · follow-up · first line \\[1 img\\]"
                              (buffer-string))))
    ;; A new draft, including an image-only draft, cannot be overwritten.
    (pichat-test-set-draft "draft")
    (should-error (pichat-chat-recover-submission) :type 'user-error)
    (pichat-test-set-draft "")
    (setq pichat-chat--pending-attachments (list pichat-test-held-image))
    (should-error (pichat-chat-recover-submission) :type 'user-error)
    (setq pichat-chat--pending-attachments nil)
    ;; Existing recovery wins over the newest held record.
    (setq pichat-chat--recoverable-submissions (list '(:text "failed")))
    (pichat-chat-recover-submission)
    (should (equal "failed" (pichat-chat--input-text)))
    (should (= 2 (length pichat-chat--held-submissions)))
    (pichat-test-set-draft "")
    (pichat-chat-recover-submission)
    (should (equal "second" (pichat-chat--input-text)))
    (should (= 1 (length pichat-chat--held-submissions)))
    (pichat-test-set-draft "")
    (goto-char (pichat-test-held-item-position "first line"))
    (call-interactively (key-binding (kbd "RET")))
    (should (equal "first\nline" (pichat-chat--input-text)))
    (should (equal (list pichat-test-held-image) pichat-chat--pending-attachments))
    (should-not pichat-chat--held-submissions)
    (should-not (string-match-p "├ queued" (buffer-string)))
    (pichat-chat-send-input)
    (pichat-chat-follow-up "delete this")
    (pichat-test-set-draft "keep draft")
    (goto-char (pichat-test-held-item-position "delete this"))
    (call-interactively (key-binding (kbd "d")))
    (should (equal "keep draft" (pichat-chat--input-text)))
    (should (= 1 (length pichat-chat--held-submissions)))
    (pichat-chat-input-abandon-held)
    (should-not (string-match-p "├ queued" (buffer-string)))))

(ert-deftest pichat-held-input-panel-coexists-with-widgets-and-release ()
  (pichat-test-with-held-chat
    (pichat-chat-follow-up "waiting")
    (pichat-test-set-draft "untouched")
    (puthash "fixture" '(:lines ["widget content"])
             pichat-chat--extension-widgets)
    (dotimes (_ 3) (pichat-chat--render-extension-widgets))
    (should (equal "untouched" (pichat-chat--input-text)))
    (should (string-match-p "widget content\n├ queued" (buffer-string)))
    (should (= 1 (how-many "├ queued" (point-min) (point-max))))
    (setf (pichat-session-compacting-p session) nil)
    (cl-letf (((symbol-function 'pichat-rpc-prompt)
               (lambda (_session _text &optional _images _behavior success _failure)
                 (funcall success '(:data (:disposition "queued")) session)
                 "inline")))
      (pichat-chat-input-compaction-end '(:result (:summary "ok")))
      (pichat-chat-input-cancel-held-timer)
      (pichat-chat-input-held-barrier))
    (should-not (string-match-p "├ queued" (buffer-string)))
    (should (string-match-p "widget content" (buffer-string)))
    (should (equal "untouched" (pichat-chat--input-text)))))

(ert-deftest pichat-held-input-panel-keys-in-evil-states ()
  (skip-unless (require 'evil nil t))
  (require 'pichat-evil)
  (pichat-evil-setup)
  (pichat-test-with-held-chat
    (evil-local-mode 1)
    (dolist (state '(normal insert))
      (pichat-chat-follow-up (symbol-name state))
      (funcall (if (eq state 'normal) #'evil-normal-state #'evil-insert-state))
      (goto-char (pichat-test-held-item-position (concat "· " (symbol-name state))))
      (should (eq (key-binding (kbd "RET")) 'pichat-chat-input-recall-held-at-point))
      (call-interactively (key-binding (kbd "RET")))
      (should (equal (symbol-name state) (pichat-chat--input-text)))
      (pichat-test-set-draft "")
      (pichat-chat-follow-up "delete in Evil")
      (goto-char (pichat-test-held-item-position "delete in Evil"))
      (should (eq (key-binding (kbd "d")) 'pichat-chat-input-delete-held-at-point))
      (call-interactively (key-binding (kbd "d")))
      (should-not pichat-chat--held-submissions))))

(ert-deftest pichat-held-input-keeps-boundaries-images-and-editor-usable ()
  (pichat-test-with-held-chat
    (cl-letf (((symbol-function 'pichat-rpc-prompt)
               (lambda (&rest _) (ert-fail "Prompt during compaction")))
              ((symbol-function 'pichat-rpc-steer)
               (lambda (&rest _) (ert-fail "Steer during compaction"))))
      (pichat-test-set-draft "first")
      (setq pichat-chat--pending-attachments (list pichat-test-held-image))
      (pichat-chat-send-input)
      (should (pichat-chat--prompt-live-p))
      (should (equal "" (pichat-chat--input-text)))
      (should-not pichat-chat--pending-attachments)
      (pichat-chat-follow-up "second")
      (pichat-chat-steer "third")
      (should (equal '("first" "second" "third")
                     (mapcar (lambda (r) (plist-get r :text)) pichat-chat--held-submissions)))
      (should (equal '("followUp" "followUp" "steer")
                     (mapcar (lambda (r) (plist-get r :behavior)) pichat-chat--held-submissions)))
      (should (equal (list pichat-test-held-image)
                     (plist-get (car pichat-chat--held-submissions) :attachments)))
      (should (equal (list pichat-test-held-image) (pichat-chat--retained-attachments)))
      (should (zerop (hash-table-count pichat-chat--pending-submissions)))
      ;; Automatic compaction inside a run must not enter the held FIFO.
      (setf (pichat-session-streaming-p session) t)
      (should-not (pichat-chat-input-hold-p)))))

(ert-deftest pichat-held-input-release-waits-for-ack-and-authoritative-start ()
  (pichat-test-with-held-chat
    (let (calls)
      (cl-letf (((symbol-function 'pichat-rpc-prompt)
                 (lambda (_session text &optional images behavior success failure)
                   (let ((id (format "held-%d" (length calls))))
                     (setq calls (append calls (list (list id text images behavior success failure))))
                     id))))
        (pichat-test-set-draft "first")
        (pichat-chat-send-input)
        (pichat-chat-steer "steer")
        (pichat-chat-follow-up "follow")
        (setf (pichat-session-compacting-p session) nil)
        (pichat-chat-input-compaction-end '(:result (:summary "ok")))
        (pichat-chat-input-cancel-held-timer)
        (pichat-chat-input-held-barrier)
        (should (= 1 (length calls)))
        (should-not (nth 3 (car calls)))
        (funcall (nth 4 (car calls)) '(:data (:disposition "started")) session)
        (should (= 1 (length calls)))
        (pichat-test-set-draft "during handoff")
        (pichat-chat-send-input)
        (should (= 1 (length calls)))
        (setf (pichat-session-streaming-p session) t)
        (pichat-chat-input-agent-start)
        (should (= 2 (length calls)))
        (should (equal "steer" (nth 3 (nth 1 calls))))
        ;; Replayed acceptance of the earlier prompt cannot advance the FIFO
        ;; past a different outstanding request.
        (funcall (nth 4 (car calls)) '(:data (:disposition "started")) session)
        (should (= 2 (length calls)))
        ;; Even if a fast run settles before its queued acknowledgment, later
        ;; follow-ups retain atomic followUp behavior rather than idle prompts.
        (setf (pichat-session-streaming-p session) nil)
        (funcall (nth 4 (nth 1 calls)) '(:data (:disposition "queued")) session)
        (should (= 3 (length calls)))
        (should (equal "followUp" (nth 3 (nth 2 calls))))
        (funcall (nth 4 (nth 2 calls)) '(:data (:disposition "queued")) session)
        (should (= 4 (length calls)))
        (should (equal '("first" "steer" "follow" "during handoff")
                       (mapcar (lambda (c) (nth 1 c)) calls)))
        ;; Uncertain final transfer is retained exactly once, never retried.
        (funcall (nth 5 (nth 3 calls)) '(:pichat-failure-kind timeout) session)
        (funcall (nth 5 (nth 3 calls)) '(:pichat-failure-kind timeout) session)
        (should (= 1 (length pichat-chat--recoverable-submissions)))
        (should-not pichat-chat--held-release)
        (should-not pichat-chat--held-timer)
        (should (zerop (hash-table-count pichat-chat--pending-submissions)))))))

(ert-deftest pichat-held-input-started-without-agent-event-is-recoverable ()
  (pichat-test-with-held-chat
    (let ((calls 0))
      (cl-letf (((symbol-function 'pichat-rpc-prompt)
                 (lambda (_s _text &optional _images _behavior accepted _rejected)
                   (cl-incf calls)
                   (funcall accepted '(:data (:disposition "started")) session)
                   "inline-start")))
        (pichat-test-set-draft "uncertain start")
        (setq pichat-chat--pending-attachments (list pichat-test-held-image))
        (pichat-chat-send-input)
        (pichat-chat-follow-up "not sent")
        (setf (pichat-session-compacting-p session) nil)
        (pichat-chat-input-compaction-end '(:result (:summary "ok")))
        (pichat-chat-input-cancel-held-timer)
        (pichat-chat-input-held-barrier)
        (should (= 1 calls))
        (should (equal (list pichat-test-held-image) (pichat-chat--retained-attachments)))
        (pichat-chat-input-held-timeout)
        (should (= 2 (length pichat-chat--recoverable-submissions)))
        (should-not pichat-chat--held-awaiting-start)
        (pichat-chat-input-agent-start)
        (should (= 1 calls))))))

(ert-deftest pichat-held-input-chain-ack-is-not-a-start-barrier ()
  (pichat-test-with-held-chat
    (pichat-chat-follow-up "held")
    (setf (pichat-session-compacting-p session) nil)
    (cl-letf (((symbol-function 'pichat-chat-input-prompt-pending-p) (lambda () t)))
      (pichat-chat-input-compaction-end '(:result (:summary "ok"))))
    ;; Chain prompt was acknowledged before the deferred release callback,
    ;; but its run has not started.  No idle submission is permitted here.
    (cl-letf (((symbol-function 'pichat-chat-input-prompt-pending-p) (lambda () nil))
              ((symbol-function 'pichat-rpc-prompt)
               (lambda (&rest _) (ert-fail "Concurrent idle prompt"))))
      (pichat-chat-input-cancel-held-timer)
      (pichat-chat-input-held-barrier)
      (should (eq 'wait-start pichat-chat--held-release))
      (pichat-chat-input-held-timeout)
      (should (equal "held" (plist-get (car pichat-chat--recoverable-submissions) :text)))
      (should-not pichat-chat--held-release))))

(ert-deftest pichat-held-input-interruption-recovers-without-overwriting-draft ()
  (dolist (boundary '(failure abort-event abort-command rebind ended timeout))
    (ert-info ((format "%s" boundary))
      (pichat-test-with-held-chat
        (pichat-test-set-draft "held")
        (setq pichat-chat--pending-attachments (list pichat-test-held-image))
        (pichat-chat-send-input)
        (pichat-chat-steer "held steer")
        (pichat-test-set-draft "new draft")
        (pcase boundary
          ('failure (pichat-chat-input-compaction-end '(:errorMessage "failed")))
          ('abort-event (pichat-chat-input-compaction-end '(:aborted t)))
          ('abort-command (pichat-chat-abort))
          ('rebind (pichat-chat--on-session-rebinding session nil nil))
          ('ended (pichat-chat--on-session-ended session nil nil))
          ('timeout (pichat-chat-input-held-timeout)))
        (should (equal "new draft" (pichat-chat--input-text)))
        (should-not pichat-chat--held-submissions)
        (should-not pichat-chat--held-release)
        (should (= 2 (length pichat-chat--recoverable-submissions)))
        (should (equal (list pichat-test-held-image) (pichat-chat--retained-attachments)))
        (pichat-chat-input-abandon-in-flight)
        (should (= 2 (length pichat-chat--recoverable-submissions)))))))

(ert-deftest pichat-held-input-guards-owned-runtime-before-consuming-editor ()
  (pichat-test-with-held-chat
    (pichat-test-set-draft "keep draft")
    (setq pichat-chat--pending-attachments (list pichat-test-held-image))
    (setf (pichat-session-input-guard session)
          (lambda (_command) (user-error "Input is owned")))
    (should-error (pichat-chat-send-input) :type 'user-error)
    (should-error (pichat-chat-follow-up "no hold") :type 'user-error)
    (should-error (pichat-chat-steer "no hold") :type 'user-error)
    (should (equal "keep draft" (pichat-chat--input-text)))
    (should (equal (list pichat-test-held-image) pichat-chat--pending-attachments))
    (should-not pichat-chat--held-submissions)))

(ert-deftest pichat-held-input-source-loss-retires-inflight-and-late-callbacks ()
  (pichat-test-with-held-chat
    (let (success failure calls)
      (cl-letf (((symbol-function 'pichat-rpc-prompt)
                 (lambda (_s _text &optional _images _behavior accepted rejected)
                   (cl-incf calls)
                   (setq success accepted failure rejected)
                   "inflight-held")))
        (setq calls 0)
        (pichat-chat-follow-up "in flight")
        (pichat-chat-follow-up "not sent")
        (setf (pichat-session-compacting-p session) nil)
        (pichat-chat-input-compaction-end '(:result (:summary "ok")))
        (pichat-chat-input-cancel-held-timer)
        (pichat-chat-input-held-barrier)
        (should (= 1 calls))
        (pichat-chat--on-session-rebinding session nil nil)
        (should (= 2 (length pichat-chat--recoverable-submissions)))
        (funcall success '(:data (:disposition "started")) session)
        (funcall failure '(:pichat-failure-kind transport) session)
        (pichat-chat-input-agent-start)
        (should (= 1 calls))
        (should (= 2 (length pichat-chat--recoverable-submissions)))
        (should-not pichat-chat--held-release)
        (should-not pichat-chat--held-timer)
        (should (zerop (hash-table-count pichat-chat--pending-submissions)))))))

(ert-deftest pichat-held-input-close-confirms-and-reopen-retains-recovery ()
  (pichat-test-with-held-chat
    (pichat-chat-follow-up "held")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-not (kill-buffer buffer)))
    (should (buffer-live-p buffer))
    (should pichat-chat--held-submissions)
    (let ((pichat-chat-stop-session-on-kill t)
          stopped)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                ((symbol-function 'pichat-stop-session) (lambda (_session) (setq stopped t)))
                ((symbol-function 'pichat-forget-session)
                 (lambda (&rest _) (ert-fail "Forgot runtime owning recovery"))))
        (should (kill-buffer buffer))
        (should stopped)))
    (should (equal "held" (plist-get (car (pichat-session-input-recovery session)) :text)))
    (setq buffer (pichat-chat-open session))
    (with-current-buffer buffer
      (should-not pichat-chat--held-submissions)
      (pichat-chat-recover-submission)
      (should (equal "held" (pichat-chat--input-text))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-held-input-ordered-release-with-images ()
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vconcat [(:text "h1") (:text "h2")
                                           (:text "summary" :delayMs 600)
                                           (:text "first reply" :delayMs 600)]
                                          (if (equal mode "all")
                                              [(:text "combined reply")]
                                            [(:text "second reply") (:text "third reply")]))))
        (pichat-test-prompt-and-wait session (make-string 2000 ?a))
        (pichat-test-prompt-and-wait session (make-string 2000 ?b))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (let ((pichat-chat-stop-session-on-kill nil)
              (buffer (pichat-chat-open session))
              (settled (pichat-test-count-raw-events session "agent_settled")))
          (unwind-protect
              (progn
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (with-current-buffer buffer
                  (dolist (text '("held first" "held second" "held third"))
                    (pichat-test-set-draft text)
                    (setq pichat-chat--pending-attachments (list pichat-test-held-image))
                    (pichat-chat-send-input))
                  (should (= 3 (length pichat-chat--held-submissions))))
                (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
                (let ((users (cl-remove-if-not
                              (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                              (pichat-test-compaction-users session))))
                  ;; Compare every matching message, not just the last three:
                  ;; an earlier duplicate must fail as well as a missing item.
                  (should (equal '("held first[image]" "held second[image]" "held third[image]")
                                 (mapcar #'pichat-render-message-text users)))
                  (dolist (user users)
                    (let ((image (cl-find "image" (plist-get user :content)
                                          :key (lambda (part) (plist-get part :type))
                                          :test #'equal)))
                      (should (equal (plist-get image :data)
                                     (plist-get pichat-test-held-image :data)))
                      (should (equal "image/png" (plist-get image :mimeType))))))
                (with-current-buffer buffer
                  (should-not pichat-chat--held-submissions)
                  (should-not pichat-chat--held-release)
                  (should-not pichat-chat--recoverable-submissions)
                  (should (zerop (hash-table-count pichat-chat--pending-submissions)))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-held-input-chain-notice-starts-first ()
    (require 'pichat-job-tools)
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vconcat [(:text "h1") (:text "h2")
                                           (:text "summary" :delayMs 600)
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
               (entry (list :root "held-test" :chat (pichat-job-conversation-address session)
                            :delivery delivery))
               (settled (pichat-test-count-raw-events session "agent_settled")))
          (unwind-protect
              (cl-letf (((symbol-function 'pichat-job-executor--changed) #'ignore))
                (puthash "held-test" entry (pichat-job-executor-chains executor))
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (with-current-buffer buffer
                  (pichat-chat-follow-up "held one")
                  (pichat-chat-follow-up "held two"))
                (pichat-job-tools--chain-send executor entry delivery "chain notice")
                (should (equal "waiting" (plist-get delivery :state)))
                (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
                (should (equal '("chain notice" "held one" "held two")
                               (cl-remove-if-not
                                (lambda (text) (member text '("chain notice" "held one" "held two")))
                                (mapcar #'pichat-render-message-text
                                        (pichat-test-compaction-users session)))))
                (should (equal "sent" (plist-get delivery :state)))
                (with-current-buffer buffer
                  (should-not pichat-chat--recoverable-submissions)
                  (should-not pichat-chat--held-release)))
            (pichat-job-tools--chain-unwait delivery)
            (when (buffer-live-p buffer) (kill-buffer buffer)))))))

  (ert-deftest pichat-integration-held-input-steering-alone-and-mixed ()
    (pcase-dolist (`(,mixed . ,mode)
                  '((nil . "one-at-a-time") (t . "one-at-a-time")
                    (nil . "all") (t . "all")))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vconcat [(:text "h1") (:text "h2")
                                           (:text "summary" :delayMs 600)
                                           (:text "first reply" :delayMs 600)]
                                          (when mixed [(:text "steer reply") (:text "follow reply")]))))
        (pichat-test-prompt-and-wait session (make-string 2000 ?a))
        (pichat-test-prompt-and-wait session (make-string 2000 ?b))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (let ((pichat-chat-stop-session-on-kill nil)
              (buffer (pichat-chat-open session))
              (settled (pichat-test-count-raw-events session "agent_settled")))
          (unwind-protect
              (progn
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (with-current-buffer buffer
                  (when mixed (pichat-chat-follow-up "first follow"))
                  (pichat-chat-steer "held steer")
                  (when mixed (pichat-chat-follow-up "last follow")))
                (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
                (should (equal (if mixed '("first follow" "held steer" "last follow") '("held steer"))
                               (cl-remove-if-not
                                (lambda (text) (member text '("first follow" "held steer" "last follow")))
                                (mapcar #'pichat-render-message-text
                                        (pichat-test-compaction-users session))))))
            (when (buffer-live-p buffer) (kill-buffer buffer)))))))

  (ert-deftest pichat-integration-held-input-failure-and-abort-never-send ()
    (dolist (outcome '(failure abort))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vector '(:text "h1") '(:text "h2")
                                         (if (eq outcome 'failure)
                                             '(:error "held test failure" :delayMs 600)
                                           '(:text "summary" :delayMs 600)))))
        (pichat-test-prompt-and-wait session (make-string 2000 ?a))
        (pichat-test-prompt-and-wait session (make-string 2000 ?b))
        (let ((pichat-chat-stop-session-on-kill nil)
              (buffer (pichat-chat-open session))
              (starts (pichat-test-count-raw-events session "agent_start")))
          (unwind-protect
              (progn
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (with-current-buffer buffer
                  (pichat-test-set-draft "held image")
                  (setq pichat-chat--pending-attachments (list pichat-test-held-image))
                  (pichat-chat-send-input)
                  (pichat-chat-steer "held steer")
                  (when (eq outcome 'abort) (pichat-chat-abort)))
                (pichat-test-wait-for-raw-event session "compaction_end" 10)
                (pichat-test-rpc-call session "get_state")
                (should (= starts (pichat-test-count-raw-events session "agent_start")))
                (with-current-buffer buffer
                  (should (= 2 (length pichat-chat--recoverable-submissions)))
                  (should-not pichat-chat--held-submissions)
                  (should-not pichat-chat--held-release)
                  (should-not (string-match-p "├ queued" (buffer-string)))
                  (should (equal '("held image" "held steer")
                                 (sort (mapcar (lambda (r) (plist-get r :text))
                                               pichat-chat--recoverable-submissions)
                                       #'string<)))
                  (should (equal (list pichat-test-held-image) (pichat-chat--retained-attachments))))
                (should-not (cl-find-if
                             (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                             (pichat-test-compaction-users session))))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-held-input-recall-and-delete-before-delivery ()
    (pichat-test-with-integration-session
        (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                 :script '(:turns [(:text "h1") (:text "h2")
                                   (:text "summary" :delayMs 1000)
                                   (:text "delivered")]))
      (pichat-test-prompt-and-wait session (make-string 2000 ?a))
      (pichat-test-prompt-and-wait session (make-string 2000 ?b))
      (let ((pichat-chat-stop-session-on-kill nil)
            (buffer (pichat-chat-open session))
            (starts (pichat-test-count-raw-events session "agent_start"))
            (settled (pichat-test-count-raw-events session "agent_settled")))
        (unwind-protect
            (progn
              (with-current-buffer buffer (pichat-chat-compact))
              (pichat-test-wait-for-raw-event session "compaction_start")
              (with-current-buffer buffer
                (dolist (text '("held deliver" "held delete" "held panel recall" "held recall"))
                  (pichat-test-set-draft text)
                  (setq pichat-chat--pending-attachments (list pichat-test-held-image))
                  (pichat-chat-send-input))
                (should (= 4 (how-many "held · follow-up" (point-min) (point-max))))
                (goto-char (pichat-test-held-item-position "held panel recall"))
                (call-interactively (key-binding (kbd "RET")))
                (should (equal "held panel recall" (pichat-chat--input-text)))
                (should (equal (list pichat-test-held-image) pichat-chat--pending-attachments))
                ;; Explicitly discard this recalled fixture draft before
                ;; exercising newest-first recall from the empty prompt.
                (pichat-test-set-draft "")
                (pichat-chat-clear-attachments)
                (goto-char (point-max))
                (call-interactively (key-binding (kbd "C-c C-y")))
                (should (equal "held recall" (pichat-chat--input-text)))
                (should (equal (list pichat-test-held-image) pichat-chat--pending-attachments))
                (goto-char (pichat-test-held-item-position "held deliver"))
                (should-error (call-interactively (key-binding (kbd "RET"))) :type 'user-error)
                (goto-char (pichat-test-held-item-position "held delete"))
                (call-interactively (key-binding (kbd "d")))
                (should (= 1 (length pichat-chat--held-submissions))))
              ;; Round-trip readiness while still compacting: none of the held
              ;; or recalled content has reached Pi or started an agent run.
              (should (plist-get (plist-get (pichat-test-rpc-call session "get_state") :data)
                                 :isCompacting))
              (should (= starts (pichat-test-count-raw-events session "agent_start")))
              (should-not (cl-find-if
                           (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                           (pichat-test-compaction-users session)))
              (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
              (should (equal '("held deliver[image]")
                             (mapcar #'pichat-render-message-text
                                     (cl-remove-if-not
                                      (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                                      (pichat-test-compaction-users session)))))
              (with-current-buffer buffer
                (should (equal "held recall" (pichat-chat--input-text)))
                (should (equal (list pichat-test-held-image) pichat-chat--pending-attachments))
                (should-not (string-match-p "├ queued" (buffer-string)))
                (should-not pichat-chat--recoverable-submissions)))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-integration-held-input-submission-during-real-handoff ()
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                   :script (list :turns
                                 (vconcat [(:text "h1") (:text "h2")
                                           (:text "summary" :delayMs 600)
                                           (:text "first reply" :delayMs 600)]
                                          (if (equal mode "all")
                                              [(:text "combined")]
                                            [(:text "second") (:text "third")]))))
        (pichat-test-prompt-and-wait session (make-string 2000 ?a))
        (pichat-test-prompt-and-wait session (make-string 2000 ?b))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (let* ((pichat-chat-stop-session-on-kill nil)
               (buffer (pichat-chat-open session))
               (settled (pichat-test-count-raw-events session "agent_settled"))
               injected
               (handler (lambda (&rest _)
                          (unless injected
                            (with-current-buffer buffer
                              ;; This listener runs before the chat's start
                              ;; handler, with release still owning the FIFO.
                              (should pichat-chat--held-release)
                              (setq injected t)
                              (pichat-test-set-draft "held during handoff")
                              (setq pichat-chat--pending-attachments (list pichat-test-held-image))
                              (pichat-chat-send-input))))))
          (unwind-protect
              (progn
                (pichat-rpc-compact session nil #'ignore)
                (pichat-test-wait-for-raw-event session "compaction_start")
                (with-current-buffer buffer
                  (pichat-chat-follow-up "held first")
                  (pichat-chat-follow-up "held second"))
                (pichat-on 'agent-start handler session)
                (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
                (should injected)
                (should (equal '("held first" "held second" "held during handoff[image]")
                               (mapcar #'pichat-render-message-text
                                       (cl-remove-if-not
                                        (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                                        (pichat-test-compaction-users session)))))
                (with-current-buffer buffer
                  (should-not pichat-chat--held-release)
                  (should-not pichat-chat--recoverable-submissions)
                  (should-not (string-match-p "├ queued" (buffer-string)))))
            (pichat-off 'agent-start handler session)
            (when (buffer-live-p buffer) (kill-buffer buffer)))))))

  (ert-deftest pichat-integration-held-input-lifecycle-never-retargets-or-replays ()
    (dolist (boundary '(close rebind restart))
      (ert-info ((format "held input / %s" boundary))
        (pichat-test-with-integration-session
            (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
                     :script '(:turns [(:text "h1") (:text "h2")
                                       (:text "summary" :delayMs 1000)
                                       (:text "explicit later reply")]))
          (pichat-test-prompt-and-wait session (make-string 2000 ?a))
          (pichat-test-prompt-and-wait session (make-string 2000 ?b))
          (let ((pichat-chat-stop-session-on-kill nil)
                (buffer (pichat-chat-open session))
                (runtime-id (pichat-session-runtime-id session))
                (source-id (pichat-session-id session))
                (old-process (pichat-session-process session)))
            (unwind-protect
                (progn
                  (pichat-rpc-compact session nil #'ignore)
                  (pichat-test-wait-for-raw-event session "compaction_start")
                  (with-current-buffer buffer
                    (pichat-test-set-draft "held image")
                    (setq pichat-chat--pending-attachments (list pichat-test-held-image))
                    (pichat-chat-send-input)
                    (pichat-chat-steer "held steer")
                    (pichat-test-set-draft "unsent draft"))
                  (pcase boundary
                    ('close
                     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
                       (should-not (kill-buffer buffer)))
                     (should (buffer-live-p buffer))
                     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
                       (should (kill-buffer buffer)))
                     (setq buffer (pichat-chat-open session))
                     (pichat-test-wait-for-raw-event session "compaction_end"))
                    ('rebind
                     ;; Real source mutation while compaction is pending, not
                     ;; a hand-emitted session-rebinding notification.
                     (pichat-test-rpc-call session "new_session")
                     (pichat-test-rpc-call session "get_state")
                     (should-not (equal source-id (pichat-session-id session)))
                     (pichat-test-wait-for-raw-event session "compaction_end"))
                    ('restart
                     ;; Stop the actual process mid-summary, then start a
                     ;; replacement in the same runtime with a fresh script.
                     (pichat-rpc-stop session)
                     (should-not (process-live-p old-process))
                     (with-temp-file script-file
                       (insert "{\"turns\":[{\"text\":\"explicit later reply\"}]}"))
                     (pichat-rpc-start session (pichat-session-rpc-command session))
                     (pichat-test-rpc-call session "get_state")
                     (pichat-test-rpc-call session "set_auto_compaction" '(:enabled :json-false))
                     (should-not (eq old-process (pichat-session-process session)))))
                  (should (equal runtime-id (pichat-session-runtime-id session)))
                  ;; A later real run must not rearm any abandoned release.
                  (pichat-test-prompt-and-wait session "explicit later input")
                  (pichat-test-rpc-call session "get_state")
                  (should-not (cl-find-if
                               (lambda (m) (string-prefix-p "held " (pichat-render-message-text m)))
                               (pichat-test-compaction-users session)))
                  (with-current-buffer buffer
                    (should-not pichat-chat--held-submissions)
                    (should-not pichat-chat--held-release)
                    (should-not pichat-chat--held-timer)
                    (should-not (string-match-p "├ queued" (buffer-string)))
                    (should (= 2 (length pichat-chat--recoverable-submissions)))
                    (should (equal (list pichat-test-held-image) (pichat-chat--retained-attachments)))
                    (unless (eq boundary 'close)
                      (should (equal "unsent draft" (pichat-chat--input-text))))
                    (pichat-test-set-draft "")
                    (let (recovered)
                      (dotimes (_ 2)
                        (cl-letf (((symbol-function 'completing-read)
                                   (lambda (_prompt choices &rest _) (caar choices))))
                          (pichat-chat-recover-submission))
                        (push (cons (pichat-chat--input-text) pichat-chat--pending-attachments) recovered)
                        (pichat-test-set-draft "")
                        (setq pichat-chat--pending-attachments nil))
                      (should (equal '("held image" "held steer") (sort (mapcar #'car recovered) #'string<)))
                      (should (equal (list pichat-test-held-image) (cdr (assoc "held image" recovered)))))
                    (should-not pichat-chat--recoverable-submissions)))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(provide 'pichat-test-held-input)
;;; pichat-test-held-input.el ends here
