;;; pichat-sessions.el --- Session history and saved-session browsing -*- lexical-binding: t; -*-

;;; Commentary:

;; Current-session history commands and a separate saved-session file browser.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pp)
(require 'json)
(require 'pichat-rpc)
(require 'pichat-session)
(require 'pichat-events)
(require 'pichat-render)
(require 'pichat-path)
(require 'pichat-view)
(require 'pichat-archive)

(declare-function pichat-start-session "pichat"
                  (&optional cwd scope launch-options))
(declare-function pichat--scope-for-directory "pichat" (&optional directory force-global))
(declare-function pichat--unregister-session "pichat" (session))
(declare-function pichat-stop-session "pichat" (&optional session))
(declare-function pichat-forget-session "pichat" (session))
(declare-function pichat-note-session-updated "pichat" (session))
(declare-function pichat-chat-open "pichat-chat" (session &optional synchronize))
(declare-function pichat-chat-input-restore-fork-text
                  "pichat-chat-input" (text))
(declare-function pichat-chat-repaint "pichat-chat")
(declare-function pichat-chat--rename-buffer-maybe "pichat-chat" (&optional session))
(declare-function pichat-consult-available-p "pichat-consult")
(declare-function pichat-consult-sessions
                  "pichat-consult"
                  (capability &optional initial selection-function))
(declare-function pichat-consult-show-current-relations
                  "pichat-consult" (capability session))

(defvar pichat-current-session)
(defvar pichat-chat-stop-session-on-kill)
(defvar pichat-chat--editor-generation)
(defvar pichat--sessions-by-scope)

(defcustom pichat-sessions-default-root
  (expand-file-name "~/.pi/agent/sessions/")
  "Default root directory used by Pi for saved session files.
Used when `pichat-pi-session-dir' is nil.  PiChat passes
`pichat-pi-session-dir' to Pi only when explicitly set; otherwise Pi uses
its own default, which is normally this directory."
  :type 'directory
  :group 'pichat)

(defcustom pichat-sessions-completion-title-width 42
  "Maximum display width of a title in saved-session completion.
The compact session ID occupies a fixed leading field.  Annotations begin at
a shared column derived from this width so metadata remains comparable across
rows."
  :type '(integer :tag "Title columns")
  :safe (lambda (value) (and (integerp value) (<= 12 value 120)))
  :group 'pichat)

(defvar-local pichat-sessions-session nil)

(defvar-local pichat-sessions--tree nil)

(defvar-local pichat-sessions--leaf-id nil)

(defvar-local pichat-sessions--nodes nil)

(defvar-local pichat-sessions--parents nil)

(defvar-local pichat-sessions--children nil)

(defvar-local pichat-sessions--roots nil)

(defvar-local pichat-sessions--active-path nil)

(defvar-local pichat-sessions--folded nil)

(defvar-local pichat-sessions--filter 'default)

(defvar-local pichat-sessions--query nil)

(defvar-local pichat-sessions--selected-id nil)

(defvar-local pichat-sessions--visible-rows nil)

(defvar-local pichat-sessions--visible-parents nil)

(defvar-local pichat-sessions--visible-children nil)

(defvar-local pichat-sessions--visible-roots nil)

(defvar-local pichat-sessions--visible-foldable nil)

(defvar-local pichat-sessions--request-generation 0)

(defvar-local pichat-sessions--source-token nil)

(defvar-local pichat-sessions--request-id nil)

(defvar-local pichat-sessions--event-handler nil)

(defvar-local pichat-sessions--stale-p nil)

(defvar-local pichat-sessions--ordered-ids nil)

(defvar-local pichat-sessions--diagnostics nil)

(defvar-local pichat-sessions-preview--origin-buffer nil)

(defvar-local pichat-sessions-preview--session nil)

(defvar-local pichat-sessions-preview--source-token nil)

(defvar-local pichat-sessions-preview--selected-id nil)

(defvar-local pichat-sessions-preview--path nil)

(defvar-local pichat-sessions-preview--status nil)

(defvar-local pichat-sessions-preview--stale-p nil)

(defvar-local pichat-sessions-preview--event-handler nil)

(defconst pichat-sessions--diagnostic-limit 20
  "Maximum number of tree-model diagnostics retained per response.")

(defconst pichat-sessions--diagnostic-width 240
  "Maximum length of one tree-model diagnostic.")

(defconst pichat-sessions--filters
  '(default no-tools user-only labeled-only all)
  "Session-history filters in cycle order.")

(defconst pichat-sessions--bookkeeping-types
  '("label" "custom" "model_change" "thinking_level_change" "session_info")
  "Entry types hidden by the default history filters.")

(defvar pichat-sessions--summary-cache (make-hash-table :test #'equal)
  "Saved-session summaries keyed by file path and guarded by file metadata.")

(defface pichat-sessions-user-face
  '((t :inherit font-lock-keyword-face))
  "Face for user-message history rows."
  :group 'pichat)

(defface pichat-sessions-assistant-face
  '((t :inherit default))
  "Face for assistant-message history rows."
  :group 'pichat)

(defface pichat-sessions-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for tool-related history rows."
  :group 'pichat)

(defface pichat-sessions-bookkeeping-face
  '((t :inherit shadow))
  "Face for bookkeeping history rows."
  :group 'pichat)

(defvar pichat-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "RET") #'pichat-sessions-activate-at-point)
    (define-key map (kbd "TAB") #'pichat-sessions-toggle-fold-at-point)
    (define-key map (kbd "/") #'pichat-sessions-search)
    (define-key map (kbd "F") #'pichat-sessions-cycle-filter)
    (define-key map (kbd "f") #'pichat-sessions-fork-at-point)
    (define-key map (kbd "C") #'pichat-sessions-clone-current)
    (define-key map (kbd "n") #'pichat-sessions-next-entry)
    (define-key map (kbd "<down>") #'pichat-sessions-next-entry)
    (define-key map (kbd "p") #'pichat-sessions-previous-entry)
    (define-key map (kbd "<up>") #'pichat-sessions-previous-entry)
    (define-key map (kbd "M-n") #'pichat-sessions-next-branch-segment)
    (define-key map (kbd "M-p") #'pichat-sessions-previous-branch-segment)
    (define-key map (kbd "<") #'pichat-sessions-first-entry)
    (define-key map (kbd ">") #'pichat-sessions-last-entry)
    (define-key map (kbd "v") #'pichat-sessions-preview-branch-at-point)
    (define-key map (kbd "g") #'pichat-sessions-list-refresh)
    (define-key map (kbd "d") #'pichat-sessions-show-details-at-point)
    (define-key map (kbd "b") #'pichat-sessions-browse-files)
    (define-key map (kbd "q") #'pichat-sessions-return-to-chat)
    (define-key map (kbd "?") #'describe-mode)
    map))

(defvar pichat-sessions-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "f") #'pichat-sessions-preview-fork)
    (define-key map (kbd "t") #'pichat-sessions-preview-return-to-history)
    (define-key map (kbd "q") #'pichat-view-quit)
    (define-key map (kbd "d") #'pichat-sessions-preview-show-details)
    map)
  "Keymap for immutable PiChat branch previews.")

(define-derived-mode pichat-sessions-mode pichat-view-mode "PiChat-History"
  "Inspect entries from the current Pi session file as a tree.

RET jumps to the matching entry in the active chat transcript.  f forks
explicitly, v previews, d shows details, C clones the active branch, b browses
saved sessions, q returns to chat, and ? describes the complete mode bindings."
  (setq-local truncate-lines t)
  (unless (hash-table-p pichat-sessions--folded)
    (setq pichat-sessions--folded (make-hash-table :test #'equal)))
  (add-hook 'post-command-hook #'pichat-sessions--track-selection nil t)
  (add-hook 'kill-buffer-hook #'pichat-sessions--release-request-ownership nil t)
  (hl-line-mode 1))

(define-derived-mode pichat-sessions-preview-mode pichat-view-mode "PiChat-Preview"
  "Read an immutable root-to-entry PiChat branch preview.

Keys: f forks from the nearest user prompt, t returns to history, d shows
selected-entry details, and q closes the preview."
  (setq-local truncate-lines nil)
  (add-hook 'kill-buffer-hook
            #'pichat-sessions-preview--remove-event-handler nil t))

(defun pichat-sessions--node-entry (node)
  "Return session entry carried by tree NODE, or NODE itself."
  (or (plist-get node :entry) node))

(defun pichat-sessions--node-children (node)
  "Return children carried by tree NODE."
  (or (plist-get node :children) (plist-get node :branches)))

(defun pichat-sessions--shorten (text &optional width)
  "Return one-line TEXT truncated to WIDTH."
  (let* ((width (or width 78))
         (text (string-trim (replace-regexp-in-string "[\n\r\t ]+" " " (or text "")))))
    (if (> (length text) width)
        (concat (substring text 0 (max 0 (- width 1))) "…")
      text)))

(defun pichat-sessions--truncate-display (text width)
  "Return one-line TEXT truncated to display WIDTH with an ellipsis."
  (let ((text (string-trim
               (replace-regexp-in-string "[\n\r\t ]+" " " (or text "")))))
    (if (> (string-width text) width)
        (truncate-string-to-width text width nil nil "…")
      text)))

(defun pichat-sessions--completion-field (text width)
  "Return TEXT truncated and right-padded to display WIDTH."
  (let* ((text (pichat-sessions--truncate-display text width))
         (padding (max 0 (- width (string-width text)))))
    (concat text (make-string padding ?\s))))

(defun pichat-sessions--completion-annotation-prefix (identity)
  "Return padding and a separator after completion IDENTITY.
The separator starts at one shared visual column for ordinary saved-session
identities."
  (let* ((column (+ 12 (max 12 pichat-sessions-completion-title-width)))
         (padding (max 2 (- column (string-width identity)))))
    (concat (make-string padding ?\s)
            (propertize "│ " 'face 'shadow))))

(defun pichat-sessions--entry-time (entry)
  "Return compact timestamp for ENTRY."
  (let ((ts (plist-get entry :timestamp)))
    (cond
     ((and (stringp ts) (string-match "T\\([0-9][0-9]:[0-9][0-9]\\)" ts))
      (match-string 1 ts))
     ((numberp ts)
      (format-time-string "%H:%M" (/ ts 1000.0)))
     (t ""))))

(defun pichat-sessions--stable-id (entry)
  "Return ENTRY's stable Pi ID, or nil when it has none."
  (let ((id (or (plist-get entry :id) (plist-get entry :entryId))))
    (and (stringp id) (not (string-empty-p id)) id)))

(defun pichat-sessions--normalized-entry-type (entry)
  "Return the normalized Pi v3 type for ENTRY."
  (pcase (or (plist-get entry :type) (plist-get entry :entryType))
    ("customMessage" "custom_message")
    ("custom_entry" "custom")
    ((or "compaction_summary" "compactionSummary") "compaction")
    ("branchSummary" "branch_summary")
    (type (or type "node"))))

(defun pichat-sessions--entry-tool-calls (entry)
  "Return normalized assistant tool-call records carried by ENTRY."
  (let* ((message (plist-get entry :message))
         (content (plist-get message :content))
         calls)
    (when (and (string= (pichat-sessions--normalized-entry-type entry)
                        "message")
               (string= (plist-get message :role) "assistant")
               (listp content))
      (dolist (part content (nreverse calls))
        (when (and (listp part)
                   (member (plist-get part :type) '("toolCall" "tool_call")))
          (let ((id (plist-get part :id)))
            (when (and (stringp id) (not (string-empty-p id)))
              (push (list :id id
                          :name (plist-get part :name)
                          :arguments (plist-get part :arguments))
                    calls))))))))

(defun pichat-sessions--entry-kind (entry)
  "Return display kind for Pi v3 ENTRY."
  (let ((type (pichat-sessions--normalized-entry-type entry)))
    (if (string= type "message")
        (or (plist-get (plist-get entry :message) :role) "message")
      type)))

(defun pichat-sessions--entry-info (entry node)
  "Return readable summary for ENTRY from normalized tree NODE."
  (let* ((type (pichat-sessions--normalized-entry-type entry))
         (summary
          (pcase type
            ("message"
             (let* ((message (plist-get entry :message))
                    (role (or (plist-get message :role) "message"))
                    (text (pichat-render-message-text message))
                    (calls (plist-get node :tool-calls))
                    (result-call (plist-get node :tool-call))
                    (display-role
                     (if result-call
                         (format "%s(%s)" role
                                 (or (plist-get result-call :name) "unknown"))
                       role)))
               (cond
                ((not (string-empty-p text))
                 (format "%s: %s" display-role text))
                (calls
                 (format "%s: tool call%s %s"
                         role (if (= (length calls) 1) "" "s")
                         (string-join
                          (mapcar (lambda (call)
                                    (or (plist-get call :name) "unknown"))
                                  calls)
                          ", ")))
                (t display-role))))
            ("model_change"
             (format "%s%s"
                     (or (plist-get entry :modelId)
                         (plist-get entry :model) "model")
                     (if-let ((provider (plist-get entry :provider)))
                         (format " via %s" provider)
                       "")))
            ("thinking_level_change"
             (format "thinking: %s"
                     (or (plist-get entry :thinkingLevel) "?")))
            ("custom_message"
             (format "custom:%s %s"
                     (or (plist-get entry :customType) "custom")
                     (pichat-render-content (plist-get entry :content))))
            ("compaction"
             (format "compaction: %s" (or (plist-get entry :summary) "")))
            ("branch_summary"
             (format "branch summary: %s"
                     (or (plist-get entry :summary) "")))
            ("custom"
             (format "custom:%s" (or (plist-get entry :customType) "custom")))
            ("label"
             (format "label: %s" (or (plist-get entry :label) "")))
            ("session_info"
             (format "session: %s"
                     (or (plist-get entry :name)
                         (plist-get entry :sessionName) "info")))
            (_
             (or (plist-get entry :name)
                 (plist-get entry :sessionName)
                 (plist-get entry :text)
                 type)))))
    (pichat-sessions--shorten
     (if-let ((label (plist-get node :label)))
         (format "[%s] %s" label summary)
       summary))))

(defun pichat-sessions--short-id (id)
  "Return compact display form of ID."
  (if (and (stringp id) (> (length id) 10))
      (substring id 0 10)
    (format "%s" id)))

(defun pichat-sessions--bounded-diagnostic (format-string &rest args)
  "Return a bounded tree-model diagnostic from FORMAT-STRING and ARGS."
  (truncate-string-to-width
   (apply #'format format-string args)
   pichat-sessions--diagnostic-width nil nil "…"))

(defun pichat-sessions--build-active-path (nodes parents leaf-id)
  "Return a cycle-safe active-path set from LEAF-ID through PARENTS.
Only IDs present in NODES are included."
  (let ((active (make-hash-table :test #'equal))
        id)
    (setq id leaf-id)
    (while (and (stringp id)
                (gethash id nodes)
                (not (gethash id active)))
      (puthash id t active)
      (setq id (gethash id parents)))
    active))

(defun pichat-sessions--active-first (ids active-path)
  "Return stable active-first ordering of IDS using ACTIVE-PATH."
  (append (cl-remove-if-not (lambda (id) (gethash id active-path)) ids)
          (cl-remove-if (lambda (id) (gethash id active-path)) ids)))

(defun pichat-sessions--ordered-model-ids
    (roots children active-path)
  "Return iterative active-first preorder from ROOTS and CHILDREN."
  (let ((stack (pichat-sessions--active-first roots active-path))
        ordered)
    (while stack
      (let* ((id (pop stack))
             (child-ids (pichat-sessions--active-first
                         (gethash id children) active-path)))
        (push id ordered)
        (dolist (child (reverse child-ids))
          (push child stack))))
    (nreverse ordered)))

(defun pichat-sessions--tree-model-from-data (data)
  "Normalize get_tree DATA into a deterministic pure view model."
  (let ((tree (plist-get data :tree))
        (leaf-id (plist-get data :leafId))
        (nodes (make-hash-table :test #'equal))
        (parents (make-hash-table :test #'equal))
        (children (make-hash-table :test #'equal))
        (seen-nodes (make-hash-table :test #'eq))
        (tool-calls (make-hash-table :test #'equal))
        stack roots source-order diagnostics)
    (cl-labels
        ((diagnose (format-string &rest args)
           (when (< (length diagnostics) pichat-sessions--diagnostic-limit)
             (push (apply #'pichat-sessions--bounded-diagnostic
                          format-string args)
                   diagnostics)))
         (push-children (raw-children parent-id)
           (if (listp raw-children)
               (dolist (child (reverse raw-children))
                 (push (cons child parent-id) stack))
             (when raw-children
               (diagnose "Skipped malformed children for %s"
                         (or parent-id "root"))))))
      (dolist (root (reverse (if (listp tree) tree nil)))
        (push (cons root nil) stack))
      (when (and tree (not (listp tree)))
        (diagnose "Skipped malformed get_tree root collection"))
      (while stack
        (pcase-let* ((`(,raw-node . ,parent-id) (pop stack)))
          (cond
           ((not (listp raw-node))
            (diagnose "Skipped malformed tree node"))
           ((gethash raw-node seen-nodes)
            (diagnose "Skipped repeated tree node while checking nesting cycles"))
           (t
            (puthash raw-node t seen-nodes)
            (let* ((entry (pichat-sessions--node-entry raw-node))
                   (id (and (listp entry)
                            (pichat-sessions--stable-id entry)))
                   (raw-children (pichat-sessions--node-children raw-node)))
              (cond
               ((not id)
                (diagnose "Skipped tree node without a stable Pi entry ID")
                (push-children raw-children parent-id))
               ((gethash id nodes)
                (diagnose "Skipped duplicate Pi entry ID: %s" id)
                (push-children raw-children parent-id))
               (t
                (let* ((calls (pichat-sessions--entry-tool-calls entry))
                       (model-node
                        (list :id id :entry entry :raw-node raw-node
                              :type (pichat-sessions--normalized-entry-type entry)
                              :role (plist-get (plist-get entry :message) :role)
                              :label (plist-get raw-node :label)
                              :label-timestamp
                              (plist-get raw-node :labelTimestamp)
                              :tool-calls calls)))
                  (puthash id model-node nodes)
                  (push id source-order)
                  (if parent-id
                      (progn
                        (puthash id parent-id parents)
                        (puthash parent-id
                                 (cons id (gethash parent-id children))
                                 children))
                    (push id roots))
                  (dolist (call calls)
                    (puthash (plist-get call :id) call tool-calls))
                  (push-children raw-children id)))))))))
      (setq roots (nreverse roots)
            source-order (nreverse source-order)
            diagnostics (nreverse diagnostics))
      (maphash (lambda (id ids) (puthash id (nreverse ids) children))
               children)
      (dolist (id source-order)
        (let* ((node (gethash id nodes))
               (entry (plist-get node :entry))
               (message (plist-get entry :message))
               (tool-id (and (string= (plist-get node :role) "toolResult")
                             (plist-get message :toolCallId))))
          (when-let ((call (and tool-id (gethash tool-id tool-calls))))
            (setq node (plist-put node :tool-call call))
            (puthash id node nodes))))
      (when (and leaf-id (not (gethash leaf-id nodes)))
        (setq diagnostics
              (append diagnostics
                      (when (< (length diagnostics)
                               pichat-sessions--diagnostic-limit)
                        (list (pichat-sessions--bounded-diagnostic
                               "Active leaf is not present in tree: %s"
                               leaf-id))))))
      (let* ((active-path
              (pichat-sessions--build-active-path nodes parents leaf-id))
             (ordered-ids
              (pichat-sessions--ordered-model-ids
               roots children active-path)))
        (list :tree tree :leaf-id leaf-id :nodes nodes :parents parents
              :children children :roots roots :active-path active-path
              :ordered-ids ordered-ids :diagnostics diagnostics)))))

(defun pichat-sessions--model-root-ids (model)
  "Return structural root IDs from MODEL in source order."
  (plist-get model :roots))

(defun pichat-sessions--model-ordered-ids (model)
  "Return active-first display IDs from MODEL."
  (plist-get model :ordered-ids))

(defun pichat-sessions--model-parent-id (model id)
  "Return ID's nesting-derived parent in MODEL."
  (gethash id (plist-get model :parents)))

(defun pichat-sessions--model-child-ids (model id)
  "Return ID's structural children in source order from MODEL."
  (gethash id (plist-get model :children)))

(defun pichat-sessions--model-active-p (model id)
  "Return non-nil when ID is on MODEL's active path."
  (gethash id (plist-get model :active-path)))

(defun pichat-sessions--model-node (model id)
  "Return normalized node ID from MODEL."
  (gethash id (plist-get model :nodes)))

(defun pichat-sessions--model-node-label (model id)
  "Return resolved label for node ID in MODEL."
  (plist-get (pichat-sessions--model-node model id) :label))

(defun pichat-sessions--model-node-label-timestamp (model id)
  "Return resolved label timestamp for node ID in MODEL."
  (plist-get (pichat-sessions--model-node model id) :label-timestamp))

(defun pichat-sessions--model-node-tool-calls (model id)
  "Return assistant tool calls collected for node ID in MODEL."
  (plist-get (pichat-sessions--model-node model id) :tool-calls))

(defun pichat-sessions--model-node-tool-call (model id)
  "Return correlated assistant tool call for result node ID in MODEL."
  (plist-get (pichat-sessions--model-node model id) :tool-call))

(defun pichat-sessions--model-node-kind (model id)
  "Return display kind for node ID in MODEL."
  (let ((node (pichat-sessions--model-node model id)))
    (pichat-sessions--entry-kind (plist-get node :entry))))

(defun pichat-sessions--model-node-summary (model id)
  "Return display summary for node ID in MODEL."
  (let ((node (pichat-sessions--model-node model id)))
    (pichat-sessions--entry-info (plist-get node :entry) node)))

(defun pichat-sessions--model-diagnostics (model)
  "Return bounded normalization diagnostics from MODEL."
  (plist-get model :diagnostics))

(defun pichat-sessions--assistant-tool-only-p (node)
  "Return non-nil when assistant NODE has tool calls but no prose."
  (let* ((entry (plist-get node :entry))
         (message (plist-get entry :message)))
    (and (equal (plist-get node :type) "message")
         (equal (plist-get node :role) "assistant")
         (plist-get node :tool-calls)
         (string-empty-p (string-trim
                          (pichat-render-message-text message))))))

(defun pichat-sessions--entry-error-or-abort-p (node)
  "Return non-nil when NODE records an error or aborted assistant turn."
  (let* ((entry (plist-get node :entry))
         (message (plist-get entry :message))
         (reason (or (plist-get entry :stopReason)
                     (plist-get message :stopReason))))
    (or (plist-get entry :error)
        (plist-get message :error)
        (plist-get entry :isError)
        (plist-get message :isError)
        (plist-get entry :aborted)
        (plist-get message :aborted)
        (member reason '("error" "abort" "aborted")))))

(defun pichat-sessions--node-visible-for-filter-p (model id filter)
  "Return non-nil when ID in MODEL passes FILTER.
The current leaf is retained as a deterministic active-position fallback."
  (let* ((node (pichat-sessions--model-node model id))
         (type (plist-get node :type))
         (role (plist-get node :role))
         (current (equal id (plist-get model :leaf-id)))
         (tool-only-hidden
          (and (memq filter '(default no-tools))
               (pichat-sessions--assistant-tool-only-p node)
               (not current)
               (not (pichat-sessions--entry-error-or-abort-p node))))
         (visible
          (pcase filter
            ('default
             (and (not (member type pichat-sessions--bookkeeping-types))
                  (not tool-only-hidden)))
            ('no-tools
             (and (not (member type pichat-sessions--bookkeeping-types))
                  (not (member role '("toolResult" "tool_result")))
                  (not tool-only-hidden)))
            ('user-only
             (and (equal type "message") (equal role "user")))
            ('labeled-only (and (plist-get node :label) t))
            ('all t)
            (_ (error "Unknown session history filter: %s" filter)))))
    (or visible current)))

(defun pichat-sessions--search-text (node)
  "Return complete searchable text for normalized history NODE."
  (let* ((entry (plist-get node :entry))
         (message (plist-get entry :message))
         (values
          (list (plist-get node :type)
                (plist-get node :role)
                (plist-get node :label)
                (pichat-render-message-text message)
                (plist-get entry :summary)
                (plist-get entry :customType)
                (pichat-render-content (plist-get entry :content))
                (plist-get entry :modelId)
                (plist-get entry :model)
                (plist-get entry :provider)
                (plist-get entry :thinkingLevel)
                (plist-get entry :name)
                (plist-get entry :sessionName)
                (plist-get entry :text)
                (plist-get entry :command)
                (plist-get entry :output)
                (plist-get entry :label)))
         call-values)
    (dolist (call (append (plist-get node :tool-calls)
                          (when-let ((call (plist-get node :tool-call)))
                            (list call))))
      (push (plist-get call :name) call-values)
      (push (pichat-render-tool-args (plist-get call :arguments)) call-values))
    (string-join
     (delq nil
           (mapcar (lambda (value)
                     (when (stringp value) value))
                   (append values call-values)))
     " ")))

(defun pichat-sessions--query-tokens (query)
  "Return normalized whitespace-separated tokens from QUERY."
  (when (and (stringp query)
             (not (string-empty-p (string-trim query))))
    (split-string (downcase query) "[[:space:]]+" t)))

(defun pichat-sessions--node-matches-query-p (node query)
  "Return non-nil when NODE matches every token in QUERY."
  (let ((text (downcase (pichat-sessions--search-text node))))
    (cl-every (lambda (token)
                (string-match-p (regexp-quote token) text))
              (pichat-sessions--query-tokens query))))

(defun pichat-sessions--visible-relations (model ids)
  "Return nearest-visible parent/child/root relationships for MODEL IDS."
  (let ((visible (make-hash-table :test #'equal))
        (parents (make-hash-table :test #'equal))
        (children (make-hash-table :test #'equal))
        roots)
    (dolist (id ids) (puthash id t visible))
    (dolist (id ids)
      (let ((parent (pichat-sessions--model-parent-id model id))
            (seen (make-hash-table :test #'equal)))
        (while (and parent (not (gethash parent visible))
                    (not (gethash parent seen)))
          (puthash parent t seen)
          (setq parent (pichat-sessions--model-parent-id model parent)))
        (if (and parent (gethash parent visible))
            (progn
              (puthash id parent parents)
              (puthash parent (cons id (gethash parent children)) children))
          (push id roots))))
    (maphash (lambda (id child-ids)
               (puthash id (nreverse child-ids) children))
             children)
    (list :parents parents :children children :roots (nreverse roots))))

(defun pichat-sessions--foldable-segments (ids relations)
  "Return foldable branch-segment IDs from visible IDS and RELATIONS.
Roots and direct children of visible branch points begin segments; only segment
starts with visible descendants are foldable."
  (let ((roots (plist-get relations :roots))
        (parents (plist-get relations :parents))
        (children (plist-get relations :children))
        (foldable (make-hash-table :test #'equal)))
    (dolist (id ids)
      (let* ((parent (gethash id parents))
             (segment-start
              (or (member id roots)
                  (and parent (> (length (gethash parent children)) 1)))))
        (when (and segment-start (gethash id children))
          (puthash id t foldable))))
    foldable))

(defun pichat-sessions--project-visible (model filter query folded)
  "Project MODEL through FILTER, QUERY, and FOLDED state.
The returned model uses nearest-visible relationships for tree geometry."
  (let ((candidates (make-hash-table :test #'equal))
        candidate-ids)
    (dolist (id (pichat-sessions--model-ordered-ids model))
      (let ((node (pichat-sessions--model-node model id)))
        (when (and (pichat-sessions--node-visible-for-filter-p model id filter)
                   (pichat-sessions--node-matches-query-p node query))
          (puthash id t candidates)
          (push id candidate-ids))))
    (setq candidate-ids (nreverse candidate-ids))
    (let* ((base-relations
            (pichat-sessions--visible-relations model candidate-ids))
           (foldable
            (pichat-sessions--foldable-segments candidate-ids base-relations))
           (blocked (make-hash-table :test #'equal))
           visible-ids)
      (dolist (id (pichat-sessions--model-ordered-ids model))
        (let ((parent (pichat-sessions--model-parent-id model id)))
          (when (or (and parent (gethash parent blocked))
                    (and parent (gethash parent candidates)
                         (gethash parent folded)
                         (gethash parent foldable)))
            (puthash id t blocked)))
        (when (and (gethash id candidates) (not (gethash id blocked)))
          (push id visible-ids)))
      (setq visible-ids (nreverse visible-ids))
      (let* ((relations (pichat-sessions--visible-relations model visible-ids))
             (projection (copy-sequence model)))
        (setq projection (plist-put projection :ordered-ids visible-ids)
              projection (plist-put projection :parents
                                    (plist-get relations :parents))
              projection (plist-put projection :children
                                    (plist-get relations :children))
              projection (plist-put projection :roots
                                    (plist-get relations :roots))
              projection (plist-put projection :foldable foldable))
        projection))))

(defun pichat-sessions--display-siblings (model parent-id)
  "Return active-first sibling IDs below PARENT-ID in MODEL."
  (pichat-sessions--active-first
   (if parent-id
       (pichat-sessions--model-child-ids model parent-id)
     (pichat-sessions--model-root-ids model))
   (plist-get model :active-path)))

(defun pichat-sessions--tree-prefixes (model)
  "Return ID-to-prefix table for MODEL in one preorder pass.
Linear links reuse their parent's branch context and add no indentation."
  (let ((prefixes (make-hash-table :test #'equal))
        (descendant-prefixes (make-hash-table :test #'equal)))
    (dolist (id (pichat-sessions--model-ordered-ids model))
      (let* ((parent (pichat-sessions--model-parent-id model id))
             (base (or (and parent (gethash parent descendant-prefixes)) ""))
             (siblings (pichat-sessions--display-siblings model parent))
             (branched (> (length siblings) 1))
             (lastp (and branched (equal id (car (last siblings))))))
        (puthash id (concat base
                            (if branched
                                (if lastp "└─" "├─")
                              ""))
                 prefixes)
        (puthash id (concat base
                            (if branched
                                (if lastp "  " "│ ")
                              ""))
                 descendant-prefixes)))
    prefixes))

(defun pichat-sessions--entry-face (node)
  "Return an appropriate display face for normalized NODE."
  (pcase (plist-get node :role)
    ("user" 'pichat-sessions-user-face)
    ("assistant" 'pichat-sessions-assistant-face)
    ((or "toolResult" "tool_result") 'pichat-sessions-tool-face)
    (_ (if (string= (plist-get node :type) "message")
           'default
         'pichat-sessions-bookkeeping-face))))

(defun pichat-sessions--render-entry-line (model id prefix folded)
  "Insert one property-bearing history row for ID from MODEL using PREFIX.
FOLDED records collapsed branch segments."
  (let* ((node (pichat-sessions--model-node model id))
         (entry (plist-get node :entry))
         (active (pichat-sessions--model-active-p model id))
         (foldable (gethash id (plist-get model :foldable)))
         (fold-mark (cond
                     ((not foldable) " ")
                     ((gethash id folded) "⊞")
                     (t "⊟")))
         (summary (pichat-sessions--entry-info entry node))
         (time (pichat-sessions--entry-time entry))
         (line (concat "  " prefix fold-mark (if active "• " "  ") summary
                       (if (string-empty-p time) "" (format "  %s" time)))))
    (insert (propertize line
                        'pichat-session-entry-id id
                        'mouse-face 'highlight
                        'help-echo "RET: jump to active chat entry; v: preview; f: fork; d: details"
                        'face (pichat-sessions--entry-face node)))
    (insert "\n")))

(defun pichat-sessions--render-model (model filter query folded)
  "Return a temporary buffer containing projected MODEL.
The header displays FILTER and optional QUERY; FOLDED controls segment marks."
  (let ((rendered (generate-new-buffer " *pichat-history-render*")))
    (condition-case error-data
        (with-current-buffer rendered
          (insert (format "Session History  [%s]%s  %d entries%s\n"
                          filter
                          (if query (format "  query: %s" query) "")
                          (length (pichat-sessions--model-ordered-ids model))
                          (if pichat-sessions--stale-p "  [stale]" "")))
          (insert "RET jump to chat · f fork · v preview · TAB fold · n/p move · M-n/M-p branch\n")
          (insert "/ search · F filter · g refresh · d details · C clone · b browse · q chat · ? help\n\n")
          (let ((prefixes (pichat-sessions--tree-prefixes model)))
            (dolist (id (pichat-sessions--model-ordered-ids model))
              (pichat-sessions--render-entry-line
               model id (gethash id prefixes) folded)))
          rendered)
      (error
       (kill-buffer rendered)
       (signal (car error-data) (cdr error-data))))))

(defun pichat-sessions--entry-id-at-point ()
  "Return the stable history entry ID on point's logical line.
This works at beginning of line, end of line, and on the terminating newline."
  (or (get-text-property (point) 'pichat-session-entry-id)
      (get-text-property (line-beginning-position) 'pichat-session-entry-id)
      (and (> (line-end-position) (line-beginning-position))
           (get-text-property (1- (line-end-position))
                              'pichat-session-entry-id))))

(defun pichat-sessions--track-selection ()
  "Track the stable history row selected by point."
  (when-let ((id (pichat-sessions--entry-id-at-point)))
    (setq pichat-sessions--selected-id id)))

(defun pichat-sessions--nearest-visible-id (model projection id)
  "Return ID or its nearest visible ancestor in PROJECTION of MODEL."
  (let ((visible (make-hash-table :test #'equal))
        (seen (make-hash-table :test #'equal)))
    (dolist (visible-id (plist-get projection :ordered-ids))
      (puthash visible-id t visible))
    (while (and id (not (gethash id visible)) (not (gethash id seen)))
      (puthash id t seen)
      (setq id (pichat-sessions--model-parent-id model id)))
    (and id (gethash id visible) id)))

(defun pichat-sessions--selection-target (model projection selected-id)
  "Choose a deterministic visible target from MODEL and PROJECTION."
  (or (pichat-sessions--nearest-visible-id model projection selected-id)
      (pichat-sessions--nearest-visible-id
       model projection (plist-get model :leaf-id))
      (car (plist-get projection :ordered-ids))))

(defun pichat-sessions--clean-folds (model folded)
  "Return a copy of FOLDED retaining only IDs still present in MODEL."
  (let ((clean (make-hash-table :test #'equal)))
    (when (hash-table-p folded)
      (maphash (lambda (id value)
                 (when (and value (pichat-sessions--model-node model id))
                   (puthash id t clean)))
               folded))
    clean))

(defun pichat-sessions--current-model ()
  "Return the complete normalized model installed in this history buffer."
  (when (hash-table-p pichat-sessions--nodes)
    (list :tree pichat-sessions--tree
          :leaf-id pichat-sessions--leaf-id
          :nodes pichat-sessions--nodes
          :parents pichat-sessions--parents
          :children pichat-sessions--children
          :roots pichat-sessions--roots
          :active-path pichat-sessions--active-path
          :ordered-ids pichat-sessions--ordered-ids
          :diagnostics pichat-sessions--diagnostics)))

(defun pichat-sessions--install-model
    (model projection session rendered selected-id folded)
  "Atomically install MODEL, PROJECTION, and RENDERED text for SESSION.
Restore SELECTED-ID or a deterministic visible fallback and install FOLDED."
  (let ((inhibit-read-only t)
        (target (pichat-sessions--selection-target
                 model projection selected-id)))
    (erase-buffer)
    (insert-buffer-substring rendered)
    (setq pichat-sessions-session session
          pichat-sessions--tree (plist-get model :tree)
          pichat-sessions--leaf-id (plist-get model :leaf-id)
          pichat-sessions--nodes (plist-get model :nodes)
          pichat-sessions--parents (plist-get model :parents)
          pichat-sessions--children (plist-get model :children)
          pichat-sessions--roots (plist-get model :roots)
          pichat-sessions--active-path (plist-get model :active-path)
          pichat-sessions--ordered-ids (plist-get model :ordered-ids)
          pichat-sessions--visible-rows (plist-get projection :ordered-ids)
          pichat-sessions--visible-parents (plist-get projection :parents)
          pichat-sessions--visible-children (plist-get projection :children)
          pichat-sessions--visible-roots (plist-get projection :roots)
          pichat-sessions--visible-foldable (plist-get projection :foldable)
          pichat-sessions--folded folded
          pichat-sessions--source-token
          (list (pichat-session-id session)
                (pichat-session-session-file session))
          pichat-sessions--diagnostics (plist-get model :diagnostics)
          pichat-sessions--selected-id target)
    (if target
        (pichat-sessions--goto-id target)
      (goto-char (point-min)))))

(defun pichat-sessions--render-and-install
    (model session selected-id folded)
  "Project, render, and install MODEL transactionally for SESSION."
  (let* ((projection
          (pichat-sessions--project-visible
           model pichat-sessions--filter pichat-sessions--query folded))
         (rendered (pichat-sessions--render-model
                    projection pichat-sessions--filter
                    pichat-sessions--query folded)))
    (unwind-protect
        (pichat-sessions--install-model
         model projection session rendered selected-id folded)
      (when (buffer-live-p rendered)
        (kill-buffer rendered)))))

(defun pichat-sessions--rerender (&optional selected-id)
  "Rerender the installed model, preferring SELECTED-ID."
  (let ((model (pichat-sessions--current-model)))
    (unless model (user-error "No session history is loaded"))
    (pichat-sessions--render-and-install
     model pichat-sessions-session
     (or selected-id (pichat-sessions--entry-id-at-point)
         pichat-sessions--selected-id)
     pichat-sessions--folded)))

(defun pichat-sessions--refresh-from-response (response session buffer)
  "Normalize get_tree RESPONSE and transactionally populate BUFFER for SESSION."
  (let ((model (pichat-sessions--tree-model-from-data
                (plist-get response :data))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-sessions-mode)
        (pichat-sessions-mode))
      (let ((selected-id (or (pichat-sessions--entry-id-at-point)
                             pichat-sessions--selected-id))
            (folded (pichat-sessions--clean-folds
                     model pichat-sessions--folded))
            (old-stale-p pichat-sessions--stale-p))
        (setq pichat-sessions--stale-p nil)
        (condition-case error-data
            (pichat-sessions--render-and-install
             model session selected-id folded)
          (error
           (setq pichat-sessions--stale-p old-stale-p)
           (signal (car error-data) (cdr error-data))))))))

;;;###autoload
(defun pichat-sessions-search (query)
  "Filter visible history rows by whitespace-separated AND-token QUERY.
Interactively, an empty query clears the current search."
  (interactive
   (list (read-string "Session history search (empty clears): "
                      pichat-sessions--query)))
  (let ((old-query pichat-sessions--query)
        (new-query (and (stringp query)
                        (not (string-empty-p (string-trim query)))
                        (string-trim query))))
    (setq pichat-sessions--query new-query)
    (condition-case error-data
        (pichat-sessions--rerender)
      (error
       (setq pichat-sessions--query old-query)
       (signal (car error-data) (cdr error-data))))))

;;;###autoload
(defun pichat-sessions-cycle-filter ()
  "Cycle through Pi-compatible session-history filters."
  (interactive)
  (let* ((old-filter pichat-sessions--filter)
         (tail (cdr (memq old-filter pichat-sessions--filters)))
         (new-filter (or (car tail) (car pichat-sessions--filters))))
    (setq pichat-sessions--filter new-filter)
    (condition-case error-data
        (pichat-sessions--rerender)
      (error
       (setq pichat-sessions--filter old-filter)
       (signal (car error-data) (cdr error-data))))
    (message "PiChat session history filter: %s" new-filter)))

;;;###autoload
(defun pichat-sessions-toggle-fold-at-point ()
  "Toggle the branch segment rooted at the current visible entry."
  (interactive)
  (let ((id (pichat-sessions--entry-id-at-point)))
    (unless id (user-error "No history entry at point"))
    (unless (and (hash-table-p pichat-sessions--visible-foldable)
                 (gethash id pichat-sessions--visible-foldable))
      (user-error "Current entry does not begin a foldable branch segment"))
    (if (gethash id pichat-sessions--folded)
        (remhash id pichat-sessions--folded)
      (puthash id t pichat-sessions--folded))
    (condition-case error-data
        (pichat-sessions--rerender id)
      (error
       (if (gethash id pichat-sessions--folded)
           (remhash id pichat-sessions--folded)
         (puthash id t pichat-sessions--folded))
       (signal (car error-data) (cdr error-data))))))

(defun pichat-sessions--session-source-token (session)
  "Return the cached source identity token for SESSION."
  (and session
       (list (pichat-session-id session)
             (pichat-session-session-file session))))

(defun pichat-sessions--cancel-owned-request ()
  "Cancel the tree request owned by the current history buffer."
  (when (and pichat-sessions--request-id pichat-sessions-session)
    (pichat-rpc-cancel-request
     pichat-sessions-session pichat-sessions--request-id))
  (setq pichat-sessions--request-id nil))

(defun pichat-sessions--remove-event-handler ()
  "Remove the source-rebinding handler owned by this history buffer."
  (when (and pichat-sessions--event-handler pichat-sessions-session)
    (pichat-off 'session-rebinding pichat-sessions--event-handler
                pichat-sessions-session))
  (setq pichat-sessions--event-handler nil))

(defun pichat-sessions--release-request-ownership ()
  "Release RPC and event ownership held by the current history buffer."
  (cl-incf pichat-sessions--request-generation)
  (pichat-sessions--cancel-owned-request)
  (pichat-sessions--remove-event-handler))

(defun pichat-sessions--mark-stale ()
  "Mark the installed tree stale without replacing its visible rows."
  (setq pichat-sessions--stale-p t)
  (when (derived-mode-p 'pichat-sessions-mode)
    (let ((inhibit-read-only t)
          (selected-id (or (pichat-sessions--entry-id-at-point)
                           pichat-sessions--selected-id)))
      (save-excursion
        (goto-char (point-min))
        (unless (search-forward "[stale]" (line-end-position) t)
          (end-of-line)
          (insert "  [stale]")))
      (when selected-id
        (ignore-errors (pichat-sessions--goto-id selected-id))))))

(defun pichat-sessions--on-session-rebinding (session _event _plist)
  "Invalidate this history buffer before SESSION changes source."
  (when (eq session pichat-sessions-session)
    (cl-incf pichat-sessions--request-generation)
    (pichat-sessions--cancel-owned-request)
    (setq pichat-sessions--source-token nil)
    (pichat-sessions--mark-stale)))

(defun pichat-sessions--install-request-owner (session buffer)
  "Make BUFFER own history requests and rebind events for SESSION."
  (with-current-buffer buffer
    (unless (eq session pichat-sessions-session)
      (pichat-sessions--release-request-ownership)
      (setq pichat-sessions-session session
            pichat-sessions--source-token
            (pichat-sessions--session-source-token session)))
    (unless pichat-sessions--event-handler
      (let ((handler
             (lambda (event-session event plist)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (pichat-sessions--on-session-rebinding
                    event-session event plist))))))
        (setq pichat-sessions--event-handler handler)
        (pichat-on 'session-rebinding handler session)))))

(defun pichat-sessions--request-current-p
    (buffer session generation source-token)
  "Return non-nil when a tree callback still owns BUFFER and SESSION."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (= generation pichat-sessions--request-generation)
              (eq session pichat-sessions-session)
              (equal source-token pichat-sessions--source-token)
              (equal source-token
                     (pichat-sessions--session-source-token session))))))

(defun pichat-sessions--request-tree (session buffer &optional origin target-id)
  "Request SESSION's tree for BUFFER with stale-callback protection.
When ORIGIN is non-nil, show BUFFER from that captured view origin after the
accepted response.  When TARGET-ID is non-nil, move to that visible entry
before displaying BUFFER."
  (pichat-sessions--install-request-owner session buffer)
  (with-current-buffer buffer
    (pichat-sessions--cancel-owned-request)
    (cl-incf pichat-sessions--request-generation)
    (let* ((generation pichat-sessions--request-generation)
           (source-token (pichat-sessions--session-source-token session))
           (completed nil)
           request-id)
      (setq pichat-sessions--source-token source-token)
      (cl-labels
          ((current-p ()
             (pichat-sessions--request-current-p
              buffer session generation source-token))
           (success (response response-session)
             (setq completed t)
             (when (and (eq response-session session) (current-p))
               (with-current-buffer buffer
                 (setq pichat-sessions--request-id nil))
               (condition-case error-data
                   (progn
                     (pichat-sessions--refresh-from-response
                      response session buffer)
                     (when target-id
                       (with-current-buffer buffer
                         (pichat-sessions--goto-id target-id)))
                     (when origin
                       (pichat-view-display buffer origin 'bury)))
                 (error
                  (message "PiChat session history refresh failed: %s"
                           (pichat-sessions--shorten
                            (error-message-string error-data) 160))))))
           (failure (response response-session)
             (setq completed t)
             (when (and (eq response-session session) (current-p))
               (with-current-buffer buffer
                 (setq pichat-sessions--request-id nil))
               (message "PiChat session history refresh failed: %s"
                        (pichat-sessions--shorten
                         (format "%s" (or (plist-get response :error)
                                          "unknown error"))
                         160)))))
        (setq request-id
              (pichat-rpc-get-tree session #'success #'failure))
        ;; Synchronous test transports may complete before returning an ID.
        (when (and (not completed) (current-p))
          (setq pichat-sessions--request-id request-id))))))

(defun pichat-sessions-list-refresh ()
  "Refresh the current session history."
  (interactive)
  (unless pichat-sessions-session (user-error "No current PiChat session"))
  (pichat-sessions--request-tree
   pichat-sessions-session (current-buffer)))

;;;###autoload
(defun pichat-sessions-list (&optional session entry-id)
  "Show complete Session History for SESSION's current file.
This view previews entries or forks user prompts into new sessions; it does not
change the active leaf within the current file.  When ENTRY-ID is non-nil, move
to that visible entry after the tree is synchronized."
  (interactive)
  (let* ((session (pichat-session-current session))
         (buffer (get-buffer-create "*PiChat Session History*")))
    (unless session (user-error "No current PiChat session"))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-sessions-mode)
        (pichat-sessions-mode)))
    (pichat-sessions--request-tree
     session buffer (pichat-view-capture-origin) entry-id)))

(defun pichat-sessions--root-dir (&optional session)
  "Return the Emacs-visible Pi session root for optional SESSION."
  (if (and session
           (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh))
      (let* ((runtime-root
              (file-name-as-directory
               (expand-file-name ".pi/agent/sessions/"
                                 (pichat-transport-runtime-home
                                  (pichat-session-transport session)))))
             (resolution
              (pichat-path-resolve-from-runtime
               runtime-root (pichat-session-path-context session))))
        (file-name-as-directory
         (or (plist-get resolution :path)
             (pichat-transport-runtime-file-name
              (pichat-session-transport session) runtime-root))))
    (file-name-as-directory
     (expand-file-name (or pichat-pi-session-dir
                           pichat-sessions-default-root)))))

(defun pichat-sessions--files (&optional session)
  "Return saved Pi session files for optional SESSION's runtime."
  (let ((root (if session
                  (pichat-sessions--root-dir session)
                (pichat-sessions--root-dir))))
    (unless (file-directory-p root)
      (user-error "Pi session directory does not exist: %s" root))
    (let ((files (sort (directory-files-recursively root "\\.jsonl\\'")
                       #'file-newer-than-file-p))
          stale)
      (maphash (lambda (file _entry)
                 (unless (member file files) (push file stale)))
               pichat-sessions--summary-cache)
      (dolist (file stale) (remhash file pichat-sessions--summary-cache))
      files)))

(defun pichat-sessions--truncate-prefix (text width)
  "Return TEXT truncated to display WIDTH by removing from the prefix."
  (let* ((text (or text ""))
         (text-width (string-width text)))
    (if (> text-width width)
        (concat "…"
                (truncate-string-to-width
                 text text-width (- text-width (max 0 (1- width)))))
      text)))

(defun pichat-sessions--short-cwd (cwd &optional width)
  "Return readable CWD shortened by truncating its prefix."
  (pichat-sessions--truncate-prefix
   (abbreviate-file-name (directory-file-name (or cwd "")))
   (or width 32)))

(defun pichat-sessions--file-session-id (file)
  "Return the session id encoded in FILE's basename, if present."
  (let ((base (file-name-base file)))
    (if (string-match "_\\([^_]+\\)\\'" base)
        (match-string 1 base)
      base)))

(defun pichat-sessions--file-short-id (id)
  "Return compact display form of session ID for file browsing."
  (let ((id (format "%s" id)))
    (if (> (length id) 8)
        (substring id 0 8)
      id)))

(defun pichat-sessions--jsonl-records (file fn)
  "Call FN for each parsed JSONL record in FILE, ignoring malformed lines."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (unless (string-empty-p (string-trim line))
          (condition-case nil
              (funcall fn (json-parse-string line
                                             :object-type 'plist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil))
            (error nil))))
      (forward-line 1))))

(defun pichat-sessions--file-signature (file)
  "Return modification-time and size signature for FILE."
  (when-let ((attributes (file-attributes file)))
    (list (file-attribute-modification-time attributes)
          (file-attribute-size attributes))))

(defun pichat-sessions--file-summary-uncached (file)
  "Parse and return a summary plist for session FILE."
  (let ((id (pichat-sessions--file-session-id file))
        cwd
        name
        first-user-prompt)
    (pichat-sessions--jsonl-records
     file
     (lambda (entry)
       (pcase (plist-get entry :type)
         ("session"
          (setq id (or (plist-get entry :id) id)
                cwd (or (plist-get entry :cwd) cwd)))
         ("session_info"
          (setq name (plist-get entry :name)))
         ("message"
          (let* ((message (plist-get entry :message))
                 (role (plist-get message :role)))
            (when (string= role "user")
              (let ((text (pichat-render-message-text message)))
                (when (and (not first-user-prompt)
                           (not (string-empty-p (string-trim text))))
                  (setq first-user-prompt text)))))))))
    (list :id id
          :cwd cwd
          :name name
          :first-user-prompt first-user-prompt)))

(defun pichat-sessions--file-summary (file)
  "Return cached summary for session FILE, reparsing when metadata changes."
  (let* ((signature (pichat-sessions--file-signature file))
         (cached (gethash file pichat-sessions--summary-cache)))
    (if (and signature (equal signature (plist-get cached :signature)))
        (plist-get cached :summary)
      (let ((summary (pichat-sessions--file-summary-uncached file)))
        (puthash file (list :signature signature :summary summary)
                 pichat-sessions--summary-cache)
        summary))))

(defun pichat-sessions--completion-identity (title id)
  "Return a compact-ID-first saved-session identity from TITLE and ID."
  (let* ((title-width (max 12 pichat-sessions-completion-title-width))
         (raw-title (pichat-sessions--truncate-display title most-positive-fixnum))
         (title (pichat-sessions--truncate-display raw-title title-width))
         (id (string-trim (format "%s" (or id ""))))
         (short-id (and (not (string-empty-p id))
                        (pichat-sessions--file-short-id id))))
    (cond
     ((string-empty-p title) (or short-id "Untitled session"))
     ((or (null short-id) (equal raw-title id) (equal raw-title short-id))
      (or short-id title))
     (t (format "%s  %s" short-id title)))))

(defun pichat-sessions--file-presentation-record (file root)
  "Return a bounded completion presentation record for FILE under ROOT."
  (let* ((rel (file-relative-name file root))
         (summary (pichat-sessions--file-summary file))
         (id (format "%s" (or (plist-get summary :id)
                                (pichat-sessions--file-session-id file))))
         (attributes (file-attributes file))
         (mtime (if attributes
                    (format-time-string
                     "%Y-%m-%d %H:%M"
                     (file-attribute-modification-time attributes))
                  ""))
         (cwd (or (plist-get summary :cwd) (file-name-directory rel) ""))
         (short-cwd (pichat-sessions--short-cwd cwd))
         (title (or (plist-get summary :name)
                    (plist-get summary :first-user-prompt)
                    id rel))
         (candidate (pichat-sessions--completion-identity title id)))
    (list :candidate candidate :file file :cwd (plist-get summary :cwd)
          :title title :session-id id
          :short-id (pichat-sessions--file-short-id id)
          :mtime mtime :display-cwd short-cwd :full-cwd cwd
          :relative-file rel)))

(defun pichat-sessions--file-search-key (record)
  "Return bounded searchable aliases for presentation RECORD."
  (string-join
   (delq nil
         (mapcar
          (lambda (value)
            (when (and (stringp value) (not (string-empty-p value)))
              (pichat-sessions--shorten value 1024)))
          (list (plist-get record :candidate)
                (plist-get record :title)
                (plist-get record :session-id)
                (plist-get record :short-id)
                (plist-get record :full-cwd)
                (plist-get record :display-cwd)
                (plist-get record :mtime)
                (plist-get record :relative-file))))
   " "))

(defun pichat-sessions--file-annotation (record candidate)
  "Return aligned date and CWD annotation for RECORD and CANDIDATE."
  (when record
    (let ((metadata
           (string-trim-right
            (concat
             (pichat-sessions--completion-field
              (or (plist-get record :mtime) "") 16)
             "  " (or (plist-get record :display-cwd) "")))))
      (concat
       (pichat-sessions--completion-annotation-prefix candidate)
       (propertize metadata 'face 'completions-annotations)))))

(defun pichat-sessions--file-choices (files root)
  "Return completion choices for FILES under ROOT.
The resulting alist preserves FILES order and disambiguates duplicate primary
identities.  Each value is an opaque presentation record used for lookup and
affixation."
  (let ((seen (make-hash-table :test #'equal))
        choices)
    (dolist (file files (nreverse choices))
      (let* ((record (pichat-sessions--file-presentation-record file root))
             (identity (plist-get record :candidate))
             (candidate (if (gethash identity seen)
                            (format "%s  —  %s" identity
                                    (plist-get record :relative-file))
                          identity)))
        (puthash identity t seen)
        (setq record (plist-put record :candidate candidate))
        (push (cons candidate record) choices)))))

(defun pichat-sessions--choice-record (choice)
  "Return the presentation record stored in completion CHOICE, if any."
  (and (listp (cdr choice)) (cdr choice)))

(defun pichat-sessions--choice-file (choice)
  "Return the exact saved-session file stored in completion CHOICE."
  (let ((value (cdr choice)))
    (if (listp value) (plist-get value :file) value)))

(defun pichat-sessions--completion-table (choices)
  "Return searchable completion table for session CHOICES in display order."
  (let ((records (make-hash-table :test #'equal))
        (candidates (mapcar #'car choices)))
    (dolist (choice choices)
      (puthash (substring-no-properties (car choice))
               (pichat-sessions--choice-record choice) records))
    (let ((affixation
           (lambda (values)
             (mapcar
              (lambda (candidate)
                (list candidate ""
                      (or (pichat-sessions--file-annotation
                           (gethash (substring-no-properties candidate) records)
                           candidate)
                          "")))
              values))))
      (lambda (string pred action)
        (cond
         ((eq action 'metadata)
          `(metadata
            (category . pichat-session)
            (display-sort-function . identity)
            (cycle-sort-function . identity)
            (affixation-function . ,affixation)))
         ((eq action t)
          (let ((case-fold-search completion-ignore-case))
            (cl-loop
             for candidate in candidates
             for record = (gethash (substring-no-properties candidate) records)
             for search-key = (if record
                                  (pichat-sessions--file-search-key record)
                                candidate)
             when (and
                   (or (string-empty-p string)
                       (string-match-p (regexp-quote string) search-key))
                   (cl-every (lambda (regexp)
                               (string-match-p regexp search-key))
                             completion-regexp-list)
                   (or (null pred) (funcall pred candidate)))
             collect candidate)))
         ((eq action 'lambda)
          (let ((candidate (member string candidates)))
            (and candidate (or (null pred) (funcall pred (car candidate))))))
         (t (complete-with-action action candidates string pred)))))))

(defun pichat-sessions--active-session ()
  "Return an active PiChat session, starting one if possible."
  (let ((session (pichat-session-current)))
    (or (and session
             (pichat-session-alive-p session)
             session)
        (and (fboundp 'pichat-start-session)
             (pichat-start-session default-directory))
        (user-error "No active PiChat session"))))

(defun pichat-sessions--apply-session-cwd (session cwd &optional runtime-cwd)
  "Apply Emacs CWD and optional RUNTIME-CWD without changing owner scope."
  (when (and session
             (stringp cwd)
             (not (string-empty-p (string-trim cwd))))
    (let ((cwd (file-name-as-directory (expand-file-name cwd))))
      (pichat-session-set-working-directories
       session cwd (file-name-as-directory (or runtime-cwd cwd)))
      (when (fboundp 'pichat-note-session-updated)
        (pichat-note-session-updated session))
      cwd)))

(defun pichat-sessions--emacs-file (file &optional session)
  "Return FILE in Emacs-visible form for optional SESSION."
  (if (or (null session) (file-remote-p file))
      file
    (let ((resolution
           (pichat-path-resolve-from-runtime
            file (pichat-session-path-context session))))
      (or (plist-get resolution :path) file))))

(defun pichat-sessions--runtime-file (file &optional session)
  "Return the Pi runtime path for selected host session FILE.
Signal a user error rather than sending an uncovered host path when path
mappings are configured."
  (let* ((file (pichat-sessions--emacs-file file session))
         (resolution
          (pichat-path-resolve-to-runtime
           file (and session (pichat-session-path-context session)))))
    (if-let ((runtime-file (plist-get resolution :path)))
        runtime-file
      (user-error "Saved session path is not covered by pichat-path-mappings: %s"
                  file))))

(defun pichat-sessions--host-cwd-resolution (cwd &optional session)
  "Return strict Emacs resolution for saved runtime CWD, or nil."
  (when (and (stringp cwd) (not (string-empty-p (string-trim cwd))))
    (pichat-path-resolve-from-runtime
     cwd (and session (pichat-session-path-context session)))))

(defun pichat-sessions-switch-file (file &optional cwd ready source)
  "Switch the active PiChat session to FILE with its optional CWD metadata.
FILE is host-visible and is translated to a Pi runtime path.  Call READY with
the synchronized session after a successful switch.  SOURCE is the buffer
whose auxiliary-view chain should close on success; it defaults to the invoking
non-minibuffer buffer."
  (unless (and (stringp file) (not (string-empty-p (string-trim file))))
    (user-error "No saved Pi session file was selected"))
  (let* ((candidate (pichat-session-current))
         (runtime-file (pichat-sessions--runtime-file file candidate))
         (cwd-resolution (pichat-sessions--host-cwd-resolution cwd candidate))
         (session (pichat-sessions--active-session))
         (session-cwd
          (when-let ((host-cwd (plist-get cwd-resolution :path)))
            (file-name-as-directory (expand-file-name host-cwd))))
         (cwd-unmapped-p
          (and cwd-resolution
               (eq 'unavailable (plist-get cwd-resolution :status))))
         (source (or source
                     (plist-get (pichat-view-capture-origin) :buffer)
                     (current-buffer))))
    (pichat-rpc-switch-session
     session runtime-file
     (lambda (response s)
       (if (plist-get (plist-get response :data) :cancelled)
           (message "PiChat session switch cancelled")
         (pichat-sessions-clear-source-navigation s)
         (pichat-rpc-get-state
          s
          (lambda (_r _s)
            (when session-cwd
              (pichat-sessions--apply-session-cwd s session-cwd cwd))
            (let ((buffer (or (pichat-session-buffer s)
                              (and (fboundp 'pichat-chat-open)
                                   (pichat-chat-open s)
                                   (pichat-session-buffer s)))))
              (when (buffer-live-p buffer)
                (pichat-view-complete buffer source)
                (with-current-buffer buffer
                  (when session-cwd
                    (setq default-directory session-cwd))
                  (when (fboundp 'pichat-chat--rename-buffer-maybe)
                    (pichat-chat--rename-buffer-maybe s))
                  (when (fboundp 'pichat-chat-repaint)
                    (pichat-chat-repaint)))))
            (when ready (funcall ready s))
            (if cwd-unmapped-p
                (message
                 "PiChat switched session: %s (runtime working directory is not mapped: %s)"
                 file cwd)
              (message "PiChat switched session: %s" file)))))))))

(cl-defun pichat-sessions-open-file-independently
    (file &key cwd owner-directory owner-scope source-session ready error-callback
          (display-function #'pichat-chat-open))
  "Open saved session FILE in a newly created independent runtime.
CWD is saved runtime metadata.  OWNER-DIRECTORY determines the startup
location and defaults to the mapped CWD or `default-directory'.  OWNER-SCOPE,
when non-nil, is the exact immutable (KEY CWD LABEL) owner scope.
DISPLAY-FUNCTION receives the state-synchronized runtime; nil suppresses
display.  When display creates a chat buffer, PiChat starts a full transcript
synchronization before calling READY.  ERROR-CALLBACK receives a bounded
failure response and the cleaned-up runtime.  Any startup, switch,
cancellation, or state-synchronization failure stops and forgets only the new
runtime."
  (unless (and (stringp file) (not (string-empty-p (string-trim file))))
    (user-error "No saved Pi session file was selected"))
  (let* ((runtime-file (pichat-sessions--runtime-file file source-session))
         (cwd-resolution (pichat-sessions--host-cwd-resolution cwd source-session))
         (session-cwd
          (when-let ((host-cwd (plist-get cwd-resolution :path)))
            (file-name-as-directory (expand-file-name host-cwd))))
         (start-directory
          (file-name-as-directory
           (expand-file-name (or owner-directory session-cwd default-directory))))
         (session
          (if source-session
              (pichat-start-session
               start-directory owner-scope
               (list :transport (pichat-session-transport source-session)))
            (pichat-start-session start-directory owner-scope)))
         (finished nil))
    (cl-labels
        ((cleanup (response)
           (unless finished
             (setq finished t)
             (when (pichat-session-alive-p session)
               (ignore-errors (pichat-stop-session session)))
             (when-let ((buffer (pichat-session-buffer session)))
               (when (buffer-live-p buffer)
                 (let ((pichat-chat-stop-session-on-kill nil))
                   (kill-buffer buffer))))
             (when (fboundp 'pichat-forget-session)
               (pichat-forget-session session))
             (when error-callback
               (funcall error-callback response session))))
         (failure (response _response-session)
           (cleanup response))
         (state-ready (_response response-session)
           (unless finished
             (setq finished t)
             (pichat-sessions-clear-source-navigation response-session)
             (when session-cwd
               (pichat-sessions--apply-session-cwd
                response-session session-cwd cwd))
             (when display-function
               (funcall display-function response-session)
               ;; `get_state' arrived before the newly displayed chat installed
               ;; its handlers, and it contains metadata rather than entries.
               ;; Explicitly request the authoritative transcript just as the
               ;; ordinary saved-session switch path does.
               (when-let ((buffer (pichat-session-buffer response-session)))
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when (fboundp 'pichat-chat-repaint)
                       (pichat-chat-repaint))))))
             (when ready (funcall ready response-session))
             (message "PiChat opened saved session independently: %s" file)))
         (switched (response response-session)
           (if (plist-get (plist-get response :data) :cancelled)
               (cleanup (list :success nil :pichat-failure-kind 'cancelled
                              :error "PiChat session switch cancelled"))
             (pichat-rpc-get-state response-session #'state-ready #'failure))))
      (if (or (eq (pichat-session-state session) 'error)
              (not (pichat-session-alive-p session)))
          (cleanup (list :success nil :pichat-failure-kind 'process
                         :error "PiChat independent runtime failed to start"))
        (condition-case condition
            (pichat-rpc-switch-session session runtime-file
                                       #'switched #'failure)
          (error
           (cleanup (list :success nil :pichat-failure-kind 'process
                          :error (error-message-string condition)))))))
    session))

(defun pichat-sessions--choose-basic-file (&optional session)
  "Return (FILE CWD) selected for optional SESSION's runtime."
  (let* ((root (if session
                   (pichat-sessions--root-dir session)
                 (pichat-sessions--root-dir)))
         (files (if session
                    (pichat-sessions--files session)
                  (pichat-sessions--files)))
         (choices (pichat-sessions--file-choices files root)))
    (unless choices
      (user-error "No Pi session files found under %s" root))
    (let* ((choice (completing-read "Pi session: "
                                    (pichat-sessions--completion-table choices)
                                    nil t))
           (entry (assoc choice choices))
           (record (and entry (pichat-sessions--choice-record entry)))
           (file (and entry (pichat-sessions--choice-file entry)))
           (cwd (if record
                    (plist-get record :cwd)
                  (and file (plist-get (pichat-sessions--file-summary file)
                                       :cwd)))))
      (list file cwd))))

(defun pichat-sessions-browse-files-basic (&optional session)
  "Browse saved files for SESSION with synchronous built-in completion."
  (let ((session (or session (pichat-session-current))))
    (pcase-let ((`(,file ,cwd) (pichat-sessions--choose-basic-file session)))
      (pichat-sessions-switch-file file cwd))))

(defun pichat-sessions--consult-available-p ()
  "Load the optional Consult integration and return non-nil when usable."
  (and (or (featurep 'pichat-consult)
           (require 'pichat-consult nil t))
       (fboundp 'pichat-consult-available-p)
       (pichat-consult-available-p)))

(cl-defun pichat-sessions-browse-files-independently
    (&key session owner-directory owner-scope ready error-callback
          display-function basic)
  "Select a saved file and load it into a new independent runtime.
Use the archive-backed Consult browser when available, falling back to the
synchronous JSONL picker.  SESSION is the explicit runtime used for archive
capability discovery.  BASIC forces the synchronous picker.  Remaining keyword
arguments are forwarded to `pichat-sessions-open-file-independently'."
  (interactive)
  (let ((buffer (current-buffer))
        (continued nil))
    (cl-labels
        ((open-selection (file cwd)
           (pichat-sessions-open-file-independently
            file :cwd cwd :owner-directory owner-directory
            :owner-scope owner-scope :source-session session :ready ready
            :error-callback error-callback
            :display-function (or display-function #'pichat-chat-open)))
         (open-basic ()
           (pcase-let ((`(,file ,cwd)
                        (if session
                            (pichat-sessions--choose-basic-file session)
                          (pichat-sessions--choose-basic-file))))
             (open-selection file cwd)))
         (continue-once (function &rest args)
           (unless continued
             (setq continued t)
             (apply function args)))
         (archive-ready (capability)
           (continue-once #'pichat-consult-sessions
                          capability nil #'open-selection))
         (archive-unavailable (_reason)
           (continue-once #'open-basic)))
      (if (or basic
              (not (pichat-sessions--consult-available-p)))
          (open-basic)
        (pichat-archive-discover
         (or session (pichat-session-current)) buffer
         #'archive-ready #'archive-unavailable)))))

;;;###autoload
(defun pichat-sessions-browse-files (&optional basic)
  "Search saved sessions and switch PiChat to the selected source.
This browser is separate from current-file Session History.  A compatible
`pi-archive' capability from the exact active local Pi process enables rich
Consult search.  Without a live process, `pichat-archive-standalone-source' may
provide an explicitly trusted host-local capability.  BASIC, missing UI/runtime
capability, or any archive availability failure uses the synchronous JSONL file
picker.  Discovery never starts a Pi process solely for browsing."
  (interactive "P")
  (if (or basic
          (not (pichat-sessions--consult-available-p)))
      (pichat-sessions-browse-files-basic)
    (let ((session (pichat-session-current))
          (buffer (current-buffer))
          (continued nil))
      (cl-labels
          ((continue-once (function &rest args)
             (unless continued
               (setq continued t)
               (apply function args)))
           (archive-ready (capability)
             (continue-once #'pichat-consult-sessions capability))
           (archive-unavailable (_reason)
             (continue-once #'pichat-sessions-browse-files-basic)))
        (pichat-archive-discover session buffer
                                 #'archive-ready #'archive-unavailable)))))

;;;###autoload
(defun pichat-sessions-browse-related ()
  "Browse the active persisted session's archived parent and direct children.
This graph navigation is separate from the live source back/forward stacks.
Loading a relation uses the ordinary saved-session switch transaction."
  (interactive)
  (unless (pichat-sessions--consult-available-p)
    (user-error "Related session browsing requires Consult and Node.js"))
  (let* ((session (pichat-session-current))
         (session-id (and session (pichat-session-id session)))
         (session-file (and session (pichat-session-session-file session)))
         (buffer (current-buffer))
         (continued nil))
    (unless session
      (user-error "No PiChat session"))
    (unless (and (stringp session-id)
                 (not (string-empty-p (string-trim session-id)))
                 (pichat-sessions--persisted-path-p session-file))
      (user-error "Current PiChat session has no persisted archive identity"))
    (cl-labels
        ((continue-once (function &rest args)
           (unless continued
             (setq continued t)
             (apply function args)))
         (archive-ready (capability)
           (continue-once #'pichat-consult-show-current-relations
                          capability session))
         (archive-unavailable (failure)
           (continue-once
            #'message "PiChat related sessions unavailable: %s"
            (or (plist-get failure :message) "archive capability unavailable"))))
      (pichat-archive-discover session buffer
                               #'archive-ready #'archive-unavailable))))

(defun pichat-sessions--entry-for-id (id)
  "Return entry for row ID."
  (when-let ((node (gethash id pichat-sessions--nodes)))
    (pichat-sessions--node-entry node)))

(defun pichat-sessions--user-message-entry-p (entry)
  "Return non-nil when ENTRY is a Pi user-message entry."
  (and (equal (pichat-sessions--normalized-entry-type entry) "message")
       (equal (plist-get (plist-get entry :message) :role) "user")))

;;;###autoload
(defun pichat-sessions-return-to-chat ()
  "Return to this history buffer's owning live chat, or quit its window."
  (interactive)
  (let ((chat-buffer
         (and pichat-sessions-session
              (pichat-session-buffer pichat-sessions-session))))
    (pichat-view-return
     (and (buffer-live-p chat-buffer) chat-buffer))))

(defun pichat-sessions--goto-id (id)
  "Move point to visible history row with ID."
  (unless id (user-error "No target entry"))
  (let ((position (point-min)) found)
    (while (and (< position (point-max)) (not found))
      (when (equal (get-text-property position 'pichat-session-entry-id) id)
        (setq found position))
      (setq position
            (next-single-property-change
             position 'pichat-session-entry-id nil (point-max))))
    (unless found (user-error "Entry not visible: %s" id))
    (goto-char found)
    (beginning-of-line)
    (setq pichat-sessions--selected-id id)))

(defun pichat-sessions--move-to-visible-id (id)
  "Move to visible ID when non-nil, otherwise leave point unchanged."
  (when id
    (pichat-sessions--goto-id id)))

(defun pichat-sessions--adjacent-visible-id (direction)
  "Return the adjacent visible row ID in DIRECTION, bounded at the ends."
  (let* ((ids pichat-sessions--visible-rows)
         (current (pichat-sessions--entry-id-at-point))
         (index (and current (cl-position current ids :test #'equal))))
    (cond
     ((null ids) nil)
     ((null index) (if (> direction 0) (car ids) (car (last ids))))
     ((> direction 0) (nth (min (1- (length ids)) (1+ index)) ids))
     (t (nth (max 0 (1- index)) ids)))))

;;;###autoload
(defun pichat-sessions-next-entry ()
  "Move to the next visible history entry, bounded at the final row."
  (interactive)
  (pichat-sessions--move-to-visible-id
   (pichat-sessions--adjacent-visible-id 1)))

;;;###autoload
(defun pichat-sessions-previous-entry ()
  "Move to the previous visible history entry, bounded at the first row."
  (interactive)
  (pichat-sessions--move-to-visible-id
   (pichat-sessions--adjacent-visible-id -1)))

;;;###autoload
(defun pichat-sessions-first-entry ()
  "Move to the first visible history entry."
  (interactive)
  (pichat-sessions--move-to-visible-id (car pichat-sessions--visible-rows)))

;;;###autoload
(defun pichat-sessions-last-entry ()
  "Move to the last visible history entry."
  (interactive)
  (pichat-sessions--move-to-visible-id
   (car (last pichat-sessions--visible-rows))))

(defun pichat-sessions--adjacent-branch-segment-id (direction)
  "Return the next foldable branch-segment ID in DIRECTION."
  (let* ((ids pichat-sessions--visible-rows)
         (current (pichat-sessions--entry-id-at-point))
         (current-index (and current (cl-position current ids :test #'equal)))
         (candidates
          (cl-loop for id in ids
                   for index from 0
                   when (and (hash-table-p pichat-sessions--visible-foldable)
                             (gethash id pichat-sessions--visible-foldable))
                   collect (cons index id))))
    (cond
     ((null candidates) nil)
     ((null current-index)
      (if (> direction 0) (cdar candidates) (cdar (last candidates))))
     ((> direction 0)
      (cdr (cl-find-if (lambda (candidate)
                         (> (car candidate) current-index))
                       candidates)))
     (t
      (cdr (car (last (cl-remove-if-not
                       (lambda (candidate)
                         (< (car candidate) current-index))
                       candidates))))))))

;;;###autoload
(defun pichat-sessions-next-branch-segment ()
  "Move to the next visible foldable branch segment."
  (interactive)
  (pichat-sessions--move-to-visible-id
   (pichat-sessions--adjacent-branch-segment-id 1)))

;;;###autoload
(defun pichat-sessions-previous-branch-segment ()
  "Move to the previous visible foldable branch segment."
  (interactive)
  (pichat-sessions--move-to-visible-id
   (pichat-sessions--adjacent-branch-segment-id -1)))

(defun pichat-sessions--details-node-snapshot (node)
  "Return bounded printable metadata for normalized history NODE.
The raw tree node is omitted because it recursively contains the selected
node's entire descendant subtree; ENTRY is printed separately by the caller."
  (let (snapshot)
    (while node
      (let ((key (pop node))
            (value (pop node)))
        (unless (memq key '(:entry :raw-node))
          (setq snapshot (append snapshot (list key value))))))
    snapshot))

;;;###autoload
(defun pichat-sessions-show-details-at-point ()
  "Show bounded raw details for session entry at point."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (node (and id (gethash id pichat-sessions--nodes)))
         (entry (and node (pichat-sessions--node-entry node)))
         ;; Capture buffer-local session-view maps before switching buffers.
         (parent (and id pichat-sessions--parents
                      (gethash id pichat-sessions--parents)))
         (children (and id pichat-sessions--children
                        (gethash id pichat-sessions--children)))
         (buffer (get-buffer-create "*PiChat Session Entry*")))
    (unless node (user-error "No entry at point"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "ID: %s\n" id))
        (when parent
          (insert (format "Parent: %s\n" parent)))
        (when children
          (insert (format "Children: %s\n" (string-join children ", "))))
        (let ((print-circle t))
          (insert "\nEntry:\n")
          (insert (pp-to-string entry))
          (insert "\nNode:\n")
          (insert (pp-to-string
                   (pichat-sessions--details-node-snapshot node)))))
      (pichat-view-mode))
    (pichat-view-display buffer nil 'bury)))

;;;###autoload
(defun pichat-sessions-parent-at-point ()
  "Jump to the nearest visible parent of the current entry.
This unbound compatibility command follows the projected visible-model index;
it does not depend on the raw tree or `tabulated-list-mode'."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (parent (and id (hash-table-p pichat-sessions--visible-parents)
                      (gethash id pichat-sessions--visible-parents))))
    (unless parent (user-error "Current entry has no visible parent"))
    (pichat-sessions--goto-id parent)))

;;;###autoload
(defun pichat-sessions-first-child-at-point ()
  "Jump to the first visible child of the current entry.
This unbound compatibility command follows the projected visible-model index;
it does not depend on the raw tree or `tabulated-list-mode'."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (children (and id (hash-table-p pichat-sessions--visible-children)
                        (gethash id pichat-sessions--visible-children))))
    (unless children (user-error "Current entry has no visible children"))
    (pichat-sessions--goto-id (car children))))

(defun pichat-sessions--preview-node-snapshot (node)
  "Return an independent, non-recursive preview snapshot of NODE."
  (list :id (plist-get node :id)
        :entry (copy-tree (plist-get node :entry))
        :type (plist-get node :type)
        :role (plist-get node :role)
        :label (plist-get node :label)
        :label-timestamp (plist-get node :label-timestamp)
        :tool-calls (copy-tree (plist-get node :tool-calls))
        :tool-call (copy-tree (plist-get node :tool-call))))

(defun pichat-sessions--preview-path (model selected-id)
  "Return an immutable root-to-SELECTED-ID path copied from MODEL."
  (let ((id selected-id)
        (seen (make-hash-table :test #'equal))
        path)
    (while (and id (not (gethash id seen)))
      (puthash id t seen)
      (let ((node (pichat-sessions--model-node model id)))
        (unless node (setq id nil))
        (when node
          (push (pichat-sessions--preview-node-snapshot node) path)
          (setq id (pichat-sessions--model-parent-id model id)))))
    path))

(defun pichat-sessions--preview-status (model selected-id)
  "Return the branch status of SELECTED-ID in MODEL."
  (cond
   ((equal selected-id (plist-get model :leaf-id)) 'active-leaf)
   ((pichat-sessions--model-active-p model selected-id) 'active-ancestor)
   (t 'alternate)))

(defun pichat-sessions--preview-status-label (status)
  "Return user-facing text for preview STATUS."
  (pcase status
    ('active-leaf "active leaf")
    ('active-ancestor "ancestor on active path")
    (_ "alternate branch")))

(defun pichat-sessions-preview-active-snapshot (data)
  "Return an immutable active-branch preview snapshot from get_tree DATA.
The returned plist contains `:path', `:selected-id', `:status', and bounded
normalization `:diagnostics'.  An empty session produces a nil path."
  (let* ((model (pichat-sessions--tree-model-from-data data))
         (leaf-id (plist-get model :leaf-id))
         (path (and leaf-id
                    (pichat-sessions--preview-path model leaf-id))))
    (list :path path
          :selected-id leaf-id
          :status (and path
                       (pichat-sessions--preview-status model leaf-id))
          :diagnostics (copy-sequence
                        (pichat-sessions--model-diagnostics model)))))

(defun pichat-sessions-preview-active-snapshot-from-entries (entries leaf-id)
  "Return an active-branch preview snapshot from linear ENTRIES and LEAF-ID.
ENTRIES must be a root-to-leaf branch such as the branch retained by PiChat's
canonical entry cache."
  (let (nested)
    (dolist (entry (reverse entries))
      (setq nested
            (list (list :entry (copy-tree entry t) :children nested))))
    (pichat-sessions-preview-active-snapshot
     (list :tree nested :leafId leaf-id))))

(defun pichat-sessions--preview-message-has-images-p (message)
  "Return non-nil when MESSAGE contains historical image content."
  (cl-some (lambda (part)
             (and (listp part) (equal (plist-get part :type) "image")))
           (let ((content (plist-get message :content)))
             (and (listp content) content))))

(defun pichat-sessions--preview-nearest-user (path)
  "Return the nearest preceding user-message snapshot in root-first PATH."
  (cl-find-if
   (lambda (node)
     (and (equal (plist-get node :type) "message")
          (equal (plist-get node :role) "user")))
   (reverse path)))

(defun pichat-sessions--preview-insert-section (heading text)
  "Insert a preview section with HEADING and optional TEXT."
  (insert (propertize heading 'face 'bold) "\n")
  (unless (string-empty-p (string-trim (or text "")))
    (insert text "\n"))
  (insert "\n"))

(defun pichat-sessions--preview-render-node (node)
  "Insert one exact-dispatch transcript section for preview NODE."
  (let* ((entry (plist-get node :entry))
         (type (plist-get node :type))
         (message (plist-get entry :message))
         (role (plist-get node :role)))
    (pcase type
      ("message"
       (cond
        ((equal role "assistant")
         (pichat-sessions--preview-insert-section
          "ASSISTANT" (pichat-render-message-text message))
         (dolist (call (plist-get node :tool-calls))
           (pichat-sessions--preview-insert-section
            (format "TOOL CALL: %s" (or (plist-get call :name) "unknown"))
            (format "Arguments: %s"
                    (pichat-render-tool-args
                     (plist-get call :arguments))))))
        ((member role '("toolResult" "tool_result"))
         (let ((call (plist-get node :tool-call)))
           (pichat-sessions--preview-insert-section
            (format "TOOL RESULT: %s"
                    (or (plist-get call :name)
                        (plist-get message :toolName) "unknown"))
            (pichat-render-message-text message))))
        (t
         (pichat-sessions--preview-insert-section
          (upcase (replace-regexp-in-string
                   "_" " " (or role "MESSAGE")))
          (pichat-render-message-text message)))))
      ("custom_message"
       (pichat-sessions--preview-insert-section
        (format "CUSTOM MESSAGE: %s"
                (or (plist-get entry :customType) "custom"))
        (pichat-render-content (plist-get entry :content))))
      ("compaction"
       (pichat-sessions--preview-insert-section
        "COMPACTION" (or (plist-get entry :summary) "")))
      ("branch_summary"
       (pichat-sessions--preview-insert-section
        "BRANCH SUMMARY" (or (plist-get entry :summary) "")))
      ("model_change"
       (pichat-sessions--preview-insert-section
        "MODEL CHANGE"
        (format "%s%s"
                (or (plist-get entry :modelId)
                    (plist-get entry :model) "unknown")
                (if-let ((provider (plist-get entry :provider)))
                    (format " via %s" provider)
                  ""))))
      ("thinking_level_change"
       (pichat-sessions--preview-insert-section
        "THINKING LEVEL"
        (format "%s" (or (plist-get entry :thinkingLevel) "unknown"))))
      ("session_info"
       (pichat-sessions--preview-insert-section
        "SESSION INFO"
        (or (plist-get entry :name)
            (plist-get entry :sessionName) "")))
      ("label"
       (pichat-sessions--preview-insert-section
        "LABEL" (or (plist-get entry :label) "")))
      ("custom"
       (pichat-sessions--preview-insert-section
        (format "CUSTOM: %s" (or (plist-get entry :customType) "custom"))
        ""))
      (_
       (pichat-sessions--preview-insert-section
        (upcase (replace-regexp-in-string "_" " " (or type "ENTRY")))
        (or (plist-get entry :text)
            (plist-get entry :output) ""))))))

(defun pichat-sessions-insert-preview-path (path &optional selected-id)
  "Insert immutable branch preview PATH into the current buffer.
When SELECTED-ID is non-nil, return the buffer position at which that entry
starts.  This is the shared transcript renderer used by session history and
runtime-manager previews."
  (let (selected-position)
    (dolist (node path)
      (let ((start (point)))
        (when (equal (plist-get node :id) selected-id)
          (setq selected-position start))
        (pichat-sessions--preview-render-node node)
        (add-text-properties
         start (point)
         (list 'pichat-preview-entry-id (plist-get node :id)))))
    selected-position))

(defun pichat-sessions-preview--render ()
  "Render the immutable path owned by the current preview buffer."
  (let* ((selected (car (last pichat-sessions-preview--path)))
         (entry (plist-get selected :entry))
         (kind (pichat-sessions--entry-kind entry))
         (time (pichat-sessions--entry-time entry))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (propertize "Branch Preview" 'face 'bold)
            (if pichat-sessions-preview--stale-p
                "  [STALE — fork disabled]" "")
            "\n")
    (insert (format "Selected entry: %s%s\n"
                    kind (if (string-empty-p time) "" (format " at %s" time))))
    (insert (format "Status: %s\n"
                    (pichat-sessions--preview-status-label
                     pichat-sessions-preview--status)))
    (insert "f fork · t history · d details · q close\n\n")
    (let ((selected-position
           (pichat-sessions-insert-preview-path
            pichat-sessions-preview--path
            pichat-sessions-preview--selected-id)))
      (goto-char (or selected-position (point-min))))))

(defun pichat-sessions-preview--remove-event-handler ()
  "Remove the rebind handler owned by the current preview buffer."
  (when (and pichat-sessions-preview--event-handler
             pichat-sessions-preview--session)
    (pichat-off 'session-rebinding
                pichat-sessions-preview--event-handler
                pichat-sessions-preview--session))
  (setq pichat-sessions-preview--event-handler nil))

(defun pichat-sessions-preview--mark-stale ()
  "Mark the current immutable preview stale while preserving its path."
  (unless pichat-sessions-preview--stale-p
    (setq pichat-sessions-preview--stale-p t)
    (pichat-sessions-preview--render)))

(defun pichat-sessions-preview--source-current-p ()
  "Return non-nil when this preview still owns its captured source."
  (and (not pichat-sessions-preview--stale-p)
       pichat-sessions-preview--session
       (equal pichat-sessions-preview--source-token
              (pichat-sessions--session-source-token
               pichat-sessions-preview--session))))

(defun pichat-sessions-preview--install-event-handler ()
  "Subscribe the current preview to source rebinding."
  (let ((buffer (current-buffer))
        (session pichat-sessions-preview--session))
    (setq pichat-sessions-preview--event-handler
          (lambda (event-session _event _plist)
            (when (and (eq event-session session) (buffer-live-p buffer))
              (with-current-buffer buffer
                (pichat-sessions-preview--mark-stale)))))
    (pichat-on 'session-rebinding
               pichat-sessions-preview--event-handler session)))

;;;###autoload
(defun pichat-sessions-preview-branch-at-point ()
  "Preview the immutable root-to-selected branch without changing chat state."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (model (pichat-sessions--current-model))
         (path (and id model (pichat-sessions--preview-path model id)))
         (origin (current-buffer))
         (session pichat-sessions-session)
         (source-token pichat-sessions--source-token)
         (status (and id model (pichat-sessions--preview-status model id)))
         (buffer (get-buffer-create "*PiChat Branch Preview*")))
    (unless id (user-error "No entry at point"))
    (unless path (user-error "Selected entry has no previewable branch"))
    (with-current-buffer buffer
      (when (derived-mode-p 'pichat-sessions-preview-mode)
        (pichat-sessions-preview--remove-event-handler))
      (pichat-sessions-preview-mode)
      (setq pichat-sessions-preview--origin-buffer origin
            pichat-sessions-preview--session session
            pichat-sessions-preview--source-token (copy-tree source-token)
            pichat-sessions-preview--selected-id id
            pichat-sessions-preview--path path
            pichat-sessions-preview--status status
            pichat-sessions-preview--stale-p nil)
      (pichat-sessions-preview--install-event-handler)
      (pichat-sessions-preview--render))
    (pichat-view-display buffer nil 'bury)
    (when (eq (window-buffer (selected-window)) buffer)
      (let ((position (with-current-buffer buffer (point))))
        (set-window-point (selected-window) position)
        (set-window-start (selected-window) position)))))

(defalias 'pichat-sessions-show-branch-at-point
  #'pichat-sessions-preview-branch-at-point)

;;;###autoload
(defun pichat-sessions-preview-return-to-history ()
  "Return to the exact live history buffer that opened this preview."
  (interactive)
  (unless (buffer-live-p pichat-sessions-preview--origin-buffer)
    (user-error "Originating session history buffer is no longer live"))
  (pichat-view-return pichat-sessions-preview--origin-buffer))

;;;###autoload
(defun pichat-sessions-preview-show-details ()
  "Show raw details for this preview's immutable selected entry snapshot."
  (interactive)
  (let* ((selected (car (last pichat-sessions-preview--path)))
         (entry (plist-get selected :entry))
         (buffer (get-buffer-create "*PiChat Session Entry*")))
    (unless selected (user-error "Preview has no selected entry"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t)
            (print-circle t))
        (erase-buffer)
        (insert (format "ID: %s\n\nEntry:\n%s"
                        (plist-get selected :id)
                        (pp-to-string entry))))
      (pichat-view-mode))
    (pichat-view-display buffer nil 'bury)))

(defun pichat-sessions--fork-source-current-p (session source-token stale-p)
  "Return non-nil when SESSION still owns SOURCE-TOKEN and is not STALE-P."
  (and session
       (not stale-p)
       (equal source-token (pichat-sessions--session-source-token session))))

(defun pichat-sessions--capture-fork-context
    (session source-token id entry origin-buffer)
  "Capture a complete fork transaction for SESSION and user ENTRY at ID.
SOURCE-TOKEN identifies the pre-fork source and ORIGIN-BUFFER owns the command."
  (let* ((message (plist-get entry :message))
         (text (pichat-render-message-text message))
         (chat-buffer (pichat-session-buffer session)))
    (list :session session
          :source-token (copy-tree source-token)
          :source-file (pichat-session-session-file session)
          :entry-id id
          :summary (pichat-sessions--shorten
                    (if (string-empty-p (string-trim text))
                        "[empty prompt]"
                      text)
                    80)
          :has-images
          (pichat-sessions--preview-message-has-images-p message)
          :origin-buffer origin-buffer
          :chat-buffer (and (buffer-live-p chat-buffer) chat-buffer)
          :editor-generation
          (and (buffer-live-p chat-buffer)
               (buffer-local-value 'pichat-chat--editor-generation
                                   chat-buffer)))))

(defun pichat-sessions--transaction-error-text (response)
  "Return bounded user-facing error text from a transaction RESPONSE."
  (pichat-sessions--shorten
   (format "%s" (or (plist-get response :error) "unknown error")) 160))

(defun pichat-sessions--persisted-path-p (path)
  "Return non-nil when PATH can participate in source navigation."
  (and (stringp path)
       (not (string-empty-p (string-trim path)))))

(defun pichat-sessions-clear-source-navigation (session)
  "Clear fork-origin source navigation stacks for SESSION."
  (when session
    (setf (pichat-session-session-file-back-stack session) nil
          (pichat-session-session-file-forward-stack session) nil)))

(defun pichat-sessions--commit-rebind-origin (context)
  "Commit persisted source navigation after CONTEXT reaches a persisted target."
  (let* ((session (plist-get context :session))
         (source (plist-get context :source-file))
         (target (and session (pichat-session-session-file session))))
    (if (and (pichat-sessions--persisted-path-p source)
             (pichat-sessions--persisted-path-p target)
             (not (equal source target)))
        (progn
          (push source (pichat-session-session-file-back-stack session))
          (setf (pichat-session-session-file-forward-stack session) nil)
          t)
      ;; An unrepresentable transition ends the coherent persisted chain.
      (pichat-sessions-clear-source-navigation session)
      nil)))

(defun pichat-sessions--fork-result-message (context result)
  "Report prompt restoration RESULT for completed fork CONTEXT."
  (let ((warning
         (if (plist-get context :has-images)
             "; historical images were not restored (text only)"
           "")))
    (pcase result
      ('copied
       (message "Fork created; existing draft kept and fork prompt copied to kill ring%s"
                warning))
      ((or 'inserted 'replaced)
       (message "Forked from “%s”; edit the restored prompt and submit when ready%s"
                (plist-get context :summary) warning))
      (_
       (message "Fork created, but prompt restoration returned an unknown result%s"
                warning)))))

(defun pichat-sessions--finish-fork (context text)
  "Focus the rebound chat for CONTEXT and restore fork response TEXT."
  (let* ((session (plist-get context :session))
         (existing (pichat-session-buffer session))
         (buffer (if (buffer-live-p existing)
                     existing
                   (pichat-chat-open session t))))
    (when (buffer-live-p buffer)
      (if (stringp text)
          (let ((result
                 (with-current-buffer buffer
                   (prog1 (pichat-chat-input-restore-fork-text text)
                     (goto-char (point-max))))))
            (pichat-view-complete buffer (plist-get context :origin-buffer))
            (pichat-sessions--fork-result-message context result))
        (with-current-buffer buffer
          (goto-char (point-max)))
        (pichat-view-complete buffer (plist-get context :origin-buffer))
        (message "PiChat fork created, but Pi did not return prompt text; existing draft was preserved")))))

(defun pichat-sessions--request-fork (context)
  "Execute the complete fork UI transaction captured by CONTEXT."
  (let ((session (plist-get context :session))
        (id (plist-get context :entry-id)))
    (pichat-rpc-fork
     session id
     (lambda (response response-session)
       (if (plist-get (plist-get response :data) :cancelled)
           (message "PiChat fork cancelled; session history was unchanged")
         (let ((text (plist-get (plist-get response :data) :text)))
           (pichat-rpc-get-state
            response-session
            (lambda (_state-response state-session)
              (if (eq state-session session)
                  (progn
                    (pichat-sessions--commit-rebind-origin context)
                    (pichat-sessions--finish-fork context text))
                (message "PiChat fork changed sessions, but returned state for an unexpected owner")))
            (lambda (state-response _state-session)
              (message
               "PiChat fork succeeded and session changed, but state synchronization failed: %s"
               (pichat-sessions--transaction-error-text state-response)))))))
     (lambda (response _response-session)
       (message "PiChat fork failed: %s"
                (pichat-sessions--transaction-error-text response))))))

;;;###autoload
(defun pichat-sessions-preview-fork ()
  "Confirm and fork from the nearest user prompt in this preview path."
  (interactive)
  (unless (pichat-sessions-preview--source-current-p)
    (pichat-sessions-preview--mark-stale)
    (user-error "Branch preview is stale; refresh session history before forking"))
  (let* ((target (pichat-sessions--preview-nearest-user
                  pichat-sessions-preview--path))
         (entry (plist-get target :entry))
         (message (plist-get entry :message))
         (id (plist-get target :id))
         (summary (pichat-sessions--shorten
                   (pichat-render-message-text message) 80))
         (images (pichat-sessions--preview-message-has-images-p message)))
    (unless target
      (user-error "No preceding user message exists on this branch"))
    (when (yes-or-no-p
           (format "Fork from “%s” (%s)%s? "
                   summary id
                   (if images "; historical images are not restored (text only)"
                     "")))
      (pichat-sessions--request-fork
       (pichat-sessions--capture-fork-context
        pichat-sessions-preview--session
        pichat-sessions-preview--source-token
        id entry (current-buffer))))))

;;;###autoload
(defun pichat-sessions-switch-at-point ()
  "Explain how to switch saved sessions from a Session History buffer.
History entries are not session files, so this compatibility command never
constructs or sends a source path.  Use `pichat-sessions-browse-files' instead."
  (interactive)
  (user-error
   "History entries are not session files; use pichat-sessions-browse-files"))

(make-obsolete 'pichat-sessions-switch-at-point
               'pichat-sessions-browse-files "2026-07-25")

;;;###autoload
(defun pichat-sessions-fork-at-point ()
  "Fork the exact user prompt at point as a complete UI transaction."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (entry (and id (pichat-sessions--entry-for-id id))))
    (unless id (user-error "No entry at point"))
    (unless (pichat-sessions--user-message-entry-p entry)
      (user-error
       "Select a user prompt to fork; press v to preview this branch"))
    (unless (pichat-sessions--fork-source-current-p
             pichat-sessions-session pichat-sessions--source-token
             pichat-sessions--stale-p)
      (pichat-sessions--mark-stale)
      (user-error "Session history is stale; refresh before forking"))
    (pichat-sessions--request-fork
     (pichat-sessions--capture-fork-context
      pichat-sessions-session pichat-sessions--source-token
      id entry (current-buffer)))))

(defun pichat-sessions--chat-entry-position (chat-buffer id)
  "Return the start of ID's rendered node in CHAT-BUFFER, or nil."
  (with-current-buffer chat-buffer
    (let ((position (point-min)) found)
      (while (and (< position (point-max)) (not found))
        (if (equal id (get-text-property position 'pichat-node-key))
            (setq found position)
          (setq position
                (or (next-single-property-change
                     position 'pichat-node-key nil (point-max))
                    (point-max)))))
      found)))

;;;###autoload
(defun pichat-sessions-activate-at-point ()
  "Jump from the history entry at point to its active chat transcript node."
  (interactive)
  (let* ((id (pichat-sessions--entry-id-at-point))
         (session pichat-sessions-session)
         (origin (current-buffer))
         (chat-buffer (and session (pichat-session-buffer session))))
    (unless id (user-error "No entry at point"))
    (unless (and session
                 (not pichat-sessions--stale-p)
                 (equal pichat-sessions--source-token
                        (pichat-sessions--session-source-token session)))
      (pichat-sessions--mark-stale)
      (user-error "Session history is stale; refresh before jumping"))
    (unless (buffer-live-p chat-buffer)
      (user-error "Owning chat buffer is no longer live"))
    (let ((position (pichat-sessions--chat-entry-position chat-buffer id)))
      (unless position
        (user-error
         "Entry is not in the active transcript; press v to preview its branch"))
      (with-current-buffer chat-buffer
        (goto-char position))
      (pichat-view-complete chat-buffer origin)
      (when (eq (window-buffer (selected-window)) chat-buffer)
        (set-window-point (selected-window) position)))))

(defun pichat-sessions--capture-clone-context (session origin-buffer)
  "Capture clone transaction state for SESSION from ORIGIN-BUFFER."
  (let ((chat-buffer (pichat-session-buffer session)))
    (list :session session
          :source-token
          (copy-tree (pichat-sessions--session-source-token session))
          :source-file (pichat-session-session-file session)
          :origin-buffer origin-buffer
          :chat-buffer (and (buffer-live-p chat-buffer) chat-buffer)
          :editor-generation
          (and (buffer-live-p chat-buffer)
               (buffer-local-value 'pichat-chat--editor-generation
                                   chat-buffer)))))

(defun pichat-sessions--clone-identity (session)
  "Return a bounded display identity for cloned SESSION."
  (let ((id (pichat-session-id session))
        (file (pichat-session-session-file session)))
    (pichat-sessions--shorten
     (cond
      ((and id file) (format "%s (%s)" id file))
      (id (format "%s" id))
      (file (format "%s" file))
      (t "unknown identity"))
     200)))

(defun pichat-sessions--finish-clone (context)
  "Focus the cloned chat after authoritative state arrives for CONTEXT."
  (let* ((session (plist-get context :session))
         (existing (pichat-session-buffer session))
         (buffer (if (buffer-live-p existing)
                     existing
                   (pichat-chat-open session t))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-max)))
      (pichat-view-complete buffer (plist-get context :origin-buffer))
      (message "Cloned current active branch into session %s"
               (pichat-sessions--clone-identity session)))))

(defun pichat-sessions--request-clone (context)
  "Execute the complete clone transaction captured by CONTEXT."
  (let ((session (plist-get context :session)))
    (pichat-rpc-clone
     session
     (lambda (response response-session)
       (if (plist-get (plist-get response :data) :cancelled)
           (message "PiChat clone cancelled; session history was unchanged")
         (pichat-rpc-get-state
          response-session
          (lambda (_state-response state-session)
            (if (eq state-session session)
                (progn
                  (pichat-sessions--commit-rebind-origin context)
                  (pichat-sessions--finish-clone context))
              (message "PiChat clone changed sessions, but returned state for an unexpected owner")))
          (lambda (state-response _state-session)
            (message
             "PiChat clone succeeded and session changed, but state synchronization failed: %s"
             (pichat-sessions--transaction-error-text state-response))))))
     (lambda (response _response-session)
       (message "PiChat clone failed: %s"
                (pichat-sessions--transaction-error-text response))))))

;;;###autoload
(defun pichat-sessions-clone-current ()
  "Clone Pi's current active branch, regardless of the selected history row."
  (interactive)
  (unless pichat-sessions-session
    (user-error "No PiChat session to clone"))
  (if (yes-or-no-p
       "Clone the current active branch (not the selected history row)? ")
      (pichat-sessions--request-clone
       (pichat-sessions--capture-clone-context
        pichat-sessions-session (current-buffer)))
    (message "PiChat clone cancelled; session history was unchanged")))

(defun pichat-sessions--focus-navigated-session
    (session direction target source)
  "Focus SESSION after navigation in DIRECTION to TARGET from SOURCE."
  (let* ((existing (pichat-session-buffer session))
         (buffer (if (buffer-live-p existing)
                     existing
                   (pichat-chat-open session t))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (goto-char (point-max)))
      (pichat-view-complete buffer source)
      (message "PiChat moved %s to source session: %s"
               direction (pichat-sessions--shorten target 200)))))

(defun pichat-sessions--request-source-navigation
    (session direction target current remaining opposite source)
  "Switch SESSION in DIRECTION from CURRENT to TARGET.
REMAINING is the captured remainder of the source stack and OPPOSITE is the
captured destination stack.  SOURCE is the invoking buffer.  Stack mutation
occurs only after switch success."
  (pichat-rpc-switch-session
   session target
   (lambda (response response-session)
     (if (plist-get (plist-get response :data) :cancelled)
         (message "PiChat source navigation cancelled; history was unchanged")
       (if (eq direction 'back)
           (setf (pichat-session-session-file-back-stack session) remaining
                 (pichat-session-session-file-forward-stack session)
                 (cons current opposite))
         (setf (pichat-session-session-file-forward-stack session) remaining
               (pichat-session-session-file-back-stack session)
               (cons current opposite)))
       (pichat-rpc-get-state
        response-session
        (lambda (_state-response state-session)
          (if (eq state-session session)
              (pichat-sessions--focus-navigated-session
               session direction target source)
            (message "PiChat source navigation returned state for an unexpected owner")))
        (lambda (state-response _state-session)
          (message
           "PiChat source session changed, but state synchronization failed: %s"
           (pichat-sessions--transaction-error-text state-response))))))
   (lambda (response _response-session)
     (message "PiChat source navigation failed: %s"
              (pichat-sessions--transaction-error-text response)))))

(defun pichat-sessions--navigate-source (direction)
  "Navigate the current session source in DIRECTION, either `back' or `forward'."
  (let* ((session (pichat-session-current))
         (current (and session (pichat-session-session-file session)))
         (source-stack
          (and session
               (if (eq direction 'back)
                   (pichat-session-session-file-back-stack session)
                 (pichat-session-session-file-forward-stack session))))
         (opposite
          (and session
               (if (eq direction 'back)
                   (pichat-session-session-file-forward-stack session)
                 (pichat-session-session-file-back-stack session))))
         (target (car source-stack)))
    (unless session
      (user-error "No PiChat session"))
    (unless (pichat-sessions--persisted-path-p current)
      (user-error "Current PiChat session has no persisted source file"))
    (unless (pichat-sessions--persisted-path-p target)
      (user-error "No persisted %s source session is available"
                  (if (eq direction 'back) "previous" "forward")))
    (pichat-sessions--request-source-navigation
     session direction target current (cdr source-stack) opposite
     (current-buffer))))

;;;###autoload
(defun pichat-sessions-return-to-origin ()
  "Return to the previous persisted source session in this fork/clone chain.
Both the current and previous sources must have nonblank session-file paths."
  (interactive)
  (pichat-sessions--navigate-source 'back))

;;;###autoload
(defun pichat-sessions-forward-to-fork ()
  "Move forward to the next persisted fork/clone source session.
Both the current and forward sources must have nonblank session-file paths."
  (interactive)
  (pichat-sessions--navigate-source 'forward))

;;;###autoload
(defun pichat-open-permissions-file (&optional local)
  "Open project `.pi/permissions.json', or local override with LOCAL prefix."
  (interactive "P")
  (let* ((session (pichat-session-current))
         (root (or (and session (pichat-session-cwd session))
                   default-directory))
         (file (expand-file-name (if local ".pi/permissions.local.json" ".pi/permissions.json") root)))
    (find-file file)))

;;;###autoload
(defun pichat-open-permission-log ()
  "Open newest pi-permission-gate log for current project."
  (interactive)
  (let* ((session (pichat-session-current))
         (root (or (and session (pichat-session-cwd session))
                   default-directory))
         (dir (expand-file-name ".pi/logs" root))
         (files (and (file-directory-p dir)
                     (directory-files dir t "permission-gate_.*\\.jsonl\\'")))
         (newest (car (sort files #'file-newer-than-file-p))))
    (unless newest (user-error "No permission-gate log found under %s" dir))
    (find-file newest)))

(provide 'pichat-sessions)
;;; pichat-sessions.el ends here
