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

;; Fixed safety ceilings, independent of presentation and user count settings.
;; A retained slot is charged its full capture allowance, even when mostly empty.
(defconst pichat-diagnostic-raw-byte-limit 65536
  "Maximum string bytes copied in one raw diagnostic/event snapshot.")
(defconst pichat-diagnostic-raw-string-limit 16384
  "Maximum bytes copied from any one raw string.")
(defconst pichat-diagnostic-raw-node-limit 1024
  "Maximum visited values in one raw snapshot (including list tails).")
(defconst pichat-diagnostic-raw-depth-limit 16
  "Maximum nesting depth of a raw snapshot.")
(defconst pichat-diagnostic-record-slots 20
  "Aggregate transport evidence ceiling: 1.25 MiB and 20480 visited values.")
(defconst pichat-diagnostic-event-slots 512
  "Aggregate event evidence ceiling: 32 MiB and 524288 visited values.")
(defconst pichat-diagnostic--omitted 'pichat-omitted
  "Marker for exhausted traversal budgets or unsupported raw objects.")

(defun pichat-diagnostic-raw-budget ()
  "Return a fresh shared byte/node budget for a raw snapshot."
  (vector pichat-diagnostic-raw-byte-limit pichat-diagnostic-raw-node-limit))

(defun pichat-diagnostic-copy-raw (value &optional budget)
  "Copy VALUE without serializing or traversing it in full.
BUDGET, when supplied, is shared by all fields of one snapshot.  Strings lose
text properties and retain at most 16384 bytes each; all strings together
retain at most 65536 bytes.  At most 1024 values and 16 nesting levels are
visited.  Cycles/shared containers and opaque objects become `pichat-omitted'.
Truncated strings end with an explicit marker (outside the string-byte budget).
List tails may become dotted omission markers; this is inspection data only,
never a protocol value to dispatch or a recovery/submission record."
  (let ((budget (or budget (pichat-diagnostic-raw-budget)))
        (seen (make-hash-table :test #'eq)))
    (cl-labels
        ((copy-value
          (object depth)
          (cond
           ((or (<= (aref budget 1) 0)
                (> depth pichat-diagnostic-raw-depth-limit))
            pichat-diagnostic--omitted)
           (t
            (aset budget 1 (1- (aref budget 1)))
            (cond
             ((stringp object)
              ;; Bound the initial substring by characters before measuring
              ;; bytes: never copy a huge string merely to truncate it later.
              (let* ((limit (min (aref budget 0)
                                 pichat-diagnostic-raw-string-limit))
                     (end (min (length object) limit))
                     (text (substring-no-properties object 0 end)))
                (when (> (string-bytes text) limit)
                  ;; Binary search a character boundary in the bounded prefix.
                  (let ((low 0) (high (length text)))
                    (while (< low high)
                      (let ((mid (/ (+ low high 1) 2)))
                        (if (<= (string-bytes (substring text 0 mid)) limit)
                            (setq low mid)
                          (setq high (1- mid)))))
                    (setq end low text (substring text 0 low))))
                (aset budget 0 (- (aref budget 0) (string-bytes text)))
                (if (< end (length object))
                    (concat text "[truncated by PiChat]")
                  text)))
             ((or (null object) (fixnump object) (floatp object)) object)
             ;; Do not retain arbitrary (possibly huge uninterned) symbol names.
             ((symbolp object)
              (if (<= (length (symbol-name object)) 256) object
                pichat-diagnostic--omitted))
             ((or (consp object) (vectorp object))
              (if (gethash object seen) pichat-diagnostic--omitted
                (puthash object t seen)
                (if (consp object)
                    ;; Iterate spines so a wide list cannot exhaust Lisp's
                    ;; evaluation stack before the node ceiling is reached.
                    (let* ((head (list (copy-value (car object) (1+ depth))))
                           (tail head)
                           (rest (cdr object)))
                      (while (and (consp rest)
                                  (> (aref budget 1) 0)
                                  (not (gethash rest seen)))
                        (puthash rest t seen)
                        (aset budget 1 (1- (aref budget 1)))
                        (setcdr tail (list (copy-value (car rest) (1+ depth))))
                        (setq tail (cdr tail) rest (cdr rest)))
                      (setcdr tail (if (consp rest) pichat-diagnostic--omitted
                                    (copy-value rest depth)))
                      head)
                  (let ((items nil) (index 0))
                    (while (and (< index (length object))
                                (> (aref budget 1) 0))
                      (push (copy-value (aref object index) (1+ depth)) items)
                      (setq index (1+ index)))
                    (when (< index (length object))
                      (push pichat-diagnostic--omitted items))
                    (vconcat (nreverse items))))))
             (t pichat-diagnostic--omitted))))))
      (copy-value value 0))))

(provide 'pichat-diagnostic)
;;; pichat-diagnostic.el ends here
