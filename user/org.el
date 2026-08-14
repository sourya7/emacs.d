;;; org.el --- org mode packages -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; org mode packages
;;; Code:

(use-package org
  :diminish org-indent-mode
  :ensure `,(unless (string-equal system-type "android") t)
  :hook ((org-mode . org-indent-mode)
         (org-mode . (lambda () (org-bullets-mode 1))))
  :general
  (:states 'normal :keymaps 'org-mode-map
           "<TAB>" 'org-cycle)
  :custom
  (org-agenda-files (list "~/org/agenda.org"))
  (org-edit-src-content-indentation 0)
  (org-confirm-babel-evaluate nil)
  (org-id-locations-file (my/emacs-local-dir ".org-id-locations"))
  (org-display-remote-inline-images t)
  (org-capture-templates
   `(("c" "Code Flow" entry
      (file+headline "~/org/code-flow.org" "Code Flow Documentation")
      (file ,(my/emacs-shared-dir "org-templates/code-flow.orgcaptmpl")))))
  :config
  (defun org-kill-src-block-at-point ()
    (interactive)
    (kill-new (org-element-property :value (org-element-at-point))))

  (define-key org-mode-map (kbd "C-c C-r") verb-command-map)

  (org-babel-do-load-languages
   'org-babel-load-languages
   (quote ((emacs-lisp . t)
           (gnuplot . t)
           (shell . t)
           (python . t)
           (ruby . t)
           (nushell . t)
           (sqlite . t))))
  :general
  (sharmaso/mode-keys
    :keymaps 'org-mode-map
    "" '(:ignore t :wk "Org")
    ;; Headings
    "h" '(:ignore t :wk "Headings")
    "hi" '(org-insert-heading-after-current :wk "Insert heading")
    "hI" '(org-insert-subheading :wk "Insert subheading")
    "hp" '(org-promote-subtree :wk "Promote heading")
    "hd" '(org-demote-subtree :wk "Demote heading")
    ;; Tables
    "T" '(:ignore t :wk "Table")
    "Tc" '(org-table-create :wk "Insert row")
    "Ti" '(org-table-insert-row :wk "Insert row")
    "TI" '(org-table-insert-column :wk "Insert column")
    "Td" '(org-table-delete-row :wk "Delete row")
    "TD" '(org-table-delete-column :wk "Delete column")
    ;; Links
    "l" '(:ignore t :wk "Links")
    "li" '(org-insert-link :wk "Insert link")
    "ls" '(org-store-link :wk "Store link")
    ;; Properties
    "p" '(org-set-property :wk "Set property")
    ;; Scheduling
    "s" '(:ignore t :wk "Schedule")
    "sd" '(org-deadline :wk "Set deadline")
    "ss" '(org-schedule :wk "Schedule")
    ;; Toggle
    "t" '(:ignore t :wk "Toggle")
    "tt" '(org-todo :wk "Todo state")
    "ti" '(org-toggle-inline-images :wk "Toggle inline images")
    "tl" '(org-toggle-link-display :wk "Toggle link display")))

(use-package verb :after org)

(use-package hl-todo
  :after org
  :hook ((org-mode . hl-todo-mode)
         (prog-mode . hl-todo-mode))
  :custom
  (hl-todo-highlight-punctuation ":")
  (hl-todo-keyword-faces
   `(("TODO"       warning bold)
     ("FIXME"      error bold)
     ("HACK"       font-lock-constant-face bold)
     ("REVIEW"     font-lock-keyword-face bold)
     ("NOTE"       success bold)
     ("DEPRECATED" font-lock-doc-face bold))))

(use-package toc-org :after org :hook ((org-mode . toc-org-enable)))

(use-package org-bullets :defer t :after org)

(use-package denote
  :ensure t
  :hook (dired-mode . denote-dired-mode)
  :custom
  (denote-directory (expand-file-name "~/Documents/notes/"))
  (denote-rename-buffer-mode 1))

(use-package consult-denote)

(use-package org-nix-shell
  :hook (org-mode . org-nix-shell-mode))

(use-package consult-notes
  :config
  (when (fboundp 'consult-notes-denote-mode)
    (consult-notes-denote-mode)))

(use-package denote-explore)

(use-package ob-nushell
  :ensure (:host github :repo "b3tchi/ob-nushell")
  :config
  (add-to-list 'major-mode-remap-alist '(nu-mode . nushell-ts-mode)))

(use-package evil-org :after (evil org) :defer t)

(use-package pandoc-mode
  :hook ((org-mode . pandoc-mode) (pandoc-mode . pandoc-load-default-settings)))

(use-package literate-calc-mode)


(provide 'user/org)
;;; org.el ends here
