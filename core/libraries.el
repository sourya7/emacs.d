;;; libraries.el --- support libraries -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Shared support libraries (logging, http, popups) depended on by other
;;; modules.  These are infrastructure, not user-facing applications, so they
;;; live in core to keep the base self-contained.
;;; Code:

(declare-function my/emacs-local-dir "utils.el")

(use-package lgr
  :functions lgr-add-appender lgr-get-logger lgr-appender-file lgr-layout-json
  :config
  (lgr-add-appender
   (lgr-get-logger "lgr--root")
   (lgr-set-layout
    (lgr-appender-file :file (my/emacs-local-dir "emacs.mine.log"))
    (lgr-layout-json))))

(use-package request :defer t
  :custom
  (request-storage-directory (my/emacs-local-dir "request")))

(use-package posframe)

(use-package inheritenv
  :ensure t
  :config)

(provide 'core/libraries)
;;; libraries.el ends here
