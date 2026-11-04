;;; pichat-job-schedule.el --- Data-only native timing rules -*- lexical-binding: t; -*-

;;; Commentary:
;; One timing implementation, not a backend interface.  Versioned rules and a
;; pure next-occurrence calculation allow a later explicit replacement/migration.
;; Instants are Unix seconds; intervals are elapsed seconds, never calendar days.

;;; Code:
(require 'cl-lib)

(defun pichat-job-schedule-instant-p (value)
  "Whether VALUE is a finite, supported Unix instant."
  (and (numberp value) (<= 0 value 253402300799)))

(defun pichat-job-schedule-validate-rule (rule)
  "Validate data-only RULE without consulting a clock or external settings."
  (unless (and (listp rule)
               (member (plist-get rule :kind) '("once" "interval"))
               (pichat-job-schedule-instant-p (plist-get rule :start))
               (if (equal (plist-get rule :kind) "interval")
                   (and (integerp (plist-get rule :seconds))
                        (> (plist-get rule :seconds) 0))
                 (null (plist-get rule :seconds))))
    (user-error "Invalid schedule timing rule"))
  rule)

(defun pichat-job-schedule-next (rule reference)
  "Return RULE's next instant strictly after explicit REFERENCE, or nil.
No timer, clock read, persistence or execution occurs here.  Interval timing is
anchored at :start and skips intervening ticks rather than drifting with work."
  (pichat-job-schedule-validate-rule rule)
  (unless (pichat-job-schedule-instant-p reference)
    (user-error "Invalid schedule reference instant"))
  (let ((start (plist-get rule :start)) (seconds (plist-get rule :seconds)))
    (cond ((> start reference) start)
          ((equal (plist-get rule :kind) "once") nil)
          (t (let ((next (+ start (* seconds (1+ (floor (- reference start) seconds))))))
               (and (pichat-job-schedule-instant-p next) next))))))

(defun pichat-job-schedule-validate (schedule)
  "Validate optional versioned SCHEDULE, rejecting unknown versions."
  (when schedule
    (unless (and (listp schedule) (eql (plist-get schedule :version) 1)
                 (stringp (plist-get schedule :token))
                 (> (length (plist-get schedule :token)) 0)
                 (memq (plist-get schedule :enabled) '(t :false)))
      (user-error "Unsupported or invalid job schedule"))
    (pichat-job-schedule-validate-rule (plist-get schedule :rule))
    (let ((next (plist-get schedule :next)) (last (plist-get schedule :last)))
      (unless (if (eq (plist-get schedule :enabled) t)
                  (and (pichat-job-schedule-instant-p next)
                       ;; A stored due instant must actually belong to this rule.
                       (= next (or (pichat-job-schedule-next
                                    (plist-get schedule :rule) (max 0 (1- next))) -1)))
                (null next))
        (user-error "Invalid schedule next occurrence"))
      (when last
        (unless (and (pichat-job-schedule-instant-p (plist-get last :due))
                     (member (plist-get last :state) '("submitted" "skipped" "missed" "dismissed"))
                     (if (equal (plist-get last :state) "submitted")
                         (stringp (plist-get last :run-id))
                       (stringp (plist-get last :reason))))
          (user-error "Invalid schedule occurrence disposition")))))
  schedule)

(provide 'pichat-job-schedule)
;;; pichat-job-schedule.el ends here
