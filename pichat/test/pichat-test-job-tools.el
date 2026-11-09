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
                   (lambda (prompt &rest _) (push prompt prompts) "Deny once")))
          (should (string-match-p "Denied by user" (format "%S" (funcall call)))))
        (should (string-match-p "pichat_job_schedule.*once" (car prompts)))
        (should (string-match-p "(Run once at .*: “Review files” on .* in " (car prompts)))
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
          (should (string-match-p "Cancellation requested.*uncertain" (plist-get result :message))))))))

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

(provide 'pichat-test-job-tools)
;;; pichat-test-job-tools.el ends here
