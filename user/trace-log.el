;;; trace-log.el --- Log cursor locations with annotations to an org buffer  -*- lexical-binding: t; -*-

;;; Commentary:
;; Use `trace-log-push' (bound to your preferred key) to append the current
;; file/buffer location to an Org trace buffer.  With prefix arg, prompts
;; for an annotation.  Resulting org buffer has clickable links.

;;; Code:

(defgroup trace-log nil
  "Log code locations to an org trace buffer."
  :group 'convenience)

(defcustom trace-log-buffer-name "*trace-log*"
  "Name of the org buffer used for the trace log."
  :type 'string)

(defcustom trace-log-file nil
  "If non-nil, a file path to persist the trace log.
When nil, uses an in-memory buffer."
  :type '(choice (const nil) file))

(defun trace-log--get-buffer ()
  "Get or create the trace log buffer."
  (let ((buf (if trace-log-file
                 (find-file-noselect trace-log-file)
               (get-buffer-create trace-log-buffer-name))))
    (with-current-buffer buf
      (unless (derived-mode-p 'org-mode)
        (org-mode)))
    buf))

(defun trace-log--make-link ()
  "Return an org link string for the current location."
  (let* ((file (buffer-file-name))
         (line (line-number-at-pos))
         (col  (current-column))
         (name (buffer-name))
         (context (string-trim
                   (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position)))))
    (if file
        (format "[[file:%s::%d][%s:%d]] ~%s~"
                file line
                (file-name-nondirectory file) line
                (truncate-string-to-width context 80 nil nil "…"))
      ;; Non-file buffer: use a buffer link (may go stale)
      (format "[[elisp:(when (get-buffer \"%s\") (switch-to-buffer \"%s\") (goto-line %d))][%s:%d]] ~%s~"
              name name line
              name line
              (truncate-string-to-width context 80 nil nil "…")))))

;;;###autoload
(defun trace-log-push (arg)
  "Push the current location to the trace log.
With prefix ARG, prompt for an annotation."
  (interactive "P")
  (let* ((link (trace-log--make-link))
         (annotation (when arg
                       (read-string "Annotation: ")))
         (entry (concat "- " (format-time-string "[%H:%M:%S] ")
                        link
                        (when (and annotation (not (string-empty-p annotation)))
                          (concat "\n  - " annotation))
                        "\n")))
    (with-current-buffer (trace-log--get-buffer)
      (goto-char (point-max))
      (insert entry)
      (message "Traced: %s" (truncate-string-to-width entry 70 nil nil "…")))))

;;;###autoload
(defun trace-log-show ()
  "Display the trace log buffer."
  (interactive)
  (pop-to-buffer (trace-log--get-buffer)))

;;;###autoload
(defun trace-log-new-session ()
  "Insert a new session heading in the trace log."
  (interactive)
  (let ((title (read-string "Session title: " nil nil
                            (format-time-string "Trace %Y-%m-%d %H:%M"))))
    (with-current-buffer (trace-log--get-buffer)
      (goto-char (point-max))
      (insert (format "\n* %s\n" title)))
    (message "New session: %s" title)))

;;;###autoload
(defun trace-log-clear ()
  "Clear the trace log buffer."
  (interactive)
  (when (yes-or-no-p "Clear trace log? ")
    (with-current-buffer (trace-log--get-buffer)
      (erase-buffer))
    (message "Trace log cleared.")))

(provide 'trace-log)
;;; trace-log.el ends here
