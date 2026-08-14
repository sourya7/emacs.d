;;; pichat-tool-enrichment.el --- Pure live tool metadata for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Derive presentation-only metadata from live Pi RPC tool events.  This module
;; performs no file I/O and owns no buffers.  Its records are ephemeral and may
;; be discarded whenever the chat source generation changes.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-path)

(defvar pichat-tool-enrichment-path-context nil
  "Dynamically bound path context for enrichment construction.")

(defcustom pichat-tool-enrichment-kind-alist
  '(("bash" . execute)
    ("read" . read)
    ("write" . write)
    ("edit" . edit)
    ("grep" . search)
    ("find" . search)
    ("ls" . read)
    ("glob" . search)
    ("fetch" . fetch)
    ("web_fetch" . fetch)
    ("webfetch" . fetch))
  "Known tool names and their presentation kinds.
Exact names are matched case-insensitively before conservative name
heuristics are used.  Classification affects presentation only."
  :type '(repeat (cons (string :tag "Tool name") symbol))
  :group 'pichat)

(defconst pichat-tool-enrichment-argument-aliases
  '((:path :path :file_path :filePath :filename :file :target_path :targetPath)
    (:line :line :line_number :lineNumber :start_line :startLine)
    (:column :column :column_number :columnNumber :start_column :startColumn)
    (:offset :offset)
    (:command :command :cmd)
    (:pattern :pattern :search :search_term :searchTerm)
    (:url :url :uri)
    (:query :query)
    (:old-text :old-text :oldText :old_text)
    (:new-text :new-text :newText :new_text)
    (:content :content :text))
  "Canonical tool argument keys followed by accepted RPC aliases.")

(defun pichat-tool-enrichment--nonempty-string-p (value)
  "Return non-nil when VALUE is a non-empty string."
  (and (stringp value) (not (string-empty-p value))))

(defun pichat-tool-enrichment--plist-present-value (plist keys)
  "Return the first present value in PLIST for one of KEYS.
The return value is a cons (PRESENT-P . VALUE), preserving explicit false or
zero values rather than confusing them with an absent key."
  (catch 'found
    (dolist (key keys (cons nil nil))
      (when (plist-member plist key)
        (throw 'found (cons t (plist-get plist key)))))))

(defun pichat-tool-enrichment-normalize-arguments (args)
  "Return canonical recognized fields from tool argument plist ARGS.
Aliases are defined by `pichat-tool-enrichment-argument-aliases'.  Unknown
fields are intentionally omitted from presentation metadata."
  (let (normalized)
    (when (listp args)
      (dolist (entry pichat-tool-enrichment-argument-aliases)
        (pcase-let ((`(,present . ,value)
                     (pichat-tool-enrichment--plist-present-value
                      args (cdr entry))))
          (when (and present (not (null value)))
            (setq normalized (plist-put normalized (car entry) value))))))
    normalized))

(defun pichat-tool-enrichment--merge-plists (old new)
  "Monotonically merge canonical argument plists OLD and NEW."
  (let ((result (copy-sequence old)))
    (cl-loop for (key value) on new by #'cddr
             when (not (null value))
             do (setq result (plist-put result key value)))
    result))

(defun pichat-tool-enrichment--name-heuristic (name)
  "Guess a presentation kind for normalized tool NAME."
  (cond
   ((string-match-p (regexp-opt '("bash" "shell" "exec" "command" "terminal")) name)
    'execute)
   ((string-match-p (regexp-opt '("grep" "search" "find" "glob")) name) 'search)
   ((string-match-p (regexp-opt '("fetch" "http" "curl" "url" "web")) name) 'fetch)
   ((string-match-p (regexp-opt '("write" "create")) name) 'write)
   ((string-match-p (regexp-opt '("edit" "patch" "replace")) name) 'edit)
   ((or (string= name "ls")
        (string-match-p (regexp-opt '("read" "view" "list")) name)
        (string-match-p "\\(?:\\`\\|[_-]\\)cat\\(?:\\'\\|[_-]\\)" name))
    'read)
   ((string-match-p (regexp-opt '("think" "plan" "reason")) name) 'think)
   (t 'other)))

(defun pichat-tool-enrichment-classify (name)
  "Return the presentation kind for tool NAME.
Unknown or missing names classify as `other'."
  (if (not (pichat-tool-enrichment--nonempty-string-p name))
      'other
    (let ((normalized (downcase name)))
      (or (cdr (assoc-string normalized
                             pichat-tool-enrichment-kind-alist t))
          (pichat-tool-enrichment--name-heuristic normalized)))))

(defun pichat-tool-enrichment-resolve-runtime-path (runtime-path &optional context)
  "Resolve RUNTIME-PATH with optional path CONTEXT without file I/O.
Return a plist with :status, :runtime-path, :host-path, and :reason.  Status is
`mapped' for an explicit runtime mapping, `same-runtime' when no mappings are
configured and Pi is therefore assumed to share Emacs's filesystem, or
`unavailable' when configured mappings do not cover the runtime path."
  (let* ((context (or context pichat-tool-enrichment-path-context))
         (resolution (pichat-path-resolve-from-runtime runtime-path context)))
    (list :status (plist-get resolution :status)
          :runtime-path runtime-path
          :host-path (plist-get resolution :path)
          :reason (plist-get resolution :reason))))

(defun pichat-tool-enrichment--positive-position (value)
  "Return VALUE as a positive integer position, or nil."
  (when (numberp value)
    (max 1 (truncate value))))

(defun pichat-tool-enrichment--line (kind args)
  "Derive a 1-based line for KIND from normalized ARGS."
  (or (pichat-tool-enrichment--positive-position (plist-get args :line))
      (and (eq kind 'read)
           (pichat-tool-enrichment--positive-position (plist-get args :offset)))
      (and (eq kind 'write) 1)))

(defun pichat-tool-enrichment--location (kind args resolution)
  "Derive a local location for KIND from normalized ARGS and RESOLUTION."
  (let ((host-path (plist-get resolution :host-path)))
    (when host-path
      (let* ((line (pichat-tool-enrichment--line kind args))
             (column
              (and line
                   (pichat-tool-enrichment--positive-position
                    (plist-get args :column)))))
        (list :path host-path :line line :column column)))))

(defun pichat-tool-enrichment-infer-old-text-location (old-text supplied-text)
  "Infer OLD-TEXT's unique 1-based location in SUPPLIED-TEXT.
Both strings are supplied by the caller; this function never reads a file.
Return a plist whose :status is `unique', `not-found', `non-unique', or
`unavailable'.  A unique result also contains :line and :column."
  (cond
   ((or (not (stringp supplied-text))
        (not (pichat-tool-enrichment--nonempty-string-p old-text)))
    (list :status 'unavailable))
   (t
    (let ((regexp (regexp-quote old-text))
          (start 0)
          matches)
      (while (and (< (length matches) 2)
                  (string-match regexp supplied-text start))
        (push (match-beginning 0) matches)
        (setq start (max (1+ (match-beginning 0)) (match-end 0))))
      (pcase (length matches)
        (0 (list :status 'not-found))
        (1
         (let* ((position (car matches))
                (prefix (substring supplied-text 0 position))
                (line (1+ (cl-count ?\n prefix)))
                (last-newline (cl-position ?\n prefix :from-end t))
                (column (1+ (- position (if last-newline (1+ last-newline) 0)))))
           (list :status 'unique :line line :column column)))
        (_ (list :status 'non-unique)))))))

(defun pichat-tool-enrichment--truncate (text limit)
  "Return TEXT truncated to LIMIT characters."
  (if (and (stringp text) (> (length text) limit))
      (concat (substring text 0 limit) "…")
    text))

(defun pichat-tool-enrichment--first-string-value (args)
  "Return the first non-empty string value in canonical ARGS."
  (cl-loop for (nil value) on args by #'cddr
           when (pichat-tool-enrichment--nonempty-string-p value)
           return value))

(defun pichat-tool-enrichment-title (kind name args resolution location)
  "Return a concise title from KIND, NAME, canonical ARGS and location data."
  (let* ((host-path (plist-get resolution :host-path))
         (runtime-path (plist-get resolution :runtime-path))
         (path (or host-path runtime-path))
         (line (or (plist-get location :line)
                   (pichat-tool-enrichment--line kind args))))
    (pcase kind
      ('execute
       (let ((command (plist-get args :command)))
         (if (pichat-tool-enrichment--nonempty-string-p command)
             (pichat-tool-enrichment--truncate command 80)
           name)))
      ((or 'read 'edit 'write)
       (cond ((and path line) (format "%s:%d" path line))
             (path path)
             (t name)))
      ('search
       (let ((pattern (plist-get args :pattern)))
         (if (pichat-tool-enrichment--nonempty-string-p pattern)
             (format "%s in %s" pattern (or (plist-get args :path) "."))
           name)))
      ('fetch (or (plist-get args :url) (plist-get args :query) name))
      (_
       (if-let ((value (pichat-tool-enrichment--first-string-value args)))
           (format "%s %s" (or name "tool")
                   (pichat-tool-enrichment--truncate value 60))
         name)))))

(defun pichat-tool-enrichment-build (tool-call-id name args &optional context)
  "Build an enrichment record using optional immutable path CONTEXT."
  (let* ((arguments (pichat-tool-enrichment-normalize-arguments args))
         (kind (pichat-tool-enrichment-classify name))
         (file-oriented-p (memq kind '(read edit write)))
         (runtime-path (and file-oriented-p (plist-get arguments :path)))
         (resolution (and file-oriented-p
                          (pichat-tool-enrichment-resolve-runtime-path
                           runtime-path context)))
         (location (and resolution
                        (pichat-tool-enrichment--location
                         kind arguments resolution))))
    (list :tool-call-id tool-call-id
          :path-context context
          :name (and (pichat-tool-enrichment--nonempty-string-p name) name)
          :arguments arguments
          :kind kind
          :title (pichat-tool-enrichment-title
                  kind name arguments resolution location)
          :runtime-path runtime-path
          :path-status (and resolution (plist-get resolution :status))
          :host-path (and resolution (plist-get resolution :host-path))
          :line (and location (plist-get location :line))
          :column (and location (plist-get location :column))
          :unavailable-reason
          (and resolution (plist-get resolution :reason)))))

(defun pichat-tool-enrichment-merge (old new)
  "Monotonically merge enrichment records OLD and NEW.
Missing names and arguments in partial or reordered updates cannot erase known
metadata.  Derived values are recomputed from the accumulated inputs."
  (cond
   ((null old) new)
   ((null new) old)
   (t
    (let* ((old-id (plist-get old :tool-call-id))
           (new-id (plist-get new :tool-call-id)))
      (when (and old-id new-id (not (equal old-id new-id)))
        (error "Cannot merge different tool calls: %S and %S" old-id new-id))
      (pichat-tool-enrichment-build
       (or old-id new-id)
       (or (and (pichat-tool-enrichment--nonempty-string-p
                 (plist-get new :name))
                (plist-get new :name))
           (plist-get old :name))
       (pichat-tool-enrichment--merge-plists
        (plist-get old :arguments)
        (plist-get new :arguments))
       (or (plist-get new :path-context)
           (plist-get old :path-context)))))))

(provide 'pichat-tool-enrichment)
;;; pichat-tool-enrichment.el ends here
