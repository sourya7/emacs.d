;;; plans-explore.el --- Read-only plans CLI adapter -*- lexical-binding: t; -*-

;;; Code:

;; Loaded after json-explore by the configuration's module loader.
(require 'org)
(require 'cl-lib)
(require 'subr-x)

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

(defun plans-explore--state-label (value)
  (if (not (stringp value)) (format "%s" value)
    (let ((face (pcase value
                  ("DONE" 'shadow) ("TODO" 'bold) ("IN-PROGRESS" 'highlight)
                  ("BLOCKED" 'warning))))
      (if face (propertize value 'face face) value))))

(defun plans-explore--display-text (value)
  (if (stringp value) (replace-regexp-in-string "[[:cntrl:]]" " " value)
    (json-serialize value :null-object :null :false-object :false)))

(defun plans-explore--progress-line (value)
  (let* ((counts (gethash "task_counts" value))
         (progress (plans-explore--progress counts))
         (total (and (hash-table-p counts) (gethash "total" counts)))
         (done (and (hash-table-p counts) (gethash "done" counts)))
         (bar (when (and (natnump done) (natnump total) (> total 0))
                (let ((filled (min 10 (/ (* done 10) total))))
                  (concat "  " (make-string filled ?█) (make-string (- 10 filled) ?░)))))
         (status (gethash "status" value))
         (updated (gethash "updated" value)))
    (string-join (delq nil (list (and (stringp status)
                                     (format "[%s]" (plans-explore--display-text status)))
                                (unless (equal progress "—") (concat progress " done" bar))
                                (and (stringp updated)
                                     (concat "updated " (plans-explore--display-text updated)))))
                 "   ")))

(defun plans-explore--show-page (value)
  (let ((tasks (gethash "tasks" value))
        (progress (plans-explore--progress-line value)))
    (vui-vstack
     (vui-text (plans-explore--display-text (or (gethash "title" value) (gethash "id" value)))
               :face 'bold)
     (unless (string-empty-p progress) (vui-text progress))
     (json-explore-fields :fields '(("next_action" "Next" plans-explore--display-text)
                                    ("path" "File" plans-explore--display-text)))
     (json-explore-section :path '("tasks") :title (format "Tasks (%d)" (length tasks))
                           :expanded t
                           :body (json-explore-table :path '("tasks")
                                  :columns '(("state" "State" plans-explore--state-label)
                                             ("title" "Title" plans-explore--display-text)
                                             ("line" "Line"))))
     (json-explore-section :path '("task_counts") :title "Details"
                           :body (vui-vstack
                                  (apply #'vui-vstack
                                         (cl-loop for key in '("id" "created" "archived")
                                                  for item = (gethash key value)
                                                  when item collect
                                                  (vui-text (format "%s  %s" key (plans-explore--display-text item)))))
                                  (json-explore-fields :path '("task_counts")))))))

(defun plans-explore--workspaces-page ()
  (vui-vstack
   (json-explore-fields :fields '(("project" "Project" plans-explore--display-text)
                                  ("version" "Version")))
   (json-explore-section :path '("workspaces") :title "Workspaces" :expanded t
                         :body (json-explore-table :path '("workspaces") :heading "plan_id"))
   (json-explore-section :path '("orphans") :title "Orphans" :expanded t
                         :body (json-explore-table :path '("orphans")))))

(defun plans-explore--page (value view-context)
  ;; Drilled entries retain the source and use the usual typed JSON renderer.
  (unless (plist-get view-context :path)
    (pcase (plans-explore--context-operation (plist-get view-context :context))
      ('list (json-explore-table :heading "id"))
      ('show (plans-explore--show-page value))
      ('workspaces (plans-explore--workspaces-page)))))

(defun plans-explore--source (program directory global-argv operation id archived local)
  (unless (or (not (eq operation 'show)) (plans-explore--id-p id))
    (user-error "Invalid plan ID: %s" id))
  (let* ((id (and id (copy-sequence id)))
         (context (plans-explore--make-context :operation operation :id id :local local
                                              :global-argv global-argv)))
    (json-explore-make-source
     :program program :directory directory :context context
     :label (if id (format "Plans %s %s" operation id) (format "Plans %s" operation))
     :view (when (memq operation '(list show workspaces)) #'plans-explore--page)
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
  (let ((global-argv (plans-explore--global-args root project local config)))
    (if (and local (eq operation 'workspaces))
        (json-explore-show-message "Plans workspaces" "Workspace inventory unavailable with --local."
                                   :mode #'plans-explore-mode :no-display no-display)
      (json-explore-open-source
       (plans-explore--source plans-explore-program default-directory global-argv
                              operation id archived local)
       :mode #'plans-explore-mode :no-display no-display))))

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

(defun plans-explore--operation (context)
  (when (plans-explore--context-p context) (plans-explore--context-operation context)))

(defun plans-explore--fetch-row (thing)
  (let* ((source (plist-get thing :source))
         (context (plist-get thing :context))
         (row (plist-get thing :row-value)))
    (unless (and (memq (plans-explore--operation context) '(list check))
                 (not (json-explore-current-path)) (hash-table-p row))
      (user-error "Select a row in the plans list or check inventory"))
    (json-explore-push-source
     (plans-explore--source
      (json-explore-source-program source) (json-explore-source-directory source)
      (plans-explore--context-global-argv context) 'show (gethash "id" row)
      (eq (gethash "archived" row) t) (plans-explore--context-local context)))))

(defun plans-explore-open-plan ()
  "Fetch the inventory row's details and push a view in this buffer."
  (interactive)
  (plans-explore--fetch-row (json-explore-thing-at-point)))

(defun plans-explore--record ()
  (when (eq (plans-explore--operation (json-explore-current-context)) 'show)
    (json-explore-current-snapshot)))

(defun plans-explore--open-handler (thing action)
  (when (and (eq action 'drill)
             (eq (plans-explore--operation (plist-get thing :context)) 'list)
             (not (json-explore-current-path)) (eq (plist-get thing :column) 'index))
    (plans-explore--fetch-row thing)
    t))

(defun plans-explore--visit-handler (thing)
  (when-let* ((record (plans-explore--record)))
    (let* ((file (gethash "path" record))
           (tasks (gethash "tasks" record))
           (where (if thing (plist-get thing :path) (json-explore-current-path)))
           (index (and (equal (car where) "tasks") (cadr where)))
           (task (and (natnump index) (< index (length tasks)) (aref tasks index))))
      (unless (and (stringp file) (file-name-absolute-p file)
                   (not (file-remote-p file)) (file-regular-p file))
        (user-error "No local plan file at %s" file))
      (let* ((org-inhibit-startup t)
             (enable-local-variables nil)
             (enable-local-eval nil)
             (buffer (find-file-noselect file)))
        (unless task
          (with-current-buffer buffer
            (widen)
            (goto-char (point-min))))
        (list :buffer buffer
              :line (and (hash-table-p task) (gethash "line" task)))))))

(define-derived-mode plans-explore-mode json-explore-mode "Plans Explore"
  "Browse plans CLI results.  RET on a plan's list index fetches details.
C-c C-o fetches the selected plan from list or check; C-c C-v (gf in
Evil) visits the authoritative Org file in View mode, at the top or
at the snapshot line when on a task."
  (add-hook 'json-explore-open-functions #'plans-explore--open-handler nil t)
  (add-hook 'json-explore-visit-functions #'plans-explore--visit-handler nil t))

(define-key plans-explore-mode-map (kbd "C-c C-o") #'plans-explore-open-plan)

;; Keep existing M-x entry points without remapping the explorer's actions.
(defalias 'plans-explore-open #'json-explore-open)
(defalias 'plans-explore-open-other-window #'json-explore-open-other-window)
(defalias 'plans-explore-display-other-window #'json-explore-display-other-window)
(defalias 'plans-explore-visit #'json-explore-visit)

(provide 'plans-explore)
;;; plans-explore.el ends here
