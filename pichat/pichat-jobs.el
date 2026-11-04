;;; pichat-jobs.el --- Manual job setup and inspection -*- lexical-binding: t; -*-

;;; Commentary:
;; Saved definitions, manual attempts and native timing share one executor.
;; Schedule controls belong to saved details; there is no plan adapter.
;; Saving, running, inspecting and manual uncertainty resolution are distinct.

;;; Code:
(require 'pichat-job-executor)
(require 'pichat-job-schedule-ui)
(require 'pichat-view)
(require 'pichat-disclosure)
(require 'pichat-response-view)
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
(defvar-local pichat-job--settings nil
  "Identity of the latest staged execution-settings menu for this buffer.")
(defvar-local pichat-jobs--expanded nil)
(defvar-local pichat-jobs--response-source nil)

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

(defvar pichat-jobs--disclosure-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map (kbd "TAB") #'pichat-jobs-detail-tab)
    (define-key map (kbd "<tab>") #'pichat-jobs-detail-tab)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "S-TAB") #'backward-button)
    (define-key map (kbd "S-<tab>") #'backward-button)
    map)
  "Button map for local folding, never execution actions.")

(defun pichat-jobs--button (label function &optional disclosure help)
  "Insert LABEL invoking FUNCTION; DISCLOSURE marks a local fold control.
HELP optionally describes the action without adding inline prose."
  (let ((button (insert-text-button label 'follow-link t
                                    'pichat-job-disclosure disclosure
                                    'pichat-job-action function
                                    'keymap (if disclosure pichat-jobs--disclosure-map button-map)
                                    'action (lambda (_button) (funcall function)))))
    (when help (button-put button 'help-echo help)))
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
          ((equal state "uncertain") "Needs inspection")
          ((equal state "finished") "Finished")
          ((and execution (pichat-job-execution-cleanup execution)) "Finishing")
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
      (member (plist-get (plist-get run :dispatch) :state) '("not-dispatched" "interrupted"))
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

(defun pichat-jobs--local-time (timestamp &optional format)
  "Format UTC TIMESTAMP in Emacs's local timezone using optional FORMAT."
  (condition-case nil
      (format-time-string (or format "%Y-%m-%d %H:%M:%S %Z") (date-to-time timestamp))
    (error timestamp)))

(defun pichat-jobs--queued-less-p (a b)
  "Compare run rows A and B by stored instants, not local clock strings."
  (time-less-p
   (date-to-time (get-text-property 0 'pichat-job-queued-at (aref (cadr a) 1)))
   (date-to-time (get-text-property 0 'pichat-job-queued-at (aref (cadr b) 1)))))

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
              (vconcat (list (list "Job" title-width t))
                       (unless narrow (list '("Schedule" 26 nil)))
                       (list '("Latest run" 20 nil) '("Project / target" 0 t)))
            (if narrow
                (vector (list "Work" title-width t)
                        '("Queued" 16 pichat-jobs--queued-less-p)
                        '("State / result" 0 nil))
              [("Work" 24 t) ("Queued" 20 pichat-jobs--queued-less-p) ("State" 20 nil)
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
                   (list id (vconcat
                             (list (pichat-jobs--display (plist-get spec :title)))
                             (unless narrow
                               (list (pichat-job-schedule-ui-status (plist-get job :schedule))))
                             (list (if latest (pichat-jobs--status pichat-jobs--owner latest) "Never run")
                                   (pichat-jobs--display (pichat-jobs--context spec)))))))
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
                                          (unless (plist-get run :job-id) " [unsaved]"))
                                  (propertize
                                   (pichat-jobs--local-time
                                    (plist-get run :created-at)
                                    (if narrow "%Y-%m-%d %H:%M" "%Y-%m-%d %H:%M:%S"))
                                   'pichat-job-queued-at (plist-get run :created-at)
                                   'help-echo (pichat-jobs--local-time (plist-get run :created-at))))
                            (if narrow (list (pichat-jobs--status pichat-jobs--owner run))
                              (list (pichat-jobs--state pichat-jobs--owner run)
                                    (pichat-jobs--result run)
                                    (pichat-jobs--trigger-label run)))
                            (unless narrow
                              (list (pichat-jobs--display (pichat-jobs--context (plist-get run :spec))))))))))
    (tabulated-list-init-header)
    (setq mode-line-process
          (format "%d/%d active · %d attention (%s) [%s%s]"
                  active pichat-jobs-max-concurrency attention
                  (if (pichat-view-evil-normal-p) "g a" "a")
                  (if (eq pichat-jobs--kind 'jobs) "Jobs" "Runs")
                  (cond (pichat-jobs--attention-only ": Needs attention")
                        (pichat-jobs--filter
                         (format ": %s"
                                 (plist-get
                                  (plist-get
                                   (or (seq-find (lambda (job)
                                                   (equal (plist-get job :id) pichat-jobs--filter))
                                                 (pichat-job-records store 'jobs))
                                       (pichat-jobs--latest store pichat-jobs--filter runs))
                                   :spec)
                                  :title)))
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
  "Toggle attempts needing input or review, without contacting Pi."
  (interactive)
  (when (eq pichat-jobs--kind 'jobs)
    (setq pichat-jobs--selection (tabulated-list-get-id)))
  (setq pichat-jobs--kind 'runs pichat-jobs--filter nil
        pichat-jobs--attention-only (not pichat-jobs--attention-only))
  (pichat-jobs-refresh))

(defun pichat-jobs-delete ()
  "Confirm deletion of the selected job definition, preserving run history."
  (interactive nil pichat-jobs-mode)
  (unless (and (derived-mode-p 'pichat-jobs-mode) (eq pichat-jobs--kind 'jobs))
    (user-error "Select a job in Jobs first"))
  (let* ((store (pichat-jobs--store))
         (id (or (tabulated-list-get-id) (user-error "No job selected")))
         (job (pichat-job-record store 'jobs id))
         (title (pichat-jobs--display (plist-get (plist-get job :spec) :title))))
    (when (y-or-n-p (format "Delete job ‘%s’? " title))
      (pichat-job-delete store id)
      (pichat-job-executor-schedule-refresh pichat-jobs--owner)
      (pichat-jobs--changed pichat-jobs--owner)
      (message "Job deleted; run history preserved"))))

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
      (cond ((derived-mode-p 'pichat-jobs-mode) (pichat-jobs-refresh))
            ((derived-mode-p 'pichat-job-setup-mode) (pichat-job--render-setup))
            ((and pichat-jobs--detail (derived-mode-p 'pichat-jobs-detail-mode))
             (pichat-jobs--render-detail))))))
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
    (define-key map (kbd "<tab>") #'pichat-jobs-toggle)
    (define-key map (kbd "C-o") #'pichat-jobs-preview)
    (define-key map (kbd "+") #'pichat-job-new)
    (define-key map (kbd "RET") #'pichat-jobs-details)
    (define-key map (kbd "r") #'pichat-jobs-run)
    (define-key map (kbd "e") #'pichat-jobs-edit)
    (define-key map (kbd "R") #'pichat-jobs-release-reservation)
    (define-key map (kbd "h") #'pichat-jobs-history)
    (define-key map (kbd "a") #'pichat-jobs-attention)
    (define-key map (kbd "g") #'pichat-jobs-refresh)
    map))
(define-derived-mode pichat-jobs-mode tabulated-list-mode "PiChat Jobs"
  "Inspect saved jobs and individual attempts; browsing never executes work.
\\<pichat-jobs-mode-map>\\[pichat-jobs-details] opens the selected row.
\\[pichat-jobs-release-reservation] releases an uncertain run's scheduling
reservation after inspection and confirmation.  With Evil, use g R."
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

(defun pichat-jobs-release-reservation ()
  "Release the selected uncertain run's reservation after manual inspection."
  (interactive)
  (unless (eq pichat-jobs--kind 'runs)
    (user-error "Select a run in Runs first"))
  (pichat-jobs--resolve pichat-jobs--owner
                        (or (tabulated-list-get-id) (user-error "No run selected"))))

(defun pichat-jobs--resolve (owner id)
  "Explicitly acknowledge manual inspection of uncertain OWNER/ID."
  (unless (equal (plist-get (pichat-job-record (pichat-job-executor-store owner)
                                             'runs id) :state) "uncertain")
    (user-error "This run has no uncertain reservation to release"))
  (let ((ack (read-string "Inspection note: ")))
    (when (and (not (string-blank-p ack))
               (yes-or-no-p "Release reservation? Queued jobs may start; running tools are not stopped. "))
      (pichat-job-executor-resolve owner id ack))))

(defun pichat-jobs--repeat (owner id)
  "Review historical OWNER/ID settings without rerunning automatically."
  (let ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (unless (equal (plist-get run :state) "finished")
      (user-error "Previous run must stop and uncertainty must be resolved first"))
    (pichat-job--setup (plist-get run :spec) nil owner)
    (setf (plist-get pichat-job--draft :repeat-of) id)
    (pichat-job--render-setup)))

(defun pichat-jobs--continue (owner id)
  "Review a fresh background continuation of stopped OWNER/ID, without running."
  (let ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (unless (pichat-job-continuable-p run)
      (user-error "Continue requires interrupted work with uncertainty resolved"))
    (pichat-job--setup (plist-get run :spec) nil owner)
    (setf (plist-get pichat-job--draft :continue-of) id
          (plist-get pichat-job--draft :guidance) "")
    (pichat-job--render-setup)))

(defun pichat-jobs--diagnostics (owner id)
  "Show exact OWNER/ID's cached runtime diagnostics."
  (let* ((execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (if session (pichat-show-diagnostics session)
      (pichat-jobs--show-detail owner 'runs id 'diagnostics))))

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
    (if (eq (plist-get preset :inherited) t) "Pi defaults"
      (format "%s%s%s%s"
              (if (or (null tools)
                      (and (equal builtins (plist-get preset :tools))
                           (equal extensions (plist-get preset :extensions))
                           (seq-empty-p mcp)))
                  "Preset defaults: " "Selected: ")
              (if (seq-empty-p builtins) "no built-ins" (string-join (append builtins nil) ", "))
              (if (seq-empty-p extensions) "" (format " · %d extension tools" (length extensions)))
              (if (seq-empty-p mcp) "" (format " · %d MCP tools" (length mcp)))))))

(defun pichat-jobs--insert-settings (spec)
  "Insert compact captured SPEC settings, omitting the default overlap policy."
  (let* ((config (plist-get spec :configuration))
         (preset (plist-get config :preset)))
    (insert (format "Model: %s\nPreset: %s · Tools: %s\n"
                    (plist-get config :model) (plist-get preset :name)
                    (if (eq (plist-get preset :inherited) t) "Pi defaults"
                      (pichat-jobs--tools-summary config))))
    (seq-doseq (resource (plist-get spec :resources))
      (unless (equal (plist-get resource :access) "write")
        (insert (format "Overlap policy: %s\n"
                        (pichat-jobs--access-label (plist-get resource :access))))))))

(defun pichat-jobs--insert-run-times (record)
  "Insert RECORD's local timeline without inventing unknown finish times."
  (insert "Times (local):\n")
  (dolist (field '((:created-at . "Queued") (:started-at . "Started")
                   (:finished-at . "Finished") (:resolved-at . "Manually resolved")))
    (when (or (not (eq (car field) :resolved-at)) (plist-get record :resolved-at))
      (let* ((value (plist-get record (car field)))
             (display (if value
                          (pichat-jobs--local-time value)
                        (if (and (eq (car field) :finished-at)
                                 (or (equal (plist-get record :state) "uncertain")
                                     (plist-get record :resolved-at)))
                            "Not established" "Not recorded"))))
        (insert (format "  %-9s %s\n" (concat (cdr field) ":") display))))))

(defun pichat-jobs--show-detail (owner kind id &optional section)
  "Display exact OWNER/KIND/ID's cached SECTION, never executing work."
  (let ((buffer (get-buffer-create (format "*PiChat %s %s%s*" kind id
                                            (if section (format " %s" section) "")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'pichat-jobs-detail-mode) (pichat-jobs-detail-mode))
      (setq pichat-jobs--owner owner pichat-jobs--detail (cons kind id)
            pichat-jobs--section section)
      (pichat-jobs--render-detail))
    (pichat-view-display buffer)
    (with-current-buffer buffer (pichat-jobs--render-detail))))

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
      (when (yes-or-no-p
             (format "Continue in chat using preset ‘%s’ on %s? "
                     pichat-default-preset (pichat-transport-label transport)))
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

(defun pichat-jobs--width ()
  "Return the narrowest displayed width for this view, without selecting it."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows (apply #'min (mapcar #'window-body-width windows))
      (window-body-width))))

(defun pichat-jobs--insert-instructions (instructions &optional key refresh)
  "Insert read-only INSTRUCTIONS, folded after five visual lines.
KEY identifies independent folding state (default task).  REFRESH redraws the
owning view (default report).  Setup keeps TAB as navigation; RET/click folds.
Use the chat's input styling, measured at the narrowest displaying window."
  (let* ((key (or key 'task))
         (refresh (or refresh #'pichat-jobs--render-detail))
         (setup (derived-mode-p 'pichat-job-setup-mode))
         (start (point))
         (prefix (pichat-chat--bar-prefix))
         (window (or (pichat-disclosure-window) (selected-window))))
    (insert instructions)
    (add-text-properties start (point)
                         (list 'line-prefix prefix 'wrap-prefix prefix
                               'face 'pichat-input-block-face))
    (let* ((end (point))
           (cut (pichat-disclosure-cut start end window))
           (long cut))
      (when long
        (if (member key pichat-jobs--expanded)
            (insert "  Show less")
          (delete-region cut end)
          (insert "…"))
        (make-text-button
         start (point) 'face 'pichat-input-block-face
         'keymap (if setup button-map pichat-jobs--disclosure-map)
         'pichat-job-disclosure t 'follow-link t
         'help-echo (if setup "RET or click to expand/collapse instructions"
                      "TAB, RET or click to expand/collapse instructions")
         'action (lambda (button)
                   (goto-char (button-start button))
                   (setq pichat-jobs--expanded
                         (if (member key pichat-jobs--expanded)
                             (remove key pichat-jobs--expanded)
                           (cons key pichat-jobs--expanded)))
                   (funcall refresh)))
        (put-text-property (- (point) (if (member key pichat-jobs--expanded) 9 1))
                           (point) 'face 'button))
      (add-text-properties start (point)
                           (list 'line-prefix prefix 'wrap-prefix prefix
                                 'pichat-job-section key)))
    (insert "\n\n")))

(defun pichat-jobs-detail-tab ()
  "Toggle only the disclosure at point; otherwise navigate without activating."
  (interactive)
  (if-let* ((button (button-at (point)))
            (_ (button-get button 'pichat-job-disclosure)))
      (button-activate button)
    (forward-button 1 t)))

(defun pichat-jobs--disclosure (key label)
  "Insert an explicit disclosure for KEY with LABEL."
  (pichat-jobs--button
   (concat (if (member key pichat-jobs--expanded) "▾ " "▸ ") label)
   (lambda ()
     (setq pichat-jobs--expanded
           (if (member key pichat-jobs--expanded) (remove key pichat-jobs--expanded)
             (cons key pichat-jobs--expanded)))
     (pichat-jobs--render-detail))
   t))

(defun pichat-jobs-copy-response ()
  "Copy the inspected run's exact response Markdown, never its rendered text."
  (interactive)
  (unless (stringp pichat-jobs--response-source) (user-error "No complete captured response"))
  (kill-new pichat-jobs--response-source))

(defun pichat-jobs--source-view (title text)
  "Display immutable TEXT in a read-only source view named TITLE."
  (let ((buffer (generate-new-buffer title)) (owner pichat-jobs--owner))
    (with-current-buffer buffer
      (pichat-view-mode)
      (setq-local pichat-jobs--owner owner)
      (let ((inhibit-read-only t)) (insert text))
      (setq-local truncate-lines nil)
      (visual-line-mode 1)
      (goto-char (point-min)))
    (pichat-view-display buffer nil 'kill)))

(defun pichat-jobs-response-source ()
  "Inspect exact captured response Markdown without starting Pi."
  (interactive)
  (unless (stringp pichat-jobs--response-source) (user-error "No complete captured response"))
  (pichat-jobs--source-view "*PiChat Job Response Source*" pichat-jobs--response-source))

(defun pichat-jobs--preview (owner id)
  "Preview ID's immutable run-end conversation, never its current saved file."
  (let* ((store (pichat-job-executor-store owner))
         (run (pichat-job-record store 'runs id))
         (digest (plist-get run :evidence)))
    (unless digest (user-error "This older run has no captured conversation"))
    (let ((evidence (pichat-job-evidence-read store digest)))
      (pichat-jobs--source-view
       (format "*PiChat Run Preview %s*" id)
       (with-temp-buffer
         (insert (propertize "Run conversation" 'face 'bold)
                 "\nCaptured run-end snapshot · Read-only\n\n")
         (if (eql (plist-get evidence :version) 2)
             (let* ((entries (json-parse-string
                              (json-serialize (plist-get evidence :entries))
                              :object-type 'plist :array-type 'list
                              :null-object nil :false-object :json-false))
                    (snapshot (pichat-sessions-preview-active-snapshot-from-entries
                               entries (plist-get evidence :leaf))))
               (pichat-sessions-insert-preview-path (plist-get snapshot :path)))
           (insert (propertize "Structured preview unavailable for this older capture; showing captured Markdown.\n\n"
                               'face 'shadow)
                   (plist-get evidence :transcript)))
         (buffer-string))))))

(defun pichat-jobs--reading-position (position)
  "Capture semantic section POSITION for a refresh; otherwise absolute position."
  (let ((section (get-text-property position 'pichat-job-section)))
    (if section
        (let ((start (or (previous-single-property-change
                          (1+ position) 'pichat-job-section nil (point-min)) (point-min))))
          (list section
                (length (replace-regexp-in-string
                         "[[:space:]]" "" (buffer-substring-no-properties start position)))))
      position)))

(defun pichat-jobs--restore-position (saved)
  "Resolve SAVED reading position after a render."
  (min (point-max)
       (if (consp saved)
           (let ((start (text-property-any (point-min) (point-max)
                                           'pichat-job-section (car saved))))
             (if (not start) (point-min)
               (save-excursion
                 (goto-char start)
                 (let ((remaining (cadr saved))
                       (end (or (next-single-property-change
                                 start 'pichat-job-section nil (point-max)) (point-max))))
                   (while (and (> remaining 0) (< (point) end))
                     (unless (looking-at-p "[[:space:]]") (cl-decf remaining))
                     (forward-char 1))
                   (point)))))
         saved)))

(defun pichat-jobs--captured-error (evidence)
  "Return the last assistant's original error from captured EVIDENCE, if any."
  (let ((message (cl-loop for entry across (vconcat (plist-get evidence :entries))
                          for message = (plist-get entry :message)
                          when (equal (plist-get message :role) "assistant")
                          collect message into messages
                          finally return (car (last messages)))))
    (when-let* ((error (plist-get message :errorMessage))
                ((stringp error))
                ((not (string-blank-p error))))
      (pichat-chat-diagnostics-safe-summary-text error))))

(defun pichat-jobs--insert-followup (owner record)
  "Insert one linked status line for RECORD's captured after-run job in OWNER."
  (when (or (plist-get record :after-job) (plist-get record :dispatch))
    (let* ((snapshot (plist-get record :after-job))
           (dispatch (plist-get record :dispatch))
           (id (plist-get dispatch :run-id))
           (run (and id (pichat-job-record (pichat-job-executor-store owner) 'runs id))))
      (insert (format "After this run: %s · %s"
                      (if snapshot
                          (pichat-jobs--display (plist-get (plist-get snapshot :spec) :title))
                        (pichat-job--after-job-title (plist-get (plist-get record :spec) :after-job-id)))
                      (cond ((equal (plist-get dispatch :state) "interrupted")
                             (plist-get dispatch :reason))
                            (run (pichat-jobs--status owner run))
                            ((equal (plist-get dispatch :state) "not-dispatched")
                             (concat "Not dispatched — " (plist-get dispatch :reason)))
                            (t "Waiting for this run to stop"))))
      (when (and run (equal (plist-get run :state) "queued"))
        (let ((reason (plist-get (pichat-job-admission
                                 (pichat-job-executor-store owner) id
                                 pichat-jobs-max-concurrency) :reason)))
          (when reason (insert " — " reason))))
      (insert "  ")
      (when id
        (pichat-jobs--button "View follow-up run"
                            (lambda () (pichat-jobs--show-detail owner 'runs id))))
      (insert "\n"))))

(defun pichat-jobs--trigger-label (run)
  "Describe RUN's trigger without conflating timing and outcome."
  (pcase (plist-get (plist-get run :trigger) :kind)
    ("lifecycle" "After run") ("once" "Once") ("interval" "Interval") (_ "Manual")))

(defun pichat-jobs--render-run (owner record)
  "Insert cached run RECORD's state and applicable actions for OWNER."
  (let* ((id (plist-get record :id)) (spec (plist-get record :spec))
         (execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution)))
         (chat (and session (pichat-chat-owned-buffer session)))
         (state (plist-get record :state)))
    (insert (format "%s · %s\n\n"
                    (cond ((equal state "finished") (pichat-jobs--result record))
                          ((and (equal state "settling") execution
                                (pichat-job-execution-cleanup execution))
                           "Answer captured · Stopping runtime")
                          (t (pichat-jobs--state owner record)))
                    (pichat-jobs--trigger-label record)))
    (when-let* ((event (plist-get record :event)))
      (let ((origin (plist-get event :run-id)))
        (insert "Triggered by: ")
        (pichat-jobs--button (pichat-jobs--display (plist-get event :title))
                            (lambda () (pichat-jobs--show-detail owner 'runs origin)))
        (insert "\n")
        (when (equal (plist-get event :completeness) "partial")
          (insert "Previous run context is partial or unavailable.\n"))
        (insert "\n")))
    (pichat-jobs--insert-instructions (plist-get spec :instructions))

    (when (equal state "queued")
      (let ((decision (pichat-job-admission (pichat-job-executor-store owner) id pichat-jobs-max-concurrency)))
        (insert (format "Waiting reason: %s\n" (or (plist-get decision :reason) "Ready for dispatch")))
        (when-let* ((blocker (plist-get decision :blocking-run)))
          (pichat-jobs--button "Open blocking run"
                              (lambda () (pichat-jobs--show-detail owner 'runs blocker)))
          (insert "\n"))))
    (when session
      (when-let* ((attention (pichat-chat-pending-user-input-summary session)))
        (insert (format "Needs input: %s\nOpen the owning chat to respond; nothing is auto-approved.\n" attention))))
    (let ((start (point)))
      (setq pichat-jobs--response-source nil)
      (if (plist-get record :evidence)
          (condition-case err
              (let* ((evidence (pichat-job-evidence-read (pichat-job-executor-store owner)
                                                       (plist-get record :evidence)))
                     (markdown (plist-get evidence :response))
                     (error (pichat-jobs--captured-error evidence)))
                (unless (string-blank-p (or markdown ""))
                  (setq pichat-jobs--response-source markdown)
                  (insert "\n" (pichat-response-view-render-markdown markdown (pichat-jobs--width))))
                (when error (insert "\n" error "\n"))
                (when (and (string-blank-p (or markdown "")) (not error))
                  (insert "\nNo response captured.\n")))
            (error (insert (format "\nResponse unavailable: %s\n" (error-message-string err)))))
        (when-let* ((summary (plist-get record :summary))
                    ((not (string-blank-p summary))))
          (insert "\nResponse preview (complete response not captured)\n\n" summary "\n")))
      (when (and (= start (point)) (member state '("finished" "uncertain")))
        (insert "\nNo response captured.\n"))
      (put-text-property start (point) 'pichat-job-section 'response))
    (insert "\n")
    (when (pichat-job-continuable-p record)
      (pichat-jobs--button "Continue work…" (lambda () (pichat-jobs--continue owner id))))
    (when (plist-get record :evidence)
      (pichat-jobs--button "Preview conversation" (lambda () (pichat-jobs--preview owner id))))
    (when (and chat (or (not (plist-get record :evidence)) (not (equal state "finished"))))
      (pichat-jobs--button "View chat" (lambda () (pichat-jobs--open-chat owner id))))
    (pichat-jobs--button "Diagnostics" (lambda () (pichat-jobs--diagnostics owner id)))
    (insert "\n")
    (pichat-jobs--insert-followup owner record)
    (pichat-jobs--disclosure 'actions "More actions")
    (when (member 'actions pichat-jobs--expanded)
      (insert "\n")
      (cl-flet ((action (label function &optional help)
                  (insert "  ")
                  (pichat-jobs--button label function nil help)
                  (insert "\n")))
        (when (equal state "finished")
          (action "Repeat…" (lambda () (pichat-jobs--repeat owner id))))
        (when (and (equal state "finished") (plist-get record :session-file))
          (action "Continue in chat…" (lambda () (pichat-jobs--open-saved owner id))
                  "Open the saved conversation for interactive work."))
        (when (equal state "uncertain")
          (action "Release reservation…" (lambda () (pichat-jobs--resolve owner id))))
        (action "Save as job…" (lambda () (pichat-job--setup spec nil owner)))
        (when-let* ((job-id (plist-get record :job-id)))
          (action "Job history" (lambda () (pichat-jobs--show-history owner job-id)))
          (when (seq-find (lambda (job) (equal (plist-get job :id) job-id))
                          (pichat-job-records (pichat-jobs--store) 'jobs))
            (action "Job definition" (lambda () (pichat-jobs--show-detail owner 'jobs job-id)))))
        (when pichat-jobs--response-source
          (action "Copy response Markdown" #'pichat-jobs-copy-response)
          (action "View response source" #'pichat-jobs-response-source))))
    (unless (bolp) (insert "\n"))
    (when (and (not (member state '("finished" "uncertain")))
               (not (and execution (pichat-job-execution-cleanup execution))))
      (pichat-jobs--button "Cancel run…" (lambda () (pichat-jobs--cancel owner id)))
      (insert "\n"))
    (pichat-jobs--disclosure 'execution "Execution details")
    (when (member 'execution pichat-jobs--expanded)
      (insert "\n")
      (when (equal state "uncertain")
        (insert "State: Execution uncertain\nReservation: Held\n"))
      (insert (format "Workspace: %s · Target: %s\n"
                      (plist-get spec :directory)
                      (plist-get (plist-get (plist-get spec :configuration) :transport) :label)))
      (when (and (equal state "uncertain") session
                 (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
                 (pichat-process-lifetime-supported-p (pichat-job-execution-process execution)))
        (pichat-jobs--button
         "Recheck remote Pi exit"
         (lambda ()
           (pichat-job-executor-recheck-exit
            owner id (lambda (success reason)
                       (message "%s" (if success "Pi exit confirmed; reservation remains held"
                                       (or reason "Exit not confirmed")))))))
        (insert "\n"))
      (pichat-jobs--insert-settings spec)
      (insert "\n")
      (pichat-jobs--insert-run-times record)
      (when-let* ((due (plist-get (plist-get record :trigger) :due)))
        (insert "Scheduled for: " (pichat-job-schedule-ui-time due) "\n"))
      (insert "\n")
      (when-let* ((origin (or (plist-get (plist-get record :trigger) :continue-of)
                             (plist-get (plist-get record :trigger) :repeat-of))))
        (insert (if (plist-get record :continuation)
                    "Continued from an earlier run.\n" "Repeated from an earlier run.\n"))
        (pichat-jobs--button "Previous run"
                            (lambda () (pichat-jobs--show-detail owner 'runs origin)))
        (insert "\n"))
      (when-let* ((continuation (plist-get record :continuation)))
        (unless (string-empty-p (plist-get continuation :guidance))
          (insert "Additional instructions:\n")
          (pichat-jobs--insert-instructions (plist-get continuation :guidance) 'guidance))
        (when (plist-get continuation :warning)
          (insert (plist-get continuation :warning) "\n")))
      (when-let* ((file (plist-get record :session-file)))
        (pichat-jobs--button "Copy saved-session path" (lambda () (kill-new file))))
      (insert "\n")
      (pichat-jobs--button "Inspect raw settings…"
                          (lambda () (pichat-jobs--show-detail owner 'runs id 'raw)))
      (insert "\n"))))

(defun pichat-jobs--render-job (owner record)
  "Insert cached job definition RECORD and applicable actions for OWNER."
  (let* ((id (plist-get record :id)) (spec (plist-get record :spec)))
    (insert (format "Workspace: %s · Target: %s\n\n"
                    (plist-get spec :directory)
                    (plist-get (plist-get (plist-get spec :configuration) :transport) :label)))
    (pichat-jobs--insert-instructions (plist-get spec :instructions))
    (when (plist-get spec :after-job-id)
      (insert (format "After this run: %s\n"
                      (pichat-job--after-job-title (plist-get spec :after-job-id)))))
    (pichat-jobs--button "Run job" (lambda () (pichat-job-executor-submit owner nil id)))
    (pichat-jobs--button "Edit…" (lambda () (pichat-job--setup spec id owner)))
    (pichat-jobs--button "Job history" (lambda () (pichat-jobs--show-history owner id)))
    (insert "\n\n")
    (pichat-job-schedule-ui-insert owner record)
    (if-let* ((latest (pichat-jobs--latest (pichat-jobs--store) id)))
        (let ((run-id (plist-get latest :id)))
          (insert (format "Latest run: %s · %s\n" (pichat-jobs--status owner latest)
                          (pichat-jobs--local-time (plist-get latest :created-at))))
          (pichat-jobs--button "Open latest run"
                              (lambda () (pichat-jobs--show-detail owner 'runs run-id))))
      (insert "Latest run: Never run\n"))
    (insert "\n\n")
    (pichat-jobs--disclosure 'definition "Job details")
    (when (member 'definition pichat-jobs--expanded)
      (insert "\n")
      (pichat-jobs--insert-settings spec)
      (insert "\n")
      (pichat-jobs--button "Inspect raw settings…"
                          (lambda () (pichat-jobs--show-detail owner 'jobs id 'raw))))))

(defun pichat-jobs--render-detail ()
  "Render exact cached details with progressive disclosure of captured inputs."
  (interactive)
  (let* ((owner pichat-jobs--owner)
         (kind (car pichat-jobs--detail)) (id (cdr pichat-jobs--detail))
         (record (if (eq kind 'jobs)
                     (seq-find (lambda (job) (equal (plist-get job :id) id))
                               (pichat-job-records (pichat-jobs--store) 'jobs))
                   (pichat-job-record (pichat-jobs--store) kind id)))
         (spec (plist-get record :spec))
         (inhibit-read-only t)
         (position (pichat-jobs--reading-position (point)))
         (windows (mapcar (lambda (window)
                            (list window (pichat-jobs--reading-position (window-start window))
                                  (pichat-jobs--reading-position (window-point window))))
                          (get-buffer-window-list (current-buffer) nil t))))
    (erase-buffer)
    (when (and record (eq kind 'jobs) (null pichat-jobs--section))
      (insert (propertize (plist-get spec :title) 'face 'bold) "\n"))
    (cond
     ((null record)
      (insert "Job deleted. Run history is preserved.\n"))
     ((eq pichat-jobs--section 'raw)
      (insert (pp-to-string record)))
     ((eq pichat-jobs--section 'diagnostics)
      (insert "Recorded execution diagnostics\n\n"
              (or (plist-get record :reason) "No execution note recorded.")
              "\n\nRuntime logs are unavailable; no retained runtime.\n\n")
      (pichat-jobs--button "Inspect raw settings…"
                          (lambda () (pichat-jobs--show-detail owner kind id 'raw))))
     (t
      (if (eq kind 'jobs)
          (pichat-jobs--render-job owner record)
        (pichat-jobs--render-run owner record))
      (insert "\n\n")))
    (setq header-line-format "q Back")
    (goto-char (pichat-jobs--restore-position position))
    (dolist (saved windows)
      (when (window-live-p (car saved))
        (set-window-start (car saved) (pichat-jobs--restore-position (cadr saved)) t)
        (set-window-point (car saved) (pichat-jobs--restore-position (caddr saved)))))
    (set-buffer-modified-p nil)))

(defun pichat-jobs-detail-refresh ()
  "Refresh the inspected report from durable evidence at its displayed width."
  (interactive)
  (pichat-jobs--render-detail))

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
    (define-key map (kbd "TAB") #'pichat-jobs-detail-tab)
    (define-key map (kbd "<tab>") #'pichat-jobs-detail-tab)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "S-TAB") #'backward-button)
    (define-key map (kbd "S-<tab>") #'backward-button)
    (define-key map (kbd "g") #'pichat-jobs-detail-refresh)
    (define-key map (kbd "w") #'pichat-jobs-copy-response)
    map))
(define-derived-mode pichat-jobs-detail-mode pichat-view-mode "PiChat Job Details"
  "Read-only cached job/run details with explicit action buttons."
  (setq-local truncate-lines nil truncate-partial-width-windows nil)
  (visual-line-mode 1)
  (pichat-response-view-install-faces))

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
                :after-job-id (plist-get spec :after-job-id)
                :profile (list :preset pichat-default-preset :target 'inferred
                               :model (or pichat-default-model 'prompt))
                :access (or (and spec (plist-get (aref (plist-get spec :resources) 0) :access))
                            "write") :dirty nil))
      (pichat-job--render-setup))
    (pichat-view-display buffer)
    (with-current-buffer buffer (pichat-job--render-setup))))

;;;###autoload
(defun pichat-job-new ()
  "Compose one-off work or save a reusable job; no runtime is launched yet."
  (interactive)
  (pichat-job--setup nil nil (pichat-jobs--engine)))

(defun pichat-job--position-anchor (position)
  "Capture POSITION as an action button and offset, with a numeric fallback."
  (let ((button (button-at position)))
    (list position (and button (button-get button 'pichat-job-action))
          (and button (- position (button-start button))))))

(defun pichat-job--anchor-position (anchor)
  "Resolve ANCHOR after rebuilding setup, preferring the same action button."
  (let ((button (next-button (point-min) t))
        (action (nth 1 anchor)))
    (while (and button
                (not (and action (eq action (button-get button 'pichat-job-action)))))
      (setq button (next-button (button-end button) t)))
    (if button
        (min (+ (button-start button) (nth 2 anchor)) (1- (button-end button)))
      (min (car anchor) (point-max)))))

(defun pichat-job--render-setup ()
  "Render the draft, preserving navigation without resolving launch settings."
  (let* ((anchor (pichat-job--position-anchor (point)))
         (windows
          (mapcar (lambda (window)
                    (list window
                          (pichat-job--position-anchor (window-point window))
                          (pichat-job--position-anchor (window-start window))
                          (window-vscroll window t)))
                  (get-buffer-window-list (current-buffer) nil t)))
         (draft pichat-job--draft) (spec (plist-get draft :spec))
         (profile (plist-get draft :profile))
         (config (plist-get spec :configuration))
         (inhibit-read-only t))
    (erase-buffer)
    (setq header-line-format
          (concat (cond ((plist-get draft :continue-of) "Continue work")
                        ((plist-get draft :repeat-of) "Repeat job run")
                        ((plist-get draft :id) "Edit job")
                        (t "New job"))
                  " · q Cancel"))
    (when-let* ((origin (or (plist-get draft :continue-of) (plist-get draft :repeat-of)))
                (owner pichat-jobs--owner))
      (pichat-jobs--button "Previous run"
                          (lambda () (pichat-jobs--show-detail owner 'runs origin)))
      (insert "\n\n"))
    (insert "Instructions:\n")
    (pichat-jobs--insert-instructions (plist-get draft :instructions)
                                      'task #'pichat-job--render-setup)
    (if (plist-get draft :continue-of)
        (progn
          (unless (string-empty-p (or (plist-get draft :guidance) ""))
            (insert "\nAdditional instructions:\n")
            (pichat-jobs--insert-instructions (plist-get draft :guidance)
                                              'guidance #'pichat-job--render-setup))
          (pichat-jobs--button "Additional instructions…" #'pichat-job-edit-instructions)
          (when-let* ((warning (plist-get
                               (pichat-job-continuation-context
                                (pichat-job-executor-store pichat-jobs--owner)
                                (pichat-job-record (pichat-job-executor-store pichat-jobs--owner)
                                                  'runs (plist-get draft :continue-of)))
                               :warning)))
            (insert "\n" warning "\n")))
      (pichat-jobs--button "Edit instructions…" #'pichat-job-edit-instructions))
    (when (plist-get draft :repeat-of)
      (insert "\nPrevious effects are not undone; repeating may repeat changes or external actions.\n"))
    (insert (format "\n\nProject: %s\n" (plist-get draft :directory)))
    (unless (plist-get draft :continue-of)
      (pichat-jobs--button "Change project…" #'pichat-job-change-project))
    (insert (format "\nExecution: %s · %s · %s\n"
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
                        (error "Target unavailable — choose execution settings")))))
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
    (insert (format "\n\nAfter this run: %s  "
                    (pichat-job--after-job-title (plist-get draft :after-job-id))))
    (pichat-jobs--button "Change…" #'pichat-job-change-after-job nil
                        "Completion, failure, cancellation or first uncertainty; not waiting for input. Sends bounded previous-run context to the selected job's model. Choose None to bypass for this run.")
    (when-let* ((id (plist-get draft :after-job-id))
                (owner pichat-jobs--owner)
                (_ (seq-find (lambda (job) (equal (plist-get job :id) id))
                             (pichat-job-records (pichat-jobs--store) 'jobs))))
      (pichat-jobs--button "View job" (lambda () (pichat-jobs--show-detail owner 'jobs id))))
    (insert "\n\n")
    (pichat-jobs--button "Run once" #'pichat-job-run-once)
    (unless (plist-get draft :continue-of)
      (pichat-jobs--button "Save job…" #'pichat-job-save-draft))
    (pichat-jobs--button "Cancel" #'pichat-job-setup-quit)
    (insert "\n")
    (dolist (state windows)
      (let ((window (car state)))
        (when (window-live-p window)
          (set-window-point window (pichat-job--anchor-position (nth 1 state)))
          (set-window-start window (pichat-job--anchor-position (nth 2 state)) t)
          (set-window-vscroll window (nth 3 state) t))))
    (goto-char (pichat-job--anchor-position anchor))))

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
    (define-key map (kbd "TAB") #'forward-button)
    (define-key map (kbd "<tab>") #'forward-button)
    (define-key map (kbd "<backtab>") #'backward-button)
    (define-key map (kbd "S-TAB") #'backward-button)
    (define-key map (kbd "S-<tab>") #'backward-button)
    (define-key map (kbd "C-c C-c") #'pichat-job-run-once)
    (define-key map (kbd "C-c C-s") #'pichat-job-save-draft)
    (define-key map (kbd "C-c C-e") #'pichat-job-edit-instructions)
    (define-key map (kbd "q") #'pichat-job-setup-quit)
    map))
(define-derived-mode pichat-job-setup-mode pichat-view-mode "PiChat Job Setup"
  "Compose job settings without starting or reconfiguring a runtime."
  (setq-local truncate-lines nil truncate-partial-width-windows nil)
  (visual-line-mode 1))

(defun pichat-job--editable ()
  "Reject competing draft edits while an explicitly requested picker is pending."
  (when (or (plist-get pichat-job--draft :pending)
            (and (plist-get pichat-job--settings :pending)
                 (pichat-job--settings-current-p pichat-job--settings)))
    (user-error "Finish the pending execution picker before editing or submitting")))

(defun pichat-job-edit-instructions ()
  "Edit multiline instructions separately; applying does not submit them."
  (interactive)
  (pichat-job--editable)
  (let* ((origin (current-buffer))
         (presentation (pichat-view-capture-origin))
         (key (if (plist-get pichat-job--draft :continue-of) :guidance :instructions))
         (text (or (plist-get pichat-job--draft key) "")))
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
                        (setf (plist-get pichat-job--draft key) text
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
  (when (plist-get pichat-job--draft :continue-of)
    (user-error "Continuation keeps the original workspace"))
  (let ((directory (read-directory-name "Job workspace: " (plist-get pichat-job--draft :directory))))
    (pichat-job--invalidate-capture)
    (setf (plist-get pichat-job--draft :directory) (file-name-as-directory (expand-file-name directory))
          (plist-get pichat-job--draft :dirty) t)
    (pichat-job--render-setup)))

(defun pichat-job--settings-current-p (scope)
  "Whether SCOPE still owns an unchanged setup draft."
  (let ((origin (plist-get scope :origin)))
    (and (buffer-live-p origin)
         (not (plist-get scope :closed))
         (with-current-buffer origin
           (and (eq scope pichat-job--settings)
                (equal pichat-job--draft (plist-get scope :original)))))))

(defun pichat-job--settings-show (scope)
  "Redisplay the configuration menu for current SCOPE."
  (when (pichat-job--settings-current-p scope)
    (with-current-buffer (plist-get scope :origin)
      (transient-setup 'pichat-job-settings-menu nil nil :scope scope))))

(defun pichat-job--settings-abandoned ()
  "Discard staged menus after explicitly quitting the Transient stack.
Do not discard model selections merely because their asynchronous picker exited
its prefix while waiting for the model-list process."
  (when (memq this-command '(transient-quit-one transient-quit-all transient-quit-seq))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when pichat-job--settings
          (setf (plist-get pichat-job--settings :closed) t))))))

(add-hook 'transient-post-exit-hook #'pichat-job--settings-abandoned)

(defun pichat-job--settings-finish-picker (scope draft)
  "Accept staged DRAFT or retain prior choices when nil, then return to SCOPE."
  (when (and (plist-get scope :pending) (pichat-job--settings-current-p scope))
    (setf (plist-get scope :pending) nil)
    (when draft (setf (plist-get scope :draft) draft))
    (pichat-job--settings-show scope)))

(defun pichat-job--settings-model (scope draft)
  "Choose a concrete model asynchronously for staged DRAFT in SCOPE."
  (let* ((target (plist-get (plist-get draft :profile) :target))
         (process
          (pichat--list-models-async
           nil (lambda (models)
                 (when (and (plist-get scope :pending)
                            (pichat-job--settings-current-p scope))
                   (condition-case err
                       (let ((model (pichat--read-model-table-choice "Job model: " models t)))
                         (setf (plist-get (plist-get draft :profile) :model) model)
                         (pichat-job--settings-finish-picker scope draft))
                     ((error quit)
                      (pichat-job--settings-finish-picker scope nil)
                      (message "%s" (error-message-string err))))))
           (plist-get draft :directory) (unless (eq target 'inferred) target))))
    ;; Empty/error listings do not call the model helper's success callback.
    (when (processp process)
      (let ((sentinel (process-sentinel process)))
        (set-process-sentinel
         process
         (lambda (process event)
           (unwind-protect (when sentinel (funcall sentinel process event))
             (when (memq (process-status process) '(exit signal))
               (pichat-job--settings-finish-picker scope nil)))))))))

(defun pichat-job--settings-edit (choice)
  "Edit CHOICE transactionally within the current settings menu."
  (let ((scope (transient-scope)))
    (unless (pichat-job--settings-current-p scope)
      (user-error "Job draft changed; reopen Execution settings"))
    (when (plist-get scope :pending) (user-error "Finish the pending picker first"))
    (when (and (plist-get (plist-get scope :draft) :continue-of)
               (member choice '("Target" "Workspace coordination")))
      (user-error "Continuation keeps the original target and resource claims"))
    ;; Existing capture invalidation works on a private copy, never the setup.
    (let ((draft (copy-tree (plist-get scope :draft) t)))
      (condition-case err
          (progn
            (unless (equal choice "Workspace coordination")
              (let ((pichat-job--draft draft))
                (pichat-job--invalidate-capture)
                (setq draft pichat-job--draft)))
            (let ((profile (plist-get draft :profile)))
              (pcase choice
                ("Preset"
                 (let* ((initial (symbol-name (plist-get profile :preset)))
                        (name (pichat--read-configuration-preset
                               "Preset: " initial (plist-get profile :tools))))
                   (unless (equal name initial)
                     (setf (plist-get profile :tools) nil))
                   (setf (plist-get profile :preset) (intern name))))
                ("Target"
                 (setf (plist-get profile :target)
                       (intern (completing-read "Target: " (pichat--launch-target-choices) nil t))))
                ("Workspace coordination"
                 (let ((access (completing-read
                                "Coordination (not tool permissions): "
                                '("May modify files — avoid overlapping changes"
                                  "Read-only — wait for stable files"
                                  "Read-only — accepts changing files") nil t)))
                   (setf (plist-get draft :access)
                         (cond ((string-prefix-p "May" access) "write")
                               ((string-match-p "stable" access) "read") (t "observe")))
                   (when-let* ((spec (plist-get draft :spec)))
                     (setf (plist-get (aref (plist-get spec :resources) 0) :access)
                           (plist-get draft :access)))))
                ((or "Model" "Tools")
                 (setf (plist-get scope :pending) t)
                 (if (equal choice "Model")
                     (pichat-job--settings-model scope draft)
                   (let* ((directory (plist-get draft :directory))
                          (target (plist-get profile :target))
                          (transport (pichat-transport-resolve
                                      directory (unless (eq target 'inferred) target))))
                     (setf (plist-get scope :tool-discovery)
                           (or (plist-get scope :tool-discovery)
                               (pichat-tool-discovery-draft-create)))
                     (pichat-tool-picker-open
                      (pichat-presets-resolve (plist-get profile :preset))
                      (plist-get profile :tools) directory transport pichat-pi-executable
                      (lambda (selection)
                        (unless (eq selection :cancel)
                          (setf (plist-get profile :tools) selection))
                        (pichat-job--settings-finish-picker
                         scope (unless (eq selection :cancel) draft)))
                      (let ((model (plist-get profile :model))) (and (stringp model) model))
                      (plist-get scope :tool-discovery)))))
                (_ (user-error "Unknown execution setting")))
              (unless (member choice '("Tools" "Model"))
                (setf (plist-get scope :draft) draft)
                (pichat-job--settings-show scope))))
        ((error quit)
         (setf (plist-get scope :pending) nil)
         (pichat-job--settings-show scope)
         (signal (car err) (cdr err)))))))

(defun pichat-job--settings-description (setting)
  "Describe SETTING inline, using captured values until explicitly edited."
  (let* ((draft (plist-get (transient-scope) :draft))
         (config (plist-get (plist-get draft :spec) :configuration))
         (profile (plist-get draft :profile))
         (value
          (pcase setting
            ('preset (if config (plist-get (plist-get config :preset) :name)
                       (plist-get profile :preset)))
            ('model (if config (plist-get config :model) (plist-get profile :model)))
            ('target (if config (plist-get (plist-get config :transport) :label)
                       (plist-get profile :target)))
            ('coordination
             (pcase (plist-get draft :access)
               ("read" "Read-only — wait for stable files")
               ("observe" "Read-only — accepts changing files")
               (_ "May modify files")))
            ('tools
             (if config
                 (let* ((preset (pichat-job-launch--unpreset (plist-get config :preset)))
                        (tools (pichat-job-launch--untools preset (plist-get config :tools))))
                   (not (equal tools (pichat-tool-selection-resolve preset))))
               (plist-get profile :tools))))))
    (if (eq setting 'tools)
        (if value (propertize "Tools" 'face 'transient-value) "Tools")
      (concat (capitalize (symbol-name setting)) ": "
              (propertize (if (and (eq setting 'model) (not (stringp value)))
                              "Choose…"
                            (format "%s" value))
                          'face 'transient-value)))))

(defun pichat-job--settings-continuation-p ()
  "Whether the settings menu belongs to a continuation."
  (plist-get (plist-get (transient-scope) :draft) :continue-of))

(transient-define-suffix pichat-job-settings-preset ()
  "Choose a preset." (interactive) (pichat-job--settings-edit "Preset"))
(transient-define-suffix pichat-job-settings-tools ()
  "Choose Tools." (interactive) (pichat-job--settings-edit "Tools"))
(transient-define-suffix pichat-job-settings-model ()
  "Choose a concrete model." (interactive) (pichat-job--settings-edit "Model"))
(transient-define-suffix pichat-job-settings-target ()
  "Choose a target." (interactive) (pichat-job--settings-edit "Target"))
(transient-define-suffix pichat-job-settings-coordination ()
  "Choose workspace coordination." (interactive) (pichat-job--settings-edit "Workspace coordination"))

(transient-define-suffix pichat-job-settings-apply ()
  "Apply staged settings to setup without saving or submitting work."
  (interactive)
  (let* ((scope (transient-scope)) (draft (plist-get scope :draft)))
    (unless (pichat-job--settings-current-p scope)
      (user-error "Job draft changed; reopen Execution settings"))
    (when (plist-get scope :pending) (user-error "Finish the pending picker first"))
    (with-current-buffer (plist-get scope :origin)
      (unless (equal draft pichat-job--draft)
        (setq pichat-job--draft (copy-tree draft t))
        (setf (plist-get pichat-job--draft :dirty) t))
      (setf (plist-get scope :closed) t)
      (pichat-job--render-setup))))

(transient-define-suffix pichat-job-settings-cancel ()
  "Discard all staged settings, leaving setup untouched."
  (interactive)
  (let ((scope (transient-scope)))
    (setf (plist-get scope :closed) t)))

(transient-define-prefix pichat-job-settings-menu ()
  "Stage job execution settings; applying never runs the job."
  [["Configuration"
    ("p" pichat-job-settings-preset
     :description (lambda () (pichat-job--settings-description 'preset)))
    ("m" pichat-job-settings-model
     :description (lambda () (pichat-job--settings-description 'model)))
    ("x" pichat-job-settings-tools
     :description (lambda () (pichat-job--settings-description 'tools)))
    ("t" pichat-job-settings-target
     :description (lambda () (pichat-job--settings-description 'target))
     :if-not pichat-job--settings-continuation-p)
    ("w" pichat-job-settings-coordination
     :description (lambda () (pichat-job--settings-description 'coordination))
     :if-not pichat-job--settings-continuation-p)]]
  [["Action"
    ("RET" "Apply" pichat-job-settings-apply)
    ("q" "Cancel" pichat-job-settings-cancel)]]
  [:hide (lambda () t) ("<return>" pichat-job-settings-apply)])

(defun pichat-job-execution-settings ()
  "Stage execution choices in a Transient; setup changes only on Apply."
  (interactive)
  (pichat-job--editable)
  (setq pichat-job--settings
        (list :origin (current-buffer) :pending nil :closed nil :tool-discovery nil
              :original (copy-tree pichat-job--draft t)
              :draft (copy-tree pichat-job--draft t)))
  (pichat-job--settings-show pichat-job--settings))

(defun pichat-job--after-job-title (id)
  "Return saved job ID's display title, including absent/None choices."
  (if (not id) "None"
    (if-let* ((job (seq-find (lambda (job) (equal (plist-get job :id) id))
                             (pichat-job-records (pichat-jobs--store) 'jobs))))
        (pichat-jobs--display (plist-get (plist-get job :spec) :title))
      "Unavailable job — choose another or None")))

(defun pichat-job-change-after-job ()
  "Select a saved after-run job, or None for this draft only."
  (interactive)
  (pichat-job--editable)
  (let* ((origin (current-buffer)) (draft pichat-job--draft)
         (snapshot (copy-tree draft t))
         (jobs (pichat-job-records (pichat-jobs--store) 'jobs))
         (index 0)
         (choices (cons '("None")
                        (mapcar (lambda (job)
                                  (cons (format "%s [%d]"
                                                (pichat-jobs--display
                                                 (plist-get (plist-get job :spec) :title))
                                                (cl-incf index))
                                        (plist-get job :id)))
                                (append jobs nil))))
         (default (car (rassoc (plist-get draft :after-job-id) choices)))
         (choice (completing-read
                  "After this run (receives bounded previous-run context): "
                  choices nil t nil nil default)))
    (unless (and (buffer-live-p origin)
                 (eq (current-buffer) origin) (eq pichat-job--draft draft)
                 (equal draft snapshot))
      (user-error "Job draft changed; reopen After this run"))
    (unless (equal (plist-get draft :after-job-id) (cdr (assoc choice choices)))
      (setf (plist-get pichat-job--draft :after-job-id) (cdr (assoc choice choices))
            (plist-get pichat-job--draft :dirty) t))
    (pichat-job--render-setup)))

(defun pichat-job--submission-spec ()
  "Return captured draft work; never launch, silently refresh or pick a model."
  (pichat-job--editable)
  (let* ((draft pichat-job--draft)
         (text (plist-get draft :instructions))
         (_ (unless (pichat-job--text-p text) (user-error "Enter job instructions first")))
         (title (or (and (pichat-job--text-p (plist-get draft :title)) (plist-get draft :title))
                    (truncate-string-to-width (car (split-string text "\n" t)) 60 nil nil "…"))))
    (unless (pichat-job--text-p text) (user-error "Enter job instructions first"))
    (let ((spec
           (if-let* ((captured (plist-get draft :spec)))
               (let ((spec (pichat-job--copy captured)))
                 (setf (plist-get spec :instructions) text (plist-get spec :title) title)
                 spec)
             (unless (stringp (plist-get (plist-get draft :profile) :model))
               (user-error "Choose Model in Execution settings before submission"))
             (pichat-job-launch-capture title text (plist-get draft :directory)
                                       (plist-get draft :profile) (plist-get draft :access)))))
      (setf (plist-get spec :after-job-id) (plist-get draft :after-job-id))
      spec)))

(defun pichat-job-run-once ()
  "Submit this draft once without saving/enabling any definition."
  (interactive)
  (let* ((owner pichat-jobs--owner)
         (spec (pichat-job--submission-spec))
         (origin (plist-get pichat-job--draft :continue-of))
         (capture (when origin
                    (let ((store (pichat-job-executor-store owner)))
                      (pichat-job-continuation-context store (pichat-job-record store 'runs origin)))))
         (_ (when-let* ((warning (plist-get capture :warning)))
              (unless (yes-or-no-p (concat warning ". Continue with incomplete previous run context? "))
                (user-error "Continuation not submitted"))))
         (id (pichat-job-executor-submit owner spec nil (plist-get pichat-job--draft :repeat-of)
                                         origin (plist-get pichat-job--draft :guidance) capture)))
    (setf (plist-get pichat-job--draft :dirty) nil)
    (pichat-view-return nil 'kill)
    (message "PiChat queued %s; inspect it in Jobs → Runs" id)))

(defun pichat-job-save-draft ()
  "Save this draft without submitting work or changing its existing schedule."
  (interactive)
  (pichat-job--editable)
  (when (plist-get pichat-job--draft :continue-of)
    (user-error "Continuation is one run; save original instructions from its run report"))
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
        (pichat-job-executor-schedule-refresh pichat-jobs--owner)
        (pichat-jobs--changed pichat-jobs--owner)
        (message "Saved job; nothing started")))))

(provide 'pichat-jobs)
;;; pichat-jobs.el ends here
