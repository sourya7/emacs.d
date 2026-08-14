;;; clojure.el --- Clojure programming support -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;
;; Configuration for Clojure development environment including:
;; - Clojure mode with enhanced font-locking
;; - CIDER for REPL, navigation, and completion
;; - Structural editing via paredit/smartparens
;; - Test runner integration
;; - clj-refactor for refactoring support
;;
;;; Code:

;;; Core Clojure Support
(use-package clojure-mode
  :mode (("\\.clj\\'" . clojure-mode)
         ("\\.cljs\\'" . clojurescript-mode)
         ("\\.cljc\\'" . clojurec-mode)
         ("\\.edn\\'" . clojure-mode))
  :custom
  (clojure-align-forms-automatically t)
  (clojure-indent-style 'always-align))

;;; REPL and Development Environment
(use-package cider
  :hook ((clojure-mode . cider-mode)
         (clojurescript-mode . cider-mode)
         (clojurec-mode . cider-mode))
  :custom
  ;; REPL behavior
  (cider-repl-display-help-banner nil)
  (cider-repl-pop-to-buffer-on-connect 'display-only)
  (cider-repl-use-pretty-printing t)
  (cider-repl-history-file (expand-file-name "cider-repl-history" user-emacs-directory))
  (cider-repl-wrap-history t)
  (cider-repl-history-size 1000)
  ;; Eval and result display
  (cider-show-error-buffer 'only-in-repl)
  (cider-result-overlay-position 'at-eol)
  (cider-auto-select-error-buffer nil)
  ;; Completion and eldoc
  (cider-eldoc-display-for-symbol-at-point t)
  (cider-eldoc-display-context-dependent-info t)
  ;; Save files before loading
  (cider-save-file-on-load t)
  ;; Prefer clojure-cli (deps.edn) over lein; adjust if you use lein
  (cider-preferred-build-tool 'clojure-cli)
  ;; Enriched javadoc
  (cider-enrich-classpath t)
  :config
  (defun my/cider-jack-in ()
    "Jack in with sensible defaults."
    (interactive)
    (cider-jack-in nil))

  (defun my/cider-jack-in-cljs ()
    "Jack in for ClojureScript."
    (interactive)
    (cider-jack-in-cljs nil))
  :general
  (sharmaso/mode-keys
    :keymaps '(clojure-mode-map clojurescript-mode-map clojurec-mode-map)
    ;; REPL
    "r" '(:ignore t :which-key "repl")
    "r j" '(my/cider-jack-in :wk "jack-in")
    "r J" '(my/cider-jack-in-cljs :wk "jack-in-cljs")
    "r c" '(cider-connect :wk "connect")
    "r r" '(cider-switch-to-repl-buffer :wk "switch-to-repl")
    "r q" '(cider-quit :wk "quit")
    "r R" '(cider-restart :wk "restart")
    "r n" '(cider-repl-set-ns :wk "set-repl-ns")
    ;; Eval
    "e" '(:ignore t :which-key "eval")
    "e e" '(cider-eval-last-sexp :wk "eval-last-sexp")
    "e f" '(cider-eval-defun-at-point :wk "eval-defun")
    "e b" '(cider-eval-buffer :wk "eval-buffer")
    "e r" '(cider-eval-region :wk "eval-region")
    "e n" '(cider-eval-ns-form :wk "eval-ns")
    "e i" '(cider-inspect-last-result :wk "inspect-result")
    ;; Navigation / docs
    "d" '(:ignore t :which-key "docs")
    "d d" '(cider-doc :wk "doc")
    "d j" '(cider-javadoc :wk "javadoc")
    "d a" '(cider-apropos :wk "apropos")
    "d s" '(cider-clojuredocs :wk "clojuredocs")
    ;; Find
    "g d" '(cider-find-var :wk "find-var")
    "g b" '(cider-pop-back :wk "pop-back")
    "g n" '(cider-find-ns :wk "find-ns")
    "g r" '(cider-find-resource :wk "find-resource")
    ;; Test
    "t" '(:ignore t :which-key "test")
    "t t" '(cider-test-run-test :wk "run-test-at-point")
    "t n" '(cider-test-run-ns-tests :wk "run-ns-tests")
    "t p" '(cider-test-run-project-tests :wk "run-project-tests")
    "t r" '(cider-test-rerun-failed-tests :wk "rerun-failed")
    "t s" '(cider-test-show-report :wk "show-report")
    ;; Debug
    "D" '(:ignore t :which-key "debug")
    "D d" '(cider-debug-defun-at-point :wk "debug-defun")
    "D i" '(cider-inspect :wk "inspect")
    "D m" '(cider-macroexpand-1 :wk "macroexpand-1")
    "D M" '(cider-macroexpand-all :wk "macroexpand-all")
    ;; Namespace
    "n" '(:ignore t :which-key "namespace")
    "n r" '(cider-ns-refresh :wk "refresh")
    "n R" '(cider-ns-reload-all :wk "reload-all")))

;;; Structural Editing
(use-package paredit
  :hook ((clojure-mode . paredit-mode)
         (clojurescript-mode . paredit-mode)
         (clojurec-mode . paredit-mode)
         (cider-repl-mode . paredit-mode)))

;;; Refactoring
(use-package clj-refactor
  :hook ((clojure-mode . my/clj-refactor-setup)
         (clojurescript-mode . my/clj-refactor-setup)
         (clojurec-mode . my/clj-refactor-setup))
  :custom
  (cljr-warn-on-eval nil)
  (cljr-eagerly-build-asts-on-startup nil)
  :config
  (defun my/clj-refactor-setup ()
    (clj-refactor-mode 1)
    (cljr-add-keybindings-with-prefix "C-c C-m"))
  :general
  (sharmaso/mode-keys
    :keymaps '(clojure-mode-map clojurescript-mode-map clojurec-mode-map)
    "R" '(:ignore t :which-key "refactor")
    "R a" '(cljr-add-require-to-ns :wk "add-require")
    "R i" '(cljr-add-import-to-ns :wk "add-import")
    "R r" '(cljr-rename-symbol :wk "rename-symbol")
    "R e" '(cljr-extract-function :wk "extract-fn")
    "R l" '(cljr-introduce-let :wk "introduce-let")
    "R t" '(cljr-thread-first-all :wk "thread-first")
    "R T" '(cljr-thread-last-all :wk "thread-last")
    "R u" '(cljr-unwind :wk "unwind")
    "R c" '(cljr-clean-ns :wk "clean-ns")
    "R s" '(cljr-sort-ns :wk "sort-ns")))

;;; Linting
(use-package flycheck-clj-kondo
  :after (clojure-mode flycheck)
  :config
  ;; Requires clj-kondo installed: https://github.com/clj-kondo/clj-kondo
  (dolist (hook '(clojure-mode-hook clojurescript-mode-hook clojurec-mode-hook))
    (add-hook hook #'flycheck-mode)))

;;; Enhanced REPL history and usability
(use-package cider-eval-sexp-fu
  :after cider
  :config
  ;; Brief highlight of evaluated sexps
  (require 'cider-eval-sexp-fu))

(provide 'clojure)
;;; clojure.el ends here
