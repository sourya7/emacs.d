;;; pichat-test-debug.el --- Bounded runtime snapshots -*- lexical-binding: t; -*-

;;; Commentary:

;; Contracts for `pichat-debug': read-only, bounded views of retained runtimes
;; that callers address by runtime ID or chat buffer.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-debug)

(cl-defmacro pichat-test-with-debug-runtime ((session buffer) &rest body)
  "Run BODY with registered SESSION owning chat BUFFER."
  (declare (indent 1))
  `(pichat-test-with-clean-state
     (let* ((,session (pichat-session-make :id "source-a" :name "Review" :state 'idle
                                           :cwd "/tmp/project/"))
            (,buffer (generate-new-buffer "*pi:debug-test*")))
       (unwind-protect
           (progn
             (with-current-buffer ,buffer
               (pichat-chat-mode)
               (setq pichat-chat-session ,session))
             (setf (pichat-session-buffer ,session) ,buffer)
             (pichat-register-session ,session)
             ,@body)
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))))))

(ert-deftest pichat-debug-runtimes-report-queue-and-pending-state ()
  (pichat-test-with-debug-runtime (session buffer)
    (with-current-buffer buffer (setq pichat-chat--queue-counts '(1 . 2)))
    (puthash "req-1" #'ignore (pichat-session-pending-responses session))
    (let ((row (car (pichat-debug-runtimes))))
      (should (= 1 (length (pichat-debug-runtimes))))
      (should (equal (pichat-session-runtime-id session) (plist-get row :runtime)))
      (should (equal (buffer-name buffer) (plist-get row :buffer)))
      (should (equal "Review" (plist-get row :name)))
      (should (equal '(1 . 2) (plist-get row :queued)))
      (should (= 1 (plist-get row :pending-responses)))
      (should (equal "source-a" (plist-get row :session-id))))))

(ert-deftest pichat-debug-addresses-runtimes-by-id-or-chat-buffer ()
  (pichat-test-with-debug-runtime (session buffer)
    (let ((id (pichat-session-runtime-id session)))
      (should (equal id (plist-get (pichat-debug-runtime id) :runtime)))
      (should (equal id (plist-get (pichat-debug-runtime (buffer-name buffer)) :runtime)))
      (should (equal id (plist-get (pichat-debug-runtime buffer) :runtime)))
      (should-error (pichat-debug-runtime "no-such-runtime") :type 'user-error)
      (with-temp-buffer
        (should-error (pichat-debug-runtime (current-buffer)) :type 'user-error)))))

(ert-deftest pichat-debug-events-summarize-recent-events-oldest-first ()
  (pichat-test-with-debug-runtime (session _buffer)
    ;; The retained log is newest first.
    (setf (pichat-session-event-log session)
          (list (list :type "response" :command "get_state" :id "3" :success t
                      :data '(:big t))
                (list :type "agent_end" :messages nil)
                (list :type "response" :command "prompt" :success nil
                      :error (make-string 400 ?x))))
    (let ((events (pichat-debug-events (pichat-session-runtime-id session) 2)))
      (should (equal '((:type "agent_end" :other-keys (:messages))
                       (:type "response" :command "get_state" :id "3" :success t
                              :other-keys (:data)))
                     events)))
    (let ((oldest (car (pichat-debug-events session))))
      (should (= (1+ pichat-debug-string-limit) (length (plist-get oldest :error)))))
    (should (equal '(:big t)
                   (plist-get (car (last (pichat-debug-events session 3 t))) :data)))))

(ert-deftest pichat-debug-events-skip-streaming-and-status-noise-by-default ()
  (pichat-test-with-debug-runtime (session _buffer)
    (setf (pichat-session-event-log session)
          (list (list :type "extension_ui_request" :method "setStatus")
                (list :type "message_update")
                (list :type "extension_ui_request" :method "notify")
                (list :type "tool_execution_update")
                (list :type "agent_end")))
    (should (equal '("agent_end" "extension_ui_request")
                   (mapcar (lambda (event) (plist-get event :type))
                           (pichat-debug-events session))))
    (should (equal '("notify")
                   (mapcar (lambda (event) (plist-get event :method))
                           (pichat-debug-events session 1))))
    (should (= 5 (length (pichat-debug-events session nil nil t))))
    (should (equal '("message_update")
                   (mapcar (lambda (event) (plist-get event :type))
                           (pichat-debug-events session nil nil
                                                '("message_update")))))))

(ert-deftest pichat-debug-events-summarize-truncated-retained-events ()
  (pichat-test-with-debug-runtime (session _buffer)
    ;; Event snapshots can end in an omission marker rather than a value.
    (setf (pichat-session-event-log session)
          (list (append (list :type "agent_end" :messages nil) 'pichat-omitted)
                (list :type "turn_end" :message)))
    (should (equal '((:type "turn_end" :truncated t)
                     (:type "agent_end" :other-keys (:messages) :truncated t))
                   (pichat-debug-events session)))))

(ert-deftest pichat-debug-tail-returns-plain-chat-text ()
  (pichat-test-with-debug-runtime (session buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (pichat-chat--inhibit-edit-guard t))
        (erase-buffer)
        (insert (propertize "earlier text " 'face 'bold) "latest")
        (narrow-to-region 1 3)))
    (let ((tail (pichat-debug-tail session 6)))
      (should (equal "latest" tail))
      (should-not (text-properties-at 0 tail)))
    (setf (pichat-session-buffer session) nil)
    (should-error (pichat-debug-tail session) :type 'user-error)))

(ert-deftest pichat-debug-stderr-and-diagnostics-use-retained-state ()
  (pichat-test-with-debug-runtime (session _buffer)
    (should-not (pichat-debug-stderr session))
    (let ((stderr (generate-new-buffer " *pichat-debug-stderr*")))
      (unwind-protect
          (progn
            (with-current-buffer stderr (insert "warning: one\nfatal: two"))
            (setf (pichat-session-stderr-buffer session) stderr)
            (should (equal "fatal: two" (pichat-debug-stderr session 10))))
        (kill-buffer stderr)))
    (setf (pichat-session-diagnostics session)
          (list (pichat-diagnostic-create :domain 'transport :category 'process-exit
                                          :summary "Pi exited")))
    (let ((runtime (assoc "Runtime / transport" (pichat-debug-diagnostics session))))
      (should (= 1 (length (cdr runtime))))
      (should (string-match-p "Pi exited" (cadr runtime))))))

(provide 'pichat-test-debug)
;;; pichat-test-debug.el ends here
