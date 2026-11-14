;;; pichat-chat-actions.el --- Thin chat discovery menu -*- lexical-binding: t; -*-

;;; Commentary:

;; Discover infrequent commands without another action registry or policy layer.
;; Point-sensitive tool/artifact actions and emergency keys stay in the chat.

;;; Code:

(require 'pichat-chat)
(require 'pichat-transient)

(defun pichat-chat-actions--capture ()
  "Capture this chat and its runtime/source, without requiring a live process."
  (unless (and (derived-mode-p 'pichat-chat-mode) pichat-chat-session)
    (user-error "Open a PiChat chat first"))
  (let ((session pichat-chat-session))
    (list :target (pichat-chat-draft-capture)
          :id (pichat-session-id session)
          :file (pichat-session-session-file session)
          :process (pichat-session-process session)
          :generation (pichat-session-process-generation session))))

(defun pichat-chat-actions--buffer (scope)
  "Return SCOPE's owning chat, or reject stale menu work."
  (let* ((target (plist-get scope :target))
         (session (and target (pichat-chat-draft-target-session target))))
    (unless (and (pichat-chat-draft-current-p target)
                 (eq (pichat-session-buffer session)
                     (pichat-chat-draft-target-buffer target))
                 (equal (plist-get scope :id) (pichat-session-id session))
                 (equal (plist-get scope :file) (pichat-session-session-file session))
                 (eq (plist-get scope :process) (pichat-session-process session))
                 (equal (plist-get scope :generation)
                        (pichat-session-process-generation session)))
      (user-error "PiChat Actions context changed; reopen the menu"))
    (pichat-chat-draft-target-buffer target)))

(defun pichat-chat-actions--invoke (scope command)
  "Invoke existing COMMAND in SCOPE's validated chat, not the selected chat.
COMMAND retains responsibility for its own prompts, capabilities and async work."
  (let ((buffer (pichat-chat-actions--buffer scope)))
    ;; Establish the actual view origin too: compose/diagnostics capture the
    ;; selected window, not just `current-buffer'.  Keep any resulting view.
    (pop-to-buffer buffer)
    (call-interactively command)))

(defun pichat-chat-actions--suffixes (items)
  "Build thin suffixes for this menu's ITEMS, capturing the opening scope."
  (let ((scope (transient-scope)))
    (transient-parse-suffixes
     'pichat-chat-actions
     (mapcar (lambda (item)
               (let ((command (nth 2 item)))
                 (list (car item) (cadr item)
                       (lambda () (interactive)
                         (pichat-chat-actions--invoke scope command)))))
             items))))

(defun pichat-chat-actions--heading ()
  "Describe the captured runtime/source using cached data only."
  (let* ((scope (transient-scope))
         (buffer (pichat-chat-actions--buffer scope))
         (session (buffer-local-value 'pichat-chat-session buffer)))
    (pichat-transient-fill
     (format "Runtime %s · %s · %s\nSource %s · %s"
             (pichat-session-runtime-id session)
             (or (pichat-session-state session) 'unknown)
             (pichat-session-model-label session)
             (or (pichat-session-id session) "unknown")
             (abbreviate-file-name (or (pichat-session-emacs-cwd session)
                                       (pichat-session-cwd session) ""))))))

;;;###autoload (autoload 'pichat-chat-actions "pichat-chat-actions" nil t)
(transient-define-prefix pichat-chat-actions ()
  "Discover commands for this exact chat; opening/closing does no RPC work.
Commands recheck the captured chat/source before dispatch and retain their own
validation.  Process replacement also invalidates this menu.  Stopped chats
can still use draft and cached-transcript commands.  Tools and artifacts remain
point-sensitive direct/Embark actions, not delayed menu actions."
  [:description pichat-chat-actions--heading
   ["Draft" :class transient-column
    :setup-children (lambda (_)
                      (pichat-chat-actions--suffixes
                       '(("c" "Compose draft" pichat-chat-open-compose-buffer)
                         ("y" "Recover submission" pichat-chat-recover-submission)
                         ("x" "Pi command (sends)" pichat-command-run))))]
   ["Navigate" :class transient-column
    :setup-children (lambda (_)
                      (pichat-chat-actions--suffixes
                       '(("i" "Settled turns (Imenu)" imenu)
                         ("h" "Session History" pichat-sessions-list)
                         ("b" "Switch saved session" pichat-sessions-switch-files))))]
   ["Transcript" :class transient-column
    :setup-children (lambda (_)
                      (pichat-chat-actions--suffixes
                       '(("r" "Repaint (fetches entries)" pichat-chat-repaint)
                         ("e" "Export canonical Markdown" pichat-chat-export-transcript-to-markdown)
                         ("D" "Diagnostics (cached)" pichat-show-diagnostics))))]]
  [("q" "Close" transient-quit-one)]
  (interactive)
  (transient-setup 'pichat-chat-actions nil nil
                   :scope (pichat-chat-actions--capture)))

(provide 'pichat-chat-actions)
;;; pichat-chat-actions.el ends here
