;;; tramp-contract-tests.el --- Isolated SSH shutdown investigation -*- lexical-binding: t; -*-

(require 'ert)
(require 'pichat-transport)

(defun pichat-contract--wait (predicate seconds description)
  (let ((deadline (+ (float-time) seconds)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (unless (funcall predicate) (ert-fail description))))

(defun pichat-contract--stat (directory pid)
  "Read Linux PID identity via a separate command; reject probe failure."
  (let ((default-directory directory))
    (with-temp-buffer
      (let ((status (process-file "sh" nil t nil "-c"
                                  (format "if test -r /proc/%d/stat; then cat /proc/%d/stat; elif test -d /proc/%d; then exit 2; else printf 'absent\\n'; fi" pid pid pid))))
        (should (eql status 0))
        (let ((text (string-trim (buffer-string))))
          (should (or (equal text "absent")
                      (string-prefix-p (format "%d (" pid) text)))
          text)))))

(defun pichat-contract--start-time (stat)
  "Extract Linux /proc STAT field 22, allowing parentheses in the comm field."
  (should (string-match "^\\([0-9]+\\) (.*) \\(.*\\)$" stat))
  (let ((value (nth 19 (split-string (match-string 2 stat)))))
    (should (and value (string-match-p "\\`[0-9]+\\'" value)))
    value))

(ert-deftest pichat-contract-ssh-transport-death-does-not-prove-remote-exit ()
  "Delete only this fixture's SSH endpoint; its HUP-immune child survives."
  (let* ((directory (getenv "PICHAT_TEST_SSH_DIRECTORY"))
         (transport (pichat-transport-resolve directory))
         (buffer (generate-new-buffer " *pichat-contract-output*"))
         process pid)
    (should (file-remote-p directory))
    ;; Establish the control connection before the owned async channel.
    (should (file-directory-p directory))
    (unwind-protect
        (progn
          (setq process (pichat-transport-make-process
                         transport (file-local-name directory)
                         :name "pichat-contract-owned-ssh"
                         :buffer buffer :sentinel #'ignore
                         :command '("sh" "-c" "trap '' HUP; echo READY; exec sleep 6")))
          (pichat-contract--wait
           (lambda () (with-current-buffer buffer
                        (string-match-p "^READY\r?$" (buffer-string))))
           5 "Fixture did not become ready")
          (setq pid (process-get process 'remote-pid))
          (should (integerp pid))
          (let ((before (pichat-contract--stat directory pid)))
            (should-not (equal before "absent"))
            (message "Owned SSH fixture: local PID=%s remote PID=%s remote stat=%s"
                     (process-id process) pid before)
            (delete-process process)
            (should-not (process-live-p process))
            (should (eq (process-status process) 'signal))
            (let ((after (pichat-contract--stat directory pid)))
              (should-not (equal after "absent"))
              (should (equal (pichat-contract--start-time before)
                             (pichat-contract--start-time after)))
              (message "After delete-process: local=%s, remote still present: %s"
                       (process-status process) after)))
          ;; No remote kill: the fixture self-expires.  No shared SSH endpoint
          ;; or host networking is modified by this test.
          (pichat-contract--wait
           (lambda () (equal "absent" (pichat-contract--stat directory pid)))
           10 "Self-expiring owned remote child did not exit"))
      (when (and process (process-live-p process)) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest pichat-contract-ssh-remote-signal-is-not-exit-confirmation ()
  "A successful signal request need not terminate the remote process."
  (let* ((directory (getenv "PICHAT_TEST_SSH_DIRECTORY"))
         (transport (pichat-transport-resolve directory))
         (buffer (generate-new-buffer " *pichat-contract-signal*"))
         process pid)
    (should (file-directory-p directory))
    (unwind-protect
        (progn
          (setq process (pichat-transport-make-process
                         transport (file-local-name directory)
                         :name "pichat-contract-signal-ssh"
                         :buffer buffer :sentinel #'ignore
                         :command '("sh" "-c" "trap '' TERM; echo READY; exec sleep 3")))
          (pichat-contract--wait
           (lambda () (with-current-buffer buffer
                        (string-match-p "^READY\r?$" (buffer-string))))
           5 "Signal fixture did not become ready")
          (setq pid (process-get process 'remote-pid))
          (should (integerp pid))
          (should (eql 0 (signal-process process 'SIGTERM)))
          (should (process-live-p process))
          (should-not (equal "absent" (pichat-contract--stat directory pid)))
          (pichat-contract--wait (lambda () (not (process-live-p process)))
                                8 "Remote child did not exit naturally")
          (should (eq (process-status process) 'exit))
          (should (= 0 (process-exit-status process)))
          (should (equal "absent" (pichat-contract--stat directory pid))))
      (when (and process (process-live-p process)) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))
