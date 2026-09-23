;;; pichat-llm-search-tools.el --- Bounded native fd/rg tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Asynchronous, read-only repository search adapters for native PiChat tools.
;; Executables are invoked directly with internally constructed argument lists.
;; This is a policy boundary, not an operating-system sandbox.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(defgroup pichat-llm-search-tools nil
  "Bounded fd and ripgrep adapters for native PiChat."
  :group 'pichat-llm-coding-tools)

(defcustom pichat-llm-search-tools-fd-executable "fd"
  "Executable name or path for fd.  A bare missing `fd' falls back to `fdfind'."
  :type 'string :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-rg-executable "rg"
  "Executable name or path for ripgrep."
  :type 'string :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-timeout 10
  "Maximum seconds allowed for one find or grep process."
  :type 'number :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-default-limit 100
  "Default number of find results or grep matching lines."
  :type 'integer :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-max-limit 200
  "Maximum accepted find results or grep matching lines."
  :type 'integer :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-max-context 5
  "Maximum before/after context lines accepted by grep."
  :type 'integer :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-max-patterns 16
  "Maximum number of OR patterns accepted by grep."
  :type 'integer :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-max-pattern-chars 2000
  "Maximum characters accepted in one find glob, grep pattern, or file glob."
  :type 'integer :group 'pichat-llm-search-tools)

(defcustom pichat-llm-search-tools-max-record-bytes (* 128 1024)
  "Maximum unterminated fd or rg output record retained by a parser."
  :type 'integer :group 'pichat-llm-search-tools)

;; Defined by pichat-llm-coding-tools before this module is loaded.
(declare-function pichat-llm-coding-tools--root "pichat-llm-coding-tools" ())
(declare-function pichat-llm-coding-tools--resolve "pichat-llm-coding-tools"
                  (path &optional must-exist directory-p))
(declare-function pichat-llm-coding-tools--inside-root-p
                  "pichat-llm-coding-tools" (path root))
(declare-function pichat-llm-coding-tools--stop-process
                  "pichat-llm-coding-tools" (process))
(defvar pichat-llm-coding-tools-max-output-chars)
(defvar pichat-llm-coding-tools-search-skip-directories)

(defun pichat-llm-search-tools--present-p (params key)
  "Return non-nil when PARAMS contains KEY."
  (and (listp params) (plist-member params key)))

(defun pichat-llm-search-tools--boolean (params key label &optional default)
  "Read boolean KEY from PARAMS, using DEFAULT when absent, or reject it."
  (if (not (pichat-llm-search-tools--present-p params key))
      default
    (let ((value (plist-get params key)))
      (unless (memq value '(nil t :json-false))
        (user-error "%s must be a boolean" label))
      (eq value t))))

(defun pichat-llm-search-tools--integer (params key label default minimum maximum)
  "Read integer KEY from PARAMS and clamp it between MINIMUM and MAXIMUM."
  (let ((value (if (pichat-llm-search-tools--present-p params key)
                   (plist-get params key) default)))
    (unless (and (integerp value) (>= value minimum))
      (user-error "%s must be an integer of at least %d" label minimum))
    (min value maximum)))

(defun pichat-llm-search-tools--string (value label &optional allow-empty)
  "Validate VALUE as a bounded string named LABEL."
  (unless (and (stringp value)
               (or allow-empty (not (string-empty-p value))))
    (user-error "%s must be a non-empty string" label))
  (when (string-match-p "\0" value)
    (user-error "%s contains a NUL character" label))
  (when (> (length value) pichat-llm-search-tools-max-pattern-chars)
    (user-error "%s exceeds the %d character limit"
                label pichat-llm-search-tools-max-pattern-chars))
  value)

(defun pichat-llm-search-tools--executable (configured label &optional fallback)
  "Resolve CONFIGURED executable for LABEL, optionally trying FALLBACK."
  (let* ((explicit (file-name-directory configured))
         (found (if explicit (expand-file-name configured)
                  (executable-find configured)))
         (found (or found (and fallback (not explicit)
                               (executable-find fallback)))))
    (unless (and found (file-regular-p found) (file-executable-p found))
      (user-error "%s executable is unavailable: %s%s"
                  label configured
                  (if fallback (format " (also tried %s)" fallback) "")))
    found))

(defun pichat-llm-search-tools--reject-symlink-path (requested canonical)
  "Reject REQUESTED when it names or traverses an in-root symbolic link.
CANONICAL is the already boundary-checked resolution."
  (let* ((root (pichat-llm-coding-tools--root))
         (expanded (expand-file-name requested root))
         (relative (file-relative-name expanded root))
         (cursor root))
    (unless (pichat-llm-coding-tools--inside-root-p canonical root)
      (user-error "Path escapes the coding tool working directory: %s" requested))
    (dolist (part (split-string relative "/" t))
      (setq cursor (expand-file-name part cursor))
      (when (file-symlink-p cursor)
        (user-error "Search path uses a symbolic link: %s" requested)))
    canonical))

(defun pichat-llm-search-tools--resolve (requested directory-p)
  "Resolve existing REQUESTED and reject symlink roots or descendants."
  (pichat-llm-search-tools--reject-symlink-path
   requested
   (pichat-llm-coding-tools--resolve requested t directory-p)))

(defun pichat-llm-search-tools--escape (text)
  "Escape control and non-UTF-8 byte characters in TEXT for safe display."
  (apply #'concat
         (mapcar
          (lambda (character)
            (cond
             ((eq character ?\t) "\\t")
             ((or (< character 32) (= character 127)
                  (eq (char-charset character) 'eight-bit))
              (format "\\x%02X" character))
             (t (string character))))
          (string-to-list text))))

(defun pichat-llm-search-tools--relative (path)
  "Return canonical PATH relative to the fixed tool root, safely escaped."
  (pichat-llm-search-tools--escape
   (file-relative-name path (pichat-llm-coding-tools--root))))

(defun pichat-llm-search-tools--json-text (object label)
  "Return UTF-8 text from rg JSON OBJECT, or reject byte data for LABEL."
  (cond
   ((stringp (plist-get object :text)) (plist-get object :text))
   ((stringp (plist-get object :bytes))
    (user-error "%s is not valid UTF-8 text" label))
   (t (user-error "ripgrep returned an invalid %s record" label))))

(defun pichat-llm-search-tools--bounded-result (lines empty marker)
  "Render LINES or EMPTY with complete truncation and outcome markers."
  (let* ((limit (max 0 pichat-llm-coding-tools-max-output-chars))
         (body (if lines (string-join lines "\n") empty))
         (suffix (and marker (concat "\n" marker)))
         (available (max 0 (- limit (length (or suffix ""))))))
    (when (and (> (length body) available)
               (not (equal marker
                           "[results truncated: output limit reached]")))
      (setq suffix
            (concat "\n[results truncated: output limit reached]"
                    (or suffix ""))
            available (max 0 (- limit (length suffix)))))
    (concat (if (> (length body) available)
                (substring body 0 available) body)
            suffix)))

(defun pichat-llm-search-tools--diagnostic (stderr)
  "Return a bounded, single-line diagnostic from STDERR."
  (let ((text (string-trim
               (replace-regexp-in-string "[\n\r\t]+" " " stderr))))
    (if (string-empty-p text) "no diagnostic output"
      (truncate-string-to-width text 1000 nil nil "…"))))

(defun pichat-llm-search-tools--start
    (name command separator consume finish callback)
  "Start COMMAND and parse records separated by SEPARATOR.
CONSUME receives complete unibyte records.  FINISH receives process status,
exit code, stderr, and an intentional-stop reason.  CALLBACK receives the
final structured tool result.  Return a cancellation closure."
  (let ((stdout (encode-coding-string "" 'binary))
        (stderr-buffer (generate-new-buffer (format " *%s stderr*" name)))
        (stderr-retained "")
        (done nil) (cancelled nil) (intentional nil) timer process)
    (cl-labels
        ((stop (reason)
           (unless (or done intentional)
             (setq intentional reason)
             (pichat-llm-coding-tools--stop-process process)))
         (consume-records ()
           (let ((start 0) position)
             (while (setq position (cl-position separator stdout :start start))
               (funcall consume (substring stdout start position) #'stop)
               (setq start (1+ position)))
             (setq stdout (substring stdout start))
             (when (> (length stdout) pichat-llm-search-tools-max-record-bytes)
               (stop 'record-limit))))
         (complete (status code)
           (unless done
             (setq done t)
             (when (timerp timer) (cancel-timer timer))
             (when (buffer-live-p stderr-buffer)
               (with-current-buffer stderr-buffer
                 (setq stderr-retained
                       (buffer-substring-no-properties
                        (max (point-min) (- (point-max) 4096)) (point-max))))
               (kill-buffer stderr-buffer))
             (unless cancelled
               (funcall callback
                        (funcall finish status code stderr-retained intentional))))))
      (setq process
            (make-process
             :name name :buffer nil :command command :connection-type 'pipe
             :coding 'no-conversion :stderr stderr-buffer :noquery t
             :filter
             (lambda (_process chunk)
               (unless done
                 (setq stdout (concat stdout (encode-coding-string chunk 'binary)))
                 (consume-records)))
             :sentinel
             (lambda (proc _event)
               (when (memq (process-status proc) '(exit signal))
                 (unless intentional (consume-records))
                 (complete (process-status proc) (process-exit-status proc))))))
      (unless done
        (setq timer
              (run-at-time
               pichat-llm-search-tools-timeout nil
               (lambda () (unless done (stop 'timeout))))))
      (lambda ()
        (unless done
          (setq cancelled t done t)
          (when (timerp timer) (cancel-timer timer))
          (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
          (pichat-llm-coding-tools--stop-process process))))))

(defun pichat-llm-search-tools-find (params callback)
  "Find regular files from PARAMS with fd and call CALLBACK once."
  (let* ((pattern (pichat-llm-search-tools--string
                   (or (plist-get params :pattern) "*") "Pattern"))
         (requested (or (plist-get params :path) "."))
         (_ (pichat-llm-search-tools--string requested "Path"))
         (root (pichat-llm-search-tools--resolve requested t))
         (hidden (pichat-llm-search-tools--boolean params :hidden "hidden" nil))
         (limit (pichat-llm-search-tools--integer
                 params :limit "Limit" pichat-llm-search-tools-default-limit
                 1 pichat-llm-search-tools-max-limit))
         (fd (pichat-llm-search-tools--executable
              pichat-llm-search-tools-fd-executable "fd" "fdfind"))
         (skip pichat-llm-coding-tools-search-skip-directories)
         (command (append (list fd "--glob" "--type" "f" "--color" "never"
                                "--print0" "--absolute-path")
                          (when hidden (list "--hidden"))
                          (apply #'append
                                 (mapcar (lambda (name) (list "--exclude" name))
                                         skip))
                          (list "--" pattern root)))
         lines (count 0) (retained 0) parse-error)
    (when (string-match-p "[/\\]" pattern)
      (user-error "Find pattern must be a basename glob without path separators"))
    (pichat-llm-search-tools--start
     "pichat-find" command 0
     (lambda (record stop)
       (unless (or parse-error (string-empty-p record))
         (condition-case err
             (if (>= count limit)
                 (funcall stop 'result-limit)
               (let* ((path (decode-coding-string record 'utf-8-unix))
                      (canonical (file-truename path)))
                 (unless (pichat-llm-coding-tools--inside-root-p
                          canonical (pichat-llm-coding-tools--root))
                   (user-error "fd returned an out-of-root path"))
                 (let* ((line (pichat-llm-search-tools--relative canonical))
                        (size (+ (length line) (if lines 1 0))))
                   (if (> (+ retained size)
                          pichat-llm-coding-tools-max-output-chars)
                       (funcall stop 'output-limit)
                     (cl-incf count)
                     (cl-incf retained size)
                     (push line lines)))))
           (error
            (setq parse-error (error-message-string err))
            (funcall stop 'parse-error)))))
     (lambda (status code stderr intentional)
       (cond
        ((eq intentional 'timeout)
         (list :is-error t :value
               (pichat-llm-search-tools--bounded-result
                (nreverse lines) "[no files found]"
                "[search failed: find timed out]")))
        ((eq intentional 'record-limit)
         (list :is-error t :value
               (pichat-llm-search-tools--bounded-result
                (nreverse lines) "[no files found]"
                "[search failed: oversized fd output record]")))
        ((eq intentional 'parse-error)
         (list :is-error t :value
               (pichat-llm-search-tools--bounded-result
                (nreverse lines) "[no files found]"
                (format "[search failed: %s]" parse-error))))
        ((memq intentional '(result-limit output-limit))
         (list :is-error nil :value
               (pichat-llm-search-tools--bounded-result
                (nreverse lines) "[no files found]"
                (if (eq intentional 'result-limit)
                    "[results truncated: file limit reached]"
                  "[results truncated: output limit reached]"))))
        ((and (eq status 'exit) (zerop code))
         (list :is-error nil :value
               (pichat-llm-search-tools--bounded-result
                (nreverse lines) "[no files found]" nil)))
        (t (list :is-error t :value
                 (pichat-llm-search-tools--bounded-result
                  (nreverse lines) "[no files found]"
                  (format "[search failed: %s]"
                          (pichat-llm-search-tools--diagnostic stderr)))))))
     callback)))

(defun pichat-llm-search-tools--patterns (params)
  "Validate and return PARAMS grep patterns as a list."
  (let ((legacy (pichat-llm-search-tools--present-p params :pattern))
        (multiple (pichat-llm-search-tools--present-p params :patterns)))
    (when (eq (not (null legacy)) (not (null multiple)))
      (user-error "Provide exactly one of pattern or patterns"))
    (let ((patterns
           (if legacy
               (list (pichat-llm-search-tools--string
                      (plist-get params :pattern) "Pattern"))
             (let ((value (plist-get params :patterns)))
               (unless (or (listp value) (vectorp value))
                 (user-error "patterns must be an array of non-empty strings"))
               (append value nil)))))
      (unless (and patterns
                   (<= (length patterns) pichat-llm-search-tools-max-patterns))
        (user-error "patterns must contain between 1 and %d strings"
                    pichat-llm-search-tools-max-patterns))
      (cl-loop for pattern in patterns for index from 1
               collect (pichat-llm-search-tools--string
                        pattern (format "Pattern %d" index))))))

(defun pichat-llm-search-tools-grep (params callback)
  "Search file contents from PARAMS with ripgrep and call CALLBACK once."
  (let* ((patterns (pichat-llm-search-tools--patterns params))
         (requested (or (plist-get params :path) "."))
         (_ (pichat-llm-search-tools--string requested "Path"))
         (tool-root (pichat-llm-coding-tools--root))
         (expanded (expand-file-name requested tool-root))
         (directory-p (file-directory-p expanded))
         (target (pichat-llm-search-tools--resolve requested directory-p))
         (literal (if (pichat-llm-search-tools--boolean
                       params :regex "regex" nil)
                      nil
                    (pichat-llm-search-tools--boolean
                     params :literal "literal" t)))
         (ignore-case (pichat-llm-search-tools--boolean
                       params :ignoreCase "ignoreCase" nil))
         (hidden (pichat-llm-search-tools--boolean params :hidden "hidden" nil))
         (context (pichat-llm-search-tools--integer
                   params :context "Context" 0 0
                   pichat-llm-search-tools-max-context))
         (limit (pichat-llm-search-tools--integer
                 params :limit "Limit" pichat-llm-search-tools-default-limit
                 1 pichat-llm-search-tools-max-limit))
         (glob (and (pichat-llm-search-tools--present-p params :glob)
                    (pichat-llm-search-tools--string
                     (plist-get params :glob) "Glob")))
         (rg (pichat-llm-search-tools--executable
              pichat-llm-search-tools-rg-executable "ripgrep"))
         (command
          (append (list rg "--json" "--no-config" "--no-ignore-global"
                        "--color" "never" "--encoding" "none")
                  (when literal (list "--fixed-strings"))
                  (when ignore-case (list "--ignore-case"))
                  (when hidden (list "--hidden"))
                  (when (> context 0) (list "--context" (number-to-string context)))
                  (when glob (list "--glob" glob))
                  (when directory-p
                    (apply #'append
                           (mapcar (lambda (name)
                                     (list "--glob" (format "!**/%s/**" name)))
                                   pichat-llm-coding-tools-search-skip-directories)))
                  (apply #'append
                         (mapcar (lambda (pattern) (list "-e" pattern)) patterns))
                  (list "--" target)))
         lines (matches 0) (retained 0) previous-path previous-line parse-error)
    (pichat-llm-search-tools--start
     "pichat-grep" command ?\n
     (lambda (record stop)
       (unless (or parse-error (string-empty-p record))
         (condition-case err
             (let* ((json (json-parse-string
                           (decode-coding-string record 'utf-8-unix)
                           :object-type 'plist :array-type 'list
                           :false-object nil :null-object nil))
                    (type (plist-get json :type)))
               (when (member type '("match" "context"))
                 (let* ((data (plist-get json :data))
                        (raw-path (pichat-llm-search-tools--json-text
                                   (plist-get data :path) "path"))
                        (path (file-truename raw-path))
                        (number (plist-get data :line_number))
                        (text (string-remove-suffix
                               "\n" (pichat-llm-search-tools--json-text
                                      (plist-get data :lines) raw-path)))
                        (match-p (equal type "match")))
                   (unless (pichat-llm-coding-tools--inside-root-p
                            path (pichat-llm-coding-tools--root))
                     (user-error "ripgrep returned an out-of-root path"))
                   (if (and match-p (>= matches limit))
                       (funcall stop 'result-limit)
                     (let* ((separator-p
                             (and lines
                                  (or (not (equal path previous-path))
                                      (not (= number (1+ previous-line))))))
                            (line (format "%s%s%d%s%s"
                                          (pichat-llm-search-tools--relative path)
                                          (if match-p ":" "-") number
                                          (if match-p ":" "-")
                                          (pichat-llm-search-tools--escape text)))
                            (size (+ (length line) (if lines 1 0)
                                     (if separator-p 3 0))))
                       (if (> (+ retained size)
                              pichat-llm-coding-tools-max-output-chars)
                           (funcall stop 'output-limit)
                         (when separator-p (push "--" lines))
                         (when match-p (cl-incf matches))
                         (cl-incf retained size)
                         (push line lines)
                         (setq previous-path path previous-line number)))))))
           (error
            (setq parse-error (error-message-string err))
            (funcall stop 'parse-error)))))
     (lambda (status code stderr intentional)
       (let ((rendered (nreverse lines)))
         (cond
          ((eq intentional 'timeout)
           (list :is-error t :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]" "[search failed: grep timed out]")))
          ((eq intentional 'record-limit)
           (list :is-error t :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]"
                  "[search failed: oversized ripgrep output record]")))
          ((eq intentional 'parse-error)
           (list :is-error t :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]"
                  (format "[search failed: %s]" parse-error))))
          ((memq intentional '(result-limit output-limit))
           (list :is-error nil :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]"
                  (if (eq intentional 'result-limit)
                      "[results truncated: matching-line limit reached]"
                    "[results truncated: output limit reached]"))))
          ((and (eq status 'exit) (memq code '(0 1)))
           (list :is-error nil :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]" nil)))
          (t
           (list :is-error t :value
                 (pichat-llm-search-tools--bounded-result
                  rendered "[no matches]"
                  (format "[search failed: %s]"
                          (pichat-llm-search-tools--diagnostic stderr))))))))
     callback)))

(provide 'pichat-llm-search-tools)
;;; pichat-llm-search-tools.el ends here
