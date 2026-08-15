;;; libraries.el --- support libraries -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Shared support libraries depended on by other modules.  These are
;;; infrastructure, not user-facing applications, so they live in core to keep
;;; the base self-contained.
;;; Code:

(declare-function my/emacs-local-dir "utils.el")

(use-package request :defer t
  :custom
  (request-storage-directory (my/emacs-local-dir "request")))

(use-package inheritenv
  :ensure t
  :config)

(provide 'core/libraries)
;;; libraries.el ends here
