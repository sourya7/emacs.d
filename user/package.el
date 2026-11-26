;;; package.el --- Package management -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;; Package management configuration
;;;
;;; Code:

(declare-function my/load-packages "core/package.el")

;; Define packages with conditions.  ISOLATE is passed so a single failing
;; user module is logged and skipped rather than aborting the whole layer.
(my/load-packages
 '(keybindings
   reading
   windows
   ops
   programming
   golang
   java
   pichat
   org
   ;ruby
   ;clojure
   tools
   consult-atuin
   go-template-mode
   helm-yaml-mode
   (work-apps . my/is-work-machine))
 t)

(declare-function my/emacs-main-dir "core/utils.el")

(defun my/load-explorer-modules ()
  "Load the JSON explorer and its plans adapter after Elpaca activation."
  (let ((load-file-name (my/emacs-main-dir "user/package.el")))
    (my/load-packages '(json-explore plans-explore) t)))

;; The generic explorer needs vui on `load-path'; its Elpaca order can
;; still be pending when this file first loads.
(add-hook 'elpaca-after-init-hook #'my/load-explorer-modules)

(provide 'user/package)
;;; package.el ends here
