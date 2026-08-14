;;; keybinding-managers.el --- keybinding managers -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; keybinding managers
;;; Code:

(use-package diminish :ensure t)

(use-package which-key
  :diminish
  :demand t
  :custom
  (which-key-sort-order #'which-key-key-order-alpha)
  (which-key-allow-imprecise-window-fit nil)
  (which-key-sort-uppercase-first nil)
  (which-key-add-column-padding 1)
  (which-key-max-display-columns nil)
  (which-key-min-display-lines 6)
  (which-key-idle-delay 0.8)
  (which-key-allow-imprecise-window-fit nil)
  (which-key-mode t))

(use-package evil
  :functions evil-mode
  :after (general)
  :demand t
  :custom
  ;; tweak evil's configuration before loading it
  (evil-want-keybinding nil)
  (evil-vsplit-window-right t)
  (evil-split-window-below t)
  (evil-want-C-u-scroll t)
  (evil-symbol-word-search t)
  (evil-undo-system 'undo-redo)  ;; Adds vim-like C-r redo functionality
  :config
  (evil-mode t))

(use-package evil-collection
  :after evil
  :functions evil-collection-init
  :demand t
  :custom
  (evil-collection-binding-overrides
   '((repl-submit :state insert)
     (repl-newline :state normal)))
  :config
  ;; Do not uncomment this unless you want to specify each and every mode
  ;; that evil-collection should works with.  The following line is here
  ;; for documentation purposes in case you need it.
  ;; (setq evil-collection-mode-list '(calendar dashboard dired ediff info magit ibuffer))
  ;; evilify help mode
  (add-to-list 'evil-collection-mode-list 'help)
  (evil-collection-init))

(provide 'core/keybinding-managers)
;;; keybinding-managers.el ends here
