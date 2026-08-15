;;; autocomplete.el --- Autocompletion -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; autocomplete
;;; Code:

(use-package vertico
  :hook (minibuffer-setup . vertico-repeat-save)
  :general
  (:keymaps 'vertico-map
            "M-RET"   'vertico-exit-input
            "C-j"     'vertico-next
            "<volume-down>"     'vertico-next
            "C-M-j"   'vertico-next-group
            "<volume-up>"     'vertico-previous
            "C-k"     'vertico-previous
            "C-M-k"   'vertico-previous-group)
  :custom
  (vertico-multiform-categories
   '((symbol (vertico-sort-function . vertico-sort-history-alpha))
     (file (vertico-sort-function . vertico-sort-alpha))
     (embark-keybinding grid)))
  (vertico-count 20)
  (vertico-cycle t)
  (vertico-multiform-mode t)
  (vertico-mode t))

(use-package vertico-directory
  :after vertico
  :ensure nil
  ;; More convenient directory navigation commands
  :general
  (:keymaps 'vertico-map
            "RET" 'vertico-directory-enter
            "DEL" 'vertico-directory-delete-char
            "M-DEL" 'vertico-directory-delete-word)
  :hook (rfn-eshadow-update-overlay . vertico-directory-tidy))

(use-package savehist
  :ensure nil
  :custom
  (savehist-file (my/emacs-local-dir "history"))
  (savehist-mode t))

(use-package comint-histories
  :demand t
  :custom
  (comint-histories-global-filters '((lambda (x) (<= (length x) 3)) string-blank-p))
  (comint-histories-persist-dir (my/emacs-local-dir "comint-histories"))
  :config
  (comint-histories-add-history ruby
    :predicates '((lambda () (derived-mode-p 'inf-ruby-mode)))
    :length 2000
    :no-dups t)

  (comint-histories-add-history shell
    :predicates '((lambda () (derived-mode-p 'shell-mode)))
    :filters '("^ls" "^cd")
    :length 2000
    :no-dups t)

  (comint-histories-mode 1))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package consult
  :functions consult-register-window consult-customize
  :custom
  (register-preview-delay 0.5)
  (xref-show-xrefs-function #'consult-xref)
  (xref-show-definitions-function #'consult-xref)
  (consult-narrow-key "<")
  :init
  (advice-add #'register-preview :override #'consult-register-window)
  ;; Use Consult to select xref locations with preview
  :config
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-ripgrep consult-git-grep consult-grep
   consult-bookmark consult-recent-file consult-xref
   consult-source-bookmark consult-source-file-register
   consult-source-recent-file consult-source-project-recent-file
   ;; :preview-key "M-."
   :preview-key '(:debounce 0.4 any))
  )

(use-package consult-dir
  :after consult
  :ensure t
  :bind (:map vertico-map
         ("C-x C-d" . consult-dir)
         ("C-x C-j" . consult-dir-jump-file))
  :config
  (defun consult-dir--zoxide-dirs ()
    "Return list of zoxide dirs."
    (split-string (shell-command-to-string "zoxide query -l") "\n" t))
  (defvar consult-dir--source-zoxide
    `(:name     "zoxide"
                :narrow   ?z
                :category file
                :face     consult-file
                :history  file-name-history
                :enabled  ,(lambda () (executable-find "zoxide"))
                :items    ,#'consult-dir--zoxide-dirs)
    "zoxide directory source for `consult-dir'.")

  (add-to-list 'consult-dir-sources 'consult-dir--source-zoxide t))

(use-package marginalia
  :custom
  (marginalia-mode t))

;; corfu
(use-package corfu
  :hook (elpaca-after-init . global-corfu-mode)
  :bind (:map corfu-map ("<tab>" . corfu-complete))
  :custom
  (corfu-auto t)
  (corfu-quit-no-match t)
  (corfu-preview-current nil)
  (corfu-min-width 30)
  (corfu-quit-at-boundary 'separator)
  (corfu-popupinfo-delay '(1.25 . 0.5))
  (global-corfu-modes '((not inf-ruby-mode) t))
  :config
  (corfu-popupinfo-mode 1)
  (with-eval-after-load 'savehist
    (corfu-history-mode 1)
    (add-to-list 'savehist-additional-variables 'corfu-history)))

(use-package cape :after corfu)

(use-package corfu-terminal
  :after corfu
  :if (version< emacs-version "31")
  :ensure t
  :config
  (unless (display-graphic-p)
    (corfu-terminal-mode +1)))

(use-package yasnippet :hook (elpaca-after-init . yas-global-mode))

(use-package consult-yasnippet
  :after yasnippet)

(use-package embark :ensure t
  :functions embark-prefix-help-command
  :custom
  (prefix-help-command #'embark-prefix-help-command)
  (embark-indicators
   '(embark-minimal-indicator  ; default is embark-mixed-indicator
     embark-highlight-indicator
     embark-isearch-highlight-indicator))
  :config
  ;; Hide the mode line of the Embark live/completions buffers
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none)))))

(use-package embark-consult :ensure t)

(use-package wgrep :defer t)

(use-package flymake :ensure nil :defer t)

(use-package eglot :ensure nil :defer t)

(use-package jsonrpc :ensure nil :defer nil)
(use-package project :ensure nil :defer nil)

(use-package eldoc :ensure nil :defer t
  :custom
  (eldoc-echo-area-use-multiline-p nil))

;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(provide 'core/autocomplete)
;;; autocomplete.el ends here
