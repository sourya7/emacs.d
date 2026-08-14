;;; pichat-shell-presentation.el --- Pure shell tool presentation -*- lexical-binding: t; -*-

;;; Commentary:

;; Normalize execute-tool commands and outcomes without owning chat buffers or
;; transcript state.  Pi tool updates are cumulative snapshots, so callers pass
;; the latest complete output rather than appending chunks here.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-tool-enrichment)

(defcustom pichat-shell-presentation-enable-compilation-rerun nil
  "When non-nil, allow explicit shell-command reruns via `compilation-start'.
Reruns execute in Emacs's host environment and current `default-directory';
they are never sent through Pi RPC and do not inherit Pi container/SSH setup."
  :type 'boolean
  :group 'pichat)

(defun pichat-shell-presentation-execute-p (record)
  "Return non-nil when enrichment RECORD describes command execution."
  (eq 'execute (plist-get record :kind)))

(defun pichat-shell-presentation-command (record)
  "Return the exact command from enrichment RECORD, or nil."
  (let ((command (plist-get (plist-get record :arguments) :command)))
    (and (stringp command) (not (string-empty-p command)) command)))

(defun pichat-shell-presentation--plist-value (plist keys)
  "Return the first present value in PLIST among KEYS."
  (catch 'found
    (dolist (key keys)
      (when (and (listp plist) (plist-member plist key))
        (throw 'found (plist-get plist key))))))

(defun pichat-shell-presentation--result-text (raw)
  "Return concatenated text content from RAW's result or partial result."
  (let* ((result (or (plist-get raw :result)
                     (plist-get raw :partialResult)))
         (content (and (listp result) (plist-get result :content))))
    (mapconcat
     (lambda (part)
       (if (and (listp part) (stringp (plist-get part :text)))
           (plist-get part :text)
         ""))
     (if (listp content) content nil) "")))

(defun pichat-shell-presentation--terminal-match (regexp text)
  "Return first capture for REGEXP when it matches the end of TEXT."
  (when (string-match (concat regexp "[[:space:]]*\\'") (or text ""))
    (match-string 1 text)))

(defun pichat-shell-presentation-normalize-outcome (raw)
  "Return a normalized execute outcome from Pi tool event RAW.
The returned :kind distinguishes `running', `success', `exit', `signal',
`timeout', and `tool-error'.  Configured timeout arguments are never mistaken
for an observed timeout."
  (let* ((type (plist-get raw :type))
         (result (plist-get raw :result))
         (details (and (listp result) (plist-get result :details)))
         (text (pichat-shell-presentation--result-text raw))
         (explicit-timeout
          (pichat-shell-presentation--plist-value
           details '(:timedOut :timed-out :timed_out)))
         (signal
          (pichat-shell-presentation--plist-value
           details '(:signal :termSignal :term-signal :term_signal)))
         (exit-code
          (pichat-shell-presentation--plist-value
           details '(:exitCode :exit-code :exit_code)))
         (text-timeout
          (pichat-shell-presentation--terminal-match
           "Command timed out after \\([^\n]+\\) seconds" text))
         (text-signal
          (or (pichat-shell-presentation--terminal-match
               "Command terminated by signal \\([^[:space:]\n]+\\)" text)
              (pichat-shell-presentation--terminal-match
               "Command killed by signal \\([^[:space:]\n]+\\)" text)))
         (text-exit
          (pichat-shell-presentation--terminal-match
           "Command exited with code \\(-?[0-9]+\\)" text)))
    (cond
     ((not (equal type "tool_execution_end"))
      (list :kind 'running))
     ((or (eq explicit-timeout t) text-timeout)
      (list :kind 'timeout :duration text-timeout))
     ((or (and (stringp signal) (not (string-empty-p signal))) text-signal)
      (list :kind 'signal :signal (or signal text-signal)))
     ((numberp exit-code)
      (list :kind 'exit :exit-code exit-code))
     (text-exit
      (list :kind 'exit :exit-code (string-to-number text-exit)))
     ((eq t (plist-get raw :isError))
      (list :kind 'tool-error))
     (t (list :kind 'success)))))

(defun pichat-shell-presentation--outcome-rank (outcome)
  "Return monotonic specificity rank for OUTCOME."
  (pcase (plist-get outcome :kind)
    ('running 1)
    ((or 'success 'tool-error) 2)
    ((or 'exit 'signal 'timeout) 3)
    (_ 0)))

(defun pichat-shell-presentation-observe (record raw)
  "Return RECORD with a monotonic execute outcome observed from RAW.
Terminal specific outcomes cannot be erased by stale running updates."
  (if (not (pichat-shell-presentation-execute-p record))
      record
    (let* ((old (plist-get record :shell-outcome))
           (new (pichat-shell-presentation-normalize-outcome raw)))
      (if (> (pichat-shell-presentation--outcome-rank new)
             (pichat-shell-presentation--outcome-rank old))
          (plist-put record :shell-outcome new)
        record))))

(defun pichat-shell-presentation-outcome-label (outcome fallback-status)
  "Return concise OUTCOME label, falling back to FALLBACK-STATUS."
  (pcase (plist-get outcome :kind)
    ('running "running")
    ('success "completed")
    ('exit (format "exit %s" (plist-get outcome :exit-code)))
    ('signal (format "signal %s" (plist-get outcome :signal)))
    ('timeout (if-let ((duration (plist-get outcome :duration)))
                  (format "timed out after %ss" duration)
                "timed out"))
    ('tool-error "tool error")
    (_ (pcase fallback-status
         ((or "running" 'running) "running")
         ((or "error" 'error) "tool error")
         ((or "incomplete" 'incomplete) "incomplete")
         ((or "orphan" 'orphan) "orphaned")
         (_ "completed")))))

(defun pichat-shell-presentation--bounded-command (command limit)
  "Return COMMAND bounded to LIMIT characters."
  (let ((command (or command "[command unavailable]")))
    (if (<= (length command) limit) command
      (concat (substring command 0 limit)
              (format "…[%d chars omitted]" (- (length command) limit))))))

(defun pichat-shell-presentation--truncate-output (text limit notice-format)
  "Return TEXT truncated at LIMIT using NOTICE-FORMAT."
  (let ((text (or text "")))
    (if (<= (length text) limit) text
      (concat (substring text 0 limit)
              (format notice-format (- (length text) limit))))))

(defun pichat-shell-presentation-text
    (record status output state max-command max-output notice-format)
  "Return execute-tool text for RECORD, STATUS, OUTPUT, and display STATE.
MAX-COMMAND and MAX-OUTPUT bound inline presentation.  NOTICE-FORMAT is used
for omitted output.  This is a command record, not an interactive terminal."
  (let* ((state (or state 'output))
         (command (pichat-shell-presentation-command record))
         (title
          (replace-regexp-in-string
           "[[:space:]\n\r]+" " "
           (string-trim
            (or (plist-get record :title)
                command
                (plist-get record :name)
                "command"))))
         (outcome (pichat-shell-presentation-outcome-label
                   (plist-get record :shell-outcome) status))
         (header
          (propertize (format "[execute: %s — %s]" title outcome)
                      'font-lock-face 'pichat-tool-label-face))
         (command-section
          (format "Command (non-interactive):\n%s"
                  (pichat-shell-presentation--bounded-command
                   command max-command))))
    (pcase state
      ('summary (concat header "\n"))
      ('args (format "%s\n%s\n" header command-section))
      (_
       (format "%s\n%s\nOutput:\n%s\n"
               header command-section
               (pichat-shell-presentation--truncate-output
                output max-output notice-format))))))

(provide 'pichat-shell-presentation)
;;; pichat-shell-presentation.el ends here
