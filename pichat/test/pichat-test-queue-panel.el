;;; pichat-test-queue-panel.el --- Native Pi queue projection -*- lexical-binding: t; -*-
(require 'pichat-test-support)

(defconst pichat-test-queue-image
  '(:id "queue-image" :type "image" :mimeType "image/png" :name "queue.png" :bytes 68
    :data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))

(defmacro pichat-test-with-queue-chat (&rest body)
  "Run BODY in an isolated unit chat during an agent run."
  (declare (indent 0))
  `(pichat-test-with-unit-session (session proc)
     (let ((pichat-chat-stop-session-on-kill nil)
           (buffer (pichat-chat-open session)))
       (unwind-protect
           (with-current-buffer buffer
             (setf (pichat-session-streaming-p session) t)
             ,@body)
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun pichat-test-queue-event (session steering follow)
  "Deliver a queue event with STEERING and FOLLOW text to SESSION's chat."
  (pichat-chat--on-simple-event
   session 'queue-update (list :raw (list :steering steering :followUp follow))))

(ert-deftest pichat-queue-panel-busy-editor-input-images-and-recall-all ()
  (pichat-test-with-queue-chat
    (let (queued-steer queued-follow calls)
      (cl-letf (((symbol-function 'pichat-rpc-prompt)
                 (lambda (_s text &optional images behavior success _failure)
                   (push (list text images behavior) calls)
                   (if (equal behavior "steer") (push text queued-steer) (push text queued-follow))
                   ;; Pi emits the queue BEFORE acknowledging the prompt.
                   (pichat-test-queue-event session (reverse queued-steer) (reverse queued-follow))
                   (funcall success '(:data (:disposition "queued")) session)
                   (format "q-%d" (length calls))))
                ((symbol-function 'pichat-backend-clear-session-queue)
                 (lambda (_s success &optional _failure)
                   (let ((raw (list :steering (reverse queued-steer) :followUp (reverse queued-follow))))
                     (pichat-test-queue-event session nil nil)
                     (funcall success (list :data raw) session)))))
        (pichat-test-set-draft "follow\nline")
        (setq pichat-chat--pending-attachments (list pichat-test-queue-image))
        (call-interactively (key-binding (kbd "RET")))
        (pichat-test-set-draft "steering")
        (call-interactively (key-binding (kbd "M-RET")))
        (should (equal '("steer" "followUp") (mapcar #'caddr calls)))
        (should (equal '(1 . 1) pichat-chat--queue-counts))
        (should (string-match-p "1 queued in Pi · steering · steering" (buffer-string)))
        (should (string-match-p "2 queued in Pi · follow-up · follow line \\[1 img\\]" (buffer-string)))
        (should (equal (list pichat-test-queue-image) (pichat-chat--retained-attachments)))
        (goto-char (point-min))
        (search-forward "1 queued in Pi")
        (should (get-text-property (point) 'read-only))
        (should (< (point) pichat-chat--prompt-start))
        (should (eq 'pichat-chat-recall-queue (key-binding (kbd "RET"))))
        (call-interactively (key-binding (kbd "RET")))
        (should (equal "steering\n\nfollow\nline" (pichat-chat--input-text)))
        (should (equal (list pichat-test-queue-image) pichat-chat--pending-attachments))
        (should-not pichat-chat--pi-queue)
        (should-not (string-match-p "queued in Pi" (buffer-string)))
        (should (= 2 (length calls)))))))

(ert-deftest pichat-queue-panel-abort-restores-matching-images-and-reports-unmatched ()
  (dolist (texts '(("queued follow") ("external")
                   ("queued follow" "queued follow")
                   ("external" "queued follow")))
    (pichat-test-with-queue-chat
      (let ((draft-image (plist-put (copy-sequence pichat-test-queue-image)
                                   :id "draft-image"))
            aborted feedback)
        (cl-letf (((symbol-function 'pichat-rpc-prompt)
                   (lambda (_s text &optional _images _behavior success _failure)
                     (pichat-test-queue-event session nil (list text))
                     (funcall success '(:data (:disposition "queued")) session)
                     "queued"))
                  ((symbol-function 'pichat-backend-clear-session-queue)
                   (lambda (_s success &optional _failure)
                     ;; Even if the projection empties before the response,
                     ;; Abort must use its pre-clear image snapshot.
                     (pichat-test-queue-event session nil nil)
                     (funcall success (list :data (list :followUp texts)) session)))
                  ((symbol-function 'pichat-backend-abort-session)
                   (lambda (_s &optional _retry) (setq aborted t)))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (push (apply #'format format-string args) feedback))))
          (pichat-test-set-draft "queued follow")
          (setq pichat-chat--pending-attachments (list pichat-test-queue-image))
          (pichat-chat-send-input)
          (pichat-test-set-draft "draft")
          (setq pichat-chat--pending-attachments (list draft-image))
          (pichat-chat-abort)
          (should aborted)
          (should (equal (concat (string-join texts "\n\n") "\n\ndraft")
                         (pichat-chat--input-text)))
          (should-not pichat-chat--pi-queue)
          (if (equal texts '("queued follow"))
              (progn
                (should (equal (list draft-image pichat-test-queue-image)
                               pichat-chat--pending-attachments))
                (should-not (string-match-p "unmatched images" (buffer-string))))
            (should (equal (list draft-image) pichat-chat--pending-attachments))
            (should (string-match-p "unmatched images were not restored" (buffer-string)))
            (should (member "PiChat: unmatched queue images were not restored" feedback))))))))

(ert-deftest pichat-queue-panel-minibuffer-input-keeps-draft-and-provenance ()
  (pichat-test-with-queue-chat
    (pichat-test-set-draft "unsent editor")
    (let (steering follow)
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (_s command payload &optional success _failure)
                   (if (equal command "steer")
                       (setq steering (list (plist-get payload :message)))
                     (setq follow (list (plist-get payload :message))))
                   (pichat-test-queue-event session steering follow)
                   (funcall success '(:data (:disposition "queued")) session)
                   "inline")))
        (pichat-chat-steer " steer text ")
        (pichat-chat-follow-up "follow text"))
      (should (equal "unsent editor" (pichat-chat--input-text)))
      (should (equal '(" steer text " "follow text")
                     (mapcar (lambda (r) (plist-get r :text)) pichat-chat--pi-queue)))
      (should (cl-every (lambda (r) (plist-get r :known)) pichat-chat--pi-queue))
      (should-not pichat-chat--queue-candidates))))

(ert-deftest pichat-queue-panel-drain-mismatch-and-duplicate-images-are-conservative ()
  (pichat-test-with-queue-chat
    (dolist (text '("one" "two"))
      (pichat-chat-queue-track (list :text text :attachments (list pichat-test-queue-image)) "followUp"))
    (pichat-test-queue-event session nil '("one" "two"))
    (pichat-test-queue-event session nil '("two"))
    (should (equal (list pichat-test-queue-image)
                   (plist-get (car pichat-chat--pi-queue) :attachments)))
    (pichat-test-queue-event session nil '("external" "two"))
    (should-not (cl-some (lambda (r) (plist-get r :attachments)) pichat-chat--pi-queue))
    (pichat-chat-queue-reset)
    (dotimes (_ 2)
      (pichat-chat-queue-track (list :text "duplicate" :attachments (list pichat-test-queue-image)) "followUp"))
    (pichat-test-queue-event session nil '("duplicate" "duplicate"))
    (should (string-match-p "images unknown" (buffer-string)))
    (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
               (lambda (_s success &optional _failure)
                 (pichat-test-queue-event session nil nil)
                 (funcall success '(:data (:followUp ("duplicate" "duplicate"))) session))))
      (pichat-chat-recover-submission))
    (should (equal "duplicate\n\nduplicate" (pichat-chat--input-text)))
    (should-not pichat-chat--pending-attachments)
    (should (string-match-p "unmatched images were not restored" (buffer-string)))
    (should-not (pichat-chat--retained-attachments))))

(ert-deftest pichat-queue-panel-recall-preserves-later-drafts-and-source ()
  (dolist (boundary '(edit source close))
    (pichat-test-with-queue-chat
      (pichat-test-queue-event session nil '("waiting"))
      (let (reply)
        (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
                   (lambda (_s success &optional _failure) (setq reply success))))
          (pichat-chat-recall-queue)
          (should-error (pichat-chat-recall-queue) :type 'user-error)
          (pcase boundary
            ('edit (pichat-test-set-draft "later"))
            ('source (pichat-chat--reset-for-source "other" nil t))
            ('close (kill-buffer buffer)))
          (dotimes (_ 2) (funcall reply '(:data (:followUp ("waiting"))) session))
          (if (eq boundary 'close)
              (progn
                (should (= 1 (length (pichat-session-input-recovery session))))
                (should (equal "waiting" (plist-get (car (pichat-session-input-recovery session)) :text))))
            (should (equal (if (eq boundary 'edit) "later" "") (pichat-chat--input-text)))
            (should (= 1 (length pichat-chat--recoverable-submissions)))
            (should (equal "waiting" (plist-get (car pichat-chat--recoverable-submissions) :text)))))))))

(ert-deftest pichat-queue-panel-recall-guards-failure-and-source-reset ()
  (pichat-test-with-queue-chat
    (pichat-test-queue-event session '("steer") '("follow"))
    (pichat-test-set-draft "draft")
    (should-error (pichat-chat-recall-queue) :type 'user-error)
    (pichat-test-set-draft "")
    (setq pichat-chat--pending-attachments (list pichat-test-queue-image))
    (should-error (pichat-chat-recall-queue) :type 'user-error)
    (setq pichat-chat--pending-attachments nil)
    (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
               (lambda (_s _success &optional failure) (funcall failure '(:error "failed") session))))
      (pichat-chat-recall-queue))
    (should (= 2 (length pichat-chat--pi-queue)))
    (should-not pichat-chat--queue-recall)
    (should (equal "" (pichat-chat--input-text)))
    (pichat-chat--reset-for-source "other" nil t)
    (should-not pichat-chat--pi-queue)
    (should (equal '(0 . 0) pichat-chat--queue-counts))
    (should-not (string-match-p "queued in Pi" (buffer-string)))))

(ert-deftest pichat-queue-panel-evil-item-recalls-all-and-meta-return-steers ()
  (skip-unless (require 'evil nil t))
  (require 'pichat-evil)
  (pichat-evil-setup)
  (pichat-test-with-queue-chat
    (evil-local-mode 1)
    (dolist (state '(normal insert))
      (pichat-test-queue-event session '("steer") '("follow"))
      (funcall (if (eq state 'normal) #'evil-normal-state #'evil-insert-state))
      (goto-char (point-min)) (search-forward "1 queued in Pi")
      (should (eq 'pichat-chat-recall-queue (key-binding (kbd "RET"))))
      (goto-char (point-max))
      (should (eq 'pichat-chat-steer-input (key-binding (kbd "M-RET"))))
      (should (eq 'pichat-chat-steer-input (key-binding (kbd "M-<return>")))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-queue-panel-editor-and-image-recall ()
    (pichat-test-with-integration-session
        (session :script '(:turns [(:text "reply" :delayMs 1500)]))
      (let ((pichat-chat-stop-session-on-kill nil)
            (buffer (pichat-chat-open session)))
        (unwind-protect
            (progn
              (pichat-rpc-prompt session "start")
              (pichat-test-wait-for-raw-event session "agent_start")
              (with-current-buffer buffer
                (pichat-test-set-draft "queued follow")
                (setq pichat-chat--pending-attachments (list pichat-test-queue-image))
                (pichat-chat-send-input)
                (pichat-test-set-draft "queued steer")
                (pichat-chat-steer-input))
              (pichat-test-wait-until
               (lambda () (with-current-buffer buffer (= 2 (length pichat-chat--pi-queue)))) 5)
              (with-current-buffer buffer
                (should (equal '("queued steer" "queued follow")
                               (mapcar (lambda (r) (plist-get r :text)) pichat-chat--pi-queue)))
                (pichat-chat-recover-submission))
              (pichat-test-wait-until
               (lambda () (with-current-buffer buffer (equal "queued steer\n\nqueued follow" (pichat-chat--input-text)))) 5)
              (with-current-buffer buffer
                (should (equal (list pichat-test-queue-image) pichat-chat--pending-attachments))
                (should-not pichat-chat--pi-queue))
              (pichat-test-wait-for-raw-event session "agent_settled")
              (should (equal '("start") (mapcar #'pichat-render-message-text
                                                 (pichat-test-compaction-users session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defmacro pichat-test-queue-with-live-chat (&rest body)
  "Run BODY in SESSION's disposable chat, cleaning it even on failure."
  (declare (indent 0))
  `(let ((pichat-chat-stop-session-on-kill nil)
         (buffer (pichat-chat-open session)))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun pichat-test-queue-submit (buffer text &optional steer)
  "Submit image-bearing TEXT through BUFFER's editor, optionally STEER."
  (with-current-buffer buffer
    (pichat-test-set-draft text)
    (setq pichat-chat--pending-attachments (list pichat-test-queue-image))
    (call-interactively (key-binding (kbd (if steer "M-RET" "RET"))))))

(defun pichat-test-queue-wait-count (buffer count)
  "Wait for BUFFER's authoritative queue to contain COUNT items."
  (pichat-test-wait-until
   (lambda () (with-current-buffer buffer (= count (length pichat-chat--pi-queue))))
   5 (format "queue panel count %d" count)))

(defun pichat-test-queue-assert-empty (buffer)
  "Assert BUFFER no longer displays or retains any queued input."
  (with-current-buffer buffer
    (should-not pichat-chat--pi-queue)
    (should-not pichat-chat--queue-candidates)
    (should-not pichat-chat--held-submissions)
    (should (equal '(0 . 0) pichat-chat--queue-counts))
    (should-not (string-match-p "queued in Pi" (buffer-string)))
    (should-not (pichat-chat--retained-attachments))))

(defun pichat-test-queue-assert-user-image (user)
  "Assert USER has the exact submitted image, not just an image indicator."
  (let ((images (cl-remove-if-not
                 (lambda (part) (equal "image" (plist-get part :type)))
                 (plist-get user :content))))
    (should (= 1 (length images)))
    (should (equal (plist-get pichat-test-queue-image :data) (plist-get (car images) :data)))
    (should (equal "image/png" (plist-get (car images) :mimeType)))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-queue-panel-drains-in-native-priority-and-modes ()
    (dolist (mode '("one-at-a-time" "all"))
      (pichat-test-with-integration-session
          (session :script
                   (list :turns
                         (vconcat '((:text "initial" :delayMs 1500)
                                    (:expectContextIncludes "steer" :text "steered" :delayMs 300)
                                    (:expectContextIncludes "follow one" :text "followed" :delayMs 300))
                                  (unless (equal mode "all")
                                    '((:expectContextIncludes "follow two" :text "done"))))))
        (pichat-test-rpc-call session "set_follow_up_mode" (list :mode mode))
        (pichat-test-queue-with-live-chat
          (pichat-test-rpc-call session "prompt" '(:message "start"))
          (pichat-test-wait-for-raw-event session "agent_start")
          (pichat-test-queue-submit buffer "follow one")
          (pichat-test-queue-submit buffer "follow two")
          (pichat-test-queue-submit buffer "steer" t)
          (pichat-test-queue-wait-count buffer 3)
          (with-current-buffer buffer
            (should (equal '("steer" "follow one" "follow two")
                           (mapcar (lambda (r) (plist-get r :text)) pichat-chat--pi-queue)))
            (should (equal '(1 . 2) pichat-chat--queue-counts))
            (should (= 3 (pichat-test-count-substring "[1 img]" (buffer-string)))))
          ;; Observe a real partial drain, not just the final empty snapshot.
          (pichat-test-queue-wait-count buffer 2)
          (with-current-buffer buffer
            (should (equal '("follow one" "follow two")
                           (mapcar (lambda (r) (plist-get r :text)) pichat-chat--pi-queue))))
          (pichat-test-wait-for-raw-event session "agent_settled")
          (let ((users (pichat-test-compaction-users session)))
            (should (equal '("start" "steer[image]" "follow one[image]" "follow two[image]")
                           (mapcar #'pichat-render-message-text users)))
            (mapc #'pichat-test-queue-assert-user-image (cdr users)))
          (pichat-test-queue-assert-empty buffer)))))

  (ert-deftest pichat-integration-queue-panel-abort-restores-images-and-keeps-draft ()
    (pichat-test-with-integration-session
        (session :script '(:turns [(:text "interrupted" :delayMs 2000)
                                  (:text "later reply" :expectContextIncludes "later run")]))
      (pichat-test-queue-with-live-chat
        (pichat-test-rpc-call session "prompt" '(:message "start"))
        (pichat-test-wait-for-raw-event session "agent_start")
        (pichat-test-queue-submit buffer "follow")
        (pichat-test-queue-submit buffer "steer" t)
        (pichat-test-queue-wait-count buffer 2)
        (with-current-buffer buffer
          (pichat-test-set-draft "draft")
          (call-interactively (key-binding (kbd "C-c C-k"))))
        (pichat-test-wait-for-raw-event session "agent_settled")
        (with-current-buffer buffer
          (should (equal "steer\n\nfollow\n\ndraft" (pichat-chat--input-text)))
          (should (equal (list pichat-test-queue-image) pichat-chat--pending-attachments))
          (should-not pichat-chat--pi-queue)
          (should-not (string-match-p "queued in Pi" (buffer-string))))
        ;; An explicit later prompt must not replay either cleared message.
        (pichat-test-prompt-and-wait session "later run")
        (should (equal '("start" "later run")
                       (mapcar #'pichat-render-message-text (pichat-test-compaction-users session)))))))

  (ert-deftest pichat-integration-queue-panel-during-automatic-compaction-and-retry ()
    (dolist (boundary '(threshold overflow retry))
      (ert-info ((format "boundary: %s" boundary))
        (pichat-test-with-integration-session
            (session :settings '(:compaction (:enabled t :reserveTokens 1000 :keepRecentTokens 100)
                                 :retry (:enabled t :maxRetries 2 :baseDelayMs 1000))
                     :script
                     (list :turns
                           (vconcat
                            (pcase boundary
                              ('threshold '((:text "h1" :usage (:input 500 :output 20))
                                            (:text "h2" :usage (:input 127500 :output 20))
                                            (:text "summary" :delayMs 1500)))
                              ('overflow '((:text "h1") (:text "h2")
                                           (:error "maximum context length exceeded")
                                           (:text "summary" :delayMs 1500)
                                           (:text "after overflow")))
                              ('retry '((:error "WebSocket error") (:text "recovered"))))
                            '((:text "queued reply" :expectContextIncludes "during boundary")))))
          (unless (eq boundary 'retry)
            (pichat-test-prompt-and-wait session (concat "one " (make-string 5000 ?a)))
            (when (eq boundary 'overflow)
              (pichat-test-prompt-and-wait session (concat "two " (make-string 5000 ?b)))))
          (pichat-test-queue-with-live-chat
            (pichat-test-rpc-call session (if (eq boundary 'retry) "set_auto_retry" "set_auto_compaction")
                                  '(:enabled t))
            (let ((settled (pichat-test-count-raw-events session "agent_settled")))
              (pichat-test-rpc-call session "prompt"
                                    (list :message (if (eq boundary 'threshold)
                                                       (concat "two " (make-string 5000 ?b)) "start")))
              (pichat-test-wait-for-raw-event
               session (if (eq boundary 'retry) "auto_retry_start" "compaction_start"))
              (pichat-test-queue-submit buffer "during boundary")
              (pichat-test-queue-wait-count buffer 1)
              (with-current-buffer buffer
                (should-not pichat-chat--held-submissions)
                (should (string-match-p "queued in Pi.*follow-up.*during boundary.*1 img" (buffer-string))))
              (pichat-test-wait-for-raw-event session "agent_settled" 15 settled))
            (let ((users (cl-remove-if-not
                          (lambda (u) (equal "during boundary[image]" (pichat-render-message-text u)))
                          (pichat-test-compaction-users session))))
              (should (= 1 (length users)))
              (pichat-test-queue-assert-user-image (car users)))
            (pichat-test-queue-assert-empty buffer))))))

  (ert-deftest pichat-integration-queue-panel-run-ends-during-recall ()
    ;; Delay either actual dispatch (Pi consumes first) or only the real reply
    ;; (clear wins).  Both sides cross real settlement and real clear_queue.
    (dolist (timing '(before-clear after-clear))
      (pichat-test-with-integration-session
          (session :script (list :turns
                                 (vconcat '((:text "initial" :delayMs 1000))
                                          (when (eq timing 'before-clear)
                                            '((:text "consumed" :expectContextIncludes "waiting"))))))
        (pichat-test-queue-with-live-chat
          (pichat-test-rpc-call session "prompt" '(:message "start"))
          (pichat-test-wait-for-raw-event session "agent_start")
          (pichat-test-queue-submit buffer "waiting")
          (pichat-test-queue-wait-count buffer 1)
          (let ((clear (symbol-function 'pichat-backend-clear-session-queue)) delayed response)
            (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
                       (lambda (s success &optional failure)
                         (setq delayed
                               (if (eq timing 'before-clear)
                                   (lambda () (funcall clear s success failure))
                                 (funcall clear s (lambda (&rest args) (setq response args)) failure)
                                 (lambda () (apply success response)))))))
              (with-current-buffer buffer (pichat-chat-recover-submission))
              (pichat-test-wait-for-raw-event session "agent_settled")
              (when (eq timing 'after-clear) (should response))
              (funcall delayed)
              (pichat-test-wait-until
               (lambda () (with-current-buffer buffer (not pichat-chat--queue-recall))))
              (with-current-buffer buffer
                (should (equal (if (eq timing 'before-clear) "" "waiting") (pichat-chat--input-text)))
                (should (equal (unless (eq timing 'before-clear) (list pichat-test-queue-image))
                               pichat-chat--pending-attachments))
                (should-not pichat-chat--recoverable-submissions)
                (should-not pichat-chat--pi-queue)
                (should-not (string-match-p "queued in Pi" (buffer-string))))
              (should (equal (if (eq timing 'before-clear) '("start" "waiting[image]") '("start"))
                             (mapcar #'pichat-render-message-text (pichat-test-compaction-users session)))))))))))

(provide 'pichat-test-queue-panel)
;;; pichat-test-queue-panel.el ends here
