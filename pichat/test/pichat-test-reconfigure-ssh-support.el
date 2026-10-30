;;; pichat-test-reconfigure-ssh-support.el --- Offline SSH restart mechanics -*- lexical-binding: t; -*-

(require 'pichat-test-support)

(defun pichat-test-ssh-restart--identity (pid)
  "Return a synthetic verified lifetime for fixture PID."
  (list :pid pid :start "42" :boot "12345678-1234-1234-1234-123456789abc"))

(defun pichat-test-ssh-restart--watch (fixture index event &optional success reason)
  "Deliver EVENT to FIXTURE observer INDEX, including deliberately late replies."
  (let ((watch (nth index (plist-get fixture :watches))))
    (should watch)
    (pcase event
      ('ready (funcall (plist-get watch :ready)))
      ('done (funcall (plist-get watch :done) success reason)))))

(defun pichat-test-ssh-restart--run (scenario &optional unwritten)
  "Call SCENARIO with an offline SSH restart fixture.
Only transport creation/observer delivery and Pi RPC replies are simulated.
Restart, source validation, snapshot projection, shutdown and recovery are real.
UNWRITTEN selects a metadata-only source without an existing file."
  (pichat-test-with-unit-session (session original)
    (pichat-test-with-temp-dir dir
      (let* ((pichat-chat-stop-session-on-kill nil)
             (pichat-chat-render-markdown nil)
             (pichat-rpc-command nil)
             (pichat-pi-extra-args nil)
             (pichat-pi-default-args '("--mode" "rpc"))
             (pichat-default-model nil)
             (pichat--sessions-by-id (make-hash-table :test #'equal))
             (pichat--sessions-by-scope (make-hash-table :test #'equal))
             (pichat--session-order nil)
             (transport (pichat-transport--create :id 'fixture :kind 'ssh
                                                 :tramp-prefix "/ssh:fixture.invalid:"
                                                 :pi-executable "fixture-pi"))
             (file "/runtime/session.jsonl")
             (host-file (expand-file-name "session.jsonl" dir))
             (data (pichat-test-read-json-fixture "canonical-session.json"))
             (entries (if unwritten
                          '(:entries ((:type "model_change" :id "model" :parentId nil))
                            :leafId "model")
                        (list :entries (plist-get data :entries)
                              :leafId (plist-get data :leafId))))
             (state (list :sessionId "source" :sessionFile file
                          :pendingMessageCount 0 :isStreaming nil :isCompacting nil
                          :model '(:provider "fake" :id "model")
                          :thinkingLevel "medium" :steeringMode "one-at-a-time"
                          :followUpMode "all" :autoCompactionEnabled nil))
             (fixture (list :session session :original original :buffer nil
                            :transport transport :host-file host-file :state state
                            :entries entries :watches nil :starts nil :results nil
                            :unknown-replacement nil :rpc-error nil :rpc-calls nil))
             buffer)
        (unless unwritten (write-region "{}\n" nil host-file nil 'silent))
        (setf (pichat-session-id session) "source"
              (pichat-session-session-file session) file
              (pichat-session-state session) 'idle
              (pichat-session-preset-name session) 'manual
              (pichat-session-preset-spec session) (pichat-presets-resolve 'manual)
              (pichat-session-tool-selection session)
              (pichat-tool-selection-resolve (pichat-session-preset-spec session)))
        (process-put original 'pichat-lifetime (pichat-test-ssh-restart--identity 100))
        (unwind-protect
            (progn
              ;; Open locally, then capture a synthetic SSH transport.  No
              ;; TRAMP connection or target filesystem is ever touched.
              (setq buffer (pichat-chat-open session))
              (plist-put fixture :buffer buffer)
              (with-current-buffer buffer
                (pichat-chat--apply-sync-response (list :data entries) t nil)
                (pichat-chat--set-input-text "unsent SSH draft"))
              (setf (pichat-session-transport session) transport
                    (pichat-session-runtime-cwd session) "/runtime/project/")
              (pichat-register-session session '("fixture-scope" "/host/project/" "fixture"))
              (cl-letf
                  (((symbol-function 'pichat-transport-runtime-file-name)
                    (lambda (captured path)
                      (should (eq transport captured))
                      (should (equal path file))
                      host-file))
                   ((symbol-function 'pichat-process-lifetime-watch)
                    (lambda (captured cwd process _seconds require-live ready done)
                      (let ((watch (list :transport captured :cwd cwd :process process
                                         :require-live require-live :ready ready
                                         :done done :cancelled nil)))
                        (plist-put fixture :watches
                                   (append (plist-get fixture :watches) (list watch)))
                        (lambda () (plist-put watch :cancelled t)))))
                   ((symbol-function 'pichat-tool-runtime-prepare)
                    (lambda (&rest _) "/fixture-helper.ts"))
                   ((symbol-function 'pichat-transport-make-process)
                    (lambda (captured cwd &rest args)
                      (should (eq captured transport))
                      (should (equal cwd "/runtime/project/"))
                      (let ((process (apply #'make-process :noquery t
                                            (plist-put args :command
                                                       '("sh" "-c" "cat >/dev/null")))))
                        (unless (plist-get fixture :unknown-replacement)
                          (process-put process 'pichat-lifetime
                                       (pichat-test-ssh-restart--identity (process-id process))))
                        (plist-put fixture :starts
                                   (append (plist-get fixture :starts) (list process)))
                        process)))
                   ((symbol-function 'pichat-rpc-get-state)
                    (lambda (_session callback &optional _error)
                      (funcall callback (list :data (plist-get fixture :state)) session)))
                   ((symbol-function 'pichat-rpc-get-entries)
                    (lambda (_session _since callback &optional _error)
                      (funcall callback (list :data (plist-get fixture :entries)) session)))
                   ((symbol-function 'pichat-rpc-send)
                    (lambda (_session type payload callback &optional failure)
                      (plist-put fixture :rpc-calls
                                 (append (plist-get fixture :rpc-calls) (list type)))
                      (if (equal type (plist-get fixture :rpc-error))
                          (funcall failure '(:error "Injected RPC failure") session)
                        (funcall callback
                                 (list :data
                                       (pcase type
                                         ("get_state"
                                          (pichat-session-apply-rpc-state session (plist-get fixture :state))
                                          (plist-get fixture :state))
                                         ("get_entries" (plist-get fixture :entries))
                                         ("switch_session"
                                          (should (equal file (plist-get payload :sessionPath))) nil)
                                         (_ (ert-fail (format "Unexpected RPC %s" type)))))
                                 session)))))
                (funcall scenario fixture)))
          (setf (pichat-session-restart-operation session) nil)
          (dolist (process (plist-get fixture :starts))
            (when (process-live-p process) (delete-process process)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun pichat-test-ssh-restart--begin (fixture)
  "Begin a real guarded restart, recording FIXTURE's callback deliveries."
  (let* ((session (plist-get fixture :session))
         (requested (pichat-reconfigure-select-preset
                     (pichat-reconfigure-captured-configuration session) 'coding)))
    (pichat-reconfigure-restart
     (pichat-reconfigure-capture-origin session) requested
     (lambda (success reason)
       (plist-put fixture :results
                  (append (plist-get fixture :results) (list (list success reason))))))))

(defun pichat-test-ssh-restart--recover (fixture choice)
  "Recover FIXTURE with CHOICE, recording callback deliveries."
  (pichat-reconfigure-recover
   (plist-get fixture :session) choice
   (lambda (success reason)
     (plist-put fixture :results
                (append (plist-get fixture :results) (list (list success reason)))))))

(provide 'pichat-test-reconfigure-ssh-support)
;;; pichat-test-reconfigure-ssh-support.el ends here
