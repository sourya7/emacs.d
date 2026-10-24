;;; pichat-diagnostic.el --- Pure diagnostic records -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared vocabulary only.  Collectors retain ownership and retention policy.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(cl-defun pichat-diagnostic-create
    (&key domain category (severity 'warning) summary entry-id type)
  "Construct a diagnostic without runtime or UI dependencies."
  (list :domain domain :category category :severity severity
        :summary summary :entry-id entry-id :type type))

(defun pichat-diagnostic-summary (record)
  "Return the presentation text for RECORD (or a legacy string)."
  (if (stringp record) record
    (or (plist-get record :summary)
        (format "%s at %s (%s)"
                (or (plist-get record :category) 'unknown)
                (or (plist-get record :entry-id) "unknown")
                (or (plist-get record :type) "unknown")))))

(defun pichat-diagnostic-append (records record limit)
  "Append distinct RECORD to RECORDS if below LIMIT, preserving order."
  (if (or (>= (length records) limit) (member record records)) records
    (append records (list record))))

(provide 'pichat-diagnostic)
;;; pichat-diagnostic.el ends here
