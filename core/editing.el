;;; editing.el --- configurations related to editing -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;; Editing configurations
;;; Code:

;; Use Ctrl-Q for single quotes
(use-package smartparens
  :hook (prog-mode . smartparens-mode)
  :config
  (require 'smartparens-config)
  (sp-local-pair '(emacs-lisp-mode) "'" "'" :actions nil)
  (sp-local-pair '(emacs-lisp-mode) "`" "`" :actions nil))

(use-package jsonnet-mode)

(use-package ediff
  :ensure nil
  :init
  (defun ediff-current-windows ()
    "Run ediff on the buffers displayed in the current frame's two windows."
    (interactive)
    (let ((windows (window-list)))
      (if (= (length windows) 2)
          (let ((buf1 (window-buffer (car windows)))
                (buf2 (window-buffer (cadr windows))))
            (ediff-buffers buf1 buf2))
        (error "This function requires exactly 2 windows"))))

  (setq ediff-split-window-function 'split-window-horizontally
        ediff-window-setup-function 'ediff-setup-windows-plain))

(use-package evil-indent-plus :after evil
  :defer nil
  :config
  (evil-indent-plus-default-bindings))

(use-package evil-surround :after evil
  :config
  (global-evil-surround-mode))

(use-package string-edit-at-point :defer t)

(use-package evil-cleverparens
  :after evil
  :hook (emacs-lisp-mode . evil-cleverparens-mode))

(use-package dumb-jump
  :commands dumb-jump-xref-activate
  :config
  (add-hook 'xref-backend-functions #'dumb-jump-xref-activate))

(use-package smart-jump
  :ensure t
  :config
  (smart-jump-setup-default-registers))

(use-package undo-fu
  :after evil
  :custom
  (evil-undo-system 'undo-fu))

(use-package undo-fu-session
  :defer nil
  :custom
  (undo-fu-session-directory (my/emacs-local-dir "undo-fu-session"))
  :config
  (undo-fu-session-global-mode))

(use-package vundo
  :custom
  (vundo-window-side 'top))

(use-package treesit-auto
  :when (and (fboundp 'treesit-available-p) (treesit-available-p))
  :custom
  (treesit-auto-install nil)
  :config
  ;; disable treesit for ruby momentarily because of multiple issues (indentation)
  (delete 'ruby treesit-auto-langs)
  (add-to-list 'treesit-extra-load-path (my/emacs-local-dir "tree-sitter"))
  ;; Only register modes whose grammars are available
  (treesit-auto-add-to-auto-mode-alist))

(use-package inhibit-mouse
  :if (not (eq system-type 'android))
  :hook (elpaca-after-init . inhibit-mouse-mode))

;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(provide 'core/editing)
;;; editing.el ends here
