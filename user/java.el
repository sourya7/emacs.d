;;; java.el --- Java programming support -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Java editing, JDTLS/Eglot language support, builds, tests, and Dape
;;; debugging.
;;;
;;; Setup:
;;; 1. Put Java 21+ and `jdtls' on Emacs's PATH.
;;; 2. For debugging, build/install Microsoft's java-debug plugin and either
;;;    set JAVA_DEBUG_BUNDLE or customize `my/java-debug-bundle' to its
;;;    com.microsoft.java.debug.plugin-*.jar file.
;;; 3. Open a .java file inside a Git, Maven, or Gradle project; Eglot starts
;;;    automatically.  Maven and Gradle wrappers are preferred when present.
;;; 4. Run `M-x my/java-check-setup' to check dependencies.  After changing a
;;;    bundle path, run `M-x eglot-reconnect' (or restart Emacs).
;;;
;;; Code:

(declare-function dape "dape")
(declare-function dape-breakpoint-toggle "dape")
(declare-function dape-continue "dape")
(declare-function dape-next "dape")
(declare-function dape-quit "dape")
(declare-function dape-restart "dape")
(declare-function dape-step-in "dape")
(declare-function dape-step-out "dape")
(declare-function eglot-code-actions "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eglot-inlay-hints-mode "eglot")
(declare-function eglot-jdtls-debugger-hot-code-replace "eglot-jdtls-debugger")
(declare-function eglot-jdtls-organize-imports "eglot-jdtls")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-rename "eglot")
(declare-function evil-jump-forward "evil-commands")
(declare-function evil-local-set-key "evil-core")
(declare-function evil-normalize-keymaps "evil-core")

(defvar eglot-jdtls-config)

(defgroup my/java nil
  "Java development configuration."
  :group 'languages)

(defcustom my/java-jdtls-command '("jdtls")
  "Command used to start Eclipse JDTLS.
The JDTLS runtime must use Java 21 or newer."
  :type '(repeat string)
  :group 'my/java)

(defcustom my/java-debug-bundle
  (let ((bundle (getenv "JAVA_DEBUG_BUNDLE")))
    (and bundle (not (string-empty-p bundle)) bundle))
  "Path to the Microsoft java-debug server plugin JAR.
This is the com.microsoft.java.debug.plugin-*.jar produced by java-debug.
It is passed to JDTLS at startup and is required by Dape's `jdtls' adapter."
  :type '(choice (const :tag "Disabled" nil) file)
  :group 'my/java)

(defcustom my/java-extra-jdtls-bundles nil
  "Additional Eclipse plugin JARs loaded by JDTLS.
This can, for example, contain the plugin JARs from vscode-java-test."
  :type '(repeat file)
  :group 'my/java)

(defcustom my/java-format-on-save t
  "When non-nil, organize imports and format Eglot-managed Java buffers."
  :type 'boolean
  :group 'my/java)

(defcustom my/java-enable-inlay-hints t
  "When non-nil, enable Eglot inlay hints in managed Java buffers."
  :type 'boolean
  :group 'my/java)

(defun my/java--bundles ()
  "Return existing JDTLS plugin bundle paths as a vector."
  (vconcat
   (seq-filter #'file-regular-p
               (delq nil (cons my/java-debug-bundle
                               my/java-extra-jdtls-bundles)))))

(defun my/java--configure-jdtls ()
  "Configure the JDTLS command and plugin bundles."
  (setq eglot-jdtls-config
        `(:cmd ,my/java-jdtls-command
          :init-options (:bundles ,(my/java--bundles)))))

(defun my/java-project-root ()
  "Return the current Java project root."
  (if-let* ((project (project-current nil)))
      (project-root project)
    default-directory))

(defun my/java--build-tool ()
  "Return the build tool and executable for the current Java project."
  (let ((root (my/java-project-root)))
    (cond
     ((file-executable-p (expand-file-name "mvnw" root))
      (cons 'maven "./mvnw"))
     ((file-executable-p (expand-file-name "gradlew" root))
      (cons 'gradle "./gradlew"))
     ((file-exists-p (expand-file-name "pom.xml" root))
      (cons 'maven "mvn"))
     ((or (file-exists-p (expand-file-name "build.gradle" root))
          (file-exists-p (expand-file-name "build.gradle.kts" root)))
      (cons 'gradle "gradle"))
     (t (user-error "No Maven or Gradle build found at %s" root)))))

(defun my/java--compile-task (maven-task gradle-task)
  "Run MAVEN-TASK or GRADLE-TASK from the Java project root."
  (pcase-let* ((default-directory (my/java-project-root))
               (`(,tool . ,executable) (my/java--build-tool))
               (task (if (eq tool 'maven) maven-task gradle-task)))
    (compile (format "%s %s" (shell-quote-argument executable) task))))

(defun my/java-build-project ()
  "Build the current Maven or Gradle project."
  (interactive)
  (my/java--compile-task "package -DskipTests" "build -x test"))

(defun my/java-test-project ()
  "Run all tests in the current Maven or Gradle project."
  (interactive)
  (my/java--compile-task "test" "test"))

(defun my/java-clean-project ()
  "Clean the current Maven or Gradle project."
  (interactive)
  (my/java--compile-task "clean" "clean"))

(defun my/java-before-save ()
  "Organize imports and format the current Java buffer."
  (when (and my/java-format-on-save (eglot-managed-p))
    ;; A buffer may have no import action, which should not prevent saving.
    (ignore-errors (eglot-jdtls-organize-imports))
    (eglot-format-buffer)))

(defun my/java-eglot-managed-setup ()
  "Enable Java-specific features after Eglot starts managing a buffer."
  (when (derived-mode-p 'java-mode 'java-ts-mode)
    (when (and my/java-enable-inlay-hints
               (fboundp 'eglot-inlay-hints-mode))
      (eglot-inlay-hints-mode 1))
    (when (fboundp 'eglot-codelens-mode)
      (eglot-codelens-mode 1))))

(defun my/java-check-setup ()
  "Report missing external dependencies for Java development."
  (interactive)
  (let (missing)
    (unless (executable-find (car my/java-jdtls-command))
      (push (format "JDTLS executable `%s'" (car my/java-jdtls-command)) missing))
    (unless (executable-find "java")
      (push "Java 21+ executable `java'" missing))
    (unless (seq-some #'file-regular-p
                      (cons my/java-debug-bundle my/java-extra-jdtls-bundles))
      (push "java-debug plugin JAR (needed for Dape)" missing))
    (if missing
        (message "Java setup missing: %s" (mapconcat #'identity (nreverse missing) "; "))
      (message "Java development dependencies are configured"))))

(defun my/java-mode-setup ()
  "Configure Java editing and start JDTLS through Eglot."
  ;; Load CodeLens before eglot-jdtls so its optional integration is installed.
  (require 'eglot-codelens nil t)
  (require 'eglot-jdtls)
  (my/java--configure-jdtls)
  (setq-local indent-tabs-mode nil
              tab-width 4)
  (when (fboundp 'evil-local-set-key)
    (evil-local-set-key 'normal (kbd "TAB") #'evil-jump-forward)
    (evil-local-set-key 'normal (kbd "<tab>") #'evil-jump-forward)
    (when (fboundp 'evil-normalize-keymaps)
      (evil-normalize-keymaps)))
  (add-hook 'before-save-hook #'my/java-before-save nil t)
  (eglot-ensure))

(use-package eglot-codelens
  :ensure (:host github :repo "zsxh/eglot-codelens")
  :defer t)

(use-package eglot-jdtls
  :ensure (:host github :repo "zsxh/eglot-jdtls")
  :defer t
  :init
  (with-eval-after-load 'eglot
    (add-to-list 'eglot-server-programs
                 '((java-mode java-ts-mode) .
                   (eglot-jdtls-server . eglot-jdtls-cmd))))
  :hook ((java-mode . my/java-mode-setup)
         (java-ts-mode . my/java-mode-setup))
  :general
  (sharmaso/mode-keys
    :keymaps '(java-mode-map java-ts-mode-map)
    "b" '(:ignore t :which-key "build")
    "b b" '(my/java-build-project :wk "build-project")
    "b c" '(my/java-clean-project :wk "clean-project")
    "t" '(:ignore t :which-key "test")
    "t p" '(my/java-test-project :wk "test-project")
    "t r" '(recompile :wk "rerun")
    "c" '(:ignore t :which-key "code")
    "c a" '(eglot-code-actions :wk "code-actions")
    "c f" '(eglot-format-buffer :wk "format")
    "c i" '(eglot-jdtls-organize-imports :wk "organize-imports")
    "c r" '(eglot-rename :wk "rename")
    "h" '(eldoc-doc-buffer :wk "documentation")
    "d" '(:ignore t :which-key "debug")
    "d d" '(dape :wk "start")
    "d b" '(dape-breakpoint-toggle :wk "breakpoint")
    "d c" '(dape-continue :wk "continue")
    "d n" '(dape-next :wk "next")
    "d i" '(dape-step-in :wk "step-in")
    "d o" '(dape-step-out :wk "step-out")
    "d r" '(dape-restart :wk "restart")
    "d h" '(eglot-jdtls-debugger-hot-code-replace :wk "hot-code-replace")
    "d q" '(dape-quit :wk "quit")
    "s" '(my/java-check-setup :wk "check-setup")))

(add-hook 'eglot-managed-mode-hook #'my/java-eglot-managed-setup)

;; Eglot supplies Flymake diagnostics; do not duplicate them with Flycheck.
(with-eval-after-load 'flycheck
  (when (eq (car-safe flycheck-global-modes) 'not)
    (dolist (mode '(java-mode java-ts-mode))
      (add-to-list 'flycheck-global-modes mode t))))

(provide 'user/java)
;;; java.el ends here
