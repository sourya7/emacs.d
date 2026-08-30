;;; pichat-chat.el --- Basic PiChat chat buffer -*- lexical-binding: t; -*-

;;; Commentary:

;; MVP chat UI using a plain Emacs buffer and Pi RPC events.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'ansi-color)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-events)
(require 'pichat-rpc)
(require 'pichat-pi)
(require 'pichat-render)
(require 'pichat-markdown-fontification)
(require 'pichat-markdown-presentation)
(require 'pichat-reference)
(require 'pichat-commands)
(require 'pichat-sessions)
(require 'pichat-tools)
(require 'pichat-tool-enrichment)
(require 'pichat-shell-presentation)
(require 'pichat-chat-tool-ui)
(require 'pichat-chat-activity-ui)
(require 'pichat-chat-completion)
(require 'pichat-chat-input)
(require 'pichat-chat-diagnostics)
(require 'pichat-chat-navigation)
(require 'pichat-response-view)
(require 'pichat-view)
(require 'pichat-bridge-transport)

(defvar pichat-current-session)
(defvar pichat--sessions-by-scope)

(defcustom pichat-chat-show-lifecycle-events nil
  "When non-nil, show normal Pi lifecycle events in chat transcripts."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-ret-sends t
  "When non-nil, RET sends the prompt and S-RET inserts a newline.
When nil, C-c C-c sends and RET inserts a newline."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-stop-session-on-kill t
  "When non-nil, killing a PiChat chat buffer stops its RPC session."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-collapse-tools-by-default t
  "When non-nil, completed tool blocks default to summary display."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-tool-default-display 'summary
  "Default display state for completed tool blocks.
`summary' shows only the tool header, `args' also shows arguments, and
`output' shows arguments plus truncated inline output.  When
`pichat-chat-collapse-tools-by-default' is non-nil, completed tools use
`summary' regardless of this value."
  :type '(choice (const :tag "Header only" summary)
                 (const :tag "Header and args" args)
                 (const :tag "Header, args, and output" output))
  :group 'pichat)

(defcustom pichat-chat-activity-group-display 'latest
  "Default disclosure policy for agent activity groups.
`latest' expands only current live tail activity, `collapsed' folds every
group, and `expanded' opens every group.  Explicit per-group choices override
this policy without changing individual tool display state."
  :type '(choice (const :tag "Current live activity only" latest)
                 (const :tag "Collapse all activity" collapsed)
                 (const :tag "Expand all activity" expanded))
  :group 'pichat)

(defcustom pichat-chat-max-tool-output-chars 4000
  "Maximum tool output characters shown inline before truncation."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-max-tool-args-chars 300
  "Maximum tool argument characters shown in a tool header."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-max-extension-notification-chars 16000
  "Maximum characters retained for one extension notification."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-render-markdown t
  "When non-nil, fontify completed assistant prose as Markdown.
This uses `markdown-mode' when available, but PiChat still works without it."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-show-thinking t
  "When non-nil, show assistant thinking blocks inline.
When nil, thinking blocks are omitted from the chat transcript."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-max-width 120
  "Maximum visual width of PiChat chat buffers before wrapping.
When nil, PiChat wraps at the window edge.  When non-nil and
`visual-fill-column' is available, PiChat visually wraps at this width."
  :type '(choice (const :tag "Window width" nil)
                 integer)
  :group 'pichat)

(defcustom pichat-chat-tool-truncation-notice-format
  "\n\n[… %d chars truncated; use C-c C-d on the tool block for full output]"
  "Format string used for truncated tool output notices."
  :type 'string
  :group 'pichat)

(defcustom pichat-chat-live-update-delay 0.03
  "Seconds used to coalesce high-frequency live-tail projections."
  :type 'number
  :group 'pichat)

(defcustom pichat-chat-tool-call-update-delay 0.2
  "Seconds used to throttle streamed tool-call argument projections.
Every RPC delta still updates normalized live state; this only limits how often
large cumulative argument snapshots are rendered."
  :type 'number
  :group 'pichat)

(defcustom pichat-chat-extension-status-update-delay 0.1
  "Seconds during which successive extension status updates are coalesced."
  :type 'number
  :group 'pichat)

(defcustom pichat-chat-follow-bottom-threshold 2
  "Number of characters from `point-max' considered to be at the chat tail.
PiChat auto-follows asynchronous output only when the visible window was already
showing the tail before the update.  A small threshold avoids false negatives
from final newlines or redisplay edge cases."
  :type 'integer
  :group 'pichat)

(declare-function visual-fill-column-mode "visual-fill-column")
(declare-function pichat-select-model "pichat" (&optional session))
(declare-function pichat-stop-session "pichat" (&optional session))
(declare-function pichat-forget-session "pichat" (session))
(declare-function pichat-note-session-updated "pichat" (session))
(defvar visual-fill-column-width)
(defvar visual-fill-column-center-text)

(defface pichat-user-block-face
  '((((class color) (min-colors 88) (background light))
     :inherit default :background "gray92" :extend t)
    (((class color) (min-colors 88) (background dark))
     :inherit default :background "gray18" :extend t)
    (t :inherit highlight :extend t))
  "Face for submitted PiChat user message blocks."
  :group 'pichat)

(defface pichat-input-block-face
  '((((class color) (min-colors 88) (background light))
     :inherit default :background "gray95" :extend t)
    (((class color) (min-colors 88) (background dark))
     :inherit default :background "gray15" :extend t)
    (t :inherit highlight :extend t))
  "Face for the live PiChat input area."
  :group 'pichat)

(defface pichat-input-bar-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the PiChat input/user left bar."
  :group 'pichat)

(defface pichat-tool-label-face
  '((t :inherit font-lock-comment-face :weight bold))
  "Face for PiChat tool labels."
  :group 'pichat)

(defface pichat-thinking-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for PiChat thinking blocks."
  :group 'pichat)

(defconst pichat-chat--thinking-levels
  '("off" "minimal" "low" "medium" "high" "xhigh" "max")
  "Pi thinking levels in protocol cycle order.")

(defvar-local pichat-chat-session nil
  "PiChat session associated with this buffer.")

(defvar-local pichat-chat--thinking-control-error nil
  "Non-nil when the most recent thinking control request failed.")

(defvar-local pichat-chat--prompt-start nil
  "Marker at the beginning of the current prompt line.")

(defvar-local pichat-chat--input-start nil
  "Marker at the beginning of the editable input area.")

(defvar-local pichat-chat--inhibit-edit-guard nil
  "Non-nil while PiChat is programmatically editing the chat buffer.")

(defvar-local pichat-chat--handlers nil
  "Session event handlers installed by this chat buffer.")

(defvar-local pichat-chat--entry-cache nil
  "Authoritative Pi session-entry cache for this chat buffer.")

(defvar-local pichat-chat--canonical-transcript nil
  "Last successfully projected canonical transcript.")

(defvar-local pichat-chat--live-draft nil
  "Transient RPC-event transcript since the last successful sync.")

(defvar-local pichat-chat--live-projection-timer nil
  "Pending coalesced live-tail projection timer.")

(defvar-local pichat-chat--live-projection-priority nil
  "Priority of the pending live projection, either `normal' or `urgent'.")

(defvar-local pichat-chat--live-projection-fingerprint nil
  "Fingerprint of the last committed live-tail presentation.")

(defvar-local pichat-chat--live-projection-fragments nil
  "Committed logical live fragments with buffer boundary markers.")

(defvar-local pichat-chat--projection-transaction-depth 0
  "Current nesting depth of an atomic projection transaction.")

(defvar pichat-chat--focused-change-group-active-p nil
  "Non-nil while a focused live transaction records private undo data.")

(defvar-local pichat-chat--editor-generation 0
  "Generation incremented by user edits to the prompt.")

(defvar-local pichat-chat--canonical-start nil
  "Marker at the start of the canonical transcript region.")

(defvar-local pichat-chat--canonical-end nil
  "Marker at the end of the canonical transcript region.")

(defvar-local pichat-chat--live-start nil
  "Marker at the start of the transient live-tail region.")

(defvar-local pichat-chat--live-end nil
  "Marker at the end of the transient live-tail region.")

(defvar-local pichat-chat--extension-status-start nil
  "Marker at the start of the persistent extension-status region.")

(defvar-local pichat-chat--extension-status-end nil
  "Marker at the end of the persistent extension-status region.")

(defvar-local pichat-chat--status-start nil
  "Marker at the start of the diagnostic/status region.")

(defvar-local pichat-chat--status-end nil
  "Marker at the end of the diagnostic/status region.")

(defvar-local pichat-chat--status-lines nil
  "Alist of bounded status lines keyed by lifecycle category.")

(defvar-local pichat-chat--source-generation 0
  "Generation of the Pi session identity bound to this buffer.")

(defvar-local pichat-chat--source-bound-p nil
  "Non-nil after this buffer captures its first Pi session identity.")

(defvar-local pichat-chat--source-rebinding-p nil
  "Non-nil after rebind success and before fresh state arrives.")

(defvar-local pichat-chat--source-session-id nil
  "Pi session id associated with the current source generation.")

(defvar-local pichat-chat--source-session-file nil
  "Pi session file associated with the current source generation.")

(defvar-local pichat-chat--sync-sequence 0
  "Monotonic canonical synchronization request sequence.")

(defvar-local pichat-chat--sync-in-flight nil
  "Generation number of the active canonical synchronization.")

(defvar-local pichat-chat--sync-in-flight-full-p nil
  "Non-nil when the active synchronization is already a full fetch.")

(defvar-local pichat-chat--sync-request-id nil
  "RPC request id owned by the active canonical synchronization.")

(defvar-local pichat-chat--sync-pending nil
  "Pending synchronization kind, either `incremental' or `full'.")

(defvar-local pichat-chat--stats-sequence 0
  "Monotonic generation for context-usage stats requests.")

(defvar-local pichat-chat--stats-in-flight nil
  "Generation token of the active context-usage stats request.")

(defvar-local pichat-chat--stats-request-id nil
  "RPC request id owned by the active context-usage refresh.")

(defvar-local pichat-chat--stats-pending nil
  "Newest context-usage refresh boundary waiting behind an active request.")

(defvar-local pichat-chat--stats-run-covered-p nil
  "Non-nil when stats cover the latest turn of the active agent run.")

(defvar-local pichat-chat--tool-blocks nil
  "Combined canonical and live tool blocks used by interactive commands.")

(defvar-local pichat-chat--canonical-tool-blocks nil
  "Tool blocks owned by the stable canonical transcript region.")

(defvar-local pichat-chat--live-tool-blocks nil
  "Tool blocks owned by the replaceable live-tail region.")

(defvar-local pichat-chat--tool-view-states nil
  "Tool display states keyed by source-local tool call id.")

(defvar-local pichat-chat--activity-blocks nil
  "Combined canonical and live activity group blocks.")

(defvar-local pichat-chat--canonical-activity-blocks nil
  "Activity group blocks owned by the canonical region.")

(defvar-local pichat-chat--live-activity-blocks nil
  "Activity group blocks owned by the live-tail region.")

(defvar-local pichat-chat--activity-view-states nil
  "Explicit activity disclosure states keyed by source-local identity.")

(defvar-local pichat-chat--tool-auxiliary-details nil
  "Non-persisted live tool details keyed by tool call id.")

(defvar-local pichat-chat--tool-enrichments nil
  "Generation-scoped presentation metadata keyed by tool call id.")

(defvar-local pichat-chat--queue-counts '(0 . 0)
  "Cons of steering and follow-up queue counts.")

(defvar-local pichat-chat--pending-ui-count 0
  "Number of pending dialog-like extension UI requests.")

(defvar-local pichat-chat--extension-statuses nil
  "Hash table mapping extension UI status keys to their latest text.")

(defvar-local pichat-chat--extension-status-timer nil
  "Cooldown timer coalescing successive extension status projections.")

(defvar-local pichat-chat--extension-status-dirty-p nil
  "Non-nil when extension status state changed during its cooldown.")

(defvar-local pichat-chat--extension-notifications nil
  "Buffer-local extension notifications anchored to canonical transcript nodes.")

(defvar-local pichat-chat--extension-widgets nil
  "Hash table mapping extension widget keys to line/placement plists.")

(defvar-local pichat-chat--extension-title nil
  "Latest title requested by a Pi extension.")

(defvar-local pichat-chat--widget-start nil
  "Marker at the start of the rendered extension widget area.")

(defvar-local pichat-chat--widget-end nil
  "Marker at the end of the rendered extension widget area.")

(defvar-local pichat-chat--pending-ui-requests nil
  "Hash table of pending dialog extension UI requests by request id.")

(defvar-local pichat-chat--pending-ui-queue nil
  "Dialog extension UI requests waiting for interaction.")

(defvar-local pichat-chat--active-ui-request nil
  "Request id of the dialog currently interacting with the user.")

(defvar-local pichat-chat--scheduled-ui-request nil
  "Request id scheduled for an eligibility-checked interaction.")

(defvar-local pichat-chat--scheduled-ui-timer nil
  "Timer scheduled to activate `pichat-chat--scheduled-ui-request'.")

(defvar-local pichat-chat--ui-schedule-generation 0
  "Generation used to reject stale extension UI activation callbacks.")

(defun pichat-chat-beginning-of-line (&optional arg)
  "Move to beginning of line, stopping after PiChat's read-only input prefix.
On the live input line, this lands at `pichat-chat--input-start' instead of
before the protected left-bar prefix.  With ARG other than 1, delegate to
`move-beginning-of-line'."
  (interactive "^p")
  (let ((arg (or arg 1))
        (input-pos (and (markerp pichat-chat--input-start)
                        (marker-position pichat-chat--input-start))))
    (if (and (= arg 1)
             input-pos
             (pichat-chat--prompt-live-p)
             (<= (line-beginning-position) input-pos)
             (<= input-pos (line-end-position)))
        (goto-char input-pos)
      (move-beginning-of-line arg))))

(define-minor-mode pichat-chat-markdown-mode
  "Fontify completed PiChat assistant responses as Markdown.
Markup characters remain visible; this is fontification only."
  :lighter " md"
  :group 'pichat)

(defvar pichat-chat-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-ret)
    (define-key map (kbd "S-<return>") #'newline)
    (define-key map (kbd "C-c C-c") #'pichat-chat-send-input)
    (define-key map (kbd "C-c C-k") #'pichat-chat-abort)
    (define-key map (kbd "C-c C-s") #'pichat-chat-steer)
    (define-key map (kbd "C-c C-f") #'pichat-chat-follow-up)
    (define-key map (kbd "C-c C-o") #'pichat-chat-compact)
    (define-key map (kbd "C-c C-n") #'pichat-chat-new-session)
    (define-key map (kbd "C-c C-e") #'pichat-chat-set-session-name)
    (define-key map (kbd "C-c C-m") #'pichat-chat-cycle-model)
    (define-key map (kbd "C-c C-t") #'pichat-chat-cycle-thinking-level)
    (define-key map (kbd "C-c C-r") #'pichat-sessions-browse-related)
    (define-key map (kbd "C-c C-y") #'pichat-chat-recover-submission)
    (define-key map (kbd "C-c C-i") #'pichat-chat-attach-image-file)
    (define-key map (kbd "C-c C-u") #'pichat-chat-paste-clipboard-image)
    (define-key map (kbd "C-c C-j") #'pichat-chat-screenshot)
    (define-key map (kbd "C-c C-q") #'pichat-chat-remove-attachment)
    (define-key map (kbd "C-c C-x") #'pichat-command-run)
    (define-key map (kbd "C-c C-p") #'pichat-sessions-list)
    (define-key map (kbd "C-c C-b") #'pichat-sessions-browse-files)
    (define-key map (kbd "C-c C-z") #'pichat-chat-toggle-tool-at-point)
    (define-key map (kbd "C-c C-;") #'pichat-chat-toggle-activity-at-point)
    (define-key map (kbd "C-c C-d") #'pichat-chat-show-tool-details)
    (define-key map (kbd "C-c C-g") #'pichat-chat-visit-tool-location)
    (define-key map (kbd "C-c C-w") #'pichat-chat-copy-tool-location)
    (define-key map (kbd "C-c C-v") #'pichat-chat-repaint)
    (define-key map (kbd "C-c C-l") #'pichat-chat-toggle-link-at-point)
    (define-key map (kbd "C-c C-a") #'pichat-chat-toggle-table-at-point)
    (define-key map (kbd "C-c C-<return>")
                #'pichat-chat-open-table-at-point)
    (define-key map (kbd "M-n") #'pichat-chat-next-tool)
    (define-key map (kbd "M-p") #'pichat-chat-previous-tool)
    (define-key map (kbd "C-c M-n") #'pichat-chat-next-user-turn)
    (define-key map (kbd "C-c M-p") #'pichat-chat-previous-user-turn)
    (define-key map (kbd "C-c C-.") #'pichat-chat-jump-to-active-item)
    (define-key map (kbd "C-c C-,") #'pichat-chat-open-compose-buffer)
    (define-key map (kbd "C-c C-h") #'pichat-chat-view-response)
    (define-key map (kbd "M-<up>") #'pichat-chat-history-previous)
    (define-key map (kbd "M-<down>") #'pichat-chat-history-next)
    (define-key map [remap move-beginning-of-line]
                #'pichat-chat-beginning-of-line)
    (define-key map [remap beginning-of-line]
                #'pichat-chat-beginning-of-line)
    (define-key map [remap beginning-of-line-text]
                #'pichat-chat-beginning-of-line)
    (define-key map [remap evil-beginning-of-line]
                #'pichat-chat-beginning-of-line)
    map)
  "Keymap for `pichat-chat-mode'.")

(defun pichat-chat--setup-visual-width ()
  "Configure PiChat visual wrapping."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (when pichat-max-width
    (setq-local fill-column pichat-max-width)
    (when (require 'visual-fill-column nil t)
      (setq-local visual-fill-column-width pichat-max-width)
      (setq-local visual-fill-column-center-text nil)
      (visual-fill-column-mode 1))))

(define-derived-mode pichat-chat-mode text-mode "PiChat"
  "Major mode for chatting with Pi.

`C-c C-p' opens Session History for every branch in the current session file;
it forks into new sessions and does not perform same-file tree navigation.
`C-c C-b' separately browses saved session files and switches sources.
`C-c C-r' browses the active persisted session's archived parent and children."
  (pichat-chat--setup-visual-width)
  (add-hook 'kill-buffer-hook #'pichat-chat--cancel-pending-ui-requests nil t)
  (add-hook 'kill-buffer-hook #'pichat-chat--cancel-live-projection nil t)
  (add-hook 'kill-buffer-hook
            #'pichat-chat--cancel-extension-status-projection nil t)
  (add-hook 'kill-buffer-hook #'pichat-chat--cancel-sync-request nil t)
  (add-hook 'kill-buffer-hook #'pichat-chat--cancel-stats-request nil t)
  (pichat-markdown-presentation-setup)
  (add-hook 'kill-buffer-hook #'pichat-chat--remove-event-handlers nil t)
  (add-hook 'kill-buffer-hook #'pichat-chat--stop-session-on-kill nil t)
  (add-hook 'kill-buffer-hook #'pichat-chat--release-session-buffer nil t)
  (add-hook 'completion-at-point-functions
            #'pichat-chat--slash-command-capf nil t)
  (add-hook 'post-command-hook
            #'pichat-chat--maybe-start-next-ui-request nil t)
  (add-hook 'focus-in-hook
            #'pichat-chat--maybe-start-next-ui-request nil t)
  (setq-local pichat-chat--prompt-start (make-marker))
  (setq-local pichat-chat--input-start (make-marker))
  (setq-local pichat-chat--entry-cache nil)
  (setq-local pichat-chat--canonical-transcript nil)
  (setq-local pichat-chat--live-draft (pichat-live-draft-empty 0))
  (setq-local pichat-chat--live-projection-timer nil)
  (setq-local pichat-chat--live-projection-priority nil)
  (setq-local pichat-chat--live-projection-fingerprint nil)
  (setq-local pichat-chat--live-projection-fragments nil)
  (setq-local pichat-chat--projection-transaction-depth 0)
  (setq-local pichat-chat--editor-generation 0)
  (pichat-chat-input-initialize)
  (setq-local pichat-chat--canonical-start (make-marker))
  (setq-local pichat-chat--canonical-end (make-marker))
  (setq-local pichat-chat--live-start (make-marker))
  (setq-local pichat-chat--live-end (make-marker))
  (setq-local pichat-chat--extension-status-start (make-marker))
  (setq-local pichat-chat--extension-status-end (make-marker))
  (setq-local pichat-chat--status-start (make-marker))
  (setq-local pichat-chat--status-end (make-marker))
  (setq-local pichat-chat--status-lines nil)
  (setq-local pichat-chat--source-generation 0)
  (setq-local pichat-chat--source-bound-p nil)
  (setq-local pichat-chat--source-rebinding-p nil)
  (setq-local pichat-chat--source-session-id nil)
  (setq-local pichat-chat--source-session-file nil)
  (setq-local pichat-chat--thinking-control-error nil)
  (pichat-chat-completion-reset pichat-chat--source-generation nil)
  (setq-local pichat-chat--sync-sequence 0)
  (setq-local pichat-chat--sync-in-flight nil)
  (setq-local pichat-chat--sync-in-flight-full-p nil)
  (setq-local pichat-chat--sync-request-id nil)
  (setq-local pichat-chat--sync-pending nil)
  (setq-local pichat-chat--stats-sequence 0)
  (setq-local pichat-chat--stats-in-flight nil)
  (setq-local pichat-chat--stats-request-id nil)
  (setq-local pichat-chat--stats-pending nil)
  (setq-local pichat-chat--stats-run-covered-p nil)
  (setq-local pichat-chat--tool-blocks (make-hash-table :test #'equal))
  (setq-local pichat-chat--canonical-tool-blocks
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--live-tool-blocks
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--tool-view-states (make-hash-table :test #'equal))
  (setq-local pichat-chat--activity-blocks (make-hash-table :test #'equal))
  (setq-local pichat-chat--canonical-activity-blocks
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--live-activity-blocks
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--activity-view-states
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--tool-auxiliary-details
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--tool-enrichments
              (make-hash-table :test #'equal))
  (setq-local pichat-chat--extension-statuses (make-hash-table :test #'equal))
  (setq-local pichat-chat--extension-status-timer nil)
  (setq-local pichat-chat--extension-status-dirty-p nil)
  (setq-local pichat-chat--extension-notifications nil)
  (setq-local pichat-chat--extension-widgets (make-hash-table :test #'equal))
  (setq-local pichat-chat--pending-ui-requests (make-hash-table :test #'equal))
  (setq-local pichat-chat--pending-ui-queue nil)
  (setq-local pichat-chat--active-ui-request nil)
  (setq-local pichat-chat--scheduled-ui-request nil)
  (setq-local pichat-chat--scheduled-ui-timer nil)
  (setq-local pichat-chat--ui-schedule-generation 0)
  (setq-local pichat-chat--extension-title nil)
  (setq-local pichat-chat--widget-start (make-marker))
  (setq-local pichat-chat--widget-end (make-marker))
  (setq-local mode-line-format
              '(" " mode-line-buffer-identification
                "  " (:eval (pichat-chat--mode-line-status))))
  (add-hook 'before-change-functions #'pichat-chat--before-change nil t)
  (add-hook 'after-change-functions #'pichat-chat--after-change-style-input nil t)
  (when pichat-chat-render-markdown
    (pichat-chat-markdown-mode 1)))

(defun pichat-chat--remove-event-handlers ()
  "Unregister event handlers installed by the current chat buffer."
  (when (and pichat-chat-session pichat-chat--handlers)
    (dolist (pair pichat-chat--handlers)
      (pichat-off (car pair) (cdr pair) pichat-chat-session))
    (setq pichat-chat--handlers nil)))

(defun pichat-chat--release-session-buffer ()
  "Clear this chat buffer from its runtime without changing the runtime."
  (when (and pichat-chat-session
             (eq (pichat-session-buffer pichat-chat-session) (current-buffer)))
    (setf (pichat-session-buffer pichat-chat-session) nil)
    (when (fboundp 'pichat-note-session-updated)
      (pichat-note-session-updated pichat-chat-session))))

(defun pichat-chat--stop-session-on-kill ()
  "Stop and forget this chat buffer's runtime session when configured."
  (when (and pichat-chat-stop-session-on-kill pichat-chat-session)
    (let ((session pichat-chat-session))
      (if (fboundp 'pichat-stop-session)
          (pichat-stop-session session)
        (when (pichat-session-alive-p session)
          (pichat-rpc-stop session)))
      (when (fboundp 'pichat-forget-session)
        (pichat-forget-session session)))))

(defun pichat-chat--short-session-id (session)
  "Return a compact display id for SESSION.
Use its scope label as a unique provisional identity until Pi reports an id."
  (let ((id (pichat-session-id session))
        (label (pichat-session-scope-label session)))
    (cond
     ((and (stringp id) (not (string-empty-p id)))
      (substring id 0 (min 8 (length id))))
     ((and (stringp label) (not (string-empty-p label))) label)
     (t "pending"))))

(defun pichat-chat--project-name (session)
  "Return SESSION's immutable owner project name, or nil for global scope."
  (let ((scope-key (pichat-session-owner-scope-key session))
        (directory (pichat-session-owner-directory session)))
    (when (and (stringp directory)
               (not (or (equal scope-key "global")
                        (and (stringp scope-key)
                             (string-prefix-p "global|" scope-key)))))
      (file-name-nondirectory (directory-file-name directory)))))

(defun pichat-chat-buffer-name (session)
  "Return chat buffer name for SESSION."
  (let ((short-id (pichat-chat--short-session-id session))
        (project-name (pichat-chat--project-name session)))
    (if project-name
        (format "*PiChat:%s:%s*" project-name short-id)
      (format "*PiChat:%s*" short-id))))

(defun pichat-chat--rename-buffer-maybe (&optional session)
  "Rename the current chat buffer to match SESSION's compact identity."
  (when-let ((s (or session pichat-chat-session)))
    (let ((name (pichat-chat-buffer-name s)))
      (unless (string= (buffer-name) name)
        (rename-buffer name t)))))

(defun pichat-chat--source-identity-changed-p (session-id session-file)
  "Return non-nil when SESSION-ID/SESSION-FILE identify another source."
  (cond
   ((or pichat-chat--source-session-id session-id)
    (not (equal pichat-chat--source-session-id session-id)))
   (t
    (not (equal pichat-chat--source-session-file session-file)))))

(defun pichat-chat--completion-source-key ()
  "Return the stable identity key for source-scoped prompt completion."
  (if pichat-chat--source-session-id
      (list :session-id pichat-chat--source-session-id)
    (and pichat-chat--source-session-file
         (list :session-file pichat-chat--source-session-file))))

(defun pichat-chat--refresh-slash-commands (&optional session)
  "Refresh source-scoped slash commands for SESSION."
  (when-let ((session (or session pichat-chat-session)))
    (pichat-chat-completion-refresh
     session pichat-chat--source-generation
     (pichat-chat--completion-source-key) (current-buffer))))

(defun pichat-chat--slash-command-capf ()
  "Offer Pi slash commands at the beginning of the editable input."
  (pichat-chat-completion-capf pichat-chat--input-start))

(defun pichat-chat--release-tool-blocks ()
  "Release markers and overlays owned by all current tool blocks."
  (pichat-chat-tool-ui-release-blocks pichat-chat--canonical-tool-blocks)
  (pichat-chat-tool-ui-release-blocks pichat-chat--live-tool-blocks))

(defun pichat-chat--release-live-tool-blocks ()
  "Release markers and overlays owned only by live-tail tool blocks."
  (pichat-chat-tool-ui-release-blocks pichat-chat--live-tool-blocks))

(defun pichat-chat--release-activity-blocks ()
  "Release markers owned by all current activity group blocks."
  (pichat-chat-activity-ui-release-blocks
   pichat-chat--canonical-activity-blocks)
  (pichat-chat-activity-ui-release-blocks pichat-chat--live-activity-blocks))

(defun pichat-chat--release-live-activity-blocks ()
  "Release markers owned only by live-tail activity group blocks."
  (pichat-chat-activity-ui-release-blocks pichat-chat--live-activity-blocks))

(defun pichat-chat--release-live-projection-fragments (&optional fragments)
  "Release boundary markers owned by live FRAGMENTS or current state."
  (dolist (fragment (or fragments pichat-chat--live-projection-fragments))
    (dolist (key '(:start :end))
      (when-let ((marker (plist-get fragment key)))
        (when (markerp marker) (set-marker marker nil))))))

(defun pichat-chat--live-tool-view-key (tool-id)
  "Return source-scoped explicit view key for live TOOL-ID."
  (pichat-chat-tool-ui-live-view-key
   pichat-chat--source-generation tool-id))

(defun pichat-chat--canonical-tool-view-key (node-key tool-id)
  "Return durable explicit view key for NODE-KEY and TOOL-ID."
  (pichat-chat-tool-ui-canonical-view-key node-key tool-id))

(defun pichat-chat--tool-explicit-view (node-key tool-id live-p)
  "Return explicit view for TOOL-ID, or nil when it uses policy defaults."
  (pichat-chat-tool-ui-explicit-view
   pichat-chat--tool-view-states pichat-chat--source-generation
   node-key tool-id live-p))

(defun pichat-chat--cancel-sync-request ()
  "Cancel the RPC request owned by the current synchronization."
  (when (and pichat-chat--sync-request-id pichat-chat-session)
    (pichat-rpc-cancel-request
     pichat-chat-session pichat-chat--sync-request-id))
  (setq pichat-chat--sync-request-id nil))

(defun pichat-chat--reset-for-source (session-id session-file &optional defer-sync)
  "Reset state for SESSION-ID/SESSION-FILE and advance source generation.
When DEFER-SYNC is non-nil, wait for a subsequent authoritative state reply."
  (pichat-chat--cancel-live-projection)
  (pichat-chat--cancel-extension-status-projection)
  (pichat-chat--cancel-sync-request)
  (pichat-chat--cancel-stats-request)
  (pichat-chat-input-abandon-in-flight)
  (pichat-chat--release-live-projection-fragments)
  (cl-incf pichat-chat--source-generation)
  (setq pichat-chat--source-session-id session-id
        pichat-chat--source-session-file session-file
        pichat-chat--entry-cache nil
        pichat-chat--canonical-transcript nil
        pichat-chat--live-draft
        (pichat-live-draft-empty pichat-chat--source-generation)
        pichat-chat--live-projection-fingerprint nil
        pichat-chat--live-projection-fragments nil
        pichat-chat--sync-in-flight nil
        pichat-chat--sync-in-flight-full-p nil
        pichat-chat--sync-pending nil
        pichat-chat--stats-run-covered-p nil
        pichat-chat--extension-notifications nil
        pichat-chat--thinking-control-error nil)
  (pichat-chat-completion-reset
   pichat-chat--source-generation (pichat-chat--completion-source-key))
  (pichat-chat--release-tool-blocks)
  (pichat-chat--release-activity-blocks)
  (setq pichat-chat--tool-blocks (make-hash-table :test #'equal)
        pichat-chat--canonical-tool-blocks (make-hash-table :test #'equal)
        pichat-chat--live-tool-blocks (make-hash-table :test #'equal)
        pichat-chat--tool-view-states (make-hash-table :test #'equal)
        pichat-chat--activity-blocks (make-hash-table :test #'equal)
        pichat-chat--canonical-activity-blocks (make-hash-table :test #'equal)
        pichat-chat--live-activity-blocks (make-hash-table :test #'equal)
        pichat-chat--activity-view-states (make-hash-table :test #'equal)
        pichat-chat--tool-auxiliary-details
        (make-hash-table :test #'equal)
        pichat-chat--tool-enrichments
        (make-hash-table :test #'equal))
  (unless defer-sync
    (pichat-chat--request-sync t)))

(defun pichat-chat--refresh-source-identity (session)
  "Capture SESSION identity and synchronize after a source transition."
  (let ((session-id (pichat-session-id session))
        (session-file (pichat-session-session-file session)))
    (cond
     ((not pichat-chat--source-bound-p)
      (setq pichat-chat--source-bound-p t
            pichat-chat--source-session-id session-id
            pichat-chat--source-session-file session-file))
     ((pichat-chat--source-identity-changed-p session-id session-file)
      (pichat-chat--reset-for-source session-id session-file))
     (t
      ;; Persistence may materialize a file for the same session id.
      (setq pichat-chat--source-session-file session-file)))))

(defun pichat-chat--on-session-rebinding (_session _event _plist)
  "Invalidate source-derived state before fresh state for a rebind arrives."
  (pichat-chat--reset-for-source nil nil t)
  (setq pichat-chat--source-bound-p nil
        pichat-chat--source-rebinding-p t)
  (pichat-chat--set-status 'source "[session source changing]")
  (force-mode-line-update))

(defun pichat-chat-canonical-entry-cache (session)
  "Return SESSION's current settled entry cache, or nil.
The returned cache is authoritative Pi data owned by SESSION's live chat buffer;
callers must treat it as read-only.  A cache for an older rebound source is
never returned."
  (let ((buffer (and session (pichat-session-buffer session))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (and (derived-mode-p 'pichat-chat-mode)
             (eq pichat-chat-session session)
             (pichat-entry-cache-p pichat-chat--entry-cache)
             (equal (pichat-entry-cache-session-id pichat-chat--entry-cache)
                    (pichat-session-id session))
             pichat-chat--entry-cache)))))

(defun pichat-chat-pending-user-input-count (session)
  "Return cached pending user-input count for SESSION's exact chat."
  (let ((buffer (and session (pichat-session-buffer session))))
    (if (buffer-live-p buffer)
        (with-current-buffer buffer
          (if (and (derived-mode-p 'pichat-chat-mode)
                   (eq pichat-chat-session session))
              pichat-chat--pending-ui-count
            0))
      0)))

(defun pichat-chat-open (session &optional synchronize)
  "Open chat buffer for SESSION.
When SYNCHRONIZE is non-nil, start an authoritative full-entry sync after the
buffer owns SESSION.  This is used when opening only after state has already
arrived, so no later state-change event would otherwise trigger initial sync."
  (let ((buffer (get-buffer-create (pichat-chat-buffer-name session))))
    (with-current-buffer buffer
      (when (pichat-session-cwd session)
        (setq default-directory
              (file-name-as-directory
               (expand-file-name (pichat-session-cwd session)))))
      (unless (derived-mode-p 'pichat-chat-mode)
        (pichat-chat-mode)
        (pichat-chat--insert-header session)
        (pichat-chat--insert-prompt))
      (unless (eq pichat-chat-session session)
        (setq pichat-chat--handlers nil))
      (setq pichat-chat-session session)
      (pichat-chat--refresh-header session)
      (pichat-chat--refresh-source-identity session)
      (setf (pichat-session-buffer session) buffer)
      (pichat-chat--rename-buffer-maybe session)
      (pichat-chat--install-handlers session buffer)
      (when (fboundp 'pichat-note-session-updated)
        (pichat-note-session-updated session))
      (pichat-chat--refresh-slash-commands session)
      (when synchronize
        (pichat-chat--request-sync t))
      (when-let ((diagnostic (pichat-chat-diagnostics-latest session)))
        (pichat-chat--set-status
         (if (eq 'rpc-parse (plist-get diagnostic :origin))
             'rpc-parse
           'error)
         (format "[diagnostic] %s" (plist-get diagnostic :summary)))))
    (pop-to-buffer buffer)
    (with-current-buffer buffer
      (pichat-chat--maybe-start-next-ui-request session))
    buffer))

(defun pichat-chat--before-change (beg _end)
  "Prevent editing transcript/prompt-label text before the current input area.
Programmatic PiChat rendering binds `pichat-chat--inhibit-edit-guard'."
  (when (and (not pichat-chat--inhibit-edit-guard)
             pichat-chat--input-start
             (< beg (marker-position pichat-chat--input-start)))
    (user-error "PiChat transcript is read-only; edit at the current prompt")))

(defmacro pichat-chat--with-buffer-edit (&rest body)
  "Run BODY while allowing PiChat to edit the chat buffer.
Programmatic transcript changes neither run modification hooks nor enter buffer
undo history; both behaviors remain enabled for user edits in the prompt."
  (declare (indent 0) (debug t))
  `(let ((inhibit-read-only t)
         (inhibit-modification-hooks t)
         (pichat-chat--inhibit-edit-guard t))
     (if pichat-chat--focused-change-group-active-p
         ;; Do not introduce a nested dynamic undo binding here: unwinding it
         ;; would discard the change group's private records before rollback.
         (progn ,@body)
       (let ((buffer-undo-list t))
         ,@body))))

(defun pichat-chat--adjust-undo-for-prefix-delta (old-boundary delta)
  "Shift prompt undo positions after OLD-BOUNDARY by DELTA characters.
PiChat edits before the prompt with undo recording disabled.  Emacs undo entries
store integer positions, so those positions must follow an internal prefix
length change even though the internal edit itself must not become undoable."
  (when (/= delta 0)
    (let ((deltas (list (cons old-boundary (- delta)))))
      (dolist (variable '(buffer-undo-list pending-undo-list))
        (when (and (boundp variable)
                   (listp (symbol-value variable)))
          (set variable
               (mapcar (lambda (entry)
                         (undo-adjust-elt entry deltas))
                       (symbol-value variable))))))))

(defun pichat-chat--protect-region (beg end)
  "Mark BEG..END as read-only transcript text."
  (when (< beg end)
    (add-text-properties
     beg end
     '(read-only t
       front-sticky t
       rear-nonsticky t
       pichat-transcript t))))

(defun pichat-chat--header-title (session)
  "Return the dynamic first-line title for SESSION."
  (format "PiChat — %s" (or (pichat-session-cwd session)
                              default-directory)))

(defun pichat-chat--insert-header (session)
  "Insert the initial chat header shell for SESSION."
  (pichat-chat--with-buffer-edit
    (erase-buffer)
    (insert (pichat-chat--header-title session) "\n")
    (insert "Keys: RET send, S-RET newline, C-c C-k abort, C-c C-y recover, C-c C-z fold tools, C-c C-d tool details, C-h m help\n\n")
    (dolist (marker (list pichat-chat--extension-status-start
                          pichat-chat--extension-status-end
                          pichat-chat--canonical-start
                          pichat-chat--canonical-end
                          pichat-chat--live-start
                          pichat-chat--live-end
                          pichat-chat--status-start
                          pichat-chat--status-end))
      (when (markerp marker)
        (set-marker marker (point))))))

(defun pichat-chat--refresh-header (session)
  "Refresh only the dynamic first header line for SESSION when needed."
  (when (and session (> (point-max) (point-min)))
    (let* ((start (point-min))
           (end (save-excursion
                  (goto-char start)
                  (line-end-position)))
           (title (pichat-chat--header-title session))
           (old (buffer-substring-no-properties start end)))
      (unless (equal old title)
        (let ((delta (- (length title) (- end start)))
              (modified (buffer-modified-p)))
          (pichat-chat--preserve-view
            (pichat-chat--with-buffer-edit
              (delete-region start end)
              (goto-char start)
              (insert title)
              (pichat-chat--protect-region start (point))))
          (pichat-chat--adjust-undo-for-prefix-delta end delta)
          (set-buffer-modified-p modified))))))

(defun pichat-chat--format-token-count (count)
  "Format token COUNT compactly for the PiChat mode line."
  (cond
   ((not (numberp count)) "?")
   ((< count 1000) (number-to-string count))
   ((< count 10000) (format "%.1fk" (/ count 1000.0)))
   ((< count 1000000) (format "%dk" (round (/ count 1000.0))))
   ((< count 10000000) (format "%.1fM" (/ count 1000000.0)))
   (t (format "%dM" (round (/ count 1000000.0))))))

(defun pichat-chat--format-context-usage (session)
  "Return compact context usage text for SESSION, or nil when unavailable."
  (when-let ((usage (pichat-session-context-usage session)))
    (let* ((tokens (plist-get usage :tokens))
           (percent (plist-get usage :percent))
           (window (plist-get usage :contextWindow))
           (formatted-tokens (pichat-chat--format-token-count tokens))
           (formatted-window (pichat-chat--format-token-count window))
           (display (format "%s/%s" formatted-tokens formatted-window))
           (face (cond
                  ((and (numberp percent) (> percent 90)) 'error)
                  ((and (numberp percent) (> percent 70)) 'warning)))
           (help (format "Context usage: %s of %s tokens%s"
                         formatted-tokens formatted-window
                         (if (numberp percent)
                             (format " (%.1f%%)" percent)
                           ""))))
      (propertize display 'help-echo help 'face face))))

(defun pichat-chat--mode-line-state-control (state)
  "Return compact mode-line indicator for Pi session STATE."
  (pcase-let* ((`(,indicator ,label ,face)
                (pcase state
                  ('starting '("◌" "starting" warning))
                  ('idle '("○" "idle" success))
                  ('running '("▶" "running" mode-line-emphasis))
                  ('compacting '("⇥" "compacting" warning))
                  ('retrying '("↻" "retrying" warning))
                  ('stopped '("■" "stopped" shadow))
                  ('error '("✕" "error" error))
                  ('not-connected '("⊘" "not connected" shadow))
                  (_ '("?" "unknown" warning)))))
    (propertize indicator
                'face face
                'help-echo (format "Pi status: %s" label))))

(defun pichat-chat--stats-callback-current-p
    (buffer session source-generation token)
  "Return non-nil when stats TOKEN still owns BUFFER for SESSION.
SOURCE-GENERATION identifies the source for which the request was sent."
  (and (buffer-live-p buffer)
       (eq session (buffer-local-value 'pichat-chat-session buffer))
       (= source-generation
          (buffer-local-value 'pichat-chat--source-generation buffer))
       (eq token
           (buffer-local-value 'pichat-chat--stats-in-flight buffer))))

(defun pichat-chat--cancel-stats-request ()
  "Cancel and invalidate context-usage stats work owned by this chat."
  (when (and pichat-chat--stats-request-id pichat-chat-session)
    (pichat-rpc-cancel-request
     pichat-chat-session pichat-chat--stats-request-id))
  (cl-incf pichat-chat--stats-sequence)
  (setq pichat-chat--stats-in-flight nil
        pichat-chat--stats-request-id nil
        pichat-chat--stats-pending nil
        pichat-chat--stats-run-covered-p nil))

(defun pichat-chat--stats-finish
    (buffer session source-generation token reason previous success response)
  "Finish BUFFER's stats TOKEN for SESSION.
REASON is its lifecycle boundary, PREVIOUS is the old cached usage, SUCCESS is
non-nil for a successful RPC response, and RESPONSE is the response plist."
  (when (pichat-chat--stats-callback-current-p
         buffer session source-generation token)
    (with-current-buffer buffer
      (let* ((cancelled
              (eq 'cancelled (plist-get response :pichat-failure-kind)))
             (pending pichat-chat--stats-pending)
             (newer-boundary-p (memq pending '(turn compaction))))
        (setq pichat-chat--stats-in-flight nil
              pichat-chat--stats-request-id nil
              pichat-chat--stats-pending nil)
        (when success
          (when (and (memq reason '(turn compaction settled))
                     (not newer-boundary-p))
            (setq pichat-chat--stats-run-covered-p t))
          (unless (equal previous (pichat-session-context-usage session))
            (force-mode-line-update)))
        (when cancelled
          (setq pending nil))
        ;; A settled fallback queued behind a successful final-turn refresh is
        ;; redundant.  Retain it after failure so settlement still gets one
        ;; chance to refresh.
        (when (and (eq pending 'settled)
                   success pichat-chat--stats-run-covered-p)
          (setq pending nil))
        (when (and pending
                   (eq session pichat-chat-session)
                   (pichat-session-alive-p session))
          (pichat-chat--start-stats-request session pending))))))

(defun pichat-chat--start-stats-request (session reason)
  "Start one context-usage request for SESSION at lifecycle REASON."
  (let* ((buffer (current-buffer))
         (source-generation pichat-chat--source-generation)
         (token (cl-incf pichat-chat--stats-sequence))
         (previous (copy-tree (pichat-session-context-usage session)))
         request-id)
    ;; Establish ownership before sending: unit transports may call back
    ;; synchronously from `pichat-rpc-get-session-stats'.
    (setq pichat-chat--stats-in-flight token
          pichat-chat--stats-request-id nil)
    (condition-case _condition
        (setq request-id
              (pichat-rpc-get-session-stats
               session
               (lambda (response callback-session)
                 (pichat-chat--stats-finish
                  buffer callback-session source-generation token reason
                  previous t response))
               (lambda (response callback-session)
                 (pichat-chat--stats-finish
                  buffer callback-session source-generation token reason
                  previous nil response))))
      (error
       (pichat-chat--stats-finish
        buffer session source-generation token reason previous nil nil)))
    (when (eq token pichat-chat--stats-in-flight)
      (setq pichat-chat--stats-request-id request-id))))

(defun pichat-chat--refresh-stats (&optional session reason)
  "Schedule cached stats refresh for SESSION at lifecycle REASON.
REASON is one of `state', `turn', `compaction', or `settled'."
  (when-let ((s (or session pichat-chat-session)))
    (when (and (eq s pichat-chat-session)
               (pichat-session-alive-p s))
      (setq reason (or reason 'state))
      (when (memq reason '(turn compaction))
        (setq pichat-chat--stats-run-covered-p nil))
      (cond
       ((and (eq reason 'settled) pichat-chat--stats-run-covered-p)
        nil)
       (pichat-chat--stats-in-flight
        (pcase reason
          ('settled
           (unless (or pichat-chat--stats-run-covered-p
                       (memq pichat-chat--stats-pending '(turn compaction)))
             (setq pichat-chat--stats-pending 'settled)))
          ('state
           (unless pichat-chat--stats-pending
             (setq pichat-chat--stats-pending 'state)))
          (_
           (setq pichat-chat--stats-pending reason))))
       (t
        (pichat-chat--start-stats-request s reason))))))

(defun pichat-chat--model-thinking-levels (model)
  "Return thinking levels advertised by full Pi MODEL metadata.
Pi's model-level `thinkingLevelMap' uses nil values for unsupported levels;
omitted standard levels through `high' retain their default support, while
omitted `xhigh' and `max' levels are unsupported."
  (when (eq (plist-get model :reasoning) t)
    (let ((mapping (plist-get model :thinkingLevelMap)))
      (cl-loop for level in pichat-chat--thinking-levels
               for key = (intern (concat ":" level))
               for extended = (member level '("xhigh" "max"))
               when (if (plist-member mapping key)
                        (stringp (plist-get mapping key))
                      (not extended))
               collect level))))

(defun pichat-chat--thinking-control-state (session)
  "Return availability state of SESSION's thinking control."
  (let ((model (pichat-session-model session)))
    (cond
     ((not (pichat-session-alive-p session)) 'unavailable)
     ((or (not (listp model)) (not (plist-member model :reasoning)))
      'unavailable)
     ((not (eq (plist-get model :reasoning) t)) 'disabled)
     (pichat-chat--thinking-control-error 'error)
     (t 'available))))

(defun pichat-chat--mode-line-run-command (command event)
  "Run COMMAND in the mode-line buffer identified by mouse EVENT.
When EVENT is nil, run in the current buffer; this also keeps the controls
straightforward to exercise without synthesizing mouse input."
  (if event
      (let ((window (posn-window (event-start event))))
        (when (window-live-p window)
          (with-selected-window window
            (call-interactively command))))
    (call-interactively command)))

(defun pichat-chat--mode-line-model-click (event)
  "Select a Pi model from the mode line mouse EVENT."
  (interactive "e")
  (pichat-chat--mode-line-run-command #'pichat-select-model event))

(defun pichat-chat--mode-line-thinking-click (event)
  "Cycle Pi thinking from the mode line mouse EVENT."
  (interactive "e")
  (pichat-chat--mode-line-run-command
   #'pichat-chat-cycle-thinking-level event))

(defvar pichat-chat--model-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'pichat-chat--mode-line-model-click)
    map)
  "Keymap for the PiChat model mode-line control.")

(defvar pichat-chat--thinking-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'pichat-chat--mode-line-thinking-click)
    map)
  "Keymap for the PiChat thinking mode-line control.")

(defun pichat-chat--mode-line-control (text help &optional map disabled)
  "Return mode-line control TEXT with HELP, optional MAP, and DISABLED styling."
  (apply #'propertize text
         (append (list 'help-echo help)
                 (when map
                   (list 'mouse-face 'mode-line-highlight 'local-map map))
                 (when disabled (list 'face 'shadow)))))

(defun pichat-chat--mode-line-model-control (session model-name)
  "Return model selector segment for SESSION displaying MODEL-NAME verbatim."
  (if (pichat-session-alive-p session)
      (pichat-chat--mode-line-control
       (if (equal model-name "?") "select" model-name)
       "mouse-1: select Pi model" pichat-chat--model-mode-line-map)
    (pichat-chat--mode-line-control
     model-name "Pi model selection unavailable: session not connected" nil t)))

(defun pichat-chat--compact-thinking-level (level)
  "Return compact display text for Pi thinking LEVEL."
  (or (cdr (assoc level
                  '(("off" . "0")
                    ("minimal" . "m")
                    ("low" . "L")
                    ("medium" . "M")
                    ("high" . "H")
                    ("xhigh" . "XH")
                    ("max" . "MAX"))))
      (and (stringp level) (not (string-empty-p level)) level)
      "?"))

(defun pichat-chat--mode-line-thinking-control (session)
  "Return compact thinking suffix control for SESSION, or nil when disabled."
  (let ((state (pichat-chat--thinking-control-state session)))
    (pcase state
      ('available
       (let ((level (pichat-session-thinking-level session)))
         (pichat-chat--mode-line-control
          (format ".%s" (pichat-chat--compact-thinking-level level))
          (format "mouse-1: cycle Pi thinking level; current: %s (available: %s)"
                  (or level "unknown")
                  (string-join
                   (pichat-chat--model-thinking-levels
                    (pichat-session-model session)) ", "))
          pichat-chat--thinking-mode-line-map)))
      ('error
       (pichat-chat--mode-line-control
        ".!" "Pi rejected the last thinking-level request; mouse-1 retries"
        pichat-chat--thinking-mode-line-map))
      ('disabled nil)
      (_
       (pichat-chat--mode-line-control
        ".?" "Pi thinking control unavailable until model state is known"
        nil t)))))

(defun pichat-chat--mode-line-status ()
  "Return compact PiChat mode-line status text."
  (if-let ((s pichat-chat-session))
      (let* ((state (or (pichat-session-state s) 'unknown))
             (model (or (plist-get (pichat-session-model s) :id)
                        (plist-get (pichat-session-model s) :modelId)
                        (plist-get (pichat-session-model s) :name)
                        "?"))
             (model-control (pichat-chat--mode-line-model-control s model))
             (thinking-control (pichat-chat--mode-line-thinking-control s))
             (model-thinking (concat model-control (or thinking-control "")))
             (name (pichat-session-name s))
             (context-usage (pichat-chat--format-context-usage s))
             (q-steer (car pichat-chat--queue-counts))
             (q-follow (cdr pichat-chat--queue-counts))
             (ui pichat-chat--pending-ui-count)
             (widgets (and (hash-table-p pichat-chat--extension-widgets)
                           (hash-table-count pichat-chat--extension-widgets))))
        (string-join
         (delq nil
               (list (pichat-chat--mode-line-state-control state)
                     model-thinking
                     (when (and (stringp name) (not (string-empty-p name)))
                       (truncate-string-to-width name 32 nil nil "…"))
                     (when (and (stringp pichat-chat--extension-title)
                                (not (string-empty-p pichat-chat--extension-title)))
                       (truncate-string-to-width pichat-chat--extension-title 32 nil nil "…"))
                     context-usage
                     (unless (and (zerop q-steer) (zerop q-follow))
                       (format "Q:%d/%d" q-steer q-follow))
                     (unless (zerop ui)
                       (format "UI:%d" ui))
                     (when (and widgets (> widgets 0))
                       (format "W:%d" widgets))))
         "  "))
    (pichat-chat--mode-line-state-control 'not-connected)))

(defun pichat-chat--label (text face)
  "Return TEXT with stable FACE for transcript labels."
  ;; Use `font-lock-face' rather than `face' so font-lock in text-derived
  ;; buffers does not wipe our label styling during refontification.
  (propertize text 'font-lock-face face))

(defun pichat-chat--prompt-live-p ()
  "Return non-nil when the buffer already has a current prompt."
  (and (markerp pichat-chat--prompt-start)
       (markerp pichat-chat--input-start)
       (let ((prompt-pos (marker-position pichat-chat--prompt-start))
             (input-pos (marker-position pichat-chat--input-start)))
         (and prompt-pos
              input-pos
              (<= prompt-pos input-pos)
              (<= input-pos (point-max))
              (get-text-property prompt-pos 'pichat-live-prompt)))))

(defun pichat-chat--bar-prefix (&optional live)
  "Return a propertized PiChat left-bar prefix.
When LIVE is non-nil, mark the prefix as the current live prompt."
  (concat
   (propertize "▌"
               'font-lock-face '(pichat-input-bar-face pichat-input-block-face)
               'pichat-live-prompt live)
   (propertize " "
               'font-lock-face 'pichat-input-block-face
               'pichat-live-prompt live)))

(defun pichat-chat--style-live-input ()
  "Apply live-input styling from the current prompt to buffer end."
  (when (pichat-chat--prompt-live-p)
    (let ((inhibit-read-only t)
          (beg (marker-position pichat-chat--prompt-start))
          (end (point-max)))
      (when (< beg end)
        (with-silent-modifications
          (put-text-property beg end 'font-lock-face 'pichat-input-block-face)
          (put-text-property beg (min (1+ beg) end)
                             'font-lock-face
                             '(pichat-input-bar-face pichat-input-block-face))
          (put-text-property beg (min (+ beg 2) end)
                             'pichat-live-prompt t))))))

(defun pichat-chat--after-change-style-input (beg end _len)
  "Keep the editable live prompt styled and track user edits."
  (when (and (not pichat-chat--inhibit-edit-guard)
             (pichat-chat--prompt-live-p)
             (>= end (marker-position pichat-chat--input-start)))
    (when (>= beg (marker-position pichat-chat--input-start))
      (cl-incf pichat-chat--editor-generation))
    (pichat-chat--style-live-input)))

(defun pichat-chat--insert-prompt ()
  "Insert editable Pi-style input area if one is not already live.
The left-bar prefix is protected; only text after `pichat-chat--input-start' is
editable by the user."
  (pichat-chat--with-buffer-edit
    (if (pichat-chat--prompt-live-p)
        (goto-char (point-max))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (unless (marker-position pichat-chat--widget-start)
        (set-marker pichat-chat--widget-start (point)))
      (unless (marker-position pichat-chat--widget-end)
        (set-marker pichat-chat--widget-end (point)))
      (set-marker pichat-chat--prompt-start (point))
      (let ((label-start (point)))
        (insert (pichat-chat--bar-prefix t))
        (pichat-chat--protect-region label-start (point)))
      (set-marker pichat-chat--input-start (point))
      (pichat-chat--style-live-input)
      (setq buffer-undo-list nil)
      (goto-char (point-max)))))

(defun pichat-chat--input-text ()
  "Return current input text."
  (string-trim (buffer-substring-no-properties pichat-chat--input-start (point-max))))

(defun pichat-chat--clear-input ()
  "Remove current prompt line, leaving transcript ready for response."
  (pichat-chat--with-buffer-edit
    (delete-region pichat-chat--prompt-start (point-max))
    (goto-char (point-max))
    (set-marker pichat-chat--prompt-start (point))
    (set-marker pichat-chat--input-start (point))))

(defun pichat-chat--set-input-text (text)
  "Replace the editable prompt with TEXT and advance editor generation."
  (pichat-chat--insert-prompt)
  (let* ((text (or text ""))
         (old (buffer-substring-no-properties
               pichat-chat--input-start (point-max))))
    (pichat-chat--with-buffer-edit
      (delete-region pichat-chat--input-start (point-max))
      (goto-char (point-max))
      (insert text))
    (unless (equal old text)
      (cl-incf pichat-chat--editor-generation))))

(defun pichat-chat--window-at-bottom-p (win)
  "Return non-nil when WIN is visibly showing the chat tail."
  (when (and win (window-live-p win))
    (when-let* ((window-end (window-end win))
                (visible-end
                 (save-excursion
                   ;; A nonselected window can deliberately have point outside
                   ;; its retained viewport.  In that state `window-end' reports
                   ;; the point rather than the viewport's currently visible
                   ;; end, so bound it by geometry from `window-start'.
                   (goto-char (window-start win))
                   (vertical-motion (window-body-height win) win)
                   (point))))
      (<= (- (point-max) (min window-end visible-end))
          pichat-chat-follow-bottom-threshold))))

(defun pichat-chat--logical-anchor-at (position)
  "Return a stable transcript anchor for POSITION, or nil."
  (when-let ((key (get-text-property position 'pichat-node-key)))
    (let* ((candidate (previous-single-property-change
                       position 'pichat-node-key nil (point-min)))
           (start (if (and candidate
                           (equal key (get-text-property
                                       candidate 'pichat-node-key)))
                      candidate
                    position)))
      (list key (- position start)))))

(defun pichat-chat--logical-anchor-position (anchor)
  "Return current buffer position corresponding to transcript ANCHOR."
  (when anchor
    (let ((position (point-min))
          start)
      (while (and (< position (point-max)) (not start))
        (if (equal (car anchor)
                   (get-text-property position 'pichat-node-key))
            (setq start position)
          (setq position
                (or (next-single-property-change
                     position 'pichat-node-key nil (point-max))
                    (point-max)))))
      (when start
        (let ((end (or (next-single-property-change
                        start 'pichat-node-key nil (point-max))
                       (point-max))))
          (min end (+ start (cadr anchor))))))))

(defun pichat-chat--property-anchor-at (position property)
  "Return PROPERTY's value and local offset at POSITION, or nil."
  (when-let ((value (get-text-property position property)))
    (let* ((candidate (previous-single-property-change
                       position property nil (point-min)))
           (start (if (and candidate
                           (equal value (get-text-property candidate property)))
                      candidate
                    position)))
      (list value (- position start)))))

(defun pichat-chat--property-anchor-position
    (anchor property &optional matcher)
  "Resolve ANCHOR to one unambiguous PROPERTY range.
MATCHER compares each property value with ANCHOR's saved value and defaults to
`equal'.  Return nil when no range or more than one range matches."
  (when anchor
    (let ((position (point-min))
          (limit (point-max))
          (matcher (or matcher #'equal))
          found ambiguous)
      (while (< position limit)
        (let* ((value (get-text-property position property))
               (next (or (next-single-property-change
                          position property nil limit)
                         limit)))
          (when (funcall matcher value (car anchor))
            (if found
                (setq ambiguous t)
              (setq found (cons position next))))
          (setq position next)))
      (when (and found (not ambiguous))
        (min (1- (cdr found))
             (+ (car found) (cadr anchor)))))))

(defun pichat-chat--tool-id-anchor-at (position)
  "Return the tool-call ID and local tool offset at POSITION, or nil."
  (when-let ((anchor (pichat-chat--property-anchor-at
                      position 'pichat-tool-key)))
    (when-let ((tool-id (cdr-safe (car anchor))))
      (list tool-id (cadr anchor)))))

(defun pichat-chat--tool-id-anchor-position (anchor)
  "Resolve tool-call ANCHOR only when one visible tool range matches."
  (pichat-chat--property-anchor-position
   anchor 'pichat-tool-key
   (lambda (tool-key tool-id)
     (and (consp tool-key) (equal (cdr tool-key) tool-id)))))

(defun pichat-chat--capture-view-anchor (position live-start live-end)
  "Capture a compact restorable anchor for POSITION.
LIVE-START and LIVE-END describe the replaceable live region before an edit."
  (let* ((fallback (copy-marker position))
         (record (pichat-chat--property-anchor-at
                  position 'pichat-logical-key))
         (tool (pichat-chat--tool-id-anchor-at position))
         (logical (pichat-chat--logical-anchor-at position))
         (live-offset
          (and live-start live-end (< live-start live-end)
               (>= position live-start) (< position live-end)
               (- position live-start))))
    (cond
     ((or record logical)
      (append (list :kind 'logical)
              (when record (list :record record))
              (when tool (list :tool tool))
              (when logical (list :logical logical))
              (when live-offset (list :live-offset live-offset))
              (list :fallback fallback :absolute position)))
     (live-offset
      (list :kind 'live :live-offset live-offset
            :fallback fallback :absolute position))
     (t
      (list :kind 'ordinary :fallback fallback :absolute position)))))

(defun pichat-chat--pre-prompt-limit ()
  "Return the last safe position before editable prompt text."
  (if-let ((prompt (and (markerp pichat-chat--prompt-start)
                        (marker-position pichat-chat--prompt-start))))
      (max (point-min) (1- prompt))
    (point-max)))

(defun pichat-chat--clamp-view-position (position &optional before-prompt)
  "Clamp POSITION to the buffer, optionally BEFORE-PROMPT."
  (max (point-min)
       (min (or position (point-min))
            (if before-prompt
                (pichat-chat--pre-prompt-limit)
              (point-max)))))

(defun pichat-chat--live-anchor-position (anchor)
  "Resolve ANCHOR's live offset while a live region remains."
  (let ((start (and (markerp pichat-chat--live-start)
                    (marker-position pichat-chat--live-start)))
        (end (and (markerp pichat-chat--live-end)
                  (marker-position pichat-chat--live-end))))
    (when (and start end (< start end))
      (+ start
         (min (plist-get anchor :live-offset)
              (max 0 (1- (- end start))))))))

(defun pichat-chat--view-anchor-position (anchor)
  "Resolve captured view ANCHOR in the current projection."
  (let ((fallback (or (and (markerp (plist-get anchor :fallback))
                           (marker-position (plist-get anchor :fallback)))
                      (plist-get anchor :absolute))))
    (pcase (plist-get anchor :kind)
      ('logical
       (or (pichat-chat--property-anchor-position
            (plist-get anchor :record) 'pichat-logical-key)
           (pichat-chat--tool-id-anchor-position
            (plist-get anchor :tool))
           (pichat-chat--logical-anchor-position
            (plist-get anchor :logical))
           (and (plist-member anchor :live-offset)
                (or (pichat-chat--live-anchor-position anchor)
                    (pichat-chat--clamp-view-position
                     (plist-get anchor :absolute) t)))
           (pichat-chat--clamp-view-position fallback t)))
      ('live
       (or (pichat-chat--live-anchor-position anchor)
           (pichat-chat--clamp-view-position
            (plist-get anchor :absolute) t)))
      (_ (pichat-chat--clamp-view-position fallback)))))

(defun pichat-chat--release-view-anchor (anchor)
  "Release the temporary marker owned by ANCHOR."
  (when-let ((marker (plist-get anchor :fallback)))
    (set-marker marker nil)))

(defun pichat-chat--window-following-p (window)
  "Return non-nil when WINDOW's point and viewport both follow the tail."
  (and (window-live-p window)
       (<= (- (point-max) (window-point window))
           pichat-chat-follow-bottom-threshold)
       (pichat-chat--window-at-bottom-p window)))

(defun pichat-chat--capture-view-state ()
  "Capture per-window cursor, viewport, and follow state for this buffer."
  (let* ((buffer (current-buffer))
         (live-start (and (markerp pichat-chat--live-start)
                          (marker-position pichat-chat--live-start)))
         (live-end (and (markerp pichat-chat--live-end)
                        (marker-position pichat-chat--live-end)))
         (windows (get-buffer-window-list buffer nil t))
         snapshots)
    (dolist (window windows)
      (let ((window-point (window-point window))
            (window-start (window-start window)))
        (push (list :window window
                    :follow (pichat-chat--window-following-p window)
                    :point (pichat-chat--capture-view-anchor
                            window-point live-start live-end)
                    :start (pichat-chat--capture-view-anchor
                            window-start live-start live-end))
              snapshots)))
    (list :buffer buffer
          :windows (nreverse snapshots)
          :selected-chat-p (memq (selected-window) windows)
          :buffer-follow (and (null windows)
                              (<= (- (point-max) (point))
                                  pichat-chat-follow-bottom-threshold))
          :buffer-point (pichat-chat--capture-view-anchor
                         (point) live-start live-end))))

(defun pichat-chat--release-view-state (state)
  "Release all temporary markers owned by view STATE."
  (when-let ((anchor (plist-get state :buffer-point)))
    (pichat-chat--release-view-anchor anchor))
  (dolist (snapshot (plist-get state :windows))
    (pichat-chat--release-view-anchor (plist-get snapshot :point))
    (pichat-chat--release-view-anchor (plist-get snapshot :start))))

(defun pichat-chat--restore-view-state (state)
  "Restore per-window cursor, viewport, and follow behavior from STATE."
  (unwind-protect
      (when-let ((buffer (plist-get state :buffer)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (if (null (plist-get state :windows))
                (if (plist-get state :buffer-follow)
                    (goto-char (point-max))
                  (goto-char
                   (pichat-chat--view-anchor-position
                    (plist-get state :buffer-point))))
              (dolist (snapshot (plist-get state :windows))
                (let ((window (plist-get snapshot :window)))
                  (when (and (window-live-p window)
                             (eq (window-buffer window) buffer))
                    (if (plist-get snapshot :follow)
                        (with-selected-window window
                          (goto-char (point-max))
                          (recenter -1))
                      (let ((point-position
                             (pichat-chat--view-anchor-position
                              (plist-get snapshot :point)))
                            (start-position
                             (pichat-chat--view-anchor-position
                              (plist-get snapshot :start))))
                        ;; Avoid needlessly touching a deliberately unusual
                        ;; point-outside-viewport arrangement: redisplay would
                        ;; otherwise scroll that window back to its point.
                        (unless (= (window-point window) point-position)
                          (set-window-point window point-position))
                        (unless (= (window-start window) start-position)
                          (set-window-start window start-position t)))))))
              ;; When another buffer (including a minibuffer) was selected,
              ;; ordinary buffer point is independent from every chat window's
              ;; `window-point' and should survive as well.
              (unless (plist-get state :selected-chat-p)
                (goto-char
                 (pichat-chat--view-anchor-position
                  (plist-get state :buffer-point))))))))
    (pichat-chat--release-view-state state)))

(defvar pichat-chat--view-preservation-buffer nil
  "Buffer owned by the dynamically enclosing view-preservation transaction.")

(defmacro pichat-chat--preserve-view (&rest body)
  "Run BODY in the outermost same-buffer view-preservation transaction.
Nested calls in another buffer establish an independent transaction."
  (declare (indent 0) (debug t))
  `(if (eq pichat-chat--view-preservation-buffer (current-buffer))
       (progn ,@body)
     (let ((pichat-chat--view-preservation-buffer (current-buffer))
           (view-state (pichat-chat--capture-view-state)))
       (unwind-protect
           (progn ,@body)
         (pichat-chat--restore-view-state view-state)))))

(defun pichat-chat-abort ()
  "Abort the current Pi run or active automatic retry delay."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (if (pichat-session-retrying-p pichat-chat-session)
      (pichat-rpc-abort-retry pichat-chat-session)
    (pichat-rpc-abort pichat-chat-session)))

(defun pichat-chat-steer (message)
  "Queue steering MESSAGE."
  (interactive "sSteer: ")
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-steer pichat-chat-session message))

(defun pichat-chat-follow-up (message)
  "Queue follow-up MESSAGE."
  (interactive "sFollow-up: ")
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-follow-up pichat-chat-session message))

(defun pichat-chat-set-steering-mode (mode)
  "Set Pi steering queue MODE for the current session."
  (interactive (list (completing-read "Steering mode: "
                                      '("one-at-a-time" "all") nil t)))
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-set-steering-mode
   pichat-chat-session mode
   (lambda (_response session)
     (pichat-rpc-get-state session (lambda (_r _s) (force-mode-line-update))))))

(defun pichat-chat-set-follow-up-mode (mode)
  "Set Pi follow-up queue MODE for the current session."
  (interactive (list (completing-read "Follow-up mode: "
                                      '("one-at-a-time" "all") nil t)))
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-set-follow-up-mode
   pichat-chat-session mode
   (lambda (_response session)
     (pichat-rpc-get-state session (lambda (_r _s) (force-mode-line-update))))))

(defun pichat-chat-compact (&optional instructions)
  "Compact current Pi session with optional INSTRUCTIONS."
  (interactive "sCompaction instructions (optional): ")
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-compact pichat-chat-session
                       (unless (string-empty-p instructions) instructions)
                       (lambda (_response _session)
                         (message "PiChat compaction requested"))))

(defun pichat-chat-new-session ()
  "Start a new Pi session in the current chat buffer.
A successful unrelated new session clears Session History source navigation."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (when (yes-or-no-p "Start a new Pi session? ")
    (pichat-rpc-new-session
     pichat-chat-session
     (lambda (response session)
       (if (plist-get (plist-get response :data) :cancelled)
           (message "PiChat new session cancelled")
         (pichat-sessions-clear-source-navigation session)
         (pichat-chat--set-status 'source "[new session]")
         (pichat-rpc-get-state
          session (lambda (_r _s) (force-mode-line-update))))))))

(defun pichat-chat-cycle-model ()
  "Cycle Pi model for current session."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-cycle-model
   pichat-chat-session
   (lambda (_response session)
     (pichat-rpc-get-state session (lambda (_r _s) (force-mode-line-update))))))

(defun pichat-chat--thinking-levels-for-selection (session)
  "Return model-supported thinking levels selectable for SESSION.
Signal a user error when thinking control is disabled or unavailable."
  (unless session (user-error "No PiChat session"))
  (pcase (pichat-chat--thinking-control-state session)
    ('disabled (user-error "Selected Pi model does not support thinking"))
    ('unavailable (user-error "Pi thinking control is unavailable")))
  (or (pichat-chat--model-thinking-levels (pichat-session-model session))
      (user-error "Selected Pi model advertises no thinking levels")))

(defun pichat-chat--read-thinking-level ()
  "Read a supported thinking level for the current PiChat session."
  (let* ((session pichat-chat-session)
         (levels (pichat-chat--thinking-levels-for-selection session))
         (current (pichat-session-thinking-level session)))
    (completing-read "Thinking level: " levels nil t nil nil
                     (and (member current levels) current))))

(defun pichat-chat--thinking-control-callback-current-p
    (buffer session source-generation)
  "Return non-nil when captured thinking callback context remains current."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (eq session pichat-chat-session)
              (= source-generation pichat-chat--source-generation)))))

(defun pichat-chat--thinking-control-failed
    (buffer session source-generation _response response-session)
  "Record a failed thinking request when its captured context remains current."
  (when (and (eq session response-session)
             (pichat-chat--thinking-control-callback-current-p
              buffer session source-generation))
    (with-current-buffer buffer
      (setq pichat-chat--thinking-control-error t)
      (force-mode-line-update))))

(defun pichat-chat--thinking-control-refreshed
    (buffer session source-generation _response response-session)
  "Finish thinking refresh when its captured context remains current."
  (when (and (eq session response-session)
             (pichat-chat--thinking-control-callback-current-p
              buffer session source-generation))
    (with-current-buffer buffer
      (setq pichat-chat--thinking-control-error nil)
      (force-mode-line-update))))

(defun pichat-chat--thinking-control-succeeded
    (buffer session source-generation _response response-session)
  "Refresh state after a successful thinking change in the current context."
  (when (and (eq session response-session)
             (pichat-chat--thinking-control-callback-current-p
              buffer session source-generation))
    (with-current-buffer buffer
      (setq pichat-chat--thinking-control-error nil)
      (force-mode-line-update))
    (pichat-rpc-get-state
     session
     (apply-partially #'pichat-chat--thinking-control-refreshed
                      buffer session source-generation)
     (apply-partially #'pichat-chat--thinking-control-failed
                      buffer session source-generation))))

(defun pichat-chat-cycle-thinking-level ()
  "Cycle thinking level for current session and refresh authoritative state."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pcase (pichat-chat--thinking-control-state pichat-chat-session)
    ('disabled (user-error "Selected Pi model does not support thinking"))
    ('unavailable (user-error "Pi thinking control is unavailable"))
    (_
     (let ((buffer (current-buffer))
           (session pichat-chat-session)
           (source-generation pichat-chat--source-generation))
       (pichat-rpc-cycle-thinking-level
        session
        (apply-partially #'pichat-chat--thinking-control-succeeded
                         buffer session source-generation)
        (apply-partially #'pichat-chat--thinking-control-failed
                         buffer session source-generation))))))

(defun pichat-chat-set-thinking-level (level)
  "Set the current session's thinking LEVEL and refresh authoritative state."
  (interactive (list (pichat-chat--read-thinking-level)))
  (let* ((session pichat-chat-session)
         (levels (pichat-chat--thinking-levels-for-selection session)))
    (unless (and (stringp level) (member level levels))
      (user-error "Thinking level is not available for this model: %s" level))
    (let ((buffer (current-buffer))
          (source-generation pichat-chat--source-generation))
      (pichat-rpc-set-thinking-level
       session level
       (apply-partially #'pichat-chat--thinking-control-succeeded
                        buffer session source-generation)
       (apply-partially #'pichat-chat--thinking-control-failed
                        buffer session source-generation)))))

;;;###autoload
(defun pichat-chat--reproject-display-options ()
  "Reproject canonical and live regions without fetching or renormalizing."
  (let ((draft pichat-chat--live-draft)
        (auxiliary (and (hash-table-p pichat-chat--tool-auxiliary-details)
                        (copy-hash-table
                         pichat-chat--tool-auxiliary-details))))
    (when (pichat-transcript-p pichat-chat--canonical-transcript)
      (let* ((context (pichat-chat--canonical-render-context
                       pichat-chat--canonical-transcript))
             (fragment (pichat-render-canonical
                        pichat-chat--canonical-transcript context)))
        (pichat-chat--project-canonical
         pichat-chat--entry-cache pichat-chat--canonical-transcript
         fragment context)))
    (setq pichat-chat--live-draft draft
          pichat-chat--tool-auxiliary-details auxiliary)
    (when (pichat-live-draft-p draft)
      (pichat-chat--project-live-tail))))

(defun pichat-chat-toggle-thinking-display ()
  "Toggle thinking visibility by reprojecting current normalized state."
  (interactive)
  (setq pichat-chat-show-thinking (not pichat-chat-show-thinking))
  (when (and (derived-mode-p 'pichat-chat-mode)
             pichat-chat-session)
    (pichat-chat--reproject-display-options))
  (message "PiChat thinking display: %s"
           (if pichat-chat-show-thinking "shown" "hidden")))

(defun pichat-chat-refresh-status ()
  "Refresh Pi state displayed in the mode line."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-rpc-get-state pichat-chat-session
                         (lambda (_response _session)
                           (force-mode-line-update))))

;;;###autoload
(defun pichat-chat-set-session-name (name)
  "Set the display NAME for the current Pi session."
  (interactive
   (let* ((session (pichat-session-current))
          (current (and session (pichat-session-name session))))
     (unless session (user-error "No PiChat session"))
     (list (read-string "Session name: " current))))
  (let ((session (pichat-session-current)))
    (unless session (user-error "No PiChat session"))
    (pichat-rpc-set-session-name
     session
     name
     (lambda (_response s)
       (pichat-rpc-get-state
        s
        (lambda (_state-response _session)
          (when (buffer-live-p (pichat-session-buffer s))
            (with-current-buffer (pichat-session-buffer s)
              (pichat-chat--rename-buffer-maybe s)
              (force-mode-line-update)))
          (message "PiChat session name set: %s" name)))))))

(defun pichat-chat--markdown-fontify-region (beg end)
  "Fail-open Markdown-fontify completed assistant prose in BEG..END."
  (when pichat-chat-markdown-mode
    (pichat-markdown-fontification-apply-region beg end)))

(defun pichat-chat--tool-views-for-transcript (transcript live-p)
  "Return pure per-tool render views for TRANSCRIPT."
  (pichat-chat-tool-ui-views-for-transcript
   transcript live-p pichat-chat--source-generation
   pichat-chat--tool-view-states pichat-chat--live-draft
   pichat-chat-collapse-tools-by-default pichat-chat-tool-default-display))

(defun pichat-chat--render-tool-text-with-path-context
    (enrichments generation notice-format tool node-key context)
  "Render TOOL while supplying the owning session path context."
  (let ((pichat-tool-enrichment-path-context
         (and pichat-chat-session
              (pichat-session-path-context pichat-chat-session))))
    (pichat-chat-tool-ui-render-tool-text
     enrichments generation notice-format tool node-key context)))

(defun pichat-chat--activity-presentation-state (transcript live-p)
  "Return explicit activity presentation state for TRANSCRIPT and LIVE-P."
  (pichat-chat-activity-ui-presentation-state
   transcript '(thinking tool) pichat-chat-show-thinking live-p
   pichat-chat--source-generation pichat-chat--activity-view-states
   pichat-chat--live-draft pichat-chat-activity-group-display))

(defun pichat-chat--canonical-render-context (&optional transcript)
  "Return an explicit canonical render context for optional TRANSCRIPT."
  (let ((activity (and transcript
                       (pichat-chat--activity-presentation-state
                        transcript nil))))
    (pichat-render-context-create
     :show-thinking pichat-chat-show-thinking
     :tool-view (pichat-chat--tool-completed-display-state)
     :tool-views (and transcript
                      (pichat-chat--tool-views-for-transcript transcript nil))
     :tool-renderer
     (apply-partially
      #'pichat-chat--render-tool-text-with-path-context
      pichat-chat--tool-enrichments pichat-chat--source-generation
      pichat-chat-tool-truncation-notice-format)
     :max-tool-args pichat-chat-max-tool-args-chars
     :max-tool-output pichat-chat-max-tool-output-chars
     :activity-member-kinds '(thinking tool)
     :activity-display pichat-chat-activity-group-display
     :activity-views (plist-get activity :views)
     :activity-latest-key nil
     :activity-live-p nil
     :activity-header-renderer
     (apply-partially #'pichat-chat-activity-ui-format-header
                      pichat-chat--tool-enrichments
                      pichat-chat--source-generation))))

(defun pichat-chat--index-canonical-tools (transcript start end context
                                                      &optional live-p)
  "Build interactive tool blocks for TRANSCRIPT between START and END."
  (let ((pichat-tool-enrichment-path-context
         (and pichat-chat-session
              (pichat-session-path-context pichat-chat-session))))
    (pichat-chat-tool-ui-index-tools
     transcript start end context live-p pichat-chat--source-generation
     pichat-chat--tool-enrichments)))

(defun pichat-chat--index-activity-groups (start end &optional live-p)
  "Build activity header blocks between START and END for LIVE-P source."
  (pichat-chat-activity-ui-index-groups
   start end live-p pichat-chat--source-generation))

(defun pichat-chat--projection-snapshot ()
  "Capture buffer and projection state for transactional rollback."
  (let (block-markers activity-block-markers fragment-markers)
    (dolist (fragment pichat-chat--live-projection-fragments)
      (push (list fragment
                  (marker-position (plist-get fragment :start))
                  (marker-position (plist-get fragment :end)))
            fragment-markers))
    (dolist (table (list pichat-chat--canonical-tool-blocks
                         pichat-chat--live-tool-blocks))
      (when (hash-table-p table)
        (maphash
         (lambda (id block)
           (push (list id block
                       (marker-position (plist-get block :start))
                       (marker-position (plist-get block :end)))
                 block-markers))
         table)))
    (dolist (table (list pichat-chat--canonical-activity-blocks
                         pichat-chat--live-activity-blocks))
      (when (hash-table-p table)
        (maphash
         (lambda (key block)
           (push (list key block
                       (marker-position (plist-get block :start))
                       (marker-position (plist-get block :end)))
                 activity-block-markers))
         table)))
    (list :text (buffer-substring (point-min) (point-max))
          :point (point)
          :modified (buffer-modified-p)
          :undo-list (copy-tree buffer-undo-list)
          :pending-undo-list
          (and (boundp 'pending-undo-list)
               (copy-tree pending-undo-list))
          :markers
          (mapcar (lambda (marker)
                    (cons marker (and (markerp marker)
                                      (marker-position marker))))
                  (list pichat-chat--extension-status-start
                        pichat-chat--extension-status-end
                        pichat-chat--canonical-start
                        pichat-chat--canonical-end
                        pichat-chat--live-start pichat-chat--live-end
                        pichat-chat--status-start pichat-chat--status-end
                        pichat-chat--widget-start pichat-chat--widget-end
                        pichat-chat--prompt-start pichat-chat--input-start))
          :blocks pichat-chat--tool-blocks
          :canonical-blocks pichat-chat--canonical-tool-blocks
          :live-blocks pichat-chat--live-tool-blocks
          :block-markers block-markers
          :activity-blocks pichat-chat--activity-blocks
          :canonical-activity-blocks pichat-chat--canonical-activity-blocks
          :live-activity-blocks pichat-chat--live-activity-blocks
          :activity-block-markers activity-block-markers
          :live-fragments pichat-chat--live-projection-fragments
          :fragment-markers fragment-markers
          :view-states (and (hash-table-p pichat-chat--tool-view-states)
                            (copy-hash-table pichat-chat--tool-view-states))
          :activity-view-states
          (and (hash-table-p pichat-chat--activity-view-states)
               (copy-hash-table pichat-chat--activity-view-states))
          :auxiliary (and (hash-table-p pichat-chat--tool-auxiliary-details)
                          (copy-hash-table
                           pichat-chat--tool-auxiliary-details))
          :cache pichat-chat--entry-cache
          :transcript pichat-chat--canonical-transcript
          :draft pichat-chat--live-draft
          :live-fingerprint pichat-chat--live-projection-fingerprint
          :statuses (copy-tree pichat-chat--status-lines)
          :notifications (copy-tree pichat-chat--extension-notifications))))

(defun pichat-chat--restore-projection-snapshot (snapshot)
  "Restore projection SNAPSHOT after a failed edit."
  (pichat-chat--with-buffer-edit
    (erase-buffer)
    (insert (plist-get snapshot :text)))
  (dolist (entry (plist-get snapshot :markers))
    (set-marker (car entry) (cdr entry)))
  (dolist (entry (plist-get snapshot :block-markers))
    (set-marker (plist-get (cadr entry) :start) (nth 2 entry))
    (set-marker-insertion-type (plist-get (cadr entry) :start) t)
    (set-marker (plist-get (cadr entry) :end) (nth 3 entry)))
  (dolist (entry (plist-get snapshot :activity-block-markers))
    (set-marker (plist-get (cadr entry) :start) (nth 2 entry))
    (set-marker-insertion-type (plist-get (cadr entry) :start) t)
    (set-marker (plist-get (cadr entry) :end) (nth 3 entry)))
  (unless (eq pichat-chat--live-projection-fragments
              (plist-get snapshot :live-fragments))
    (pichat-chat--release-live-projection-fragments))
  (dolist (entry (plist-get snapshot :fragment-markers))
    (set-marker (plist-get (car entry) :start) (nth 1 entry))
    (set-marker-insertion-type (plist-get (car entry) :start) t)
    (set-marker (plist-get (car entry) :end) (nth 2 entry)))
  (setq pichat-chat--tool-blocks (plist-get snapshot :blocks)
        pichat-chat--canonical-tool-blocks
        (plist-get snapshot :canonical-blocks)
        pichat-chat--live-tool-blocks (plist-get snapshot :live-blocks)
        pichat-chat--activity-blocks (plist-get snapshot :activity-blocks)
        pichat-chat--canonical-activity-blocks
        (plist-get snapshot :canonical-activity-blocks)
        pichat-chat--live-activity-blocks
        (plist-get snapshot :live-activity-blocks)
        pichat-chat--live-projection-fragments
        (plist-get snapshot :live-fragments)
        pichat-chat--tool-view-states (plist-get snapshot :view-states)
        pichat-chat--activity-view-states
        (plist-get snapshot :activity-view-states)
        pichat-chat--tool-auxiliary-details (plist-get snapshot :auxiliary)
        pichat-chat--entry-cache (plist-get snapshot :cache)
        pichat-chat--canonical-transcript (plist-get snapshot :transcript)
        pichat-chat--live-draft (plist-get snapshot :draft)
        pichat-chat--live-projection-fingerprint
        (plist-get snapshot :live-fingerprint)
        pichat-chat--status-lines (plist-get snapshot :statuses)
        pichat-chat--extension-notifications
        (plist-get snapshot :notifications))
  (pichat-chat-tool-ui-refresh-decorations
   pichat-chat--tool-blocks pichat-chat--tool-enrichments
   pichat-chat--source-generation)
  (goto-char (min (point-max) (plist-get snapshot :point)))
  (setq buffer-undo-list (plist-get snapshot :undo-list))
  (when (boundp 'pending-undo-list)
    (setq pending-undo-list (plist-get snapshot :pending-undo-list)))
  ;; Optional presentation overlays are intentionally outside projection
  ;; rollback ownership.  Exact source and fontification properties are part
  ;; of the text snapshot; a later presentation refresh may derive overlays.
  (set-buffer-modified-p (plist-get snapshot :modified)))

(defun pichat-chat--hash-state-snapshot (table)
  "Return a shallow contents snapshot retaining hash TABLE identity."
  (and (hash-table-p table) (cons table (copy-hash-table table))))

(defun pichat-chat--restore-hash-state (snapshot)
  "Restore hash SNAPSHOT and return its original table."
  (when snapshot
    (let ((table (car snapshot))
          (contents (cdr snapshot)))
      (clrhash table)
      (maphash (lambda (key value) (puthash key value table)) contents)
      table)))

(defun pichat-chat--focused-fragment-snapshot ()
  "Capture current live fragment objects and their marker positions."
  (mapcar
   (lambda (fragment)
     (list fragment
           (marker-position (plist-get fragment :start))
           (marker-position (plist-get fragment :end))))
   pichat-chat--live-projection-fragments))

(defun pichat-chat--focused-block-snapshot ()
  "Capture current live block objects, boundaries, and location overlays."
  (let (records)
    (when (hash-table-p pichat-chat--live-tool-blocks)
      (maphash
       (lambda (_id block)
         (let ((start (plist-get block :start))
               (end (plist-get block :end))
               (overlay (plist-get block :overlay)))
           (push (list :block block
                       :start (marker-position start)
                       :start-insertion (marker-insertion-type start)
                       :end (marker-position end)
                       :overlay overlay
                       :overlay-start (and (overlayp overlay)
                                           (overlay-start overlay))
                       :overlay-end (and (overlayp overlay)
                                         (overlay-end overlay)))
                 records)))
       pichat-chat--live-tool-blocks))
    records))

(defun pichat-chat--focused-activity-block-snapshot ()
  "Capture current live activity block identities and boundaries."
  (let (records)
    (when (hash-table-p pichat-chat--live-activity-blocks)
      (maphash
       (lambda (_key block)
         (let ((start (plist-get block :start))
               (end (plist-get block :end)))
           (push (list :block block
                       :start (marker-position start)
                       :start-insertion (marker-insertion-type start)
                       :end (marker-position end))
                 records)))
       pichat-chat--live-activity-blocks))
    records))

(defun pichat-chat--focused-live-snapshot (_candidate)
  "Capture owned state for focused rollback of a live candidate.
No chat-buffer text is copied; the active Emacs change group owns text undo."
  (list
   :modified (buffer-modified-p)
   :markers
   (mapcar (lambda (marker) (cons marker (marker-position marker)))
           (list pichat-chat--live-start pichat-chat--live-end
                 pichat-chat--status-start pichat-chat--status-end
                 pichat-chat--widget-start pichat-chat--widget-end
                 pichat-chat--prompt-start pichat-chat--input-start))
   :blocks pichat-chat--tool-blocks
   :live-blocks pichat-chat--live-tool-blocks
   :block-state (pichat-chat--focused-block-snapshot)
   :activity-blocks pichat-chat--activity-blocks
   :live-activity-blocks pichat-chat--live-activity-blocks
   :activity-block-state (pichat-chat--focused-activity-block-snapshot)
   :fragments pichat-chat--live-projection-fragments
   :fragment-state (pichat-chat--focused-fragment-snapshot)
   :view-states
   (pichat-chat--hash-state-snapshot pichat-chat--tool-view-states)
   :activity-view-states
   (pichat-chat--hash-state-snapshot pichat-chat--activity-view-states)
   :auxiliary
   (pichat-chat--hash-state-snapshot pichat-chat--tool-auxiliary-details)
   :enrichments
   (pichat-chat--hash-state-snapshot pichat-chat--tool-enrichments)
   :fingerprint pichat-chat--live-projection-fingerprint
   :statuses (copy-tree pichat-chat--status-lines)))

(defun pichat-chat--restore-focused-live-snapshot (snapshot)
  "Restore owned projection state from focused live SNAPSHOT."
  ;; Current tables may contain retained old blocks as well as newly indexed
  ;; blocks.  Release all of them, then revive the captured objects exactly.
  (pichat-chat--release-live-tool-blocks)
  (pichat-chat--release-live-activity-blocks)
  (let ((start (cdr (assq pichat-chat--live-start
                          (plist-get snapshot :markers))))
        (end (cdr (assq pichat-chat--live-end
                        (plist-get snapshot :markers)))))
    (when (and start end)
      (dolist (overlay (overlays-in start end))
        (when (overlay-get overlay 'pichat-tool-location-overlay)
          (delete-overlay overlay)))))
  (pichat-chat--release-live-projection-fragments)
  (dolist (entry (plist-get snapshot :markers))
    (set-marker (car entry) (cdr entry)))
  (setq pichat-chat--tool-blocks (plist-get snapshot :blocks)
        pichat-chat--live-tool-blocks (plist-get snapshot :live-blocks)
        pichat-chat--activity-blocks (plist-get snapshot :activity-blocks)
        pichat-chat--live-activity-blocks
        (plist-get snapshot :live-activity-blocks)
        pichat-chat--live-projection-fragments
        (plist-get snapshot :fragments)
        pichat-chat--tool-view-states
        (pichat-chat--restore-hash-state (plist-get snapshot :view-states))
        pichat-chat--activity-view-states
        (pichat-chat--restore-hash-state
         (plist-get snapshot :activity-view-states))
        pichat-chat--tool-auxiliary-details
        (pichat-chat--restore-hash-state (plist-get snapshot :auxiliary))
        pichat-chat--tool-enrichments
        (pichat-chat--restore-hash-state (plist-get snapshot :enrichments))
        pichat-chat--live-projection-fingerprint
        (plist-get snapshot :fingerprint)
        pichat-chat--status-lines (plist-get snapshot :statuses))
  (dolist (entry (plist-get snapshot :fragment-state))
    (let ((fragment (car entry)))
      (set-marker (plist-get fragment :start) (nth 1 entry))
      (set-marker-insertion-type (plist-get fragment :start) t)
      (set-marker (plist-get fragment :end) (nth 2 entry))))
  (dolist (entry (plist-get snapshot :activity-block-state))
    (let* ((block (plist-get entry :block))
           (start (plist-get block :start))
           (end (plist-get block :end)))
      (set-marker start (plist-get entry :start))
      (set-marker-insertion-type start (plist-get entry :start-insertion))
      (set-marker end (plist-get entry :end))))
  (dolist (entry (plist-get snapshot :block-state))
    (let* ((block (plist-get entry :block))
           (start (plist-get block :start))
           (end (plist-get block :end))
           (overlay (plist-get entry :overlay)))
      (set-marker start (plist-get entry :start))
      (set-marker-insertion-type
       start (plist-get entry :start-insertion))
      (set-marker end (plist-get entry :end))
      (setf (plist-get block :overlay) overlay)
      (when (and (overlayp overlay)
                 (plist-get entry :overlay-start)
                 (plist-get entry :overlay-end))
        (move-overlay overlay
                      (plist-get entry :overlay-start)
                      (plist-get entry :overlay-end)
                      (current-buffer)))))
  (set-buffer-modified-p (plist-get snapshot :modified)))

(defun pichat-chat--focused-live-rollback-safe-p (candidate)
  "Return non-nil when CANDIDATE can use the focused live transaction."
  (let* ((markers (list pichat-chat--canonical-end
                        pichat-chat--live-start pichat-chat--live-end
                        pichat-chat--status-start pichat-chat--status-end
                        pichat-chat--prompt-start pichat-chat--input-start))
         (positions
          (mapcar (lambda (marker)
                    (and (markerp marker) (marker-position marker)))
                  markers))
         ;; Empty widget markers may intentionally remain at the stable shell
         ;; boundary, so validate them without imposing conversation order.
         (widget-positions
          (mapcar (lambda (marker)
                    (and (markerp marker) (marker-position marker)))
                  (list pichat-chat--widget-start
                        pichat-chat--widget-end)))
         (compatibility
          (pichat-chat--compatibility-diagnostics-text
           (plist-get candidate :transcript))))
    (and (not (memq nil positions))
         (not (memq nil widget-positions))
         (cl-every (lambda (position) (<= position (point-max)))
                   widget-positions)
         (cl-loop for (first second) on positions
                  while second always (<= first second))
         (<= (car (last positions)) (point-max))
         ;; A status edit lies outside the live transaction.  Use the complete
         ;; transaction if this candidate needs one.
         (equal compatibility
                (cdr (assq 'compatibility pichat-chat--status-lines))))))

(defun pichat-chat--call-with-focused-live-rollback (candidate function)
  "Call FUNCTION in a focused change-group transaction for CANDIDATE."
  (let ((snapshot (pichat-chat--focused-live-snapshot candidate)))
    (let ((buffer-undo-list nil)
          (pichat-chat--focused-change-group-active-p t)
          (pichat-chat--projection-transaction-depth 1)
          (change-group (prepare-change-group))
          accepted)
      (activate-change-group change-group)
      (condition-case err
          (prog1 (funcall function)
            (accept-change-group change-group)
            (setq accepted t))
        ((error quit)
         (unless accepted
           (let ((inhibit-read-only t)
                 (inhibit-modification-hooks t)
                 (pichat-chat--inhibit-edit-guard t))
             (cancel-change-group change-group)))
         (pichat-chat--restore-focused-live-snapshot snapshot)
         (signal (car err) (cdr err)))))))

(defmacro pichat-chat--with-projection-rollback (&rest body)
  "Run BODY atomically and restore the complete projection if it signals.
Nested transactions share the outer snapshot and propagate failures to its
single rollback owner."
  (declare (indent 0) (debug t))
  `(if (> pichat-chat--projection-transaction-depth 0)
       (progn ,@body)
     (let ((snapshot (pichat-chat--projection-snapshot))
           (pichat-chat--projection-transaction-depth 1))
       (condition-case err
           (progn ,@body)
         (error
          (pichat-chat--restore-projection-snapshot snapshot)
          (signal (car err) (cdr err)))))))

(defmacro pichat-chat--with-live-projection-rollback (candidate &rest body)
  "Run BODY with focused rollback for safe live CANDIDATE changes.
Uncertain live state retains the complete projection transaction."
  (declare (indent 1) (debug (form body)))
  `(let ((live-candidate ,candidate))
     (if (> pichat-chat--projection-transaction-depth 0)
         (progn ,@body)
       (if (pichat-chat--focused-live-rollback-safe-p live-candidate)
           (pichat-chat--call-with-focused-live-rollback
            live-candidate (lambda () ,@body))
         (pichat-chat--with-projection-rollback ,@body)))))

(defun pichat-chat--commit-live-tool-view-transfers ()
  "Move matching explicit live tool views to canonical transcript keys.
This walks normalized canonical content so tools hidden by a folded activity
parent retain their independent explicit state."
  (when (pichat-transcript-p pichat-chat--canonical-transcript)
    (dolist (node (pichat-transcript-nodes pichat-chat--canonical-transcript))
      (dolist (content (pichat-transcript-node-content node))
        (when (eq (pichat-transcript-content-kind content) 'tool)
          (let* ((tool-id (pichat-transcript-content-tool-call-id content))
                 (live-key (pichat-chat--live-tool-view-key tool-id))
                 (state (gethash live-key pichat-chat--tool-view-states)))
            (when state
              (puthash (pichat-chat--canonical-tool-view-key
                        (pichat-transcript-node-key node) tool-id)
                       state pichat-chat--tool-view-states)
              (remhash live-key pichat-chat--tool-view-states))))))))

(defun pichat-chat--commit-live-activity-view-transfers ()
  "Move compatible live activity choices to projected canonical groups."
  (pichat-chat-activity-ui-transfer-live-views
   pichat-chat--canonical-activity-blocks
   pichat-chat--activity-view-states pichat-chat--source-generation))

(defun pichat-chat--extension-notification-face (type)
  "Return the display face for extension notification TYPE."
  (pcase type
    ("error" 'error)
    ("warning" 'warning)
    (_ 'shadow)))

(defun pichat-chat--extension-notification-text (type message)
  "Return bounded multiline notification text for TYPE and MESSAGE."
  (let* ((type (if (stringp type) type "info"))
         (message (ansi-color-filter-apply
                   (if (stringp message) message "")))
         (message (truncate-string-to-width
                   (substring-no-properties message)
                   pichat-chat-max-extension-notification-chars
                   nil nil "…")))
    (propertize (format "[extension %s]\n%s" type message)
                'pichat-extension-notification t
                'font-lock-face (pichat-chat--extension-notification-face type))))

(defun pichat-chat--node-end-position (key start end)
  "Return the end of node KEY between START and END, or nil."
  (when-let ((position (text-property-any start end 'pichat-node-key key)))
    (or (next-single-property-change position 'pichat-node-key nil end)
        end)))

(defun pichat-chat--notification-insertion (record position start _end)
  "Return insertion text for RECORD at POSITION after START."
  (concat (when (> position start) "\n\n")
          (plist-get record :text)))

(defun pichat-chat--insert-projected-extension-notifications (start end)
  "Insert current source's anchored notifications in START..END.
Return the resulting end position."
  (dolist (record (reverse (copy-sequence
                            pichat-chat--extension-notifications)))
    (when (= (plist-get record :generation) pichat-chat--source-generation)
      (let* ((anchor (plist-get record :anchor))
             (position (if anchor
                           (pichat-chat--node-end-position anchor start end)
                         start)))
        (when position
          (goto-char position)
          (let* ((text (pichat-chat--notification-insertion
                        record position start end))
                 (beg (point)))
            (insert text)
            (pichat-chat--protect-region beg (point))
            (cl-incf end (length text)))))))
  end)

(defun pichat-chat--current-notification-anchor ()
  "Return the last currently rendered canonical node key."
  (when (and (pichat-transcript-p pichat-chat--canonical-transcript)
             (markerp pichat-chat--canonical-start)
             (markerp pichat-chat--canonical-end))
    (let ((start (marker-position pichat-chat--canonical-start))
          (end (marker-position pichat-chat--canonical-end)))
      (cl-loop for node in (reverse
                            (pichat-transcript-nodes
                             pichat-chat--canonical-transcript))
               for key = (pichat-transcript-node-key node)
               when (and start end
                         (text-property-any start end 'pichat-node-key key))
               return key))))

(defun pichat-chat--append-extension-notification (type message)
  "Append a buffer-local extension notification of TYPE containing MESSAGE."
  (pichat-chat--preserve-view
    (pichat-chat--with-projection-rollback
      (let* ((end (marker-position pichat-chat--canonical-end))
             (anchor (pichat-chat--current-notification-anchor))
             (position end)
             (record (list :generation pichat-chat--source-generation
                           :anchor anchor
                           :text (pichat-chat--extension-notification-text
                                  type message)))
             (text (concat (plist-get record :text) "\n\n"))
             (tracked
              (delq nil
                    (mapcar
                     (lambda (marker)
                       (when (and (markerp marker) (marker-position marker))
                         (cons marker (marker-position marker))))
                     (list pichat-chat--canonical-end
                           pichat-chat--live-start pichat-chat--live-end
                           pichat-chat--status-start pichat-chat--status-end
                           pichat-chat--widget-start pichat-chat--widget-end
                           pichat-chat--prompt-start pichat-chat--input-start))))
             (modified (buffer-modified-p)))
        (setq pichat-chat--extension-notifications
              (append pichat-chat--extension-notifications (list record)))
        (pichat-chat--with-buffer-edit
          (goto-char position)
          (let ((beg (point)))
            (insert text)
            (pichat-chat--protect-region beg (point)))
          (dolist (entry tracked)
            (when (>= (cdr entry) position)
              (set-marker (car entry) (+ (cdr entry) (length text)))))
          (pichat-chat--style-live-input))
        (set-buffer-modified-p modified)))))

(defun pichat-chat--project-canonical (cache transcript fragment context
                                             &optional transfer-live-views-p)
  "Atomically project CACHE, TRANSCRIPT, and rendered FRAGMENT using CONTEXT.
When TRANSFER-LIVE-VIEWS-P is non-nil, commit matching explicit live views to
canonical keys as part of the projection transaction."
  (pichat-chat--preserve-view
    (pichat-chat--with-projection-rollback
        (pichat-chat--cancel-live-projection)
        (pichat-chat--release-tool-blocks)
        (pichat-chat--release-activity-blocks)
        (pichat-chat--release-live-projection-fragments)
        (let* ((modified (buffer-modified-p))
               (rendered
                (pichat-render-fragment-propertized-string fragment))
               (canonical-start
                (marker-position pichat-chat--canonical-start))
               (replace-end (marker-position pichat-chat--live-end))
               (tracked
                (delq nil
                      (mapcar
                       (lambda (marker)
                         (when-let ((position (marker-position marker)))
                           (cons marker position)))
                       (list pichat-chat--status-start pichat-chat--status-end
                             pichat-chat--widget-start pichat-chat--widget-end
                             pichat-chat--prompt-start
                             pichat-chat--input-start))))
               (statuses-before (copy-tree pichat-chat--status-lines))
               canonical-end blocks activity-blocks)
          (pichat-chat--with-buffer-edit
            (delete-region canonical-start replace-end)
            (goto-char canonical-start)
            (insert rendered)
            (let ((rendered-end (point)))
              (when pichat-chat-markdown-mode
                (pichat-chat--markdown-fontify-region
                 canonical-start rendered-end))
              (setq canonical-end
                    (pichat-chat--insert-projected-extension-notifications
                     canonical-start rendered-end)))
            (goto-char canonical-end)
            (unless (= canonical-start canonical-end)
              (insert "\n\n")
              (setq canonical-end (point)))
            (let ((delta (- canonical-end replace-end)))
              (set-marker pichat-chat--canonical-start canonical-start)
              (set-marker pichat-chat--canonical-end canonical-end)
              (set-marker pichat-chat--live-start canonical-end)
              (set-marker pichat-chat--live-end canonical-end)
              (dolist (entry tracked)
                (when (>= (cdr entry) replace-end)
                  (set-marker (car entry) (+ (cdr entry) delta)))))
            (pichat-chat--protect-region canonical-start canonical-end)
            (pichat-chat--style-live-input)
            (setq blocks
                  (pichat-chat--index-canonical-tools
                   transcript canonical-start canonical-end context)
                  activity-blocks
                  (pichat-chat--index-activity-groups
                   canonical-start canonical-end nil)))
          ;; Adjust prompt undo positions from the final projected prefix.
          (pichat-chat--adjust-undo-for-prefix-delta
           replace-end
           (- (marker-position pichat-chat--live-end) replace-end))
          (setq pichat-chat--entry-cache cache
                pichat-chat--canonical-transcript transcript
                pichat-chat--live-draft
                (pichat-live-draft-empty pichat-chat--source-generation)
                pichat-chat--live-projection-fingerprint nil
                pichat-chat--live-projection-fragments nil
                pichat-chat--canonical-tool-blocks blocks
                pichat-chat--live-tool-blocks (make-hash-table :test #'equal)
                pichat-chat--tool-blocks
                (pichat-chat--merge-tool-block-tables
                 pichat-chat--canonical-tool-blocks
                 pichat-chat--live-tool-blocks)
                pichat-chat--canonical-activity-blocks activity-blocks
                pichat-chat--live-activity-blocks
                (make-hash-table :test #'equal)
                pichat-chat--activity-blocks
                (pichat-chat-activity-ui-merge-block-tables
                 pichat-chat--canonical-activity-blocks
                 pichat-chat--live-activity-blocks))
          (when transfer-live-views-p
            (pichat-chat--commit-live-tool-view-transfers)
            (pichat-chat--commit-live-activity-view-transfers)
            (pichat-chat-activity-ui-prune-views
             pichat-chat--canonical-activity-blocks
             pichat-chat--live-activity-blocks
             pichat-chat--activity-view-states
             pichat-chat--source-generation))
          (clrhash pichat-chat--tool-auxiliary-details)
          (dolist (key '(agent compaction retry queue synchronization source))
            (pichat-chat--set-status-state key nil))
          (when pichat-chat--recoverable-submissions
            (pichat-chat--set-status-state
             'recovery
             (format "[%d submission%s available for recovery]"
                     (length pichat-chat--recoverable-submissions)
                     (if (= 1 (length pichat-chat--recoverable-submissions))
                         "" "s"))))
          (pichat-chat--set-status-state
           'compatibility
           (pichat-chat--compatibility-diagnostics-text transcript))
          (unless (equal statuses-before pichat-chat--status-lines)
            (pichat-chat--render-status-region))
          (set-buffer-modified-p modified)))
    ;; Commit canonical text and fontification before attempting the optional
    ;; inline overlay layer, whose cache and failures are not transactional.
    (pichat-markdown-presentation--refresh-after-toggle)))

(defun pichat-chat--cancel-live-projection ()
  "Cancel the pending coalesced live-tail projection."
  (when (timerp pichat-chat--live-projection-timer)
    (cancel-timer pichat-chat--live-projection-timer))
  (setq pichat-chat--live-projection-timer nil
        pichat-chat--live-projection-priority nil))

(defun pichat-chat--run-live-projection (buffer generation)
  "Project BUFFER's live tail when GENERATION remains current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pichat-chat--live-projection-timer nil
            pichat-chat--live-projection-priority nil)
      (when (= generation pichat-chat--source-generation)
        (pichat-chat--project-live-tail)))))

(defun pichat-chat--schedule-live-projection (&optional delay urgent)
  "Schedule one coalesced live-tail projection after DELAY seconds.
Use the ordinary live delay when DELAY is nil.  URGENT replaces a pending
normal timer, but adjacent urgent terminal events share one next-tick render."
  (when (and urgent pichat-chat--live-projection-timer
             (not (eq pichat-chat--live-projection-priority 'urgent)))
    (pichat-chat--cancel-live-projection))
  (unless pichat-chat--live-projection-timer
    (setq pichat-chat--live-projection-priority
          (if urgent 'urgent 'normal)
          pichat-chat--live-projection-timer
          (run-with-idle-timer
           (or delay pichat-chat-live-update-delay) nil
           #'pichat-chat--run-live-projection
           (current-buffer) pichat-chat--source-generation))))

(defun pichat-chat--flush-live-projection ()
  "Cancel pending work and immediately project the latest live state."
  (pichat-chat--cancel-live-projection)
  (pichat-chat--project-live-tail))

(defun pichat-chat--flush-or-expedite-live-projection ()
  "Coalesce with pending stream work, otherwise project immediately.
A terminal event upgrades an existing delayed update to one next-tick urgent
projection.  Without pending work it remains immediately visible."
  (if pichat-chat--live-projection-timer
      (pichat-chat--schedule-live-projection 0 t)
    (pichat-chat--flush-live-projection)))

(defun pichat-chat--live-render-context (transcript)
  "Return status-aware render policy for transient TRANSCRIPT."
  (let ((activity (pichat-chat--activity-presentation-state transcript t)))
    (pichat-render-context-create
     :show-thinking pichat-chat-show-thinking
     :tool-view 'output
     :tool-views (pichat-chat--tool-views-for-transcript transcript t)
     :tool-renderer
     (apply-partially
      #'pichat-chat--render-tool-text-with-path-context
      pichat-chat--tool-enrichments pichat-chat--source-generation
      pichat-chat-tool-truncation-notice-format)
     :max-tool-args pichat-chat-max-tool-args-chars
     :max-tool-output pichat-chat-max-tool-output-chars
     :activity-member-kinds '(thinking tool)
     :activity-display pichat-chat-activity-group-display
     :activity-views (plist-get activity :views)
     :activity-latest-key (plist-get activity :latest-key)
     :activity-live-p t
     :activity-header-renderer
     (apply-partially #'pichat-chat-activity-ui-format-header
                      pichat-chat--tool-enrichments
                      pichat-chat--source-generation))))

(defun pichat-chat--merge-tool-block-tables (first second)
  "Return a combined tool-block table containing FIRST and SECOND.
Block objects and their markers are shared, but neither ownership table is
mutated.  SECOND wins if a transient tool id collides with a canonical id."
  (let ((combined (make-hash-table :test #'equal)))
    (when (hash-table-p first)
      (maphash (lambda (key value) (puthash key value combined)) first))
    (when (hash-table-p second)
      (maphash (lambda (key value) (puthash key value combined)) second))
    combined))

(defun pichat-chat--live-tool-identities (transcript context)
  "Return ordered interactive and decorative tool identity for TRANSCRIPT."
  (let (identities)
    (dolist (node (pichat-transcript-nodes transcript))
      (dolist (content (pichat-transcript-node-content node))
        (when (eq 'tool (pichat-transcript-content-kind content))
          (let* ((node-key (pichat-transcript-node-key node))
                 (tool-id (pichat-transcript-content-tool-call-id content))
                 (record
                  (pichat-chat-tool-ui-enrichment
                   pichat-chat--tool-enrichments
                   pichat-chat--source-generation tool-id)))
            (push
             (list node-key tool-id
                   (pichat-transcript-content-name content)
                   (pichat-transcript-content-status content)
                   (pichat-render-tool-view-for
                    context node-key tool-id)
                   (pichat-transcript-content-arguments content)
                   (pichat-chat-tool-ui--canonical-output content)
                   (pichat-chat-tool-ui-location-string record))
             identities)))))
    (nreverse identities)))

(defun pichat-chat--live-candidate-fingerprint
    (transcript replacement tool-identities)
  "Return complete visible and interactive identity for a live candidate."
  (cons
   replacement
   (list pichat-chat--source-generation
         (pichat-live-draft-message-final-p pichat-chat--live-draft)
         (pichat-live-draft-settled-p pichat-chat--live-draft)
         (pichat-chat--compatibility-diagnostics-text transcript)
         tool-identities)))

(defun pichat-chat--live-fingerprints-equal-p (first second)
  "Return non-nil when live fingerprints FIRST and SECOND are identical."
  (and first second
       (equal-including-properties (car first) (car second))
       (equal (cdr first) (cdr second))))

(defun pichat-chat--build-live-candidate ()
  "Build the authoritative live presentation without editing the buffer."
  (when (and (pichat-live-draft-p pichat-chat--live-draft)
             (markerp pichat-chat--live-start)
             (marker-position pichat-chat--live-start)
             (markerp pichat-chat--live-end)
             (marker-position pichat-chat--live-end))
    (let* ((transcript (pichat-live-draft-as-transcript
                        pichat-chat--live-draft))
           (context (pichat-chat--live-render-context transcript))
           (tool-identities
            (pichat-chat--live-tool-identities transcript context))
           (fragments
            (mapcar
             (lambda (fragment)
               (let ((tool-id (plist-get fragment :tool-id)))
                 (append fragment
                         (list :identity
                               (and tool-id
                                    (cl-find-if
                                     (lambda (identity)
                                       (and (equal
                                             (plist-get fragment :node-key)
                                             (car identity))
                                            (equal tool-id (cadr identity))))
                                     tool-identities))))))
             (pichat-render-logical-strings transcript context)))
           (fragments
            (if fragments
                (append fragments
                        (list (list :key '(live-end)
                                    :node-key nil :tool-id nil
                                    :text "\n\n" :identity nil)))
              nil))
           (replacement
            (mapconcat (lambda (fragment) (plist-get fragment :text))
                       fragments "")))
      (list :transcript transcript
            :context context
            :fragments fragments
            :replacement replacement
            :fingerprint
            (pichat-chat--live-candidate-fingerprint
             transcript replacement tool-identities)
            :final-p
            (pichat-live-draft-message-final-p pichat-chat--live-draft)))))

(defun pichat-chat--live-fragment-equivalent-p (old new)
  "Return non-nil when OLD and NEW are the same logical live fragment."
  (and (equal (plist-get old :key) (plist-get new :key))
       (equal-including-properties
        (plist-get old :text) (plist-get new :text))
       (equal (plist-get old :identity) (plist-get new :identity))))

(defun pichat-chat--live-fragment-keys-unique-p (fragments)
  "Return non-nil when FRAGMENTS have unique non-nil logical keys."
  (let ((seen (make-hash-table :test #'equal))
        unique)
    (setq unique t)
    (dolist (fragment fragments)
      (let ((key (plist-get fragment :key)))
        (if (or (null key) (gethash key seen))
            (setq unique nil)
          (puthash key t seen))))
    unique))

(defun pichat-chat--live-fragments-valid-p (fragments start end)
  "Return non-nil when FRAGMENTS still describe contiguous START..END text."
  (if (null fragments)
      (= start end)
    (let ((position start)
          valid)
      (setq valid t)
      (dolist (fragment fragments)
        (let ((fragment-start
               (marker-position (plist-get fragment :start)))
              (fragment-end
               (marker-position (plist-get fragment :end))))
          (let ((actual (and fragment-start fragment-end
                             (<= fragment-start fragment-end)
                             (buffer-substring fragment-start fragment-end))))
            (when actual
              ;; Projection protection is added after pure rendering and is
              ;; therefore not part of fragment identity.
              (remove-text-properties
               0 (length actual)
               '(read-only nil front-sticky nil rear-nonsticky nil
                 pichat-transcript nil fontified nil)
               actual))
            (if (and fragment-start fragment-end
                     (= fragment-start position)
                     (<= fragment-start fragment-end)
                     (equal-including-properties
                      (plist-get fragment :text) actual))
                (setq position fragment-end)
              (setq valid nil)))))
      (and valid (= position end)))))

(defun pichat-chat--make-live-fragment-state (fragments start)
  "Return committed state for rendered FRAGMENTS beginning at START."
  (let ((position start)
        state)
    (dolist (fragment fragments)
      (let* ((text (plist-get fragment :text))
             (end (+ position (length text)))
             (record (append fragment
                             (list :start (copy-marker position t)
                                   :end (copy-marker end nil)))))
        (push record state)
        (setq position end)))
    (nreverse state)))

(defun pichat-chat--live-suffix-marker-positions ()
  "Return tracked marker positions after the replaceable live tail."
  (delq nil
        (mapcar
         (lambda (marker)
           (when (and (markerp marker) (marker-position marker))
             (cons marker (marker-position marker))))
         (list pichat-chat--status-start pichat-chat--status-end
               pichat-chat--prompt-start pichat-chat--input-start))))

(defun pichat-chat--adjust-live-suffix-markers (tracked boundary delta)
  "Shift TRACKED markers at or after BOUNDARY by DELTA."
  (dolist (entry tracked)
    (when (>= (cdr entry) boundary)
      (set-marker (car entry) (+ (cdr entry) delta)))))

(defun pichat-chat--replace-live-full (candidate)
  "Fully replace the live region with CANDIDATE and return committed state."
  (let* ((transcript (plist-get candidate :transcript))
         (context (plist-get candidate :context))
         (fragments (plist-get candidate :fragments))
         (replacement (plist-get candidate :replacement))
         (start (marker-position pichat-chat--live-start))
         (end (marker-position pichat-chat--live-end))
         (tracked (pichat-chat--live-suffix-marker-positions))
         (delta (- (length replacement) (- end start)))
         fragment-state blocks activity-blocks)
    (pichat-chat--release-live-projection-fragments)
    (pichat-chat--with-buffer-edit
      (delete-region start end)
      (goto-char start)
      (let ((beg (point)))
        (insert replacement)
        (when (and pichat-chat-markdown-mode
                   (plist-get candidate :final-p))
          (pichat-chat--markdown-fontify-region beg (point)))
        (pichat-chat--protect-region beg (point)))
      (set-marker pichat-chat--live-start start)
      (set-marker pichat-chat--live-end (+ start (length replacement)))
      (pichat-chat--adjust-live-suffix-markers tracked end delta)
      (pichat-chat--style-live-input)
      (setq fragment-state
            (pichat-chat--make-live-fragment-state fragments start)))
    (pichat-chat--release-live-tool-blocks)
    (pichat-chat--release-live-activity-blocks)
    (setq blocks
          (pichat-chat--index-canonical-tools
           transcript start (+ start (length replacement)) context t)
          activity-blocks
          (pichat-chat--index-activity-groups
           start (+ start (length replacement)) t))
    (list :fragments fragment-state :blocks blocks
          :activity-blocks activity-blocks :incremental nil)))

(defun pichat-chat--live-fragment-change-span (old new)
  "Return OLD/NEW middle span metadata, or nil when no fragments differ."
  (let* ((old-count (length old))
         (new-count (length new))
         (prefix 0)
         (suffix 0))
    (while (and (< prefix old-count) (< prefix new-count)
                (pichat-chat--live-fragment-equivalent-p
                 (nth prefix old) (nth prefix new)))
      (cl-incf prefix))
    (while (and (< suffix (- old-count prefix))
                (< suffix (- new-count prefix))
                (pichat-chat--live-fragment-equivalent-p
                 (nth (- old-count suffix 1) old)
                 (nth (- new-count suffix 1) new)))
      (cl-incf suffix))
    (unless (and (= prefix old-count) (= prefix new-count))
      (list :prefix prefix :suffix suffix
            :old-end (- old-count suffix)
            :new-end (- new-count suffix)))))

(defun pichat-chat--live-block-overlaps-p (block start end)
  "Return non-nil when BLOCK overlaps the non-empty START..END range."
  (let ((block-start (marker-position (plist-get block :start)))
        (block-end (marker-position (plist-get block :end))))
    (and block-start block-end (< start end)
         (< block-start end) (> block-end start))))

(defun pichat-chat--replace-live-fragments (candidate)
  "Incrementally replace changed CANDIDATE fragments, or return nil if unsafe."
  (let* ((old pichat-chat--live-projection-fragments)
         (new (plist-get candidate :fragments))
         (live-start (marker-position pichat-chat--live-start))
         (live-end (marker-position pichat-chat--live-end))
         (span (and old
                    (pichat-chat--live-fragment-keys-unique-p old)
                    (pichat-chat--live-fragment-keys-unique-p new)
                    (pichat-chat--live-fragments-valid-p
                     old live-start live-end)
                    (pichat-chat--live-fragment-change-span old new))))
    (when span
      (let* ((prefix-count (plist-get span :prefix))
             (suffix-count (plist-get span :suffix))
             (old-end-index (plist-get span :old-end))
             (new-end-index (plist-get span :new-end))
             (old-middle (cl-subseq old prefix-count old-end-index))
             (new-middle (cl-subseq new prefix-count new-end-index))
             (start (if (< prefix-count (length old))
                        (marker-position
                         (plist-get (nth prefix-count old) :start))
                      live-end))
             (end (if (> suffix-count 0)
                      (marker-position
                       (plist-get (nth old-end-index old) :start))
                    live-end))
             (replacement
              (mapconcat (lambda (fragment) (plist-get fragment :text))
                         new-middle ""))
             (tracked (pichat-chat--live-suffix-marker-positions))
             (delta (- (length replacement) (- end start)))
             (retained-blocks (make-hash-table :test #'equal))
             (retained-activity-blocks (make-hash-table :test #'equal))
             new-fragment-state new-blocks blocks
             new-activity-blocks activity-blocks)
        (maphash
         (lambda (id block)
           (if (pichat-chat--live-block-overlaps-p block start end)
               (pichat-chat-tool-ui-release-block block)
             (puthash id block retained-blocks)))
         pichat-chat--live-tool-blocks)
        (maphash
         (lambda (key block)
           (if (pichat-chat--live-block-overlaps-p block start end)
               (pichat-chat-activity-ui-release-block block)
             (puthash key block retained-activity-blocks)))
         pichat-chat--live-activity-blocks)
        (dolist (fragment old-middle)
          (pichat-chat--release-live-projection-fragments (list fragment)))
        (pichat-chat--with-buffer-edit
          (delete-region start end)
          (goto-char start)
          (let ((beg (point)))
            (insert replacement)
            (pichat-chat--protect-region beg (point)))
          (set-marker pichat-chat--live-end (+ live-end delta))
          (pichat-chat--adjust-live-suffix-markers tracked end delta)
          (pichat-chat--style-live-input)
          (setq new-fragment-state
                (pichat-chat--make-live-fragment-state new-middle start)))
        (setq new-blocks
              (pichat-chat--index-canonical-tools
               (plist-get candidate :transcript)
               start (+ start (length replacement))
               (plist-get candidate :context) t)
              blocks (pichat-chat--merge-tool-block-tables
                      retained-blocks new-blocks)
              new-activity-blocks
              (pichat-chat--index-activity-groups
               start (+ start (length replacement)) t)
              activity-blocks
              (pichat-chat-activity-ui-merge-block-tables
               retained-activity-blocks new-activity-blocks))
        (list :fragments
              (append (cl-subseq old 0 prefix-count)
                      new-fragment-state
                      (cl-subseq old old-end-index))
              :blocks blocks :activity-blocks activity-blocks
              :incremental t)))))

(defun pichat-chat--refresh-final-live-presentation ()
  "Refresh optional presentation overlays for committed final live text."
  (condition-case err
      (pichat-markdown-presentation-refresh-region
       (marker-position pichat-chat--live-start)
       (marker-position pichat-chat--live-end))
    (error
     (pichat-markdown-presentation-remove-region
      (marker-position pichat-chat--live-start)
      (marker-position pichat-chat--live-end))
     (pichat-markdown-presentation--warn-once
      'live-refresh
      (format "PiChat live Markdown presentation failed: %s"
              (error-message-string err))))))

(defun pichat-chat--commit-live-projection-result (candidate result)
  "Commit CANDIDATE projection RESULT after all buffer-local edits succeed."
  (let ((live-blocks (plist-get result :blocks))
        (live-activity-blocks (plist-get result :activity-blocks)))
    (setq pichat-chat--live-projection-fragments
          (plist-get result :fragments)
          pichat-chat--live-tool-blocks live-blocks
          pichat-chat--tool-blocks
          (pichat-chat--merge-tool-block-tables
           pichat-chat--canonical-tool-blocks live-blocks)
          pichat-chat--live-activity-blocks live-activity-blocks
          pichat-chat--activity-blocks
          (pichat-chat-activity-ui-merge-block-tables
           pichat-chat--canonical-activity-blocks live-activity-blocks))
    (pichat-chat-activity-ui-refresh-live-views
     live-activity-blocks pichat-chat--activity-view-states
     pichat-chat--source-generation)
    (pichat-chat-activity-ui-prune-views
     pichat-chat--canonical-activity-blocks live-activity-blocks
     pichat-chat--activity-view-states pichat-chat--source-generation)
    (pichat-chat--set-compatibility-diagnostics
     (plist-get candidate :transcript))
    (setq pichat-chat--live-projection-fingerprint
          (plist-get candidate :fingerprint))))

(defun pichat-chat--project-live-tail ()
  "Project the current normalized live draft into its dedicated region.
Return non-nil when a changed candidate commits."
  (when-let ((candidate (pichat-chat--build-live-candidate)))
    (let ((fingerprint (plist-get candidate :fingerprint)))
      (unless (pichat-chat--live-fingerprints-equal-p
               fingerprint pichat-chat--live-projection-fingerprint)
        (pichat-chat--preserve-view
          (pichat-chat--with-live-projection-rollback candidate
            (let* ((modified (buffer-modified-p))
                   ;; Final Markdown fontification may change every prose run;
                   ;; without that derived layer, final tool updates remain
                   ;; safe for logical replacement.
                   (result
                    (or (and (or (not (plist-get candidate :final-p))
                                 (not pichat-chat-markdown-mode))
                             (pichat-chat--replace-live-fragments candidate))
                        (pichat-chat--replace-live-full candidate))))
              (pichat-chat--commit-live-projection-result candidate result)
              (set-buffer-modified-p modified)))
          ;; Inline overlays remain an optional post-commit layer until their
          ;; removal phase; projection rollback owns neither their caches nor
          ;; their failures.
          (when (plist-get candidate :final-p)
            (pichat-chat--refresh-final-live-presentation)))
        t))))

(defun pichat-chat--capture-tool-enrichment (raw source-generation)
  "Capture presentation metadata from tool event RAW for SOURCE-GENERATION.
Stale generations and events without a tool call id are ignored."
  (when (and (= source-generation pichat-chat--source-generation)
             (hash-table-p pichat-chat--tool-enrichments)
             (member (plist-get raw :type)
                     '("tool_execution_start" "tool_execution_update"
                       "tool_execution_end")))
    (let ((id (plist-get raw :toolCallId)))
      (when (stringp id)
        (let* ((old (gethash id pichat-chat--tool-enrichments))
               (incoming
                (pichat-tool-enrichment-build
                 id (plist-get raw :toolName) (plist-get raw :args)
                 (and pichat-chat-session
                      (pichat-session-path-context pichat-chat-session))))
               (record (pichat-tool-enrichment-merge old incoming)))
          ;; The pure enrichment merge intentionally rebuilds from accumulated
          ;; identity/arguments.  Preserve the already normalized terminal
          ;; shell observation before considering this possibly stale event.
          (when-let ((outcome (plist-get old :shell-outcome)))
            (setq record (plist-put record :shell-outcome outcome)))
          (setq record
                (pichat-shell-presentation-observe record raw)
                record (plist-put record :source-generation source-generation))
          (puthash id record pichat-chat--tool-enrichments))))))

(defun pichat-chat--capture-tool-auxiliary-details (raw)
  "Capture non-persisted tool details from execution event RAW."
  (when (and (equal (plist-get raw :type) "tool_execution_end")
             (hash-table-p pichat-chat--tool-auxiliary-details))
    (let* ((id (plist-get raw :toolCallId))
           (result (plist-get raw :result))
           (details (and (listp result) (plist-get result :details)))
           (full-output-path
            (and (listp result)
                 (or (plist-get result :fullOutputPath)
                     (and (listp details)
                          (plist-get details :fullOutputPath))))))
      (when (and (stringp id) (or details full-output-path))
        (puthash id (list :details (copy-tree details t)
                          :full-output-path
                          (and (stringp full-output-path) full-output-path))
                 pichat-chat--tool-auxiliary-details)))))

(defun pichat-chat--on-rpc-event (_session _event plist)
  "Reduce transcript-affecting generic RPC event PLIST into the live tail."
  (let* ((raw (pichat-chat--raw plist))
         (type (plist-get raw :type)))
    (when (and (not pichat-chat--source-rebinding-p)
               (member type '("message_start" "message_update" "message_end"
                              "tool_execution_start" "tool_execution_update"
                              "tool_execution_end" "compaction_end"
                              "agent_settled")))
      (unless (and (pichat-live-draft-p pichat-chat--live-draft)
                   (= (pichat-live-draft-generation pichat-chat--live-draft)
                      pichat-chat--source-generation))
        (setq pichat-chat--live-draft
              (pichat-live-draft-empty pichat-chat--source-generation)))
      (pichat-chat--capture-tool-enrichment raw pichat-chat--source-generation)
      (pichat-chat--capture-tool-auxiliary-details raw)
      (pichat-pi-live-draft-apply pichat-chat--live-draft raw)
      (cond
       ((and (string= type "message_start")
             (member (plist-get (plist-get raw :message) :role)
                     '("toolResult" "tool_result")))
        ;; Pi emits a tool-result start immediately before its complete result.
        ;; The reducer intentionally ignores it, so there is nothing to paint.
        nil)
       ((and (string= type "message_update")
             (not (pichat-live-draft-event-changed-p
                   pichat-chat--live-draft)))
        ;; Control, malformed, incomplete tool JSON, and unknown deltas can
        ;; leave the renderable draft unchanged.
        nil)
       ((string= type "message_update")
        (let ((assistant-type
               (plist-get (plist-get raw :assistantMessageEvent) :type)))
          (if (member assistant-type
                      '("text_end" "thinking_end" "toolcall_end"))
              (pichat-chat--flush-or-expedite-live-projection)
            (pichat-chat--schedule-live-projection
             (if (equal assistant-type "toolcall_delta")
                 pichat-chat-tool-call-update-delay
               pichat-chat-live-update-delay)))))
       ((string= type "tool_execution_update")
        (pichat-chat--schedule-live-projection
         pichat-chat-live-update-delay))
       ((or (member type '("tool_execution_start" "tool_execution_end"))
            (and (string= type "message_start")
                 (string= (plist-get (plist-get raw :message) :role)
                          "assistant"))
            (and (string= type "message_end")
                 (or (member (plist-get (plist-get raw :message) :role)
                             '("toolResult" "tool_result"))
                     (cl-some
                      (lambda (content)
                        (equal (plist-get content :type) "toolCall"))
                      (plist-get (plist-get raw :message) :content)))))
        (pichat-chat--flush-or-expedite-live-projection))
       (t
        (pichat-chat--flush-live-projection)))
      (when (and (string= type "message_end")
                 (string= (plist-get (plist-get raw :message) :role)
                          "custom")
                 (not (pichat-chat--active-operation-p)))
        ;; Extension commands (e.g. "/sandbox") resolve via this custom
        ;; message without ever emitting `agent_settled', which is the only
        ;; other place the live prompt bar gets redrawn after
        ;; `pichat-chat-send-input' clears it.  Restore it here too, or the
        ;; input area is left invisibly editable until the next real turn.
        (pichat-chat--preserve-view (pichat-chat--insert-prompt))
        (pichat-chat--request-sync nil)))))

(defun pichat-chat--active-operation-p ()
  "Return non-nil when canonical synchronization must be deferred."
  (memq (and pichat-chat-session
             (pichat-session-state pichat-chat-session))
        '(running compacting retrying)))

(defun pichat-chat--queue-sync (kind)
  "Coalesce pending synchronization KIND.  `full' dominates."
  (setq pichat-chat--sync-pending
        (if (or (eq kind 'full) (eq pichat-chat--sync-pending 'full))
            'full
          'incremental)))

(defun pichat-chat--sync-current-p (generation session source-generation
                                               session-id session-file)
  "Return non-nil when a synchronization callback is still current."
  (and (eq session pichat-chat-session)
       (equal generation pichat-chat--sync-in-flight)
       (= source-generation pichat-chat--source-generation)
       (equal session-id (pichat-session-id session))
       (equal session-file (pichat-session-session-file session))))

(defun pichat-chat--finish-sync (generation)
  "Finish synchronization GENERATION and start any coalesced request."
  (when (equal generation pichat-chat--sync-in-flight)
    (setq pichat-chat--sync-in-flight nil
          pichat-chat--sync-in-flight-full-p nil
          pichat-chat--sync-request-id nil)
    (when-let ((pending pichat-chat--sync-pending))
      (setq pichat-chat--sync-pending nil)
      (pichat-chat--request-sync (eq pending 'full)))))

(defun pichat-chat--apply-sync-response (response full base-cache)
  "Build and project RESPONSE as a FULL or incremental synchronization.
BASE-CACHE is the cache captured by the incremental request."
  (let* ((data (plist-get response :data))
         (cache
          (if full
              (pichat-pi-entry-cache-full
               (pichat-session-id pichat-chat-session)
               (pichat-session-session-file pichat-chat-session)
               (plist-get data :entries)
               (plist-get data :leafId))
            (unless (eq base-cache pichat-chat--entry-cache)
              (error "Canonical entry cache changed during synchronization"))
            (pichat-pi-entry-cache-merge
             base-cache
             (plist-get data :entries)
             (plist-get data :leafId))))
         (transcript (pichat-pi-build-canonical-transcript cache))
         (context (pichat-chat--canonical-render-context transcript))
         (fragment (pichat-render-canonical transcript context)))
    (pichat-chat--project-canonical cache transcript fragment context t)))

(defun pichat-chat--start-sync (full)
  "Start one FULL or incremental canonical synchronization."
  (let* ((session pichat-chat-session)
         (buffer (current-buffer))
         (base-cache pichat-chat--entry-cache)
         (full (or full (null base-cache)))
         (cursor (and (not full)
                      (pichat-entry-cache-last-seen-id base-cache)))
         (generation (cl-incf pichat-chat--sync-sequence))
         (source-generation pichat-chat--source-generation)
         (session-id (pichat-session-id session))
         (session-file (pichat-session-session-file session)))
    (setq pichat-chat--sync-in-flight generation
          pichat-chat--sync-in-flight-full-p full)
    (cl-labels
        ((current-p ()
           (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (pichat-chat--sync-current-p
                   generation session source-generation
                   session-id session-file))))
         (success (response _response-session)
           (when (current-p)
             (with-current-buffer buffer
               (condition-case err
                   (progn
                     (pichat-chat--apply-sync-response
                      response full base-cache)
                     (pichat-chat--set-status 'synchronization nil)
                     ;; A successful authoritative projection repairs any
                     ;; transcript event lost to malformed RPC framing.  Keep
                     ;; the retained diagnostic available in the explicit
                     ;; diagnostics view, but remove its recovered chat notice.
                     (pichat-chat--set-status 'rpc-parse nil))
                 (error
                  (pichat-chat--set-status
                   'synchronization
                   "[not synchronized with Pi session]")
                  (message "PiChat synchronization rejected session data: %s"
                           (error-message-string err))))
               (pichat-chat--finish-sync generation))))
         (failure (response _response-session)
           (when (current-p)
             (with-current-buffer buffer
               (if (and (not full)
                        (null (plist-get response :pichat-failure-kind)))
                   (progn
                     ;; Pi rejected the durable cursor.  Retry exactly once
                     ;; without `since'; the full request does not recurse.
                     (pichat-chat--queue-sync 'full)
                     (pichat-chat--finish-sync generation))
                 (pichat-chat--set-status
                  'synchronization
                  "[not synchronized with Pi session]")
                 (message "PiChat synchronization failed: %s"
                          (or (plist-get response :error) "unknown error"))
                 (pichat-chat--finish-sync generation))))))
      (let ((request-id
             (pichat-rpc-get-entries
              session (unless full cursor) #'success #'failure)))
        ;; Synchronous test transports may finish before returning an id.
        (when (equal generation pichat-chat--sync-in-flight)
          (setq pichat-chat--sync-request-id request-id))))))

(defun pichat-chat--request-sync (&optional full)
  "Request canonical synchronization; when FULL, ignore the cache cursor."
  (let ((kind (if full 'full 'incremental)))
    (cond
     ((pichat-chat--active-operation-p)
      (pichat-chat--queue-sync kind))
     (pichat-chat--sync-in-flight
      ;; A second full request for the same source is already covered by the
      ;; in-flight full snapshot.  Other combinations may represent later
      ;; mutations and remain coalesced for one follow-up request.
      (unless (and full pichat-chat--sync-in-flight-full-p)
        (pichat-chat--queue-sync kind)))
     (t
      (let ((effective-full
             (or full (eq pichat-chat--sync-pending 'full))))
        (setq pichat-chat--sync-pending nil)
        (pichat-chat--start-sync effective-full))))))

;;;###autoload
(defun pichat-chat-repaint ()
  "Fully synchronize and repaint from Pi's authoritative active branch."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (pichat-chat--request-sync t))

(defun pichat-chat--install-handlers (session buffer)
  "Install SESSION event handlers for BUFFER."
  (with-current-buffer buffer
    (unless pichat-chat--handlers
      (let ((handler (lambda (event-fn)
                       (lambda (session event plist)
                         (when (buffer-live-p buffer)
                           (with-current-buffer buffer
                             (when (eq session pichat-chat-session)
                               (funcall event-fn session event plist))))))))
        (setq pichat-chat--handlers
              `((rpc-event . ,(funcall handler #'pichat-chat--on-rpc-event))
                (session-rebinding . ,(funcall handler #'pichat-chat--on-session-rebinding))
                (agent-start . ,(funcall handler #'pichat-chat--on-agent-start))
                (turn-end . ,(funcall handler #'pichat-chat--on-turn-end))
                (agent-settled . ,(funcall handler #'pichat-chat--on-agent-settled))
                (compaction-start . ,(funcall handler #'pichat-chat--on-simple-event))
                (compaction-end . ,(funcall handler #'pichat-chat--on-simple-event))
                (retry-start . ,(funcall handler #'pichat-chat--on-simple-event))
                (retry-end . ,(funcall handler #'pichat-chat--on-simple-event))
                (queue-update . ,(funcall handler #'pichat-chat--on-simple-event))
                (session-state-changed . ,(funcall handler #'pichat-chat--on-state-changed))
                (extension-ui-request . ,(funcall handler #'pichat-chat--on-extension-ui-request))
                (error . ,(funcall handler #'pichat-chat--on-error))
                (session-ended . ,(funcall handler #'pichat-chat--on-session-ended))))
        (dolist (pair pichat-chat--handlers)
          (pichat-on (car pair) (cdr pair) session))))))

(defun pichat-chat--raw (plist)
  "Return raw event from PLIST."
  (plist-get plist :raw))

(defun pichat-chat--truncate-tool-output (text)
  "Return TEXT truncated for inline tool display when needed."
  (pichat-chat-tool-ui-truncate-output
   text pichat-chat-max-tool-output-chars
   pichat-chat-tool-truncation-notice-format))

(defun pichat-chat--truncate-tool-args (args)
  "Return compact display string for tool ARGS, or nil when absent."
  (pichat-chat-tool-ui-truncate-args args pichat-chat-max-tool-args-chars))

(defun pichat-chat--tool-text (raw status text &optional state)
  "Return rendered tool block for RAW event with STATUS, TEXT, and STATE."
  (pichat-chat-tool-ui-text
   raw status text (or state 'output)
   pichat-chat-max-tool-args-chars pichat-chat-max-tool-output-chars
   pichat-chat-tool-truncation-notice-format))

(defun pichat-chat--tool-completed-display-state ()
  "Return the default display state for a completed tool block."
  (pichat-chat-tool-ui-completed-display-state
   pichat-chat-collapse-tools-by-default pichat-chat-tool-default-display))

(defun pichat-chat--tool-ui-edit (thunk)
  "Call THUNK with chat buffer editing and view preservation enabled."
  (pichat-chat--preserve-view
    (pichat-chat--with-buffer-edit
      (funcall thunk))))

(defun pichat-chat--tool-ui-context ()
  "Return explicit context consumed by the tool presentation module."
  (list :max-args pichat-chat-max-tool-args-chars
        :max-output pichat-chat-max-tool-output-chars
        :truncation-notice pichat-chat-tool-truncation-notice-format
        :tracked-markers
        (list pichat-chat--canonical-end
              pichat-chat--live-start pichat-chat--live-end
              pichat-chat--status-start pichat-chat--status-end
              pichat-chat--widget-start pichat-chat--widget-end
              pichat-chat--prompt-start pichat-chat--input-start)
        :edit-function #'pichat-chat--tool-ui-edit
        :enrichments pichat-chat--tool-enrichments
        :generation pichat-chat--source-generation))

(defun pichat-chat--replace-tool-block-region (block text)
  "Replace BLOCK's buffer range with TEXT without corrupting adjacent markers."
  (pichat-chat-tool-ui-replace-region
   block text (plist-get (pichat-chat--tool-ui-context) :tracked-markers)
   #'pichat-chat--tool-ui-edit))

(defun pichat-chat--render-tool-block (block)
  "Re-render BLOCK according to its current display state."
  (pichat-chat-tool-ui-render-block block (pichat-chat--tool-ui-context)))

(defun pichat-chat--cycle-tool-state (state)
  "Return the display state after STATE."
  (pichat-chat-tool-ui-cycle-state state))

(defun pichat-chat--collapse-tool-block (block)
  "Set BLOCK to an explicit summary display."
  (pichat-chat-tool-ui-collapse-block
   block pichat-chat--tool-view-states (pichat-chat--tool-ui-context)))

(defun pichat-chat--activity-at-point ()
  "Return activity header block at point, if any."
  (pichat-chat-activity-ui-block-at pichat-chat--activity-blocks (point)))

;;;###autoload
(defun pichat-chat-toggle-activity-at-point (&optional event)
  "Toggle the activity group header at point without fetching source data."
  (interactive (list (and (listp last-command-event) last-command-event)))
  (when event (posn-set-point (event-end event)))
  (let ((block (pichat-chat--activity-at-point)))
    (unless block (user-error "No activity group header at point"))
    (let* ((group-key (plist-get block :key))
           (state-key (plist-get block :view-state-key))
           (present (gethash state-key pichat-chat--activity-view-states
                             'pichat-absent))
           (next (if (eq (plist-get block :display-state) 'expanded)
                     'collapsed 'expanded)))
      (pichat-chat-activity-ui-store-view
       block pichat-chat--activity-view-states next)
      (condition-case err
          (pichat-chat--reproject-display-options)
        (error
         (if (eq present 'pichat-absent)
             (remhash state-key pichat-chat--activity-view-states)
           (puthash state-key present pichat-chat--activity-view-states))
         (signal (car err) (cdr err))))
      (when-let ((new (gethash group-key pichat-chat--activity-blocks)))
        (goto-char (marker-position (plist-get new :start)))))))

;;;###autoload
(defun pichat-chat-next-activity ()
  "Move point to the next visible activity group header."
  (interactive)
  (if-let ((next (pichat-chat-activity-ui-next-position
                  pichat-chat--activity-blocks (point))))
      (goto-char next)
    (user-error "No next activity group")))

;;;###autoload
(defun pichat-chat-previous-activity ()
  "Move point to the previous visible activity group header."
  (interactive)
  (if-let ((previous (pichat-chat-activity-ui-previous-position
                      pichat-chat--activity-blocks (point))))
      (goto-char previous)
    (user-error "No previous activity group")))

(defun pichat-chat--tool-at-point ()
  "Return tool block plist at point, if any."
  (pichat-chat-tool-ui-block-at pichat-chat--tool-blocks (point)))

;;;###autoload
(defun pichat-chat-next-tool ()
  "Move point to next tool block."
  (interactive)
  (if-let ((next (pichat-chat-tool-ui-next-position
                  pichat-chat--tool-blocks (point))))
      (goto-char next)
    (user-error "No next tool block")))

;;;###autoload
(defun pichat-chat-previous-tool ()
  "Move point to previous tool block."
  (interactive)
  (if-let ((previous (pichat-chat-tool-ui-previous-position
                      pichat-chat--tool-blocks (point))))
      (goto-char previous)
    (user-error "No previous tool block")))

;;;###autoload
(defun pichat-chat-toggle-tool-at-point ()
  "Toggle the tool block at point between summary and argument display."
  (interactive)
  (let ((block (pichat-chat--tool-at-point)))
    (unless block (user-error "No tool block at point"))
    (pichat-chat-tool-ui-toggle-block
     block pichat-chat--tool-view-states (pichat-chat--tool-ui-context))
    (goto-char (marker-position (plist-get block :start)))))

(defun pichat-chat--tool-enrichment-at-point ()
  "Return current or source-derived enrichment for the tool at point."
  (when-let* ((block (pichat-chat--tool-at-point))
              (raw (plist-get block :raw))
              (id (plist-get raw :toolCallId)))
    (or (pichat-chat-tool-ui-enrichment
         pichat-chat--tool-enrichments pichat-chat--source-generation id)
        (pichat-tool-enrichment-build
         id (plist-get raw :toolName) (plist-get raw :args)
         (pichat-session-path-context pichat-chat-session)))))

(defun pichat-chat--set-point-from-tool-event (event)
  "Move point to the tool location clicked in mouse EVENT."
  (when event (posn-set-point (event-end event))))

;;;###autoload
(defun pichat-chat-visit-tool-location (&optional event)
  "Visit the local file location for the tool call at point."
  (interactive (list (and (listp last-command-event) last-command-event)))
  (pichat-chat--set-point-from-tool-event event)
  (let ((record (pichat-chat--tool-enrichment-at-point)))
    (unless record (user-error "No tool location at point"))
    (let ((path (plist-get record :host-path)))
      (unless path
        (user-error "Tool location unavailable%s"
                    (if-let ((reason (plist-get record :unavailable-reason)))
                        (format ": %s" reason) "")))
      (find-file path)
      (goto-char (point-min))
      (when-let ((line (plist-get record :line)))
        (forward-line (1- line)))
      (when-let ((column (plist-get record :column)))
        (move-to-column (1- column))))))

(defun pichat-chat--copy-tool-location (path-only-p)
  "Copy current tool location, or only its path when PATH-ONLY-P."
  (let ((record (pichat-chat--tool-enrichment-at-point)))
    (unless record (user-error "No tool location at point"))
    (let ((text (if path-only-p
                    (plist-get record :host-path)
                  (pichat-chat-tool-ui-location-string record))))
      (unless text
        (user-error "Tool location unavailable%s"
                    (if-let ((reason (plist-get record :unavailable-reason)))
                        (format ": %s" reason) "")))
      (kill-new text)
      (message "Copied tool %s: %s"
               (if path-only-p "path" "location") text))))

;;;###autoload
(defun pichat-chat-copy-tool-path ()
  "Copy the local path for the tool call at point."
  (interactive)
  (pichat-chat--copy-tool-location t))

;;;###autoload
(defun pichat-chat-copy-tool-location ()
  "Copy the local path, line, and column for the tool call at point."
  (interactive)
  (pichat-chat--copy-tool-location nil))

(defun pichat-chat--shell-command-at-point ()
  "Return execute command at point or signal a user-facing error."
  (let ((record (pichat-chat--tool-enrichment-at-point)))
    (unless (pichat-shell-presentation-execute-p record)
      (user-error "No execute tool at point"))
    (or (pichat-shell-presentation-command record)
        (user-error "Execute command unavailable"))))

;;;###autoload
(defun pichat-chat-copy-shell-command ()
  "Copy the exact execute-tool command at point."
  (interactive)
  (let ((command (pichat-chat--shell-command-at-point)))
    (kill-new command)
    (message "Copied execute command")))

;;;###autoload
(defun pichat-chat-copy-shell-output ()
  "Copy the complete retained execute-tool output at point."
  (interactive)
  (let ((block (pichat-chat--tool-at-point)))
    (unless block (user-error "No tool block at point"))
    (pichat-chat--shell-command-at-point)
    (kill-new (or (plist-get block :full-text) ""))
    (message "Copied execute output")))

;;;###autoload
(defun pichat-chat-rerun-shell-in-compilation ()
  "Rerun the execute command at point through host `compilation-start'.
This never invokes Pi RPC or reproduces a Pi container/SSH transport."
  (interactive)
  (unless pichat-shell-presentation-enable-compilation-rerun
    (user-error
     "Set pichat-shell-presentation-enable-compilation-rerun to enable host reruns"))
  (let ((command (pichat-chat--shell-command-at-point)))
    (require 'compile)
    (compilation-start
     command 'compilation-mode
     (lambda (_mode) "*PiChat Shell Rerun*"))))

;;;###autoload
(defun pichat-chat-show-tool-details ()
  "Show full details for the tool block at point."
  (interactive)
  (let* ((block (pichat-chat--tool-at-point))
         (raw (and block (plist-get block :raw)))
         (id (and raw (plist-get raw :toolCallId)))
         (auxiliary (and id (hash-table-p pichat-chat--tool-auxiliary-details)
                         (gethash id pichat-chat--tool-auxiliary-details)))
         (enrichment
          (and id
               (or (pichat-chat-tool-ui-enrichment
                    pichat-chat--tool-enrichments
                    pichat-chat--source-generation id)
                   (pichat-tool-enrichment-build
                    id (plist-get raw :toolName) (plist-get raw :args)
                    (pichat-session-path-context pichat-chat-session)))))
         (buffer (get-buffer-create "*PiChat Tool Details*")))
    (unless block (user-error "No tool block at point"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pichat-chat-tool-ui-details-text
                 block auxiliary enrichment)))
      (pichat-view-mode))
    (pichat-view-display buffer nil 'bury)))

(defun pichat-chat--compatibility-diagnostics-text (transcript)
  "Return bounded status text for TRANSCRIPT compatibility diagnostics."
  (let* ((diagnostics (and (pichat-transcript-p transcript)
                           (pichat-transcript-diagnostics transcript)))
         (shown (seq-take diagnostics 20))
         (lines
          (mapcar
           (lambda (diagnostic)
             (truncate-string-to-width
              (format "[Pi compatibility: %s at %s (%s)]"
                      (or (plist-get diagnostic :category) 'unknown)
                      (or (plist-get diagnostic :entry-id) "unknown")
                      (or (plist-get diagnostic :type) "unknown"))
              240 nil nil "…"))
           shown)))
    (when (> (length diagnostics) (length shown))
      (setq lines
            (append lines
                    (list (format "[%d additional diagnostics omitted]"
                                  (- (length diagnostics)
                                     (length shown)))))))
    (when lines (string-join lines "\n"))))

(defun pichat-chat--set-compatibility-diagnostics (transcript)
  "Update compatibility diagnostics from TRANSCRIPT in the current transaction."
  (when (pichat-chat--set-status-state
         'compatibility
         (pichat-chat--compatibility-diagnostics-text transcript))
    (pichat-chat--render-status-region)))

(defun pichat-chat--render-status-region ()
  "Render bounded lifecycle and diagnostic lines in the current transaction."
  (when (and (markerp pichat-chat--status-start)
             (marker-position pichat-chat--status-start)
             (markerp pichat-chat--status-end)
             (marker-position pichat-chat--status-end))
    (let* ((start (marker-position pichat-chat--status-start))
           (end (marker-position pichat-chat--status-end))
           (prompt-position (marker-position pichat-chat--prompt-start))
           (input-position (marker-position pichat-chat--input-start))
           (text (if pichat-chat--status-lines
                     (concat (mapconcat #'cdr pichat-chat--status-lines "\n")
                             "\n")
                   ""))
           (delta (- (length text) (- end start)))
           (modified (buffer-modified-p)))
      (pichat-chat--with-buffer-edit
        (delete-region start end)
        (goto-char start)
        (let ((beg (point)))
          (insert (propertize text 'pichat-status t
                              'font-lock-face 'shadow))
          (pichat-chat--protect-region beg (point)))
        (set-marker pichat-chat--status-start start)
        (set-marker pichat-chat--status-end (+ start (length text)))
        (when (and prompt-position (>= prompt-position end))
          (set-marker pichat-chat--prompt-start
                      (+ prompt-position delta)))
        (when (and input-position (>= input-position end))
          (set-marker pichat-chat--input-start
                      (+ input-position delta)))
        (pichat-chat--style-live-input))
      (pichat-chat--adjust-undo-for-prefix-delta end delta)
      (set-buffer-modified-p modified))))

(defun pichat-chat--normalize-status-text (text)
  "Return bounded display state for status TEXT, or nil."
  (and (stringp text) (not (string-empty-p text))
       (truncate-string-to-width
        (substring-no-properties text) 4000 nil nil "…")))

(defun pichat-chat--set-status-state (key text)
  "Set status KEY to normalized TEXT without projecting it.
Return non-nil only when the in-memory status state changes."
  (let* ((text (pichat-chat--normalize-status-text text))
         (old (cdr (assq key pichat-chat--status-lines))))
    (unless (equal old text)
      (setq pichat-chat--status-lines
            (assq-delete-all key pichat-chat--status-lines))
      (when text
        (setq pichat-chat--status-lines
              (append pichat-chat--status-lines (list (cons key text)))))
      t)))

(defun pichat-chat--set-status (key text)
  "Transactionally set status KEY to TEXT, or remove it when TEXT is nil.
Return non-nil only when the projected status value changes."
  (let ((text (pichat-chat--normalize-status-text text)))
    (unless (equal (cdr (assq key pichat-chat--status-lines)) text)
      (pichat-chat--preserve-view
        (pichat-chat--with-projection-rollback
          (pichat-chat--set-status-state key text)
          (pichat-chat--render-status-region)))
      t)))

(defun pichat-chat--on-simple-event (session event plist)
  "Render simple EVENT from PLIST when appropriate."
  (let ((raw (pichat-chat--raw plist)))
    (when (eq event 'queue-update)
      (setq pichat-chat--queue-counts
            (cons (length (plist-get raw :steering))
                  (length (plist-get raw :followUp)))))
    (force-mode-line-update)
    (pcase event
      ('compaction-start
       (pichat-chat--set-status 'compaction
                                (pichat-render-event-line raw)))
      ('compaction-end
       (cond
        ((eq t (plist-get raw :aborted))
         (pichat-chat--set-status 'compaction "[compaction aborted]"))
        ((plist-get raw :errorMessage)
         (pichat-chat--set-status
          'compaction
          (format "[compaction failed: %s]"
                  (pichat-chat--bounded-notice
                   (plist-get raw :errorMessage)))))
        (t
         (pichat-chat--set-status 'compaction nil)
         (pichat-chat--refresh-stats session 'compaction)
         (pichat-chat--request-sync nil))))
      ('retry-start
       (pichat-chat--set-status 'retry (pichat-render-event-line raw)))
      ('retry-end
       (pichat-chat--set-status 'retry nil))
      ('queue-update
       (pichat-chat--set-status
        'queue
        (unless (and (zerop (car pichat-chat--queue-counts))
                     (zerop (cdr pichat-chat--queue-counts)))
          (format "[queue: %d steering, %d follow-up]"
                  (car pichat-chat--queue-counts)
                  (cdr pichat-chat--queue-counts)))))
      ((or 'agent-start 'agent-settled)
       (when pichat-chat-show-lifecycle-events
         (pichat-chat--set-status 'agent
                                  (pichat-render-event-line raw)))))))

(defun pichat-chat--on-agent-start (session event plist)
  "Start a new stats-coverage window and render agent EVENT from PLIST."
  (setq pichat-chat--stats-run-covered-p nil)
  (pichat-chat--on-simple-event session event plist))

(defun pichat-chat--on-turn-end (session _event _plist)
  "Refresh context usage after a completed turn for SESSION."
  (pichat-chat--refresh-stats session 'turn))

(defun pichat-chat--on-agent-settled (session event plist)
  "Finalize the live preview, prompt, stats, and canonical entries."
  (pichat-chat--on-simple-event session event plist)
  (pichat-chat--preserve-view
    (pichat-chat--insert-prompt))
  (pichat-chat--refresh-stats session 'settled)
  (pichat-chat--request-sync nil))

(defun pichat-chat--on-state-changed (session _event _plist)
  "Update display and source identity after state changes."
  (setq pichat-chat--thinking-control-error nil)
  (let ((rebound pichat-chat--source-rebinding-p)
        (source-generation pichat-chat--source-generation))
    (pichat-chat--refresh-source-identity session)
    (when rebound
      (setq pichat-chat--source-rebinding-p nil)
      (pichat-chat--set-status 'source nil)
      (pichat-chat--request-sync t))
    (when (or rebound
              (/= source-generation pichat-chat--source-generation))
      (pichat-chat--refresh-slash-commands session)))
  (pichat-chat--rename-buffer-maybe session)
  (pichat-chat--refresh-header session)
  (pichat-chat--refresh-stats session 'state)
  (force-mode-line-update))

(defun pichat-chat--on-error (_session _event plist)
  "Render only a bounded, redacted summary for diagnostic PLIST."
  (let* ((diagnostic (plist-get plist :diagnostic))
         (summary (or (plist-get diagnostic :summary)
                      (pichat-chat-diagnostics-safe-summary-text
                       (plist-get plist :message)))))
    (pichat-chat--set-status
     (if (eq 'rpc-parse (plist-get diagnostic :origin))
         'rpc-parse
       'error)
     (format "[diagnostic] %s"
             (if (string-empty-p (or summary ""))
                 "unknown PiChat error"
               summary)))))

(defun pichat-chat--update-pending-ui-count ()
  "Synchronize and publish the current chat's pending user-input count."
  (let ((old pichat-chat--pending-ui-count)
        (count (if (hash-table-p pichat-chat--pending-ui-requests)
                   (hash-table-count pichat-chat--pending-ui-requests)
                 0)))
    (setq pichat-chat--pending-ui-count count)
    (force-mode-line-update)
    (when (and pichat-chat-session (/= old count))
      (pichat-emit pichat-chat-session 'user-input-pending-changed
                   :count count))))

(defun pichat-chat--cancel-scheduled-ui-request ()
  "Cancel any pending activation callback owned by the current chat."
  (when (timerp pichat-chat--scheduled-ui-timer)
    (cancel-timer pichat-chat--scheduled-ui-timer))
  (cl-incf pichat-chat--ui-schedule-generation)
  (setq pichat-chat--scheduled-ui-request nil
        pichat-chat--scheduled-ui-timer nil))

(defun pichat-chat--cancel-pending-ui-requests ()
  "Cancel every dialog request owned by the current chat buffer."
  (pichat-chat--cancel-scheduled-ui-request)
  (when (hash-table-p pichat-chat--pending-ui-requests)
    (let (ids)
      (maphash (lambda (id _raw) (push id ids)) pichat-chat--pending-ui-requests)
      (dolist (id ids)
        (when (and pichat-chat-session
                   (pichat-session-alive-p pichat-chat-session))
          (ignore-errors
            (pichat-rpc-extension-ui-cancel pichat-chat-session id)))
        (remhash id pichat-chat--pending-ui-requests)))
    (setq pichat-chat--pending-ui-queue nil
          pichat-chat--active-ui-request nil)
    (pichat-chat--update-pending-ui-count)))

(defun pichat-chat--on-session-ended (_session _event _plist)
  "Cancel pending UI/stats work and display a session-ended status."
  (pichat-chat--cancel-stats-request)
  (pichat-chat--cancel-pending-ui-requests)
  (pichat-chat--set-status 'session "[session ended]"))

(defun pichat-chat--render-extension-widgets ()
  "Render extension widgets in a dedicated region before the prompt."
  (pichat-chat--preserve-view
    (pichat-chat--with-projection-rollback
      (pichat-chat--with-buffer-edit
        (let* ((old-start (marker-position pichat-chat--widget-start))
               (old-end (marker-position pichat-chat--widget-end))
               (prompt (marker-position pichat-chat--prompt-start))
               (input (marker-position pichat-chat--input-start)))
          (when (and old-start old-end (< old-start old-end))
            (delete-region old-start old-end)
            (let ((removed (- old-end old-start)))
              (when (and prompt (>= prompt old-end))
                (setq prompt (- prompt removed)))
              (when (and input (>= input old-end))
                (setq input (- input removed)))))
          (let ((position (or prompt (point-max))))
            (goto-char position)
            (set-marker pichat-chat--widget-start position)
            (maphash
             (lambda (key widget)
               (insert (format "[widget:%s %s]\n" key
                               (or (plist-get widget :placement)
                                   "aboveEditor")))
               (seq-doseq (line (plist-get widget :lines))
                 (insert (ansi-color-filter-apply (format "%s" line)) "\n")))
             pichat-chat--extension-widgets)
            (let ((new-end (point))
                  (inserted (- (point) position)))
              (set-marker pichat-chat--widget-end new-end)
              (set-marker pichat-chat--prompt-start (+ position inserted))
              (when input
                (set-marker pichat-chat--input-start (+ input inserted)))
              (pichat-chat--protect-region position new-end)))))))
  (force-mode-line-update))

(defun pichat-chat--complete-ui-request (session id method value)
  "Respond to dialog ID for SESSION using METHOD-specific VALUE."
  (when (pichat-session-alive-p session)
    (if (string= method "confirm")
        (pichat-rpc-extension-ui-confirm session id value)
      (pichat-rpc-extension-ui-value session id value))))

(defun pichat-chat--read-extension-editor (title prefill)
  "Read multiline extension editor content using TITLE and PREFILL."
  (let ((map (copy-keymap minibuffer-local-map)))
    (define-key map (kbd "C-j") #'newline)
    (read-from-minibuffer (concat title ": ") prefill map)))

(defun pichat-chat--ui-request-eligible-p (session id)
  "Return non-nil when SESSION request ID may interact in this chat now."
  (and (eq session pichat-chat-session)
       (pichat-session-alive-p session)
       (hash-table-p pichat-chat--pending-ui-requests)
       (gethash id pichat-chat--pending-ui-requests)
       (null pichat-chat--active-ui-request)
       (not (active-minibuffer-window))
       (not (window-minibuffer-p (selected-window)))
       (eq (window-buffer (selected-window)) (current-buffer))
       ;; Batch tests have no display focus.  Interactive frames must be
       ;; focused so a timer cannot open an unseen minibuffer.
       (or noninteractive (frame-focus-state (selected-frame)))))

(defun pichat-chat--remove-queued-ui-request (id)
  "Remove the first queued request identified by ID."
  (let ((tail pichat-chat--pending-ui-queue)
        previous)
    (while (and tail
                (not (equal id (plist-get (car tail) :id))))
      (setq previous tail
            tail (cdr tail)))
    (when tail
      (if previous
          (setcdr previous (cdr tail))
        (setq pichat-chat--pending-ui-queue (cdr tail))))))

(defun pichat-chat--interact-with-ui-request (session raw)
  "Interactively answer pending RAW for SESSION."
  (let ((id (plist-get raw :id))
        (method (plist-get raw :method)))
    (if (pichat-bridge-transport-handle-p raw)
        (unless (pichat-bridge-transport-handle session raw)
          (error "Unsupported PiChat bridge request"))
      (pcase method
        ("confirm"
         (pichat-chat--complete-ui-request
          session id method
          (yes-or-no-p (format "%s: %s "
                               (or (plist-get raw :title) "Pi asks")
                               (or (plist-get raw :message) "Confirm?")))))
        ("input"
         (pichat-chat--complete-ui-request
          session id method
          (read-string (concat (or (plist-get raw :title) "Pi input") ": ")
                       nil nil (or (plist-get raw :placeholder) ""))))
        ("select"
         (pichat-chat--complete-ui-request
          session id method
          (completing-read
           (concat (or (plist-get raw :title) "Pi select") ": ")
           (plist-get raw :options) nil t)))
        ("editor"
         (pichat-chat--complete-ui-request
          session id method
          (pichat-chat--read-extension-editor
           (or (plist-get raw :title) "Pi editor")
           (or (plist-get raw :prefill) ""))))))))

(defun pichat-chat--run-extension-ui-request
    (buffer session id generation)
  "Activate SESSION request ID in BUFFER for scheduling GENERATION."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (= generation pichat-chat--ui-schedule-generation)
                 (equal id pichat-chat--scheduled-ui-request))
        (setq pichat-chat--scheduled-ui-request nil
              pichat-chat--scheduled-ui-timer nil)
        (when (pichat-chat--ui-request-eligible-p session id)
          (let ((raw (gethash id pichat-chat--pending-ui-requests)))
            (setq pichat-chat--active-ui-request id)
            (pichat-chat--remove-queued-ui-request id)
            (unwind-protect
                (condition-case _err
                    (pichat-chat--interact-with-ui-request session raw)
                  ((quit error)
                   (when (pichat-session-alive-p session)
                     (pichat-rpc-extension-ui-cancel session id))))
              (remhash id pichat-chat--pending-ui-requests)
              (when (equal id pichat-chat--active-ui-request)
                (setq pichat-chat--active-ui-request nil))
              (pichat-chat--update-pending-ui-count)
              (pichat-chat--maybe-start-next-ui-request session))))))))

(defun pichat-chat--maybe-start-next-ui-request (&optional session)
  "Schedule the next queued dialog when its exact chat is selected."
  (let* ((session (or session pichat-chat-session))
         (raw (car pichat-chat--pending-ui-queue))
         (id (and raw (plist-get raw :id))))
    (when (and session id
               (null pichat-chat--scheduled-ui-request)
               (pichat-chat--ui-request-eligible-p session id))
      (let ((generation (cl-incf pichat-chat--ui-schedule-generation)))
        (setq pichat-chat--scheduled-ui-request id
              pichat-chat--scheduled-ui-timer
              (run-at-time 0 nil #'pichat-chat--run-extension-ui-request
                           (current-buffer) session id generation))))))

(defun pichat-chat--queue-extension-ui-request (session raw)
  "Queue dialog RAW for focus-gated serialized interaction with SESSION."
  (let ((id (plist-get raw :id)))
    (unless (gethash id pichat-chat--pending-ui-requests)
      (puthash id raw pichat-chat--pending-ui-requests)
      (setq pichat-chat--pending-ui-queue
            (append pichat-chat--pending-ui-queue (list raw)))
      (pichat-chat--update-pending-ui-count))
    (pichat-chat--maybe-start-next-ui-request session)))

(defun pichat-chat--extension-status-text ()
  "Return sorted persistent extension status text."
  (let (lines)
    (maphash
     (lambda (key text)
       (push (format "[status:%s] %s" key text) lines))
     pichat-chat--extension-statuses)
    (when lines
      (concat (string-join (sort lines #'string<) "\n") "\n\n"))))

(defun pichat-chat--insert-extension-statuses ()
  "Insert persistent extension statuses at point and set their markers."
  (let ((start (point))
        (text (pichat-chat--extension-status-text)))
    (set-marker pichat-chat--extension-status-start start)
    (when text
      (let ((beg (point)))
        (insert (propertize text
                            'pichat-status t
                            'pichat-extension-status t
                            'font-lock-face 'shadow))
        (pichat-chat--protect-region beg (point))))
    (set-marker pichat-chat--extension-status-end (point))))

(defun pichat-chat--project-extension-statuses ()
  "Project extension statuses in their persistent post-header region."
  (pichat-chat--preserve-view
    (pichat-chat--with-projection-rollback
      ;; Remove state left by versions that routed extension statuses through the
      ;; moving lifecycle-status region.
      (setq pichat-chat--status-lines
            (assq-delete-all 'extension-status pichat-chat--status-lines))
      (when (and (markerp pichat-chat--extension-status-start)
                 (marker-position pichat-chat--extension-status-start)
                 (markerp pichat-chat--extension-status-end)
                 (marker-position pichat-chat--extension-status-end))
        (let* ((start (marker-position pichat-chat--extension-status-start))
               (end (marker-position pichat-chat--extension-status-end))
               (tracked
                (mapcar
                 (lambda (marker)
                   (cons marker (marker-position marker)))
                 (list pichat-chat--canonical-start
                       pichat-chat--canonical-end
                       pichat-chat--live-start pichat-chat--live-end
                       pichat-chat--status-start pichat-chat--status-end
                       pichat-chat--widget-start pichat-chat--widget-end
                       pichat-chat--prompt-start pichat-chat--input-start)))
               (modified (buffer-modified-p)))
          (pichat-chat--with-buffer-edit
            (delete-region start end)
            (goto-char start)
            (pichat-chat--insert-extension-statuses)
            (let ((delta (- (marker-position pichat-chat--extension-status-end)
                            end)))
              (dolist (entry tracked)
                (when (and (cdr entry) (>= (cdr entry) end))
                  (set-marker (car entry) (+ (cdr entry) delta)))))
            (pichat-chat--style-live-input))
          (pichat-chat--render-status-region)
          (set-buffer-modified-p modified))))))

(defun pichat-chat--cancel-extension-status-projection ()
  "Cancel pending coalesced extension-status work."
  (when (timerp pichat-chat--extension-status-timer)
    (cancel-timer pichat-chat--extension-status-timer))
  (setq pichat-chat--extension-status-timer nil
        pichat-chat--extension-status-dirty-p nil))

(defun pichat-chat--run-extension-status-projection
    (buffer source-generation)
  "Project BUFFER extension status if SOURCE-GENERATION remains current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((dirty pichat-chat--extension-status-dirty-p))
        (setq pichat-chat--extension-status-timer nil
              pichat-chat--extension-status-dirty-p nil)
        (when (and dirty
                   (= source-generation pichat-chat--source-generation))
          (pichat-chat--project-extension-statuses))))))

(defun pichat-chat--start-extension-status-cooldown ()
  "Start the cooldown that coalesces subsequent extension status updates."
  (unless pichat-chat--extension-status-timer
    (setq pichat-chat--extension-status-timer
          (run-with-idle-timer
           pichat-chat-extension-status-update-delay nil
           #'pichat-chat--run-extension-status-projection
           (current-buffer) pichat-chat--source-generation))))

(defun pichat-chat--bounded-notice (text)
  "Return bounded single-line extension notice TEXT."
  (truncate-string-to-width
   (replace-regexp-in-string "[[:space:]]+" " "
                             (if (stringp text) text ""))
   500 nil nil "…"))

(defun pichat-chat--on-extension-ui-request (session _event plist)
  "Handle extension UI request in PLIST for SESSION."
  (let* ((raw (pichat-chat--raw plist))
         (method (plist-get raw :method)))
    (cond
     ((and (member method '("confirm" "input" "select" "editor"))
           (pichat-bridge-transport-handle-p raw))
      (if (pichat-bridge-transport-user-input-required-p session raw)
          (pichat-chat--queue-extension-ui-request session raw)
        (pichat-bridge-transport-handle session raw)))
     ((member method '("confirm" "input" "select" "editor"))
      (pichat-chat--queue-extension-ui-request session raw))
     ((string= method "notify")
      (pichat-chat--append-extension-notification
       (or (plist-get raw :notifyType) "info")
       (plist-get raw :message)))
     ((string= method "setStatus")
      (let* ((key (let ((value (plist-get raw :statusKey)))
                    (if (stringp value) value "unknown")))
             (text (plist-get raw :statusText))
             (clean-text (and (stringp text) (ansi-color-filter-apply text)))
             (value (and clean-text (not (string-empty-p clean-text))
                         (pichat-chat--bounded-notice clean-text)))
             (old (gethash key pichat-chat--extension-statuses)))
        (unless (equal old value)
          (if value
              (puthash key value pichat-chat--extension-statuses)
            (remhash key pichat-chat--extension-statuses))
          (cond
           ((null value)
            ;; Removal should not leave a stale status visible.
            (pichat-chat--cancel-extension-status-projection)
            (pichat-chat--project-extension-statuses))
           (pichat-chat--extension-status-timer
            (setq pichat-chat--extension-status-dirty-p t))
           (t
            (pichat-chat--project-extension-statuses)
            (pichat-chat--start-extension-status-cooldown)))
          (force-mode-line-update))))
     ((string= method "setWidget")
      (let ((key (let ((value (plist-get raw :widgetKey)))
                   (if (stringp value) value "unknown")))
            (lines (plist-get raw :widgetLines)))
        (if lines
            (puthash key (list :lines lines
                               :placement (plist-get raw :widgetPlacement))
                     pichat-chat--extension-widgets)
          (remhash key pichat-chat--extension-widgets))
        (pichat-chat--render-extension-widgets)))
     ((string= method "setTitle")
      (setq pichat-chat--extension-title (plist-get raw :title))
      (force-mode-line-update))
     ((string= method "set_editor_text")
      (pichat-chat--set-input-text (or (plist-get raw :text) "")))
     (t
      (pichat-chat--set-status
       'extension-ui
       (format "[ui:%s]" (or method "unknown")))))))

(defun pichat-chat--user-turn-position (direction)
  "Return another user-turn position in DIRECTION, or nil."
  (let ((start (and (markerp pichat-chat--canonical-start)
                    (marker-position pichat-chat--canonical-start)))
        (end (and (markerp pichat-chat--live-end)
                  (marker-position pichat-chat--live-end))))
    (when (and start end)
      (pichat-chat-navigation-turn-position
       start end (point) direction))))

;;;###autoload
(defun pichat-chat-next-user-turn ()
  "Move point to the next logical user message."
  (interactive)
  (if-let ((position (pichat-chat--user-turn-position 1)))
      (goto-char position)
    (user-error "No next user turn")))

;;;###autoload
(defun pichat-chat-previous-user-turn ()
  "Move point to the previous logical user message."
  (interactive)
  (if-let ((position (pichat-chat--user-turn-position -1)))
      (goto-char position)
    (user-error "No previous user turn")))

;;;###autoload
(defun pichat-chat-jump-to-active-item ()
  "Jump to the highest-priority active PiChat item.
Priority is the latest running tool, a pending extension request, the live tail,
and finally the prompt while Pi is running."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (let* ((target
          (pichat-chat-navigation-active-target
           pichat-chat--tool-blocks
           pichat-chat--pending-ui-count
           (and (markerp pichat-chat--prompt-start)
                (marker-position pichat-chat--prompt-start))
           (and (markerp pichat-chat--live-start)
                (marker-position pichat-chat--live-start))
           (and (markerp pichat-chat--live-end)
                (marker-position pichat-chat--live-end))
           (and (markerp pichat-chat--prompt-start)
                (marker-position pichat-chat--prompt-start))
           (memq (pichat-session-state pichat-chat-session)
                 '(running compacting retrying)))))
    (unless target (user-error "No active PiChat item"))
    (goto-char (plist-get target :position))
    (message "PiChat active item: %s" (plist-get target :kind))))

(defun pichat-chat--source-token ()
  "Return the current chat source identity."
  (list pichat-chat--source-generation
        pichat-chat--source-session-id
        pichat-chat--source-session-file))

(defun pichat-chat--compose-source-token ()
  "Return the current source identity captured by compose editors."
  (pichat-chat--source-token))

(defun pichat-chat--compose-source-valid-p (token)
  "Return non-nil when compose source TOKEN is still current."
  (equal token (pichat-chat--source-token)))

(defun pichat-chat--replace-from-compose (text point-offset)
  "Replace the current prompt with TEXT and return its POINT-OFFSET position."
  (unless (derived-mode-p 'pichat-chat-mode)
    (user-error "Compose target is not a PiChat buffer"))
  (pichat-chat--set-input-text text)
  (goto-char (+ (marker-position pichat-chat--input-start)
                (min (length text) (max 0 point-offset))))
  (point))

;;;###autoload
(defun pichat-chat-open-compose-buffer ()
  "Open an expanded editor for the current prompt, or reuse its live editor."
  (interactive)
  (unless pichat-chat-session (user-error "No PiChat session"))
  (let ((original-point (point)))
    (pichat-chat--insert-prompt)
    (let* ((input-start (marker-position pichat-chat--input-start))
           (raw (buffer-substring-no-properties input-start (point-max)))
           (raw-point
            (if (<= input-start original-point (point-max))
                (- original-point input-start)
              (length raw)))
           (text-and-point
            (pichat-chat-navigation--trimmed-text-and-point raw raw-point)))
      (pop-to-buffer
       (pichat-chat-navigation-open-compose
        (current-buffer) #'pichat-chat--replace-from-compose
        (car text-and-point) (cdr text-and-point)
        (pichat-chat--compose-source-token)
        #'pichat-chat--compose-source-valid-p)))))

(defun pichat-chat--response-view-refresh (response)
  "Return a refreshed canonical RESPONSE or reject stale source identity."
  (let ((token (pichat-chat--source-token)))
    (unless (pichat-chat-navigation-response-current-p
             response pichat-chat--canonical-transcript token)
      (user-error "PiChat response source changed; snapshot preserved"))
    (pichat-chat-navigation-select-response
     pichat-chat--canonical-transcript
     (pichat-chat-navigation-response-node-key response)
     token)))

(defun pichat-chat--response-view-origin-position (response)
  "Return RESPONSE's current canonical display position or reject it."
  (let ((token (pichat-chat--source-token)))
    (unless (pichat-chat-navigation-response-current-p
             response pichat-chat--canonical-transcript token)
      (user-error "PiChat response source changed; snapshot preserved"))
    (let* ((start (and (markerp pichat-chat--canonical-start)
                       (marker-position pichat-chat--canonical-start)))
           (end (and (markerp pichat-chat--canonical-end)
                     (marker-position pichat-chat--canonical-end)))
           (position
            (and start end
                 (text-property-any
                  start end 'pichat-node-key
                  (pichat-chat-navigation-response-node-key response)))))
      (or position
          (user-error
           "PiChat response is no longer projected; snapshot preserved")))))

;;;###autoload
(defun pichat-chat-view-response ()
  "Render the settled canonical assistant response at point, or the latest one."
  (interactive)
  (unless (pichat-transcript-p pichat-chat--canonical-transcript)
    (user-error "No synchronized PiChat transcript to view"))
  (let* ((origin (pichat-view-capture-origin))
         (response
          (pichat-chat-navigation-select-response
           pichat-chat--canonical-transcript
           (get-text-property (point) 'pichat-node-key)
           (pichat-chat--source-token))))
    (unless response (user-error "No settled assistant response to view"))
    (pichat-response-view-open
     response origin #'pichat-chat--response-view-refresh
     #'pichat-chat--response-view-origin-position (buffer-name))))

;;;###autoload
(defun pichat-chat-export-transcript-to-markdown ()
  "Export authoritative canonical transcript data to a Markdown buffer."
  (interactive)
  (unless (pichat-transcript-p pichat-chat--canonical-transcript)
    (user-error "No synchronized PiChat transcript to export"))
  (pop-to-buffer
   (pichat-chat-navigation-export-buffer
    pichat-chat--canonical-transcript (buffer-name))))

(provide 'pichat-chat)
;;; pichat-chat.el ends here
