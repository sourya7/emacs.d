;;; pichat-response-view.el --- Rendered assistant response views -*- lexical-binding: t; -*-

;;; Commentary:

;; Read-only, snapshot-oriented rendering for canonical assistant prose.  The
;; chat orchestration layer supplies source validation and origin resolution as
;; callbacks; this module does not require or mutate `pichat-chat'.

;;; Code:

(require 'cl-lib)
(require 'dom)
(require 'face-remap)
(require 'shr)
(require 'subr-x)
(require 'pichat-chat-navigation)
(require 'pichat-view)

(declare-function markdown "markdown-mode" (&optional output-buffer-name))
(declare-function markdown-mode "markdown-mode" ())

(defgroup pichat-response-view nil
  "Rendered assistant response views."
  :group 'pichat)

(defface pichat-response-view-heading-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face used for rendered Markdown headings."
  :group 'pichat-response-view)

(defface pichat-response-view-code-face
  '((t :inherit (font-lock-string-face fixed-pitch)))
  "Face used for rendered inline and fenced code."
  :group 'pichat-response-view)

(defface pichat-response-view-blockquote-face
  '((t :inherit font-lock-doc-face :slant italic))
  "Face used for rendered block quotes."
  :group 'pichat-response-view)

(defface pichat-response-view-link-face
  '((t :inherit link))
  "Face used for rendered Markdown links."
  :group 'pichat-response-view)

(defface pichat-response-view-table-face
  '((t :inherit (font-lock-variable-name-face fixed-pitch)))
  "Face used for rendered Markdown tables."
  :group 'pichat-response-view)

(defface pichat-response-view-empty-face
  '((t :inherit shadow :slant italic))
  "Face used when a selected assistant response contains no prose."
  :group 'pichat-response-view)

(defcustom pichat-response-view-convert-function
  #'pichat-response-view--markdown-to-html
  "Function converting one exact Markdown string to an HTML string."
  :type 'function
  :group 'pichat-response-view)

(defvar-local pichat-response-view-response nil
  "Canonical response identity owned by this snapshot view.")

(defvar-local pichat-response-view-source-markdown nil
  "Exact canonical Markdown owned by this snapshot view.")

(defvar-local pichat-response-view-origin-buffer nil
  "Chat buffer from which this response view was opened.")

(defvar-local pichat-response-view-refresh-function nil
  "Origin-buffer callback returning a refreshed canonical response.")

(defvar-local pichat-response-view-return-function nil
  "Origin-buffer callback returning the response's current position.")

(defun pichat-response-view--markdown-to-html (markdown)
  "Convert MARKDOWN to an HTML fragment using `markdown-mode'."
  (unless (require 'markdown-mode nil t)
    (user-error "markdown-mode is unavailable"))
  (let ((output (generate-new-buffer " *PiChat Markdown HTML*")))
    (unwind-protect
        (with-temp-buffer
          (insert markdown)
          (markdown-mode)
          (markdown (buffer-name output))
          (with-current-buffer output
            (buffer-substring-no-properties (point-min) (point-max))))
      (when (buffer-live-p output) (kill-buffer output)))))

(defun pichat-response-view--render-faced-tag (renderer dom face)
  "Render DOM with SHR RENDERER and append FACE to the inserted text."
  (let ((start (point)))
    (funcall renderer dom)
    (when (< start (point))
      (add-face-text-property start (point) face t))))

(defun pichat-response-view--render-blockquote (dom)
  "Render blockquote DOM with a PiChat-specific face."
  (pichat-response-view--render-faced-tag
   #'shr-tag-blockquote dom 'pichat-response-view-blockquote-face))

(defun pichat-response-view--render-pre (dom)
  "Render preformatted DOM with a PiChat-specific face."
  (pichat-response-view--render-faced-tag
   #'shr-tag-pre dom 'pichat-response-view-code-face))

(defun pichat-response-view--render-table (dom)
  "Render table DOM with a PiChat-specific face."
  (pichat-response-view--render-faced-tag
   #'shr-tag-table dom 'pichat-response-view-table-face))

(defun pichat-response-view--html-dom (html)
  "Parse HTML into a DOM suitable for SHR."
  (unless (fboundp 'libxml-parse-html-region)
    (user-error "This Emacs lacks libxml HTML parsing support"))
  (with-temp-buffer
    (insert html)
    (libxml-parse-html-region (point-min) (point-max))))

(defun pichat-response-view--rendered-string (markdown width)
  "Return propertized SHR output for MARKDOWN rendered at WIDTH."
  (if (string-empty-p markdown)
      (propertize "No assistant prose in this response.\n"
                  'face 'pichat-response-view-empty-face)
    (let* ((html (funcall pichat-response-view-convert-function markdown))
           (dom (pichat-response-view--html-dom html)))
      (with-temp-buffer
        (let ((shr-width (and (integerp width) (max 20 width)))
              (shr-max-width nil)
              (shr-inhibit-images t)
              (shr-use-fonts (display-graphic-p))
              (shr-external-rendering-functions
               (append '((blockquote . pichat-response-view--render-blockquote)
                         (pre . pichat-response-view--render-pre)
                         (table . pichat-response-view--render-table))
                       shr-external-rendering-functions)))
          (shr-insert-document dom))
        (buffer-substring (point-min) (point-max))))))

(defun pichat-response-view--display-width (origin)
  "Return an initial rendering width derived from ORIGIN."
  (let ((window (plist-get origin :window)))
    (if (window-live-p window) (window-body-width window) 80)))

(defun pichat-response-view--install-face-remaps ()
  "Install theme-aware SHR face remaps in the current response view."
  (dolist (face '(shr-h1 shr-h2 shr-h3 shr-h4 shr-h5 shr-h6))
    (face-remap-add-relative face 'pichat-response-view-heading-face))
  (face-remap-add-relative 'shr-code 'pichat-response-view-code-face)
  (face-remap-add-relative 'shr-link 'pichat-response-view-link-face))

(defun pichat-response-view--replace-rendering (response width)
  "Transactionally replace this view with RESPONSE rendered at WIDTH."
  (let* ((markdown
          (copy-sequence
           (pichat-chat-navigation-response-markdown response)))
         (rendered (pichat-response-view--rendered-string markdown width))
         (inhibit-read-only t))
    (erase-buffer)
    (insert rendered)
    (goto-char (point-min))
    (setq-local pichat-response-view-response response)
    (setq-local pichat-response-view-source-markdown markdown)
    (set-buffer-modified-p nil)))

(defun pichat-response-view--call-origin (function response operation)
  "Call origin FUNCTION with RESPONSE or reject stale OPERATION."
  (unless (buffer-live-p pichat-response-view-origin-buffer)
    (user-error "PiChat response origin is no longer live; snapshot preserved"))
  (unless (functionp function)
    (user-error "PiChat response view cannot %s; snapshot preserved" operation))
  (with-current-buffer pichat-response-view-origin-buffer
    (funcall function response)))

(defun pichat-response-view-refresh ()
  "Refresh this settled response snapshot from its canonical origin."
  (interactive)
  (let* ((response
          (pichat-response-view--call-origin
           pichat-response-view-refresh-function
           pichat-response-view-response "refresh"))
         (width (window-body-width (selected-window))))
    (unless (pichat-chat-navigation-response-p response)
      (user-error "PiChat response source changed; snapshot preserved"))
    (pichat-response-view--replace-rendering response width)
    (message "PiChat response view refreshed")))

(defun pichat-response-view-copy-markdown ()
  "Copy the exact canonical Markdown owned by this response snapshot."
  (interactive)
  (unless (stringp pichat-response-view-source-markdown)
    (user-error "PiChat response view has no source Markdown"))
  (kill-new pichat-response-view-source-markdown)
  (message "Copied exact response Markdown"))

(defun pichat-response-view-return-to-origin ()
  "Validate this response identity, close the view, and return to its origin."
  (interactive)
  (let ((origin pichat-response-view-origin-buffer)
        (position
         (pichat-response-view--call-origin
          pichat-response-view-return-function
          pichat-response-view-response "return to its origin")))
    (unless (integer-or-marker-p position)
      (user-error "PiChat response source changed; snapshot preserved"))
    (pichat-view-return origin 'kill)
    (when (buffer-live-p origin)
      (goto-char position))))

(defvar pichat-response-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "g") #'pichat-response-view-refresh)
    (define-key map (kbd "t") #'pichat-response-view-return-to-origin)
    (define-key map (kbd "w") #'pichat-response-view-copy-markdown)
    map)
  "Keymap for `pichat-response-view-mode'.")

(define-derived-mode pichat-response-view-mode pichat-view-mode
  "PiChat-Response"
  "Read-only rendered view of one settled canonical assistant response."
  (setq-local truncate-lines nil)
  (visual-line-mode 1)
  (pichat-response-view--install-face-remaps))

(defun pichat-response-view-open
    (response origin refresh-function return-function &optional source-name)
  "Open rendered RESPONSE associated with ORIGIN.
REFRESH-FUNCTION and RETURN-FUNCTION are called in ORIGIN with the response
identity.  SOURCE-NAME is used only to name the snapshot buffer."
  (unless (pichat-chat-navigation-response-p response)
    (error "Invalid canonical PiChat response"))
  (let ((buffer
         (generate-new-buffer
          (format "*PiChat Response: %s*" (or source-name "assistant")))))
    (condition-case error-data
        (progn
          (with-current-buffer buffer
            (pichat-response-view-mode)
            (setq-local pichat-response-view-origin-buffer
                        (plist-get origin :buffer))
            (setq-local pichat-response-view-refresh-function refresh-function)
            (setq-local pichat-response-view-return-function return-function)
            (pichat-response-view--replace-rendering
             response (pichat-response-view--display-width origin)))
          (pichat-view-display buffer origin 'kill))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car error-data) (cdr error-data))))))

(provide 'pichat-response-view)
;;; pichat-response-view.el ends here
