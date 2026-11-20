;;; pichat-launch-extensions.el --- Extensions added for one launch -*- lexical-binding: t; -*-

;;; Commentary:

;; The launcher's Extensions menu edits the extensions added for one
;; launch: an ordered list of (SPEC . CHECKED) entries, where SPEC is a
;; path or an `npm:' / `git:' package specification as given to Pi's -e
;; option.  The menu also offers recently used specs and lists the
;; extensions Pi discovered, from the launcher's owner-scoped discovery
;; cache.  Only extensions that register tools or commands can be listed;
;; Pi reports no others.  The menu changes no runtime: the launcher owns
;; the result.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)
(require 'pichat-transient)
(require 'pichat-presets)
(require 'pichat-tool-discovery)
(require 'pichat-tool-picker)

(defvar pichat-launch-extensions--state nil
  "Draft of the open Extensions menu, or nil.")

(defvar pichat-launch-extensions--history nil
  "Minibuffer history of extensions entered with Add.")

(defconst pichat-launch-extensions--keys
  (mapcar #'char-to-string (string-to-list "1234567890"))
  "Keys of added extensions; their number bounds the list.")

(defconst pichat-launch-extensions--recent-keys '("A" "B" "C")
  "Keys of recently used extensions.")

;;; Draft data

(defun pichat-launch-extensions-checked (added)
  "Return the checked specs of ADDED, an ordered (SPEC . CHECKED) list."
  (cl-loop for (spec . checked) in added when checked collect spec))

(defun pichat-launch-extensions--added ()
  "Return the open menu's (SPEC . CHECKED) draft."
  (plist-get pichat-launch-extensions--state :added))

(defun pichat-launch-extensions--set-added (added)
  "Store ADDED as the open menu's draft."
  (setf (plist-get pichat-launch-extensions--state :added) added))

(defun pichat-launch-extensions--add (spec)
  "Add SPEC, checked, to the draft; signal for an invalid or repeated SPEC.
Also refuse SPEC when the menu's ready discovery shows that Pi already
loads it (see `pichat-launch-extensions-duplicate')."
  (let ((added (pichat-launch-extensions--added)))
    (unless (pichat-presets-extension-spec-p spec)
      (user-error "Invalid extension %S: one line, not starting with `-'" spec))
    (when (assoc spec added)
      (user-error "%s is already added" spec))
    (when-let* ((found (pichat-launch-extensions--duplicate spec)))
      (user-error "%s is not added: Pi already loads it (discovered as %s)"
                  spec found))
    (when (>= (length added) (length pichat-launch-extensions--keys))
      (user-error "At most %d extensions can be added"
                  (length pichat-launch-extensions--keys)))
    (pichat-launch-extensions--set-added
     (append (copy-tree added) (list (cons spec t))))))

(defun pichat-launch-extensions--recent ()
  "Return recently used specs that are not added, newest first."
  (let ((added (pichat-launch-extensions--added)))
    (cl-remove-if (lambda (spec) (assoc spec added))
                  (pichat-presets-recent-extensions))))

(defun pichat-launch-extensions-discovered (draft)
  "Return the extensions of discovery DRAFT that register tools or commands.
Each element is (LABEL . DETAIL).  Extensions are grouped as in the Tools
picker (see `pichat-tool-picker--extension-group-key'): DETAIL is the
package source or path, or for \"Pi built-in\" the built-in paths, or for
\"Unattributed\" the number of tools and commands without a known source.
Items of extensions the probe added are grouped under their specs.  Core
built-in tools and tools of Pi's built-in MCP are not extensions and are
skipped.  Order: discovery order, then Unattributed, then Pi built-in."
  (let ((attribution (pichat-tool-picker-added-attribution
                      (pichat-tool-discovery-draft-context draft)))
        groups)
    (dolist (item (append
                   (cl-remove-if
                    (lambda (tool)
                      (or (member (plist-get tool :name) pichat-presets--known-built-in-tools)
                          (pichat-tool-picker--mcp-source-p tool)))
                    (pichat-tool-discovery-draft-tools draft))
                   (pichat-tool-discovery-draft-commands draft)))
      (let* ((key (pichat-tool-picker--extension-group-key item attribution))
             (entry (assoc key groups)))
        (if entry (setcdr entry (append (cdr entry) (list item)))
          (push (list key item) groups))))
    (setq groups (nreverse groups))
    (setq groups (append (cl-remove-if (lambda (group) (keywordp (car group))) groups)
                         (cl-remove-if-not (lambda (group) (eq (car group) :unattributed)) groups)
                         (cl-remove-if-not (lambda (group) (eq (car group) :builtin)) groups)))
    (let ((labels (mapcar (lambda (group) (pichat-tool-picker--extension-group-label (car group)))
                          groups)))
      (cl-loop for (key . items) in groups
               for label in labels
               collect
               (pcase key
                 (:builtin
                  (cons label (string-join
                               (delete-dups (mapcar (lambda (item)
                                                      (plist-get (plist-get item :source) :path))
                                                    items))
                               ", ")))
                 (:unattributed
                  (cons label (format "%d without a known source" (length items))))
                 (_ (cons (if (> (cl-count label labels :test #'equal) 1) key label)
                          key)))))))

;;; Duplicates

(defun pichat-launch-extensions-duplicate (spec draft)
  "Return how discovery DRAFT shows that Pi already loads SPEC, or nil.
DRAFT must hold ready results of a probe without added extensions.  A
package SPEC (see `pichat-tool-picker-package-spec-p') duplicates a
discovered package source exactly; a path duplicates, after resolution
against the probe's directory (and, locally, symbolic links), a
discovered extension's path or base directory.  The result is that
source or path.  Only extensions that register tools or commands are
discovered, and Pi's built-in tools are not files."
  (when (eq (pichat-tool-discovery-draft-status draft) 'ready)
    (let* ((context (pichat-tool-discovery-draft-context draft))
           (cwd (or (plist-get context :cwd) default-directory))
           (transport (plist-get context :transport))
           (local (not (and (pichat-transport-p transport)
                            (eq 'ssh (pichat-transport-kind transport)))))
           (package (pichat-tool-picker-package-spec-p spec))
           (wanted (unless package (pichat-tool-picker-resolve-path spec cwd local)))
           (sources (delq nil (mapcar (lambda (item) (plist-get item :source))
                                      (append (pichat-tool-discovery-draft-tools draft)
                                              (pichat-tool-discovery-draft-commands draft))))))
      (cl-loop for source in sources
               for kind = (plist-get source :source)
               thereis
               (cond
                ((equal kind "builtin") nil)
                (package (and (equal kind spec) kind))
                (wanted
                 (cl-loop for path in (list (plist-get source :path)
                                            (plist-get source :base-dir))
                          thereis (and path
                                       (equal wanted (pichat-tool-picker-resolve-path
                                                      path cwd local))
                                       path))))))))

(defun pichat-launch-extensions--duplicate (spec)
  "Return how the open menu's discovery shows Pi already loads SPEC, or nil."
  (pichat-launch-extensions-duplicate
   spec (plist-get pichat-launch-extensions--state :discovery)))

(defun pichat-launch-extensions--duplicates (added)
  "Return (SPEC . FOUND) for the checked specs of ADDED that Pi already loads."
  (cl-loop for spec in (pichat-launch-extensions-checked added)
           for found = (pichat-launch-extensions--duplicate spec)
           when found collect (cons spec found)))

(defun pichat-launch-extensions--duplicates-message (duplicates)
  "Return a message naming DUPLICATES, (SPEC . FOUND) pairs."
  (format "Pi already loads %s; uncheck or remove %s"
          (mapconcat (lambda (pair) (format "%s (discovered as %s)" (car pair) (cdr pair)))
                     duplicates ", ")
          (if (cdr duplicates) "them" "it")))

;;; Discovery

(defun pichat-launch-extensions--stop-discovery ()
  "Cancel the open menu's pending discovery; keep completed results."
  (when-let* ((draft (plist-get pichat-launch-extensions--state :discovery))
              (cancel (pichat-tool-discovery-draft-cancel draft)))
    (when (eq 'loading (pichat-tool-discovery-draft-status draft))
      (funcall cancel)
      (setf (pichat-tool-discovery-draft-cancel draft) nil
            (pichat-tool-discovery-draft-status draft) nil))))

(defun pichat-launch-extensions--discover (&optional force)
  "Discover the launch's extensions, reusing ready results unless FORCE.
The probe context comes from the owner; when it signals, the reason is
shown instead of results and nothing starts."
  (let* ((state pichat-launch-extensions--state)
         (draft (plist-get state :discovery)))
    (setf (plist-get state :probe-error) nil)
    (condition-case err
        (pichat-tool-discovery-draft-reset draft (funcall (plist-get state :probe)))
      (error (setf (plist-get state :probe-error) (error-message-string err))))
    (unless (or (plist-get state :probe-error)
                (and (not force) (memq (pichat-tool-discovery-draft-status draft)
                                       '(ready loading))))
      (pichat-tool-discovery-draft-refresh
       draft (lambda (_draft)
               (when (eq state pichat-launch-extensions--state)
                 (when-let* ((duplicates (pichat-launch-extensions--duplicates
                                          (pichat-launch-extensions--added))))
                   (message "%s" (pichat-launch-extensions--duplicates-message duplicates)))
                 (when (and transient--prefix
                            (eq (oref transient--prefix command)
                                'pichat-launch-extensions-menu))
                   (pichat-launch-extensions--show))))))))

;;; Menu entries

(defun pichat-launch-extensions--fit (text indent)
  "Return TEXT shortened from the left to fit after INDENT columns."
  (pichat-transient-truncate-left text (max 10 (- (frame-width) indent 1))))

(defun pichat-launch-extensions--added-entries (_)
  "Build checkboxes for the added extensions."
  (transient-parse-suffixes
   'pichat-launch-extensions-menu
   (or (cl-loop for (spec . _) in (pichat-launch-extensions--added)
                for key in pichat-launch-extensions--keys
                collect
                (let ((spec spec))
                  (list key spec
                        (lambda () (interactive)
                          (let ((added (copy-tree (pichat-launch-extensions--added))))
                            (setcdr (assoc spec added) (not (cdr (assoc spec added))))
                            (pichat-launch-extensions--set-added added)
                            (when transient--prefix (transient--redisplay))))
                        :description
                        (lambda ()
                          (pichat-tool-picker--description
                           (cdr (assoc spec (pichat-launch-extensions--added)))
                           (pichat-launch-extensions--fit spec 9)))
                        :transient t)))
       (list (list :info (lambda () (propertize "None; + to add one" 'face 'shadow)))))))

(defun pichat-launch-extensions--recent-heading ()
  "Head the recently used extensions with their count."
  (format "Recent (%d)" (length (pichat-launch-extensions--recent))))

(defun pichat-launch-extensions--recent-entries (_)
  "Build entries adding a recently used extension."
  (transient-parse-suffixes
   'pichat-launch-extensions-menu
   (cl-loop for spec in (pichat-launch-extensions--recent)
            for key in pichat-launch-extensions--recent-keys
            collect
            (let ((spec spec))
              (list key (pichat-launch-extensions--fit spec 5)
                    (lambda () (interactive)
                      (condition-case err
                          (pichat-launch-extensions--add spec)
                        (user-error (message "%s" (error-message-string err))))
                      (pichat-launch-extensions--show))
                    :transient t)))))

(defun pichat-launch-extensions--discovered-entries (_)
  "Build informational lines for the discovered extensions."
  (let* ((state pichat-launch-extensions--state)
         (draft (plist-get state :discovery))
         (status (pichat-tool-discovery-draft-status draft))
         (shadow (lambda (text) (list :info (propertize text 'face 'shadow)))))
    (transient-parse-suffixes
     'pichat-launch-extensions-menu
     (cond
      ((plist-get state :probe-error)
       (list (funcall shadow (pichat-transient-fill
                              (concat "Unavailable: " (plist-get state :probe-error))))))
      ((eq status 'loading) (list (funcall shadow "Discovering…")))
      ((eq status 'failed)
       (list (funcall shadow (pichat-transient-fill
                              (concat "Failed: " (or (pichat-tool-discovery-draft-error draft)
                                                     "unknown error"))))))
      ((not (eq status 'ready)) (list (funcall shadow "Not discovered; r to refresh")))
      (t
       (or (cl-loop for (label . detail) in (pichat-launch-extensions-discovered draft)
                    collect
                    (list :info
                          (let ((room (- (frame-width) 6 (string-width label))))
                            (if (< room 12) label
                              (concat label "  "
                                      (propertize (pichat-transient-truncate-left detail room)
                                                  'face 'shadow))))))
           (list (funcall shadow "None"))))))))

;;; Actions

(defun pichat-launch-extensions--show ()
  "Display the Extensions menu for the open draft."
  (transient-setup 'pichat-launch-extensions-menu))

(defmacro pichat-launch-extensions--reading (&rest body)
  "Run BODY, which may read input, then redisplay the menu.
A refusal or quit is reported and leaves the draft unchanged."
  (declare (indent 0) (debug t))
  `(progn
     (condition-case err
         (progn ,@body)
       (quit (message "Cancelled"))
       (user-error (message "%s" (error-message-string err))))
     (when pichat-launch-extensions--state
       (pichat-launch-extensions--show))))

(transient-define-suffix pichat-launch-extensions-add ()
  "Add an extension, checked, by path or package specification."
  (interactive)
  (pichat-launch-extensions--reading
    (pichat-launch-extensions--add
     (string-trim (read-string "Add extension (path, npm:… or git:…): "
                               nil 'pichat-launch-extensions--history)))))

(transient-define-suffix pichat-launch-extensions-remove ()
  "Remove one added extension."
  (interactive)
  (pichat-launch-extensions--reading
    (let ((added (pichat-launch-extensions--added)))
      (unless added (user-error "No extensions are added"))
      (let ((spec (completing-read "Remove extension: " (mapcar #'car added) nil t)))
        (pichat-launch-extensions--set-added
         (cl-remove spec (copy-tree added) :key #'car :test #'equal))))))

(transient-define-suffix pichat-launch-extensions-refresh ()
  "Discover the extensions Pi loads for this launch again." :transient t
  (interactive)
  (pichat-launch-extensions--discover t)
  (pichat-launch-extensions--show))

(defun pichat-launch-extensions--return (result)
  "Close the menu and give RESULT, a draft or :cancel, to the owner."
  (let ((callback (plist-get pichat-launch-extensions--state :callback)))
    (pichat-launch-extensions--stop-discovery)
    (setq pichat-launch-extensions--state nil)
    (funcall callback result)))

(transient-define-suffix pichat-launch-extensions-done ()
  "Apply the added extensions to the launch draft.
The checked ones become the most recently used extensions.  Refuse, and
stay in the menu, while a checked one is already loaded by Pi according
to the ready discovery."
  (interactive)
  (let* ((added (pichat-launch-extensions--added))
         (duplicates (pichat-launch-extensions--duplicates added)))
    (if duplicates
        (progn
          (message "%s" (pichat-launch-extensions--duplicates-message duplicates))
          (pichat-launch-extensions--show))
      (when-let* ((reason (pichat-presets-note-recent-extensions
                           (pichat-launch-extensions-checked added))))
        (message "Recent extensions kept for this session only: %s" reason))
      (pichat-launch-extensions--return (copy-tree added)))))

(transient-define-suffix pichat-launch-extensions-cancel ()
  "Discard changes to the added extensions."
  (interactive)
  (pichat-launch-extensions--return :cancel))

(transient-define-prefix pichat-launch-extensions-menu ()
  "Choose extensions added for this launch."
  ["Added for this launch" :class transient-column
   :setup-children pichat-launch-extensions--added-entries]
  [:description pichat-launch-extensions--recent-heading :class transient-column
   :setup-children pichat-launch-extensions--recent-entries]
  ["Discovered (with tools or commands)" :class transient-column
   :setup-children pichat-launch-extensions--discovered-entries]
  [["Actions"
    ("+" "Add…" pichat-launch-extensions-add)
    ("-" "Remove…" pichat-launch-extensions-remove)
    ("r" "Refresh" pichat-launch-extensions-refresh)]
   ["Action"
    ("RET" "Done" pichat-launch-extensions-done)
    ("q" "Cancel" pichat-launch-extensions-cancel)]]
  [:hide (lambda () t)
   ("<return>" pichat-launch-extensions-done)]
  (interactive)
  (unless pichat-launch-extensions--state
    (user-error "Open Extensions from the PiChat launcher (l)"))
  (pichat-launch-extensions--show))

(defun pichat-launch-extensions-open (added discovery probe callback)
  "Open the Extensions menu on a copy of ADDED, (SPEC . CHECKED) entries.
DISCOVERY is the owner's discovery cache.  PROBE returns the probe context
for the launch (see `pichat-tool-picker-discovery-context') or signals why
discovery is unavailable; it is called on opening and on Refresh.  Ready
cached results are reused.  CALLBACK receives the new list on Done or
`:cancel'.  Nothing else changes."
  (setq pichat-launch-extensions--state
        (list :added (copy-tree added) :discovery discovery :probe probe
              :callback callback :probe-error nil))
  (pichat-launch-extensions--discover)
  (pichat-launch-extensions--show))

(defun pichat-launch-extensions--abandoned ()
  "Release discovery when the user quits the entire Transient stack."
  (when pichat-launch-extensions--state
    (pichat-launch-extensions--stop-discovery)
    (setq pichat-launch-extensions--state nil)))
(add-hook 'transient-post-exit-hook #'pichat-launch-extensions--abandoned)

(provide 'pichat-launch-extensions)
;;; pichat-launch-extensions.el ends here
