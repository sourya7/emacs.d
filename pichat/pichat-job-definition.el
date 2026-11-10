;;; pichat-job-definition.el --- Authored job data and discovery -*- lexical-binding: t; -*-

;;; Commentary:
;; Read untrusted local data only.  No store, launch, executor or UI dependency.
;; Discovery is not import or execution authorization.  Callers select the
;; execution project explicitly; nil roots omit scopes, never imply user state.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'pichat-pi-environment)

(define-error 'pichat-job-definition-error "Invalid authored PiChat job")
(defconst pichat-job-definition-max-bytes (* 256 1024))

(defun pichat-job-definition--fail (format-string &rest args)
  "Signal a definition error using FORMAT-STRING and ARGS."
  (signal 'pichat-job-definition-error (list (apply #'format format-string args))))

(defun pichat-job-definition--unicode-p (text)
  "Whether TEXT contains only Unicode scalar values, without raw byte escapes."
  (seq-every-p (lambda (char) (and (<= char #x10ffff)
                                  (not (<= #xd800 char #xdfff)))) text))

(defun pichat-job-definition--object (object allowed)
  "Check OBJECT for duplicate or unknown keys outside ALLOWED."
  (unless (listp object)
    (pichat-job-definition--fail "Expected a JSON object"))
  (let (seen)
    (dolist (entry object)
      (let ((key (car entry)))
        (unless (member key allowed)
          (pichat-job-definition--fail "Unknown field: %.80s" key))
        (when (member key seen)
          (pichat-job-definition--fail "Duplicate field: %s" key))
        (push key seen)))))

(defun pichat-job-definition--text (object key limit)
  "Return required nonblank OBJECT field KEY, bounded by LIMIT characters."
  (let ((value (cdr (assoc key object))))
    (unless (and (stringp value) (pichat-job-definition--unicode-p value)
                 (not (string-blank-p value))
                 (<= (length value) limit) (not (string-match-p "\0" value)))
      (pichat-job-definition--fail "Field %s must be nonblank text (at most %s characters, no NUL)"
                                   key limit))
    value))

(defun pichat-job-definition-parse (text)
  "Parse strict authored JSON TEXT into a detached validated plist.
Reject duplicate/unknown fields, invalid Unicode and oversized input.  This
validates data shape only: named presets/targets are resolved at explicit
import."
  (unless (and (stringp text) (<= (string-bytes text) pichat-job-definition-max-bytes))
    (pichat-job-definition--fail "Definition must be JSON, at most 256 KiB of UTF-8"))
  ;; json-serialize returns UTF-8 bytes; buffer callers normally supply decoded
  ;; text.  Normalize once so both native and Lisp readers see the same Unicode.
  (unless (multibyte-string-p text)
    (setq text (decode-coding-string text 'utf-8-unix)))
  (unless (pichat-job-definition--unicode-p text)
    (pichat-job-definition--fail "Definition must be strict UTF-8 Unicode JSON"))
  (condition-case err
      ;; The native parser enforces strict JSON syntax.  Read a second time with
      ;; string keys to retain duplicate members without interning untrusted keys.
      (let* ((case-fold-search nil)
             (_ (json-parse-string text :object-type 'hash-table))
             (json-object-type 'alist) (json-key-type 'string)
             (json-array-type 'vector) (json-null :null) (json-false :false)
             (data (json-read-from-string text)))
        (pichat-job-definition--object
         data '("version" "id" "title" "instructions" "directory" "model" "preset" "target"
                "input" "after_job"))
        (unless (eql (cdr (assoc "version" data)) 1)
          (pichat-job-definition--fail "Field version must be integer 1"))
        (let* ((id (pichat-job-definition--text data "id" 64))
               (title (pichat-job-definition--text data "title" 200))
               (instructions (pichat-job-definition--text data "instructions" 131072))
               (model (pichat-job-definition--text data "model" 1024))
               (preset (pichat-job-definition--text data "preset" 200))
               (result (list :version 1 :id id :title title :instructions instructions
                             :model model :preset preset)))
          (unless (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" id)
            (pichat-job-definition--fail "Field id must be lowercase kebab-case"))
          (unless (and (string-match-p "\\`[^/[:space:]]+/[^[:space:]]+\\'" model)
                       (not (string-match-p
                             ":\\(?:off\\|minimal\\|low\\|medium\\|high\\|xhigh\\|max\\)\\'" model)))
            (pichat-job-definition--fail "Field model must be provider/model without a thinking suffix"))
          (when (or (member preset '("default" "prompt"))
                    (string-match-p "[[:space:]]" preset))
            (pichat-job-definition--fail "Field preset must name an explicit preset"))
          (when (assoc "directory" data)
            (let ((directory (pichat-job-definition--text data "directory" 4096)))
              (when (or (string-prefix-p "~" directory) (file-remote-p directory))
                (pichat-job-definition--fail "Field directory must be local Emacs-visible text, without tilde expansion"))
              (setq result (append result (list :directory directory)))))
          (when (assoc "target" data)
            (let ((target (cdr (assoc "target" data))))
              (pichat-job-definition--object target '("name"))
              (let ((name (pichat-job-definition--text target "name" 200)))
                (when (or (member name '("inferred" "default" "prompt"))
                          (string-match-p "[[:space:]]" name))
                  (pichat-job-definition--fail "Field target.name must be local or an explicit configured name"))
                (setq result (append result (list :target (list :name name)))))))
          (when (assoc "input" data)
            (let ((prompt (pichat-job-definition--text data "input" 200)))
              (when (string-match-p "[\n\r]" prompt)
                (pichat-job-definition--fail "Field input must be a single-line prompt"))
              (setq result (append result (list :input prompt)))))
          (when (assoc "after_job" data)
            (let ((link (cdr (assoc "after_job" data))))
              (pichat-job-definition--object link '("scope" "id"))
              (let ((scope (pichat-job-definition--text link "scope" 16))
                    (target (pichat-job-definition--text link "id" 64)))
                (unless (member scope '("global" "project"))
                  (pichat-job-definition--fail "Field after_job.scope must be global or project"))
                (unless (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" target)
                  (pichat-job-definition--fail "Field after_job.id must be a lowercase kebab-case authored ID"))
                (setq result (append result (list :after-job (list :scope scope :id target)))))))
          result))
    (pichat-job-definition-error (signal (car err) (cdr err)))
    (error (pichat-job-definition--fail "Invalid JSON: %.400s" (error-message-string err)))))

(defun pichat-job-definition-agent-directory ()
  "Return the local agent directory using PiChat's effective environment.
Like local settings discovery, honor configured PI_CODING_AGENT_DIR overrides.
This only resolves a path; it does not scan files or infer an execution target."
  (file-name-as-directory
   (expand-file-name (or (pichat-pi-getenv "PI_CODING_AGENT_DIR") "~/.pi/agent"))))

(defun pichat-job-definition--read (file)
  "Read bounded regular local FILE as strict UTF-8, without file hooks."
  (when (file-symlink-p file)
    (pichat-job-definition--fail "Symbolic-link definition files are unsupported"))
  (let ((attrs (file-attributes file)))
    (unless (and attrs (file-regular-p file) (file-readable-p file)
                 (<= (file-attribute-size attrs) pichat-job-definition-max-bytes))
      (pichat-job-definition--fail "Definition must be a readable regular file, at most 256 KiB")))
  (let* ((bytes (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally file nil 0 (1+ pichat-job-definition-max-bytes))
                  (buffer-string)))
         (text (decode-coding-string bytes 'utf-8-unix)))
    (unless (and (<= (length bytes) pichat-job-definition-max-bytes)
                 (pichat-job-definition--unicode-p text)
                 (equal bytes (encode-coding-string text 'utf-8-unix)))
      (pichat-job-definition--fail "Definition must be strict UTF-8, at most 256 KiB"))
    (when (file-symlink-p file)
      (pichat-job-definition--fail "Definition became a symbolic link while reading"))
    (pichat-job-definition-parse text)))

(defun pichat-job-definition--record (file scope root)
  "Read FILE in SCOPE at canonical ROOT and attach provenance and cwd."
  (let* ((definition (pichat-job-definition--read file))
         (directory (plist-get definition :directory)))
    (when (and (equal scope "global")
               (not (and directory (file-name-absolute-p directory))))
      (pichat-job-definition--fail "Global jobs require an explicit absolute directory"))
    (when-let* ((link (plist-get definition :after-job)))
      ;; A global file has no repository, so it may only name another global job.
      (when (and (equal scope "global") (equal (plist-get link :scope) "project"))
        (pichat-job-definition--fail "Global jobs can only name a global after_job"))
      (when (and (equal scope (plist-get link :scope))
                 (equal (plist-get definition :id) (plist-get link :id)))
        (pichat-job-definition--fail "Field after_job cannot name this job itself")))
    (list :scope scope :root root :file file
          :identity (vector scope root (plist-get definition :id))
          :definition definition
          :directory (file-name-as-directory (expand-file-name (or directory ".") root)))))

(defun pichat-job-definition--diagnostic (file err)
  "Make a bounded diagnostic for FILE and condition ERR."
  (let ((message (error-message-string err)))
    (list :file file :message (substring message 0 (min 512 (length message))))))

(defun pichat-job-definition--scan (directory scope root)
  "Scan DIRECTORY in SCOPE at ROOT, returning (RECORDS DIAGNOSTICS)."
  (let ((case-fold-search nil) records diagnostics)
    (condition-case err
        (progn
          (when (or (file-symlink-p (directory-file-name directory))
                    (and (equal scope "project")
                         (file-symlink-p (expand-file-name ".pi" root))))
            (pichat-job-definition--fail "Symbolic-link job resource directories are unsupported"))
          ;; Check the known parent too: an inaccessible .pi directory must
          ;; not turn an unstatable jobs/ child into an apparently missing root.
          (let ((parent (file-name-directory (directory-file-name directory))))
            (when (and (file-exists-p parent)
                       (not (and (file-directory-p parent) (file-readable-p parent)
                                 (file-accessible-directory-p parent))))
              (pichat-job-definition--fail "Job resource parent must be readable and searchable")))
          (when (file-exists-p directory)
            (unless (and (file-directory-p directory) (file-readable-p directory)
                         (file-accessible-directory-p directory))
              (pichat-job-definition--fail "Job resource directory must be readable and searchable"))
            (dolist (file (directory-files directory t "\\`[^.].*\\.json\\'"))
              (condition-case file-error
                  (push (pichat-job-definition--record file scope root) records)
                (error (push (pichat-job-definition--diagnostic file file-error) diagnostics))))))
      (error (push (pichat-job-definition--diagnostic directory err) diagnostics)))
    (list (nreverse records) (nreverse diagnostics))))

(defun pichat-job-definition-discover (agent-directory project-root)
  "Discover authored jobs in explicit local AGENT-DIRECTORY and PROJECT-ROOT.
Nil omits that scope.  Return :definitions and :diagnostics vectors.  Each
record carries scope-qualified identity, file provenance, parsed data and
project-relative resolved directory.  Invalid siblings do not hide valid files;
all same-scope duplicate ID claimants are excluded with diagnostics.
Never initializes a store, resolves launch settings, spawns Pi or writes files."
  ;; Reject unsupported source hosts before any filesystem operation, even when
  ;; the other scope is local.  Never silently search a different project/host.
  (dolist (root (list agent-directory project-root))
    (when (and root (or (not (stringp root)) (file-remote-p root)
                       (not (file-name-absolute-p root))))
      (pichat-job-definition--fail "Source root must be an absolute local path")))
  (let (records diagnostics)
    (dolist (entry (list (list "global" agent-directory "jobs/")
                         (list "project" project-root ".pi/jobs/")))
      (pcase-let ((`(,scope ,root ,suffix) entry))
        (when root
          (condition-case err
              (let* ((_ (when (and (file-exists-p root)
                                   (not (and (file-directory-p root) (file-readable-p root)
                                             (file-accessible-directory-p root))))
                          (pichat-job-definition--fail "Source root must be a readable, searchable directory")))
                     (canonical (file-name-as-directory (file-truename root)))
                     (scan (pichat-job-definition--scan
                            (expand-file-name suffix canonical) scope canonical)))
                (setq records (append records (car scan))
                      diagnostics (append diagnostics (cadr scan))))
            (error (setq diagnostics
                         (append diagnostics (list (pichat-job-definition--diagnostic root err)))))))))
    (let ((counts (make-hash-table :test #'equal)) valid)
      (dolist (record records)
        (let ((key (plist-get record :identity)))
          (puthash key (1+ (gethash key counts 0)) counts)))
      (dolist (record records)
        (if (> (gethash (plist-get record :identity) counts) 1)
            (setq diagnostics
                  (append diagnostics
                          (list (list :file (plist-get record :file)
                                      :message "Duplicate authored ID in this scope; give files distinct IDs or remove duplicate files"))))
          (push record valid)))
      (list :definitions (vconcat (nreverse valid))
            :diagnostics (vconcat diagnostics)))))

(provide 'pichat-job-definition)
;;; pichat-job-definition.el ends here
