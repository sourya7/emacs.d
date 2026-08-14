;;; pichat-session.el --- PiChat session state -*- lexical-binding: t; -*-

;;; Commentary:

;; Session data object.  Pi remains authoritative; this struct caches state and
;; holds process/RPC bookkeeping for Emacs.

;;; Code:

(require 'cl-lib)
(require 'pichat-transport)

(defvar pichat-current-session)
(defvar pichat-chat-session)
(defvar pichat-sessions-session)

(defvar pichat-session--runtime-counter 0
  "Counter used to assign immutable Emacs-side runtime identities.")

(cl-defstruct (pichat-session
               (:constructor pichat-session-create))
  runtime-id
  id
  name
  cwd
  emacs-cwd
  runtime-cwd
  owner-directory
  transport
  path-context
  process
  rpc
  buffer
  stderr-buffer
  stop-requested-p
  state
  persistence
  startup-model
  session-file
  session-file-back-stack
  session-file-forward-stack
  model
  thinking-level
  streaming-p
  compacting-p
  retrying-p
  pending-responses
  event-log
  diagnostics
  tool-registry
  event-handlers
  rpc-receive-buffer
  rpc-ready-p
  rpc-send-queue
  rpc-ready-timer
  rpc-seq
  rpc-command
  scope-key
  scope-label
  owner-scope-key
  owner-scope-label
  auto-compaction-enabled
  steering-mode
  follow-up-mode
  context-usage)

(defun pichat-session-make (&rest args)
  "Create a `pichat-session' with sensible defaults and ARGS overrides."
  (let ((session (apply #'pichat-session-create args)))
    (unless (pichat-session-transport session)
      (setf (pichat-session-transport session) pichat-transport-local))
    (unless (pichat-session-emacs-cwd session)
      (setf (pichat-session-emacs-cwd session)
            (or (pichat-session-cwd session) default-directory)))
    (unless (pichat-session-cwd session)
      (setf (pichat-session-cwd session)
            (pichat-session-emacs-cwd session)))
    (unless (pichat-session-runtime-cwd session)
      (setf (pichat-session-runtime-cwd session)
            (pichat-session-emacs-cwd session)))
    (unless (pichat-session-owner-directory session)
      (setf (pichat-session-owner-directory session)
            (pichat-session-emacs-cwd session)))
    (unless (pichat-session-path-context session)
      (setf (pichat-session-path-context session)
            (pichat-transport-path-context
             (pichat-session-transport session)
             (and (boundp 'pichat-path-mappings) pichat-path-mappings))))
    (unless (pichat-session-runtime-id session)
      (setf (pichat-session-runtime-id session)
            (format "pichat-runtime-%d"
                    (cl-incf pichat-session--runtime-counter))))
    (unless (pichat-session-state session)
      (setf (pichat-session-state session) 'starting))
    (unless (pichat-session-persistence session)
      (setf (pichat-session-persistence session) 'persistent))
    (unless (pichat-session-pending-responses session)
      (setf (pichat-session-pending-responses session)
            (make-hash-table :test #'equal)))
    (unless (pichat-session-event-log session)
      (setf (pichat-session-event-log session) nil))
    (unless (pichat-session-diagnostics session)
      (setf (pichat-session-diagnostics session) nil))
    (unless (pichat-session-event-handlers session)
      (setf (pichat-session-event-handlers session)
            (make-hash-table :test #'eq)))
    (unless (pichat-session-rpc-receive-buffer session)
      (setf (pichat-session-rpc-receive-buffer session) ""))
    (unless (pichat-session-rpc-ready-p session)
      (setf (pichat-session-rpc-ready-p session) t))
    (unless (pichat-session-rpc-seq session)
      (setf (pichat-session-rpc-seq session) 0))
    session))

(defun pichat-session-emacs-session-file (session)
  "Return SESSION's runtime source path translated for Emacs, or nil."
  (when-let ((path (pichat-session-session-file session)))
    (if (fboundp 'pichat-path-resolve-from-runtime)
        (plist-get
         (pichat-path-resolve-from-runtime
          path (pichat-session-path-context session))
         :path)
      path)))

(defun pichat-session-set-working-directories (session emacs-cwd runtime-cwd)
  "Set SESSION's mutable source working directories atomically."
  (setf (pichat-session-cwd session) emacs-cwd
        (pichat-session-emacs-cwd session) emacs-cwd
        (pichat-session-runtime-cwd session) runtime-cwd)
  session)

(defun pichat-session-alive-p (session)
  "Return non-nil if SESSION has a live RPC process."
  (let ((proc (pichat-session-process session)))
    (and proc (process-live-p proc))))

(defun pichat-session-current (&optional session)
  "Return the best current PiChat session.

Prefer explicit SESSION, then a buffer-local chat session, then a
buffer-local sessions-browser session, then an existing live session for
`default-directory' scope, and finally the global `pichat-current-session'."
  (or session
      (and (boundp 'pichat-chat-session) pichat-chat-session)
      (and (boundp 'pichat-sessions-session) pichat-sessions-session)
      (and (fboundp 'pichat-session-for-directory)
           (pichat-session-for-directory default-directory))
      (and (boundp 'pichat-current-session) pichat-current-session)))

(defun pichat-session-note-state (session state)
  "Set SESSION state to STATE."
  (setf (pichat-session-state session) state))

(defun pichat-session-apply-rpc-state (session state-plist)
  "Update SESSION cache from Pi RPC STATE-PLIST."
  (when state-plist
    (setf (pichat-session-id session) (plist-get state-plist :sessionId)
          (pichat-session-name session) (plist-get state-plist :sessionName)
          (pichat-session-session-file session) (plist-get state-plist :sessionFile)
          (pichat-session-model session) (plist-get state-plist :model)
          (pichat-session-thinking-level session) (plist-get state-plist :thinkingLevel)
          (pichat-session-auto-compaction-enabled session) (plist-get state-plist :autoCompactionEnabled)
          (pichat-session-steering-mode session) (plist-get state-plist :steeringMode)
          (pichat-session-follow-up-mode session) (plist-get state-plist :followUpMode)
          (pichat-session-streaming-p session) (not (null (plist-get state-plist :isStreaming)))
          (pichat-session-compacting-p session) (not (null (plist-get state-plist :isCompacting))))
    (pichat-session-note-state
     session
     (cond
      ((pichat-session-compacting-p session) 'compacting)
      ((pichat-session-streaming-p session) 'running)
      (t 'idle))))
  session)

(defun pichat-session-apply-rpc-stats (session stats-plist)
  "Update SESSION cache from Pi RPC STATS-PLIST."
  (when stats-plist
    (setf (pichat-session-context-usage session)
          (plist-get stats-plist :contextUsage)))
  session)

(provide 'pichat-session)
;;; pichat-session.el ends here
