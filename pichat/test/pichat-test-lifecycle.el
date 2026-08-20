;;; pichat-test-lifecycle.el --- Pichat Test Lifecycle -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-idle-custom-message-and-compaction-trigger-sync ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since _callback _error)
                         (push (and (not (functionp since)) since) calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"visible-note\",\"content\":\"idle update\",\"display\":true}}\n")
              (should (= 1 (length calls)))
              (with-current-buffer buffer
                (setq pichat-chat--sync-in-flight nil))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (should (= 2 (length calls))))
            (with-current-buffer buffer
              (should (equal '(nil nil) calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-live-draft-preserves-successful-compaction-preview ()
  (let ((draft (pichat-live-draft-empty 0)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "compaction_end"
       :result (:summary "bounded summary" :tokensBefore 42)))
    (let ((node (car (pichat-live-draft-nodes draft))))
      (should (eq 'activity (pichat-transcript-node-kind node)))
      (should (= 42 (pichat-transcript-node-tokens-before node)))
      (should (equal "bounded summary"
                     (pichat-transcript-node-summary node))))))

(ert-deftest pichat-chat-aborted-compaction-does-not-request-sync-or-stats ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (sync-calls 0) (stats-calls 0) buffer)
      (setf (pichat-session-state session) 'compacting)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf sync-calls)))
                      ((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (&rest _args) (cl-incf stats-calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":true}\n"))
            (should (= 0 sync-calls))
            (should (= 0 stats-calls))
            (should (eq 'idle (pichat-session-state session)))
            (should (string-match-p "compaction aborted"
                                    (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-failed-compaction-uses-error-message-without-refresh ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (sync-calls 0) (stats-calls 0) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf sync-calls)))
                      ((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (&rest _args) (cl-incf stats-calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false,\"errorMessage\":\"summary failed\"}\n"))
            (should (= 0 sync-calls))
            (should (= 0 stats-calls))
            (should (string-match-p "compaction failed: summary failed"
                                    (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-compaction-displays-unknown-context-usage ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          stats-callback buffer)
      (setf (pichat-session-context-usage session)
            '(:tokens 90 :contextWindow 100 :percent 90))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional _error-callback)
                         (setq stats-callback callback)
                         "stats"))
                      ((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "entries")))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (should stats-callback)
              (pichat-session-apply-rpc-stats
               session '(:contextUsage
                         (:tokens nil :contextWindow 100 :percent nil)))
              (funcall stats-callback '(:success t) session))
            (with-current-buffer buffer
              (should (string-match-p
                       "?/100" (pichat-chat--mode-line-status)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-compaction-covers-settlement-stats ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          stats-callback
          (stats-calls 0)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional _error-callback)
                         (cl-incf stats-calls)
                         (setq stats-callback callback)
                         "stats"))
                      ((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "entries")))
              (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (funcall stats-callback '(:success t) session)
              (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
              (should (= 1 stats-calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-idle-custom-sync-coalesces-one-settlement-follow-up ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          callbacks buffer)
      (setf (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session _since callback &optional _error)
                         (setq callbacks (append callbacks (list callback))))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"extension-visible\",\"display\":true,\"content\":\"persisted extension message\"}}\n")
              (should (= 1 (length callbacks)))
              (pichat-rpc--process-filter
               proc "{\"type\":\"agent_settled\"}\n")
              (should (= 1 (length callbacks)))
              (funcall (car callbacks)
                       '(:data (:entries nil :leafId nil)) session)
              (should (= 2 (length callbacks)))
              (funcall (cadr callbacks)
                       '(:data (:entries nil :leafId nil)) session)
              (with-current-buffer buffer
                (should-not pichat-chat--sync-in-flight)
                (should-not pichat-chat--sync-pending))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-running-custom-message-defers-to-settlement-sync ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-state session) 'running)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"visible-note\",\"content\":\"running update\",\"display\":true}}\n"))
            (should-not calls))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-lifecycle-notices-use-dedicated-status-region ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n")
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "compaction started")
              (let ((position (match-beginning 0)))
                (should (<= (marker-position pichat-chat--status-start)
                            position))
                (should (< position
                           (marker-position pichat-chat--status-end)))
                (should (get-text-property position 'pichat-status))
                (should-not (get-text-property position
                                               'pichat-node-key))))
            (pichat-rpc--process-filter
             proc "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
            (should-not (string-match-p "compaction started"
                                        (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-compaction-and-retry-events-are-visible ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter proc
             "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n")
            (should (eq 'compacting (pichat-session-state session)))
            (should (string-match-p "compaction started"
                                    (pichat-test-buffer-text buffer)))
            (pichat-rpc--process-filter proc
             "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
            (pichat-rpc--process-filter proc
             "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":3,\"delayMs\":20,\"errorMessage\":\"busy\"}\n")
            (should (eq 'retrying (pichat-session-state session)))
            (with-current-buffer buffer
              (should (string-prefix-p "↻" (pichat-chat--mode-line-status))))
            (should (string-match-p "retry 1/3"
                                    (pichat-test-buffer-text buffer)))
            (pichat-rpc--process-filter proc
             "{\"type\":\"auto_retry_end\",\"success\":true,\"attempt\":1}\n")
            (should (eq 'idle (pichat-session-state session)))
            (let ((text (pichat-test-buffer-text buffer)))
              (should-not (string-match-p "compaction started" text))
              (should-not (string-match-p "retry 1/3" text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-lifecycle)
;;; pichat-test-lifecycle.el ends here
