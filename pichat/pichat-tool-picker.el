;;; pichat-tool-picker.el --- Preset-aware Tools Transient -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'pichat-transient)
(require 'pichat-tool-selection)
(require 'pichat-mcp-discovery)
(require 'pichat-tool-discovery)
(require 'pichat-path)
(require 'pichat-tools)

(defvar pichat-tool-picker--state nil
  "Draft of the currently open Tools picker.")
(defconst pichat-tool-picker--keys
  (mapcar #'char-to-string (string-to-list "1234567890bcfghijklmopstuvwxyz")))
(defconst pichat-tool-picker--server-keys
  (mapcar #'char-to-string (string-to-list "ABCDEFGHIJKLMNOPQRSTUVWXYZ")))
(defconst pichat-tool-picker--page-size 20)

(defconst pichat-tool-picker--prefixes
  '(pichat-tool-picker pichat-tool-picker-server pichat-tool-picker-emacs-group
    pichat-tool-picker-extension-group)
  "Transient prefixes owned by the Tools picker.")

(defun pichat-tool-picker--refresh-display ()
  "Redisplay the current picker."
  (when (and transient--prefix
             (memq (oref transient--prefix command) pichat-tool-picker--prefixes))
    (transient--redisplay)))

(defun pichat-tool-picker--refresh-children ()
  "Rebuild visible dynamic choices."
  (when (and transient--prefix
             (memq (oref transient--prefix command) pichat-tool-picker--prefixes))
    (transient-setup (oref transient--prefix command) nil nil
                     :scope (oref transient--prefix scope))))

(defun pichat-tool-picker--description (checked label)
  "Return checkbox LABEL for CHECKED."
  (format "[%s] %s" (if checked "✓" " ") label))

(defun pichat-tool-picker--with-description (key head description)
  "Return HEAD, then as much of DESCRIPTION as fits after KEY in the frame.
HEAD carries the checkbox, name and state; the description is only a
reminder, so it is dropped when too little room is left for it."
  (let ((room (- (frame-width) 1 (+ 2 (string-width key)) (string-width head) 3)))
    (if (< room 8) head
      (concat head " — " (truncate-string-to-width description room nil nil "…")))))

(defun pichat-tool-picker--selection ()
  "Return the current Tools draft."
  (plist-get pichat-tool-picker--state :draft))

(defun pichat-tool-picker--set-selection (selection)
  "Store SELECTION without changing the launch configuration."
  (setf (plist-get pichat-tool-picker--state :draft) selection)
  (pichat-tool-picker--refresh-display))

(defun pichat-tool-picker--toggle (kind value)
  "Toggle VALUE under KIND in the draft."
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (values (plist-get selection kind)))
    (pichat-tool-picker--set-selection
     (plist-put selection kind
                (if (member value values) (cl-remove value values :test #'equal)
                  (append values (list value)))))))

(defun pichat-tool-picker--page-items (items)
  "Return the current page of ITEMS."
  (let ((start (* pichat-tool-picker--page-size
                  (or (plist-get pichat-tool-picker--state :page) 0))))
    (cl-subseq items (min start (length items))
               (min (+ start pichat-tool-picker--page-size) (length items)))))

(defun pichat-tool-picker--builtins (_)
  "Build the preset's built-in checkboxes."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for name in (plist-get pichat-tool-picker--state :baseline)
            for key in pichat-tool-picker--keys
            collect (let ((name name))
                      (list key name
                            (lambda () (interactive) (pichat-tool-picker--toggle :builtins name))
                            :description
                            (lambda () (pichat-tool-picker--description
                                        (member name (plist-get (pichat-tool-picker--selection) :builtins)) name))
                            :transient t)))))

(defun pichat-tool-picker--mcp-source-p (tool)
  "Return non-nil when Pi reports TOOL as registered by its built-in MCP."
  (let ((source (plist-get tool :source)))
    (and (equal (plist-get source :source) "builtin")
         (equal (plist-get source :path) "builtin:mcp"))))

(defun pichat-tool-picker--extension-tools ()
  "Return custom tools, excluding known built-in and MCP tools.
Exact known built-in and listed MCP names are excluded, and so are tools Pi
attributes to its built-in MCP (`builtin:mcp'), which belong under MCP
servers.  Do not guess provenance from prefixes.  Tools of MCP servers that
an extension registers may consequently appear here, under that extension."
  (let ((mcp-names (cl-loop for server in (plist-get pichat-tool-picker--state :servers)
                            append (mapcar (lambda (tool)
                                             (pichat-tool-selection--name
                                              (plist-get server :name) (plist-get tool :name)))
                                           (plist-get server :tools)))))
    (when-let* ((draft (plist-get pichat-tool-picker--state :discovery)))
      (cl-remove-if
       (lambda (tool) (or (member (plist-get tool :name)
                                 (append pichat-presets--known-built-in-tools mcp-names))
                         (pichat-tool-picker--mcp-source-p tool)))
       (pichat-tool-discovery-draft-tools draft)))))

;;; Extension tool groups

(defun pichat-tool-picker--grouped-p ()
  "Return non-nil when Pi reported provenance for some extension tool.
Older Pi reports none; the picker then keeps one flat checkbox list."
  (cl-some (lambda (tool) (plist-get tool :source))
           (pichat-tool-picker--extension-tools)))

;; Pi reports every extension loaded with `-e' as source `cli' with the
;; resolved path of its entry file, never the spec as typed (probed against
;; Pi 1.5.1).  An `npm:' or `git:' spec is installed into Pi's temporary
;; package cache, <agent>/tmp/extensions/npm/<hash>/node_modules/<name>/
;; and <agent>/tmp/extensions/git-<host>/<hash>/<owner>/<repo>/, where
;; <hash> is eight hexadecimal digits.

(defconst pichat-tool-picker--git-shortcut-hosts
  '(("github" . "github.com") ("gitlab" . "gitlab.com") ("bitbucket" . "bitbucket.org"))
  "Hosts of the git shortcut prefixes Pi accepts.")

(defconst pichat-tool-picker--package-cache-regexp
  "/tmp/extensions/\\(?:npm\\|git-[^/]+\\)/[0-9a-f]\\{8\\}/"
  "Match a path inside Pi's cache of packages loaded with `-e'.")

(defun pichat-tool-picker-package-spec-p (spec)
  "Return non-nil when extension SPEC names a package, not a path.
Pi installs `npm:' specs with npm and treats `git:', `github:', `http:',
`https:' and `ssh:' specs as git repositories; anything else is a path."
  (string-match-p "\\`\\(?:npm\\|git\\|github\\|http\\|https\\|ssh\\):" spec))

(defun pichat-tool-picker-resolve-path (path cwd local)
  "Return PATH resolved against CWD, without a trailing slash, or nil.
LOCAL non-nil means PATH is on this host: resolve symbolic links too.  A
remote PATH is a path on the target (passed to its Pi unchanged), so
only an absolute or relative path is resolved, never `~'."
  (cond
   (local (directory-file-name (file-truename (expand-file-name path cwd))))
   ((string-prefix-p "~" path) nil)
   (t (directory-file-name (expand-file-name path cwd)))))

(defun pichat-tool-picker--npm-name (spec)
  "Return the package name of `npm:' SPEC, as Pi parses it.
The name keeps a leading @scope and drops a trailing @version."
  (let ((spec (string-trim (substring spec (length "npm:")))))
    (if (string-match "\\`\\(@?[^@]+\\)\\(?:@.+\\)?\\'" spec)
        (match-string 1 spec)
      spec)))

(defun pichat-tool-picker--git-repository (spec)
  "Return (HOST . PATH) of git SPEC as Pi installs it, or nil.
PATH is the repository path, usually OWNER/REPO, without a @ref or
#committish and without a .git suffix."
  (let ((url (string-trim (string-remove-prefix "git:" spec))) host path)
    (cond
     ((string-match "\\`git@\\([^:/]+\\):\\(.+\\)\\'" url)
      (setq host (match-string 1 url) path (match-string 2 url)))
     ((string-match "\\`[a-z][a-z0-9+.-]*://\\(?:[^@/]*@\\)?\\([^/:]+\\)\\(?::[0-9]*\\)?/\\(.+\\)\\'" url)
      (setq host (match-string 1 url) path (match-string 2 url)))
     ((string-match "\\`\\([a-z]+\\):\\(.+\\)\\'" url)
      (setq host (cdr (assoc (match-string 1 url) pichat-tool-picker--git-shortcut-hosts))
            path (match-string 2 url)))
     ((string-match "\\`\\([^/]+\\)/\\(.+\\)\\'" url)
      (setq host (match-string 1 url) path (match-string 2 url))))
    (when (and host path)
      (setq path (replace-regexp-in-string "[#@].*\\'" "" path)
            path (replace-regexp-in-string "\\.git\\'" "" path)
            path (directory-file-name (string-trim-left path "/+")))
      (when (string-match-p "[^/]/[^/]" path)
        (cons host path)))))

(defun pichat-tool-picker-added-attribution (context)
  "Return how to attribute tools to the added extensions of CONTEXT, or nil.
CONTEXT is a discovery probe context; its :extensions are the specs
loaded with `-e'.  The result is a plist: :matchers, (SPEC KIND DATA)
where KIND is `npm' (DATA the package name), `git' (DATA (HOST . PATH))
or `path' (DATA the resolved path, nil when it cannot be resolved), and
:cwd and :local for resolving the tools' paths."
  (when-let* ((specs (plist-get context :extensions)))
    (let* ((cwd (or (plist-get context :cwd) default-directory))
           (transport (plist-get context :transport))
           (local (not (and (pichat-transport-p transport)
                            (eq 'ssh (pichat-transport-kind transport))))))
      (list :cwd cwd :local local
            :matchers
            (mapcar
             (lambda (spec)
               (cond
                ((string-prefix-p "npm:" spec)
                 (list spec 'npm (pichat-tool-picker--npm-name spec)))
                ((pichat-tool-picker-package-spec-p spec)
                 (list spec 'git (pichat-tool-picker--git-repository spec)))
                (t (list spec 'path
                         (ignore-errors (pichat-tool-picker-resolve-path spec cwd local))))))
             specs)))))

(defun pichat-tool-picker--added-extension (path attribution)
  "Return the added spec of ATTRIBUTION that Pi loaded from PATH, or nil.
PATH is the entry file Pi reports for a tool loaded with `-e'.  A path
spec matches its own resolved path, or for a directory any path below
it; the most specific (longest) one wins.  An `npm:' spec matches its
node_modules/<name>/ directory in Pi's package cache, a git spec its
git-<host>/<hash>/<owner>/<repo>/ directory."
  (let* ((local (plist-get attribution :local))
         (resolved (ignore-errors
                     (pichat-tool-picker-resolve-path
                      path (plist-get attribution :cwd) local)))
         best best-length)
    (pcase-dolist (`(,spec ,kind ,data) (plist-get attribution :matchers))
      (pcase kind
        ('npm
         (when (and (not best)
                    (string-match-p (concat "/npm/[0-9a-f]\\{8\\}/node_modules/"
                                            (regexp-quote data) "/")
                                    path))
           (setq best spec best-length most-positive-fixnum)))
        ('git
         (when (and data (not best)
                    (string-match-p (concat "/git-" (regexp-quote (car data))
                                            "/[0-9a-f]\\{8\\}/" (regexp-quote (cdr data)) "/")
                                    path))
           (setq best spec best-length most-positive-fixnum)))
        ('path
         (when (and data resolved
                    (or (equal resolved data)
                        (string-prefix-p (file-name-as-directory data) resolved))
                    (> (length data) (or best-length -1)))
           (setq best spec best-length (length data))))))
    best))

(defun pichat-tool-picker--extension-group-key (tool &optional attribution)
  "Return the group identity of extension TOOL from its provenance.
The identity is `:builtin' for tools shipped with Pi (\"Pi built-in\"),
and otherwise:
- for a tool loaded with `-e' (source `cli'): the added extension's spec
  exactly as given, when ATTRIBUTION (see
  `pichat-tool-picker-added-attribution') matches the tool's path to one;
- `:unattributed' without provenance, or for an unmatched `cli' tool in
  Pi's package cache (whose path names no stable extension);
- the package directory or file path for other extensions Pi loaded from a
  path (`cli', `local', `auto', `sdk' sources);
- the package source exactly as Pi reports it (for example
  `npm:name@1.2.3' or `git:github.com/owner/repo')."
  (let* ((info (plist-get tool :source))
         (source (plist-get info :source))
         (path (plist-get info :path)))
    (cond
     ((not info) :unattributed)
     ((equal source "builtin") :builtin)
     ((and (equal source "cli") attribution
           (pichat-tool-picker--added-extension path attribution)))
     ((and (equal source "cli")
           (string-match-p pichat-tool-picker--package-cache-regexp path))
      :unattributed)
     ((member source '("cli" "local" "auto" "sdk"))
      (or (plist-get info :base-dir) path))
     (t source))))

(defun pichat-tool-picker-group-tool-names (source tools &optional attribution)
  "Return the names of the eligible extension TOOLS in the group SOURCE.
SOURCE is a preset group source: a tool belongs to it when its group
identity (`pichat-tool-picker--extension-group-key' with ATTRIBUTION)
equals SOURCE, or, for a `builtin:' SOURCE, when Pi reports that path.
Known built-ins and tools of Pi's built-in MCP are never extension tools.
This expands a (SOURCE . :all) group to the tools discovered now."
  (cl-loop for tool in tools
           for info = (plist-get tool :source)
           when (and (plist-get tool :eligible)
                     (not (member (plist-get tool :name)
                                  pichat-presets--known-built-in-tools))
                     (not (pichat-tool-picker--mcp-source-p tool))
                     (or (equal source (pichat-tool-picker--extension-group-key
                                        tool attribution))
                         (and (equal (plist-get info :source) "builtin")
                              (equal (plist-get info :path) source))))
           collect (plist-get tool :name)))

(defun pichat-tool-picker-tool-sources (names draft)
  "Return (NAME . SOURCE) for each extension tool NAME as DRAFT groups it.
DRAFT is the discovery draft the Tools picker chose NAMES from.  SOURCE
is the preset group source of the tool's group in the picker
(`pichat-tool-picker--extension-group-key' with the draft's
added-extension attribution): an added spec exactly as given, a package
source, or a path; for \"Pi built-in\" the tool's `builtin:' path.  It is
nil when the source is not stable (\"Unattributed\"), the tool was not
discovered, or DRAFT is not ready.  Saving a preset groups NAMES by it."
  (let* ((ready (and draft (eq 'ready (pichat-tool-discovery-draft-status draft))))
         (tools (and ready (pichat-tool-discovery-draft-tools draft)))
         (attribution (and ready (pichat-tool-picker-added-attribution
                                  (pichat-tool-discovery-draft-context draft)))))
    (mapcar (lambda (name)
              (let* ((tool (cl-find name tools :key (lambda (tool) (plist-get tool :name))
                                    :test #'equal))
                     (key (and tool (pichat-tool-picker--extension-group-key
                                     tool attribution)))
                     (source (cond ((stringp key) key)
                                   ((eq key :builtin)
                                    (plist-get (plist-get tool :source) :path)))))
                (cons name (and (pichat-presets-extension-spec-p source)
                                (copy-sequence source)))))
            names)))

(defun pichat-tool-picker-expand-all (preset draft)
  "Return resolved PRESET with its :all groups expanded from DRAFT.
DRAFT is a ready discovery draft probed with the runtime's context; its
tools and added-extension attribution decide each group's current tools.
See `pichat-presets-expand-all'."
  (let ((tools (pichat-tool-discovery-draft-tools draft))
        (attribution (pichat-tool-picker-added-attribution
                      (pichat-tool-discovery-draft-context draft))))
    (pichat-presets-expand-all
     preset
     (mapcar (lambda (source)
               (cons source (pichat-tool-picker-group-tool-names
                             source tools attribution)))
             (pichat-presets-all-sources preset)))))

(defun pichat-tool-picker--extension-group-label (key)
  "Return a short label for group KEY: package or file name."
  (pcase key
    (:builtin "Pi built-in")
    (:unattributed "Unattributed")
    ((pred (lambda (key) (not (pichat-tool-picker-package-spec-p key))))
     ;; A path, absolute or as an added extension was given.
     (let* ((path (directory-file-name key))
            (base (file-name-base path)))
       (cond
        ((member base '("" "." ".." "~")) key)
        ((equal base "index")
         (let ((parent (file-name-directory path)))
           (if parent (file-name-nondirectory (directory-file-name parent)) base)))
        (t base))))
    ((pred (string-prefix-p "npm:"))
     ;; The package name as Pi parses it, without its @scope.
     (let ((name (file-name-nondirectory (pichat-tool-picker--npm-name key))))
       (if (string-empty-p name) key name)))
    ((and (pred pichat-tool-picker--git-repository)
          (app pichat-tool-picker--git-repository `(,_ . ,path)))
     (file-name-nondirectory path))
    (_
     ;; Strip a scheme, a trailing @version (not a leading npm @scope) and
     ;; a .git suffix, then keep the last path component.
     (let* ((spec (replace-regexp-in-string "\\`[a-z]+:\\(//\\)?" "" key))
            (spec (replace-regexp-in-string "\\(.\\)@[^@/]*\\'" "\\1" spec))
            (spec (replace-regexp-in-string "\\.git\\'" "" spec))
            (name (file-name-nondirectory (directory-file-name spec))))
       (if (string-empty-p name) key name)))))

(defun pichat-tool-picker--extension-groups ()
  "Return ordered (KEY LABEL . TOOLS) extension tool groups.
Extensions come in discovery order, then \"Unattributed\", then \"Pi
built-in\".  Tools of the extensions the probe added with `-e' group
under their specs.  Labels shared by several groups fall back to their
keys."
  (let ((attribution (when-let* ((draft (plist-get pichat-tool-picker--state :discovery)))
                       (pichat-tool-picker-added-attribution
                        (pichat-tool-discovery-draft-context draft))))
        groups)
    (dolist (tool (pichat-tool-picker--extension-tools))
      (let* ((key (pichat-tool-picker--extension-group-key tool attribution))
             (entry (assoc key groups)))
        (if entry (setcdr entry (append (cdr entry) (list tool)))
          (push (list key tool) groups))))
    (setq groups (nreverse groups))
    (setq groups (append (cl-remove-if (lambda (group) (keywordp (car group))) groups)
                         (cl-remove-if-not (lambda (group) (eq (car group) :unattributed)) groups)
                         (cl-remove-if-not (lambda (group) (eq (car group) :builtin)) groups)))
    (let ((labels (mapcar (lambda (group) (pichat-tool-picker--extension-group-label (car group)))
                          groups)))
      (cl-loop for (key . tools) in groups
               for label in labels
               collect (cons key (cons (if (and (stringp key) (> (cl-count label labels :test #'equal) 1))
                                           key label)
                                       tools))))))

(defun pichat-tool-picker--extension-group (key)
  "Return the (KEY LABEL . TOOLS) group for KEY, or nil."
  (assoc key (pichat-tool-picker--extension-groups)))

;;; Include future tools

;; The draft's :all lists the group sources whose future tools are
;; included, (SOURCE . :all) in a preset.  Their current tools are always
;; checked in :extensions as well, so what a launch enables is visible.

(defun pichat-tool-picker--source-names (source)
  "Return the eligible extension tools discovered for group SOURCE."
  (pichat-tool-picker-group-tool-names
   source (pichat-tool-picker--extension-tools)
   (when-let* ((draft (plist-get pichat-tool-picker--state :discovery)))
     (pichat-tool-picker-added-attribution (pichat-tool-discovery-draft-context draft)))))

(defun pichat-tool-picker--future-p (key)
  "Return non-nil when the draft includes the future tools of group KEY."
  (and (stringp key) (member key (plist-get (pichat-tool-picker--selection) :all)) t))

(defun pichat-tool-picker--materialize-all ()
  "Check the discovered tools of every group whose future tools are included.
Once discovery is ready the draft holds them as exact names and is no
longer :unexpanded.  Nothing changes before that."
  (when-let* ((draft (plist-get pichat-tool-picker--state :discovery)))
    (when (eq 'ready (pichat-tool-discovery-draft-status draft))
      (let* ((selection (copy-tree (pichat-tool-picker--selection)))
             (names (plist-get selection :extensions)))
        (dolist (source (plist-get selection :all))
          (dolist (name (pichat-tool-picker--source-names source))
            (unless (member name names) (setq names (append names (list name))))))
        (setq selection (plist-put selection :extensions names))
        (setf (plist-get pichat-tool-picker--state :draft)
              (cl-loop for (key value) on selection by #'cddr
                       unless (eq key :unexpanded) append (list key value)))))))

(defun pichat-tool-picker--drop-future (selection names)
  "Return SELECTION without future tools of groups containing any of NAMES.
Unchecking a tool of such a group turns its \"Include future tools\" off."
  (plist-put selection :all
             (cl-remove-if (lambda (source)
                             (cl-intersection names (pichat-tool-picker--source-names source)
                                              :test #'equal))
                           (plist-get selection :all))))

(defun pichat-tool-picker--toggle-future (key)
  "Toggle whether the draft includes the future tools of group KEY.
Turning it on also checks every current eligible tool of the group;
turning it off keeps the checked tools as exact names."
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (all (plist-get selection :all)))
    (if (member key all)
        (setq selection (plist-put selection :all (remove key all)))
      (unless (eq 'ready (pichat-tool-discovery-draft-status
                          (plist-get pichat-tool-picker--state :discovery)))
        (user-error "Extension discovery is incomplete"))
      (setq selection (plist-put selection :all (append all (list key))))
      (let ((names (plist-get selection :extensions)))
        (dolist (name (pichat-tool-picker--source-names key))
          (unless (member name names) (setq names (append names (list name)))))
        (setq selection (plist-put selection :extensions names))))
    (pichat-tool-picker--set-selection selection)))

(defun pichat-tool-picker--future-entry (key)
  "Return the group page's \"Include future tools\" row for group KEY."
  (list "*" "Include future tools"
        (lambda () (interactive) (pichat-tool-picker--toggle-future key))
        :description
        (lambda () (pichat-tool-picker--description
                    (pichat-tool-picker--future-p key) "Include future tools"))
        :transient t))

(defun pichat-tool-picker--extension-count (tools)
  "Return how many of TOOLS the draft checks."
  (cl-count-if (lambda (tool) (member (plist-get tool :name)
                                      (plist-get (pichat-tool-picker--selection) :extensions)))
               tools))

(defun pichat-tool-picker--extension-checkbox (key tool width)
  "Return a suffix spec checking extension TOOL under KEY.
WIDTH bounds the description."
  (let ((name (plist-get tool :name)) (eligible (plist-get tool :eligible))
        (description (truncate-string-to-width
                      (replace-regexp-in-string "[[:cntrl:]]" " " (plist-get tool :description))
                      width nil nil "…")))
    (list key name
          (lambda () (interactive)
            (let ((checked (member name (plist-get (pichat-tool-picker--selection) :extensions))))
              (unless (or eligible checked)
                (user-error "Tool %s cannot be enabled" name))
              (when checked
                (setf (plist-get pichat-tool-picker--state :draft)
                      (pichat-tool-picker--drop-future
                       (copy-tree (pichat-tool-picker--selection)) (list name))))
              (pichat-tool-picker--toggle :extensions name)))
          :description
          (lambda ()
            (pichat-tool-picker--with-description
             key
             (concat (pichat-tool-picker--description
                      (member name (plist-get (pichat-tool-picker--selection) :extensions)) name)
                     (if eligible "" " (unavailable)"))
             description))
          :transient t)))

(defun pichat-tool-picker--extensions (_)
  "Build extension group shortcuts, or flat checkboxes without provenance."
  (transient-parse-suffixes
   'pichat-tool-picker
   (if (pichat-tool-picker--grouped-p)
       (cl-loop for (group-key label . _) in (pichat-tool-picker--page-items
                                              (pichat-tool-picker--extension-groups))
                for key in pichat-tool-picker--keys
                collect
                (let ((group-key group-key))
                  (list (concat "e" key) label
                        (lambda () (interactive)
                          (setf (plist-get pichat-tool-picker--state :extension-group) group-key
                                (plist-get pichat-tool-picker--state :page) 0)
                          (transient-setup 'pichat-tool-picker-extension-group))
                        :description
                        (lambda ()
                          (pcase-let ((`(,_ ,label . ,tools)
                                       (pichat-tool-picker--extension-group group-key)))
                            (if (pichat-tool-picker--future-p group-key)
                                (format "%s (all) →" label)
                              (format "%s (%d/%d) →" label
                                      (pichat-tool-picker--extension-count tools)
                                      (length tools)))))
                        :transient t)))
     (cl-loop for tool in (pichat-tool-picker--page-items (pichat-tool-picker--extension-tools))
              for key in pichat-tool-picker--keys
              collect (pichat-tool-picker--extension-checkbox
                       (concat "e" key) tool 65)))))

(defun pichat-tool-picker--extension-group-tools ()
  "Return the tools of the open extension group."
  (cddr (pichat-tool-picker--extension-group
         (plist-get pichat-tool-picker--state :extension-group))))

(defun pichat-tool-picker--extension-tool-entries (_)
  "Build checkboxes for the open extension group."
  (let ((group (plist-get pichat-tool-picker--state :extension-group)))
    (transient-parse-suffixes
     'pichat-tool-picker-extension-group
     (append
      ;; Only an extension has a stable identity to include future tools of.
      (when (stringp group) (list (pichat-tool-picker--future-entry group)))
      (cl-loop for tool in (pichat-tool-picker--page-items
                            (pichat-tool-picker--extension-group-tools))
               for key in pichat-tool-picker--keys
               collect (pichat-tool-picker--extension-checkbox key tool 60))))))

(defun pichat-tool-picker--extension-group-description ()
  "Head the open extension group with its label, source and count."
  (let* ((key (plist-get pichat-tool-picker--state :extension-group))
         (group (pichat-tool-picker--extension-group key))
         (tools (cddr group)))
    (concat (format "%s: %d/%d selected" (or (cadr group) "Extension")
                    (pichat-tool-picker--extension-count tools) (length tools))
            (when (and (stringp key) (not (equal key (cadr group))))
              (concat "\n" (propertize (pichat-transient-fill key) 'face 'shadow))))))

(defun pichat-tool-picker--extension-group-set (selected)
  "Check the open group's eligible tools when SELECTED, else none of them.
Only that group's current tools change; tools registered later are not
included, and checking none also stops including them."
  (let* ((tools (pichat-tool-picker--extension-group-tools))
         (members (mapcar (lambda (tool) (plist-get tool :name)) tools))
         (selection (copy-tree (pichat-tool-picker--selection)))
         (selection (if selected selection
                      (pichat-tool-picker--drop-future
                       (plist-put selection :all
                                  (remove (plist-get pichat-tool-picker--state :extension-group)
                                          (plist-get selection :all)))
                       members)))
         (others (cl-remove-if (lambda (name) (member name members))
                               (plist-get selection :extensions))))
    (pichat-tool-picker--set-selection
     (plist-put selection :extensions
                (if selected
                    (append others (cl-loop for tool in tools
                                            when (plist-get tool :eligible)
                                            collect (plist-get tool :name)))
                  others)))))

(transient-define-suffix pichat-tool-picker-extension-group-all ()
  "Check this extension's eligible tools." :transient t
  (interactive) (pichat-tool-picker--extension-group-set t))
(transient-define-suffix pichat-tool-picker-extension-group-none ()
  "Uncheck this extension's tools." :transient t
  (interactive) (pichat-tool-picker--extension-group-set nil))

(defun pichat-tool-picker--current-server ()
  "Return the selected MCP server."
  (cl-find (plist-get pichat-tool-picker--state :server)
           (plist-get pichat-tool-picker--state :servers)
           :key (lambda (item) (plist-get item :name)) :test #'equal))

(defun pichat-tool-picker--servers (_)
  "Build MCP server shortcuts."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for server in (pichat-tool-picker--page-items (plist-get pichat-tool-picker--state :servers))
            for key in pichat-tool-picker--server-keys
            collect
            (let ((name (plist-get server :name)))
              (list key name
                    (lambda () (interactive)
                      (setf (plist-get pichat-tool-picker--state :server) name
                            (plist-get pichat-tool-picker--state :page) 0)
                      (transient-setup 'pichat-tool-picker-server))
                    :description
                    (lambda ()
                      (let* ((entry (cl-find name (plist-get pichat-tool-picker--state :servers)
                                             :key (lambda (item) (plist-get item :name)) :test #'equal))
                             (count (cl-count-if
                                     (lambda (tool) (member (cons name (plist-get tool :name))
                                                            (plist-get (pichat-tool-picker--selection) :mcp)))
                                     (plist-get entry :tools))))
                        (format "%s (%s, %d/%d) →" name (or (plist-get entry :state) "unknown")
                                count (length (plist-get entry :tools)))))
                    :transient t)))))

(defun pichat-tool-picker--server-tools (_)
  "Build checkboxes for the selected server."
  (let ((server (pichat-tool-picker--current-server)))
    (transient-parse-suffixes
     'pichat-tool-picker-server
     (cl-loop for tool in (pichat-tool-picker--page-items (plist-get server :tools))
              for key in pichat-tool-picker--keys
              collect
              (let* ((name (plist-get tool :name)) (eligible (plist-get tool :eligible))
                     (pair (cons (plist-get server :name) name)))
                (list key name
                      (lambda () (interactive)
                        (if eligible (pichat-tool-picker--toggle :mcp pair)
                          (user-error "MCP tool %s/%s is not directly available" (car pair) name)))
                      :description
                      (lambda () (concat (pichat-tool-picker--description
                                          (member pair (plist-get (pichat-tool-picker--selection) :mcp)) name)
                                         (unless eligible (format " (%s)" (or (plist-get tool :exposure) "unavailable")))))
                      :transient t))))))

;;; Emacs-defined tool groups

(defun pichat-tool-picker--emacs-groups ()
  "Return ordered (GROUP . TOOLS) from the picker's Emacs tool catalogue."
  (let (groups)
    (dolist (tool (plist-get pichat-tool-picker--state :emacs-catalogue))
      (let* ((group (plist-get tool :group))
             (entry (assoc group groups)))
        (if entry (setcdr entry (append (cdr entry) (list tool)))
          (setq groups (append groups (list (list group tool)))))))
    groups))

(defun pichat-tool-picker--emacs-group-tools (group)
  "Return catalogue tools in GROUP."
  (cdr (assoc group (pichat-tool-picker--emacs-groups))))

(defun pichat-tool-picker--emacs-missing ()
  "Return selected Emacs tool names absent from the picker catalogue."
  (let ((names (mapcar (lambda (tool) (plist-get tool :name))
                       (plist-get pichat-tool-picker--state :emacs-catalogue))))
    (cl-remove-if (lambda (name) (member name names))
                  (plist-get (pichat-tool-picker--selection) :emacs))))

(defun pichat-tool-picker--emacs-count (tools)
  "Return how many of TOOLS the draft selects."
  (cl-count-if (lambda (tool) (member (plist-get tool :name)
                                      (plist-get (pichat-tool-picker--selection) :emacs)))
               tools))

(defun pichat-tool-picker--emacs-group-entries (_)
  "Build Emacs-defined tool group shortcuts with selected/available counts."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for (group . tools) in (pichat-tool-picker--emacs-groups)
            for key in pichat-tool-picker--keys
            collect
            (let ((group group))
              (list (concat "x" key) group
                    (lambda () (interactive)
                      (setf (plist-get pichat-tool-picker--state :emacs-group) group
                            (plist-get pichat-tool-picker--state :page) 0)
                      (transient-setup 'pichat-tool-picker-emacs-group))
                    :description
                    (lambda ()
                      (let ((tools (pichat-tool-picker--emacs-group-tools group)))
                        (format "%s (%d/%d) →" group
                                (pichat-tool-picker--emacs-count tools) (length tools))))
                    :transient t)))))

(defun pichat-tool-picker--emacs-tool-entries (_)
  "Build checkboxes for the selected Emacs tool group."
  (let ((group (plist-get pichat-tool-picker--state :emacs-group)))
    (transient-parse-suffixes
     'pichat-tool-picker-emacs-group
     (cl-loop for tool in (pichat-tool-picker--page-items
                           (pichat-tool-picker--emacs-group-tools group))
              for key in pichat-tool-picker--keys
              collect
              (let ((name (plist-get tool :name))
                    (description (truncate-string-to-width
                                  (replace-regexp-in-string
                                   "[[:cntrl:]]" " " (plist-get tool :description))
                                  60 nil nil "…"))
                    (mutating (plist-get tool :mutating)))
                (list key name
                      (lambda () (interactive) (pichat-tool-picker--toggle :emacs name))
                      :description
                      (lambda ()
                        (pichat-tool-picker--with-description
                         key
                         (concat (pichat-tool-picker--description
                                  (member name (plist-get (pichat-tool-picker--selection) :emacs))
                                  name)
                                 (if mutating " (approval)" ""))
                         description))
                      :transient t))))))

(defun pichat-tool-picker--emacs-group-set (selected)
  "Select all current members of the open group when SELECTED, else none.
Only that group's current catalogue members change; this is a convenience
over exact names, not a grant to tools registered later."
  (let* ((group (plist-get pichat-tool-picker--state :emacs-group))
         (members (mapcar (lambda (tool) (plist-get tool :name))
                          (pichat-tool-picker--emacs-group-tools group)))
         (selection (copy-tree (pichat-tool-picker--selection)))
         (others (cl-remove-if (lambda (name) (member name members))
                               (plist-get selection :emacs))))
    (pichat-tool-picker--set-selection
     (plist-put selection :emacs (if selected (append others members) others)))))

(transient-define-suffix pichat-tool-picker-emacs-group-all ()
  "Select this group's current Emacs-defined tools." :transient t
  (interactive) (pichat-tool-picker--emacs-group-set t))
(transient-define-suffix pichat-tool-picker-emacs-group-none ()
  "Deselect this group's Emacs-defined tools." :transient t
  (interactive) (pichat-tool-picker--emacs-group-set nil))

(defun pichat-tool-picker--emacs-heading ()
  "Head the Emacs-defined tools section, noting why tools are unavailable."
  (let ((missing (pichat-tool-picker--emacs-missing))
        (transport (plist-get pichat-tool-picker--state :transport)))
    (concat
     "Emacs-defined tools"
     (cond
      ((not (pichat-rpc-bridge-p transport))
       (propertize (if (and transport (eq (pichat-transport-kind transport) 'ssh))
                       " (not over SSH)"
                     " (no PiChat bridge)")
                   'face 'warning))
      (missing
       (concat "\n"
               (propertize (pichat-transient-fill
                            (format "Not loaded, skipped: %s" (string-join missing ", ")))
                           'face 'warning)))))))

(defun pichat-tool-picker--group-description ()
  "Describe the open Emacs tool group."
  (let* ((group (plist-get pichat-tool-picker--state :emacs-group))
         (tools (pichat-tool-picker--emacs-group-tools group)))
    (format "%s: %d/%d selected\nSelecting does not approve calls"
            group (pichat-tool-picker--emacs-count tools) (length tools))))

(defun pichat-tool-picker--all (&optional only-server)
  "Explicitly select all eligible tools, or just ONLY-SERVER.
Emacs-defined tools remain explicit per-group or per-tool choices."
  (unless (plist-get pichat-tool-picker--state :loaded) (user-error "MCP discovery is incomplete"))
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (servers (if only-server (list (pichat-tool-picker--current-server))
                    (plist-get pichat-tool-picker--state :servers)))
         (pairs (cl-loop for server in servers
                         append (cl-loop for tool in (plist-get server :tools)
                                          when (plist-get tool :eligible)
                                          collect (cons (plist-get server :name) (plist-get tool :name))))))
    (setq selection (plist-put selection :mcp
                               (if only-server
                                   (append (cl-remove-if (lambda (pair) (equal (car pair) only-server))
                                                         (plist-get selection :mcp)) pairs)
                                 pairs)))
    (unless only-server
      (unless (eq 'ready (pichat-tool-discovery-draft-status (plist-get pichat-tool-picker--state :discovery)))
        (user-error "Extension discovery is incomplete"))
      (setq selection (plist-put selection :builtins (copy-sequence (plist-get pichat-tool-picker--state :baseline))))
      (setq selection (plist-put selection :extensions
                                 (cl-loop for tool in (pichat-tool-picker--extension-tools)
                                          when (plist-get tool :eligible) collect (plist-get tool :name)))))
    (pichat-tool-picker--set-selection selection)))

(transient-define-suffix pichat-tool-picker-all ()
  "Select all listed eligible tools." :transient t
  (interactive) (pichat-tool-picker--all))
(transient-define-suffix pichat-tool-picker-server-all ()
  "Select this server's eligible tools." :transient t
  (interactive) (pichat-tool-picker--all (plist-get pichat-tool-picker--state :server)))
(transient-define-suffix pichat-tool-picker-none ()
  "Deselect all tools." :transient t
  (interactive)
  (pichat-tool-picker--set-selection
   (list :builtins nil :mcp nil :extensions nil :emacs nil :all nil)))
(transient-define-suffix pichat-tool-picker-server-none ()
  "Deselect this server's tools." :transient t
  (interactive)
  (let ((selection (copy-tree (pichat-tool-picker--selection)))
        (server (plist-get pichat-tool-picker--state :server)))
    (pichat-tool-picker--set-selection
     (plist-put selection :mcp (cl-remove-if (lambda (pair) (equal (car pair) server))
                                            (plist-get selection :mcp))))))
(transient-define-suffix pichat-tool-picker-reset ()
  "Restore the captured preset baseline." :transient t
  (interactive)
  (let ((preset (plist-get pichat-tool-picker--state :preset)))
    (setf (plist-get pichat-tool-picker--state :draft)
          (list :builtins (copy-sequence (plist-get pichat-tool-picker--state :baseline))
                :mcp (copy-tree (plist-get preset :mcp))
                :extensions (copy-sequence (plist-get preset :extensions))
                :emacs (copy-sequence (plist-get preset :emacs-tools))
                :all (pichat-presets-all-sources preset)))
    ;; The groups' current tools show checked again.
    (pichat-tool-picker--materialize-all)
    (pichat-tool-picker--refresh-display)))

(defun pichat-tool-picker--page (delta prefix)
  "Move DELTA pages in PREFIX."
  (let* ((count (pcase prefix
                  ('pichat-tool-picker-server
                   (length (plist-get (pichat-tool-picker--current-server) :tools)))
                  ('pichat-tool-picker-emacs-group
                   (length (pichat-tool-picker--emacs-group-tools
                            (plist-get pichat-tool-picker--state :emacs-group))))
                  ('pichat-tool-picker-extension-group
                   (length (pichat-tool-picker--extension-group-tools)))
                  (_ (max (length (plist-get pichat-tool-picker--state :servers))
                          (length (if (pichat-tool-picker--grouped-p)
                                      (pichat-tool-picker--extension-groups)
                                    (pichat-tool-picker--extension-tools)))))))
         (last (max 0 (1- (ceiling count pichat-tool-picker--page-size)))))
    (setf (plist-get pichat-tool-picker--state :page)
          (min last (max 0 (+ delta (or (plist-get pichat-tool-picker--state :page) 0)))))
    (transient-setup prefix)))
(transient-define-suffix pichat-tool-picker-next ()
  "Show next page." :transient t
  (interactive) (pichat-tool-picker--page 1 (oref transient--prefix command)))
(transient-define-suffix pichat-tool-picker-prev ()
  "Show previous page." :transient t
  (interactive) (pichat-tool-picker--page -1 (oref transient--prefix command)))

(defun pichat-tool-picker--stop-discovery ()
  "Cancel pending discovery; retain completed owner-scoped results."
  (when-let* ((draft (plist-get pichat-tool-picker--state :discovery))
              (cancel (pichat-tool-discovery-draft-cancel draft)))
    (funcall cancel)
    (setf (pichat-tool-discovery-draft-cancel draft) nil)
    (when (eq 'loading (pichat-tool-discovery-draft-status draft))
      (setf (pichat-tool-discovery-draft-status draft) nil)))
  (when-let* ((cancel (plist-get pichat-tool-picker--state :cancel-extension-start)))
    (funcall cancel))
  (setf (plist-get pichat-tool-picker--state :cancel-extension-start) nil)
  (when-let* ((cancel (plist-get pichat-tool-picker--state :cancel))) (funcall cancel))
  (setf (plist-get pichat-tool-picker--state :cancel) nil))

(defun pichat-tool-picker--discover-extensions (&optional force)
  "Discover extension tools, reusing the draft unless FORCE."
  (let* ((state pichat-tool-picker--state) (draft (plist-get state :discovery)))
    (when (and draft (or force (not (eq 'ready (pichat-tool-discovery-draft-status draft)))))
      (pichat-tool-discovery-draft-refresh
       draft (lambda (_draft) (when (eq state pichat-tool-picker--state)
                                (pichat-tool-picker--materialize-all)
                                (pichat-tool-picker--refresh-children)))))))

(defun pichat-tool-picker--discover (&optional force-extensions)
  "Refresh the MCP listing for the captured target."
  (pichat-tool-picker--stop-discovery)
  (let* ((state pichat-tool-picker--state)
         (version (1+ (or (plist-get state :version) 0)))
         (transport (plist-get state :transport))
         (ssh (eq (pichat-transport-kind transport) 'ssh)))
    (setf (plist-get state :version) version
          (plist-get state :servers) (plist-get state :servers)
          (plist-get state :loaded) nil
          (plist-get state :error) "Discovering MCP servers…")
    (setq pichat-tool-picker--state state)
    (pichat-tool-picker--refresh-display)
    (cl-labels ((current-p ()
                  (and (eq state pichat-tool-picker--state)
                       (= version (plist-get state :version))))
                (complete (servers errors)
                  (when (current-p)
                    (setf (plist-get state :servers) servers
                          (plist-get state :loaded) (or servers (not errors))
                          (plist-get state :error) (if errors (format "%s" errors)
                                                    (unless servers "No MCP servers configured")))
                    (when ssh
                      ;; Completion can precede TRAMP's stderr teardown tail.
                      (setf (plist-get state :cancel-extension-start)
                            (pichat-transport-defer
                             transport
                             (lambda ()
                               (when (current-p)
                                 (setf (plist-get state :cancel-extension-start) nil)
                                 (pichat-tool-picker--discover-extensions force-extensions))))))
                    (pichat-tool-picker--refresh-children))))
      (let ((cancel (pichat-mcp-discovery-start
                     transport (plist-get state :runtime-cwd)
                     (or (pichat-transport-pi-executable transport) (plist-get state :executable))
                     #'complete)))
        (if (current-p)
            (progn
              (setf (plist-get state :cancel) cancel)
              (unless ssh (pichat-tool-picker--discover-extensions force-extensions)))
          (when cancel (funcall cancel)))))))

(defun pichat-tool-picker--status-description ()
  "Describe MCP discovery."
  (format "MCP discovery: %s" (or (plist-get pichat-tool-picker--state :error)
                                 (format "%d servers" (length (plist-get pichat-tool-picker--state :servers))))))
(defun pichat-tool-picker--extension-status ()
  "Describe extension discovery without activation jargon."
  (let ((draft (plist-get pichat-tool-picker--state :discovery)))
    (format "Extension tools: %s"
            (if (not draft) "not available"
              (pcase (pichat-tool-discovery-draft-status draft)
                ('loading "discovering…")
                ('ready (format "%d found" (length (pichat-tool-picker--extension-tools))))
                ('failed (pichat-tool-discovery-draft-error draft))
                (_ "not available"))))))
(transient-define-suffix pichat-tool-picker-status ()
  "Show MCP discovery status." :transient t
  (interactive) (message "%s" (pichat-tool-picker--status-description)))
(transient-define-suffix pichat-tool-picker-extension-status ()
  "Show extension discovery status." :transient t
  (interactive) (message "%s" (pichat-tool-picker--extension-status)))
(transient-define-suffix pichat-tool-picker-refresh ()
  "Refresh all catalogues, retaining exact selections." :transient t
  (interactive)
  ;; Newly registered Emacs tools become listed, never selected.
  (setf (plist-get pichat-tool-picker--state :emacs-catalogue) (pichat-tools-catalogue))
  (pichat-tool-picker--discover t))

(defun pichat-tool-picker--return (selection)
  "Return SELECTION or :cancel to the owner."
  (let ((callback (plist-get pichat-tool-picker--state :callback)))
    (pichat-tool-picker--stop-discovery)
    (setq pichat-tool-picker--state nil)
    (funcall callback selection)))
(transient-define-suffix pichat-tool-picker-apply ()
  "Apply the validated draft."
  (interactive)
  (pichat-tool-picker--materialize-all)
  (let* ((state pichat-tool-picker--state)
         (selection (pichat-tool-picker--selection))
         (snapshot (pichat-tool-selection-resolve (plist-get state :preset) selection)))
    (when (plist-get snapshot :mcp)
      (unless (plist-get state :loaded) (user-error "MCP discovery has not succeeded for this target"))
      (pichat-tool-selection-mcp-access snapshot (plist-get state :servers)
                                        (pichat-tool-picker--extension-tools)))
    ;; Future tools are applied as the exact tools discovered now.
    (when (or (plist-get snapshot :extensions) (plist-get snapshot :all)
              (plist-get snapshot :unexpanded))
      (unless (eq 'ready (pichat-tool-discovery-draft-status (plist-get state :discovery)))
        (user-error "Extension discovery has not succeeded for this target"))
      (pichat-tool-selection-check-extensions snapshot (pichat-tool-picker--extension-tools)))
    (pichat-tool-picker--return
     (unless (equal snapshot (pichat-tool-selection-resolve (plist-get state :preset))) selection))))
(transient-define-suffix pichat-tool-picker-cancel ()
  "Discard edits." (interactive) (pichat-tool-picker--return :cancel))
(transient-define-suffix pichat-tool-picker-back ()
  "Return to the outer picker." (interactive)
  (setf (plist-get pichat-tool-picker--state :page) 0)
  (transient-setup 'pichat-tool-picker))

(transient-define-prefix pichat-tool-picker ()
  "Select tools for this runtime."
  ["Built-in tools" :class transient-column :setup-children pichat-tool-picker--builtins]
  ["Extension tools" :class transient-column :setup-children pichat-tool-picker--extensions]
  ["MCP servers" :class transient-column :setup-children pichat-tool-picker--servers]
  [:description pichat-tool-picker--emacs-heading :class transient-column
   :setup-children pichat-tool-picker--emacs-group-entries]
  [["Selection"
    ("a" "All eligible" pichat-tool-picker-all)
    ("n" "None" pichat-tool-picker-none)
    ("d" "Reset to preset" pichat-tool-picker-reset)
    ("r" "Refresh discovery" pichat-tool-picker-refresh)
    ("?" pichat-tool-picker-status :description pichat-tool-picker--status-description)
    ("!" pichat-tool-picker-extension-status :description pichat-tool-picker--extension-status)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Apply" pichat-tool-picker-apply) ("q" "Cancel" pichat-tool-picker-cancel)]]
  (interactive) (transient-setup 'pichat-tool-picker))
(transient-define-prefix pichat-tool-picker-emacs-group ()
  "Select Emacs-defined tools in one group."
  [:description pichat-tool-picker--group-description
   :class transient-column :setup-children pichat-tool-picker--emacs-tool-entries]
  [["Selection" ("a" "All in group" pichat-tool-picker-emacs-group-all)
    ("n" "None in group" pichat-tool-picker-emacs-group-none)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Done" pichat-tool-picker-back) ("q" "Back" pichat-tool-picker-back)]]
  (interactive) (transient-setup 'pichat-tool-picker-emacs-group))
(transient-define-prefix pichat-tool-picker-extension-group ()
  "Select the tools of one extension."
  [:description pichat-tool-picker--extension-group-description
   :class transient-column :setup-children pichat-tool-picker--extension-tool-entries]
  [["Selection" ("a" "All in extension" pichat-tool-picker-extension-group-all)
    ("n" "None in extension" pichat-tool-picker-extension-group-none)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Done" pichat-tool-picker-back) ("q" "Back" pichat-tool-picker-back)]]
  (interactive) (transient-setup 'pichat-tool-picker-extension-group))
(transient-define-prefix pichat-tool-picker-server ()
  "Select MCP server tools."
  ["Server tools" :class transient-column :setup-children pichat-tool-picker--server-tools]
  [["Selection" ("a" "All eligible" pichat-tool-picker-server-all)
    ("n" "None" pichat-tool-picker-server-none)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Done" pichat-tool-picker-back) ("q" "Back" pichat-tool-picker-back)]]
  (interactive) (transient-setup 'pichat-tool-picker-server))

(defun pichat-tool-picker-discovery-context (preset directory transport executable
                                                   &optional model extensions)
  "Return (RUNTIME-CWD . PROBE-CONTEXT) for discovering tools of PRESET.
DIRECTORY is resolved on TRANSPORT; EXECUTABLE and MODEL qualify the probe,
which also carries the preset's prompt arguments and loads the added
EXTENSIONS (specs, each passed as `-e').  Owners reset their discovery
cache with PROBE-CONTEXT, so menus sharing one cache share results, and a
changed list of extensions invalidates them.  With EXTENSIONS, the context
also names them as :extensions, so a failed install or load fails the
probe.  Signal when discovery is unavailable there.  Start nothing."
  (let* ((cwd (file-name-as-directory (expand-file-name directory)))
         (context (pichat-transport-path-context transport (and (boundp 'pichat-path-mappings) pichat-path-mappings)))
         (runtime-cwd (or (plist-get (pichat-path-resolve-to-runtime cwd context) :path)
                          (user-error "Directory is unavailable to target %s" (pichat-transport-label transport))))
         (probe-context (pichat-tool-discovery-context
                         transport runtime-cwd
                         (or (pichat-transport-pi-executable transport) executable) model)))
    (pichat-rpc--validate-preset-args preset (plist-get probe-context :args))
    (setf (plist-get probe-context :args)
          (append (plist-get probe-context :args)
                  (pichat-rpc-extension-args extensions)
                  (when (plist-get preset :system-prompt)
                    (list "--system-prompt" (plist-get preset :system-prompt)))
                  (when (plist-get preset :append-system-prompt)
                    (list "--append-system-prompt" (plist-get preset :append-system-prompt)))))
    (when extensions
      ;; Their install and load failures then fail the probe.
      (setq probe-context (plist-put probe-context :extensions
                                     (copy-sequence extensions))))
    (cons runtime-cwd probe-context)))

(defun pichat-tool-picker-open (preset selection directory transport executable callback
                                     &optional model discovery extensions)
  "Open PRESET/SELECTION for DIRECTORY on TRANSPORT using EXECUTABLE.
CALLBACK receives a raw selection, nil baseline or :cancel.  MODEL and the
owner's DISCOVERY cache qualify the probe, which also loads the added
EXTENSIONS the runtime will load; no unrelated runtime is queried."
  (when (eq (plist-get preset :tools) :default)
    (user-error "Preset %s uses Pi defaults; Tools cannot customize it" (plist-get preset :name)))
  (pcase-let* ((`(,runtime-cwd . ,probe-context)
                (pichat-tool-picker-discovery-context
                 preset directory transport executable model extensions))
               (discovery (or discovery (pichat-tool-discovery-draft-create))))
    (when pichat-tool-picker--state (pichat-tool-picker--stop-discovery))
    (pichat-tool-discovery-draft-reset discovery probe-context)
    (setq pichat-tool-picker--state
          (list :preset preset :baseline (copy-sequence (plist-get preset :tools))
                :draft (copy-tree (or selection (pichat-tool-selection-resolve preset)))
                :discovery discovery :transport transport :runtime-cwd runtime-cwd
                :emacs-catalogue (pichat-tools-catalogue) :emacs-group nil
                :extension-group nil
                :executable executable :callback callback :page 0 :cancel nil
                :cancel-extension-start nil
                :servers nil :loaded nil :error nil :version 0))
    ;; A reused ready cache shows included future tools checked at once.
    (pichat-tool-picker--materialize-all)
    (transient-setup 'pichat-tool-picker)
    (pichat-tool-picker--discover)))

(defun pichat-tool-picker--abandoned ()
  "Release probes when the user quits the entire Transient stack."
  (when pichat-tool-picker--state
    (pichat-tool-picker--stop-discovery)
    (setq pichat-tool-picker--state nil)))
(add-hook 'transient-post-exit-hook #'pichat-tool-picker--abandoned)

(provide 'pichat-tool-picker)
;;; pichat-tool-picker.el ends here
