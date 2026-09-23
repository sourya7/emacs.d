;;; pichat-test-backend-contract.el --- Native backend contract targets -*- lexical-binding: t; -*-

;;; Commentary:
;; Backend-neutral targets activated with the phase that implements them.  Later
;; targets use mocked HTTP around the real pinned llm lifecycle and the shared
;; chat path.  Codex proxy and Vertex protocol fixtures remain offline.

;;; Code:
(require 'pichat-test-support)

(defconst pichat-test-memory-backend 'pichat-test-memory
  "Non-process backend identity used by contract tests.")

(cl-defmethod pichat-backend-id ((_backend (eql pichat-test-memory)))
  'memory)

(cl-defmethod pichat-backend-label ((_backend (eql pichat-test-memory)))
  "test-memory")

(cl-defmethod pichat-backend-capabilities ((_backend (eql pichat-test-memory)))
  '(lifecycle))

(cl-defmethod pichat-backend-start
  ((_backend (eql pichat-test-memory)) session)
  (setf (pichat-session-backend-state session) '(:alive t)
        (pichat-session-state session) 'idle)
  session)

(cl-defmethod pichat-backend-stop
  ((_backend (eql pichat-test-memory)) session)
  (setf (pichat-session-backend-state session) '(:alive nil)
        (pichat-session-state session) 'stopped)
  session)

(cl-defmethod pichat-backend-alive-p
  ((_backend (eql pichat-test-memory)) session)
  (eq t (plist-get (pichat-session-backend-state session) :alive)))

(ert-deftest pichat-backend-contract-memory-liveness-and-optional-dependency ()
  "A non-process backend owns liveness and cannot collide with Pi scope reuse."
  (pichat-test-with-clean-state
    (let* ((scope '("project|local|/tmp/backend/"
                    "/tmp/backend/" "backend@test"))
           (pi-session (pichat-session-make
                        :cwd "/tmp/backend/"
                        :owner-scope-key (car scope)))
           (memory-session
            (pichat-session-make
             :backend pichat-test-memory-backend
             :backend-state '(:alive nil)
             :cwd "/tmp/backend/"
             :owner-scope-key (car scope)))
           (process (pichat-test--make-unit-process pi-session)))
      (unwind-protect
          (progn
            (should (eq 'pi (pichat-session-backend-id pi-session)))
            (should (eq 'memory (pichat-session-backend-id memory-session)))
            (should-not (pichat-session-process memory-session))
            (should-not (pichat-session-alive-p memory-session))
            (pichat-backend-start-session memory-session)
            (should (pichat-session-alive-p memory-session))
            (pichat-register-session pi-session scope)
            (pichat-register-session memory-session scope)
            (pichat-set-default-session pi-session)
            (pichat-set-default-session memory-session)
            (should (pichat-session-default-p pi-session))
            (should (pichat-session-default-p memory-session))
            (should (eq pi-session
                        (gethash (car scope) pichat--sessions-by-scope)))
            (should
             (eq memory-session
                 (gethash (list 'memory (car scope))
                          pichat--sessions-by-scope)))
            (cl-letf (((symbol-function 'pichat--scope-for-directory)
                       (lambda (&rest _args) scope)))
              (should (eq pi-session
                          (pichat-session-for-directory "/tmp/backend/"))))
            (pichat-backend-stop-session memory-session)
            (pichat-backend-stop-session memory-session)
            (should-not (pichat-session-alive-p memory-session))
            (should (eq 'stopped (pichat-session-state memory-session))))
        (when (process-live-p process) (delete-process process))
        (when-let* ((buffer (process-buffer process)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-backend-contract-pi-delegates-shared-operations ()
  "The default backend delegates shared operations to the existing Pi RPC API."
  (let ((session (pichat-session-make))
        calls)
    (cl-letf (((symbol-function 'pichat-rpc-start)
               (lambda (value) (push (list 'start value) calls)))
              ((symbol-function 'pichat-rpc-stop)
               (lambda (value) (push (list 'stop value) calls)))
              ((symbol-function 'pichat-rpc-prompt)
               (lambda (value message images streaming callback error-callback)
                 (push (list 'submit value message images streaming
                             callback error-callback)
                       calls)))
              ((symbol-function 'pichat-rpc-abort)
               (lambda (value &optional callback)
                 (push (list 'abort value callback) calls)))
              ((symbol-function 'pichat-rpc-abort-retry)
               (lambda (value &optional callback)
                 (push (list 'abort-retry value callback) calls)))
              ((symbol-function 'pichat-rpc-clear-queue)
               (lambda (value callback &optional error-callback)
                 (push (list 'clear-queue value callback error-callback) calls)))
              ((symbol-function 'pichat-rpc-new-session)
               (lambda (value &optional callback _parent)
                 (push (list 'new value callback) calls)))
              ((symbol-function 'pichat-rpc-get-state)
               (lambda (value callback &optional error-callback)
                 (push (list 'state value callback error-callback) calls)))
              ((symbol-function 'pichat-rpc-get-entries)
               (lambda (value cursor callback &optional error-callback)
                 (push (list 'transcript value cursor callback error-callback)
                       calls)))
              ((symbol-function 'pichat-rpc-get-session-stats)
               (lambda (value callback &optional error-callback)
                 (push (list 'stats value callback error-callback) calls)))
              ((symbol-function 'pichat-rpc-set-session-name)
               (lambda (value name &optional callback)
                 (push (list 'name value name callback) calls)))
              ((symbol-function 'pichat-rpc-cancel-request)
               (lambda (value request)
                 (push (list 'cancel value request) calls))))
      (pichat-backend-start-session session)
      (pichat-backend-submit-prompt
       session "hello" '((:image t)) 'follow-up #'ignore #'ignore)
      (pichat-backend-abort-session session nil #'ignore)
      (pichat-backend-abort-session session t #'ignore)
      (pichat-backend-clear-session-queue session #'ignore #'ignore)
      (pichat-backend-start-new-conversation session #'ignore)
      (pichat-backend-get-state session #'ignore #'ignore)
      (pichat-backend-get-transcript session "cursor" #'ignore #'ignore)
      (pichat-backend-get-stats session #'ignore #'ignore)
      (pichat-backend-name-session session "name" #'ignore)
      (pichat-backend-cancel-owned-request session "request")
      (pichat-backend-stop-session session))
    (should
     (equal '(start submit abort abort-retry clear-queue new state transcript stats name cancel stop)
            (mapcar #'car (nreverse calls))))))

(ert-deftest pichat-backend-contract-phase1-capability-rejection-is-preflight ()
  "Pi-only and submit operations reject before changing a memory chat draft."
  (pichat-test-with-clean-state
    (let* ((session
            (pichat-session-make
             :backend pichat-test-memory-backend
             :backend-state '(:alive t)
             :cwd default-directory))
           (pichat-chat-stop-session-on-kill nil)
           rpc-called
           buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-rpc-prompt)
                     (lambda (&rest _args) (setq rpc-called t)))
                    ((symbol-function 'pichat-rpc-compact)
                     (lambda (&rest _args) (setq rpc-called t)))
                    ((symbol-function 'pichat-rpc-get-commands)
                     (lambda (&rest _args) (setq rpc-called t)))
                    ((symbol-function 'pichat-rpc-extension-ui-value)
                     (lambda (&rest _args) (setq rpc-called t)))
                    ((symbol-function 'pichat-archive-cancel-discovery)
                     (lambda () (setq rpc-called t))))
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "keep this draft")
              (let ((draft (pichat-chat--input-text)))
                (should-error (pichat-chat-send-input) :type 'user-error)
                (should (equal draft (pichat-chat--input-text)))
                (should-not pichat-chat--prompt-history))
              (should-error (pichat-chat-compact) :type 'user-error)
              (should-error (pichat-command-run session) :type 'user-error)
              (let ((control
                     (pichat-chat--mode-line-model-control session "model")))
                (should-not (get-text-property 0 'local-map control)))
              (should-not pichat-chat--handlers))
            (should-not rpc-called)
            (should-not (get-buffer "*PiChat Session History*"))
            (should-error (pichat-sessions-list session) :type 'user-error)
            (should-not (get-buffer "*PiChat Session History*"))
            (should-error
             (pichat-archive-discover session (current-buffer)
                                      #'ignore #'ignore)
             :type 'user-error)
            (should-error
             (pichat-bridge-transport-handle
              session
              (list :id "bridge"
                    :title pichat-bridge-transport-handshake-title))
             :type 'user-error)
            (should-not rpc-called))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

;; Phase 2 native lifecycle contracts live in
;; `pichat-test-backend-llm' so Pi-only contract fixtures remain dependency-light.

;; Native tool contracts are activated in `pichat-test-backend-llm', where the
;; pinned real llm.el lifecycle and deterministic provider fixture are available.

(provide 'pichat-test-backend-contract)
;;; pichat-test-backend-contract.el ends here
