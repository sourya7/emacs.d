;;; pichat-chat-navigation.el --- PiChat navigation and secondary views -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused helpers for logical turn navigation, active-item selection, compose
;; buffers, and canonical-transcript Markdown export.  The chat orchestration
;; layer supplies all markers, block tables, transcripts, and input callbacks;
;; this module does not require or mutate `pichat-chat'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-transcript)

(defun pichat-chat-navigation--property-run-start (position property limit)
  "Return start of PROPERTY's run at POSITION, bounded by LIMIT."
  (let ((value (and (< position (point-max))
                    (get-text-property position property)))
        (cursor position)
        previous)
    (when value
      (while (and (> cursor limit)
                  (setq previous
                        (previous-single-property-change
                         cursor property nil limit))
                  (equal value (get-text-property previous property)))
        (setq cursor previous))
      cursor)))

(defun pichat-chat-navigation-turn-position (start end position direction)
  "Return another user-turn start in START..END from POSITION.
DIRECTION is 1 for the next turn and -1 for the previous turn.  Navigation is
based only on the stable `pichat-node-role' logical property.  When POSITION is
inside a user turn, that turn is excluded in both directions."
  (unless (memq direction '(1 -1))
    (error "Invalid navigation direction: %S" direction))
  (let* ((start (max (point-min) start))
         (end (min (point-max) end))
         (position (min end (max start position)))
         (current-start
          (and (< position end)
               (eq 'user (get-text-property position 'pichat-node-role))
               (pichat-chat-navigation--property-run-start
                position 'pichat-node-role start)))
         (cursor start)
         turns)
    (while (< cursor end)
      (let* ((role (get-text-property cursor 'pichat-node-role))
             (next (or (next-single-property-change
                        cursor 'pichat-node-role nil end)
                       end)))
        (when (eq role 'user)
          (push cursor turns))
        (setq cursor (if (> next cursor) next end))))
    (setq turns (nreverse turns))
    (if (> direction 0)
        (cl-find-if (lambda (turn)
                      (> turn (or current-start position)))
                    turns)
      (car (last (cl-remove-if-not
                  (lambda (turn)
                    (< turn (or current-start position)))
                  turns))))))

(defun pichat-chat-navigation--latest-running-tool (blocks)
  "Return the latest visible running tool position in BLOCKS."
  (let (latest)
    (when (hash-table-p blocks)
      (maphash
       (lambda (_id block)
         (let ((start (plist-get block :start)))
           (when (and (equal "running" (plist-get block :status))
                      (markerp start) (marker-position start)
                      (or (null latest)
                          (> (marker-position start) latest)))
             (setq latest (marker-position start)))))
       blocks))
    latest))

(defun pichat-chat-navigation-active-target
    (blocks pending-request-count pending-position live-start live-end
            prompt-position session-running-p)
  "Return the highest-priority active target as a plist.
Priority is: latest running tool in BLOCKS, pending extension request at
PENDING-POSITION, non-empty live tail in LIVE-START..LIVE-END, then the prompt
while SESSION-RUNNING-P.  PENDING-REQUEST-COUNT makes pending state explicit;
no hash-table ordering affects the result."
  (let ((tool-position
         (pichat-chat-navigation--latest-running-tool blocks)))
    (cond
     (tool-position (list :kind 'tool :position tool-position))
     ((and (> (or pending-request-count 0) 0) pending-position)
      (list :kind 'extension-request :position pending-position))
     ((and live-start live-end (< live-start live-end))
      (list :kind 'live-tail :position live-start))
     ((and session-running-p prompt-position)
      (list :kind 'prompt :position prompt-position)))))

(defvar-local pichat-chat-compose-target-buffer nil
  "Chat buffer receiving this compose buffer's text.")

(defvar-local pichat-chat-compose-replace-function nil
  "Function called in the target chat buffer with composed text and point.")

(defvar-local pichat-chat-compose-target-token nil
  "Source identity captured when this compose editor was opened.")

(defvar-local pichat-chat-compose-target-valid-function nil
  "Function called in the target buffer with the captured source token.")

(defvar-local pichat-chat-compose-origin-window-configuration nil
  "Window configuration to restore after applying or cancelling composition.")

(defvar pichat-chat-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'pichat-chat-compose-apply)
    (define-key map (kbd "C-c C-k") #'pichat-chat-compose-cancel)
    map)
  "Keymap for `pichat-chat-compose-mode'.")

(define-derived-mode pichat-chat-compose-mode text-mode "PiChat-Compose"
  "Major mode for composing text for a PiChat input editor.")

(defun pichat-chat-navigation--compose-buffer (target token)
  "Return an existing compose buffer associated with TARGET and TOKEN."
  (cl-find-if
   (lambda (buffer)
     (with-current-buffer buffer
       (and (derived-mode-p 'pichat-chat-compose-mode)
            (eq pichat-chat-compose-target-buffer target)
            (equal pichat-chat-compose-target-token token))))
   (buffer-list)))

(defun pichat-chat-navigation--trimmed-text-and-point (text point-offset)
  "Return trimmed TEXT and its adjusted POINT-OFFSET as a cons."
  (let* ((left-trimmed (string-trim-left text))
         (leading (- (length text) (length left-trimmed)))
         (trimmed (string-trim-right left-trimmed)))
    (cons trimmed
          (min (length trimmed) (max 0 (- point-offset leading))))))

(defun pichat-chat-navigation-open-compose
    (target replace-function initial-text initial-point
            &optional target-token target-valid-function)
  "Return a compose editor for TARGET using REPLACE-FUNCTION.
INITIAL-TEXT and INITIAL-POINT initialize a newly created editor.
REPLACE-FUNCTION is called in TARGET with trimmed text and its adjusted point
offset, and must return the resulting absolute target position.  TARGET-TOKEN
identifies the bound chat source.
TARGET-VALID-FUNCTION, when non-nil, is called in TARGET with that token before
replacement.  An existing editor for the same live target and source is reused
without refreshing its unsaved text.  Editors whose target died or rebound
remain separate so they cannot be silently reassigned."
  (unless (buffer-live-p target)
    (user-error "PiChat compose target is not live"))
  (let* ((existing
          (pichat-chat-navigation--compose-buffer target target-token))
         (buffer
          (or existing
              (generate-new-buffer
               (generate-new-buffer-name
                (format "*PiChat Compose: %s*" (buffer-name target)))))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-chat-compose-mode)
        (pichat-chat-compose-mode))
      (unless existing
        (insert initial-text)
        (goto-char (+ (point-min)
                      (min (length initial-text) (max 0 initial-point))))
        (set-buffer-modified-p nil))
      (setq-local pichat-chat-compose-target-buffer target)
      (setq-local pichat-chat-compose-replace-function replace-function)
      (setq-local pichat-chat-compose-target-token target-token)
      (setq-local pichat-chat-compose-target-valid-function
                  target-valid-function)
      ;; Refresh the return destination each time an existing editor is opened.
      (setq-local pichat-chat-compose-origin-window-configuration
                  (current-window-configuration)))
    buffer))

(defun pichat-chat-navigation--compose-close-and-return (buffer target point)
  "Kill compose BUFFER, restore its origin, and focus TARGET at POINT."
  (let ((configuration
         (buffer-local-value
          'pichat-chat-compose-origin-window-configuration buffer)))
    (with-current-buffer buffer
      (set-buffer-modified-p nil))
    (kill-buffer buffer)
    (when (and (window-configuration-p configuration)
               (frame-live-p (window-configuration-frame configuration)))
      (set-window-configuration configuration))
    (let ((window (get-buffer-window target t)))
      (if (window-live-p window)
          (progn
            (select-window window)
            (with-current-buffer target
              (goto-char point)
              (set-window-point window point)))
        (pop-to-buffer target)
        (goto-char point)))))

;;;###autoload
(defun pichat-chat-compose-apply ()
  "Replace the live target's prompt with this editor's text, then close.
Text is trimmed before replacement and an empty result clears the prompt.
Target death, source rebinding, or replacement failure leaves this compose
buffer and its text intact.  Applying never submits the prompt to Pi."
  (interactive)
  (unless (derived-mode-p 'pichat-chat-compose-mode)
    (user-error "Not in a PiChat compose buffer"))
  (unless (buffer-live-p pichat-chat-compose-target-buffer)
    (user-error "PiChat compose target is no longer live; text preserved"))
  (unless (functionp pichat-chat-compose-replace-function)
    (user-error "PiChat compose target has no replacement function"))
  (let* ((raw (buffer-substring-no-properties (point-min) (point-max)))
         (raw-point (- (point) (point-min)))
         (text-and-point
          (pichat-chat-navigation--trimmed-text-and-point raw raw-point))
         (text (car text-and-point))
         (point-offset (cdr text-and-point))
         (target pichat-chat-compose-target-buffer)
         (target-token pichat-chat-compose-target-token)
         (target-valid-function pichat-chat-compose-target-valid-function)
         (replace-function pichat-chat-compose-replace-function)
         (compose-buffer (current-buffer))
         target-point)
    (with-current-buffer target
      (when (and target-valid-function
                 (not (funcall target-valid-function target-token)))
        (user-error "PiChat compose target source changed; text preserved"))
      (setq target-point (funcall replace-function text point-offset)))
    (pichat-chat-navigation--compose-close-and-return
     compose-buffer target target-point)
    (message "PiChat compose text applied to prompt")
    text))

;;;###autoload
(defun pichat-chat-compose-cancel ()
  "Discard this compose editor without changing its target prompt."
  (interactive)
  (unless (derived-mode-p 'pichat-chat-compose-mode)
    (user-error "Not in a PiChat compose buffer"))
  (let ((target pichat-chat-compose-target-buffer)
        (compose-buffer (current-buffer)))
    (unless (buffer-live-p target)
      (user-error "PiChat compose target is no longer live; text preserved"))
    (let ((point (with-current-buffer target (point))))
      (pichat-chat-navigation--compose-close-and-return
       compose-buffer target point))
    (message "PiChat composition cancelled")))

(defalias 'pichat-chat-compose-send #'pichat-chat-compose-apply)

(defun pichat-chat-navigation--fence (text language)
  "Return a Markdown fenced block containing TEXT tagged with LANGUAGE."
  (let* ((text (or text ""))
         (width 3)
         (start 0))
    (while (string-match "~+" text start)
      (setq width (max width (1+ (- (match-end 0) (match-beginning 0))))
            start (match-end 0)))
    (let ((fence (make-string width ?~)))
      (format "%s%s\n%s%s%s\n"
              fence (or language "") text
              (if (or (string-empty-p text) (string-suffix-p "\n" text)) "" "\n")
              fence))))

(defun pichat-chat-navigation--inline-code (value)
  "Return VALUE as a safe Markdown inline-code span."
  (let* ((value (format "%s" (or value "?")))
         (width 1)
         (start 0))
    (while (string-match "`+" value start)
      (setq width (max width (1+ (- (match-end 0) (match-beginning 0))))
            start (match-end 0)))
    (let ((fence (make-string width ?`)))
      (if (> width 1)
          (concat fence " " value " " fence)
        (concat fence value fence)))))

(defun pichat-chat-navigation--content-text (content)
  "Return exact normalized text from CONTENT."
  (or (pichat-transcript-content-text content) ""))

(defun pichat-chat-navigation--tool-markdown (tool)
  "Serialize canonical TOOL content to Markdown."
  (let* ((name (pichat-chat-navigation--inline-code
                (pichat-transcript-content-name tool)))
         (status (or (pichat-transcript-content-status tool) 'incomplete))
         (arguments (pichat-transcript-content-arguments tool))
         (output
          (mapconcat #'pichat-chat-navigation--content-text
                     (pichat-transcript-content-output tool) "")))
    (concat
     (format "### Tool %s — %s\n\n" name status)
     (when arguments
       (concat "**Arguments**\n\n"
               (pichat-chat-navigation--fence
                (condition-case _
                    (json-serialize arguments
                                    :false-object :json-false
                                    :null-object nil)
                  (error "[arguments unavailable]"))
                "json")
               "\n"))
     (unless (string-empty-p output)
       (concat "**Output**\n\n"
               (pichat-chat-navigation--fence output "text"))))))

(defun pichat-chat-navigation--quote (text)
  "Return TEXT as a Markdown block quote."
  (mapconcat (lambda (line) (concat "> " line))
             (split-string (or text "") "\n" nil) "\n"))

(defun pichat-chat-navigation--message-markdown (node)
  "Serialize canonical message NODE to Markdown."
  (let ((role (pichat-transcript-node-role node))
        parts)
    (dolist (content (pichat-transcript-node-content node))
      (pcase (pichat-transcript-content-kind content)
        ('tool (push (pichat-chat-navigation--tool-markdown content) parts))
        ('thinking
         (push (concat "**Thinking**\n\n"
                       (pichat-chat-navigation--quote
                        (pichat-chat-navigation--content-text content))
                       "\n")
               parts))
        (_ (let ((text (pichat-chat-navigation--content-text content)))
             (unless (string-empty-p text) (push text parts))))))
    (concat (format "## %s\n\n"
                    (pcase role
                      ('user "User")
                      ('assistant "Assistant")
                      ('custom "Context")
                      (_ "Message")))
            (string-join (nreverse parts) "\n\n"))))

(defun pichat-chat-navigation--node-markdown (node)
  "Serialize canonical transcript NODE to Markdown."
  (pcase (pichat-transcript-node-kind node)
    ('message (pichat-chat-navigation--message-markdown node))
    ('tool
     (concat "## Tool result\n\n"
             (mapconcat #'pichat-chat-navigation--tool-markdown
                        (pichat-transcript-node-content node) "\n\n")))
    ('activity
     (format "## Compaction\n\nTokens before: %s"
             (or (pichat-transcript-node-tokens-before node) "unknown")))
    (_ "")))

(defun pichat-chat-navigation-transcript-markdown (transcript)
  "Serialize canonical TRANSCRIPT model data to Markdown.
No displayed buffer text, presentation overlay, or inline truncation is read."
  (unless (pichat-transcript-p transcript)
    (user-error "No synchronized PiChat transcript to export"))
  (let ((nodes
         (delq nil
               (mapcar
                (lambda (node)
                  (let ((text (pichat-chat-navigation--node-markdown node)))
                    (unless (string-empty-p text) text)))
                (pichat-transcript-nodes transcript)))))
    (if nodes (concat (string-join nodes "\n\n") "\n") "")))

(defun pichat-chat-navigation-export-buffer (transcript source-name)
  "Create and return a Markdown export buffer for TRANSCRIPT and SOURCE-NAME."
  (let ((buffer
         (generate-new-buffer
          (format "*PiChat Export: %s*" (or source-name "transcript"))))
        (text (pichat-chat-navigation-transcript-markdown transcript)))
    (with-current-buffer buffer
      (insert text)
      (goto-char (point-min))
      (if (fboundp 'markdown-mode) (markdown-mode) (text-mode))
      (set-buffer-modified-p nil))
    buffer))

(provide 'pichat-chat-navigation)
;;; pichat-chat-navigation.el ends here
