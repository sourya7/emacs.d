;;; pichat-presets.el --- Launch-time Pi tool and prompt presets -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup pichat-presets nil "PiChat runtime presets." :group 'pichat)

(defcustom pichat-default-preset 'manual
  "Preset used when creating a runtime without an explicit selection."
  :type 'symbol :group 'pichat-presets)

(defcustom pichat-append-system-prompt nil
  "Shared instructions appended after every preset's prompt additions.
Accepts literal text, (:file ABSOLUTE-PATH), an ordered list of these,
or nil.  Files are read by Emacs when resolving a preset.  The combined
text is captured in the runtime snapshot and sent with one
--append-system-prompt argument; existing runtimes are not changed.
A preset's replacement system prompt remains separate."
  :type '(choice (const :tag "None" nil)
                 (string :tag "Text")
                 (list :tag "File" (const :file) file)
                 (repeat :tag "Fragments"
                         (choice string (list (const :file) file))))
  :group 'pichat-presets)

(defvar pichat-presets nil
  "Ordered alist mapping preset names to configuration plists.")

(defconst pichat-presets--built-in-tools
  '("read" "grep" "find" "ls" "edit" "write" "bash")
  "Built-in Pi tools supported by PiChat presets.")

(defconst pichat-presets--known-built-in-tools
  (append pichat-presets--built-in-tools '("powershell"))
  "Known Pi built-ins, including those not offered by PiChat presets.
Keep catalogue partitioning and extension opt-in from bypassing the preset
boundary.  Pi 1.4.0 lists powershell even in a non-Windows catalogue.")

(defun pichat-presets-extension-names-p (names)
  "Return non-nil for a unique list of exact custom tool NAMES.
Built-ins cannot be opted into through the extension policy."
  (and (proper-list-p names)
       (cl-every (lambda (name)
                   (and (stringp name) (<= 1 (length name) 256)
                        (string-match-p "\\`[A-Za-z0-9_-]+\\'" name)
                        (not (member name pichat-presets--known-built-in-tools)))) names)
       (= (length names) (length (delete-dups (copy-sequence names))))))

(defun pichat-presets--source-p (value)
  "Return non-nil if VALUE is a valid prompt source."
  (or (and (stringp value) (not (string-blank-p value)))
      (and (listp value) (= (length value) 2)
           (eq (car value) :file)
           (stringp (cadr value)) (file-name-absolute-p (cadr value)))))

(defun pichat-presets--copy (value)
  "Copy preset VALUE, including mutable strings."
  (cond ((stringp value) (copy-sequence value))
        ((consp value) (cons (pichat-presets--copy (car value))
                             (pichat-presets--copy (cdr value))))
        (t value)))

(defun pichat-presets--validate (name spec)
  "Validate preset NAME and SPEC, without reading source files."
  (unless (and (symbolp name) name (not (keywordp name)) (not (eq name 'default)))
    (user-error "Invalid PiChat preset name: %S" name))
  (let ((rest spec) seen)
    (while rest
      (let ((key (pop rest)))
        (when (memq key seen)
          (user-error "Duplicate PiChat preset key: %S" key))
        (push key seen)
        (unless (and rest (memq key '(:description :tools :extensions :system-prompt
                                     :append-system-prompt)))
          (user-error "Invalid PiChat preset key or plist: %S" key))
        (let ((value (pop rest)))
          (pcase key
            (:description
             (unless (or (null value) (stringp value))
               (user-error "Invalid preset description")))
            (:extensions
             (unless (pichat-presets-extension-names-p value)
               (user-error "Invalid or duplicate preset extension tools")))
            (:tools
             (unless (or (null value) (eq value :default)
                         (and (consp value) (proper-list-p value)
                              (cl-every (lambda (tool)
                                          (member tool pichat-presets--built-in-tools))
                                        value)))
               (user-error "Invalid preset tools: %S" value)))
            (_ (unless (or (null value)
                           (pichat-presets--source-p value)
                           (and (consp value) (proper-list-p value)
                                (cl-every #'pichat-presets--source-p value)))
                 (user-error "Invalid preset prompt source: %S" value))))))))
  (when (and (plist-get spec :extensions)
             (or (not (plist-member spec :tools))
                 (eq (plist-get spec :tools) :default)))
    (user-error "Extension baselines require an explicit built-in tool preset"))
  spec)

(defun pichat-make-preset (name &rest keys)
  "Register PiChat preset NAME with KEYS.
Supported keys are :description, :tools, :extensions, :system-prompt and
:append-system-prompt.  Prompt sources are text, (:file ABSOLUTE-PATH),
or an ordered list of these.  Nil tools means no built-in tools; omitted
or :default tools leaves Pi's default selection alone.  :extensions supplies
an explicit baseline of exact extension tool names; it defaults to none."
  (declare (indent 1))
  (pichat-presets--validate name keys)
  (let ((entry (assq name pichat-presets)))
    (if entry (setcdr entry (pichat-presets--copy keys))
      (setq pichat-presets (append pichat-presets
                                   (list (cons name (pichat-presets--copy keys)))))))
  name)

(defun pichat-get-preset (name)
  "Return a copy of named preset NAME, or nil if unknown."
  (when-let* ((entry (assq name pichat-presets)))
    (pichat-presets--copy (cdr entry))))

(defun pichat-presets--prompt (source)
  "Resolve SOURCE to literal text at launch."
  (when source
    (let ((fragments (if (pichat-presets--source-p source)
                         (list source) source)))
      (concat (string-join
               (mapcar (lambda (fragment)
                 (if (stringp fragment) (copy-sequence fragment)
                   (let ((path (cadr fragment)))
                     (unless (file-readable-p path)
                       (user-error "Preset prompt file not readable: %s" path))
                     (let ((text (with-temp-buffer
                                   (insert-file-contents path)
                                   (buffer-string))))
                       (when (string-blank-p text)
                         (user-error "Preset prompt file is empty: %s" path))
                       text))))
               fragments)
               "\n\n") "\n"))))

(defun pichat-presets-resolve (name)
  "Resolve named preset NAME into a detached runtime snapshot."
  (unless (assq name pichat-presets)
    (user-error "Unknown PiChat preset: %S" name))
  (let ((spec (pichat-get-preset name)))
    (pichat-presets--validate name spec)
    (pichat-presets--validate
     name (list :append-system-prompt pichat-append-system-prompt))
    (list :name name :description (plist-get spec :description)
          :tools (if (plist-member spec :tools)
                     (let ((tools (plist-get spec :tools)))
                       (if (eq tools :default) :default
                         (cl-remove-duplicates (pichat-presets--copy tools)
                                               :test #'equal :from-end t)))
                   :default)
          :extensions (pichat-presets--copy (plist-get spec :extensions))
          :system-prompt (pichat-presets--prompt (plist-get spec :system-prompt))
          :append-system-prompt
          (pichat-presets--prompt
           (cl-loop for source in (list (plist-get spec :append-system-prompt)
                                        pichat-append-system-prompt)
                    append (if (pichat-presets--source-p source)
                               (list source)
                             source))))))

(defun pichat-presets-overrides-p (snapshot)
  "Return non-nil when SNAPSHOT changes Pi tools or prompt."
  (and snapshot
       (or (not (eq (plist-get snapshot :tools) :default))
           (plist-get snapshot :system-prompt)
           (plist-get snapshot :append-system-prompt))))

(pichat-make-preset 'manual
  :description "Inspect and edit files without built-in bash."
  :tools '("read" "grep" "find" "ls" "edit" "write"))
(pichat-make-preset 'coding
  :description "Implement changes and run checks."
  :tools '("read" "grep" "find" "ls" "edit" "write" "bash")
  :append-system-prompt "Inspect existing code before changing it. Make focused changes, run relevant checks, and report failures.")
(pichat-make-preset 'review
  :description "Review code with read-only built-in tools."
  :tools '("read" "grep" "find" "ls")
  :append-system-prompt "Review for correctness, regressions and missing tests. Report actionable findings with locations.")
(pichat-make-preset 'standard
  :description "Use Pi's normal prompt and default built-in tools."
  :tools :default)

(provide 'pichat-presets)
;;; pichat-presets.el ends here
