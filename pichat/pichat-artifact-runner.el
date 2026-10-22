;;; pichat-artifact-runner.el --- Explicit code execution on Pi's host -*- lexical-binding: t; -*-
;;; Commentary:
;; Not a sandbox.  Scripts can access credentials/network/files on the
;; selected host.  Pi tool permissions do not govern these subprocesses.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-artifact-elisp)
(require 'pichat-view)
(require 'pichat-artifact-result)
(require 'pichat-session)
(require 'pichat-path)

(defgroup pichat-artifact-runner nil "Explicit PiChat code runners." :group 'pichat)
(defcustom pichat-artifact-runner-timeout 120
  "Maximum subprocess run time in seconds (not output publication time)."
  :type 'number :group 'pichat-artifact-runner)
(defcustom pichat-artifact-runner-output-limit 65536
  "Maximum output characters shown in a subprocess result view."
  :type 'integer :group 'pichat-artifact-runner)
(defcustom pichat-artifact-runner-output-max-bytes (* 32 1024 1024)
  "Maximum UTF-8 bytes retained in a subprocess spill file.
The run continues after this limit, but the resulting file is incomplete."
  :type 'integer :group 'pichat-artifact-runner)
(defcustom pichat-artifact-runner-output-directory nil
  "Directory for published output files, or nil for the runtime's temporary directory.
SSH sessions default to remote /tmp.  An override must be accessible to the
owning Pi runtime through its captured path mappings."
  :type '(choice (const :tag "Runtime temporary directory" nil) directory)
  :group 'pichat-artifact-runner)
(defcustom pichat-artifact-runner-publication-timeout 30
  "Maximum seconds allowed to publish an output file over TRAMP."
  :type 'number :group 'pichat-artifact-runner)

(defconst pichat-artifact-runner-specs
  '((python "python3" ".py" ("python" "python3" "py"))
    (javascript "node" ".js" ("javascript" "js" "node"))
    (shell "sh" ".sh" ("sh" "shell" "bash"))
    (elisp nil nil ("elisp" "emacs-lisp")))
  "Runner, executable, extension, and explicit language aliases.")
(defvar-local pichat-artifact-runner--process nil)
(defvar-local pichat-artifact-runner--timer nil)
(defvar-local pichat-artifact-runner--file nil)
(defvar-local pichat-artifact-runner--captured-output nil)
(defvar-local pichat-artifact-runner--preview-limit nil)
(defvar-local pichat-artifact-runner--share-limit nil)
(defvar-local pichat-artifact-runner--preview-truncated nil)
(defvar-local pichat-artifact-runner--status nil)
(defvar-local pichat-artifact-runner--terminal-reason nil)
(defvar-local pichat-artifact-runner--exit nil)
(defvar-local pichat-artifact-runner--code nil)
(defvar-local pichat-artifact-runner--directory nil)
(defvar-local pichat-artifact-runner--executable nil)
(defvar-local pichat-artifact-runner--transport nil)
(defvar-local pichat-artifact-runner--session nil)
(defvar-local pichat-artifact-runner--staging nil)
(defvar-local pichat-artifact-runner--output-file nil)
(defvar-local pichat-artifact-runner--output-bytes 0)
(defvar-local pichat-artifact-runner--discarded-bytes 0)
(defvar-local pichat-artifact-runner--capture-error nil)

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

(defun pichat-artifact-runner--output-description (&optional for-agent)
  "Describe output availability, omitting Emacs-only paths when FOR-AGENT."
  (cond
   (pichat-artifact-runner--output-file
    (format "Output: %s; %soutput at %s (%d bytes captured%s)"
            (if pichat-artifact-runner--preview-truncated
                "preview shown" "full output shown in view")
            (if (> pichat-artifact-runner--discarded-bytes 0)
                "INCOMPLETE " "")
            pichat-artifact-runner--output-file
            pichat-artifact-runner--output-bytes
            (concat
             (if (> pichat-artifact-runner--discarded-bytes 0)
                 (format "; %d bytes discarded at safety limit"
                         pichat-artifact-runner--discarded-bytes) "")
             (if pichat-artifact-runner--session ""
               "; Emacs-local, Pi access not verified"))))
   (pichat-artifact-runner--capture-error
    (concat "Output: full output unavailable to Pi ("
            (pichat-artifact-result-bounded pichat-artifact-runner--capture-error)
            ")"
            (if (or for-agent (not pichat-artifact-runner--staging)) ""
              (format "; Emacs-only staging file: %s"
                      pichat-artifact-runner--staging))))
   (pichat-artifact-runner--staging
    (if (eq pichat-artifact-runner--status 'publishing)
        "Output: preview shown; publishing full output to Pi's host"
      "Output: preview shown; collecting full output (not yet available to Pi)"))
   (t "Output: preview shown")))

(defun pichat-artifact-runner--agent-output-description ()
  "Describe the shared output, not the Emacs view."
  (cond
   (pichat-artifact-runner--output-file
    (concat "Output excerpt — "
            (if (> pichat-artifact-runner--discarded-bytes 0)
                (format "INCOMPLETE output at %s (%d bytes captured; %d discarded)"
                        pichat-artifact-runner--output-file
                        pichat-artifact-runner--output-bytes
                        pichat-artifact-runner--discarded-bytes)
              (format "full output: %s" pichat-artifact-runner--output-file))
            (unless pichat-artifact-runner--session
              " (Emacs-local; Pi access not verified)")))
   (pichat-artifact-runner--capture-error
    (concat "Output excerpt — full output unavailable: "
            (pichat-artifact-result-bounded pichat-artifact-runner--capture-error)))
   (pichat-artifact-runner--staging
    (if (eq pichat-artifact-runner--status 'publishing)
        "Output excerpt — full output is being published"
      "Output excerpt — full output is still being collected"))
   (t "Output:")))

(defun pichat-artifact-runner--fence (text)
  "Delimit TEXT safely even when it contains Markdown fences."
  (let ((fence "```"))
    (while (string-match-p (regexp-quote fence) text)
      (setq fence (concat fence "`")))
    (concat fence "\n" text (unless (string-suffix-p "\n" text) "\n") fence)))

(defun pichat-artifact-runner--report ()
  "Return a bounded report using this run's captured sharing threshold."
  (let ((pichat-artifact-result-share-limit
         (or pichat-artifact-runner--share-limit
             pichat-artifact-result-share-limit)))
    (format "Ran with %s — %s\n\nExecuted script:\n%s\n\n%s\n%s"
            (file-name-nondirectory pichat-artifact-runner--executable)
            (pcase pichat-artifact-runner--status
              ('running "running (partial output)")
              ('publishing "publishing output (not ready to share)")
              ('timeout "timed out")
              ('exit (format "exit %s" pichat-artifact-runner--exit))
              ('signal (format "signal (status %s)" pichat-artifact-runner--exit))
              (_ "unknown"))
            (pichat-artifact-runner--fence
             (pichat-artifact-result-bounded pichat-artifact-runner--code))
            (pichat-artifact-runner--agent-output-description)
            (pichat-artifact-runner--fence
             (pichat-artifact-result-bounded pichat-artifact-runner--captured-output)))))

(defun pichat-artifact-runner--cleanup ()
  "Stop execution and remove the script and unpublished, unneeded staging."
  (when (timerp pichat-artifact-runner--timer)
    (cancel-timer pichat-artifact-runner--timer))
  (setq pichat-artifact-runner--timer nil)
  (when (process-live-p pichat-artifact-runner--process)
    (delete-process pichat-artifact-runner--process))
  (when pichat-artifact-runner--file
    (ignore-errors (delete-file pichat-artifact-runner--file))
    (setq pichat-artifact-runner--file nil))
  ;; An explicitly reported failed staging file remains available for manual
  ;; inspection; successful published files outlive the result view.
  (when (and pichat-artifact-runner--staging
             (not pichat-artifact-runner--capture-error))
    (ignore-errors (delete-file pichat-artifact-runner--staging))
    (setq pichat-artifact-runner--staging nil)))

(defun pichat-artifact-runner--destination ()
  "Return (EMACS-FILE-PREFIX . PI-PATH-PREFIX) for output publication."
  (let* ((transport pichat-artifact-runner--transport)
         (ssh (eq (pichat-transport-kind transport) 'ssh))
         (override pichat-artifact-runner-output-directory)
         (directory (file-name-as-directory
                     (expand-file-name
                      (or override
                          (if ssh
                              (pichat-transport-runtime-file-name transport "/tmp")
                            temporary-file-directory)))))
         (remote (file-remote-p directory))
         (path (cond
                ((and ssh remote
                      (equal remote (pichat-transport-tramp-prefix transport)))
                 (file-local-name directory))
                ((and ssh remote)
                 (error "Output directory belongs to a different SSH target"))
                (t (plist-get
                    (pichat-path-resolve-to-runtime
                     (expand-file-name "pichat-output-" directory)
                     (if pichat-artifact-runner--session
                         (pichat-session-path-context
                          pichat-artifact-runner--session)
                       (pichat-transport-path-context pichat-transport-local)))
                    :path)))))
    (unless (and path (file-name-absolute-p path) (not (file-remote-p path)))
      (error "Output directory is not mapped to a native Pi runtime path"))
    (cons (expand-file-name "pichat-output-" directory)
          (expand-file-name "pichat-output-" (file-name-directory path)))))

(defun pichat-artifact-runner--publish ()
  "Publish this buffer's spill file to the captured Pi runtime."
  (when (and pichat-artifact-runner--staging
             (not pichat-artifact-runner--capture-error))
    (let ((target nil)
          (staging pichat-artifact-runner--staging))
      (condition-case err
          (let* ((destination (pichat-artifact-runner--destination))
                 (prefix (car destination)))
            (if (and (not (file-remote-p prefix))
                     (equal (file-name-directory prefix)
                            (file-name-directory staging)))
                (setq target staging)
              (with-timeout (pichat-artifact-runner-publication-timeout
                             (error "Output publication timed out"))
                (setq target (make-temp-file prefix nil ".txt"))
                (copy-file staging target t)
                (set-file-modes target #o600)
                (unless (= (file-attribute-size (file-attributes target))
                           pichat-artifact-runner--output-bytes)
                  (error "Published output size differs from captured output"))))
            (setq pichat-artifact-runner--output-file
                  (if (eq target staging)
                      (concat (cdr destination)
                              (substring (file-name-nondirectory staging)
                                         (length (file-name-nondirectory prefix))))
                    (concat (file-name-directory (cdr destination))
                            (file-name-nondirectory target))))
            (unless (eq target staging)
              (delete-file staging))
            (setq pichat-artifact-runner--staging nil))
        (error
         (setq pichat-artifact-runner--capture-error
               (format "output publication failed: %s" (error-message-string err)))
         (when (and target (not (equal target staging)))
           (ignore-errors (delete-file target))))))))

(defun pichat-artifact-runner--finish (process event)
  "Finish PROCESS on EVENT and publish its captured output."
  (let ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq process pichat-artifact-runner--process)
          (setq pichat-artifact-runner--exit (process-exit-status process)
                pichat-artifact-runner--status 'publishing)
          (when (timerp pichat-artifact-runner--timer)
            (cancel-timer pichat-artifact-runner--timer))
          (setq pichat-artifact-runner--timer nil)
          (pichat-artifact-runner--publish)
          (setq pichat-artifact-runner--status
                (or pichat-artifact-runner--terminal-reason
                    (if (eq (process-status process) 'exit) 'exit 'signal)))
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (insert (format "\nExit: %s (%s)\n%s\n"
                            pichat-artifact-runner--exit (string-trim event)
                            (pichat-artifact-runner--output-description))))
          (pichat-artifact-runner--cleanup))))))

(defun pichat-artifact-runner--byte-prefix (text budget)
  "Return longest character prefix of TEXT fitting in BUDGET UTF-8 bytes."
  (let ((low 0) (high (length text)))
    (while (< low high)
      (let ((mid (/ (+ low high 1) 2)))
        (if (<= (string-bytes (encode-coding-string (substring text 0 mid)
                                                  'utf-8-unix)) budget)
            (setq low mid)
          (setq high (1- mid)))))
    (substring text 0 low)))

(defun pichat-artifact-runner--spool (text)
  "Append TEXT to the bounded local spill file, or record a capture error."
  (when (and pichat-artifact-runner--staging
             (not pichat-artifact-runner--capture-error)
             (not (string-empty-p text)))
    (let* ((bytes (string-bytes (encode-coding-string text 'utf-8-unix)))
           (remaining (max 0 (- pichat-artifact-runner-output-max-bytes
                                pichat-artifact-runner--output-bytes)))
           (part (if (<= bytes remaining) text
                   (pichat-artifact-runner--byte-prefix text remaining)))
           (written (string-bytes (encode-coding-string part 'utf-8-unix))))
      (condition-case err
          (progn
            (unless (string-empty-p part)
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region part nil pichat-artifact-runner--staging t 'silent)))
            (cl-incf pichat-artifact-runner--output-bytes written)
            (cl-incf pichat-artifact-runner--discarded-bytes (- bytes written)))
        (error (setq pichat-artifact-runner--capture-error
                     (format "output capture failed: %s" (error-message-string err))))))))

(defun pichat-artifact-runner--filter (process output)
  "Keep a bounded view preview and spool output truncated in either report or view."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when (and (eq pichat-artifact-runner--status 'running)
                 (or (null pichat-artifact-runner--process)
                     (eq process pichat-artifact-runner--process)))
        (let* ((preview-limit (or pichat-artifact-runner--preview-limit
                                  (max 0 pichat-artifact-runner-output-limit)))
               (share-limit (or pichat-artifact-runner--share-limit
                                (max 0 pichat-artifact-result-share-limit)))
               (previous (length pichat-artifact-runner--captured-output))
               (remaining (max 0 (- preview-limit previous)))
               (shown (substring output 0 (min remaining (length output))))
               (preview-overflow (> (length output) remaining))
               (spill (> (+ previous (length output))
                         (min preview-limit share-limit)))
               (created nil)
               (inhibit-read-only t))
          (unless (string-empty-p shown)
            (goto-char (point-max))
            (insert shown)
            (setq pichat-artifact-runner--captured-output
                  (concat pichat-artifact-runner--captured-output shown)))
          (when (and spill (not pichat-artifact-runner--staging)
                     (not pichat-artifact-runner--capture-error))
            (condition-case err
                (setq pichat-artifact-runner--staging
                      (make-temp-file "pichat-output-" nil ".txt")
                      created t)
              (error (setq pichat-artifact-runner--capture-error
                           (format "output capture failed: %s"
                                   (error-message-string err)))))
            (pichat-artifact-runner--spool pichat-artifact-runner--captured-output))
          (when pichat-artifact-runner--staging
            ;; The new file already contains SHOWN; later chunks must spool
            ;; their entire output even while SHOWN still grows in the view.
            (pichat-artifact-runner--spool
             (if created (substring output (length shown)) output)))
          (when (and preview-overflow (not pichat-artifact-runner--preview-truncated))
            (setq pichat-artifact-runner--preview-truncated t)
            (goto-char (point-max))
            (insert "\n[Preview limit reached; run continues]\n")))))))

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

(defun pichat-artifact-runner--context (directory session)
  "Return (TRANSPORT RUNTIME-CWD EMACS-CWD) for DIRECTORY and SESSION."
  (let* ((transport (if session (pichat-session-transport session)
                      pichat-transport-local))
         (ssh (eq (pichat-transport-kind transport) 'ssh))
         (cwd (if ssh (pichat-session-runtime-cwd session) directory)))
    (when (and ssh (or (not (stringp cwd))
                       (not (file-name-absolute-p cwd))
                       (file-remote-p cwd)))
      (user-error "SSH session has no valid runtime working directory"))
    (let ((emacs-cwd (if ssh (pichat-transport-runtime-file-name transport cwd)
                       directory)))
      (when (and (file-remote-p directory)
                 (not (and ssh (equal (file-remote-p directory)
                                      (pichat-transport-tramp-prefix transport)))))
        (user-error "Runner directory does not belong to the Pi SSH target"))
      (unless (file-directory-p emacs-cwd)
        (user-error "Working directory is unavailable on the execution host: %s" cwd))
      (list transport cwd emacs-cwd))))

(defun pichat-artifact-runner--executable (name transport emacs-cwd)
  "Find NAME on TRANSPORT, using EMACS-CWD for the remote PATH lookup."
  (let* ((remote (eq (pichat-transport-kind transport) 'ssh))
         (default-directory emacs-cwd)
         (tramp-remote-path (if (and remote (pichat-transport-remote-path transport))
                                (pichat-transport-remote-path transport)
                              tramp-remote-path))
         (found (if remote (executable-find name t) (executable-find name))))
    (unless found (user-error "Runner executable not found on %s: %s"
                              (pichat-transport-label transport) name))
    (if (file-remote-p found) (file-local-name found) found)))

(defun pichat-artifact-runner-run (code language directory &optional session)
  "Run exact CODE using LANGUAGE on SESSION's host, or locally without SESSION.
DIRECTORY is the originating Emacs directory; for SSH the captured session's
runtime cwd, not DIRECTORY, determines where the subprocess runs."
  (pcase-let* ((`(,transport ,cwd ,emacs-cwd)
                (pichat-artifact-runner--context directory session))
               (spec (pichat-artifact-runner-select language)))
    (if (eq (car spec) 'elisp)
        (progn
          (when (eq (pichat-transport-kind transport) 'ssh)
            (user-error "Emacs Lisp runs in this Emacs, not on the SSH Pi host"))
          (pichat-artifact-elisp-run code directory))
      (pichat-artifact-runner--run-process code cwd emacs-cwd transport session spec))))

(defun pichat-artifact-runner--run-process (code cwd emacs-cwd transport session spec)
  "Run CODE with SPEC on TRANSPORT in CWD, visible to Emacs as EMACS-CWD."
  (let* ((origin (current-buffer))
         (token (pichat-artifact-result-source-token origin))
         (executable (pichat-artifact-runner--executable (nth 1 spec)
                                                         transport emacs-cwd))
         (buffer (generate-new-buffer "*PiChat Code Run*"))
         (remote (eq (pichat-transport-kind transport) 'ssh))
         file)
    (condition-case error-data
        (progn
          (setq file (make-temp-file
                      (if remote
                          (pichat-transport-runtime-file-name
                           transport "/tmp/pichat-code-")
                        "pichat-code-") nil (nth 2 spec)))
          (with-temp-file file (insert code))
          (set-file-modes file #o600)
          (let ((script (if remote (file-local-name file) file)))
            (with-current-buffer buffer
              (setq default-directory emacs-cwd)
              (let ((inhibit-read-only t))
                (insert (format "Submitted code:\n%s\n\nHost: %s\nExecutable/arguments: %S\nCwd: %s\n\n[s] Share after completion  [w / g y] Copy  [q] Quit\n\nstdout/stderr:\n"
                                code (pichat-transport-description transport)
                                (list executable script) cwd)))
              (pichat-artifact-runner-result-mode)
              (setq-local pichat-artifact-runner--file file
                          pichat-artifact-runner--captured-output ""
                          pichat-artifact-runner--preview-limit
                          (max 0 pichat-artifact-runner-output-limit)
                          pichat-artifact-runner--share-limit
                          (max 0 pichat-artifact-result-share-limit)
                          pichat-artifact-runner--status 'running
                          pichat-artifact-runner--code code
                          pichat-artifact-runner--directory cwd
                          pichat-artifact-runner--executable executable
                          pichat-artifact-runner--transport transport
                          pichat-artifact-runner--session session)
              (pichat-artifact-result-setup
               origin token #'pichat-artifact-runner--report
               (lambda () (not (memq pichat-artifact-runner--status
                                     '(running publishing)))))
              (add-hook 'kill-buffer-hook #'pichat-artifact-runner--cleanup nil t)
              (setq-local pichat-artifact-runner--process
                          (pichat-transport-make-process
                           transport cwd :name "pichat-code" :buffer buffer
                           :command (list executable script)
                           :coding 'utf-8-unix
                           :filter #'pichat-artifact-runner--filter
                           :sentinel #'pichat-artifact-runner--finish))
              (setq-local pichat-artifact-runner--timer
                          (run-at-time pichat-artifact-runner-timeout nil
                                       #'pichat-artifact-runner--timeout
                                       pichat-artifact-runner--process))))
          (pichat-view-display buffer nil 'kill)
          buffer)
      (error
       (when file (ignore-errors (delete-file file)))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))
(provide 'pichat-artifact-runner)
;;; pichat-artifact-runner.el ends here
