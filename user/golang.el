;;; golang.el --- Go programming support -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Go editing, language-server, build, test, and debugging support.
;;; Code:

(declare-function dape "dape")
(declare-function dape-breakpoint-toggle "dape")
(declare-function dape-continue "dape")
(declare-function dape-next "dape")
(declare-function dape-quit "dape")
(declare-function dape-step-in "dape")
(declare-function eglot-code-action-organize-imports "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function evil-jump-forward "evil-commands")
(declare-function evil-local-set-key "evil-core")
(declare-function evil-normalize-keymaps "evil-core")
(declare-function gofmt "go-mode")

(defun my/project-find-go-module (directory)
  "Return a project rooted at the nearest go.mod above DIRECTORY."
  (when-let ((root (locate-dominating-file directory "go.mod")))
    (cons 'go-module root)))

(cl-defmethod project-root ((project (head go-module)))
  "Return the root directory of Go module PROJECT."
  (cdr project))

(add-hook 'project-find-functions #'my/project-find-go-module)

(defun my/go-project-root ()
  "Return the current Go module or project root."
  (if-let ((project (project-current nil)))
      (project-root project)
    default-directory))

(defun my/go-format-buffer ()
  "Format the current Go buffer with gofmt."
  (require 'go-mode)
  (gofmt))

(defun my/go-before-save ()
  "Format the current Go buffer and organize its imports."
  (if (eglot-managed-p)
      (progn
        ;; Eglot signals when gopls has no import action to offer, which should
        ;; not prevent an otherwise valid save.
        (ignore-errors
          (eglot-code-action-organize-imports (point-min) (point-max)))
        (eglot-format-buffer))
    (my/go-format-buffer)))

(defun my/go-indent-region (_start _end)
  "Format Go buffers when `indent-region' is used."
  (my/go-format-buffer))

(defun my/go-compile (command &optional project-root)
  "Run Go COMMAND with `compile'.
When PROJECT-ROOT is non-nil, run it from the current Go project root."
  (let ((default-directory (if project-root
                               (my/go-project-root)
                             default-directory)))
    (compile command)))

(defun my/go-build-project ()
  "Build all packages in the current Go project."
  (interactive)
  (my/go-compile "go build ./..." t))

(defun my/go-run-package ()
  "Run the Go package in the current directory."
  (interactive)
  (my/go-compile "go run ."))

(defun my/go-generate-package ()
  "Run go generate for the package in the current directory."
  (interactive)
  (my/go-compile "go generate ."))

(defun my/go-generate-project ()
  "Run go generate for all packages in the current Go project."
  (interactive)
  (my/go-compile "go generate ./..." t))

(defun my/go-test-package ()
  "Test the Go package in the current directory."
  (interactive)
  (my/go-compile "go test -count=1 -v ."))

(defun my/go-test-project ()
  "Test all packages in the current Go project."
  (interactive)
  (my/go-compile "go test -count=1 -v ./..." t))

(defun my/go--test-names-in-buffer ()
  "Return top-level Go test function names in the current buffer."
  (save-excursion
    (goto-char (point-min))
    (let (names)
      (while (re-search-forward
              "^func[[:space:]]+\\(Test[[:alnum:]_]+\\)[[:space:]]*(" nil t)
        (push (match-string-no-properties 1) names))
      (nreverse names))))

(defun my/go-test-file ()
  "Run the tests declared in the current Go test file."
  (interactive)
  (unless (and buffer-file-name
               (string-suffix-p "_test.go" buffer-file-name))
    (user-error "Current buffer is not a Go test file"))
  (let ((names (my/go--test-names-in-buffer)))
    (unless names
      (user-error "No Go tests found in this file"))
    (my/go-compile
     (format "go test -count=1 -v -run %s ."
             (shell-quote-argument
              (format "^(%s)$"
                      (mapconcat #'regexp-quote names "|")))))))

(defun my/go-test-at-point ()
  "Run the top-level Go test containing point."
  (interactive)
  (unless (and buffer-file-name
               (string-suffix-p "_test.go" buffer-file-name))
    (user-error "Current buffer is not a Go test file"))
  (let ((name
         (save-excursion
           (when (re-search-backward
                  "^func[[:space:]]+\\(Test[[:alnum:]_]+\\)[[:space:]]*(" nil t)
             (match-string-no-properties 1)))))
    (unless name
      (user-error "No Go test found at point"))
    (my/go-compile
     (format "go test -count=1 -v -run %s ."
             (shell-quote-argument (format "^%s$" (regexp-quote name)))))))

(defun my/go-benchmark-project ()
  "Run all benchmarks in the current Go project."
  (interactive)
  (my/go-compile "go test -run='^$' -bench=. ./..." t))

(defun my/go-vet-project ()
  "Run go vet for all packages in the current Go project."
  (interactive)
  (my/go-compile "go vet ./..." t))

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
  (add-hook 'before-save-hook #'my/go-before-save nil t)
  (eglot-ensure))

(use-package eglot
  :ensure nil
  :defer t
  :custom
  (eglot-workspace-configuration
   '((:gopls . ((staticcheck . t)))))
  :hook ((go-dot-mod-mode . eglot-ensure)
         (go-dot-work-mode . eglot-ensure)
         (go-mod-ts-mode . eglot-ensure)))

(use-package go-mode
  :ensure t
  :mode "\\.go\\'"
  :hook ((go-mode . my/go-mode-setup)
         (go-ts-mode . my/go-mode-setup))
  :general
  (sharmaso/mode-keys
    :keymaps '(go-mode-map go-ts-mode-map)
    "b" '(:ignore t :which-key "build")
    "b b" '(my/go-build-project :wk "build-project")
    "b r" '(my/go-run-package :wk "run-package")
    "g" '(:ignore t :which-key "generate")
    "g p" '(my/go-generate-package :wk "generate-package")
    "g P" '(my/go-generate-project :wk "generate-project")
    "t" '(:ignore t :which-key "test")
    "t t" '(my/go-test-at-point :wk "test-at-point")
    "t f" '(my/go-test-file :wk "test-file")
    "t p" '(my/go-test-package :wk "test-package")
    "t P" '(my/go-test-project :wk "test-project")
    "t r" '(recompile :wk "rerun")
    "t b" '(my/go-benchmark-project :wk "benchmark-project")
    "c" '(:ignore t :which-key "code")
    "c a" '(eglot-code-actions :wk "code-actions")
    "c i" '(eglot-code-action-organize-imports :wk "organize-imports")
    "c r" '(eglot-rename :wk "rename")
    "h" '(eldoc-doc-buffer :wk "documentation")
    "v" '(my/go-vet-project :wk "vet-project")
    "d" '(:ignore t :which-key "debug")
    "d d" '(dape :wk "start")
    "d b" '(dape-breakpoint-toggle :wk "breakpoint")
    "d c" '(dape-continue :wk "continue")
    "d n" '(dape-next :wk "next")
    "d i" '(dape-step-in :wk "step-in")
    "d q" '(dape-quit :wk "quit")))

(defvar flycheck-global-modes)
(setq flycheck-global-modes '(not lisp-interaction-mode go-mode go-ts-mode))

(provide 'user/golang)
;;; golang.el ends here
