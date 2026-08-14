;;; pichat-commands.el --- Pi command picker for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Discover slash commands, prompt templates, and skills through Pi RPC.

;;; Code:

(require 'cl-lib)
(require 'pichat-session)
(require 'pichat-rpc)

(defun pichat-command--prompt-and-run (session commands)
  "Prompt for one of COMMANDS and run it in SESSION.
A quit from either minibuffer prompt cancels the operation silently."
  (when (pichat-session-alive-p session)
    (condition-case nil
        (let* ((choices (mapcar
                         (lambda (cmd)
                           (cons (format "/%s  [%s] %s"
                                         (plist-get cmd :name)
                                         (plist-get cmd :source)
                                         (or (plist-get cmd :description) ""))
                                 cmd))
                         commands))
               (choice (completing-read "Pi command: " choices nil t))
               (cmd (cdr (assoc choice choices)))
               (args (read-string (format "/%s args: " (plist-get cmd :name))))
               (message (string-trim (concat "/" (plist-get cmd :name) " " args))))
          (when (pichat-session-alive-p session)
            (pichat-rpc-prompt session message)))
      (quit nil))))

;;;###autoload
(defun pichat-command-run (&optional session)
  "Pick and run a Pi slash command/template/skill in SESSION."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session (user-error "No current PiChat session"))
    (pichat-rpc-get-commands
     session
     (lambda (response response-session)
       (run-at-time
        0 nil #'pichat-command--prompt-and-run response-session
        (plist-get (plist-get response :data) :commands))))))

(provide 'pichat-commands)
;;; pichat-commands.el ends here
