;;; pichat-tool-picker.el --- Preset-aware Tools Transient -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'pichat-tool-selection)
(require 'pichat-mcp-discovery)
(require 'pichat-tool-discovery)
(require 'pichat-path)

(defvar pichat-tool-picker--state nil
  "Draft of the currently open Tools picker.")
(defconst pichat-tool-picker--keys
  (mapcar #'char-to-string (string-to-list "1234567890bcfghijklmopstuvwxyz")))
(defconst pichat-tool-picker--server-keys
  (mapcar #'char-to-string (string-to-list "ABCDEFGHIJKLMNOPQRSTUVWXYZ")))
(defconst pichat-tool-picker--page-size 20)

(defun pichat-tool-picker--refresh-display ()
  "Redisplay the current picker."
  (when (and transient--prefix
             (memq (oref transient--prefix command)
                   '(pichat-tool-picker pichat-tool-picker-server)))
    (transient--redisplay)))

(defun pichat-tool-picker--refresh-children ()
  "Rebuild visible dynamic choices."
  (when (and transient--prefix
             (memq (oref transient--prefix command)
                   '(pichat-tool-picker pichat-tool-picker-server)))
    (transient-setup (oref transient--prefix command) nil nil
                     :scope (oref transient--prefix scope))))

(defun pichat-tool-picker--description (checked label)
  "Return checkbox LABEL for CHECKED."
  (format "[%s] %s" (if checked "✓" " ") label))

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

(defun pichat-tool-picker--extension-tools ()
  "Return custom tools, excluding exact known built-in and MCP names.
Do not guess provenance from prefixes.  Unlisted extension-registered MCP
servers may consequently appear here rather than in the shell MCP listing."
  (let ((mcp-names (cl-loop for server in (plist-get pichat-tool-picker--state :servers)
                            append (mapcar (lambda (tool)
                                             (pichat-tool-selection--name
                                              (plist-get server :name) (plist-get tool :name)))
                                           (plist-get server :tools)))))
    (when-let* ((draft (plist-get pichat-tool-picker--state :discovery)))
      (cl-remove-if
       (lambda (tool) (member (plist-get tool :name)
                             (append pichat-presets--known-built-in-tools mcp-names)))
       (pichat-tool-discovery-draft-tools draft)))))

(defun pichat-tool-picker--extensions (_)
  "Build simple extension checkboxes with descriptions."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for tool in (pichat-tool-picker--page-items (pichat-tool-picker--extension-tools))
            for key in pichat-tool-picker--keys
            collect
            (let ((name (plist-get tool :name)) (eligible (plist-get tool :eligible))
                  (description (truncate-string-to-width
                                (replace-regexp-in-string "[[:cntrl:]]" " " (plist-get tool :description))
                                65 nil nil "…")))
              (list (concat "e" key) name
                    (lambda () (interactive)
                      (if (or eligible (member name (plist-get (pichat-tool-picker--selection) :extensions)))
                          (pichat-tool-picker--toggle :extensions name)
                        (user-error "Tool %s cannot be enabled" name)))
                    :description
                    (lambda () (format "%s — %s%s"
                                       (pichat-tool-picker--description
                                        (member name (plist-get (pichat-tool-picker--selection) :extensions)) name)
                                       description (if eligible "" " (unavailable)")))
                    :transient t)))))

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

(defun pichat-tool-picker--all (&optional only-server)
  "Explicitly select all eligible tools, or just ONLY-SERVER."
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
  (interactive) (pichat-tool-picker--set-selection '(:builtins nil :mcp nil :extensions nil)))
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
  (pichat-tool-picker--set-selection
   (list :builtins (copy-sequence (plist-get pichat-tool-picker--state :baseline)) :mcp nil
         :extensions (copy-sequence (plist-get (plist-get pichat-tool-picker--state :preset) :extensions)))))

(defun pichat-tool-picker--page (delta prefix)
  "Move DELTA pages in PREFIX."
  (let* ((count (if (eq prefix 'pichat-tool-picker-server)
                    (length (plist-get (pichat-tool-picker--current-server) :tools))
                  (max (length (plist-get pichat-tool-picker--state :servers))
                       (length (pichat-tool-picker--extension-tools)))))
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
  (when-let* ((cancel (plist-get pichat-tool-picker--state :cancel))) (funcall cancel))
  (setf (plist-get pichat-tool-picker--state :cancel) nil))

(defun pichat-tool-picker--discover-extensions (&optional force)
  "Discover extension tools, reusing the draft unless FORCE."
  (let* ((state pichat-tool-picker--state) (draft (plist-get state :discovery)))
    (unless (and (not force) (eq 'ready (pichat-tool-discovery-draft-status draft)))
      (pichat-tool-discovery-draft-refresh
       draft (lambda (_draft) (when (eq state pichat-tool-picker--state)
                                (pichat-tool-picker--refresh-children)))))))

(defun pichat-tool-picker--discover ()
  "Refresh the MCP listing for the captured target."
  (pichat-tool-picker--stop-discovery)
  (let* ((state pichat-tool-picker--state)
         (version (1+ (or (plist-get state :version) 0)))
         (transport (plist-get state :transport)))
    (setf (plist-get state :version) version
          (plist-get state :loaded) nil (plist-get state :error) "Discovering MCP servers…")
    (setq pichat-tool-picker--state state)
    (pichat-tool-picker--refresh-display)
    (setf (plist-get state :cancel)
          (pichat-mcp-discovery-start
           transport (plist-get state :runtime-cwd)
           (or (pichat-transport-pi-executable transport) (plist-get state :executable))
           (lambda (servers errors)
             (when (and (eq state pichat-tool-picker--state) (= version (plist-get state :version)))
               (setf (plist-get state :servers) servers
                     (plist-get state :loaded) (or (not (null servers)) (not errors))
                     (plist-get state :error) (if errors (format "%s" errors)
                                               (unless servers "No MCP servers configured")))
               (setq pichat-tool-picker--state state)
               (pichat-tool-picker--refresh-children)))))
    (setq pichat-tool-picker--state state)))

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
  "Refresh both catalogues." :transient t
  (interactive) (pichat-tool-picker--discover) (pichat-tool-picker--discover-extensions t))

(defun pichat-tool-picker--return (selection)
  "Return SELECTION or :cancel to the owner."
  (let ((callback (plist-get pichat-tool-picker--state :callback)))
    (pichat-tool-picker--stop-discovery)
    (setq pichat-tool-picker--state nil)
    (funcall callback selection)))
(transient-define-suffix pichat-tool-picker-apply ()
  "Apply the validated draft."
  (interactive)
  (let* ((state pichat-tool-picker--state)
         (selection (pichat-tool-picker--selection))
         (snapshot (pichat-tool-selection-resolve (plist-get state :preset) selection)))
    (when (plist-get snapshot :mcp)
      (unless (plist-get state :loaded) (user-error "MCP discovery has not succeeded for this target"))
      (pichat-tool-selection-check-catalogue snapshot (plist-get state :servers)))
    (when (plist-get snapshot :extensions)
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
  [["Selection"
    ("a" "Select all eligible tools" pichat-tool-picker-all)
    ("n" "Select none" pichat-tool-picker-none)
    ("d" "Reset to preset" pichat-tool-picker-reset)
    ("r" "Refresh discovery" pichat-tool-picker-refresh)
    ("?" pichat-tool-picker-status :description pichat-tool-picker--status-description)
    ("!" pichat-tool-picker-extension-status :description pichat-tool-picker--extension-status)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Apply" pichat-tool-picker-apply) ("q" "Cancel" pichat-tool-picker-cancel)]]
  (interactive) (transient-setup 'pichat-tool-picker))
(transient-define-prefix pichat-tool-picker-server ()
  "Select MCP server tools."
  ["Server tools" :class transient-column :setup-children pichat-tool-picker--server-tools]
  [["Selection" ("a" "Select all" pichat-tool-picker-server-all)
    ("n" "Select none" pichat-tool-picker-server-none)
    ("[" "Previous page" pichat-tool-picker-prev) ("]" "Next page" pichat-tool-picker-next)]
   ["Action" ("RET" "Done" pichat-tool-picker-back) ("q" "Back" pichat-tool-picker-back)]]
  (interactive) (transient-setup 'pichat-tool-picker-server))

(defun pichat-tool-picker-open (preset selection directory transport executable callback
                                     &optional model discovery)
  "Open PRESET/SELECTION for DIRECTORY on TRANSPORT using EXECUTABLE.
CALLBACK receives a raw selection, nil baseline or :cancel.  MODEL and the
owner's DISCOVERY cache qualify the probe; no unrelated runtime is queried."
  (when (eq (plist-get preset :tools) :default)
    (user-error "Preset %s uses Pi defaults; Tools cannot customize it" (plist-get preset :name)))
  (let* ((cwd (file-name-as-directory (expand-file-name directory)))
         (context (pichat-transport-path-context transport (and (boundp 'pichat-path-mappings) pichat-path-mappings)))
         (runtime-cwd (or (plist-get (pichat-path-resolve-to-runtime cwd context) :path)
                          (user-error "Directory is unavailable to target %s" (pichat-transport-label transport))))
         (discovery (or discovery (pichat-tool-discovery-draft-create)))
         (probe-context (pichat-tool-discovery-context
                         transport runtime-cwd
                         (or (pichat-transport-pi-executable transport) executable) model)))
    (pichat-rpc--validate-preset-args preset (plist-get probe-context :args))
    (setf (plist-get probe-context :args)
          (append (plist-get probe-context :args)
                  (when (plist-get preset :system-prompt)
                    (list "--system-prompt" (plist-get preset :system-prompt)))
                  (when (plist-get preset :append-system-prompt)
                    (list "--append-system-prompt" (plist-get preset :append-system-prompt)))))
    (pichat-tool-discovery-draft-reset discovery probe-context)
    (setq pichat-tool-picker--state
          (list :preset preset :baseline (copy-sequence (plist-get preset :tools))
                :draft (copy-tree (or selection (pichat-tool-selection-resolve preset)))
                :discovery discovery :transport transport :runtime-cwd runtime-cwd
                :executable executable :callback callback :page 0 :cancel nil
                :servers nil :loaded nil :error nil :version 0))
    (transient-setup 'pichat-tool-picker)
    (pichat-tool-picker--discover)
    (pichat-tool-picker--discover-extensions)))

(defun pichat-tool-picker--abandoned ()
  "Release probes when the user quits the entire Transient stack."
  (when pichat-tool-picker--state
    (pichat-tool-picker--stop-discovery)
    (setq pichat-tool-picker--state nil)))
(add-hook 'transient-post-exit-hook #'pichat-tool-picker--abandoned)

(provide 'pichat-tool-picker)
;;; pichat-tool-picker.el ends here
