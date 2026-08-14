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

(defvar pichat-approval-session-rules
  (make-hash-table :test #'eq :weakness 'key)
  "Per-session approval alists keyed weakly by PiChat session objects.")

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

(defun pichat-approval-decision (tool-name &optional session)
  "Return resolved decision for TOOL-NAME and optional SESSION.
An explicit deny at either scope takes precedence over any allow."
  (let ((durable (cdr (assoc tool-name pichat-approval-rules)))
        (local (and session
                    (cdr (assoc tool-name
                                (gethash session pichat-approval-session-rules))))))
    (cond
     ((memq 'deny (list local durable)) 'deny)
     ((memq 'allow (list local durable)) 'allow)
     (t 'ask))))

(defun pichat-approval-set-session (session tool-name decision)
  "Set SESSION-local TOOL-NAME approval DECISION."
  (unless session (error "Session-scoped approval requires a session"))
  (let ((rules (copy-tree (gethash session pichat-approval-session-rules))))
    (setf (alist-get tool-name rules nil nil #'equal) decision)
    (puthash session rules pichat-approval-session-rules)))

(defun pichat-approval-set (tool-name decision)
  "Set TOOL-NAME approval DECISION."
  (setf (alist-get tool-name pichat-approval-rules nil nil #'equal) decision)
  (pichat-approval-save))

(defun pichat-approval-resolve (tool-name mutating-p &optional session)
  "Resolve TOOL-NAME policy without prompting for optional SESSION.
Return `allow', `deny', or `ask'.  An unruled non-mutating tool resolves to
`allow'; only an unruled mutating tool resolves to `ask'."
  (pichat-approval-load)
  (pcase (pichat-approval-decision tool-name session)
    ('allow 'allow)
    ('deny 'deny)
    (_ (if mutating-p 'ask 'allow))))

(defun pichat-approval-prompt (tool-name params &optional session)
  "Prompt for mutating TOOL-NAME with PARAMS in optional SESSION."
  (let ((choice
         (completing-read
          (format "Allow mutating Emacs tool %s with arguments %S? "
                  tool-name params)
          '("Allow once" "Allow for session" "Always allow"
            "Deny once" "Deny for session" "Always deny")
          nil t nil nil "Deny once")))
    (pcase choice
      ("Allow once" t)
      ("Allow for session"
       (pichat-approval-set-session session tool-name 'allow) t)
      ("Always allow" (pichat-approval-set tool-name 'allow) t)
      ("Deny for session"
       (pichat-approval-set-session session tool-name 'deny) nil)
      ("Always deny" (pichat-approval-set tool-name 'deny) nil)
      (_ nil))))

(defun pichat-approval-approve-p (tool-name mutating-p &optional params session)
  "Return non-nil if Emacs TOOL-NAME with PARAMS should run in SESSION.
Non-mutating tools are allowed unless explicitly denied.  Mutating prompts show
arguments and support one-shot, session, and durable exact-tool decisions."
  (pcase (pichat-approval-resolve tool-name mutating-p session)
    ('allow t)
    ('deny nil)
    (_ (pichat-approval-prompt tool-name params session))))

(provide 'pichat-approval)
;;; pichat-approval.el ends here
