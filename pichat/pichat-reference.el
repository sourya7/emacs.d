;;; pichat-reference.el --- Insert Emacs references into PiChat prompts -*- lexical-binding: t; -*-

;;; Commentary:

;; A lightweight alternative to persistent context: turn the thing at point in
;; Emacs into an explicit reference/snapshot and insert it into a live PiChat
;; prompt.  Pi's own session history and tools remain responsible for retaining
;; and reading the referenced source.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)
(require 'pichat-path)

(defvar pichat-current-session)
(defvar pichat-chat-session)
(defvar pichat-chat--input-start)
(defvar pichat-reference--path-context nil
  "Dynamically bound destination-session path context.")

(declare-function dired-get-marked-files "dired")
(declare-function compilation-goto-error "compile")
(declare-function pichat-chat--insert-prompt "pichat-chat")
(declare-function pichat-session-buffer "pichat-session")
(declare-function pichat-session-path-context "pichat-session")

(defcustom pichat-reference-snapshot-large-threshold 80000
  "Ask before inserting a snapshot larger than this many characters."
  :type 'integer
  :group 'pichat)

(defun pichat-reference--chat-buffers ()
  "Return live PiChat chat buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (derived-mode-p 'pichat-chat-mode)))
   (buffer-list)))

(defun pichat-reference--read-chat-buffer ()
  "Prompt for a PiChat chat buffer."
  (let ((buffers (pichat-reference--chat-buffers)))
    (unless buffers
      (user-error "No live PiChat buffers"))
    (get-buffer
     (completing-read "Insert reference into PiChat buffer: "
                      (mapcar #'buffer-name buffers) nil t))))

(defun pichat-reference--target-buffer (&optional prompt)
  "Return the PiChat buffer to receive a reference.
When PROMPT is non-nil, always ask."
  (cond
   (prompt (pichat-reference--read-chat-buffer))
   ((derived-mode-p 'pichat-chat-mode) (current-buffer))
   ((and (boundp 'pichat-current-session)
         pichat-current-session
         (buffer-live-p (pichat-session-buffer pichat-current-session)))
    (pichat-session-buffer pichat-current-session))
   ((let ((buffers (pichat-reference--chat-buffers)))
      (and (= (length buffers) 1) (car buffers))))
   (t (pichat-reference--read-chat-buffer))))

(defun pichat-reference--runtime-path (path)
  "Return the destination Pi runtime path for Emacs PATH."
  (let* ((expanded (expand-file-name path))
         (resolution
          (pichat-path-resolve-to-runtime
           expanded pichat-reference--path-context)))
    (or (plist-get resolution :path)
        (user-error "Reference path is unavailable to the target runtime: %s"
                    expanded))))

(defun pichat-reference--line-range (beg end)
  "Return cons of 1-based line range for BEG..END."
  (cons (line-number-at-pos beg t)
        (line-number-at-pos (max beg (1- end)) t)))

(defun pichat-reference--code-lang ()
  "Return a code fence language derived from `major-mode'."
  (let ((name (symbol-name major-mode)))
    (setq name (string-remove-suffix "-mode" name))
    (setq name (string-remove-suffix "-ts" name))
    name))

(defun pichat-reference--format-location (path &optional start-line end-line symbol note)
  "Return a prompt reference for PATH and optional START-LINE/END-LINE/SYMBOL/NOTE."
  (let ((loc (pichat-reference--runtime-path path)))
    (concat
     "- `" loc "`"
     (cond
      ((and start-line end-line (/= start-line end-line))
       (format ":%d-%d" start-line end-line))
      (start-line (format ":%d" start-line))
      (t ""))
     (if (and symbol (not (string-empty-p symbol)))
         (format " — `%s`" symbol)
       "")
     (if (and note (not (string-empty-p note)))
         (format " — %s" note)
       ""))))

(defconst pichat-reference--block-heading
  "References for the Pi agent to inspect:"
  "Heading used for prompt reference blocks.")

(defun pichat-reference--format-reference-block (lines)
  "Return reference block for LINES."
  (concat pichat-reference--block-heading "\n"
          (mapconcat #'identity lines "\n")
          "\n\n"))

(defun pichat-reference--reference-lines (text)
  "Return location lines from reference block TEXT, or nil."
  (when (string-prefix-p pichat-reference--block-heading text)
    (cl-remove-if-not
     (lambda (line) (string-prefix-p "- " line))
     (split-string text "\n" t))))

(defun pichat-reference--extract-reference-blocks (text)
  "Return (LINES . REST) after removing prompt reference blocks from TEXT."
  (let ((lines (split-string text "\n"))
        references
        rest)
    (while lines
      (let ((line (pop lines)))
        (if (string= line pichat-reference--block-heading)
            (progn
              (while (and lines (string-prefix-p "- " (car lines)))
                (push (pop lines) references))
              (while (and lines (string-empty-p (car lines)))
                (pop lines)))
          (push line rest))))
    (cons (nreverse references)
          (string-trim-left (string-join (nreverse rest) "\n")))))

(defun pichat-reference--merge-reference-text (input new-text)
  "Return INPUT with NEW-TEXT reference block merged into existing blocks."
  (let ((new-lines (pichat-reference--reference-lines new-text)))
    (if (not new-lines)
        (concat input new-text)
      (pcase-let* ((`(,old-lines . ,rest)
                    (pichat-reference--extract-reference-blocks input))
                   (all-lines (copy-sequence old-lines)))
        (dolist (line new-lines)
          (unless (member line all-lines)
            (setq all-lines (append all-lines (list line)))))
        (if (string-empty-p rest)
            (concat "\n" (pichat-reference--format-reference-block all-lines))
          (concat (string-trim-right rest)
                  "\n\n"
                  (pichat-reference--format-reference-block all-lines)))))))

(defun pichat-reference--confirm-snapshot (label text)
  "Ask before inserting large snapshot TEXT labelled LABEL."
  (when (> (length text) pichat-reference-snapshot-large-threshold)
    (unless (yes-or-no-p
             (format "Insert large PiChat snapshot from %s (%d chars)? "
                     label (length text)))
      (user-error "Snapshot cancelled"))))

(defun pichat-reference--format-snapshot (label text &optional lang)
  "Return prompt snapshot LABEL/TEXT with optional LANG."
  (pichat-reference--confirm-snapshot label text)
  (format "Reference snapshot from `%s`:\n\n````%s\n%s\n````\n\n"
          label (or lang "") text))

(defun pichat-reference--region ()
  "Return reference text for the active region in the current buffer."
  (let ((beg (region-beginning))
        (end (region-end)))
    (if-let ((file (buffer-file-name)))
        (pcase-let ((`(,start . ,finish) (pichat-reference--line-range beg end)))
          (pichat-reference--format-reference-block
           (list (pichat-reference--format-location
                  file start finish (thing-at-point 'symbol t)))))
      (pichat-reference--format-snapshot
       (buffer-name)
       (buffer-substring-no-properties beg end)
       (pichat-reference--code-lang)))))

(defun pichat-reference--dired ()
  "Return reference text for Dired marked files."
  (require 'dired)
  (pichat-reference--format-reference-block
   (mapcar (lambda (file) (pichat-reference--format-location file))
           (dired-get-marked-files))))

(defun pichat-reference--compilation ()
  "Return reference text for the compilation error at point, or nil."
  (require 'compile)
  (let ((diagnostic (string-trim (or (thing-at-point 'line t) "")))
        location)
    (save-window-excursion
      (condition-case nil
          (progn
            (compilation-goto-error)
            (when-let ((file (buffer-file-name)))
              (setq location
                    (pichat-reference--format-location
                     file (line-number-at-pos nil t) nil nil diagnostic))))
        (error nil)))
    (when location
      (pichat-reference--format-reference-block (list location)))))

(defun pichat-reference--defun-or-line ()
  "Return reference text for defun/symbol/current line in a file buffer."
  (let* ((file (buffer-file-name))
         (symbol (thing-at-point 'symbol t))
         (bounds (ignore-errors (bounds-of-thing-at-point 'defun))))
    (if bounds
        (pcase-let ((`(,start . ,finish)
                     (pichat-reference--line-range (car bounds) (cdr bounds))))
          (pichat-reference--format-reference-block
           (list (pichat-reference--format-location file start finish symbol))))
      (pichat-reference--format-reference-block
       (list (pichat-reference--format-location
              file (line-number-at-pos nil t) nil symbol))))))

(defun pichat-reference--buffer-snapshot ()
  "Return snapshot text for the current buffer."
  (pichat-reference--format-snapshot
   (buffer-name)
   (buffer-substring-no-properties (point-min) (point-max))
   (pichat-reference--code-lang)))

(defun pichat-reference--dwim-text ()
  "Return prompt text describing the current Emacs context DWIM."
  (cond
   ((use-region-p) (pichat-reference--region))
   ((derived-mode-p 'dired-mode) (pichat-reference--dired))
   ((derived-mode-p 'compilation-mode) (or (pichat-reference--compilation)
                                           (pichat-reference--buffer-snapshot)))
   ((buffer-file-name) (pichat-reference--defun-or-line))
   (t (pichat-reference--buffer-snapshot))))

(defun pichat-reference--insert-into-chat (buffer text)
  "Insert TEXT into PiChat prompt BUFFER.
Reference blocks are merged with any existing reference block in the live
prompt, so repeated `pichat-add-reference' calls produce one grouped list."
  (with-current-buffer buffer
    (unless (derived-mode-p 'pichat-chat-mode)
      (user-error "Not a PiChat buffer: %s" (buffer-name buffer)))
    (when (fboundp 'pichat-chat--insert-prompt)
      (pichat-chat--insert-prompt))
    (goto-char (point-max))
    (if (and (pichat-reference--reference-lines text)
             (boundp 'pichat-chat--input-start)
             (markerp pichat-chat--input-start)
             (marker-position pichat-chat--input-start))
        (let* ((input (buffer-substring-no-properties
                       pichat-chat--input-start (point-max)))
               (merged (pichat-reference--merge-reference-text input text)))
          (delete-region pichat-chat--input-start (point-max))
          (insert merged))
      (unless (or (bobp) (bolp))
        (insert "\n"))
      (insert text))))

;;;###autoload
(defun pichat-add-reference (&optional prompt-for-chat-buffer)
  "Insert a DWIM reference to the current buffer/region into a PiChat prompt.

With universal prefix PROMPT-FOR-CHAT-BUFFER, ask which PiChat buffer should
receive the reference.  Otherwise choose the target buffer DWIM-style."
  (interactive "P")
  (let* ((target (pichat-reference--target-buffer prompt-for-chat-buffer))
         (pichat-reference--path-context
          (with-current-buffer target
            (and (boundp 'pichat-chat-session)
                 pichat-chat-session
                 (pichat-session-path-context pichat-chat-session))))
         (text (pichat-reference--dwim-text)))
    (pichat-reference--insert-into-chat target text)
    (deactivate-mark)
    (pop-to-buffer target)
    (message "Inserted PiChat reference into %s" (buffer-name target))))

(provide 'pichat-reference)
;;; pichat-reference.el ends here
