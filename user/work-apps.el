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

(use-package agent-shell
  :defer t
  :custom
  (agent-shell-preferred-agent-config 'claude-code)
  (agent-shell-session-strategy 'prompt)
  (agent-shell-context-sources '(region error))
  (agent-shell-session-restore-visibility 'full)
  ;(agent-shell-permission-responder-function #'agent-shell-permission-allow-always)
  :config
  (setq agent-shell-anthropic-claude-environment (agent-shell-make-environment-variables :inherit-env t)))

(use-package hurl-mode
  :ensure (:host github :repo "JasZhe/hurl-mode") :defer t)

(provide 'user/work-apps)
;;; work-apps.el ends here
