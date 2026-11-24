;;; pichat-transport.el --- Runtime targets and process transport -*- lexical-binding: t; -*-

;;; Commentary:

;; Structured local and SSH/TRAMP runtime identity, path context, and process
;; startup for PiChat.  This module deliberately does not depend on sessions or
;; chat UI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tramp)

(defgroup pichat nil
  "Emacs frontend for the Pi coding agent."
  :group 'applications)

(defcustom pichat-targets nil
  "Configured PiChat runtime targets.
Each entry has the form (ID :kind KIND ...).  KIND is `local' or `ssh'.  SSH
targets accept :tramp-prefix, :pi-executable, :pi-args, :remote-path,
:runtime-home, :startup-cache-root (a remote-native path), and :path-mappings.
Path mappings are (EMACS-PREFIX . RUNTIME-PREFIX)."
  :type '(repeat (cons (symbol :tag "Target ID") (plist :tag "Properties")))
  :group 'pichat)

(defcustom pichat-project-target-alist nil
  "Local project-prefix to PiChat target associations.
The longest matching normalized project prefix wins."
  :type '(repeat (cons (directory :tag "Project prefix")
                       (symbol :tag "Target ID")))
  :group 'pichat)

(cl-defstruct (pichat-transport
               (:constructor pichat-transport--create))
  id kind label tramp-prefix pi-executable pi-args remote-path
  runtime-home-value startup-cache-root mappings)

(cl-defstruct (pichat-path-context
               (:constructor pichat-path-context--create))
  transport-id mappings strict-p)

(defconst pichat-transport-local
  (pichat-transport--create
   :id 'local :kind 'local :label "local" :pi-executable nil)
  "Implicit local PiChat transport.")

(defun pichat-transport--nonblank-string-p (value)
  "Return non-nil when VALUE is a nonblank string."
  (and (stringp value) (not (string-blank-p value))))

(defun pichat-transport--directory-prefix (path)
  "Return normalized directory prefix PATH without requiring it to exist."
  (file-name-as-directory (expand-file-name path)))

(defun pichat-transport--path-prefix-p (prefix path)
  "Return non-nil when normalized directory PREFIX covers PATH."
  (let ((prefix (directory-file-name
                 (pichat-transport--directory-prefix prefix)))
        (path (directory-file-name (expand-file-name path))))
    (or (equal prefix path)
        (string-prefix-p (file-name-as-directory prefix) path))))

(defun pichat-transport--target-entry (target-id)
  "Return configured entry for TARGET-ID, or nil."
  (cl-find target-id pichat-targets :key #'car :test #'equal))

(defun pichat-transport--copy-mappings (mappings)
  "Validate and copy path MAPPINGS, rejecting reverse ambiguity."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (mapping mappings (nreverse result))
      (unless (and (consp mapping)
                   (pichat-transport--nonblank-string-p (car mapping))
                   (pichat-transport--nonblank-string-p (cdr mapping)))
        (user-error "Invalid PiChat path mapping: %S" mapping))
      (let* ((emacs-prefix
              (directory-file-name (expand-file-name (car mapping))))
             (runtime-prefix (directory-file-name (cdr mapping)))
             (prior (gethash runtime-prefix seen)))
        (when (and prior (not (equal prior emacs-prefix)))
          (user-error "Ambiguous PiChat runtime prefix %s" runtime-prefix))
        (puthash runtime-prefix emacs-prefix seen)
        (push (cons emacs-prefix runtime-prefix) result)))))

(defun pichat-transport--configured (entry)
  "Normalize configured target ENTRY into a transport."
  (let* ((id (car entry))
         (properties (cdr entry))
         (kind (or (plist-get properties :kind) 'ssh))
         (prefix (plist-get properties :tramp-prefix))
         (executable (or (plist-get properties :pi-executable) "pi")))
    (unless (memq kind '(local ssh))
      (user-error "Invalid PiChat target kind for %s: %S" id kind))
    (when (and (eq kind 'ssh)
               (not (and (pichat-transport--nonblank-string-p prefix)
                         (file-remote-p prefix))))
      (user-error "SSH target %s needs a remote :tramp-prefix" id))
    (unless (pichat-transport--nonblank-string-p executable)
      (user-error "Target %s has an invalid Pi executable" id))
    (pichat-transport--create
     :id id :kind kind :label (symbol-name id)
     :tramp-prefix (and prefix (file-remote-p prefix))
     :pi-executable executable
     :pi-args
     (let ((args (plist-get properties :pi-args)))
       (unless (cl-every #'stringp args)
         (user-error "Target %s has invalid :pi-args" id))
       (copy-sequence args))
     :remote-path (copy-tree (plist-get properties :remote-path))
     :runtime-home-value (plist-get properties :runtime-home)
     :startup-cache-root
     (let ((root (plist-get properties :startup-cache-root)))
       (when root
         (unless (and (eq kind 'ssh) (stringp root))
           (user-error "Target %s has an invalid :startup-cache-root" id))
         (copy-sequence root)))
     :mappings (pichat-transport--copy-mappings
                (plist-get properties :path-mappings)))))

(defun pichat-transport--configured-for-remote (directory)
  "Return configured target matching remote DIRECTORY, or nil."
  (let ((remote (file-remote-p directory)))
    (when remote
      (cl-loop for entry in pichat-targets
               for properties = (cdr entry)
               for prefix = (plist-get properties :tramp-prefix)
               when (and prefix (equal remote (file-remote-p prefix)))
               return (pichat-transport--configured entry)))))

(defun pichat-transport--infer-remote (directory)
  "Create a conservative inferred SSH transport for remote DIRECTORY."
  (let* ((prefix (file-remote-p directory))
         (host (file-remote-p directory 'host))
         ;; The complete canonical prefix retains method, user, host, port,
         ;; and hop identity.  It is private and never interpreted as a path.
         (identity (concat "tramp:" prefix)))
    (pichat-transport--create
     :id identity :kind 'ssh :label (or host identity)
     :tramp-prefix prefix :pi-executable "pi"
     :remote-path '(tramp-own-remote-path)
     :mappings (list (cons (concat prefix "/") "/")))))

(defun pichat-transport-project-target (directory)
  "Return configured target ID for local DIRECTORY, or nil."
  (unless (file-remote-p directory)
    (let ((best nil) (best-length -1))
      (dolist (entry pichat-project-target-alist best)
        (let ((prefix (car entry)))
          (when (and (pichat-transport--path-prefix-p prefix directory)
                     (> (length (expand-file-name prefix)) best-length))
            (setq best (cdr entry)
                  best-length (length (expand-file-name prefix)))))))))

(defun pichat-transport-resolve (directory &optional target-id)
  "Resolve DIRECTORY and optional explicit TARGET-ID to a transport."
  (cond
   ((or (eq target-id 'local) (equal target-id "local"))
    pichat-transport-local)
   (target-id
    (if-let* ((entry (pichat-transport--target-entry target-id)))
        (pichat-transport--configured entry)
      (user-error "Unknown PiChat target: %s" target-id)))
   ((file-remote-p directory)
    (or (pichat-transport--configured-for-remote directory)
        (pichat-transport--infer-remote directory)))
   ((pichat-transport-project-target directory)
    (pichat-transport-resolve
     directory (pichat-transport-project-target directory)))
   (t pichat-transport-local)))

(defun pichat-transport-path-context (transport &optional fallback-mappings)
  "Capture immutable path context for TRANSPORT.
FALLBACK-MAPPINGS are used only for the implicit local transport."
  (let* ((local-p (eq (pichat-transport-kind transport) 'local))
         (mappings (or (pichat-transport-mappings transport)
                       (and local-p fallback-mappings))))
    (pichat-path-context--create
     :transport-id (pichat-transport-id transport)
     :mappings (pichat-transport--copy-mappings mappings)
     :strict-p (or (not local-p) (not (null mappings))))))

(defun pichat-transport-runtime-file-name (transport runtime-path)
  "Return an Emacs file name for RUNTIME-PATH through TRANSPORT."
  (if (eq (pichat-transport-kind transport) 'ssh)
      (concat (pichat-transport-tramp-prefix transport)
              (if (string-prefix-p "/" runtime-path) "" "/")
              runtime-path)
    runtime-path))

(defun pichat-transport-runtime-home (transport)
  "Return TRANSPORT's configured or resolved runtime-native home directory."
  (or (pichat-transport-runtime-home-value transport)
      (if (eq (pichat-transport-kind transport) 'ssh)
          (file-local-name
           (expand-file-name
            (concat (pichat-transport-tramp-prefix transport) "~/")))
        (expand-file-name "~"))))

(defun pichat-transport-description (transport)
  "Return a bounded display description for TRANSPORT."
  (format "%s (%s)" (pichat-transport-label transport)
          (pichat-transport-kind transport)))

(defvar pichat-transport--active-connections nil
  "TRAMP connections with PiChat acquisition or composed teardown on stack.")

(defun pichat-transport--connection (transport)
  "Return TRANSPORT's TRAMP identity without connecting."
  (when-let* ((transport)
              ((eq (pichat-transport-kind transport) 'ssh))
              (prefix (pichat-transport-tramp-prefix transport)))
    (tramp-dissect-file-name prefix)))

(defun pichat-transport--busy-p (connection)
  "Whether CONNECTION is currently in PiChat or TRAMP synchronous work."
  (or (cl-some (apply-partially #'tramp-file-name-equal-p connection)
               pichat-transport--active-connections)
      (tramp-file-name-equal-p connection (car tramp-current-connection))
      ;; The lock also covers direct TRAMP I/O outside the filename handler.
      (let ((process (tramp-get-process connection)))
        (and (processp process)
             (tramp-get-connection-property process "locked")))))

(defun pichat-transport-defer (transport function)
  "Run FUNCTION on a later turn when TRANSPORT is free; return a canceller.
Callers must still validate ownership when FUNCTION runs.  Do not use this
for a callback that a synchronous operation on the same connection awaits."
  (let ((connection (pichat-transport--connection transport)) timer)
    (cl-labels ((dispatch ()
                  (if (and connection (pichat-transport--busy-p connection))
                      (setq timer (run-at-time 0.05 nil #'dispatch))
                    (setq timer nil)
                    (funcall function))))
      (setq timer (run-at-time 0 nil #'dispatch))
      (lambda ()
        (when timer (cancel-timer timer) (setq timer nil))))))

(defun pichat-transport-busy-p (transport)
  "Return non-nil if TRANSPORT's connection is in synchronous use."
  (when-let* ((connection (pichat-transport--connection transport)))
    (pichat-transport--busy-p connection)))

(defun pichat-transport-run-when-idle (transport function)
  "Run FUNCTION now or defer it if TRANSPORT is busy.
Use for detached work that need not finish before the caller returns."
  (if (pichat-transport-busy-p transport)
      (pichat-transport-defer transport function)
    (funcall function)))

(defun pichat-transport-delete-process (process)
  "Delete owned PROCESS when its captured transport is idle.
The endpoint, not the current UI target, determines teardown placement.  This
only retires the endpoint; it is not evidence of remote child shutdown."
  (when (processp process)
    (pichat-transport-run-when-idle
     (process-get process 'pichat-transport)
     (lambda ()
       (when (process-live-p process)
         (delete-process process))))))

(defun pichat-transport--sentinel (transport connection sentinel process event)
  "Run the complete SSH SENTINEL (including TRAMP's tail) when safe."
  (let ((run (lambda ()
               (let ((pichat-transport--active-connections
                      (cons connection pichat-transport--active-connections)))
                 (funcall sentinel process event)))))
    (if (pichat-transport--busy-p connection)
        (pichat-transport-defer transport run)
      (funcall run))))

(defun pichat-transport-make-process (transport runtime-cwd &rest process-args)
  "Start a pipe process through TRANSPORT in RUNTIME-CWD.
PROCESS-ARGS are ordinary `make-process' keyword arguments."
  (let* ((remote-p (eq (pichat-transport-kind transport) 'ssh))
         (default-directory
          (file-name-as-directory
           (if remote-p
               (pichat-transport-runtime-file-name transport runtime-cwd)
             runtime-cwd)))
         (tramp-remote-path
          (if (and remote-p (pichat-transport-remote-path transport))
              (pichat-transport-remote-path transport)
            tramp-remote-path))
         (args (copy-sequence process-args)))
    (setq args (plist-put args :connection-type 'pipe)
          args (plist-put args :noquery t))
    (if (not remote-p)
        (apply #'make-process args)
      (let* ((connection (pichat-transport--connection transport))
             (pichat-transport--active-connections
              (cons connection pichat-transport--active-connections))
             (proc (apply #'make-process (plist-put args :file-handler t))))
        (when (processp proc)
          (process-put proc 'pichat-transport transport))
        ;; TRAMP installs stderr FIFO cleanup after our sentinel during
        ;; acquisition.  Wrap the installed sentinel, not just our callback.
        (when (and connection (processp proc) (process-sentinel proc))
          (add-function :around (process-sentinel proc)
                        (apply-partially #'pichat-transport--sentinel
                                         transport connection)))
        proc))))

(provide 'pichat-transport)
;;; pichat-transport.el ends here
