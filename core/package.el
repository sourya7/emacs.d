;;; package.el --- Package management -*- lexical-binding: t; -*-
;;;
;;; Commentary:
;;; Package management configuration
;;;
;;; Code:

(declare-function load-relative "load-relative")

(defun my/load-packages (packages &optional isolate)
  "Load PACKAGES conditionally based on their configuration.
PACKAGES can be either strings or cons cells of (package . condition).
When ISOLATE is non-nil, load each module in its own `condition-case' so a
single failing module is logged and skipped instead of aborting the rest."
  (let ((to-load '()))
    (dolist (pkg packages)
      (let ((package-name
             (pcase pkg
               ((pred stringp) pkg)
               ((pred symbolp) (symbol-name pkg))
               (`(,(and name (or (pred stringp) (pred symbolp))) . ,condition)
                (when (eval condition)
                  (if (stringp name) name (symbol-name name)))))))
        (when package-name
          (push package-name to-load))))
    (setq to-load (nreverse to-load))
    (if isolate
        (dolist (name to-load)
          (condition-case err
              (load-relative name)
            (error
             (display-warning 'my/load-packages
                              (format "Failed to load module `%s': %S" name err)
                              :error))))
      (load-relative to-load))))

(let ((core-dir (expand-file-name "core/" user-emacs-directory)))
  (load (expand-file-name "utils.el" core-dir))
  (load (expand-file-name "basic-config.el" core-dir))
  (load (expand-file-name "package-manager.el" core-dir))

  (my/load-packages
   '(libraries
     autocomplete
     buffer-move
     editing
     emacs-builtin
     eshell
     fs
     git
     keybinding-managers
     project
     visual-config
     (term . (not (eq system-type 'android))))))

(provide 'core/package)
;;; package.el ends here
