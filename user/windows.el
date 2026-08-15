;;; windows.el --- window & buffer management -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Window layout and buffer lifecycle (golden-ratio, neotree, rotate).
;;; Code:

(use-package golden-ratio
  :disabled
  :config
  (setq golden-ratio-extra-commands
        '(
          windmove-left windmove-right windmove-down windmove-up
          evil-window-left evil-window-right evil-window-up evil-window-down
          buf-move-left buf-move-right buf-move-up buf-move-down ace-window)
        golden-ratio-exclude-modes '(ediff-mode)))

(use-package neotree :defer t)

(use-package rotate :defer t)

(provide 'user/windows)
;;; windows.el ends here
