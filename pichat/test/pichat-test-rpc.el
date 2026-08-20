;;; pichat-test-rpc.el --- Pichat Test Rpc -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

;;; Transport unit tests

(ert-deftest pichat-session-persistence-defaults-to-persistent ()
  (should (eq 'persistent
              (pichat-session-persistence (pichat-session-make)))))

(ert-deftest pichat-rpc-build-command-includes-default-model ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model "test/model")
        (pichat-pi-session-dir "/tmp/sessions")
        (pichat-bridge-extension-file nil)
        (pichat-pi-extra-args '("--offline")))
    (should (equal '("/opt/pi" "--mode" "rpc"
                     "--model" "test/model"
                     "--session-dir" "/tmp/sessions"
                     "--offline")
                   (pichat-rpc-build-command)))))

(ert-deftest pichat-rpc-build-command-run-local-model-is-authoritative ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model "default/model")
        (pichat-pi-session-dir nil)
        (pichat-bridge-extension-file nil)
        (pichat-pi-extra-args '("--model" "extra/model" "--offline"))
        (session (pichat-session-make :startup-model "run/model")))
    (should (equal '("/opt/pi" "--mode" "rpc"
                     "--model" "extra/model" "--offline"
                     "--model" "run/model")
                   (pichat-rpc-build-command session)))))

(ert-deftest pichat-rpc-build-command-inserts-ephemeral-flag-before-extra-args ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model "test/model")
        (pichat-pi-session-dir "/tmp/sessions")
        (pichat-bridge-extension-file "/tmp/bridge.ts")
        (pichat-pi-extra-args '("--offline"))
        (session (pichat-session-make :persistence 'ephemeral)))
    (should (equal '("/opt/pi" "--mode" "rpc"
                     "--model" "test/model"
                     "--session-dir" "/tmp/sessions"
                     "-e" "/tmp/bridge.ts"
                     "--no-session"
                     "--offline")
                   (pichat-rpc-build-command session)))))

(ert-deftest pichat-rpc-build-command-ignores-default-model-for-complete-command ()
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (pichat-default-model "test/model"))
    (should (equal pichat-rpc-command (pichat-rpc-build-command)))))

(ert-deftest pichat-rpc-build-command-preserves-complete-command-for-persistent-session ()
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (session (pichat-session-make :persistence 'persistent)))
    (should (equal pichat-rpc-command (pichat-rpc-build-command session)))))

(ert-deftest pichat-rpc-build-command-rejects-run-local-model-complete-command ()
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (session (pichat-session-make :startup-model "run/model")))
    (should-error (pichat-rpc-build-command session) :type 'user-error)))

(ert-deftest pichat-rpc-build-command-rejects-ephemeral-complete-command ()
  (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
        (session (pichat-session-make :persistence 'ephemeral)))
    (should-error (pichat-rpc-build-command session) :type 'user-error)))

(ert-deftest pichat-rpc-build-command-omits-blank-default-model ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model "  ")
        (pichat-pi-session-dir nil)
        (pichat-bridge-extension-file nil)
        (pichat-pi-extra-args nil))
    (should (equal '("pi" "--mode" "rpc")
                   (pichat-rpc-build-command)))))

(ert-deftest pichat-rpc-filter-dispatches-split-jsonl-once ()
  (pichat-test-with-unit-session (session proc)
    (let (events)
      (pichat-on 'message-update
                 (lambda (_session event plist)
                   (push (cons event plist) events))
                 session)
      (pichat-rpc--process-filter proc "{\"type\":\"message_update\",\"messageId\":\"m1\"")
      (should (null events))
      (pichat-rpc--process-filter proc ",\"delta\":\"hello\"}\n")
      (should (= 1 (length events)))
      (should (equal "hello" (plist-get (plist-get (cdar events) :raw) :delta))))))

(ert-deftest pichat-rpc-filter-parses-multiple-jsonl-records-in-one-chunk ()
  (pichat-test-with-unit-session (session proc)
    (let (events)
      (pichat-on 'agent-start (lambda (_s event _p) (push event events)) session)
      (pichat-on 'agent-settled (lambda (_s event _p) (push event events)) session)
      (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n{\"type\":\"agent_settled\"}\n")
      (should (equal '(agent-settled agent-start) events))
      (should (eq (pichat-session-state session) 'idle)))))

(ert-deftest pichat-rpc-active-run-survives-retry-and-compaction-phase-ends ()
  (pichat-test-with-unit-session (session proc)
    (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
    (should (pichat-session-streaming-p session))
    (should (eq (pichat-session-state session) 'running))

    (pichat-rpc--process-filter
     proc
     "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":3,\"delayMs\":20}\n")
    (should (eq (pichat-session-state session) 'retrying))
    (pichat-rpc--process-filter
     proc "{\"type\":\"auto_retry_end\",\"success\":true,\"attempt\":1}\n")
    (should-not (pichat-session-retrying-p session))
    (should (eq (pichat-session-state session) 'running))

    (pichat-rpc--process-filter
     proc "{\"type\":\"tool_execution_start\",\"toolCallId\":\"call-1\",\"toolName\":\"bash\"}\n")
    (should (eq (pichat-session-state session) 'running))
    (pichat-rpc--process-filter
     proc "{\"type\":\"compaction_start\",\"reason\":\"overflow\"}\n")
    (should (pichat-session-compacting-p session))
    (should (eq (pichat-session-state session) 'compacting))
    (pichat-rpc--process-filter
     proc "{\"type\":\"compaction_end\",\"reason\":\"overflow\",\"willRetry\":true}\n")
    (should-not (pichat-session-compacting-p session))
    (should (eq (pichat-session-state session) 'running))

    (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
    (should-not (pichat-session-streaming-p session))
    (should (eq (pichat-session-state session) 'idle))))

(ert-deftest pichat-rpc-filter-strips-crlf-records ()
  (pichat-test-with-unit-session (session proc)
    (let (seen)
      (pichat-on 'agent-start (lambda (_s _e _p) (setq seen t)) session)
      (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\r\n")
      (should seen)
      (should (eq (pichat-session-state session) 'running)))))

(ert-deftest pichat-rpc-filter-preserves-unicode-line-separator-inside-json-string ()
  (pichat-test-with-unit-session (session proc)
    (let (delta)
      (pichat-on 'message-update
                 (lambda (_session _event plist)
                   (setq delta (plist-get (plist-get plist :raw) :delta)))
                 session)
      (pichat-rpc--process-filter
       proc
       (concat "{\"type\":\"message_update\",\"delta\":\"a" (string #x2028) "b\"}\n"))
      (should (equal delta (concat "a" (string #x2028) "b"))))))

(ert-deftest pichat-rpc-filter-emits-error-for-malformed-json-and-continues ()
  (pichat-test-with-unit-session (session proc)
    (let (errors started)
      (pichat-on 'error (lambda (_s _e plist) (push plist errors)) session)
      (pichat-on 'agent-start (lambda (_s _e _p) (setq started t)) session)
      (pichat-rpc--process-filter proc "{not json}\n{\"type\":\"agent_start\"}\n")
      (should (= 1 (length errors)))
      (let ((diagnostic (plist-get (car errors) :diagnostic)))
        (should (eq 'rpc-parse (plist-get diagnostic :origin)))
        (should (equal "{not json}" (plist-get diagnostic :response))))
      (should (string-match-p "malformed RPC output"
                              (plist-get (car errors) :message)))
      (should-not (plist-member (car errors) :line))
      (should started))))

(ert-deftest pichat-rpc-response-success-dispatches-callback-and-removes-pending ()
  (pichat-test-with-unit-session (session proc)
    (let (callback-response callback-session)
      (let ((id (pichat-rpc-send session "get_state" nil
                                  (lambda (response s)
                                    (setq callback-response response
                                          callback-session s)))))
        (should (gethash id (pichat-session-pending-responses session)))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"s1\",\"isStreaming\":false}}\n" id))
        (should (null (gethash id (pichat-session-pending-responses session))))
        (should (eq callback-session session))
        (should (equal "s1" (pichat-session-id session)))
        (should (equal "s1" (plist-get (plist-get callback-response :data) :sessionId)))))))

(ert-deftest pichat-rpc-successful-rebind-emits-before-command-callback ()
  (pichat-test-with-unit-session (session proc)
    (let (order)
      (pichat-on 'session-rebinding
                 (lambda (_session _event plist)
                   (push (list 'rebind (plist-get plist :command)) order))
                 session)
      (let ((id (pichat-rpc-send
                 session "switch_session" '(:sessionPath "/sanitized/new.jsonl")
                 (lambda (_response _session) (push '(callback) order)))))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"switch_session\",\"success\":true,\"data\":{}}\n"
                 id))
        (should (equal '((rebind "switch_session") (callback))
                       (nreverse order)))))))

(ert-deftest pichat-rpc-cancelled-rebind-calls-back-without-rebinding ()
  (pichat-test-with-unit-session (session proc)
    (let (order callback-response)
      (pichat-on 'session-rebinding
                 (lambda (&rest _args) (push 'rebind order))
                 session)
      (let ((id (pichat-rpc-switch-session
                 session "/sanitized/new.jsonl"
                 (lambda (response _session)
                   (setq callback-response response)
                   (push 'callback order)))))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"switch_session\",\"success\":true,\"data\":{\"cancelled\":true}}\n"
                 id))
        (should (equal '(callback) (nreverse order)))
        (should (eq t (plist-get (plist-get callback-response :data)
                                 :cancelled)))))))

(ert-deftest pichat-rpc-tree-and-rebind-wrappers-dispatch-failures ()
  (pichat-test-with-unit-session (session proc)
    (dolist (case '(("get_tree" get-tree)
                    ("switch_session" switch-session)
                    ("fork" fork)
                    ("clone" clone)))
      (let (error-response
            (command (car case)))
        (pcase (cadr case)
          ('get-tree
           (pichat-rpc-get-tree session nil
                                (lambda (response _session)
                                  (setq error-response response))))
          ('switch-session
           (pichat-rpc-switch-session session "/sanitized/new.jsonl" nil
                                      (lambda (response _session)
                                        (setq error-response response))))
          ('fork
           (pichat-rpc-fork session "entry-1" nil
                            (lambda (response _session)
                              (setq error-response response))))
          ('clone
           (pichat-rpc-clone session nil
                             (lambda (response _session)
                               (setq error-response response)))))
        (let ((id (format "pichat-%d" (pichat-session-rpc-seq session))))
          (pichat-rpc--process-filter
           proc
           (format "{\"type\":\"response\",\"id\":%S,\"command\":%S,\"success\":false,\"error\":\"rejected\"}\n"
                   id command)))
        (should (equal "rejected" (plist-get error-response :error)))))))

(ert-deftest pichat-rpc-rebind-cancels-and-ignores-older-get-state-response ()
  (pichat-test-with-unit-session (session proc)
    (let (state-events)
      (pichat-on 'session-state-changed
                 (lambda (&rest _args) (cl-incf state-events)) session)
      (let ((old-state-id (pichat-rpc-send session "get_state" nil nil))
            (rebind-id (pichat-rpc-send session "switch_session"
                                        '(:sessionPath
                                          "/sanitized/new.jsonl") nil)))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"switch_session\",\"success\":true,\"data\":{}}\n"
                 rebind-id))
        (should-not (gethash old-state-id
                             (pichat-session-pending-responses session)))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"stale-session\"}}\n"
                 old-state-id))
        (should-not (equal "stale-session" (pichat-session-id session)))
        (should-not state-events)))))

(ert-deftest pichat-rpc-rebind-cancels-stats-clears-usage-and-ignores-late-response ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-rpc-request-timeout 30)
          cancelled-response
          context-at-rebind
          stats-timer)
      (setf (pichat-session-context-usage session)
            '(:tokens 45 :contextWindow 100 :percent 45))
      (pichat-on 'session-rebinding
                 (lambda (rebound-session _event _plist)
                   (setq context-at-rebind
                         (pichat-session-context-usage rebound-session)))
                 session)
      (let* ((stats-id
              (pichat-rpc-get-session-stats
               session nil
               (lambda (response _session)
                 (setq cancelled-response response))))
             (pending (gethash stats-id
                               (pichat-session-pending-responses session)))
             (rebind-id (pichat-rpc-switch-session
                         session "/sanitized/new.jsonl" nil)))
        (setq stats-timer (pichat-rpc--pending-timer pending))
        (should (timerp stats-timer))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"switch_session\",\"success\":true,\"data\":{}}\n"
                 rebind-id))
        (should-not (gethash stats-id
                             (pichat-session-pending-responses session)))
        (should-not (memq stats-timer timer-list))
        (should-not context-at-rebind)
        (should-not (pichat-session-context-usage session))
        (should (eq 'cancelled
                    (plist-get cancelled-response :pichat-failure-kind)))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"contextUsage\":{\"tokens\":99,\"contextWindow\":100,\"percent\":99}}}\n"
                 stats-id))
        (should-not (pichat-session-context-usage session))))))

(ert-deftest pichat-rpc-response-failure-dispatches-error-callback-and-removes-pending ()
  (pichat-test-with-unit-session (session proc)
    (let (error-response)
      (let ((id (pichat-rpc-send session "bogus" nil nil
                                  (lambda (response _s)
                                    (setq error-response response)))))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"bogus\",\"success\":false,\"error\":\"nope\"}\n" id))
        (should (null (gethash id (pichat-session-pending-responses session))))
        (should (equal "nope" (plist-get error-response :error)))))))

(ert-deftest pichat-rpc-response-failure-without-error-callback-emits-error ()
  (pichat-test-with-unit-session (session proc)
    (let (emitted)
      (pichat-on 'error (lambda (_s _e plist) (setq emitted plist)) session)
      (let ((id (pichat-rpc-send session "bogus" nil nil)))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"bogus\",\"success\":false,\"error\":\"bad command\"}\n" id))
        (should (equal "Pi rejected an RPC command: bad command"
                       (plist-get emitted :message)))
        (should (eq 'rpc-response
                    (plist-get (plist-get emitted :diagnostic) :origin)))))))

(ert-deftest pichat-rpc-get-session-stats-applies-context-usage ()
  (pichat-test-with-unit-session (session proc)
    (let ((id (pichat-rpc-get-session-stats session nil)))
      (pichat-rpc--process-filter
       proc
       (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_session_stats\",\"success\":true,\"data\":{\"contextUsage\":{\"tokens\":12,\"contextWindow\":100,\"percent\":12}}}\n" id))
      (should (equal 12 (plist-get (pichat-session-context-usage session) :tokens))))))

(ert-deftest pichat-rpc-get-session-stats-forwards-error-callback ()
  (pichat-test-with-unit-session (session)
    (let (captured
          (error-callback (lambda (&rest _args) nil)))
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (_session type payload callback &optional error)
                   (setq captured (list type payload callback error))
                   "stats-request")))
        (should (equal "stats-request"
                       (pichat-rpc-get-session-stats
                        session #'ignore error-callback))))
      (should (equal "get_session_stats" (nth 0 captured)))
      (should-not (nth 1 captured))
      (should (eq #'ignore (nth 2 captured)))
      (should (eq error-callback (nth 3 captured))))))

(ert-deftest pichat-rpc-unknown-events-are-normalized-and-emitted ()
  (pichat-test-with-unit-session (session proc)
    (let (payload)
      (pichat-on 'surprise-event (lambda (_s _e plist) (setq payload plist)) session)
      (pichat-rpc--process-filter proc "{\"type\":\"surprise_event\",\"value\":7}\n")
      (should (equal 7 (plist-get (plist-get payload :raw) :value))))))

(ert-deftest pichat-rpc-generic-event-precedes-named-event-after-state-update ()
  (pichat-test-with-unit-session (session proc)
    (let (events generic-payload generic-state)
      (pichat-on 'rpc-event
                 (lambda (s event plist)
                   (setq generic-payload plist
                         generic-state (pichat-session-state s))
                   (push event events))
                 session)
      (pichat-on 'agent-start
                 (lambda (_s event _plist) (push event events))
                 session)
      (pichat-rpc--process-filter proc "{\"type\":\"agent_start\",\"value\":7}\n")
      (should (equal '(rpc-event agent-start) (nreverse events)))
      (should (eq generic-state 'running))
      (should (eq (plist-get generic-payload :normalized-event) 'agent-start))
      (should (equal 7 (plist-get (plist-get generic-payload :raw) :value))))))

(ert-deftest pichat-rpc-generic-event-is-exactly-once-for-name-collision ()
  (pichat-test-with-unit-session (session proc)
    (let ((generic-count 0)
          (named-count 0))
      (pichat-on 'rpc-event
                 (lambda (&rest _args) (cl-incf generic-count)) session)
      (pichat-on 'pi-rpc-event
                 (lambda (&rest _args) (cl-incf named-count)) session)
      (pichat-rpc--process-filter proc "{\"type\":\"rpc_event\"}\n")
      (should (= 1 generic-count))
      (should (= 1 named-count)))))

(ert-deftest pichat-rpc-generic-event-covers-missing-type-without-signalling ()
  (pichat-test-with-unit-session (session proc)
    (let (generic named errors)
      (pichat-on 'rpc-event
                 (lambda (_s _event plist) (setq generic plist)) session)
      (pichat-on 'unknown-rpc-event
                 (lambda (_s _event plist) (setq named plist)) session)
      (pichat-on 'error
                 (lambda (_s _event plist) (push plist errors)) session)
      (pichat-rpc--process-filter proc "{\"value\":8}\n")
      (should (eq 'unknown-rpc-event
                  (plist-get generic :normalized-event)))
      (should (equal 8 (plist-get (plist-get named :raw) :value)))
      (should-not errors))))

(ert-deftest pichat-rpc-model-wrappers-forward-error-callbacks ()
  (pichat-test-with-unit-session (session)
    (let (calls
          (error-callback (lambda (&rest _args) nil)))
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (_session type payload callback &optional error)
                   (push (list type payload callback error) calls))))
        (pichat-rpc-get-available-models session #'ignore error-callback)
        (pichat-rpc-set-model session "provider" "model" #'ignore
                              error-callback))
      (setq calls (nreverse calls))
      (should (equal "get_available_models" (caar calls)))
      (should (eq error-callback (nth 3 (car calls))))
      (should (equal '("set_model" (:provider "provider" :modelId "model"))
                     (list (car (cadr calls)) (cadr (cadr calls)))))
      (should (eq error-callback (nth 3 (cadr calls)))))))

(ert-deftest pichat-rpc-prompt-forwards-final-error-callback ()
  (pichat-test-with-unit-session (session)
    (let (captured
          (error-callback (lambda (&rest _args) nil)))
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (_session type payload callback &optional error)
                   (setq captured (list type payload callback error))
                   "request-id")))
        (should (equal "request-id"
                       (pichat-rpc-prompt session "hello" nil nil nil error-callback))))
      (should (equal "prompt" (nth 0 captured)))
      (should (equal '(:message "hello") (nth 1 captured)))
      (should (eq error-callback (nth 3 captured))))))

;;; Lifecycle behavior

(ert-deftest pichat-rpc-process-exit-fails-pending-responses ()
  (pichat-test-with-unit-session (session proc)
    (let (error-response)
      (let ((id (pichat-rpc-send session "get_state" nil nil
                                  (lambda (response _session)
                                    (setq error-response response)))))
        (should (gethash id (pichat-session-pending-responses session)))
        (delete-process proc)
        (pichat-test-wait-until (lambda () error-response) 2 "pending response failure after process exit")
        (should (null (gethash id (pichat-session-pending-responses session))))
        (should-not (plist-get error-response :success))
        (should (eq 'process (plist-get error-response :pichat-failure-kind)))
        (should (string-match-p (regexp-opt '("exited" "deleted" "finished" "killed" "stopped"))
                                (or (plist-get error-response :error) "")))))))

(ert-deftest pichat-rpc-request-timeout-removes-pending-response ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-rpc-request-timeout 0.05)
          error-response)
      (let ((id (pichat-rpc-send session "get_state" nil nil
                                  (lambda (response _session)
                                    (setq error-response response)))))
        (should (gethash id (pichat-session-pending-responses session)))
        (pichat-test-wait-until (lambda () error-response) 2 "RPC request timeout")
        (should (null (gethash id (pichat-session-pending-responses session))))
        (should-not (plist-get error-response :success))
        (should (eq 'timeout (plist-get error-response :pichat-failure-kind)))
        (should (string-match-p "timed out" (or (plist-get error-response :error) "")))))))

(ert-deftest pichat-rpc-intentional-stop-cancels-pending-responses ()
  (pichat-test-with-unit-session (session proc)
    (let (error-response)
      (pichat-rpc-send session "get_state" nil nil
                       (lambda (response _session)
                         (setq error-response response)))
      (pichat-rpc-stop session)
      (pichat-test-wait-until (lambda () error-response) 2
                              "pending cancellation after intentional stop")
      (should (eq 'cancelled
                  (plist-get error-response :pichat-failure-kind))))))

(ert-deftest pichat-rpc-process-exit-kills-hidden-process-buffer ()
  (pichat-test-with-unit-session (session proc)
    (let ((buffer (process-buffer proc)))
      (should (buffer-live-p buffer))
      (delete-process proc)
      (pichat-test-wait-until (lambda () (not (buffer-live-p buffer)))
                              2 "hidden RPC buffer cleanup"))))

(ert-deftest pichat-chat-buffer-death-removes-session-event-handlers ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer handlers)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setq handlers (copy-tree pichat-chat--handlers)))
            (should handlers)
            (kill-buffer buffer)
            (dolist (pair handlers)
              (should-not (memq (cdr pair)
                                (gethash (car pair)
                                         (pichat-session-event-handlers session))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;;; Future behavior anchors

(ert-deftest pichat-rpc-unexpected-exit-retains-stderr-outside-normal-error-event ()
  (pichat-test-with-clean-state
    (let* ((pichat-rpc-command '("sh" "-c" "printf fatal-diagnostic >&2; exit 7"))
           (session (pichat-session-make :cwd default-directory))
           failure)
      (pichat-on 'error (lambda (_s _e plist) (setq failure plist)) session)
      (pichat-rpc-start session)
      (pichat-test-wait-until (lambda () failure) 2 "Pi stderr failure event")
      (should (eq 'error (pichat-session-state session)))
      (let ((diagnostic (plist-get failure :diagnostic)))
        (should (eq 'process-exit (plist-get diagnostic :origin)))
        (should (equal "fatal-diagnostic" (plist-get diagnostic :stderr))))
      (should-not (plist-member failure :stderr))
      (should-not (string-match-p "fatal-diagnostic" (plist-get failure :message)))
      (should-not (buffer-live-p (pichat-session-stderr-buffer session))))))

(ert-deftest pichat-rpc-intentional-stop-uses-stopped-state ()
  (pichat-test-with-unit-session (session proc)
    (pichat-rpc-stop session)
    (pichat-test-wait-until (lambda () (eq 'stopped (pichat-session-state session)))
                            2 "intentional stopped state")))

(ert-deftest pichat-rpc-queue-mode-wrappers-send-supported-pi-commands ()
  (pichat-test-with-unit-session (session proc)
    (let (calls)
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (_session type payload callback &optional _error)
                   (push (list type payload callback) calls))))
        (pichat-rpc-set-steering-mode session "all" #'ignore)
        (pichat-rpc-set-follow-up-mode session "one-at-a-time" #'ignore))
      (should (equal '(("set_steering_mode" (:mode "all"))
                       ("set_follow_up_mode" (:mode "one-at-a-time")))
                     (mapcar (lambda (call) (list (car call) (cadr call)))
                             (nreverse calls)))))))

(ert-deftest pichat-rpc-set-thinking-level-sends-level-and-error-callback ()
  (pichat-test-with-unit-session (session proc)
    (let (call)
      (cl-letf (((symbol-function 'pichat-rpc-send)
                 (lambda (selected-session type payload callback
                          &optional error-callback)
                   (setq call (list selected-session type payload callback
                                    error-callback)))))
        (pichat-rpc-set-thinking-level session "high" #'ignore #'identity))
      (should (eq session (nth 0 call)))
      (should (equal "set_thinking_level" (nth 1 call)))
      (should (equal '(:level "high") (nth 2 call)))
      (should (eq #'ignore (nth 3 call)))
      (should (eq #'identity (nth 4 call))))))

(provide 'pichat-test-rpc)
;;; pichat-test-rpc.el ends here
