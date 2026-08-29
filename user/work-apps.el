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
  :custom
  (agent-shell-preferred-agent-config 'claude-code)
  (agent-shell-session-strategy 'prompt)
  (agent-shell-context-sources '(region error))
  :config
  (setq agent-shell-anthropic-claude-environment (agent-shell-make-environment-variables :inherit-env t)))

(provide 'user/work-apps)
;;; work-apps.el ends here
