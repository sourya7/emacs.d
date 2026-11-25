;;; pichat-tool-selection.el --- Run-local PiChat tool selection -*- lexical-binding: t; -*-

;;; Commentary:
;; An explicit built-in preset owns its tool policy.  MCP tools are opt-in;
;; inherited (:default) presets stay entirely Pi-controlled.  Emacs-defined
;; tools are exact opt-in names captured in the snapshot's :emacs list; the
;; bridge exposes nothing else, and pass-through presets expose none.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-presets)
(require 'pichat-tools)

(defalias 'pichat-tool-selection--name #'pichat-presets-mcp-name)

(defconst pichat-tool-selection--indirect-mcp-exposures '("codemode" "deferred"))

(defun pichat-tool-selection-mcp-exposure-p (exposure)
  "Return non-nil when an MCP tool with EXPOSURE can be selected."
  (or (equal exposure "direct")
      (member exposure pichat-tool-selection--indirect-mcp-exposures)))

(defun pichat-tool-selection-resolve (preset &optional selection)
  "Resolve PRESET and optional explicit SELECTION into a runtime snapshot.
SELECTION contains :builtins, :mcp (SERVER . TOOL) pairs, :extensions and
:emacs exact names, and :all, the extension group sources whose future
tools are included (the Tools picker's \"Include future tools\"; their
current tools are among :extensions).  Omission means the preset baseline,
including its :mcp pairs and the sources of its (SOURCE . :all) groups;
MCP is disabled when the baseline has none.  A baseline whose :all groups
are not expanded yet (`pichat-presets-pending-all') also lists them as
:unexpanded, and so does a SELECTION that carries them on: its exact names
are incomplete, so no runtime may start from it.  An explicit selection
is complete, so an empty :mcp stays empty.  The pass-through preset
returns nil and cannot accept a selection."
  (let ((baseline (plist-get preset :tools)))
    (if (eq baseline :default)
        (progn
          (when selection
            (user-error "Preset %s uses Pi defaults; Tools cannot customize it"
                        (plist-get preset :name)))
          nil)
      (let ((builtins (if selection (plist-get selection :builtins) baseline))
            (mcp (if selection (plist-get selection :mcp)
                   (plist-get preset :mcp)))
            (extensions (if selection (plist-get selection :extensions)
                          (plist-get preset :extensions)))
            (emacs (if selection (plist-get selection :emacs)
                     (plist-get preset :emacs-tools)))
            (all (if selection (plist-get selection :all)
                   (pichat-presets-all-sources preset)))
            ;; A selection derived from such a baseline stays incomplete
            ;; until the Tools picker adds the discovered tools.
            (unexpanded (if selection (plist-get selection :unexpanded)
                          (pichat-presets-pending-all preset))))
        (unless (and (proper-list-p all)
                     (cl-every #'pichat-presets-extension-spec-p all)
                     (= (length all) (length (delete-dups (copy-sequence all)))))
          (user-error "Invalid or duplicate extension groups with future tools: %S" all))
        (unless (pichat-presets-extension-names-p extensions)
          (user-error "Invalid or duplicate extension tool selection"))
        (unless (pichat-presets-extension-names-p emacs)
          (user-error "Invalid or duplicate Emacs-defined tool selection"))
        (when (cl-intersection emacs extensions :test #'equal)
          (user-error "Tool selected as both Emacs-defined and extension"))
        (unless (and (listp builtins) (proper-list-p builtins)
                     (cl-every (lambda (name) (member name baseline)) builtins)
                     (= (length builtins)
                        (length (cl-remove-duplicates (copy-sequence builtins)
                                                       :test #'equal))))
          (user-error "Tools must be unique built-ins from preset %s"
                      (plist-get preset :name)))
        (unless (and (listp mcp) (proper-list-p mcp)
                     (cl-every (lambda (pair)
                                 (and (consp pair) (stringp (car pair))
                                      (string-match-p "\\`[A-Za-z0-9_-]+\\'" (car pair))
                                      (stringp (cdr pair)) (not (string-empty-p (cdr pair)))))
                               mcp)
                     (= (length mcp)
                        (length (cl-remove-duplicates (copy-tree mcp) :test #'equal))))
          (user-error "Invalid or duplicate MCP tool selection"))
        (let ((names (mapcar (lambda (pair) (pichat-tool-selection--name (car pair) (cdr pair))) mcp)))
          (unless (pichat-presets-mcp-pairs-p mcp)
            (user-error "Ambiguous normalized MCP tool names"))
          (when (cl-intersection names extensions :test #'equal)
            (user-error "Tool selected as both MCP and extension"))
          (when (cl-intersection names emacs :test #'equal)
            (user-error "Tool selected as both MCP and Emacs-defined"))
          (append (list :builtins (pichat-presets--copy builtins)
                        :mcp (pichat-presets--copy mcp) :names names)
                  (when extensions
                    (list :extensions (sort (pichat-presets--copy extensions) #'string<)))
                  (when emacs
                    (list :emacs (sort (pichat-presets--copy emacs) #'string<)))
                  (when all
                    (list :all (sort (pichat-presets--copy all) #'string<)))
                  (when unexpanded
                    (list :unexpanded (pichat-presets--copy unexpanded)))))))))

(defun pichat-tool-selection-check-expanded (snapshot preset-name)
  "Return resolved Tools SNAPSHOT, or signal when it is not expanded.
PRESET-NAME names its preset in the refusal.  A snapshot with
:unexpanded sources lacks the tools of the preset's (SOURCE . :all)
groups, so a runtime started from it would silently miss them."
  (when-let* ((sources (plist-get snapshot :unexpanded)))
    (user-error "Preset %s includes future tools of %s; launch it from `pichat-launch' (which discovers them first) or choose its tools with x Tools"
                preset-name (string-join sources ", ")))
  snapshot)

(defun pichat-tool-selection-emacs-unavailable (snapshot &optional bridge-p)
  "Return SNAPSHOT's selected Emacs-defined tools a runtime cannot offer.
Without BRIDGE-P the bridge is absent, so none can be offered; otherwise
only names missing from the registry.  Such names are skipped, not fatal."
  (let ((names (plist-get snapshot :emacs)))
    (if bridge-p
        (cl-remove-if (lambda (name) (gethash name pichat-tools-registry)) names)
      names)))

(defun pichat-tool-selection-emacs-note (snapshot &optional bridge-p)
  "Return a short note about SNAPSHOT Emacs tools unavailable without BRIDGE-P."
  (when-let* ((names (pichat-tool-selection-emacs-unavailable snapshot bridge-p)))
    (format "Emacs-defined tools not available%s: %s"
            (if bridge-p " (not loaded)" " (no PiChat bridge for this runtime)")
            (string-join names ", "))))

(defun pichat-tool-selection-mcp-indirect-p (snapshot servers)
  "Validate the exact MCP choices in SNAPSHOT and report indirect exposure."
  (let (indirect)
    (dolist (pair (plist-get snapshot :mcp))
      (let* ((server (cl-find (car pair) servers :key (lambda (entry) (plist-get entry :name))
                              :test #'equal))
             (tool (cl-find (cdr pair) (plist-get server :tools)
                            :key (lambda (entry) (plist-get entry :name)) :test #'equal))
             (exposure (plist-get tool :exposure)))
        (unless (and (plist-get tool :eligible)
                     (pichat-tool-selection-mcp-exposure-p exposure))
          (user-error "MCP tool %s/%s is not available for selection" (car pair) (cdr pair)))
        (when (member exposure pichat-tool-selection--indirect-mcp-exposures)
          (setq indirect t))))
    indirect))

(defun pichat-tool-selection-mcp-access (snapshot servers tools)
  "Validate SNAPSHOT against destination SERVERS and return a derived route.
TOOLS is the extension-tool catalogue for the same destination and launch
configuration.  Return an exact extension tool name only when an indirect
MCP tool needs a route and no usable one was explicitly selected.  Prefer
codemode to tool_search; either can serve both indirect exposures.  Signal
`user-error' for an unavailable MCP choice or missing usable route.

Neither catalogue nor the returned name belongs in a stored selection.
Recompute from the destination catalogues when preparing each runtime."
  (when (pichat-tool-selection-mcp-indirect-p snapshot servers)
    (let* ((routes
            (cl-loop for name in '("codemode" "tool_search")
                     for tool = (cl-find name tools :key (lambda (entry) (plist-get entry :name))
                                         :test #'equal)
                     when (and (plist-get tool :eligible)
                               (eq t (plist-get tool :reaches-tools))
                               (not (member name (plist-get snapshot :emacs))))
                     collect name))
           (selected (plist-get snapshot :extensions)))
      (unless routes
        (user-error "Indirect MCP selections require an available codemode or tool_search extension tool that can reach MCP tools"))
      (unless (cl-some (lambda (route) (member route selected)) routes)
        (car routes)))))

(defun pichat-tool-selection-check-catalogue (snapshot servers)
  "Return validated SNAPSHOT for a caller without extension discovery.
Indirect choices require `pichat-tool-selection-mcp-access' with a destination
extension catalogue, so refuse them rather than launch without a route."
  (pichat-tool-selection-mcp-access snapshot servers nil)
  snapshot)

(defun pichat-tool-selection-check-extensions (snapshot tools)
  "Validate SNAPSHOT's extension choices against registered TOOLS."
  (dolist (name (plist-get snapshot :extensions))
    (let ((tool (cl-find name tools :key (lambda (item) (plist-get item :name))
                         :test #'equal)))
      (unless (and tool (plist-get tool :eligible))
        (user-error "Extension tool %s is missing or cannot be enabled" name))))
  snapshot)

(defun pichat-tool-selection-args (snapshot)
  "Return Pi startup tool arguments for resolved SNAPSHOT.
Nil SNAPSHOT means pass-through; a preset with no tools uses --no-tools."
  (when snapshot
    ;; Pi's allowlist also governs tools the bridge registers later, so the
    ;; selected Emacs-defined names that are registered are allowed here too.
    (let* ((missing (pichat-tool-selection-emacs-unavailable snapshot t))
           (names (append (plist-get snapshot :builtins)
                          (plist-get snapshot :names)
                          (plist-get snapshot :extensions)
                          (cl-set-difference (plist-get snapshot :emacs) missing
                                             :test #'equal))))
      (append (if names
                  (list "--tools" (string-join names ","))
                (list "--no-tools"))
              (unless (plist-get snapshot :mcp) (list "--no-mcp"))))))

(provide 'pichat-tool-selection)
;;; pichat-tool-selection.el ends here
