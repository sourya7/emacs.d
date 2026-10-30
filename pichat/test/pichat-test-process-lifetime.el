;;; pichat-test-process-lifetime.el --- SSH lifetime barrier basics -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-process-lifetime)

(defun pichat-test-lifetime--identity (process)
  "Read this test-owned Linux PROCESS identity without any network access."
  (unless (file-readable-p "/proc/self/stat")
    (ert-skip "Linux procfs is needed for the real observer fixture"))
  (let* ((pid (process-id process))
         (stat (with-temp-buffer
                 (insert-file-contents (format "/proc/%d/stat" pid))
                 (buffer-string)))
         (boot (with-temp-buffer
                 (insert-file-contents "/proc/sys/kernel/random/boot_id")
                 (string-trim (buffer-string)))))
    (should (string-match "^.*) \\(.*\\)$" stat))
    (list :pid pid :start (nth 19 (split-string (match-string 1 stat))) :boot boot)))

(ert-deftest pichat-process-lifetime-observer-confirms-exit-not-just-readiness ()
  (pichat-test-with-unit-session (session process)
    (let* ((identity (pichat-test-lifetime--identity process))
           (transport (pichat-transport--create :id 'fixture :kind 'ssh))
           (make-local (symbol-function 'pichat-transport-make-process))
           ready result cancel)
      (process-put process 'pichat-lifetime identity)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (_transport cwd &rest args)
                       (apply make-local pichat-transport-local cwd args))))
            (setq cancel
                  (pichat-process-lifetime-watch
                   transport default-directory process 2 t
                   (lambda () (setq ready t))
                   (lambda (success reason) (setq result (list success reason)))))
            (pichat-test-wait-until (lambda () ready) 2 "observer live baseline")
            (should-not result)
            (should (process-live-p process))
            (delete-process process)
            (pichat-test-wait-until (lambda () result) 3 "actual process exit evidence")
            (should (equal result '(t nil))))
        (when cancel (funcall cancel))))))

(ert-deftest pichat-process-lifetime-wrong-boot-fails-before-ready ()
  (pichat-test-with-unit-session (session process)
    (let* ((identity (pichat-test-lifetime--identity process))
           (transport (pichat-transport--create :id 'fixture :kind 'ssh))
           (make-local (symbol-function 'pichat-transport-make-process))
           ready result cancel)
      (plist-put identity :boot "00000000-0000-0000-0000-000000000000")
      (process-put process 'pichat-lifetime identity)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (_transport cwd &rest args)
                       (apply make-local pichat-transport-local cwd args))))
            (setq cancel
                  (pichat-process-lifetime-watch
                   transport default-directory process 2 t
                   (lambda () (setq ready t))
                   (lambda (success reason) (setq result (list success reason)))))
            (pichat-test-wait-until (lambda () result) 3 "observer boot mismatch")
            (should-not ready)
            (should-not (car result))
            (should (process-live-p process))
            (should-not (pichat-process-lifetime-confirmed-p process)))
        (when cancel (funcall cancel))))))

(ert-deftest pichat-process-lifetime-preflight-observer-retains-operation-ownership ()
  (pichat-test-with-unit-session (session process)
    (let* ((identity (pichat-test-lifetime--identity process))
           (transport (pichat-transport--create :id 'fixture :kind 'ssh))
           (buffer (pichat-chat-open session))
           (make-local (symbol-function 'pichat-transport-make-process))
           (operation (list :session session :chat buffer :phase 'preflight
                            :transport transport :runtime-cwd default-directory
                            :shutdown-obligations (list process)))
           ready)
      (setf (pichat-session-transport session) transport
            (pichat-session-restart-operation session) operation)
      (process-put process 'pichat-lifetime identity)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (_transport cwd &rest args)
                       (apply make-local pichat-transport-local cwd args))))
            (pichat-reconfigure--prepare-shutdown
             operation nil (lambda () (setq ready t)))
            (pichat-test-wait-until (lambda () ready) 2 "owned preflight observer")
            (should (eq operation (pichat-session-restart-operation session)))
            (should (plist-get operation :observer-cancellers))
            (should (process-live-p process))
            (pichat-reconfigure-cancel-operation session "fixture cancellation")
            (should-not (plist-get operation :observer-cancellers))
            (should (equal (list process)
                           (plist-get (pichat-session-restart-operation session)
                                      :shutdown-obligations))))
        (pichat-reconfigure--cancel-observers operation)
        (when (buffer-live-p buffer)
          (let ((pichat-chat-stop-session-on-kill nil)) (kill-buffer buffer)))))))

(ert-deftest pichat-process-lifetime-recovery-cannot-bypass-unconfirmed-writer ()
  (pichat-test-with-unit-session (session process)
    (let* ((transport (pichat-transport--create :id 'fixture :kind 'ssh))
           (operation (list :session session :shutdown-obligations (list process))))
      (setf (pichat-session-transport session) transport)
      (delete-process process)
      ;; Even a stopped local endpoint and a recovery attempt confer no proof.
      (should-not (pichat-reconfigure--shutdown-safe-p operation))
      (should-error (pichat-reconfigure--start-replacement operation) :type 'user-error)
      (process-put process 'pichat-exit-confirmed t)
      (should (pichat-reconfigure--shutdown-safe-p operation)))))

(ert-deftest pichat-process-lifetime-identity-validates-helper-envelope ()
  (should-not (pichat-process-lifetime-identity nil))
  (let* ((data (json-parse-string
                "{\"kind\":\"linux-procfs-v1\",\"pid\":123,\"start\":\"42\",\"boot\":\"12345678-1234-1234-1234-123456789abc\"}"))
         (identity (pichat-process-lifetime-identity data)))
    (should (= 123 (plist-get identity :pid)))
    (puthash "start" "42; exit 0" data)
    (should-error (pichat-process-lifetime-identity data))))

(provide 'pichat-test-process-lifetime)
;;; pichat-test-process-lifetime.el ends here
