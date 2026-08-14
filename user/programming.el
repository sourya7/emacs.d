;;; programming.el --- programming -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Programming Modes
;;; Code:

(declare-function gofmt "go-mode")
(declare-function evil-jump-forward "evil-commands")
(declare-function evil-local-set-key "evil-core")
(declare-function evil-normalize-keymaps "evil-core")

(defun my/go-format-buffer ()
  "Format the current Go buffer with gofmt."
  (require 'go-mode)
  (gofmt))

(defun my/go-indent-region (_start _end)
  "Format Go buffers when `indent-region' is used."
  (my/go-format-buffer))

(defun my/go-mode-setup ()
  "Configure Go editing defaults."
  (setq-local indent-tabs-mode t
              tab-width 4
              indent-region-function #'my/go-indent-region)
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "TAB") #'evil-jump-forward)
    (evil-local-set-key 'normal (kbd "<tab>") #'evil-jump-forward)
    (when (fboundp 'evil-normalize-keymaps)
      (evil-normalize-keymaps)))
  (add-hook 'before-save-hook #'my/go-format-buffer nil t))

(use-package go-mode
  :ensure t
  :mode "\\.go\\'"
  :hook ((go-mode . my/go-mode-setup)
         (go-ts-mode . my/go-mode-setup)))

(use-package flycheck
  :defer t
  :diminish
  :custom
  (flycheck-idle-change-delay 1.5)
  (flycheck-check-syntax-automatically '(save mode-enabled))
  (flycheck-emacs-lisp-load-path 'inherit)
  (global-flycheck-mode '(not lisp-interaction-mode))
  (flycheck-disabled-checkers '(emacs-lisp-checkdoc)))

(use-package json-mode :mode "\\.json\\'")

;; (use-package nushell-ts-mode :mode "\\.nu\\'" :defer nil)

(use-package markdown-mode :defer t)

(use-package devdocs :defer t
  :custom
  (devdocs-data-dir (my/emacs-local-dir "devdocs")))

(use-package dockerfile-mode :defer t :mode "Dockerfile\\'")

(use-package nix-mode :mode "\\.nix\\'"
  :config
  (when (boundp 'eglot-server-programs)
    (add-to-list 'eglot-server-programs '(nix-mode . ("nil"))))
  :hook (nix-mode . eglot-ensure))

;; (use-package rust-mode :mode "\\.rs\\'")

(use-package nix-ts-mode :defer t)

(use-package yaml-mode :mode ("\\.yml\\'" "\\.yaml\\'"))

(use-package dape :defer t)

(use-package repeat :ensure nil :defer t)

(use-package apheleia :defer t)

(use-package kdl-ts-mode
  :mode ("\\.kdl\\'" . kdl-ts-mode)
  :ensure (:host github :repo "merrickluo/kdl-ts-mode"))

(use-package just-mode)

(use-package just-ts-mode
  :mode (("\\`[Jj]ustfile\\'" . just-ts-mode)))

(provide 'user/programming)
;;; programming.el ends here
