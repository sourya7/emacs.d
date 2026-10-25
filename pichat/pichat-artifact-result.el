;;; pichat-artifact-result.el --- Share explicit code-run results -*- lexical-binding: t; -*-
;;; Commentary:
;; Runner-specific execution and reporting remain in their respective modules.
;; This module owns the common view actions and source-safe prompt insertion.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-chat)
(require 'pichat-view)

(defgroup pichat-artifact-result nil
  "Sharing PiChat code-run results with a chat draft." :group 'pichat)
(defcustom pichat-artifact-result-share-limit 4000
  "Maximum characters per section of a code-run report inserted into a draft."
  :type 'integer :group 'pichat-artifact-result)

(defvar pichat-artifact-result--handoff-context nil
  "Dynamically bound (ORIGIN TOKEN) for an explicitly captured artifact action.
Execution may outlive or occur outside ORIGIN; never recapture its new source.")

(defvar-local pichat-artifact-result--origin nil)
(defvar-local pichat-artifact-result--token nil)
(defvar-local pichat-artifact-result--report-function nil)
(defvar-local pichat-artifact-result--ready-function nil)

(defun pichat-artifact-result-source-token (origin)
  "Capture ORIGIN's chat source identity, or nil if it is not a chat."
  (when (buffer-live-p origin)
    (with-current-buffer origin
      (when (derived-mode-p 'pichat-chat-mode)
        (pichat-chat--source-token)))))

(defun pichat-artifact-result-setup (origin token report-function &optional ready-function)
  "Set up this result view for ORIGIN, TOKEN and REPORT-FUNCTION.
REPORT-FUNCTION runs in the result buffer and returns a bounded report.
READY-FUNCTION, when non-nil, must return non-nil before sharing is allowed.
Copy remains available while a run is active or its origin has changed."
  (setq-local pichat-artifact-result--origin
              (if pichat-artifact-result--handoff-context
                  (car pichat-artifact-result--handoff-context) origin)
              pichat-artifact-result--token
              (if pichat-artifact-result--handoff-context
                  (cadr pichat-artifact-result--handoff-context) token)
              pichat-artifact-result--report-function report-function
              pichat-artifact-result--ready-function ready-function))

(defun pichat-artifact-result-bounded (text)
  "Return TEXT bounded for sharing, with an explicit truncation marker."
  (let ((limit (max 0 pichat-artifact-result-share-limit)))
    (if (> (length text) limit)
        (concat (substring text 0 limit) "\n[Section truncated for sharing]")
      text)))

(defun pichat-artifact-result--report ()
  "Return this view's current report, or signal if no report is available."
  (unless (functionp pichat-artifact-result--report-function)
    (user-error "No code-run result in this buffer"))
  (funcall pichat-artifact-result--report-function))

(defun pichat-artifact-result-copy-report ()
  "Copy the bounded result report, including partial results from active runs."
  (interactive)
  (kill-new (pichat-artifact-result--report))
  (message "Copied PiChat code-run result"))

(defun pichat-artifact-result-share ()
  "Insert this finished result into its originating chat draft without sending."
  (interactive)
  (let ((report (pichat-artifact-result--report))
        (origin pichat-artifact-result--origin)
        (token pichat-artifact-result--token))
    (when (and pichat-artifact-result--ready-function
               (not (funcall pichat-artifact-result--ready-function)))
      (user-error "Code run is active; wait to share, or copy with w (g y in Evil)"))
    (unless (and (buffer-live-p origin)
                 (with-current-buffer origin
                   (and (derived-mode-p 'pichat-chat-mode)
                        (equal token (pichat-chat--source-token)))))
      (user-error "Originating PiChat source changed; copy with w (g y in Evil)"))
    (with-current-buffer origin
      (pichat-chat--insert-prompt)
      (let ((old (buffer-substring-no-properties
                  pichat-chat--input-start (point-max))))
        (pichat-chat--set-input-text
         (concat old (if (string-empty-p old) "" "\n\n") report))))
    (pichat-view-return origin 'kill)
    (message "Inserted code-run result in draft; review and send explicitly")))

(defvar-keymap pichat-artifact-result-mode-map
  :parent pichat-view-mode-map
  "s" #'pichat-artifact-result-share
  "w" #'pichat-artifact-result-copy-report)
(define-derived-mode pichat-artifact-result-mode pichat-view-mode
  "PiChat-Code-Result" "Read-only result of an explicit code run.")

(provide 'pichat-artifact-result)
;;; pichat-artifact-result.el ends here
