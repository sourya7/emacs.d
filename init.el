;;; init.el --- main entrypoint for emacs -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;; init config
;;; Code:

(defun efs/display-startup-time ()
  "Output the Emacs startup time and restore runtime GC thresholds."
  (message "Emacs loaded in %s with %d garbage collections."
           (format "%.2f seconds"
                   (float-time
                    (time-subtract after-init-time before-init-time)))
           gcs-done)
  (setq gc-cons-threshold (* 32 1024 1024)
        gc-cons-percentage 0.1))

(add-hook 'emacs-startup-hook #'efs/display-startup-time)

(let ((file-name-handler-alist nil))
  (load (expand-file-name "core/package.el" user-emacs-directory))
  (load (expand-file-name "user/package.el" user-emacs-directory) 'noerror))

(provide 'init)
;;; init.el ends here
