;;; ops.el --- external tool clients -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Clients and integrations for external CLI tools (docker, kubernetes,
;;; detached processes).
;;; Code:

(declare-function my/emacs-local-dir "utils.el")

(use-package docker :defer t)

(use-package kubel :disabled :defer t)

(use-package kubel-evil :disabled :after kubel)

(defcustom my/detached-notify nil
  "Enable/disable ditached notify."
  :type 'boolean
  :group 'sharmaso)

(use-package detached
  ;; seems promising but doesn't look like its supported actively
  ;; using the forked version https://github.com/LemonBreezes/detached.el
  :ensure (:host github :repo "sourya7/detached.el")
  :functions detached-init
  :init
  (detached-init)
  :bind
  (([remap detached-open-session] . detached-consult-session))
  :custom

  (detached-notification-function #'detached-state-transitionion-echo-message)
  (detached-shell-command-initial-input nil)
  (detached-db-directory (my/emacs-local-dir "detached"))
  (detached-session-directory (my/emacs-local-dir "detached/sessions"))
  (detached-terminal-data-command system-type))

(provide 'user/ops)
;;; ops.el ends here
