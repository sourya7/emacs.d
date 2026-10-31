;;; pichat-test-real-ssh-support.el --- Isolated real SSH RPC mechanics -*- lexical-binding: t; -*-

(require 'pichat-test-support)

(defun pichat-test-real-ssh--probe-script (pid &optional procfs)
  "Build independent PID observation against PROCFS (default /proc).
A failed stat read is not absence: explicitly recheck the directory after the
read, with healthy boot/self baselines.  PROCFS permits owned offline fixtures."
  (let ((root (shell-quote-argument (or procfs "/proc"))))
    (format "root=%s
cat \"$root/sys/kernel/random/boot_id\" || exit 2
cat \"$root/self/stat\" >/dev/null || exit 2
if s=$(cat \"$root/%d/stat\" 2>/dev/null); then
  printf '%%s\\n' \"$s\"
elif [ ! -d \"$root/%d\" ]; then
  printf 'ABSENT\\n'
else
  exit 2
fi" root pid pid)))

(defun pichat-test-real-ssh--alive-p (fixture process)
  "Independently read procfs for FIXTURE's exact actual-Pi PROCESS.
Probe failures are test failures, never evidence of absence.  This does not
use the production observer, its parser, or its confirmed-exit property."
  (let* ((identity (process-get process 'pichat-lifetime))
         (pid (plist-get identity :pid))
         (default-directory (plist-get fixture :project)))
    (should (integerp pid))
    (with-temp-buffer
      (should
       (zerop (process-file
               "sh" nil t nil "-c"
               (pichat-test-real-ssh--probe-script pid))))
      (goto-char (point-min))
      (should (equal (buffer-substring-no-properties (point) (line-end-position))
                     (plist-get identity :boot)))
      (forward-line 1)
      (unless (looking-at "ABSENT$")
        (let ((stat (buffer-substring-no-properties (point) (line-end-position))))
          (should (string-match ") \\([^)]*\\)\\'" stat))
          (equal (nth 19 (split-string (match-string 1 stat)))
                 (plist-get identity :start)))))))

(defun pichat-test-real-ssh--write-script (fixture script)
  "Write fake-provider SCRIPT for the next Pi process in FIXTURE."
  (with-temp-file (plist-get fixture :script)
    (insert (json-serialize script :false-object :json-false :null-object nil))))

(defun pichat-test-real-ssh--settled (session)
  "Wait for SESSION's canonical chat synchronization to finish."
  (pichat-test-wait-until
   (lambda ()
     (with-current-buffer (pichat-session-buffer session)
       (and (not pichat-chat--sync-in-flight) (not pichat-chat--sync-pending)
            (pichat-chat-canonical-entry-cache session))))
   15 "SSH canonical source synchronization"))

(defun pichat-test-real-ssh--restart (session configuration &optional recovery)
  "Wait for SESSION to restart with CONFIGURATION, or RECOVERY choice."
  (let (result)
    (if recovery
        (pichat-reconfigure-recover
         session recovery (lambda (ok reason) (setq result (list ok reason))))
      (pichat-reconfigure-restart
       (pichat-reconfigure-capture-origin session) configuration
       (lambda (ok reason) (setq result (list ok reason)))))
    (pichat-test-wait-until
     (lambda () result) 40
     (format "SSH restart/recovery; runtime=%s" (pichat-session-runtime-id session)))
    result))

(defun pichat-test-real-ssh--run (scenario)
  "Run SCENARIO against isolated real SSH and Pi, recording every RPC spawn.
SCENARIO receives a fixture plist.  Instrumentation delegates actual process
creation unchanged and checks old actual-Pi lifetimes before each replacement."
  (let ((base (getenv "PICHAT_TEST_SSH_DIRECTORY")))
    (unless (and (stringp base) (file-remote-p base))
      (ert-fail "PICHAT_TEST_SSH_DIRECTORY must be a writable TRAMP directory"))
    (pichat-test-with-clean-state
      (let* ((root (file-name-as-directory
                    (expand-file-name (format "pichat-reconfigure-%d-%06x"
                                              (emacs-pid) (random #xFFFFFF)) base)))
             (project (expand-file-name "project/" root))
             (runtime-root (file-local-name root))
             (agent (expand-file-name "agent/" root))
             (script (expand-file-name "script.json" root))
             (status (expand-file-name "status.json" root))
             (fixture (list :root root :project project :script script :status status
                            :session nil :processes nil :spawn-checks 0))
             (pichat-default-preset 'manual)
             (pichat-default-model nil)
             (pichat-rpc-command nil)
             (pichat-pi-extra-args nil)
             (pichat-pi-extra-env nil)
             (pichat-pi-default-args '("--mode" "rpc"))
             (pichat-chat-render-markdown nil)
             (pichat-chat-stop-session-on-kill nil)
             (pichat-append-system-prompt nil)
             (pichat-targets
              `((real-ssh :kind ssh :tramp-prefix ,(file-remote-p root)
                          :pi-executable ,(or (getenv "PICHAT_TEST_SSH_PI") "pi")
                          :runtime-home ,runtime-root
                          :path-mappings ((,root . ,runtime-root))
                          :pi-args
                          ("--offline" "--no-approve" "--no-context-files"
                           "--no-skills" "--no-prompt-templates" "--no-themes"
                           "--no-extensions"
                           "-e" ,(expand-file-name "fake-provider.ts" runtime-root)
                           "-e" ,(expand-file-name "tool-control-extension.ts" runtime-root)))))
             (process-environment
              (append (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1" "PI_TELEMETRY=0"
                            (concat "PI_CODING_AGENT_DIR=" (file-local-name agent))
                            (concat "PI_CODING_AGENT_SESSION_DIR="
                                    (expand-file-name "sessions/" runtime-root))
                            (concat "PICHAT_FAKE_PROVIDER_SCRIPT=" (file-local-name script))
                            (concat "PICHAT_FAKE_PROVIDER_STATUS=" (file-local-name status)))
                      process-environment))
             (make-process (symbol-function 'pichat-transport-make-process))
             session buffer)
        (unwind-protect
            (progn
              (make-directory project t)
              (make-directory agent t)
              (copy-file pichat-test-fake-provider-extension
                         (expand-file-name "fake-provider.ts" root))
              (copy-file (expand-file-name "tool-control-extension.ts" pichat-test-fixture-directory)
                         (expand-file-name "tool-control-extension.ts" root))
              (pichat-test-real-ssh--write-script fixture '(:turns [(:text "persisted SSH answer")]))
              (cl-letf (((symbol-function 'pichat-transport-make-process)
                         (lambda (transport cwd &rest args)
                           (when (equal (plist-get args :name) "pichat-rpc")
                             (should (eq 'ssh (pichat-transport-kind transport)))
                             (should (equal (file-local-name project) cwd))
                             (dolist (old (plist-get fixture :processes))
                               (should-not (pichat-test-real-ssh--alive-p fixture old)))
                             (cl-incf (plist-get fixture :spawn-checks)))
                           (let ((process (apply make-process transport cwd args)))
                             (when (equal (plist-get args :name) "pichat-rpc")
                               (push process (plist-get fixture :processes)))
                             process))))
                (let ((default-directory project))
                  (setq session (pichat-start-session
                                 project nil '(:persistence persistent :target real-ssh
                                               :model "pichat-fake/pichat-fake-reasoning"))))
                (plist-put fixture :session session)
                (pichat-test-rpc-call session "get_state" nil 25)
                (pichat-test-rpc-call session "set_auto_retry" '(:enabled :json-false))
                (pichat-test-rpc-call session "set_auto_compaction" '(:enabled :json-false))
                (setq buffer (pichat-chat-open session t))
                (pichat-test-real-ssh--settled session)
                (should (pichat-test-real-ssh--alive-p fixture (pichat-session-process session)))
                (funcall scenario fixture)))
          (when (and session (pichat-session-alive-p session)) (pichat-rpc-stop session))
          ;; Never delete target files while a fixture writer may still use them.
          (dolist (process (plist-get fixture :processes))
            (when (process-live-p process) (delete-process process))
            (pichat-test-wait-until
             (lambda () (not (pichat-test-real-ssh--alive-p fixture process)))
             15 (format "fixture Pi exit before cleanup: %s" root))
            (pichat-process-lifetime-confirm process)
            (pichat-process-lifetime-cleanup process))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (delete-directory root t))))))

(provide 'pichat-test-real-ssh-support)
;;; pichat-test-real-ssh-support.el ends here
