;;; git.el --- git -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; git
;;; Code:

(use-package majutsu
  :straight (:host github :repo "0WD0/majutsu"))

(use-package git-timemachine
  :after evil
  :hook (evil-normalize-keymaps . git-timemachine-hook)
  :general
  (:states 'normal :keymaps 'git-timemachine-mode-map
           "C-j" 'git-timemachine-show-previous-revision
           "C-k" 'git-timemachine-show-next-revision))

(use-package git-link :defer t)

(use-package magit
  :defer nil
  :after evil
  :hook (with-editor-mode . evil-insert-state)
  :init
  (with-eval-after-load 'magit
    (defun transient-setup-cache (fn &rest args)
      (let ((magit--refresh-cache (list (cons 0 0))))
        (apply fn args)))
    (defun my/magit-rev-parse-safe-advice (orig-fun &rest args)
      "Advice magit to returns nil if Git complains about not being in a work tree."
      (let ((result (apply orig-fun args)))
        (if (and (stringp result)
                 (string-match-p "fatal: this operation must be run in a work tree" result))
            nil
          result)))
    (setq magit-status-headers-hook
          (cl-set-difference magit-status-headers-hook '(magit-insert-tags-header)))
    (advice-add 'transient-setup :around 'transient-setup-cache)
    (advice-add 'magit-rev-parse-safe :around 'my/magit-rev-parse-safe-advice))
  :custom
  (magit-commit-diff-inhibit-same-window t)
  (magit-display-buffer-function #'magit-display-buffer-fullcolumn-most-v1)
  (magit-bury-buffer-function (lambda (_x) (magit-mode-quit-window t))))

(use-package difftastic)

(use-package diff-hl
  :after magit
  :if (not (eq system-type 'android))
  :hook (prog-mode . turn-on-diff-hl-mode)
  :config
  (diff-hl-flydiff-mode 1)
  (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh))

(use-package transient
  :custom
  (transient-levels-file (my/emacs-local-dir "transients/levels.el"))
  (transient-values-file (my/emacs-local-dir "transients/values.el"))
  (transient-history-file (my/emacs-local-dir "transients/history.el")))

(provide 'core/git)
;;; git.el ends here
