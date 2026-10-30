;;; pichat-tool-runtime.el --- Initial tool and SSH identity readiness -*- lexical-binding: t; -*-

;;; Commentary:
;; The actual process, not a discovery snapshot, establishes tool readiness.
;; Ordinary RPC output/input stays behind this barrier until selected tools
;; are enabled.  No hook continually reapplies the selection after launch.

;;; Code:

(require 'cl-lib)
(require 'pichat-tool-selection)
(require 'pichat-tool-discovery)
(require 'pichat-events)
(require 'pichat-process-lifetime)

(defun pichat-tool-runtime-prepare (session names)
  "Stage the helper for SESSION and capture exact selected NAMES.
Return its runtime path.  Called only during actual process startup, never
when building a replacement command during preflight."
  (let ((helper (pichat-tool-discovery-prepare-helper (pichat-session-transport session))))
    (setf (pichat-session-rpc-startup-control session)
          (list :helper helper :names (copy-sequence names) :process nil :verified nil
                :queue nil :handler nil :timer nil :requests nil :callback nil))
    (plist-get helper :path)))

(defun pichat-tool-runtime-dispose (session)
  "Retire SESSION's tool control state after process exit or startup failure."
  (when-let* ((control (pichat-session-rpc-startup-control session)))
    (setf (pichat-session-rpc-startup-control session) nil)
    (when-let* ((timer (plist-get control :timer))) (cancel-timer timer))
    (dolist (id (plist-get control :requests)) (pichat-rpc-cancel-request session id))
    (let ((process (plist-get control :process)))
      (if (and process
               (eq 'ssh (pichat-transport-kind (pichat-session-transport session)))
               (not (pichat-process-lifetime-confirmed-p process)))
          (progn
            (process-put process 'pichat-helper-cleanup
                         (plist-get (plist-get control :helper) :cleanup))
            ;; An active restart observer, not the local sentinel, decides
            ;; whether this is uncertain.  Avoid a spurious failure record
            ;; while its ordinary shutdown confirmation is still pending.
            (unless (eq (plist-get (pichat-session-restart-operation session) :phase)
                        'stopping)
              (pichat-chat-diagnostics-record
               session :origin 'tool-control
               :message "Remote shutdown is uncertain; private tool-control helper retained on target")))
        (condition-case err
            (funcall (plist-get (plist-get control :helper) :cleanup))
          (error (pichat-chat-diagnostics-record
                  session :origin 'tool-control
                  :message "Tool-control helper cleanup failed" :condition err)))))))

(defun pichat-tool-runtime-begin (session &optional callback)
  "Enable and verify SESSION's selections, then call CALLBACK (SUCCESS REASON).
The startup barrier also runs without CALLBACK.  Explicit initial saved-source
loading may call this again after its startup handlers; later source switches
and extension activation changes do not trigger it automatically."
  (let* ((control (pichat-session-rpc-startup-control session))
         (process (pichat-session-process session))
         (generation (pichat-session-process-generation session))
         (restart-token (plist-get (pichat-session-restart-operation session) :token))
         (request-id (format "pichat-enable-%s" (gensym)))
         (names (plist-get control :names))
         payload handled finished)
    (unless control (error "No captured extension tool policy"))
    (setf (plist-get control :verified) nil
          (plist-get control :process) process
          (plist-get control :callback) callback)
    (cl-labels
        ((owned ()
           (and (eq control (pichat-session-rpc-startup-control session))
                (eq process (pichat-session-process session))
                (eql generation (pichat-session-process-generation session))))
         (finish (success reason)
           (when (and (owned) (not finished))
             (setq finished t)
             (when-let* ((timer (plist-get control :timer))) (cancel-timer timer))
             (setf (plist-get control :timer) nil (plist-get control :handler) nil)
             (dolist (id (plist-get control :requests)) (pichat-rpc-cancel-request session id))
             (setf (plist-get control :requests) nil)
             (if success
                 (progn
                   (setf (plist-get control :verified) t)
                   (let ((queue (nreverse (plist-get control :queue))))
                     (setf (plist-get control :queue) nil)
                     (dolist (line queue) (pichat-rpc--write-line session line)))
                   (when callback (funcall callback t nil)))
               (let ((reason (truncate-string-to-width (or reason "Tool verification failed") 600 nil nil "…")))
                 (let ((diagnostic (pichat-chat-diagnostics-record session :origin 'tool-control :message reason)))
                   (pichat-emit session 'error :message (plist-get diagnostic :summary) :diagnostic diagnostic))
                 ;; Stop before notifying any waiter; no selected-but-unverified
                 ;; runtime can remain usable after a failure.
                 (pichat-rpc-stop session)
                 (when callback (funcall callback nil reason))))))
         (failed (response _session) (finish nil (plist-get response :error)))
         (send (type data continuation)
           (when (and (owned) (not finished))
             (let ((pichat-rpc--internal-request t)
                   (pichat-rpc--operation-token restart-token)
                   (pichat-rpc-request-timeout pichat-tool-discovery-timeout))
               (push (pichat-rpc-send
                      session type data
                      (lambda (response _session)
                        (when (and (owned) (not finished))
                          (condition-case err
                              (funcall continuation (plist-get response :data))
                            (error (finish nil (error-message-string err)))))) #'failed)
                     (plist-get control :requests)))))
         (complete () (when (and payload handled) (finish t nil)))
         (event (record)
           (when (and (owned) (not finished))
             (condition-case err
                 (pcase (plist-get record :type)
                   ("extension_ui_request"
                    (cond
                     ((and (equal (plist-get record :method) "input")
                           (pichat-bridge-transport-startup-reply record))
                      (let ((pichat-rpc--internal-request t) (pichat-rpc--operation-token restart-token))
                        (pichat-rpc-extension-ui-value session (plist-get record :id)
                                                       (pichat-bridge-transport-startup-reply record)))
                      t)
                     ((equal (plist-get record :title) pichat-tool-discovery--title)
                      (unless (and (equal (plist-get record :method) "input") (not payload))
                        (error "Unexpected tool-control response"))
                      (let ((raw (plist-get record :placeholder)))
                        (unless (and (stringp raw) (<= (string-bytes raw) pichat-tool-discovery--limit))
                          (error "Invalid or oversized tool-control response"))
                        (let* ((data (json-parse-string raw :array-type 'array :null-object nil))
                               (tools (pichat-tool-discovery--catalogue data request-id))
                               (identity (pichat-process-lifetime-identity
                                          (gethash "processIdentity" data))))
                          (when identity
                            (let ((previous (process-get process 'pichat-lifetime)))
                              (when (and previous (not (equal previous identity)))
                                (error "Actual Pi process identity changed")))
                            (process-put process 'pichat-lifetime identity))
                          (pichat-tool-selection-check-extensions (list :extensions names) tools)
                          (dolist (name names)
                            (unless (plist-get (cl-find name tools :key (lambda (tool) (plist-get tool :name))
                                                       :test #'equal) :active)
                              (error "Extension tool %s was not enabled" name)))))
                      (let ((pichat-rpc--internal-request t) (pichat-rpc--operation-token restart-token))
                        (pichat-rpc-extension-ui-value session (plist-get record :id) "ack"))
                      (setq payload t) (complete) t)
                     ((member (plist-get record :method) '("input" "select" "confirm" "editor"))
                      (error "Enabling extension tools requires user interaction; configure Pi on this target first"))))
                   ("extension_error" (error "Pi extension startup/control error"))
                   ((or "agent_start" "message_start") (error "Unexpected model activity during tool verification")))
               (error (finish nil (error-message-string err)) t)))))
      (setf (plist-get control :handler) #'event
            (plist-get control :timer)
            (run-at-time pichat-tool-discovery-timeout nil
                         (lambda () (finish nil "Timed out enabling selected extension tools"))))
      (condition-case err
          (send "get_state" nil
                (lambda (_state)
                  (send "get_commands" nil
                        (lambda (data)
                          (let* ((matches (cl-remove-if-not
                                           (lambda (command) (equal (plist-get command :name) pichat-tool-discovery--command))
                                           (plist-get data :commands)))
                                 (command (car matches)))
                            (unless (and (= (length matches) 1)
                                         (equal (plist-get command :source) "extension")
                                         (equal (plist-get (plist-get command :sourceInfo) :path)
                                                (plist-get (plist-get control :helper) :path)))
                              (error "PiChat tool-control helper unavailable or source mismatch")))
                          (send "prompt"
                                (list :message
                                      (concat "/" pichat-tool-discovery--command " "
                                              (json-serialize (list :protocolVersion 1 :requestId request-id
                                                                    :operation "enable" :names (vconcat names)))))
                                (lambda (data)
                                  (unless (equal (plist-get data :disposition) "handled")
                                    (error "Pi did not handle the internal tool-control command"))
                                  (setq handled t) (complete)))))))
        (error (finish nil (error-message-string err)))))))

(defun pichat-tool-runtime-verify (session callback)
  "Verify tools before initial loaded-source commit, or call CALLBACK directly."
  (if (pichat-session-rpc-startup-control session)
      (pichat-tool-runtime-begin session callback)
    (funcall callback t nil)))

(provide 'pichat-tool-runtime)
;;; pichat-tool-runtime.el ends here
