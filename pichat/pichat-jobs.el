;;; pichat-jobs.el --- Manual job setup and inspection -*- lexical-binding: t; -*-

;;; Commentary:
;; Saved definitions and one-off attempts share the same executor.  This initial
;; UI implements manual work only: no schedule or plan adapter controls are shown.
;; Saving, running, inspecting and manual uncertainty resolution are distinct.

;;; Code:
(require 'pichat-job-executor)
(require 'pichat-view)
(require 'tabulated-list)
(require 'button)
(require 'pp)

(defcustom pichat-jobs-file (locate-user-emacs-file "pichat/jobs.json")
  "Local, private metadata file for saved jobs and captured run settings.
May contain instructions, resolved prompts and process arguments.  Do not put
credentials in job instructions/arguments.  Environment and installed extensions
are not frozen.  Use only one owning Emacs per file."
  :type 'file :group 'pichat-jobs)
(defvar pichat-jobs--executor nil)
(defvar-local pichat-jobs--kind 'jobs)
(defvar-local pichat-jobs--filter nil)
(defvar-local pichat-jobs--owner nil)
(defvar-local pichat-jobs--detail nil)
(defvar-local pichat-jobs--section nil)
(defvar-local pichat-jobs--selection nil)
(defvar-local pichat-jobs--attention-only nil)
(defvar-local pichat-job--draft nil)

(defun pichat-jobs--engine ()
  "Return the owning executor, initializing/reconciling once on explicit entry."
  (unless pichat-jobs--executor
    (setq pichat-jobs--executor
          (pichat-job-executor-open (pichat-job-store-open pichat-jobs-file))))
  (unless (equal (expand-file-name pichat-jobs-file)
                 (pichat-job-store-file (pichat-job-executor-store pichat-jobs--executor)))
    (user-error "Jobs already owns another metadata file; restart before changing it"))
  pichat-jobs--executor)

(defun pichat-jobs--store ()
  "Return current buffer's owning store without initialization or execution."
  (pichat-job-executor-store (or pichat-jobs--owner
                               (user-error "No owning job store"))))

(defun pichat-jobs--button (label function)
  "Insert explicit action LABEL invoking FUNCTION."
  (insert-text-button label 'follow-link t
                      'action (lambda (_button) (funcall function)))
  (insert "   "))

(defun pichat-jobs--display (text)
  "Return single-line bounded display TEXT, without interpreting properties."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\r\t]+" " " (or text "—")) 80 nil nil "…"))

(defun pichat-jobs--state (owner run)
  "Return plain-language state for RUN owned by OWNER."
  (let* ((execution (gethash (plist-get run :id) (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution)))
         (state (plist-get run :state)))
    (cond ((equal state "queued") "Waiting")
          ((equal state "uncertain") "Execution uncertain")
          ((equal state "finished") "Finished")
          ((and execution (pichat-job-execution-cancelling execution)) "Cancelling")
          ((equal state "starting") "Starting")
          ((equal state "settling") "Finishing")
          ((and session (> (pichat-chat-pending-user-input-count session) 0)) "Needs input")
          (t "Running"))))

(defun pichat-jobs--result (run)
  "Return RUN's human-readable result, separate from its execution state."
  (pcase (plist-get run :result)
    ("completed" "Completed") ("needs-review" "Needs review")
    ("failed" "Failed") ("cancelled" "Cancelled") (_ "—")))

(defun pichat-jobs--latest (store job-id &optional runs)
  "Return the latest cached attempt for JOB-ID in STORE, or nil.
Use already detached RUNS during list rendering to avoid copying history for
every definition row."
  (car (last (seq-filter (lambda (run) (equal job-id (plist-get run :job-id)))
                         (append (or runs (pichat-job-records store 'runs)) nil)))))

(defun pichat-jobs--attention-p (owner run)
  "Whether cached RUN in OWNER needs human attention."
  (or (equal (plist-get run :state) "uncertain")
      (member (plist-get run :result) '("failed" "needs-review"))
      (equal (pichat-jobs--state owner run) "Needs input")))

(defun pichat-jobs--context (spec)
  "Return a compact workspace/target label from captured SPEC."
  (format "%s · %s"
          (plist-get (plist-get (plist-get spec :configuration) :transport) :label)
          (file-name-nondirectory (directory-file-name (plist-get spec :directory)))))

(defun pichat-jobs--select (id)
  "Restore exact row ID when present; never match visible titles."
  (when id
    (goto-char (point-min))
    (while (and (not (eobp)) (not (equal id (tabulated-list-get-id))))
      (forward-line 1))
    (when (eobp) (goto-char (point-min)))))

(defun pichat-jobs-refresh ()
  "Redraw Jobs/Runs using cached records; never dispatch or contact Pi."
  (interactive)
  (let* ((store (pichat-jobs--store))
         (runs (pichat-job-records store 'runs))
         (windows (get-buffer-window-list (current-buffer) nil t))
         (width (if windows (apply #'min (mapcar #'window-body-width windows))
                  (window-body-width)))
         (narrow (< width 110))
         (title-width (if narrow (max 10 (min 20 (/ width 4))) 24))
         (active (seq-count (lambda (run) (member (plist-get run :state)
                                                 pichat-job--active-states)) runs))
         (attention (seq-count (lambda (run) (pichat-jobs--attention-p pichat-jobs--owner run)) runs)))
    (setq tabulated-list-format
          (if (eq pichat-jobs--kind 'jobs)
              (vector (list "Job" title-width t) '("Schedule" 8 nil)
                      '("Latest run" 20 nil) '("Project / target" 0 t))
            (if narrow
                (vector (list "Work" title-width t) '("State / result" 20 nil)
                        '("Project / target" 0 t))
              [("Work" 24 t) ("Queued UTC" 20 t) ("State" 20 nil)
               ("Result" 14 nil) ("Trigger" 8 nil) ("Project / target" 0 t)])))
    ;; A sort column can disappear when changing tabs or narrowing the view.
    (unless (assoc (car tabulated-list-sort-key) (append tabulated-list-format nil))
      (setq tabulated-list-sort-key nil))
    (setq tabulated-list-entries
          (if (eq pichat-jobs--kind 'jobs)
              (mapcar
               (lambda (job)
                 (let* ((id (plist-get job :id)) (spec (plist-get job :spec))
                        (latest (pichat-jobs--latest store id runs)))
                   (list id (vector (pichat-jobs--display (plist-get spec :title)) "Off"
                                    (if latest (pichat-jobs--status pichat-jobs--owner latest) "Never run")
                                    (pichat-jobs--display (pichat-jobs--context spec))))))
               (append (pichat-job-records store 'jobs) nil))
            (cl-loop for run in (reverse (append runs nil))
                     when (and (or (null pichat-jobs--filter)
                                   (equal pichat-jobs--filter (plist-get run :job-id)))
                               (or (not pichat-jobs--attention-only)
                                   (pichat-jobs--attention-p pichat-jobs--owner run)))
                     collect
                     (list (plist-get run :id)
                           (vconcat
                            (list (concat (pichat-jobs--display (plist-get (plist-get run :spec) :title))
                                          (unless (plist-get run :job-id) " [unsaved]")))
                            (if narrow (list (pichat-jobs--status pichat-jobs--owner run))
                              (list (substring (plist-get run :created-at) 0 19)
                                    (pichat-jobs--state pichat-jobs--owner run)
                                    (pichat-jobs--result run) "Manual"))
                            (list (pichat-jobs--display (pichat-jobs--context (plist-get run :spec)))))))))
    (tabulated-list-init-header)
    (setq mode-line-process
          (format "%d/%d active · %d attention (a) [%s%s]"
                  active pichat-jobs-max-concurrency attention
                  (if (eq pichat-jobs--kind 'jobs) "Jobs" "Runs")
                  (cond (pichat-jobs--attention-only ": Needs attention")
                        (pichat-jobs--filter
                         (format ": %s (%s)"
                                 (plist-get (plist-get (pichat-job-record store 'jobs pichat-jobs--filter) :spec) :title)
                                 pichat-jobs--filter))
                        (t ""))))
    (tabulated-list-print t)))

(defun pichat-jobs--status (owner run)
  "Return the relevant cached execution/result summary of RUN in OWNER."
  (if (equal (plist-get run :state) "finished") (pichat-jobs--result run)
    (pichat-jobs--state owner run)))

(defun pichat-jobs-toggle ()
  "Switch Jobs/Runs, restoring the selected job when returning from history."
  (interactive)
  (when (eq pichat-jobs--kind 'jobs)
    (setq pichat-jobs--selection (tabulated-list-get-id)))
  (setq pichat-jobs--kind (if (eq pichat-jobs--kind 'jobs) 'runs 'jobs)
        pichat-jobs--filter nil pichat-jobs--attention-only nil)
  (pichat-jobs-refresh)
  (when (eq pichat-jobs--kind 'jobs) (pichat-jobs--select pichat-jobs--selection)))

(defun pichat-jobs-attention ()
  "Show attempts needing input or review, without contacting Pi."
  (interactive)
  (when (eq pichat-jobs--kind 'jobs)
    (setq pichat-jobs--selection (tabulated-list-get-id)))
  (setq pichat-jobs--kind 'runs pichat-jobs--filter nil pichat-jobs--attention-only t)
  (pichat-jobs-refresh))

(defun pichat-jobs-history ()
  "Show attempts for the selected saved job."
  (interactive)
  (unless (eq pichat-jobs--kind 'jobs) (user-error "Select a job in Jobs first"))
  (setq pichat-jobs--selection (or (tabulated-list-get-id) (user-error "No job selected"))
        pichat-jobs--filter pichat-jobs--selection
        pichat-jobs--attention-only nil pichat-jobs--kind 'runs)
  (pichat-jobs-refresh))

(defun pichat-jobs--resize (frame)
  "Adapt visible lists to FRAME's new window widths, from cached state only."
  (dolist (window (window-list frame 'no-minibuffer))
    (with-current-buffer (window-buffer window)
      (when (derived-mode-p 'pichat-jobs-mode) (pichat-jobs-refresh)))))
(add-hook 'window-size-change-functions #'pichat-jobs--resize)

(defun pichat-jobs--changed (owner)
  "Refresh existing cached views belonging to OWNER, without selecting them."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (eq pichat-jobs--owner owner)
        (cond ((derived-mode-p 'pichat-jobs-mode) (pichat-jobs-refresh))
              ((and pichat-jobs--detail (derived-mode-p 'pichat-view-mode))
               (pichat-jobs--render-detail)))))))
(add-hook 'pichat-job-executor-changed-hook #'pichat-jobs--changed)

(defvar pichat-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "TAB") #'pichat-jobs-toggle)
    (define-key map (kbd "C-o") #'pichat-jobs-preview)
    (define-key map (kbd "+") #'pichat-job-new)
    (define-key map (kbd "RET") #'pichat-jobs-details)
    (define-key map (kbd "r") #'pichat-jobs-run)
    (define-key map (kbd "e") #'pichat-jobs-edit)
    (define-key map (kbd "h") #'pichat-jobs-history)
    (define-key map (kbd "a") #'pichat-jobs-attention)
    (define-key map (kbd "g") #'pichat-jobs-refresh)
    map))
(define-derived-mode pichat-jobs-mode tabulated-list-mode "PiChat Jobs"
  "Inspect saved jobs and individual attempts; browsing never executes work."
  (setq tabulated-list-padding 1)
  ;; Keep native sortable column headings above the rows, with the compact
  ;; overview/filter always visible below rather than replacing those headings.
  (setq-local mode-line-format '("%e" mode-line-front-space "PiChat Jobs  "
                                mode-line-process mode-line-end-spaces)))

;;;###autoload
(defun pichat-jobs ()
  "Open the Jobs view; initialize the store once, without replaying old work."
  (interactive)
  (let ((owner (pichat-jobs--engine)))
    (pop-to-buffer (get-buffer-create "*PiChat Jobs*"))
    (unless (derived-mode-p 'pichat-jobs-mode) (pichat-jobs-mode))
    (setq pichat-jobs--owner owner)
    (pichat-jobs-refresh)))

(defun pichat-jobs-run ()
  "Run selected job's current definition, without changing any schedule."
  (interactive)
  (unless (eq pichat-jobs--kind 'jobs) (user-error "Use Repeat this run from run details"))
  (let ((id (or (tabulated-list-get-id) (user-error "No job selected"))))
    (pichat-job-executor-submit pichat-jobs--owner nil id)
    (message "PiChat job queued; your current chat is unchanged")))

(defun pichat-jobs-edit ()
  "Edit the selected saved job; existing attempts remain immutable."
  (interactive)
  (unless (eq pichat-jobs--kind 'jobs) (user-error "Select a saved job to edit"))
  (let ((job (pichat-job-record (pichat-jobs--store) 'jobs
                               (or (tabulated-list-get-id) (user-error "No job selected")))))
    (pichat-job--setup (plist-get job :spec) (plist-get job :id) pichat-jobs--owner)))

(defun pichat-jobs--open-chat (owner id)
  "Open exact run ID's retained chat, never select an unrelated runtime."
  (let* ((execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (unless (and session (buffer-live-p (pichat-session-buffer session)))
      (user-error "Owning chat unavailable; use the captured saved-session reference"))
    (pichat-chat-open session)))

(defun pichat-jobs--cancel (owner id)
  "Confirm cancellation of exact OWNER/ID, not merely its visible row."
  (let ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (when (yes-or-no-p (format "Cancel %s (%s) at %s in %s? "
                               (plist-get (plist-get run :spec) :title) id
                               (plist-get (plist-get (plist-get (plist-get run :spec) :configuration) :transport) :label)
                               (plist-get (plist-get run :spec) :directory)))
      (pichat-job-executor-cancel owner id))))

(defun pichat-jobs--resolve (owner id)
  "Explicitly acknowledge manual inspection of uncertain OWNER/ID."
  (let ((ack (read-string "Describe your process/workspace inspection: ")))
    (when (and (not (string-blank-p ack))
               (yes-or-no-p "Release claims even though shutdown is NOT independently verified? "))
      (pichat-job-executor-resolve owner id ack))))

(defun pichat-jobs--repeat (owner id)
  "Review historical OWNER/ID settings without rerunning automatically."
  (let ((spec (plist-get (pichat-job-record (pichat-job-executor-store owner) 'runs id) :spec)))
    (pichat-job--setup spec nil owner)
    (setf (plist-get pichat-job--draft :repeat-of) id)
    (pichat-job--render-setup)))

(defun pichat-jobs--diagnostics (owner id)
  "Show exact OWNER/ID's cached runtime diagnostics."
  (let* ((execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (unless session (user-error "No retained runtime; inspect recorded reason"))
    (pichat-show-diagnostics session)))

(defun pichat-jobs--access-label (access)
  "Describe coordination ACCESS without implying tool enforcement."
  (pcase access
    ("read" "Read-only — wait for stable files")
    ("observe" "Read-only — accepts changing files")
    (_ "May modify files — avoid overlapping changes")))

(defun pichat-jobs--tools-summary (config)
  "Describe captured CONFIG's Tools without exposing internal Lisp."
  (let* ((preset (plist-get config :preset)) (tools (plist-get config :tools))
         (builtins (plist-get (or tools preset) (if tools :builtins :tools)))
         (extensions (plist-get (or tools preset) :extensions))
         (mcp (plist-get tools :mcp)))
    (if (eq (plist-get preset :inherited) t) "Pi defaults (inherited from preset)"
      (format "%s%s%s%s"
              (if (or (null tools)
                      (and (equal builtins (plist-get preset :tools))
                           (equal extensions (plist-get preset :extensions))
                           (seq-empty-p mcp)))
                  "Preset defaults: " "Selected: ")
              (if (seq-empty-p builtins) "no built-ins" (string-join (append builtins nil) ", "))
              (if (seq-empty-p extensions) "" (format " · %d extension tools" (length extensions)))
              (if (seq-empty-p mcp) "" (format " · %d MCP tools" (length mcp)))))))

(defun pichat-jobs--insert-settings (spec &optional all-policies)
  "Insert a readable execution summary of captured SPEC.
Omit the default overlap policy unless ALL-POLICIES is non-nil."
  (let ((config (plist-get spec :configuration)))
    (insert (format "Project/workspace: %s\nTarget: %s\nModel: %s\nPreset: %s (captured)\nTools: %s\n"
                    (plist-get spec :directory)
                    (plist-get (plist-get config :transport) :label)
                    (plist-get config :model) (plist-get (plist-get config :preset) :name)
                    (pichat-jobs--tools-summary config)))
    (seq-doseq (resource (plist-get spec :resources))
      (when (or all-policies (not (equal (plist-get resource :access) "write")))
        (insert (format "Overlap policy: %s\n"
                        (pichat-jobs--access-label (plist-get resource :access))))))))

(defun pichat-jobs--show-detail (owner kind id &optional section)
  "Display exact OWNER/KIND/ID's cached SECTION, never executing work."
  (let ((buffer (get-buffer-create (format "*PiChat %s %s%s*" kind id
                                            (if section (format " %s" section) "")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-jobs-detail-mode) (pichat-jobs-detail-mode))
      (setq pichat-jobs--owner owner pichat-jobs--detail (cons kind id)
            pichat-jobs--section section)
      (pichat-jobs--render-detail))
    (pichat-view-display buffer)))

(defun pichat-jobs--show-history (owner job-id)
  "Display cached history for exact JOB-ID in OWNER."
  (pop-to-buffer (get-buffer-create "*PiChat Jobs*"))
  (unless (derived-mode-p 'pichat-jobs-mode) (pichat-jobs-mode))
  (setq pichat-jobs--owner owner pichat-jobs--selection job-id
        pichat-jobs--filter job-id pichat-jobs--attention-only nil pichat-jobs--kind 'runs)
  (pichat-jobs-refresh))

(defun pichat-jobs--open-saved (owner id)
  "Explicitly open finished run ID's saved Pi session independently.
Use captured transport/path context and the current default preset, not job
instructions.  Guard against managed duplicate writers and concurrent opens."
  (let* ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id))
         (spec (plist-get run :spec))
         (source (car (pichat-job-launch-prepare spec)))
         (transport (pichat-session-transport source))
         (file (plist-get run :session-file)))
    (unless (and (equal (plist-get run :state) "finished") file)
      (user-error "Resolve this execution before opening its saved session independently"))
    (let* ((host-file (pichat-transport-runtime-file-name transport file))
           (key (pichat--selected-file-key transport file)))
      (when (pichat--selected-file-conflict key)
        (user-error "A managed runtime still hosts this saved session; open or stop it first"))
      (unless (and (file-regular-p host-file) (file-readable-p host-file))
        (user-error "The captured saved session is not readable on its target"))
      (when (yes-or-no-p (format "Open saved session independently at %s using preset %s (not rerun work)? "
                                (pichat-transport-label transport) pichat-default-preset))
        (let ((token (pichat--claim-selected-file key)) (previous pichat-current-session))
          (condition-case err
              (pichat-sessions-open-file-independently
               (pichat-sessions--emacs-file file source)
               :cwd (pichat-session-runtime-cwd source)
               :owner-directory (plist-get spec :directory) :source-session source
               :launch-options (list :persistence 'persistent :preset pichat-default-preset)
               :readiness 'transcript-ready
               :ready (lambda (_session) (pichat--release-selected-file key token))
               :error-callback (lambda (response _session)
                                 (pichat--release-selected-file key token)
                                 (setq pichat-current-session previous)
                                 (message "Saved session open failed: %s" (plist-get response :error))))
            ((error quit)
             (pichat--release-selected-file key token)
             (setq pichat-current-session previous)
             (signal (car err) (cdr err)))))))))

(defun pichat-jobs--render-run (owner record)
  "Insert cached run RECORD's state and applicable actions for OWNER."
  (let* ((id (plist-get record :id)) (spec (plist-get record :spec))
         (execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution)))
         (chat (and session (pichat-chat-owned-buffer session)))
         (state (plist-get record :state)))
    (insert (format "Execution: %s\nResult: %s\nTrigger: Manual\n"
                    (pichat-jobs--state owner record) (pichat-jobs--result record)))
    (dolist (field '((:created-at . "Queued") (:started-at . "Started (dispatch)")
                     (:finished-at . "Finished") (:resolved-at . "Manually resolved")))
      (when (or (not (eq (car field) :resolved-at)) (plist-get record :resolved-at))
        (insert (format "%s (UTC): %s\n" (cdr field)
                        (or (plist-get record (car field))
                            (cond
                             ((and (eq (car field) :started-at)
                                   (null (plist-get record :attempt))) "Not started")
                             ((and (eq (car field) :finished-at)
                                   (or (equal state "uncertain") (plist-get record :resolved-at)))
                              "Not established")
                             ((and (eq (car field) :finished-at) (not (equal state "finished")))
                              "Not finished")
                             (t "Not recorded")))))))
    (when (equal state "queued")
      (let ((decision (pichat-job-admission (pichat-jobs--store) id pichat-jobs-max-concurrency)))
        (insert (format "Waiting reason: %s\n" (or (plist-get decision :reason) "Ready for dispatch")))
        (when-let* ((blocker (plist-get decision :blocking-run)))
          (pichat-jobs--button "Open blocking run"
                              (lambda () (pichat-jobs--show-detail owner 'runs blocker)))
          (insert (format "(%s)\n" blocker)))))
    (when session
      (when-let* ((attention (pichat-chat-pending-user-input-summary session)))
        (insert (format "Needs input: %s\nOpen the owning chat to respond; nothing is auto-approved.\n" attention))))
    (when (plist-get record :reason) (insert (format "Reason: %s\n" (plist-get record :reason))))
    (when (plist-get record :summary)
      (insert (format "\nAgent report (not independent verification):\n%s\n" (plist-get record :summary))))
    (insert (format "\nSaved session: %s\nRuntime ID: %s\n\n"
                    (or (plist-get record :session-file) "Unavailable")
                    (or (plist-get record :runtime-id) "Unavailable")))
    (if chat
        (pichat-jobs--button "Open chat" (lambda () (pichat-jobs--open-chat owner id)))
      (insert "Owning chat unavailable. ")
      (when (and (equal state "finished") (plist-get record :session-file))
        (pichat-jobs--button "Open saved session independently…"
                            (lambda () (pichat-jobs--open-saved owner id)))))
    (when session
      (pichat-jobs--button "Diagnostics" (lambda () (pichat-jobs--diagnostics owner id))))
    (insert "\n")
    (pichat-jobs--button "Instructions & settings"
                        (lambda () (pichat-jobs--show-detail owner 'runs id 'settings)))
    (pichat-jobs--button "Repeat this run…" (lambda () (pichat-jobs--repeat owner id)))
    (pichat-jobs--button "Save as job…" (lambda () (pichat-job--setup spec nil owner)))
    (insert "\n")
    (cond
     ((equal state "uncertain")
      (insert "Claims remain held; Pi exit alone does not prove descendant/workspace safety.\n")
      (seq-doseq (resource (plist-get spec :resources))
        (insert (format "Held resource: %s\n" (plist-get resource :key))))
      (if (and session (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
               (pichat-process-lifetime-supported-p (pichat-job-execution-process execution)))
          (pichat-jobs--button
           "Recheck remote Pi exit"
           (lambda ()
             (pichat-job-executor-recheck-exit
              owner id (lambda (success reason)
                         (message "%s" (if success "Pi exit confirmed; inspect descendants/workspace before release"
                                         (or reason "Exit not confirmed")))))))
        (insert "Remote exit recheck unavailable: no retained verified SSH lifetime.\n"))
      (pichat-jobs--button "Release after manual inspection…" (lambda () (pichat-jobs--resolve owner id))))
     ((not (equal state "finished"))
      (pichat-jobs--button "Cancel run…" (lambda () (pichat-jobs--cancel owner id)))))))

(defun pichat-jobs--render-detail ()
  "Render exact cached details with progressive disclosure of captured inputs."
  (let* ((owner pichat-jobs--owner)
         (kind (car pichat-jobs--detail)) (id (cdr pichat-jobs--detail))
         (record (pichat-job-record (pichat-jobs--store) kind id))
         (spec (plist-get record :spec))
         (inhibit-read-only t) (position (point)))
    (erase-buffer)
    (insert (format "%s\n%s\n\n" (plist-get spec :title) id))
    (cond
     ((eq pichat-jobs--section 'raw)
      (insert "Raw captured record — may contain sensitive prompts/arguments. Review before sharing.\n\n"
              (pp-to-string record)))
     ((eq pichat-jobs--section 'settings)
      (pichat-jobs--insert-settings spec t)
      (insert (format "\nInstructions\n%s\n\n" (plist-get spec :instructions)))
      (pichat-jobs--button "Inspect raw settings (sensitive)…"
                          (lambda () (pichat-jobs--show-detail owner kind id 'raw))))
     (t
      (if (eq kind 'jobs)
          (progn
            (insert "Schedule: Off\n\n")
            (pichat-jobs--button "Run job" (lambda () (pichat-job-executor-submit owner nil id)))
            (pichat-jobs--button "Edit…" (lambda () (pichat-job--setup spec id owner)))
            (insert "\n\n")
            (if-let* ((latest (pichat-jobs--latest (pichat-jobs--store) id)))
                (let ((run-id (plist-get latest :id)))
                  (insert (format "Latest run: %s · %s\n" (pichat-jobs--status owner latest) (plist-get latest :created-at)))
                  (when (plist-get latest :summary)
                    (insert (format "Agent report (not independently verified): %s\n"
                                    (pichat-jobs--display (plist-get latest :summary)))))
                  (pichat-jobs--button "Open latest run" (lambda () (pichat-jobs--show-detail owner 'runs run-id))))
              (insert "Latest run: Never run\n")))
        (pichat-jobs--render-run owner record))
      (when-let* ((job-id (if (eq kind 'jobs) id (plist-get record :job-id))))
        (pichat-jobs--button "Job history" (lambda () (pichat-jobs--show-history owner job-id)))
        (unless (eq kind 'jobs)
          (pichat-jobs--button "Job definition" (lambda () (pichat-jobs--show-detail owner 'jobs job-id)))))
      (when-let* ((origin (plist-get (plist-get record :trigger) :repeat-of)))
        (insert (format "\nRepeated from: %s (historical captured settings)\n" origin)))
      (insert "\n\n")
      (pichat-jobs--insert-settings spec)
      (when (eq kind 'jobs)
        (insert (format "\nInstructions\n%s\n\n" (plist-get spec :instructions)))
        (pichat-jobs--button "Captured settings"
                            (lambda () (pichat-jobs--show-detail owner kind id 'settings))))))
    (setq header-line-format "Cached inspection · q Back")
    (goto-char (min position (point-max)))))

(defun pichat-jobs-preview ()
  "Toggle a read-only details preview, preserving selection in Jobs/Runs."
  (interactive)
  (let* ((id (or (tabulated-list-get-id) (user-error "No row selected")))
         (buffer (get-buffer (format "*PiChat %s %s*" pichat-jobs--kind id)))
         (window (and buffer (get-buffer-window buffer t))))
    (if window (quit-window nil window)
      (save-selected-window (pichat-jobs-details)))))

(defvar pichat-jobs-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "RET") #'push-button)
    map))
(define-derived-mode pichat-jobs-detail-mode pichat-view-mode "PiChat Job Details"
  "Read-only cached job/run details with explicit action buttons.")

(defun pichat-jobs-details ()
  "Open details of the exact selected definition or attempt without executing."
  (interactive)
  (pichat-jobs--show-detail pichat-jobs--owner pichat-jobs--kind
                            (or (tabulated-list-get-id) (user-error "No row selected"))))

;;; Setup owns a mutable draft, never a live runtime.  Captured settings survive
;;; instruction edits.  Explicit execution changes re-resolve after review.

(defun pichat-job--setup (spec id owner)
  "Open a persistent setup draft for captured SPEC, optional saved ID and OWNER."
  (let ((buffer (generate-new-buffer "*PiChat Job Setup*"))
        (directory default-directory))
    (with-current-buffer buffer
      (setq default-directory directory)
      (pichat-job-setup-mode)
      (setq pichat-jobs--owner owner
            pichat-job--draft
          (list :spec (and spec (pichat-job--copy spec)) :id id
                :directory (or (plist-get spec :directory)
                               (pichat--project-root default-directory) default-directory)
                :instructions (or (plist-get spec :instructions) "")
                :title (or (plist-get spec :title) "")
                :profile (list :preset pichat-default-preset :target 'inferred
                               :model (or pichat-default-model 'prompt))
                :access (or (and spec (plist-get (aref (plist-get spec :resources) 0) :access))
                            "write") :dirty nil))
      (pichat-job--render-setup))
    (pichat-view-display buffer)))

;;;###autoload
(defun pichat-job-new ()
  "Compose one-off work or save a reusable job; no runtime is launched yet."
  (interactive)
  (pichat-job--setup nil nil (pichat-jobs--engine)))

(defun pichat-job--render-setup ()
  "Render the draft without changing it or resolving launch settings."
  (let* ((draft pichat-job--draft) (spec (plist-get draft :spec))
         (profile (plist-get draft :profile))
         (config (plist-get spec :configuration))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (cond ((plist-get draft :repeat-of) "Repeat captured job run\n\n")
                  ((plist-get draft :id) "Edit PiChat job\n\n")
                  (t "New PiChat job\n\n")))
    (insert (format "Instructions:\n%s\n\n" (plist-get draft :instructions)))
    (pichat-jobs--button "Edit instructions…" #'pichat-job-edit-instructions)
    (insert (format "\n\nProject: %s\n" (plist-get draft :directory)))
    (pichat-jobs--button "Change project…" #'pichat-job-change-project)
    (insert (format "\nExecution: %s · %s · %s%s\n"
                    (if spec (plist-get (plist-get config :preset) :name) (plist-get profile :preset))
                    (if spec (plist-get config :model)
                      (if (stringp (plist-get profile :model)) (plist-get profile :model)
                        "Needs setup — choose Model"))
                    (if spec (plist-get (plist-get config :transport) :label)
                      (condition-case nil
                          (pichat-transport-label
                           (pichat-transport-resolve
                            (plist-get draft :directory)
                            (unless (eq (plist-get profile :target) 'inferred)
                              (plist-get profile :target))))
                        (error "Target unavailable — choose execution settings")))
                    (if spec " (captured settings)" "")))
    (insert (format "Tools: %s\n"
                    (if spec (pichat-jobs--tools-summary config)
                      (pichat-jobs--tools-summary
                       (list :preset (pichat-job-launch--preset
                                      (pichat-presets-resolve (plist-get profile :preset)))
                             :tools (pichat-job-launch--tools (plist-get profile :tools)))))))
    (unless (equal (plist-get draft :access) "write")
      (insert (format "Overlap policy: %s\n"
                      (pichat-jobs--access-label (plist-get draft :access)))))
    (when spec
      (let ((different
             (condition-case nil
                 (not (equal (pichat-job-launch--preset
                              (pichat-presets-resolve
                               (intern (plist-get (plist-get config :preset) :name))))
                             (plist-get config :preset)))
               (error t))))
        (when different
          (insert "Current preset differs or is unavailable; captured settings remain in use.\n"))))
    (pichat-jobs--button "Execution settings…" #'pichat-job-execution-settings)
    (insert "\n\nStart: Now (manual)\n\n")
    (pichat-jobs--button "Run once" #'pichat-job-run-once)
    (pichat-jobs--button "Save job…" #'pichat-job-save-draft)
    (pichat-jobs--button "Cancel" #'pichat-job-setup-quit)
    (insert "\n")
    (goto-char (point-min))))

(defun pichat-job-setup-quit ()
  "Close setup after explicitly discarding changes, or keep the draft for later."
  (interactive)
  (if (and (plist-get pichat-job--draft :dirty)
           (not (yes-or-no-p "Discard unsaved job draft? (No keeps it for later) ")))
      (pichat-view-return)
    (pichat-view-return nil 'kill)))

(defvar pichat-job-setup-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "RET") #'push-button)
    (define-key map (kbd "C-c C-c") #'pichat-job-run-once)
    (define-key map (kbd "C-c C-s") #'pichat-job-save-draft)
    (define-key map (kbd "C-c C-e") #'pichat-job-edit-instructions)
    (define-key map (kbd "q") #'pichat-job-setup-quit)
    map))
(define-derived-mode pichat-job-setup-mode pichat-view-mode "PiChat Job Setup"
  "Compose job settings without starting or reconfiguring a runtime.")

(defun pichat-job--editable ()
  "Reject competing draft edits while an explicitly requested picker is pending."
  (when (plist-get pichat-job--draft :pending)
    (user-error "Finish the pending execution picker before editing or submitting")))

(defun pichat-job-edit-instructions ()
  "Edit multiline instructions separately; applying does not submit them."
  (interactive)
  (pichat-job--editable)
  (let ((origin (current-buffer))
        (presentation (pichat-view-capture-origin))
        (text (plist-get pichat-job--draft :instructions)))
    (pop-to-buffer (generate-new-buffer "*PiChat Job Instructions*"))
    (text-mode)
    (pichat-view-display (current-buffer) presentation)
    (insert text)
    (setq header-line-format "C-c C-c Apply instructions (does not run)   C-c C-k Cancel")
    (let ((map (copy-keymap (current-local-map))))
      (define-key map (kbd "C-c C-c")
                  (lambda () (interactive)
                    (unless (buffer-live-p origin) (user-error "Job draft no longer exists"))
                    (let ((text (buffer-string)) (editor (current-buffer)))
                      (with-current-buffer origin
                        (setf (plist-get pichat-job--draft :instructions) text
                              (plist-get pichat-job--draft :dirty) t)
                        (pichat-job--render-setup))
                      (with-current-buffer editor (pichat-view-return origin 'kill)))))
      (define-key map (kbd "C-c C-k")
                  (lambda () (interactive) (pichat-view-return origin 'kill)))
      (use-local-map map))))

(defun pichat-job--invalidate-capture ()
  "Confirm explicitly re-resolving captured settings before changing execution."
  (when (plist-get pichat-job--draft :spec)
    (unless (yes-or-no-p "Changing execution re-resolves preset/target settings; continue? ")
      (user-error "Captured settings preserved"))
    (let* ((config (plist-get (plist-get pichat-job--draft :spec) :configuration))
           (target (plist-get (plist-get config :transport) :id)))
      (setf (plist-get pichat-job--draft :profile)
            (list :preset (intern (plist-get (plist-get config :preset) :name))
                  :target (if (equal target "local") 'local (intern target))
                  :model (plist-get config :model)
                  :tools (pichat-job-launch--untools
                          (pichat-job-launch--unpreset (plist-get config :preset))
                          (plist-get config :tools)))
            (plist-get pichat-job--draft :access)
            (plist-get (aref (plist-get (plist-get pichat-job--draft :spec) :resources) 0) :access)
            (plist-get pichat-job--draft :spec) nil))))

(defun pichat-job-change-project ()
  "Select project explicitly, retaining instructions and other draft fields."
  (interactive)
  (pichat-job--editable)
  (let ((directory (read-directory-name "Job workspace: " (plist-get pichat-job--draft :directory))))
    (pichat-job--invalidate-capture)
    (setf (plist-get pichat-job--draft :directory) (file-name-as-directory (expand-file-name directory))
          (plist-get pichat-job--draft :dirty) t)
    (pichat-job--render-setup)))

(defun pichat-job--choose-model (origin original)
  "Select a run-local model for ORIGIN asynchronously.
Restore ORIGINAL on failure."
  (let* ((profile (plist-get pichat-job--draft :profile))
         (target (plist-get profile :target))
         (token (make-symbol "job-model"))
         process)
    (setf (plist-get pichat-job--draft :pending) token)
    (setq process
          (pichat--list-models-async
           nil (lambda (models)
                 (when (buffer-live-p origin)
                   (with-current-buffer origin
                     (when (eq token (plist-get pichat-job--draft :pending))
                       (condition-case err
                           (let ((model (pichat--read-model-table-choice "Job model: " models t)))
                             (setf (plist-get (plist-get pichat-job--draft :profile) :model) model
                                   (plist-get pichat-job--draft :dirty) t
                                   (plist-get pichat-job--draft :pending) nil)
                             (pichat-job--render-setup))
                         ((error quit)
                          (setq pichat-job--draft original)
                          (pichat-job--render-setup)
                          (message "%s" (error-message-string err))))))))
           (plist-get pichat-job--draft :directory)
           (unless (eq target 'inferred) target)))
    ;; The shared model-list helper reports empty/error results without invoking
    ;; its success callback.  Observe its owned process exit to restore our draft.
    (when (processp process)
      (let ((sentinel (process-sentinel process)))
        (set-process-sentinel
         process
         (lambda (process event)
           (unwind-protect (when sentinel (funcall sentinel process event))
             (when (and (memq (process-status process) '(exit signal))
                        (buffer-live-p origin))
               (with-current-buffer origin
                 (when (eq token (plist-get pichat-job--draft :pending))
                   (setq pichat-job--draft original)
                   (pichat-job--render-setup)))))))))))

(defun pichat-job-execution-settings ()
  "Choose a familiar execution control; preserve the draft across sub-pickers."
  (interactive)
  (pichat-job--editable)
  (let ((choice (completing-read
                 "Execution setting: "
                 '("Preset" "Tools" "Model" "Target" "Workspace coordination") nil t)))
    (if (equal choice "Workspace coordination")
        (let ((access (completing-read
                       "Coordination (not tool permissions): "
                       '("May modify files — avoid overlapping changes"
                         "Read-only — wait for stable files"
                         "Read-only — accepts changing files") nil t)))
          (setf (plist-get pichat-job--draft :access)
                (cond ((string-prefix-p "May" access) "write")
                      ((string-match-p "stable" access) "read") (t "observe")))
          (when-let* ((spec (plist-get pichat-job--draft :spec)))
            (setf (plist-get (aref (plist-get spec :resources) 0) :access)
                  (plist-get pichat-job--draft :access)))
          (setf (plist-get pichat-job--draft :dirty) t)
          (pichat-job--render-setup))
      ;; Make execution edits transactional, including cancel in any sub-picker.
      (let* ((original (pichat-presets--copy pichat-job--draft))
             (origin (current-buffer)))
        (condition-case err
            (progn
              (pichat-job--invalidate-capture)
              (pcase choice
                ("Preset"
                 (let* ((name (completing-read "Preset: " (mapcar #'symbol-name (mapcar #'car pichat-presets)) nil t))
                        (profile (plist-get pichat-job--draft :profile)))
                   (when (and (plist-get profile :tools)
                              (not (yes-or-no-p "Changing preset resets Tools to its defaults; continue? ")))
                     (signal 'quit nil))
                   (setf (plist-get profile :preset) (intern name)
                         (plist-get profile :tools) nil)))
                ("Target"
                 (let* ((name (completing-read "Target: " (pichat--launch-target-choices) nil t))
                        (profile (plist-get pichat-job--draft :profile)))
                   (setf (plist-get profile :target) (intern name))))
                ("Model" (pichat-job--choose-model origin original))
                ("Tools"
                 (let* ((profile (plist-get pichat-job--draft :profile))
                        (preset (pichat-presets-resolve (plist-get profile :preset)))
                        (directory (plist-get pichat-job--draft :directory))
                        (target (plist-get profile :target))
                        (transport (pichat-transport-resolve directory (unless (eq target 'inferred) target))))
                   (setf (plist-get pichat-job--draft :pending) t)
                   (pichat-tool-picker-open
                    preset (plist-get profile :tools) directory transport pichat-pi-executable
                    (lambda (selection)
                      (when (buffer-live-p origin)
                        (with-current-buffer origin
                          (if (eq selection :cancel) (setq pichat-job--draft original)
                            (setf (plist-get (plist-get pichat-job--draft :profile) :tools) selection
                                  (plist-get pichat-job--draft :dirty) t
                                  (plist-get pichat-job--draft :pending) nil))
                          (pichat-job--render-setup))
                        (pop-to-buffer origin)))
                    (let ((model (plist-get profile :model))) (and (stringp model) model))))))
              (unless (member choice '("Tools" "Model"))
                (setf (plist-get pichat-job--draft :dirty) t))
              (with-current-buffer origin (pichat-job--render-setup)))
          ((error quit)
           (setq pichat-job--draft original)
           (pichat-job--render-setup)
           (signal (car err) (cdr err))))))))

(defun pichat-job--submission-spec ()
  "Return captured draft work; never launch, silently refresh or pick a model."
  (pichat-job--editable)
  (let* ((draft pichat-job--draft)
         (text (plist-get draft :instructions))
         (_ (unless (pichat-job--text-p text) (user-error "Enter job instructions first")))
         (title (or (and (pichat-job--text-p (plist-get draft :title)) (plist-get draft :title))
                    (truncate-string-to-width (car (split-string text "\n" t)) 60 nil nil "…"))))
    (unless (pichat-job--text-p text) (user-error "Enter job instructions first"))
    (if-let* ((captured (plist-get draft :spec)))
        (let ((spec (pichat-job--copy captured)))
          (setf (plist-get spec :instructions) text (plist-get spec :title) title)
          spec)
      (unless (stringp (plist-get (plist-get draft :profile) :model))
        (user-error "Choose Model in Execution settings before submission"))
      (pichat-job-launch-capture title text (plist-get draft :directory)
                                 (plist-get draft :profile) (plist-get draft :access)))))

(defun pichat-job-run-once ()
  "Submit this draft once without saving/enabling any definition."
  (interactive)
  (let* ((owner pichat-jobs--owner)
         (spec (pichat-job--submission-spec))
         (id (pichat-job-executor-submit owner spec nil (plist-get pichat-job--draft :repeat-of))))
    (setf (plist-get pichat-job--draft :dirty) nil)
    (pichat-view-return nil 'kill)
    (message "PiChat queued %s; inspect it in Jobs → Runs" id)))

(defun pichat-job-save-draft ()
  "Save this draft as a disabled manual definition; never submit work."
  (interactive)
  (pichat-job--editable)
  (let ((name (read-string "Job name: " (plist-get pichat-job--draft :title))))
    (unless (pichat-job--text-p name) (user-error "Job name is required"))
    (let ((spec (pichat-job--submission-spec)))
      (setf (plist-get spec :title) name)
      (let ((id (pichat-job-save (pichat-jobs--store) spec (plist-get pichat-job--draft :id))))
        (setf (plist-get pichat-job--draft :spec) spec
              (plist-get pichat-job--draft :id) id
              (plist-get pichat-job--draft :title) name
              (plist-get pichat-job--draft :dirty) nil)
        (pichat-job--render-setup)
        (pichat-jobs--changed pichat-jobs--owner)
        (message "Saved job; schedule off, nothing started")))))

(provide 'pichat-jobs)
;;; pichat-jobs.el ends here
