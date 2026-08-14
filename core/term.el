;;; term.el --- term -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; terminals
;;; Code:

(use-package vterm
  :defer t
  :init
  (setq vterm-always-compile-module t)
  :custom
  (vterm-environment '("EDITOR=emacsclient"))
  (vterm-shell "nu --login")
  (shell-file-name "bash")
  (dotimes (i 9)
    (define-key vterm-mode-map (kbd (format "M-%d" (1+ i))) nil)))

(use-package eat
  :commands (eat eat-project eat-project-other-window)
  :hook (eshell-load . eat-eshell-visual-command-mode)
  :custom
  (eat-shell "nu --login"))

(use-package vterm-toggle
    :after vterm
    :defer t
    :custom
    (vterm-toggle-fullscreen-p nil)
    (vterm-toggle-scope 'project)
    :init
    (add-to-list 'display-buffer-alist
                 '((lambda (buffer-or-name _)
                     (let ((buffer (get-buffer buffer-or-name)))
                       (with-current-buffer buffer
                         (or (equal major-mode 'vterm-mode)
                             (string-prefix-p vterm-buffer-name (buffer-name buffer))))))
                   (display-buffer-reuse-window display-buffer-at-bottom)
                   (reusable-frames . visible)
                   (window-height . 0.4))))

(use-package clipetty :hook (elpaca-after-init . global-clipetty-mode))


(provide 'core/term)
;;; term.el ends here
