;;; pichat-tool-selection.el --- Run-local PiChat tool selection -*- lexical-binding: t; -*-

;;; Commentary:
;; An explicit built-in preset owns its tool policy.  MCP tools are opt-in;
;; inherited (:default) presets stay entirely Pi-controlled.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-presets)

(defun pichat-tool-selection--name (server tool)
  "Return Pi's unambiguous MCP name for SERVER and original TOOL.
Reject normalized collisions against the complete server catalogue first:
Pi hash-suffixes both members of a collision."
  (concat "mcp__" (replace-regexp-in-string "[^A-Za-z0-9_]" "_" server)
          "__" (replace-regexp-in-string "[^A-Za-z0-9_]" "_" tool)))

(defun pichat-tool-selection-resolve (preset &optional selection)
  "Resolve PRESET and optional explicit SELECTION into a runtime snapshot.
SELECTION is a plist with :builtins and :mcp (SERVER . TOOL) pairs.
An omitted SELECTION means the preset baseline, with MCP disabled.  The
pass-through preset returns nil and cannot accept a selection."
  (let ((baseline (plist-get preset :tools)))
    (if (eq baseline :default)
        (progn
          (when selection
            (user-error "Preset %s uses Pi defaults; Tools cannot customize it"
                        (plist-get preset :name)))
          nil)
      (let ((builtins (if selection (plist-get selection :builtins) baseline))
            (mcp (and selection (plist-get selection :mcp))))
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
          (unless (= (length names)
                     (length (cl-remove-duplicates (copy-sequence names) :test #'equal)))
            (user-error "Ambiguous normalized MCP tool names"))
          (list :builtins (copy-sequence builtins)
                :mcp (copy-tree mcp)
                :names names))))))

(defun pichat-tool-selection-check-catalogue (snapshot servers)
  "Validate SNAPSHOT MCP choices against discovered SERVERS.
Fail closed on disconnected, hidden, non-direct, absent, or ambiguous tools."
  (dolist (pair (plist-get snapshot :mcp))
    (let* ((server (cl-find (car pair) servers :key (lambda (entry) (plist-get entry :name))
                            :test #'equal))
           (tool (cl-find (cdr pair) (plist-get server :tools)
                          :key (lambda (entry) (plist-get entry :name)) :test #'equal)))
      (unless (and server tool (plist-get tool :eligible))
        (user-error "MCP tool %s/%s is not available with direct exposure"
                    (car pair) (cdr pair)))))
  snapshot)

(defun pichat-tool-selection-args (snapshot)
  "Return Pi startup tool arguments for resolved SNAPSHOT.
Nil SNAPSHOT means pass-through; a preset with no tools uses --no-tools."
  (when snapshot
    (let ((names (append (plist-get snapshot :builtins)
                         (plist-get snapshot :names))))
      (append (if names
                  (list "--tools" (string-join names ","))
                (list "--no-tools"))
              (unless (plist-get snapshot :mcp) (list "--no-mcp"))))))

(provide 'pichat-tool-selection)
;;; pichat-tool-selection.el ends here
