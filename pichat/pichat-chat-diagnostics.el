;;; pichat-chat-diagnostics.el --- Conservative PiChat diagnostics -*- lexical-binding: t; -*-

;;; Commentary:

;; Classifies transport and Pi response failures conservatively, retains a
;; bounded explicit-inspection record, and produces redacted summaries for the
;; ordinary chat status region.  This module does not depend on the chat mode.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'pp)
(require 'term)
(require 'pichat-session)
(require 'pichat-transport)
(require 'pichat-pi-environment)
(require 'pichat-path)
(require 'pichat-view)

(defgroup pichat-diagnostics nil
  "Transport diagnostics and setup guidance for PiChat."
  :group 'pichat)

(defcustom pichat-diagnostics-record-limit 20
  "Maximum number of diagnostic records retained per session."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-stderr-limit 100000
  "Maximum number of stderr characters retained in one diagnostic record."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-summary-width 320
  "Maximum width of a diagnostic summary shown in the normal chat UI."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-view-event-limit 100
  "Maximum number of recent raw RPC events shown by the diagnostics view."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-view-value-limit 20000
  "Maximum printed characters for one raw value in the diagnostics view."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-interactive-command nil
  "Optional argv list for starting interactive Pi setup.
When nil and `pichat-rpc-command' is nil, PiChat starts
`pichat-pi-executable' without RPC arguments.  Wrapper/container users should
set this explicitly because removing RPC arguments from an arbitrary wrapper
command is not safe."
  :type '(choice (const :tag "Derive from plain Pi executable" nil)
                 (repeat string))
  :group 'pichat-diagnostics)

(defvar pichat-pi-executable)
(defvar pichat-rpc-command)

(defun pichat-chat-diagnostics--text (value)
  "Return VALUE as plain text without signaling."
  (cond
   ((stringp value) value)
   ((null value) "")
   (t (condition-case nil (format "%s" value) (error "")))))

(defun pichat-chat-diagnostics--condition-symbol (condition)
  "Return the condition symbol from CONDITION, if available."
  (and (consp condition) (symbolp (car condition)) (car condition)))

(defun pichat-chat-diagnostics-classify (origin text &optional condition program)
  "Conservatively classify diagnostic TEXT from ORIGIN.
CONDITION and PROGRAM refine local process-start failures.  Return nil rather
than guessing when a message merely mentions credentials, permissions, status
codes, or missing files in unrelated output."
  (let* ((message (string-trim (pichat-chat-diagnostics--text text)))
         (lower (downcase message))
         (condition-symbol
          (pichat-chat-diagnostics--condition-symbol condition))
         (program-name (and (stringp program)
                            (regexp-quote
                             (file-name-nondirectory program)))))
    (pcase origin
      ('process-start
       (cond
        ((and (memq condition-symbol '(file-error file-missing))
              (string-match-p
               "tramp\|connection refused\|connection failed\|could not resolve hostname\|connection timed out"
               lower))
         'connection-failed)
        ((and (eq condition-symbol 'file-missing)
              (or (string-match-p "searching for program\\|doing vfork" lower)
                  (and program-name
                       (string-match-p
                        (format "no such file or directory.*%s" program-name)
                        lower))))
         'executable-not-found)
        ((and (memq condition-symbol '(file-error file-missing))
              (string-match-p "permission denied" lower))
         'permission-denied)
        ((string-empty-p (or program "")) 'invalid-command)))
      ((or 'process-exit 'rpc-response)
       (cond
        ((and (eq origin 'process-exit)
              (string-match-p
               "\\`env:.*no such file or directory\\|command not found"
               lower))
         'executable-not-found)
        ;; These are exact Pi 0.80.x guidance prefixes, not broad keyword
        ;; matches.  In particular, generic 401/unauthorized text is ignored.
        ((or (string-match-p
              "\\`no api key found for \"[^\"]+\"\\(?:[.\n]\\|\\'\\)"
              lower)
             (string-match-p
              "\\`no api key found for \\(?:the selected model\\|[-[:alnum:]_.]+\\)\\(?:[.\n]\\|\\'\\)"
              lower)
             (string-match-p
              "\\`no api key for [-[:alnum:]_.]+/[-[:alnum:]_.]+\\'"
              lower))
         'missing-credential)
        ((or (string-match-p "\\`no model selected\\(?:[.\n]\\|\\'\\)" lower)
             (string-match-p "\\`no models available\\(?:[.\n]\\|\\'\\)" lower))
         'provider-not-configured)))
      (_ nil))))

(defun pichat-chat-diagnostics--redact (text)
  "Return TEXT with common credential forms redacted."
  (let ((result (pichat-chat-diagnostics--text text))
        (case-fold-search t))
    (setq result
          (replace-regexp-in-string
           "\\bBearer[[:space:]]+[[:alnum:]_.~+/-]+"
           "Bearer [REDACTED]" result t t))
    (setq result
          (replace-regexp-in-string
           "\\bsk-[[:alnum:]_-]+" "[REDACTED]" result t t))
    (setq result
          (replace-regexp-in-string
           "\\b\\([[:alnum:]_]*\\(?:api[_-]?key\\|token\\|secret\\)[[:alnum:]_]*\\)[[:space:]]*[:=][[:space:]]*[^[:space:],;]+"
           "\\1=[REDACTED]" result t))
    result))

(defun pichat-chat-diagnostics-safe-summary-text (text)
  "Normalize, redact, and bound normal-UI TEXT."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[[:space:]\n\r]+" " "
    (string-trim (pichat-chat-diagnostics--redact text)))
   pichat-diagnostics-summary-width nil nil "…"))

(defun pichat-chat-diagnostics-setup-kind (&optional session)
  "Return the configured setup kind for optional SESSION."
  (cond
   ((and session
         (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh))
    'ssh)
   ((and (boundp 'pichat-rpc-command) pichat-rpc-command) 'wrapper-command)
   (t 'plain-executable)))

(defun pichat-chat-diagnostics--setup-hint (setup-kind)
  "Return conservative setup guidance for SETUP-KIND."
  (if (eq setup-kind 'wrapper-command)
      "Check `pichat-rpc-command'; wrappers need an explicit `pichat-diagnostics-interactive-command'."
    "Check `pichat-pi-executable', or run `pichat-diagnostics-open-interactive-pi' for /login and /model setup."))

(cl-defun pichat-chat-diagnostics-summary
    (&key origin category message exit-status setup-kind)
  "Return a bounded normal-chat summary for a diagnostic record."
  (let* ((setup-kind (or setup-kind (pichat-chat-diagnostics-setup-kind)))
         (text
          (pcase origin
            ('process-start
             (pcase category
               ('connection-failed
                "PiChat could not connect to the selected SSH target. Check the TRAMP/SSH connection and target configuration.")
               ('executable-not-found
                (format "Pi RPC executable was not found. %s"
                        (pichat-chat-diagnostics--setup-hint setup-kind)))
               ('permission-denied
                (format "Pi RPC command could not be executed. %s"
                        (pichat-chat-diagnostics--setup-hint setup-kind)))
               (_ (format "Pi RPC process could not be started. %s"
                          (pichat-chat-diagnostics--setup-hint setup-kind)))))
            ('process-exit
             (pcase category
               ('executable-not-found
                "The selected runtime could not find the Pi executable. Check its target executable and remote PATH policy.")
               ('missing-credential
                "Pi exited because provider credentials are unavailable. Run `pichat-diagnostics-open-interactive-pi' and use /login.")
               ('provider-not-configured
                "Pi exited without a configured model. Run `pichat-diagnostics-open-interactive-pi' and use /model.")
               (_ (format "Pi RPC process exited unexpectedly%s. See `pichat-show-transport-diagnostics'."
                          (if (numberp exit-status)
                              (format " (status %d)" exit-status)
                            "")))))
            ('rpc-response
             (pcase category
               ('missing-credential
                "Pi rejected an RPC command because provider credentials are unavailable. Run `pichat-diagnostics-open-interactive-pi' and use /login.")
               ('provider-not-configured
                "Pi rejected an RPC command because no model is configured. Run `pichat-diagnostics-open-interactive-pi' and use /model.")
               (_
                (format "Pi rejected an RPC command: %s"
                        (if (string-empty-p (or message ""))
                            "unknown Pi error"
                          message)))))
            ('rpc-timeout "A Pi RPC command timed out.")
            ('rpc-parse "PiChat received malformed RPC output. See `pichat-show-transport-diagnostics'.")
            (_ (if (string-empty-p (or message ""))
                   "Unknown PiChat error"
                 message)))))
    (pichat-chat-diagnostics-safe-summary-text text)))

(defun pichat-chat-diagnostics--bounded-raw (text limit)
  "Return raw TEXT bounded to LIMIT characters."
  (when (stringp text)
    (if (> (length text) limit)
        (concat (substring text 0 limit) "\n[truncated by PiChat]")
      text)))

(cl-defun pichat-chat-diagnostics-record
    (session &key origin message condition program stderr exit-status response
             category command)
  "Create and retain one bounded diagnostic record for SESSION."
  (let* ((setup-kind (pichat-chat-diagnostics-setup-kind session))
         (classification
          (or category
              (pichat-chat-diagnostics-classify
               origin (or stderr message) condition program)))
         (record
          (list :origin origin
                :category classification
                :summary
                (pichat-chat-diagnostics-summary
                 :origin origin :category classification :message message
                 :exit-status exit-status :setup-kind setup-kind)
                :message message
                :condition condition
                :program program
                :stderr (pichat-chat-diagnostics--bounded-raw
                         stderr pichat-diagnostics-stderr-limit)
                :exit-status exit-status
                ;; RPC dispatch may annotate its RESPONSE after recording it.
                ;; Keep the explicit raw value independent and acyclic.
                :response (and response (copy-tree response))
                :command command
                :setup-kind setup-kind
                :time (current-time))))
    (when session
      (setf (pichat-session-diagnostics session)
            (cons record
                  (seq-take (pichat-session-diagnostics session)
                            (max 0 (1- pichat-diagnostics-record-limit))))))
    record))

(defun pichat-chat-diagnostics-latest (session)
  "Return SESSION's most recent diagnostic record."
  (car (and session (pichat-session-diagnostics session))))

(defun pichat-chat-diagnostics-latest-summary (session)
  "Return SESSION's most recent safe normal-UI diagnostic summary."
  (plist-get (pichat-chat-diagnostics-latest session) :summary))

(defun pichat-chat-diagnostics-interactive-argv (&optional session)
  "Return safe interactive Pi argv for optional SESSION."
  (cond
   ((and session
         (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh))
    (list (pichat-transport-pi-executable
           (pichat-session-transport session))))
   (pichat-diagnostics-interactive-command
    (copy-sequence pichat-diagnostics-interactive-command))
   ((and (boundp 'pichat-rpc-command) pichat-rpc-command) nil)
   ((and (boundp 'pichat-pi-executable)
         (stringp pichat-pi-executable)
         (not (string-empty-p pichat-pi-executable)))
    (list pichat-pi-executable))))

(defun pichat-chat-diagnostics--agent-directory ()
  "Return Pi's configured agent directory."
  (file-name-as-directory
   (expand-file-name
    (or (pichat-pi-getenv "PI_CODING_AGENT_DIR") "~/.pi/agent"))))

;;;###autoload
(defun pichat-diagnostics-open-settings (&optional session)
  "Visit the owning runtime's settings.json without displaying auth.json."
  (interactive)
  (let ((session (pichat-session-current session)))
    (if (and session
             (eq (pichat-transport-kind
                  (pichat-session-transport session)) 'ssh))
        (let* ((transport (pichat-session-transport session))
               (runtime-path
                (expand-file-name ".pi/agent/settings.json"
                                  (pichat-transport-runtime-home transport))))
          (find-file (pichat-transport-runtime-file-name
                      transport runtime-path)))
      (find-file (expand-file-name
                  "settings.json"
                  (pichat-chat-diagnostics--agent-directory))))))

;;;###autoload
(defun pichat-diagnostics-customize-transport ()
  "Customize PiChat's executable, wrapper, and interactive setup commands."
  (interactive)
  (customize-group 'pichat))

;;;###autoload
(defun pichat-diagnostics-open-interactive-pi (&optional session)
  "Launch interactive Pi in a terminal for /login, /model, and /settings.
Use SESSION's working directory when available.  Arbitrary RPC wrappers are
never rewritten; configure `pichat-diagnostics-interactive-command' for them."
  (interactive)
  (let* ((session (pichat-session-current session))
         (argv (pichat-chat-diagnostics-interactive-argv session))
         (transport (and session (pichat-session-transport session))))
    (unless argv
      (user-error
       "Set pichat-diagnostics-interactive-command for this wrapper/container setup"))
    (let* ((default-directory
            (file-name-as-directory
             (expand-file-name
              (or (and session
                       (if (eq (pichat-transport-kind transport) 'ssh)
                           (pichat-transport-runtime-file-name
                            transport (pichat-session-runtime-cwd session))
                         (pichat-session-emacs-cwd session)))
                  default-directory))))
           (tramp-remote-path
            (if (and transport
                     (eq (pichat-transport-kind transport) 'ssh)
                     (pichat-transport-remote-path transport))
                (pichat-transport-remote-path transport)
              tramp-remote-path))
           (name "PiChat Pi Setup")
           (buffer (get-buffer-create (format "*%s*" name))))
      (require 'term)
      (unless (process-live-p (get-buffer-process buffer))
        (with-current-buffer buffer
          (let ((inhibit-read-only t)) (erase-buffer)))
        (let ((process-environment (pichat-pi-process-environment)))
          (apply #'make-term name (car argv) nil (cdr argv)))
        (with-current-buffer buffer
          (term-mode)
          (term-char-mode)))
      (pop-to-buffer buffer))))

;;;###autoload
(defun pichat-diagnostics-probe-pi (&optional session)
  "Run `pi --version' through SESSION's transport and report availability."
  (interactive)
  (let* ((session (pichat-session-current session))
         (transport (if session (pichat-session-transport session)
                      pichat-transport-local))
         (runtime-cwd (if session (pichat-session-runtime-cwd session)
                        default-directory))
         (output (generate-new-buffer " *pichat-pi-probe*"))
         (command (list (or (pichat-transport-pi-executable transport)
                            pichat-pi-executable)
                        "--version")))
    (let ((process-environment (pichat-pi-process-environment)))
      (pichat-transport-make-process
       transport runtime-cwd
       :name "pichat-pi-probe" :buffer output :stderr output :command command
       :sentinel
       (lambda (process _event)
         (when (memq (process-status process) '(exit signal))
           (let ((status (process-exit-status process))
                 (text (with-current-buffer output
                         (string-trim
                          (buffer-substring-no-properties
                           (point-min) (point-max))))))
             (kill-buffer output)
             (if (zerop status)
                 (message "Pi available on %s: %s"
                          (pichat-transport-label transport) text)
               (message "Pi probe failed on %s (status %d): %s"
                        (pichat-transport-label transport) status text)))))))))

(defun pichat-chat-diagnostics--print-value (value)
  "Return an explicitly inspectable bounded representation of VALUE."
  (pichat-chat-diagnostics--bounded-raw
   (condition-case err
       (pp-to-string value)
     (error (format "<unprintable: %s>" (error-message-string err))))
   pichat-diagnostics-view-value-limit))

;;;###autoload
(defun pichat-show-transport-diagnostics (&optional session)
  "Show bounded raw transport diagnostics and recent RPC events for SESSION.
Unlike the ordinary chat status, this explicit inspection view may contain
paths, prompts, command arguments, provider output, and credentials."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session (user-error "No PiChat session"))
    (let ((buffer (get-buffer-create "*PiChat Transport Diagnostics*"))
          (records (reverse (copy-sequence
                             (pichat-session-diagnostics session))))
          (events (reverse
                   (seq-take (pichat-session-event-log session)
                             pichat-diagnostics-view-event-limit))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "PiChat transport diagnostics\n\n")
          (insert "WARNING: this explicit view may contain secrets, paths, and prompt content.\n\n")
          (let ((transport (pichat-session-transport session)))
            (insert (format "Target: %s\nTransport: %s\nEmacs CWD: %s\nRuntime CWD: %s\nPi executable: %s\n"
                            (pichat-transport-label transport)
                            (pichat-transport-kind transport)
                            (or (pichat-session-emacs-cwd session) "—")
                            (or (pichat-session-runtime-cwd session) "—")
                            (or (pichat-transport-pi-executable transport)
                                pichat-pi-executable))))
          (insert "Configured command:\n"
                  (pichat-chat-diagnostics--print-value
                   (pichat-session-rpc-command session)) "\n")
          (insert (format "State: %s\n\n" (pichat-session-state session)))
          (insert (format "Diagnostic records (%d, oldest first):\n" (length records)))
          (if records
              (dolist (record records)
                (insert "\n" (pichat-chat-diagnostics--print-value record)))
            (insert "  none\n"))
          (insert (format "\nRecent raw RPC events (%d, oldest first):\n"
                          (length events)))
          (if events
              (dolist (event events)
                (insert "\n" (pichat-chat-diagnostics--print-value event)))
            (insert "  none\n")))
        (pichat-view-mode))
      (pichat-view-display buffer nil 'bury)
      buffer)))

(defalias 'pichat-chat-show-transport-diagnostics
  #'pichat-show-transport-diagnostics)
(defalias 'pichat-chat-open-interactive-pi
  #'pichat-diagnostics-open-interactive-pi)

(provide 'pichat-chat-diagnostics)
;;; pichat-chat-diagnostics.el ends here
