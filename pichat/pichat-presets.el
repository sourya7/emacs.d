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
  "Ordered alist mapping programmatic preset names to configuration plists.
Use `pichat-make-preset' to register entries.  Definitions saved from the
launcher live separately in `pichat-saved-presets'; see
`pichat-presets-entries' for the effective registry.")

(defcustom pichat-saved-presets nil
  "Named preset definitions saved from the launcher's Save preset as action.
An alist of (NAME . PLIST) entries using the `pichat-make-preset' keys.  The
value is plain data persisted through `custom-file'; it may be loaded before
PiChat, and is validated when a preset is resolved.  A saved definition takes
precedence over a programmatic definition with the same name."
  :type '(alist :key-type (symbol :tag "Name")
                :value-type (plist :tag "Definition"))
  :group 'pichat-presets)

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

(defun pichat-presets-mcp-name (server tool)
  "Return Pi's unambiguous MCP name for SERVER and original TOOL.
Reject normalized collisions against the complete server catalogue first:
Pi hash-suffixes both members of a collision."
  (concat "mcp__" (replace-regexp-in-string "[^A-Za-z0-9_]" "_" server)
          "__" (replace-regexp-in-string "[^A-Za-z0-9_]" "_" tool)))

(defun pichat-presets-mcp-pairs-p (pairs)
  "Return non-nil for a unique proper list of exact MCP (SERVER . TOOL) PAIRS.
Normalized Pi names must also be unique."
  (and (proper-list-p pairs)
       (cl-every (lambda (pair)
                   (and (consp pair) (stringp (car pair))
                        (string-match-p "\\`[A-Za-z0-9_-]+\\'" (car pair))
                        (stringp (cdr pair)) (not (string-empty-p (cdr pair)))))
                 pairs)
       (= (length pairs)
          (length (cl-remove-duplicates (copy-tree pairs) :test #'equal)))
       (let ((names (mapcar (lambda (pair)
                              (pichat-presets-mcp-name (car pair) (cdr pair)))
                            pairs)))
         (= (length names) (length (delete-dups (copy-sequence names)))))))

(defun pichat-presets-model-p (value)
  "Return non-nil if VALUE is an exact provider/model reference.
Thinking-level suffixes are rejected, as for authored job definitions."
  (and (stringp value)
       (string-match-p "\\`[^/[:space:]]+/[^[:space:]]+\\'" value)
       (not (string-match-p
             ":\\(?:off\\|minimal\\|low\\|medium\\|high\\|xhigh\\|max\\)\\'" value))))

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
        (unless (and rest (memq key '(:description :tools :extensions :emacs-tools
                                     :mcp :model
                                     :system-prompt :append-system-prompt)))
          (user-error "Invalid PiChat preset key or plist: %S" key))
        (let ((value (pop rest)))
          (pcase key
            (:description
             (unless (or (null value) (stringp value))
               (user-error "Invalid preset description")))
            (:extensions
             (unless (pichat-presets-extension-names-p value)
               (user-error "Invalid or duplicate preset extension tools")))
            (:emacs-tools
             (unless (pichat-presets-extension-names-p value)
               (user-error "Invalid or duplicate preset Emacs-defined tools")))
            (:mcp
             (unless (pichat-presets-mcp-pairs-p value)
               (user-error "Invalid or duplicate preset MCP tools: %S" value)))
            (:model
             (unless (or (null value) (eq value 'default)
                         (pichat-presets-model-p value))
               (user-error "Invalid preset model; use provider/model or default: %S"
                           value)))
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
  (when (and (plist-get spec :emacs-tools)
             (or (not (plist-member spec :tools))
                 (eq (plist-get spec :tools) :default)))
    (user-error "Emacs-defined tool baselines require an explicit built-in tool preset"))
  (when (and (plist-get spec :mcp)
             (or (not (plist-member spec :tools))
                 (eq (plist-get spec :tools) :default)))
    (user-error "MCP baselines require an explicit built-in tool preset"))
  (when (cl-intersection (plist-get spec :emacs-tools) (plist-get spec :extensions)
                         :test #'equal)
    (user-error "Tool selected as both Emacs-defined and extension"))
  (let ((names (mapcar (lambda (pair) (pichat-presets-mcp-name (car pair) (cdr pair)))
                       (plist-get spec :mcp))))
    (when (cl-intersection names (append (plist-get spec :extensions)
                                         (plist-get spec :emacs-tools))
                           :test #'equal)
      (user-error "Tool selected as both MCP and extension or Emacs-defined")))
  spec)

(defun pichat-presets-entries ()
  "Return the effective ordered alist of named preset definitions.
Programmatic `pichat-presets' order is kept; a saved definition replaces a
programmatic one of the same name in place, and other saved names follow in
`pichat-saved-presets' order.  The result shares structure; copy before use."
  (let ((saved (cl-remove-if-not (lambda (entry) (and (consp entry) (symbolp (car entry))))
                                 pichat-saved-presets)))
    (append (mapcar (lambda (entry) (or (assq (car entry) saved) entry))
                    pichat-presets)
            (cl-remove-if (lambda (entry) (assq (car entry) pichat-presets))
                          saved))))

(defun pichat-presets-names ()
  "Return the names of all effective presets, in registry order."
  (mapcar #'car (pichat-presets-entries)))

(defun pichat-presets-defined-p (name)
  "Return non-nil when NAME is an effective preset."
  (and (symbolp name) name (assq name (pichat-presets-entries)) t))

(defun pichat-presets-saved-p (name)
  "Return non-nil when NAME has a definition saved from the launcher."
  (and (assq name pichat-saved-presets) t))

(defun pichat-make-preset (name &rest keys)
  "Register PiChat preset NAME with KEYS.
Supported keys are :description, :tools, :extensions, :emacs-tools, :mcp,
:model, :system-prompt and :append-system-prompt.  Prompt sources are text,
(:file ABSOLUTE-PATH), or an ordered list of these.  Nil tools means no
built-in tools; omitted or :default tools leaves Pi's default selection
alone.  :extensions supplies an explicit baseline of exact extension tool
names; it defaults to none.  :emacs-tools likewise lists exact
Emacs-defined tool names exposed through the PiChat bridge; it defaults to
none and, like :extensions, requires explicit built-in tools.  Pass-through
presets expose no Emacs-defined tools.  :mcp lists exact (SERVER . TOOL)
pairs selected by default; it also requires explicit built-in tools, and
omitting it keeps MCP disabled.  :model is an exact provider/model used for
runtimes launched by naming this preset, or `default' for Pi's normal model
policy (the same as omitting it).

A definition saved from the launcher with the same name takes precedence;
see `pichat-saved-presets'."
  (declare (indent 1))
  (pichat-presets--validate name keys)
  (let ((entry (assq name pichat-presets)))
    (if entry (setcdr entry (pichat-presets--copy keys))
      (setq pichat-presets (append pichat-presets
                                   (list (cons name (pichat-presets--copy keys)))))))
  name)

(defun pichat-get-preset (name)
  "Return a copy of effective preset NAME's definition, or nil if unknown."
  (when-let* ((entry (and (symbolp name) name
                          (assq name (pichat-presets-entries)))))
    (pichat-presets--copy (cdr entry))))

(defun pichat-presets-model (name)
  "Return effective preset NAME's model policy: a provider/model or `default'."
  (let ((model (plist-get (pichat-get-preset name) :model)))
    (if (stringp model) model 'default)))

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
  (unless (pichat-presets-defined-p name)
    (user-error "Unknown PiChat preset: %S" name))
  (let ((spec (pichat-get-preset name)))
    (pichat-presets--validate name spec)
    (pichat-presets--validate
     name (list :append-system-prompt pichat-append-system-prompt))
    (append
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
                             source))))
     ;; Omitted when empty so existing snapshots remain unchanged.
     (when-let* ((names (plist-get spec :emacs-tools)))
       (list :emacs-tools (pichat-presets--copy names)))
     (when-let* ((pairs (plist-get spec :mcp)))
       (list :mcp (pichat-presets--copy pairs)))
     ;; Informational only: launch selects a model from the profile, and
     ;; reconfiguration keeps the runtime's active model.
     (when (stringp (plist-get spec :model))
       (list :model (copy-sequence (plist-get spec :model)))))))

(defun pichat-presets-overrides-p (snapshot)
  "Return non-nil when SNAPSHOT changes Pi tools or prompt."
  (and snapshot
       (or (not (eq (plist-get snapshot :tools) :default))
           (plist-get snapshot :system-prompt)
           (plist-get snapshot :append-system-prompt))))

;;; Saved definitions

(defconst pichat-presets--reserved-names '(default prompt)
  "Names with launcher or job meaning that cannot name a saved preset.")

(defun pichat-presets-read-name (string)
  "Return the preset name symbol for user-entered STRING, or signal."
  (let ((text (string-trim (or string ""))))
    (unless (and (<= 1 (length text) 64)
                 (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_.-]*\\'" text))
      (user-error "Preset names use letters, digits, `-', `_' or `.' (at most 64)"))
    (let ((name (intern text)))
      (when (memq name pichat-presets--reserved-names)
        (user-error "`%s' is reserved; choose another preset name" text))
      name)))

(defun pichat-presets--custom-forms (file)
  "Return FILE's top-level `custom-set-variables' entries as an alist.
Each element is (SYMBOL . VALUE-FORM).  Signal when FILE cannot be parsed or
holds more than one `custom-set-variables' form, since Custom would then
rewrite an ambiguous structure."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let (forms)
        (condition-case err
            (while (progn (forward-comment (buffer-size)) (not (eobp)))
              (let ((form (read (current-buffer))))
                (when (eq (car-safe form) 'custom-set-variables)
                  (push form forms))))
          (error (user-error "Cannot parse %s: %s" file (error-message-string err))))
        (when (cdr forms)
          (user-error "%s has several custom-set-variables forms; merge them first" file))
        (mapcar (lambda (entry)
                  (let ((spec (and (eq (car-safe entry) 'quote) (cadr entry))))
                    (unless (and (consp spec) (symbolp (car spec)))
                      (user-error "Unrecognized custom-set-variables entry in %s" file))
                    (cons (car spec) (cadr spec))))
                (cdar forms))))))

(declare-function custom-file "cus-edit" (&optional no-error))

(defun pichat-presets--check-custom-file ()
  "Return the custom file presets are saved to, or signal why it is unsafe."
  (require 'cus-edit)
  (unless (and custom-file (custom-file t))
    (user-error "Saving presets requires `custom-file' (Emacs started without an init file?)"))
  (let* ((file (custom-file))
         (buffer (find-buffer-visiting file)))
    (when buffer
      (when (buffer-modified-p buffer)
        (user-error "Save or revert %s before saving a preset" (buffer-name buffer)))
      (unless (verify-visited-file-modtime buffer)
        (user-error "%s changed on disk; revert %s before saving a preset"
                    file (buffer-name buffer))))
    ;; Custom rewrites every saved variable from memory.  Refuse when the file
    ;; holds saved values this Emacs does not, for example after another
    ;; instance saved, rather than silently discarding them.
    (dolist (entry (pichat-presets--custom-forms file))
      (unless (equal (cdr entry) (car (get (car entry) 'saved-value)))
        (user-error "%s has saved settings this Emacs has not loaded (%s); reload it first"
                    file (car entry))))
    file))

(defun pichat-presets-save-definition (name spec)
  "Save preset NAME with definition SPEC to `custom-file' and register it.
SPEC uses the `pichat-make-preset' keys.  Replace an existing saved entry of
the same name in place, or append one.  Only `pichat-saved-presets' is newly
saved; other unsaved Custom changes are not written.  On any failure the
registry, saved definitions and Custom state are left unchanged.  Return the
file written.  Callers confirm replacing an existing name."
  (unless (and (symbolp name) name (not (memq name pichat-presets--reserved-names)))
    (user-error "Invalid PiChat preset name: %S" name))
  (pichat-presets--validate name spec)
  (let* ((file (pichat-presets--check-custom-file))
         (symbol 'pichat-saved-presets)
         (old-value (pichat-presets--copy pichat-saved-presets))
         (properties '(saved-value theme-value customized-value variable-comment
                       saved-variable-comment customized-variable-comment))
         (old-properties (mapcar (lambda (property)
                                   (cons property (copy-tree (get symbol property))))
                                 properties))
         (entry (cons name (pichat-presets--copy spec)))
         (value (if (assq name old-value)
                    (mapcar (lambda (item) (if (eq (car item) name) entry item))
                            old-value)
                  (append old-value (list entry)))))
    (condition-case err
        (progn (customize-save-variable symbol value) file)
      ((error quit)
       (set-default symbol old-value)
       (dolist (property old-properties)
         (put symbol (car property) (cdr property)))
       (signal (car err) (cdr err))))))

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
