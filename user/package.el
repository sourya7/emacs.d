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

(provide 'user/package)
;;; package.el ends here
