;;; pichat-approval.el --- Approval policies for PiChat Emacs tools -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defcustom pichat-approval-policy-file
  (locate-user-emacs-file "pichat-approvals.el")
  "File storing durable PiChat approval decisions."
  :type 'file
  :group 'pichat)

(defvar pichat-approval-rules nil
  "Durable approval rules as alist of (TOOL-NAME . DECISION).")

(defconst pichat-approval-arguments-limit 300
  "Maximum characters of raw arguments shown in an approval prompt.")

(defconst pichat-approval-choices '("Allow once" "Always allow" "Deny")
  "Approval prompt choices.  Only *Always allow* stores a rule.")

(defun pichat-approval-load ()
  "Load valid approval rules from `pichat-approval-policy-file'.
Missing, empty, or malformed policy data safely resets to ask-by-default."
  (setq pichat-approval-rules nil)
  (when (file-exists-p pichat-approval-policy-file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents pichat-approval-policy-file)
          (let ((rules (read (current-buffer))))
            (when (and (listp rules)
                       (cl-every (lambda (rule)
                                   (and (consp rule)
                                        (stringp (car rule))
                                        (memq (cdr rule) '(allow deny ask))))
                                 rules))
              (setq pichat-approval-rules rules))))
      (error nil))))

(defun pichat-approval-save ()
  "Persist approval rules with an atomic same-directory replacement."
  (let* ((directory (or (file-name-directory pichat-approval-policy-file)
                        default-directory))
         (prefix (expand-file-name ".pichat-approvals-" directory))
         temporary)
    (make-directory directory t)
    (unwind-protect
        (progn
          (setq temporary (make-temp-file prefix))
          (with-temp-file temporary
            (prin1 pichat-approval-rules (current-buffer)))
          (set-file-modes temporary #o600)
          (rename-file temporary pichat-approval-policy-file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun pichat-approval-decision (tool-name)
  "Return the stored decision for TOOL-NAME: `allow', `deny' or `ask'."
  (pcase (cdr (assoc tool-name pichat-approval-rules))
    ('allow 'allow)
    ('deny 'deny)
    (_ 'ask)))

(defun pichat-approval-set (tool-name decision)
  "Set TOOL-NAME approval DECISION."
  (setf (alist-get tool-name pichat-approval-rules nil nil #'equal) decision)
  (pichat-approval-save))

(defun pichat-approval-resolve (tool-name mutating-p)
  "Resolve TOOL-NAME policy without prompting.
Return `allow', `deny', or `ask'.  An unruled non-mutating tool resolves to
`allow'; only an unruled mutating tool resolves to `ask'."
  (pichat-approval-load)
  (pcase (pichat-approval-decision tool-name)
    ('allow 'allow)
    ('deny 'deny)
    (_ (if mutating-p 'ask 'allow))))

(defun pichat-approval--arguments-text (params)
  "Return PARAMS printed on one line in `pichat-approval-arguments-limit' chars.
A cut text ends with a marker counting the omitted characters."
  (let ((text (replace-regexp-in-string
               "[[:cntrl:]]+" " "
               (let ((print-escape-newlines t)
                     (print-length nil)
                     (print-level nil))
                 (prin1-to-string params))))
        (limit pichat-approval-arguments-limit))
    (if (<= (length text) limit)
        text
      ;; The marker is at most 30 characters; keep the whole within LIMIT.
      (let ((kept (- limit 30)))
        (format "%s… [%d more characters]"
                (substring text 0 kept) (- (length text) kept))))))

(defun pichat-approval-prompt (tool-name params &optional summary)
  "Prompt for mutating TOOL-NAME with PARAMS; return non-nil to run it.
Optional SUMMARY is the tool's one-line description of this call, or a
function returning it; it comes first, then the bounded raw arguments.
Only *Always allow* stores a rule.  Quitting the prompt means *Deny*."
  (let* ((summary (if (functionp summary) (funcall summary) summary))
         (choice
          (condition-case nil
              (completing-read
               (format "%sEmacs tool %s, arguments %s. Allow? "
                       (if summary (format "%s — " summary) "")
                       tool-name (pichat-approval--arguments-text params))
               pichat-approval-choices nil t nil nil "Deny")
            (quit "Deny"))))
    (pcase choice
      ("Allow once" t)
      ("Always allow" (pichat-approval-set tool-name 'allow) t)
      (_ nil))))

(defun pichat-approval-approve-p (tool-name mutating-p &optional params summary)
  "Return non-nil if Emacs TOOL-NAME with PARAMS should run.
Non-mutating tools are allowed unless explicitly denied.  Mutating tools
without a stored rule prompt, showing SUMMARY (when non-nil) and arguments."
  (pcase (pichat-approval-resolve tool-name mutating-p)
    ('allow t)
    ('deny nil)
    (_ (pichat-approval-prompt tool-name params summary))))

(provide 'pichat-approval)
;;; pichat-approval.el ends here
