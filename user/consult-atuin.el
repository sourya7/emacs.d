;;; consult-atuin.el --- Atuin command history-*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; various ai
;;; Code:

(defgroup consult-atuin nil
  "Consult integration for atuin command history."
  :group 'consult
  :prefix "consult-atuin-")

(defcustom consult-atuin-command "atuin"
  "Command to invoke atuin."
  :type 'string
  :group 'consult-atuin)

(defcustom consult-atuin-args '("history" "list")
  "Arguments for atuin search command."
  :type '(repeat string)
  :group 'consult-atuin)

(defun consult-atuin--history-source ()
  "Get command history from atuin."
  (with-temp-buffer
    (when (zerop (apply #'call-process consult-atuin-command nil t nil
                        consult-atuin-args))
      (split-string (buffer-string) "\n" t))))

(defun consult-atuin--execute-command (query session)
  "Search shell history using atuin with QUERY in SESSION.
Returns a list of matching history entries."
  (when (and query (not (string-empty-p (string-trim query))))
    (let ((process-environment
           (cons (format "ATUIN_SESSION=%s" session) process-environment)))
      (let ((output (shell-command-to-string
                     (format "atuin search --search-mode prefix --cmd-only --print0 %s"
                             query))))
        (when (and output (not (string-empty-p output)))
          (split-string (string-trim output) "\0" t))))))

(defun consult-atuin--read-input ()
  "Request atuin history and read the results."
  (consult--read
   (consult--dynamic-collection
       (lambda (input)
         (let ((atuin-session (shell-command-to-string "atuin uuid")))
           (or (consult-atuin--execute-command input atuin-session) '()))))
   :prompt "Search history: "
   :category 'consult-atuin
   :sort nil
   :history 'consult-atuin--history
   :require-match t))

;;;###autoload
(defun consult-atuin ()
  "Search and execute commands from atuin history."
  (interactive)
  (require 'consult)

  (let* ((shell-cmd (if (fboundp 'detached-shell-command) #'detached-shell-command
                      #'shell-command))
         (input (consult-atuin--read-input)))
    (funcall shell-cmd (format "nu -l -c '%s'" input))))

(provide 'consult-atuin)
;;; consult-atuin.el ends here
