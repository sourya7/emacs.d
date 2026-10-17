;;; pichat-artifacts-embark.el --- Optional typed artifact actions -*- lexical-binding: t; -*-
;;; Commentary:
;; Load after Embark.  Actions take captured strings, never reread point.
;;; Code:
(require 'pichat-chat-artifacts)
(require 'pichat-artifact-runner)
(require 'pichat-response-view)
(require 'pichat-view)
(require 'browse-url)

(defvar pichat-artifacts-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'pichat-view-quit)
    map)
  "Keymap for read-only PiChat artifact previews.")

(define-minor-mode pichat-artifacts-preview-mode
  "Give artifact previews PiChat's owned view lifecycle and quit binding.
A minor mode retains `markdown-mode' for aligned table previews."
  :lighter ""
  :keymap pichat-artifacts-preview-mode-map)

(defun pichat-artifacts-embark-target ()
  "Return a typed target for the settled PiChat artifact at point."
  (when (and (not (use-region-p)) (derived-mode-p 'pichat-chat-mode))
    (when-let* ((item (pichat-chat-artifacts-at-point))
                (artifact (car item)))
      (let ((target (copy-sequence (pichat-artifact-source artifact))))
        (put-text-property 0 (length target) 'pichat-artifact artifact target)
        ;; Embark expects (TYPE TARGET START . END), not a nested bounds pair.
        (cons (intern (format "pichat-%s%s" (pichat-artifact-type artifact)
                              (if (eq (pichat-artifact-type artifact) 'code) "-block" "")))
              (cons target (cons (nth 1 item) (nth 2 item))))))))

(defun pichat-artifacts-embark--descriptor (target)
  "Extract captured descriptor from TARGET."
  (or (get-text-property 0 'pichat-artifact target)
      (user-error "No captured PiChat artifact")))

(defun pichat-artifacts-embark-copy-body (target)
  "Copy the exact body of code TARGET."
  (kill-new (pichat-artifact-payload (pichat-artifacts-embark--descriptor target))))
(defun pichat-artifacts-embark-copy-source (target)
  "Copy exact Markdown TARGET."
  (kill-new (pichat-artifact-source (pichat-artifacts-embark--descriptor target))))
(defun pichat-artifacts-embark--code-mode (language)
  "Return a major mode for fence LANGUAGE, or `text-mode' if unknown.
Use `markdown-mode's customizable language mapping when available."
  (or (and (not (string-empty-p language))
           (require 'markdown-mode nil t)
           (markdown-get-lang-mode language))
      (pcase language
        ((or "python" "python3" "py") (and (fboundp 'python-mode) 'python-mode))
        ((or "javascript" "js" "node") (and (fboundp 'js-mode) 'js-mode))
        ((or "sh" "shell" "bash") (and (fboundp 'sh-mode) 'sh-mode))
        ((or "elisp" "emacs-lisp") 'emacs-lisp-mode))
      'text-mode))

(defun pichat-artifacts-embark-edit (target)
  "Open code TARGET in a separate buffer with its fence language's mode."
  (let* ((artifact (pichat-artifacts-embark--descriptor target))
         (language (downcase (or (pichat-artifact-metadata artifact) "")))
         (buffer (generate-new-buffer "*PiChat Code Edit*")))
    (with-current-buffer buffer
      (insert (pichat-artifact-payload artifact))
      (funcall (pichat-artifacts-embark--code-mode language)))
    (pop-to-buffer buffer)))
(defun pichat-artifacts-embark--focus-result (result origin-window origin)
  "Focus RESULT if Embark restored ORIGIN in ORIGIN-WINDOW after Run.
Do not steal focus after the user has selected another window or changed the
origin window.  Direct runner calls already focus their result normally."
  (when (and (buffer-live-p result)
             (window-live-p origin-window)
             (eq (selected-window) origin-window)
             (eq (window-buffer origin-window) origin))
    (when-let* ((window (get-buffer-window result (window-frame origin-window))))
      (select-window window))))

(defun pichat-artifacts-embark-run (target)
  "Explicitly execute code TARGET outside Pi's tool permission boundary."
  (let* ((artifact (pichat-artifacts-embark--descriptor target))
         (origin (current-buffer))
         (origin-window (selected-window))
         (result (pichat-artifact-runner-run
                  (pichat-artifact-payload artifact)
                  (pichat-artifact-metadata artifact)
                  default-directory)))
    ;; Embark may reselect the target window after the action has displayed
    ;; its result.  Wait until that command finishes before selecting the view.
    (run-at-time 0 nil #'pichat-artifacts-embark--focus-result
                 result origin-window origin)
    result))
(defun pichat-artifacts-embark-copy-link (target)
  "Copy destination of link TARGET."
  (kill-new (pichat-artifact-payload (pichat-artifacts-embark--descriptor target))))
(defun pichat-artifacts-embark-inspect-link (target)
  "Inspect destination of link TARGET."
  (message "%s" (pichat-artifact-payload (pichat-artifacts-embark--descriptor target))))
(defun pichat-artifacts-embark--open-link (target browser)
  "Open link TARGET with BROWSER only when PiChat's scheme policy allows it."
  (let ((url (pichat-artifact-payload (pichat-artifacts-embark--descriptor target))))
    (unless (pichat-response-view--safe-url-p url)
      (user-error "PiChat will not open URL scheme: %s" url))
    (funcall browser url)))
(defun pichat-artifacts-embark-open-link (target)
  "Open link TARGET using the configured browser, subject to scheme policy."
  (pichat-artifacts-embark--open-link target #'browse-url))
(defun pichat-artifacts-embark-open-link-externally (target)
  "Open link TARGET in an external browser, subject to scheme policy."
  (pichat-artifacts-embark--open-link target #'browse-url-default-browser))
(defun pichat-artifacts-embark--prepare-table ()
  "Add outer pipes where needed so `markdown-table-align' sees the table.
Only the private preview buffer is changed; the captured source stays exact."
  (goto-char (point-min))
  (while (not (eobp))
    (unless (looking-at-p "[ \t]*|") (insert "|"))
    (end-of-line)
    (unless (save-excursion
              (skip-chars-backward " \t" (line-beginning-position))
              (eq (char-before) ?|))
      (insert "|"))
    (forward-line 1)))

(defun pichat-artifacts-embark-preview (target)
  "Open read-only TARGET preview, aligning tables with `markdown-mode'."
  (let* ((artifact (pichat-artifacts-embark--descriptor target))
         (table (eq (pichat-artifact-type artifact) 'table))
         (buffer (generate-new-buffer (format "*PiChat %s Preview*" (pichat-artifact-type artifact)))))
    (with-current-buffer buffer
      (insert (pichat-artifact-source artifact))
      (if (and table (require 'markdown-mode nil t))
          (progn
            (markdown-mode)
            (condition-case error-data
                (progn
                  (pichat-artifacts-embark--prepare-table)
                  (goto-char (point-min))
                  (font-lock-ensure)
                  (unless (markdown-table-at-point-p)
                    (error "markdown-mode does not recognize this table"))
                  (markdown-table-align))
              (error
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (insert (pichat-artifact-source artifact)))
               (message "PiChat table alignment unavailable: %s"
                        (error-message-string error-data))))
            (setq buffer-read-only t))
        (special-mode))
      (pichat-artifacts-preview-mode 1)
      (goto-char (point-min))
      (set-buffer-modified-p nil))
    (pichat-view-display buffer nil 'kill)))

(defvar-keymap pichat-code-block-map
  :doc "PiChat code block actions."
  "c" #'pichat-artifacts-embark-copy-body
  "f" #'pichat-artifacts-embark-copy-source
  "e" #'pichat-artifacts-embark-edit
  "r" #'pichat-artifacts-embark-run)
(defvar-keymap pichat-link-map
  :doc "PiChat link actions; no generic URL actions."
  "o" #'pichat-artifacts-embark-open-link
  "x" #'pichat-artifacts-embark-open-link-externally
  "c" #'pichat-artifacts-embark-copy-link
  "?" #'pichat-artifacts-embark-inspect-link)
(defvar-keymap pichat-table-map
  :doc "PiChat table actions."
  "c" #'pichat-artifacts-embark-copy-source
  "p" #'pichat-artifacts-embark-preview)
(defvar-keymap pichat-latex-map
  :doc "PiChat LaTeX actions (source-only preview; no TeX execution)."
  "c" #'pichat-artifacts-embark-copy-source
  "p" #'pichat-artifacts-embark-preview)

(with-eval-after-load 'embark
  (dolist (pair '((pichat-code-block . pichat-code-block-map)
                  (pichat-link . pichat-link-map)
                  (pichat-table . pichat-table-map)
                  (pichat-latex . pichat-latex-map)))
    (add-to-list 'embark-keymap-alist pair))
  (add-to-list 'embark-default-action-overrides
               '(pichat-code-block . pichat-artifacts-embark-copy-body))
  (add-hook 'embark-target-finders #'pichat-artifacts-embark-target))
(provide 'pichat-artifacts-embark)
;;; pichat-artifacts-embark.el ends here
