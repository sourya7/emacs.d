;;; basic-config.el ---  basic config-*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; configure the basic portions of Emacs before other
;;; configurations
;;;
;;; Code:

(declare-function my/emacs-local-dir "utils.el")
(declare-function my/emacs-shared-dir "utils.el")
;; ================================
;; Basic UI Configuration
;; ================================
(setq inhibit-startup-message t
      frame-resize-pixelwise  t  ; fine resize
      visible-bell nil
      x-stretch-cursor t
      window-combination-resize t)

;; make emacs ask y/n vs the full yes/no strings
(if (version<= emacs-version "28")
    (defalias 'yes-or-no-p 'y-or-n-p)
  (setopt use-short-answers t))

(with-eval-after-load 'mule-util
  (setq-default truncate-string-ellipsis "…"))

;; Disable unnecessary UI elements
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'set-fringe-mode) (set-fringe-mode 10))
(when (fboundp 'tooltip-mode) (tooltip-mode -1))
(when (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(when (fboundp 'blink-cursor-mode) (blink-cursor-mode 0))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))

;; Frame settings
(add-to-list 'default-frame-alist '(fullscreen . maximized))
;; (add-to-list 'default-frame-alist '(undecorated . t))
;; (add-to-list 'default-frame-alist '(alpha-background . 0.9)) ; uncomment for transparency

;; ================================
;; Package Management
;; ================================
(setq package-enable-at-startup nil
      package-native-compile t)

(setq-default native-comp-async-report-warnings-errors 'silent)
;; ================================
;; File Management
;; ================================
(setq backup-by-copying t
      delete-by-moving-to-trash t
      auto-save-default nil
      undo-limit 100000000
      vc-handled-backends '(Git))

;; Directory configurations
;;(setcar native-comp-eln-load-path (my/emacs-local-dir "eln-cache/"))
(setq package-user-dir (my/emacs-local-dir "elpa/"))
(setq backup-directory-alist `(("." . ,(my/emacs-local-dir "backups/"))))
(setq-default no-littering-etc-directory (my/emacs-shared-dir ""))
(setq-default no-littering-var-directory (my/emacs-local-dir "var/"))


;; Rendering optimizations (esp for macos)
(setq inhibit-compacting-font-caches t)
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)

;; ================================
;; Editing Behavior
;; ================================
(delete-selection-mode 1)
(electric-pair-mode 1)
(winner-mode 1)
(global-auto-revert-mode 1)

(setq-default sentence-end-double-space nil
              indent-tabs-mode nil
              initial-buffer-choice t
              initial-scratch-message nil
              initial-major-mode 'org-mode)

;; Choose mods where you want to enable code collapse
(dolist (mode '())
  (add-hook mode #'hs-minor-mode))

;; Cleanup hooks
(add-hook 'before-save-hook #'whitespace-cleanup)

;; ================================
;; Font Configuration
;; ================================

(defun my/set-font-default ()
  "Set the current default font and size."
  (when (and (boundp 'my/default-font-name)
             (boundp 'my/default-font-size)
             (fboundp 'my/set-font)
             my/default-font-name
             my/default-font-size)
    (my/set-font my/default-font-name my/default-font-size)))

(defun my/custom-set-font (symbol value)
  "Handler to run when the customized font variable SYMBOL VALUE is updated."
  (set-default symbol value)
  (my/set-font-default))

(defcustom my/default-font-name "Hack Nerd Font Mono"
  "Default font."
  :group 'sharmaso
  :type 'string
  :set 'my/custom-set-font)

(defcustom my/default-font-size 150
  "Default font size."
  :group 'sharmaso
  :type 'integer
  :set 'my/custom-set-font)

(add-hook 'server-after-make-frame-hook 'my/set-font-default)

;; ================================
;; Mode Line Configuration
;; ================================
(column-number-mode)

;; Battery display
(let ((battery-str (battery)))
  (unless (or (equal "Battery status not available" battery-str)
              (string-match-p (regexp-quote "N/A") battery-str))
    (display-battery-mode 1)))

;; UTF-8 encoding display
(defun modeline-contitional-buffer-encoding ()
  "Hide \"LF UTF-8\" in modeline when using standard encoding."
  (setq-local doom-modeline-buffer-encoding
              (unless (and (memq (plist-get (coding-system-plist buffer-file-coding-system) :category)
                                '(coding-category-undecided coding-category-utf-8))
                          (not (memq (coding-system-eol-type buffer-file-coding-system) '(1 2))))
                t)))
(add-hook 'after-change-major-mode-hook #'modeline-contitional-buffer-encoding)

;; Frame title format
(defvar-local my/frame-title-project-name-cache nil
  "Cached project name as (DEFAULT-DIRECTORY . NAME) for the frame title.")

(defun my/frame-title-project-name ()
  "Return the current project name, cached for `default-directory'."
  (let ((directory (expand-file-name default-directory)))
    (if (and my/frame-title-project-name-cache
             (equal directory
                    (car my/frame-title-project-name-cache)))
        (cdr my/frame-title-project-name-cache)
      (let* ((project (project-current nil directory))
             (name (and project (project-name project))))
        (setq my/frame-title-project-name-cache (cons directory name))
        name))))

(defun my/invalidate-frame-title-project-name-cache ()
  "Invalidate the frame-title project name cache in the current buffer."
  (kill-local-variable 'my/frame-title-project-name-cache))

(add-hook 'hack-local-variables-hook
          #'my/invalidate-frame-title-project-name-cache)

(setq frame-title-format
      '(""
        "%b"
        (:eval
         (when-let ((project-name (my/frame-title-project-name)))
           (unless (string= "-" project-name)
             (format (if (buffer-modified-p) " ◉ %s" "  ●  %s - Emacs") project-name))))))

;; ================================
;; User Information
;; ================================
(setq user-full-name "Sourya Sharma"
      user-mail-address "sourya.s7@gmail.com")

;; ================================
;; System-Specific Configuration
;; ================================
(defun contextual-menubar (&optional frame)
  "Display the menubar in FRAME if on graphical display, hide if in terminal."
  (interactive)
  (set-frame-parameter frame 'menu-bar-lines
                       (if (display-graphic-p frame) 1 0)))

(when (eq system-type 'darwin)
  (add-hook 'after-make-frame-functions #'contextual-menubar))

(setq ring-bell-function 'ignore)
(setq-default epa-pinentry-mode 'loopback)

(setq custom-file (my/emacs-local-dir "custom.el"))
(load custom-file 'noerror)

;; ================================
;; Buffer Display Rules
;; ================================
(add-to-list 'display-buffer-alist
             '("\\`\\*\\(Warnings\\|Compile-Log\\)\\*\\'"
               (display-buffer-no-window)
               (allow-no-window . t)))

;; (setq display-buffer-base-action
;;       '((display-buffer-reuse-window display-buffer-same-window)
;;         (reusable-frames . t))
;;       even-window-sizes nil)

(provide 'core/basic-config)
;;; basic-config.el ends here
