;;; pichat-test-process-lifetime-protocol.el --- Exit observer failure matrix -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-process-lifetime)

(defun pichat-test-lifetime-protocol--drain ()
  "Wait for queued zero-delay observer deliveries, not an arbitrary sleep."
  (let (drained)
    (run-at-time 0 nil (lambda () (setq drained t)))
    (pichat-test-wait-until (lambda () drained) 1 "observer dispatch barrier")))

(defun pichat-test-lifetime-protocol--run (scenario &optional seconds exit-code)
  "Call SCENARIO with a real endpoint and controlled observer wire output.
The target writer and observer endpoint are test-owned local children; no SSH
connection occurs.  SECONDS and EXIT-CODE control deadline and clean exit."
  (pichat-test-with-unit-session (session writer)
    (let* ((transport (pichat-transport--create :id 'fixture :kind 'ssh))
           (fixture (list :writer writer :observer nil :filter nil :sentinel nil
                          :token nil :ready 0 :results nil))
           observer cancel)
      (process-put writer 'pichat-lifetime
                   '(:pid 123 :start "42" :boot "12345678-1234-1234-1234-123456789abc"))
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (_transport _cwd &rest args)
                       (let ((script (car (last (plist-get args :command)))))
                         (should (string-match "PC-LIFETIME \\([0-9a-f]+\\) ready" script))
                         (plist-put fixture :token (match-string 1 script)))
                       (plist-put fixture :filter (plist-get args :filter))
                       (plist-put fixture :sentinel (plist-get args :sentinel))
                       (setq observer
                             (make-process :name "pichat-test-exit-observer"
                                           :command (list "sh" "-c"
                                                          (format "cat >/dev/null; exit %d" (or exit-code 0)))
                                           :buffer nil :connection-type 'pipe :noquery t
                                           :filter (plist-get args :filter)
                                           :sentinel (plist-get args :sentinel)))
                       (plist-put fixture :observer observer)
                       observer)))
            (setq cancel
                  (pichat-process-lifetime-watch
                   transport default-directory writer (or seconds 2) t
                   (lambda () (cl-incf (plist-get fixture :ready)))
                   (lambda (success reason)
                     (plist-put fixture :results
                                (append (plist-get fixture :results) (list (list success reason)))))))
            (plist-put fixture :cancel cancel)
            (funcall scenario fixture))
        (when cancel (funcall cancel))
        (when (and observer (process-live-p observer)) (delete-process observer))))))

(defun pichat-test-lifetime-protocol--feed (fixture text)
  "Deliver TEXT with FIXTURE's token substituted for TOKEN, then drain."
  (funcall (plist-get fixture :filter) (plist-get fixture :observer)
           (replace-regexp-in-string "TOKEN" (plist-get fixture :token) text t t))
  (pichat-test-lifetime-protocol--drain))

(ert-deftest pichat-process-lifetime-protocol-requires-gone-and-clean-exit ()
  (pichat-test-lifetime-protocol--run
   (lambda (fixture)
     (dolist (chunk '("PC-LIFE" "TIME TOKEN ready\r" "\n" "PC-LIFETIME TOKEN gone\n"))
       (pichat-test-lifetime-protocol--feed fixture chunk))
     (should (= 1 (plist-get fixture :ready)))
     (should-not (plist-get fixture :results))
     (should (process-live-p (plist-get fixture :observer)))
     (process-send-eof (plist-get fixture :observer))
     (pichat-test-wait-until (lambda () (plist-get fixture :results)) 2 "clean observer exit")
     (should (equal '((t nil)) (plist-get fixture :results)))
     ;; Only the owning transaction records proof, not the wire parser.
     (should-not (pichat-process-lifetime-confirmed-p (plist-get fixture :writer)))
     (pichat-test-lifetime-protocol--feed fixture "late data\n")
     (funcall (plist-get fixture :sentinel) (plist-get fixture :observer) "late sentinel")
     (pichat-test-lifetime-protocol--drain)
     (should (= 1 (length (plist-get fixture :results)))))))

(ert-deftest pichat-process-lifetime-protocol-rejects-incomplete-and-unqualified-eof ()
  (dolist (output '("" "PC-LIFETIME TOKEN ready\n" "PC-LIFETIME TOKEN gone\n"
                    "PC-LIFETIME wrong-token ready\nPC-LIFETIME TOKEN gone\n"
                    "PC-LIFETIME TOKEN ready\nPC-LIFETIME wrong-token gone\n"
                    "PC-LIFETIME TOKEN ready\nPC-LIFETIME TOKEN gone"))
    (pichat-test-lifetime-protocol--run
     (lambda (fixture)
       (pichat-test-lifetime-protocol--feed fixture output)
       (when (process-live-p (plist-get fixture :observer))
         (process-send-eof (plist-get fixture :observer)))
       (pichat-test-wait-until (lambda () (plist-get fixture :results)) 2 "rejected observer EOF")
       (should (= 1 (length (plist-get fixture :results))))
       (should-not (caar (plist-get fixture :results)))
       (should-not (pichat-process-lifetime-confirmed-p (plist-get fixture :writer)))))))

(ert-deftest pichat-process-lifetime-protocol-rejects-duplicate-garbage-and-overflow ()
  (dolist (output (list "PC-LIFETIME TOKEN ready\nPC-LIFETIME TOKEN ready\n"
                       "PC-LIFETIME TOKEN ready\nPC-LIFETIME TOKEN gone\nPC-LIFETIME TOKEN gone\n"
                       "unexpected shell banner\n"
                       (make-string 4097 ?x)
                       (make-string 2049 ?λ)))
    (pichat-test-lifetime-protocol--run
     (lambda (fixture)
       (pichat-test-lifetime-protocol--feed fixture output)
       (should (= 1 (length (plist-get fixture :results))))
       (should-not (caar (plist-get fixture :results)))
       (should-not (process-live-p (plist-get fixture :observer)))
       (should (process-live-p (plist-get fixture :writer)))))))

(ert-deftest pichat-process-lifetime-protocol-gone-before-disconnect-is-not-proof ()
  (dolist (failure '(nonzero signal))
    (pichat-test-lifetime-protocol--run
     (lambda (fixture)
       (pichat-test-lifetime-protocol--feed fixture "PC-LIFETIME TOKEN ready\nPC-LIFETIME TOKEN gone\n")
       (if (eq failure 'signal)
           (delete-process (plist-get fixture :observer))
         (process-send-eof (plist-get fixture :observer)))
       (pichat-test-wait-until (lambda () (plist-get fixture :results)) 2 "failed observer endpoint")
       (should-not (caar (plist-get fixture :results)))
       (should (process-live-p (plist-get fixture :writer))))
     nil 2)))

(ert-deftest pichat-process-lifetime-protocol-timeout-retires-late-output ()
  (pichat-test-lifetime-protocol--run
   (lambda (fixture)
     (pichat-test-lifetime-protocol--feed fixture "PC-LIFETIME TOKEN ready\n")
     (pichat-test-wait-until (lambda () (plist-get fixture :results)) 2 "observer deadline")
     (should-not (caar (plist-get fixture :results)))
     (should (string-match-p "Timed out" (cadar (plist-get fixture :results))))
     (pichat-test-lifetime-protocol--feed fixture "PC-LIFETIME TOKEN gone\n")
     (should (= 1 (length (plist-get fixture :results))))
     (should (process-live-p (plist-get fixture :writer))))
   0.05))

(ert-deftest pichat-process-lifetime-protocol-cancellation-suppresses-all-deliveries ()
  (dolist (ready '(nil t))
    (pichat-test-lifetime-protocol--run
     (lambda (fixture)
       (when ready (pichat-test-lifetime-protocol--feed fixture "PC-LIFETIME TOKEN ready\n"))
       (funcall (plist-get fixture :cancel))
       (pichat-test-lifetime-protocol--feed fixture "PC-LIFETIME TOKEN ready\nPC-LIFETIME TOKEN gone\n")
       (funcall (plist-get fixture :sentinel) (plist-get fixture :observer) "late exit")
       (pichat-test-lifetime-protocol--drain)
       (should-not (plist-get fixture :results))
       (should (= (if ready 1 0) (plist-get fixture :ready)))
       (should-not (process-live-p (plist-get fixture :observer)))
       (should (process-live-p (plist-get fixture :writer)))))))

(provide 'pichat-test-process-lifetime-protocol)
;;; pichat-test-process-lifetime-protocol.el ends here
