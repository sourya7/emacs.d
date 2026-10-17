;;; pichat-artifact-runner.el --- Explicit local code execution -*- lexical-binding: t; -*-
;;; Commentary:
;; Not a sandbox.  Scripts can access credentials/network/files.  Pi tool
;; permissions do not govern Emacs subprocesses.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-artifact-elisp)
(require 'pichat-view)
(require 'pichat-artifact-result)
(defgroup pichat-artifact-runner nil "Explicit PiChat code runners." :group 'pichat)
(defcustom pichat-artifact-runner-timeout 15 "Maximum run time in seconds." :type 'number :group 'pichat-artifact-runner)
(defcustom pichat-artifact-runner-output-limit 65536 "Maximum output characters." :type 'integer :group 'pichat-artifact-runner)
(defconst pichat-artifact-runner-specs
  '((python "python3" ".py" ("python" "python3" "py"))
    (javascript "node" ".js" ("javascript" "js" "node"))
    (shell "sh" ".sh" ("sh" "shell" "bash"))
    (elisp nil nil ("elisp" "emacs-lisp")))
  "Runner, executable, extension, and explicit language aliases.")
(defvar-local pichat-artifact-runner--process nil)
(defvar-local pichat-artifact-runner--timer nil)
(defvar-local pichat-artifact-runner--file nil)
(defvar-local pichat-artifact-runner--output-start nil)
(defvar-local pichat-artifact-runner--captured-output nil)
(defvar-local pichat-artifact-runner--status nil)
(defvar-local pichat-artifact-runner--terminal-reason nil)
(defvar-local pichat-artifact-runner--exit nil)
(defvar-local pichat-artifact-runner--code nil)
(defvar-local pichat-artifact-runner--directory nil)
(defvar-local pichat-artifact-runner--executable nil)

(define-derived-mode pichat-artifact-runner-result-mode pichat-artifact-result-mode
  "PiChat-Code-Run" "Read-only output from an explicit code subprocess.")

(defun pichat-artifact-runner-select (language)
  "Return runner spec for LANGUAGE, prompting for unknown or missing language."
  (or (cl-find-if (lambda (spec) (member (downcase (or language "")) (nth 3 spec)))
                  pichat-artifact-runner-specs)
      (assoc (intern (completing-read "Run with: "
                                    (mapcar (lambda (spec) (symbol-name (car spec)))
                                            pichat-artifact-runner-specs)
                                    nil t)) pichat-artifact-runner-specs)))

(defun pichat-artifact-runner--report ()
  "Return a bounded report of the current subprocess result."
  (format "Code run: %s\nCwd: %s\nStatus: %s\nCode:\n%s\nstdout/stderr:\n%s"
          (pichat-artifact-result-bounded pichat-artifact-runner--executable)
          (pichat-artifact-result-bounded pichat-artifact-runner--directory)
          (pcase pichat-artifact-runner--status
            ('running "running (partial output)")
            ('timeout "timed out")
            ('output-limit "output limit reached")
            ('exit (format "exit %s" pichat-artifact-runner--exit))
            ('signal (format "signal (status %s)" pichat-artifact-runner--exit))
            (_ "unknown"))
          (pichat-artifact-result-bounded pichat-artifact-runner--code)
          (pichat-artifact-result-bounded pichat-artifact-runner--captured-output)))

(defun pichat-artifact-runner--cleanup ()
  "Stop the current execution and remove its temporary resources."
  (when (timerp pichat-artifact-runner--timer)
    (cancel-timer pichat-artifact-runner--timer))
  (setq pichat-artifact-runner--timer nil)
  (when (process-live-p pichat-artifact-runner--process)
    (delete-process pichat-artifact-runner--process))
  (when (and pichat-artifact-runner--file (file-exists-p pichat-artifact-runner--file))
    (delete-file pichat-artifact-runner--file))
  (setq pichat-artifact-runner--file nil))

(defun pichat-artifact-runner--finish (process event)
  "Finish PROCESS on EVENT without retaining temporary resources."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq process pichat-artifact-runner--process)
          (setq pichat-artifact-runner--exit (process-exit-status process)
                pichat-artifact-runner--status
                (or pichat-artifact-runner--terminal-reason
                    (if (eq (process-status process) 'exit) 'exit 'signal)))
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\nExit: %s (%s)\n" (process-exit-status process)
                            (string-trim event))))
          (pichat-artifact-runner--cleanup))))))

(defun pichat-artifact-runner--filter (process output)
  "Append bounded OUTPUT from PROCESS, stopping it on limit."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let* ((remaining (- pichat-artifact-runner-output-limit
                           (- (point-max) pichat-artifact-runner--output-start)))
             (inhibit-read-only t))
        (goto-char (point-max))
        (let ((chunk (substring output 0 (max 0 (min remaining (length output))))))
          (insert chunk)
          (when (stringp pichat-artifact-runner--captured-output)
            (setq pichat-artifact-runner--captured-output
                  (concat pichat-artifact-runner--captured-output chunk))))
        (when (>= (length output) remaining)
          (setq pichat-artifact-runner--terminal-reason 'output-limit)
          (insert "\n[Output limit reached]\n")
          (delete-process process))))))

(defun pichat-artifact-runner--timeout (process)
  "Stop PROCESS on deadline and report the timeout in its result buffer."
  (when (process-live-p process)
    (when (buffer-live-p (process-buffer process))
      (with-current-buffer (process-buffer process)
        (setq pichat-artifact-runner--terminal-reason 'timeout)
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\n[Timed out]\n"))))
    (delete-process process)))

(defun pichat-artifact-runner-run (code language directory)
  "Run exact CODE with LANGUAGE runner in local DIRECTORY; return output buffer."
  (when (file-remote-p directory) (user-error "Remote code execution is unsupported"))
  (unless (file-directory-p directory) (user-error "Working directory is unavailable"))
  (let* ((spec (pichat-artifact-runner-select language)))
    (if (eq (car spec) 'elisp)
        (pichat-artifact-elisp-run code directory)
      (pichat-artifact-runner--run-process code directory spec))))

(defun pichat-artifact-runner--run-process (code directory spec)
  "Run CODE in DIRECTORY with a subprocess described by SPEC."
  (let* ((origin (current-buffer))
         (token (pichat-artifact-result-source-token origin))
         (executable (executable-find (nth 1 spec)))
         (buffer (generate-new-buffer "*PiChat Code Run*"))
         file)
    (unless executable
      (kill-buffer buffer)
      (user-error "Runner executable not found: %s" (nth 1 spec)))
    (condition-case error-data
        (progn
          (setq file (make-temp-file "pichat-code-" nil (nth 2 spec)))
          (with-temp-file file (insert code))
          (with-current-buffer buffer
            (setq default-directory directory)
            (let ((inhibit-read-only t))
              (insert (format "Submitted code:\n%s\n\nExecutable/arguments: %S\nCwd: %s\n\n[s] Share after completion  [w / g y] Copy  [q] Quit\n\nstdout/stderr:\n"
                              code (list executable file) directory)))
            (pichat-artifact-runner-result-mode)
            (setq-local pichat-artifact-runner--file file
                        pichat-artifact-runner--output-start (point-max)
                        pichat-artifact-runner--captured-output ""
                        pichat-artifact-runner--status 'running
                        pichat-artifact-runner--code code
                        pichat-artifact-runner--directory directory
                        pichat-artifact-runner--executable executable)
            (pichat-artifact-result-setup
             origin token #'pichat-artifact-runner--report
             (lambda () (not (eq pichat-artifact-runner--status 'running))))
            (add-hook 'kill-buffer-hook #'pichat-artifact-runner--cleanup nil t)
            (setq-local pichat-artifact-runner--process
                        (make-process :name "pichat-code" :buffer buffer
                                      :command (list executable file)
                                      :connection-type 'pipe :noquery t
                                      :filter #'pichat-artifact-runner--filter
                                      :sentinel #'pichat-artifact-runner--finish))
            (setq-local pichat-artifact-runner--timer
                        (run-at-time pichat-artifact-runner-timeout nil
                                     #'pichat-artifact-runner--timeout
                                     pichat-artifact-runner--process)))
          (pichat-view-display buffer nil 'kill)
          buffer)
      (error
       (when (and file (file-exists-p file)) (delete-file file))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))
(provide 'pichat-artifact-runner)
;;; pichat-artifact-runner.el ends here
