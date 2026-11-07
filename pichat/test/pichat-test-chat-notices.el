;;; pichat-test-chat-notices.el --- Diagnostic notice lifecycle -*- lexical-binding: t; -*-

;;; Commentary:
;; Notice behavior is independent of retained history, source and chat lifetime.

;;; Code:
(require 'pichat-test-support)
(require 'pichat-chat-notices)

(defun pichat-test-notices-response (session id &optional error-text data)
  "Deliver SESSION request ID with ERROR-TEXT or successful DATA."
  (let ((command (plist-get (gethash id (pichat-session-pending-responses session))
                            :command)))
    (pichat-rpc--process-filter
     (pichat-session-process session)
     (concat (pichat-rpc--json-encode
              (list :type "response" :id id :command command
                    :success (if error-text :json-false t)
                    :error error-text :data data)) "\n"))))

(defun pichat-test-notices-fail (session command text)
  "Fail a new SESSION request for COMMAND with TEXT and return its record."
  (pichat-test-notices-response session (pichat-rpc-send session command nil nil) text)
  (pichat-chat-diagnostics-latest session))

(ert-deftest pichat-notices-dismiss-preserves-draft-history-and-reopen ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (attachment '(:id "pending" :name "image.png" :bytes 1))
          buffer inspector)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-input-text "keep this draft")
              (setq pichat-chat--pending-attachments (list attachment)))
            (let ((record (pichat-test-notices-fail
                           session "compact" "summary failed token=private")))
              (should (string-match-p "summary failed" (pichat-test-buffer-text buffer)))
              (should-not (string-match-p "private" (pichat-test-buffer-text buffer)))
              (with-current-buffer buffer
                (should (eq (key-binding (kbd "C-c C-0"))
                            #'pichat-chat-dismiss-diagnostic-notices))
                (execute-kbd-macro (kbd "C-c C-0"))
                (should (equal "keep this draft" (pichat-chat--input-text)))
                (should (equal (list attachment) pichat-chat--pending-attachments)))
              (should (process-live-p proc))
              (should (memq record (pichat-session-diagnostics session)))
              (should (eq 'dismissed (plist-get record :notice-state))))
            (pichat-chat-ensure session)
            (should-not (string-match-p "summary failed" (pichat-test-buffer-text buffer)))
            (kill-buffer buffer)
            (setq buffer (pichat-chat-open session))
            (should-not (string-match-p "summary failed" (pichat-test-buffer-text buffer)))
            (setq inspector (pichat-show-diagnostics session))
            (should (string-match-p "summary failed" (pichat-test-buffer-text inspector)))
            ;; Identical text is a new failure, not an already-dismissed identity.
            (pichat-test-notices-fail session "compact" "summary failed token=private")
            (should (string-match-p "summary failed" (pichat-test-buffer-text buffer))))
        (when (buffer-live-p inspector) (kill-buffer inspector))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-compaction-recovers-only-captured-operation-errors ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let* ((old (pichat-test-notices-fail session "compact" "old compact failure"))
                   (independent (pichat-test-notices-fail session "set_model" "independent failure"))
                   (id (pichat-rpc-send session "compact" nil nil))
                   (newer (pichat-test-notices-fail session "compact" "new compact failure")))
              (pichat-test-notices-response session id nil '(:aborted :json-false))
              (should (eq 'resolved (plist-get old :notice-state)))
              (should-not (plist-get newer :notice-state))
              (should-not (plist-get independent :notice-state))
              (should-not (string-match-p "old compact failure" (pichat-test-buffer-text buffer)))
              (should (string-match-p "new compact failure" (pichat-test-buffer-text buffer)))
              (should (string-match-p "independent failure" (pichat-test-buffer-text buffer)))
              ;; Duplicate success cannot resolve a failure that came afterward.
              (pichat-rpc--process-filter
               proc (concat (pichat-rpc--json-encode
                             (list :type "response" :id id :command "compact" :success t)) "\n"))
              (should-not (plist-get newer :notice-state))
              (pichat-test-notices-response session (pichat-rpc-send session "compact" nil nil))
              (should (eq 'resolved (plist-get newer :notice-state)))
              (pichat-chat-ensure session)
              (should-not (string-match-p "compact failure" (pichat-test-buffer-text buffer)))
              (should (string-match-p "independent failure" (pichat-test-buffer-text buffer)))
              (should (= 3 (length (pichat-session-diagnostics session))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-manual-events-cannot-widen-request-recovery ()
  (pichat-test-with-unit-session (session proc)
    (let* ((old (pichat-test-notices-fail session "compact" "old manual failure"))
           (id (pichat-rpc-send session "compact" nil nil))
           (newer (pichat-test-notices-fail session "compact" "intervening failure")))
      (pichat-rpc--process-filter
       proc "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n")
      (pichat-rpc--process-filter
       proc "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
      (should-not (plist-get old :notice-state))
      (should-not (plist-get newer :notice-state))
      (pichat-test-notices-response session id)
      (should (eq 'resolved (plist-get old :notice-state)))
      (should-not (plist-get newer :notice-state)))))

(ert-deftest pichat-notices-many-failures-keep-bounded-dismissal-help ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (dotimes (_ 20)
              (pichat-test-notices-fail session "set_model" (make-string 320 ?x)))
            (with-current-buffer buffer
              (let ((text (cdr (assq 'error pichat-chat--status-lines))))
                (should (<= (string-width text) 4000))
                (should (string-match-p "C-c C-0: dismiss" text)))
              (pichat-chat-dismiss-diagnostic-notices))
            (should-not (pichat-chat-notices-current session))
            (should (= 20 (length (pichat-session-diagnostics session)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-unrelated-failed-and-aborted-requests-do-not-recover ()
  (pichat-test-with-unit-session (session proc)
    (let ((record (pichat-test-notices-fail session "compact" "still failed")))
      (pichat-test-notices-response session (pichat-rpc-send session "get_state" nil nil)
                                   nil (list :sessionId (pichat-session-id session)))
      (pichat-test-notices-response session (pichat-rpc-send session "get_session_stats" nil nil))
      (pichat-test-notices-response session (pichat-rpc-send session "compact" nil nil) nil '(:aborted t))
      (pichat-test-notices-response session (pichat-rpc-send session "compact" nil nil) nil '(:cancelled t))
      (pichat-test-notices-fail session "compact" "still failed")
      (should-not (plist-get record :notice-state))
      (should (= 2 (length (pichat-chat-notices-current session)))))))

(ert-deftest pichat-notices-compaction-events-require-a-current-start-and-snapshot ()
  (pichat-test-with-unit-session (session proc)
    (let ((old (pichat-test-notices-fail session "compact" "old event failure")))
      (dolist (end '("{\"type\":\"compaction_end\",\"aborted\":true}\n"
                     "{\"type\":\"compaction_end\",\"errorMessage\":\"failed\"}\n"))
        (pichat-rpc--process-filter proc "{\"type\":\"compaction_start\"}\n")
        (pichat-rpc--process-filter proc end)
        (should-not (plist-get old :notice-state)))
      ;; A bare/duplicate successful end is not a recovery authority.
      (pichat-rpc--process-filter proc "{\"type\":\"compaction_end\",\"aborted\":false}\n")
      (should-not (plist-get old :notice-state))
      (pichat-rpc--process-filter proc "{\"type\":\"compaction_start\"}\n")
      (let ((newer (pichat-test-notices-fail session "compact" "new event failure")))
        ;; Duplicate starts must not widen the original recovery snapshot.
        (pichat-rpc--process-filter proc "{\"type\":\"compaction_start\"}\n")
        (pichat-rpc--process-filter proc "{\"type\":\"compaction_end\",\"aborted\":false}\n")
        (should (eq 'resolved (plist-get old :notice-state)))
        (should-not (plist-get newer :notice-state))
        (pichat-rpc--process-filter proc "{\"type\":\"compaction_end\",\"aborted\":false}\n")
        (should-not (plist-get newer :notice-state))))))

(ert-deftest pichat-notices-source-rebinding-retires-old-context-and-late-responses ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (setf (pichat-session-id session) "source-a")
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let* ((old (pichat-test-notices-fail session "compact" "old source failure"))
                   (late-failure (pichat-rpc-send session "compact" nil nil))
                   (late-success (pichat-rpc-send session "compact" nil nil))
                   (runtime-wide (pichat-chat-diagnostics-record
                                  session :origin 'process-exit :message "runtime failure")))
              (pichat-test-notices-response session (pichat-rpc-send session "new_session" nil nil))
              (pichat-session-apply-rpc-state session '(:sessionId "source-b"))
              (pichat-emit session 'session-state-changed)
              (should-not (memq old (pichat-chat-notices-current session)))
              (should (memq runtime-wide (pichat-chat-notices-current session)))
              (let ((newer (pichat-test-notices-fail session "compact" "new source failure")))
                (pichat-test-notices-response session late-failure "late source failure")
                (pichat-test-notices-response session late-success)
                (should-not (plist-get newer :notice-state))
                (should-not (string-match-p "old source failure\\|late source failure"
                                            (pichat-test-buffer-text buffer)))
                (should (string-match-p "new source failure" (pichat-test-buffer-text buffer))))
              ;; Going back does not reauthorize failures from the old epoch.
              (pichat-session-apply-rpc-state session '(:sessionId "source-a"))
              (pichat-emit session 'session-state-changed)
              (pichat-chat-ensure session)
              (should-not (memq old (pichat-chat-notices-current session)))
              (should (memq runtime-wide (pichat-chat-notices-current session)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-restart-invalidates-notices-and-recovery-with-same-source ()
  (pichat-test-with-unit-session (session proc)
    (let* ((old (pichat-test-notices-fail session "compact" "previous process failure"))
           (runtime-wide (pichat-chat-diagnostics-record session :origin 'process-exit))
           (id (pichat-rpc-send session "compact" nil nil)))
      (pichat-rpc--process-filter proc "{\"type\":\"compaction_start\"}\n")
      (setf (pichat-session-process-generation session) 'replacement-process)
      (let ((newer (pichat-test-notices-fail session "compact" "replacement failure")))
        (pichat-test-notices-response session id)
        (pichat-rpc--process-filter proc "{\"type\":\"compaction_end\",\"aborted\":false}\n")
        (should-not (plist-get newer :notice-state))
        (should-not (memq old (pichat-chat-notices-current session)))
        (should-not (memq runtime-wide (pichat-chat-notices-current session)))))))

(ert-deftest pichat-notices-sync-recovers-parse-history-without-clearing-other-errors ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter proc "malformed output\n")
            (let ((record (pichat-chat-diagnostics-latest session))
                  (other (pichat-test-notices-fail session "set_model" "model still failed")))
              (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                         (lambda (_session &optional _since callback _error)
                           (funcall callback '(:data (:entries nil :leafId nil)) session))))
                (with-current-buffer buffer (pichat-chat--request-sync t)))
              (should (eq 'resolved (plist-get record :notice-state)))
              (should-not (plist-get other :notice-state))
              (kill-buffer buffer)
              (setq buffer (pichat-chat-open session))
              (should-not (string-match-p "malformed RPC output" (pichat-test-buffer-text buffer)))
              (should (string-match-p "model still failed" (pichat-test-buffer-text buffer)))
              (should (memq record (pichat-session-diagnostics session))))
            (pichat-rpc--process-filter proc "another malformed output\n")
            (should (string-match-p "malformed RPC output" (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-event-only-failure-is-retained-and-recovers-without-chat ()
  (pichat-test-with-unit-session (session proc)
    (pichat-rpc--process-filter
     proc "{\"type\":\"compaction_start\",\"reason\":\"auto\"}\n")
    (pichat-rpc--process-filter
     proc "{\"type\":\"compaction_end\",\"reason\":\"auto\",\"errorMessage\":\"auto failed\"}\n")
    (let ((record (pichat-chat-diagnostics-latest session)))
      (should (memq record (pichat-chat-notices-current session)))
      (pichat-rpc--process-filter
       proc "{\"type\":\"compaction_start\",\"reason\":\"auto\"}\n")
      ;; A mismatched event cannot consume this attempt's recovery authority.
      (pichat-rpc--process-filter
       proc "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
      (should-not (plist-get record :notice-state))
      (pichat-rpc--process-filter
       proc "{\"type\":\"compaction_end\",\"reason\":\"auto\",\"aborted\":false}\n")
      (should (eq 'resolved (plist-get record :notice-state)))
      (should (memq record (pichat-session-diagnostics session)))
      (let ((pichat-chat-stop-session-on-kill nil)
            (buffer (pichat-chat-ensure session)))
        (unwind-protect
            (should-not (string-match-p "auto failed" (pichat-test-buffer-text buffer)))
          (kill-buffer buffer))))))

(ert-deftest pichat-notices-sync-does-not-resolve-a-newer-parse-failure ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer callback)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter proc "first malformed output\n")
            (let ((old (pichat-chat-diagnostics-latest session)))
              (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                         (lambda (_session &optional _since success _error)
                           (setq callback success))))
                (with-current-buffer buffer (pichat-chat--request-sync t)))
              (pichat-rpc--process-filter proc "newer malformed output\n")
              (let ((newer (pichat-chat-diagnostics-latest session)))
                (funcall callback '(:data (:entries nil :leafId nil)) session)
                (should (eq 'resolved (plist-get old :notice-state)))
                (should-not (plist-get newer :notice-state))
                (pichat-chat-ensure session)
                (should (string-match-p "malformed RPC output" (pichat-test-buffer-text buffer))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-auto-expire-with-history-draft-and-reopen-preserved ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-diagnostics-notice-timeout 0.1)
          (attachment '(:id "pending" :name "image.png" :bytes 1))
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-input-text "keep draft")
              (setq pichat-chat--pending-attachments (list attachment)))
            (let ((record (pichat-test-notices-fail session "compact" "expires shortly")))
              (should (string-match-p "expires shortly" (pichat-test-buffer-text buffer)))
              (pichat-test-wait-until
               (lambda () (not (string-match-p "expires shortly" (pichat-test-buffer-text buffer))))
               2 "automatic notice dismissal")
              (with-current-buffer buffer
                (should (equal "keep draft" (pichat-chat--input-text)))
                (should (equal (list attachment) pichat-chat--pending-attachments))
                (should-not pichat-chat--diagnostic-notice-timer))
              (should (memq record (pichat-session-diagnostics session)))
              (should (process-live-p proc))
              (kill-buffer buffer)
              (setq buffer (pichat-chat-open session))
              (should-not (string-match-p "expires shortly" (pichat-test-buffer-text buffer)))
              (pichat-test-notices-fail session "compact" "expires shortly")
              (should (string-match-p "expires shortly" (pichat-test-buffer-text buffer)))
              (let ((timer (buffer-local-value 'pichat-chat--diagnostic-notice-timer buffer)))
                (should (timerp timer))
                (kill-buffer buffer)
                (should-not (memq timer timer-list)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-expiry-callbacks-cannot-hide-newer-or-rebound-notices ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-diagnostics-notice-timeout 5)
          callbacks buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_time _repeat callback &rest args)
                         (push (lambda () (apply callback args)) callbacks)
                         nil)))
              (let* ((old (pichat-test-notices-fail session "compact" "old expiry"))
                     (stale (car callbacks)))
                (pichat-test-notices-fail session "set_model" "new expiry")
                (setf (plist-get old :notice-expires-at) (- (float-time) 1))
                (funcall (car callbacks))
                (should-not (string-match-p "old expiry" (pichat-test-buffer-text buffer)))
                (should (string-match-p "new expiry" (pichat-test-buffer-text buffer)))
                (let ((count (length callbacks)))
                  (funcall stale)
                  (should (= count (length callbacks)))
                  (should (string-match-p "new expiry" (pichat-test-buffer-text buffer)))))
              (let ((stale (car callbacks)))
                (pichat-session-apply-rpc-state session '(:sessionId "replacement"))
                (pichat-emit session 'session-state-changed)
                (pichat-test-notices-fail session "compact" "rebound expiry")
                (let ((count (length callbacks)))
                  (funcall stale)
                  (should (= count (length callbacks)))
                  (should (string-match-p "rebound expiry" (pichat-test-buffer-text buffer)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-notices-disabled-timeout-remains-manually-dismissible ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-diagnostics-notice-timeout nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((record (pichat-test-notices-fail session "compact" "manual notice")))
              (setf (plist-get record :time) (seconds-to-time 0))
              (with-current-buffer buffer
                (pichat-chat--project-diagnostic-notices session)
                (should-not pichat-chat--diagnostic-notice-timer)
                (should (string-match-p "manual notice" (pichat-test-buffer-text buffer)))
                (pichat-chat-dismiss-diagnostic-notices))
              (should (memq record (pichat-session-diagnostics session)))
              (should-not (pichat-chat-notices-current session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-notices-real-compaction-failure-dismiss-repeat-recover ()
    (pichat-test-with-integration-session
        (session :settings '(:compaction (:enabled t :reserveTokens 1000 :keepRecentTokens 100))
                 :script '(:turns [(:text "history one" :usage (:input 500 :output 20))
                                   (:text "history two" :usage (:input 700 :output 20))
                                   (:error "repeatable summary failure")
                                   (:error "repeatable summary failure")
                                   (:text "abort this summary" :delayMs 5000)
                                   (:text "successful compact summary" :usage (:input 200 :output 30))]))
      (let ((pichat-chat-stop-session-on-kill nil) buffer)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (pichat-test-chat-send-and-wait session buffer (make-string 2200 ?a) 8)
              (pichat-test-chat-send-and-wait session buffer (make-string 2200 ?b) 8)
              (dotimes (attempt 2)
                ;; No error callback: exercise the actual chat diagnostic path.
                (let ((before (pichat-chat-diagnostics-latest session)))
                  (pichat-rpc-compact session)
                  (pichat-test-wait-until
                   (lambda () (not (eq before (pichat-chat-diagnostics-latest session))))
                   8 "retained real compaction failure"))
                (should (string-match-p "repeatable summary failure" (pichat-test-buffer-text buffer)))
                (if (zerop attempt)
                    (progn
                      (with-current-buffer buffer
                        (pichat-chat--set-input-text "draft survives")
                        (call-interactively #'pichat-chat-dismiss-diagnostic-notices))
                      (pichat-chat-ensure session)
                      (should-not (string-match-p "repeatable summary failure" (pichat-test-buffer-text buffer))))
                  (should (= 1 (length (pichat-chat-notices-current session))))))
              ;; Polling does not resolve the repeated failure.
              (pichat-test-rpc-call session "get_state")
              (should (string-match-p "repeatable summary failure" (pichat-test-buffer-text buffer)))
              (let ((previous (car (pichat-chat-notices-current session))) aborted-response)
                (pichat-rpc-send
                 session "compact" nil
                 (lambda (response _session) (setq aborted-response response))
                 (lambda (response _session) (setq aborted-response response)))
                (pichat-test-wait-until
                 (lambda () (= 5 (or (plist-get (pichat-test-provider-status status-file) :turnIndex) 0)))
                 4 "fake summary call started before abort")
                (pichat-test-rpc-call session "abort" nil 8)
                (pichat-test-wait-until (lambda () aborted-response) 4 "aborted compact response")
                (should-not (plist-get aborted-response :success))
                (should-not (plist-get previous :notice-state))
                (should (string-match-p "repeatable summary failure" (pichat-test-buffer-text buffer))))
              (pichat-test-rpc-call session "compact" nil 8)
              (pichat-test-wait-until
               (lambda () (null (pichat-chat-notices-current session))) 4 "recovered compaction notice")
              (pichat-chat-ensure session)
              (should-not (string-match-p "repeatable summary failure" (pichat-test-buffer-text buffer)))
              (with-current-buffer buffer
                (should (equal "draft survives" (pichat-chat--input-text))))
              (should (= 3 (length (pichat-session-diagnostics session))))
              (should (equal '(resolved resolved dismissed)
                             (mapcar (lambda (record) (plist-get record :notice-state))
                                     (pichat-session-diagnostics session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-chat-notices)
;;; pichat-test-chat-notices.el ends here
