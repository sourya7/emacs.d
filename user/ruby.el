;;; ruby.el --- Ruby programming support -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; Configuration for Ruby development environment including:
;; - Basic Ruby mode setup
;; - Testing support (minitest)
;; - Rails integration
;; - Code completion and navigation
;;
;;; Code:

(defvar semantic-symref-filepattern-alist)

;;; Core Ruby Support
(use-package ruby-mode
  :ensure nil  ; Built-in package
  :mode "\\.rb\\'"
  :config
  (require 'semantic/symref/grep)
  (setq ruby-align-chained-calls t)
  (add-to-list 'semantic-symref-filepattern-alist
               '(ruby-ts-mode "*.r[bu]" "*.rake" "*.gemspec" "*.erb" "*.haml" "Rakefile"
                              "Thorfile" "Capfile" "Guardfile" "Vagrantfile")))

(defvar my/rails-console-hook nil "Hook to run after rails console starts.")

;;; REPL and Completion
(use-package inf-ruby
  :hook ((ruby-mode . inf-ruby-minor-mode)
         (ruby-ts-mode . inf-ruby-minor-mode)
         (compilation-filter . inf-ruby-auto-enter))
  :custom
  (inf-ruby-console-environment "development")
  (inf-ruby-implementations '(("ruby" . "spring rails console")))
  :config
  (defun my/rails-console ()
    (interactive)
    (inf-ruby-console-auto)
    (evil-normal-state)
    (run-hooks 'my/rails-console-hook))
  :general
  (sharmaso/mode-keys
    :keymaps '(ruby-ts-mode-map ruby-mode-map)
    "r" '(my/rails-console :wk "rails-console")
    "`" '(robe-start :wk "robe-start")))

;;; Development Tools
(use-package rubocop
  :hook ((ruby-mode . rubocop-mode)
         (ruby-ts-mode . rubocop-mode)))

(use-package robe
  :hook ((ruby-mode . robe-mode)
         (ruby-ts-mode . robe-mode)
         (my/rails-console . robe-start))
  :config
  (advice-add 'robe-eldoc :around
              (lambda (orig-fun &rest args)
                (ignore-errors (apply orig-fun args)))))

;;; Project Management
(use-package rake :defer t)
(use-package rbenv :defer t)

(defun my/spring-server ()
  "Run spring server with current project's root directory."
  (interactive)
  (when-let* ((project-dir (when (and (fboundp 'project-root) (project-current))
                             (project-root (project-current))))
              (default-directory project-dir)
              (command "spring server"))
    (message "Running: %s dir: %s" command project-dir) ; Display the command in the minibuffer
    (async-shell-command command)))

;;; Testing
(use-package minitest
  :hook '(ruby-mode ruby-ts-mode)
  :custom
  (minitest-default-env "RAILS_ENV=test")
  (minitest-use-rails nil)
  (minitest-default-command '("spring" "rails" "test"))
  :config
  (defun my/setup-minitest-dape ()
    (let* ((config (my/dape-override-config
                    dape-configs
                    'rdbg
                    '(-c (format "spring rails test %s:%d"
                                 (dape-buffer-default)
                                 (line-number-at-pos))))))
      (cl-pushnew `(rdbg-test . ,config) dape-configs)))

  ;; Unsed but keeping around so I can reference if necessary.
  (defun my/minitest-fix-path (orig-fun &rest args)
    "Set PATH in minitest-default-env from exec-path before running the command."
    (let* ((path (mapconcat #'identity exec-path path-separator))
           (minitest-default-env (format "PATH=\"%s\"" path)))
      (apply orig-fun args)))

  (eval-after-load 'dape #'my/setup-minitest-dape)
  ;; (advice-add #'minitest--run-command :around #'my/minitest-fix-path)
  :general
  (sharmaso/mode-keys
    :keymaps '(ruby-ts-mode-map ruby-mode-map)
    "t" '(:ignore t :which-key "test")
    "t r" 'minitest-rerun
    "t s" 'minitest-verify-single
    "t v" 'minitest-verify
    "t d" 'dape))

(provide 'ruby)
;;; ruby.el ends here
