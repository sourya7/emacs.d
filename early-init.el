;;; early-init.el --- early-init -  related to editing -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;; Earyly init
;;; Code:
(setq package-enable-at-startup nil)
(setq gc-cons-threshold (* 200 1024 1024))
(setq read-process-output-max (* 1024 1024 4))

(when (boundp 'native-comp-eln-load-path)
  (startup-redirect-eln-cache (expand-file-name ".local/eln-cache/" user-emacs-directory)))

(when (string-equal system-type "android")
  (setq touch-screen-display-keyboard t)
  (setq overriding-text-conversion-style nil)
  (setq elpaca-queue-limit 10)
  ;; Add Termux binaries to PATH environment
  ;; It is important that termuxpath is prepended, not appended.
  ;; Otherwise we will get Androids incompatible diff executable, instead of the one in Termux.
  (let ((termuxpath "/data/data/com.termux/files/usr/bin"))
    (setenv "PATH" (format "%s:%s" termuxpath
                       (getenv "PATH")))
    (push termuxpath exec-path)))

(provide 'early-init)
;;; early-init.el ends here
