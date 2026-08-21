;;; pichat-pi-environment.el --- Pi process environment -*- lexical-binding: t; -*-

;;; Commentary:

;; Defines and constructs the additional environment shared by every process
;; PiChat starts to invoke Pi.  The inherited Emacs environment remains
;; unchanged.

;;; Code:

(require 'subr-x)
(require 'pichat-transport)

(defcustom pichat-pi-extra-env nil
  "Additional environment variables supplied to Pi processes.
Each entry is a (NAME . VALUE) pair of strings.  Entries override variables
inherited from Emacs; when NAME occurs more than once, the last entry wins.

The environment is applied to Pi RPC, model-listing, diagnostic probe, and
interactive setup processes.  For wrapper commands, such as Docker, it is the
wrapper process environment; the wrapper remains responsible for forwarding
variables into its runtime."
  :type '(alist :key-type (string :tag "Variable")
                :value-type (string :tag "Value"))
  :group 'pichat)

(defun pichat-pi--validate-extra-env-entry (entry)
  "Return validated Pi environment ENTRY or signal `user-error'."
  (unless (and (consp entry)
               (stringp (car entry))
               (not (string-empty-p (car entry)))
               (not (string-match-p "=" (car entry)))
               (not (string-match-p "\0" (car entry)))
               (stringp (cdr entry))
               (not (string-match-p "\0" (cdr entry))))
    (user-error "Invalid `pichat-pi-extra-env' entry: %S" entry))
  entry)

(defun pichat-pi-process-environment (&optional inherited)
  "Return Pi's process environment based on optional INHERITED environment.
When INHERITED is nil, use `process-environment'.  The returned list is a copy;
neither INHERITED nor the current Emacs environment is modified."
  (let ((process-environment
         (copy-sequence (or inherited process-environment))))
    (dolist (entry pichat-pi-extra-env)
      (pcase-let ((`(,name . ,value)
                   (pichat-pi--validate-extra-env-entry entry)))
        (setenv name value)))
    process-environment))

(defun pichat-pi-getenv (variable)
  "Return VARIABLE from Pi's effective process environment."
  (let ((process-environment (pichat-pi-process-environment)))
    (getenv variable)))

(provide 'pichat-pi-environment)
;;; pichat-pi-environment.el ends here
