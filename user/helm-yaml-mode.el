;;; helm-yaml-mode.el --- helm-yaml-mode -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Helm templates embedded in YAML.
;;; Code:

(declare-function load-relative "load-relative.el")
(declare-function yaml-mode "yaml-mode.el")

(use-package polymode
  :commands helm-template-mode
  :config
  (require 'yaml-mode)
  (require 'load-relative)

  (define-derived-mode helm-yaml-mode yaml-mode "helm-template"
    "Major mode for editing kubernetes helm templates")

  (define-innermode poly-go-template-innermode
    :mode 'go-template-mode
    ;; :mode 'prog-mode
    :head-matcher "{{-?"
    :tail-matcher "-?}}"
    :head-mode 'body
    :tail-mode 'body)

  (define-hostmode poly-helm-template-hostmode :mode 'helm-yaml-mode)
  (define-polymode helm-template-mode
    :hostmode 'poly-helm-template-hostmode
    :innermodes '(poly-go-template-innermode)))

(provide 'user/helm-yaml-mode)
;;; helm-yaml-mode.el ends here
