;;; pichat-permissions.el --- Compatibility facade for PiChat permissions -*- lexical-binding: t; -*-

;;; Commentary:

;; Pi-native permissions are delegated to Pi packages such as
;; pi-permission-gate.  This file exists for Emacs-tool approval compatibility.

;;; Code:

(require 'pichat-approval)

(provide 'pichat-permissions)
;;; pichat-permissions.el ends here
