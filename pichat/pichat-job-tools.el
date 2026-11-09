;;; pichat-job-tools.el --- Saved-job schedule tools for the PiChat bridge -*- lexical-binding: t; -*-

;;; Commentary:
;; Loading this file registers the Jobs group of Emacs-defined tools.  That
;; makes them selectable in Tools; a runtime exposes them only when selected,
;; and the mutating tool keeps its own approval policy.
;;
;; The tools use the same Jobs owner as M-x pichat-jobs and start it when
;; needed, exactly as opening Jobs would.  Jobs itself loads on first use.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'pichat-tools)

(defvar pichat-jobs--executor)
(declare-function pichat-jobs--engine "pichat-jobs")
(declare-function pichat-job-executor-store "pichat-job-executor")
(declare-function pichat-job-executor-schedules "pichat-job-executor")
(declare-function pichat-job-executor-schedules-closed "pichat-job-executor")
(declare-function pichat-job-executor-schedule-error "pichat-job-executor")
(declare-function pichat-job-executor-schedule-change "pichat-job-executor")
(declare-function pichat-job-executor-schedule-enable "pichat-job-executor")
(declare-function pichat-job-records "pichat-job-core")
(declare-function pichat-job-schedule-instant-p "pichat-job-schedule")
(declare-function pichat-job-schedule-validate-rule "pichat-job-schedule")
(declare-function pichat-job-schedule-next "pichat-job-schedule")
(declare-function pichat-job-launch-prepare "pichat-job-launch")

(defconst pichat-job-tools-list-limit 50
  "Maximum saved jobs returned by one list call.")

(defconst pichat-job-tools-run-limit 10
  "Maximum recent run summaries returned by one inspect call.")

(defconst pichat-job-tools-text-limit 300
  "Maximum characters of one free-text field in a tool result.")

(defconst pichat-job-tools-min-interval 60
  "Minimum elapsed interval seconds accepted for saved-job timing.")

(defun pichat-job-tools--owner ()
  "Return the Jobs owner, starting it as opening M-x pichat-jobs would."
  (require 'pichat-jobs)
  (pichat-jobs--engine))

;;; Presentation

(defun pichat-job-tools--text (value &optional limit)
  "Return display-safe VALUE truncated to LIMIT characters."
  (when (stringp value)
    (truncate-string-to-width
     (replace-regexp-in-string "[[:cntrl:]]+" " " value)
     (or limit pichat-job-tools-text-limit) nil nil "…")))

(defun pichat-job-tools--instant (instant)
  "Describe Unix INSTANT with explicit UTC and host-local offset forms."
  (when instant
    (list :unix instant
          :utc (format-time-string "%Y-%m-%dT%H:%M:%SZ" (seconds-to-time instant) t)
          :local (format-time-string "%Y-%m-%d %H:%M:%S %Z (%z)" (seconds-to-time instant)))))

(defun pichat-job-tools--rule (rule)
  "Describe timing RULE, distinguishing elapsed intervals from wall clocks."
  (append
   (list :kind (plist-get rule :kind)
         :start (pichat-job-tools--instant (plist-get rule :start)))
   (if (equal (plist-get rule :kind) "interval")
       (list :interval_seconds (plist-get rule :seconds)
             :semantics (concat "Elapsed interval anchored at start; not wall-clock or "
                                "calendar recurrence, so local times shift across DST changes. "
                                "Missed ticks while Emacs is not running are not replayed."))
     (list :semantics "One occurrence at start while Emacs is running."))))

(defun pichat-job-tools--live-timer-p (owner id)
  "Return non-nil when OWNER holds a native timer for saved job ID."
  (and (not (pichat-job-executor-schedules-closed owner))
       (not (pichat-job-executor-schedule-error owner))
       (pichat-job-executor-schedules owner)
       (gethash id (pichat-job-executor-schedules owner))
       t))

(defun pichat-job-tools--scheduling (owner)
  "Describe the Jobs scheduling status of OWNER."
  (cond
   ((pichat-job-executor-schedule-error owner)
    (list :status "stopped" :detail (pichat-job-executor-schedule-error owner)))
   ((pichat-job-executor-schedules-closed owner)
    (list :status "stopped" :detail "Scheduling was stopped; restart Emacs to resume."))
   (t (list :status "running"))))

(defun pichat-job-tools--schedule (owner job)
  "Describe JOB's saved and live timing for OWNER."
  (when-let* ((schedule (plist-get job :schedule)))
    (let* ((enabled (eq (plist-get schedule :enabled) t))
           (live (pichat-job-tools--live-timer-p owner (plist-get job :id)))
           (last (plist-get schedule :last)))
      (append
       (list :rule (pichat-job-tools--rule (plist-get schedule :rule))
             :enabled (if enabled t :false)
             :live_timer (if live t :false)
             :next (if enabled (pichat-job-tools--instant (plist-get schedule :next)) :null))
       (when (and enabled (not live))
         (list :warning "Enabled, but no timer is running; see scheduling status."))
       (when last
         (list :last_occurrence
               (append (list :state (plist-get last :state)
                             :due (pichat-job-tools--instant (plist-get last :due)))
                       (when (plist-get last :run-id) (list :run_id (plist-get last :run-id)))
                       (when (plist-get last :reason)
                         (list :reason (pichat-job-tools--text (plist-get last :reason)))))))))))

(defun pichat-job-tools--run (run)
  "Return a bounded summary of RUN without evidence or configuration."
  (let ((trigger (plist-get run :trigger)))
    (append
     (list :id (plist-get run :id)
           :state (plist-get run :state)
           :result (or (plist-get run :result) :null)
           :trigger (or (plist-get trigger :kind) "manual")
           :created_at (plist-get run :created-at))
     (cl-loop for (key . label) in '((:started-at . :started_at) (:finished-at . :finished_at))
              when (plist-get run key) append (list label (plist-get run key)))
     (when (plist-get trigger :due)
       (list :due (pichat-job-tools--instant (plist-get trigger :due))))
     (when (plist-get run :reason)
       (list :reason (pichat-job-tools--text (plist-get run :reason)))))))

(defun pichat-job-tools--runs (store id limit)
  "Return up to LIMIT newest run summaries of saved job ID in STORE."
  (let ((runs (seq-filter (lambda (run) (equal id (plist-get run :job-id)))
                          (pichat-job-records store 'runs))))
    (list :total (length runs)
          :recent (vconcat (mapcar #'pichat-job-tools--run
                                   (seq-take (reverse (append runs nil)) limit))))))

(defun pichat-job-tools--job (owner store job &optional detail runs)
  "Summarize JOB from STORE for OWNER; DETAIL adds settings and RUNS."
  (let* ((spec (plist-get job :spec))
         (config (plist-get spec :configuration))
         (id (plist-get job :id)))
    (append
     (list :id id
           :title (pichat-job-tools--text (plist-get spec :title) 200)
           :directory (plist-get spec :directory)
           :schedule (or (pichat-job-tools--schedule owner job) :null))
     (when detail
       (list :instructions_preview (pichat-job-tools--text (plist-get spec :instructions))
             :model (or (plist-get config :model) :null)
             :preset (or (plist-get (plist-get config :preset) :name) :null)
             :updated_at (or (plist-get job :updated-at) :null)
             :runs (pichat-job-tools--runs store id runs))))))

(defun pichat-job-tools--json (value)
  "Encode result VALUE as compact JSON text."
  (json-serialize value :null-object :null :false-object :false))

;;; Validation

(defun pichat-job-tools--params (params allowed required)
  "Validate PARAMS object keys against ALLOWED and REQUIRED keywords.
Enforced here, not only by the advertised schema."
  (unless (and (listp params) (cl-evenp (length params))
               (cl-loop for (key) on params by #'cddr always (keywordp key)))
    (user-error "Arguments must be a JSON object"))
  (cl-loop for (key) on params by #'cddr
           unless (memq key allowed)
           do (user-error "Unknown argument: %s" (substring (symbol-name key) 1)))
  (dolist (key required)
    (unless (plist-member params key)
      (user-error "Missing required argument: %s" (substring (symbol-name key) 1))))
  params)

(defun pichat-job-tools--id-param (params)
  "Return a validated job_id from PARAMS."
  (let ((id (plist-get params :job_id)))
    (unless (and (stringp id) (string-match-p "\\`[A-Za-z0-9_-]\\{1,128\\}\\'" id))
      (user-error "job_id must be a saved job ID string"))
    id))

(defun pichat-job-tools--count-param (params key default maximum)
  "Return integer PARAMS KEY in [0, MAXIMUM], or DEFAULT when absent."
  (let ((value (if (plist-member params key) (plist-get params key) default)))
    (unless (and (integerp value) (<= 0 value maximum))
      (user-error "%s must be an integer from 0 to %d"
                  (substring (symbol-name key) 1) maximum))
    value))

(defun pichat-job-tools--find (store id)
  "Return saved job ID from STORE or fail with an actionable message."
  (or (seq-find (lambda (job) (equal id (plist-get job :id)))
                (pichat-job-records store 'jobs))
      (user-error "Unknown saved job ID: %s; list saved jobs again" id)))

(defun pichat-job-tools--rule-param (params)
  "Return the timing rule requested by PARAMS, or nil to remove timing."
  (let ((kind (plist-get params :kind))
        (start (plist-get params :start))
        (seconds (plist-get params :interval_seconds)))
    (pcase kind
      ("none"
       (when (or start seconds) (user-error "kind none takes no start or interval_seconds"))
       nil)
      ((or "once" "interval")
       (unless (and (integerp start) (pichat-job-schedule-instant-p start))
         (user-error "start must be a whole Unix time in seconds"))
       (if (equal kind "once")
           (progn
             (when seconds (user-error "kind once takes no interval_seconds"))
             (unless (> start (float-time))
               (user-error "Choose a future start for a one-time schedule"))
             (list :kind "once" :start start))
         (unless (and (integerp seconds) (>= seconds pichat-job-tools-min-interval))
           (user-error "interval_seconds must be a whole number of at least %d"
                       pichat-job-tools-min-interval))
         (pichat-job-schedule-validate-rule
          (list :kind "interval" :start start :seconds seconds))))
      (_ (user-error "kind must be once, interval or none")))))

(defun pichat-job-tools--enabled-param (params)
  "Return t, nil or `absent' for PARAMS's enabled flag."
  (if (not (plist-member params :enabled)) 'absent
    (pcase (plist-get params :enabled)
      ('t t) (:false nil)
      (_ (user-error "enabled must be true or false")))))

;;; Operations

(defun pichat-job-tools-list (params)
  "Return bounded saved-job summaries for PARAMS as JSON text."
  (pichat-job-tools--params params '(:limit) nil)
  (let* ((limit (pichat-job-tools--count-param params :limit 20 pichat-job-tools-list-limit))
         (owner (pichat-job-tools--owner))
         (store (pichat-job-executor-store owner))
         (jobs (append (pichat-job-records store 'jobs) nil)))
    (pichat-job-tools--json
     (list :scheduling (pichat-job-tools--scheduling owner)
           :total (length jobs)
           :truncated (if (> (length jobs) limit) t :false)
           :jobs (vconcat (mapcar (lambda (job) (pichat-job-tools--job owner store job))
                                  (seq-take jobs limit)))))))

(defun pichat-job-tools-inspect (params)
  "Return one saved job and bounded recent runs for PARAMS as JSON text."
  (pichat-job-tools--params params '(:job_id :runs) '(:job_id))
  (let* ((id (pichat-job-tools--id-param params))
         (runs (pichat-job-tools--count-param params :runs 5 pichat-job-tools-run-limit))
         (owner (pichat-job-tools--owner))
         (store (pichat-job-executor-store owner)))
    (pichat-job-tools--json
     (list :scheduling (pichat-job-tools--scheduling owner)
           :job (pichat-job-tools--job owner store (pichat-job-tools--find store id) t runs)))))

(defun pichat-job-tools-schedule (params)
  "Set, enable, disable or remove saved-job timing for PARAMS; return JSON.
With kind once/interval, save that timing and enable it unless enabled is
false.  With kind none, remove timing.  Without kind, only switch the
existing timing on or off.  Runs already queued or active are unaffected."
  (pichat-job-tools--params params '(:job_id :kind :start :interval_seconds :enabled)
                            '(:job_id))
  (let* ((id (pichat-job-tools--id-param params))
         (kind-p (plist-member params :kind))
         (rule (and kind-p (pichat-job-tools--rule-param params)))
         (enabled (pichat-job-tools--enabled-param params))
         (owner (pichat-job-tools--owner))
         (store (pichat-job-executor-store owner))
         (job (pichat-job-tools--find store id))
         (current (plist-get (plist-get job :schedule) :rule))
         changes)
    (cond
     ((and kind-p (null rule))
      (unless (eq enabled 'absent) (user-error "kind none takes no enabled flag"))
      (when current
        (pichat-job-executor-schedule-change owner id nil)
        (push "timing removed" changes)))
     (kind-p
      (unless (equal rule current)
        (pichat-job-executor-schedule-change owner id rule)
        (push "timing saved" changes))
      (when (eq enabled 'absent) (setq enabled t)))
     ((eq enabled 'absent)
      (user-error "Give kind to set timing, or enabled to switch existing timing"))
     ((null current)
      (user-error "Saved job %s has no timing; give kind and start" id)))
    (unless (eq enabled 'absent)
      (let* ((schedule (plist-get (pichat-job-tools--find store id) :schedule))
             (now-enabled (eq (plist-get schedule :enabled) t)))
        (cond
         ((and enabled (not now-enabled))
          (unless (pichat-job-schedule-next (plist-get schedule :rule) (float-time))
            (user-error "This one-time schedule is in the past; give a future start"))
          ;; Validate the saved job's configuration without launching it.
          (pichat-job-launch-prepare (plist-get (pichat-job-tools--find store id) :spec))
          (pichat-job-executor-schedule-enable owner id t)
          (push "enabled" changes))
         ((and (not enabled) now-enabled)
          (pichat-job-executor-schedule-enable owner id nil)
          (push "disabled" changes)))))
    (pichat-job-tools--json
     (list :changed (if changes t :false)
           :message (if changes
                        (concat (let ((text (string-join (nreverse changes) ", ")))
                                  (concat (upcase (substring text 0 1)) (substring text 1)))
                                ". "
                                "Queued or active runs are unaffected; Emacs must keep running "
                                "and missed occurrences are not replayed.")
                      "Nothing changed.")
           :scheduling (pichat-job-tools--scheduling owner)
           :job (pichat-job-tools--job owner store (pichat-job-tools--find store id))))))

;;; Tool definitions

(defvar pichat-job-tools--definitions nil
  "Registered Jobs tool definitions, in definition order.")

(defun pichat-job-tools-register ()
  "Register the Jobs tool group again, for example after a registry reset.
Registration lists the tools in the Tools picker; it exposes nothing."
  (interactive)
  (mapc #'pichat-tools-register pichat-job-tools--definitions)
  (mapcar #'pichat-tool-name pichat-job-tools--definitions))

(pichat-define-tool pichat_jobs_list
    (:group "Jobs" :label "List saved jobs"
     :description "List PiChat saved jobs with IDs, timing, enabled state and next occurrence."
     :instructions "Times are Unix seconds with UTC and host-local forms."
     :parameters (:type "object"
                  :properties (:limit (:type "integer" :minimum 0 :maximum 50))
                  :additionalProperties :json-false))
  (pichat-job-tools-list params))

(pichat-define-tool pichat_job_inspect
    (:group "Jobs" :label "Inspect saved job"
     :description "Inspect one PiChat saved job: timing, timer status and recent run summaries."
     :parameters (:type "object"
                  :properties (:job_id (:type "string")
                               :runs (:type "integer" :minimum 0 :maximum 10))
                  :required ["job_id"]
                  :additionalProperties :json-false))
  (pichat-job-tools-inspect params))

(pichat-define-tool pichat_job_schedule
    (:group "Jobs" :label "Schedule saved job" :mutating t
     :description "Schedule a saved job once or at an elapsed interval, remove its timing, or switch existing timing on or off."
     :instructions "kind once/interval saves timing and enables it unless enabled is false; kind none removes timing; omit kind and give enabled to switch existing timing. start is whole Unix seconds; tell the user the time with an explicit timezone. Intervals are elapsed seconds, not calendar recurrence. Does not cancel queued or active runs."
     :parameters (:type "object"
                  :properties (:job_id (:type "string")
                               :kind (:type "string" :enum ["once" "interval" "none"])
                               :start (:type "integer" :minimum 0)
                               :interval_seconds (:type "integer" :minimum 60)
                               :enabled (:type "boolean"))
                  :required ["job_id"]
                  :additionalProperties :json-false))
  (pichat-job-tools-schedule params))

(setq pichat-job-tools--definitions
      (mapcar (lambda (name) (gethash name pichat-tools-registry))
              '("pichat_jobs_list" "pichat_job_inspect" "pichat_job_schedule")))

(provide 'pichat-job-tools)
;;; pichat-job-tools.el ends here
