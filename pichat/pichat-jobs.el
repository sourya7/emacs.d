;;; pichat-jobs.el --- Job composition and inspection -*- lexical-binding: t; -*-

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
(defvar pichat-jobs--owned-store nil
  "Store retained before explicit executor initialization (for definition import).")
(defvar-local pichat-jobs--kind 'jobs)
(defvar-local pichat-jobs--filter nil)
(defvar-local pichat-jobs--owner nil)
(defvar-local pichat-jobs--detail nil)
(defvar-local pichat-jobs--section nil)
(defvar-local pichat-jobs--selection nil)
(defvar-local pichat-jobs--attention-only nil)
(defvar pichat-job--draft nil
  "Dynamically bound private draft for capture and synchronous field adapters.
Persistent draft ownership belongs to an explicit composer scope, not a buffer.")
(defvar-local pichat-job--instructions nil
  "Exact owner and draft snapshot of this multiline instructions editor.")
(defvar-local pichat-job--settings nil
  "Identity of this origin's most recent detached composer context.")
(defvar-local pichat-jobs--expanded nil)
(defvar-local pichat-jobs--response-source nil)
(defvar-local pichat-jobs--actions nil
  "Exact owning context of this buffer's most recent Actions menu.")

(defun pichat-jobs--owning-store ()
  "Return the shared store without executor initialization or reconciliation.
Retain an initially opened store so later explicit executor entry adopts that
same object, rather than reopening behind a definition import's back."
  (let ((store (or (and pichat-jobs--executor
                        (pichat-job-executor-store pichat-jobs--executor))
                   pichat-jobs--owned-store)))
    (unless store
      (setq store (pichat-job-store-open pichat-jobs-file)
            pichat-jobs--owned-store store))
    (unless (equal (expand-file-name pichat-jobs-file) (pichat-job-store-file store))
      (user-error "Jobs already owns another metadata file; restart before changing it"))
    store))

(defun pichat-jobs--engine ()
  "Return the owning executor, initializing/reconciling once on explicit entry."
  (let ((store (pichat-jobs--owning-store)))
    (unless pichat-jobs--executor
      (setq pichat-jobs--executor (pichat-job-executor-open store))))
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
    (cond ((equal state "scheduled")
           (format-time-string "Due %m-%d %H:%M" (seconds-to-time (plist-get (plist-get run :trigger) :due))))
          ((equal state "queued") "Waiting")
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
  (let ((left (get-text-property 0 'pichat-job-queued-at (aref (cadr a) 1)))
        (right (get-text-property 0 'pichat-job-queued-at (aref (cadr b) 1))))
    (cond ((null left) (and right t)) ((null right) nil)
          (t (time-less-p (date-to-time left) (date-to-time right))))))

(defun pichat-jobs-refresh ()
  "Redraw Jobs/Runs using cached records; never dispatch or contact Pi."
  (interactive)
  (let* ((store (pichat-jobs--store))
         (runs (pichat-job-records store 'runs))
         (windows (get-buffer-window-list (current-buffer) nil t))
         (positions (mapcar
                     (lambda (window)
                       (save-excursion
                         (goto-char (window-point window))
                         (list window (tabulated-list-get-id) (current-column))))
                     windows))
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
                                  (let ((queued (if (pichat-job-conversation-p run)
                                                    (plist-get run :queued-at) (plist-get run :created-at))))
                                    (propertize
                                     (if queued (pichat-jobs--local-time queued
                                                  (if narrow "%Y-%m-%d %H:%M" "%Y-%m-%d %H:%M:%S")) "—")
                                     'pichat-job-queued-at queued
                                     'help-echo (if queued (pichat-jobs--local-time queued) "Not queued"))))
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
    (tabulated-list-print t)
    ;; Printing remembers buffer point, but erasing the table also moves every
    ;; nonselected window's point marker.  In particular, M-x can trigger a
    ;; resize while the minibuffer is selected, before a row command runs.
    (dolist (position positions)
      (when (cadr position)
        (save-excursion
          (pichat-jobs--select (cadr position))
          (move-to-column (caddr position))
          (set-window-point (car position) (point)))))))

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
  (pichat-jobs--delete-job pichat-jobs--owner
                           (or (tabulated-list-get-id) (user-error "No job selected"))))

(defun pichat-jobs--delete-job (owner id)
  "Confirm deletion of exact saved job ID in OWNER, preserving run history."
  (let* ((store (pichat-job-executor-store owner))
         (job (pichat-job-record store 'jobs id))
         (title (pichat-jobs--display (plist-get (plist-get job :spec) :title))))
    (when (y-or-n-p (format "Delete job ‘%s’? " title))
      (unless (equal job (pichat-job-record store 'jobs id))
        (user-error "Job changed; review it again before deleting"))
      (pichat-job-delete store id)
      (pichat-job-executor-schedule-refresh owner)
      (pichat-jobs--changed owner)
      (message "Job deleted; run history preserved"))))

(defun pichat-jobs-delete-run ()
  "Confirm deletion of the exact run at point or in the current run report.
Only finished, unreferenced runs may be deleted.  Evidence and saved session
files are retained."
  (interactive)
  (let ((id (cond
             ((and (derived-mode-p 'pichat-jobs-mode) (eq pichat-jobs--kind 'runs))
              (or (tabulated-list-get-id) (user-error "No run selected")))
             ((and (derived-mode-p 'pichat-jobs-detail-mode)
                   (eq (car pichat-jobs--detail) 'runs) (null pichat-jobs--section))
              (cdr pichat-jobs--detail))
             (t (user-error "Select a run in Runs or open its report first")))))
    (pichat-jobs--delete-run pichat-jobs--owner id)))

(defun pichat-jobs--delete-run (owner id)
  "Confirm and delete exact run ID belonging to OWNER."
  (let ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (unless (equal (plist-get run :state) "finished")
      (user-error "Only finished runs can be deleted"))
    (when (y-or-n-p
           (format "Delete run ‘%s’ (%s, %s)? Evidence and saved session retained. "
                   (pichat-jobs--display (plist-get (plist-get run :spec) :title))
                   (pichat-jobs--local-time (plist-get run :created-at)) id))
      (pichat-job-executor-delete-run owner id)
      (message "Run deleted; evidence and saved session retained"))))

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
    (define-key map (kbd "i") #'pichat-job-definitions)
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
    (pichat-jobs--run-saved pichat-jobs--owner id)
    (message "PiChat job queued; your current chat is unchanged")))

(defun pichat-jobs--read-input (spec &optional initial)
  "Read run input for SPEC when it declares a prompt, else return nil.
INITIAL prefills the minibuffer.  Blank or oversized input is refused here,
before anything is queued; the store checks it again."
  (when-let* ((prompt (plist-get spec :input)))
    (let ((input (read-string (format "%s: " prompt) initial)))
      (when (string-blank-p input)
        (user-error "This job needs run input; nothing queued"))
      (when (> (length input) pichat-job-input-max-length)
        (user-error "Run input exceeds %d characters; nothing queued"
                    pichat-job-input-max-length))
      input)))

(defun pichat-jobs--run-saved (owner id)
  "Queue saved job ID in OWNER, asking for run input only when it declares one."
  (let* ((job (pichat-job-record (pichat-job-executor-store owner) 'jobs id))
         (input (pichat-jobs--read-input (plist-get job :spec))))
    (pichat-job-executor-submit-options owner (list :job-id id :input input))))

(defun pichat-jobs-edit ()
  "Edit the selected saved job; existing attempts remain immutable."
  (interactive)
  (unless (eq pichat-jobs--kind 'jobs) (user-error "Select a saved job to edit"))
  (let ((job (pichat-job-record (pichat-jobs--store) 'jobs
                               (or (tabulated-list-get-id) (user-error "No job selected")))))
    (pichat-job--edit-saved pichat-jobs--owner (plist-get job :id))))

(defun pichat-jobs--open-chat (owner id)
  "Open exact run ID's retained chat, never select an unrelated runtime."
  (let* ((execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (unless (and session (buffer-live-p (pichat-session-buffer session))
                 (or (not (pichat-job-execution-borrowed execution))
                     (pichat-job-conversation-source-p (pichat-job-execution-borrowed execution) t)))
      (user-error "Owning chat/source unavailable; this report cannot open another conversation"))
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
    (when (pichat-job-conversation-p run)
      (user-error "Reschedule from the chat with a fresh conversation capture"))
    (unless (equal (plist-get run :state) "finished")
      (user-error "Previous run must stop and uncertainty must be resolved first"))
    (pichat-job--compose owner 'repeat (plist-get run :spec) run)))

(defun pichat-jobs--continue (owner id)
  "Review a fresh background continuation of stopped OWNER/ID, without running."
  (let ((run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (unless (pichat-job-continuable-p run)
      (user-error "Continue requires interrupted work with uncertainty resolved"))
    (pichat-job--compose owner 'continue (plist-get run :spec) run)))

(defun pichat-jobs--diagnostics (owner id)
  "Show exact OWNER/ID's cached runtime diagnostics."
  (let* ((execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (if (and session
             (or (not (pichat-job-execution-borrowed execution))
                 (pichat-job-conversation-source-p (pichat-job-execution-borrowed execution) t)))
        (pichat-show-diagnostics session)
      (pichat-jobs--show-detail owner 'runs id 'diagnostics))))

(defun pichat-jobs--tools-summary (config)
  "Describe captured CONFIG's Tools without exposing internal Lisp."
  (let* ((preset (plist-get config :preset)) (tools (plist-get config :tools))
         (builtins (plist-get (or tools preset) (if tools :builtins :tools)))
         (extensions (plist-get (or tools preset) :extensions))
         (emacs (plist-get (or tools preset) (if tools :emacs :emacs-tools)))
         (mcp (plist-get tools :mcp)))
    (if (eq (plist-get preset :inherited) t) "Pi defaults"
      (format "%s%s%s%s%s"
              (if (or (null tools)
                      (and (equal builtins (plist-get preset :tools))
                           (equal extensions (plist-get preset :extensions))
                           (equal (append emacs nil)
                                  (append (plist-get preset :emacs-tools) nil))
                           (seq-empty-p mcp)))
                  "Preset defaults: " "Selected: ")
              (if (seq-empty-p builtins) "no built-ins" (string-join (append builtins nil) ", "))
              (if (seq-empty-p extensions) "" (format " · %d extension tools" (length extensions)))
              (if (seq-empty-p mcp) "" (format " · %d MCP tools" (length mcp)))
              (if (seq-empty-p emacs) "" (format " · %d Emacs-defined tools" (length emacs)))))))

(defun pichat-jobs--insert-settings (spec)
  "Insert compact captured SPEC settings."
  (let* ((config (plist-get spec :configuration))
         (preset (plist-get config :preset)))
    (insert (format "Model: %s\nPreset: %s · Tools: %s\n"
                    (plist-get config :model) (plist-get preset :name)
                    (if (eq (plist-get preset :inherited) t) "Pi defaults"
                      (pichat-jobs--tools-summary config))))))

(defun pichat-jobs--insert-run-times (record)
  "Insert RECORD's local timeline without inventing unknown finish times."
  (insert "Times (local):\n")
  (dolist (field (append (if (pichat-job-conversation-p record)
                            '((:created-at . "Scheduled") (:queued-at . "Queued"))
                          '((:created-at . "Queued")))
                        '((:started-at . "Started") (:finished-at . "Finished")
                          (:resolved-at . "Manually resolved"))))
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
owning view (default report).  Use the chat's input styling, measured at the
narrowest displaying window."
  (let* ((key (or key 'task))
         (refresh (or refresh #'pichat-jobs--render-detail))
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
         'keymap pichat-jobs--disclosure-map
         'pichat-job-disclosure t 'follow-link t
         'help-echo "TAB, RET or click to expand/collapse instructions"
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

(defun pichat-jobs--disclosure (key label &optional refresh)
  "Insert a disclosure for KEY with LABEL, redrawing with REFRESH or Jobs."
  (pichat-jobs--button
   (concat (if (member key pichat-jobs--expanded) "▾ " "▸ ") label)
   (lambda ()
     (setq pichat-jobs--expanded
           (if (member key pichat-jobs--expanded) (remove key pichat-jobs--expanded)
             (cons key pichat-jobs--expanded)))
     (funcall (or refresh #'pichat-jobs--render-detail)))
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
           (run (and id (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
           (label (format "After this run: %s · %s"
                          (if snapshot
                              (pichat-jobs--display (plist-get (plist-get snapshot :spec) :title))
                            (pichat-job--after-job-title (plist-get (plist-get record :spec) :after-job-id)))
                          (cond ((equal (plist-get dispatch :state) "interrupted")
                                 (plist-get dispatch :reason))
                                (run (pichat-jobs--status owner run))
                                ((equal (plist-get dispatch :state) "not-dispatched")
                                 (concat "Not dispatched — " (plist-get dispatch :reason)))
                                (t "Waiting for this run to stop")))))
      (when (and run (equal (plist-get run :state) "queued"))
        (let ((reason (plist-get (pichat-job-admission
                                 (pichat-job-executor-store owner) id
                                 pichat-jobs-max-concurrency) :reason)))
          (when reason (setq label (concat label " — " reason)))))
      (if id
          (pichat-jobs--button label (lambda () (pichat-jobs--show-detail owner 'runs id)))
        (insert label))
      (insert "\n"))))

(defun pichat-jobs--trigger-label (run)
  "Describe RUN's trigger without conflating timing and outcome."
  (pcase (plist-get (plist-get run :trigger) :kind)
    ("conversation-once" "This conversation · Once")
    ("lifecycle" "After run") ("once" "Once") ("interval" "Interval") (_ "Manual")))

(defun pichat-jobs--cancellable-p (owner record)
  "Whether RECORD in OWNER still offers cancellation."
  (let ((execution (gethash (plist-get record :id) (pichat-job-executor-contexts owner))))
    (and (not (member (plist-get record :state) '("finished" "uncertain")))
         (not (and execution (pichat-job-execution-cleanup execution))))))

(defun pichat-jobs--chat-p (owner record)
  "Whether RECORD has a usable owning chat in OWNER."
  (let* ((execution (gethash (plist-get record :id) (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (and session (buffer-live-p (pichat-chat-owned-buffer session))
         (or (not (pichat-job-execution-borrowed execution))
             (pichat-job-conversation-source-p (pichat-job-execution-borrowed execution) t))
         (or (not (plist-get record :evidence))
             (not (equal (plist-get record :state) "finished"))))))

(defun pichat-jobs--recheck-p (owner record)
  "Whether RECORD in OWNER offers independent remote exit inspection."
  (let* ((execution (gethash (plist-get record :id) (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution))))
    (and (equal (plist-get record :state) "uncertain") session
         (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh)
         (pichat-process-lifetime-supported-p (pichat-job-execution-process execution)))))

(defun pichat-jobs--action-items (owner kind record)
  "Return applicable grouped command entries for exact OWNER/KIND/RECORD.
Each entry is (GROUP KEY LABEL ACTION).  This is presentation, not admission."
  (let* ((store (pichat-job-executor-store owner))
         (job-id (plist-get record :job-id))
         (schedule (plist-get record :schedule))
         (rule (plist-get schedule :rule))
         (finished (equal (plist-get record :state) "finished"))
         (runs (and (eq kind 'jobs) (pichat-job-records store 'runs)))
         (unfinished
          (and (eq kind 'jobs)
               (seq-some (lambda (run)
                           (and (equal (plist-get record :id) (plist-get run :job-id))
                                (not (equal (plist-get run :state) "finished"))))
                         runs))))
    (if (eq kind 'jobs)
        (append
         (when (and (< (seq-count (lambda (run) (equal (plist-get run :state) "queued")) runs)
                       pichat-jobs-queue-limit)
                    (not unfinished))
           '((work "r" "Run job" run)))
         '((work "e" "Edit…" edit) (navigate "h" "Run history" history))
         (unless unfinished '((work "D" "Delete job…" delete-job)))
         (list (list 'schedule "s" (cond ((pichat-job-schedule-ui-missed-p schedule) "Reschedule…")
                                              (schedule "Change…") (t "Set schedule…")) 'schedule))
         (cond ((eq (plist-get schedule :enabled) t)
                '((schedule "d" "Disable" disable)))
               ((and schedule (or (equal (plist-get rule :kind) "interval")
                                  (> (plist-get rule :start) (float-time))))
                '((schedule "t" "Enable…" enable))))
         (when (and (pichat-job-schedule-run-now-p schedule)
                    (not (pichat-job-executor-schedules-closed owner))
                    (not (pichat-job-executor-schedule-error owner)))
           '((schedule "n" "Run now" run-now)))
         (when (pichat-job-schedule-ui-missed-p schedule)
           '((schedule "x" "Dismiss" dismiss)))
         '((inspect "I" "Inspect raw settings…" raw)))
      (append
       (when (and (pichat-job-conversation-p record)
                  (equal (plist-get record :state) "scheduled")
                  (not (pichat-job-executor-schedules-closed owner))
                  (not (pichat-job-executor-schedule-error owner))
                  (gethash (plist-get record :id) (pichat-job-executor-conversations owner)))
         '((work "n" "Run now" conversation-run-now)))
       (when (and (not (pichat-job-executor-schedules-closed owner))
                  (not (pichat-job-executor-schedule-error owner))
                  (pichat-jobs--reschedule-source owner record))
         '((work "s" "Reschedule…" conversation-reschedule)))
       (when (pichat-job-continuable-p record) '((work "c" "Continue work…" continue)))
       (when (and finished (not (pichat-job-conversation-p record))) '((work "r" "Repeat…" repeat)))
       (when finished '((work "D" "Delete run…" delete-run)))
       (when (and finished (not (pichat-job-conversation-p record)) (plist-get record :session-file))
         '((work "i" "Continue in chat…" open-saved)))
       (when (pichat-jobs--cancellable-p owner record) '((work "k" "Cancel run…" cancel)))
       (when (equal (plist-get record :state) "uncertain")
         '((work "R" "Release reservation…" release)))
       (unless (pichat-job-conversation-p record) '((work "s" "Save as job…" save)))
       (when (plist-get record :evidence)
         '((inspect "p" "Preview conversation" preview)))
       (when (pichat-jobs--chat-p owner record) '((inspect "o" "View chat" chat)))
       '((inspect "d" "Diagnostics" diagnostics) (inspect "I" "Inspect raw settings…" raw))
       (when (plist-get record :session-file)
         '((inspect "f" "Copy saved-session path" copy-path)))
       (when pichat-jobs--response-source
         '((inspect "w" "Copy response Markdown" copy) (inspect "v" "View response source" source)))
       (when (pichat-jobs--recheck-p owner record) '((inspect "x" "Recheck remote Pi exit" recheck)))
       (when job-id
         (append '((navigate "h" "Run history" history))
                 (when (seq-find (lambda (job) (equal (plist-get job :id) job-id))
                                 (pichat-job-records store 'jobs))
                   '((navigate "j" "Job definition" definition)))))))))

(defun pichat-jobs--actions-current (scope)
  "Return the current record only while SCOPE owns its exact report."
  (let ((origin (plist-get scope :origin)))
    (unless (and (buffer-live-p origin) (not (plist-get scope :closed))
                 (with-current-buffer origin
                   (and (eq scope pichat-jobs--actions)
                        (eq pichat-jobs--owner (plist-get scope :owner))
                        (equal pichat-jobs--detail (plist-get scope :detail))
                        (null pichat-jobs--section))))
      (user-error "Report changed; reopen Actions"))
    (let* ((detail (plist-get scope :detail))
           (record (condition-case nil
                       (pichat-job-record (pichat-job-executor-store (plist-get scope :owner))
                                          (car detail) (cdr detail))
                     (pichat-job-error nil))))
      (unless record (user-error "Job deleted; reopen Jobs"))
      (when (and (eq (car detail) 'jobs) (not (equal record (plist-get scope :original))))
        (user-error "Job changed; reopen Actions"))
      record)))

(defun pichat-jobs--action (scope action)
  "Invoke ACTION for revalidated SCOPE, never a selection in another buffer."
  (let* ((record (pichat-jobs--actions-current scope))
         (owner (plist-get scope :owner)) (kind (car (plist-get scope :detail)))
         (id (plist-get record :id)) (spec (plist-get record :spec)))
    (with-current-buffer (plist-get scope :origin)
      (unless (seq-some (lambda (item) (eq (nth 3 item) action))
                        (pichat-jobs--action-items owner kind record))
        (user-error "Action no longer available; reopen Actions"))
      (setf (plist-get scope :closed) t))
    ;; Navigation may select a new buffer; do not restore the old one over it.
    (set-buffer (plist-get scope :origin))
    (pcase action
      ('run (pichat-jobs--run-saved owner id))
      ('edit (pichat-job--edit-saved owner id))
      ('delete-job (pichat-jobs--delete-job owner id))
      ('history (pichat-jobs--show-history owner (if (eq kind 'jobs) id (plist-get record :job-id))))
      ('definition (pichat-jobs--show-detail owner 'jobs (plist-get record :job-id)))
      ('schedule (pichat-job-schedule-ui-open owner id))
      ('enable (pichat-job-schedule-ui--enable owner id record))
      ('disable (pichat-job-executor-schedule-enable owner id nil))
      ('run-now (pichat-job-executor-schedule-run-now owner id (plist-get record :schedule)))
      ('conversation-run-now
       (unless (equal record (plist-get scope :original))
         (user-error "Scheduled continuation changed; reopen Actions"))
       (pichat-job-executor-conversation-run-now owner id record))
      ('conversation-reschedule
       (unless (equal record (plist-get scope :original))
         (user-error "Scheduled continuation changed; reopen Actions"))
       (pichat-jobs--compose-reschedule owner record
                                        (pichat-jobs--reschedule-source owner record)))
      ('dismiss
       (pichat-job-schedule-dismiss (pichat-job-executor-store owner) id (plist-get record :schedule))
       (pichat-job-executor--changed owner))
      ('continue (pichat-jobs--continue owner id))
      ('repeat (pichat-jobs--repeat owner id))
      ('delete-run (pichat-jobs--delete-run owner id))
      ('open-saved (pichat-jobs--open-saved owner id))
      ('release (pichat-jobs--resolve owner id))
      ('save (pichat-job--compose owner 'save-as spec record))
      ('preview (pichat-jobs--preview owner id))
      ('chat (pichat-jobs--open-chat owner id))
      ('cancel (pichat-jobs--cancel owner id))
      ('diagnostics (pichat-jobs--diagnostics owner id))
      ('raw (pichat-jobs--show-detail owner kind id 'raw))
      ('copy (pichat-jobs-copy-response))
      ('copy-path (kill-new (plist-get record :session-file)))
      ('source (pichat-jobs-response-source))
      ('recheck
       (pichat-job-executor-recheck-exit
        owner id (lambda (success reason)
                   (message "%s" (if success "Pi exit confirmed; reservation remains held"
                                   (or reason "Exit not confirmed")))))))))

(defun pichat-jobs--action-suffixes (group)
  "Build this report's command suffixes for GROUP."
  (let* ((scope (transient-scope))
         (record (pichat-jobs--actions-current scope)))
    (with-current-buffer (plist-get scope :origin)
      (transient-parse-suffixes
       'pichat-jobs-actions-menu
       (cl-loop for (section key label action) in
                (pichat-jobs--action-items (plist-get scope :owner)
                                          (car (plist-get scope :detail)) record)
                when (eq section group)
                collect (let ((operation action))
                          (list key label (lambda () (interactive)
                                            (pichat-jobs--action scope operation)))))))))

(transient-define-prefix pichat-jobs-actions-menu ()
  "Commands for the exact inspected job or run; closing does nothing."
  [["Work" :class transient-column :setup-children (lambda (_) (pichat-jobs--action-suffixes 'work))]
   ["Inspect" :class transient-column :setup-children (lambda (_) (pichat-jobs--action-suffixes 'inspect))]
   ["Navigate" :class transient-column :setup-children (lambda (_) (pichat-jobs--action-suffixes 'navigate))]
   ["Schedule" :class transient-column :setup-children (lambda (_) (pichat-jobs--action-suffixes 'schedule))]]
  ["" ("q" "Close" transient-quit-one)])

(defun pichat-jobs-actions ()
  "Open commands for the exact inspected report, without executing work."
  (interactive)
  (unless (and pichat-jobs--detail (null pichat-jobs--section))
    (user-error "Open a job or run report first"))
  (let ((record (condition-case nil
                    (pichat-job-record (pichat-jobs--store)
                                       (car pichat-jobs--detail) (cdr pichat-jobs--detail))
                  (pichat-job-error nil))))
    (unless record (user-error "Job deleted; reopen Jobs"))
    (pichat-job--settings-stop)
    (setq pichat-jobs--actions (list :origin (current-buffer) :owner pichat-jobs--owner
                                   :detail pichat-jobs--detail :original record :closed nil))
    (transient-setup 'pichat-jobs-actions-menu nil nil :scope pichat-jobs--actions)))

(defun pichat-jobs--summary-time (record)
  "Return a truthful compact timestamp for RECORD's current state."
  (let ((finished (equal (plist-get record :state) "finished")))
    (concat
     (when (and finished (not (plist-get record :finished-at))) "Queued ")
     (pichat-jobs--local-time
      (if finished (or (plist-get record :finished-at) (plist-get record :created-at))
        (or (plist-get record :started-at) (plist-get record :created-at)))
      "%b %-d, %H:%M %Z"))))

(defun pichat-jobs--render-run (owner record)
  "Insert cached run RECORD's state and applicable actions for OWNER."
  (let* ((id (plist-get record :id)) (spec (plist-get record :spec))
         (execution (gethash id (pichat-job-executor-contexts owner)))
         (session (and execution (pichat-job-execution-session execution)))
         (state (plist-get record :state)))
    (insert (format "%s · %s\n\n"
                    (cond ((equal state "finished") (pichat-jobs--result record))
                          ((and (equal state "settling") execution
                                (pichat-job-execution-cleanup execution))
                           "Answer captured · Stopping runtime")
                          (t (pichat-jobs--state owner record)))
                    (pichat-jobs--summary-time record)))
    (when (pichat-job-conversation-p record)
      (let ((destination (plist-get record :destination)))
        (insert "This conversation · Pi session: " (plist-get destination :session-id)
                " · Runtime: " (plist-get destination :runtime-id) "\n"
                "Scheduled for: " (pichat-job-schedule-ui-time (plist-get (plist-get record :trigger) :due)) "\n")
        (when (equal state "scheduled")
          (insert "Emacs and this chat/runtime must remain alive. Sleep may delay delivery.\n"))
        (when-let* ((instant (plist-get (plist-get record :trigger) :dispatched-at)))
          (insert "Run now requested: " (pichat-job-schedule-ui-time instant) "\n"))
        (when (and (equal state "finished") (equal (plist-get record :result) "cancelled"))
          (insert "Not sent: " (or (plist-get record :reason) "Cancelled before dispatch") "\n"))
        (when-let* ((model (plist-get record :execution-model)))
          (insert "Verified dispatch model: " model "\n"))
        (insert "\n")))
    (when (and (not (pichat-job-conversation-p record))
               (plist-get (plist-get record :trigger) :dispatched-at))
      (let ((trigger (plist-get record :trigger)))
        (insert "Scheduled for: " (pichat-job-schedule-ui-time (plist-get trigger :due)) "\n"
                "Run now requested: " (pichat-job-schedule-ui-time (plist-get trigger :dispatched-at)) "\n\n")))
    (when (equal (plist-get (plist-get record :event) :completeness) "partial")
      (insert "Previous run context is partial or unavailable.\n"))

    (when (equal state "queued")
      (let ((decision (pichat-job-admission (pichat-job-executor-store owner) id pichat-jobs-max-concurrency)))
        (insert (format "Waiting reason: %s\n" (or (plist-get decision :reason) "Ready for dispatch")))
        (when-let* ((blocker (plist-get decision :blocking-run)))
          (pichat-jobs--button "Open blocking run"
                              (lambda () (pichat-jobs--show-detail owner 'runs blocker)))
          (insert "\n"))))
    (when session
      (when-let* ((attention (pichat-chat-pending-user-input-summary session)))
        (insert (format "Needs input: %s\n" attention))))
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
    (when (pichat-jobs--chat-p owner record)
      (pichat-jobs--button "View chat" (lambda () (pichat-jobs--open-chat owner id)))
      (insert "\n"))
    (when (member (plist-get (plist-get record :dispatch) :state) '("not-dispatched" "interrupted"))
      (pichat-jobs--insert-followup owner record))
    (when (equal state "uncertain") (insert "Reservation held · Inspect before releasing\n"))
    (when (pichat-jobs--cancellable-p owner record)
      (pichat-jobs--button "Cancel run…" (lambda () (pichat-jobs--cancel owner id)))
      (insert "\n"))
    (pichat-jobs--disclosure 'execution "Details")
    (when (member 'execution pichat-jobs--expanded)
      (insert "\n")
      (insert (format "Run: %s\n" id))
      (when-let* ((job-id (plist-get record :job-id))) (insert "Job: " job-id "\n"))
      (insert "Trigger: " (pichat-jobs--trigger-label record) "\n\n")
      (insert "Instructions:\n")
      (pichat-jobs--insert-instructions (plist-get spec :instructions))
      (when-let* ((input (plist-get record :input)))
        (insert "Run input:\n")
        (pichat-jobs--insert-instructions input 'input))
      (when (equal state "uncertain")
        (insert "State: Execution uncertain\nReservation: Held\n"))
      (when-let* ((event (plist-get record :event)))
        (let ((origin (plist-get event :run-id)))
          (insert "Triggered by: ")
          (pichat-jobs--button (pichat-jobs--display (plist-get event :title))
                              (lambda () (pichat-jobs--show-detail owner 'runs origin)))
          (insert "\n")))
      (unless (member (plist-get (plist-get record :dispatch) :state) '("not-dispatched" "interrupted"))
        (pichat-jobs--insert-followup owner record))
      (insert (format "Workspace: %s · Target: %s\n"
                      (plist-get spec :directory)
                      (plist-get (plist-get (plist-get spec :configuration) :transport) :label)))
      (when (pichat-job-conversation-p record)
        (insert "Scheduling-time settings (historical):\n")
        (unless (plist-get record :execution-model)
          (insert "Dispatch model: not recorded\n")))
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
      (insert "\n"))))

(defun pichat-jobs--render-job (owner record)
  "Insert instructions-first saved RECORD, compact context and disclosures."
  (let* ((id (plist-get record :id)) (spec (plist-get record :spec)))
    (pichat-jobs--insert-instructions (plist-get spec :instructions))
    (insert "Latest run: ")
    (if-let* ((latest (pichat-jobs--latest (pichat-jobs--store) id)))
        (let ((run-id (plist-get latest :id)))
          (pichat-jobs--button (format "%s · %s" (pichat-jobs--status owner latest)
                                      (pichat-jobs--summary-time latest))
                              (lambda () (pichat-jobs--show-detail owner 'runs run-id))))
      (insert "Never run"))
    (insert "\n")
    (pichat-job-schedule-ui-insert owner record)
    (when (pichat-job-source-diverged-p record)
      (insert (propertize "Saved edits differ from last import; reimport requires replacement confirmation.\n"
                          'face 'warning)))
    (insert (format "Workspace: %s · %s\n\n"
                    (plist-get spec :directory)
                    (plist-get (plist-get (plist-get spec :configuration) :transport) :label)))
    (pichat-jobs--disclosure 'definition "Details")
    (when (member 'definition pichat-jobs--expanded)
      (insert "\n")
      (when-let* ((source (plist-get record :source)))
        (insert "Imported from: " (plist-get source :file) "\n"))
      (pichat-jobs--insert-settings spec)
      (when-let* ((prompt (plist-get spec :input)))
        (insert "Run input: asked when run (" (pichat-jobs--display prompt) ")\n"))
      (when (plist-get spec :after-job-id)
        (insert (format "After this run: %s\n"
                        (pichat-job--after-job-title (plist-get spec :after-job-id)))))
      (pichat-job-schedule-ui-insert owner record t))))

(defun pichat-jobs--render-detail ()
  "Render exact cached details with progressive disclosure of captured inputs."
  (interactive)
  (let* ((owner pichat-jobs--owner)
         (kind (car pichat-jobs--detail)) (id (cdr pichat-jobs--detail))
         (record (seq-find (lambda (item) (equal (plist-get item :id) id))
                           (pichat-job-records (pichat-jobs--store) kind)))
         (spec (plist-get record :spec))
         (inhibit-read-only t)
         (position (pichat-jobs--reading-position (point)))
         (windows (mapcar (lambda (window)
                            (list window (pichat-jobs--reading-position (window-start window))
                                  (pichat-jobs--reading-position (window-point window))))
                          (get-buffer-window-list (current-buffer) nil t))))
    (erase-buffer)
    (cond
     ((null record)
      (setq pichat-jobs--response-source nil)
      (insert (if (eq kind 'jobs) "Job deleted. Run history is preserved.\n"
                "Run deleted. Evidence and saved session retained.\n")))
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
    (let ((job-id (if (eq kind 'jobs) id (plist-get record :job-id))))
      (setq header-line-format
            (concat (propertize
                     (replace-regexp-in-string "%" "%%" (pichat-jobs--display (plist-get spec :title)) t t)
                     'face 'bold)
                    (when (and (eq kind 'runs) record job-id (null pichat-jobs--section))
                      (propertize (format " (%s…)" (substring job-id 0 (min 12 (length job-id))))
                                  'face 'shadow)))))
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
    (define-key map (kbd "a") #'pichat-jobs-actions)
    (define-key map (kbd "w") #'pichat-jobs-copy-response)
    map))
(define-derived-mode pichat-jobs-detail-mode pichat-view-mode "PiChat Job Details"
  "Read-only cached job/run details with contextual commands.
\\<pichat-jobs-detail-mode-map>\\[pichat-jobs-actions] opens Actions.
With Evil Normal state, use g a."
  (setq-local truncate-lines nil truncate-partial-width-windows nil)
  (visual-line-mode 1)
  (pichat-response-view-install-faces))

(defun pichat-jobs-details ()
  "Open details of the exact selected definition or attempt without executing."
  (interactive)
  (pichat-jobs--show-detail pichat-jobs--owner pichat-jobs--kind
                            (or (tabulated-list-get-id) (user-error "No row selected"))))

;;; The composer owns a detached draft, never a live runtime.  Captures survive
;;; instruction edits.  Explicit execution changes re-resolve after review.

(defun pichat-job--close-context (scope)
  "Invalidate SCOPE before cancelling owned discovery and late returns."
  (setf (plist-get scope :closed) t)
  (when-let* ((discovery (plist-get scope :tool-discovery)))
    (pichat-tool-discovery-draft-reset discovery nil)))

(defun pichat-job--compose (owner kind &optional spec run capture)
  "Compose detached work for OWNER and KIND over the current view.
SPEC and RUN are captured values, never an instruction to dispatch.  The scope
object itself is the unique ownership token; no chat state is borrowed."
  (let* ((draft (pichat-job--make-draft spec nil default-directory))
         (scope (list :composer t :kind kind :origin (current-buffer)
                      :origin-owner pichat-jobs--owner :owner owner
                      :context (pichat-job--edit-context)
                      :draft draft :run (and run (pichat-job--copy run))
                      :menu 'pichat-job-edit-menu :closed nil :pending nil
                      :submitted-run-id nil :tool-discovery nil
                      :conversation capture :due nil)))
    (pcase kind
      ('repeat (setf (plist-get draft :repeat-of) (plist-get run :id)))
      ('continue (setf (plist-get draft :continue-of) (plist-get run :id)
                       (plist-get draft :guidance) "")))
    (setf (plist-get scope :draft) draft)
    (pichat-job--settings-start scope)
    scope))

(defun pichat-job--composer-edit-p ()
  "Whether this composer edits a saved definition."
  (plist-get (transient-scope) :job))

(defun pichat-job--composer-runnable-p ()
  "Whether this invocation offers independent execution."
  (not (memq (plist-get (transient-scope) :kind) '(edit save-as schedule))))

(defun pichat-job--composer-savable-p ()
  "Whether this composer offers saving a new reusable definition."
  (and (not (pichat-job--composer-edit-p))
       (not (pichat-job--composer-conversation-p))
       (not (pichat-job--settings-continuation-p))))

(defun pichat-job--composer-conversation-p ()
  "Whether this invocation schedules in its exact originating conversation."
  (eq (plist-get (transient-scope) :kind) 'schedule))

(defun pichat-job--composer-fixed-source-p ()
  "Whether workspace/name/target changes would change the captured source."
  (or (pichat-job--composer-conversation-p) (pichat-job--settings-continuation-p)))

(defun pichat-job--composer-check (scope)
  "Require current SCOPE with no pending picker or prior final action."
  (unless (pichat-job--settings-current-p scope)
    (user-error "Job context changed or closed; reopen the composer"))
  (when (plist-get scope :pending) (user-error "Finish the pending picker first")))

(defun pichat-job--composer-submit (scope save)
  "Save or submit SCOPE through existing capture/admission paths.
SAVE creates a definition only.  Failures retain a recoverable detached draft."
  (let ((token (list 'submission)))
    (condition-case err
        (progn
          (pichat-job--composer-check scope)
          (when (eq (plist-get scope :kind) 'schedule)
            (user-error "Use explicit Schedule for this conversation"))
          (when (plist-get scope :job) (user-error "Use Save in the saved-job editor"))
          (when (and (not save) (eq (plist-get scope :kind) 'save-as))
            (user-error "Save as job does not execute work"))
          (let* ((draft (plist-get scope :draft))
                 (owner (plist-get scope :owner))
                 (store (pichat-job-executor-store owner))
                 (continuation (plist-get draft :continue-of)) spec capture input id)
            (when (and save continuation)
              (user-error "Continuation is one run, not a reusable job"))
            (when (and save (not (pichat-job--text-p (plist-get draft :title))))
              (user-error "Review Name before saving a job"))
            (setf (plist-get scope :pending) token)
            (with-current-buffer (plist-get scope :origin)
              (let ((pichat-job--draft draft) (pichat-jobs--owner owner))
                (setq spec (pichat-job--submission-spec))))
            ;; Repeat and continuation reuse the earlier run's input.  Ask only
            ;; when there is none to reuse and the definition declares a prompt.
            (unless save
              (setq input (or (and (or continuation (plist-get draft :repeat-of))
                                   (plist-get spec :input)
                                   (plist-get (plist-get scope :run) :input))
                              (pichat-jobs--read-input spec))))
            (when continuation
              (setq capture (pichat-job-continuation-context
                             store (pichat-job-record store 'runs continuation)))
              (when-let* ((warning (plist-get capture :warning)))
                (unless (yes-or-no-p
                         (concat warning ". Continue with incomplete previous run context? "))
                  (user-error "Continuation not submitted"))))
            ;; Capture/confirmation may have processed asynchronous events.
            (unless (and (pichat-job--settings-current-p scope)
                         (eq (plist-get scope :pending) token))
              (user-error "Job context changed; reopen the composer"))
            (setq id
                  (if save (pichat-job-save store spec)
                    (pichat-job-executor-submit-options
                     owner (list :spec spec :repeat-of (plist-get draft :repeat-of)
                                 :continue-of continuation
                                 :guidance (plist-get draft :guidance)
                                 :capture capture :input input)
                     (lambda (accepted-id)
                       ;; Commit is final even if later refresh/dispatch fails.
                       (setf (plist-get scope :submitted-run-id) accepted-id)
                       (pichat-job--close-context scope)))))
            (pichat-job--close-context scope)
            (if save
                (progn
                  (pichat-jobs--changed owner)
                  (pichat-jobs--show-detail owner 'jobs id)
                  (message "Saved job; nothing started"))
              ;; There is no setup view to kill, and no worker chat to select.
              (pichat-view--focus-buffer (plist-get scope :origin))
              (message "PiChat queued %s; inspect it in Jobs → Runs" id))))
      ((error quit)
       (if (plist-get scope :closed)
           (when-let* ((id (plist-get scope :submitted-run-id)))
             (message "PiChat queued %s before error; inspect Jobs → Runs" id))
         (when (eq (plist-get scope :pending) token)
           (setf (plist-get scope :pending) nil))
         (pichat-job--settings-show scope))
       (signal (car err) (cdr err))))))

(transient-define-suffix pichat-job-composer-run ()
  "Submit independent work once, without saving a definition."
  (interactive) (pichat-job--composer-submit (transient-scope) nil))

(transient-define-suffix pichat-job-composer-save ()
  "Save a reviewed reusable definition without starting work."
  (interactive) (pichat-job--composer-submit (transient-scope) t))

(defvar-local pichat-job--inspection-scope nil)

(defun pichat-job-composer-inspection-return ()
  "Return from full-value inspection to its exact composer."
  (interactive)
  (let ((scope pichat-job--inspection-scope))
    (pichat-view-return (plist-get scope :origin) 'kill)
    (pichat-job--settings-show scope)))

(defvar pichat-job-composer-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'pichat-job-composer-inspection-return)
    map))

(define-derived-mode pichat-job-composer-review-mode pichat-view-mode "PiChat Job Review"
  "Inspect staged work in full; q returns to its exact composer."
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

(transient-define-suffix pichat-job-composer-inspect ()
  "Inspect full staged instructions and execution captures without resolving."
  (interactive)
  (let* ((scope (transient-scope)) (draft (plist-get scope :draft))
         (origin (pichat-view-capture-origin)) buffer)
    (pichat-job--composer-check scope)
    (setq buffer (generate-new-buffer "*PiChat Job Review*"))
    (with-current-buffer buffer
      (pichat-job-composer-review-mode)
      (setq pichat-job--inspection-scope scope)
      (let ((inhibit-read-only t))
        (insert (format "Name: %s\nWorkspace: %s\nAfter this run: %s\nRun input prompt: %s\n\nInstructions:\n"
                        (plist-get draft :title) (plist-get draft :directory)
                        (let ((pichat-jobs--owner (plist-get scope :owner)))
                          (pichat-job--after-job-title (plist-get draft :after-job-id)))
                        (or (plist-get draft :input) "None"))
                (plist-get draft :instructions) "\n\n")
        (when-let* ((input (and (plist-get draft :input)
                                (or (plist-get draft :repeat-of) (plist-get draft :continue-of))
                                (plist-get (plist-get scope :run) :input))))
          (insert "Run input (reused from the earlier run):\n" input "\n\n"))
        (when (plist-get draft :continue-of)
          (insert "Additional guidance:\n" (plist-get draft :guidance) "\n\n"))
        (when-let* ((run (and (plist-get draft :continue-of) (plist-get scope :run))))
          (insert "Previous run context (untrusted):\n"
                  (plist-get (pichat-job-continuation-context
                              (pichat-job-executor-store (plist-get scope :owner)) run)
                             :context)
                  "\n\n"))
        (when-let* ((capture (plist-get scope :conversation)))
          (insert "This conversation (provenance, not restart authorization):\n"
                  (pp-to-string (plist-get capture :destination)) "\n"))
        (insert (if (plist-get draft :spec) "Captured execution (may be sensitive):\n"
                  "Staged execution profile (not yet captured):\n")
                (pp-to-string (or (plist-get (plist-get draft :spec) :configuration)
                                  (plist-get draft :profile)))))
      (goto-char (point-min)))
    (pichat-view-display buffer origin 'kill)))

(defun pichat-job--composer-heading ()
  "Describe this invocation and context-specific warnings, not usage help."
  (let* ((scope (transient-scope)) (draft (plist-get scope :draft))
         (preset (plist-get (plist-get (plist-get draft :spec) :configuration) :preset)))
    (mapconcat
     (lambda (line)
       (with-temp-buffer
         (insert line)
         (let ((fill-column (max 30 (min 76 (- (frame-width) 4)))))
           (fill-region (point-min) (point-max)))
         (buffer-string)))
     (split-string
      (concat (pcase (plist-get scope :kind)
                ('edit "Edit job") ('repeat "Repeat run")
                ('continue "Continue work")
                ('save-as "Save as job")
                ('schedule "Schedule · This conversation")
                (_ "New job"))
              (when (and preset
                         (condition-case nil
                             (not (equal preset (pichat-job-launch--preset
                                                 (pichat-presets-resolve
                                                  (intern (plist-get preset :name))))))
                           (error t)))
                "\nCurrent preset differs or is unavailable; captured settings remain in use.")
              (when-let* ((run (and (plist-get draft :continue-of) (plist-get scope :run)))
                          (warning (plist-get
                                    (pichat-job-continuation-context
                                     (pichat-job-executor-store (plist-get scope :owner)) run)
                                    :warning)))
                (concat "\n" warning)))
      "\n")
     "\n")))

(defun pichat-job--make-draft (spec id directory)
  "Return detached editable work from SPEC/ID, defaulting to DIRECTORY."
  (list :spec (and spec (pichat-job--copy spec)) :id id
        :directory (or (plist-get spec :directory)
                       (pichat--project-root directory) directory)
        :instructions (or (plist-get spec :instructions) "")
        :title (or (plist-get spec :title) "")
        :after-job-id (plist-get spec :after-job-id)
        :input (plist-get spec :input)
        :profile (list :preset pichat-default-preset :target 'inferred
                       :model (or pichat-default-model 'prompt) :tools nil)
        :dirty nil))

;;;###autoload
(defun pichat-job-new ()
  "Compose one-off work or save a reusable job; no runtime is launched yet."
  (interactive)
  (pichat-job--compose (pichat-jobs--engine) 'new))

(defun pichat-job--continuation-notice-context ()
  "Return this chat's exact notice context, rejecting rebound/dead sources."
  (pcase-let ((`(,owner ,id ,capture) pichat-job-executor--continuation-notice))
    (unless (and (derived-mode-p 'pichat-chat-mode)
                 (eq (current-buffer) (plist-get capture :buffer))
                 (pichat-job-conversation-notice-p capture)
                 (pichat-job-record (pichat-job-executor-store owner) 'runs id))
      (user-error "Scheduled-continuation notice is stale; inspect Jobs Runs"))
    (list owner id capture)))

(defun pichat-job-review-continuation ()
  "Open the exact cancelled attempt named by this chat's current notice."
  (interactive)
  (pcase-let ((`(,owner ,id ,_capture) (pichat-job--continuation-notice-context)))
    (pichat-jobs--show-detail owner 'runs id)))

(defun pichat-jobs--reschedule-source (owner run)
  "Return RUN's retained source in OWNER for explicit renewed review.
Use only live captures or exact chat notices, never resolve stored runtime IDs.
Finished work without a not-sent notice is not a rescheduling authority.
Check availability only; capture and verify history when opening the composer."
  (when (pichat-job-conversation-p run)
    (let* ((id (plist-get run :id))
           (capture
            (cond
             ((member (plist-get run :state) '("scheduled" "queued"))
              (gethash id (pichat-job-executor-conversations owner)))
             ((and (equal (plist-get run :state) "finished")
                   (equal (plist-get run :result) "cancelled"))
              (seq-some
               (lambda (buffer)
                 (let ((notice (buffer-local-value 'pichat-job-executor--continuation-notice buffer)))
                   (when (and (eq owner (car notice)) (equal id (cadr notice))
                              (eq buffer (plist-get (nth 2 notice) :buffer)))
                     (nth 2 notice))))
               (buffer-list))))))
      (when (and capture
                 (equal (plist-get run :destination) (plist-get capture :destination))
                 (pichat-job-conversation-notice-p capture)
                 (let ((session (plist-get capture :session)))
                   (and (pichat-job-conversation-available-p session)
                        (pichat-job-conversation--model session)
                        (pichat-chat-canonical-entry-cache session))))
        capture))))

(defun pichat-jobs--compose-reschedule (owner run source)
  "Review RUN's prompt in a fresh capture of exact live SOURCE for OWNER.
Opening or cancelling this composer never changes the original attempt."
  (unless (and source (pichat-job-conversation-notice-p source))
    (user-error "Originating conversation unavailable; schedule from its chat"))
  (let* ((capture (pichat-job-conversation-capture (plist-get source :session)))
         (spec (pichat-job-conversation-spec capture (plist-get (plist-get run :spec) :instructions))))
    (pichat-job--compose owner 'schedule spec nil capture)))

(defun pichat-job-reschedule-continuation ()
  "Review a fresh capture and the cancelled prompt; never reschedule silently.
No time is selected.  Choose When and explicitly Schedule to authorize it."
  (interactive)
  (pcase-let* ((`(,owner ,id ,source) (pichat-job--continuation-notice-context))
               (run (pichat-job-record (pichat-job-executor-store owner) 'runs id)))
    (pichat-jobs--compose-reschedule owner run source)))

;;;###autoload
(defun pichat-job-schedule-continuation ()
  "Schedule a one-shot prompt in this exact live Pi conversation.
The shared composer starts with `continue' and no selected time.  Edit the
instructions and choose When, then explicitly Schedule.  Opening or
cancelling the composer sends nothing and preserves the chat draft.

Execution settings are inherited read-only; inspect full settings and
conversation provenance with the composer's inspection action.
Emacs and the captured chat/runtime must remain alive.  Submitted input
invalidates the attempt; renaming and model selection do not.  Execution uses
Pi's verified current model; no other conversation or runtime is substituted.
Sleep may delay delivery, and quota availability is not checked.
Review or cancel the pending attempt in Jobs Runs."
  (interactive)
  (unless (derived-mode-p 'pichat-chat-mode) (user-error "Invoke scheduling from its owning Pi chat"))
  (let* ((capture (pichat-job-conversation-capture pichat-chat-session))
         (spec (pichat-job-conversation-spec capture "continue")))
    (pichat-job--compose (pichat-jobs--engine) 'schedule spec nil capture)))

(transient-define-suffix pichat-job-composer-when ()
  "Choose a future local date/time using Org's calendar.
Enter just a time such as 15:30, or +1d 09:00 for tomorrow morning.
The default is the current selection or about five minutes ahead.
This stages the time only; Schedule remains a separate explicit action."
  (interactive)
  (let ((scope (transient-scope)) (token (list 'time)))
    (pichat-job--composer-check scope)
    (unless (plist-get scope :conversation) (user-error "Not an existing-conversation composer"))
    (setf (plist-get scope :pending) token)
    (unwind-protect
        (let ((due (pichat-job-schedule-ui-read-time (plist-get scope :due))))
          (unless (and (pichat-job--settings-current-p scope) (eq token (plist-get scope :pending)))
            (user-error "Conversation or composer changed; reopen scheduling"))
          (unless (> due (float-time)) (user-error "Choose a future time"))
          (setf (plist-get scope :due) due))
      (when (eq token (plist-get scope :pending)) (setf (plist-get scope :pending) nil))
      (pichat-job--settings-show scope))))

(transient-define-suffix pichat-job-composer-schedule ()
  "Authorize exactly this reviewed one-shot; save no reusable definition."
  (interactive)
  (let* ((scope (transient-scope)) (capture (plist-get scope :conversation))
         (owner (plist-get scope :owner)) (token (list 'schedule))
         (due (plist-get scope :due)) (draft (plist-get scope :draft))
         (failed (lambda (reason)
                   (if (plist-get scope :closed)
                       (message "Scheduled %s before error; inspect Jobs: %s" (plist-get scope :submitted-run-id) reason)
                     (when (eq token (plist-get scope :pending))
                       (setf (plist-get scope :pending) nil)
                       (pichat-job--settings-show scope)
                       (message "%s" reason))))))
    (pichat-job--composer-check scope)
    (unless (and capture (pichat-job-schedule-instant-p due) (> due (float-time)))
      (user-error "Choose a future When before Schedule"))
    (setf (plist-get scope :pending) token)
    (condition-case err
        (let ((pending (seq-find
                        (lambda (run)
                          (and (pichat-job-conversation-p run)
                               (equal (plist-get (plist-get run :destination) :runtime-id)
                                      (plist-get (plist-get capture :destination) :runtime-id))
                               (not (equal (plist-get run :state) "finished"))))
                        (pichat-job-records (pichat-job-executor-store owner) 'runs))))
          (when pending
            (unless (member (plist-get pending :state) '("scheduled" "queued"))
              (user-error "Active/uncertain work cannot be replaced; inspect Jobs"))
            (unless (yes-or-no-p "Replace the pending scheduled attempt in this runtime? ")
              (user-error "Pending attempt retained")))
          (pichat-job-executor-conversation-schedule
           owner capture (plist-get draft :instructions) due pending
           (lambda (id)
             (setf (plist-get scope :submitted-run-id) id)
             (pichat-job--close-context scope)
             (pichat-jobs--show-detail owner 'runs id)
             (message "Scheduled once; nothing sent. Inspect or cancel in Jobs → Runs"))
           failed
           (lambda () (and (pichat-job--settings-current-p scope) (eq token (plist-get scope :pending))))))
      ((error quit)
       (funcall failed (error-message-string err))
       (signal (car err) (cdr err))))))

(defun pichat-job--instructions-finish (apply-text)
  "Close this editor, applying plain text only to its unchanged owning draft."
  (unless pichat-job--instructions (user-error "No job instructions editor"))
  (let* ((context pichat-job--instructions) (editor (current-buffer))
         (origin (plist-get context :origin)) (scope (plist-get context :scope))
         (draft (plist-get context :draft))
         (valid (and (buffer-live-p origin)
                     (with-current-buffer origin
                       (and (eq pichat-jobs--owner (plist-get context :owner))
                            (pichat-job--settings-current-p scope)
                            (eq (plist-get scope :pending) editor)
                            (eq (plist-get scope :draft) draft)
                            (equal draft (plist-get context :snapshot)))))))
    (when (and apply-text (not valid))
      (user-error "Job draft changed or closed; reopen its instructions"))
    (when valid
      (let ((text (buffer-substring-no-properties (point-min) (point-max))))
        (with-current-buffer origin
          (when apply-text
            (let ((updated (copy-tree draft t)))
              (setf (plist-get updated (plist-get context :key)) text
                    (plist-get updated :dirty) t)
              (setf (plist-get scope :draft) updated)))
          (setf (plist-get scope :pending) nil))))
    (pichat-view-return origin 'kill)
    (when valid (pichat-job--settings-show scope))))

(defun pichat-job-instructions-apply ()
  "Apply this editor's text without saving a definition or submitting work."
  (interactive) (pichat-job--instructions-finish t))

(defun pichat-job-instructions-cancel ()
  "Discard this editor's text, retaining prior staged instructions."
  (interactive) (pichat-job--instructions-finish nil))

(defun pichat-job--instructions-killed ()
  "Release this editor's pending ownership without reopening any menu."
  (let ((scope (plist-get pichat-job--instructions :scope)))
    (when (eq (plist-get scope :pending) (current-buffer))
      (setf (plist-get scope :pending) nil))))

(defun pichat-job-edit-instructions (&optional scope)
  "Edit exact composer SCOPE's instructions; Apply never saves or runs."
  (interactive)
  (setq scope (or scope pichat-job--settings))
  (pichat-job--composer-check scope)
  (let* ((origin (plist-get scope :origin))
         (owner (buffer-local-value 'pichat-jobs--owner origin))
         (presentation (pichat-view-capture-origin))
         (draft (plist-get scope :draft))
         (key (if (plist-get draft :continue-of) :guidance :instructions))
         (context (list :origin origin :owner owner :scope scope :draft draft
                        :snapshot (copy-tree draft t) :key key)))
    (pop-to-buffer (generate-new-buffer "*PiChat Job Instructions*"))
    (text-mode)
    (pichat-view-display (current-buffer) presentation)
    (insert (or (plist-get draft key) ""))
    (setq pichat-job--instructions context)
    (setf (plist-get scope :pending) (current-buffer))
    (add-hook 'kill-buffer-hook #'pichat-job--instructions-killed nil t)
    (setq header-line-format "C-c C-c Apply to composer   C-c C-k Cancel")
    (let ((map (copy-keymap (current-local-map))))
      (define-key map (kbd "C-c C-c") #'pichat-job-instructions-apply)
      (define-key map (kbd "C-c C-k") #'pichat-job-instructions-cancel)
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
            (plist-get pichat-job--draft :spec) nil))))

(defun pichat-job--pick-project ()
  "Pick a workspace for the dynamically bound private draft."
  (when (plist-get pichat-job--draft :continue-of)
    (user-error "Continuation keeps the original workspace"))
  (let ((directory (read-directory-name "Job workspace: " (plist-get pichat-job--draft :directory))))
    (pichat-job--invalidate-capture)
    (setf (plist-get pichat-job--draft :directory) (file-name-as-directory (expand-file-name directory))
          (plist-get pichat-job--draft :dirty) t)))

(defun pichat-job--edit-context ()
  "Return the exact report or list-row context owned by a saved-job editor."
  (list pichat-jobs--detail pichat-jobs--section pichat-jobs--kind pichat-jobs--filter
        (when (derived-mode-p 'pichat-jobs-mode) (tabulated-list-get-id))
        (when (and (derived-mode-p 'pichat-chat-mode)
                   (fboundp 'pichat-chat--source-token))
          (list pichat-chat-session (pichat-chat--source-token)))))

(defun pichat-job--settings-current-p (scope)
  "Whether SCOPE still owns its exact live origin and captured records."
  (let ((origin (plist-get scope :origin)))
    (and (buffer-live-p origin)
         (not (plist-get scope :closed))
         (with-current-buffer origin
           (and (eq scope pichat-job--settings)
                (or (not (plist-member scope :owner))
                    (eq pichat-jobs--owner
                        (plist-get scope (if (plist-get scope :composer)
                                             :origin-owner :owner))))
                (or (not (plist-get scope :composer))
                    (equal (plist-get scope :context) (pichat-job--edit-context)))
                (or (not (plist-get scope :conversation))
                    (pichat-job-conversation-current-p (plist-get scope :conversation)))
                (or (not (plist-get scope :run))
                    (equal (plist-get scope :run)
                           (seq-find
                            (lambda (run) (equal (plist-get run :id)
                                                 (plist-get (plist-get scope :run) :id)))
                            (pichat-job-records
                             (pichat-job-executor-store (plist-get scope :owner)) 'runs))))
                (or (not (plist-get scope :job))
                    (and (equal (plist-get scope :context) (pichat-job--edit-context))
                         (equal (plist-get scope :job)
                                (seq-find (lambda (job)
                                            (equal (plist-get job :id)
                                                   (plist-get (plist-get scope :job) :id)))
                                          (pichat-job-records (pichat-jobs--store) 'jobs))))))))))

(defun pichat-job--settings-show (scope)
  "Redisplay the configuration menu for current SCOPE."
  (when (pichat-job--settings-current-p scope)
    (with-current-buffer (plist-get scope :origin)
      (transient-setup 'pichat-job-edit-menu
                       nil nil :scope scope))))

(defun pichat-job--settings-abandoned ()
  "Discard staged menus after explicitly quitting the Transient stack.
Do not discard model selections merely because their asynchronous picker exited
its prefix while waiting for the model-list process."
  (when (memq this-command '(transient-quit-one transient-quit-all transient-quit-seq))
    (pichat-job--settings-stop)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when pichat-jobs--actions
          (setf (plist-get pichat-jobs--actions :closed) t))))))

(add-hook 'transient-post-exit-hook #'pichat-job--settings-abandoned)

(defun pichat-job--settings-stop ()
  "Close old editing scopes without changing their owning drafts."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when pichat-job--settings
        (pichat-job--close-context pichat-job--settings)))))

(defun pichat-job--settings-origin-killed ()
  "Retire this origin's scope and any owned discovery."
  (when pichat-job--settings (pichat-job--close-context pichat-job--settings)))

(defun pichat-job--settings-start (scope)
  "Install SCOPE as the sole current editing menu, invalidating late returns."
  (pichat-job--settings-stop)
  (setq pichat-job--settings scope)
  (add-hook 'kill-buffer-hook #'pichat-job--settings-origin-killed nil t)
  (pichat-job--settings-show scope))

(defun pichat-job--settings-finish-picker (scope token draft)
  "Apply DRAFT only for SCOPE's exact pending TOKEN; nil retains prior choices."
  (when (and (eq (plist-get scope :pending) token)
             (pichat-job--settings-current-p scope))
    (setf (plist-get scope :pending) nil)
    (when draft (setf (plist-get scope :draft) draft))
    (pichat-job--settings-show scope)))

(defun pichat-job--settings-model (scope draft)
  "Choose a concrete model asynchronously for staged DRAFT in SCOPE."
  (let* ((token (plist-get scope :pending))
         (target (plist-get (plist-get draft :profile) :target))
         (process
          (pichat--list-models-async
           nil (lambda (models)
                 (when (and (eq (plist-get scope :pending) token)
                            (pichat-job--settings-current-p scope))
                   (condition-case err
                       (let ((model (pichat--read-model-table-choice "Job model: " models t)))
                         (setf (plist-get (plist-get draft :profile) :model) model)
                         (pichat-job--settings-finish-picker scope token draft))
                     ((error quit)
                      (pichat-job--settings-finish-picker scope token nil)
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
               (pichat-job--settings-finish-picker scope token nil)))))))))

(defun pichat-job--settings-edit (choice)
  "Edit CHOICE transactionally within the current settings menu."
  (let ((scope (transient-scope)))
    (unless (pichat-job--settings-current-p scope)
      (user-error "Job draft changed; reopen Execution settings"))
    (when (plist-get scope :pending) (user-error "Finish the pending picker first"))
    (when (plist-get scope :conversation) (user-error "This conversation's settings are inherited read-only"))
    (when (and (plist-get (plist-get scope :draft) :continue-of)
               (equal choice "Target"))
      (user-error "Continuation keeps the original target"))
    ;; Capture invalidation works on a private copy, never the origin.
    (let ((draft (copy-tree (plist-get scope :draft) t)))
      (setf (plist-get scope :pending) 'editing)
      (condition-case err
          (progn
            (unless (member choice '("Name" "Workspace" "After this run" "Run input"))
              (let ((pichat-job--draft draft))
                (pichat-job--invalidate-capture)
                (setq draft pichat-job--draft)))
            (unless (pichat-job--settings-current-p scope)
              (user-error "Job draft changed; reopen its editor"))
            (let ((profile (plist-get draft :profile)))
              (pcase choice
                ("Name" (setf (plist-get draft :title)
                              (read-string "Job name: " (plist-get draft :title))))
                ("Run input"
                 (let ((prompt (string-trim
                                (read-string "Run input prompt (empty for none): "
                                             (plist-get draft :input)))))
                   (unless (or (string-empty-p prompt) (pichat-job-input-prompt-p prompt))
                     (user-error "Run input prompt must be one line of at most %d characters"
                                 pichat-job-input-prompt-max-length))
                   (setf (plist-get draft :input) (unless (string-empty-p prompt) prompt)
                         (plist-get draft :dirty) t)))
                ((or "Workspace" "After this run")
                 (let ((pichat-job--draft draft)
                       (pichat-jobs--owner (plist-get scope :owner)))
                   (if (equal choice "Workspace") (pichat-job--pick-project)
                     (pichat-job--pick-after-job))
                   (setq draft pichat-job--draft)))
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
                ((or "Model" "Tools")
                 (setf (plist-get scope :pending) (list 'picker))
                 (if (equal choice "Model")
                     (pichat-job--settings-model scope draft)
                   (let* ((token (plist-get scope :pending))
                          (directory (plist-get draft :directory))
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
                         scope token (unless (eq selection :cancel) draft)))
                      (let ((model (plist-get profile :model))) (and (stringp model) model))
                      (plist-get scope :tool-discovery)))))
                (_ (user-error "Unknown execution setting")))
              (unless (member choice '("Tools" "Model"))
                (unless (pichat-job--settings-current-p scope)
                  (user-error "Job draft changed; reopen its editor"))
                (setf (plist-get scope :draft) draft
                      (plist-get scope :pending) nil)
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

(transient-define-suffix pichat-job-settings-cancel ()
  "Discard the detached composer draft without changing its origin."
  (interactive)
  (let ((scope (transient-scope)))
    (pichat-job--close-context scope)))

(defun pichat-job-execution-settings ()
  "Return to this origin's shared composer, which includes execution settings."
  (interactive)
  (pichat-job--composer-check pichat-job--settings)
  (pichat-job--settings-show pichat-job--settings))

(defun pichat-job--edit-saved (owner id)
  "Stage exact saved ID in OWNER over its existing report or selected row."
  (unless (and (eq owner pichat-jobs--owner)
               (or (and (derived-mode-p 'pichat-jobs-mode)
                        (eq pichat-jobs--kind 'jobs) (equal (tabulated-list-get-id) id))
                   (and (derived-mode-p 'pichat-jobs-detail-mode)
                        (equal pichat-jobs--detail (cons 'jobs id))
                        (null pichat-jobs--section))))
    (user-error "Job view changed; reopen Edit"))
  (let ((job (pichat-job-record (pichat-jobs--store) 'jobs id)))
    (pichat-job--settings-start
     (list :origin (current-buffer) :owner owner :job job
           :composer t :kind 'edit :origin-owner pichat-jobs--owner
           :context (pichat-job--edit-context) :menu 'pichat-job-edit-menu
           :draft (pichat-job--make-draft (plist-get job :spec) id default-directory)
           :closed nil :pending nil :submitted-run-id nil :tool-discovery nil))))

(defun pichat-job--edit-description (field)
  "Describe saved-job FIELD with one bounded inline value."
  (let* ((scope (transient-scope)) (draft (plist-get scope :draft))
         (value (pcase field
                  ('name (plist-get draft :title))
                  ('instructions (if (plist-get draft :continue-of)
                                     (plist-get draft :guidance)
                                   (plist-get draft :instructions)))
                  ('workspace (abbreviate-file-name (plist-get draft :directory)))
                  ('after (let ((pichat-jobs--owner (plist-get scope :owner)))
                            (pichat-job--after-job-title (plist-get draft :after-job-id))))
                  ('input (or (plist-get draft :input) "None"))))
         (label (pcase field ('after "After this run") ('input "Run input")
                       ('instructions (if (plist-get draft :continue-of) "Guidance" "Instructions"))
                       (_ (capitalize (symbol-name field))))))
    (concat label ": "
            (propertize (truncate-string-to-width (pichat-jobs--display value) 20 nil nil "…")
                        'face 'transient-value))))

(defun pichat-job--edit-execution-description (field)
  "Bound existing execution FIELD presentation for the compact editor."
  (truncate-string-to-width (pichat-job--settings-description field) 30 nil nil "…"))

(transient-define-suffix pichat-job-edit-name ()
  "Stage the job's name." (interactive) (pichat-job--settings-edit "Name"))
(transient-define-suffix pichat-job-edit-workspace ()
  "Stage a workspace change." (interactive) (pichat-job--settings-edit "Workspace"))
(transient-define-suffix pichat-job-edit-after ()
  "Stage the after-run default." (interactive) (pichat-job--settings-edit "After this run"))
(transient-define-suffix pichat-job-edit-input ()
  "Stage the run input prompt asked for each time the job runs.
Empty input removes it.  Jobs that take run input cannot be scheduled."
  (interactive) (pichat-job--settings-edit "Run input"))
(transient-define-suffix pichat-job-edit-text ()
  "Edit multiline instructions; Apply returns here without saving."
  (interactive)
  (let ((scope (transient-scope)))
    (pichat-job--composer-check scope)
    (pichat-job-edit-instructions scope)))

(transient-define-suffix pichat-job-edit-save ()
  "Save this exact definition once without running or changing timing."
  (interactive)
  (let ((scope (transient-scope)) (token (list 'save)))
    (condition-case err
        (progn
          (unless (and (plist-get scope :job) (pichat-job--settings-current-p scope))
            (user-error "Job changed or editor closed; reopen Edit"))
          (when (plist-get scope :pending) (user-error "Finish the pending picker first"))
          (let ((origin (plist-get scope :origin)) (owner (plist-get scope :owner))
                (id (plist-get (plist-get scope :job) :id)) spec)
            (setf (plist-get scope :pending) token)
            (with-current-buffer origin
              (let ((pichat-job--draft (plist-get scope :draft)))
                (unless (pichat-job--text-p (plist-get pichat-job--draft :title))
                  (user-error "Job name is required"))
                (setq spec (pichat-job--submission-spec)))
              ;; Capture or validation can process minibuffers/remote file events.
              (unless (pichat-job--settings-current-p scope)
                (user-error "Job changed; reopen Edit"))
              (unless (equal spec (plist-get (plist-get scope :job) :spec))
                (when (and (plist-get (plist-get scope :job) :source)
                           (not (yes-or-no-p
                                 "Save native edits without changing authored file? Reimport may replace instructions/settings. ")))
                  (user-error "Save cancelled; authored file and saved job unchanged"))
                (unless (pichat-job--settings-current-p scope)
                  (user-error "Job changed; reopen Edit"))
                (pichat-job-save (pichat-jobs--store) spec id))
              (pichat-job--close-context scope)
              (pichat-jobs--changed owner)
              (when (derived-mode-p 'pichat-jobs-mode) (pichat-jobs--select id)))
            (message "Saved job; nothing started")))
      ((error quit)
       (when (eq (plist-get scope :pending) token)
         (setf (plist-get scope :pending) nil))
       (pichat-job--settings-show scope)
       (signal (car err) (cdr err))))))

(transient-define-prefix pichat-job-edit-menu ()
  "Compose a job, repeat, continuation, or scheduled prompt.
Only explicit final actions save, run or schedule work.  Inspection shows
full instructions and captured execution settings.  Cancel discards the
composer draft, not the originating chat draft or attachments.

Repeat uses captured settings and may repeat changes or external actions;
previous effects are not undone.  Continue work starts a fresh Pi session
with captured previous-run context, not the original conversation.
Context-specific capture or incomplete-context warnings appear in the menu.

Schedule targets only the captured live conversation, with inherited,
read-only execution settings.  Emacs and that chat/runtime must stay alive;
intervening work invalidates the attempt.  Sleep may delay delivery, and
quota availability is not checked.  See `pichat-job-schedule-continuation'."
  [:description pichat-job--composer-heading
   ["Job"
    ("n" pichat-job-edit-name :description (lambda () (pichat-job--edit-description 'name))
     :if-not pichat-job--composer-fixed-source-p)
    ("i" pichat-job-edit-text :description (lambda () (pichat-job--edit-description 'instructions)))
    ("d" pichat-job-edit-workspace :description (lambda () (pichat-job--edit-description 'workspace))
     :if-not pichat-job--composer-fixed-source-p)
    ("a" pichat-job-edit-after :description (lambda () (pichat-job--edit-description 'after))
     :if-not pichat-job--composer-conversation-p)
    ("u" pichat-job-edit-input :description (lambda () (pichat-job--edit-description 'input))
     :if-not pichat-job--composer-fixed-source-p)]
   ["Timing" :if pichat-job--composer-conversation-p
    ("w" pichat-job-composer-when
     :description (lambda () (concat "When: " (if-let* ((due (plist-get (transient-scope) :due)))
                                                   (pichat-job-schedule-ui-time due) "Choose a time"))))]
   ["Execution" :if-not pichat-job--composer-conversation-p
    ("p" pichat-job-settings-preset
     :description (lambda () (pichat-job--edit-execution-description 'preset)))
    ("m" pichat-job-settings-model
     :description (lambda () (pichat-job--edit-execution-description 'model)))
    ("x" pichat-job-settings-tools
     :description (lambda () (pichat-job--edit-execution-description 'tools)))
    ("t" pichat-job-settings-target
     :description (lambda () (pichat-job--edit-execution-description 'target))
     :if-not pichat-job--settings-continuation-p)]]
  [["Inspect" ("v" "Details" pichat-job-composer-inspect)]
   ["Action"
    ("RET" "Save" pichat-job-edit-save :if pichat-job--composer-edit-p)
    ("r" "Run once" pichat-job-composer-run :if pichat-job--composer-runnable-p)
    ("s" "Save job" pichat-job-composer-save :if pichat-job--composer-savable-p)
    ("s" "Schedule" pichat-job-composer-schedule :if pichat-job--composer-conversation-p)
    ("q" "Cancel" pichat-job-settings-cancel)]]
  [:hide (lambda () t)
   ("<return>" pichat-job-edit-save :if pichat-job--composer-edit-p)])

(defun pichat-job--after-job-title (id)
  "Return saved job ID's display title, including absent/None choices."
  (if (not id) "None"
    (if-let* ((job (seq-find (lambda (job) (equal (plist-get job :id) id))
                             (pichat-job-records (pichat-jobs--store) 'jobs))))
        (pichat-jobs--display (plist-get (plist-get job :spec) :title))
      "Unavailable job — choose another or None")))

(defun pichat-job--pick-after-job ()
  "Pick an after-run job for the bound draft without presenting setup."
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
            (plist-get pichat-job--draft :dirty) t))))

(defun pichat-job--submission-spec ()
  "Capture the dynamically bound private draft; never launch or pick a model."
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
                                       (plist-get draft :profile)))))
      (when (or (plist-member spec :after-job-id) (plist-get draft :after-job-id))
        (setf (plist-get spec :after-job-id) (plist-get draft :after-job-id)))
      ;; Remove a cleared declaration rather than storing nil.
      (setq spec (if (plist-get draft :input)
                     (plist-put spec :input (plist-get draft :input))
                   (cl-loop for (key value) on spec by #'cddr
                            unless (eq key :input) append (list key value))))
      spec)))

(defun pichat-job-run-once ()
  "Submit this origin's composer draft once, without saving a definition."
  (interactive)
  (pichat-job--composer-submit pichat-job--settings nil))

(defun pichat-job-save-draft ()
  "Save this origin's reviewed new job without submitting work."
  (interactive)
  (pichat-job--composer-submit pichat-job--settings t))

(provide 'pichat-jobs)
;;; pichat-jobs.el ends here
