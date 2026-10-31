;;; pichat-test-jobs-ssh.el --- Opt-in real SSH job execution -*- lexical-binding: t; -*-

;;; Code:
(require 'pichat-test-real-ssh-support)
(require 'pichat-job-executor)

(ert-deftest pichat-integration-job-ssh-captured-target-and-hidden-completion ()
  (pichat-test-real-ssh--run
   (lambda (fixture)
     ;; Reuse the established isolated environment, but retire its starter
     ;; runtime before the fixture's independent no-old-writer spawn assertions.
     (let* ((previous (plist-get fixture :session))
            (old (pichat-session-process previous)))
       (pichat-rpc-stop previous)
       (pichat-test-wait-until
        (lambda () (not (pichat-test-real-ssh--alive-p fixture old))) 15
        "starter runtime exit before independent job")
       (pichat-process-lifetime-confirm old)
       (pichat-process-lifetime-cleanup old)
       (pichat-test-with-temp-dir metadata-directory
         (let* ((store (pichat-job-store-open (expand-file-name "jobs.json" metadata-directory)))
                (executor (pichat-job-executor-open store))
                (pichat-jobs-control-timeout 15)
                (current-buffer (current-buffer))
                (pichat-current-session previous)
                (spec (pichat-job-launch-capture
                       "SSH review" "Inspect the supplied files." (plist-get fixture :project)
                       '(:preset review :target real-ssh :model "pichat-fake/pichat-fake-reasoning")
                       "read"))
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
                 (should (pichat-process-lifetime-supported-p (pichat-session-process session)))
                 (should (eq 'ssh (pichat-transport-kind (pichat-session-transport session))))
                 (should (equal (file-local-name (plist-get fixture :project))
                                (pichat-session-runtime-cwd session)))
                 (pichat-test-assert-provider-script-consumed (plist-get fixture :status)))
             (pichat-job-executor--retire execution)
             (when session (pichat-rpc-stop session))
             (when-let* ((buffer (and session (pichat-session-buffer session))))
               (when (buffer-live-p buffer) (kill-buffer buffer))))))))))

(provide 'pichat-test-jobs-ssh)
;;; pichat-test-jobs-ssh.el ends here
