;;; project.el --- project -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; various project
;;; Code:


;; Local Variables:
;; byte-compile-warnings: (not free-vars unresolved)
;; End:

(use-package ibuffer-vc
  :hook (ibuffer . ibuffer-vc-set-filter-groups-by-vc-root))

(defvar consult-bufferlo--source-buffer
  `(:name "Other Buffers"
    :narrow   ?b
    :category buffer
    :face     consult-buffer
    :history  buffer-name-history
    :state    ,#'consult--buffer-state
    :items ,(lambda () (consult--buffer-query
                        :predicate #'bufferlo-non-local-buffer-p
                        :sort 'visibility
                        :as #'buffer-name)))
    "Non-local buffer candidate source for `consult-buffer'.")

(defvar consult-bufferlo--source-local-buffer
  `(:name "Local Buffers"
    :narrow   ?l
    :category buffer
    :face     consult-buffer
    :history  buffer-name-history
    :state    ,#'consult--buffer-state
    :default  t
    :items ,(lambda () (consult--buffer-query
                        :predicate #'bufferlo-local-buffer-p
                        :sort 'visibility
                        :as #'buffer-name)))
    "Local buffer candidate source for `consult-buffer'.")

(defun my/bufferlo-consult-buffer ()
  "Consult buffer sourced for bufferlo."
  (interactive)
  (let* ((sources
          (list
           'consult-bufferlo--source-local-buffer
           'consult-source-project-recent-file)))
    (consult-buffer sources)))

(use-package bufferlo
  :commands (bufferlo-local-buffer-p bufferlo-tab-close-kill-buffers)
  :custom
  (tab-bar-new-tab-choice "*scratch*")
  :config
  (bufferlo-mode 1)
  (bufferlo-anywhere-mode 1))

(use-package project
  :ensure nil
  :custom
  (project-switch-commands
   '((project-find-file "find file")
     (my/bufferlo-consult-buffer "Project Buffer" "p")
     (consult-ripgrep "Find regexp" "s")
     (project-find-dir "Find directory")
     (project-vc-dir "VC-Dir")
     (project-eshell "Eshell")
     (pichat "PiChat" "P")
     (project-any-command "Other")))
  :config
  (advice-add 'project-switch-project :around #'my/project-switch-project-with-tab))

(provide 'core/project)
;;; project.el ends here
