;;; pichat-display.el --- Shared PiChat display options and faces -*- lexical-binding: t; -*-

;;; Commentary:

;; Presentation definitions shared by chat and read-only transcript views.
;; Public names and the customization group are retained for compatibility.
;; This module owns no buffer state and does not load chat orchestration.

;;; Code:

(defvar pichat-chat-collapse-tools-by-default t
  "Obsolete, ignored legacy setting; use `pichat-chat-tool-default-display'.")
(make-obsolete-variable 'pichat-chat-collapse-tools-by-default
                        'pichat-chat-tool-default-display "2026-11-14")

(defcustom pichat-chat-tool-default-display 'summary
  "Default display state for completed tool blocks.
`summary' shows only the tool header, `args' also shows arguments, and
`output' shows arguments plus truncated inline output.
This is the sole completed-tool default; the former collapse boolean is ignored.
Set globally or buffer-locally.  Changes apply on the next projection (or
`pichat-chat-repaint'), without restarting Pi.  Explicit per-tool choices take
precedence.  Parent activity-group disclosure is independent."
  :type '(choice (const :tag "Header only" summary)
                 (const :tag "Header and args" args)
                 (const :tag "Header, args, and output" output))
  :group 'pichat)

(defcustom pichat-chat-activity-group-display 'collapsed
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

(defcustom pichat-chat-tool-truncation-notice-format
  "\n\n[… %d chars truncated; use C-c C-d on the tool block for full output]"
  "Format string used for truncated tool output notices."
  :type 'string
  :group 'pichat)

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

(provide 'pichat-display)
;;; pichat-display.el ends here
