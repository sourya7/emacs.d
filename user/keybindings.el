;;; keybindings.el --- keybindings -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; keybindings
;;; Code:

(require 'general)

(keymap-global-set "C-=" 'text-scale-increase)
(keymap-global-set "C--" 'text-scale-decrease)
(keymap-global-set "C-<wheel-up>" 'text-scale-increase)
(keymap-global-set "C-<wheel-down>" 'text-scale-decrease)
(keymap-global-set "<escape>" 'keyboard-quit)
(keymap-global-set "C-g" 'my/keyboard-quit-dwim)

(general-define-key
 :keymaps 'evil-insert-state-map
 "C-e" #'end-of-line
 "C-a" #'beginning-of-line-text)

(general-define-key
 :states '(normal visual)
 "gc" 'evil-avy-goto-char-timer
 "gC" 'evil-avy-goto-char
 "gl" 'evil-avy-goto-line)

(add-hook 'eshell-mode-hook
          (lambda ()
            (general-define-key
             :states 'insert
             :keymaps 'local
             "C-r" 'consult-history)))

(general-define-key
 :states 'normal
 "gD" 'dumb-jump-go)

(defvar sharmaso/leader-keys nil
  "Leader key definition for general.el keybindings.")

(defvar sharmaso/mode-keys nil
  "Mode key definition for general.el keybindings.")

(general-create-definer sharmaso/leader-keys
  :states '(normal insert visual emacs)
  :keymaps 'override
  ;; set leader
  :prefix "SPC"
  ;; access leader in insert mode
  :global-prefix "M-SPC")

(general-create-definer sharmaso/mode-keys
  :states '(normal insert visual emacs)
  :keymaps 'override
  ;; set leader
  :prefix "SPC m"
  ;; access leader in insert mode
  :global-prefix "M-SPC m")

(general-define-key
 :keymaps 'minibuffer-local-map
 "C-;" 'embark-act
 "C-c C-;" 'embark-export
 "C-c C-l" 'embark-collect
 "M-s" 'consult-history
 "M-r" 'consult-history)

(general-define-key
 :keymaps 'project-prefix-map
 "r" 'my/project-recentf
 "b" 'consult-project-buffer)

(defvar-keymap my/tab-prefix-map
  "`" 'my/bufferlo-consult-buffer
  "SPC" 'project-find-file
  "TAB" 'ace-window)

(defvar-keymap my/buffer-map
  "`" 'mode-line-other-buffer
  "b" 'my/bufferlo-consult-buffer
  "c" 'clone-indirect-buffer
  "d" 'kill-current-buffer
  "D" 'bookmark-delete
  "i" 'ibuffer
  "l" 'consult-bookmark
  "m" 'bookmark-set
  "n" 'next-buffer
  "p" 'previous-buffer
  "r" 'revert-buffer
  "R" 'rename-buffer
  "s" 'basic-save-buffer
  "w" 'bookmark-save
  "x" 'scratch-buffer)

(defvar-keymap my/consult-map
  "a" 'consult-atuin
  "c" 'consult-yasnippet
  "d" 'consult-dir
  "h" 'consult-history
  "i" 'consult-imenu
  "I" 'consult-imenu-multi
  "n" 'consult-notes
  "r" 'consult-register
  "R" 'consult-register-store
  "s" 'detached-consult-session
  "y" 'consult-yank-from-kill-ring)

(defvar-keymap my/transient-map
  "a" 'casual-agenda-tmenu
  "b" 'casual-ibuffer-tmenu
  "c" 'casual-calc-tmenu
  "C" 'casual-calendar-tmenu
  "d" 'casual-dired-tmenu
  "e" 'casual-editkit-main-tmenu
  "i" 'casual-info-tmenu
  "s" 'casual-isearch-tmenu
  "r" 'casual-re-builder-tmenu)

(defvar-keymap my/dired-map
  "d" 'dired
  "j" 'dired-jump
  "n" 'neotree-dir
  "z" 'zoxide-travel)

(defvar-keymap my/flycheck-map
  "l" 'flycheck-list-errors
  "n" 'flycheck-next-error
  "p" 'flycheck-previous-error)

(defvar-keymap my/files-map
  "c" 'my/copy-file
  "e" 'my/find-files-emacsd
  "f" 'find-file
  "F" 'find-file-other-window
  "g" 'consult-grep
  "l" 'consult-locate
  "r" 'consult-recent-file
  "R" 'my/move-file
  "s" 'save-buffer
  "u" 'sudo-edit-find-file
  "U" 'sudo-edit)

(defvar-keymap my/git-map
  "/" 'magit-dispatch
  "." 'magit-file-dispatch
  "b" 'magit-blame
  "B" 'magit-branch-checkout
  "c" (define-keymap
        "b" 'magit-branch-and-checkout
        "c" 'magit-commit-create
        "f" 'magit-commit-fixup)
  "C" 'magit-clone
  "f" (define-keymap
        "c" 'magit-show-commit
        "f" 'magit-find-file
        "g" 'magit-find-git-config-file)
  "F" 'magit-fetch
  "g" 'magit-status
  "i" 'magit-init
  "l" 'magit-log-buffer-file
  "r" 'vc-revert
  "d" 'difftastic-magit-diff-buffer-file
  "D" 'difftastic-magit-diff
  "s" 'difftastic-magit-show
  "t" 'git-timemachine
  "u" 'magit-stage-file)

(defvar-keymap my/help-map
  "a" 'apropos
  "b" 'describe-bindings
  "c" 'describe-char
  "d" (define-keymap
        "l" 'devdocs-lookup
        "p" 'devdocs-peruse
        "i" 'devdocs-install)
  "e" 'view-echo-area-messages
  "f" 'helpful-callable
  "F" 'describe-face
  "i" 'info
  "I" 'describe-input-method
  "k" 'helpful-key
  "l" 'view-lossage
  "L" 'describe-language-environment
  "m" 'describe-mode
  "p" 'describe-package
  "t" 'consult-theme
  "v" 'helpful-variable
  "w" 'where-is
  "x" 'helpful-command)

(defvar-keymap my/lisp-map
  "b" 'eval-buffer
  "d" 'eval-defun
  "e" 'eval-last-sexp
  "E" 'eval-expression
  "r" 'eval-region)

(defvar-keymap my/tab-map
  "1" 'my/switch-to-tab-from-key
  "2" 'my/switch-to-tab-from-key
  "3" 'my/switch-to-tab-from-key
  "4" 'my/switch-to-tab-from-key
  "5" 'my/switch-to-tab-from-key
  "b" 'switch-to-buffer-other-tab
  "c" 'bufferlo-tab-close-kill-buffers
  "C" 'tab-close-other
  "d" 'tab-duplicate
  "f" 'find-file-other-tab
  "n" 'tab-new
  "p" 'other-tab-prefix
  "r" 'tab-rename
  "s" 'tab-switcher
  "h" 'tab-previous
  "l" 'tab-next)

(sharmaso/mode-keys
  :keymaps '(emacs-lisp-mode-map lisp-interaction-mode-map)
  "e" '(:keymap my/lisp-map :wk "eval"))

(defvar-keymap my/notes-map
  "c" 'org-capture
  "n" 'denote
  "r" 'denote-rename-file
  "l" 'denote-link
  "b" 'denote-backlinks
  "d" 'denote-dired
  "y" 'my/yank-buffer-line-at-point
  "g" 'consult-denote-grep
  "f" 'consult-denote-find)

(defvar-keymap my/open-map
  "a" 'ace-link
  "d" 'docker
  "k" 'kubel
  "p" (define-keymap
        "d" 'my/process-compose-down
        "l" 'my/process-compose-list-process
        "r" 'my/process-compose-restart-process
        "s" 'my/process-compose-start-process
        "k" 'my/process-compose-stop-process
        "u" 'my/process-compose-up)
  "w" (define-keymap
        "o" 'eww
        "r" 'eww-reload
        "s" 'my/web-search-interactive)
  "t" (define-keymap
        "p" 'eat-project
        "t" 'vterm-toggle
        "e" 'eshell)
  "v" (define-keymap
        "v" 'vundo
        "c" 'undo-fu-clear-all)
  "e" (define-keymap
        "e" 'elfeed
        "u" 'elfeed-update))

(defun my/reload-emacs-config ()
  "Reload Emacs config."
  (interactive)
  (load-file (expand-file-name "init.el" user-emacs-directory))
  (ignore (elpaca-process-queues)))

(with-eval-after-load 'embark
  (keymap-set embark-url-map "v" #'my/extract-url-content-web)
  ;; If this causes other mode issues, might consider somehow constraining
  ;; it to emacs-lisp-mode
  (keymap-set embark-function-map "h" #'helpful-symbol))

(defvar-keymap my/quit-map
  "f" 'delete-frame
  "q" 'save-buffers-kill-terminal
  "Q" 'kill-emacs
  "r" 'my/reload-emacs-config
  "R" 'restart-emacs)

(defun my/search-dir ()
  "Search the local directory."
  (interactive)
  (consult-ripgrep default-directory))

(defvar-keymap my/search-map
  "d" 'my/search-dir
  "i" 'consult-info
  "l" 'consult-line
  "L" 'consult-line-multi
  "m" 'consult-man
  "p" 'consult-ripgrep)

(defvar-keymap my/toggle-map
  "F" 'flycheck-mode
  "f" 'toggle-frame-fullscreen
  "g" 'golden-ratio
  "G" 'golden-ratio-mode
  "l" 'display-line-numbers-mode
  "L" 'global-display-line-numbers-mode
  "n" 'neotree-toggle
  "r" 'rainbow-mode
  "t" 'visual-line-mode
  "z" 'my/run-zellij-with-project-dir)

(defvar-keymap my/window-map
  "=" 'balance-windows
  "d" 'evil-window-delete
  "n" 'evil-window-new
  "s" 'evil-window-split
  "v" 'evil-window-vsplit
  "r" (define-keymap
        "t" 'transpose-window-layout
        "r" 'rotate-window-layout-clockwise
        "l" 'rotate-window-layout-counterclockwise
        "f" 'flip-window-layout-horizontally
        "c" 'rotate-windows
        "C" 'rotate-windows-back
        "v" 'rotate:even-vertical
        "h" 'rotate:even-horizontal)
  "h" 'evil-window-left
  "j" 'evil-window-down
  "k" 'evil-window-up
  "l" 'evil-window-right
  "m" 'delete-other-windows
  "p" 'other-window-prefix
  "C-r" 'winner-redo
  "u" 'winner-undo
  "w" 'evil-window-next
  "x" 'kill-buffer-and-window
  "H" 'buf-move-left
  "J" 'buf-move-down
  "K" 'buf-move-up
  "L" 'buf-move-right)

(sharmaso/leader-keys
  ";" 'pp-eval-expression
  "`" 'evil-switch-to-windows-last-buffer
  "'" 'vertico-repeat
  "." 'consult-buffer
  "!" 'my/shell-command
  "@" 'async-shell-command
  "SPC" 'execute-extended-command
  "TAB" '(:keymap my/tab-prefix-map)
  "C-;" 'embark-dwim
  "a" 'embark-act
  "b" '(:keymap my/buffer-map :wk "buffer")
  "c" '(:keymap my/consult-map :wk "consult")
  "C" '(:keymap my/transient-map :wk "transient")
  "d" '(:keymap my/dired-map :wk "dired")
  "D" 'detached-shell-command
  "e" '(:keymap my/flycheck-map :wk "flycheck")
  "f" '(:keymap my/files-map :wk "files")
  "g" '(:keymap my/git-map :wk "git")
  "h" '(:keymap my/help-map :wk "help")
  "j" '(:keymap my/tab-map :wk "tabs")
  "n" '(:keymap my/notes-map :wk "notes")
  "o" '(:keymap my/open-map :wk "open")
  "q" '(:keymap my/quit-map :wk "quit")
  "p" '(:keymap project-prefix-map :wk "project")
  "s" '(:keymap my/search-map :wk "search")
  "t" '(:keymap my/toggle-map :wk "toggle")
  "u" 'universal-argument
  "w" '(:keymap my/window-map :wk "window"))

(which-key-add-key-based-replacements
  "SPC g c" "create"
  "SPC g f" "find"
  "SPC w r" "rotate"
  "SPC o w" "web"
  "SPC o t" "term"
  "SPC o v" "undo"
  "SPC o e" "elfeed")

(provide 'user/keybindings)
;;; keybindings.el ends here
