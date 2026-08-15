;;; emacs-builtin.el --- emacs builtin package configuration -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Emacs builtins
;;; Code:

(use-package emacs
  :ensure nil
  ;; Do not allow the cursor in the minibuffer prompt
  :hook (minibuffer-setup . cursor-intangible-mode)
  :custom
  ;; Support opening new minibuffers from inside existing minibuffers.
  (enable-recursive-minibuffers t)
  ;; Hide commands in M-x which do not work in the current mode.  Vertico
  ;; commands are hidden in normal buffers. This setting is useful beyond
  ;; Vertico.
  (read-extended-command-predicate #'command-completion-default-include-p)
  (minibuffer-prompt-properties '(read-only t cursor-intangible t face minibuffer-prompt))
  (tab-always-indent 'complete)
  (text-mode-ispell-word-completion nil)
  (read-file-name-completion-ignore-case t)
  (read-buffer-completion-ignore-case t)
  (completion-ignore-case t)
  :init
  ;; Add prompt indicator to `completing-read-multiple'.
  ;; We display [CRM<separator>], e.g., [CRM,] if the separator is a comma.
  (defun crm-indicator (args)
    (cons (format "[CRM%s] %s"
                  (replace-regexp-in-string
                   "\\`\\[.*?]\\*\\|\\[.*?]\\*\\'" ""
                   crm-separator)
                  (car args))
          (cdr args)))
  (advice-add #'completing-read-multiple :filter-args #'crm-indicator))

(use-package ielm
  :ensure nil
  :hook ((ielm-mode . eldoc-mode)
         (ielm-mode . paredit-mode)
         (ielm-mode . g-ielm-init-history))
  :general
  (general-define-key :states 'insert :keymaps 'paredit-mode-map
                      "<RET>" nil
                      "C-j" 'paredit-newline)
  (general-define-key :states 'insert :keymaps 'inferior-emacs-lisp-mode-map
                      "C-l" 'comint-clear-buffer
                      "C-r" 'consult-history
                      "C-c C-c" 'ielm-send-input)
  :init
  (defun g-ielm-init-history ()
    (let ((path (my/emacs-local-dir "ielm/history")))
      (make-directory (file-name-directory path) t)
      (setq-local comint-input-ring-file-name path))
    (setq-local comint-input-ring-size 10000)
    (setq-local comint-input-ignoredups t)
    (comint-read-input-ring))

  (defun g-ielm-write-history (&rest _args)
    (with-file-modes #o600
      (comint-write-input-ring)))

  (advice-add 'ielm-send-input :after 'g-ielm-write-history))

(use-package project
  :ensure nil
  :custom
  (project-list-file (my/emacs-local-dir "projects")))

(use-package multisession
  :ensure nil
  :custom
  (multisession-directory (my/emacs-local-dir "multisession/")))

(use-package saveplace
  :ensure nil
  :custom
  (save-place-mode t)
  (save-place-file (my/emacs-local-dir "places")))

(use-package dired
  :ensure nil
  :commands (dired)
  :hook
  ((dired-mode . dired-hide-details-mode)
   (dired-mode . hl-line-mode))
  :custom
  (dired-kill-when-opening-new-dired-buffer t)
  :config
  (setq dired-recursive-copies 'always)
  (setq dired-recursive-deletes 'always)
  (setq delete-by-moving-to-trash t)
  (setq dired-dwim-target t))

(use-package recentf
  :ensure nil
  :custom
  (recentf-max-saved-items 500)
  (recentf-mode t)
  :config
  (my/add-all-to-list 'recentf-exclude
                      `(,(rx (* any)
                             (or "elfeed-db"
                                 ".elfeed/"
                                 "shared/bookmarks"
                                 ".git/"
                                 "/TAGS"
                                 "eln-cache/"
                                 ".cache/")
                             (* any))
                        ,(rx (* any) ".elc" eol)
                        )))

(defcustom my/save-sessions nil
  "Save Emacs sessions with desktop mode."
  :type 'boolean
  :group 'sharmaso)

(use-package desktop
  :ensure nil
  :if my/save-sessions
  :hook ((server-after-make-frame . desktop-read))
  :custom
  (desktop-dirname my/emacs-local-dir)
  (desktop-path (list my/emacs-local-dir))
  :config
  (advice-add 'server-handle-delete-frame
              :before (lambda (&rest _args)
                        (call-interactively 'desktop-save-in-desktop-dir)
                        (desktop-release-lock))))

(use-package tramp
  :ensure nil
  :config
  ;; NOTE - this might break LSP
  (connection-local-set-profile-variables
   'remote-direct-async-process
   '((tramp-direct-async-process . t)))

  (connection-local-set-profiles
   '(:application tramp :machine "server")
   'remote-direct-async-process)

  (connection-local-set-profiles
   '(:application tramp :protocol "ssh")
   'remote-direct-async-process)
  ;; END

  (with-eval-after-load 'compile
    (remove-hook 'compilation-mode-hook #'tramp-compile-disable-ssh-controlmaster-options))

  (setq magit-tramp-pipe-stty-settings 'pty)
  (setq tramp-persistency-file-name (my/emacs-local-dir "tramp")
        remote-file-name-inhibit-locks t
        tramp-use-scp-direct-remote-copying t
        remote-file-name-inhibit-auto-save-visited t
        tramp-copy-size-limit (* 1024 1024) ;; 1MB
        tramp-verbose 2
        ;; necessary for dir-locals over tramp
        enable-remote-dir-locals t))

(use-package helpful :defer t)

(use-package casual :defer t)

;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(provide 'core/emacs-builtin)
;;; emacs-builtin.el ends here
