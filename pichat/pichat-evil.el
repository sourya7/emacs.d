;;; pichat-evil.el --- Optional Evil bindings for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat's ordinary mode maps remain usable without Evil.  Evil's Normal-state
;; map (and Evil Collection's read-only bindings) take precedence over those
;; maps, so Vim-style PiChat actions need explicit state-specific bindings.

;;; Code:

(require 'pichat-view)
(require 'pichat-chat)
(require 'pichat-sessions)
(require 'pichat-response-view)
(require 'pichat-session-manager)

(defvar pichat-artifacts-preview-mode-map)

(declare-function evil-set-initial-state "evil-core" (mode state))
(declare-function evil-define-key* "evil-core"
                  (state keymap key def &rest bindings))
(declare-function evil-normalize-keymaps "evil-core" ())

;;;###autoload
(defun pichat-evil-setup ()
  "Use Vim navigation and PiChat-specific actions in PiChat buffers.
Keep Normal-state RET for movement in the chat transcript.  Insert-state RET
still sends the prompt; C-c C-c sends in either state.  All non-Evil bindings
remain in their original mode maps."
  (interactive)
  (unless (require 'evil nil t)
    (user-error "PiChat Evil bindings require Evil"))
  (evil-set-initial-state 'pichat-chat-mode 'normal)
  (evil-set-initial-state 'pichat-chat-compose-mode 'normal)
  (evil-set-initial-state 'pichat-view-mode 'normal)
  (evil-set-initial-state 'pichat-session-manager-mode 'normal)
  ;; The shared view close must beat Evil Collection's generic quit-window:
  ;; PiChat also owns the origin, nested displays, and snapshot kill policy.
  (evil-define-key* 'normal pichat-view-mode-map
    (kbd "q") #'pichat-view-quit)
  (evil-define-key* 'normal pichat-sessions-mode-map
    (kbd "q") #'pichat-sessions-return-to-chat
    (kbd "RET") #'pichat-sessions-activate-at-point
    (kbd "j") #'pichat-sessions-next-entry
    (kbd "k") #'pichat-sessions-previous-entry
    (kbd "z a") #'pichat-sessions-toggle-fold-at-point
    (kbd "z v") #'pichat-sessions-preview-branch-at-point
    (kbd "g r") #'pichat-sessions-list-refresh)
  (evil-define-key* 'normal pichat-session-manager-mode-map
    (kbd "q") #'pichat-session-manager-quit
    (kbd "RET") #'pichat-session-manager-open-chat
    (kbd "z v") #'pichat-session-manager-toggle-preview
    (kbd "g r") #'pichat-session-manager-refresh)
  (evil-define-key* 'normal pichat-session-manager-preview-mode-map
    (kbd "q") #'pichat-session-manager-preview-quit
    (kbd "g r") #'pichat-session-manager-preview-refresh)
  (evil-define-key* 'normal pichat-response-view-mode-map
    (kbd "g r") #'pichat-response-view-refresh)
  (with-eval-after-load 'pichat-artifacts-embark
    (evil-define-key* 'normal pichat-artifacts-preview-mode-map
      (kbd "q") #'pichat-view-quit)
    ;; Evil caches active minor-mode maps; refresh when a preview is enabled
    ;; after `markdown-mode' or `special-mode' has already selected Normal.
    (add-hook 'pichat-artifacts-preview-mode-hook #'evil-normalize-keymaps)))

(provide 'pichat-evil)
;;; pichat-evil.el ends here
