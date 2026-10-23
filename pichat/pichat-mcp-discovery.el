;;; pichat-mcp-discovery.el --- Discover Pi MCP tools asynchronously -*- lexical-binding: t; -*-

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-transport)
(require 'pichat-pi-environment)
(require 'pichat-tool-selection)

(defcustom pichat-mcp-discovery-timeout 25
  "Maximum seconds allowed for a Pi MCP listing."
  :type 'positive-integer :group 'pichat)

(defconst pichat-mcp-discovery--output-limit (* 1024 1024))

(defun pichat-mcp-discovery--normalize (json)
  "Return (SERVERS . ERRORS) from Pi MCP list JSON.
Each server and tool carries its original name and effective exposure.
Normalized name collisions are marked ineligible: Pi gives these tools hash
suffixes that its shell discovery command does not report."
  (let* ((data (json-parse-string json :object-type 'hash-table :array-type 'list
                                  :null-object nil :false-object nil))
         (raw-servers (gethash "servers" data :missing))
         (errors (gethash "errors" data))
         (_ (unless (listp raw-servers)
              (error "Malformed Pi MCP catalogue: missing servers array")))
         (servers
          (mapcar
           (lambda (server)
             (let* ((name (gethash "name" server))
                    (exposure (gethash "exposure" server))
                    (overrides (gethash "toolExposure" server))
                    (raw-tools (gethash "tools" server))
                    (seen (make-hash-table :test #'equal))
                    (state (gethash "state" server)))
               (unless (and (stringp name) (listp raw-tools)
                            (cl-every #'stringp raw-tools))
                 (error "Malformed Pi MCP server catalogue"))
               (dolist (tool raw-tools)
                 (let ((key (pichat-tool-selection--name name tool)))
                   (puthash key (1+ (gethash key seen 0)) seen)))
               (list :name name :state state :enabled
                     (gethash "enabled" server)
                     :error (gethash "error" server)
                     :tools
                     (mapcar (lambda (tool)
                               (let ((effective
                                      (or (and overrides (gethash tool overrides))
                                          exposure)))
                                 (list :name tool :exposure effective
                                       :eligible (and (gethash "enabled" server)
                                                      (equal state "connected")
                                                      (equal effective "direct")
                                                      (= 1 (gethash
                                                            (pichat-tool-selection--name name tool)
                                                            seen 0))))))
                             raw-tools))))
           raw-servers)))
    (cons servers errors)))

(defun pichat-mcp-discovery-start (transport runtime-cwd executable callback)
  "Start `pi mcp list --json' on TRANSPORT in RUNTIME-CWD.
Call CALLBACK with (SERVERS ERRORS) or (nil ERROR-STRING).  Return a
cancellation function.  Incomplete or failed discovery is never reported
as a successful empty catalogue."
  (let ((stdout (generate-new-buffer " *PiChat MCP discovery*"))
        (stderr (generate-new-buffer " *PiChat MCP discovery stderr*"))
        process timer finished)
    (cl-labels ((finish (servers errors)
                  (unless finished
                    (setq finished t)
                    (when timer (cancel-timer timer))
                    (when (and process (process-live-p process)) (delete-process process))
                    (when (buffer-live-p stdout) (kill-buffer stdout))
                    (when (buffer-live-p stderr) (kill-buffer stderr))
                    (when callback (funcall callback servers errors)))))
      (condition-case err
          (let ((process-environment (pichat-pi-process-environment)))
            (setq process
                  (pichat-transport-make-process
                   transport runtime-cwd :name "pichat-mcp-discovery"
                   :buffer stdout :stderr stderr
                   :command (list executable "mcp" "list" "--json")
                   :filter (lambda (_proc chunk)
                             (when (buffer-live-p stdout)
                               (with-current-buffer stdout
                                 (if (> (+ (buffer-size) (length chunk))
                                        pichat-mcp-discovery--output-limit)
                                     (finish nil "Pi MCP discovery output is too large")
                                   (goto-char (point-max)) (insert chunk)))))
                   :sentinel
                   (lambda (proc _event)
                     (when (and (not finished)
                                (memq (process-status proc) '(exit signal)))
                       (condition-case parse-error
                           (let* ((result
                                   (with-current-buffer stdout
                                     (pichat-mcp-discovery--normalize
                                      (buffer-substring-no-properties
                                       (point-min) (point-max)))))
                                  (errors (cdr result))
                                  (diagnostic
                                   (unless (zerop (process-exit-status proc))
                                     (format "Pi MCP discovery exited %d%s"
                                             (process-exit-status proc)
                                             (with-current-buffer stderr
                                               (let ((text (string-trim (buffer-string))))
                                                 (if (string-empty-p text) ""
                                                   (concat ": " (truncate-string-to-width
                                                                 text 300 nil nil "…")))))))))
                             (finish (car result) (append errors (and diagnostic (list diagnostic)))))
                         (error (finish nil (format "Pi MCP discovery failed: %s"
                                                    (error-message-string parse-error)))))))))
            (setq timer
                  (run-at-time pichat-mcp-discovery-timeout nil
                               (lambda () (finish nil "Pi MCP discovery timed out")))))
        (error (finish nil (error-message-string err))))
      (lambda () (setq callback nil) (finish nil nil)))))

(provide 'pichat-mcp-discovery)
;;; pichat-mcp-discovery.el ends here
