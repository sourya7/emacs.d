;;; pichat-reference.el --- Insert Emacs references into PiChat prompts -*- lexical-binding: t; -*-

;;; Commentary:

;; A lightweight alternative to persistent context: turn the thing at point in
;; Emacs into an explicit file reference and insert it into a live PiChat prompt.
;; Pi's own session history and tools remain responsible for retaining and
;; reading the referenced source.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)
(require 'pichat-path)

(defvar pichat-chat-session)
(defvar pichat-reference--path-context nil
  "Dynamically bound destination-session path context.")
(defvar pichat-reference--transport nil
  "Dynamically bound destination-session transport.")
(declare-function dired-get-marked-files "dired")
(declare-function compilation-goto-error "compile")
(declare-function pichat-chat-draft-capture "pichat-chat" (&optional buffer source-token))
(declare-function pichat-chat-draft-current-p "pichat-chat" (target))
(declare-function pichat-chat-draft-text "pichat-chat" (target))
(declare-function pichat-chat-draft-replace "pichat-chat" (target text &optional point-offset))
(declare-function bufferlo-local-buffer-p "bufferlo" (buffer &optional frame tabnum include-hidden))
(declare-function pichat--project-root "pichat" (&optional directory))
(declare-function pichat--scope-for-directory "pichat" (&optional directory force-global target-id))
(declare-function pichat-session-buffer "pichat-session")
(declare-function pichat-session-owner-scope-key "pichat-session")
(declare-function pichat-session-path-context "pichat-session")
(declare-function pichat-session-transport "pichat-session")

(defcustom pichat-reference-snapshot-large-threshold 80000
  "Ask before writing a temporary reference larger than this many characters."
  :type 'integer
  :group 'pichat)

(defcustom pichat-reference-temp-directory nil
  "Directory for non-file references, or nil for the runtime's temp directory.
With nil, local runtimes use `temporary-file-directory' and SSH runtimes use
remote /tmp through TRAMP.  An explicit directory must be shared with or
mapped to Pi.  PiChat does not remove the files; cleanup follows the chosen
directory's OS policy."
  :type '(choice (const :tag "Emacs temporary directory" nil)
                 (directory :tag "Runtime-accessible directory"))
  :group 'pichat)

(defun pichat-reference--chat-buffers ()
  "Return live PiChat chat buffers."
  (cl-remove-if-not
   (lambda (buffer)
     (with-current-buffer buffer
       (derived-mode-p 'pichat-chat-mode)))
   (buffer-list)))

(defun pichat-reference--read-chat-buffer (&optional buffers)
  "Prompt for a chat among BUFFERS, or all live chats when nil."
  (let ((buffers (or buffers (pichat-reference--chat-buffers))))
    (unless buffers
      (user-error "No live PiChat buffers"))
    (get-buffer
     (completing-read "Insert reference into PiChat buffer: "
                      (mapcar #'buffer-name buffers) nil t))))

(defun pichat-reference--choose-chat (buffers)
  "Choose a chat from BUFFERS, prompting if ambiguous."
  (if (= (length buffers) 1)
      (car buffers)
    (pichat-reference--read-chat-buffer buffers)))

(defun pichat-reference--target-buffer (&optional prompt)
  "Return the chat to receive a reference; PROMPT always asks explicitly.
When Bufferlo is enabled, only chats local to the selected tab are
selected implicitly.  Otherwise use the source project scope."
  (let ((buffers (pichat-reference--chat-buffers)))
    (cond
     (prompt (pichat-reference--read-chat-buffer buffers))
     ((derived-mode-p 'pichat-chat-mode) (current-buffer))
     ((and (bound-and-true-p bufferlo-mode)
           (fboundp 'bufferlo-local-buffer-p))
      (let ((local (cl-remove-if-not
                    (lambda (buffer)
                      (bufferlo-local-buffer-p buffer (selected-frame) nil t))
                    buffers)))
        ;; Never route implicitly to a chat in another tab.
        (if local
            (pichat-reference--choose-chat local)
          (pichat-reference--read-chat-buffer buffers))))
     (t
      (let* ((scope (and (fboundp 'pichat--project-root)
                         (pichat--project-root default-directory)
                         (pichat--scope-for-directory default-directory)))
             (matched (and scope
                           (cl-remove-if-not
                            (lambda (buffer)
                              (with-current-buffer buffer
                                (and pichat-chat-session
                                     (equal (pichat-session-owner-scope-key
                                             pichat-chat-session)
                                            (car scope)))))
                            buffers))))
        (if (and scope (null matched))
            (pichat-reference--read-chat-buffer buffers)
          (pichat-reference--choose-chat (or matched buffers))))))))

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
  "References:"
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

(defun pichat-reference--write-temp-reference (label text)
  "Write TEXT from LABEL to a runtime-accessible file and return its reference."
  (when (> (length text) pichat-reference-snapshot-large-threshold)
    (unless (yes-or-no-p
             (format "Write large PiChat reference from %s (%d chars)? "
                     label (length text)))
      (user-error "Temporary reference cancelled")))
  (let* ((ssh-default (and (null pichat-reference-temp-directory)
                           pichat-reference--transport
                           (eq (pichat-transport-kind pichat-reference--transport)
                               'ssh)))
         (dir (file-name-as-directory
               (expand-file-name
                (cond (ssh-default
                       (pichat-transport-runtime-file-name
                        pichat-reference--transport "/tmp"))
                      (pichat-reference-temp-directory)
                      (t temporary-file-directory)))))
         (probe (expand-file-name "pichat-reference-probe.txt" dir)))
    ;; A remote /tmp file is written through the exact SSH transport, not
    ;; through the ordinary project path mappings.
    (unless (or ssh-default
                (plist-get (pichat-path-resolve-to-runtime
                            probe pichat-reference--path-context) :path))
      (user-error "Temporary reference directory is unavailable to Pi; configure pichat-reference-temp-directory: %s"
                  dir))
    (let* ((file (make-temp-file (expand-file-name "pichat-reference-" dir)
                                 nil ".txt" text))
           (runtime-file (if ssh-default (file-local-name file)
                           (pichat-reference--runtime-path file))))
      (pichat-reference--format-reference-block
       (list (concat "- `" runtime-file "` — from " label))))))

(defun pichat-reference--region ()
  "Return reference text for the active region in the current buffer."
  (let ((beg (region-beginning))
        (end (region-end)))
    (if-let* ((file (buffer-file-name)))
        (pcase-let ((`(,start . ,finish) (pichat-reference--line-range beg end)))
          (pichat-reference--format-reference-block
           (list (pichat-reference--format-location
                  file start finish (thing-at-point 'symbol t)))))
      (pichat-reference--write-temp-reference
       (buffer-name)
       (buffer-substring-no-properties beg end)))))

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
            (when-let* ((file (buffer-file-name)))
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

(defun pichat-reference--buffer-temp-reference ()
  "Return a temporary file reference for the current buffer."
  (pichat-reference--write-temp-reference
   (buffer-name)
   (buffer-substring-no-properties (point-min) (point-max))))

(defun pichat-reference--dwim-text ()
  "Return prompt text describing the current Emacs context DWIM."
  (cond
   ((use-region-p) (pichat-reference--region))
   ((derived-mode-p 'pichat-chat-mode)
    (let ((file (read-file-name "Reference file: " default-directory nil t)))
      (unless (file-regular-p file)
        (user-error "Not a regular file: %s" file))
      (pichat-reference--format-reference-block
       (list (pichat-reference--format-location file)))))
   ((derived-mode-p 'dired-mode) (pichat-reference--dired))
   ((derived-mode-p 'compilation-mode) (or (pichat-reference--compilation)
                                           (pichat-reference--buffer-temp-reference)))
   ((buffer-file-name) (pichat-reference--defun-or-line))
   (t (pichat-reference--buffer-temp-reference))))

(defun pichat-reference--insert-into-chat (buffer text &optional captured-target)
  "Insert TEXT into BUFFER's draft, merging reference blocks when possible.
CAPTURED-TARGET retains an earlier destination across collection."
  (let* ((target (or captured-target (pichat-chat-draft-capture buffer)))
         (input (pichat-chat-draft-text target))
         (at-bol (with-current-buffer buffer
                   (save-excursion (goto-char (point-max)) (or (bobp) (bolp))))))
    (pichat-chat-draft-replace
     target
     (if (pichat-reference--reference-lines text)
         (pichat-reference--merge-reference-text input text)
       (concat input (if at-bol "" "\n") text)))))

;;;###autoload
(defun pichat-add-reference (&optional prompt-for-chat-buffer)
  "Insert a DWIM reference to the current buffer/region into a PiChat prompt.

With universal prefix PROMPT-FOR-CHAT-BUFFER, ask which PiChat buffer should
receive the reference.  Otherwise choose a chat in the current Bufferlo tab,
or in the source project's scope when Bufferlo is unavailable; ask if
ambiguous.  From a chat without a region, prompt for a file to reference.
Cancel if the destination chat or its source changes during collection."
  (interactive "P")
  (let* ((target (pichat-reference--target-buffer prompt-for-chat-buffer))
         (session (with-current-buffer target pichat-chat-session))
         (draft-target (pichat-chat-draft-capture target))
         (pichat-reference--path-context
          (and session (pichat-session-path-context session)))
         (pichat-reference--transport
          (and session (pichat-session-transport session)))
         (text (pichat-reference--dwim-text)))
    ;; Collection may prompt or wait for file I/O.  Draft editing does not
    ;; require a running process, but must retain the chosen source and owner.
    (unless (pichat-chat-draft-current-p draft-target)
      (user-error "Reference destination changed; invoke pichat-add-reference again"))
    (pichat-reference--insert-into-chat target text draft-target)
    (deactivate-mark)
    (pop-to-buffer target)
    (message "Inserted PiChat reference into %s" (buffer-name target))))

(provide 'pichat-reference)
;;; pichat-reference.el ends here
