;;; pichat-test-job-tools.el --- Saved-job schedule bridge tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Contracts for the Jobs Emacs-defined tools: they share the M-x pichat-jobs
;; owner (starting it when needed), validate strictly and go through the
;; ordinary approval policy.  All stores are temporary.

;;; Code:

(require 'pichat-test-job-support)
(require 'pichat-job-tools)
(require 'pichat-tool-bridge)

(defconst pichat-test-job-tools-names
  '("pichat_job_inspect" "pichat_job_run_cancel" "pichat_job_run_inspect"
    "pichat_job_run_now" "pichat_job_schedule" "pichat_jobs_list")
  "The Jobs group, sorted.")

(defconst pichat-test-job-tools-mutating
  '("pichat_job_run_cancel" "pichat_job_run_now" "pichat_job_schedule")
  "Jobs tools that ask approval by default.")

(defmacro pichat-test-with-job-tools (&rest body)
  "Run BODY with the Jobs tools registered over the fixture's owned store."
  (declare (indent 0))
  `(pichat-test-with-job-executor ()
     (pichat-job-tools-register)
     (let ((pichat-jobs-file (pichat-job-store-file store))
           (pichat-jobs--executor executor)
           (pichat-jobs--owned-store nil))
       ,@body)))

(defun pichat-test-job-tool (name &optional params session)
  "Call registered Jobs tool NAME with PARAMS from optional calling SESSION.
Return (ERRORP . DECODED-OR-TEXT)."
  (let* ((result (pichat-tools-call (gethash name pichat-tools-registry) params session))
         (value (plist-get result :value)))
    (cons (plist-get result :is-error)
          (if (plist-get result :is-error) value
            (json-parse-string value :object-type 'plist :array-type 'list
                               :null-object nil :false-object :false)))))

(defun pichat-test-job-tool-ok (name &optional params session)
  "Return NAME's decoded successful result for PARAMS from optional SESSION."
  (let ((result (pichat-test-job-tool name params session)))
    (ert-info ((format "%S" (cdr result)))
      (should-not (car result)))
    (cdr result)))

(defun pichat-test-job-tool-error (name params pattern &optional session)
  "Assert NAME with PARAMS from optional SESSION fails matching PATTERN."
  (let ((result (pichat-test-job-tool name params session)))
    (should (car result))
    (ert-info ((cdr result))
      (should (string-match-p pattern (cdr result))))))

(defun pichat-test-job-tools-schedule (params)
  "Call pichat_job_schedule successfully with PARAMS."
  (pichat-test-job-tool-ok "pichat_job_schedule" params))

(defun pichat-test-job-tools-timer (executor id)
  "Return EXECUTOR's live timer entry for ID."
  (gethash id (pichat-job-executor-schedules executor)))

(ert-deftest pichat-job-tools-register-a-grouped-opt-in-jobs-group ()
  (pichat-test-with-clean-state
    (should-not (gethash "pichat_jobs_list" pichat-tools-registry))
    (should (equal pichat-test-job-tools-names (sort (pichat-job-tools-register) #'string<)))
    (let ((catalogue (pichat-tools-catalogue)))
      (dolist (name pichat-test-job-tools-names)
        (let ((tool (cl-find name catalogue :key (lambda (entry) (plist-get entry :name))
                             :test #'equal)))
          (should (equal "Jobs" (plist-get tool :group)))
          (should (eq (and (member name pichat-test-job-tools-mutating) t)
                      (plist-get tool :mutating))))))
    ;; Registration is not exposure.
    (should (equal "{\"protocolVersion\":1,\"tools\":[]}"
                   (pichat-tool-bridge-definitions-json
                    (pichat-session-make :cwd default-directory))))))

(ert-deftest pichat-job-tools-bridge-preserves-unicode-and-truncated-previews ()
  ;; json-serialize returns UTF-8 bytes.  A tool result must be decoded text
  ;; before it is embedded in the outer bridge JSON response.
  (pichat-test-with-job-tools
    (let* ((spec (pichat-test-job-spec project-dir))
           (title "Résumé — 日本語")
           (instructions (concat "Inspect café " (make-string 400 ?x)))
           (job (pichat-job-save store (plist-put (plist-put spec :title title)
                                                 :instructions instructions)))
           (session (apply #'pichat-test-select-emacs-tools
                           (pichat-session-make :cwd project-dir) pichat-test-job-tools-names)))
      (dolist (call (list (list :name "pichat_jobs_list" :params '(:limit 5))
                         (list :name "pichat_job_inspect" :params (list :job_id job))))
        (let* ((reply (json-parse-string
                       (pichat-tool-bridge-execute-json (json-serialize call) session)
                       :object-type 'plist :array-type 'list))
               (text (plist-get (car (plist-get reply :content)) :text))
               (data (json-parse-string text :object-type 'plist :array-type 'list))
               (entry (or (plist-get data :job) (car (plist-get data :jobs)))))
          (should-not (plist-get reply :isError))
          (should (equal title (plist-get entry :title)))
          (when-let* ((preview (plist-get entry :instructions_preview)))
            (should (string-prefix-p "Inspect café " preview))
            (should (string-suffix-p "…" preview))))))))

(ert-deftest pichat-job-tools-start-jobs-like-opening-it ()
  ;; With Jobs not yet opened in this Emacs, a tool starts the same owner
  ;; M-x pichat-jobs would, so enabled timing really runs.
  (pichat-test-with-job-executor ()
    (pichat-job-tools-register)
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (future (+ 3600 (floor (float-time))))
           (pichat-jobs-file (pichat-job-store-file store))
           (pichat-jobs--executor nil)
           (pichat-jobs--owned-store nil))
      (pichat-job-executor-schedule-change executor job
                                           (list :kind "interval" :start future :seconds 7200))
      (pichat-job-executor-schedule-enable executor job t)
      (pichat-job-executor-schedule-stop executor)
      (unwind-protect
          (let* ((listed (pichat-test-job-tool-ok "pichat_jobs_list" '(:limit 5)))
                 (entry (car (plist-get listed :jobs)))
                 (schedule (plist-get entry :schedule))
                 (rule (plist-get schedule :rule)))
            (should pichat-jobs--executor)
            (should (equal "running" (plist-get (plist-get listed :scheduling) :status)))
            (should (equal job (plist-get entry :id)))
            (should (eq t (plist-get schedule :enabled)))
            (should (eq t (plist-get schedule :live_timer)))
            (should (= future (plist-get (plist-get rule :start) :unix)))
            (should (string-match-p "Z\\'" (plist-get (plist-get rule :start) :utc)))
            (should (string-match-p "(\\(?:[-+][0-9]\\{4\\}\\))"
                                    (plist-get (plist-get schedule :next) :local)))
            (should (string-match-p "not wall-clock" (plist-get rule :semantics)))
            (let ((inspected (plist-get (pichat-test-job-tool-ok
                                         "pichat_job_inspect" (list :job_id job :runs 0))
                                        :job)))
              (should (equal "Review files" (plist-get inspected :title)))
              (should (= 0 (length (plist-get (plist-get inspected :runs) :recent))))
              (should-not (string-match-p ":command\\|--mode" (format "%S" inspected)))))
        (when pichat-jobs--executor
          (pichat-job-executor-schedule-stop pichat-jobs--executor))))))

(ert-deftest pichat-job-tools-schedule-sets-switches-and-removes-timing ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (start (+ 7200 (floor (float-time)))))
      ;; Setting timing enables it by default.
      (let* ((result (pichat-test-job-tools-schedule (list :job_id job :kind "once" :start start)))
             (schedule (plist-get (plist-get result :job) :schedule)))
        (should (eq t (plist-get result :changed)))
        (should (string-match-p "Timing saved, enabled" (plist-get result :message)))
        (should (eq t (plist-get schedule :enabled)))
        (should (eq t (plist-get schedule :live_timer)))
        (should (= start (plist-get (plist-get schedule :next) :unix))))
      (let ((timer (pichat-test-job-tools-timer executor job)))
        (should timer)
        ;; Repeating the same request changes nothing and keeps the timer.
        (should (eq :false (plist-get (pichat-test-job-tools-schedule
                                       (list :job_id job :kind "once" :start start))
                                      :changed)))
        (should (eq timer (pichat-test-job-tools-timer executor job))))
      ;; Switching off retires the timer but leaves queued work alone.
      (let ((run (pichat-job-enqueue store nil job)))
        (pichat-test-job-tools-schedule (list :job_id job :enabled :false))
        (should-not (pichat-test-job-tools-timer executor job))
        (should (equal "queued" (plist-get (pichat-job-record store 'runs run) :state)))
        (pichat-job-cancel-queued store run))
      (pichat-test-job-tools-schedule (list :job_id job :enabled t))
      (should (pichat-test-job-tools-timer executor job))
      ;; Timing can be saved without enabling it.
      (pichat-test-job-tools-schedule (list :job_id job :kind "interval" :start start
                                            :interval_seconds 3600 :enabled :false))
      (should-not (pichat-test-job-tools-timer executor job))
      (should (eq :false (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule) :enabled)))
      (should (string-match-p "Timing removed"
                              (plist-get (pichat-test-job-tools-schedule
                                          (list :job_id job :kind "none"))
                                         :message)))
      (should-not (plist-get (pichat-job-record store 'jobs job) :schedule)))))

(ert-deftest pichat-job-tools-accept-json-false-from-the-bridge ()
  ;; The bridge decodes JSON false as nil, not :false.
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (session (apply #'pichat-test-select-emacs-tools
                           (pichat-session-make :cwd project-dir) pichat-test-job-tools-names))
           (pichat-approval-policy-file (expand-file-name "approvals.el" project-dir))
           (request (json-serialize
                     (list :name "pichat_job_schedule"
                           :params (list :job_id job :kind "once"
                                         :start (+ 3600 (floor (float-time)))
                                         :enabled :false)))))
      (setq pichat-approval-rules '(("pichat_job_schedule" . allow)))
      (pichat-approval-save)
      (let ((reply (json-parse-string (pichat-tool-bridge-execute-json request session)
                                      :object-type 'plist :array-type 'list :false-object nil)))
        (ert-info ((format "%S" reply))
          (should-not (plist-get reply :isError))))
      (should (eq :false (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule)
                                    :enabled))))))

(ert-deftest pichat-job-tools-validate-arguments-in-emacs ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (future (+ 3600 (floor (float-time))))
           (bytes (pichat-job-store-bytes store)))
      (dolist (case
               `(((:job_id ,job :kind "once" :start ,future :extra 1) "Unknown argument: extra")
                 ((:kind "none") "Missing required argument: job_id")
                 ((:job_id 7 :kind "none") "job_id must be")
                 ((:job_id ,job) "Give kind")
                 ((:job_id ,job :enabled t) "has no timing")
                 ((:job_id ,job :kind "weekly") "kind must be")
                 ((:job_id ,job :kind "once" :start 100) "future start")
                 ((:job_id ,job :kind "once" :start ,(+ future 0.5)) "whole Unix time")
                 ((:job_id ,job :kind "once" :start ,future :interval_seconds 60)
                  "takes no interval_seconds")
                 ((:job_id ,job :kind "interval" :start ,future :interval_seconds 59) "at least 60")
                 ((:job_id ,job :kind "none" :start ,future) "takes no start")
                 ((:job_id ,job :kind "none" :enabled t) "takes no enabled")
                 ((:job_id ,job :kind "once" :start ,future :enabled "yes") "true or false")
                 ((:job_id "job-unknown" :kind "none") "Unknown saved job")))
        (pichat-test-job-tool-error "pichat_job_schedule" (car case) (cadr case)))
      (pichat-test-job-tool-error "pichat_jobs_list" '(:limit 51) "limit must be")
      (pichat-test-job-tool-error "pichat_job_inspect" (list :job_id job :runs -1) "runs must be")
      (should (equal bytes (pichat-job-store-bytes store))))))

(ert-deftest pichat-job-tools-enable-rejects-past-and-stopped-scheduling ()
  (pichat-test-with-job-tools
    (let ((job (pichat-job-save store (pichat-test-job-spec project-dir))))
      (pichat-job-schedule-set store job '(:kind "once" :start 100))
      (pichat-test-job-tool-error "pichat_job_schedule" (list :job_id job :enabled t) "in the past")
      (pichat-job-executor-schedule-change executor job (list :kind "once" :start (+ 3600 (floor (float-time)))))
      (setf (pichat-job-executor-schedule-error executor) "Scheduling stopped (test); restart Emacs")
      (let ((listed (pichat-test-job-tool-ok "pichat_jobs_list")))
        (should (equal "stopped" (plist-get (plist-get listed :scheduling) :status)))
        (should (string-match-p "restart Emacs" (plist-get (plist-get listed :scheduling) :detail))))
      (pichat-test-job-tool-error "pichat_job_schedule" (list :job_id job :enabled t) "Scheduling stopped")
      (should (eq :false (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule) :enabled))))))

(ert-deftest pichat-job-tools-schedule-errors-leave-timing-unchanged ()
  ;; Saving a rule disables it, so a check that failed after the save used to
  ;; leave the new timing stored and the old, working timing switched off.
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (input-job (pichat-job-save
                       store (plist-put (pichat-test-job-spec project-dir)
                                        :input "Plan and scope")))
           (soon (+ 3600 (floor (float-time))))
           (later (+ 7200 (floor (float-time))))
           (prepare-error nil))
      (pichat-job-executor-schedule-change executor job (list :kind "once" :start soon))
      (pichat-job-executor-schedule-enable executor job t)
      (cl-letf* ((prepare (symbol-function 'pichat-job-launch-prepare))
                 ((symbol-function 'pichat-job-launch-prepare)
                  (lambda (spec)
                    (if prepare-error (user-error "%s" prepare-error) (funcall prepare spec)))))
        (dolist (case
                 `(("Preset gone (test)" (:job_id ,job :kind "once" :start ,later)
                    "Preset gone")
                   ("Preset gone (test)" (:job_id ,job :kind "interval" :start ,later
                                          :interval_seconds 3600)
                    "Preset gone")
                   (nil (:job_id ,input-job :kind "once" :start ,later) "takes run input")))
          (setq prepare-error (car case))
          (let ((bytes (pichat-job-store-bytes store)))
            (pichat-test-job-tool-error "pichat_job_schedule" (nth 1 case) (nth 2 case))
            (should (equal bytes (pichat-job-store-bytes store))))))
      (should (equal soon (plist-get (plist-get (plist-get (pichat-job-record store 'jobs job)
                                                           :schedule)
                                                :rule)
                                     :start)))
      (should (pichat-test-job-tools-timer executor job))
      ;; Stopped scheduling refuses a new rule without saving it disabled.
      (pichat-job-executor-schedule-change executor job nil)
      (setf (pichat-job-executor-schedule-error executor) "Scheduling stopped (test); restart Emacs")
      (let ((bytes (pichat-job-store-bytes store)))
        (pichat-test-job-tool-error "pichat_job_schedule"
                                    (list :job_id job :kind "once" :start later)
                                    "Scheduling stopped")
        (should (equal bytes (pichat-job-store-bytes store))))
      (should-not (plist-get (pichat-job-record store 'jobs job) :schedule)))))

(ert-deftest pichat-job-tools-persistence-failure-claims-no-success ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (before (pichat-job-record store 'jobs job)))
      (cl-letf (((symbol-function 'pichat-job--commit)
                 (lambda (&rest _) (pichat-job--fail "Disk full (test)"))))
        (pichat-test-job-tool-error
         "pichat_job_schedule"
         (list :job_id job :kind "once" :start (+ 3600 (floor (float-time))))
         "Disk full"))
      (should (equal before (pichat-job-record store 'jobs job)))
      (should-not (pichat-test-job-tools-timer executor job)))))

(ert-deftest pichat-job-tools-schedule-asks-approval ()
  (pichat-test-with-job-tools
    (pichat-test-with-temp-dir dir
      (let* ((pichat-approval-policy-file (expand-file-name "approvals.el" dir))
             (session (apply #'pichat-test-select-emacs-tools
                             (pichat-session-make :cwd project-dir) pichat-test-job-tools-names))
             (job (pichat-job-save store (pichat-test-job-spec project-dir)))
             (params (list :job_id job :kind "once" :start (+ 3600 (floor (float-time)))))
             (request (json-serialize (list :name "pichat_job_schedule" :params params)))
             (call (lambda ()
                     (json-parse-string (pichat-tool-bridge-execute-json request session)
                                        :object-type 'plist :array-type 'list :false-object nil)))
             prompts)
        ;; Reads are immediate; scheduling asks by default and shows the request.
        (should-not (pichat-tool-bridge-approval-required-p
                     "{\"name\":\"pichat_jobs_list\",\"params\":{}}" session))
        (should (pichat-tool-bridge-approval-required-p request session))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _) (push prompt prompts) "Deny")))
          (should (string-match-p "Denied by user" (format "%S" (funcall call)))))
        (should (string-match-p "pichat_job_schedule.*once" (car prompts)))
        (should (string-match-p "\\`Run once at .*: “Review files” on .* in .* — Emacs tool" (car prompts)))
        (should-not (plist-get (pichat-job-record store 'jobs job) :schedule))
        ;; An allow policy runs it without prompting.
        (setq pichat-approval-rules '(("pichat_job_schedule" . allow)))
        (pichat-approval-save)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (ert-fail "Allowed policy must not prompt"))))
          (should-not (plist-get (funcall call) :isError)))
        (should (eq t (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule)
                                 :enabled)))))))

(defun pichat-test-job-tools-worker (executor store job)
  "Claim a run of saved JOB in STORE as a job worker; return (RUN-ID . SESSION).
The execution is registered with EXECUTOR but has no process."
  (let* ((run (pichat-job-enqueue store nil job))
         (claim (pichat-job-claim store run))
         (session (pichat-session-make :cwd default-directory)))
    (puthash run (pichat-job-execution--create
                  :executor executor :id run :token (plist-get claim :attempt)
                  :session session)
             (pichat-job-executor-contexts executor))
    (cons run session)))

(defun pichat-test-job-tools-finish (store run &optional evidence)
  "Finish claimed RUN in STORE as completed, with optional EVIDENCE plist."
  (let ((token (plist-get (pichat-job-record store 'runs run) :attempt)))
    (pichat-job-advance store run token "running" '(:runtime-id "pichat-runtime-gone"))
    (pichat-job-advance store run token "settling")
    (pichat-job-advance store run token "finished"
                        (list :result "completed" :safe-to-release t :synchronized t
                              :summary "Stored summary"
                              :evidence (and evidence (pichat-job-evidence-save store evidence))))))

(ert-deftest pichat-job-tools-run-now-submits-like-run-job ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (other (pichat-job-save store (pichat-test-job-spec project-dir)))
           (rule (list :kind "once" :start (+ 3600 (floor (float-time))))))
      (pichat-job-executor-schedule-change executor job rule)
      (let ((schedule (plist-get (pichat-job-record store 'jobs job) :schedule)))
        ;; Keep submitted runs queued: no runtime starts in unit tests.
        (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
          (let* ((first (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id job)))
                 (run (pichat-job-record store 'runs (plist-get first :run_id))))
            (should (equal "queued" (plist-get first :state)))
            (should (equal job (plist-get run :job-id)))
            (should (equal "manual" (plist-get (plist-get first :run) :trigger)))
            (should (string-match-p "Timing is unchanged" (plist-get first :message)))
            (should-not (plist-get first :waiting_for))
            ;; As in Jobs, one unfinished run per saved job; the error names it.
            (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job)
                                        (concat "unfinished run " (plist-get run :id)
                                                " (queued); inspect or cancel")))
          (let ((pichat-jobs-queue-limit 1))
            (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id other) "queue is full"))
          ;; A run waiting for a slot says why.
          (let* ((pichat-jobs-max-concurrency 1)
                 (active (pichat-job-enqueue store (pichat-test-job-spec project-dir))))
            (pichat-job-claim store active)
            (let ((waiting (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id other))))
              (should (equal "queued" (plist-get waiting :state)))
              (should (equal "Global concurrency limit" (plist-get waiting :waiting_for)))
              (should (string-match-p "\\`Queued" (plist-get waiting :message))))))
        (should (equal schedule (plist-get (pichat-job-record store 'jobs job) :schedule)))
        (pichat-test-job-tool-error "pichat_job_run_now" '(:job_id "job-unknown") "Unknown saved job")
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job :now t) "Unknown argument")))))

(ert-deftest pichat-job-tools-run-now-passes-declared-input ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                  :input "Plan and scope")))
           (plain (pichat-job-save store (pichat-test-job-spec project-dir)))
           (input "plan: example; scope: Phase 1\nfindings (round 1): none"))
      (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
        ;; Inspect shows whether input is needed.
        (should (equal "Plan and scope"
                       (plist-get (plist-get (pichat-test-job-tool-ok "pichat_job_inspect"
                                                                     (list :job_id job))
                                             :job)
                                  :input_prompt)))
        (should-not (plist-get (plist-get (pichat-test-job-tool-ok "pichat_job_inspect"
                                                                  (list :job_id plain))
                                          :job)
                               :input_prompt))
        ;; Required when declared, refused otherwise, bounded, and nothing is queued on error.
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job)
                                    "needs run input (Plan and scope)")
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job :input "  ")
                                    "needs run input")
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job :input 7)
                                    "input must be a string")
        (pichat-test-job-tool-error "pichat_job_run_now"
                                    (list :job_id job :input (make-string 4001 ?x))
                                    "exceeds 4000 characters")
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id plain :input "x")
                                    "does not take run input")
        (should (equal [] (pichat-job-records store 'runs)))
        (let* ((result (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id job :input input)))
               (run (pichat-job-record store 'runs (plist-get result :run_id))))
          (should (equal input (plist-get run :input)))
          (should (string-suffix-p input (pichat-job-prompt run)))
          (should (equal input (plist-get (pichat-test-job-tool-ok "pichat_job_run_inspect"
                                                                  (list :run_id (plist-get run :id)))
                                          :input))))
        (let ((result (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id plain))))
          (should-not (plist-member (pichat-test-job-tool-ok "pichat_job_run_inspect"
                                                            (list :run_id (plist-get result :run_id)))
                                    :input))))
      ;; The approval prompt shows the input's first line.
      (let ((tool (gethash "pichat_job_run_now" pichat-tools-registry)))
        (should (string-match-p "“Review files” .* with input “plan: example; scope: Phase 1” (first line)\\'"
                                (pichat-tools-approval-summary tool (list :job_id job :input input))))
        (should (string-match-p "with input “one line”\\'"
                                (pichat-tools-approval-summary tool (list :job_id job :input "one line"))))
        (should-not (string-match-p "with input"
                                    (pichat-tools-approval-summary tool (list :job_id plain))))))))

(ert-deftest pichat-job-tools-run-now-from-a-job-run-continues-its-chain ()
  (pichat-test-with-job-tools
    (let* ((reviewer (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                       :title "Reviewer")))
           (worker (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                     :after-job-id reviewer)))
           (caller (pichat-test-job-tools-worker executor store reviewer))
           (run (car caller)) (session (cdr caller)))
      (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
        (let* ((result (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id worker) session))
               (started (pichat-job-record store 'runs (plist-get result :run_id))))
          (should (equal run (plist-get (plist-get started :trigger) :requested-by)))
          ;; The started run captures the worker's after-run default again.
          (should (equal reviewer (plist-get (plist-get started :after-job) :job-id)))
          (let ((inspect (pichat-test-job-tool-ok "pichat_job_run_inspect"
                                                  (list :run_id (plist-get started :id)))))
            (should (equal run (plist-get inspect :requested_by)))
            ;; Rounds count restarts of the chain's first job (here the
            ;; reviewer), so starting another job keeps round 1.
            (should (= 1 (plist-get inspect :round))))
          (let ((inspect (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id run))))
            (should-not (plist-member inspect :requested_by))
            (should (= 1 (plist-get inspect :round))))
          ;; A busy worker is refused, naming the blocking run.
          (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id worker)
                                      (concat "unfinished run " (plist-get started :id))
                                      session))
        ;; A chat that is not a job run records no requester.
        (let ((plain (pichat-job-save store (pichat-test-job-spec project-dir))))
          (should-not (plist-get (plist-get (pichat-job-record
                                             store 'runs
                                             (plist-get (pichat-test-job-tool-ok
                                                         "pichat_job_run_now" (list :job_id plain))
                                                        :run_id))
                                            :trigger)
                                 :requested-by)))))))

(ert-deftest pichat-job-tools-chain-limit-refuses-only-tool-started-runs ()
  (pichat-test-with-job-tools
    (let* ((pichat-jobs-max-chain-runs 3)
           (worker (pichat-job-save store (pichat-test-job-spec project-dir)))
           (reviewer (pichat-job-save store (pichat-test-job-spec project-dir)))
           (first (car (pichat-test-job-tools-worker executor store worker))))
      (pichat-test-job-tools-finish store first)
      (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
        ;; Two runs in the chain: the caller may start a third.
        (let* ((r1 (pichat-job-enqueue-options store (list :job-id reviewer :requested-by first)))
               (token (plist-get (pichat-job-claim store r1) :attempt))
               (session (pichat-session-make :cwd project-dir)))
          (puthash r1 (pichat-job-execution--create :executor executor :id r1 :token token
                                                    :session session)
                   (pichat-job-executor-contexts executor))
          (let ((w2 (plist-get (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id worker)
                                                        session)
                               :run_id)))
            (pichat-job-cancel-queued store w2)
            ;; Three runs now: the next tool request is refused, naming the chain.
            (let ((before (length (pichat-job-records store 'runs))))
              (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id worker)
                                          (concat "Run chain of " first " already has 3 runs")
                                          session)
              (should (= before (length (pichat-job-records store 'runs)))))
            ;; Runs started from Jobs are never refused by the limit.
            (let ((repeat (pichat-job-executor-submit-options executor (list :repeat-of w2))))
              (should (= 4 (length (plist-get (pichat-job-chain store repeat) :members)))))))))))

(ert-deftest pichat-job-tools-run-now-blocked-by-uncertain-run-points-to-the-user ()
  ;; An uncertain run cannot be cancelled, so the error must not suggest it.
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (run (pichat-job-enqueue store nil job))
           (token (plist-get (pichat-job-claim store run) :attempt)))
      (pichat-job-advance store run token "running" '(:runtime-id "pichat-runtime-gone"))
      (pichat-job-advance store run token "uncertain" '(:reason "Process lost"))
      (let ((result (pichat-test-job-tool "pichat_job_run_now" (list :job_id job))))
        (should (car result))
        (ert-info ((cdr result))
          (should (string-match-p (concat "unfinished run " run " (uncertain)")
                                  (cdr result)))
          (should (string-match-p "only the user can release it in Jobs" (cdr result)))
          (should-not (string-match-p "cancel" (cdr result))))))))

(ert-deftest pichat-job-tools-cancel-pending-and-active-runs ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (queued (pichat-job-enqueue store nil job))
           (result (pichat-test-job-tool-ok "pichat_job_run_cancel" (list :run_id queued))))
      (should (equal "finished" (plist-get result :state)))
      (should (equal "cancelled" (plist-get result :result)))
      (should (equal "Cancelled." (plist-get result :message)))
      (pichat-test-job-tool-error "pichat_job_run_cancel" (list :run_id queued) "not cancellable")
      (pichat-test-job-tool-error "pichat_job_run_cancel" '(:run_id "run-unknown") "Unknown job run")))
  ;; An active run is asked to abort; the result does not claim it stopped.
  (pichat-test-with-owned-job
    (pichat-job-tools-register)
    (let ((pichat-jobs-file (pichat-job-store-file store))
          (pichat-jobs--executor executor)
          (pichat-jobs--owned-store nil)
          calls)
      (setf (pichat-job-execution-submitted execution) t)
      (pichat-job-executor--advance execution "running")
      (cl-letf (((symbol-function 'pichat-job-executor--call)
                 (lambda (_execution type &rest _) (push type calls))))
        (let ((result (pichat-test-job-tool-ok "pichat_job_run_cancel" (list :run_id id))))
          (should (equal '("abort") calls))
          (should (equal "running" (plist-get result :state)))
          (should (eq nil (plist-get result :result)))
          ;; Once the prompt was sent, a cancelled run ends uncertain, holding
          ;; its slot until the user releases it; the result says so.
          (should (string-match-p "\\`Abort requested\\..*becomes uncertain.*releases it in Jobs"
                                  (plist-get result :message))))))))

(ert-deftest pichat-job-tools-a-job-run-cannot-start-or-cancel-itself ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (other (pichat-job-save store (pichat-test-job-spec project-dir)))
           (worker (pichat-test-job-tools-worker executor store job))
           (run (car worker))
           (session (cdr worker)))
      (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id job)
                                    "this runtime's own run" session)
        (pichat-test-job-tool-error "pichat_job_run_cancel" (list :run_id run)
                                    "cannot cancel itself" session)
        (should (= 1 (length (pichat-job-records store 'runs))))
        (should (equal "starting" (plist-get (pichat-job-record store 'runs run) :state)))
        ;; The caller may still start other saved jobs.
        (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id other) session)))))

(ert-deftest pichat-job-tools-run-inspect-reads-results-without-the-chat ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (long (concat "# Report\n\n" (make-string 5000 ?x)))
           (finished (car (pichat-test-job-tools-worker executor store job)))
           fallback queued)
      (pichat-test-job-tools-finish store finished (list :version 1 :response long :transcript "t"))
      (setq fallback (car (pichat-test-job-tools-worker executor store job)))
      (pichat-test-job-tools-finish store fallback)
      (setq queued (pichat-job-enqueue store nil job))
      ;; Finished: final response from captured evidence, bounded; no chat needed.
      (let ((result (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id finished))))
        (should (equal "finished" (plist-get (plist-get result :run) :state)))
        (should (equal "completed" (plist-get (plist-get result :run) :result)))
        (should (equal job (plist-get result :job_id)))
        (should (equal "Review files" (plist-get result :title)))
        (should (string-prefix-p "# Report\n\nxxx" (plist-get result :response)))
        (should (= pichat-job-tools-response-limit (length (plist-get result :response))))
        (should (eq t (plist-get result :response_truncated)))
        (should (equal "captured evidence" (plist-get result :response_source)))
        ;; The runtime is gone, so no runtime_id is offered.
        (should-not (plist-member result :runtime_id))
        (should-not (string-match-p "transcript\\|entries" (format "%S" result))))
      ;; Without evidence the stored summary is used and labelled.
      (let ((result (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id fallback))))
        (should (equal "Stored summary" (plist-get result :response)))
        (should (equal "stored summary" (plist-get result :response_source))))
      ;; Missing evidence falls back too, with the error reported.
      (let ((digest (plist-get (pichat-job-record store 'runs finished) :evidence)))
        (delete-file (pichat-job--evidence-file store digest))
        (let ((result (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id finished))))
          (should (equal "Stored summary" (plist-get result :response)))
          (should (string-match-p "missing or changed" (plist-get result :evidence_error)))))
      ;; Pending runs report state and why they wait, without output.
      (let ((result (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id queued))))
        (should (equal "queued" (plist-get (plist-get result :run) :state)))
        (should-not (plist-member result :response)))
      (pichat-test-job-tool-error "pichat_job_run_inspect" '(:run_id "run-unknown") "Unknown job run"))))

(ert-deftest pichat-job-tools-run-inspect-links-repeated-follow-ups-to-their-chain ()
  (pichat-test-with-job-tools
    (let* ((reviewer (pichat-job-save store (pichat-test-job-spec project-dir)))
           (worker (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                     :after-job-id reviewer)))
           (w1 (pichat-job-enqueue store nil worker))
           (inspect (lambda (id) (pichat-test-job-tool-ok "pichat_job_run_inspect"
                                                          (list :run_id id)))))
      (pichat-job-claim store w1)
      (pichat-test-job-tools-finish store w1)
      (let ((r1 (plist-get (plist-get (pichat-job-record store 'runs w1) :dispatch) :run-id)))
        (pichat-job-claim store r1)
        (pichat-test-job-tools-finish store r1)
        (let ((result (funcall inspect w1)))
          (should (equal w1 (plist-get result :chain_root)))
          (should-not (plist-member result :after_run_of)))
        (let ((result (funcall inspect r1)))
          (should (equal w1 (plist-get result :after_run_of)))
          (should-not (plist-member result :repeat_of)))
        (let ((repeat (pichat-job-enqueue store nil nil nil r1)))
          (let ((result (funcall inspect repeat)))
            (should (equal r1 (plist-get result :repeat_of)))
            (should (equal w1 (plist-get result :after_run_of)))
            (should (equal w1 (plist-get result :chain_root)))
            (should (= 1 (plist-get result :round))))
          (pichat-job-cancel-queued store repeat)
          (let ((result (funcall inspect (pichat-job-enqueue store nil nil nil nil repeat))))
            (should (equal repeat (plist-get result :continue_of)))
            (should (equal w1 (plist-get result :after_run_of)))
            (should (equal w1 (plist-get result :chain_root)))))))))

(ert-deftest pichat-job-tools-run-inspect-links-a-retained-runtime ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (worker (pichat-test-job-tools-worker executor store job))
           (run (car worker))
           (session (cdr worker)))
      (pichat-register-session session)
      (pichat-job-advance store run (plist-get (pichat-job-record store 'runs run) :attempt)
                          "running" (list :runtime-id (pichat-session-runtime-id session)))
      (let ((result (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id run))))
        (should (equal (pichat-session-runtime-id session) (plist-get result :runtime_id)))
        (should-not (plist-member result :response))))))

(ert-deftest pichat-job-tools-run-inspect-ignores-a-reused-runtime-id ()
  ;; Runtime IDs restart with each Emacs session: a finished run's recorded ID
  ;; links only while the runtime is still bound to the run's session file.
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (session (pichat-session-make :cwd project-dir :session-file "/tmp/now.jsonl"))
           (run (pichat-job-enqueue store nil job))
           (token (plist-get (pichat-job-claim store run) :attempt))
           (inspect (lambda ()
                      (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id run)))))
      (pichat-register-session session)
      (pichat-job-advance store run token "running"
                          (list :runtime-id (pichat-session-runtime-id session)
                                :session-file "/tmp/earlier-emacs.jsonl"))
      (should-not (plist-member (funcall inspect) :runtime_id))
      (setf (pichat-session-session-file session) "/tmp/earlier-emacs.jsonl")
      (should (equal (pichat-session-runtime-id session)
                     (plist-get (funcall inspect) :runtime_id))))))

;;; Chains started from a chat

(defmacro pichat-test-with-chain-chat (&rest body)
  "Run BODY with Jobs tools, an inert chat SESSION and a FINISHES log.
FINISHES lists (ROOT MEMBER-IDS LOST) per reported chain finish, newest
first.  Nothing is pumped, so runs start only when the test claims them."
  (declare (indent 0) (debug t))
  `(pichat-test-with-conversation-job
     (pichat-job-tools-register)
     (let* ((pichat-jobs-file (pichat-job-store-file store))
            (pichat-jobs--executor executor)
            (pichat-jobs--owned-store nil)
            (finishes nil)
            (pichat-job-executor-chain-finished-functions
             (list (lambda (_executor entry chain)
                     (push (list (plist-get entry :root)
                                 (mapcar (lambda (run) (plist-get run :id))
                                         (plist-get chain :members))
                                 (plist-get entry :lost))
                           finishes)))))
       (cl-letf (((symbol-function 'pichat-job-executor-pump) #'ignore))
         ,@body))))

(defun pichat-test-chain-start (job session)
  "Start saved JOB with pichat_job_run_now from chat SESSION; return the run ID."
  (plist-get (pichat-test-job-tool-ok "pichat_job_run_now" (list :job_id job) session)
             :run_id))

(defun pichat-test-chain-end (executor run result &optional evidence)
  "Claim queued RUN in EXECUTOR's store and end it with RESULT.
RESULT is completed, failed or uncertain; a completed run may have
EVIDENCE.  Report the change as the executor does."
  (let* ((store (pichat-job-executor-store executor))
         (token (plist-get (pichat-job-claim store run) :attempt)))
    (pcase result
      ("completed" (pichat-test-job-tools-finish store run evidence))
      ("failed" (pichat-job-advance store run token "finished"
                                    '(:result "failed" :safe-to-release t :reason "Broke")))
      ("uncertain"
       (pichat-job-advance store run token "running" '(:runtime-id "pichat-runtime-gone"))
       (pichat-job-advance store run token "uncertain" '(:reason "Process lost"))))
    (pichat-job-executor--changed executor)))

(defun pichat-test-chain-followup (store run)
  "Return the run STORE queued after RUN as its after-run job."
  (plist-get (plist-get (pichat-job-record store 'runs run) :dispatch) :run-id))

(ert-deftest pichat-job-tools-chat-started-chain-reports-its-end-once ()
  ;; The worker's stop queues the reviewer in the same transaction, so the
  ;; chain is reported after the reviewer, not after the worker.
  (pichat-test-with-chain-chat
    (let* ((reviewer (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                       :title "Reviewer")))
           (worker (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                     :after-job-id reviewer)))
           (root (pichat-test-chain-start worker session))
           (entry (pichat-job-executor-chain-entry executor root)))
      (should (eq session (plist-get (plist-get entry :chat) :session)))
      (should (equal "conversation-source"
                     (plist-get (plist-get (plist-get entry :chat) :destination) :session-id)))
      (pichat-test-chain-end executor root "completed")
      (let ((review (pichat-test-chain-followup store root)))
        (should review)
        (should-not finishes)
        (pichat-test-chain-end executor review "completed")
        (should (equal (list (list root (list root review) nil)) finishes))
        ;; Later changes elsewhere do not report the same finish again.
        (pichat-job-executor--changed executor)
        (pichat-job-enqueue store (pichat-test-job-spec project-dir))
        (pichat-job-executor--changed executor)
        (should (= 1 (length finishes)))
        ;; Nothing is stored in the run records.
        (should-not (string-match-p "conversation-source"
                                    (format "%S" (pichat-job-records store 'runs))))))))

(ert-deftest pichat-job-tools-chat-started-chain-waits-for-a-reviewer-restart ()
  (pichat-test-with-chain-chat
    (let* ((reviewer (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                       :title "Reviewer")))
           (worker (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                     :after-job-id reviewer)))
           (root (pichat-test-chain-start worker session))
           review restart review-2)
      (pichat-test-chain-end executor root "completed")
      (setq review (pichat-test-chain-followup store root))
      ;; The reviewer restarts the worker before it stops itself.
      (let* ((token (plist-get (pichat-job-claim store review) :attempt))
             (review-session (pichat-session-make :cwd project-dir)))
        (puthash review (pichat-job-execution--create :executor executor :id review :token token
                                                      :session review-session)
                 (pichat-job-executor-contexts executor))
        (setq restart (pichat-test-chain-start worker review-session))
        ;; A job run's restart continues the chain; it is not a new chat chain.
        (should-not (pichat-job-executor-chain-entry executor restart))
        (pichat-job-advance store review token "running" '(:runtime-id "pichat-runtime-gone"))
        (pichat-job-advance store review token "settling")
        (pichat-job-advance store review token "finished"
                            '(:result "completed" :safe-to-release t :synchronized t))
        (remhash review (pichat-job-executor-contexts executor))
        (pichat-job-executor--changed executor))
      (should-not finishes)
      (pichat-test-chain-end executor restart "completed")
      (setq review-2 (pichat-test-chain-followup store restart))
      (should-not finishes)
      (pichat-test-chain-end executor review-2 "completed")
      (should (equal (list (list root (list root review restart review-2) nil)) finishes)))))

(ert-deftest pichat-job-tools-chat-started-chains-report-failed-cancelled-and-uncertain-ends ()
  (pichat-test-with-chain-chat
    (let* ((jobs (cl-loop repeat 3 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (failed (pichat-test-chain-start (nth 0 jobs) session))
           (cancelled (pichat-test-chain-start (nth 1 jobs) session))
           (uncertain (pichat-test-chain-start (nth 2 jobs) session)))
      (pichat-test-chain-end executor failed "failed")
      (should (equal (list (list failed (list failed) nil)) finishes))
      ;; The chat may cancel its own run; it is still told.
      (pichat-test-job-tool-ok "pichat_job_run_cancel" (list :run_id cancelled) session)
      (should (equal (list cancelled (list cancelled) nil) (car finishes)))
      (pichat-test-chain-end executor uncertain "uncertain")
      (should (equal (list uncertain (list uncertain) nil) (car finishes)))
      (should (= 3 (length finishes)))
      ;; Releasing the uncertain run is not a new finish.
      (pichat-job-executor-resolve executor uncertain "Inspected")
      (should (equal "finished" (plist-get (pichat-job-record store 'runs uncertain) :state)))
      (should (= 3 (length finishes))))))

(ert-deftest pichat-job-tools-runs-started-from-jobs-report-no-chain-end ()
  (pichat-test-with-chain-chat
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (other (pichat-job-save store (pichat-test-job-spec project-dir)))
           (run (pichat-job-executor-submit-options executor (list :job-id job))))
      (pichat-test-chain-end executor run "completed")
      ;; A tool call without a calling chat remembers nothing either.
      (let ((plain (pichat-test-chain-start other nil)))
        (should-not (pichat-job-executor-chain-entry executor plain))
        (pichat-test-chain-end executor plain "completed"))
      (should (= 0 (hash-table-count (pichat-job-executor-chains executor))))
      (should-not finishes))))

(ert-deftest pichat-job-tools-chat-started-chain-forgets-deleted-runs-and-a-closed-chat ()
  (pichat-test-with-chain-chat
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (other (pichat-job-save store (pichat-test-job-spec project-dir)))
           (deleted (pichat-test-chain-start job session))
           (closed (pichat-test-chain-start other session)))
      ;; Deleting a finished chain forgets it.
      (pichat-test-chain-end executor deleted "completed")
      (pichat-job-executor-delete-chain executor deleted (list deleted))
      (should-not (pichat-job-executor-chain-entry executor deleted))
      ;; A closed chat is dropped at the next change; the finish is still
      ;; reported, with the reason, so it can be shown as not notified.
      (kill-buffer (pichat-session-buffer session))
      (pichat-job-executor--changed executor)
      (let ((entry (pichat-job-executor-chain-entry executor closed)))
        (should-not (plist-get entry :chat))
        (should (equal "Chat closed" (plist-get entry :lost))))
      (pichat-test-chain-end executor closed "completed")
      (should (equal (list closed (list closed) "Chat closed") (car finishes))))))

(ert-deftest pichat-job-tools-chat-address-notices-a-stopped-or-switched-chat ()
  (pichat-test-with-conversation-job
    (let ((address (pichat-job-conversation-address session)))
      (should address)
      (should-not (pichat-job-conversation-address-lost address))
      ;; Busy is fine: the address does not need an idle chat.
      (setf (pichat-session-streaming-p session) t)
      (should (equal address (pichat-job-conversation-address session)))
      (should-not (pichat-job-conversation-address-lost address))
      (setf (pichat-session-id session) "other-source")
      (should (equal "Chat's Pi session changed" (pichat-job-conversation-address-lost address)))
      (setf (pichat-session-id session) "conversation-source")
      (setf (pichat-session-process-generation session) 2)
      (should (equal "Chat runtime stopped or restarted"
                     (pichat-job-conversation-address-lost address)))
      (setf (pichat-session-process-generation session) 1)
      (delete-process process)
      (should (equal "Chat runtime stopped" (pichat-job-conversation-address-lost address)))
      ;; Without a live runtime there is nothing to remember.
      (should-not (pichat-job-conversation-address session)))))

;;; Delivering the chain's finish to the chat

(defmacro pichat-test-with-chain-delivery (&rest body)
  "Run BODY like `pichat-test-with-chain-chat', delivering to the chat.
SENT lists the prompts PiChat sent, newest first, each a plist with
:session, :type, :payload, :success and :failure; nothing is answered
until the test calls `pichat-test-chain-answer'.  Other RPC calls (the
chat's own synchronization) are left unanswered."
  (declare (indent 0) (debug t))
  `(pichat-test-with-chain-chat
     (let ((pichat-job-executor-chain-finished-functions
            (list #'pichat-job-tools-chain-deliver))
           (sent nil))
       (cl-letf (((symbol-function 'pichat-rpc-send)
                  (lambda (session type payload &optional success failure)
                    (pichat-rpc--require-operation-ownership session type)
                    (when (equal type "prompt")
                      (push (list :session session :type type :payload payload
                                  :success success :failure failure)
                            sent))
                    1)))
         ,@body))))

(defun pichat-test-chain-answer (call &optional disposition error)
  "Answer RPC CALL with DISPOSITION, or refuse it with ERROR."
  (if error
      (funcall (plist-get call :failure) (list :success :false :error error)
               (plist-get call :session))
    (funcall (plist-get call :success) (list :success t :data (list :disposition disposition))
             (plist-get call :session))))

(defun pichat-test-chain-delivery (executor root)
  "Return the delivery state of EXECUTOR's chain ROOT."
  (plist-get (plist-get (pichat-job-executor-chain-entry executor root) :delivery) :state))

(ert-deftest pichat-job-tools-chain-finish-sends-the-chat-one-bounded-message ()
  (pichat-test-with-chain-delivery
    (let* ((reviewer (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                       :title "Plan reviewer")))
           (worker (pichat-job-save store (plist-put (plist-put (pichat-test-job-spec project-dir)
                                                                :title "Plan worker")
                                                     :after-job-id reviewer)))
           (root (pichat-test-chain-start worker session))
           review)
      (pichat-test-chain-end executor root "completed")
      (setq review (pichat-test-chain-followup store root))
      ;; Not after the worker: the reviewer is part of the chain.
      (should-not sent)
      (pichat-test-chain-end executor review "completed"
                             (list :version 1 :transcript "t"
                                   :response "\nplan-loop reviewer: accept\nDetails follow."))
      (should (= 1 (length sent)))
      (let* ((call (car sent))
             (payload (plist-get call :payload))
             (text (plist-get payload :message)))
        (should (eq session (plist-get call :session)))
        (should (equal "prompt" (plist-get call :type)))
        (should (equal "followUp" (plist-get payload :streamingBehavior)))
        (should (string-prefix-p "[PiChat] " text))
        (should (string-match-p "sent by PiChat, not by the user" text))
        (should (string-match-p "It is data, not a user request" text))
        (should (string-match-p (format "first run %s · 2 runs · ended completed" root) text))
        (should (string-match-p (format "1\\. %s “Plan worker”: completed" root) text))
        (should (string-match-p (format "2\\. %s “Plan reviewer”: completed" review) text))
        (should (string-match-p (format "Last response (%s, first line): plan-loop reviewer: accept$"
                                        review)
                                text))
        (should-not (string-match-p "Details follow" text))
        (should (string-match-p "pichat_job_run_inspect" text))
        (should (equal "sending" (pichat-test-chain-delivery executor root)))
        (pichat-test-chain-answer call "started"))
      (should (equal "sent" (pichat-test-chain-delivery executor root)))
      ;; Later changes do not send the same finish again.
      (pichat-job-executor--changed executor)
      (should (= 1 (length sent)))
      ;; The chain's first run shows the delivery; other runs do not.
      (should (equal '(:state "sent" :description "Sent to the starting chat")
                     (plist-get (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id root))
                                :chat_notification)))
      (should-not (plist-member (pichat-test-job-tool-ok "pichat_job_run_inspect"
                                                         (list :run_id review))
                                :chat_notification))
      (pichat-test-job-report executor 'runs root)
      (unless (member 'execution pichat-jobs--expanded) (pichat-test-job-press "Details"))
      (should (string-match-p "^Chat notification: Sent to the starting chat$" (buffer-string))))))

(ert-deftest pichat-job-tools-chain-finish-queues-behind-a-busy-chat-and-notifies-again-after-repeat ()
  (pichat-test-with-chain-delivery
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (root (pichat-test-chain-start job session))
           repeat)
      (setf (pichat-session-streaming-p session) t
            (pichat-session-state session) 'running)
      (pichat-test-chain-end executor root "failed")
      (should (string-match-p "ended failed (Broke)" (plist-get (plist-get (car sent) :payload) :message)))
      (pichat-test-chain-answer (car sent) "queued")
      (should (equal "queued" (pichat-test-chain-delivery executor root)))
      (should (equal "Sent; queued after the starting chat's current work"
                     (pichat-job-executor-chain-delivery-text
                      (pichat-job-executor-chain-entry executor root))))
      ;; Repeat from Jobs: the chain finishes again, so the chat is told again.
      (setq repeat (pichat-job-executor-submit-options executor (list :repeat-of root)))
      (pichat-test-chain-end executor repeat "completed")
      (should (= 2 (length sent)))
      (should (string-match-p (format "2 runs · ended completed\n1\\. %s .*failed (Broke)\n2\\. %s"
                                      root repeat)
                              (plist-get (plist-get (car sent) :payload) :message)))
      (should (equal "sending" (pichat-test-chain-delivery executor root))))))

(ert-deftest pichat-job-tools-chain-finish-names-uncertain-runs-and-undispatched-follow-ups ()
  (pichat-test-with-chain-delivery
    (let* ((reviewer (pichat-job-save store (pichat-test-job-spec project-dir)))
           (worker (pichat-job-save store (plist-put (plist-put (pichat-test-job-spec project-dir)
                                                                :title (make-string 300 ?w))
                                                     :after-job-id reviewer)))
           (root (pichat-test-chain-start worker session))
           (token (plist-get (pichat-job-claim store root) :attempt)))
      ;; A full queue: the reviewer cannot be dispatched.
      (pichat-job-advance store root token "running" '(:runtime-id "pichat-runtime-gone"))
      (pichat-job-advance store root token "uncertain" '(:reason "Process lost") 0)
      (pichat-job-executor--changed executor)
      (let ((text (plist-get (plist-get (car sent) :payload) :message)))
        (should (string-match-p "1 run · ended uncertain (Process lost)" text))
        (should (string-match-p (format "Follow-up not dispatched after %s .*: Job queue is full" root)
                                text))
        (should (string-match-p "none captured" text))
        ;; Titles are bounded.
        (should-not (string-match-p (make-string 100 ?w) text))))))

(ert-deftest pichat-job-tools-chain-finish-message-is-bounded-for-long-chains ()
  (pichat-test-with-chain-delivery
    (let* ((job (pichat-job-save store (plist-put (pichat-test-job-spec project-dir)
                                                  :title (make-string 200 ?t))))
           (root (pichat-test-chain-start job session))
           (run root))
      (pichat-test-chain-end executor root "failed")
      (dotimes (_ 13)
        (setq run (pichat-job-executor-submit-options executor (list :repeat-of run)))
        (pichat-test-chain-end executor run "completed"
                               (list :version 1 :transcript "t"
                                     :response (make-string 3000 ?r))))
      (let ((text (plist-get (plist-get (car sent) :payload) :message)))
        (should (= 14 (length sent)))
        (should (<= (length text) pichat-job-tools-notice-limit))
        (should (string-match-p (format "first run %s · 14 runs" root) text))
        (should (string-match-p "(4 earlier runs not listed)\n5\\. " text))
        (should (string-match-p (format "14\\. %s " run) text))
        (should (string-match-p "pichat_job_run_inspect" text))))))

(ert-deftest pichat-job-tools-chain-finish-keeps-undispatched-follow-ups-when-runs-overflow ()
  ;; Every run has a long title and reason and a follow-up that the full
  ;; queue refused; the run lines alone exceed the message budget.
  (pichat-test-with-chain-delivery
    (let* ((reviewer (pichat-job-save store (pichat-test-job-spec project-dir)))
           (worker (pichat-job-save store (plist-put (plist-put (pichat-test-job-spec project-dir)
                                                                :title (make-string 200 ?w))
                                                     :after-job-id reviewer)))
           (run (pichat-test-chain-start worker session))
           (end (lambda (id)
                  (let ((token (plist-get (pichat-job-claim store id) :attempt)))
                    (pichat-job-advance store id token "finished"
                                        (list :result "failed" :safe-to-release t
                                              :reason (make-string 300 ?x))
                                        0)
                    (pichat-job-executor--changed executor)))))
      (funcall end run)
      (dotimes (_ 11)
        (setq run (pichat-job-executor-submit-options executor (list :repeat-of run)))
        (funcall end run))
      (let ((text (plist-get (plist-get (car sent) :payload) :message)))
        (should (= 12 (length sent)))
        (should (<= (length text) pichat-job-tools-notice-limit))
        (should (string-match-p "first run .* · 12 runs" text))
        ;; The newest undispatched follow-up is named in full; older ones
        ;; are counted.
        (should (string-match-p (format "Follow-up not dispatched after %s .*: Job queue is full$"
                                        run)
                                text))
        (should (string-match-p "^([0-9]+ earlier follow-ups not dispatched, not listed)$" text))
        (should (string-match-p "^For details, call pichat_job_run_inspect" text))))))

(ert-deftest pichat-job-tools-chain-finish-records-why-a-chat-was-not-notified ()
  (pichat-test-with-chain-delivery
    (let* ((jobs (cl-loop repeat 4 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (refused (pichat-test-chain-start (nth 0 jobs) session))
           (owned (pichat-test-chain-start (nth 1 jobs) session))
           (closed (pichat-test-chain-start (nth 2 jobs) session)))
      ;; Pi refuses the prompt: recorded, not retried.
      (pichat-test-chain-end executor refused "completed")
      (pichat-test-chain-answer (car sent) nil "Agent is busy in an odd way")
      (should (equal "Not notified: Pi refused the message: Agent is busy in an odd way"
                     (pichat-job-executor-chain-delivery-text
                      (pichat-job-executor-chain-entry executor refused))))
      (should (= 1 (length sent)))
      ;; A scheduled continuation owns the chat's input: nothing is sent.
      (setf (pichat-session-input-guard session)
            (lambda (_command) (user-error "A scheduled attempt owns this chat")))
      (pichat-test-chain-end executor owned "completed")
      (should (= 1 (length sent)))
      (should (equal "Not notified: Another job owns the chat's input"
                     (pichat-job-executor-chain-delivery-text
                      (pichat-job-executor-chain-entry executor owned))))
      (setf (pichat-session-input-guard session) nil)
      ;; The chat was closed.
      (kill-buffer (pichat-session-buffer session))
      (pichat-test-chain-end executor closed "completed")
      (should (= 1 (length sent)))
      (should (equal "not-notified" (pichat-test-chain-delivery executor closed)))
      (should (equal '(:state "not-notified" :description "Not notified: Chat closed")
                     (plist-get (pichat-test-job-tool-ok "pichat_job_run_inspect" (list :run_id closed))
                                :chat_notification))))))

(ert-deftest pichat-job-tools-chain-finish-waits-for-a-manual-compaction ()
  (pichat-test-with-chain-delivery
    (let* ((jobs (cl-loop repeat 3 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (waits (pichat-test-chain-start (nth 0 jobs) session))
           (stops (pichat-test-chain-start (nth 1 jobs) session))
           (races (pichat-test-chain-start (nth 2 jobs) session)))
      ;; Compacting outside a run: Pi would refuse, so the send waits.
      (setf (pichat-session-compacting-p session) t (pichat-session-state session) 'compacting)
      (pichat-test-chain-end executor waits "completed")
      (should-not sent)
      (should (equal "waiting" (pichat-test-chain-delivery executor waits)))
      (setf (pichat-session-compacting-p session) nil (pichat-session-state session) 'idle)
      (pichat-emit session 'compaction-end)
      (should (= 1 (length sent)))
      (pichat-test-chain-answer (car sent) "started")
      (should (equal "sent" (pichat-test-chain-delivery executor waits)))
      ;; The handlers are gone: a later compaction sends nothing more.
      (pichat-emit session 'compaction-end)
      (should (= 1 (length sent)))
      ;; Pi's refusal in a race with a new compaction is recorded, not retried.
      (pichat-test-chain-end executor races "completed")
      (pichat-test-chain-answer
       (car sent) nil "Cannot submit a prompt while compaction is in progress. Wait for compaction to finish and retry.")
      (should (equal "Not notified: Chat was compacting"
                     (pichat-job-executor-chain-delivery-text
                      (pichat-job-executor-chain-entry executor races))))
      ;; The runtime stops while the send waits: not notified, never sent.
      (setf (pichat-session-compacting-p session) t)
      (pichat-test-chain-end executor stops "completed")
      (should (equal "waiting" (pichat-test-chain-delivery executor stops)))
      (pichat-emit session 'session-ended)
      (setf (pichat-session-compacting-p session) nil)
      (pichat-emit session 'compaction-end)
      (should (= 2 (length sent)))
      (should (equal "Not notified: Chat runtime stopped"
                     (pichat-job-executor-chain-delivery-text
                      (pichat-job-executor-chain-entry executor stops)))))))

(ert-deftest pichat-job-tools-chain-finish-deleted-while-waiting-removes-its-handlers ()
  (pichat-test-with-chain-delivery
    (let* ((events '(compaction-end session-ended session-rebinding))
           (handlers (lambda ()
                       (mapcar (lambda (event) (length (pichat--handlers-for event session)))
                               events)))
           (before (funcall handlers))
           (jobs (cl-loop repeat 2 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (deleted (pichat-test-chain-start (nth 0 jobs) session))
           (stale (pichat-test-chain-start (nth 1 jobs) session)))
      (setf (pichat-session-compacting-p session) t (pichat-session-state session) 'compacting)
      ;; Deleting the chain during a manual compaction removes the handlers.
      (pichat-test-chain-end executor deleted "completed")
      (should (equal "waiting" (pichat-test-chain-delivery executor deleted)))
      (should (equal (mapcar #'1+ before) (funcall handlers)))
      (pichat-job-executor-delete-chain executor deleted (list deleted))
      (should-not (pichat-job-executor-chain-entry executor deleted))
      (should (equal before (funcall handlers)))
      ;; A delivery that became stale without cleanup removes its handlers
      ;; at the next event and sends nothing.
      (pichat-test-chain-end executor stale "completed")
      (should (equal (mapcar #'1+ before) (funcall handlers)))
      (remhash stale (pichat-job-executor-chains executor))
      (setf (pichat-session-compacting-p session) nil (pichat-session-state session) 'idle)
      (pichat-emit session 'compaction-end)
      (should (equal before (funcall handlers)))
      (should-not sent))))

;;; Limiting runs a chat starts in response to notifications

(defconst pichat-test-chat-run-limit-error
  (concat "already started 2 job runs since the user.s last message, "
          "the limit (pichat-jobs-max-notified-runs); stop")
  "The refusal of a third chat-started run with a limit of 2.")

(ert-deftest pichat-job-tools-chat-run-limit-refuses-until-the-user-writes ()
  (pichat-test-with-chain-delivery
    (let* ((pichat-jobs-max-notified-runs 2)
           (jobs (cl-loop repeat 3 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (buffer (pichat-session-buffer session))
           (start (lambda (n) (pichat-test-chain-start (nth n jobs) session)))
           (finish (lambda (run)
                     (pichat-test-chain-end executor run "completed")
                     (pichat-test-chain-answer (car sent) "started"))))
      ;; Each finish is answered with another run; PiChat's own messages do
      ;; not reset the count.
      (funcall finish (funcall start 0))
      (funcall finish (funcall start 1))
      (should (= 2 (length sent)))
      (let ((before (length (pichat-job-records store 'runs))))
        (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id (nth 2 jobs))
                                    pichat-test-chat-run-limit-error session)
        (should (= before (length (pichat-job-records store 'runs)))))
      ;; The user's prompt resets it.
      (with-current-buffer buffer
        (pichat-chat--set-input-text "Carry on")
        (pichat-chat-send-input))
      (should (equal "Carry on" (plist-get (plist-get (car sent) :payload) :message)))
      (funcall finish (funcall start 2))
      (funcall finish (funcall start 0))
      (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id (nth 1 jobs))
                                  pichat-test-chat-run-limit-error session)
      ;; So do the user's follow-up and steering messages.
      (with-current-buffer buffer (pichat-chat-follow-up "And then"))
      (funcall finish (funcall start 1))
      (funcall finish (funcall start 2))
      (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id (nth 0 jobs))
                                  pichat-test-chat-run-limit-error session)
      (with-current-buffer buffer (pichat-chat-steer "Next"))
      (should (pichat-test-chain-start (nth 0 jobs) session)))))

(ert-deftest pichat-job-tools-chat-run-limit-leaves-job-runs-and-jobs-alone ()
  (pichat-test-with-chain-chat
    (let* ((pichat-jobs-max-notified-runs 1)
           (jobs (cl-loop repeat 3 collect (pichat-job-save store (pichat-test-job-spec project-dir))))
           (worker (cdr (pichat-test-job-tools-worker executor store (nth 2 jobs)))))
      (pichat-test-chain-start (nth 0 jobs) session)
      (pichat-test-job-tool-error "pichat_job_run_now" (list :job_id (nth 1 jobs))
                                  "the limit (pichat-jobs-max-notified-runs)" session)
      ;; A job run is bounded by its chain's limit only.
      (dotimes (_ 2)
        (pichat-job-cancel-queued
         store (pichat-test-chain-start (nth 1 jobs) worker)))
      ;; Runs from Jobs and calls without a calling chat are not counted.
      (pichat-job-cancel-queued
       store (pichat-job-executor-submit-options executor (list :job-id (nth 1 jobs))))
      (pichat-test-chain-start (nth 1 jobs) nil)
      (should (= 1 (pichat-job-executor-chat-runs executor session)))
      (should (= 0 (pichat-job-executor-chat-runs executor worker))))))

(ert-deftest pichat-job-tools-approval-names-the-job-and-run ()
  (pichat-test-with-job-tools
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (run (pichat-job-enqueue store nil job))
           (tool (lambda (name) (gethash name pichat-tools-registry))))
      (should (string-match-p "\\`Run now: “Review files” on .* in "
                              (pichat-tools-approval-summary
                               (funcall tool "pichat_job_run_now") (list :job_id job))))
      (should (string-match-p "\\`Cancel queued run: “Review files”"
                              (pichat-tools-approval-summary
                               (funcall tool "pichat_job_run_cancel") (list :run_id run))))
      ;; A bad ID cannot be summarized, but the prompt still shows arguments.
      (should-not (pichat-tools-approval-summary
                   (funcall tool "pichat_job_run_cancel") '(:run_id "run-unknown"))))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-job-tools-bridge-manages-one-native-scheduled-occurrence ()
    ;; A real offline Pi conversation lists and inspects jobs, is denied once,
    ;; then schedules a job; the owned native timer submits one attributable
    ;; worker run.  All storage is private.
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "scheduled work done")]))
      (pichat-job-tools-register)
      (let* ((pichat-jobs-file (pichat-job-store-file store))
             (pichat-jobs--executor executor)
             (pichat-jobs--owned-store nil)
             (pichat-approval-policy-file (expand-file-name "approvals.el" project-dir))
             (pichat-chat-stop-session-on-kill nil)
             (job (pichat-job-save
                   store (plist-put (plist-put (pichat-test-job-spec project-dir)
                                              :title "Review files — café 日本語")
                                    :instructions (concat "Review files " (make-string 400 ?x)))))
             (schedule-args (expand-file-name "schedule-args.json" project-dir))
             (chat-status (expand-file-name "chat-status.json" project-dir))
             (write-args (lambda (start)
                           (with-temp-file schedule-args
                             (insert (json-serialize
                                      (list :job_id job :kind "once" :start start))))))
             (script
              `(:turns
                [(:expectTool (:name "pichat_jobs_list")
                  :expectToolAbsent "read"
                  :toolCall (:id "list" :name "pichat_jobs_list" :arguments (:limit 5)))
                 (:expectContextIncludes ,job
                  :toolCall (:id "inspect" :name "pichat_job_inspect" :arguments (:job_id ,job)))
                 (:expectContextIncludes ["Review files — café 日本語" "…"]
                  :toolCall (:id "denied" :name "pichat_job_schedule" :argumentsFile ,schedule-args))
                 (:expectContextIncludes "Denied by user" :text "denied")
                 (:toolCall (:id "schedule" :name "pichat_job_schedule" :argumentsFile ,schedule-args))
                 (:expectContextIncludes "Timing saved, enabled" :text "scheduled")]))
             chat)
        (funcall write-args (+ 86400 (floor (float-time))))
        (setq pichat-approval-rules '(("pichat_job_schedule" . deny)))
        (pichat-approval-save)
        (unwind-protect
            (progn
              (let ((pichat-bridge-extension-file pichat-test-bridge-extension)
                    (process-environment
                     (append (list (concat "PICHAT_FAKE_PROVIDER_STATUS=" chat-status)
                                   (concat "PICHAT_FAKE_PROVIDER_SCRIPT_JSON=" (json-serialize script)))
                             process-environment)))
                (setq chat (pichat-start-session
                            project-dir nil
                            `(:preset review :tools (:builtins nil :emacs ,pichat-test-job-tools-names)))))
              (pichat-test-rpc-call chat "get_state")
              (pichat-test-rpc-call chat "set_auto_retry" (list :enabled :json-false))
              (pichat-test-rpc-call chat "set_auto_compaction" (list :enabled :json-false))
              (pichat-chat-open chat)
              (pichat-test-prompt-and-wait chat "inspect jobs")
              (should-not (plist-get (pichat-job-record store 'jobs job) :schedule))
              (setq pichat-approval-rules '(("pichat_job_schedule" . allow)))
              (pichat-approval-save)
              (let ((start (+ 4 (floor (float-time)))))
                (funcall write-args start)
                (pichat-test-prompt-and-wait chat "schedule it")
                (pichat-test-assert-provider-script-consumed chat-status)
                (let ((schedule (plist-get (pichat-job-record store 'jobs job) :schedule)))
                  (should (eq t (plist-get schedule :enabled)))
                  (should (= start (plist-get schedule :next)))
                  (should (pichat-test-job-tools-timer executor job))
                  (pichat-test-wait-until
                   (lambda () (equal "submitted"
                                     (plist-get (plist-get (plist-get (pichat-job-record store 'jobs job)
                                                                      :schedule) :last) :state)))
                   15 "scheduled occurrence submission")
                  (let* ((last (plist-get (plist-get (pichat-job-record store 'jobs job) :schedule) :last))
                         (run (plist-get last :run-id))
                         (trigger (plist-get (pichat-job-record store 'runs run) :trigger)))
                    (should (= start (plist-get last :due)))
                    (should (equal "once" (plist-get trigger :kind)))
                    (should (equal (plist-get schedule :token) (plist-get trigger :schedule-token)))
                    (pichat-test-job-wait store run "finished")
                    (should (equal "completed" (plist-get (pichat-job-record store 'runs run) :result)))
                    (pichat-test-assert-provider-script-consumed status-file)))))
          (when chat
            (ignore-errors (pichat-rpc-stop chat))
            (when-let* ((buffer (pichat-session-buffer chat)))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

;; Integration: an orchestrator chat runs a saved job now, reads its result
;; after the worker finishes, and cancels another queued run.
(when pichat-test-include-integration
  (ert-deftest pichat-integration-job-tools-run-now-inspect-and-cancel ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "WORKER REPORT: all files reviewed")]))
      (pichat-job-tools-register)
      (let* ((pichat-jobs-file (pichat-job-store-file store))
             (pichat-jobs--executor executor)
             (pichat-jobs--owned-store nil)
             (pichat-approval-policy-file (expand-file-name "approvals.el" project-dir))
             (pichat-chat-stop-session-on-kill nil)
             (job (pichat-job-save store (pichat-test-job-spec project-dir)))
             (other (pichat-job-save store (pichat-test-job-spec project-dir)))
             (inspect-args (expand-file-name "inspect-args.json" project-dir))
             (cancel-args (expand-file-name "cancel-args.json" project-dir))
             (chat-status (expand-file-name "chat-status.json" project-dir))
             (finishes nil)
             (pichat-job-executor-chain-finished-functions
              (list (lambda (_executor entry chain)
                      (push (list (plist-get entry :root)
                                  (plist-get (plist-get entry :chat) :session)
                                  (length (plist-get chain :members)))
                            finishes))))
             (script
              `(:turns
                [(:expectTool (:name "pichat_job_run_now")
                  :toolCall (:id "run" :name "pichat_job_run_now" :arguments (:job_id ,job)))
                 (:expectContextIncludes ["run_id" "Timing is unchanged"] :text "submitted")
                 (:toolCall (:id "inspect" :name "pichat_job_run_inspect" :argumentsFile ,inspect-args))
                 (:expectContextIncludes ["WORKER REPORT: all files reviewed" "captured evidence"]
                  :toolCall (:id "cancel" :name "pichat_job_run_cancel" :argumentsFile ,cancel-args))
                 (:expectContextIncludes "Cancelled." :text "done")]))
             chat)
        (setq pichat-approval-rules '(("pichat_job_run_now" . allow)
                                      ("pichat_job_run_cancel" . allow)))
        (pichat-approval-save)
        (unwind-protect
            (progn
              (setq chat (pichat-test-start-bridge-chat project-dir script chat-status
                                                        pichat-test-job-tools-names))
              (pichat-test-prompt-and-wait chat "run the review job")
              (let ((run (plist-get (seq-find (lambda (r) (equal job (plist-get r :job-id)))
                                              (pichat-job-records store 'runs))
                                    :id)))
                (should run)
                (pichat-test-job-wait store run "finished")
                (should (equal "completed" (plist-get (pichat-job-record store 'runs run) :result)))
                (pichat-test-assert-provider-script-consumed status-file)
                ;; The chat that started the run is told once that its chain ended.
                (should (equal (list (list run chat 1)) finishes))
                ;; A pending run to cancel; nothing pumps until the cancel.
                (let ((queued (pichat-job-enqueue store nil other)))
                  (with-temp-file inspect-args (insert (json-serialize (list :run_id run))))
                  (with-temp-file cancel-args (insert (json-serialize (list :run_id queued))))
                  (pichat-test-prompt-and-wait chat "report and cancel the other run")
                  (pichat-test-assert-provider-script-consumed chat-status)
                  (let ((cancelled (pichat-job-record store 'runs queued)))
                    (should (equal "finished" (plist-get cancelled :state)))
                    (should (equal "cancelled" (plist-get cancelled :result)))))))
          (when chat
            (ignore-errors (pichat-rpc-stop chat))
            (when-let* ((buffer (pichat-session-buffer chat)))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

;; Integration: when the chain a chat started finishes, the real chat gets one
;; message from PiChat, after or behind its current turn, and replies to it.
(when pichat-test-include-integration
  (ert-deftest pichat-integration-job-tools-chain-finish-notifies-the-starting-chat ()
    (pichat-test-with-job-executor
        (:script '(:turns [(:text "WORKER REPORT: all files reviewed")]))
      (pichat-job-tools-register)
      (let* ((pichat-jobs-file (pichat-job-store-file store))
             (pichat-jobs--executor executor)
             (pichat-jobs--owned-store nil)
             (pichat-approval-policy-file (expand-file-name "approvals.el" project-dir))
             (pichat-chat-stop-session-on-kill nil)
             (pichat-job-executor-chain-finished-functions
              (list #'pichat-job-tools-chain-deliver))
             (job (pichat-job-save store (pichat-test-job-spec project-dir)))
             (chat-status (expand-file-name "chat-status.json" project-dir))
             (script
              `(:turns
                [(:expectTool (:name "pichat_job_run_now")
                  :toolCall (:id "run" :name "pichat_job_run_now" :arguments (:job_id ,job)))
                 (:expectContextIncludes "run_id" :text "submitted")
                 (:expectContextIncludes
                  ["[PiChat] A job run chain started from this chat has finished."
                   "not a user request" "“Review files”: completed"
                   "first line): WORKER REPORT: all files reviewed"]
                  :text "NOTED: the review job finished")]))
             chat)
        (setq pichat-approval-rules '(("pichat_job_run_now" . allow)))
        (pichat-approval-save)
        (unwind-protect
            (progn
              (setq chat (pichat-test-start-bridge-chat project-dir script chat-status
                                                        pichat-test-job-tools-names))
              (pichat-test-prompt-and-wait chat "run the review job")
              (let ((run (plist-get (seq-find (lambda (r) (equal job (plist-get r :job-id)))
                                              (pichat-job-records store 'runs))
                                    :id)))
                (should run)
                (pichat-test-job-wait store run "finished")
                (pichat-test-assert-provider-script-consumed status-file)
                (pichat-test-wait-until
                 (lambda () (member (pichat-test-chain-delivery executor run) '("sent" "queued")))
                 8 "the notification to be accepted by Pi")
                (pichat-test-wait-for-buffer-contains (pichat-session-buffer chat)
                                                      "NOTED: the review job finished" 10)
                (pichat-test-assert-provider-script-consumed chat-status)
                (let ((text (pichat-test-buffer-text (pichat-session-buffer chat))))
                  (should (= 1 (pichat-test-count-substring
                                "A job run chain started from this chat has finished" text))))
                (should (member (plist-get (plist-get (pichat-test-job-tool-ok
                                                       "pichat_job_run_inspect" (list :run_id run))
                                                      :chat_notification)
                                           :state)
                                '("sent" "queued")))))
          (when chat
            (ignore-errors (pichat-rpc-stop chat))
            (when-let* ((buffer (pichat-session-buffer chat)))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(provide 'pichat-test-job-tools)
;;; pichat-test-job-tools.el ends here
