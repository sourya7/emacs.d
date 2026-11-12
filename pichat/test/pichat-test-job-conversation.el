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

(ert-deftest pichat-job-conversation-run-now-atomically-consumes-future-attempt ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id))
             (now (float-time)))
        (should-not (pichat-job-conversation-dispatch store id expected now))
        (should (equal id (pichat-job-conversation-dispatch store id expected now 20 nil t)))
        (let* ((run (pichat-job-record store 'runs id)) (trigger (plist-get run :trigger)))
          (should (equal "queued" (plist-get run :state)))
          (should (equal (plist-get expected :destination) (plist-get run :destination)))
          (should (equal (plist-get expected :spec) (plist-get run :spec)))
          (should (= (plist-get (plist-get expected :trigger) :due) (plist-get trigger :due)))
          (should (eq t (plist-get trigger :run-now)))
          (should (= now (plist-get trigger :dispatched-at))))
        (should-not (pichat-job-conversation-dispatch store id expected now 20 nil t))
        (should-not (pichat-job-conversation-dispatch
                     store id expected (plist-get (plist-get expected :trigger) :due)))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-run-now-provenance-is-validated-and-survives-reload ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id)))
        (pichat-job-conversation-dispatch store id expected (float-time) 20 nil t)
        (should (equal (pichat-job-record store 'runs id)
                       (pichat-job-record (pichat-job-store-open (pichat-job-store-file store)) 'runs id)))
        (dolist (change '(flag instant pending))
          (let* ((data (pichat-job--copy (pichat-job-store-data store)))
                 (run (aref (plist-get data :runs) 0))
                 (trigger (plist-get run :trigger)))
            (pcase change
              ('flag (setf (plist-get trigger :run-now) :false))
              ('instant (setf (plist-get trigger :dispatched-at) "invalid"))
              ('pending (setf (plist-get run :state) "scheduled")))
            (should-error (pichat-job--validate data) :type 'pichat-job-error)))))))

(ert-deftest pichat-job-conversation-run-now-reentrant-action-cannot-duplicate-submission ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id))
             (callback (timer--function (cdr (gethash id (pichat-job-executor-schedules executor)))))
             (pichat-job-executor-changed-hook
              (list (lambda (_executor)
                      (should-not (gethash id (pichat-job-executor-schedules executor)))
                      (funcall callback)
                      (should-error (pichat-job-executor-conversation-run-now executor id expected)
                                    :type 'user-error)))))
        (pichat-job-executor-conversation-run-now executor id expected)
        (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))))))

(ert-deftest pichat-job-conversation-run-now-retires-original-timer-and-sends-once ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id))
             (timer (cdr (gethash id (pichat-job-executor-schedules executor))))
             (callback (timer--function timer)))
        (cl-letf (((symbol-function 'pichat-job-launch-prepare) (lambda (&rest _) (ert-fail "Started worker"))))
          (should (equal id (pichat-job-executor-conversation-run-now executor id expected))))
        (should (equal "running" (plist-get (pichat-job-record store 'runs id) :state)))
        (should-not (gethash id (pichat-job-executor-schedules executor)))
        ;; Even an already-delivered native callback cannot consume it again.
        (funcall callback)
        (should-error (pichat-job-executor-conversation-run-now executor id expected) :type 'user-error)
        (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))
        (should (= 1 (length (pichat-job-records store 'runs))))
        (should (process-live-p process))))))

(ert-deftest pichat-job-conversation-run-now-revalidates-and-does-not-bypass-capacity ()
  (dolist (change '(source busy missing-capture queue-full capacity fresh-busy))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let* ((id (pichat-test-job-conversation-schedule executor session))
               (expected (pichat-job-record store 'runs id))
               (pichat-jobs-max-concurrency 1)
               (pichat-jobs-queue-limit (if (eq change 'queue-full) 0 20)))
          (pcase change
            ('source (with-current-buffer buffer (cl-incf pichat-chat--source-generation 2)))
            ('busy (setf (pichat-session-state session) 'running))
            ('missing-capture (pichat-job-executor--conversation-forget executor id))
            ('capacity (pichat-job-claim store (pichat-job-enqueue store (pichat-test-job-spec project-dir)))))
          (if (eq change 'fresh-busy)
              (let ((reply (symbol-function 'pichat-test-job-conversation-reply)))
                (cl-letf (((symbol-function 'pichat-test-job-conversation-reply)
                           (lambda (target type)
                             (if (equal type "get_state") '(:success t :data (:isStreaming t))
                               (funcall reply target type)))))
                  (pichat-job-executor-conversation-run-now executor id expected)))
            (if (eq change 'capacity)
                (pichat-job-executor-conversation-run-now executor id expected)
              (should-error (pichat-job-executor-conversation-run-now executor id expected) :type 'user-error)))
          (should-not (member "prompt" commands))
          (should-not (gethash id (pichat-job-executor-schedules executor)))
          (if (eq change 'capacity)
              (progn
                (should (equal "queued" (plist-get (pichat-job-record store 'runs id) :state)))
                (setf (pichat-session-state session) 'running)
                (pichat-job-executor-pump executor)
                (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result))))
            (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))))))))

(ert-deftest pichat-job-conversation-run-now-write-failure-never-sends-or-leaves-timer ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id)))
        (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Write failed"))))
          (should-error (pichat-job-executor-conversation-run-now executor id expected)))
        (should (equal expected (pichat-job-record store 'runs id)))
        (should (pichat-job-executor-schedules-closed executor))
        (should (= 0 (hash-table-count (pichat-job-executor-schedules executor))))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-run-now-report-action-is-exact-and-contextual ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (expected (pichat-job-record store 'runs id)))
        (with-current-buffer buffer
          (pichat-chat-draft-replace (pichat-chat-draft-capture) "Keep draft")
          (setq pichat-chat--pending-attachments '(fixture-image)))
        (pichat-jobs--show-detail executor 'runs id)
        (should (member "Run now" (pichat-test-job-actions)))
        (let ((scope pichat-jobs--actions))
          (pichat-job-executor-cancel executor id)
          (should-error (pichat-jobs--action scope 'conversation-run-now) :type 'user-error))
        (should-not (member "Run now" (pichat-test-job-actions)))
        (should-error (pichat-job-executor-conversation-run-now executor id expected) :type 'user-error)
        (setq id (pichat-test-job-conversation-schedule executor session))
        (pichat-jobs--show-detail executor 'runs id)
        (pichat-test-job-command "Run now")
        (should-not (member "Run now" (pichat-test-job-actions)))
        (pichat-jobs-detail-refresh)
        (should (string-match-p "Run now requested:" (buffer-string)))
        (with-current-buffer buffer
          (should (equal "Keep draft" (pichat-chat-draft-text (pichat-chat-draft-capture))))
          (should (equal '(fixture-image) pichat-chat--pending-attachments)))
        (should (= 1 (seq-count (lambda (type) (equal type "prompt")) commands)))))))

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

(ert-deftest pichat-job-conversation-report-menu-does-not-capture-or-hash-history ()
  (dolist (cancelled '(nil t))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let ((id (pichat-test-job-conversation-schedule executor session)))
          (when cancelled (pichat-rpc--require-operation-ownership session "prompt"))
          (pichat-jobs--show-detail executor 'runs id)
          (cl-letf (((symbol-function 'pichat-job-conversation-capture)
                     (lambda (&rest _) (ert-fail "Menu captured conversation")))
                    ((symbol-function 'pichat-job-conversation--digest)
                     (lambda (&rest _) (ert-fail "Menu hashed history"))))
            (should (member "Reschedule…" (pichat-test-job-actions)))
            (cl-letf (((symbol-function 'transient-scope) (lambda () pichat-jobs--actions)))
              (dolist (group '(work inspect navigate schedule))
                (pichat-jobs--action-suffixes group))))
          (let ((capture (symbol-function 'pichat-job-conversation-capture))
                (captures 0))
            (cl-letf (((symbol-function 'pichat-job-conversation-capture)
                       (lambda (&rest args) (cl-incf captures) (apply capture args)))
                      ((symbol-function 'transient-setup) #'ignore))
              (pichat-jobs--action pichat-jobs--actions 'conversation-reschedule))
            (should (= captures 1)))
          (should-not (member "prompt" commands)))))))

(ert-deftest pichat-job-conversation-report-reschedule-stages-and-replaces-only-on-authorization ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session))
             (before (pichat-job-record store 'runs id)) scope)
        (with-current-buffer buffer
          (pichat-chat-draft-replace (pichat-chat-draft-capture) "Keep draft")
          (setq pichat-chat--pending-attachments '(fixture-image)))
        (pichat-jobs--show-detail executor 'runs id)
        (cl-letf (((symbol-function 'transient-setup)
                   (lambda (_prefix _layout _edit &rest args) (setq scope (plist-get args :scope)))))
          (pichat-test-job-command "Reschedule…")
          (should-not (plist-get scope :due))
          (should (equal "continue" (plist-get (plist-get scope :draft) :instructions)))
          (should (eq session (plist-get (plist-get scope :conversation) :session)))
          (should (equal before (pichat-job-record store 'runs id)))
          (cl-letf (((symbol-function 'transient-scope) (lambda () scope)))
            (should-error (pichat-job-composer-schedule) :type 'user-error)
            (pichat-job-settings-cancel))
          (should (equal (cons 'runs id) pichat-jobs--detail))
          (should (equal before (pichat-job-record store 'runs id)))
          (pichat-test-job-command "Reschedule…")
          (setf (plist-get scope :due) (+ (float-time) 7200))
          (cl-letf (((symbol-function 'transient-scope) (lambda () scope))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (pichat-job-composer-schedule))
          (let ((new (pichat-job-record store 'runs (plist-get scope :submitted-run-id))))
            (should (equal "scheduled" (plist-get new :state)))
            (should-not (equal id (plist-get new :id)))
            (should (equal "cancelled" (plist-get (pichat-job-record store 'runs id) :result)))
            (should-not (gethash id (pichat-job-executor-schedules executor)))))
        (should-not (member "prompt" commands))
        (with-current-buffer buffer
          (should (equal "Keep draft" (pichat-chat-draft-text (pichat-chat-draft-capture))))
          (should (equal '(fixture-image) pichat-chat--pending-attachments)))))))

(ert-deftest pichat-job-conversation-report-reschedule-recaptures-not-sent-source ()
  (pichat-test-with-conversation-job
    (pichat-test-with-conversation-rpc
      (let* ((id (pichat-test-job-conversation-schedule executor session)) scope)
        (pichat-rpc--require-operation-ownership session "prompt")
        (cl-incf (pichat-session-input-generation session))
        (setf (pichat-session-model session) '(:provider "pichat-fake" :id "pichat-fake-reasoning"))
        (let ((before (pichat-job-record store 'runs id)))
          (pichat-jobs--show-detail executor 'runs id)
          (should-not (gethash id (pichat-job-executor-conversations executor)))
          (cl-letf (((symbol-function 'transient-setup)
                     (lambda (_prefix _layout _edit &rest args) (setq scope (plist-get args :scope)))))
            (pichat-test-job-command "Reschedule…")
            (let ((destination (plist-get (plist-get scope :conversation) :destination)))
              (should (equal "pichat-fake/pichat-fake-reasoning" (plist-get destination :model)))
              (should (= (pichat-session-input-generation session) (plist-get destination :input-generation))))
            (should-not (plist-get scope :due))
            (should (equal "continue" (plist-get (plist-get scope :draft) :instructions)))
            (should (equal before (pichat-job-record store 'runs id)))
            (should (= 1 (length (pichat-job-records store 'runs))))
            (cl-letf (((symbol-function 'transient-scope) (lambda () scope)))
              (pichat-job-settings-cancel))))
        (should-not (member "prompt" commands))))))

(ert-deftest pichat-job-conversation-report-reschedule-rejects-stale-or-unavailable-authority ()
  (dolist (change '(report source process notice busy sync guard uncertain))
    (pichat-test-with-conversation-job
      (pichat-test-with-conversation-rpc
        (let ((id (pichat-test-job-conversation-schedule executor session)))
          (pichat-rpc--require-operation-ownership session "prompt")
          (pichat-jobs--show-detail executor 'runs id)
          (should (member "Reschedule…" (pichat-test-job-actions)))
          (let ((scope pichat-jobs--actions))
            (pcase change
              ('report (setq pichat-jobs--detail (cons 'runs "retargeted")))
              ('source (with-current-buffer buffer (cl-incf pichat-chat--source-generation 2)))
              ('process (cl-incf (pichat-session-process-generation session)))
              ('notice (with-current-buffer buffer (setq pichat-job-executor--continuation-notice nil)))
              ('busy (setf (pichat-session-state session) 'running))
              ('sync (with-current-buffer buffer (setq pichat-chat--sync-in-flight t)))
              ('guard (setf (pichat-session-input-guard session) #'ignore))
              ('uncertain
               (setq id (pichat-test-job-conversation-schedule executor session))
               (pichat-test-job-conversation-due executor id)
               (let ((execution (gethash id (pichat-job-executor-contexts executor))))
                 (pichat-job-executor--uncertain execution "Inspect possible submission"))
               (pichat-jobs--show-detail executor 'runs id)))
            (should-error (pichat-jobs--action scope 'conversation-reschedule) :type 'user-error)
            (unless (eq change 'report)
              (should-not (member "Reschedule…" (pichat-test-job-actions)))))
          (should (= (if (eq change 'uncertain) 1 0)
                     (seq-count (lambda (type) (equal type "prompt")) commands))))))))

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

(defmacro pichat-test-with-conversation-composer (&rest body)
  "Run BODY in the chat of a conversation fixture with delayed RPC replies.
Requests are appended to REQUESTS as (TYPE SUCCESS FAILURE); COMMANDS logs
types.  `transient-setup' records SCOPE, which `transient-scope' returns."
  (declare (indent 0) (debug t))
  `(pichat-test-with-conversation-job
     (with-current-buffer buffer
       (let ((pichat-jobs--executor executor)
             (pichat-jobs-file (pichat-job-store-file store))
             scope requests commands)
         (cl-letf (((symbol-function 'transient-setup)
                    (lambda (_prefix _layout _edit &rest args) (setq scope (plist-get args :scope))))
                   ((symbol-function 'transient-scope) (lambda () scope))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                   ((symbol-function 'pichat-rpc-send)
                    (lambda (_session type _payload &optional success failure)
                      (push type commands)
                      (setq requests (append requests (list (list type success failure)))))))
           ,@body)))))

(defun pichat-test-job-conversation--answer (session request)
  "Deliver a fresh fixture reply for delayed REQUEST of SESSION."
  (should (member (car request) '("get_entries" "get_state")))
  (funcall (nth 1 request) (pichat-test-job-conversation-reply session (car request)) session))

(defun pichat-test-job-conversation--interrupt-once (symbol condition)
  "Return a definition of SYMBOL that signals CONDITION on its first call only."
  (let ((original (symbol-function symbol)) (fired nil))
    (lambda (&rest args)
      (if fired (apply original args)
        (setq fired t)
        (signal condition '("W34 injected interruption"))))))

(defun pichat-test-job-conversation--signal-of (thunk)
  "Call THUNK and return the condition it signalled, or nil."
  (condition-case caught (progn (funcall thunk) nil) ((error quit) (car caught))))

(ert-deftest pichat-job-conversation-interrupted-schedule-preparation-retires-only-its-action ()
  (dolist (condition '(error quit))
    (dolist (point '(entries state spec commit))
      (ert-info ((format "%s during %s" condition point))
        (pichat-test-with-conversation-composer
          (pichat-job-schedule-continuation)
          (let ((due (+ (float-time) 3600)) stale)
            (setf (plist-get (plist-get scope :draft) :instructions) "Reviewed prompt"
                  (plist-get scope :due) due)
            (call-interactively #'pichat-job-composer-schedule)
            (should (plist-get scope :pending))
            (let ((observed
                   (let ((target (pcase point
                                   ('entries 'pichat-job-conversation--history-p)
                                   ('state 'pichat-job-conversation-state-p)
                                   ('spec 'pichat-job-conversation-spec)
                                   ('commit 'pichat-job-conversation-schedule))))
                    (cl-letf (((symbol-function target)
                               (pichat-test-job-conversation--interrupt-once target condition)))
                     (pichat-test-job-conversation--signal-of
                      (lambda ()
                        (while requests
                          (let ((request (pop requests)))
                            (push request stale)
                            (pichat-test-job-conversation--answer session request)))))))))
              ;; Quit keeps its condition; an error becomes the failure reason.
              (should (eq observed (and (eq condition 'quit) 'quit))))
            (should (equal (if (eq point 'entries) 1 2) (length stale)))
            ;; Only this action is retired; its staged prompt and time remain.
            (should-not (plist-get scope :pending))
            (should (pichat-job--settings-current-p scope))
            (should (equal due (plist-get scope :due)))
            (should (equal "Reviewed prompt" (plist-get (plist-get scope :draft) :instructions)))
            (should (equal [] (pichat-job-records store 'runs)))
            (should (= 0 (hash-table-count (pichat-job-executor-conversations executor))))
            ;; A later Schedule owns a new action that stale replies cannot clear.
            (call-interactively #'pichat-job-composer-schedule)
            (let ((token (plist-get scope :pending)))
              (should token)
              (dolist (request (reverse stale))
                (pichat-test-job-conversation--answer session request))
              (should (eq token (plist-get scope :pending)))
              (should (equal [] (pichat-job-records store 'runs)))
              (while requests (pichat-test-job-conversation--answer session (pop requests))))
            (let ((run (pichat-job-record store 'runs (plist-get scope :submitted-run-id))))
              (should (equal "scheduled" (plist-get run :state)))
              (should (equal "Reviewed prompt" (pichat-job-prompt run)))
              (should (= due (plist-get (plist-get run :trigger) :due))))
            (should (plist-get scope :closed))
            (should (= 1 (length (pichat-job-records store 'runs))))
            (should-not (member "prompt" commands))))))))

(ert-deftest pichat-job-conversation-accepted-schedule-interruption-keeps-authorization ()
  (dolist (condition '(error quit))
    (dolist (point '(forget close display))
      (ert-info ((format "%s during %s" condition point))
        (pichat-test-with-conversation-composer
          (let (old)
            (pichat-job-executor-conversation-schedule
             executor (pichat-job-conversation-capture session) "Old prompt" (+ (float-time) 600) nil
             (lambda (id) (setq old id)) (lambda (reason) (ert-fail reason)))
            (while requests (pichat-test-job-conversation--answer session (pop requests)))
            (should old)
            (pichat-job-schedule-continuation)
            (setf (plist-get scope :due) (+ (float-time) 3600))
            (call-interactively #'pichat-job-composer-schedule)
            (let ((observed
                   (let ((target (pcase point
                                   ('forget 'pichat-job-executor--conversation-forget)
                                   ('close 'pichat-job--close-context)
                                   ('display 'pichat-jobs--show-detail))))
                    (cl-letf (((symbol-function target)
                               (pichat-test-job-conversation--interrupt-once target condition)))
                     (pichat-test-job-conversation--signal-of
                      (lambda ()
                        (while requests
                          (pichat-test-job-conversation--answer session (pop requests)))))))))
              (should (eq observed (and (eq condition 'quit) 'quit))))
            ;; The confirmed replacement is durable, accepted once and owned.
            (let* ((new (plist-get scope :submitted-run-id))
                   (capture (and new (gethash new (pichat-job-executor-conversations executor)))))
              (should new)
              (should (= 2 (length (pichat-job-records store 'runs))))
              (should (equal "cancelled" (plist-get (pichat-job-record store 'runs old) :result)))
              (should (equal "scheduled" (plist-get (pichat-job-record store 'runs new) :state)))
              (should (eq capture (plist-get scope :conversation)))
              (should (plist-get capture :handlers))
              (should (gethash new (pichat-job-executor-schedules executor)))
              (should-not (gethash old (pichat-job-executor-schedules executor)))
              ;; The composer is not reopened for a second authorization.
              (should-error (call-interactively #'pichat-job-composer-schedule) :type 'user-error)
              (should-not requests)
              (should (= 2 (length (pichat-job-records store 'runs))))
              (should-not (member "prompt" commands)))))))))

(ert-deftest pichat-job-conversation-cancelled-schedule-preparation-reports-no-run ()
  (pichat-test-with-conversation-composer
    (pichat-job-schedule-continuation)
    (setf (plist-get scope :due) (+ (float-time) 3600))
    (call-interactively #'pichat-job-composer-schedule)
    (call-interactively #'pichat-job-settings-cancel)
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format-message format args) messages))))
        (while requests (pichat-test-job-conversation--answer session (pop requests))))
      (should-not (seq-some (lambda (text) (string-match-p "Scheduled" text)) messages)))
    (should (equal [] (pichat-job-records store 'runs)))
    (should-not (member "prompt" commands))))

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
  (ert-deftest pichat-integration-job-conversation-run-now-preserves-source-and-consumes-once ()
    (pichat-test-with-job-executor (:script '(:turns [(:text "Immediate continuation result")]))
      (let* ((session (pichat-test-job-conversation-start project-dir))
             (process (pichat-session-process session))
             (source (pichat-session-id session))
             (runtime (pichat-session-runtime-id session)) id failed)
        (pichat-job-executor-conversation-schedule
         executor (pichat-job-conversation-capture session) "continue" (+ (float-time) 3600) nil
         (lambda (value) (setq id value)) (lambda (reason) (setq failed reason)))
        (pichat-test-wait-until (lambda () (or id failed)) 5 "schedule acceptance")
        (should-not failed)
        (let* ((expected (pichat-job-record store 'runs id))
               (callback (timer--function (cdr (gethash id (pichat-job-executor-schedules executor))))))
          (pichat-job-executor-conversation-run-now executor id expected)
          (funcall callback)
          (pichat-test-job-wait store id "finished")
          (let* ((run (pichat-job-record store 'runs id)) (trigger (plist-get run :trigger)))
            (should (equal "completed" (plist-get run :result)))
            (should (equal "Immediate continuation result" (plist-get run :summary)))
            (should (< (plist-get trigger :dispatched-at) (plist-get trigger :due))))
          (funcall callback)
          (should-error (pichat-job-executor-conversation-run-now executor id expected) :type 'user-error))
        (should (= 1 (length (pichat-job-records store 'runs))))
        (should (= 1 (length (pichat-session-list))))
        (should (eq process (pichat-session-process session)))
        (should (equal source (pichat-session-id session)))
        (should (equal runtime (pichat-session-runtime-id session)))
        (should (pichat-session-alive-p session))
        (should-not (pichat-session-input-guard session))
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
