;;; pichat-test-jobs-ssh.el --- Opt-in real SSH job execution -*- lexical-binding: t; -*-

;;; Code:
(require 'pichat-test-real-ssh-support)
(require 'pichat-job-executor)

(ert-deftest pichat-integration-job-ssh-captured-target-and-hidden-completion ()
  (pichat-test-real-ssh--run
   (lambda (fixture)
     ;; Reuse the established isolated environment, but retire its starter
     ;; runtime before the fixture's independent no-old-writer spawn assertions.
     (let ((previous (plist-get fixture :session)))
       (pichat-test-real-ssh--stop-starter fixture)
       (pichat-test-with-temp-dir metadata-directory
         (let* ((store (pichat-job-store-open (expand-file-name "jobs.json" metadata-directory)))
                (executor (pichat-job-executor-open store))
                (pichat-jobs-control-timeout 15)
                (current-buffer (current-buffer))
                (pichat-current-session previous)
                (spec (pichat-job-launch-capture
                       "SSH review" "Inspect the supplied files." (plist-get fixture :project)
                       '(:preset review :target real-ssh :model "pichat-fake/pichat-fake-reasoning")))
                ;; Dispatch must use the capture, not current target/preset registry.
                (pichat-targets nil)
                (id (pichat-job-executor-submit executor spec))
                (execution (gethash id (pichat-job-executor-contexts executor)))
                (session (pichat-job-execution-session execution)))
           (unwind-protect
               (progn
                 (pichat-test-wait-until
                  (lambda () (equal (plist-get (pichat-job-record store 'runs id) :state) "finished"))
                  25 "SSH job canonical completion")
                 (should (equal (plist-get (pichat-job-record store 'runs id) :result) "completed"))
                 (should (string-match-p "persisted SSH answer"
                                         (plist-get (pichat-job-record store 'runs id) :summary)))
                 (should (eq pichat-current-session previous))
                 (should (eq (current-buffer) current-buffer))
                 (should-not (get-buffer-window (pichat-session-buffer session) t))
                 (should-not (pichat-session-alive-p session))
                 (should (pichat-process-lifetime-confirmed-p (pichat-session-process session)))
                 (should-not (pichat-test-real-ssh--alive-p fixture (pichat-session-process session)))
                 (should (buffer-local-value 'buffer-read-only (pichat-session-buffer session)))
                 (should (equal (plist-get
                                 (pichat-job-evidence-read store
                                  (plist-get (pichat-job-record store 'runs id) :evidence)) :response)
                                "persisted SSH answer"))
                 (should (pichat-process-lifetime-supported-p (pichat-session-process session)))
                 (should (eq 'ssh (pichat-transport-kind (pichat-session-transport session))))
                 (should (equal (file-local-name (plist-get fixture :project))
                                (pichat-session-runtime-cwd session)))
                 (pichat-test-assert-provider-script-consumed (plist-get fixture :status)))
             (pichat-job-executor--retire execution)
             (when session (pichat-rpc-stop session))
             (when-let* ((buffer (and session (pichat-session-buffer session))))
               (when (buffer-live-p buffer) (kill-buffer buffer))))))))))

(ert-deftest pichat-integration-job-ssh-interval-and-followup-use-captured-target ()
  (pichat-test-real-ssh--run
   (lambda (fixture)
     (pichat-test-real-ssh--stop-starter fixture)
     (pichat-test-real-ssh--write-script
      fixture '(:turns [(:text "SSH_SCHEDULE_RESULT"
                         :expectContextIncludes ["SSH schedule payload"])]))
     (pichat-test-with-temp-dir metadata-directory
       (let* ((store (pichat-job-store-open (expand-file-name "jobs.json" metadata-directory)))
              (executor (pichat-job-executor-open store))
              (pichat-jobs-control-timeout 15)
              (profile '(:preset review :target real-ssh :model "pichat-fake/pichat-fake-reasoning"))
              (handler (pichat-job-save
                        store (pichat-job-launch-capture
                               "SSH reviewer" "Review supplied previous run context."
                               (plist-get fixture :project) profile)))
              (spec (pichat-job-launch-capture
                     "SSH interval worker" "SSH schedule payload" (plist-get fixture :project) profile))
              (job (pichat-job-save store (plist-put spec :after-job-id handler)))
              (pichat-targets nil)
              (pichat-current-session (plist-get fixture :session))
              (origin (current-buffer)) (window (selected-window))
              (start (+ (float-time) 1)))
         (unwind-protect
             (progn
               (pichat-job-executor-schedule-change
                executor job (list :kind "interval" :start start :seconds 3600))
               (pichat-job-executor-schedule-enable executor job t)
               (pichat-test-wait-until
                (lambda () (= (length (pichat-job-records store 'runs)) 2))
                35 "SSH scheduled worker and follow-up")
               (let* ((worker (aref (pichat-job-records store 'runs) 0))
                      (id (plist-get worker :id))
                      (child (plist-get (plist-get worker :dispatch) :run-id)))
                 (should child)
                 (pichat-test-wait-until
                  (lambda () (equal (plist-get (pichat-job-record store 'runs child) :state) "finished"))
                  35 "SSH follow-up completion")
                 (should (equal (plist-get worker :result) "completed"))
                 (should (equal (plist-get (plist-get worker :trigger) :kind) "interval"))
                 (should (= (plist-get (plist-get worker :trigger) :due) start))
                 (should (equal (plist-get (pichat-job-record store 'runs child) :result) "completed"))
                 (should (equal (plist-get (plist-get (pichat-job-record store 'runs child) :event) :run-id) id))
                 (should (= (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule) :next)
                            (+ start 3600)))
                 (let* ((run (pichat-job-record store 'runs child))
                        (entries (plist-get (pichat-job-evidence-read store (plist-get run :evidence)) :entries))
                        (user (seq-find (lambda (entry)
                                          (equal (plist-get (plist-get entry :message) :role) "user")) entries)))
                   ;; The remote Pi's persisted prompt, not only our local envelope.
                   (should (string-match-p "SSH_SCHEDULE_RESULT"
                                           (prin1-to-string (plist-get user :message)))))
                 (maphash
                  (lambda (_id execution)
                    (let* ((session (pichat-job-execution-session execution))
                           (process (pichat-session-process session)))
                      (should (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh))
                      (should (pichat-process-lifetime-confirmed-p process))
                      (should-not (pichat-test-real-ssh--alive-p fixture process))))
                  (pichat-job-executor-contexts executor))
                 (should (= (plist-get fixture :spawn-checks) 3))
                 (should (eq (current-buffer) origin))
                 (should (eq (selected-window) window))
                 (should (eq pichat-current-session (plist-get fixture :session)))
                 (pichat-test-assert-provider-script-consumed (plist-get fixture :status))))
           (pichat-job-executor-schedule-stop executor)
           (maphash (lambda (_id execution)
                      (pichat-job-executor--retire execution)
                      (when-let* ((session (pichat-job-execution-session execution)))
                        (pichat-rpc-stop session)
                        (when-let* ((buffer (pichat-session-buffer session)))
                          (when (buffer-live-p buffer) (kill-buffer buffer)))))
                    (pichat-job-executor-contexts executor))))))))

(ert-deftest pichat-integration-job-ssh-continuation-embeds-context-in-fresh-session ()
  (pichat-test-real-ssh--run
   (lambda (fixture)
     (pichat-test-real-ssh--stop-starter fixture)
     (pichat-test-real-ssh--write-script fixture '(:turns [(:error "SSH fixture interruption")]))
     (pichat-test-with-temp-dir metadata-directory
       (let* ((store (pichat-job-store-open (expand-file-name "jobs.json" metadata-directory)))
              (executor (pichat-job-executor-open store))
              (pichat-jobs-control-timeout 15)
              (spec (pichat-job-launch-capture
                     "SSH continuation" "Inspect the supplied files." (plist-get fixture :project)
                     '(:preset review :target real-ssh :model "pichat-fake/pichat-fake-reasoning")))
              (id (pichat-job-executor-submit executor spec)))
         (unwind-protect
             (progn
               (pichat-test-wait-until
                (lambda () (equal (plist-get (pichat-job-record store 'runs id) :state) "uncertain"))
                35 "SSH failed worker")
               (let* ((runtime (pichat-job-execution-session (gethash id (pichat-job-executor-contexts executor))))
                      (process (pichat-session-process runtime)))
                 (pichat-rpc-stop runtime)
                 (pichat-test-wait-until
                  (lambda () (not (pichat-test-real-ssh--alive-p fixture process)))
                  15 "failed fixture runtime exit")
                 (pichat-process-lifetime-confirm process)
                 (pichat-process-lifetime-cleanup process)
                 (pichat-job-executor-resolve executor id "Fixture inspected: no tools or descendants"))
               (let* ((before (pichat-job-record store 'runs id))
                      (original (pichat-job-execution-session
                                 (gethash id (pichat-job-executor-contexts executor)))))
                 (should (equal (plist-get before :result) "needs-review"))
                 (pichat-test-assert-provider-script-consumed (plist-get fixture :status))
                 (pichat-test-real-ssh--write-script
                  fixture '(:turns [(:text "SSH_CONTINUED_RESULT"
                                     :expectContextIncludes ["SSH fixture interruption" "checkpoint may be stale"])]))
                 (let* ((pichat-targets nil)
                        (next (pichat-job-executor-submit-options executor (list :spec spec :continue-of id)))
                        (replacement (pichat-job-execution-session
                                      (gethash next (pichat-job-executor-contexts executor)))))
                   (pichat-test-wait-until
                    (lambda () (equal (plist-get (pichat-job-record store 'runs next) :state) "finished"))
                    35 "SSH continuation completion")
                   (should (equal (plist-get (pichat-job-record store 'runs next) :result) "completed"))
                   (should (equal before (pichat-job-record store 'runs id)))
                   (should-not (equal (pichat-session-session-file original)
                                      (pichat-session-session-file replacement)))
                   (should (eq (pichat-transport-kind (pichat-session-transport replacement)) 'ssh))
                   (should (pichat-process-lifetime-confirmed-p (pichat-session-process replacement)))
                   (should-not (pichat-test-real-ssh--alive-p fixture (pichat-session-process replacement)))
                   (should (= (plist-get fixture :spawn-checks) 3))
                   (pichat-test-assert-provider-script-consumed (plist-get fixture :status)))))
           (pichat-job-executor-schedule-stop executor)
           (maphash (lambda (_id execution)
                      (pichat-job-executor--retire execution)
                      (when-let* ((session (pichat-job-execution-session execution)))
                        (pichat-rpc-stop session)
                        (when-let* ((buffer (pichat-session-buffer session)))
                          (when (buffer-live-p buffer) (kill-buffer buffer)))))
                    (pichat-job-executor-contexts executor))))))))

(ert-deftest pichat-integration-job-ssh-authoring-skill-is-staged-only-at-launch ()
  (pichat-test-real-ssh--run
   (lambda (fixture)
     (pichat-test-real-ssh--stop-starter fixture)
     (pichat-test-real-ssh--write-script
      fixture '(:turns [(:text "SSH_SKILL_RESULT" :expectContextIncludes ["<name>pichat-jobs</name>"])]))
     (pichat-test-with-temp-dir metadata-directory
       (let* ((pichat-targets (copy-tree pichat-targets))
              (pichat-pi-extra-env `(("HOME" . ,(file-local-name (plist-get fixture :root)))))
              (target (cdr (assq 'real-ssh pichat-targets)))
              (_args (setf (plist-get target :pi-args) (remove "--no-skills" (plist-get target :pi-args))))
              (store (pichat-job-store-open (expand-file-name "jobs.json" metadata-directory)))
              (executor (pichat-job-executor-open store))
              (pichat-jobs-control-timeout 15)
              (spec (pichat-job-launch-capture
                     "SSH skill" "Inspect supplied files." (plist-get fixture :project)
                     '(:preset review :target real-ssh :model "pichat-fake/pichat-fake-reasoning")))
              (command (plist-get (plist-get spec :configuration) :command))
              (_check (should-not (member "--skill" (append command nil))))
              (id (pichat-job-executor-submit executor spec))
              (execution (gethash id (pichat-job-executor-contexts executor)))
              (session (pichat-job-execution-session execution)) skill)
         (unwind-protect
             (progn
               (setq skill (cadr (member "--skill" (pichat-session-rpc-command session))))
               (should (stringp skill))
               (should-not (equal skill pichat-rpc-job-authoring-skill))
               (should-not (file-remote-p skill))
               (pichat-test-wait-until
                (lambda () (equal (plist-get (pichat-job-record store 'runs id) :state) "finished"))
                25 "SSH job using staged skill")
               (should (equal (plist-get (pichat-job-record store 'runs id) :result) "completed"))
               (should-not (pichat-test-real-ssh--alive-p fixture (pichat-session-process session)))
               (should-not (file-exists-p
                            (pichat-transport-runtime-file-name (pichat-session-transport session) skill)))
               (should (equal command (plist-get (plist-get (plist-get (pichat-job-record store 'runs id) :spec)
                                                                             :configuration) :command)))
               (pichat-test-assert-provider-script-consumed (plist-get fixture :status)))
           (pichat-job-executor--retire execution)
           (pichat-rpc-stop session)
           (when-let* ((buffer (pichat-session-buffer session)))
             (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(provide 'pichat-test-jobs-ssh)
;;; pichat-test-jobs-ssh.el ends here
