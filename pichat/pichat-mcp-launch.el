;;; pichat-mcp-launch.el --- Resolve MCP access for a runtime -*- lexical-binding: t; -*-

;;; Code:

(require 'pichat-mcp-discovery)
(require 'pichat-tool-discovery)

(defvar pichat-mcp-launch-catalogue nil
  "Dynamically supplied (TRANSPORT CWD EXECUTABLE SERVERS) for a launcher check.")

(defun pichat-mcp-launch--arguments (argv snapshot)
  "Return (ALLOWLIST-CELL . PROBE-ARGS) for MCP SNAPSHOT in captured ARGV.
The cell holds the exact tools argument, without mutating the capture."
  (let ((args (cdr argv)) allowlist probe)
    (while args
      (let ((flag (pop args)))
        (cond
         ((equal flag "--tools")
          (when (or allowlist (not args))
            (user-error "Invalid Pi allowlist for MCP selection"))
          (setq allowlist args)
          (pop args))
         ((member flag '("--session-dir" "--mode" "--provider" "--model" "--thinking" "--models"
                         "--api-key" "--extension" "-e" "--skill" "--prompt-template"
                         "--theme" "--use-theme" "--system-prompt" "--append-system-prompt"))
          (unless args (user-error "Missing Pi launch argument for %s" flag))
          (unless (equal flag "--session-dir")
            (push flag probe) (push (car args) probe))
          (pop args))
         ((or (member flag '("--no-mcp" "--no-tools" "-nt" "-t" "--no-builtin-tools" "-nbt"
                             "--exclude-tools" "-xt"))
              (string-prefix-p "--tools=" flag)
              (string-prefix-p "--exclude-tools=" flag))
          (user-error "Pi argument conflicts with exact MCP selection: %s" flag))
         (t (push flag probe)))))
    (let* ((names (and allowlist (split-string (car allowlist) "," t)))
           (mcp (seq-filter (lambda (name) (string-prefix-p "mcp__" name)) names)))
      (unless (equal mcp (plist-get snapshot :names))
        (user-error "Pi allowlist does not match the captured MCP selection")))
    (cons allowlist (nreverse probe))))

(defun pichat-mcp-launch-start (session argv callback)
  "Resolve SESSION's MCP choices for ARGV; call CALLBACK with (ARGV ERROR).
Return a cancellation function.  Add at most one reaching tool to a copy
of the launch argv; never write it back to the explicit Tools snapshot."
  (let* ((snapshot (pichat-session-tool-selection session))
         (transport (pichat-session-transport session))
         (cwd (or (pichat-session-runtime-cwd session) (pichat-session-cwd session)))
         (executable (car argv))
         (extensions (pichat-rpc-session-extensions session))
         (args (copy-sequence argv)) cancel)
    (cl-labels
        ((finish (command error)
           (when callback
             (let ((done callback))
               (setq callback nil)
               (funcall done command error))))
         (resolve-route (servers allowlist tools error)
           (when callback
             (let ((failure
                    (condition-case err
                        (progn
                          (when error (user-error "Tool discovery failed: %s" error))
                          (when-let* ((route (pichat-tool-selection-mcp-access snapshot servers tools)))
                            (setcar allowlist (concat (car allowlist) "," route)))
                          nil)
                      (error (error-message-string err)))))
               (finish (unless failure args) failure))))
         (check-servers (servers errors)
           (when callback
             (let ((failure
                    (condition-case err
                        (progn
                          (unless servers
                            (user-error "MCP discovery failed: %s" (or errors "no MCP servers")))
                          (pcase-let ((`(,allowlist . ,probe) (pichat-mcp-launch--arguments args snapshot)))
                            (if (pichat-tool-selection-mcp-indirect-p snapshot servers)
                                (setq cancel
                                      (pichat-tool-discovery-start
                                       transport cwd executable
                                       (lambda (tools error)
                                         (resolve-route servers allowlist tools error))
                                       :args probe :extensions extensions))
                              (finish args nil)))
                          nil)
                      (error (error-message-string err)))))
               (when failure (finish nil failure))))))
      (pcase pichat-mcp-launch-catalogue
        (`(,target ,directory ,program ,servers)
         (when (and (equal transport target)
                    (equal (directory-file-name cwd) (directory-file-name directory))
                    (equal executable program))
           (check-servers servers nil)))
        (_ nil))
      (when (and callback (not cancel))
        ;; Keep a synchronous discovery callback from overwriting the second
        ;; probe's canceller (the first probe may fail during acquisition).
        (let ((first (pichat-mcp-discovery-start transport cwd executable #'check-servers)))
          (unless cancel (setq cancel first))))
      (lambda () (setq callback nil) (when cancel (funcall cancel))))))

(defun pichat-mcp-launch-command (session argv &optional current-p)
  "Prepare ARGV for SESSION, waiting for MCP probes when needed.
CURRENT-P, when supplied, must still hold after processing probe events."
  (if (not (plist-get (pichat-session-tool-selection session) :mcp)) argv
    (when (pichat-transport-busy-p (pichat-session-transport session))
      (user-error "SSH connection is busy; defer MCP launch discovery"))
    (let (result cancel)
      (unwind-protect
          (progn
            (setq cancel (pichat-mcp-launch-start
                          session argv (lambda (command error) (setq result (list command error)))))
            (while (and (not result) (or (not current-p) (funcall current-p)))
              (accept-process-output nil 0.05))
            (when (and current-p (not (funcall current-p)))
              (user-error "MCP launch was cancelled during discovery"))
            (when (cadr result) (user-error "%s" (cadr result)))
            (car result))
        (when cancel (funcall cancel))))))

(defun pichat-mcp-launch-startup-extensions (snapshot argv)
  "Return explicit and launch-derived extension names, never MCP names."
  (let ((explicit (plist-get snapshot :extensions)))
    (if (not (plist-get snapshot :mcp)) explicit
      (let* ((allowlist (car (pichat-mcp-launch--arguments argv snapshot)))
             (names (split-string (car allowlist) "," t)))
        (append explicit
                (seq-filter (lambda (name)
                              (and (member name names)
                                   (not (member name explicit))
                                   (not (member name (plist-get snapshot :emacs)))))
                            '("codemode" "tool_search")))))))

(provide 'pichat-mcp-launch)
;;; pichat-mcp-launch.el ends here
