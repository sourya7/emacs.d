;;; pichat-tool-picker.el --- Preset-aware Tools Transient -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'pichat-tool-selection)
(require 'pichat-mcp-discovery)
(require 'pichat-path)

(defvar pichat-tool-picker--state nil
  "State of the currently open Tools picker (only one Transient is active).")

(defconst pichat-tool-picker--keys
  (mapcar #'char-to-string
          (string-to-list "1234567890bcfghijklmopstuvwxyz"))
  "Keys available for dynamically discovered tools and servers.")

(defconst pichat-tool-picker--server-keys
  (mapcar #'char-to-string (string-to-list "ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
  "Server shortcuts, distinct from the built-in tool shortcuts.")

(defconst pichat-tool-picker--page-size 20)

(defun pichat-tool-picker--refresh-display ()
  "Redisplay the picker when its Transient is currently visible."
  (when (and transient--prefix
             (memq (oref transient--prefix command)
                   '(pichat-tool-picker pichat-tool-picker-server)))
    (transient--redisplay)))

(defun pichat-tool-picker--refresh-children ()
  "Rebuild the visible picker when MCP discovery changes its tool list."
  (when (and transient--prefix
             (memq (oref transient--prefix command)
                   '(pichat-tool-picker pichat-tool-picker-server)))
    (transient-setup (oref transient--prefix command) nil nil
                     :scope (oref transient--prefix scope))))

(defun pichat-tool-picker--description (checked label)
  "Return a checked or unchecked LABEL for a tool."
  (format "[%s] %s" (if checked "✓" " ") label))

(defun pichat-tool-picker--selection ()
  "Return the current picker draft."
  (plist-get pichat-tool-picker--state :draft))

(defun pichat-tool-picker--set-selection (selection)
  "Store draft SELECTION and refresh visible descriptions."
  (setq pichat-tool-picker--state
        (plist-put pichat-tool-picker--state :draft selection))
  (pichat-tool-picker--refresh-display))

(defun pichat-tool-picker--toggle (kind value)
  "Toggle VALUE under KIND (:builtins or :mcp) in the picker draft."
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (values (plist-get selection kind)))
    (setq selection (plist-put selection kind
                               (if (member value values)
                                   (cl-remove value values :test #'equal)
                                 (append values (list value)))))
    (pichat-tool-picker--set-selection selection)))

(defun pichat-tool-picker--page-items (items)
  "Return visible slice of ITEMS for the current page."
  (let ((start (* pichat-tool-picker--page-size
                  (or (plist-get pichat-tool-picker--state :page) 0))))
    (cl-subseq items (min start (length items))
               (min (+ start pichat-tool-picker--page-size) (length items)))))

(defun pichat-tool-picker--builtins (_)
  "Produce the dynamic built-in tool group."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for name in (plist-get pichat-tool-picker--state :baseline)
            for key in pichat-tool-picker--keys
            collect
            (let ((name name))
              (list key name
                    (lambda () (interactive) (pichat-tool-picker--toggle :builtins name))
                    :description
                    (lambda () (pichat-tool-picker--description
                                (member name (plist-get (pichat-tool-picker--selection)
                                                        :builtins)) name))
                    :transient t)))))

(defun pichat-tool-picker--servers (_)
  "Produce the dynamic MCP server group."
  (transient-parse-suffixes
   'pichat-tool-picker
   (cl-loop for server in (pichat-tool-picker--page-items
                           (plist-get pichat-tool-picker--state :servers))
            for key in pichat-tool-picker--server-keys
            collect
            (let ((name (plist-get server :name)))
              (list key name
                    (lambda () (interactive)
                      (setq pichat-tool-picker--state
                            (plist-put pichat-tool-picker--state :server name))
                      (setq pichat-tool-picker--state
                            (plist-put pichat-tool-picker--state :page 0))
                      (transient-setup 'pichat-tool-picker-server))
                    :description
                    (lambda ()
                      (let* ((entry (cl-find name
                                             (plist-get pichat-tool-picker--state :servers)
                                             :key (lambda (item) (plist-get item :name))
                                             :test #'equal))
                             (count (cl-count-if
                                     (lambda (tool)
                                       (member (cons name (plist-get tool :name))
                                               (plist-get (pichat-tool-picker--selection) :mcp)))
                                     (plist-get entry :tools))))
                        (format "%s (%s, %d/%d) →" name
                                (or (plist-get entry :state) "unknown") count
                                (length (plist-get entry :tools)))))
                    :transient t)))))

(defun pichat-tool-picker--server-tools (_)
  "Produce toggles for the active server's tools."
  (let* ((server-name (plist-get pichat-tool-picker--state :server))
         (server (cl-find server-name (plist-get pichat-tool-picker--state :servers)
                          :key (lambda (item) (plist-get item :name)) :test #'equal)))
    (transient-parse-suffixes
     'pichat-tool-picker-server
     (cl-loop for tool in (pichat-tool-picker--page-items (plist-get server :tools))
              for key in pichat-tool-picker--keys
              collect
              (let* ((name (plist-get tool :name))
                     (pair (cons server-name name))
                     (eligible (plist-get tool :eligible)))
                (list key name
                      (lambda () (interactive)
                        (if eligible
                            (pichat-tool-picker--toggle :mcp pair)
                          (user-error "MCP tool %s/%s is not directly available"
                                      server-name name)))
                      :description
                      (lambda ()
                        (concat (pichat-tool-picker--description
                                 (member pair (plist-get (pichat-tool-picker--selection) :mcp))
                                 name)
                                (unless eligible
                                  (format " (%s)" (or (plist-get tool :exposure)
                                                      "unavailable")))))
                      :transient t))))))

(defun pichat-tool-picker--current-server ()
  "Return the selected MCP server entry."
  (cl-find (plist-get pichat-tool-picker--state :server)
           (plist-get pichat-tool-picker--state :servers)
           :key (lambda (item) (plist-get item :name)) :test #'equal))

(defun pichat-tool-picker--all (&optional only-server)
  "Select all eligible tools, optionally only for ONLY-SERVER."
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (servers (if only-server (list (pichat-tool-picker--current-server))
                    (plist-get pichat-tool-picker--state :servers)))
         (pairs (cl-loop for server in servers
                         append (cl-loop for tool in (plist-get server :tools)
                                          when (plist-get tool :eligible)
                                          collect (cons (plist-get server :name)
                                                        (plist-get tool :name))))))
    (unless (plist-get pichat-tool-picker--state :loaded)
      (user-error "MCP discovery is incomplete"))
    (setq selection (plist-put selection :mcp
                               (if only-server
                                   (append
                                    (cl-remove-if (lambda (pair)
                                                    (equal (car pair) only-server))
                                                  (plist-get selection :mcp))
                                    pairs)
                                 pairs)))
    (unless only-server
      (setq selection (plist-put selection :builtins
                                 (copy-sequence (plist-get pichat-tool-picker--state
                                                           :baseline)))))
    (pichat-tool-picker--set-selection selection)))

(transient-define-suffix pichat-tool-picker-all ()
  "Select all listed eligible tools in the outer picker."
  :transient t
  (interactive)
  (pichat-tool-picker--all))

(transient-define-suffix pichat-tool-picker-server-all ()
  "Select all eligible tools of this server."
  :transient t
  (interactive)
  (pichat-tool-picker--all (plist-get pichat-tool-picker--state :server)))

(transient-define-suffix pichat-tool-picker-none ()
  "Deselect all built-in and MCP tools."
  :transient t
  (interactive)
  (pichat-tool-picker--set-selection '(:builtins nil :mcp nil)))

(transient-define-suffix pichat-tool-picker-server-none ()
  "Deselect this server's tools."
  :transient t
  (interactive)
  (let* ((selection (copy-tree (pichat-tool-picker--selection)))
         (server (plist-get pichat-tool-picker--state :server)))
    (pichat-tool-picker--set-selection
     (plist-put selection :mcp
                (cl-remove-if (lambda (pair) (equal (car pair) server))
                              (plist-get selection :mcp))))))

(transient-define-suffix pichat-tool-picker-reset ()
  "Restore the preset's tool baseline in the draft."
  :transient t
  (interactive)
  (pichat-tool-picker--set-selection
   (list :builtins (copy-sequence (plist-get pichat-tool-picker--state :baseline))
         :mcp nil)))

(defun pichat-tool-picker--page (delta prefix)
  "Move DELTA pages and display PREFIX."
  (let* ((count (length (if (eq prefix 'pichat-tool-picker-server)
                            (plist-get (pichat-tool-picker--current-server) :tools)
                          (plist-get pichat-tool-picker--state :servers))))
         (last (max 0 (1- (ceiling count pichat-tool-picker--page-size)))))
    (setq pichat-tool-picker--state
          (plist-put pichat-tool-picker--state :page
                     (min last (max 0 (+ delta
                                         (or (plist-get pichat-tool-picker--state :page)
                                             0))))))
    (transient-setup prefix)))

(transient-define-suffix pichat-tool-picker-next ()
  "Show the next page."
  :transient t
  (interactive)
  (pichat-tool-picker--page 1 (oref transient--prefix command)))

(transient-define-suffix pichat-tool-picker-prev ()
  "Show the previous page."
  :transient t
  (interactive)
  (pichat-tool-picker--page -1 (oref transient--prefix command)))

(defun pichat-tool-picker--stop-discovery ()
  "Cancel the current discovery request."
  (when-let* ((cancel (plist-get pichat-tool-picker--state :cancel)))
    (funcall cancel)
    (setq pichat-tool-picker--state
          (plist-put pichat-tool-picker--state :cancel nil))))

(defun pichat-tool-picker--discover ()
  "Refresh discovery for the captured target and working directory."
  (pichat-tool-picker--stop-discovery)
  (let* ((state pichat-tool-picker--state)
         (version (1+ (or (plist-get state :version) 0)))
         (transport (plist-get state :transport))
         (cwd (plist-get state :runtime-cwd))
         (executable (or (pichat-transport-pi-executable transport)
                         (plist-get state :executable))))
    (setq state (plist-put state :version version))
    (setq state (plist-put state :loaded nil))
    (setq state (plist-put state :error "Discovering MCP servers…"))
    (setq pichat-tool-picker--state state)
    (pichat-tool-picker--refresh-display)
    (let ((cancel
           (pichat-mcp-discovery-start
            transport cwd executable
            (lambda (servers errors)
              (when (and (eq state pichat-tool-picker--state)
                         (= version (plist-get state :version)))
                (setq state (plist-put state :servers servers))
                (setq state (plist-put state :loaded (not (null servers))))
                (setq state (plist-put state :error
                                       (if errors
                                           (format "%s" errors)
                                         (unless servers "No MCP servers configured"))))
                (setq pichat-tool-picker--state state)
                (pichat-tool-picker--refresh-children))))))
      (setq pichat-tool-picker--state (plist-put pichat-tool-picker--state
                                               :cancel cancel)))))

(defun pichat-tool-picker--status-description ()
  "Describe MCP discovery in the outer menu."
  (let ((state pichat-tool-picker--state))
    (if (plist-get state :loaded)
        (format "MCP discovery: %d servers%s"
                (length (plist-get state :servers))
                (if-let* ((warning (plist-get state :error)))
                    (format " (%s)" warning) ""))
      (format "MCP discovery: %s" (or (plist-get state :error)
                                        "not available")))))

(transient-define-suffix pichat-tool-picker-status ()
  "Display MCP discovery status."
  :transient t
  (interactive)
  (message "%s" (pichat-tool-picker--status-description)))

(transient-define-suffix pichat-tool-picker-refresh ()
  "Refresh the MCP server list."
  :transient t
  (interactive)
  (pichat-tool-picker--discover))

(defun pichat-tool-picker--return (selection)
  "Leave the picker, returning SELECTION or :cancel to the launcher."
  (let ((callback (plist-get pichat-tool-picker--state :callback)))
    (pichat-tool-picker--stop-discovery)
    (setq pichat-tool-picker--state nil)
    (funcall callback selection)))

(transient-define-suffix pichat-tool-picker-apply ()
  "Commit the draft and return to the launch Transient."
  (interactive)
  (let* ((state pichat-tool-picker--state)
         (selection (pichat-tool-picker--selection))
         (baseline (plist-get state :baseline))
         (snapshot (pichat-tool-selection-resolve
                    (plist-get state :preset) selection)))
    (when (plist-get snapshot :mcp)
      (unless (plist-get state :loaded)
        (user-error "MCP discovery has not succeeded for this target"))
      (pichat-tool-selection-check-catalogue
       snapshot (plist-get state :servers)))
    (pichat-tool-picker--return
     (if (and (equal (plist-get snapshot :builtins) baseline)
              (not (plist-get snapshot :mcp)))
         nil selection))))

(transient-define-suffix pichat-tool-picker-cancel ()
  "Discard edits and return to the launch Transient."
  (interactive)
  (pichat-tool-picker--return :cancel))

(transient-define-suffix pichat-tool-picker-back ()
  "Return to the outer picker without applying the draft."
  (interactive)
  (setq pichat-tool-picker--state
        (plist-put pichat-tool-picker--state :page 0))
  (transient-setup 'pichat-tool-picker))

(transient-define-prefix pichat-tool-picker ()
  "Select tools for this PiChat launch."
  ["Built-in tools" :class transient-column
   :setup-children pichat-tool-picker--builtins]
  ["MCP servers" :class transient-column
   :setup-children pichat-tool-picker--servers]
  [["Selection"
    ("a" "Select all eligible tools" pichat-tool-picker-all)
    ("n" "Select none" pichat-tool-picker-none)
    ("d" "Reset to preset" pichat-tool-picker-reset)
    ("r" "Refresh servers" pichat-tool-picker-refresh)
    ("?" pichat-tool-picker-status
     :description pichat-tool-picker--status-description)
    ("[" "Previous page" pichat-tool-picker-prev)
    ("]" "Next page" pichat-tool-picker-next)]
   ["Action"
    ("RET" "Apply" pichat-tool-picker-apply)
    ("q" "Cancel" pichat-tool-picker-cancel)]]
  (interactive)
  (transient-setup 'pichat-tool-picker))

(transient-define-prefix pichat-tool-picker-server ()
  "Select tools provided by the active MCP server."
  ["Server tools" :class transient-column
   :setup-children pichat-tool-picker--server-tools]
  [["Selection"
    ("a" "Select all" pichat-tool-picker-server-all)
    ("n" "Select none" pichat-tool-picker-server-none)
    ("[" "Previous page" pichat-tool-picker-prev)
    ("]" "Next page" pichat-tool-picker-next)]
   ["Action"
    ("RET" "Done" pichat-tool-picker-back)
    ("q" "Back" pichat-tool-picker-back)]]
  (interactive)
  (transient-setup 'pichat-tool-picker-server))

(defun pichat-tool-picker-open (preset selection directory transport executable callback)
  "Open a Tools picker for PRESET and SELECTION.
DIRECTORY and TRANSPORT determine where Pi MCP discovery runs.  Invoke
CALLBACK with a committed selection or :cancel when leaving."
  (when (eq (plist-get preset :tools) :default)
    (user-error "Preset %s uses Pi defaults; Tools cannot customize it"
                (plist-get preset :name)))
  (let* ((cwd (file-name-as-directory (expand-file-name directory)))
         (path-context (pichat-transport-path-context
                        transport (and (boundp 'pichat-path-mappings)
                                       pichat-path-mappings)))
         (runtime-cwd (or (plist-get (pichat-path-resolve-to-runtime cwd path-context)
                                     :path)
                          (user-error "Directory is unavailable to target %s"
                                      (pichat-transport-label transport)))))
    (setq pichat-tool-picker--state
          (list :preset preset :baseline (copy-sequence (plist-get preset :tools))
                :draft (copy-tree (or selection
                                      (list :builtins (plist-get preset :tools)
                                            :mcp nil)))
                :transport transport :runtime-cwd runtime-cwd
                :executable executable :callback callback :page 0))
    (transient-setup 'pichat-tool-picker)
    (pichat-tool-picker--discover)))

(provide 'pichat-tool-picker)
;;; pichat-tool-picker.el ends here
