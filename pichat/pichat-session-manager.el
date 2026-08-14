;;; pichat-session-manager.el --- Global PiChat runtime manager -*- lexical-binding: t; -*-

;;; Commentary:

;; One global tabulated view of every retained PiChat RPC runtime.  Runtime
;; ownership and lifecycle remain in pichat.el; killing this buffer is harmless.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'project)
(require 'tabulated-list)
(require 'pichat-session)
(require 'pichat-transport)
(require 'pichat-path)
(require 'pichat-events)
(require 'pichat-chat)
(require 'pichat-pi)
(require 'pichat-sessions)
(require 'pichat-view)
(require 'pichat-chat-diagnostics)

(declare-function pichat-start-session "pichat"
                  (&optional cwd scope launch-options))
(declare-function pichat-launch "pichat" (&optional context))
(declare-function pichat-stop-session "pichat" (&optional session))
(declare-function pichat-forget-session "pichat" (session))
(declare-function pichat-set-default-session "pichat" (session))
(declare-function pichat-session-list "pichat" ())
(declare-function pichat-session-by-runtime-id "pichat" (runtime-id))
(declare-function pichat-session-default-p "pichat" (session))
(declare-function pichat--scope-for-directory "pichat"
                  (&optional directory force-global target-id))

(defvar pichat-session-registry-changed-hook)
(defvar pichat-global-directory)

(defgroup pichat-session-manager nil
  "Global management of PiChat RPC runtimes."
  :group 'pichat)

(defun pichat-session-manager-display-chat-current-tab (session)
  "Open SESSION's chat using PiChat's ordinary current-tab behavior."
  (pichat-chat-open session))

(defcustom pichat-session-manager-display-chat-function
  #'pichat-session-manager-display-chat-current-tab
  "Function used by the manager to display a selected SESSION.
The function receives the exact `pichat-session' represented by the selected
row.  Integrations may switch tabs before calling
`pichat-session-manager-display-chat-current-tab'; PiChat itself has no Tab Bar
or Bufferlo dependency."
  :type 'function
  :group 'pichat-session-manager)

(defcustom pichat-session-manager-preview-max-entries 24
  "Maximum active-branch entries shown in a runtime preview."
  :type 'integer
  :group 'pichat-session-manager)

(defconst pichat-session-manager-buffer-name "*PiChat Sessions*"
  "Name of the global runtime-session manager buffer.")

(defconst pichat-session-manager-preview-buffer-name
  "*PiChat Runtime Preview*"
  "Name of the runtime preview buffer owned by the global manager.")

(defvar-local pichat-session-manager--event-handlers nil
  "Global event handlers installed by this manager buffer.")

(defvar-local pichat-session-manager--registry-handler nil
  "Registry hook function installed by this manager buffer.")

(defvar-local pichat-session-manager--refresh-timer nil
  "Pending coalesced manager refresh timer.")

(defvar-local pichat-session-manager--preview-cache nil
  "Source-token keyed active-branch preview snapshots.")

(defvar-local pichat-session-manager--preview-window nil
  "Side window currently owned by this manager's preview.")

(defvar-local pichat-session-manager--preview-timer nil
  "Pending debounced selected-row preview timer.")

(defvar-local pichat-session-manager--preview-request-id nil
  "RPC request ID currently owned by the runtime preview.")

(defvar-local pichat-session-manager--preview-request-session nil
  "Runtime session owning `pichat-session-manager--preview-request-id'.")

(defvar-local pichat-session-manager--preview-generation 0
  "Generation used to reject stale runtime preview callbacks.")

(defvar-local pichat-session-manager--preview-runtime-id nil
  "Runtime identity currently represented by the preview.")

(defvar-local pichat-session-manager-preview--manager-buffer nil
  "Manager buffer which owns this runtime preview buffer.")

(defun pichat-session-manager--shorten (value width)
  "Return VALUE as one line no wider than WIDTH."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\r\t ]+" " " (format "%s" (or value "")))
   width nil nil "…"))

(defun pichat-session-manager--short-id (id)
  "Return compact display form of Pi source ID."
  (if (and (stringp id) (> (length id) 8)) (substring id 0 8) (or id "—")))

(defun pichat-session-manager--model-name (session)
  "Return compact cached model name for SESSION."
  (let ((model (pichat-session-model session)))
    (pichat-session-manager--shorten
     (if (listp model)
         (let ((provider (plist-get model :provider))
               (id (or (plist-get model :id)
                       (plist-get model :modelId)
                       (plist-get model :name))))
           (cond
            ((and provider id) (format "%s/%s" provider id))
            (id id)
            (t "—")))
       (or model "—"))
     28)))

(defun pichat-session-manager--owner-label (session)
  "Return immutable owner-scope label for SESSION."
  (or (pichat-session-owner-scope-label session)
      (pichat-session-scope-label session)
      "global"))

(defun pichat-session-manager--session-label (session)
  "Return cached human-readable source label for SESSION."
  (let ((name (pichat-session-name session))
        (id (pichat-session-id session)))
    (pichat-session-manager--shorten
     (cond
      ((and (stringp name) (not (string-blank-p name))) name)
      (id (pichat-session-manager--short-id id))
      (t (pichat-session-runtime-id session)))
     32)))

(defun pichat-session-manager--project-label (session)
  "Return a compact user-facing owner project for SESSION."
  (let ((directory (pichat-session-owner-directory session))
        (key (pichat-session-owner-scope-key session)))
    (pichat-session-manager--shorten
     (cond
      ((or (equal key "global")
           (and (stringp key) (string-prefix-p "global|" key)))
       "global")
      ((and (stringp directory) (not (string-blank-p directory)))
       (file-name-nondirectory (directory-file-name directory)))
      (t (pichat-session-manager--owner-label session)))
     18)))

(defun pichat-session-manager--preferred-marker (session)
  "Return an unobtrusive preferred-runtime marker for SESSION."
  (if (pichat-session-default-p session)
      (propertize "★" 'face 'success
                  'help-echo "Preferred runtime for this project")
    ""))

(defun pichat-session-manager--row-session-name (session)
  "Return SESSION's explicit name for the compact manager row."
  (let ((name (pichat-session-name session)))
    (pichat-session-manager--shorten
     (if (and (stringp name) (not (string-blank-p name))) name "—")
     40)))

(defun pichat-session-manager--persistence-label (session)
  "Return compact persistence label for SESSION from launch metadata."
  (if (eq (pichat-session-persistence session) 'ephemeral) "none" "file"))

(defun pichat-session-manager--status-label (session)
  "Return cached runtime Status for SESSION with a pending-input marker."
  (let* ((state (format "%s" (or (pichat-session-state session) 'unknown)))
         (count (pichat-chat-pending-user-input-count session)))
    (if (> count 0)
        (concat
         state
         (propertize
          "!" 'face 'warning
          'help-echo
          (if (= count 1)
              "Waiting for user input"
            (format "Waiting for user input (%d requests)" count))))
      state)))

(defun pichat-session-manager--target-label (session)
  "Return compact target label for SESSION."
  (pichat-session-manager--shorten
   (pichat-transport-label (pichat-session-transport session)) 16))

(defun pichat-session-manager--entry (session)
  "Return one tabulated-list row for SESSION from cached state."
  (list
   (pichat-session-runtime-id session)
   (vector
    (pichat-session-manager--preferred-marker session)
    (pichat-session-manager--short-id (pichat-session-id session))
    (pichat-session-manager--status-label session)
    (pichat-session-manager--persistence-label session)
    (pichat-session-manager--project-label session)
    (pichat-session-manager--target-label session)
    (pichat-session-manager--model-name session)
    (pichat-session-manager--row-session-name session))))

(defun pichat-session-manager--entries ()
  "Return manager rows for every retained runtime session."
  (mapcar #'pichat-session-manager--entry (pichat-session-list)))

(defun pichat-session-manager-refresh ()
  "Refresh manager rows exclusively from cached runtime state."
  (interactive)
  (when (derived-mode-p 'pichat-session-manager-mode)
    (setq tabulated-list-entries (pichat-session-manager--entries))
    (tabulated-list-print t)))

(defun pichat-session-manager--run-refresh (buffer)
  "Refresh live manager BUFFER after a coalescing delay."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pichat-session-manager--refresh-timer nil)
      (pichat-session-manager-refresh))))

(defun pichat-session-manager--schedule-refresh (&rest _ignored)
  "Coalesce a manager refresh after a registry or runtime event."
  (unless (timerp pichat-session-manager--refresh-timer)
    (setq pichat-session-manager--refresh-timer
          (run-at-time 0.03 nil #'pichat-session-manager--run-refresh
                       (current-buffer)))))

(defun pichat-session-manager--preview-source-token (session)
  "Return a source-scoped preview cache token for SESSION."
  (list (pichat-session-runtime-id session)
        (pichat-session-id session)
        (pichat-session-session-file session)))

(defun pichat-session-manager--preview-window-live-p ()
  "Return non-nil when this manager still owns a visible preview window."
  (and (window-live-p pichat-session-manager--preview-window)
       (eq (window-buffer pichat-session-manager--preview-window)
           (get-buffer pichat-session-manager-preview-buffer-name))))

(defun pichat-session-manager--cancel-preview-timer ()
  "Cancel this manager's pending selected-row preview timer."
  (when (timerp pichat-session-manager--preview-timer)
    (cancel-timer pichat-session-manager--preview-timer))
  (setq pichat-session-manager--preview-timer nil))

(defun pichat-session-manager--cancel-preview-request ()
  "Cancel the runtime preview RPC request owned by this manager."
  (when (and pichat-session-manager--preview-request-id
             pichat-session-manager--preview-request-session)
    (ignore-errors
      (pichat-rpc-cancel-request
       pichat-session-manager--preview-request-session
       pichat-session-manager--preview-request-id)))
  (setq pichat-session-manager--preview-request-id nil
        pichat-session-manager--preview-request-session nil))

(defun pichat-session-manager--invalidate-preview-cache (session)
  "Remove cached preview snapshots belonging to runtime SESSION."
  (when (and session (hash-table-p pichat-session-manager--preview-cache))
    (let ((runtime-id (pichat-session-runtime-id session))
          stale)
      (maphash (lambda (token _snapshot)
                 (when (equal runtime-id (car token))
                   (push token stale)))
               pichat-session-manager--preview-cache)
      (dolist (token stale)
        (remhash token pichat-session-manager--preview-cache)))))

(defun pichat-session-manager--snapshot-from-chat (session)
  "Return a reusable settled chat snapshot for SESSION, or nil."
  (when-let ((cache (pichat-chat-canonical-entry-cache session)))
    (condition-case nil
        (pichat-sessions-preview-active-snapshot-from-entries
         (pichat-pi-entry-cache-active-branch cache)
         (pichat-entry-cache-leaf-id cache))
      (error nil))))

(defun pichat-session-manager--cached-preview (session &optional rpc-only)
  "Return a reusable preview snapshot for SESSION.
When RPC-ONLY is non-nil, ignore the manager cache but still reuse the exact
canonical chat cache while an RPC refresh is pending."
  (let* ((token (pichat-session-manager--preview-source-token session))
         (cached (and (not rpc-only)
                      (gethash token pichat-session-manager--preview-cache)))
         (snapshot (or cached
                       (pichat-session-manager--snapshot-from-chat session))))
    (when snapshot
      (puthash token snapshot pichat-session-manager--preview-cache))
    snapshot))

(defun pichat-session-manager--preview-model-name (session)
  "Return the untruncated cached model label for SESSION."
  (let ((model (pichat-session-model session)))
    (if (listp model)
        (let ((provider (plist-get model :provider))
              (id (or (plist-get model :id)
                      (plist-get model :modelId)
                      (plist-get model :name))))
          (cond
           ((and provider id) (format "%s/%s" provider id))
           (id (format "%s" id))
           (t "—")))
      (format "%s" (or model "—")))))

(defun pichat-session-manager--render-preview (session snapshot &optional note)
  "Render SESSION and optional active-branch SNAPSHOT with NOTE."
  (let ((buffer (get-buffer-create
                 pichat-session-manager-preview-buffer-name))
        (manager (current-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-session-manager-preview-mode)
        (pichat-session-manager-preview-mode))
      (setq pichat-session-manager-preview--manager-buffer manager)
      (let ((inhibit-read-only t)
            (path (plist-get snapshot :path)))
        (erase-buffer)
        (insert (propertize "Runtime Preview" 'face 'bold) "\n")
        (insert (format "Session: %s\n"
                        (pichat-session-manager--session-label session)))
        (insert (format "State: %s    Runtime: %s\n"
                        (or (pichat-session-state session) 'unknown)
                        (pichat-session-runtime-id session)))
        (insert (format "Preferred: %s\n"
                        (if (pichat-session-default-p session) "yes" "no")))
        (insert (format "Pi ID: %s\n"
                        (or (pichat-session-id session) "—")))
        (insert (format "Model: %s\n"
                        (pichat-session-manager--preview-model-name session)))
        (insert (format "Scope: %s\n"
                        (pichat-session-manager--owner-label session)))
        (insert (format "Target: %s (%s)\n"
                        (pichat-transport-label
                         (pichat-session-transport session))
                        (pichat-transport-kind
                         (pichat-session-transport session))))
        (insert (format "Emacs CWD: %s\n"
                        (abbreviate-file-name
                         (or (pichat-session-emacs-cwd session) "—"))))
        (unless (equal (pichat-session-emacs-cwd session)
                       (pichat-session-runtime-cwd session))
          (insert (format "Runtime CWD: %s\n"
                          (or (pichat-session-runtime-cwd session) "—"))))
        (insert
         (format "Persistence: %s\n"
                 (if (eq (pichat-session-persistence session) 'ephemeral)
                     "none (--no-session)"
                   "persisted source file")))
        (insert (format "Runtime source: %s\n"
                        (or (pichat-session-session-file session) "—")))
        (when-let ((emacs-source (pichat-session-emacs-session-file session)))
          (unless (equal emacs-source (pichat-session-session-file session))
            (insert (format "Emacs source: %s\n"
                            (abbreviate-file-name emacs-source)))))
        (insert "q close · g refresh · RET in manager opens chat\n")
        (when note
          (insert (propertize (concat "\n" note "\n") 'face 'shadow)))
        (insert "\n" (propertize "Recent active branch" 'face 'bold) "\n\n")
        (cond
         (path
          (let* ((total (length path))
                 (limit (max 1 pichat-session-manager-preview-max-entries))
                 (omitted (max 0 (- total limit)))
                 (visible (if (> total limit) (nthcdr omitted path) path)))
            (when (> omitted 0)
              (insert (propertize
                       (format "[%d earlier entries omitted]\n\n" omitted)
                       'face 'shadow)))
            (pichat-sessions-insert-preview-path
             visible (plist-get snapshot :selected-id))))
         (snapshot
          (insert (propertize "[empty session]" 'face 'shadow) "\n"))
         (t
          (insert (propertize "[preview unavailable]" 'face 'shadow) "\n")))
        (goto-char (point-min))))
    (when (pichat-session-manager--preview-window-live-p)
      (set-window-point pichat-session-manager--preview-window (point-min)))
    buffer))

(defun pichat-session-manager--preview-callback-current-p
    (session generation token)
  "Return non-nil when preview callback context is still current."
  (and (= generation pichat-session-manager--preview-generation)
       (equal token (pichat-session-manager--preview-source-token session))
       (equal (pichat-session-runtime-id session)
              pichat-session-manager--preview-runtime-id)
       (pichat-session-manager--preview-window-live-p)))

(defun pichat-session-manager--request-preview (session snapshot)
  "Request and render SESSION's active branch, retaining optional SNAPSHOT."
  (pichat-session-manager--cancel-preview-request)
  (let* ((manager (current-buffer))
         (token (pichat-session-manager--preview-source-token session))
         (generation (cl-incf pichat-session-manager--preview-generation))
         completed)
    (setq pichat-session-manager--preview-request-session session)
    (cl-labels
        ((current-p ()
           (and (buffer-live-p manager)
                (with-current-buffer manager
                  (pichat-session-manager--preview-callback-current-p
                   session generation token))))
         (finish ()
           (setq completed t)
           (when (buffer-live-p manager)
             (with-current-buffer manager
               (when (= generation pichat-session-manager--preview-generation)
                 (setq pichat-session-manager--preview-request-id nil
                       pichat-session-manager--preview-request-session nil)))))
         (success (response response-session)
           (when (and (eq response-session session) (current-p))
             (condition-case error-data
                 (let ((fresh
                        (pichat-sessions-preview-active-snapshot
                         (plist-get response :data))))
                   (with-current-buffer manager
                     (puthash token fresh
                              pichat-session-manager--preview-cache)
                     (pichat-session-manager--render-preview session fresh)))
               (error
                (with-current-buffer manager
                  (pichat-session-manager--render-preview
                   session snapshot
                   (format "Preview data rejected: %s"
                           (pichat-session-manager--shorten
                            (error-message-string error-data) 160)))))))
           (finish))
         (failure (response response-session)
           (when (and (eq response-session session) (current-p))
             (with-current-buffer manager
               (pichat-session-manager--render-preview
                session snapshot
                (format "Preview request failed: %s"
                        (pichat-session-manager--shorten
                         (or (plist-get response :error) "unknown error")
                         160)))))
           (finish)))
      (let ((request-id
             (pichat-rpc-get-tree session #'success #'failure)))
        ;; A synchronous test transport may invoke its callback before the
        ;; request function returns an ID.
        (unless completed
          (setq pichat-session-manager--preview-request-id request-id))))))

(defun pichat-session-manager--preview-selected (&optional force)
  "Preview the selected runtime; FORCE requests fresh Pi data."
  (let* ((session (pichat-session-manager--session-at-point))
         (runtime-id (pichat-session-runtime-id session))
         (snapshot (pichat-session-manager--cached-preview session force))
         (active-p (memq (pichat-session-state session)
                         '(running compacting retrying))))
    (setq pichat-session-manager--preview-runtime-id runtime-id)
    (cond
     ((and (pichat-session-alive-p session)
           (or force active-p (null snapshot)))
      (pichat-session-manager--render-preview
       session snapshot (if snapshot "Refreshing preview…" "Loading preview…"))
      (pichat-session-manager--request-preview session snapshot))
     (snapshot
      (pichat-session-manager--cancel-preview-request)
      (pichat-session-manager--render-preview session snapshot))
     (t
      (pichat-session-manager--cancel-preview-request)
      (pichat-session-manager--render-preview
       session nil "Runtime is stopped and has no cached transcript.")))))

(defun pichat-session-manager--run-preview (buffer)
  "Refresh the selected-row preview owned by manager BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pichat-session-manager--preview-timer nil)
      (when (pichat-session-manager--preview-window-live-p)
        (condition-case nil
            (pichat-session-manager--preview-selected)
          (user-error nil))))))

(defun pichat-session-manager--schedule-preview (&optional delay)
  "Debounce selected-row preview by optional DELAY seconds."
  (when (pichat-session-manager--preview-window-live-p)
    (pichat-session-manager--cancel-preview-timer)
    (setq pichat-session-manager--preview-timer
          (run-at-time (or delay 0.12) nil
                       #'pichat-session-manager--run-preview
                       (current-buffer)))))

(defun pichat-session-manager--track-preview-selection ()
  "Update an open preview after point moves to another runtime row."
  (when (pichat-session-manager--preview-window-live-p)
    (let ((runtime-id (tabulated-list-get-id)))
      (when (and runtime-id
                 (not (equal runtime-id
                             pichat-session-manager--preview-runtime-id)))
        (setq pichat-session-manager--preview-runtime-id runtime-id)
        (pichat-session-manager--schedule-preview)))))

(defun pichat-session-manager--close-preview ()
  "Close the preview pane and release its asynchronous work."
  (cl-incf pichat-session-manager--preview-generation)
  (pichat-session-manager--cancel-preview-timer)
  (pichat-session-manager--cancel-preview-request)
  (when (pichat-session-manager--preview-window-live-p)
    (quit-window nil pichat-session-manager--preview-window))
  (setq pichat-session-manager--preview-window nil
        pichat-session-manager--preview-runtime-id nil))

(defun pichat-session-manager-toggle-preview ()
  "Toggle a side preview of the selected runtime's active branch."
  (interactive)
  (if (pichat-session-manager--preview-window-live-p)
      (pichat-session-manager--close-preview)
    (let ((buffer (get-buffer-create
                   pichat-session-manager-preview-buffer-name))
          (manager (current-buffer)))
      (with-current-buffer buffer
        (unless (derived-mode-p 'pichat-session-manager-preview-mode)
          (pichat-session-manager-preview-mode))
        (setq pichat-session-manager-preview--manager-buffer manager))
      (setq pichat-session-manager--preview-window
            (display-buffer-in-side-window
             buffer '((side . right) (slot . 1) (window-width . 0.45))))
      (pichat-session-manager--preview-selected))))

(defun pichat-session-manager-preview-refresh ()
  "Refresh the runtime represented by the current preview."
  (interactive)
  (let ((manager pichat-session-manager-preview--manager-buffer))
    (unless (buffer-live-p manager)
      (user-error "The owning PiChat session manager is gone"))
    (with-current-buffer manager
      (pichat-session-manager--preview-selected t))))

(defun pichat-session-manager-preview-quit ()
  "Close this runtime preview and return to its manager."
  (interactive)
  (let ((manager pichat-session-manager-preview--manager-buffer))
    (if (buffer-live-p manager)
        (with-current-buffer manager
          (pichat-session-manager--close-preview))
      (quit-window))))

(defvar pichat-session-manager-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "g") #'pichat-session-manager-preview-refresh)
    (define-key map (kbd "q") #'pichat-session-manager-preview-quit)
    map)
  "Keymap for PiChat runtime previews.")

(define-derived-mode pichat-session-manager-preview-mode pichat-view-mode
  "PiChat-Runtime-Preview"
  "Display a bounded active-branch preview for one retained runtime."
  (setq-local truncate-lines nil))

(defun pichat-session-manager--handle-runtime-event
    (buffer session event plist)
  "Update manager BUFFER after SESSION emitted EVENT with PLIST."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; Terminal/error events do not make the last settled snapshot less
      ;; useful; retain it so stopped runtimes remain previewable without a
      ;; chat buffer.  Source and transcript events invalidate it.
      (when (memq event '(session-started session-state-changed
                          session-rebinding rpc-event))
        (pichat-session-manager--invalidate-preview-cache session))
      (pichat-session-manager--schedule-refresh)
      (when (and (equal (pichat-session-runtime-id session)
                        pichat-session-manager--preview-runtime-id)
                 (or (memq event '(session-started session-state-changed
                                   session-ended error))
                     (and (eq event 'rpc-event)
                          (memq (plist-get plist :normalized-event)
                                '(agent-start agent-settled
                                  compaction-end retry-end)))))
        (pichat-session-manager--schedule-preview)))))

(defun pichat-session-manager--install-handlers ()
  "Install bounded global refresh handlers for the current manager buffer."
  (unless pichat-session-manager--event-handlers
    (let ((buffer (current-buffer)))
      (dolist (event '(session-started session-state-changed session-rebinding
                      rpc-event user-input-pending-changed error session-ended))
        (let ((handler
               (lambda (session observed-event plist)
                 (pichat-session-manager--handle-runtime-event
                  buffer session observed-event plist))))
          (pichat-on event handler)
          (push (cons event handler) pichat-session-manager--event-handlers)))
      (setq pichat-session-manager--registry-handler
            (lambda (&rest _args)
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (pichat-session-manager--schedule-refresh)))))
      (add-hook 'pichat-session-registry-changed-hook
                pichat-session-manager--registry-handler))))

(defun pichat-session-manager--remove-handlers ()
  "Remove global handlers, preview work, and timers owned by this manager."
  (pichat-session-manager--close-preview)
  (dolist (pair pichat-session-manager--event-handlers)
    (pichat-off (car pair) (cdr pair)))
  (setq pichat-session-manager--event-handlers nil)
  (when pichat-session-manager--registry-handler
    (remove-hook 'pichat-session-registry-changed-hook
                 pichat-session-manager--registry-handler)
    (setq pichat-session-manager--registry-handler nil))
  (when (timerp pichat-session-manager--refresh-timer)
    (cancel-timer pichat-session-manager--refresh-timer))
  (setq pichat-session-manager--refresh-timer nil)
  (when-let ((preview (get-buffer pichat-session-manager-preview-buffer-name)))
    (kill-buffer preview)))

(defun pichat-session-manager--session-at-point ()
  "Return the exact retained runtime session represented at point."
  (let* ((runtime-id (tabulated-list-get-id))
         (session (pichat-session-by-runtime-id runtime-id)))
    (unless runtime-id (user-error "No PiChat runtime on this row"))
    (unless session (user-error "This PiChat runtime row is stale; press g"))
    session))

(defun pichat-session-manager--display (session)
  "Display exact runtime SESSION through the configured policy."
  (funcall pichat-session-manager-display-chat-function session))

(defun pichat-session-manager-open-chat ()
  "Open the selected runtime session's chat."
  (interactive)
  (pichat-session-manager--display
   (pichat-session-manager--session-at-point)))

(defun pichat-session-manager--start-in-directory
    (directory &optional scope transport)
  "Start an independent runtime in DIRECTORY, optional SCOPE and TRANSPORT."
  (let ((session (pichat-start-session
                  directory scope (when transport (list :transport transport)))))
    (pichat-session-manager--display session)
    (unless (eq (pichat-session-state session) 'error)
      (pichat-rpc-get-state session (lambda (&rest _args) nil)))
    session))

(defun pichat-session-manager--read-project-directory ()
  "Read a known project or an arbitrary directory for a new runtime.
Use the configured `project-prompter', whose default offers known projects and
an explicit manual-directory choice.  Move a selected real project to the front
of the persistent project list."
  (let ((directory (funcall project-prompter)))
    (when-let ((project (project-current nil directory)))
      (project-remember-project project))
    directory))

(defun pichat-session-manager-new (directory)
  "Start an independent runtime rooted at selected DIRECTORY."
  (interactive (list (pichat-session-manager--read-project-directory)))
  (pichat-session-manager--start-in-directory directory))

(defun pichat-session-manager--read-launch-scope ()
  "Read and return an exact project/directory scope for the launch menu."
  (let* ((directory
          (file-name-as-directory
           (expand-file-name
            (pichat-session-manager--read-project-directory))))
         (transport (pichat-transport-resolve directory))
         (label
          (format "%s@%s"
                  (file-name-nondirectory (directory-file-name directory))
                  (substring (md5 directory) 0 8))))
    (list (format "project|%s|%s"
                  (pichat-transport-id transport) directory)
          directory label)))

(defun pichat-session-manager-launch ()
  "Open the shared PiChat launch Transient with manager display policy."
  (interactive)
  (pichat-launch
   (list :origin-buffer (current-buffer)
         :directory nil
         :display-function #'pichat-session-manager--display
         :current-scope-function
         #'pichat-session-manager--read-launch-scope
         :manager t)))

(defun pichat-session-manager--owner-directory (session)
  "Return SESSION's immutable owner directory when available."
  (or (pichat-session-owner-directory session)
      (pichat-session-emacs-cwd session)
      (pichat-session-cwd session)))

(defun pichat-session-manager--owner-scope (session)
  "Return exact immutable owner scope tuple for SESSION."
  (list (pichat-session-owner-scope-key session)
        (pichat-session-manager--owner-directory session)
        (pichat-session-owner-scope-label session)))

(defun pichat-session-manager-new-in-scope ()
  "Start an independent runtime in the selected row's owner scope."
  (interactive)
  (let* ((session (pichat-session-manager--session-at-point))
         (directory (pichat-session-manager--owner-directory session)))
    (unless directory (user-error "Selected runtime has no owner directory"))
    (pichat-session-manager--start-in-directory
     directory (pichat-session-manager--owner-scope session)
     (pichat-session-transport session))))

(defun pichat-session-manager-browse-saved ()
  "Load a selected saved source in a new independent runtime.
Use the manager row only for archive discovery.  The saved source's recorded
working directory determines the new runtime's project and display routing."
  (interactive)
  (let ((selected (ignore-errors (pichat-session-manager--session-at-point))))
    (pichat-sessions-browse-files-independently
     :session selected
     :display-function #'pichat-session-manager--display
     :error-callback
     (lambda (response _session)
       (message "PiChat independent saved-session open failed: %s"
                (or (plist-get response :error) "unknown error"))))))

(defun pichat-session-manager-stop ()
  "Stop only the selected runtime session."
  (interactive)
  (let ((session (pichat-session-manager--session-at-point)))
    (unless (pichat-session-alive-p session)
      (user-error "Selected PiChat runtime is not live"))
    (when (yes-or-no-p
           (format "Stop PiChat runtime %s? "
                   (pichat-session-manager--session-label session)))
      (pichat-stop-session session)
      (pichat-session-manager-refresh))))

(defun pichat-session-manager-forget ()
  "Forget and clean up the selected stopped or failed runtime."
  (interactive)
  (let ((session (pichat-session-manager--session-at-point)))
    (when (pichat-session-alive-p session)
      (user-error "Stop the PiChat runtime before forgetting it"))
    (when-let ((buffer (pichat-session-buffer session)))
      (when (buffer-live-p buffer)
        (setf (pichat-session-buffer session) nil)
        (let ((pichat-chat-stop-session-on-kill nil))
          (kill-buffer buffer))))
    (pichat-forget-session session)
    (pichat-session-manager-refresh)))

(defun pichat-session-manager-make-default ()
  "Make the selected live runtime default for its immutable owner scope."
  (interactive)
  (pichat-set-default-session
   (pichat-session-manager--session-at-point))
  (pichat-session-manager-refresh))

(defun pichat-session-manager-diagnostics ()
  "Open transport diagnostics for the selected runtime."
  (interactive)
  (pichat-show-transport-diagnostics
   (pichat-session-manager--session-at-point)))

(defun pichat-session-manager-quit ()
  "Bury the global manager without affecting any runtime session."
  (interactive)
  (pichat-session-manager--close-preview)
  (quit-window))

(defvar pichat-session-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'pichat-session-manager-open-chat)
    (define-key map (kbd "C-o") #'pichat-session-manager-toggle-preview)
    (define-key map (kbd "n") #'pichat-session-manager-new)
    (define-key map (kbd "N") #'pichat-session-manager-new-in-scope)
    (define-key map (kbd "+") #'pichat-session-manager-launch)
    (define-key map (kbd "b") #'pichat-session-manager-browse-saved)
    (define-key map (kbd "k") #'pichat-session-manager-stop)
    (define-key map (kbd "d") #'pichat-session-manager-forget)
    (define-key map (kbd "m") #'pichat-session-manager-make-default)
    (define-key map (kbd "g") #'pichat-session-manager-refresh)
    (define-key map (kbd "D") #'pichat-session-manager-diagnostics)
    (define-key map (kbd "q") #'pichat-session-manager-quit)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for `pichat-session-manager-mode'.")

(define-derived-mode pichat-session-manager-mode tabulated-list-mode
  "PiChat-Sessions"
  "Manage every retained PiChat RPC runtime from one global buffer.

RET opens the exact selected runtime.  C-o toggles a bounded active-branch
preview which follows the selected row.  n starts an independent runtime in a
known project or manually chosen directory; N uses the selected owner scope; +
opens the full launch menu; b loads a saved source into a new runtime.  k stops,
d forgets a stopped runtime, m makes a live runtime the scope default, D shows
diagnostics, g refreshes, and q buries this buffer.
Killing this buffer never stops or forgets a runtime."
  (setq-local default-directory
              (file-name-as-directory
               (expand-file-name
                (if (and (boundp 'pichat-global-directory)
                         pichat-global-directory)
                    pichat-global-directory
                  "~"))))
  (setq-local tabulated-list-format
              [("" 1 nil)
               ("ID" 9 t)
               ("Status" 11 t)
               ("Store" 6 t)
               ("Project" 18 t)
               ("Target" 16 t)
               ("Model" 28 t)
               ("Session" 40 t)])
  (setq-local tabulated-list-padding 2)
  (setq-local tabulated-list-sort-key (cons "Project" nil))
  (setq-local pichat-session-manager--preview-cache
              (make-hash-table :test #'equal))
  (setq-local revert-buffer-function
              (lambda (&rest _args) (pichat-session-manager-refresh)))
  (add-hook 'post-command-hook
            #'pichat-session-manager--track-preview-selection nil t)
  (add-hook 'kill-buffer-hook #'pichat-session-manager--remove-handlers nil t)
  (tabulated-list-init-header)
  (pichat-session-manager--install-handlers))

;;;###autoload
(defun pichat-session-manager ()
  "Open the single global PiChat runtime-session manager."
  (interactive)
  (let ((buffer (get-buffer-create pichat-session-manager-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-session-manager-mode)
        (pichat-session-manager-mode))
      (pichat-session-manager-refresh))
    (pop-to-buffer buffer)
    buffer))

(provide 'pichat-session-manager)
;;; pichat-session-manager.el ends here
