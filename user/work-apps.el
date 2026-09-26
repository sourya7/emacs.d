;;; work-apps.el --- work applications -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; work applications
;;; Code:

;; (use-package track-changes)

;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(use-package mise
  :hook (elpaca-after-init . global-mise-mode))



(use-package hurl-mode
  :ensure (:host github :repo "JasZhe/hurl-mode") :defer t)

(provide 'user/work-apps)
;;; work-apps.el ends here
