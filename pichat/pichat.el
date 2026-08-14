;;; pichat.el --- Emacs frontend for the Pi coding agent -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat is an Emacs frontend for Pi's JSONL RPC mode.  Pi owns the agent
;; runtime and session store; Emacs owns UI/editor integration.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'transient)
(require 'pichat-transport)
(require 'pichat-session)
(require 'pichat-events)
(require 'pichat-path)
(require 'pichat-rpc)
(require 'pichat-pi)
(require 'pichat-chat)
(require 'pichat-reference)
(require 'pichat-sessions)
(require 'pichat-archive)
(require 'pichat-consult)
(require 'pichat-commands)
(require 'pichat-approval)
(require 'pichat-permissions)
(require 'pichat-tool-bridge)
(require 'pichat-bridge-transport)
(require 'pichat-vui)

(defconst pichat-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing PiChat Lisp files.")

(defvar pichat-current-session nil
  "Current PiChat session.")

(defvar pichat--sessions-by-scope (make-hash-table :test #'equal)
  "Preferred live PiChat sessions keyed by project/global scope.")

(defvar pichat--sessions-by-id (make-hash-table :test #'equal)
  "All retained PiChat runtime sessions keyed by immutable runtime ID.")

(defvar pichat--session-order nil
  "Immutable runtime IDs in registry insertion order.")

(defvar pichat-session-registry-changed-hook nil
  "Hook run after the runtime session registry changes.
Each function receives a change symbol and the affected session.  Change is one
of `added', `removed', `default-changed', or `updated'.")

(defvar pichat--manual-session-counter 0
  "Counter used to name explicitly started PiChat sessions.")

(defvar pichat--model-list-directory nil)
(defvar pichat--model-list-target nil)

(defcustom pichat-global-directory "~"
  "Directory used for the global PiChat session outside projects."
  :type 'directory
  :group 'pichat)

(defcustom pichat-auto-use-repo-bridge nil
  "When non-nil, use `bridge/pichat-bridge.ts' from `pichat-directory' if present.
The bridge is disabled by default until implemented/tested."
  :type 'boolean
  :group 'pichat)

(defun pichat-default-bridge-file ()
  "Return the development bridge file path when it exists."
  (let ((file (expand-file-name "bridge/pichat-bridge.ts" pichat-directory)))
    (and (file-exists-p file) file)))

(defun pichat--maybe-enable-default-bridge ()
  "Set `pichat-bridge-extension-file' from repo bridge when requested."
  (when (and pichat-auto-use-repo-bridge
             (null pichat-bridge-extension-file))
    (setq pichat-bridge-extension-file (pichat-default-bridge-file))))

(defun pichat--directory-basename (directory)
  "Return a display basename for DIRECTORY."
  (file-name-nondirectory (directory-file-name (file-name-as-directory directory))))

(defun pichat--project-root (&optional directory)
  "Return project root for DIRECTORY, or nil outside projects."
  (let ((default-directory (file-name-as-directory (or directory default-directory))))
    (when-let ((project (project-current nil)))
      (file-name-as-directory (expand-file-name (project-root project))))))

(defun pichat--scope-for-directory (&optional directory force-global target-id)
  "Return transport-qualified (KEY CWD LABEL) for DIRECTORY.
When FORCE-GLOBAL is non-nil, use the selected target's global scope."
  (let* ((directory (or directory default-directory))
         (transport (if (pichat-transport-p target-id)
                        target-id
                      (pichat-transport-resolve directory target-id)))
         (transport-id (format "%s" (pichat-transport-id transport))))
    (if (not force-global)
        (if-let ((root (pichat--project-root directory)))
            (let ((label (format "%s@%s" (pichat--directory-basename root)
                                 (substring (md5 root) 0 8))))
              (list (format "project|%s|%s" transport-id root) root label))
          (pichat--scope-for-directory directory t target-id))
      (let* ((local-p (eq (pichat-transport-kind transport) 'local))
             (context (pichat-transport-path-context transport pichat-path-mappings))
             (runtime-home (if local-p
                               (expand-file-name pichat-global-directory)
                             (pichat-transport-runtime-home transport)))
             (resolved (pichat-path-resolve-from-runtime runtime-home context))
             (cwd (or (plist-get resolved :path)
                      (and local-p runtime-home)
                      (pichat-transport-runtime-file-name transport runtime-home))))
        (list (format "global|%s" transport-id)
              (file-name-as-directory cwd)
              (if (eq (pichat-transport-id transport) 'local)
                  "global"
                (format "global@%s" (pichat-transport-label transport))))))))

(defun pichat--notify-registry-change (change session)
  "Notify registry observers that CHANGE affected SESSION."
  (run-hook-with-args 'pichat-session-registry-changed-hook change session))

(defun pichat-register-session (session &optional scope)
  "Retain runtime SESSION in the all-session registry.
SCOPE, when non-nil, is a (KEY CWD LABEL) value from
`pichat--scope-for-directory'.  A session's owner scope is assigned only once."
  (unless (pichat-session-p session)
    (error "Not a PiChat session: %S" session))
  (let* ((scope (or scope
                    (pichat--scope-for-directory
                     (or (pichat-session-emacs-cwd session) default-directory)
                     nil (pichat-session-transport session))))
         (key (nth 0 scope))
         (label (nth 2 scope))
         (runtime-id (pichat-session-runtime-id session))
         (existing (gethash runtime-id pichat--sessions-by-id))
         (new-p (not (eq existing session))))
    (when (and existing (not (eq existing session)))
      (error "Duplicate PiChat runtime identity: %s" runtime-id))
    (unless (pichat-session-owner-scope-key session)
      (setf (pichat-session-owner-scope-key session) key
            (pichat-session-owner-scope-label session) label
            (pichat-session-owner-directory session) (nth 1 scope)))
    (unless (pichat-session-scope-key session)
      (setf (pichat-session-scope-key session) key))
    (unless (pichat-session-scope-label session)
      (setf (pichat-session-scope-label session) label))
    (puthash runtime-id session pichat--sessions-by-id)
    (when new-p
      (setq pichat--session-order
            (append pichat--session-order (list runtime-id)))
      (pichat--notify-registry-change 'added session))
    session))

(defun pichat-note-session-updated (session)
  "Notify observers that retained SESSION's cached presentation changed."
  (when (and session
             (eq (gethash (pichat-session-runtime-id session)
                          pichat--sessions-by-id)
                 session))
    (pichat--notify-registry-change 'updated session)))

(defun pichat-session-list ()
  "Return every retained PiChat runtime session in creation order."
  (delq nil (mapcar (lambda (runtime-id)
                      (gethash runtime-id pichat--sessions-by-id))
                    pichat--session-order)))

(defun pichat-session-by-runtime-id (runtime-id)
  "Return the retained runtime session identified by RUNTIME-ID."
  (and runtime-id (gethash runtime-id pichat--sessions-by-id)))

(defun pichat-session-default-p (session)
  "Return non-nil when SESSION is its owner scope's preferred session."
  (and session
       (let ((key (pichat-session-owner-scope-key session)))
         (and key (eq (gethash key pichat--sessions-by-scope) session)))))

(defun pichat-clear-default-session (session)
  "Remove SESSION from every preferred-scope slot without forgetting it."
  (let (keys changed)
    (maphash (lambda (key value)
               (when (eq value session) (push key keys)))
             pichat--sessions-by-scope)
    (dolist (key keys)
      (setq changed t)
      (remhash key pichat--sessions-by-scope))
    (when changed
      (pichat--notify-registry-change 'default-changed session))
    changed))

(defun pichat-set-default-session (session)
  "Make retained live SESSION preferred for its immutable owner scope."
  (unless (and session (pichat-session-alive-p session))
    (user-error "Only a live PiChat session can be made the scope default"))
  (pichat-register-session session)
  (let ((key (pichat-session-owner-scope-key session)))
    (unless key (user-error "PiChat session has no owner scope"))
    (puthash key session pichat--sessions-by-scope)
    (setf (pichat-session-scope-key session) key)
    (pichat--notify-registry-change 'default-changed session)
    session))

(defun pichat-forget-session (session)
  "Forget stopped or failed runtime SESSION without stopping other sessions."
  (when session
    (pichat-clear-default-session session)
    (let ((runtime-id (pichat-session-runtime-id session)))
      (when (eq (gethash runtime-id pichat--sessions-by-id) session)
        (remhash runtime-id pichat--sessions-by-id)
        (setq pichat--session-order
              (delete runtime-id pichat--session-order))
        (when (eq session pichat-current-session)
          (setq pichat-current-session nil))
        (pichat--notify-registry-change 'removed session)
        t))))

(defun pichat--unregister-session (session)
  "Compatibility wrapper that fully forgets runtime SESSION."
  (pichat-forget-session session))

(defun pichat-session-for-directory (&optional directory)
  "Return an existing live PiChat session for DIRECTORY's scope, if any.

This does not create a new session.  It is used by `pichat-session-current'
so commands run from ordinary project buffers prefer that project's live
session over the global `pichat-current-session'."
  (pcase-let ((`(,key ,_cwd ,_label) (pichat--scope-for-directory directory)))
    (let ((session (gethash key pichat--sessions-by-scope)))
      (when session
        (if (pichat-session-alive-p session)
            session
          (pichat-clear-default-session session)
          nil)))))

(defun pichat--preferred-session-for-exact-scope (scope &optional launch-options)
  "Return the live preferred runtime for exact SCOPE, creating it if needed."
  (pcase-let ((`(,key ,cwd ,label) scope))
    (let ((session (gethash key pichat--sessions-by-scope)))
      (unless (and session (pichat-session-alive-p session))
        (when session (pichat-clear-default-session session))
        (setq session (pichat-start-session cwd scope launch-options))
        (setf (pichat-session-scope-key session) key
              (pichat-session-scope-label session) label
              (pichat-session-owner-scope-key session) key
              (pichat-session-owner-scope-label session) label)
        (when (pichat-session-alive-p session)
          (pichat-set-default-session session)))
      (setq pichat-current-session session)
      session)))

(defun pichat--session-for-scope (&optional directory force-global)
  "Return a live preferred runtime for DIRECTORY's scope, creating one if needed."
  (pichat--preferred-session-for-exact-scope
   (pichat--scope-for-directory directory force-global)))

(defun pichat--exact-scope-p (scope)
  "Return non-nil when SCOPE is an exact immutable scope tuple."
  (and (listp scope)
       (= (length scope) 3)
       (stringp (nth 0 scope))
       (stringp (nth 1 scope))
       (stringp (nth 2 scope))))

(defun pichat--normalize-launch-profile (&optional profile)
  "Return validated high-level launch PROFILE with explicit defaults."
  (let* ((scope (or (plist-get profile :scope) 'current))
         (target (or (plist-get profile :target) 'inferred))
         (persistence (or (plist-get profile :persistence) 'persistent))
         (model (or (plist-get profile :model) 'default))
         (explicit-reuse-p (plist-member profile :reuse))
         (reuse (or (plist-get profile :reuse)
                    (if (or (eq persistence 'ephemeral)
                            (eq model 'prompt)
                            (stringp model))
                        'new
                      'preferred)))
         (display-function (or (plist-get profile :display-function)
                               #'pichat-chat-open)))
    (unless (or (memq scope '(current global))
                (pichat--exact-scope-p scope))
      (user-error "Invalid PiChat launch scope: %S" scope))
    (unless (or (eq target 'inferred) (eq target 'local)
                (pichat-transport--target-entry target))
      (user-error "Invalid PiChat target: %S" target))
    (unless (memq reuse '(preferred new))
      (user-error "Invalid PiChat runtime policy: %S" reuse))
    (unless (memq persistence '(persistent ephemeral))
      (user-error "Invalid PiChat persistence: %S" persistence))
    (unless (or (memq model '(default prompt))
                (and (stringp model) (not (string-blank-p model))))
      (user-error "Invalid PiChat model policy: %S" model))
    (unless (functionp display-function)
      (user-error "Invalid PiChat display function: %S" display-function))
    (when (and (eq reuse 'preferred)
               (or (eq persistence 'ephemeral)
                   (eq model 'prompt)
                   (stringp model)))
      (if explicit-reuse-p
          (user-error
           "Preferred PiChat runtimes require persistent/default-model launch")
        (setq reuse 'new)))
    (list :scope scope
          :target target
          :reuse reuse
          :persistence persistence
          :model model
          :display-function display-function)))

(defun pichat--resolve-launch-scope (scope &optional directory target)
  "Resolve launch SCOPE and TARGET using optional invocation DIRECTORY."
  (let ((target-id (unless (eq target 'inferred) target)))
    (pcase scope
      ('current (pichat--scope-for-directory
                 (or directory default-directory) nil target-id))
      ('global (pichat--scope-for-directory
                (or directory default-directory) t target-id))
      ((pred pichat--exact-scope-p) scope)
      (_ (user-error "Invalid PiChat launch scope: %S" scope)))))

(defun pichat--display-and-synchronize-session (session display-function)
  "Display and synchronize exact SESSION through DISPLAY-FUNCTION."
  (funcall display-function session)
  (unless (eq 'error (pichat-session-state session))
    (pichat-rpc-get-state session (lambda (_response _session) nil)))
  session)

(defun pichat--open-launch-profile (profile &optional directory)
  "Open normalized launch PROFILE relative to optional DIRECTORY.
Return the exact runtime synchronously when its model is already known.
Prompted-model profiles first select a model asynchronously and return nil."
  (let* ((profile (pichat--normalize-launch-profile profile))
         (model (plist-get profile :model)))
    (if (eq model 'prompt)
        (progn
          (pichat--select-model-before-launch profile directory)
          nil)
      (let* ((target (plist-get profile :target))
             (scope (pichat--resolve-launch-scope
                     (plist-get profile :scope) directory target))
             (reuse (plist-get profile :reuse))
             (persistence (plist-get profile :persistence))
             (display-function (plist-get profile :display-function))
             (launch-options
              (list :persistence persistence
                    :model (and (stringp model) model)
                    :target (unless (eq target 'inferred) target)))
             (previous-session pichat-current-session)
             (session
              (if (eq reuse 'preferred)
                  (pichat--preferred-session-for-exact-scope scope launch-options)
                (pichat-start-session (nth 1 scope) scope launch-options))))
        (if (stringp model)
            (progn
              ;; A selected runtime becomes current only after Pi confirms
              ;; startup; failure therefore preserves the caller's context.
              (setq pichat-current-session previous-session)
              (pichat--confirm-selected-model-launch
               session display-function))
          (setq pichat-current-session session)
          (pichat--display-and-synchronize-session session display-function))
        session))))

;;;###autoload
(defun pichat-start-session (&optional cwd scope launch-options)
  "Start a PiChat RPC session rooted at CWD and return it.
SCOPE, when non-nil, is the immutable (KEY CWD LABEL) owner scope.
LAUNCH-OPTIONS supports `:persistence' and an exact run-local `:model'."
  (interactive)
  (pichat--maybe-enable-default-bridge)
  (let* ((transport-override (plist-get launch-options :transport))
         (target (plist-get launch-options :target))
         (cwd (file-name-as-directory
               (expand-file-name (or cwd default-directory))))
         (transport (or transport-override
                        (pichat-transport-resolve cwd target)))
         (normalized-options
          (pichat-rpc-normalize-launch-options
           (plist-put (copy-sequence launch-options)
                      :structured-transport
                      (eq (pichat-transport-kind transport) 'ssh))))
         (context (pichat-transport-path-context transport pichat-path-mappings))
         (runtime-resolution (pichat-path-resolve-to-runtime cwd context))
         (runtime-cwd
          (or (plist-get runtime-resolution :path)
              (user-error "Project path is unavailable to target %s: %s"
                          (pichat-transport-label transport) cwd)))
         (scope (or scope
                    (pichat--scope-for-directory
                     cwd nil transport)))
         (session (pichat-session-make
                   :cwd cwd
                   :emacs-cwd cwd
                   :runtime-cwd (file-name-as-directory runtime-cwd)
                   :owner-directory (nth 1 scope)
                   :transport transport
                   :path-context context
                   :persistence (plist-get normalized-options :persistence)
                   :startup-model (plist-get normalized-options :model)
                   :scope-key (nth 0 scope)
                   :owner-scope-key (nth 0 scope)
                   :owner-scope-label (nth 2 scope))))
    (cl-incf pichat--manual-session-counter)
    (setf (pichat-session-scope-label session)
          (format "manual:%s#%d" (pichat--directory-basename cwd)
                  pichat--manual-session-counter))
    (pichat-register-session session scope)
    (pichat-rpc-start session)
    (setq pichat-current-session session)
    (when (called-interactively-p 'interactive)
      (if (pichat-session-alive-p session)
          (message "PiChat RPC started: %S"
                   (pichat-session-rpc-command session))
        (message "PiChat RPC startup failed: %s"
                 (or (pichat-chat-diagnostics-latest-summary session)
                     "see M-x pichat-show-transport-diagnostics"))))
    session))

;;;###autoload
(defun pichat-stop-session (&optional session)
  "Stop SESSION or the best current PiChat session."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session
      (user-error "No PiChat session"))
    (pichat-rpc-stop session)
    (pichat-clear-default-session session)
    (when (eq session pichat-current-session)
      (setq pichat-current-session nil))))

(defun pichat--parse-model-table (output)
  "Parse Pi's human-readable model table OUTPUT.
Return an alist of (PROVIDER . MODEL) strings.  Return nil when OUTPUT does
not contain the expected table header or any model rows."
  (let ((in-table nil)
        models)
    (dolist (line (split-string output "\n"))
      (cond
       ((not in-table)
        (when (string-match-p
               "\\`[[:space:]]*provider[[:space:]]\\{2,\\}model\\(?:[[:space:]]\\{2,\\}.*\\)?\\'"
               line)
          (setq in-table t)))
       ((string-match
         "\\`[[:space:]]*\\([^[:space:]]+\\)[[:space:]]\\{2,\\}\\([^[:space:]]+\\)"
         line)
        (push (cons (match-string 1 line) (match-string 2 line)) models))))
    (nreverse models)))

(defun pichat--model-table-choices (models)
  "Return completion choices for MODELS parsed from Pi's model table."
  (mapcar (lambda (model)
            (cons (format "%s/%s" (car model) (cdr model)) model))
          models))

(defconst pichat--thinking-level-names
  '("off" "minimal" "low" "medium" "high" "xhigh" "max")
  "Pi thinking-level suffixes recognized in model references.")

(defun pichat--normalize-launch-model-choice (choice models)
  "Normalize run-local model CHOICE against parsed available MODELS.
Listed choices are returned exactly.  An unlisted choice must use
provider/model syntax with a provider present in MODELS."
  (let* ((trimmed (and (stringp choice) (string-trim choice)))
         (choices (pichat--model-table-choices models)))
    (when (or (null trimmed) (string-empty-p trimmed))
      (user-error "A Pi model is required"))
    (if (assoc trimmed choices)
        trimmed
      (let ((slash (string-search "/" trimmed)))
        (unless (and slash (> slash 0) (< slash (1- (length trimmed))))
          (user-error "Enter an exact provider/model ID"))
        (let* ((provider-input (substring trimmed 0 slash))
               (model-id (substring trimmed (1+ slash)))
               (provider
                (cl-find-if
                 (lambda (candidate)
                   (string-equal-ignore-case provider-input candidate))
                 (delete-dups (mapcar #'car models)))))
          (when (or (string-match-p "[[:space:]]" provider-input)
                    (string-match-p "[[:space:]]" model-id))
            (user-error "Provider/model IDs cannot contain whitespace"))
          (unless provider
            (user-error "Provider is not available: %s" provider-input))
          (when (and (not (assoc (format "%s/%s" provider model-id) choices))
                     (cl-some
                      (lambda (level)
                        (string-suffix-p (concat ":" level) model-id))
                      pichat--thinking-level-names))
            (user-error
             "Unlisted model IDs cannot include a thinking-level suffix; use models.json"))
          (format "%s/%s" provider model-id))))))

(defun pichat--read-model-table-choice (prompt models &optional allow-unlisted)
  "Read PROMPT over parsed MODELS and return a provider/model string.
When ALLOW-UNLISTED is non-nil, accept and validate a manual model ID for a
provider represented in MODELS."
  (let* ((choices (pichat--model-table-choices models))
         (choice (completing-read prompt choices nil (not allow-unlisted))))
    (if allow-unlisted
        (pichat--normalize-launch-model-choice choice models)
      choice)))

(defun pichat--model-list-command (&optional search transport)
  "Return a Pi model-list command for optional SEARCH and TRANSPORT."
  (let* ((trimmed (and (stringp search) (string-trim search)))
         (pattern (and trimmed (not (string-empty-p trimmed)) trimmed))
         (remote-p (and transport
                        (eq (pichat-transport-kind transport) 'ssh)))
         (executable (or (and transport
                              (pichat-transport-pi-executable transport))
                         pichat-pi-executable)))
    (append (list executable)
            (when (and (not remote-p) pichat-bridge-extension-file)
              (list "-e" pichat-bridge-extension-file))
            (unless remote-p pichat-pi-extra-args)
            (list "--list-models")
            (and pattern (list pattern)))))

(defun pichat--list-models-async (search callback &optional directory target)
  "List Pi models through TARGET in DIRECTORY, then call CALLBACK."
  (let* ((directory (or directory pichat--model-list-directory))
         (target (or target pichat--model-list-target))
         (emacs-cwd (file-name-as-directory
                     (expand-file-name (or directory default-directory))))
         (transport (if (pichat-transport-p target)
                        target
                      (pichat-transport-resolve emacs-cwd target)))
         (context (pichat-transport-path-context transport pichat-path-mappings))
         (runtime-cwd (or (plist-get
                           (pichat-path-resolve-to-runtime emacs-cwd context)
                           :path)
                          (user-error "Directory is unavailable to target %s"
                                      (pichat-transport-label transport))))
         (stdout (generate-new-buffer " *PiChat model list*"))
         (stderr (generate-new-buffer " *PiChat model list errors*"))
         (command (pichat--model-list-command search transport)))
    (message "Fetching available Pi models...")
    (condition-case err
        (pichat-transport-make-process
         transport runtime-cwd
         :name "pichat-list-models"
         :buffer stdout
         :stderr stderr
         :command command
         :sentinel
         (lambda (process _event)
           (when (and (memq (process-status process) '(exit signal))
                      (not (process-get process 'pichat-model-list-finished)))
             (process-put process 'pichat-model-list-finished t)
             (let ((status (process-exit-status process)))
               (unwind-protect
                   (if (zerop status)
                       (let ((models
                              (with-current-buffer stdout
                                (pichat--parse-model-table
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))
                         (if models
                             (funcall callback models)
                           (message "Pi returned no matching available models")))
                     (if (with-current-buffer stderr
                           (string-blank-p
                            (buffer-substring-no-properties
                             (point-min) (point-max))))
                         (message "Listing Pi models failed (exit %d)" status)
                       (with-current-buffer stderr
                         (rename-buffer
                          (generate-new-buffer-name
                           "*PiChat Model List Errors*") t)
                         (goto-char (point-min))
                         (special-mode)
                         (message "Listing Pi models failed (exit %d); see %s"
                                  status (buffer-name)))))
                 (when (buffer-live-p stdout)
                   (kill-buffer stdout))
                 (when (and (buffer-live-p stderr)
                            (string-prefix-p " " (buffer-name stderr)))
                   (kill-buffer stderr)))))))
      (error
       (when (buffer-live-p stdout) (kill-buffer stdout))
       (when (buffer-live-p stderr) (kill-buffer stderr))
       (user-error "Cannot start Pi model listing: %s"
                   (error-message-string err))))))

(defun pichat--prompt-and-set-default-model (models)
  "Prompt over parsed MODELS and set `pichat-default-model'."
  (condition-case nil
      (let ((choice
             (pichat--read-model-table-choice "Default Pi model: " models)))
        (setq pichat-default-model choice)
        (customize-mark-as-set 'pichat-default-model)
        (message "PiChat default model set: %s" choice))
    (quit nil)))

;;;###autoload
(defun pichat-select-default-model (&optional search clear)
  "Select the Pi model used when starting future plain RPC processes.
Interactively, prompt for SEARCH and pass it to `pi --list-models'.  An empty
search lists all available models.  With a prefix argument, clear
`pichat-default-model' instead.  Non-interactively, CLEAR requests the same
operation.

Model selection is unavailable when `pichat-rpc-command' is non-nil because a
complete wrapper command may use a different Pi installation and also ignores
`pichat-default-model'.  Clearing remains available in that configuration."
  (interactive
   (if current-prefix-arg
       (list nil t)
     (list (read-string "Search Pi models (empty for all): ") nil)))
  (if clear
      (progn
        (setq pichat-default-model nil)
        (customize-mark-as-set 'pichat-default-model)
        (message "PiChat default model cleared"))
    (when pichat-rpc-command
      (user-error
       "Default model selection is unavailable with a complete RPC command"))
    (pichat--list-models-async
     search
     (lambda (models)
       (run-at-time 0 nil #'pichat--prompt-and-set-default-model models))
     default-directory)))

(defun pichat--model-choices (models)
  "Return structured completion choices for valid MODELS."
  (delq nil
        (mapcar
         (lambda (model)
           (let ((provider (plist-get model :provider))
                 (id (plist-get model :id)))
             (when (and (stringp provider) (not (string-blank-p provider))
                        (stringp id) (not (string-blank-p id)))
               (cons (format "%s/%s" provider id) model))))
         models)))

(defun pichat--read-model-choice (models)
  "Read and return a structured model choice from MODELS.
Return a cons of the selected display label and original model record.  A
minibuffer quit is deliberately allowed to propagate to the caller."
  (let ((choices (pichat--model-choices models)))
    (unless choices (user-error "Pi returned no available models"))
    (let* ((choice (completing-read "Model: " choices nil t))
           (model (cdr (assoc choice choices))))
      (cons choice model))))

(defun pichat--prompt-and-select-model (session models)
  "Prompt for one of MODELS and select it in SESSION.
A quit from the minibuffer prompt cancels the ordinary operation silently."
  (when (pichat-session-alive-p session)
    (condition-case nil
        (pcase-let* ((`(,choice . ,model) (pichat--read-model-choice models)))
          (when (pichat-session-alive-p session)
            (pichat-rpc-set-model
             session (plist-get model :provider) (plist-get model :id)
             (lambda (_response model-session)
               (pichat-rpc-get-state
                model-session
                (lambda (_state-response _state-session)
                  (force-mode-line-update)
                  (message "PiChat model set: %s" choice)))))))
      (quit nil))))

;;;###autoload
(defun pichat-select-model (&optional session)
  "Select a Pi model for SESSION or the best current PiChat session.
Pi 0.83 persists RPC model changes as its global default.  Use the model switch
in `pichat-launch' when the selection must apply only to a new runtime."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session (user-error "No PiChat session"))
    (pichat-rpc-get-available-models
     session
     (lambda (response response-session)
       (run-at-time
        0 nil #'pichat--prompt-and-select-model response-session
        (plist-get (plist-get response :data) :models))))))

(defun pichat--selected-model-session-current-p (session)
  "Return non-nil when selected-model SESSION is registered and live."
  (and (eq (pichat-session-by-runtime-id
            (pichat-session-runtime-id session))
           session)
       (pichat-session-alive-p session)))

(defun pichat--discard-selected-model-session (session)
  "Stop and forget exact selected-model SESSION without affecting peers."
  (when (eq (pichat-session-by-runtime-id
             (pichat-session-runtime-id session))
            session)
    (when (pichat-session-alive-p session)
      (ignore-errors (pichat-rpc-stop session)))
    (pichat-forget-session session)))

(defun pichat--selected-model-launch-error (session stage response)
  "Clean up selected-model SESSION and report STAGE failure from RESPONSE."
  (when (eq (pichat-session-by-runtime-id
             (pichat-session-runtime-id session))
            session)
    (pichat--discard-selected-model-session session)
    (message "PiChat selected-model launch failed during %s: %s"
             stage
             (truncate-string-to-width
              (format "%s" (or (plist-get response :error) "unknown error"))
              160 nil nil "…"))))

(defun pichat--selected-model-launch-call (session stage function)
  "Call FUNCTION and clean selected-model SESSION if synchronous STAGE fails."
  (condition-case error-data
      (funcall function)
    (error
     (pichat--selected-model-launch-error
      session stage (list :error (error-message-string error-data))))))

(defun pichat--prompt-and-open-selected-model (models profile directory)
  "Prompt over parsed MODELS, then open PROFILE relative to DIRECTORY."
  (condition-case error-data
      (let* ((model
              (pichat--read-model-table-choice
               "Model for this runtime (select or enter provider/model): "
               models t))
             (selected-profile
              (plist-put (copy-sequence profile) :model model)))
        (pichat--open-launch-profile selected-profile directory))
    (quit (message "PiChat launch cancelled"))
    (error
     (message "PiChat model prompt failed: %s"
              (error-message-string error-data)))))

(defun pichat--select-model-before-launch (profile directory)
  "Select an exact model before opening PROFILE relative to DIRECTORY."
  (let* ((target (plist-get profile :target))
         (transport
          (pichat-transport-resolve
           (or directory default-directory)
           (unless (eq target 'inferred) target))))
    (when (and pichat-rpc-command
               (eq (pichat-transport-kind transport) 'local))
      (user-error
       "Run-local PiChat models are not supported with a local `pichat-rpc-command'")))
  (pichat--maybe-enable-default-bridge)
  (let ((pichat--model-list-directory (or directory default-directory))
        (pichat--model-list-target
         (let ((target (plist-get profile :target)))
           (unless (eq target 'inferred) target))))
    (pichat--list-models-async
     nil
     (lambda (models)
       (run-at-time 0 nil #'pichat--prompt-and-open-selected-model
                    models profile directory)))))

(defun pichat--state-model-reference (response)
  "Return provider/model from a successful get-state RESPONSE, or nil."
  (let* ((model (plist-get (plist-get response :data) :model))
         (provider (and (listp model) (plist-get model :provider)))
         (id (and (listp model)
                  (or (plist-get model :id) (plist-get model :modelId)))))
    (when (and (stringp provider) (stringp id))
      (format "%s/%s" provider id))))

(defun pichat--confirm-selected-model-launch (session display-function)
  "Confirm SESSION's startup model before calling DISPLAY-FUNCTION."
  (pichat--selected-model-launch-call
   session "startup readiness"
   (lambda ()
     (pichat-rpc-get-state
      session
      (lambda (response ready-session)
        (when (and (eq ready-session session)
                   (pichat--selected-model-session-current-p session))
          (let ((expected (pichat-session-startup-model session))
                (actual (pichat--state-model-reference response)))
            (if (equal expected actual)
                (pichat--selected-model-launch-call
                 session "display"
                 (lambda ()
                   (setq pichat-current-session session)
                   (force-mode-line-update)
                   (funcall display-function session)))
              (pichat--selected-model-launch-error
               session "startup model verification"
               (list :error
                     (format "expected %s, got %s"
                             expected (or actual "unknown"))))))))
      (lambda (response ready-session)
        (when (eq ready-session session)
          (pichat--selected-model-launch-error
           session "startup readiness" response)))))))

;;;###autoload
(defun pichat-status (&optional session)
  "Display status for SESSION or the best current PiChat session."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session
      (user-error "No PiChat session"))
    (pichat-rpc-get-state
     session
     (lambda (response _session)
       (let ((data (plist-get response :data)))
         (message "PiChat: state=%S session=%s model=%s streaming=%s"
                  (pichat-session-state session)
                  (or (plist-get data :sessionName) (plist-get data :sessionId))
                  (or (plist-get (plist-get data :model) :id)
                      (plist-get (plist-get data :model) :modelId)
                      (plist-get data :model))
                  (plist-get data :isStreaming)))))))

;;;###autoload
(defun pichat-smoke-test ()
  "Start Pi RPC, request `get_state', print the response, and stop.
This is the first implementation check; it does not send an LLM prompt."
  (interactive)
  (let ((session (pichat-start-session default-directory)))
    (pichat-on
     'session-ended
     (lambda (_session _event plist)
       (message "PiChat smoke test session ended: %S" plist))
     session)
    (pichat-on
     'error
     (lambda (_session _event plist)
       (message "PiChat smoke test error: %S" plist))
     session)
    ;; Give process startup a moment but do not assume Pi emits a ready event.
    (run-at-time
     0.2 nil
     (lambda ()
       (if (pichat-session-alive-p session)
           (pichat-rpc-get-state
            session
            (lambda (response _session)
              (message "PiChat smoke test OK: %S" (plist-get response :data))
              (pichat-rpc-stop session)))
         (message "PiChat smoke test failed: process is not alive"))))
    session))

(defun pichat--make-launch-context (&optional display-function)
  "Capture launch origin and optional DISPLAY-FUNCTION for a Transient suffix."
  (list :origin-buffer (current-buffer)
        :directory default-directory
        :display-function (or display-function #'pichat-chat-open)))

(defun pichat--launch-target-choices ()
  "Return target names offered by the launch Transient."
  (append '("inferred" "local")
          (mapcar (lambda (entry) (symbol-name (car entry))) pichat-targets)))

(defun pichat--launch-target-argument (arguments)
  "Return normalized target selected in Transient ARGUMENTS."
  (if-let ((argument
            (cl-find-if (lambda (value)
                          (string-prefix-p "--target=" value))
                        arguments)))
      (intern (substring argument (length "--target=")))
    'inferred))

(defun pichat--launch-profile-from-arguments (arguments &optional context)
  "Convert Transient ARGUMENTS and optional CONTEXT to a launch profile."
  (let* ((global-p (member "--global" arguments))
         (ephemeral-p (member "--ephemeral" arguments))
         (prompt-p (member "--model" arguments))
         (independent-p (or (member "--new" arguments)
                            ephemeral-p prompt-p)))
    (pichat--normalize-launch-profile
     (list :scope (if global-p 'global 'current)
           :target (pichat--launch-target-argument arguments)
           :reuse (if independent-p 'new 'preferred)
           :persistence (if ephemeral-p 'ephemeral 'persistent)
           :model (if prompt-p 'prompt 'default)
           :display-function (or (plist-get context :display-function)
                                 #'pichat-chat-open)))))

(defun pichat--launch-profile-description (profile)
  "Return a concise description of normalized launch PROFILE."
  (format "Launch: %s · %s · %s · %s · %s model"
          (if (eq (plist-get profile :scope) 'global) "global" "current")
          (plist-get profile :target)
          (if (eq (plist-get profile :reuse) 'new)
              "independent" "preferred")
          (if (eq (plist-get profile :persistence) 'ephemeral)
              "ephemeral" "persistent")
          (if (eq (plist-get profile :model) 'prompt)
              "choose/enter" "default")))

(defun pichat--launch-action-description ()
  "Return the normalized action description for the active launch Transient."
  (pichat--launch-profile-description
   (pichat--launch-profile-from-arguments
    (transient-get-value) (transient-scope))))

(defun pichat--launch-transient-init-value (object)
  "Initialize Transient prefix OBJECT with safe empty launch switches."
  (oset object value nil))

(transient-define-suffix pichat-launch-execute (arguments context)
  "Execute a PiChat launch from Transient ARGUMENTS and CONTEXT."
  (interactive
   (list (transient-args 'pichat-launch)
         (transient-scope)))
  (let ((profile (pichat--launch-profile-from-arguments arguments context)))
    (when (and (eq (plist-get profile :scope) 'current)
               (functionp (plist-get context :current-scope-function)))
      (let ((selected-scope
             (funcall (plist-get context :current-scope-function))))
        (setq profile
              (plist-put
               profile :scope
               (if (eq (plist-get profile :target) 'inferred)
                   selected-scope
                 (pichat--scope-for-directory
                  (nth 1 selected-scope) nil
                  (plist-get profile :target)))))))
    (pichat--open-launch-profile profile (plist-get context :directory))))

;;;###autoload
(transient-define-prefix pichat-launch (&optional context)
  "Configure and launch a preferred or independent PiChat runtime."
  :init-value #'pichat--launch-transient-init-value
  [["Scope"
    ("g" "Global" "--global")]
   ["Runtime"
    ("n" "Independent runtime" "--new")
    ("t" "Target" "--target="
     :choices pichat--launch-target-choices)]
   ["Persistence"
    ("e" "Ephemeral" "--ephemeral")]
   ["Model"
    ("m" "Choose/enter model" "--model")]]
  [["Action"
    ("RET" pichat-launch-execute
     :description pichat--launch-action-description)]]
  (interactive)
  (transient-setup 'pichat-launch nil nil
                   :scope (or context (pichat--make-launch-context))))

;;;###autoload
(defun pichat (&optional launch-menu)
  "Open a PiChat chat buffer for the current project or global scope.
Without a prefix argument, reuse the preferred persistent/default-model runtime.
With a prefix argument, open `pichat-launch' instead."
  (interactive "P")
  (if launch-menu
      (pichat-launch)
    (pichat--open-launch-profile
     '(:scope current :reuse preferred
       :persistence persistent :model default)
     default-directory)))

;;;###autoload
(defun pichat-global ()
  "Open or create the preferred global PiChat chat buffer."
  (interactive)
  (pichat--open-launch-profile
   '(:scope global :reuse preferred
     :persistence persistent :model default)
   default-directory))

(require 'pichat-session-manager)

(provide 'pichat)
;;; pichat.el ends here
