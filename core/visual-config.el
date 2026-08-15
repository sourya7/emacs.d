;;; visual-config.el ---  visual config -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Configure the visual portions of Emacs
;;; Code:

(use-package nerd-icons)

(defvar after-load-theme-hook nil
  "Hook run after a color theme is loaded using `load-theme'.")

(defun my/ad-theme-switch (theme &rest _)
  "Run `after-load-theme-hook' only if THEME wasn't already enabled."
  (unless (memq theme custom-enabled-themes)
    (run-hooks 'after-load-theme-hook)))

(advice-add #'enable-theme :after #'my/ad-theme-switch)

(use-package vui
  :functions (widget-forward widget-backward widget-button-press
                             vui-refresh vui-quit)
  :general
  (:states 'normal :keymaps 'vui-mode-map
           [remap evil-insert]      #'evil-insert
           [remap evil-append]      #'evil-append
           [remap evil-insert-line] #'evil-insert-line
           [remap evil-append-line] #'evil-append-line
           [remap evil-open-below]  #'evil-open-below
           [remap evil-open-above]  #'evil-open-above
           [remap evil-change]      #'evil-change
           [remap evil-change-line] #'evil-change-line
           [remap evil-delete]      #'evil-delete
           [remap evil-paste-after] #'evil-paste-after
           [remap evil-paste-before] #'evil-paste-before

           "TAB"       #'widget-forward
           "<backtab>" #'widget-backward
           "RET"       #'widget-button-press
           "<"         #'beginning-of-buffer
           ">"         #'end-of-buffer
           "gr"         #'vui-refresh
           "q"         #'vui-quit))

(use-package nerd-icons-completion
  :functions nerd-icons-completion-marginalia-setup
  :after marginalia
  :config
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

(use-package nerd-icons-corfu
  :functions nerd-icons-corfu-formatter
  :defines corfu-margin-formatters
  :after corfu
  :config
  (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter))

(use-package nerd-icons-dired
  :hook
  (dired-mode . nerd-icons-dired-mode))

(use-package doom-modeline
  :config
  (setq doom-modeline-height 25
        doom-modeline-bar-width 4
        doom-modeline-workspace-name nil
        doom-modeline-project-name nil
        doom-modeline-check-simple-format t
        )
  :functions doom-modeline-mode
  :init (doom-modeline-mode 1))

(use-package rainbow-delimiters
  :hook ((emacs-lisp-mode . rainbow-delimiters-mode)
         (clojure-mode . rainbow-delimiters-mode)))

(use-package buffer-name-relative
  :config
  (setq buffer-name-relative-prefix '("<" . ">/"))
  :hook (elpaca-after-init . buffer-name-relative-mode))

(use-package rainbow-mode
  :diminish
  :hook org-mode prog-mode)

(use-package doom-themes
  :defines doom-themes-enable-bold doom-themes-enable-italic
  :functions doom-themes-neotree-config doom-themes-org-config
  :custom
  (doom-themes-enable-bold t)
  (doom-themes-enable-italic t)
  :config
  (doom-themes-org-config))

(use-package dired-subtree
  :defer nil)

(use-package ace-window :defer t
  :custom
  (aw-dispatch-always t))

(use-package ace-link :defer t)

(use-package tab-bar :ensure nil
  :config
  (setq-default tab-bar-new-tab-choice "*scratch*"))

(use-package vim-tab-bar
  :ensure t
  :init
  (defun tab-bar-enable ()
    (vim-tab-bar--apply)
    (tab-bar-mode 1))
  :autoload vim-tab-bar--apply
  :hook ((after-load-theme . tab-bar-enable)
         (server-after-make-frame-hook . tab-bar-enable)))

(defcustom my/theme 'doom-nord
  "Theme for my configuration."
  :type 'symbol
  :group 'sharmaso)

;; Sets the default theme to load!!!
(add-hook 'elpaca-after-init-hook (lambda () (load-theme my/theme t)))

(defun my/toggle-background-mode ()
  "Toggle frame background mode between light and dark."
  (interactive)
  (let* ((current-mode (frame-parameter nil 'background-mode))
         (frame-background-mode (if (eq current-mode 'dark) 'light 'dark)))
    (frame-set-background-mode nil)))

(provide 'core/visual-config)
;;; visual-config.el ends here
