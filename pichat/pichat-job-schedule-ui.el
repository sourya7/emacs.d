;;; pichat-job-schedule-ui.el --- Saved-job timing controls -*- lexical-binding: t; -*-

;;; Commentary:
;; One compact timing Transient, embedded in the existing saved-job details.
;; Picks stage privately; Save changes timing only, Enable authorizes submission.

;;; Code:
(require 'pichat-job-executor)
(require 'transient)
(require 'subr-x)
(declare-function pichat-jobs--button "pichat-jobs")
(declare-function pichat-jobs--show-detail "pichat-jobs")
(declare-function pichat-jobs--display "pichat-jobs")
(defvar-local pichat-job-schedule-ui--scope nil)

(defun pichat-job-schedule-ui-time (instant)
  "Format INSTANT explicitly in the Emacs host's local timezone."
  (format-time-string "%Y-%m-%d %H:%M %Z (%z)" (seconds-to-time instant)))

(defun pichat-job-schedule-ui-rule-label (rule)
  "Return compact human-readable timing for RULE."
  (if (equal (plist-get rule :kind) "once") "Once"
    (let* ((seconds (plist-get rule :seconds))
           (unit (cond ((zerop (% seconds 86400)) '(86400 . "day"))
                       ((zerop (% seconds 3600)) '(3600 . "hour"))
                       ((zerop (% seconds 60)) '(60 . "minute"))
                       (t '(1 . "second"))))
           (count (/ seconds (car unit))))
      (format "Every %s %s%s" count (cdr unit) (if (= count 1) "" "s")))))

(defun pichat-job-schedule-ui-status (schedule)
  "Return compact SCHEDULE status, distinct from any worker outcome."
  (if (not schedule) "None"
    (concat
     (pichat-job-schedule-ui-rule-label (plist-get schedule :rule)) " · "
     (cond ((eq (plist-get schedule :enabled) t) "Enabled")
           ((equal (plist-get (plist-get schedule :rule) :kind) "interval") "Disabled")
           (t (pcase (plist-get (plist-get schedule :last) :state)
                ("missed" "Missed") ("skipped" "Not submitted")
                ("submitted" "Dispatched") (_ "Disabled")))))))

(defun pichat-job-schedule-ui--current (scope)
  "Return the current definition only while SCOPE owns its unchanged origin."
  (let ((origin (plist-get scope :origin)))
    (unless (and (buffer-live-p origin) (not (plist-get scope :closed))
                 (eq scope (buffer-local-value 'pichat-job-schedule-ui--scope origin)))
      (user-error "Schedule editor closed; reopen it from job details"))
    (let ((job (pichat-job-record
                (pichat-job-executor-store (plist-get scope :owner)) 'jobs (plist-get scope :id))))
      (unless (equal job (plist-get scope :original))
        (user-error "Job changed; reopen Schedule"))
      job)))

(defun pichat-job-schedule-ui--show (scope)
  "Redisplay the staged editor for valid SCOPE."
  (pichat-job-schedule-ui--current scope)
  (with-current-buffer (plist-get scope :origin)
    (transient-setup 'pichat-job-schedule-menu nil nil :scope scope)))

(defun pichat-job-schedule-ui-open (owner id)
  "Stage timing for saved ID in OWNER without enabling or submitting it."
  (let* ((job (pichat-job-record (pichat-job-executor-store owner) 'jobs id))
         (rule (plist-get (plist-get job :schedule) :rule)))
    (setq pichat-job-schedule-ui--scope
          (list :origin (current-buffer) :owner owner :id id :original job :closed nil
                :rule (copy-tree (or rule (list :kind "once" :start
                                               (* 60 (1+ (floor (float-time) 60))))))))
    (pichat-job-schedule-ui--show pichat-job-schedule-ui--scope)))

(defun pichat-job-schedule-ui--local-candidates (text)
  "Return local instants matching exact YYYY-MM-DD HH:MM TEXT.
Reject nonexistent dates/times.  Preserve both DST-fold choices."
  (unless (string-match
           "\\`\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\) \\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)\\'" text)
    (user-error "Use YYYY-MM-DD HH:MM in the displayed local timezone"))
  (let ((year (string-to-number (match-string 1 text)))
        (month (string-to-number (match-string 2 text)))
        (day (string-to-number (match-string 3 text)))
        (hour (string-to-number (match-string 4 text)))
        (minute (string-to-number (match-string 5 text))) candidates)
    (dolist (dst '(nil t))
      (let ((time (encode-time (list 0 minute hour day month year nil dst nil))))
        (when (equal text (format-time-string "%Y-%m-%d %H:%M" time))
          (cl-pushnew (float-time time) candidates :test #'=))))
    (or (sort candidates #'<) (user-error "That local date/time does not exist"))))

(defun pichat-job-schedule-ui--edit (field)
  "Edit FIELD in a detached timing draft, never the saved definition."
  (let* ((scope (transient-scope))
         (_ (pichat-job-schedule-ui--current scope))
         (rule (copy-tree (plist-get scope :rule))))
    (condition-case err
        (progn
          (pcase field
            ('kind
             (let ((kind (completing-read "Timing: " '("Once" "Every") nil t))
                   (seconds (plist-get rule :seconds)))
               (setq rule (list :kind (if (equal kind "Once") "once" "interval")
                                :start (or (plist-get rule :start)
                                           (* 60 (1+ (floor (float-time) 60))))))
               (when (equal kind "Every")
                 (setq rule (plist-put rule :seconds (or seconds 3600))))))
            ('start
             (unless rule (user-error "Choose Timing first"))
             (let* ((text (read-string
                           (format "Local date/time (%s), YYYY-MM-DD HH:MM: "
                                   (format-time-string "%Z (%z)"))
                           (format-time-string "%Y-%m-%d %H:%M"
                                               (seconds-to-time (plist-get rule :start)))))
                    (candidates (pichat-job-schedule-ui--local-candidates text))
                    (instant
                     (if (= (length candidates) 1) (car candidates)
                       (let* ((choices (mapcar (lambda (time)
                                                (cons (pichat-job-schedule-ui-time time) time)) candidates))
                              (choice (completing-read "Repeated local time; choose offset: " choices nil t)))
                         (cdr (assoc choice choices))))))
               (setf (plist-get rule :start) instant)))
            ('interval
             (unless (equal (plist-get rule :kind) "interval") (user-error "Choose Every first"))
             (let* ((unit (completing-read "Interval unit (elapsed): " '("minutes" "hours" "days") nil t))
                    (count (read-number (concat "Every how many " unit "? ") 1)))
               (unless (and (integerp count) (> count 0)) (user-error "Choose a positive whole number"))
               (setf (plist-get rule :seconds)
                     (* count (pcase unit ("minutes" 60) ("hours" 3600) (_ 86400))))))
            ('remove (setq rule nil)))
          ;; The minibuffer may have processed timers or definition edits.
          (pichat-job-schedule-ui--current scope)
          (setf (plist-get scope :rule) rule)
          (pichat-job-schedule-ui--show scope))
      ((error quit)
       (when (and (buffer-live-p (plist-get scope :origin)) (not (plist-get scope :closed)))
         (ignore-errors (pichat-job-schedule-ui--show scope)))
       (signal (car err) (cdr err))))))

(defun pichat-job-schedule-ui--description (field)
  "Describe staged timing FIELD inline."
  (let ((rule (plist-get (transient-scope) :rule)))
    (pcase field
      ('kind (concat "Timing: " (if rule (pichat-job-schedule-ui-rule-label rule) "Remove schedule")))
      ('start (concat (if (equal (plist-get rule :kind) "once") "When: " "First run: ")
                      (if rule (pichat-job-schedule-ui-time (plist-get rule :start)) "—")))
      ('interval (if (equal (plist-get rule :kind) "interval")
                     (concat "Interval: " (pichat-job-schedule-ui-rule-label rule))
                   "Interval (choose Every)")))))

(transient-define-suffix pichat-job-schedule-kind ()
  "Choose Once or Every." (interactive) (pichat-job-schedule-ui--edit 'kind))
(transient-define-suffix pichat-job-schedule-start ()
  "Set the local date/time." (interactive) (pichat-job-schedule-ui--edit 'start))
(transient-define-suffix pichat-job-schedule-interval ()
  "Set an elapsed interval." (interactive) (pichat-job-schedule-ui--edit 'interval))
(transient-define-suffix pichat-job-schedule-remove ()
  "Stage removal of timing only." (interactive) (pichat-job-schedule-ui--edit 'remove))
(transient-define-suffix pichat-job-schedule-cancel ()
  "Discard staged timing."
  (interactive)
  (let ((scope (transient-scope))) (setf (plist-get scope :closed) t)))
(transient-define-suffix pichat-job-schedule-apply ()
  "Save changed timing disabled, without submitting work."
  (interactive)
  (let* ((scope (transient-scope))
         (job (pichat-job-schedule-ui--current scope))
         (rule (plist-get scope :rule)))
    (unless (equal rule (plist-get (plist-get job :schedule) :rule))
      (when (and rule (equal (plist-get rule :kind) "once")
                 (<= (plist-get rule :start) (float-time)))
        (user-error "Choose a future time for this one-shot"))
      (pichat-job-executor-schedule-change (plist-get scope :owner) (plist-get scope :id) rule))
    (setf (plist-get scope :closed) t)))

(transient-define-prefix pichat-job-schedule-menu ()
  "Stage saved-job timing.  Enabling is a separate action."
  [["Schedule"
    ("k" pichat-job-schedule-kind :description (lambda () (pichat-job-schedule-ui--description 'kind)))
    ("s" pichat-job-schedule-start :description (lambda () (pichat-job-schedule-ui--description 'start)))
    ("i" pichat-job-schedule-interval :description (lambda () (pichat-job-schedule-ui--description 'interval)))]]
  [["Action"
    ("RET" "Save disabled" pichat-job-schedule-apply)
    ("q" "Cancel" pichat-job-schedule-cancel)]
   ["More" ("d" "Remove schedule (staged)" pichat-job-schedule-remove)]]
  [:hide (lambda () t) ("<return>" pichat-job-schedule-apply)])

(defun pichat-job-schedule-ui--enable (owner id expected)
  "Confirm enabling exact EXPECTED definition in OWNER."
  (let* ((schedule (plist-get expected :schedule))
         (rule (plist-get schedule :rule))
         (next (or (pichat-job-schedule-next rule (float-time))
                   (user-error "Time has passed; reschedule this one-shot"))))
    ;; Pure preparation checks captured configuration; do not launch or discover.
    (pichat-job-launch-prepare (plist-get expected :spec))
    (when (yes-or-no-p
           (format "Enable ‘%s’ %s, next %s? Emacs must be running; missed ticks are not replayed. "
                   (pichat-jobs--display (plist-get (plist-get expected :spec) :title))
                   (pichat-job-schedule-ui-rule-label rule) (pichat-job-schedule-ui-time next)))
      (unless (equal expected (pichat-job-record (pichat-job-executor-store owner) 'jobs id))
        (user-error "Job changed; review its schedule again"))
      (pichat-job-executor-schedule-enable owner id t))))

(defun pichat-job-schedule-ui-insert (owner job)
  "Insert compact timing and actions for saved JOB owned by OWNER."
  (let* ((id (plist-get job :id)) (schedule (plist-get job :schedule))
         (rule (plist-get schedule :rule)) (last (plist-get schedule :last))
         (enabled (eq (plist-get schedule :enabled) t)))
    (insert "Schedule: " (pichat-job-schedule-ui-status schedule) "   ")
    (pichat-jobs--button (if schedule "Change…" "Set schedule…")
                        (lambda () (pichat-job-schedule-ui-open owner id)))
    (when schedule
      (cond (enabled
             (pichat-jobs--button "Disable" (lambda () (pichat-job-executor-schedule-enable owner id nil))))
            ((or (equal (plist-get rule :kind) "interval")
                 (> (plist-get rule :start) (float-time)))
             (pichat-jobs--button "Enable…" (lambda () (pichat-job-schedule-ui--enable owner id job))))))
    (insert "\n")
    (when schedule
      (let ((next (or (plist-get schedule :next)
                      (and (or (not last) (equal (plist-get rule :kind) "interval"))
                           (pichat-job-schedule-next rule (float-time))))))
        (when next (insert "Next: " (pichat-job-schedule-ui-time next) "\n")))
      (when last
        (insert (format "Last occurrence: %s at %s%s\n"
                        (capitalize (plist-get last :state))
                        (pichat-job-schedule-ui-time (plist-get last :due))
                        (if (plist-get last :reason) (concat " — " (plist-get last :reason)) "")))
        (when-let* ((run (plist-get last :run-id)))
          (pichat-jobs--button "View scheduled run" (lambda () (pichat-jobs--show-detail owner 'runs run)))
          (insert "\n")))
      (when (and (not enabled) (equal (plist-get rule :kind) "once")
                 (member (plist-get last :state) '("missed" "skipped")))
        (pichat-jobs--button "Run now" (lambda () (pichat-job-executor-schedule-run-now owner id schedule)))
        (pichat-jobs--button "Reschedule…" (lambda () (pichat-job-schedule-ui-open owner id)))
        (pichat-jobs--button "Dismiss"
                            (lambda ()
                              (pichat-job-schedule-dismiss (pichat-job-executor-store owner) id schedule)
                              (pichat-job-executor--changed owner)))
        (insert "\n")))
    (when-let* ((error (pichat-job-executor-schedule-error owner))) (insert error "\n"))
    (insert "\n")))

(provide 'pichat-job-schedule-ui)
;;; pichat-job-schedule-ui.el ends here
