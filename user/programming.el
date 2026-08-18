;;; programming.el --- programming -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Programming Modes
;;; Code:

(use-package flycheck
  :defer t
  :diminish
  :custom
  (flycheck-idle-change-delay 1.5)
  (flycheck-check-syntax-automatically '(save mode-enabled))
  (flycheck-emacs-lisp-load-path 'inherit)
  (global-flycheck-mode t)
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
