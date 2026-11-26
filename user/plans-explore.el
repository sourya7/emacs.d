;;; plans-explore.el --- Read-only plans CLI adapter -*- lexical-binding: t; -*-

;;; Code:

;; Loaded after json-explore by the configuration's module loader.
(require 'org)
(require 'view)

(defgroup plans-explore nil
  "Browse plans without changing their records or workspace state."
  :group 'json-explore)

(defcustom plans-explore-program "plans"
  "Name or path of the local plans executable."
  :type 'string)

(defcustom plans-explore-selection nil
  "Default selector keywords for interactive plans commands.
Use :root and :config for file names, and either :project for a project
key or :local t for the checkout's local plans.  Nil uses CLI defaults."
  :type '(plist :options ((:root directory) (:config file) (:project string) (:local boolean))))

(cl-defstruct (plans-explore--context (:constructor plans-explore--make-context))
  operation global-argv local id)

(defun plans-explore--id-p (id)
  (let ((case-fold-search nil))
    (and (stringp id) (string-match-p "\\`[a-z0-9]+\\(?:-[a-z0-9]+\\)*\\'" id))))

(defun plans-explore--local-path (path)
  (let ((path (expand-file-name path)))
    (when (file-remote-p path) (user-error "Plans explorer accepts only local paths"))
    path))

(defun plans-explore--global-args (root project local config)
  (when (and project local) (user-error "Choose either :project or :local"))
  (when (and project (not (plans-explore--id-p project)))
    (user-error "Invalid project key: %s" project))
  (append '("--json")
          (when root (list "--root" (plans-explore--local-path root)))
          (when project (list "--project" (copy-sequence project)))
          (when local '("--local"))
          (when config (list "--config" (plans-explore--local-path config)))))

(defun plans-explore--progress (counts)
  (if (and (hash-table-p counts) (natnump (gethash "done" counts))
           (natnump (gethash "total" counts)))
      (format "%d/%d" (gethash "done" counts) (gethash "total" counts))
    "—"))

(defconst plans-explore--list-columns
  '(("id" "ID") ("title" "Title") ("status" "Status")
    ("task_counts" "Progress" plans-explore--progress)))

(defconst plans-explore--check-columns
  '(("id" "ID") ("status" "Status") ("valid" "Valid") ("issues" "Issues")))

(defun plans-explore--record-p (value)
  ;; List and check may report malformed IDs verbatim from the record.
  (and (hash-table-p value) (stringp (gethash "id" value))))

(defun plans-explore--validation (context)
  (lambda (value code)
    (unless
        (pcase (plans-explore--context-operation context)
          ('list (and (vectorp value) (cl-every #'plans-explore--record-p value)))
          ('show (and (plans-explore--record-p value)
                      (equal (gethash "id" value) (plans-explore--context-id context))
                      (stringp (gethash "path" value)) (stringp (gethash "org" value))
                      (vectorp (gethash "tasks" value))))
          ('check
           (and (vectorp value)
                (cl-every (lambda (row)
                            (and (plans-explore--record-p row)
                                 (memq (gethash "valid" row) '(t :false))
                                 (vectorp (gethash "issues" row))
                                 (cl-every #'stringp (gethash "issues" row))))
                          value)
                (or (zerop code)
                    (cl-some (lambda (row) (eq (gethash "valid" row) :false)) value))))
          ('workspaces (and (hash-table-p value) (vectorp (gethash "workspaces" value))
                            (vectorp (gethash "orphans" value)))))
      (error "Unexpected plans %s output" (plans-explore--context-operation context)))))

(defun plans-explore--source (program directory global-argv operation id archived local)
  (unless (or (not (eq operation 'show)) (plans-explore--id-p id))
    (user-error "Invalid plan ID: %s" id))
  (let* ((id (and id (copy-sequence id)))
         (context (plans-explore--make-context :operation operation :id id :local local
                                              :global-argv global-argv)))
    (json-explore--make-source
     :program (copy-sequence program) :directory directory :context context
     :argv (append global-argv
                   (pcase operation
                     ('show (append '("show") (when archived '("--archived")) (list id)))
                     ('workspaces '("workspace" "list"))
                     (_ (cons (symbol-name operation) (when archived '("--all"))))))
     :success-codes (if (eq operation 'check) '(0 1) '(0))
     :validate (plans-explore--validation context)
     :columns (pcase operation ('list plans-explore--list-columns)
                ('check plans-explore--check-columns)))))

(defun plans-explore--start (operation id archived root project local config no-display)
  (let* ((directory (json-explore--local-directory default-directory))
         (global-argv (plans-explore--global-args root project local config))
         (source (plans-explore--source plans-explore-program directory global-argv
                                        operation id archived local))
         (label (if id (format "Plans %s %s" operation id) (format "Plans %s" operation)))
         (name (format "*%s [%x]*" label
                       (sxhash-equal (list plans-explore-program directory
                                          (json-explore--source-argv source)))))
         (unavailable (and local (eq operation 'workspaces)))
         (view (json-explore--make-view
                :label label :source (unless unavailable source)
                :diagnostic (when unavailable "Workspace inventory unavailable with --local.")))
         (buffer (json-explore--show-view view name no-display #'plans-explore-mode)))
    (unless unavailable (with-current-buffer buffer (json-explore-refresh)))
    buffer))

;;;###autoload
(cl-defun plans-explore-list (&key root project local config archived no-display)
  "Explore plans inventory; with ARCHIVED (interactive prefix), include archives."
  (interactive (append (list :archived current-prefix-arg) plans-explore-selection))
  (plans-explore--start 'list nil archived root project local config no-display))

;;;###autoload
(cl-defun plans-explore-show (id &key root project local config archived no-display)
  "Fetch plan ID and explore its details; ARCHIVED selects an archived record."
  (interactive (append (list (read-string "Plan ID: ") :archived current-prefix-arg)
                       plans-explore-selection))
  (plans-explore--start 'show id archived root project local config no-display))

;;;###autoload
(cl-defun plans-explore-check (&key root project local config archived no-display)
  "Explore validation results; with ARCHIVED (interactive prefix), include archives."
  (interactive (append (list :archived current-prefix-arg) plans-explore-selection))
  (plans-explore--start 'check nil archived root project local config no-display))

;;;###autoload
(cl-defun plans-explore-workspaces (&key root project local config no-display)
  "Explore workspace inventory, or report that it is unavailable with LOCAL."
  (interactive plans-explore-selection)
  (plans-explore--start 'workspaces nil nil root project local config no-display))

(defun plans-explore--context ()
  (when-let* ((source (json-explore--view-source json-explore--view)))
    (json-explore--source-context source)))

(defun plans-explore-open-plan ()
  "Fetch the inventory row's details and push a view in this buffer."
  (interactive)
  (let* ((view json-explore--view)
         (source (json-explore--view-source view))
         (context (plans-explore--context))
         (value (json-explore--view-value view)))
    (unless (and context (memq (plans-explore--context-operation context) '(list check))
                 (not (json-explore--view-path view)) (vectorp value))
      (user-error "Select a row in the plans list or check inventory"))
    (let* ((row (aref value (nth 1 (json-explore--selected-cell))))
           (id (gethash "id" row))
           (detail (plans-explore--source
                    (json-explore--source-program source) (json-explore--source-directory source)
                    (plans-explore--context-global-argv context) 'show id
                    (eq (gethash "archived" row) t) (plans-explore--context-local context))))
      (json-explore--push-view
       (json-explore--make-view :source detail :label (format "Plans show %s" id)))
      (json-explore-refresh))))

(defun plans-explore--record ()
  (when-let* ((context (plans-explore--context)))
    (when (eq (plans-explore--context-operation context) 'show)
      (json-explore--view-snapshot json-explore--view))))

(defun plans-explore--point-path ()
  (if-let* ((cell (json-explore--cell-at)))
      (json-explore--cell-path cell)
    (json-explore--view-path json-explore--view)))

(defun plans-explore--org-at-point-p ()
  (and (plans-explore--record) (equal (plans-explore--point-path) '("org"))))

(defun plans-explore--inspect-org (stay)
  (let ((org-inhibit-startup t))
    (json-explore--inspect-value (gethash "org" (plans-explore--record)) t stay #'org-mode)))

(defun plans-explore-open ()
  "Fetch a plan from its list index, inspect its Org text, or drill into JSON."
  (interactive)
  (cond ((plans-explore--org-at-point-p) (plans-explore--inspect-org nil))
        ((and (plans-explore--context)
              (eq (plans-explore--context-operation (plans-explore--context)) 'list)
              (not (json-explore--view-path json-explore--view))
              (eq (nth 2 (json-explore--cell-at)) 'index))
         (plans-explore-open-plan))
        (t (json-explore-open))))

(defun plans-explore-open-other-window ()
  "Open this cell in another window, using Org mode for plan text."
  (interactive)
  (if (plans-explore--org-at-point-p) (plans-explore--inspect-org nil)
    (json-explore-open-other-window)))

(defun plans-explore-display-other-window ()
  "Display this cell without selecting its window, using Org mode for plan text."
  (interactive)
  (if (plans-explore--org-at-point-p) (plans-explore--inspect-org t)
    (json-explore-display-other-window)))

(defun plans-explore-visit ()
  "Visit the fetched record's authoritative file, read-only in View mode.
On a task, use the line from this snapshot, which may no longer be current."
  (interactive)
  (let* ((record (or (plans-explore--record) (user-error "Fetch plan details first")))
         (path (gethash "path" record))
         (tasks (gethash "tasks" record))
         (where (plans-explore--point-path))
         (index (and (equal (car where) "tasks") (cadr where)))
         (task (and (natnump index) (< index (length tasks)) (aref tasks index)))
         (line (and (hash-table-p task) (gethash "line" task))))
    (unless (and (file-name-absolute-p path) (not (file-remote-p path)) (file-regular-p path))
      (user-error "No local plan file at %s" path))
    (let* ((enable-local-variables nil)
           (enable-local-eval nil)
           (org-inhibit-startup t)
           (buffer (find-file-noselect path)))
      (pop-to-buffer buffer)
      (view-mode 1)
      (when (and (integerp line) (> line 0))
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (message "Snapshot task line %d may be stale; refresh to check" line)))))

(define-derived-mode plans-explore-mode json-explore-mode "Plans Explore"
  "Browse plans CLI results.  RET on a plan's list index fetches details.
C-c C-o fetches the selected plan from list or check; C-c C-v (gf in
Evil) visits the fetched file or task in View mode.  RET on the Org
cell opens a read-only snapshot without visiting the file.")

(let ((map plans-explore-mode-map))
  (define-key map [remap json-explore-open] #'plans-explore-open)
  (define-key map [remap json-explore-open-other-window] #'plans-explore-open-other-window)
  (define-key map [remap json-explore-display-other-window] #'plans-explore-display-other-window)
  (define-key map (kbd "C-c C-o") #'plans-explore-open-plan)
  (define-key map (kbd "C-c C-v") #'plans-explore-visit))

(with-eval-after-load 'evil-collection
  (evil-collection-bind 'plans-explore-mode-map 'find-file #'plans-explore-visit))

(provide 'plans-explore)
;;; plans-explore.el ends here
