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
(require 'pichat-backend)
(require 'pichat-transport)
(require 'pichat-path)
(require 'pichat-events)
(require 'pichat-chat)
(require 'pichat-pi)
(require 'pichat-sessions)
(require 'pichat-view)
(require 'pichat-transcript-view)
(require 'pichat-chat-diagnostics)

(declare-function pichat-start-session "pichat"
                  (&optional cwd scope launch-options))
(declare-function pichat-launch "pichat" (&optional context))
(declare-function pichat--open-launch-profile "pichat" (profile &optional directory))
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
  "Open SESSION's owning chat, synchronizing a newly created live chat."
  (pichat-chat-open session (and (not (pichat-chat-owned-buffer session))
                                 (pichat-session-alive-p session))))

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
  "Maximum canonical nodes shown in a runtime preview.
Tool results stay with their calls, so this is not a raw entry count.
The historical option name is retained for configuration compatibility."
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
  "Window currently owned by this manager's preview.")

(defvar-local pichat-session-manager--preview-window-configuration nil
  "Window configuration to restore when leaving expanded preview.")

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

(defun pichat-session-manager--owner-label (session)
  "Return immutable owner-scope label for SESSION."
  (or (pichat-session-owner-scope-label session)
      (pichat-session-scope-label session)
      "global"))

(defun pichat-session-manager--project-label (session)
  "Return the full user-facing owner project for SESSION."
  (let ((directory (pichat-session-owner-directory session))
        (key (pichat-session-owner-scope-key session)))
    (cond
     ((or (equal key "global")
          (and (stringp key) (string-prefix-p "global|" key)))
      "global")
     ((and (stringp directory) (not (string-blank-p directory)))
      (file-name-nondirectory (directory-file-name directory)))
     (t (pichat-session-manager--owner-label session)))))

(defun pichat-session-manager--preferred-marker (session)
  "Return an unobtrusive preferred-runtime marker for SESSION."
  (if (pichat-session-default-p session)
      (propertize "★" 'face 'success
                  'help-echo "Preferred runtime for this project")
    ""))

(defconst pichat-session-manager--adjectives
  ["bright" "calm" "clear" "cool" "eager" "fair" "fast" "fine"
   "fresh" "glad" "gold" "grand" "green" "happy" "keen" "kind"
   "light" "lively" "lucky" "merry" "neat" "nimble" "quiet" "quick"
   "ready" "silver" "soft" "sunny" "swift" "warm" "wise" "young"])

(defconst pichat-session-manager--nouns
  ["badger" "bear" "birch" "brook" "cedar" "cloud" "coral" "crane"
   "deer" "dove" "elm" "fern" "finch" "fox" "grove" "hare"
   "heron" "hill" "lake" "lark" "leaf" "lynx" "maple" "moss"
   "otter" "owl" "pine" "reed" "robin" "seal" "star" "wren"])

(defvar pichat-session-manager--aliases (make-hash-table :test #'equal)
  "Runtime aliases retained for this Emacs uptime, not persisted names.")
(defvar pichat-session-manager--reserved-aliases (make-hash-table :test #'equal)
  "Generated labels reserved until Emacs exits, including forgotten runtimes.")

(defun pichat-session-manager--alias (runtime-id)
  "Return RUNTIME-ID's stable alias, or nil when no pair is available."
  (when runtime-id
    (let ((missing (make-symbol "missing")))
      (let ((existing (gethash runtime-id pichat-session-manager--aliases missing)))
        (if (not (eq existing missing)) existing
          (let* ((nouns (length pichat-session-manager--nouns))
                 (total (* nouns (length pichat-session-manager--adjectives)))
                 (start (random total))
                 alias)
            (cl-loop for offset below total
                     for index = (mod (+ start offset) total)
                     for candidate = (concat
                                      (aref pichat-session-manager--adjectives
                                            (/ index nouns)) " "
                                      (aref pichat-session-manager--nouns
                                            (% index nouns)))
                     unless (gethash candidate pichat-session-manager--reserved-aliases)
                     do (setq alias candidate) and return nil)
            (when alias
              (puthash alias t pichat-session-manager--reserved-aliases))
            ;; Cache exhaustion too: refresh must not repeatedly scan the pool.
            (puthash runtime-id alias pichat-session-manager--aliases)
            alias))))))

(defun pichat-session-manager-runtime-label (session)
  "Return the label the runtime manager shows for SESSION's runtime.
This is SESSION's explicit Pi session name when non-blank, otherwise its
stable two-word runtime alias, falling back to the Pi source ID and then
the runtime ID.  The first call for an unnamed runtime reserves its alias
for this Emacs uptime.  The label is display-only and never a stable
identifier; use `pichat-session-runtime-id' for identity."
  (let ((name (pichat-session-name session)))
    (if (and (stringp name) (not (string-blank-p name))) name
      (or (pichat-session-manager--alias (pichat-session-runtime-id session))
          (pichat-session-id session) (pichat-session-runtime-id session) "—"))))

(defconst pichat-session-manager--columns
  '(("ID" 2) ("Name" 16) ("Status" 11) ("Project" 14) ("Preset" 10)
    ("Target" 12) ("Model" 24) ("Pi source ID" 12) ("Backend" 7) ("Store" 6))
  "Column priority and minimum widths, independent of row content.")

(defvar-local pichat-session-manager--logical-sort '("Project")
  "Chosen sort column and direction, including when hidden.")
(defvar-local pichat-session-manager--window-handler nil
  "Global window-state handler owned by this manager buffer.")

(defun pichat-session-manager--display-width ()
  "Return the narrowest displayed manager body width across all frames."
  (let ((windows (cl-remove-if-not
                  (lambda (window) (eq t (frame-visible-p (window-frame window))))
                  (get-buffer-window-list (current-buffer) nil t))))
    (if windows (apply #'min (mapcar #'window-body-width windows))
      (window-body-width))))

(defun pichat-session-manager--layout (width)
  "Return deterministic columns fitting WIDTH display cells."
  (let* ((width (max 1 width))
         (id-width (min width
                        (apply #'max 2
                               (mapcar (lambda (session)
                                         (string-width
                                          (pichat-session-manager--field session "ID")))
                                       (pichat-session-list)))))
         (gutter (if (>= width (+ id-width 4)) 2 0))
         (remaining (- width gutter id-width))
         (name-width (min 16 (max 0 (1- remaining))))
         (columns (list (list "ID" id-width)))
         (rest (cddr pichat-session-manager--columns)))
    (when (> name-width 0)
      (push (list "Name" name-width) columns)
      (cl-decf remaining (1+ name-width)))
    (while (and rest (>= remaining (1+ (cadar rest))))
      (push (copy-sequence (car rest)) columns)
      (cl-decf remaining (1+ (cadar rest)))
      (setq rest (cdr rest)))
    (setq columns (nreverse columns))
    (when-let* ((name (assoc "Name" columns)))
      (cl-incf (cadr name) (min remaining (- 40 name-width))))
    (when (> gutter 0) (push '("" 1) columns))
    (vconcat
     (mapcar
      (lambda (column)
        (let ((name (car column)))
          (list name (cadr column)
                (unless (equal name "")
                  (lambda (a b)
                    (pichat-session-manager--less-p a b name))))))
      columns))))

(defun pichat-session-manager--field (session column)
  "Return SESSION's full cached value for COLUMN without display truncation."
  (pcase column
    ("" (pichat-session-manager--preferred-marker session))
    ("Name" (pichat-session-manager-runtime-label session))
    ("Status" (pichat-session-manager--status-label session))
    ("Project" (pichat-session-manager--project-label session))
    ("Preset" (if (pichat-session-preset-name session)
                  (symbol-name (pichat-session-preset-name session)) "legacy"))
    ("Target" (pichat-session-manager--target-label session))
    ("Model" (pichat-session-model-label session))
    ("ID" (string-remove-prefix "pichat-runtime-"
                                (pichat-session-runtime-id session)))
    ("Pi source ID" (or (pichat-session-id session) "—"))
    ("Backend" (symbol-name (pichat-session-backend-id session)))
    ("Store" (pichat-session-manager--persistence-label session))))

(defun pichat-session-manager--sort-value (entry column)
  "Return ENTRY's full value for COLUMN, even if that column is hidden."
  (or (cdr (assoc column (get-text-property 0 'pichat-manager-fields
                                          (aref (cadr entry) 0)))) ""))

(defun pichat-session-manager--less-p (a b column)
  "Compare entries A and B by COLUMN, sorting runtime numbers numerically."
  (let ((a-value (pichat-session-manager--sort-value a column))
        (b-value (pichat-session-manager--sort-value b column)))
    (if (equal column "ID")
        (< (string-to-number a-value) (string-to-number b-value))
      (string< a-value b-value))))

(defun pichat-session-manager--persistence-label (session)
  "Return compact persistence label for SESSION from launch metadata."
  (pcase (pichat-session-persistence session)
    ('memory "memory") ('ephemeral "none") (_ "file")))

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
  "Return full target label for SESSION."
  (pichat-transport-label (pichat-session-transport session)))

(defun pichat-session-manager--entry (session)
  "Return one responsive tabulated-list row for SESSION from cached state."
  (let* ((format (if (derived-mode-p 'pichat-session-manager-mode)
                     tabulated-list-format
                   (pichat-session-manager--layout 240)))
         (fields (mapcar (lambda (column)
                           (cons (car column)
                                 (pichat-session-manager--field session (car column))))
                         (cons '("") pichat-session-manager--columns)))
         (cells
          (vconcat
           (mapcar
            (lambda (column)
              (let* ((name (car column))
                     (full (cdr (assoc name fields)))
                     (display (if (equal name "Pi source ID")
                                  (pichat-session-manager--short-id full) full))
                     (width (cadr column))
                     (cell (if (and (equal name "Status") (string-suffix-p "!" display))
                               (concat (pichat-session-manager--shorten
                                        (substring display 0 -1) (1- width))
                                       (substring display -1))
                             (pichat-session-manager--shorten display width))))
                (propertize cell 'help-echo
                            (if (and (equal name "") (> (length full) 0))
                                (get-text-property 0 'help-echo full)
                              full))))
            format))))
    ;; Put full sort fields on a nonempty first cell (the marker may be empty).
    (when (equal (aref cells 0) "") (aset cells 0 (copy-sequence " ")))
    (put-text-property 0 (length (aref cells 0)) 'pichat-manager-fields fields
                       (aref cells 0))
    (list (pichat-session-runtime-id session) cells)))

(defun pichat-session-manager--entries ()
  "Return manager rows for every retained runtime session."
  (mapcar #'pichat-session-manager--entry (pichat-session-list)))

(defun pichat-session-manager-refresh ()
  "Refresh manager rows exclusively from cached runtime state."
  (interactive)
  (when (derived-mode-p 'pichat-session-manager-mode)
    (when tabulated-list-sort-key
      (setq pichat-session-manager--logical-sort
            (copy-tree tabulated-list-sort-key)))
    (setq tabulated-list-format
          (pichat-session-manager--layout (pichat-session-manager--display-width)))
    (setq tabulated-list-sort-key
          (when (assoc (car pichat-session-manager--logical-sort)
                       (append tabulated-list-format nil))
            (copy-tree pichat-session-manager--logical-sort)))
    (setq tabulated-list-entries (pichat-session-manager--entries))
    (when pichat-session-manager--logical-sort
      (let ((column (car pichat-session-manager--logical-sort))
            (flip (cdr pichat-session-manager--logical-sort)))
        (setq tabulated-list-entries
              (cl-stable-sort tabulated-list-entries
                              (lambda (a b)
                                (pichat-session-manager--less-p
                                 (if flip b a) (if flip a b) column))))))
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun pichat-session-manager--window-change (buffer)
  "Schedule a layout refresh for BUFFER only if its layout changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      ;; Closures in column sort predicates cannot be compared with `equal'.
      (unless (equal (mapcar (lambda (c) (list (car c) (cadr c)))
                            (append tabulated-list-format nil))
                     (mapcar (lambda (c) (list (car c) (cadr c)))
                             (append (pichat-session-manager--layout
                                      (pichat-session-manager--display-width)) nil)))
        (pichat-session-manager--schedule-refresh)))))

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
      (pichat-backend-cancel-owned-request
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
  (condition-case nil
      (when-let* ((cache (pichat-chat-canonical-entry-cache session)))
        (list :entries (copy-tree
                        (pichat-pi-entry-cache-active-branch cache) t)
              :selected-id (pichat-entry-cache-leaf-id cache)))
    (error nil)))

(defun pichat-session-manager--cached-preview (session &optional rpc-only)
  "Return a reusable preview snapshot for SESSION.
When RPC-ONLY is non-nil, ignore the manager cache but still reuse the exact
canonical chat cache while an RPC refresh is pending."
  (let* ((token (pichat-session-manager--preview-source-token session))
         (cached (and (not rpc-only)
                      (eq (pichat-session-backend-id session) 'pi)
                      (gethash token pichat-session-manager--preview-cache)))
         (snapshot (or cached
                       (pichat-session-manager--snapshot-from-chat session))))
    (when (and snapshot (eq (pichat-session-backend-id session) 'pi))
      (puthash token snapshot pichat-session-manager--preview-cache))
    snapshot))

(defun pichat-session-manager--insert-transcript (entries)
  "Insert the bounded canonical tail of linear ENTRIES at point.
Count omitted source entries, including merged tool results, not nodes.
Construction rejection is presented by the shared view, never a runtime notice."
  (let* ((limit (max 1 pichat-session-manager-preview-max-entries))
         (transcript
          (condition-case nil
              (pichat-pi-build-canonical-transcript-from-entries entries t)
            ((pichat-pi-invalid-session pichat-transcript-invalid) nil))))
    (if (null transcript)
        (pichat-transcript-view-render-entries entries (point) (point) limit)
      (let* ((nodes (pichat-transcript-nodes transcript))
             (omitted (max 0 (- (length nodes) limit)))
             (ids (make-hash-table :test #'equal)))
        (cl-loop for node in nodes for index from 0 below omitted do
                 (puthash (pichat-transcript-node-key node) t ids)
                 (dolist (content (pichat-transcript-node-content node))
                   (when-let* ((id (pichat-transcript-content-result-entry-id content)))
                     (puthash id t ids))))
        (when (> omitted 0)
          (insert (propertize
                   (format "[%d earlier entries omitted]\n\n"
                           (cl-count-if (lambda (entry)
                                          (gethash (plist-get entry :id) ids))
                                        entries))
                   'face 'shadow)))
        (pichat-transcript-view-render transcript (point) (point) limit)))))

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
            (entries (plist-get snapshot :entries)))
        (pichat-transcript-view-clear)
        (erase-buffer)
        (insert (propertize
                 (pichat-session-manager--shorten
                  (pichat-session-manager-runtime-label session) 40)
                 'face 'bold)
                "\n")
        (insert (format "%s · %s · %s%s%s\n"
                        (or (pichat-session-state session) 'unknown)
                        (or (pichat-session-preset-name session) "legacy")
                        (pichat-session-model-label session)
                        (if (pichat-session-default-p session) " · preferred" "")
                        (if (eq (pichat-session-persistence session) 'ephemeral)
                            " · ephemeral" "")))
        (let ((transport (pichat-session-transport session)))
          (if (and transport (eq (pichat-transport-kind transport) 'ssh))
              (insert (format "CWD: %s (SSH: %s)\n"
                              (or (pichat-session-runtime-cwd session) "—")
                              (pichat-transport-label transport)))
            (insert (format "CWD: %s\n"
                            (if-let* ((cwd (pichat-session-emacs-cwd session)))
                                (abbreviate-file-name cwd)
                              "—")))))
        (when note
          (insert (propertize (concat "\n" note "\n") 'face 'shadow)))
        (insert "\n" (propertize "Recent active branch" 'face 'bold) "\n\n")
        (cond
         (entries
          (pichat-session-manager--insert-transcript entries))
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
                        (let ((snapshot (pichat-sessions-preview-active-snapshot
                                         (plist-get response :data))))
                          (list :entries (mapcar (lambda (node)
                                                  (plist-get node :entry))
                                                (plist-get snapshot :path))
                                :selected-id (plist-get snapshot :selected-id)))))
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

(defun pichat-session-manager--preview-selected (&optional force session)
  "Preview SESSION or the selected runtime; FORCE requests fresh Pi data."
  (let* ((session (or session (pichat-session-manager--session-at-point)))
         (runtime-id (pichat-session-runtime-id session))
         (snapshot (pichat-session-manager--cached-preview session force))
         (active-p (memq (pichat-session-state session)
                         '(running compacting retrying))))
    (setq pichat-session-manager--preview-runtime-id runtime-id)
    (cond
     ((not (pichat-backend-capable-p session 'session-history))
      (pichat-session-manager--cancel-preview-request)
      (pichat-session-manager--render-preview
       session nil "Transcript preview is unavailable for this backend."))
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
  (pichat-session-manager--restore-preview-layout)
  (when (pichat-session-manager--preview-window-live-p)
    (quit-window nil pichat-session-manager--preview-window))
  (setq pichat-session-manager--preview-window nil
        pichat-session-manager--preview-runtime-id nil))

(defun pichat-session-manager-toggle-preview (&optional session)
  "Toggle a side preview of SESSION's active branch.
SESSION defaults to the runtime at point."
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
      ;; A previous expanded layout is stale once its preview window is gone.
      (setq pichat-session-manager--preview-window-configuration nil)
      (setq pichat-session-manager--preview-window
            (display-buffer-in-side-window
             buffer '((side . right) (slot . 1) (window-width . 0.45))))
      (if session
          (progn
            ;; The open pane follows the selected row.  Return to the
            ;; captured row so selection tracking won't replace the preview.
            (when-let* ((row (text-property-any
                              (point-min) (point-max) 'tabulated-list-id
                              (pichat-session-runtime-id session))))
              (goto-char row))
            (pichat-session-manager--preview-selected nil session))
        (pichat-session-manager--preview-selected)))))

(defun pichat-session-manager--restore-preview-layout ()
  "Restore this manager's layout from before preview expansion.
Keep the expanded preview's point.  Discard the saved layout without
restoring it when the expanded window no longer shows the preview."
  (when-let* ((configuration
               pichat-session-manager--preview-window-configuration))
    (setq pichat-session-manager--preview-window-configuration nil)
    (when (pichat-session-manager--preview-window-live-p)
      (let ((point (window-point pichat-session-manager--preview-window)))
        (set-window-configuration configuration)
        (setq pichat-session-manager--preview-window
              (get-buffer-window pichat-session-manager-preview-buffer-name
                                 (window-configuration-frame configuration)))
        (when (window-live-p pichat-session-manager--preview-window)
          (set-window-point pichat-session-manager--preview-window point))))))

(defun pichat-session-manager-preview-toggle-expand ()
  "Toggle between the side preview and an expanded regular window."
  (interactive)
  (let ((manager pichat-session-manager-preview--manager-buffer))
    (unless (buffer-live-p manager)
      (user-error "The owning PiChat session manager is gone"))
    (with-current-buffer manager
      (unless (pichat-session-manager--preview-window-live-p)
        (setq pichat-session-manager--preview-window-configuration nil)
        (user-error "The preview window is gone"))
      (if pichat-session-manager--preview-window-configuration
          (pichat-session-manager--restore-preview-layout)
        (let* ((window pichat-session-manager--preview-window)
               (buffer (window-buffer window))
               (point (window-point window))
               (configuration (current-window-configuration)))
          (delete-window window)
          (set-window-buffer (selected-window) buffer)
          (delete-other-windows)
          (set-window-point (selected-window) point)
          (setq pichat-session-manager--preview-window (selected-window)
                pichat-session-manager--preview-window-configuration
                configuration)))
      (select-window pichat-session-manager--preview-window))))

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
    (define-key map (kbd "e") #'pichat-session-manager-preview-toggle-expand)
    (define-key map (kbd "q") #'pichat-session-manager-preview-quit)
    map)
  "Keymap for PiChat runtime previews.")

(define-derived-mode pichat-session-manager-preview-mode pichat-view-mode
  "PiChat-Runtime-Preview"
  "Display a bounded active-branch preview for one retained runtime.

Press e to toggle expansion, g to refresh, or q to return to the manager."
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
  (when pichat-session-manager--window-handler
    (remove-hook 'window-state-change-functions pichat-session-manager--window-handler)
    (setq pichat-session-manager--window-handler nil))
  (when pichat-session-manager--registry-handler
    (remove-hook 'pichat-session-registry-changed-hook
                 pichat-session-manager--registry-handler)
    (setq pichat-session-manager--registry-handler nil))
  (when (timerp pichat-session-manager--refresh-timer)
    (cancel-timer pichat-session-manager--refresh-timer))
  (setq pichat-session-manager--refresh-timer nil)
  (when-let* ((preview (get-buffer pichat-session-manager-preview-buffer-name)))
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

(defun pichat-session-manager-open-chat (&optional session)
  "Open the chat for runtime SESSION, defaulting to the row at point."
  (interactive)
  (pichat-session-manager--display
   (or session (pichat-session-manager--session-at-point))))

(defun pichat-session-manager--start-in-directory
    (directory &optional scope transport)
  "Start an independent runtime in DIRECTORY, optional SCOPE and TRANSPORT."
  (let ((session (pichat-start-session
                  directory scope (when transport (list :transport transport)))))
    (pichat-session-manager--display session)
    (unless (eq (pichat-session-state session) 'error)
      (pichat-backend-get-state session (lambda (&rest _args) nil)))
    session))

(defun pichat-session-manager--read-project-directory ()
  "Read a known project or an arbitrary directory for a new runtime.
Use the configured `project-prompter', whose default offers known projects and
an explicit manual-directory choice.  Move a selected real project to the front
of the persistent project list."
  (let ((directory (funcall project-prompter)))
    (when-let* ((project (project-current nil directory)))
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

(defun pichat-session-manager-new-in-scope (&optional session)
  "Start an independent runtime in SESSION's owner scope.
SESSION defaults to the runtime at point."
  (interactive)
  (let* ((session (or session (pichat-session-manager--session-at-point)))
         (directory (pichat-session-manager--owner-directory session)))
    (unless directory (user-error "Selected runtime has no owner directory"))
    (pichat-session-manager--start-in-directory
     directory (pichat-session-manager--owner-scope session)
     (pichat-session-transport session))))

(defun pichat-session-manager-name (&optional session revalidate)
  "Name SESSION's active source through its backend.
SESSION defaults to the runtime at point.  Call optional REVALIDATE after
reading the name, before sending it."
  (interactive)
  (let* ((session (or session (pichat-session-manager--session-at-point)))
         (source (pichat-session-manager--preview-source-token session))
         (name (read-string "Session name: " (pichat-session-name session))))
    (when revalidate (funcall revalidate))
    (unless (equal source (pichat-session-manager--preview-source-token session))
      (user-error "Selected runtime changed source while naming"))
    (pichat-backend-name-session
     session name
     (lambda (_response s)
       (when (equal source (pichat-session-manager--preview-source-token s))
         ;; State application emits the normal manager refresh event.  This
         ;; callback owns no UI buffer and remains safe after manager death.
         (pichat-backend-get-state s (lambda (&rest _ignored) nil)))))))

(cl-defun pichat-session-manager-browse-saved
    (&optional (session (ignore-errors (pichat-session-manager--session-at-point))))
  "Load a selected saved source in a new independent runtime.
Use SESSION only for archive discovery.  With no argument, use the row at
point, if any; an explicit nil browses without a row.  The saved source's
recorded working directory determines the new runtime's project and display."
  (interactive)
  (when session
    (pichat-backend-require-capability
     session 'saved-sessions "Saved-session browsing"))
  (pichat-sessions-browse-files-independently
   :session session
   :display-function #'pichat-session-manager--display
   :error-callback
   (lambda (response _session)
     (message "PiChat independent saved-session open failed: %s"
              (or (plist-get response :error) "unknown error")))))

(defun pichat-session-manager--stop-prompt (session)
  "Return SESSION's Stop confirmation prompt, or nil for no prompt."
  (cond ((eq (pichat-session-persistence session) 'ephemeral)
         "Discard conversation? ")
        ((pichat-session-streaming-p session)
         "Abort running turn? ")))

(defun pichat-session-manager-stop (&optional session revalidate)
  "Stop only runtime SESSION, defaulting to the row at point.
Call optional REVALIDATE before dispatch, after any confirmation."
  (interactive)
  (let ((session (or session (pichat-session-manager--session-at-point))))
    (unless (pichat-session-alive-p session)
      (user-error "Selected PiChat runtime is not live"))
    (let ((prompt (pichat-session-manager--stop-prompt session)))
      (when (or (not prompt) (yes-or-no-p prompt))
        (when revalidate (funcall revalidate))
        (pichat-stop-session session)
        (pichat-session-manager-refresh)))))

(defun pichat-session-manager-forget (&optional session)
  "Forget and clean up stopped or failed runtime SESSION.
SESSION defaults to the runtime at point."
  (interactive)
  (let ((session (or session (pichat-session-manager--session-at-point))))
    (when (pichat-session-alive-p session)
      (user-error "Stop the PiChat runtime before forgetting it"))
    ;; Refuse uncertain restart claims before dismantling their recovery chat.
    (pichat-forget-session session)
    (when-let* ((buffer (pichat-session-buffer session)))
      (when (buffer-live-p buffer)
        (setf (pichat-session-buffer session) nil)
        (let ((pichat-chat-stop-session-on-kill nil))
          (kill-buffer buffer))))
    (pichat-session-manager-refresh)))

(defun pichat-session-manager-make-default (&optional session)
  "Make live runtime SESSION preferred for its immutable owner scope.
SESSION defaults to the runtime at point."
  (interactive)
  (pichat-set-default-session
   (or session (pichat-session-manager--session-at-point)))
  (pichat-session-manager-refresh))

(defun pichat-session-manager-diagnostics (&optional session)
  "Open unified cached diagnostics for runtime SESSION.
SESSION defaults to the runtime at point."
  (interactive)
  (let ((session (or session (pichat-session-manager--session-at-point))))
    (pichat-backend-require-capability
     session 'diagnostics "Cached diagnostics")
    (pichat-show-diagnostics session)))

(defun pichat-session-manager-quit ()
  "Bury the global manager without affecting any runtime session."
  (interactive)
  (pichat-session-manager--close-preview)
  (quit-window))

(autoload 'pichat-session-manager-actions "pichat-session-manager-actions" nil t)

(defvar pichat-session-manager-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "a") #'pichat-session-manager-actions)
    (define-key map (kbd "RET") #'pichat-session-manager-open-chat)
    (define-key map (kbd "C-o") #'pichat-session-manager-toggle-preview)
    (define-key map (kbd "n") #'pichat-session-manager-new)
    (define-key map (kbd "N") #'pichat-session-manager-new-in-scope)
    (define-key map (kbd "e") #'pichat-session-manager-name)
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
  "PiChat-Runtimes"
  "Manage every retained PiChat RPC runtime from one global buffer.

a opens the Actions menu.  RET opens the exact selected runtime's chat.
C-o toggles a bounded active-branch preview which follows the selected row.
n starts an independent runtime in a known project or manually chosen directory;
N uses the selected owner scope; + opens the full launch menu; b loads a saved
source into a new runtime.  k stops, d forgets a stopped runtime, e names a
session, m makes a live runtime the scope default, D shows diagnostics,
g refreshes, and q buries this buffer.
Killing this buffer never stops or forgets a runtime.

With Evil (`pichat-evil-setup'), Evil's Normal-state keys shadow the plain
bindings above, so the same actions use state-specific keys: g a opens
Actions, RET opens the chat, z v toggles the preview, g c starts a project
runtime, g C uses the selected owner scope, g L opens the launch menu, g b
loads a saved source, g k stops, g d forgets, r names, g m makes the scope
default, g D shows diagnostics, g r refreshes, and q buries this buffer.  Vim
navigation (h/j/k/l, w/b/e, gg/G, C-o) stays usable in this buffer."
  (setq-local default-directory
              (file-name-as-directory
               (expand-file-name
                (if (and (boundp 'pichat-global-directory)
                         pichat-global-directory)
                    pichat-global-directory
                  "~"))))
  (setq-local tabulated-list-format
              (pichat-session-manager--layout (pichat-session-manager--display-width)))
  (setq-local tabulated-list-padding 0)
  (setq-local tabulated-list-sort-key
              (when (assoc "Project" (append tabulated-list-format nil))
                (cons "Project" nil)))
  (let ((buffer (current-buffer)))
    (setq pichat-session-manager--window-handler
          (lambda (_frame) (pichat-session-manager--window-change buffer)))
    ;; Global: a buffer-local hook misses deletion of its narrowest window.
    (add-hook 'window-state-change-functions pichat-session-manager--window-handler))
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
  ;; The manager can be autoloaded before the lifecycle/registry entry point.
  ;; Require it here rather than introducing a top-level circular dependency.
  (require 'pichat)
  (let ((buffer (get-buffer-create pichat-session-manager-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-session-manager-mode)
        (pichat-session-manager-mode))
      (pichat-session-manager-refresh))
    (pop-to-buffer buffer)
    buffer))

(provide 'pichat-session-manager)
;;; pichat-session-manager.el ends here
