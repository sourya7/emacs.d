;;; utils.el --- keybindings -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Utility functions
;;; Code:

(require 'ansi-color)

(defcustom my/is-work-machine nil
  "Whether this is a work machine."
  :type 'boolean
  :group 'sharmaso)

(defun my/add-all-to-list (list-var elements)
  "Add all ELEMENTS to LIST-VAR."
  (dolist (element elements)
        (add-to-list list-var element)))

(defun my/move-file (new-location)
  "Write this file to NEW-LOCATION, and delete the old one."
  (interactive (list (expand-file-name
                      (if buffer-file-name
                          (read-file-name "Move file to: ")
                        (read-file-name "Move file to: "
                                        default-directory
                                        (expand-file-name (file-name-nondirectory (buffer-name))
                                                          default-directory))))))
  (when (file-exists-p new-location)
    (delete-file new-location))
  (let ((old-location (expand-file-name (buffer-file-name))))
    (write-file new-location t)
    (when (and old-location
               (file-exists-p new-location)
               (not (string-equal old-location new-location)))
      (delete-file old-location))))

(defun my/copy-file (new-path)
  "Copy the file associated with current buffer to NEW-PATH."
  (interactive "FCopy to: ")
  (let ((current-file (buffer-file-name)))
    (if current-file
        (progn
          (copy-file current-file new-path)
          (message "Copied %s to %s" current-file new-path))
      (message "Buffer is not visiting a file"))))

(defmacro my/define-emacs-dir (name dir-suffix)
  "Define a variable and function for managing Emacs directories.
Creates NAME -dir variable and NAME-dir function for DIR-SUFFIX
under `user-emacs-directory`."
  (let ((var-name (intern (format "%s-dir" name)))
        (fn-name (intern (format "%s-dir" name))))
    `(progn
       (defvar ,var-name
         (file-truename (expand-file-name ,dir-suffix user-emacs-directory)))
       (defun ,fn-name (path)
         ,(format "Locate the PATH respective to the %s dir.\nCreates the directory if it doesn't exist." name)
         (let ((full-path (expand-file-name path ,var-name)))
           (make-directory (file-name-directory full-path) t)
           full-path)))))

(my/define-emacs-dir my/emacs-local ".local/")
(my/define-emacs-dir my/emacs-shared "shared/")
(my/define-emacs-dir my/emacs-main "")

(defun my/copy-code-block ()
  "Copy the code block (surrounded by triple backticks) at point."
  (interactive)
  (let* ((start-regex "^```.*$")
         (end-regex "^```$")
         (block-start (save-excursion
                        (when (not (looking-at start-regex))
                          (search-backward-regexp start-regex nil t))
                        (line-beginning-position 2)))
         (block-end (save-excursion
                      (goto-char block-start)
                      (forward-line)
                      (if (search-forward-regexp end-regex nil t)
                          (line-end-position 0)
                        nil))))
    (if (and block-start block-end)
        (let ((code (buffer-substring-no-properties
                     block-start
                     block-end)))
          (kill-new code)
          (message "Code block copied to clipboard!"))
      (message "No code block found at point!"))))

(defun my/find-files-emacsd ()
  "Find files in Emacs local dir."
  (interactive)
  (find-file user-emacs-directory))

(defun my/keyboard-quit-dwim ()
  "Do-What-I-Mean behaviour for a general `keyboard-quit'.

The generic `keyboard-quit' does not do the expected thing when
the minibuffer is open.  Whereas we want it to close the
minibuffer, even without explicitly focusing it.

The DWIM behaviour of this command is as follows:

- When the region is active, disable it.
- When a minibuffer is open, but not focused, close the minibuffer.
- When the Completions buffer is selected, close it.
- In every other case use the regular `keyboard-quit'."
  (interactive)
  (cond
   ((region-active-p)
    (keyboard-quit))
   ((derived-mode-p 'completion-list-mode)
    (delete-completion-window))
   ((> (minibuffer-depth) 0)
    (abort-recursive-edit))
   (t
    (keyboard-quit))))

(defun my/switch-to-tab-from-key ()
  "Switch to tab based on keybinds."
  (interactive)
  (let* ((keys (this-command-keys-vector))
         (last-key (aref keys (1- (length keys))))
         (num (string-to-number (char-to-string last-key))))
    (when (and (>= num 1) (<= num 9))
      (tab-bar-select-tab num))))

(defun my/project-switch-project-with-tab (orig-fun dir)
  "Advice to create or switch to project in tab with ORIG-FUN DIR."
  (let* ((project-name (file-name-nondirectory (directory-file-name dir)))
         (existing-tab (tab-bar--tab-index-by-name project-name)))
    (if existing-tab
        (tab-bar-switch-to-tab project-name)
      (tab-bar-new-tab)
      (tab-bar-rename-tab project-name)))
  (funcall orig-fun dir))

(defvar consult-project-buffer-sources)
(declare-function consult-project-buffer "consult.el")
(defun my/project-recentf ()
  "Get the recent files using Consult."
  (interactive)
  (let ((consult-project-buffer-sources
         '(consult-source-project-recent-file
           consult-source-project-buffer)))
    (call-interactively #'consult-project-buffer)))

(defun my/merge-plists (&rest plists)
  "Create a single property list from all plists in PLISTS.
The process starts by copying the first list, and then setting properties
from the other lists.  Settings in the last list are the most significant
ones and overrule settings in the other lists."
  (let ((rtn (copy-sequence (pop plists)))
        p v ls)
    (while plists
      (setq ls (pop plists))
      (while ls
        (setq p (pop ls) v (pop ls))
        (setq rtn (plist-put rtn p v))))
    rtn))

(defun my/dape-override-config (configs provider override)
  "Override specific values in CONFIGS for PROVIDER with OVERRIDE.
CONFIGS is the dape-configs plist
PROVIDER is the symbol of the config to modify (e.g., rdbg)
OVERRIDE is a plist of values to override"
  (let* ((provider-config (assoc provider configs))
         (config-plist (cdr provider-config)))
    (if provider-config
        (my/merge-plists config-plist override)
      (error "Provider %s not found in configs" provider))))

(defvar sql-connection-alist)
(defun my/sql-connect-preset (connection)
  "Connect to a predefined SQL CONNECTION."
  (interactive
   (list
    (completing-read "Select database connection: "
                    (mapcar 'car sql-connection-alist))))
  (let* ((connection-info (assoc connection sql-connection-alist))
         (default-directory "/"))
    (sql-connect connection connection-info)))

(defun my/run-zellij-with-project-dir ()
  "Run zellij with current project's root directory as the working directory."
  (interactive)
  (let* ((project-dir (or (when (and (fboundp 'project-root) (project-current))
                            (project-root (project-current)))
                          default-directory)) ; Fallback to `default-directory`
         (command (format "zellij -s default action new-pane --cwd %s -f -c -- nu"
                          (expand-file-name project-dir)))) ; Ensure full path
    (message "Running: %s" command) ; Display the command in the minibuffer
    (shell-command command)))

(declare-function project-name "project.el")
(defun my/buffer-list-by-project ()
  "Return an association list of project names to their buffers.
The returned list has elements of the form (PROJECT-NAME . BUFFERS)
where PROJECT-NAME is a string and BUFFERS is a list of buffer objects
that belong to that project."
  (let ((projects-buffers (make-hash-table :test 'equal))
        (result '()))
    ;; Group buffers by project
    (dolist (buffer (buffer-list))
      (let* ((buffer-file (buffer-file-name buffer))
             (buffer-project (when buffer-file
                               (project-current nil (file-name-directory buffer-file))))
             (project-name (when buffer-project (project-name buffer-project))))
        (when project-name
          (let ((buffers (gethash project-name projects-buffers '())))
            (puthash project-name (cons buffer buffers) projects-buffers)))))

    ;; Convert hash table to list of (project-name . buffers) pairs
    (maphash (lambda (project-name buffers)
               (push (cons project-name buffers) result))
             projects-buffers)
    result))

(defun my/restore-project-tabs ()
  "Move project buffers to their designated project tabs."
  (interactive)
  (let ((project-buffers (my/buffer-list-by-project)))
    (dolist (project-buffer-pair project-buffers)
      (let* ((project-name (car project-buffer-pair))
             (buffers (cdr project-buffer-pair))
             (existing-tab (tab-bar--tab-index-by-name project-name)))
        (when project-name
          (unless existing-tab
            (tab-bar-new-tab)
            (tab-bar-rename-tab project-name))

          (tab-bar-switch-to-tab project-name)

          (dolist (buffer buffers)
            (with-current-buffer buffer
              (set-frame-parameter nil 'buffer-list
                                   (cons buffer (delq buffer (frame-parameter nil 'buffer-list))))
              (let* ((tab (tab-bar--current-tab))
                     (ws (alist-get 'ws tab))
                     (bufferlo-list (alist-get 'bufferlo-buffer-list ws))
                     (buffer-name (buffer-name buffer)))
                (when ws
                  (setf (alist-get 'bufferlo-buffer-list ws)
                        (cons buffer-name (delete buffer-name bufferlo-list)))))))
          (switch-to-buffer (car buffers)))))))

(defun my/set-font (font-name font-size)
  "Function to set the user font.
FONT-NAME is the name of the font to use.
FONT-SIZE is the height of the font in 1/10 pt."
  (when (find-font (font-spec :name font-name))
    (set-face-attribute 'default nil
                        :font font-name
                        :height font-size)))

(defvar my/shared-bookmarks-file (my/emacs-shared-dir "bookmarks")
  "Path to shared bookmarks file.")

(defvar bookmark-alist)
(declare-function bookmark-alist-from-buffer "bookmark.el")
(defun my/sync-shared-bookmarks ()
  "Sync shared bookmarks to local bookmarks file.
This merges shared bookmarks with the host's bookmarks."
  (interactive)
  (when (file-exists-p my/shared-bookmarks-file)
    ;; Load shared bookmarks
    (with-temp-buffer
      (insert-file-contents my/shared-bookmarks-file)
      (goto-char (point-min))
      (let* ((shared-bmks (bookmark-alist-from-buffer))
             ;; Get existing local bookmarks
             (local-bmks (copy-sequence bookmark-alist))
             ;; Extract bookmark names for comparison
             (local-names (mapcar (lambda (bmk) (car bmk)) local-bmks))
             ;; Filter shared bookmarks to avoid duplicates
             (filtered-shared (cl-remove-if (lambda (bmk)
                                           (member (car bmk) local-names))
                                         shared-bmks)))
        ;; Merge bookmarks and save
        (setq bookmark-alist (append local-bmks filtered-shared))
        (bookmark-save)))
    (message "Shared bookmarks synced to local bookmarks")))

(defun my/yank-buffer-line-at-point (&optional arg)
  "Copy an Org-mode file link to the current position in the buffer.
The link will point to the current file and line number. When called with
prefix argument ARG, prompt for additional display text to append to the link.
The default display text is \='filename:line-number\='."
  (interactive "P")
  (let* ((filename (buffer-file-name))
         (project-dir (or (when (and (fboundp 'project-root) (project-current))
                            (project-root (project-current)))
                          default-directory))
         (relative-filename (file-relative-name filename project-dir))
         (line-number (line-number-at-pos))
         (info (if arg (read-string "Display text: ")))
         (display-text (format "%s:%d" relative-filename line-number)))
    (if info (setq display-text (format "%s#%s" display-text info)))
    (kill-new (format "[[file:%s::%d][%s]]"
                      filename
                      line-number
                      display-text))))

(defun my/shell-command ()
  "Run the shell command and colorize it."
  (interactive)
  (call-interactively #'shell-command)
  (with-current-buffer shell-command-buffer-name
    (my/colorize-buffer)))

(defun my/colorize-buffer ()
  "Colorize the buffer rendering the ansi codes."
  (interactive)
  (ansi-color-apply-on-region (point-min) (point-max)))

(defun my/copy-single-line (&optional beg end)
  "Copy the shell command at point (or active region) as a single line.

Understands lines ending with \"\\\" as continuations, removes the
backslashes/newlines, and collapses whitespace to single spaces."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((bounds
          (cond
           ((and beg end) (cons beg end))
           (t
            (save-excursion
              ;; Expand to include the whole backslash-continued block.
              (beginning-of-line)
              (while (and (not (bobp))
                          (save-excursion
                            (forward-line -1)
                            (end-of-line)
                            (looking-back "\\\\[ \t]*" (line-beginning-position))))
                (forward-line -1)
                (beginning-of-line))
              (let ((start (point)))
                (while (progn
                         (end-of-line)
                         (looking-back "\\\\[ \t]*" (line-beginning-position)))
                  (forward-line 1)
                  (beginning-of-line))
                (cons start (line-end-position)))))))
         (raw (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (one-line
          (string-trim
           (replace-regexp-in-string
            "[ \t\n\r]+" " "
            (replace-regexp-in-string "\\\\[ \t]*\n[ \t]*" " " raw)))))
    (kill-new one-line)))

(provide 'core/utils)
;;; utils.el ends here
