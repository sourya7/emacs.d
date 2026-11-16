;;; eshell.el --- eshell -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Configurations for eshell
;;; Code:

(use-package eshell-syntax-highlighting
  :after eshell-mode
  :custom
  (eshell-syntax-highlighting-global-mode +1))

;; eshell-syntax-highlighting -- adds fish/zsh-like syntax highlighting.
;; eshell-rc-script -- your profile for eshell; like a bashrc for eshell.
;; eshell-aliases-file -- sets an aliases file for the eshell.

(defun my/eshell-protect-transcript ()
  "Make everything before Eshell's current input read-only."
  (when (and (markerp eshell-last-output-end)
             (marker-position eshell-last-output-end))
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t)
          (buffer-undo-list t))
      (with-silent-modifications
        (save-restriction
          (widen)
          ;; Protect insertions at the start, but not at the input boundary.
          (add-text-properties
           (point-min) eshell-last-output-end
           '(read-only my/eshell-transcript
             front-sticky (read-only) rear-nonsticky t)))))))

(define-minor-mode my/eshell-input-only-mode
  "Allow editing only the current input in an Eshell buffer."
  :lighter nil
  (if my/eshell-input-only-mode
      (progn
        (add-hook 'eshell-output-filter-functions
                  #'my/eshell-protect-transcript t t)
        (add-hook 'eshell-input-filter-functions
                  #'my/eshell-protect-transcript t t)
        (my/eshell-protect-transcript))
    (remove-hook 'eshell-output-filter-functions
                 #'my/eshell-protect-transcript t)
    (remove-hook 'eshell-input-filter-functions
                 #'my/eshell-protect-transcript t)
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (save-restriction
          (widen)
          (let ((start (point-min)) end)
            (while (< start (point-max))
              (setq end (next-single-property-change start 'read-only
                                                     nil (point-max)))
              (when (eq (get-text-property start 'read-only)
                        'my/eshell-transcript)
                (remove-text-properties start end '(read-only nil)))
              (setq start end))))))))

(defun my/eshell-allow-output-updates (function &rest args)
  "Allow FUNCTION to insert and process Eshell output with ARGS."
  ;; Output filters can rewrite earlier output (e.g. carriage returns).
  (let* ((buffer (or (car args) (current-buffer)))
         (inhibit-read-only
          (or inhibit-read-only
              (and (buffer-live-p buffer)
                   (buffer-local-value 'my/eshell-input-only-mode buffer)))))
    (apply function args)))

(use-package eshell
  :ensure nil
  :hook (eshell-mode . my/eshell-input-only-mode)
  :config
  (advice-add 'eshell-interactive-filter :around #'my/eshell-allow-output-updates)
  :custom
  ;; (eshell-history-file-name (my/emacs-local-dir "eshell/history"))
  ;; (eshell-last-dir-ring-file-name (my/emacs-local-dir "eshell/lastdir"))
  ;; (eshell-aliases-file (concat user-emacs-directory "eshell/aliases"))
  ;; (eshell-rc-script (concat user-emacs-directory "eshell/profile"))
  (eshell-history-size 5000)
  (eshell-buffer-maximum-lines 5000)
  (eshell-prefer-lisp-functions nil)
  (eshell-prefer-lisp-variables nil)
  (eshell-scroll-window-maximum-output nil)
  (eshell-hist-ignoredups t)
  (eshell-destroy-buffer-when-process-dies t)
  (eshell-visual-commands '("fish" "htop" "ssh" "top" "zsh" "codex" "opencode" "claude"))
  (eshell-visual-subcommands '(("limactl" "shell"))))

(use-package eshell-prompt-extras :after eshell
  :config
  (with-eval-after-load "esh-opt"
    (autoload 'epe-theme-lambda "eshell-prompt-extras")
    (setq eshell-highlight-prompt nil
          eshell-prompt-function 'epe-theme-multiline-with-status)))

(defun eshell/kat (buffer)
  "Cat the BUFFER contents."
  (with-current-buffer buffer
    (buffer-string)))

(defun eshell/zoxide-pwd ()
  "Get current directory (pwd)."
  (eshell/pwd))

(defun eshell/zoxide-cd (&rest args)
  "Change directory with zoxide ARGS."
  (eshell/cd (car args)))

(defun eshell/zoxide-hook ()
  "Hook to add new entries to zoxide database."
  (let ((pwd (eshell/zoxide-pwd)))
    (when pwd
      (start-process "zoxide-add" nil "zoxide" "add" "--" pwd))))

(defun eshell/z (&rest args)
  "Jump to directory using zoxide ARGS."
  (cond
   ((null args)
    (eshell/cd "~"))

   ((and (= (length args) 1) (string= (car args) "-"))
    (if eshell-last-dir-ring
        (eshell/cd (ring-ref eshell-last-dir-ring 0))
      (error "No previous directory")))

   ((and (= (length args) 1) (file-directory-p (car args)))
    (eshell/cd (car args)))

   (t
    (let* ((current-dir (eshell/zoxide-pwd))
           (query-result
            (with-temp-buffer
              (apply #'call-process "zoxide" nil t nil
                     (append '("query" "--exclude")
                            (list current-dir "--")
                            args))
              (string-trim (buffer-string)))))
      (when (not (string-empty-p query-result))
        (eshell/cd query-result))))))

(defun eshell/zi (&rest args)
  "Jump to directory using interactive zoxide ARGS search."
  (let ((query-result
         (with-temp-buffer
           (apply #'call-process "zoxide" nil t nil
                  (append '("query" "--interactive" "--")
                         args))
           (string-trim (buffer-string)))))
    (when (not (string-empty-p query-result))
      (eshell/cd query-result))))

(defun eshell/nuel (&rest args)
  "Run nushell command and return output as text."
  (let ((command (mapconcat 'identity args " ")))
    (string-trim (shell-command-to-string (format "nu -c '%s | to text'" command)))))

;; Add hook to eshell-post-command-hook
(add-hook 'eshell-post-command-hook #'eshell/zoxide-hook)

;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(provide 'core/eshell)
;;; eshell.el ends here
