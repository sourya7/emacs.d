;;; pichat.el --- Emacs frontend for the Pi coding agent -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat is an Emacs frontend for Pi's JSONL RPC mode.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'transient)
(require 'pichat-transport)
(require 'pichat-pi-environment)
(require 'pichat-session)
(require 'pichat-backend)
(require 'pichat-events)
(require 'pichat-path)
(require 'pichat-rpc)
(require 'pichat-reconfigure)
(require 'pichat-tool-picker)
(require 'pichat-presets)
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
  "Return validated high-level launch PROFILE with explicit defaults."
  (let* ((backend (or (plist-get profile :backend) 'pi))
         (scope (or (plist-get profile :scope) 'current))
         (target (or (plist-get profile :target) 'inferred))
         (persistence (or (plist-get profile :persistence) 'persistent))
         (preset (or (plist-get profile :preset) 'default))
         (tools (plist-get profile :tools))
         (model (or (plist-get profile :model) 'default))
         (explicit-reuse-p (plist-member profile :reuse))
         (reuse (or (plist-get profile :reuse)
                    (if (or (eq persistence 'ephemeral)
                            (not (eq preset 'default))
                            tools
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
    (unless (or (eq preset 'default) (assq preset pichat-presets))
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
                (eq (plist-get conversation :kind) 'new)
                (and (eq (plist-get conversation :kind) 'saved)
                     (listp (plist-get conversation :selection))))
      (user-error "Invalid PiChat launch conversation selection"))
    (when (and conversation (eq reuse 'preferred))
      (user-error "Selected conversations require an independent runtime"))
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
            (when conversation (list :conversation conversation)))))

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
    (pichat-backend-get-state session (lambda (_response _session) nil)))
  session)

(defun pichat--selected-file-key (transport runtime-file)
  "Return a transport-qualified canonical identity for RUNTIME-FILE."
  (let* ((host-file (pichat-transport-runtime-file-name
                     transport runtime-file))
         (canonical (file-truename host-file)))
    (cons (if (eq (pichat-transport-kind transport) 'ssh)
              (pichat-transport-tramp-prefix transport)
            'local)
          (or (file-remote-p canonical 'localname) canonical))))

(defun pichat--selected-file-conflict (key)
  "Return a managed live runtime already writing KEY, if any."
  (cl-find-if
   (lambda (session)
     (let* ((operation (pichat-session-restart-operation session))
            (restarting (memq (plist-get operation :phase)
                             '(preflight stopping starting loading synchronizing)))
            (file (if restarting
                      (plist-get (plist-get operation :origin) :session-file)
                    (pichat-session-session-file session))))
       (and (or restarting (pichat-session-alive-p session))
            file
            (condition-case nil
                (equal key (pichat--selected-file-key
                            (pichat-session-transport session) file))
              (error nil)))))
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
  "Launch PROFILE's saved conversation with exact ownership and no duplicate writer."
  (let* ((selection (plist-get (plist-get profile :conversation) :selection))
         (source (plist-get selection :source-session))
         (target (plist-get profile :target))
         (scope (pichat--resolve-launch-scope
                 (plist-get profile :scope) directory target))
         (transport (pichat-transport-resolve
                     (nth 1 scope) (unless (eq target 'inferred) target)))
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
                       "This saved conversation is hosted by another PiChat runtime: "
                       '((?o "Open existing chat")
                         (?r "Reconfigure existing runtime")
                         (?c "Cancel"))))
            (?o (pichat-chat-open conflict)
                (user-error "Opened existing chat; no new writer was started"))
            (?r (pichat-chat-open conflict)
                (user-error "Open the existing chat's launcher and select r"))
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
                 (list :persistence 'persistent
                       :target (unless (eq target 'inferred) target)
                       :preset (plist-get profile :preset)
                       :tools (plist-get profile :tools)
                       :model (and (stringp (plist-get profile :model))
                                   (plist-get profile :model)))
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

(defun pichat--open-launch-profile (profile &optional directory)
  "Open normalized launch PROFILE relative to optional DIRECTORY.
Return the exact runtime synchronously when its model is already known.
Prompted-model profiles first select a model asynchronously and return nil."
  (let* ((profile (pichat--normalize-launch-profile profile))
         (model (plist-get profile :model)))
    (cond
     ((eq model 'prompt)
      (pichat--select-model-before-launch profile directory)
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
              (list :persistence persistence
                    :preset (plist-get profile :preset)
                    :tools (copy-tree (plist-get profile :tools))
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
        session)))))

;;;###autoload
(defun pichat-start-session (&optional cwd scope launch-options)
  "Start a PiChat RPC session rooted at CWD and return it.
SCOPE, when non-nil, is the immutable (KEY CWD LABEL) owner scope.
LAUNCH-OPTIONS supports `:persistence', `:preset', and an exact run-local
`:model'.  Omitted preset means the configured default."
  (interactive)
  (pichat--maybe-enable-default-bridge)
  (when (plist-member launch-options :execution)
    (user-error "Obsolete :execution option; select a PiChat :preset instead"))
  (let* ((preset-name (let ((choice (plist-get launch-options :preset)))
                        (if (or (null choice) (eq choice 'default))
                            pichat-default-preset choice)))
         (preset-spec (pichat-presets-resolve preset-name))
         (tool-selection (pichat-tool-selection-resolve preset-spec
                                               (plist-get launch-options :tools)))
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
                   :startup-model (plist-get normalized-options :model)
                   :scope-key (nth 0 scope)
                   :owner-scope-key (nth 0 scope)
                   :owner-scope-label (nth 2 scope))))
    (cl-incf pichat--manual-session-counter)
    (setf (pichat-session-scope-label session)
          (format "manual:%s#%d" (pichat--directory-basename cwd)
                  pichat--manual-session-counter))
    (pichat-register-session session scope)
    (pichat-backend-start-session session)
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

(defun pichat--launch-target-choices ()
  "Return target names offered by the launch Transient."
  (append '("inferred" "local")
          (mapcar (lambda (entry) (symbol-name (car entry))) pichat-targets)))

(defun pichat--launch-preset-choices ()
  "Return default policy and registered preset names for the launcher."
  (cons "default" (mapcar (lambda (entry) (symbol-name (car entry)))
                           pichat-presets)))

(defun pichat--launch-read-preset (prompt initial history)
  "Read a named preset or default policy with descriptions."
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (choice)
                 (let ((description
                        (if (equal choice "default")
                            (format "Use configured default (%s)" pichat-default-preset)
                          (plist-get (pichat-get-preset (intern choice))
                                     :description))))
                   (when description (concat "  " description)))))))
    (let ((chosen (completing-read prompt (pichat--launch-preset-choices) nil t
                                   initial history))
          (scope (transient-scope)))
      (when (and (plist-get scope :tool-selection)
                 (not (equal chosen initial)))
        (unless (yes-or-no-p "Discard customized Tools for the new preset? ")
          (user-error "Preset change cancelled"))
        (setf (plist-get scope :tool-selection) nil
              (plist-get scope :tool-target) nil))
      chosen)))

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
                       (or (car (cl-find-if
                                 (lambda (entry)
                                   (string= name (symbol-name (car entry))))
                                 pichat-presets))
                           (and (string= name "default") 'default)
                           (user-error "Unknown PiChat preset: %s" name)))
                   'default))
         (tools (plist-get context :tool-selection))
         (conversation (plist-get context :conversation))
         (independent-p (or (member "--new" arguments)
                            conversation ephemeral-p prompt-p tools
                            (not (eq preset 'default)))))
    (pichat--normalize-launch-profile
     (list :backend 'pi
           :scope (if global-p 'global 'current)
           :target (pichat--launch-target-argument arguments)
           :reuse (if independent-p 'new 'preferred)
           :persistence (if ephemeral-p 'ephemeral 'persistent)
           :preset preset
           :tools tools
           :conversation conversation
           :model (if prompt-p 'prompt 'default)
           :display-function (or (plist-get context :display-function)
                                 #'pichat-chat-open)))))

(defun pichat--launch-profile-description (profile)
  "Summarize launch PROFILE without repeating unchanged defaults."
  (string-join
   (append
    (list "Launch"
          (if (eq (plist-get profile :reuse) 'new)
              "independent" "preferred")
          (let ((preset (plist-get profile :preset)))
            (if (eq preset 'default)
                (format "default (%s)" pichat-default-preset)
              (symbol-name preset))))
    (when (eq (plist-get profile :scope) 'global) '("global"))
    (unless (eq (plist-get profile :target) 'inferred)
      (list (format "target %s" (plist-get profile :target))))
    (when (eq (plist-get profile :persistence) 'ephemeral) '("ephemeral"))
    (when (eq (plist-get profile :model) 'prompt) '("choose model"))
    (pcase (plist-get (plist-get profile :conversation) :kind)
      ('new '("new conversation"))
      ('saved '("saved conversation"))))
   " · "))

(defun pichat--launch-menu-view ()
  "Return the launch menu's profile and optional saved-source details."
  (let* ((context (transient-scope))
         (profile (pichat--launch-profile-from-arguments
                   (transient-get-value) context))
         (selection (plist-get (plist-get profile :conversation) :selection)))
    (list :context context :profile profile :selection selection
          :owner (when selection
                   (pichat--resolve-launch-scope
                    (plist-get profile :scope)
                    (plist-get context :directory)
                    (plist-get profile :target))))))

(defun pichat--launch-action-description ()
  "Return the normalized action description for the active launch Transient."
  (let* ((view (pichat--launch-menu-view))
         (context (plist-get view :context))
         (profile (plist-get view :profile))
         (selected (plist-get view :selection)))
    (cond
     ((and selected (eq (plist-get profile :persistence) 'ephemeral))
      "Blocked · saved conversations require persistent storage")
     ((and selected
           (not (equal (plist-get selected :transport)
                       (pichat-transport-resolve
                        (plist-get context :directory)
                        (unless (eq (plist-get profile :target) 'inferred)
                          (plist-get profile :target))))))
      "Blocked · saved conversation belongs to another target")
     (t (pichat--launch-profile-description profile)))))

(defun pichat--launch-conversation-description ()
  "Return a short conversation choice suitable for a Transient column."
  (pcase (plist-get (plist-get (transient-scope) :conversation) :kind)
    ('new "New conversation")
    ('saved "Selected saved conversation")
    (_ "Default conversation")))

(defun pichat--launch-action-heading ()
  "Show selected saved-session provenance at full width above the action."
  (let* ((view (pichat--launch-menu-view))
         (selection (plist-get view :selection)))
    (if (not selection)
        "Action"
      (let ((owner (plist-get view :owner)))
        (format "Selected: %s · %s\nSaved cwd: %s · owner: %s\nAction"
                (truncate-string-to-width
                 (or (plist-get selection :title) "Saved session")
                 48 nil nil "…")
                (truncate-string-to-width
                 (or (plist-get selection :session-id) "unknown")
                 12 nil nil "…")
                (truncate-string-to-width
                 (or (plist-get selection :cwd) "unknown")
                 55 nil nil "…")
                (truncate-string-to-width (or (nth 2 owner) "unknown")
                                          40 nil nil "…"))))))

(transient-define-suffix pichat-launch-conversation ()
  "Choose a conversation intent without mutating any running runtime."
  (interactive)
  (let* ((context (transient-scope))
         (args (transient-args 'pichat-launch))
         (choice (completing-read
                  "Conversation: "
                  '("Default" "New conversation" "Current conversation…"
                    "Choose saved session…") nil t)))
    (pcase choice
      ("Default"
       (plist-put context :conversation nil)
       (plist-put context :launch-args args)
       (transient-setup 'pichat-launch nil nil :scope context))
      ("New conversation"
       (plist-put context :conversation '(:kind new))
       (plist-put context :launch-args args)
       (transient-setup 'pichat-launch nil nil :scope context))
      ("Current conversation…"
       (let* ((buffer (plist-get context :origin-buffer))
              (session (and (buffer-live-p buffer)
                            (buffer-local-value 'pichat-chat-session buffer))))
         (unless (and (pichat-session-p session)
                      (eq buffer (pichat-session-buffer session)))
           (user-error "Current conversation requires the originating chat"))
         (pcase (car (read-multiple-choice
                      "Normal launch choices will not apply to this conversation: "
                      '((?o "Open existing chat")
                        (?r "Reconfigure this runtime")
                        (?c "Cancel"))))
           (?o (funcall (plist-get context :display-function) session))
           (?r (pichat-launch-reconfigure))
           (_ (transient-setup 'pichat-launch nil nil
                               :scope (plist-put context :launch-args args))))))
      ("Choose saved session…"
       (let* ((profile (pichat--launch-profile-from-arguments args context))
              (directory (plist-get context :directory))
              (target (plist-get profile :target))
              (scope (pichat--resolve-launch-scope
                      (plist-get profile :scope) directory target))
              (transport (pichat-transport-resolve
                          (nth 1 scope) (unless (eq target 'inferred) target)))
              (buffer (plist-get context :origin-buffer))
              (session (and (buffer-live-p buffer)
                            (buffer-local-value 'pichat-chat-session buffer)))
              (source (and session
                           (equal transport (pichat-session-transport session))
                           session)))
         (when (and (eq (pichat-transport-kind transport) 'ssh)
                    (null source))
           (user-error "Select SSH saved sessions from a chat on the same target"))
         (pichat-sessions-select-file
          (lambda (selection)
            (plist-put context :conversation
                       (list :kind 'saved :selection selection))
            (plist-put context :launch-args args)
            (transient-setup 'pichat-launch nil nil :scope context))
          :session source))))))

(defun pichat--launch-transient-init-value (object)
  "Initialize Transient prefix OBJECT with safe launch switches."
  (oset object value (copy-sequence (plist-get (oref object scope) :launch-args))))

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
         (scope (pichat--resolve-launch-scope
                 (plist-get profile :scope) directory target))
         (transport (pichat-transport-resolve
                     (nth 1 scope) (unless (eq target 'inferred) target))))
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
           (setq next (plist-put next :tool-target
                                 (and result (list directory
                                                   (plist-get profile :scope)
                                                   target)))))
         (setq next (plist-put next :launch-args args))
         (transient-setup 'pichat-launch nil nil :scope next)))
     (and (stringp (plist-get profile :model)) (plist-get profile :model))
     (plist-get context :tool-discovery))))

(transient-define-suffix pichat-launch-execute (arguments context)
  "Execute a PiChat launch from Transient ARGUMENTS and CONTEXT."
  (interactive
   (list (transient-args 'pichat-launch)
         (transient-scope)))
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
    (pichat--open-launch-profile profile (plist-get context :directory))))

(defun pichat--reconfigure-menu-description ()
  "Describe the captured runtime and conversation in the reconfigure menu."
  (let* ((origin (plist-get (transient-scope) :origin))
         (session (plist-get origin :session))
         (title (or (pichat-session-name session) "Untitled conversation"))
         (id (or (plist-get origin :session-id) "unknown")))
    (format "Reconfigure · %s (%s)"
            (truncate-string-to-width title 40 nil nil "…")
            (truncate-string-to-width id 10 nil nil "…"))))

(defun pichat--reconfigure-action-description ()
  "Describe restart or no-op status of the current reconfigure draft."
  (let* ((scope (transient-scope))
         (base (plist-get scope :base))
         (draft (plist-get scope :draft))
         (blockers (plist-get scope :blockers)))
    (cond
     ((not (pichat-reconfigure-effective-change-p base draft))
      "No configuration changes · keep runtime")
     (blockers (format "Blocked · %s" (car blockers)))
     (t (format "Restart runtime · %s · %s"
                (if (equal (plist-get base :preset-spec)
                           (plist-get draft :preset-spec))
                    "update tools"
                  (let ((previous (plist-get (plist-get base :preset-spec) :name))
                        (selected (plist-get (plist-get draft :preset-spec) :name)))
                    (if (eq previous selected)
                        (format "%s definition changed" selected)
                      (format "%s → %s" previous selected))))
                (if (plist-get scope :empty-unwritten)
                    "new empty Pi session; keep chat and draft"
                  "keep conversation"))))))

(defun pichat--reconfigure-action-inapt-p ()
  "Return non-nil if a changed draft has preflight blockers."
  (let ((scope (transient-scope)))
    (and (plist-get scope :blockers)
         (pichat-reconfigure-effective-change-p
          (plist-get scope :base) (plist-get scope :draft)))))

(defun pichat--reconfigure-draft-description ()
  "Describe the exact selected preset and Tools draft."
  (let* ((scope (transient-scope))
         (draft (plist-get scope :draft))
         (name (plist-get (plist-get draft :preset-spec) :name)))
    (format "Preset: %s%s" name
            (if (equal (plist-get draft :tool-selection)
                       (plist-get (plist-get scope :base) :tool-selection))
                "" " · Tools customized"))))

(defun pichat--reconfigure-request-menu-preflight (scope)
  "Refresh bounded preflight blockers for exact menu SCOPE."
  (let ((origin (plist-get scope :origin)))
    (pichat-reconfigure-request-preflight
     origin
     (lambda (blockers result)
       (when (eq (plist-get scope :menu-token)
                 (plist-get (transient-scope) :menu-token))
         (plist-put scope :blockers blockers)
         (plist-put scope :empty-unwritten
                    (and (null blockers)
                         (eq (plist-get result :source-kind) 'unwritten)))
         (when (and (boundp 'transient--prefix)
                    transient--prefix
                    (eq (oref transient--prefix command)
                        'pichat-reconfigure-menu))
           (transient-setup 'pichat-reconfigure-menu nil nil :scope scope)))))))

(defun pichat--reconfigure-show (scope)
  "Display reconfiguration Transient for captured SCOPE and refresh blockers."
  (plist-put scope :blockers '("Checking current Pi state…"))
  (plist-put scope :menu-token (make-symbol "pichat-reconfigure-menu"))
  (transient-setup 'pichat-reconfigure-menu nil nil :scope scope)
  (pichat--reconfigure-request-menu-preflight scope))

(transient-define-suffix pichat-launch-reconfigure ()
  "Explicitly reconfigure the runtime owning the original launch chat."
  (interactive)
  (let* ((launch-scope (transient-scope))
         (buffer (plist-get launch-scope :origin-buffer))
         (session (and (buffer-live-p buffer)
                       (buffer-local-value 'pichat-chat-session buffer))))
    (unless (and (pichat-session-p session)
                 (eq buffer (pichat-session-buffer session)))
      (user-error "Reconfiguration requires the originating PiChat chat buffer"))
    (let ((operation (pichat-session-restart-operation session)))
      (if (memq (plist-get operation :phase) '(failed left-stopped))
          (transient-setup 'pichat-reconfigure-recovery nil nil
                           :scope (list :session session :launch-scope launch-scope))
        (when operation
          (user-error "A runtime restart is already in progress"))
        (let ((origin (pichat-reconfigure-capture-origin session))
              (base (pichat-reconfigure-captured-configuration session)))
          (pichat--reconfigure-show
           (list :origin origin :base base :draft (copy-tree base t)
                 :launch-scope launch-scope
                 :launch-args (transient-args 'pichat-launch))))))))

(transient-define-suffix pichat-reconfigure-preset ()
  "Select a current preset definition for this runtime restart."
  (interactive)
  (let* ((scope (transient-scope))
         (origin (plist-get scope :origin))
         (draft (plist-get scope :draft))
         (name (intern (completing-read
                        "Restart preset: " (mapcar (lambda (p) (symbol-name (car p)))
                                                    pichat-presets)
                        nil t))))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (when (and (plist-get draft :tool-selection)
               (not (equal (plist-get draft :tool-selection)
                           (pichat-tool-selection-resolve
                            (plist-get draft :preset-spec))))
               (not (yes-or-no-p "Discard customized Tools? ")))
      (user-error "Preset change cancelled"))
    (plist-put scope :draft (pichat-reconfigure-select-preset draft name))
    (pichat--reconfigure-show scope)))

(transient-define-suffix pichat-reconfigure-tools ()
  "Choose eligible Tools against this runtime's captured preset draft."
  (interactive)
  (let* ((scope (transient-scope))
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
         (pichat--reconfigure-show scope)))
     (let ((model (pichat-session-model session)))
       (when (and (plist-get model :provider) (plist-get model :id))
         (concat (plist-get model :provider) "/" (plist-get model :id))))
     (plist-get scope :tool-discovery))))

(transient-define-suffix pichat-reconfigure-back ()
  "Return to the untouched normal launch draft."
  (interactive)
  (let* ((scope (transient-scope))
         (launch-scope (plist-get scope :launch-scope)))
    (transient-setup 'pichat-launch nil nil
                     :scope (plist-put launch-scope :launch-args
                                       (plist-get scope :launch-args)))))

(transient-define-suffix pichat-reconfigure-execute ()
  "Confirm and run the captured runtime restart, or do nothing."
  (interactive)
  (let* ((scope (transient-scope))
         (origin (plist-get scope :origin))
         (draft (plist-get scope :draft))
         (base (plist-get scope :base)))
    (unless (pichat-reconfigure-origin-current-p origin)
      (user-error "Runtime changed; reopen reconfiguration"))
    (if (not (pichat-reconfigure-effective-change-p base draft))
        (message "PiChat runtime unchanged")
      (when (plist-get scope :blockers)
        (user-error "%s" (string-join (plist-get scope :blockers) "; ")))
      (when (yes-or-no-p
             (format "Restart this runtime with %s? "
                     (plist-get (plist-get draft :preset-spec) :name)))
        (pichat-reconfigure-restart
         origin draft
         (lambda (success reason)
           (message "PiChat runtime %s%s"
                    (if success "reconfigured" "restart failed")
                    (if reason (format ": %s" reason) ""))))))))

(defun pichat--reconfigure-recovery-run (choice)
  "Confirm and execute the failed-runtime recovery CHOICE."
  (let ((session (plist-get (transient-scope) :session)))
    (when (yes-or-no-p
           (pcase choice
             ('retry "Retry this runtime restart? ")
             ('restore "Restore the previous runtime configuration? ")))
      (pichat-reconfigure-recover
       session choice
       (lambda (success reason)
         (message "PiChat runtime %s%s"
                  (if success "recovered" "recovery failed")
                  (if reason (format ": %s" reason) "")))))))

(transient-define-suffix pichat-reconfigure-retry ()
  "Retry the requested captured configuration."
  (interactive)
  (pichat--reconfigure-recovery-run 'retry))

(transient-define-suffix pichat-reconfigure-restore ()
  "Restore the previous captured configuration."
  (interactive)
  (pichat--reconfigure-recovery-run 'restore))

(transient-define-suffix pichat-reconfigure-leave-stopped ()
  "Keep the failed runtime and readable last-synchronized snapshot stopped."
  (interactive)
  (pichat-reconfigure-leave-stopped (plist-get (transient-scope) :session))
  (message "PiChat runtime left stopped; conversation snapshot retained"))

(defun pichat--reconfigure-recovery-description ()
  "Describe the failure retained with the current runtime."
  (let* ((session (plist-get (transient-scope) :session))
         (operation (pichat-session-restart-operation session))
         (reason (plist-get operation :failure)))
    (format "Restart failed · %s · snapshot retained%s"
            (truncate-string-to-width (or reason "unknown failure")
                                      100 nil nil "…")
            (if (plist-get operation :empty-unwritten)
                " · recovery starts a new Pi session" ""))))

(transient-define-prefix pichat-reconfigure-recovery (&optional scope)
  "Recover a failed runtime, retaining a saved source when available."
  [["Failed restart" :description pichat--reconfigure-recovery-description
    ("r" "Retry requested" pichat-reconfigure-retry)
    ("o" "Restore previous" pichat-reconfigure-restore)
    ("q" "Leave stopped" pichat-reconfigure-leave-stopped)]])

(transient-define-prefix pichat-reconfigure-menu (&optional scope)
  "Choose a new preset or Tools for this retained runtime."
  [["Current runtime" :description pichat--reconfigure-menu-description
    ("p" pichat-reconfigure-preset
     :description pichat--reconfigure-draft-description)
    ("x" "Tools" pichat-reconfigure-tools)]
   ["Navigation"
    ("b" "Back to Open / Launch" pichat-reconfigure-back)]]
  [["Action"
    ("RET" pichat-reconfigure-execute
     :description pichat--reconfigure-action-description
     :inapt-if pichat--reconfigure-action-inapt-p)]]
  [:hide (lambda () t)
   ("<return>" pichat-reconfigure-execute
    :inapt-if pichat--reconfigure-action-inapt-p)]
  (interactive)
  (pichat--reconfigure-show scope))

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
    ("e" "Ephemeral" "--ephemeral")]]
  [["Conversation"
    ("s" pichat-launch-conversation
     :description pichat--launch-conversation-description)
    ("r" "Reconfigure this runtime…" pichat-launch-reconfigure
     :inapt-if (lambda ()
              (let ((buffer (plist-get (transient-scope) :origin-buffer)))
                (not (and (buffer-live-p buffer)
                          (buffer-local-value 'pichat-chat-session buffer))))))]
   ["Configuration"
    ("p" "Preset" "--preset=" :choices pichat--launch-preset-choices
     :reader pichat--launch-read-preset)
    ("m" "Choose/enter model" "--model")
    ("x" pichat-launch-tools :description pichat--launch-tools-description)]]
  [["Action" :description pichat--launch-action-heading
    ("RET" pichat-launch-execute
     :description pichat--launch-action-description)]]
  [:hide (lambda () t)
   ("<return>" pichat-launch-execute)]
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
