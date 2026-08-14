;;; fs.el --- fs -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; various fs
;;; Code:

(use-package dired-open
  :custom
  (dired-open-extensions '(("gif" . "sxiv")
                           ("jpg" . "sxiv")
                           ("png" . "sxiv")
                           ("mkv" . "mpv")
                           ("mp4" . "mpv"))))

(use-package trashed
  :commands trashed
  :custom
  (trashed-action-confirmer 'y-or-n-p)
  (trashed-use-header-line t)
  (trashed-sort-key '("Date deleted" . t))
  (trashed-date-format "%Y-%m-%d %H:%M:%S"))

(use-package sudo-edit :defer t)

(use-package zoxide)

(use-package envrc
  :hook (elpaca-after-init . envrc-global-mode)
  :config
  (advice-add 'shell-command-to-string :around 'envrc-propagate-environment)
  :custom
  (envrc-show-summary-in-minibuffer nil)
  (exec-path-from-shell-shell-name "bash"))

(provide 'core/fs)
;;; fs.el ends here
