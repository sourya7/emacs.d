;;; pichat.el --- Emacs frontend for the Pi coding agent -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat is an Emacs frontend for Pi's JSONL RPC mode.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'transient)
(require 'pichat-transient)
(require 'pichat-transport)
(require 'pichat-pi-environment)
(require 'pichat-session)
(require 'pichat-backend)
(require 'pichat-events)
(require 'pichat-path)
(require 'pichat-rpc)
(require 'pichat-reconfigure)
(require 'pichat-tool-picker)
(require 'pichat-mcp-launch)
(require 'pichat-launch-extensions)
(require 'pichat-presets)
(require 'pichat-pi)
(require 'pichat-chat)
(require 'pichat-reference)
(require 'pichat-sessions)
(require 'pichat-commands)
(require 'pichat-approval)
(require 'pichat-tool-bridge)
(require 'pichat-bridge-transport)
(require 'pichat-job-tools)
(require 'pichat-chat-tools)

;; Preserve direct command entry without loading saved-session adapters.
(autoload 'pichat-archive-reset "pichat-archive" nil t)
(autoload 'pichat-consult-load-session "pichat-consult" nil t)
(autoload 'pichat-consult-switch-session "pichat-consult" nil t)
(autoload 'pichat-consult-open-session-independently "pichat-consult" nil t)
(autoload 'pichat-consult-jump-to-match "pichat-consult" nil t)
(autoload 'pichat-consult-show-relations "pichat-consult" nil t)
(autoload 'pichat-consult-show-selected-relations "pichat-consult" nil t)
(autoload 'pichat-consult-select-session "pichat-consult" nil t)

(defconst pichat-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing PiChat Lisp files.")

(defvar pichat-current-session nil
  "Current PiChat session.")

(defvar pichat--sessions-by-scope (make-hash-table :test #'equal)
  "Preferred live PiChat sessions keyed by project/global scope.")

(defvar pichat--preference-revisions (make-hash-table :test #'equal)
  "Choice revision for each backend-qualified preferred-runtime scope.")

(defun pichat--preference-revision (scope-key)
  "Return preferred-runtime choice revision for SCOPE-KEY."
  (gethash scope-key pichat--preference-revisions 0))

(defun pichat--note-preference-choice (scope-key)
  "Record a preferred-runtime choice for SCOPE-KEY."
  (puthash scope-key (1+ (pichat--preference-revision scope-key))
           pichat--preference-revisions))

(defvar pichat--sessions-by-id (make-hash-table :test #'equal)
  "All retained PiChat runtime sessions keyed by immutable runtime ID.")

(defvar pichat--session-order nil
  "Immutable runtime IDs in registry insertion order.")

(defvar pichat--source-reservations (make-hash-table :test #'equal)
  "Transport-qualified saved files reserved by in-progress independent opens.")

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

(defcustom pichat-launch-display-chat-function #'pichat-chat-open
  "Function used to display a runtime launched from the ordinary Transient.
The function receives the runtime session.  Manager-initiated launches supply
an explicit display function instead of using this default."
  :type 'function
  :group 'pichat)

(defun pichat--directory-basename (directory)
  "Return a display basename for DIRECTORY."
  (file-name-nondirectory (directory-file-name (file-name-as-directory directory))))

(defun pichat--project-root (&optional directory)
  "Return project root for DIRECTORY, or nil outside projects."
  (let ((default-directory (file-name-as-directory (or directory default-directory))))
    (when-let* ((project (project-current nil)))
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
        (if-let* ((root (pichat--project-root directory)))
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
         (and key
              (eq (gethash (pichat-backend-scope-key session key)
                           pichat--sessions-by-scope)
                  session)))))

(defun pichat-clear-default-session (session)
  "Remove SESSION from every preferred-scope slot without forgetting it."
  (let (keys changed)
    (maphash (lambda (key value)
               (when (eq value session) (push key keys)))
             pichat--sessions-by-scope)
    (dolist (key keys)
      (setq changed t)
      (remhash key pichat--sessions-by-scope)
      (pichat--note-preference-choice key))
    (when changed
      (pichat--notify-registry-change 'default-changed session))
    changed))

(defun pichat-set-default-session (session)
  "Make retained live SESSION preferred for its immutable owner scope."
  (unless (and session (pichat-session-alive-p session))
    (user-error "Only a live PiChat session can be made the scope default"))
  (when (pichat-session-input-guard session)
    (user-error "A job-owned inspection runtime cannot become preferred"))
  (pichat-register-session session)
  (let ((key (pichat-session-owner-scope-key session)))
    (unless key (user-error "PiChat session has no owner scope"))
    (let ((qualified-key (pichat-backend-scope-key session key)))
      (puthash qualified-key session pichat--sessions-by-scope)
      (pichat--note-preference-choice qualified-key))
    (setf (pichat-session-scope-key session) key)
    (pichat--notify-registry-change 'default-changed session)
    session))

(defun pichat--suspend-default-for-restart (session)
  "Suspend SESSION's preferred designation and return its revision ticket.
Do this only after restart preflight succeeds, never when opening a menu."
  (when (pichat-session-default-p session)
    (let ((key (pichat-backend-scope-key
                session (pichat-session-owner-scope-key session))))
      (pichat-clear-default-session session)
      (list :key key :revision (pichat--preference-revision key)))))

(defun pichat--restore-default-after-restart (session ticket)
  "Restore SESSION's preferred designation if TICKET has not been superseded.
Return non-nil only when SESSION was restored.  A choice in another scope
never prevents restoration, but a later choice in SESSION's scope does."
  (when-let* ((key (plist-get ticket :key)))
    (when (and (eq (pichat-session-by-runtime-id
                    (pichat-session-runtime-id session))
                   session)
               (equal key (pichat-backend-scope-key
                           session (pichat-session-owner-scope-key session)))
               (eql (plist-get ticket :revision)
                    (pichat--preference-revision key))
               (not (gethash key pichat--sessions-by-scope))
               (pichat-session-alive-p session))
      (pichat-set-default-session session)
      t)))

(defun pichat-forget-session (session)
  "Forget stopped or failed runtime SESSION without stopping other sessions."
  (when session
    (when (and (pichat-session-restart-operation session)
               (pichat-session-alive-p session))
      (user-error "Stop the restarting PiChat runtime before forgetting it"))
    (when (pichat-reconfigure-source-claim session)
      (user-error "Recover the restart or confirm all Pi writer exits before forgetting it"))
    (pichat-reconfigure-cancel-operation session "Runtime forgotten")
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

(defun pichat--restarting-runtime-for-scope (key)
  "Return the retained runtime actively restarting in owner scope KEY."
  (cl-find-if
   (lambda (session)
     (let ((operation (pichat-session-restart-operation session)))
       (and (equal key (pichat-session-owner-scope-key session))
            operation
            (memq (plist-get operation :phase)
                  '(preflight stopping starting loading synchronizing)))))
   (pichat-session-list)))

(defun pichat--reject-restarting-preferred-scope (key)
  "Do not create a replacement preferred runtime for restarting scope KEY."
  (when (pichat--restarting-runtime-for-scope key)
    (user-error "A PiChat runtime is restarting in this scope; wait or recover it")))

(defun pichat-session-for-directory (&optional directory)
  "Return an existing live PiChat session for DIRECTORY's scope, if any.

This does not create a new session.  It is used by `pichat-session-current'
so commands run from ordinary project buffers prefer that project's live
session over the global `pichat-current-session'."
  (pcase-let ((`(,key ,_cwd ,_label) (pichat--scope-for-directory directory)))
    (pichat--reject-restarting-preferred-scope key)
    (let ((session (gethash key pichat--sessions-by-scope)))
      (when session
        (if (pichat-session-alive-p session)
            session
          (pichat-clear-default-session session)
          nil)))))

(defun pichat--preferred-session-for-exact-scope (scope &optional launch-options)
  "Return the live preferred runtime for exact SCOPE, creating it if needed."
  (pcase-let ((`(,key ,cwd ,label) scope))
    (pichat--reject-restarting-preferred-scope key)
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

(defun pichat--exact-scope-p (scope)
  "Return non-nil when SCOPE is an exact immutable scope tuple."
  (and (listp scope)
       (= (length scope) 3)
       (stringp (nth 0 scope))
       (stringp (nth 1 scope))
       (stringp (nth 2 scope))))

(defun pichat--normalize-launch-profile (&optional profile)
  "Return validated high-level launch PROFILE with explicit defaults.
An omitted model follows an explicitly named preset's model policy; the
`default' preset choice keeps Pi's default model so it can reuse the
preferred runtime."
  (let* ((backend (or (plist-get profile :backend) 'pi))
         (scope (or (plist-get profile :scope) 'current))
         (target (or (plist-get profile :target) 'inferred))
         (persistence (or (plist-get profile :persistence) 'persistent))
         (preset (or (plist-get profile :preset) 'default))
         (tools (plist-get profile :tools))
         (extensions (plist-get profile :extensions))
         (model (or (plist-get profile :model)
                    (and (not (eq preset 'default))
                         (pichat-presets-defined-p preset)
                         (pichat-presets-model preset))
                    'default))
         (explicit-reuse-p (plist-member profile :reuse))
         (reuse (or (plist-get profile :reuse)
                    (if (or (eq persistence 'ephemeral)
                            (not (eq preset 'default))
                            tools extensions
                            (eq model 'prompt)
                            (stringp model))
                        'new
                      'preferred)))
         (conversation (plist-get profile :conversation))
         (display-function (or (plist-get profile :display-function)
                               #'pichat-chat-open)))
    (unless (eq backend 'pi)
      (user-error "Invalid PiChat backend: %S" backend))
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
    (when (plist-member profile :execution)
      (user-error "Obsolete :execution option; select a PiChat :preset instead"))
    (unless (or (eq preset 'default) (pichat-presets-defined-p preset))
      (user-error "Unknown PiChat launch preset: %S" preset))
    (when tools
      (pichat-tool-selection-resolve
       (pichat-presets-resolve (if (eq preset 'default)
                                   pichat-default-preset preset)) tools))
    (unless (or (memq model '(default prompt))
                (and (stringp model) (not (string-blank-p model))))
      (user-error "Invalid PiChat model policy: %S" model))
    (unless (functionp display-function)
      (user-error "Invalid PiChat display function: %S" display-function))
    (unless (or (null conversation)
                (and (eq (plist-get conversation :kind) 'saved)
                     (listp (plist-get conversation :selection))))
      (user-error "Invalid PiChat launch conversation selection"))
    (unless (and (proper-list-p extensions)
                 (cl-every #'pichat-presets-extension-spec-p extensions)
                 (= (length extensions)
                    (length (delete-dups (copy-sequence extensions)))))
      (user-error "Invalid or duplicate PiChat launch extensions: %S" extensions))
    (when (and conversation (eq reuse 'preferred))
      (user-error "Selected conversations require an independent runtime"))
    (when (and extensions (eq reuse 'preferred))
      (user-error "Added extensions require an independent runtime"))
    (when (and (eq reuse 'preferred)
               (or (eq persistence 'ephemeral)
                   (not (eq preset 'default))
                   tools
                   (eq model 'prompt)
                   (stringp model)))
      (if explicit-reuse-p
          (user-error
           "Preferred PiChat runtimes require persistent/default-model/default-preset/tools launch")
        (setq reuse 'new)))
    (append (list :backend backend
                  :scope scope
                  :target target
                  :reuse reuse
                  :persistence persistence
                  :preset preset
                  :tools (copy-tree tools)
                  :model model
                  :display-function display-function)
            (when conversation (list :conversation conversation))
            ;; Omitted when empty so existing profiles remain unchanged.
            (when extensions (list :extensions (copy-sequence extensions))))))

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

(defun pichat--launch-destination (profile &optional directory)
  "Return (SCOPE . TRANSPORT) for PROFILE launched from optional DIRECTORY.
SCOPE is PROFILE's resolved owner scope; TRANSPORT is resolved from its
working directory and PROFILE's explicit target, if any."
  (let* ((target (plist-get profile :target))
         (scope (pichat--resolve-launch-scope
                 (plist-get profile :scope) directory target)))
    (cons scope (pichat-transport-resolve
                 (nth 1 scope) (unless (eq target 'inferred) target)))))

(defun pichat--display-and-synchronize-session (session display-function)
  "Display and synchronize exact SESSION through DISPLAY-FUNCTION."
  (funcall display-function session)
  (unless (eq 'error (pichat-session-state session))
    (pichat-backend-get-state session (lambda (_response _session) nil)))
  session)

(defun pichat--selected-file-key (transport runtime-file &optional context)
  "Return the canonical writer key for RUNTIME-FILE on TRANSPORT.
For a mapped local runtime, canonicalize the host path using CONTEXT."
  (let* ((host-file
          (or (and (eq (pichat-transport-kind transport) 'local)
                   (plist-get
                    (pichat-path-resolve-from-runtime
                     runtime-file (or context (pichat-transport-path-context
                                               transport pichat-path-mappings)))
                    :path))
              (pichat-transport-runtime-file-name transport runtime-file)))
         (canonical (file-truename host-file)))
    (cons (if (eq (pichat-transport-kind transport) 'ssh)
              (pichat-transport-tramp-prefix transport)
            'local)
          (or (file-remote-p canonical 'localname) canonical))))

(defun pichat--selected-file-conflict (key)
  "Return a managed runtime claiming KEY, including uncertain restart writers."
  (cl-find-if
   (lambda (session)
     (let ((claim (pichat-reconfigure-source-claim session)))
       (if (plist-get claim :key)
           (equal key (plist-get claim :key))
         (and (pichat-session-alive-p session)
              (pichat-session-session-file session)
              (condition-case nil
                  (equal key (pichat--selected-file-key
                              (pichat-session-transport session)
                              (pichat-session-session-file session)
                              (pichat-session-path-context session)))
                (error nil))))))
   (pichat-session-list)))

(defun pichat--selected-file-reserved-p (key)
  "Return the current in-progress independent launch claim for KEY."
  (gethash key pichat--source-reservations))

(defun pichat--claim-selected-file (key)
  "Acquire KEY for one independent launch and return its ownership token."
  (when (pichat--selected-file-reserved-p key)
    (user-error "A PiChat launch is already loading this saved conversation"))
  (let ((token (make-symbol "pichat-saved-launch")))
    (puthash key token pichat--source-reservations)
    token))

(defun pichat--release-selected-file (key token)
  "Release KEY only if TOKEN still owns the independent-launch claim."
  (when (eq token (pichat--selected-file-reserved-p key))
    (remhash key pichat--source-reservations)))

(defun pichat--open-selected-conversation-profile (profile directory)
  "Launch PROFILE's saved session, resolving its owner scope from DIRECTORY.
Prevent a second writer for the same saved session file."
  (let* ((selection (plist-get (plist-get profile :conversation) :selection))
         (source (plist-get selection :source-session))
         (target (plist-get profile :target))
         (destination (pichat--launch-destination profile directory))
         (scope (car destination))
         (transport (cdr destination))
         (file (plist-get selection :file)))
    (unless (eq (plist-get profile :persistence) 'persistent)
      (user-error "A saved conversation cannot launch with ephemeral storage"))
    (unless (and (equal (pichat-transport-id transport)
                        (plist-get selection :transport-id))
                 (equal transport (plist-get selection :transport)))
      (user-error "Selected conversation target or path context changed; reselect it"))
    (unless (or (null source)
                (eq (pichat-session-transport source)
                    (plist-get selection :transport)))
      (user-error "Selected conversation provenance has changed"))
    (let* ((runtime-file (pichat-sessions--runtime-file file source))
           (host-file (pichat-transport-runtime-file-name
                       transport runtime-file)))
      (unless (and (file-regular-p host-file) (file-readable-p host-file))
        (user-error "Selected saved conversation is no longer readable"))
      (let* ((key (pichat--selected-file-key transport runtime-file))
             (conflict (pichat--selected-file-conflict key))
             (reservation (pichat--selected-file-reserved-p key)))
        (when conflict
          (pcase (car (read-multiple-choice
                       (format "Open in runtime %s: " (pichat-session-runtime-id conflict))
                       '((?o "Open")
                         (?c "Cancel"))))
            (?o (pichat-chat-open conflict)
                (user-error "Opened existing chat; no new writer was started"))
            (_ (user-error "Selected saved conversation launch cancelled"))))
        (when reservation
          (user-error "A PiChat launch is already loading this saved conversation"))
        (let ((token (pichat--claim-selected-file key))
              (previous pichat-current-session))
          (cl-labels ((release () (pichat--release-selected-file key token)))
            (condition-case error-data
                (pichat-sessions-open-file-independently
                 file :cwd (plist-get selection :cwd)
                 :owner-directory (nth 1 scope) :owner-scope scope
                 :source-session source :readiness 'transcript-ready
                 :expected-session-id (plist-get selection :session-id)
                 :launch-options
                 (append
                  (list :persistence 'persistent
                        :target (unless (eq target 'inferred) target))
                  (pichat--launch-preset-option profile)
                  (list
                       :tools (plist-get profile :tools)
                       :extensions (plist-get profile :extensions)
                       :model (and (stringp (plist-get profile :model))
                                   (plist-get profile :model))))
                 :display-function (plist-get profile :display-function)
                 :ready (lambda (session)
                          (release)
                          (setq pichat-current-session session))
                 :error-callback
                 (lambda (response _session)
                   (release)
                   (setq pichat-current-session previous)
                   (message "PiChat selected conversation launch failed: %s"
                            (plist-get response :error))))
              (error (release) (signal (car error-data) (cdr error-data))))))))))

(defvar pichat--launch-mcp-verified nil
  "Non-nil while continuing a launch whose preset MCP tools were verified.")

(defvar pichat--launch-expanded-preset nil
  "Preset snapshot whose future tools were discovered for the launch continued.
See `pichat--expand-launch-all'.")

(defun pichat--launch-reuses-live-runtime-p (profile directory)
  "Return non-nil when PROFILE reuses a live preferred runtime in DIRECTORY."
  (and (eq (plist-get profile :reuse) 'preferred)
       (let* ((scope (pichat--resolve-launch-scope
                      (plist-get profile :scope) directory
                      (plist-get profile :target)))
              (session (gethash (nth 0 scope) pichat--sessions-by-scope)))
         (and session (pichat-session-alive-p session)))))

(defun pichat--launch-preset-option (profile)
  "Return the launch options naming PROFILE's preset for a new runtime.
After `pichat--expand-launch-all', the expanded snapshot is passed as
:preset-spec, so the runtime records the tools discovered for it."
  (if pichat--launch-expanded-preset
      (list :preset-spec (pichat-presets--copy pichat--launch-expanded-preset))
    (list :preset (plist-get profile :preset))))

(defun pichat--launch-baseline-mcp (profile directory)
  "Return PROFILE's preset MCP baseline when a new runtime would use it.
Nil when Tools were customized (Apply already checked them), the baseline has
no MCP tools, or a live preferred runtime in DIRECTORY's scope is reused."
  (unless (plist-get profile :tools)
    (let* ((preset (plist-get profile :preset))
           (pairs (plist-get (pichat-get-preset (if (eq preset 'default)
                                                    pichat-default-preset
                                                  preset))
                             :mcp)))
      (when (and pairs
                 (not (pichat--launch-reuses-live-runtime-p profile directory)))
        pairs))))

(defun pichat--launch-pending-all (profile directory)
  "Return PROFILE's resolved preset when its future tools are discovered first.
That is a preset with (SOURCE . :all) groups whose own tools a new runtime
would use: not when Tools were customized (the picker applied exact names),
not when they are already expanded, and not when a live preferred runtime
in DIRECTORY's scope is reused."
  (unless (or pichat--launch-expanded-preset (plist-get profile :tools))
    (let* ((preset (plist-get profile :preset))
           (name (if (eq preset 'default) pichat-default-preset preset))
           (tools (plist-get (pichat-get-preset name) :tools)))
      ;; Resolving reads prompt files, so check the definition first.
      (when (and (cl-some (lambda (group) (eq (cdr group) :all))
                          (pichat-presets-tool-groups tools))
                 (not (pichat--launch-reuses-live-runtime-p profile directory)))
        (pichat-presets-resolve name)))))

(defun pichat--expand-preset-all (spec directory transport model extensions callback)
  "Discover the future tools of resolved preset SPEC; call CALLBACK.
The probe is the one x Tools would run for a runtime in DIRECTORY on
TRANSPORT with MODEL (nil for Pi's default), SPEC's prompts and the
EXTENSIONS it loads.  CALLBACK receives (EXPANDED ERROR), later and
once: SPEC with its (SOURCE . :all) groups expanded to the eligible
tools found now (`pichat-tool-picker-expand-all'), or nil and the
reason.  Return the probe's cancel function, which suppresses CALLBACK."
  (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
    (user-error "Included future tools cannot be discovered through a complete Pi command wrapper"))
  (let ((draft (pichat-tool-discovery-draft-create)))
    (pichat-tool-discovery-draft-reset
     draft (cdr (pichat-tool-picker-discovery-context
                 spec directory transport pichat-pi-executable model extensions)))
    (pichat-tool-discovery-draft-refresh
     draft
     (lambda (draft)
       (run-at-time
        0 nil
        (lambda ()
          (when callback
            (let ((result
                   (condition-case err
                       (progn
                         (unless (eq 'ready (pichat-tool-discovery-draft-status draft))
                           (user-error "Tool discovery failed: %s"
                                       (pichat-tool-discovery-draft-error draft)))
                         (list (pichat-tool-picker-expand-all spec draft) nil))
                     (error (list nil (error-message-string err))))))
              (apply callback result)))))))
    (let ((cancel (pichat-tool-discovery-draft-cancel draft)))
      (lambda ()
        (setq callback nil)
        (when cancel (funcall cancel))))))

(defun pichat--expand-launch-all (profile directory spec continue)
  "Discover SPEC's future tools for PROFILE, then call CONTINUE.
SPEC is PROFILE's resolved preset with unexpanded (SOURCE . :all) groups.
The probe runs at the destination of PROFILE from DIRECTORY, with its
model and every extension the runtime loads (`pichat--expand-preset-all').
CONTINUE receives the expanded SPEC; the launch does not report which
tools that added.  A failed probe cancels the launch with a message."
  (pcase-let* ((`(,scope . ,transport) (pichat--launch-destination profile directory))
               (model (plist-get profile :model)))
    (message "Discovering tools for preset %s..." (plist-get spec :name))
    (pichat--expand-preset-all
     spec (nth 1 scope) transport (and (stringp model) model)
     (pichat-presets-load-extensions spec (plist-get profile :extensions))
     (lambda (expanded error)
       (if error
           (message "PiChat launch cancelled: %s" error)
         (condition-case err
             (funcall continue expanded)
           (error
            (message "PiChat launch cancelled: %s" (error-message-string err)))))))
    nil))

(defun pichat--verify-launch-mcp (profile directory continue)
  "Check PROFILE's preset MCP baseline at its destination, then call CONTINUE.
Pass the destination catalogue to runtime startup for access-route discovery."
  (let* ((destination (pichat--launch-destination profile directory))
         (scope (car destination))
         (transport (cdr destination))
         (context (pichat-transport-path-context transport pichat-path-mappings))
         (runtime-cwd (or (plist-get (pichat-path-resolve-to-runtime
                                      (nth 1 scope) context)
                                     :path)
                          (user-error "Directory is unavailable to target %s"
                                      (pichat-transport-label transport))))
         (executable (or (pichat-transport-pi-executable transport) pichat-pi-executable))
         (preset (plist-get profile :preset))
         (snapshot (pichat-tool-selection-resolve
                    (pichat-presets-resolve (if (eq preset 'default)
                                                pichat-default-preset
                                              preset)))))
    (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
      (user-error "Preset MCP tools cannot be selected through a complete Pi command wrapper"))
    (message "Checking preset MCP tools for %s..." (pichat-transport-label transport))
    (pichat-mcp-discovery-start
     transport runtime-cwd executable
     (lambda (servers errors)
       (run-at-time
        0 nil
        (lambda ()
          (condition-case err
              (progn
                (unless servers
                  (user-error "MCP discovery failed: %s" (or errors "no MCP servers")))
                (pichat-tool-selection-mcp-indirect-p snapshot servers)
                (let ((pichat--launch-mcp-verified t)
                      (pichat-mcp-launch-catalogue (list transport runtime-cwd executable servers)))
                  (funcall continue)))
            (error
             (message "PiChat launch cancelled: %s"
                      (error-message-string err))))))))))

(defun pichat--open-launch-profile (profile &optional directory)
  "Open normalized launch PROFILE relative to optional DIRECTORY.
Return the exact runtime synchronously when its model is already known.
Prompted-model profiles first select a model asynchronously and return nil,
as do presets whose MCP baseline is first checked at the destination."
  (let* ((profile (pichat--normalize-launch-profile profile))
         (model (plist-get profile :model))
         (pending (and (not (eq model 'prompt))
                       (pichat--launch-pending-all profile directory))))
    (cond
     ((eq model 'prompt)
      (pichat--select-model-before-launch profile directory)
      nil)
     (pending
      (let ((verified pichat--launch-mcp-verified))
        (pichat--expand-launch-all
         profile directory pending
         (lambda (expanded)
           (let ((pichat--launch-expanded-preset expanded)
                 (pichat--launch-mcp-verified verified))
             (pichat--open-launch-profile profile directory)))))
      nil)
     ((and (not pichat--launch-mcp-verified)
           (pichat--launch-baseline-mcp profile directory))
      (let ((expanded pichat--launch-expanded-preset))
        (pichat--verify-launch-mcp
         profile directory
         (lambda ()
           (let ((pichat--launch-expanded-preset expanded))
             (pichat--open-launch-profile profile directory)))))
      nil)
     ((eq (plist-get (plist-get profile :conversation) :kind) 'saved)
      (pichat--open-selected-conversation-profile profile directory))
     (t
      (let* ((target (plist-get profile :target))
             (scope (pichat--resolve-launch-scope
                     (plist-get profile :scope) directory target))
             (reuse (plist-get profile :reuse))
             (persistence (plist-get profile :persistence))
             (display-function (plist-get profile :display-function))
             (launch-options
              (append
               (list :persistence persistence)
               (pichat--launch-preset-option profile)
               (list
                    :tools (copy-tree (plist-get profile :tools))
                    :extensions (copy-sequence (plist-get profile :extensions))
                    :model (and (stringp model) model)
                    :target (unless (eq target 'inferred) target))))
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
        session)))))

(defun pichat-prepare-session (&optional cwd scope launch-options)
  "Prepare a runtime rooted at CWD without registering or starting it.
SCOPE is the immutable (KEY CWD LABEL) owner scope.  LAUNCH-OPTIONS supports
`:persistence', `:preset', `:tools', `:transport', run-local `:model' and
`:extensions', specs Pi loads with `-e' on every start of the runtime.
Instead of a `:preset' name, `:preset-spec' may supply an already resolved
preset snapshot (for example a job's captured preset); the preset registry is
then not consulted.  A non-nil `:restore-saved-model' (refused together with
`:model') omits `pichat-default-model', so that Pi restores the model of the
saved session the runtime then loads.
The returned runtime captures resolved configuration and path context.  It does
not become current/preferred and no RPC process or chat is created."
  (when (plist-member launch-options :execution)
    (user-error "Obsolete :execution option; select a PiChat :preset instead"))
  (when (and (plist-get launch-options :preset)
             (plist-get launch-options :preset-spec))
    (user-error "Use either a PiChat :preset name or a :preset-spec snapshot"))
  (when (and (plist-get launch-options :model)
             (plist-get launch-options :restore-saved-model))
    (user-error "Use either a run-local :model or :restore-saved-model"))
  (when-let* ((captured (plist-get launch-options :preset-spec)))
    (unless (and (listp captured) (plist-get captured :name)
                 (symbolp (plist-get captured :name)))
      (user-error "Invalid PiChat preset snapshot: %S" captured)))
  (let* ((captured (plist-get launch-options :preset-spec))
         (preset-name (if captured
                          (plist-get captured :name)
                        (let ((choice (plist-get launch-options :preset)))
                          (if (or (null choice) (eq choice 'default))
                              pichat-default-preset choice))))
         (preset-spec (if captured
                          (pichat-presets--copy captured)
                        (pichat-presets-resolve preset-name)))
         (tool-selection (pichat-tool-selection-check-expanded
                          (pichat-tool-selection-resolve preset-spec
                                                         (plist-get launch-options :tools))
                          preset-name))
         (transport-override (plist-get launch-options :transport))
         (target (plist-get launch-options :target))
         (cwd (file-name-as-directory
               (expand-file-name (or cwd default-directory))))
         (transport (or transport-override
                        (pichat-transport-resolve cwd target)))
         (normalized-options
          (pichat-rpc-normalize-launch-options
           (plist-put
            (plist-put
             (plist-put (copy-sequence launch-options)
                        :preset-spec preset-spec)
             :preset-args
             (append pichat-pi-default-args
                     (pichat-transport-pi-args transport)
                     (unless (eq (pichat-transport-kind transport) 'ssh)
                       pichat-pi-extra-args)))
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
                   :preset-name preset-name
                   :preset-spec preset-spec
                   :tool-selection tool-selection
                   :extensions (plist-get normalized-options :extensions)
                   :startup-model (plist-get normalized-options :model)
                   :restore-saved-model
                   (and (plist-get launch-options :restore-saved-model) t)
                   :scope-key (nth 0 scope)
                   :owner-scope-key (nth 0 scope)
                   :owner-scope-label (nth 2 scope))))
    (cl-incf pichat--manual-session-counter)
    (setf (pichat-session-scope-label session)
          (format "manual:%s#%d" (pichat--directory-basename cwd)
                  pichat--manual-session-counter))
    session))

(defun pichat-start-prepared-session (session &optional background command)
  "Register and start prepared SESSION, returning it.
BACKGROUND leaves current/preferred runtime selection untouched.  Optional
COMMAND is a captured Pi argv; no registry/default configuration is re-resolved.
Callers may install owning handlers/chat before starting."
  (when (pichat-session-process session)
    (user-error "Prepared runtime has already been started"))
  (pichat-register-session
   session (list (pichat-session-owner-scope-key session)
                 (pichat-session-owner-directory session)
                 (pichat-session-owner-scope-label session)))
  (if command
      (progn
        (unless (eq (pichat-session-backend-id session) 'pi)
          (user-error "Captured commands require a Pi runtime"))
        (pichat-rpc-start session command))
    (pichat-backend-start-session session))
  (unless background (setq pichat-current-session session))
  session)

;;;###autoload
(defun pichat-start-session (&optional cwd scope launch-options)
  "Start an independent PiChat runtime rooted at CWD and return it.
SCOPE is an optional immutable (KEY CWD LABEL) owner scope.
LAUNCH-OPTIONS supports `:persistence', `:preset' (or a resolved
`:preset-spec'), `:tools', `:transport' and run-local `:model' (or
`:restore-saved-model'; see `pichat-prepare-session')."
  (interactive)
  (let ((session (pichat-prepare-session cwd scope launch-options)))
    (pichat-start-prepared-session session (plist-get launch-options :background))
    (when (called-interactively-p 'interactive)
      (if (pichat-session-alive-p session)
          (message "PiChat RPC started: %S"
                   (pichat-session-rpc-command session))
        (message "PiChat RPC startup failed: %s"
                 (or (pichat-chat-diagnostics-latest-summary session)
                     "see M-x pichat-show-diagnostics"))))
    session))

;;;###autoload
(defun pichat-stop-session (&optional session)
  "Stop SESSION or the best current PiChat session."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session
      (user-error "No PiChat session"))
    (pichat-reconfigure-cancel-operation session "Runtime stopped by user")
    (pichat-backend-stop-session session)
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
        (let ((process-environment (pichat-pi-process-environment)))
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
                               (if (eq (pichat-transport-kind transport) 'ssh)
                                   ;; A consumer can start a runtime.  Run it
                                   ;; after the full stderr teardown, even if
                                   ;; the connection was otherwise idle.
                                   (pichat-transport-defer
                                    transport (lambda () (funcall callback models)))
                                 (funcall callback models))
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
                     (kill-buffer stderr))))))))
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
    (pichat-backend-require-capability session 'models "Model selection")
    (condition-case nil
        (pcase-let* ((`(,choice . ,model) (pichat--read-model-choice models)))
          (when (pichat-session-alive-p session)
            (pichat-rpc-set-model
             session (plist-get model :provider) (plist-get model :id)
             (lambda (_response model-session)
               (pichat-backend-get-state
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
    (pichat-backend-require-capability session 'models "Model selection")
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
      (ignore-errors (pichat-backend-stop-session session)))
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
       "Run-local PiChat models are not supported with a local `pichat-rpc-command'"))
    (let* ((origin-directory (or directory default-directory))
           (pichat--model-list-directory origin-directory)
           (pichat--model-list-target transport))
      (pichat--list-models-async
       nil
       (lambda (models)
         (if (eq (pichat-transport-kind transport) 'ssh)
             ;; SSH delivery has already crossed the idle boundary.  Another
             ;; zero-delay timer could run inside unrelated connection work.
             (pichat--prompt-and-open-selected-model models profile origin-directory)
           (run-at-time 0 nil #'pichat--prompt-and-open-selected-model
                        models profile directory)))))))

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
     (pichat-backend-get-state
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
    (pichat-backend-get-state
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
           (pichat-backend-get-state
            session
            (lambda (response _session)
              (message "PiChat smoke test OK: %S" (plist-get response :data))
              (pichat-backend-stop-session session)))
         (message "PiChat smoke test failed: process is not alive"))))
    session))

(defun pichat--make-launch-context (&optional display-function)
  "Capture launch origin and optional DISPLAY-FUNCTION for a Transient suffix."
  (list :origin-buffer (current-buffer)
        :directory default-directory
        :display-function (or display-function
                              pichat-launch-display-chat-function)))

(defun pichat--launch-reconfigure-scope (&optional context)
  "Return the active reconfigure draft state of launcher CONTEXT."
  (let ((context (or context (transient-scope))))
    (when (eq (plist-get context :mode) 'reconfigure)
      (plist-get context :reconfigure))))

(defun pichat--launch-reconfigure-p ()
  "Return non-nil while the launcher is in reconfigure mode."
  (and (pichat--launch-reconfigure-scope) t))

(defun pichat--launch-origin-runtime (context)
  "Return the runtime owning the chat where CONTEXT started, if any."
  (let* ((buffer (plist-get context :origin-buffer))
         (session (and (buffer-live-p buffer)
                       (buffer-local-value 'pichat-chat-session buffer))))
    (when (and (pichat-session-p session)
               (eq buffer (pichat-session-buffer session)))
      session)))

(defun pichat--launch-reconfigure-blocker ()
  "Explain why the launcher cannot enter reconfigure mode, or return nil."
  (unless (pichat--launch-reconfigure-p)
    (let ((session (pichat--launch-origin-runtime (transient-scope))))
      (cond ((null session) "Requires owning chat")
            ((pichat-session-input-guard session)
             pichat-reconfigure--job-blocker)))))

(defun pichat--launch-reconfigure-description ()
  "Describe the toggle, highlighting reconfigure mode."
  (cond
   ((pichat--launch-reconfigure-p)
    (propertize "Reconfigure" 'face 'transient-value))
   ((when-let* ((reason (pichat--launch-reconfigure-blocker)))
      (pichat-transient-fill (concat "Reconfigure · " reason))))
   (t "Reconfigure")))

(defun pichat--launch-reconfigure-action-description ()
  "Describe the action for the launcher's active mode."
  (if (pichat--launch-reconfigure-p)
      (pichat--reconfigure-action-description)
    (pichat--launch-action-description)))

(defun pichat--launch-reconfigure-action-heading ()
  "Return the action heading for the launcher's active mode."
  (if (pichat--launch-reconfigure-p)
      (pichat--reconfigure-action-heading)
    (pichat--launch-action-heading)))

(defun pichat--launch-reconfigure-action-inapt-p ()
  "Return non-nil if the launcher's restart action is blocked."
  (and (pichat--launch-reconfigure-p) (pichat--reconfigure-action-inapt-p)))

(defun pichat--launch-target-choices ()
  "Return target names offered by the launch Transient."
  (append '("inferred" "local")
          (mapcar (lambda (entry) (symbol-name (car entry))) pichat-targets)))

(defun pichat--launch-preset-choices ()
  "Return default policy and registered preset names for the launcher."
  (cons "default" (mapcar #'symbol-name (pichat-presets-names))))

(defun pichat--read-configuration-preset (prompt initial tools &optional defaults history)
  "Read a preset for PROMPT, confirming reset of customized TOOLS.
INITIAL is its current name.  DEFAULTS allows the launcher's default policy.
HISTORY is the completion history variable.
Return a name without changing state."
  (let* ((choices (if defaults (pichat--launch-preset-choices)
                    (mapcar #'symbol-name (pichat-presets-names))))
         (completion-extra-properties
          (list :annotation-function
                (lambda (choice)
                  (when-let* ((description
                               (if (equal choice "default")
                                   (format "Use configured default (%s)" pichat-default-preset)
                                 (plist-get (pichat-get-preset (intern choice)) :description))))
                    (concat "  " description)))))
         (chosen (completing-read prompt choices nil t nil history initial)))
    (when (and tools (not (equal chosen initial))
               (not (yes-or-no-p "Discard Tools changes? ")))
      (user-error "Preset change cancelled"))
    chosen))

(defun pichat--launch-read-preset (prompt initial history)
  "Read a named preset or default policy with descriptions."
  (let* ((scope (transient-scope))
         (chosen (pichat--read-configuration-preset
                  prompt initial (plist-get scope :tool-selection) t history)))
    (unless (equal chosen initial)
      ;; A newly selected preset brings its own baseline and model policy.
      (setf (plist-get scope :tool-selection) nil
            (plist-get scope :tool-sources) nil
            (plist-get scope :tool-target) nil
            (plist-get scope :model) nil))
    chosen))

(defun pichat--launch-target-argument (arguments)
  "Return normalized target selected in Transient ARGUMENTS."
  (if-let* ((argument
            (cl-find-if (lambda (value)
                          (string-prefix-p "--target=" value))
                        arguments)))
      (intern (substring argument (length "--target=")))
    'inferred))

(defun pichat--launch-profile-from-arguments (arguments &optional context)
  "Convert Transient ARGUMENTS and optional CONTEXT to a launch profile."
  (when (member "--native" arguments)
    (user-error "Native PiChat launch is no longer supported"))
  (when (member "--manual-runner" arguments)
    (user-error "Obsolete --manual-runner; use --preset=manual"))
  (let* ((global-p (member "--global" arguments))
         (ephemeral-p (member "--ephemeral" arguments))
         (prompt-p (member "--model" arguments))
         (preset-arg (cl-find-if (lambda (arg) (string-prefix-p "--preset=" arg))
                                 arguments))
         (preset (if preset-arg
                     (let ((name (substring preset-arg 9)))
                       (or (cl-find-if
                            (lambda (entry) (string= name (symbol-name entry)))
                            (pichat-presets-names))
                           (and (string= name "default") 'default)
                           (user-error "Unknown PiChat preset: %s" name)))
                   'default))
         (tools (plist-get context :tool-selection))
         (extensions (pichat-launch-extensions-checked
                      (plist-get context :extensions)))
         (conversation (plist-get context :conversation))
         ;; Nil follows the preset; a staged choice from `m' overrides it.
         (model (cond (prompt-p 'prompt)
                      ((plist-get context :model))))
         (independent-p (or (member "--new" arguments)
                            (eq (plist-get conversation :kind) 'saved)
                            ephemeral-p prompt-p tools extensions
                            (memq model '(prompt)) (stringp model)
                            (not (eq preset 'default)))))
    (pichat--normalize-launch-profile
     (list :backend 'pi
           :scope (if global-p 'global 'current)
           :target (pichat--launch-target-argument arguments)
           :reuse (if independent-p 'new 'preferred)
           :persistence (if ephemeral-p 'ephemeral 'persistent)
           :preset preset
           :tools tools
           :extensions extensions
           :conversation conversation
           :model model
           :display-function (or (plist-get context :display-function)
                                 #'pichat-chat-open)))))

(defun pichat--launch-current-chat (profile context)
  "Return the owning runtime when PROFILE can open CONTEXT's origin chat.
Return a fallback reason string if that runtime is unusable, or nil if
current-chat routing does not apply.  The owner scope includes the target."
  (when-let* (((eq (plist-get profile :reuse) 'preferred))
              (buffer (plist-get context :origin-buffer))
              ((buffer-live-p buffer))
              (session (buffer-local-value 'pichat-chat-session buffer))
              ((pichat-session-p session))
              ((eq buffer (pichat-chat-owned-buffer session)))
              (owner (pichat-session-owner-scope-key session))
              (scope (pichat--resolve-launch-scope
                      (plist-get profile :scope) (plist-get context :directory)
                      (plist-get profile :target)))
              ((equal owner (car scope))))
    (cond
     ((pichat-session-restart-operation session)
      "restart or recovery is pending")
     ((eq (pichat-session-state session) 'error) "runtime is in error")
     ((not (pichat-session-alive-p session)) "runtime is not live")
     (t session))))

(defun pichat--launch-profile-description (profile)
  "Summarize what launching normalized PROFILE does.
Name the runtime it uses and its preset; scope, target, persistence,
model and conversation are shown by their own menu entries."
  (let ((preset (plist-get profile :preset)))
    (format "Launch %s (%s)"
            (if (eq (plist-get profile :reuse) 'new) "independent" "preferred")
            (if (eq preset 'default)
                (format "default: %s" pichat-default-preset)
              preset))))

(defun pichat--launch-menu-view ()
  "Return the launch menu's profile and optional saved-source details."
  (let* ((context (transient-scope))
         (profile (pichat--launch-profile-from-arguments
                   (transient-get-value) context))
         (selection (plist-get (plist-get profile :conversation) :selection))
         (destination (when selection
                        (pichat--launch-destination
                         profile (plist-get context :directory)))))
    (list :context context :profile profile :selection selection
          :owner (car destination) :transport (cdr destination))))

(defun pichat--launch-action-description ()
  "Return the normalized action description for the active launch Transient."
  (let* ((view (pichat--launch-menu-view))
         (context (plist-get view :context))
         (profile (plist-get view :profile))
         (selected (plist-get view :selection)))
    (cond
     ((and selected (eq (plist-get profile :persistence) 'ephemeral))
      "Blocked · ephemeral can't load saved")
     ((and selected
           (not (equal (plist-get selected :transport)
                       (plist-get view :transport))))
      "Blocked · session on another target")
     ((pichat-session-p (pichat--launch-current-chat profile context))
      "Open current chat")
     (t (pichat--launch-profile-description profile)))))

(defun pichat--launch-conversation-description ()
  "Return a short conversation choice suitable for a Transient column."
  (let ((context (transient-scope)))
    (cond
     ((plist-get context :conversation) "Selected saved conversation")
     ((pichat-session-p
       (pichat--launch-current-chat
        (pichat--launch-profile-from-arguments (transient-get-value) context)
        context))
      "Current chat")
     (t "Default conversation"))))

(defun pichat--launch-action-heading ()
  "Show selected saved-session provenance on its own lines above the action."
  (let* ((view (pichat--launch-menu-view))
         (selection (plist-get view :selection)))
    (if (not selection)
        "Action"
      (let ((owner (plist-get view :owner)))
        (format "Selected: %s\nID: %s · owner: %s\nSaved cwd: %s\nAction"
                (truncate-string-to-width
                 (or (plist-get selection :title) "Saved session")
                 30 nil nil "…")
                (truncate-string-to-width
                 (or (plist-get selection :session-id) "unknown")
                 12 nil nil "…")
                (truncate-string-to-width (or (nth 2 owner) "unknown")
                                          15 nil nil "…")
                (pichat-transient-truncate-left
                 (or (plist-get selection :cwd) "unknown") 30))))))

(transient-define-suffix pichat-launch-conversation ()
  "Stage a saved session, or clear the staged selection on a second press."
  (interactive)
  (let ((context (transient-scope))
        (args (transient-args 'pichat-launch)))
    (if (plist-get context :conversation)
        (pichat--launch-stage context args :conversation nil)
      (let* ((profile (pichat--launch-profile-from-arguments args context))
             (transport (cdr (pichat--launch-destination
                              profile (plist-get context :directory))))
             (buffer (plist-get context :origin-buffer))
             (session (and (buffer-live-p buffer)
                           (buffer-local-value 'pichat-chat-session buffer)))
             (source (and (pichat-session-p session)
                          (equal transport (pichat-session-transport session))
                          session)))
        (when (and (eq (pichat-transport-kind transport) 'ssh) (null source))
          (user-error "SSH saved-session selection requires a chat on the same target"))
        (pichat-sessions-select-file
         (lambda (selection)
           (pichat--launch-stage context args :conversation
                                 (list :kind 'saved :selection selection)))
         :session source)))))

(defun pichat--launch-transient-init-value (object)
  "Restore OBJECT's launch switches only in launch mode."
  (let ((context (oref object scope)))
    (oset object value
          (unless (pichat--launch-reconfigure-scope context)
            (copy-sequence (plist-get context :launch-args))))))

(defun pichat--launch-tools-description ()
  "Show selected-option styling for a customized Tools selection."
  (if (plist-get (transient-scope) :tool-selection)
      (propertize "Tools" 'face 'transient-value)
    "Tools"))

(transient-define-suffix pichat-launch-tools ()
  "Customize the selected preset's tools for this new runtime."
  (interactive)
  (let* ((args (transient-args 'pichat-launch))
         (context (transient-scope))
         (profile (pichat--launch-profile-from-arguments args context))
         (preset (plist-get profile :preset))
         (spec (pichat-presets-resolve
                (if (eq preset 'default) pichat-default-preset preset)))
         (directory (plist-get context :directory))
         (target (plist-get profile :target))
         (destination (pichat--launch-destination profile directory))
         (scope (car destination))
         (transport (cdr destination)))
    (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
      (user-error "Tools cannot customize a complete Pi command wrapper"))
    (setq context (plist-put context :tool-discovery
                             (or (plist-get context :tool-discovery)
                                 (pichat-tool-discovery-draft-create))))
    (pichat-tool-picker-open
     spec (plist-get context :tool-selection) (nth 1 scope) transport
     pichat-pi-executable
     (lambda (result)
       (let ((next (copy-sequence context)))
         (unless (eq result :cancel)
           (setq next (plist-put next :tool-selection result))
           ;; Where discovery placed the chosen extension tools, so Save
           ;; preset as… can group them after discovery has moved on.
           (setq next (plist-put next :tool-sources
                                 (and result
                                      (pichat-tool-picker-tool-sources
                                       (plist-get result :extensions)
                                       (plist-get context :tool-discovery)))))
           (setq next (plist-put next :tool-target
                                 (and result (list directory
                                                   (plist-get profile :scope)
                                                   target)))))
         (setq next (plist-put next :launch-args args))
         (transient-setup 'pichat-launch nil nil :scope next)))
     (and (stringp (plist-get profile :model)) (plist-get profile :model))
     (plist-get context :tool-discovery)
     ;; The preset's and the added extensions' tools are offered too;
     ;; changing them invalidates discovery.
     (pichat-presets-load-extensions spec (plist-get profile :extensions)))))

(defun pichat--launch-discovery-context (args context)
  "Return the discovery probe context for launcher ARGS and CONTEXT.
It follows the launch's destination, preset and model, as the Tools
picker's probe does, but loads no added extensions: it shows what Pi
discovers by itself.  Signal when discovery is unavailable there."
  (let* ((profile (pichat--launch-profile-from-arguments args context))
         (preset (plist-get profile :preset))
         (spec (pichat-presets-resolve
                (if (eq preset 'default) pichat-default-preset preset)))
         (destination (pichat--launch-destination profile (plist-get context :directory)))
         (transport (cdr destination))
         (model (plist-get profile :model)))
    (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
      (user-error "Discovery cannot use a complete Pi command wrapper"))
    (cdr (pichat-tool-picker-discovery-context
          spec (nth 1 (car destination)) transport pichat-pi-executable
          (and (stringp model) model)))))

(defun pichat--launch-extensions-description ()
  "Describe the launcher's Extensions entry with its checked count."
  (let* ((context (or (pichat--launch-reconfigure-scope) (transient-scope)))
         (count (length (pichat-launch-extensions-checked
                         (plist-get context :extensions)))))
    (if (zerop count) "Extensions →"
      (concat "Extensions "
              (propertize (format "(%d added)" count) 'face 'transient-value)
              " →"))))

(transient-define-suffix pichat-launch-extensions ()
  "Choose extensions added for this launch.
Checked extensions make the launch use an independent runtime."
  (interactive)
  (let* ((args (transient-args 'pichat-launch))
         (context (transient-scope)))
    (setq context (plist-put context :tool-discovery
                             (or (plist-get context :tool-discovery)
                                 (pichat-tool-discovery-draft-create))))
    (pichat-launch-extensions-open
     (plist-get context :extensions)
     (plist-get context :tool-discovery)
     (lambda () (pichat--launch-discovery-context args context))
     (lambda (result)
       (let ((next (copy-sequence context)))
         (unless (eq result :cancel)
           (setq next (plist-put next :extensions result)))
         (transient-setup 'pichat-launch nil nil
                          :scope (plist-put next :launch-args args)))))))

(defvar pichat--launch-model-request nil
  "Token owning the launcher's pending asynchronous model listing.
Opening another launcher or making another request makes older
callbacks stale, so they cannot reopen or change a launch draft.")

(defun pichat--launch-model-label (profile)
  "Return a short label for normalized PROFILE's model choice."
  (let ((model (plist-get profile :model)))
    (cond ((stringp model) model)
          ((eq model 'prompt) "choose when launching")
          (t "Pi default"))))

(defun pichat--launch-model-description ()
  "Describe the launcher's model, highlighting a staged override."
  (let* ((context (transient-scope))
         (profile (ignore-errors
                    (pichat--launch-profile-from-arguments
                     (transient-get-value) context))))
    (concat "Model "
            (propertize (if profile (pichat--launch-model-label profile) "?")
                        'face (if (plist-get context :model)
                                  'transient-value
                                'transient-inactive-value)))))

(defun pichat--launch-stage (context args &rest properties)
  "Reopen the launcher on a copy of CONTEXT with ARGS and PROPERTIES."
  (let ((next (copy-sequence context)))
    (while properties
      (setq next (plist-put next (pop properties) (pop properties))))
    (transient-setup 'pichat-launch nil nil
                     :scope (plist-put next :launch-args args))))

(defun pichat--launch-select-model (context args profile)
  "List models for PROFILE's destination, then stage one in CONTEXT.
ARGS are the launcher arguments to restore.  Cancelling the prompt returns
to the unchanged launcher; a superseded listing is ignored."
  (pcase-let ((`(,scope . ,transport)
               (pichat--launch-destination profile (plist-get context :directory))))
    (pichat--launch-read-model-async
     (nth 1 scope) transport
     "Model for this launch (select or enter provider/model): "
     (lambda (model)
       (if model
           (pichat--launch-stage context args :model model)
         (pichat--launch-stage context args))))))

(defun pichat--launch-read-model-async (directory transport prompt callback)
  "Read a model at DIRECTORY and TRANSPORT, then call CALLBACK.
Prompt with PROMPT.  Cancellation returns nil; a stale listing is ignored."
  (let ((token (make-symbol "pichat-launch-model")))
    (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
      (user-error
       "Run-local PiChat models are not supported with a local `pichat-rpc-command'"))
    (setq pichat--launch-model-request token)
    (pichat--list-models-async
     nil
     (lambda (models)
       (run-at-time
        0 nil
        (lambda ()
          (when (eq token pichat--launch-model-request)
            (setq pichat--launch-model-request nil)
            (let ((model
                   (condition-case err
                       (pichat--read-model-table-choice prompt models t)
                     (quit nil)
                     (error (message "PiChat model choice rejected: %s"
                                     (error-message-string err))
                            nil))))
              (funcall callback model))))))
     directory transport)))

(transient-define-suffix pichat-launch-model ()
  "Toggle this launch's model override without changing Pi's global default.
Without an override, list models and stage the chosen one for this launch
only.  With an override, clear it so the launch follows the preset's model
policy (its model, or Pi's default) again."
  (interactive)
  (let* ((args (transient-args 'pichat-launch))
         (context (transient-scope)))
    (if (plist-get context :model)
        (pichat--launch-stage context args :model nil)
      (pichat--launch-select-model
       context args (pichat--launch-profile-from-arguments args context)))))

(defun pichat--launch-preset-tool-groups (groups names all sources)
  "Return the preset tool groups that save extension tool NAMES.
GROUPS are the source preset's tool groups.  ALL lists the sources whose
future tools are included: each becomes (SOURCE . :all), and its tools
are not listed by name.  SOURCES maps the names chosen in Tools to the
group source discovery attributed them to (see
`pichat-tool-picker-tool-sources').  A name in one of GROUPS keeps that
group; any other goes to its SOURCES group.  The source preset's groups
come first, in their order and with their names first, then new groups
in the order of NAMES; empty groups are dropped.  Signal when a name has
no known source."
  (let* ((source-of
          (lambda (name)
            (or (car (cl-find-if (lambda (group) (and (listp (cdr group))
                                                       (member name (cdr group))))
                                 groups))
                (cdr (assoc name sources)))))
         (missing (cl-remove-if source-of names)))
    (when missing
      (user-error "Extension tools without a known extension cannot be saved in a preset group (Unattributed in Tools): %s"
                  (string-join missing ", ")))
    (delq nil
          (mapcar
           (lambda (source)
             (if (member source all)
                 (cons (copy-sequence source) :all)
               (let* ((own (cdr (assoc source groups)))
                      (kept (cl-remove-if-not
                             (lambda (name) (equal source (funcall source-of name)))
                             (cl-remove-duplicates
                              (append (and (listp own)
                                           (cl-remove-if-not (lambda (name) (member name names))
                                                             own))
                                      names)
                              :test #'equal :from-end t))))
                 (when kept
                   (cons (copy-sequence source) (copy-sequence kept))))))
           (cl-remove-duplicates
            (append (mapcar #'car groups) (mapcar source-of names) all)
            :test #'equal :from-end t)))))

(defun pichat--launch-preset-extension-spec (spec)
  "Return launcher-added extension SPEC as a preset's :extensions writes it.
A bare word such as `myext' is a valid added extension (a path relative
to the runtime's directory), but a preset refuses it as an old-style
tool name; it is saved as the equivalent `./myext'."
  (if (pichat-presets--old-extension-name-p spec) (concat "./" spec) spec))

(defun pichat--launch-preset-definition (profile context name)
  "Return the definition to save as NAME from PROFILE and launcher CONTEXT.
Capture the effective built-in, extension, Emacs-defined and MCP tools, the
extensions to load (the source preset's own, then the checked added ones),
the prompt sources and the model policy.  Extension tools keep the source
preset's groups; others are grouped by the source Tools found them under
\(CONTEXT's :tool-sources), and groups with \"Include future tools\" on
are saved as (SOURCE . :all).  Shared `pichat-append-system-prompt' text,
unchecked added extensions, targets, scope, persistence and conversation
choices are not part of a preset."
  (let* ((preset (plist-get profile :preset))
         (source (if (eq preset 'default) pichat-default-preset preset))
         (definition (or (pichat-get-preset source)
                         (user-error "Unknown PiChat preset: %S" source)))
         (tools (plist-get context :tool-selection))
         (selection (pichat-tool-selection-resolve
                     (pichat-presets-resolve source) tools))
         (own (plist-get definition :extensions))
         (added (cl-remove-if (lambda (spec) (member spec own))
                              (plist-get profile :extensions)))
         (renamed (mapcar (lambda (spec)
                            (cons spec (pichat--launch-preset-extension-spec spec)))
                          added))
         (rename (lambda (spec) (or (cdr (assoc spec renamed)) spec)))
         (model (plist-get profile :model)))
    (unless (or (stringp model) (eq model 'default))
      (user-error "Choose a concrete model with m first; a choice at launch cannot be saved"))
    (append
     (list :description
           (if (and (eq source name) (not tools) (not added))
               (plist-get definition :description)
             (format "Saved from %s%s%s" source
                     (if tools " with customized tools" "")
                     (cond ((not added) "")
                           (tools " and added extensions")
                           (t " with added extensions")))))
     (if selection
         (append
          (list :tools
                (append
                 (copy-sequence (plist-get selection :builtins))
                 (mapcar (lambda (group)
                           (cons (funcall rename (car group)) (cdr group)))
                         (pichat--launch-preset-tool-groups
                          (pichat-presets-tool-groups (plist-get definition :tools))
                          (plist-get selection :extensions)
                          (plist-get selection :all)
                          (and tools (plist-get context :tool-sources))))))
          (when-let* ((names (plist-get selection :emacs)))
            (list :emacs-tools (copy-sequence names)))
          (when-let* ((pairs (plist-get selection :mcp)))
            (list :mcp (copy-tree pairs))))
       (list :tools :default))
     (when-let* ((specs (cl-remove-duplicates
                         (append own (mapcar #'cdr renamed))
                         :test #'equal :from-end t)))
       (list :extensions (copy-tree specs)))
     (when-let* ((source (plist-get definition :system-prompt)))
       (list :system-prompt (copy-tree source)))
     (when-let* ((source (plist-get definition :append-system-prompt)))
       (list :append-system-prompt (copy-tree source)))
     (list :model (if (stringp model) (copy-sequence model) 'default)))))

(transient-define-suffix pichat-launch-save-preset ()
  "Save the selected preset, Tools, checked extensions and model as a preset.
The definition is written to `custom-file' and selected in the launcher;
nothing is launched, and other launch choices remain unsaved.  The saved
preset loads the checked added extensions itself, so they are unchecked
in the launcher (and stay listed under Added)."
  (interactive)
  (let* ((args (transient-args 'pichat-launch))
         (context (copy-sequence (transient-scope)))
         name file)
    (condition-case err
        (let* ((profile (pichat--launch-profile-from-arguments args context))
               ;; Reject unsaveable drafts before asking for a name.
               (_ (pichat--launch-preset-definition profile context nil)))
          (setq name (pichat-presets-read-name (read-string "Preset name: ")))
          (when (and (pichat-presets-defined-p name)
                     (not (yes-or-no-p (format "Replace preset %s? " name))))
            (user-error "Preset %s not replaced" name))
          (setq file (pichat-presets-save-definition
                      name (pichat--launch-preset-definition profile context name))))
      (quit (message "Preset not saved"))
      (error (message "Preset not saved: %s" (error-message-string err))))
    (if (not file)
        (pichat--launch-stage context args)
      (pichat--launch-stage
       context
       (cons (format "--preset=%s" name)
             (cl-remove-if (lambda (arg) (string-prefix-p "--preset=" arg)) args))
       :tool-selection nil :tool-sources nil :tool-target nil :model nil
       :extensions (mapcar (lambda (entry) (cons (car entry) nil))
                           (plist-get context :extensions)))
      (message "Saved PiChat preset %s to %s" name (abbreviate-file-name file)))))

(transient-define-suffix pichat-launch-execute (arguments context)
  "Execute the active launcher action from ARGUMENTS and CONTEXT."
  (interactive
   (list (transient-args 'pichat-launch)
         (transient-scope)))
  (if-let* ((scope (pichat--launch-reconfigure-scope context)))
      (pichat--reconfigure-execute scope)
    (pichat--launch-execute-new arguments context)))

(defun pichat--launch-execute-new (arguments context)
  "Open or launch a runtime per launcher ARGUMENTS and CONTEXT."
  (let ((profile (pichat--launch-profile-from-arguments arguments context)))
    (when (and (plist-get profile :tools)
               (not (equal (plist-get context :tool-target)
                           (list (plist-get context :directory)
                                 (plist-get profile :scope)
                                 (plist-get profile :target)))))
      (user-error "Tools were selected for another target or scope; reopen x Tools"))
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
    (let ((current-chat (pichat--launch-current-chat profile context)))
      (if (pichat-session-p current-chat)
          (progn
            (setq pichat-current-session current-chat)
            (funcall (plist-get profile :display-function) current-chat)
            current-chat)
        (when (stringp current-chat)
          (message "PiChat: current chat unavailable (%s); using preferred launch"
                   current-chat))
        (pichat--open-launch-profile profile (plist-get context :directory))))))

(defun pichat--reconfigure-action-description ()
  "Describe the restart, or no-op, that the current reconfigure draft makes.
A restart keeps the conversation; `pichat--reconfigure-action-heading'
says when it does not, and what blocks it."
  (let* ((scope (pichat--launch-reconfigure-scope))
         (base (plist-get scope :base))
         (draft (plist-get scope :draft)))
    (if (not (pichat-reconfigure-effective-change-p base draft))
        "No changes · keep runtime"
      (let ((model-change (not (equal (pichat-reconfigure-effective-model base)
                                      (pichat-reconfigure-effective-model draft)))))
        (if (and model-change
                 (not (pichat-reconfigure-effective-change-p base draft t)))
            "Restart · new model"
          (concat (pichat--reconfigure-startup-change-description base draft)
                  (when model-change " + model")))))))

(defun pichat--reconfigure-startup-change-description (base draft)
  "Describe changes to BASE's preset, Tools or extensions in DRAFT."
  (format "Restart · %s"
          (if (equal (plist-get base :preset-spec) (plist-get draft :preset-spec))
              (if (equal (plist-get base :extensions) (plist-get draft :extensions))
                  "new tools"
                (if (equal (plist-get base :tool-selection) (plist-get draft :tool-selection))
                    "new extensions"
                  "new tools and extensions"))
            (let ((previous (plist-get (plist-get base :preset-spec) :name))
                  (selected (plist-get (plist-get draft :preset-spec) :name)))
              (if (eq previous selected)
                  (format "new %s definition" selected)
                (format "%s → %s" previous selected))))))

(defun pichat--reconfigure-action-heading ()
  "Head the action with what blocks the restart or what it starts afresh."
  (let ((scope (pichat--launch-reconfigure-scope)))
    (pichat-transient-fill
     (cond
      ((pichat--reconfigure-action-inapt-p)
       (format "Blocked: %s" (car (pichat--reconfigure-blockers scope))))
      ((and (plist-get scope :empty-unwritten)
            (pichat-reconfigure-effective-change-p
             (plist-get scope :base) (plist-get scope :draft)))
       "Action\nNew empty Pi session; keep chat and draft")
      (t "Action")))))

(defun pichat--reconfigure-blockers (scope)
  "Return what blocks the restart of reconfiguration SCOPE's draft.
A draft whose preset includes future tools not yet discovered is blocked
first (see `pichat--reconfigure-expand-draft'), then preflight blockers."
  (append (when (plist-get (plist-get (plist-get scope :draft) :tool-selection)
                           :unexpanded)
            (list (or (plist-get scope :expansion)
                      "Included future tools are not discovered yet")))
          (plist-get scope :blockers)))

(defun pichat--reconfigure-action-inapt-p ()
  "Return non-nil if a changed draft has preflight blockers."
  (let ((scope (pichat--launch-reconfigure-scope)))
    (and (pichat--reconfigure-blockers scope)
         (pichat-reconfigure-effective-change-p
          (plist-get scope :base) (plist-get scope :draft)))))

(defun pichat--reconfigure-expand-draft (scope)
  "Discover future tools of SCOPE's drafted preset, then update the draft.
Only a draft whose Tools are the preset's unexpanded baseline is probed,
with the runtime's directory, target, model and the extensions the
replacement would load.  Until the probe finishes, or when it fails,
the restart is blocked with the reason under :expansion.  A later draft
or a changed runtime ignores the result."
  (when-let* ((cancel (plist-get scope :expansion-cancel))) (funcall cancel))
  (plist-put scope :expansion-cancel nil)
  (plist-put scope :expansion nil)
  (let* ((draft (plist-get scope :draft))
         (spec (plist-get draft :preset-spec))
         (origin (plist-get scope :origin))
         (session (plist-get origin :session)))
    (when (plist-get (plist-get draft :tool-selection) :unexpanded)
      (plist-put scope :expansion "Discovering included future tools…")
      (plist-put
       scope :expansion-cancel
       (pichat--expand-preset-all
        spec (pichat-session-emacs-cwd session) (pichat-session-transport session)
        (pichat-reconfigure-effective-model draft)
        (pichat-presets-load-extensions spec (plist-get draft :extensions))
        (lambda (expanded error)
          (when (and (eq draft (plist-get scope :draft))
                     (pichat-reconfigure-origin-current-p origin))
            (plist-put scope :expansion-cancel nil)
            (if error
                (plist-put scope :expansion (format "Included future tools: %s" error))
              (plist-put scope :expansion nil)
              (plist-put scope :draft
                         (plist-put (plist-put (copy-sequence draft) :preset-spec expanded)
                                    :tool-selection (pichat-tool-selection-resolve expanded))))
            (pichat--reconfigure-refresh-visible-menu scope))))))))

(defun pichat--reconfigure-refresh-visible-menu (scope)
  "Redraw only the visible launcher that owns reconfigure SCOPE."
  (when (and (bound-and-true-p transient--prefix)
             (eq (oref transient--prefix command) 'pichat-launch))
    (let ((context (oref transient--prefix scope)))
      (when (eq scope (pichat--launch-reconfigure-scope context))
        (transient-setup 'pichat-launch nil nil :scope context)))))

(defun pichat--reconfigure-request-menu-preflight (scope)
  "Refresh bounded preflight blockers for exact menu SCOPE."
  (let ((origin (plist-get scope :origin))
        (token (plist-get scope :menu-token)))
    (pichat-reconfigure-request-preflight
     origin
     (lambda (blockers result)
       (when (eq token (plist-get scope :menu-token))
         (when-let* ((model (pichat-reconfigure--model-reference
                             (plist-get (plist-get result :state) :model))))
           ;; Refresh the passive fallback without discarding explicit
           ;; choices or invalidating an in-flight Tools expansion.
           (setf (plist-get (plist-get scope :base) :model) model
                 (plist-get (plist-get scope :draft) :model) model))
         (plist-put scope :blockers blockers)
         (plist-put scope :empty-unwritten
                    (and (null blockers)
                         (eq (plist-get result :source-kind) 'unwritten)))
         (pichat--reconfigure-refresh-visible-menu scope))))))

(defun pichat--reconfigure-show (scope context)
  "Display the launcher's captured restart SCOPE in CONTEXT."
  (plist-put scope :blockers '("Checking current Pi state…"))
  (plist-put scope :menu-token (make-symbol "pichat-reconfigure-preflight"))
  (transient-setup 'pichat-launch nil nil :scope context)
  (pichat--reconfigure-request-menu-preflight scope))

(transient-define-suffix pichat-launch-reconfigure ()
  "Toggle the launcher between its launch and restart drafts."
  (interactive)
  (let ((context (copy-sequence (transient-scope))))
    (if (pichat--launch-reconfigure-scope context)
        (transient-setup 'pichat-launch nil nil
                         :scope (plist-put context :mode 'launch))
      (when-let* ((reason (pichat--launch-reconfigure-blocker)))
        (user-error "%s" reason))
      (let* ((session (pichat--launch-origin-runtime context))
             (operation (pichat-session-restart-operation session)))
        (cond
         ((memq (plist-get operation :phase) '(failed left-stopped))
          (transient-setup 'pichat-reconfigure-recovery nil nil
                           :scope (list :session session)))
         (operation (user-error "A runtime restart is already in progress"))
         (t
          (let ((scope (or (plist-get context :reconfigure)
                           (pichat--launch-capture-reconfigure-scope session))))
            (unless (pichat-reconfigure-origin-current-p (plist-get scope :origin))
              (user-error "Runtime changed; reopen the launcher"))
            (setf (plist-get context :mode) 'reconfigure
                  (plist-get context :launch-args) (transient-args 'pichat-launch)
                  (plist-get context :reconfigure) scope)
            (pichat--reconfigure-show scope context))))))))

(defun pichat--launch-capture-reconfigure-scope (session)
  "Build the launcher's separate restart draft from SESSION's captured state."
  (let ((base (pichat-reconfigure-captured-configuration session)))
    (list :origin (pichat-reconfigure-capture-origin session)
          :base base :draft (copy-tree base t)
          ;; The picker also retains unchecked specs; only checked specs
          ;; belong to the resolved replacement configuration.
          :extensions (mapcar (lambda (spec) (cons spec t))
                              (plist-get base :extensions)))))

(defun pichat--reconfigure-launch-preset-description ()
  "Describe the resolved restart preset without consulting the registry."
  (let* ((draft (plist-get (pichat--launch-reconfigure-scope) :draft))
         (name (plist-get (plist-get draft :preset-spec) :name)))
    (format "Preset %s" (propertize (symbol-name name) 'face 'transient-value))))

(defun pichat--reconfigure-launch-tools-description ()
  "Highlight Tools when customized relative to the drafted preset."
  (let* ((draft (plist-get (pichat--launch-reconfigure-scope) :draft))
         (spec (plist-get draft :preset-spec)))
    (if (equal (plist-get draft :tool-selection) (pichat-tool-selection-resolve spec))
        "Tools"
      (propertize "Tools" 'face 'transient-value))))

(defun pichat--reconfigure-launch-model-description ()
  "Show the effective restart model, highlighting an explicit choice."
  (let ((draft (plist-get (pichat--launch-reconfigure-scope) :draft)))
    (concat "Model "
            (propertize (or (pichat-reconfigure-effective-model draft) "current")
                        'face (if (or (plist-get draft :model-override)
                                      (plist-get draft :preset-model))
                                  'transient-value 'transient-inactive-value)))))

(transient-define-suffix pichat-reconfigure-model ()
  "Stage or clear a model override in the reconfigure draft."
  (interactive)
  (let* ((context (transient-scope))
         (scope (pichat--launch-reconfigure-scope context))
         (origin (plist-get scope :origin))
         (session (plist-get origin :session)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (cl-labels ((stage (model)
                  (when (pichat-reconfigure-origin-current-p origin)
                    (plist-put scope :draft
                               (plist-put (copy-sequence (plist-get scope :draft))
                                          :model-override model))
                    (pichat--reconfigure-expand-draft scope)
                    (pichat--reconfigure-show scope context))))
      (if (plist-get (plist-get scope :draft) :model-override)
          (stage nil)
        (pichat--launch-read-model-async
         (pichat-session-emacs-cwd session) (pichat-session-transport session)
         "Model for this restart (select or enter provider/model): " #'stage)))))

(transient-define-suffix pichat-reconfigure-extensions ()
  "Edit the reconfigure draft's added extensions."
  (interactive)
  (let* ((context (transient-scope))
         (scope (pichat--launch-reconfigure-scope context))
         (origin (plist-get scope :origin))
         (session (plist-get origin :session))
         (transport (pichat-session-transport session))
         (draft (plist-get scope :draft)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (plist-put scope :tool-discovery
               (or (plist-get scope :tool-discovery) (pichat-tool-discovery-draft-create)))
    (pichat-launch-extensions-open
     (plist-get scope :extensions) (plist-get scope :tool-discovery)
     (lambda ()
       (when (and pichat-rpc-command (eq (pichat-transport-kind transport) 'local))
         (user-error "Discovery cannot use a complete Pi command wrapper"))
       (cdr (pichat-tool-picker-discovery-context
             (plist-get draft :preset-spec) (pichat-session-emacs-cwd session)
             transport pichat-pi-executable (pichat-reconfigure-effective-model draft))))
     (lambda (result)
       (when (pichat-reconfigure-origin-current-p origin)
         (unless (eq result :cancel)
           (let* ((current (plist-get scope :draft))
                  (checked (pichat-launch-extensions-checked result)))
             (unless (equal checked (plist-get current :extensions))
               (plist-put scope :draft
                          (pichat-reconfigure-select-extensions current checked))
               (pichat--reconfigure-expand-draft scope))
             (plist-put scope :extensions result)))
         (pichat--reconfigure-show scope context))))))

(transient-define-suffix pichat-reconfigure-preset ()
  "Select a current preset definition for this runtime restart."
  (interactive)
  (let* ((context (transient-scope))
         (scope (pichat--launch-reconfigure-scope context))
         (origin (plist-get scope :origin))
         (draft (plist-get scope :draft))
         (name (intern
                (pichat--read-configuration-preset
                 "Restart preset: "
                 ;; Reconfiguration explicitly selects a current definition,
                 ;; even when its name matches the captured preset.
                 nil
                 (and (not (equal (plist-get draft :tool-selection)
                                  (pichat-tool-selection-resolve
                                   (plist-get draft :preset-spec))))
                      (plist-get draft :tool-selection))))))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (plist-put scope :draft (pichat-reconfigure-select-preset draft name))
    ;; Its future tools, if any, are discovered before it can restart.
    (pichat--reconfigure-expand-draft scope)
    (pichat--reconfigure-show scope context)))

(transient-define-suffix pichat-reconfigure-tools ()
  "Choose eligible Tools against this runtime's captured preset draft."
  (interactive)
  (let* ((context (transient-scope))
         (scope (pichat--launch-reconfigure-scope context))
         (origin (plist-get scope :origin))
         (session (plist-get origin :session))
         (draft (plist-get scope :draft)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (setq scope (plist-put scope :tool-discovery
                           (or (plist-get scope :tool-discovery)
                               (pichat-tool-discovery-draft-create))))
    (pichat-tool-picker-open
     (plist-get draft :preset-spec) (plist-get draft :tool-selection)
     (pichat-session-emacs-cwd session) (pichat-session-transport session)
     pichat-pi-executable
     (lambda (selection)
       (when (pichat-reconfigure-origin-current-p origin)
         (unless (eq selection :cancel)
           (plist-put scope :draft
                      (pichat-reconfigure-select-tools draft selection)))
         (pichat--reconfigure-show scope context)))
     (pichat-reconfigure-effective-model draft)
     (plist-get scope :tool-discovery)
     (pichat-presets-load-extensions (plist-get draft :preset-spec)
                                     (plist-get draft :extensions)))))

(defun pichat--reconfigure-execute (scope)
  "Confirm and run restart for SCOPE, or do nothing."
  (let* ((origin (plist-get scope :origin))
         (draft (plist-get scope :draft))
         (base (plist-get scope :base)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (if (not (pichat-reconfigure-effective-change-p base draft))
        (message "PiChat runtime unchanged")
      (when-let* ((blockers (pichat--reconfigure-blockers scope)))
        (user-error "%s" (string-join blockers "; ")))
      (when (yes-or-no-p "Restart runtime? ")
        (pichat-reconfigure-restart
         origin draft
         (lambda (success reason)
           (message "PiChat runtime %s%s"
                    (if success "reconfigured" "restart failed")
                    (if reason (format ": %s" reason) ""))))))))

(defun pichat--reconfigure-recovery-run (choice)
  "Execute the explicitly selected failed-runtime recovery CHOICE."
  (let ((session (plist-get (transient-scope) :session)))
    (pichat-reconfigure-recover
     session choice
     (lambda (success reason)
       (message "PiChat runtime %s%s"
                (if success "recovered" "recovery failed")
                (if reason (format ": %s" reason) ""))))))

(transient-define-suffix pichat-reconfigure-retry ()
  "Retry the requested captured configuration."
  (interactive)
  (pichat--reconfigure-recovery-run 'retry))

(transient-define-suffix pichat-reconfigure-restore ()
  "Restore the previous captured configuration."
  (interactive)
  (pichat--reconfigure-recovery-run 'restore))

(transient-define-suffix pichat-reconfigure-leave-stopped-action ()
  "Keep the failed runtime and readable last-synchronized snapshot stopped."
  (interactive)
  (pichat-reconfigure-leave-stopped (plist-get (transient-scope) :session))
  (message "PiChat runtime left stopped; conversation snapshot retained"))

(defun pichat--reconfigure-recovery-description ()
  "Describe the failure retained with the current runtime."
  (let* ((session (plist-get (transient-scope) :session))
         (operation (pichat-session-restart-operation session))
         (reason (plist-get operation :failure)))
    (pichat-transient-fill
     (format "Restart failed: %s\nSnapshot retained%s"
             (truncate-string-to-width (or reason "unknown failure")
                                       100 nil nil "…")
             (if (plist-get operation :empty-unwritten)
                 "\nRecovery starts a new Pi session" "")))))

(transient-define-prefix pichat-reconfigure-recovery (&optional scope)
  "Recover a failed runtime, retaining a saved source when available."
  [:description pichat--reconfigure-recovery-description
   ("r" "Retry requested" pichat-reconfigure-retry)
   ("o" "Restore previous" pichat-reconfigure-restore)
   ("q" "Leave stopped" pichat-reconfigure-leave-stopped-action)])

;;;###autoload (autoload 'pichat-launch "pichat" nil t)
(transient-define-prefix pichat-launch (&optional context)
  "Launch a PiChat runtime or reconfigure the runtime owning this chat."
  :init-value #'pichat--launch-transient-init-value
  [["Scope"
    ("g" "Global" "--global" :inapt-if pichat--launch-reconfigure-p)]
   ["Runtime"
    ("n" "Independent runtime" "--new" :inapt-if pichat--launch-reconfigure-p)
    ("t" "Target" "--target=" :inapt-if pichat--launch-reconfigure-p
     :choices pichat--launch-target-choices)]
   ["Persistence"
    ("e" "Ephemeral" "--ephemeral" :inapt-if pichat--launch-reconfigure-p)]]
  [["Conversation"
    ("s" pichat-launch-conversation :inapt-if pichat--launch-reconfigure-p
     :description pichat--launch-conversation-description)
    ("r" pichat-launch-reconfigure
     :description pichat--launch-reconfigure-description
     :inapt-if pichat--launch-reconfigure-blocker)]
   ["Configuration"
    ("p" "Preset" "--preset=" :choices pichat--launch-preset-choices
     :reader pichat--launch-read-preset :if-not pichat--launch-reconfigure-p)
    ("p" pichat-reconfigure-preset :if pichat--launch-reconfigure-p
     :description pichat--reconfigure-launch-preset-description)
    ("m" pichat-launch-model :if-not pichat--launch-reconfigure-p
     :description pichat--launch-model-description)
    ("m" pichat-reconfigure-model :if pichat--launch-reconfigure-p
     :description pichat--reconfigure-launch-model-description)
    ("x" pichat-launch-tools :if-not pichat--launch-reconfigure-p
     :description pichat--launch-tools-description)
    ("x" pichat-reconfigure-tools :if pichat--launch-reconfigure-p
     :description pichat--reconfigure-launch-tools-description)
    ("l" pichat-launch-extensions :if-not pichat--launch-reconfigure-p
     :description pichat--launch-extensions-description)
    ("l" pichat-reconfigure-extensions :if pichat--launch-reconfigure-p
     :description pichat--launch-extensions-description)]]
  [["Action" :description pichat--launch-reconfigure-action-heading
    ("c" "Save preset as…" pichat-launch-save-preset
     :inapt-if pichat--launch-reconfigure-p)
    ("RET" pichat-launch-execute
     :description pichat--launch-reconfigure-action-description
     :inapt-if pichat--launch-reconfigure-action-inapt-p)]]
  [:hide (lambda () t)
   ("<return>" pichat-launch-execute :inapt-if pichat--launch-reconfigure-action-inapt-p)]
  (interactive)
  (setq pichat--launch-model-request nil)
  (transient-setup 'pichat-launch nil nil
                   :scope (or context (pichat--make-launch-context))))

(autoload 'pichat-job-definitions "pichat-job-definition-ui" "Discover authored job files without execution." t)
(autoload 'pichat-jobs "pichat-jobs" "Inspect jobs and attempts." t)
(autoload 'pichat-job-new "pichat-jobs" "Compose a manual job without launching." t)

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
