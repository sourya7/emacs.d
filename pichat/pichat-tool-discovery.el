;;; pichat-tool-discovery.el --- Target-qualified extension tool probes -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit probes execute trusted extension startup code, not a sandbox.  This
;; module owns no global catalogue and never borrows a live runtime's state.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-rpc)
(require 'pichat-pi-environment)
(require 'pichat-transport)
(require 'pichat-bridge-transport)

(defcustom pichat-tool-discovery-timeout 25
  "Maximum seconds for a tool probe, excluding synchronous TRAMP file setup."
  :type 'number :group 'pichat)

(defconst pichat-tool-discovery-helper
  (expand-file-name "bridge/pichat-tool-control.ts"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Bundled PiChat tool-control extension.")
(defconst pichat-tool-discovery--command "pichat-tool-control-v1")
(defconst pichat-tool-discovery--title "__pichat_tool_control_v1__")
(defconst pichat-tool-discovery--limit (* 1024 1024))

(defun pichat-tool-discovery-prepare-helper (transport)
  "Return (:path PATH :cleanup FUNCTION) for the helper on TRANSPORT.
SSH gets a private target-side copy, not a translated host path.  The caller
must invoke cleanup only after its Pi process has stopped using the helper."
  (if (eq (pichat-transport-kind transport) 'local)
      (list :path pichat-tool-discovery-helper :cleanup #'ignore)
    (let* ((prefix (pichat-transport-runtime-file-name
                    transport "/tmp/pichat-tool-control-"))
           (directory (make-temp-file prefix t))
           (file (expand-file-name "pichat-tool-control.ts" directory)))
      (condition-case err
          (progn
            (set-file-modes directory #o700)
            (copy-file pichat-tool-discovery-helper file)
            (set-file-modes file #o600)
            (list :path (file-local-name file)
                  :cleanup (lambda () (delete-directory directory t))))
        ((error quit) (ignore-errors (delete-directory directory t))
                      (signal (car err) (cdr err)))))))

(defun pichat-tool-discovery--args (transport model)
  "Capture ordinary resource/model arguments for TRANSPORT and MODEL.
Do not include preset selection or persistence flags.  Complete wrappers and
ambiguous generic session/tool arguments are rejected instead of rewritten."
  (let* ((remote (eq (pichat-transport-kind transport) 'ssh))
         (args (append pichat-pi-default-args
                       (pichat-transport-pi-args transport)
                       (unless remote
                         (append (when pichat-default-model
                                   (list "--model" pichat-default-model))
                                 (when pichat-bridge-extension-file
                                   (list "-e" pichat-bridge-extension-file))
                                 pichat-pi-extra-args)))))
    (when (and (not remote) pichat-rpc-command)
      (user-error "Tool discovery requires a structured Pi command, not a complete wrapper"))
    (append args (when model (list "--model" model)))))

(defun pichat-tool-discovery--validate-args (args)
  "Reject ARGS that could filter discovery or open a saved conversation.
Resource, trust, prompt and model arguments otherwise retain their meaning."
  (while args
    (let ((arg (pop args)))
      (cond
       ((member arg '("--mode" "--provider" "--model" "--thinking" "--models"
                      "--api-key" "--extension" "-e" "--skill" "--prompt-template"
                      "--theme" "--use-theme" "--system-prompt" "--append-system-prompt"))
        (unless (and args (stringp (car args)))
          (user-error "Missing Pi discovery argument for %s" arg))
        (when (and (equal arg "--mode") (not (equal (car args) "rpc")))
          (user-error "Tool discovery requires RPC mode"))
        (pop args))
       ((member arg '("--offline" "--approve" "-a" "--no-approve" "-na"
                      "--no-session" "--no-extensions" "-ne" "--no-mcp"
                      "--no-skills" "-ns" "--no-prompt-templates" "-np"
                      "--no-themes" "--no-context-files" "-nc")))
       (t (user-error "Unsupported Pi discovery argument (no prompts, session or tool filters): %s" arg))))))

(defun pichat-tool-discovery-context (transport runtime-cwd executable &optional model)
  "Capture a qualified discovery context, including resolved argv/environment.
Use this with draft-reset when launch context changes.  This does not start Pi."
  (let ((args (pichat-tool-discovery--args transport model)))
    (pichat-tool-discovery--validate-args args)
    (list :transport (copy-pichat-transport transport) :cwd runtime-cwd
          :executable executable :args (copy-sequence args)
          :environment (pichat-pi-process-environment))))

(defun pichat-tool-discovery--catalogue (data request-id)
  "Validate helper DATA correlated with REQUEST-ID; return normalized tools."
  (unless (and (hash-table-p data) (equal (gethash "protocolVersion" data) 1)
               (equal (gethash "requestId" data) request-id))
    (error "Invalid tool-control envelope"))
  (unless (eq (gethash "ok" data) t)
    (error "Tool control failed: %s" (gethash "error" data "unknown error")))
  (let ((tools (gethash "tools" data))
        (active (gethash "activeTools" data))
        (seen (make-hash-table :test #'equal)))
    (unless (and (vectorp tools) (<= (length tools) 4096)
                 (vectorp active) (<= (length active) 4096)
                 (cl-every #'stringp active))
      (error "Invalid tool catalogue arrays"))
    (prog1
        (mapcar
         (lambda (tool)
           (unless (hash-table-p tool) (error "Invalid tool record"))
           (let ((name (gethash "name" tool))
                 (description (gethash "description" tool))
                 (exposure (gethash "exposure" tool)))
             (unless (and (stringp name) (<= 1 (length name) 256)
                          (not (gethash name seen))
                          (stringp description) (<= (length description) 4096)
                          (member exposure '("direct" "model-only" "codemode" "deferred" "hidden")))
               (error "Invalid or duplicate tool metadata"))
             (puthash name t seen)
             (list :name name :description description :exposure exposure
                   :active (not (null (member name (append active nil))))
                   :eligible (and (not (equal exposure "hidden"))
                                  (string-match-p "\\`[A-Za-z0-9_-]+\\'" name)))))
         (append tools nil))
      (unless (cl-every (lambda (name) (gethash name seen)) active)
        (error "Active tool missing from catalogue")))))

(cl-defun pichat-tool-discovery-start
    (transport runtime-cwd executable callback &key (args nil args-p) model environment)
  "Probe TRANSPORT in RUNTIME-CWD using EXECUTABLE; return a cancel function.
CALLBACK receives (TOOLS ERROR), exactly once unless cancelled.  ARGS, when
supplied, is the captured Pi resource/model argv (without the helper or preset
allowlist); otherwise ordinary PiChat settings apply.  ENVIRONMENT can supply
an already captured process environment.  Only the verified internal command
is sent through RPC prompt; no conversation prompt or model turn is requested.
Cancellation suppresses callbacks.  SSH probes request helper-owned shutdown
after acknowledgement; local probes use EOF.  A one-second grace bounds
teardown.  Forced SSH teardown reports uncertain remote cleanup."
  (let ((environment (or environment (pichat-pi-process-environment)))
        (args (if args-p args (pichat-tool-discovery--args transport model)))
        (request-id (format "pichat-%s" (gensym)))
        (remainder "") (early-output "") early-error
        (bytes 0) (stderr-bytes 0)
        process stderr-process stderr-buffer timer shutdown-timer startup-timer helper
        phase done closing result-tools result-error payload-received prompt-handled)
    (cl-labels
        ((send (record)
           (process-send-string process (concat (json-serialize record) "\n")))
         (dispose ()
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when shutdown-timer (cancel-timer shutdown-timer))
             (when startup-timer (cancel-timer startup-timer))
             (when (and process (process-live-p process)) (delete-process process))
             (when (and stderr-process (process-live-p stderr-process))
               (delete-process stderr-process))
             (when (buffer-live-p stderr-buffer)
               (when-let* ((stderr (get-buffer-process stderr-buffer)))
                 (when (process-live-p stderr) (delete-process stderr)))
               (kill-buffer stderr-buffer))
             (when helper
               (condition-case err (funcall (plist-get helper :cleanup))
                 (error (setq result-error (format "Helper cleanup failed: %s" (error-message-string err))))))
             (when result-error
               (setq result-tools nil
                     result-error (truncate-string-to-width result-error 600 nil nil "…")))
             (when callback (funcall callback result-tools result-error))))
         (finish (tools error)
           (unless (or closing done)
             (setq closing t result-tools tools result-error error)
             (when timer (cancel-timer timer))
             (if (and process (process-live-p process))
                 (progn
                   (ignore-errors
                     (if (and (not error) (eq (pichat-transport-kind transport) 'ssh))
                         ;; Pi 1.4's asynchronous prompt handler can request
                         ;; shutdown after its command-loop check has run.
                         ;; A read-only command services that pending request.
                         (send '(:id "shutdown" :type "get_state"))
                       (process-send-eof process)))
                   (setq shutdown-timer
                         (run-at-time
                          1 nil
                          (lambda ()
                            (setq result-tools nil
                                  result-error
                                  (concat (or result-error "Pi tool probe did not shut down")
                                          (if (eq (pichat-transport-kind transport) 'ssh)
                                              "; remote process cleanup is uncertain"
                                            "; forced probe termination")))
                            (dispose)))))
               (dispose))))
         (maybe-finish ()
           (when (and payload-received prompt-handled)
             (finish result-tools nil)))
         (response (record)
           (let ((id (gethash "id" record)))
             (cond
              ((equal id "state")
               (unless (and (equal phase 'state) (eq (gethash "success" record) t))
                 (error "Pi startup readiness failed"))
               (setq phase 'commands)
               (send '(:id "commands" :type "get_commands")))
              ((equal id "commands")
               (unless (and (eq phase 'commands) (eq (gethash "success" record) t))
                 (error "Pi command discovery failed"))
               (let* ((data (gethash "data" record))
                      (commands (and (hash-table-p data) (gethash "commands" data)))
                      (matches (and (vectorp commands)
                                    (cl-remove-if-not
                                     (lambda (item)
                                       (and (hash-table-p item)
                                            (equal (gethash "name" item) pichat-tool-discovery--command)))
                                     (append commands nil))))
                      (command (car matches))
                      (source (and command (gethash "sourceInfo" command))))
                 (unless (and (= (length matches) 1)
                              (equal (gethash "source" command) "extension")
                              (hash-table-p source)
                              (equal (gethash "path" source) (plist-get helper :path)))
                   (error "PiChat tool-control helper unavailable or source mismatch")))
               (setq phase 'catalogue)
               (send (list :id "catalogue" :type "prompt"
                           :message (concat "/" pichat-tool-discovery--command " "
                                            (json-serialize
                                             (list :protocolVersion 1 :requestId request-id
                                                   :operation "catalogue"
                                                   :shutdownAfterAck
                                                   (eq (pichat-transport-kind transport) 'ssh)))))))
              ((equal id "catalogue")
               (let ((data (gethash "data" record)))
                 (unless (and (eq phase 'catalogue) (eq (gethash "success" record) t)
                              (hash-table-p data) (equal (gethash "disposition" data) "handled"))
                   (error "Pi did not handle the internal catalogue command")))
               (setq prompt-handled t)
               (maybe-finish)))))
         (record (data)
           (unless (hash-table-p data) (error "Non-object Pi RPC record"))
           (pcase (gethash "type" data)
             ("response" (response data))
             ("extension_error" (error "Pi extension startup/control error"))
             ("extension_ui_request"
              (if (and (equal (gethash "method" data) "input")
                       (equal (gethash "title" data) pichat-tool-discovery--title))
                  (progn
                    (unless (and (eq phase 'catalogue) (not payload-received))
                      (error "Unexpected tool-control payload"))
                    (let ((raw (gethash "placeholder" data)))
                      (unless (and (stringp raw) (<= (string-bytes raw) pichat-tool-discovery--limit))
                        (error "Invalid or oversized tool-control payload"))
                      (setq result-tools
                            (pichat-tool-discovery--catalogue
                             (json-parse-string raw :array-type 'array) request-id)))
                    (send (list :type "extension_ui_response" :id (gethash "id" data) :value "ack"))
                    (setq payload-received t)
                    (maybe-finish))
                (let ((reply (and (equal (gethash "method" data) "input")
                                  (pichat-bridge-transport-startup-reply
                                   (list :title (gethash "title" data))))))
                  (cond
                   (reply (send (list :type "extension_ui_response" :id (gethash "id" data) :value reply)))
                   ((member (gethash "method" data) '("input" "select" "confirm" "editor"))
                    (error "Tool discovery requires user interaction; configure Pi on this target first"))))))
             ((or "agent_start" "message_start")
              (error "Unexpected model/conversation activity in tool discovery"))))
         (stderr-filter (_proc chunk)
           (cl-incf stderr-bytes (string-bytes chunk))
           (when (> stderr-bytes pichat-tool-discovery--limit)
             (if process
                 (finish nil "Pi tool discovery stderr is too large")
               (setq early-error "Pi tool discovery stderr is too large"))))
         (filter (_proc chunk)
           ;; TRAMP can deliver startup output while make-process is still
           ;; returning.  Defer dispatch until the owned process is available.
           (if (not process)
               (if (> (+ (string-bytes early-output) (string-bytes chunk))
                      (* 2 pichat-tool-discovery--limit))
                   (setq early-error "Pi tool discovery output is too large")
                 (setq early-output (concat early-output chunk)))
             (unless (or closing done)
               (condition-case err
                   (progn
                     (cl-incf bytes (string-bytes chunk))
                     (when (> bytes (* 2 pichat-tool-discovery--limit))
                       (error "Pi tool discovery output is too large"))
                     (setq remainder (concat remainder chunk))
                     (let (end)
                       (while (and (not closing) (setq end (string-match "\n" remainder)))
                         (let ((line (string-remove-suffix "\r" (substring remainder 0 end))))
                           (setq remainder (substring remainder (1+ end)))
                           (record (json-parse-string line :array-type 'array))))))
                 (error (finish nil (error-message-string err))))))))
      (condition-case err
          (let ((process-environment (copy-sequence environment)))
            (pichat-tool-discovery--validate-args args)
            (setq helper (pichat-tool-discovery-prepare-helper transport))
            ;; TRAMP's make-process handler accepts a buffer for :stderr,
            ;; unlike local make-process which also accepts a pipe process.
            (if (eq (pichat-transport-kind transport) 'ssh)
                (setq stderr-buffer (generate-new-buffer " *pichat-tool-probe-stderr*"))
              (setq stderr-process
                    (make-pipe-process :name "pichat-tool-probe-stderr" :noquery t
                                       :buffer nil :filter #'stderr-filter)))
            (setq process
                  (pichat-transport-make-process
                   transport runtime-cwd :name "pichat-tool-probe" :buffer nil
                   :coding 'utf-8-unix :stderr (or stderr-buffer stderr-process)
                   :command (append (list executable) args
                                    (list "--mode" "rpc" "--no-session" "--extension"
                                          (plist-get helper :path)))
                   :filter #'filter
                   :sentinel (lambda (proc _event)
                               (when (and (not done) (memq (process-status proc) '(exit signal)))
                                 (if closing
                                     (progn
                                       (unless (zerop (process-exit-status proc))
                                         (setq result-tools nil result-error
                                               (or result-error "Pi tool probe exited unsuccessfully")))
                                       (dispose))
                                   (finish nil "Pi tool probe exited before discovery completed"))))))
            (when stderr-buffer
              (setq stderr-process (get-buffer-process stderr-buffer))
              (when stderr-process
                (set-process-filter stderr-process #'stderr-filter)
                (set-process-sentinel stderr-process #'ignore))
              (with-current-buffer stderr-buffer
                (unless (zerop (buffer-size))
                  (cl-incf stderr-bytes (string-bytes (buffer-string)))
                  (when (> stderr-bytes pichat-tool-discovery--limit)
                    (setq early-error "Pi tool discovery stderr is too large"))
                  (erase-buffer))))
            (setq phase 'state
                  timer (run-at-time pichat-tool-discovery-timeout nil
                                     (lambda () (finish nil "Pi tool discovery timed out"))))
            (if early-error (finish nil early-error)
              (unless (string-empty-p early-output) (filter process early-output)))
            ;; Match the RPC transport's shared-shell startup grace for SSH.
            (unless (or closing done)
              (if (eq (pichat-transport-kind transport) 'ssh)
                (setq startup-timer
                      (run-at-time 0.75 nil
                                   (lambda () (unless (or closing done)
                                                (condition-case err
                                                    (send '(:id "state" :type "get_state"))
                                                  (error (finish nil (error-message-string err))))))))
                (send '(:id "state" :type "get_state")))))
        ((error quit) (finish nil (error-message-string err))))
      (lambda () (setq callback nil) (finish nil "Cancelled")))))

(cl-defstruct (pichat-tool-discovery-draft
               (:constructor pichat-tool-discovery-draft-create))
  "Owner-scoped discovery cache; never global or attached to a live runtime."
  context tools error status cancel token)

(defun pichat-tool-discovery-draft-reset (draft context)
  "Invalidate DRAFT if captured CONTEXT changed; cancel obsolete callbacks.
CONTEXT is a caller-captured plist with :transport, :cwd, :executable, :args,
and :environment; include resolved model/resource/trust argv, not preset flags."
  (unless (equal context (pichat-tool-discovery-draft-context draft))
    (when-let* ((cancel (pichat-tool-discovery-draft-cancel draft))) (funcall cancel))
    (setf (pichat-tool-discovery-draft-context draft) (copy-tree context t)
          (pichat-tool-discovery-draft-tools draft) nil
          (pichat-tool-discovery-draft-error draft) nil
          (pichat-tool-discovery-draft-status draft) nil
          (pichat-tool-discovery-draft-cancel draft) nil
          (pichat-tool-discovery-draft-token draft) nil)))

(defun pichat-tool-discovery-draft-refresh (draft callback)
  "Explicitly refresh DRAFT; call CALLBACK with DRAFT when complete.
No reads or redraws implicitly start a process.  Reset cancels obsolete work."
  (when-let* ((cancel (pichat-tool-discovery-draft-cancel draft))) (funcall cancel))
  (let ((context (pichat-tool-discovery-draft-context draft))
        (token (list 'probe)))
    (unless context (user-error "Tool discovery has no captured launch context"))
    (setf (pichat-tool-discovery-draft-token draft) token
          (pichat-tool-discovery-draft-status draft) 'loading
          (pichat-tool-discovery-draft-tools draft) nil
          (pichat-tool-discovery-draft-error draft) nil)
    (setf (pichat-tool-discovery-draft-cancel draft)
          (pichat-tool-discovery-start
           (plist-get context :transport) (plist-get context :cwd)
           (plist-get context :executable)
           (lambda (tools error)
             (when (and (eq context (pichat-tool-discovery-draft-context draft))
                        (eq token (pichat-tool-discovery-draft-token draft)))
               (setf (pichat-tool-discovery-draft-tools draft) tools
                     (pichat-tool-discovery-draft-error draft) error
                     (pichat-tool-discovery-draft-status draft) (if error 'failed 'ready))
               (when callback (funcall callback draft))))
           :args (plist-get context :args) :environment (plist-get context :environment)))))

(provide 'pichat-tool-discovery)
;;; pichat-tool-discovery.el ends here
