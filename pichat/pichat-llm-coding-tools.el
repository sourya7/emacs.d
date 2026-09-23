;;; pichat-llm-coding-tools.el --- Opt-in bounded coding tools -*- lexical-binding: t; -*-

;;; Commentary:

;; A deliberately small local-filesystem tool set for native PiChat sessions.
;; Loading this module does not register or expose anything.  Call
;; `pichat-llm-coding-tools-register' explicitly, then select the returned names
;; through `pichat-llm-tools'.  Paths are confined to the dynamically bound
;; session working directory and remote files are intentionally unsupported.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pichat-tools)

(defgroup pichat-llm-coding-tools nil
  "Bounded, explicitly registered coding tools for native PiChat."
  :group 'pichat-llm)

(defcustom pichat-llm-coding-tools-max-file-bytes (* 1024 1024)
  "Maximum bytes read from or written to one file."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-max-output-chars 20000
  "Maximum characters returned by one coding tool before a truncation marker."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-max-read-lines 1000
  "Maximum lines returned by one file-read call."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-max-directory-entries 500
  "Maximum entries returned by one directory-list call."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-command-timeout 30
  "Default timeout in seconds for the bounded bash tool."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-max-command-timeout 120
  "Maximum timeout in seconds accepted by the bounded bash tool."
  :type 'integer
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-coding-tools-search-skip-directories
  '(".git" ".hg" ".svn" "node_modules")
  "Directory basenames skipped by the recursive text-search tool."
  :type '(repeat string)
  :group 'pichat-llm-coding-tools)

(defconst pichat-llm-coding-tool-names
  '("read" "find" "grep" "write" "edit" "bash" "ls")
  "Complete tool inventory registered by `pichat-llm-coding-tools-register'.")

(defconst pichat-llm-coding-tool-default-names
  '("read" "find" "grep" "write" "edit" "bash" "ls")
  "Default names returned by `pichat-llm-coding-tools-register'.")

(defun pichat-llm-coding-tools--positive-limit (value maximum label &optional default)
  "Validate VALUE as a positive integer bounded by MAXIMUM for LABEL.
Use DEFAULT when VALUE is nil."
  (let ((value (or value default)))
    (unless (and (integerp value) (> value 0))
      (user-error "%s must be a positive integer" label))
    (min value maximum)))

(defun pichat-llm-coding-tools--timeout (value)
  "Return validated command timeout VALUE or the configured default."
  (let ((value (or value pichat-llm-coding-tools-command-timeout)))
    (unless (and (numberp value) (> value 0))
      (user-error "Timeout must be a positive number"))
    (min value pichat-llm-coding-tools-max-command-timeout)))

(defun pichat-llm-coding-tools--required-string (params key label &optional nonempty)
  "Return string KEY from PARAMS or signal a bounded error naming LABEL.
When NONEMPTY is non-nil, reject an empty string."
  (let ((value (plist-get params key)))
    (unless (and (stringp value) (or (not nonempty) (not (string-empty-p value))))
      (user-error "%s must be %sa string" label (if nonempty "a non-empty " "")))
    (when (string-match-p "\0" value)
      (user-error "%s contains a NUL character" label))
    value))

(defun pichat-llm-coding-tools--root ()
  "Return the canonical local tool root from `default-directory'."
  (when (and (stringp default-directory) (file-remote-p default-directory))
    (user-error "Coding tools do not operate on remote files"))
  (unless (and (stringp default-directory)
               (file-directory-p default-directory))
    (user-error "Coding tool working directory is unavailable"))
  (file-name-as-directory (file-truename default-directory)))

(defun pichat-llm-coding-tools--inside-root-p (path root)
  "Return non-nil when canonical PATH is ROOT or lies below ROOT."
  (let ((path (directory-file-name path))
        (root-name (directory-file-name root)))
    (or (equal path root-name)
        (string-prefix-p root (file-name-as-directory path)))))

(defun pichat-llm-coding-tools--resolve (path &optional must-exist directory-p)
  "Resolve PATH beneath the session root.
When MUST-EXIST is non-nil, require an existing path.  DIRECTORY-P requires a
folder; otherwise an existing target must be a regular file.  Nonexistent
paths are accepted only when their immediate parent exists."
  (unless (and (stringp path) (not (string-empty-p path)))
    (user-error "Path must be a non-empty string"))
  (when (string-match-p "\0" path)
    (user-error "Path contains a NUL character"))
  (let* ((root (pichat-llm-coding-tools--root))
         (expanded (expand-file-name path root)))
    (when (file-remote-p expanded)
      (user-error "Coding tools do not operate on remote files"))
    (unless (pichat-llm-coding-tools--inside-root-p expanded root)
      (user-error "Path escapes the coding tool working directory: %s" path))
    (when (and must-exist (not (file-exists-p expanded)))
      (user-error "Path does not exist: %s" path))
    (let* ((exists (file-exists-p expanded))
           (canonical
            (if exists
                (file-truename expanded)
              (let ((parent (file-name-directory expanded)))
                (unless (file-directory-p parent)
                  (user-error "Parent directory does not exist: %s" path))
                (expand-file-name (file-name-nondirectory expanded)
                                  (file-name-as-directory
                                   (file-truename parent)))))))
      (unless (pichat-llm-coding-tools--inside-root-p canonical root)
        (user-error "Path escapes the coding tool working directory: %s" path))
      (when exists
        (if directory-p
            (unless (file-directory-p canonical)
              (user-error "Path is not a directory: %s" path))
          (unless (file-regular-p canonical)
            (user-error "Path is not a regular file: %s" path))))
      canonical)))

(defun pichat-llm-coding-tools--read-bytes (path)
  "Read local PATH literally within the configured byte bound."
  (let ((size (file-attribute-size (file-attributes path 'string))))
    (when (> size pichat-llm-coding-tools-max-file-bytes)
      (user-error "File exceeds the %d byte coding-tool limit"
                  pichat-llm-coding-tools-max-file-bytes))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (buffer-string))))

(defun pichat-llm-coding-tools--decode-text (bytes path)
  "Decode UTF-8 BYTES for PATH, rejecting binary or noncanonical input."
  (when (string-match-p "\0" bytes)
    (user-error "File is not supported UTF-8 text: %s" path))
  (let ((text (decode-coding-string bytes 'utf-8-unix)))
    (when (seq-some (lambda (character)
                      (eq (char-charset character) 'eight-bit))
                    text)
      (user-error "File is not valid UTF-8 text: %s" path))
    (unless (equal bytes (encode-coding-string text 'utf-8-unix))
      (user-error "File is not valid UTF-8 text: %s" path))
    text))

(defun pichat-llm-coding-tools--encode-text (text)
  "Encode TEXT as UTF-8 after validating the configured file bound."
  (when (string-match-p "\0" text)
    (user-error "Content contains a NUL character"))
  (let ((bytes (encode-coding-string text 'utf-8-unix)))
    (when (> (length bytes) pichat-llm-coding-tools-max-file-bytes)
      (user-error "Content exceeds the %d byte coding-tool limit"
                  pichat-llm-coding-tools-max-file-bytes))
    bytes))

(defun pichat-llm-coding-tools--bounded-output (text)
  "Bound tool output TEXT and mark truncation explicitly."
  (let* ((limit (max 0 pichat-llm-coding-tools-max-output-chars))
         (marker "\n[output truncated]\n"))
    (if (> (length text) limit)
        (if (<= limit (length marker))
            (substring marker 0 limit)
          (concat (substring text 0 (- limit (length marker))) marker))
      text)))

(defun pichat-llm-coding-tools--relative (path)
  "Return PATH relative to the canonical tool root."
  (file-relative-name path (pichat-llm-coding-tools--root)))

(defun pichat-llm-coding-tools--modified-buffer (path)
  "Return a modified file-visiting buffer for PATH, if any."
  (let ((canonical (if (file-exists-p path) (file-truename path)
                     (expand-file-name path))))
    (seq-find
     (lambda (buffer)
       (with-current-buffer buffer
         (and buffer-file-name
              (buffer-modified-p buffer)
              (equal canonical
                     (if (file-exists-p buffer-file-name)
                         (file-truename buffer-file-name)
                       (expand-file-name buffer-file-name))))))
     (buffer-list))))

(defun pichat-llm-coding-tools--write-bytes-atomically
    (path bytes &optional modes overwrite)
  "Write BYTES to local PATH with a same-directory atomic rename.
Apply MODES when non-nil.  OVERWRITE must be non-nil to replace PATH."
  (let* ((directory (file-name-directory path))
         (temporary (make-temp-file
                     (expand-file-name ".pichat-write-" directory))))
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert bytes)
            (let ((coding-system-for-write 'no-conversion))
              (write-region nil nil temporary nil 'silent)))
          (set-file-modes temporary (or modes #o600))
          (rename-file temporary path overwrite)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun pichat-llm-coding-tools-read-file (params)
  "Read a bounded UTF-8 line range described by PARAMS."
  (let* ((requested (pichat-llm-coding-tools--required-string
                     params :path "Path" t))
         (path (pichat-llm-coding-tools--resolve requested t nil))
         (offset (pichat-llm-coding-tools--positive-limit
                  (plist-get params :offset) most-positive-fixnum "Offset" 1))
         (limit (pichat-llm-coding-tools--positive-limit
                 (plist-get params :limit)
                 pichat-llm-coding-tools-max-read-lines "Limit"
                 pichat-llm-coding-tools-max-read-lines))
         (text (pichat-llm-coding-tools--decode-text
                (pichat-llm-coding-tools--read-bytes path) requested))
         (lines (split-string text "\n" nil))
         (total (length lines))
         (start (min total (1- offset)))
         (end (min total (+ start limit)))
         (selected (seq-subseq lines start end)))
    (when (> offset total)
      (user-error "Offset %d is beyond end of file (%d lines total)"
                  offset total))
    (pichat-llm-coding-tools--bounded-output
     (format "[%s lines %d-%d of %d]\n%s"
             (pichat-llm-coding-tools--relative path)
             (if selected (1+ start) 0) end total
             (string-join selected "\n")))))

(defun pichat-llm-coding-tools-list-directory (params)
  "List one bounded local directory described by PARAMS."
  (let* ((requested (or (plist-get params :path) "."))
         (path (pichat-llm-coding-tools--resolve requested t t))
         (limit (pichat-llm-coding-tools--positive-limit
                 (plist-get params :limit)
                 pichat-llm-coding-tools-max-directory-entries "Limit"
                 pichat-llm-coding-tools-max-directory-entries))
         (entries (sort (directory-files path t directory-files-no-dot-files-regexp t)
                        #'string-lessp))
         (truncated (> (length entries) limit))
         (entries (seq-take entries limit))
         (lines
          (mapcar
           (lambda (entry)
             (concat (file-name-nondirectory entry)
                     (cond ((file-symlink-p entry) "@")
                           ((file-directory-p entry) "/")
                           (t ""))))
           entries)))
    (pichat-llm-coding-tools--bounded-output
     (concat (format "[%s]\n" (pichat-llm-coding-tools--relative path))
             (string-join lines "\n")
             (if truncated "\n[entry limit reached]" "")))))

(defun pichat-llm-coding-tools-write-file (params)
  "Create one new UTF-8 file described by PARAMS."
  (let* ((requested (pichat-llm-coding-tools--required-string
                     params :path "Path" t))
         (content (pichat-llm-coding-tools--required-string
                   params :content "Content" nil))
         (path (pichat-llm-coding-tools--resolve requested nil nil))
         (bytes (pichat-llm-coding-tools--encode-text content)))
    (when (file-exists-p path)
      (user-error "Write tool creates new files only; target exists: %s" requested))
    (when (pichat-llm-coding-tools--modified-buffer path)
      (user-error "Target has unsaved Emacs buffer changes: %s" requested))
    (pichat-llm-coding-tools--write-bytes-atomically path bytes)
    (format "Created %s (%d bytes)"
            (pichat-llm-coding-tools--relative path) (length bytes))))

(defun pichat-llm-coding-tools-edit-file (params)
  "Apply one guarded exact replacement described by PARAMS."
  (let* ((requested (pichat-llm-coding-tools--required-string
                     params :path "Path" t))
         (old (pichat-llm-coding-tools--required-string
               params :oldText "oldText" t))
         (new (pichat-llm-coding-tools--required-string
               params :newText "newText" nil))
         (expected (plist-get params :expectedSha256))
         (expanded (expand-file-name requested (pichat-llm-coding-tools--root)))
         (path (pichat-llm-coding-tools--resolve requested t nil)))
    (when (file-symlink-p expanded)
      (user-error "Edit tool does not replace symbolic links: %s" requested))
    (when (and expected
               (not (and (stringp expected)
                         (= (length expected) 64)
                         (cl-every
                          (lambda (character)
                            (or (and (>= character ?0) (<= character ?9))
                                (and (>= character ?a) (<= character ?f))
                                (and (>= character ?A) (<= character ?F))))
                          expected))))
      (user-error "expectedSha256 must be a 64-character hexadecimal digest"))
    (when (pichat-llm-coding-tools--modified-buffer path)
      (user-error "Target has unsaved Emacs buffer changes: %s" requested))
    (let* ((bytes (pichat-llm-coding-tools--read-bytes path))
           (digest (secure-hash 'sha256 bytes))
           (text (pichat-llm-coding-tools--decode-text bytes requested))
           (regexp (regexp-quote old))
           (first (string-match regexp text))
           (second (and first (string-match regexp text (1+ first)))))
      (when (and expected (not (string-equal (downcase expected) digest)))
        (user-error "Edit conflict: expectedSha256 does not match"))
      (unless first
        (user-error "Edit conflict: oldText was not found"))
      (when second
        (user-error "Edit conflict: oldText is not unique"))
      (let* ((replacement (concat (substring text 0 first) new
                                  (substring text (+ first (length old)))))
             (replacement-bytes
              (pichat-llm-coding-tools--encode-text replacement))
             (modes (file-modes path)))
        ;; Re-read immediately before the atomic replacement.  Local tools do
        ;; not yield during execution, but this also detects external writers.
        (unless (equal digest
                       (secure-hash
                        'sha256 (pichat-llm-coding-tools--read-bytes path)))
          (user-error "Edit conflict: file changed during execution"))
        (pichat-llm-coding-tools--write-bytes-atomically
         path replacement-bytes modes t)
        (format "Edited %s (sha256 %s -> %s)"
                (pichat-llm-coding-tools--relative path)
                digest (secure-hash 'sha256 replacement-bytes))))))

(defun pichat-llm-coding-tools--stop-process (process)
  "Interrupt PROCESS's group and delete it without signalling failures."
  (when (process-live-p process)
    (ignore-errors (interrupt-process process))
    (ignore-errors (delete-process process))))

(defun pichat-llm-coding-tools--shell-executable ()
  "Return the configured local shell as an executable file name.
Resolve a bare `shell-file-name' through `exec-path', as Emacs does for
process commands.  Fall back to `sh' only when no shell is configured."
  (let* ((configured
          (and (stringp shell-file-name)
               (not (string-empty-p shell-file-name))
               shell-file-name))
         (shell
          (cond
           ((null configured) (executable-find "sh"))
           ((file-name-absolute-p configured) configured)
           ((file-name-directory configured) (expand-file-name configured))
           (t (executable-find configured)))))
    (unless (and shell (file-regular-p shell) (file-executable-p shell))
      (user-error "Configured Emacs shell is unavailable%s"
                  (if configured (format ": %s" configured) "")))
    shell))

(defun pichat-llm-coding-tools-bash (params callback)
  "Run the bounded asynchronous shell command in PARAMS and call CALLBACK."
  (let* ((command (pichat-llm-coding-tools--required-string
                   params :command "Command" t))
         (timeout (pichat-llm-coding-tools--timeout
                   (plist-get params :timeout)))
         (root (pichat-llm-coding-tools--root))
         (shell (pichat-llm-coding-tools--shell-executable)))
    (let ((default-directory root)
          (output "")
          (total 0)
          (truncated nil)
          (timed-out nil)
          (done nil)
          timer
          process)
      (cl-labels
          ((append-output
            (chunk)
            (let ((text (decode-coding-string
                         (encode-coding-string chunk 'utf-8-emacs)
                         'utf-8-emacs)))
              (cl-incf total (length text))
              (unless truncated
                (setq output (concat output text))
                (when (> (length output)
                         pichat-llm-coding-tools-max-output-chars)
                  (setq truncated t
                        output
                        (substring
                         output 0 pichat-llm-coding-tools-max-output-chars))))))
           (finish
            (is-error status)
            (unless done
              (setq done t)
              (when (timerp timer) (cancel-timer timer))
              (let ((text
                     (concat
                      (if (string-empty-p output) "(no output)" output)
                      (when truncated
                        (format "\n\n[output truncated after %d of %d characters]"
                                (length output) total))
                      (when status (concat "\n\n" status)))))
                (funcall callback
                         (list :is-error is-error
                               :value
                               (pichat-llm-coding-tools--bounded-output
                                text)))))))
        (setq process
              (make-process
               :name "pichat-bounded-bash"
               :buffer nil
               :command (list shell "-c" command)
               :connection-type 'pipe
               :coding 'utf-8-emacs-unix
               :noquery t
               :filter (lambda (_process chunk) (append-output chunk))
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (let ((code (process-exit-status proc)))
                     (cond
                      (timed-out
                       (finish t (format "Command timed out after %s seconds"
                                         timeout)))
                      ((and (eq (process-status proc) 'exit) (zerop code))
                       (finish nil nil))
                      ((eq (process-status proc) 'exit)
                       (finish t (format "Command exited with code %d" code)))
                      (t (finish t "Command terminated by signal"))))))))
        (unless done
          (setq timer
                (run-at-time
                 timeout nil
                 (lambda ()
                   (unless done
                     (setq timed-out t)
                     (pichat-llm-coding-tools--stop-process process))))))
        (lambda ()
          (unless done
            ;; Cancellation intentionally produces no tool callback.  The
            ;; owning run invalidates it before invoking this closure.
            (setq done t)
            (when (timerp timer) (cancel-timer timer))
            (pichat-llm-coding-tools--stop-process process)))))))

(require 'pichat-llm-search-tools)

(defun pichat-llm-coding-tools-register ()
  "Explicitly register the bounded native coding tool inventory.
Return a fresh default list suitable for `pichat-llm-tools'.
Registration never rewrites an existing explicit selection, and conversations
retain the tool list advertised when they were created."
  (dolist
      (tool
       (list
        (pichat-tool-create
         :name "read" :label "read"
         :description "Read the contents of a UTF-8 text file. Output is bounded by line and byte limits. Use offset/limit for large files and continue with a later offset when needed."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:path (:type "string" :description "Relative or in-root absolute file path")
            :offset (:type "integer" :description "1-based first line")
            :limit (:type "integer" :description "Maximum lines"))
           :required ["path"])
         :function #'pichat-llm-coding-tools-read-file
         :instructions "Use read to examine files instead of shell commands such as cat or sed. It reads UTF-8 text only; use offset and limit for bounded ranges."
         :mutating-p nil :native-only-p t)
        (pichat-tool-create
         :name "ls" :label "ls"
         :description "List directory contents. Returns entries sorted alphabetically, with '/' for directories and '@' for symbolic links. Includes dotfiles and bounds output by entry and character limits."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:path (:type "string" :description "Directory path; defaults to the working directory")
            :limit (:type "integer" :description "Maximum entries")))
         :function #'pichat-llm-coding-tools-list-directory
         :instructions "ls is non-recursive and marks directories with / and symbolic links with @."
         :mutating-p nil :native-only-p t)
        (pichat-tool-create
         :name "find" :label "find"
         :description "Locate regular files by basename glob using fd. pattern defaults to '*'; path defaults to the working directory. hidden includes hidden files without disabling ignore rules. Results are traversal-order, bounded, and relative to the working directory."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:pattern (:type "string" :description "Optional basename glob; defaults to *")
            :path (:type "string" :description "Directory path; defaults to the working directory")
            :hidden (:type "boolean" :description "Include hidden files while retaining ignore rules")
            :limit (:type "integer" :description "Maximum files; positive and bounded")))
         :function #'pichat-llm-search-tools-find
         :instructions "Use find to locate regular files by basename glob. It runs fd directly, keeps repository ignore rules, does not follow symbolic links, and needs no approval under the normal policy."
         :mutating-p nil :async-p t :native-only-p t)
        (pichat-tool-create
         :name "grep" :label "grep"
         :description "Search file contents with ripgrep. Provide exactly one of legacy pattern or patterns; patterns are ORed. Literal matching is the default; set regex=true for ripgrep regex syntax. path may be a file or directory. glob uses ripgrep file-glob semantics. hidden retains ignore rules. Matching lines, context, and output are globally bounded."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:pattern (:type "string" :description "Legacy single pattern; mutually exclusive with patterns")
            :patterns (:type "array" :items (:type "string") :description "One or more non-empty OR patterns; mutually exclusive with pattern")
            :path (:type "string" :description "File or directory; defaults to the working directory")
            :glob (:type "string" :description "Optional ripgrep file-filter glob")
            :regex (:type "boolean" :description "Use ripgrep regex syntax; defaults to false")
            :ignoreCase (:type "boolean" :description "Case-insensitive matching; defaults to false")
            :context (:type "integer" :description "Bounded lines before and after matches")
            :hidden (:type "boolean" :description "Include hidden files while retaining ignore rules")
            :limit (:type "integer" :description "Global matching-line limit; positive and bounded")))
         :function #'pichat-llm-search-tools-grep
         :instructions "Use grep to search contents and combine related patterns in one call. OR semantics apply to patterns. Literal search is the default; set regex=true for regex. No matches is successful. It runs rg directly, keeps repository ignore rules, does not follow symbolic links, and needs no approval under the normal policy."
         :mutating-p nil :async-p t :native-only-p t)
        (pichat-tool-create
         :name "write" :label "write"
         :description "Create a new UTF-8 text file atomically. The parent directory must already exist, and this guarded tool refuses to overwrite an existing file."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:path (:type "string" :description "New file path with an existing parent")
            :content (:type "string" :description "Complete UTF-8 file content"))
           :required ["path" "content"])
         :function #'pichat-llm-coding-tools-write-file
         :instructions "Use write only for new files. It requires approval and never overwrites an existing file; use edit for precise changes."
         :mutating-p t :native-only-p t)
        (pichat-tool-create
         :name "edit" :label "edit"
         :description "Make one precise file edit using exact text replacement. oldText must match exactly one region in the original file. Keep oldText as small as possible while still unique; do not include large unchanged regions."
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:path (:type "string" :description "Existing regular file path")
            :oldText (:type "string" :description "Exact non-empty text that must occur exactly once")
            :newText (:type "string" :description "Replacement text")
            :expectedSha256 (:type "string" :description "Optional current-file SHA-256 conflict guard"))
           :required ["path" "oldText" "newText"])
         :function #'pichat-llm-coding-tools-edit-file
         :instructions "Use edit for precise changes. oldText must match exactly and uniquely. It requires approval, rejects unsaved buffers and symbolic links, and supports expectedSha256 as a conflict guard."
         :mutating-p t :native-only-p t)
        (pichat-tool-create
         :name "bash" :label "bash"
         :description
         (format "Execute a shell command in the current working directory. Returns combined stdout and stderr, retains only bounded output, and always enforces a timeout (%s seconds by default, %s seconds maximum)."
                 pichat-llm-coding-tools-command-timeout
                 pichat-llm-coding-tools-max-command-timeout)
         :parameters
         '(:type "object" :additionalProperties :json-false
           :properties
           (:command (:type "string" :description "Shell command to execute")
            :timeout (:type "number" :description "Timeout in seconds; bounded and optional"))
           :required ["command"])
         :function #'pichat-llm-coding-tools-bash
         :instructions "Use bash for builds, tests, and other bounded non-interactive commands when read, find, grep, ls, write, or edit is not a better fit. Prefer find/grep for routine searches. bash always requires approval, has a mandatory timeout, and may have arbitrary side effects."
         :mutating-p t :async-p t :native-only-p t)))
    (pichat-tools-register tool))
  (copy-sequence pichat-llm-coding-tool-default-names))

(provide 'pichat-llm-coding-tools)
;;; pichat-llm-coding-tools.el ends here
