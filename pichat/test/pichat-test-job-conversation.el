;;; pichat-test-job-conversation.el --- Existing-conversation job safety -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'pichat-test-job-support)
(require 'pichat-jobs)

(ert-deftest pichat-job-conversation-schedule-sends-nothing-and-does-not-lock-chat ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (should (equal '("get_state" "get_entries") commands))
        (should-not (pichat-session-input-guard session))
        (should (= 1 (hash-table-count (pichat-job-executor-schedules executor))))
        (should (equal "scheduled" (plist-get (pichat-job-record store 'runs id) :state)))
        ;; Inspection does not invalidate; ordinary input does, before its send.
        (pichat-rpc-send session "get_state" nil)
        (should (equal "scheduled" (plist-get (pichat-job-record store 'runs id) :state)))
        (pichat-rpc-send session "prompt" '(:message "Different work"))
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should (string-match-p "not sent" (plist-get (pichat-job-record store 'runs id) :reason)))
        (should (= 0 (hash-table-count (pichat-job-executor-schedules executor))))))))

(ert-deftest pichat-job-conversation-fresh-history-and-state-required-before-authorization ()
  (dolist (change '(history busy unknown-queue changed-model))
    (pichat-test-with-conversation-job
      (let (accepted failed)
        (cl-letf (((symbol-function 'pichat-rpc-send)
                   (lambda (session type _payload success _failure)
                     (let ((reply (pichat-test-job-conversation-reply session type)))
                       (pcase (cons change type)
                         (`(history . "get_entries") (setf (plist-get (plist-get reply :data) :leafId) "other"))
                         (`(busy . "get_state") (setf (plist-get (plist-get reply :data) :isStreaming) t))
                         (`(unknown-queue . "get_state") (setf (plist-get (plist-get reply :data) :pendingMessageCount) nil))
                         (`(changed-model . "get_state") (setf (plist-get (plist-get reply :data) :model) '(:provider "other" :id "other"))))
                       (funcall success reply session)))))
          (pichat-job-executor-conversation-schedule
           executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 3600) nil
           (lambda (_) (setq accepted t)) (lambda (_) (setq failed t))))
        (should failed) (should-not accepted)
        (should (equal [] (pichat-job-records store 'runs)))))))

(ert-deftest pichat-job-conversation-invalidations-never-retarget-or-wait-until-idle ()
  (dolist (change '(source-away-back process input-generation busy queued dead-chat))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let* ((id (pichat-test-job-conversation-schedule executor session))
               (capture (gethash id (pichat-job-executor-conversations executor))))
          (pcase change
            ('source-away-back (with-current-buffer buffer (cl-incf pichat-chat--source-generation 2)))
            ('process (cl-incf (pichat-session-process-generation session)))
            ('input-generation (cl-incf (pichat-session-input-generation session)))
            ('busy (setf (pichat-session-state session) 'running))
            ('queued (with-current-buffer buffer (setq pichat-chat--queue-counts '(1 . 0))))
            ('dead-chat (kill-buffer buffer)))
          (should-not (pichat-job-conversation-current-p capture))
          (unless (eq change 'dead-chat) (pichat-test-job-conversation-due executor id))
          (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
          (should-not (member "prompt" commands))
          (unless (eq change 'dead-chat) (should (process-live-p process))))))))

(ert-deftest pichat-job-conversation-admission-revalidates-and-respects-global-capacity ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((pichat-jobs-max-concurrency 1)
             (other (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
             (_claim (pichat-job-claim store other))
             (id (pichat-test-job-conversation-schedule executor session)))
        (pichat-test-job-conversation-due executor id)
        (should (equal "queued" (plist-get (pichat-job-record store 'runs id) :state)))
        (should-not (member "prompt" commands))
        (should-not (pichat-session-input-guard session))
        ;; Do not defer a now-busy target until it becomes idle.
        (setf (pichat-session-state session) 'running)
        (pichat-job-executor-pump executor)
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-submission-owns-input-but-never-worker-settings-or-stop ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (cl-letf (((symbol-function 'pichat-backend-stop-session) (lambda (&rest _) (ert-fail "Stopped borrowed runtime")))
                  ((symbol-function 'pichat-job-launch-prepare) (lambda (&rest _) (ert-fail "Prepared worker"))))
          (pichat-test-job-conversation-due executor id)
          (should (equal "running" (plist-get (pichat-job-record store 'runs id) :state)))
          (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))
          (should-not (seq-some (lambda (type) (string-prefix-p "set_" type)) commands))
          (should-error (pichat-rpc-send session "prompt" nil) :type 'user-error)
          (should-error (pichat-rpc-send session "switch_session" nil) :type 'user-error)
          (pichat-job-executor-cancel executor id)
          (should (equal "abort" (car commands)))
          (should-not (equal "finished" (plist-get (pichat-job-record store 'runs id) :state)))
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-success-attributes-new-answer-and-restores-live-chat ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (pichat-test-job-conversation-due executor id)
        (let* ((execution (gethash id (pichat-job-executor-contexts executor)))
               (new (append entries
                            '((:type "message" :id "user" :parentId "old"
                               :message (:role "user" :content ((:type "text" :text "continue")) ))
                              (:type "message" :id "answer" :parentId "user"
                               :message (:role "assistant" :stopReason "stop"
                                         :content ((:type "text" :text "New answer")))))))
               (cache (pichat-pi-entry-cache-full (pichat-session-id session) nil new "answer")))
          (with-current-buffer buffer (setq pichat-chat--entry-cache cache))
          (pichat-job-executor--event execution 'rpc-event '(:normalized-event agent-settled))
          (cl-letf (((symbol-function 'pichat-backend-stop-session) (lambda (&rest _) (ert-fail "Stopped borrowed runtime"))))
            (pichat-job-executor--event
             execution 'transcript-synchronized
             (list :settlement-sequence (pichat-job-execution-settlement execution)
                   :process-generation 1 :session-id (pichat-session-id session) :session-file nil :cache cache)))
          (let* ((run (pichat-job-record store 'runs id))
                 (evidence (pichat-job-evidence-read store (plist-get run :evidence))))
            (should (equal "completed" (plist-get run :result)))
            (should (equal "New answer" (plist-get evidence :response)))
            (should (equal "old" (plist-get evidence :boundary))))
          (should-not (pichat-session-input-guard session))
          (should-not (buffer-local-value 'pichat-job-executor--buffer-execution buffer))
          (should-not (buffer-local-value 'buffer-read-only buffer))
          (should (process-live-p process))
          (pichat-rpc-send session "prompt" '(:message "Ordinary later work"))
          (pichat-job-executor-delete-run executor id)
          (should (equal [] (pichat-job-records store 'runs)))
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-old-response-is-not-new-evidence-and-uncertainty-keeps-guard ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (pichat-test-job-conversation-due executor id)
        (let ((execution (gethash id (pichat-job-executor-contexts executor))))
          (pichat-job-executor--event execution 'rpc-event '(:normalized-event agent-settled))
          (pichat-job-executor--event
           execution 'transcript-synchronized
           (list :settlement-sequence (pichat-job-execution-settlement execution)
                 :process-generation 1 :session-id (pichat-session-id session) :session-file nil
                 :cache (pichat-chat-canonical-entry-cache session)))
          (should (equal "uncertain" (plist-get (pichat-job-record store 'runs id) :state)))
          (should-not (plist-get (pichat-job-record store 'runs id) :evidence))
          (should (pichat-session-input-guard session))
          (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Write failed"))))
            (should-error (pichat-job-executor-resolve executor id "Inspected tools")))
          (should (pichat-session-input-guard session))
          (pichat-job-executor-resolve executor id "Inspected tools")
          (should-not (pichat-session-input-guard session))
          (should (pichat-jobs--chat-p executor (pichat-job-record store 'runs id)))
          ;; Even A -> B -> A cannot make an old report open the new source.
          (with-current-buffer buffer (cl-incf pichat-chat--source-generation 2))
          (should-not (pichat-jobs--chat-p executor (pichat-job-record store 'runs id)))
          (should-error (pichat-jobs--open-chat executor id) :type 'user-error)
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-report-offers-no-stale-binding-reuse ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (pichat-jobs--show-detail executor 'runs id)
        (should (string-match-p "Scheduled for:" (buffer-string)))
        (should (string-match-p "This conversation" (buffer-string)))
        (should (member "Cancel run…" (pichat-test-job-actions)))
        (pichat-job-executor-cancel executor id)
        (pichat-jobs-detail-refresh)
        (let ((actions (pichat-test-job-actions)))
          (dolist (label '("Repeat…" "Continue work…" "Continue in chat…" "Save as job…"))
            (should-not (member label actions))))
        (should (string-match-p "Not sent:" (buffer-string)))
        (should-error (pichat-jobs--repeat executor id) :type 'user-error)))))

(ert-deftest pichat-job-conversation-composer-preserves-chat-draft-and-requires-explicit-time ()
  (pichat-test-with-conversation-job
    (with-current-buffer buffer
      (pichat-chat-draft-replace (pichat-chat-draft-capture) "Unsent work")
      (let ((pichat-jobs--executor executor) (pichat-jobs-file (pichat-job-store-file store)) scope)
        (cl-letf (((symbol-function 'transient-setup) (lambda (_prefix _layout _edit &rest args) (setq scope (plist-get args :scope)))))
          (pichat-job-schedule-continuation)
          (should (equal 'schedule (plist-get scope :kind)))
          (should-not (plist-get scope :due))
          (should (equal "continue" (plist-get (plist-get scope :draft) :instructions)))
          (cl-letf (((symbol-function 'transient-scope) (lambda () scope)))
            (should-error (pichat-job-composer-schedule) :type 'user-error)
            (should-error (pichat-job-composer-run) :type 'user-error)
            (should-error (pichat-job-composer-save) :type 'user-error)
            (should-not (pichat-job--composer-runnable-p))
            (should-not (pichat-job--composer-savable-p))
            (should-error (pichat-job--settings-edit "Model") :type 'user-error)
            (pichat-job-settings-cancel))
          (should (equal "Unsent work" (pichat-chat-draft-text (pichat-chat-draft-capture))))
          (should (equal [] (pichat-job-records store 'runs))))))))

(ert-deftest pichat-job-conversation-dispatch-rechecks-fresh-state-without-worker-cleanup ()
  (dolist (change '(history busy unknown-queue))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let ((id (pichat-test-job-conversation-schedule executor session)))
          (cl-letf (((symbol-function 'pichat-rpc-send)
                     (lambda (session type _payload success _failure)
                       (should (member type '("get_entries" "get_state")))
                       (let ((reply (pichat-test-job-conversation-reply session type)))
                         (when (and (eq change 'history) (equal type "get_entries"))
                           (setf (plist-get (plist-get reply :data) :leafId) "new-leaf"))
                         (when (equal type "get_state")
                           (setf (plist-get (plist-get reply :data) (if (eq change 'busy) :isStreaming :pendingMessageCount)) t))
                         (funcall success reply session))))
                    ((symbol-function 'pichat-backend-stop-session) (lambda (&rest _) (ert-fail "Stopped borrowed runtime"))))
            (pichat-test-job-conversation-due executor id))
          (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
          (should-not (pichat-session-input-guard session))
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-cancel-during-preflight-ignores-duplicate-late-replies ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)) reply)
        (cl-letf (((symbol-function 'pichat-rpc-send)
                   (lambda (_session type _payload success _failure)
                     (should (equal "get_entries" type)) (setq reply success))))
          (pichat-test-job-conversation-due executor id)
          (should (equal "starting" (plist-get (pichat-job-record store 'runs id) :state)))
          (pichat-job-executor-cancel executor id)
          (dotimes (_ 2) (funcall reply (pichat-test-job-conversation-reply session "get_entries") session)))
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should-not (member "prompt" commands))
        (should-not (pichat-session-input-guard session))
        (should (process-live-p process))))))

(ert-deftest pichat-job-conversation-duplicate-preflight-delivery-cannot-submit-or-corrupt-next-state ()
  (pichat-test-with-conversation-job
    (let ((capture (pichat-job-conversation-capture session)) (accepted 0) (failed 0) callbacks)
      (pichat-job-conversation-verify
       capture (lambda (type success failure) (push (list type success failure) callbacks))
       (lambda () (cl-incf accepted)) (lambda (_) (cl-incf failed)))
      (let ((entries (cadar callbacks)))
        (dotimes (_ 2) (funcall entries (pichat-test-job-conversation-reply session "get_entries"))))
      (should (= 2 (length callbacks)))
      (let ((state (cadar callbacks)))
        (dotimes (_ 2) (funcall state (pichat-test-job-conversation-reply session "get_state"))))
      (should (= 1 accepted)) (should (= 0 failed)))))

(ert-deftest pichat-job-conversation-possible-send-and-process-loss-are-uncertain-not-retried ()
  (dolist (failure '(handled process-loss))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let ((id (pichat-test-job-conversation-schedule executor session))
              (submit (symbol-function 'pichat-backend-submit-prompt)))
          (cl-letf (((symbol-function 'pichat-backend-submit-prompt)
                     (lambda (session message images behavior success error)
                       (if (eq failure 'handled)
                           (funcall success '(:success t :data (:disposition "handled")) session)
                         (funcall submit session message images behavior success error)))))
            (pichat-test-job-conversation-due executor id))
          (when (eq failure 'process-loss)
            (cl-incf (pichat-session-process-generation session))
            (pichat-emit session 'session-ended))
          (should (equal "uncertain" (plist-get (pichat-job-record store 'runs id) :state)))
          (should-not (plist-get (pichat-job-record store 'runs id) :evidence))
          (should (pichat-session-input-guard session))
          (pichat-job-executor-pump executor)
          (should (<= (seq-count (lambda (type) (equal type "prompt")) commands) 1))
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-replacement-retires-old-timer-without-sending ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (old (pichat-job-record store 'runs id))
             (timer (cdr (gethash id (pichat-job-executor-schedules executor)))) replacement)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "Reviewed replacement" (+ (float-time) 7200) old
         (lambda (value) (setq replacement value)) (lambda (reason) (ert-fail reason)))
        (should replacement)
        (apply (timer--function timer) (timer--args timer))
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should (equal "scheduled" (plist-get (pichat-job-record store 'runs replacement) :state)))
        (should (= 1 (hash-table-count (pichat-job-executor-schedules executor))))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-lost-live-authority-is-cancelled-even-at-capacity ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((pichat-jobs-max-concurrency 1)
             (other (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
             (_claim (pichat-job-claim store other))
             (id (pichat-test-job-conversation-schedule executor session)))
        (pichat-test-job-conversation-due executor id)
        (pichat-job-executor--conversation-forget executor id)
        (pichat-job-executor-pump executor)
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should-not (member "prompt" commands))
        (should-not (pichat-session-input-guard session))))))

(ert-deftest pichat-job-conversation-pending-table-does-not-invent-a-queue-time ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((ordinary (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
             (id (pichat-test-job-conversation-schedule executor session)))
        (with-temp-buffer
          (pichat-jobs-mode)
          (setq pichat-jobs--owner executor pichat-jobs--kind 'runs
                tabulated-list-sort-key '("Queued" . nil))
          (pichat-jobs-refresh)
          (should (equal "—" (aref (cadr (assoc id tabulated-list-entries)) 1)))
          (should (string-match-p "Due " (buffer-string)))
          (should (= 2 (length tabulated-list-entries))))
        (pichat-job-cancel-queued store ordinary)
        (pichat-test-job-conversation-due executor id)
        (should (plist-get (pichat-job-record store 'runs id) :queued-at))))))

(ert-deftest pichat-job-conversation-ssh-capture-uses-only-the-owned-rpc-endpoint ()
  (pichat-test-with-conversation-job
    ;; Inert endpoint and data-only SSH identity: never connect to a host.
    (setf (pichat-session-transport session)
          (pichat-transport--create :id 'ssh-fixture :kind 'ssh :label "SSH fixture"
                                    :tramp-prefix "/ssh:example.invalid:" :pi-executable "pi"))
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)))
        (cl-letf (((symbol-function 'pichat-backend-stop-session) (lambda (&rest _) (ert-fail "Stopped endpoint")))
                  ((symbol-function 'pichat-start-prepared-session) (lambda (&rest _) (ert-fail "Reconnected")))
                  ((symbol-function 'pichat-transport-resolve) (lambda (&rest _) (ert-fail "Resolved fallback target"))))
          (pichat-test-job-conversation-due executor id)
          (should (eq session (pichat-job-execution-session (gethash id (pichat-job-executor-contexts executor)))))
          (should (equal "ssh" (plist-get (plist-get (plist-get (plist-get (pichat-job-record store 'runs id) :spec)
                                                                                :configuration) :transport) :kind)))
          (pichat-job-executor-cancel executor id)
          (should (member "abort" commands))
          (should (process-live-p process)))))))

(ert-deftest pichat-job-conversation-rename-model-suffix-survives-cached-and-fresh-checks ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (original (pichat-job-record store 'runs id))
             (capture (gethash id (pichat-job-executor-conversations executor)))
             (new (append entries '((:type "session_info" :id "name" :parentId "old" :name "Renamed")
                                    (:type "model_change" :id "model" :parentId "name"
                                     :provider "other" :modelId "model")))))
        (pichat-rpc-send session "set_session_name" '(:name "Renamed"))
        (pichat-rpc-send session "set_model" nil)
        (setf (pichat-session-model session) '(:provider "other" :id "model"))
        (with-current-buffer buffer
          (setq pichat-chat--entry-cache (pichat-pi-entry-cache-full (pichat-session-id session) nil new "model")))
        (pichat-emit session 'transcript-synchronized)
        (should (pichat-job-conversation-current-p capture))
        (pichat-test-job-conversation-due executor id)
        (let ((run (pichat-job-record store 'runs id)))
          (should (equal "running" (plist-get run :state)))
          (should (equal "other/model" (plist-get run :execution-model)))
          (should (equal (plist-get original :spec) (plist-get run :spec)))
          (should (equal (plist-get original :destination) (plist-get run :destination))))
        (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))
        (should-error (pichat-rpc-send session "set_model" nil) :type 'user-error)))))

(ert-deftest pichat-job-conversation-history-projection-never-hides-edits-custom-entries-or-branches ()
  (dolist (change '(edit custom branch broken-parent standalone-thinking))
    (pichat-test-with-conversation-job
      (let* ((capture (pichat-job-conversation-capture session))
             (new (append (copy-tree entries)
                          '((:type "session_info" :id "name" :parentId "old" :name "Renamed"))))
             (leaf "name"))
        (pcase change
          ('edit (setf (plist-get (car new) :timestamp) "changed"))
          ('custom (setf (plist-get (cadr new) :type) "custom"))
          ('standalone-thinking (setf (plist-get (cadr new) :type) "thinking_level_change"))
          ('branch (setq leaf "old"))
          ('broken-parent (setf (plist-get (cadr new) :parentId) nil)))
        (should-not (pichat-job-conversation--history-p capture new leaf))))))

(ert-deftest pichat-job-conversation-input-cancels-before-send-with-bounded-durable-evidence ()
  (dolist (command '("prompt" "steer" "follow_up" "get_unknown" "unknown-private-payload"))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let* ((id (pichat-test-job-conversation-schedule executor session))
               (selected (current-buffer)))
          ;; Even rejected/handled input invalidates at the outgoing-intent seam.
          (pichat-rpc--require-operation-ownership session command)
          (let* ((run (pichat-job-record store 'runs id))
                 (evidence (plist-get run :invalidation)))
            (should (equal "cancelled" (plist-get run :result)))
            (should (equal "input" (plist-get evidence :code)))
            (should (equal ["input-generation"] (plist-get evidence :fields)))
            (should (equal (if (member command '("prompt" "steer" "follow_up")) command "unknown")
                           (plist-get evidence :command)))
            (should-not (string-match-p "private-payload" (prin1-to-string evidence)))
            (should (equal evidence (plist-get (pichat-job-record
                                                (pichat-job-store-open (pichat-job-store-file store)) 'runs id)
                                               :invalidation))))
          (should (eq selected (current-buffer)))
          (with-current-buffer buffer
            (should (string-match-p "Intervening submitted input" (buffer-string)))
            (should (pichat-job--continuation-notice-context))
            (pichat-chat-repaint)
            (should (string-match-p "Intervening submitted input" (buffer-string)))
            (cl-incf pichat-chat--source-generation 2)
            (should-error (pichat-job-review-continuation) :type 'user-error)
            (should-error (pichat-job-reschedule-continuation) :type 'user-error)
            (pichat-chat--reset-for-source "replacement" nil t)
            (should-not pichat-job-executor--continuation-notice)
            (should-not (string-match-p "Intervening submitted input" (buffer-string)))))))))

(ert-deftest pichat-job-conversation-invalidation-storage-failure-cannot-revive-authority ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (capture (gethash id (pichat-job-executor-conversations executor))))
        (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Write failed"))))
          (pichat-rpc--require-operation-ownership session "prompt"))
        (should (plist-get capture :invalidated))
        (should-not (pichat-job-conversation-current-p capture))
        (should (pichat-job-executor-schedule-error executor))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-transition-reentrancy-cannot-send-with-stale-model-or-source ()
  (dolist (change '(model source process))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let* ((id (pichat-test-job-conversation-schedule executor session))
               (changed (symbol-function 'pichat-job-executor--changed)) injected)
          (cl-letf (((symbol-function 'pichat-job-executor--changed)
                     (lambda (owner)
                       (when (and (not injected)
                                  (equal "running" (plist-get (pichat-job-record store 'runs id) :state)))
                         (setq injected t)
                         (pcase change
                           ('model (setf (pichat-session-model session) '(:provider "other" :id "model")))
                           ('source (with-current-buffer buffer (cl-incf pichat-chat--source-generation)))
                           ('process (cl-incf (pichat-session-process-generation session)))))
                       (funcall changed owner))))
            (pichat-test-job-conversation-due executor id))
          (should injected)
          (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
          (should (equal (symbol-name change)
                         (plist-get (plist-get (pichat-job-record store 'runs id) :invalidation) :code)))
          (should-not (member "prompt" commands))
          (should-not (pichat-session-input-guard session)))))))

(ert-deftest pichat-job-conversation-notice-failure-never-strands-a-cancelled-guard ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let ((id (pichat-test-job-conversation-schedule executor session)) callback)
        (cl-letf (((symbol-function 'pichat-rpc-send)
                   (lambda (_session _type _payload success _failure) (setq callback success))))
          (pichat-test-job-conversation-due executor id))
        (cl-letf (((symbol-function 'pichat-chat--set-status) (lambda (&rest _) (error "UI failed"))))
          (funcall callback '(:success t :data (:entries nil :leafId "wrong")) session))
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (should-not (pichat-session-input-guard session))
        (should-not (pichat-job-executor-schedule-error executor))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-model-change-during-capacity-wait-does-not-restore-old-settings ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((pichat-jobs-max-concurrency 1)
             (other (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
             (claimed (pichat-job-claim store other))
             (id (pichat-test-job-conversation-schedule executor session)))
        (pichat-test-job-conversation-due executor id)
        (should (equal "queued" (plist-get (pichat-job-record store 'runs id) :state)))
        (pichat-rpc-send session "cycle_model" nil)
        (setf (pichat-session-model session) '(:provider "other" :id "model"))
        (pichat-job-executor-pump executor)
        (should (equal "queued" (plist-get (pichat-job-record store 'runs id) :state)))
        (pichat-job-advance store other (plist-get claimed :attempt) "finished"
                           '(:result "cancelled" :safe-to-release t))
        (pichat-job-executor-pump executor)
        (should (equal "other/model" (plist-get (pichat-job-record store 'runs id) :execution-model)))
        (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))))))

(ert-deftest pichat-job-conversation-cancellation-evidence-rejects-unbounded-or-content-fields ()
  (dolist (evidence '((:code "input" :event "rpc-input-sending" :fields ["prompt body"])
                      (:code "input" :event "rpc-input-sending" :fields [] :payload "secret")
                      (:code "input" :event "rpc-input-sending" :fields [] :command "secret")
                      (:code "input" :event "rpc-input-sending" :fields [] :code "secret")))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let ((id (pichat-test-job-conversation-schedule executor session)))
          (should-error (pichat-job-cancel-queued store id nil "not sent" evidence) :type 'pichat-job-error)
          (should (equal "scheduled" (plist-get (pichat-job-record store 'runs id) :state))))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-job-conversation-model-clamping-and-rejected-settings-preserve-intent ()
    (pichat-test-with-job-executor (:script '(:turns [(:text "Initial") (:text "Clamped model answer")]))
      (let* ((session (pichat-test-job-conversation-start project-dir)) id failed)
        (pichat-test-prompt-and-wait session "Initial")
        (pichat-test-rpc-call session "set_model" '(:provider "pichat-fake" :modelId "pichat-fake-reasoning"))
        (pichat-test-rpc-call session "set_thinking_level" '(:level "high"))
        (with-current-buffer (pichat-session-buffer session) (pichat-chat-repaint))
        (pichat-test-job-conversation-ready session)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 3600) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "schedule")
        (should-not failed)
        (pichat-test-rpc-call session "set_model" '(:provider "pichat-fake" :modelId "pichat-fake-reasoning"))
        (let (rejected)
          (pichat-rpc-send session "set_model" '(:provider "missing" :modelId "missing")
                           (lambda (&rest _) (ert-fail "Accepted missing model"))
                           (lambda (&rest _) (setq rejected t)))
          (pichat-test-wait-until (lambda () rejected) 5 "model selection rejection"))
        (should (equal "scheduled" (plist-get (pichat-job-record store 'runs id) :state)))
        (should-not (plist-get (pichat-job-record store 'runs id) :execution-model))
        (pichat-test-rpc-call session "set_model" '(:provider "pichat-fake" :modelId "pichat-fake"))
        (pichat-test-job-conversation-due executor id)
        (pichat-test-job-wait store id "finished")
        (should (equal "completed" (plist-get (pichat-job-record store 'runs id) :result)))
        (should (equal "pichat-fake/pichat-fake" (plist-get (pichat-job-record store 'runs id) :execution-model)))
        (pichat-test-assert-provider-script-consumed status-file))))

  (ert-deftest pichat-integration-job-conversation-rename-and-model-selection-use-current-model ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "Initial answer") (:text "New model answer")]))
      (let* ((session (pichat-test-job-conversation-start project-dir)) id failure)
        (pichat-test-prompt-and-wait session "Initial work")
        (pichat-test-job-conversation-ready session)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 3600) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failure reason)))
        (pichat-test-wait-until (lambda () (or id failure)) 5 "schedule acceptance")
        (should-not failure)
        (pichat-test-rpc-call session "set_session_name" '(:name "Fixture renamed"))
        (pichat-test-rpc-call session "set_model" '(:provider "pichat-fake" :modelId "pichat-fake-reasoning"))
        ;; Real Pi's suffix must pass fresh verification even before a cached sync.
        (pichat-test-job-conversation-due executor id)
        (pichat-test-job-wait store id "finished")
        (let* ((run (pichat-job-record store 'runs id))
               (evidence (pichat-job-evidence-read store (plist-get run :evidence)))
               (entries (plist-get evidence :entries)))
          (should (equal "completed" (plist-get run :result)))
          (should (equal "pichat-fake/pichat-fake-reasoning" (plist-get run :execution-model)))
          (should (equal "pichat-fake/pichat-fake" (plist-get (plist-get run :destination) :model)))
          (should (equal "pichat-fake-reasoning" (plist-get (pichat-session-model session) :id)))
          (should (seq-some (lambda (entry)
                              (equal "pichat-fake-reasoning" (plist-get (plist-get entry :message) :model)))
                            entries)))
        (pichat-test-assert-provider-script-consumed status-file))))
  (ert-deftest pichat-integration-job-conversation-native-timer-preserves-runtime-and-retry ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:error "Quota limit reached") (:error "WebSocket error")
                           (:text "Scheduled recovery" :expectContextIncludes ["Initial work" "continue"])
                           (:text "Ordinary later reply")]))
      (let* ((session (pichat-test-job-conversation-start project-dir))
             (process (pichat-session-process session))
             (buffer (pichat-session-buffer session))
             (runtime-id (pichat-session-runtime-id session)) id failed)
        (pichat-test-prompt-and-wait session "Initial work")
        (pichat-test-job-conversation-ready session)
        (pichat-test-rpc-call session "set_auto_retry" '(:enabled t))
        (pichat-test-rpc-call session "set_auto_compaction" '(:enabled t))
        (with-current-buffer buffer
          (pichat-chat-draft-replace (pichat-chat-draft-capture) "Unsent draft")
          (setq pichat-chat--pending-attachments '(fixture-image)))
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 0.5) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "schedule acceptance")
        (should-not failed)
        (pichat-test-job-wait store id "finished")
        (should (equal "completed" (plist-get (pichat-job-record store 'runs id) :result)))
        (should (equal "Scheduled recovery" (plist-get (pichat-job-record store 'runs id) :summary)))
        (should (eq process (pichat-session-process session)))
        (should (equal runtime-id (pichat-session-runtime-id session)))
        (should (= 1 (length (pichat-session-list))))
        (should (pichat-session-alive-p session))
        (should-not (pichat-session-input-guard session))
        (should (plist-get (plist-get (pichat-test-rpc-call session "get_state") :data) :autoCompactionEnabled))
        (with-current-buffer buffer
          (should (equal "Unsent draft" (pichat-chat-draft-text (pichat-chat-draft-capture))))
          (should (equal '(fixture-image) pichat-chat--pending-attachments)))
        (pichat-test-prompt-and-wait session "Ordinary later work")
        (pichat-test-assert-provider-script-consumed status-file))))

  (ert-deftest pichat-integration-job-conversation-preserves-automatic-compaction-settlement ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "Initial history") (:text "More history")
                           (:error "maximum context length exceeded")
                           (:text "Compacted summary")
                           (:text "Scheduled answer")]))
      (with-temp-file (expand-file-name "settings.json" agent-dir)
        (insert "{\"compaction\":{\"enabled\":true,\"reserveTokens\":1000,\"keepRecentTokens\":100}}"))
      (let ((session (pichat-test-job-conversation-start project-dir)) id failed compacted)
        (pichat-test-prompt-and-wait session (concat "Initial history " (make-string 5000 ?x)))
        (pichat-test-prompt-and-wait session (concat "More history " (make-string 5000 ?y)))
        (pichat-test-job-conversation-ready session)
        (pichat-test-rpc-call session "set_auto_compaction" '(:enabled t))
        (pichat-on 'compaction-end (lambda (&rest _) (setq compacted t)) session)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 0.5) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "schedule acceptance")
        (should-not failed)
        (pichat-test-job-wait store id "finished")
        (should compacted)
        (should (equal "Scheduled answer" (plist-get (pichat-job-record store 'runs id) :summary)))
        (should (equal "completed" (plist-get (pichat-job-record store 'runs id) :result)))
        (should (pichat-session-alive-p session))
        (pichat-test-assert-provider-script-consumed status-file))))

  (ert-deftest pichat-integration-job-conversation-intervening-prompt-and-active-cancel-never-stop-runtime ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "Intervening work") (:text "Never finishes normally" :delayMs 5000)]))
      (let ((session (pichat-test-job-conversation-start project-dir)) id failed)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 3600) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "schedule acceptance")
        (should-not failed)
        (pichat-test-prompt-and-wait session "Intervening work")
        (pichat-test-job-conversation-ready session)
        (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
        (setq id nil)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 0.5) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "second schedule acceptance")
        (should-not failed)
        (pichat-test-job-wait store id "running")
        (pichat-test-wait-until (lambda () (pichat-job-execution-started
                                          (gethash id (pichat-job-executor-contexts executor)))) 5 "agent start")
        (pichat-job-executor-cancel executor id)
        (pichat-test-job-wait store id "uncertain")
        (should (pichat-session-alive-p session))
        (should (pichat-session-input-guard session))
        (pichat-job-executor-resolve executor id "Inspected fixture, no tool descendants")
        (should-not (pichat-session-input-guard session))
        (should (pichat-session-alive-p session))))))

(provide 'pichat-test-job-conversation)
;;; pichat-test-job-conversation.el ends here
