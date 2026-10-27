;;; pichat-artifact-elisp.el --- In-process artifact evaluation -*- lexical-binding: t; -*-
;;; Commentary:
;; Explicit user action: evaluates in this Emacs, never in Pi or a subprocess.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'lisp-mode)
(require 'pichat-artifact-result)

(defgroup pichat-artifact-elisp nil
  "In-process PiChat Emacs Lisp execution."
  :group 'pichat)
(defcustom pichat-artifact-elisp-output-limit 65536
  "Maximum captured output characters for an Elisp artifact run."
  :type 'integer :group 'pichat-artifact-elisp)
(defvaralias 'pichat-artifact-elisp-share-limit
  'pichat-artifact-result-share-limit
  "Compatibility name for the shared code-run report limit.")

(cl-defstruct pichat-artifact-elisp-result
  code directory output value error status origin token)
(defvar-local pichat-artifact-elisp--result nil)

(defun pichat-artifact-elisp--collector (limit)
  "Return (WRITER . TEXT) capturing at most LIMIT characters.
TEXT is a function to call when capturing is complete; WRITER is suitable for
`standard-output'.  Neither writes to the evaluation buffer."
  (let ((buffer (generate-new-buffer " *PiChat Elisp output*"))
        (count 0) (truncated nil))
    (cons (lambda (chunk)
            (let* ((text (if (characterp chunk) (char-to-string chunk) chunk))
                   (remaining (max 0 (- limit count))))
              (when (> (length text) remaining) (setq truncated t))
              (when (> remaining 0)
                (with-current-buffer buffer
                  (insert (substring text 0 (min remaining (length text)))))
                (setq count (+ count (min remaining (length text)))))))
          (lambda ()
            (unwind-protect
                (concat (with-current-buffer buffer (buffer-string))
                        (if truncated "\n[Output truncated]\n" ""))
              (kill-buffer buffer))))))

(defun pichat-artifact-elisp--evaluate (code directory origin token)
  "Evaluate CODE in this Emacs and return a result tied to ORIGIN and TOKEN."
  (let* ((scratch (generate-new-buffer " *PiChat Elisp eval*"))
         (output (pichat-artifact-elisp--collector
                  (max 0 pichat-artifact-elisp-output-limit)))
         (value-output nil) (output-consumed nil) (value-consumed nil)
         (status 'ok) (failure nil) (value nil) (seen nil))
    (unwind-protect
        (progn
          (condition-case err
              (with-current-buffer scratch
                (setq default-directory directory)
                (insert code)
                (goto-char (point-min))
                ;; No major-mode hooks, file-local variables or chat-buffer
                ;; bindings; lexical scope is chosen explicitly for each form.
                (with-syntax-table emacs-lisp-mode-syntax-table
                  (let ((standard-output (car output)))
                    (while (progn (forward-comment (point-max)) (not (eobp)))
                      (setq value (eval (read (current-buffer)) t)
                            seen t)))))
            (quit (setq status 'quit failure "Evaluation quit"))
            (error (setq status 'error
                         failure (if (eq (car err) 'error)
                                     (error-message-string err)
                                   (format "%s: %s" (car err)
                                           (error-message-string err))))))
          (when (eq status 'ok)
            (setq value-output (pichat-artifact-elisp--collector
                                (max 0 pichat-artifact-elisp-output-limit)))
            (condition-case err
                (let ((standard-output (car value-output))
                      (print-circle t) (print-length 30) (print-level 8)
                      (print-escape-newlines t))
                  (prin1 (if seen value nil)))
              (error (setq status 'error
                           failure (format "Printing result failed (%s): %s"
                                           (car err) (error-message-string err))))))
          (make-pichat-artifact-elisp-result
           :code code :directory directory :origin origin :token token
           :output (prog1 (funcall (cdr output)) (setq output-consumed t))
           :value (when value-output
                    (prog1 (funcall (cdr value-output))
                      (setq value-consumed t)))
           :error failure :status status))
      (when (buffer-live-p scratch) (kill-buffer scratch))
      (unless output-consumed (funcall (cdr output)))
      (when (and value-output (not value-consumed))
        (funcall (cdr value-output))))))

(defun pichat-artifact-elisp--outcome-label (result)
  "Return the outcome label for RESULT."
  (pcase (pichat-artifact-elisp-result-status result)
    ('ok "Last value")
    ('quit "Quit")
    (_ "Error")))

(defun pichat-artifact-elisp--outcome-text (result)
  "Return the value or failure text for RESULT."
  (if (eq (pichat-artifact-elisp-result-status result) 'ok)
      (pichat-artifact-elisp-result-value result)
    (pichat-artifact-elisp-result-error result)))

(defun pichat-artifact-elisp--report (result)
  "Make a bounded agent-facing report for RESULT."
  (format "Emacs Lisp run in my current Emacs (private evaluation buffer; cwd: %s)\nStatus: %s\nCode:\n%s\nPrinted output:\n%s\n%s: %s"
          (pichat-artifact-result-bounded
           (pichat-artifact-elisp-result-directory result))
          (pichat-artifact-elisp-result-status result)
          (pichat-artifact-result-bounded (pichat-artifact-elisp-result-code result))
          (pichat-artifact-result-bounded (pichat-artifact-elisp-result-output result))
          (pichat-artifact-elisp--outcome-label result)
          (pichat-artifact-result-bounded
           (or (pichat-artifact-elisp--outcome-text result) ""))))

(define-derived-mode pichat-artifact-elisp-result-mode pichat-artifact-result-mode
  "PiChat-Elisp-Result" "Read-only result of an explicit in-process Elisp run.")

(defun pichat-artifact-elisp-run (code directory &optional origin)
  "Evaluate CODE in this Emacs, with DIRECTORY as cwd, from ORIGIN chat.
Unlike subprocess runners, this is synchronous and has no timeout."
  (let* ((origin (or origin (current-buffer)))
         (token (and (buffer-live-p origin)
                     (with-current-buffer origin
                       (when (derived-mode-p 'pichat-chat-mode)
                         (pichat-chat--source-token)))))
         (result (pichat-artifact-elisp--evaluate code directory origin token))
         (buffer (generate-new-buffer "*PiChat Elisp Run*")))
    (with-current-buffer buffer
      (insert (format "Cwd: %s\n\nCode:\n%s\n\nOutput:\n%s\n\n%s: %s\n\n[s] Share  [w / g y] Copy  [q] Quit\n"
                      directory code
                      (let ((output (pichat-artifact-elisp-result-output result)))
                        (if (string-empty-p output) "(none)" output))
                      (pichat-artifact-elisp--outcome-label result)
                      (or (pichat-artifact-elisp--outcome-text result) "")))
      (pichat-artifact-elisp-result-mode)
      (setq-local pichat-artifact-elisp--result result)
      (pichat-artifact-result-setup
       origin token (lambda () (pichat-artifact-elisp--report result))))
    (pichat-view-display buffer nil 'kill)))

(provide 'pichat-artifact-elisp)
;;; pichat-artifact-elisp.el ends here
