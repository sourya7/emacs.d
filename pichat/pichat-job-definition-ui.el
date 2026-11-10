;;; pichat-job-definition-ui.el --- Explicit authored job workflow -*- lexical-binding: t; -*-

;;; Commentary:
;; Discovery/preview are inert.  Import preparation and commit are separate,
;; reviewable actions on the owning store, never executor initialization.

;;; Code:
(require 'pichat-jobs)
(require 'pichat-job-import)

(defvar-local pichat-job-definition-ui--roots nil)
(defvar-local pichat-job-definition-ui--definitions nil)
(defvar-local pichat-job-definition-ui--diagnostics nil)
(defvar-local pichat-job-definition-ui--session nil
  "Staged authored import owned by this picker, or shown by its inspector.")

(defvar pichat-job-definition-ui-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "g") #'pichat-job-definition-ui-refresh)
    map))

(define-derived-mode pichat-job-definition-ui-mode pichat-view-mode "PiChat-Job-Files"
  "Read authored job files; importing and running are separate operations.")

(defvar pichat-job-definition-diagnostics-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-job-definition-ui-mode-map)
    (define-key map (kbd "g") #'pichat-job-definition-ui--render-diagnostics)
    map))

(define-derived-mode pichat-job-definition-diagnostics-mode
  pichat-job-definition-ui-mode "PiChat Job File Diagnostics"
  "Inspect a cached discovery snapshot; g redraws without reading files.")

(defvar pichat-job-definitions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'pichat-job-definition-preview)
    (define-key map (kbd "D") #'pichat-job-definition-diagnostics)
    (define-key map (kbd "g") #'pichat-job-definition-ui-refresh)
    (define-key map (kbd "q") #'pichat-view-quit)
    map))

(define-derived-mode pichat-job-definitions-mode tabulated-list-mode "PiChat Job Files"
  "Pick an authored job file; RET opens its read-only import menu.
Review resolves settings; Use current settings explicitly recaptures them.
Only Save writes the saved job.  Run and timing are separate actions."
  (setq tabulated-list-padding 1)
  (setq-local mode-line-format '("%e" mode-line-front-space "PiChat Job Files  "
                                mode-line-process mode-line-end-spaces))
  (setq-local revert-buffer-function
              (lambda (&rest _) (pichat-job-definition-ui-refresh))))

(defun pichat-job-definition-ui--buffer (title &optional mode)
  "Make a fresh owned view named TITLE, using MODE when supplied."
  (let ((buffer (generate-new-buffer title)))
    (with-current-buffer buffer (funcall (or mode #'pichat-job-definition-ui-mode)))
    buffer))

(defun pichat-job-definition-ui--source (record)
  "Insert full RECORD provenance from validated cached data."
  (insert (format "Scope: %s\nRoot: %s\nFile: %s\nAuthored ID: %s\n"
                  (plist-get record :scope) (plist-get record :root)
                  (plist-get record :file) (aref (plist-get record :identity) 2))))

(defun pichat-job-definition-ui--render-discovery ()
  "Render cached discovery as native rows at the narrowest visible width."
  (let* ((roots pichat-job-definition-ui--roots)
         (windows (get-buffer-window-list (current-buffer) nil t))
         (width (if windows (apply #'min (mapcar #'window-body-width windows))
                  (window-body-width)))
         (title-width (if (< width 110) (max 10 (min 20 (/ width 4))) 24))
         (files (length pichat-job-definition-ui--definitions))
         (diagnostics (length pichat-job-definition-ui--diagnostics)))
    (setq tabulated-list-format
          (vector (list "Job" title-width t) '("Scope" 8 t) '("File" 0 t))
          tabulated-list-entries
          (mapcar
           (lambda (record)
             (list (plist-get record :identity)
                   (vector
                    (pichat-jobs--display (plist-get (plist-get record :definition) :title))
                    (if (equal (plist-get record :scope) "project") "Project" "Global")
                    (pichat-jobs--display
                     (file-relative-name (plist-get record :file) (plist-get record :root))))))
           (append pichat-job-definition-ui--definitions nil))
          mode-line-process
          (replace-regexp-in-string
           "%" "%%"
           (format "%d file%s · %d diagnostic%s (%s) [Project: %s · Global: %s]"
                   files (if (= files 1) "" "s")
                   diagnostics (if (= diagnostics 1) "" "s")
                   (if (pichat-view-evil-normal-p) "g D" "D")
                   (if (cadr roots) (pichat-jobs--display (abbreviate-file-name (cadr roots))) "none")
                   (if (car roots) (pichat-jobs--display (abbreviate-file-name (car roots))) "omitted"))
           t t))
    (tabulated-list-init-header)
    (tabulated-list-print t)))

(defun pichat-job-definition-ui-refresh ()
  "Explicitly rediscover the exact roots captured by this discovery view."
  (interactive)
  (unless (and (derived-mode-p 'pichat-job-definitions-mode)
               pichat-job-definition-ui--roots)
    (user-error "Open discovery again to refresh files; reviews are snapshots"))
  (let* ((roots pichat-job-definition-ui--roots)
         (scan (pichat-job-definition-discover (car roots) (cadr roots))))
    (setq pichat-job-definition-ui--definitions (plist-get scan :definitions)
          pichat-job-definition-ui--diagnostics (plist-get scan :diagnostics))
    (pichat-job-definition-ui--render-discovery)))

(defun pichat-job-definition-ui--resize (frame)
  "Adapt visible file tables on FRAME using cached discovery only."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'pichat-job-definitions-mode)
                 pichat-job-definition-ui--roots)
        (pichat-job-definition-ui--render-discovery)))))
(add-hook 'window-size-change-functions #'pichat-job-definition-ui--resize)

(defun pichat-job-definition-ui--render-diagnostics ()
  "Redraw this inspector's cached file diagnostics without discovery."
  (interactive)
  (unless (derived-mode-p 'pichat-job-definition-diagnostics-mode)
    (user-error "Open Job Files diagnostics first"))
  (let ((inhibit-read-only t) (roots pichat-job-definition-ui--roots))
    (erase-buffer)
    (setq header-line-format (propertize "Job file diagnostics" 'face 'bold))
    (insert (format "Global agent root: %s\nSelected project: %s\n\n"
                    (or (car roots) "omitted") (or (cadr roots) "none")))
    (if (seq-empty-p pichat-job-definition-ui--diagnostics)
        (insert "No file diagnostics.\n")
      (seq-doseq (diagnostic pichat-job-definition-ui--diagnostics)
        (insert (pichat-jobs--display (plist-get diagnostic :file)) "\n"
                (plist-get diagnostic :message) "\n\n")))
    (goto-char (point-min))
    (set-buffer-modified-p nil)))

(defun pichat-job-definition-diagnostics ()
  "Inspect the current file table's cached diagnostics and full root context."
  (interactive)
  (unless (derived-mode-p 'pichat-job-definitions-mode)
    (user-error "Open M-x pichat-job-definitions first"))
  (let ((origin (pichat-view-capture-origin))
        (roots (copy-sequence pichat-job-definition-ui--roots))
        (diagnostics (pichat-job--copy pichat-job-definition-ui--diagnostics))
        (buffer (pichat-job-definition-ui--buffer
                 "*PiChat Job File Diagnostics*" #'pichat-job-definition-diagnostics-mode)))
    (with-current-buffer buffer
      (setq pichat-job-definition-ui--roots roots
            pichat-job-definition-ui--diagnostics diagnostics)
      (pichat-job-definition-ui--render-diagnostics))
    (pichat-view-display buffer origin 'kill)))

;;;###autoload
(defun pichat-job-definitions (&optional project-root)
  "Discover authored files in the effective agent root and PROJECT-ROOT.
Default to the current project; a prefix prompts for another root.  This never
opens the job store, resolves execution settings or initializes the executor."
  (interactive (list (if current-prefix-arg
                         (read-directory-name "Selected project root: ")
                       (pichat--project-root))))
  (let ((origin (pichat-view-capture-origin))
        (buffer (pichat-job-definition-ui--buffer "*PiChat Job Files*" #'pichat-job-definitions-mode)))
    (with-current-buffer buffer
      (setq pichat-job-definition-ui--roots
            (list (pichat-job-definition-agent-directory) project-root))
      (pichat-job-definition-ui-refresh))
    (pichat-view-display buffer origin 'kill)
    (with-current-buffer buffer (pichat-job-definition-ui--render-discovery))
    buffer))

(defun pichat-job-definition-ui--current-p (session)
  "Whether SESSION still owns its original picker and selected file."
  (let ((origin (plist-get session :origin)))
    (and session (not (plist-get session :closed)) (buffer-live-p origin)
         (with-current-buffer origin
           (and (eq session pichat-job-definition-ui--session)
                (or (not (derived-mode-p 'pichat-job-definitions-mode))
                    (equal (tabulated-list-get-id)
                           (plist-get (plist-get session :record) :identity))))))))

(defun pichat-job-definition-ui--current ()
  "Return the current staged import or reject a stale menu."
  (let ((session (or (transient-scope 'pichat-job-definition-menu)
                     pichat-job-definition-ui--session)))
    (unless (pichat-job-definition-ui--current-p session)
      (user-error "Import context changed; reopen the file row"))
    session))

(defun pichat-job-definition-ui--show (session)
  "Show SESSION in the same menu, without preparing or recapturing."
  (when (pichat-job-definition-ui--current-p session)
    (with-current-buffer (plist-get session :origin)
      (transient-setup 'pichat-job-definition-menu nil nil :scope session))))

(defun pichat-job-definition-ui--close (session)
  "Discard SESSION and its owned inspector without changing saved jobs."
  (when session
    (setf (plist-get session :closed) t (plist-get session :review) nil)
    (when-let* ((buffer (plist-get session :inspector))
                ((buffer-live-p buffer)))
      (with-current-buffer buffer
        (if (pichat-view-presentation) (pichat-view-return nil 'kill)
          (kill-buffer buffer))))))

(defun pichat-job-definition-ui--abandoned ()
  "Discard staged imports on explicit Transient quit, not inspection exit."
  (when (memq this-command '(transient-quit-one transient-quit-all transient-quit-seq))
    ;; Transient has cleared its prefix; focus may also have moved elsewhere.
    (dolist (buffer (buffer-list))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when-let* ((session pichat-job-definition-ui--session)
                      ((eq buffer (plist-get session :origin))))
            (pichat-job-definition-ui--close session)))))))
(add-hook 'transient-exit-hook #'pichat-job-definition-ui--abandoned)

(defun pichat-job-definition-preview (&optional record)
  "Open a read-only import menu for cached RECORD, without store access."
  (interactive)
  (setq record (or record
                   (and (derived-mode-p 'pichat-job-definitions-mode)
                        (let ((id (tabulated-list-get-id)))
                          (seq-find (lambda (candidate)
                                      (equal id (plist-get candidate :identity)))
                                    pichat-job-definition-ui--definitions)))))
  (unless record (user-error "Select a file row in M-x pichat-job-definitions"))
  (pichat-job-definition-ui--close pichat-job-definition-ui--session)
  (setq pichat-job-definition-ui--session
        (list :origin (current-buffer) :record (pichat-job--copy record)
              :review nil :closed nil :inspector nil))
  (pichat-job-definition-ui--show pichat-job-definition-ui--session))

(defun pichat-job-definition-ui--spec (session)
  "Return SESSION's proposed or unchanged saved spec, without resolving it."
  (when-let* ((review (plist-get session :review)))
    (or (pichat-job-import-review-spec review)
        (plist-get (pichat-job-import-review-previous review) :spec))))

(defun pichat-job-definition-ui--job-title (store id)
  "Return saved job ID's display title in STORE, or nil without ID."
  (when id
    (if-let* ((job (seq-find (lambda (job) (equal (plist-get job :id) id))
                             (and store (pichat-job-records store 'jobs)))))
        (pichat-jobs--display (plist-get (plist-get job :spec) :title))
      "Unavailable job")))

(defun pichat-job-definition-ui--fields (spec &optional store)
  "Project SPEC into readable fields for meaningful comparisons.
STORE names after-run jobs; without it the field shows the saved job ID."
  (let* ((config (plist-get spec :configuration))
         (preset (plist-get config :preset)) (tools (plist-get config :tools)))
    (list (cons "Title" (plist-get spec :title))
          (cons "Instructions" (plist-get spec :instructions))
          (cons "Directory" (plist-get spec :directory))
          (cons "Model" (plist-get config :model))
          (cons "Preset" (plist-get preset :name))
          (cons "Target" (plist-get (plist-get config :transport) :id))
          (cons "Runtime directory" (plist-get config :runtime-directory))
          (cons "Tools" (if tools (plist-get tools :builtins)
                         (if (eq (plist-get preset :inherited) t) "Pi defaults"
                           (plist-get preset :tools))))
          (cons "Extension tools" (if tools (plist-get tools :extensions)
                                   (plist-get preset :extensions)))
          (cons "Emacs-defined tools" (if tools (plist-get tools :emacs)
                                       (plist-get preset :emacs-tools)))
          (cons "System prompt" (plist-get preset :system-prompt))
          (cons "Appended prompt" (plist-get preset :append-system-prompt))
          (cons "Run input" (plist-get spec :input))
          (cons "After this run" (if store
                                     (pichat-job-definition-ui--job-title
                                      store (plist-get spec :after-job-id))
                                   (plist-get spec :after-job-id))))))

(defun pichat-job-definition-ui--links (session)
  "Return SESSION's cached run input and after-run lines, then warnings."
  (let* ((review (plist-get session :review))
         (data (plist-get (plist-get session :record) :definition))
         (link (plist-get data :after-job))
         (target (and review (pichat-job-import-review-after-job review))))
    (append
     (when-let* ((prompt (plist-get data :input)))
       (list (concat "Run input: asked when run (" prompt ")")))
     (when link
       (list (concat "After this run: "
                     (if target (pichat-jobs--display (plist-get (plist-get target :spec) :title))
                       (concat "ID " (plist-get link :id)))
                     " (" (plist-get link :scope) " job"
                     (unless target ", resolved at Review") ")")))
     (when review
       (mapcar (lambda (warning) (propertize warning 'face 'warning))
               (pichat-job-import-review-warnings review))))))

(defun pichat-job-definition-ui--changes (session)
  "Return SESSION's changed readable fields and technical capture labels."
  (let* ((review (plist-get session :review))
         (previous (and review (plist-get (pichat-job-import-review-previous review) :spec)))
         (spec (pichat-job-definition-ui--spec session))
         (old-config (plist-get previous :configuration))
         (config (plist-get spec :configuration)))
    (when previous
      (append
       (cl-loop for (label . value) in (pichat-job-definition-ui--fields spec)
                unless (equal value (cdr (assoc label (pichat-job-definition-ui--fields previous))))
                collect label)
       (cl-loop for (label . key) in '(("Launch arguments" . :command)
                                      ("Target settings" . :transport)
                                      ("Path mappings" . :mappings) ("Path policy" . :strict)
                                      ("Tool settings" . :tools))
                unless (equal (plist-get config key) (plist-get old-config key))
                collect label)))))

(defun pichat-job-definition-ui--bounded (text)
  "Bound TEXT to one display-safe menu line."
  (truncate-string-to-width (pichat-jobs--display text)
                            (max 20 (- (frame-width) 10)) nil nil "…"))

(defun pichat-job-definition-ui--summary (&optional session)
  "Describe SESSION or the current menu using cached values only."
  (let* ((session (or session (transient-scope))) (record (plist-get session :record))
         (data (plist-get record :definition)) (review (plist-get session :review))
         (status (when review
                   (concat " — " (pcase (pichat-job-import-review-action review)
                                    ("unchanged" "Already up to date")
                                    ("refresh" "Update")
                                    (action (capitalize action))))))
         (title (concat (truncate-string-to-width
                         (pichat-jobs--display (plist-get data :title))
                         (max 1 (- (frame-width) 10 (length status))) nil nil "…")
                        status)))
    (mapconcat
     #'pichat-job-definition-ui--bounded
     (append
      (list (propertize title 'face 'transient-heading))
      (unless review (list "" (plist-get data :instructions)))
      (pichat-job-definition-ui--links session)
      (when-let* ((changes (pichat-job-definition-ui--changes session)))
        (list (concat "Changes    " (string-join changes ", "))))
      (when (and review (pichat-job-import-review-diverged review))
        (list (propertize "Native edits will be replaced; confirmation required" 'face 'warning))))
     "\n")))

(defun pichat-job-definition-ui--field (field &optional session)
  "Describe cached read-only FIELD from SESSION in a native Transient column."
  (let* ((session (or session (transient-scope)))
         (record (plist-get session :record)) (data (plist-get record :definition))
         (spec (pichat-job-definition-ui--spec session))
         (config (plist-get spec :configuration))
         (value (pcase field
                  (:directory (abbreviate-file-name (or (plist-get spec :directory)
                                                       (plist-get record :directory))))
                  (:model (or (plist-get config :model) (plist-get data :model)))
                  (:preset (or (plist-get (plist-get config :preset) :name)
                               (plist-get data :preset)))
                  (:target (or (plist-get (plist-get config :transport) :id)
                               (plist-get (plist-get data :target) :name) "local"))))
         (label (concat (capitalize (substring (symbol-name field) 1)) ": "))
         (width (max 20 (/ (- (frame-width) 8) 2))))
    (concat label
            (propertize (truncate-string-to-width (pichat-jobs--display value)
                                                  (- width (length label)) nil nil "…")
                        'face 'transient-value))))

(defun pichat-job-definition-ui--reviewed-p ()
  "Whether the current menu has an explicit prepared review."
  (plist-get (transient-scope) :review))

(defun pichat-job-definition-import (&optional refresh)
  "Prepare this file for review; REFRESH explicitly recaptures settings."
  (interactive "P")
  (let ((session (pichat-job-definition-ui--current)))
    (condition-case err
        (let ((review (pichat-job-import-prepare
                       (pichat-jobs--owning-store) (plist-get session :record) refresh)))
          (unless (pichat-job-definition-ui--current-p session)
            (user-error "Import context changed; reopen the file row"))
          (setf (plist-get session :review) review)
          (pichat-job-definition-ui--show session))
      ((error quit)
       (pichat-job-definition-ui--show session)
       (signal (car err) (cdr err))))))

(defun pichat-job-definition-refresh-capture ()
  "Explicitly prepare a fresh settings capture for review."
  (interactive)
  (pichat-job-definition-import t))

(defun pichat-job-definition-ui-cancel ()
  "Discard this staged import and retain the selected file row."
  (interactive)
  (pichat-job-definition-ui--close (pichat-job-definition-ui--current)))

(defun pichat-job-definition-open-source ()
  "Close the import menu and open its authored JSON in the normal editor."
  (interactive)
  (let* ((session (pichat-job-definition-ui--current))
         (file (plist-get (plist-get session :record) :file)))
    (pichat-job-definition-ui--close session)
    (find-file file)))

(defun pichat-job-definition-ui-save ()
  "Commit the exact staged review; native replacement requires confirmation."
  (interactive)
  (let* ((session (pichat-job-definition-ui--current))
         (review (plist-get session :review)) (origin (plist-get session :origin)))
    (condition-case err
        (progn
          (unless review (user-error "Review the job first"))
          (unless (eq (pichat-job-import-review-store review) (pichat-jobs--owning-store))
            (user-error "Owning store changed; discover and review again"))
          (let ((replace (pichat-job-import-review-diverged review)))
            (when (and replace
                       (not (yes-or-no-p "Replace reviewed native instructions/settings with this import? ")))
              (user-error "Import cancelled; nothing saved"))
            (unless (and (pichat-job-definition-ui--current-p session)
                         (eq (current-buffer) origin) (eq review (plist-get session :review))
                         (eq (pichat-job-import-review-store review) (pichat-jobs--owning-store)))
              (user-error "Import context changed; discover and review again"))
            (pichat-job-import-commit review replace)
            (pichat-job-definition-ui--close session)
            (when pichat-jobs--executor (pichat-jobs--changed pichat-jobs--executor))
            (message (if (equal (pichat-job-import-review-action review) "unchanged")
                         "Already up to date" "Imported job"))))
      ((error quit)
       (pichat-job-definition-ui--show session)
       (signal (car err) (cdr err))))))

(transient-define-prefix pichat-job-definition-menu ()
  "Review an authored job; imported fields are read-only until edited in JSON."
  [(:info (lambda () (pichat-job-definition-ui--summary)))]
  [["Job"
    (:info (lambda () (pichat-job-definition-ui--field :directory)))]
   ["Execution"
    (:info (lambda () (pichat-job-definition-ui--field :model)))
    (:info (lambda () (pichat-job-definition-ui--field :preset)))
    (:info (lambda () (pichat-job-definition-ui--field :target)))]]
  [["File"
    ("d" "Inspect" pichat-job-definition-inspect)
    ("o" "Open file" pichat-job-definition-open-source
     :if-not pichat-job-definition-ui--reviewed-p)]
   ["Settings" :if pichat-job-definition-ui--reviewed-p
    ("r" "Use current settings" pichat-job-definition-refresh-capture)]]
  [[""
    ("i" "Review" pichat-job-definition-import :if-not pichat-job-definition-ui--reviewed-p)
    ("RET" "Save" pichat-job-definition-ui-save :if pichat-job-definition-ui--reviewed-p)
    ("q" pichat-job-definition-ui-cancel
     :description (lambda () (if (pichat-job-definition-ui--reviewed-p) "Cancel" "Close")))]]
  [:hide (lambda () t)
   ("<return>" pichat-job-definition-ui-save :if pichat-job-definition-ui--reviewed-p)])

(defvar pichat-job-definition-inspector-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-job-definition-ui-mode-map)
    (define-key map (kbd "q") #'pichat-job-definition-inspector-quit)
    (define-key map (kbd "g") #'pichat-job-definition-ui--render-inspector)
    (define-key map (kbd "TAB") #'pichat-jobs-detail-tab)
    (define-key map (kbd "<tab>") #'pichat-jobs-detail-tab)
    map))

(define-derived-mode pichat-job-definition-inspector-mode
  pichat-job-definition-ui-mode "PiChat Job Import"
  "Inspect a cached authored import; q returns to the unchanged staged menu.
Technical details disclose the exact cached capture.
This view never recaptures."
  (setq-local truncate-lines nil truncate-partial-width-windows nil)
  (visual-line-mode 1))

(defun pichat-job-definition-ui--value (value)
  "Format a readable cached field VALUE without Lisp syntax."
  (cond ((or (null value) (and (sequencep value) (seq-empty-p value))) "None")
        ((stringp value) value)
        ((vectorp value) (string-join (append value nil) ", "))
        (t (format "%s" value))))

(defun pichat-job-definition-ui--inspector-settings (data spec)
  "Insert cached DATA or resolved SPEC settings using the Jobs presentation."
  (if spec
      (pichat-jobs--insert-settings spec)
    (insert "Model: " (plist-get data :model) "\nPreset: " (plist-get data :preset) "\n"))
  (when spec
    (let* ((config (plist-get spec :configuration)) (preset (plist-get config :preset))
           (runtime (plist-get config :runtime-directory))
           (extensions (cdr (assoc "Extension tools" (pichat-job-definition-ui--fields spec))))
           (prompts (seq-filter (lambda (field) (not (seq-empty-p (cdr field))))
                               (list (cons "System prompt" (plist-get preset :system-prompt))
                                     (cons "Appended prompt" (plist-get preset :append-system-prompt))))))
      (when (and runtime (not (equal runtime (plist-get spec :directory))))
        (insert "Runtime directory: " runtime "\n"))
      (unless (seq-empty-p extensions)
        (insert "Extension tools: " (pichat-job-definition-ui--value extensions) "\n"))
      (when prompts
        (pichat-jobs--disclosure 'prompts "Prompts" #'pichat-job-definition-ui--render-inspector)
        (when (memq 'prompts pichat-jobs--expanded)
          (insert "\n")
          (dolist (field prompts) (insert (car field) ": " (cdr field) "\n")))))))

(defun pichat-job-definition-ui--render-inspector ()
  "Render cached import data with shared Jobs styling and disclosures."
  (interactive)
  (let* ((session pichat-job-definition-ui--session) (record (plist-get session :record))
         (data (plist-get record :definition)) (review (plist-get session :review))
         (spec (pichat-job-definition-ui--spec session))
         (old (and review (plist-get (pichat-job-import-review-previous review) :spec)))
         (changes (and old (pichat-job-definition-ui--changes session)))
         (position (pichat-jobs--reading-position (point)))
         (windows (mapcar (lambda (window)
                            (list window (pichat-jobs--reading-position (window-start window))
                                  (pichat-jobs--reading-position (window-point window))))
                          (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format
          (propertize (replace-regexp-in-string "%" "%%"
                       (pichat-jobs--display (or (plist-get spec :title) (plist-get data :title))) t t)
                      'face 'bold))
    (pichat-jobs--insert-instructions
     (or (plist-get spec :instructions) (plist-get data :instructions))
     'task #'pichat-job-definition-ui--render-inspector)
    (when review
      (insert (pcase (pichat-job-import-review-action review)
                ("unchanged" "Already up to date") ("refresh" "Update")
                (action (capitalize action))) "\n")
      (when (pichat-job-import-review-diverged review)
        (insert (propertize "Native edits will be replaced; confirmation required\n" 'face 'warning))))
    (insert "File: " (plist-get record :file) "\nWorkspace: "
            (abbreviate-file-name (or (plist-get spec :directory) (plist-get record :directory)))
            " · " (or (plist-get (plist-get (plist-get spec :configuration) :transport) :id)
                       (plist-get (plist-get data :target) :name) "local") "\n\n")
    (pichat-jobs--disclosure 'definition "Details" #'pichat-job-definition-ui--render-inspector)
    (when (memq 'definition pichat-jobs--expanded)
      (insert "\n")
      (pichat-job-definition-ui--inspector-settings data spec)
      (dolist (line (pichat-job-definition-ui--links session))
        (insert line "\n")))
    (when changes
      (insert "\n")
      (pichat-jobs--disclosure 'changes "Changes" #'pichat-job-definition-ui--render-inspector)
      (when (memq 'changes pichat-jobs--expanded)
        (insert "\n")
        (dolist (label changes)
          (let* ((store (pichat-job-import-review-store review))
                 (before (assoc label (pichat-job-definition-ui--fields old store)))
                 (after (assoc label (pichat-job-definition-ui--fields spec store))))
            (insert label "\n")
            (when after
              (insert "Before: " (pichat-job-definition-ui--value (cdr before)) "\n"
                      "After: " (pichat-job-definition-ui--value (cdr after)) "\n"))))))
    (insert "\n")
    (pichat-jobs--disclosure 'technical "Technical details" #'pichat-job-definition-ui--render-inspector)
    (when (memq 'technical pichat-jobs--expanded)
      (insert "\n")
      (pichat-job-definition-ui--source record)
      (insert "\nAuthored data\n" (pp-to-string data))
      (when review
        (insert "\nPrevious capture\n" (pp-to-string old)
                "\nProposed capture\n" (pp-to-string spec))))
    (goto-char (pichat-jobs--restore-position position))
    (dolist (saved windows)
      (when (window-live-p (car saved))
        (set-window-start (car saved) (pichat-jobs--restore-position (cadr saved)) t)
        (set-window-point (car saved) (pichat-jobs--restore-position (caddr saved)))))
    (set-buffer-modified-p nil)))

(defun pichat-job-definition-inspect ()
  "Inspect cached instructions, provenance and capture without preparation."
  (interactive)
  (let* ((session (pichat-job-definition-ui--current))
         (buffer (plist-get session :inspector))
         (origin (list :buffer (plist-get session :origin)
                       :window (selected-window))))
    (unless (buffer-live-p buffer)
      (setq buffer (pichat-job-definition-ui--buffer
                    "*PiChat Job Import*" #'pichat-job-definition-inspector-mode))
      (setf (plist-get session :inspector) buffer))
    (with-current-buffer buffer
      (setq pichat-job-definition-ui--session session)
      (pichat-job-definition-ui--render-inspector))
    (pichat-view-display buffer origin 'bury)))

(defun pichat-job-definition-inspector-quit ()
  "Return from optional inspection to the same menu without re-preparing."
  (interactive)
  (let ((session pichat-job-definition-ui--session))
    (pichat-view-return (plist-get session :origin))
    (pichat-job-definition-ui--show session)))

(provide 'pichat-job-definition-ui)
;;; pichat-job-definition-ui.el ends here
