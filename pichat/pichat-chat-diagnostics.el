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
(require 'pichat-backend)
(require 'pichat-transport)
(require 'pichat-pi-environment)
(require 'pichat-path)
(require 'pichat-view)
(require 'pichat-diagnostic)
(require 'pichat-diagnostics-report)

(defvar pichat-diagnostics-section-functions nil
  "Functions taking a runtime and returning cached diagnostic sections.
Each section is (TITLE . RECORDS).  Providers must reject stale sources and
must not fetch data or mutate their collectors.")

(defgroup pichat-diagnostics nil
  "Transport diagnostics and setup guidance for PiChat."
  :group 'pichat)

(defcustom pichat-diagnostics-record-limit 20
  "Maximum number of diagnostic records retained per session.
A fixed safety ceiling of 20 records also applies, independently of this option."
  :type 'positive-integer
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-notice-timeout 5
  "Seconds before a new diagnostic notice disappears from chat.
Nil disables automatic dismissal.  This setting applies to newly recorded
failures; expiration never deletes retained diagnostic history."
  :type '(choice (const :tag "Manual dismissal only" nil)
                 (number :tag "Seconds"))
  :group 'pichat-diagnostics)

(defcustom pichat-diagnostics-stderr-limit 100000
  "Maximum stderr characters retained in one diagnostic record.
The independent raw string-byte and shared snapshot budgets also apply."
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

(declare-function pichat-session-by-runtime-id "pichat" (runtime-id))

(defvar-local pichat-diagnostics--owner nil
  "Runtime whose snapshot is displayed in this inspector.")

(defvar-local pichat-diagnostics--setup-context nil
  "Launch context of this setup terminal; never inferred from its name.")

(defvar pichat-diagnostics-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'pichat-diagnostics-refresh)
    (define-key map (kbd "TAB") #'pichat-diagnostics-toggle-section)
    (define-key map (kbd "<tab>") #'pichat-diagnostics-toggle-section)
    (define-key map (kbd "RET") #'pichat-diagnostics-toggle-section)
    map)
  "Native bindings for the cached runtime troubleshooting report.")

;; `defvar' keeps maps on source reload.  Remove the former navigation keys
;; without replacing the map (personal menus may already extend it).
(define-key pichat-diagnostics-mode-map (kbd "r") nil)
(define-key pichat-diagnostics-mode-map (kbd "s") nil)

;; A source reload must not leave a second inspector or callable legacy entry
;; points behind.  Raw buffers are disposable snapshots, not collector storage.
(dolist (buffer (buffer-list))
  (when (eq (buffer-local-value 'major-mode buffer)
            'pichat-transport-diagnostics-mode)
    (kill-buffer buffer)))
(dolist (command '(pichat-show-transport-diagnostics
                   pichat-diagnostics-show-raw pichat-diagnostics-setup
                   pichat-transport-diagnostics-mode))
  (fmakunbound command))
(makunbound 'pichat-transport-diagnostics-mode-map)
(put 'pichat-transport-diagnostics-mode 'derived-mode-parent nil)

(define-derived-mode pichat-diagnostics-mode pichat-view-mode "PiChat-Diagnostics"
  "Read-only cached diagnostics owned by one PiChat runtime.
Evidence may contain credentials, paths and prompts; review before sharing.
TAB, graphical <tab>, RET or a click on an evidence heading toggles it.
Native g refreshes from retained state only; q returns to the origin.
With `pichat-evil-setup', Normal-state TAB, RET and za toggle evidence,
gr refreshes and q returns; j/k, w, / and n/N keep Vim motions/search.
There is no setup key or chooser.  No health probes run.

Related standalone commands (explicit side effects, never run by this report):
`pichat-diagnostics-open-settings' visits editable settings;
`pichat-diagnostics-customize' opens Emacs customization;
`pichat-diagnostics-open-interactive-pi' starts a separate setup terminal;
`pichat-diagnostics-probe-pi' starts a version probe, reporting only in
 the echo area and *Messages*, not this report.
\n\\{pichat-diagnostics-mode-map}")

(defun pichat-chat-diagnostics--session (&optional session)
  "Resolve SESSION, honoring inspector ownership before ordinary context.
An inspector's owner must still be registered.  Never substitute another
runtime for a forgotten owner; leave the existing snapshot readable."
  (or session
      (if (derived-mode-p 'pichat-diagnostics-mode)
          (let ((owner pichat-diagnostics--owner))
            (unless (and owner
                         (fboundp 'pichat-session-by-runtime-id)
                         (eq owner (pichat-session-by-runtime-id
                                    (pichat-session-runtime-id owner))))
              (user-error "Inspected PiChat runtime is no longer registered; snapshot retained"))
            owner)
        (pichat-session-current))))

(defun pichat-chat-diagnostics--identity-label (value)
  "Return a bounded, path-free identity label for VALUE."
  (let ((text (pichat-chat-diagnostics--text value)))
    (if (string-match-p "\\`[[:alnum:]_-]+\\'" text)
        (substring-no-properties
         (pichat-chat-diagnostics-safe-summary-text text))
      "[custom]")))

(defun pichat-chat-diagnostics--text (value)
  "Return VALUE as plain text without signaling."
  (let ((value (pichat-diagnostic-copy-raw value)))
    (cond
     ((stringp value) value)
     ((null value) "")
     (t (condition-case nil (format "%s" value) (error ""))))))

(defun pichat-chat-diagnostics--condition-symbol (condition)
  "Return the condition symbol from CONDITION, if available."
  (and (consp condition) (symbolp (car condition)) (car condition)))

(defun pichat-chat-diagnostics-classify (origin text &optional condition program)
  "Conservatively classify diagnostic TEXT from ORIGIN.
CONDITION and PROGRAM refine local process-start failures.  Return nil rather
than guessing when a message merely mentions credentials, permissions, status
codes, or missing files in unrelated output."
  (let* ((program (pichat-chat-diagnostics--text program))
         (message (string-trim (pichat-chat-diagnostics--text text)))
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
               (concat "\\(?:tramp:\\|\\b"
                       (regexp-opt '("connection refused" "connection failed"
                                     "could not resolve hostname"
                                     "connection timed out"))
                       "\\b\\)")
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
  (let* ((message (pichat-chat-diagnostics--text message))
         (setup-kind (or setup-kind (pichat-chat-diagnostics-setup-kind)))
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
               (_ (format "Pi RPC process exited unexpectedly%s. See `pichat-show-diagnostics'."
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
            ('rpc-parse "PiChat received malformed RPC output. See `pichat-show-diagnostics'.")
            ('rpc-protocol "PiChat received an invalid RPC record. See `pichat-show-diagnostics'.")
            ('rpc-dispatch "PiChat could not process an RPC record. See `pichat-show-diagnostics'.")
            ('event-handler "A PiChat event consumer failed. See `pichat-show-diagnostics'.")
            (_ (if (string-empty-p (or message ""))
                   "Unknown PiChat error"
                 message)))))
    (pichat-chat-diagnostics-safe-summary-text text)))

(defun pichat-chat-diagnostics--bounded-raw (text limit)
  "Return raw TEXT bounded to LIMIT characters."
  (if (and (stringp text) (> (length text) limit))
      (concat (substring-no-properties text 0 limit) "\n[truncated by PiChat]")
    text))

(defun pichat-chat-diagnostics-context (session)
  "Return SESSION's process and source lifetime identity."
  (when session
    (list (pichat-session-process-generation session)
          (pichat-session-diagnostic-source-generation session)
          (pichat-session-id session))))

(cl-defun pichat-chat-diagnostics-record
    (session &key origin message condition program stderr exit-status response
             category command (context (pichat-chat-diagnostics-context session)))
  "Create and retain one bounded diagnostic record for SESSION."
  (let* ((setup-kind (pichat-chat-diagnostics-setup-kind session))
         ;; Classification and safe presentation use their own bounded prefix,
         ;; independent of raw capture exhaustion and user stderr settings.
         (classification
          (or category
              (pichat-chat-diagnostics-classify
               origin (or stderr message) condition program)))
         (summary (pichat-chat-diagnostics-summary
                   :origin origin :category classification :message message
                   :exit-status exit-status :setup-kind setup-kind))
         (budget (pichat-diagnostic-raw-budget))
         ;; Capture small control metadata first.  Large evidence must not
         ;; consume the command used to correlate compaction notice recovery.
         (command (pichat-diagnostic-copy-raw command budget))
         (exit-status (pichat-diagnostic-copy-raw exit-status budget))
         (message (pichat-diagnostic-copy-raw message budget))
         (condition (pichat-diagnostic-copy-raw condition budget))
         (program (pichat-diagnostic-copy-raw program budget))
         (stderr (pichat-chat-diagnostics--bounded-raw
                  (pichat-diagnostic-copy-raw stderr budget)
                  pichat-diagnostics-stderr-limit))
         (response (pichat-diagnostic-copy-raw response budget))
         (record
          (list :domain 'transport :severity 'error :origin origin
                :notice-context context :notice-state nil
                :notice-expires-at
                (when pichat-diagnostics-notice-timeout
                  (+ (float-time) (max 0 pichat-diagnostics-notice-timeout)))
                :category classification
                :summary summary
                :message message
                :condition condition
                :program program
                :stderr stderr
                :exit-status exit-status
                ;; Independent bounded evidence, never a dispatchable response.
                :response response
                :command command
                :setup-kind setup-kind
                :time (current-time))))
    (when session
      (setf (pichat-session-diagnostics session)
            (cons record
                  (seq-take (pichat-session-diagnostics session)
                            (max 0 (1- (min pichat-diagnostics-record-limit
                                            pichat-diagnostic-record-slots)))))))
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
   ((and session
         (pichat-transport-pi-executable (pichat-session-transport session)))
    (list (pichat-transport-pi-executable (pichat-session-transport session))))
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
  (let ((session (pichat-chat-diagnostics--session session)))
    (when session
      (pichat-backend-require-capability
       session 'diagnostics "Pi settings"))
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
(defun pichat-diagnostics-customize ()
  "Customize the PiChat group, including transport and setup settings."
  (interactive)
  (customize-group 'pichat))

;;;###autoload
(defalias 'pichat-diagnostics-customize-transport #'pichat-diagnostics-customize)

;;;###autoload
(defun pichat-diagnostics-open-interactive-pi (&optional session)
  "Launch interactive Pi in a terminal for /login, /model, and /settings.
Use SESSION's target and working directory when available.  Reuse a live
setup terminal only when its transport, directory, argv, environment and
executable search context match; otherwise open a separate terminal without
stopping an existing process.  Arbitrary RPC wrappers are never rewritten;
configure `pichat-diagnostics-interactive-command' for them."
  (interactive)
  (let* ((session (pichat-chat-diagnostics--session session))
         (_capability
          (when session
            (pichat-backend-require-capability
             session 'diagnostics "Interactive Pi setup")))
         (argv (pichat-chat-diagnostics-interactive-argv session))
         (transport (and session (pichat-session-transport session))))
    (unless (and (consp argv)
                 (cl-every (lambda (arg)
                             (and (stringp arg) (not (string-empty-p arg))))
                           argv))
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
           (process-environment (pichat-pi-process-environment))
           ;; Include effective environment and executable search context: a
           ;; matching target/cwd/argv with different credentials or PATH is
           ;; not the same setup launch.  Copy mutable configuration values.
           (context (copy-tree
                     (list :transport (or transport pichat-transport-local)
                           :directory default-directory :argv argv
                           :environment process-environment :exec-path exec-path
                           :remote-path tramp-remote-path)
                     t))
           (buffer
            (seq-find
             (lambda (candidate)
               (and (process-live-p (get-buffer-process candidate))
                    (equal context
                           (buffer-local-value
                            'pichat-diagnostics--setup-context candidate))))
             (buffer-list))))
      (unless buffer
        ;; A mismatched or untracked terminal is never stopped or overwritten.
        ;; `make-term' accepts a name without the surrounding stars.
        (let* ((base (format "PiChat Pi Setup %s"
                             (if session (pichat-session-runtime-id session)
                               "local")))
               (name base)
               (index 1))
          (while (get-buffer (format "*%s*" name))
            (setq index (1+ index)
                  name (format "%s <%d>" base index)))
          (setq buffer (apply #'make-term name (car argv) nil (cdr argv)))
          (with-current-buffer buffer
            (term-char-mode)
            (setq-local pichat-diagnostics--setup-context context))))
      (pop-to-buffer buffer))))

;;;###autoload
(defun pichat-diagnostics-probe-pi (&optional session)
  "Check Pi executable/version through SESSION's transport with --version.
Starts a process, not an RPC health check: this does not validate credentials,
model configuration, RPC startup, or `pichat-rpc-command' wrappers.  Results
are reported in the echo area and *Messages*, not the cached inspector."
  (interactive)
  (let* ((session (pichat-chat-diagnostics--session session))
         (_capability
          (when session
            (pichat-backend-require-capability
             session 'diagnostics "Pi executable/version check")))
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
                 (message "Pi executable/version on %s (not RPC/auth/model health): %s"
                          (pichat-transport-label transport) text)
               (message "Pi executable/version check failed on %s (status %d): %s"
                        (pichat-transport-label transport) status text)))))))))

(defun pichat-chat-diagnostics--print-value (value)
  "Return an explicitly inspectable bounded representation of VALUE."
  (pichat-chat-diagnostics--bounded-raw
   (condition-case err
       (pp-to-string (pichat-diagnostic-copy-raw value))
     (error (format "<unprintable: %s>" (error-message-string err))))
   (max 1 (min 20000 pichat-diagnostics-view-value-limit))))

(defun pichat-diagnostics-refresh ()
  "Rebuild the current runtime report from its owner's cached records.
Never fetch history, issue RPC, launch processes or check files."
  (interactive)
  (unless (derived-mode-p 'pichat-diagnostics-mode)
    (user-error "Not a PiChat diagnostics inspector"))
  (pichat-show-diagnostics))

(defun pichat-chat-diagnostics--safe-record-line (record)
  "Return RECORD's safe summary with only available optional metadata.
Legacy strings have no metadata.  Missing or invalid times are omitted,
never replaced by the snapshot time.  Raw record fields are not printed."
  (let* ((metadata (and (listp record) record))
         (labels (delq nil
                       (mapcar (lambda (key)
                                 (when-let* ((value (plist-get metadata key)))
                                   (pichat-chat-diagnostics--identity-label value)))
                               '(:severity :category))))
         (time (when-let* ((value (plist-get metadata :time)))
                 (condition-case nil
                     (format-time-string "%Y-%m-%dT%H:%M:%SZ" value t)
                   (error nil))))
         (prefix (string-join
                  (delq nil (list (and labels (string-join labels "/")) time))
                  "; ")))
    (concat (unless (string-empty-p prefix) (format "[%s] " prefix))
            (pichat-chat-diagnostics-safe-summary-text
             (pichat-diagnostic-summary record)))))

;;;###autoload
(defun pichat-show-diagnostics (&optional session)
  "Show the cached runtime troubleshooting report for SESSION.
Overview and sensitive expandable evidence use retained state only, without
RPC, process launch or filesystem checks.  Missing caches are unavailable,
not healthy.  Collector lifetimes and retention remain unchanged."
  (interactive)
  (let* ((session (pichat-chat-diagnostics--session session))
         (_owner (unless session (user-error "No PiChat session")))
         (buffer (get-buffer-create
                  (format "*PiChat Diagnostics %s*"
                          (pichat-session-runtime-id session)))))
    (let ((sections
           (cons (cons "Runtime / transport"
                       (reverse (copy-sequence
                                 (pichat-session-diagnostics session))))
                 (apply #'append
                        (mapcar (lambda (provider) (funcall provider session))
                                pichat-diagnostics-section-functions)))))
      (with-current-buffer buffer
        (unless (eq major-mode 'pichat-diagnostics-mode)
          (pichat-diagnostics-mode))
        (setq-local pichat-diagnostics--owner session)
        (pichat-diagnostics-report-install session sections))
      (unless (eq buffer (current-buffer))
        (pichat-view-display buffer nil 'bury))
      buffer)))

(provide 'pichat-chat-diagnostics)
;;; pichat-chat-diagnostics.el ends here
