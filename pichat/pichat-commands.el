;;; pichat-commands.el --- Pi command picker for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Discover slash commands, prompt templates, and skills through Pi RPC.

;;; Code:

(require 'cl-lib)
(require 'pichat-session)
(require 'pichat-backend)
(require 'pichat-command-catalog)

(defun pichat-command--capture-context (session)
  "Return a predicate validating SESSION's current discovery/action context.
Submission requires the same process lifetime and Pi source.  If a chat owns
SESSION, also retain its buffer ownership and source generation, without
requiring the chat module for callers that have no chat."
  (let* ((process (pichat-session-process session))
         (generation (pichat-session-process-generation session))
         (id (pichat-session-id session))
         (file (pichat-session-session-file session))
         (buffer (pichat-session-buffer session))
         (chat-p (and (buffer-live-p buffer)
                      (local-variable-p 'pichat-chat-session buffer)
                      (local-variable-p 'pichat-chat--source-generation buffer)))
         (source-generation
          (and chat-p (buffer-local-value 'pichat-chat--source-generation buffer))))
    (lambda ()
      (and (pichat-session-alive-p session)
           (eq process (pichat-session-process session))
           (equal generation (pichat-session-process-generation session))
           (equal id (pichat-session-id session))
           (equal file (pichat-session-session-file session))
           (eq buffer (pichat-session-buffer session))
           (or (null buffer) (buffer-live-p buffer))
           (or (not chat-p)
               (and (local-variable-p 'pichat-chat-session buffer)
                    (local-variable-p 'pichat-chat--source-generation buffer)
                    (eq session (buffer-local-value 'pichat-chat-session buffer))
                    (equal source-generation
                           (buffer-local-value 'pichat-chat--source-generation buffer))))))))

(defun pichat-command--current-p (current-p)
  "Check CURRENT-P and explain why stale command work was cancelled."
  (if (funcall current-p) t
    (message "Pi command cancelled: runtime or source changed; invoke the picker again")
    nil))

(defun pichat-command--prompt-and-run (session commands &optional current-p)
  "Prompt for one of COMMANDS and run it in SESSION while CURRENT-P holds.
CURRENT-P retains the context captured before command discovery; direct calls
capture it before prompting.  Quit at either prompt cancels silently."
  (let ((current-p (or current-p (pichat-command--capture-context session))))
    (when (and commands (pichat-command--current-p current-p))
      (condition-case nil
          (let* ((choice (completing-read
                          "Pi command: /" (pichat-command-catalog-table commands) nil t))
                 (cmd (cl-find choice commands
                               :key (lambda (record) (plist-get record :name))
                               :test #'equal))
                 (args (and cmd (pichat-command--current-p current-p)
                            (read-string (format "/%s args: " (plist-get cmd :name)))))
                 (message (and args
                               (string-trim (concat "/" (plist-get cmd :name) " " args)))))
            (when (and message (pichat-command--current-p current-p))
              (pichat-backend-submit-prompt session message)))
        (quit nil)))))

;;;###autoload
(defun pichat-command-run (&optional session)
  "Pick and run a Pi slash command/template/skill in SESSION."
  (interactive)
  (let ((session (pichat-session-current session)))
    (unless session (user-error "No current PiChat session"))
    (pichat-backend-require-capability session 'commands "Pi commands")
    (let ((current-p (pichat-command--capture-context session)))
      (pichat-command-catalog-fetch
       session
       (lambda (commands response-session)
         (when (and (eq session response-session)
                    (pichat-command--current-p current-p))
           (if commands
               (run-at-time
                0 nil #'pichat-command--prompt-and-run session commands current-p)
             (message "No Pi commands available"))))
       (lambda (_response response-session)
         (when (and (eq session response-session)
                    (pichat-command--current-p current-p))
           (message "Pi command discovery failed; invoke the picker again")))))))

(provide 'pichat-commands)
;;; pichat-commands.el ends here
