;;; pichat-job-core.el --- Durable job records and admission -*- lexical-binding: t; -*-

;;; Commentary:

;; Data-only job/run storage and resource admission.  No runtime, timer, UI or
;; Org dependency.  The executor must resolve configuration/resource identities
;; before enqueueing, persist admission before spawning, and supply verified
;; synchronization/release evidence before finishing.  Agent output is not that
;; evidence.  This module never executes stored instructions or Lisp.
;;
;; One owning Emacs per store is supported.  Writes reject changed files and
;; existing foreign Emacs locks; this is not a distributed execution lock.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(define-error 'pichat-job-error "PiChat job error")

(cl-defstruct (pichat-job-store (:constructor pichat-job--make-store))
  "An owned store.  DATA is private; public readers return detached snapshots."
  file data bytes)

(defconst pichat-job--active-states '("starting" "running" "settling" "uncertain"))
(defconst pichat-job--results '("completed" "needs-review" "failed" "cancelled"))
(defconst pichat-job--max-file-bytes (* 16 1024 1024))

(defun pichat-job--fail (format-string &rest arguments)
  "Signal a job error using FORMAT-STRING and ARGUMENTS."
  (signal 'pichat-job-error (list (apply #'format format-string arguments))))

(defun pichat-job--text-p (value)
  "Whether VALUE is nonblank text."
  (and (stringp value) (not (string-blank-p value))))

(defun pichat-job--copy (value)
  "Detach JSON-compatible VALUE, including mutable strings and arrays."
  (json-parse-string (json-serialize value :null-object nil :false-object :false)
                     :object-type 'plist :array-type 'array
                     :null-object nil :false-object :false))

(defun pichat-job--now ()
  "Return a UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%S.%NZ" nil t))

(defun pichat-job--stamp (record key time)
  "Set RECORD's optional timestamp KEY to TIME, preserving its list identity.
Older version-1 records omit these keys; prepending a plist entry would detach
it from the store vector rather than update the stored record."
  (if (plist-member record key) (setf (plist-get record key) time)
    (nconc record (list key time))))

(defun pichat-job--id (prefix)
  "Make an opaque identity with PREFIX, independent of runtime identity."
  (concat prefix "-" (substring (secure-hash
                                'sha256 (format "%s:%S:%s" (emacs-pid)
                                                (current-time) (random))) 0 24)))

(defun pichat-job--validate-spec (spec)
  "Validate a captured prompt job SPEC without resolving external settings."
  (unless (and (listp spec)
               (pichat-job--text-p (plist-get spec :title))
               (pichat-job--text-p (plist-get spec :instructions))
               (pichat-job--text-p (plist-get spec :directory))
               (file-name-absolute-p (plist-get spec :directory))
               (consp (plist-get spec :configuration))
               (keywordp (car (plist-get spec :configuration)))
               (vectorp (plist-get spec :resources))
               (> (length (plist-get spec :resources)) 0))
    (pichat-job--fail "Invalid captured job specification"))
  (let (seen)
    (seq-doseq (claim (plist-get spec :resources))
      (let ((key (plist-get claim :key)))
        (unless (and (pichat-job--text-p key)
                     (member (plist-get claim :access) '("write" "read" "observe"))
                     (not (member key seen)))
          (pichat-job--fail "Invalid or duplicate job resource claim"))
        (push key seen))))
  spec)

(defun pichat-job--validate (data)
  "Validate versioned store DATA.  Reject corrupt/future records, never reset."
  (unless (and (listp data) (eql (plist-get data :version) 1)
               (vectorp (plist-get data :jobs))
               (vectorp (plist-get data :runs)))
    (pichat-job--fail "Unsupported or invalid PiChat job store"))
  (let (ids)
    (dolist (kind '(:jobs :runs))
      (seq-doseq (record (plist-get data kind))
        (let ((id (plist-get record :id)))
          (unless (and (pichat-job--text-p id) (not (member id ids))
                       (pichat-job--text-p (plist-get record :created-at))
                       (pichat-job--text-p (plist-get record :updated-at)))
            (pichat-job--fail "Invalid or duplicate job/run identity"))
          (push id ids))
        (pichat-job--validate-spec (plist-get record :spec))
        (when (eq kind :runs)
          (dolist (key '(:started-at :finished-at :resolved-at))
            (when (and (plist-get record key)
                       (not (pichat-job--text-p (plist-get record key))))
              (pichat-job--fail "Invalid run timestamp")))
          (let ((state (plist-get record :state))
                (result (plist-get record :result)))
            (unless (and (member state (append '("queued" "finished")
                                               pichat-job--active-states))
                         (if (equal state "finished")
                             (member result pichat-job--results)
                           (null result))
                         (or (null (plist-get record :job-id))
                             (pichat-job--text-p (plist-get record :job-id)))
                         (equal (plist-get (plist-get record :trigger) :kind)
                                "manual")
                         (or (not (member state pichat-job--active-states))
                             (pichat-job--text-p (plist-get record :attempt))))
              (pichat-job--fail "Invalid job run lifecycle record")))))))
  data)

(defun pichat-job--read-bytes (file)
  "Read bounded local FILE without decoding or evaluating it, or return nil."
  (when (file-symlink-p file)
    (pichat-job--fail "Job store cannot be a symbolic link"))
  (when (file-exists-p file)
    (unless (and (file-regular-p file)
                 (<= (file-attribute-size (file-attributes file))
                     pichat-job--max-file-bytes))
      (pichat-job--fail "Job store is not a bounded regular file"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun pichat-job-store-open (file)
  "Read local FILE into a new store without writes, execution or recovery.
An absent file represents an empty store.  Invalid data signals an error;
it is never overwritten with an empty history.  Call `pichat-job-reconcile'
explicitly at executor startup, not on UI refresh."
  (setq file (expand-file-name file))
  (when (file-remote-p file)
    (pichat-job--fail "Job metadata must be stored locally"))
  (let* ((bytes (pichat-job--read-bytes file))
         (data (if bytes
                   (json-parse-string (decode-coding-string bytes 'utf-8)
                                      :object-type 'plist :array-type 'array
                                      :null-object nil :false-object :false)
                 '(:version 1 :jobs [] :runs []))))
    (pichat-job--make-store :file file :bytes bytes
                            :data (pichat-job--validate data))))

(defun pichat-job--commit (store data)
  "Atomically replace STORE with validated DATA, publishing only after success."
  (pichat-job--validate data)
  (let* ((file (pichat-job-store-file store))
         (directory (file-name-directory file))
         (bytes (encode-coding-string
                 (concat (json-serialize data :null-object nil :false-object :false)
                         "\n") 'utf-8-unix))
         temporary locked)
    (when (> (length bytes) pichat-job--max-file-bytes)
      (pichat-job--fail "Job store size limit reached; nothing was written"))
    (make-directory directory t)
    (unwind-protect
        (progn
          (let ((owner (file-locked-p file)))
            (when (and owner (not (eq owner t)))
              (pichat-job--fail "Job store is locked by another Emacs"))
            (unless owner
              (lock-file file)
              (setq locked t)))
          (unless (equal (pichat-job-store-bytes store)
                         (pichat-job--read-bytes file))
            (pichat-job--fail "Job store changed on disk; reload before writing"))
          (setq temporary (make-temp-file (expand-file-name ".pichat-jobs-" directory)))
          (set-file-modes temporary #o600)
          (let ((coding-system-for-write 'no-conversion)
                (write-region-inhibit-fsync nil))
            (write-region bytes nil temporary nil 'silent))
          (rename-file temporary file t)
          (setq temporary nil)
          (setf (pichat-job-store-data store) data
                (pichat-job-store-bytes store) bytes))
      (when temporary (delete-file temporary))
      (when locked (unlock-file file))))
  store)

(defun pichat-job-records (store kind)
  "Return detached records from STORE of KIND, either `jobs' or `runs'."
  (unless (memq kind '(jobs runs)) (pichat-job--fail "Invalid record kind"))
  (pichat-job--copy (plist-get (pichat-job-store-data store)
                              (if (eq kind 'jobs) :jobs :runs))))

(defun pichat-job--find (data kind id)
  "Find ID in DATA's KIND vector or signal a job error."
  (or (seq-find (lambda (record) (equal (plist-get record :id) id))
                (plist-get data kind))
      (pichat-job--fail "Unknown job/run: %s" id)))

(defun pichat-job-record (store kind id)
  "Return a detached record of KIND identified by ID from STORE."
  (unless (memq kind '(jobs runs)) (pichat-job--fail "Invalid record kind"))
  (pichat-job--copy (pichat-job--find (pichat-job-store-data store)
                                    (if (eq kind 'jobs) :jobs :runs) id)))

(defun pichat-job-save (store spec &optional id)
  "Save captured SPEC in STORE without executing it; return its stable ID.
With ID, edit that definition.  Existing run snapshots are never changed."
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (spec (pichat-job--validate-spec (pichat-job--copy spec)))
         (now (pichat-job--now))
         (record (if id (pichat-job--find data :jobs id)
                   (list :id (pichat-job--id "job") :created-at now
                         :updated-at now :spec nil))))
    (setf (plist-get record :spec) spec
          (plist-get record :updated-at) now)
    (unless id
      (setf (plist-get data :jobs)
            (vconcat (plist-get data :jobs) (vector record))))
    (pichat-job--commit store data)
    (copy-sequence (plist-get record :id))))

(defun pichat-job-enqueue (store spec &optional job-id queue-limit repeat-of)
  "Persist one manual attempt in STORE and return its ID; never start it.
Use inline SPEC for one-offs.  With JOB-ID, SPEC must be nil and the current
saved definition is captured.  QUEUE-LIMIT defaults to 20.  At most one queued
or active attempt per saved definition is allowed.  REPEAT-OF captures
historical provenance and retains its definition's exclusion even when
settings are edited."
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (runs (plist-get data :runs))
         (limit (or queue-limit 20)))
    (unless (and (integerp limit) (> limit 0))
      (pichat-job--fail "Queue limit must be positive"))
    (when (>= (seq-count (lambda (run) (equal (plist-get run :state) "queued"))
                        runs) limit)
      (pichat-job--fail "Job queue is full"))
    (when repeat-of
      (when job-id (pichat-job--fail "Choose a saved job or historical attempt"))
      (let ((origin (pichat-job--find data :runs repeat-of)))
        (setq job-id (plist-get origin :job-id)
              spec (or spec (plist-get origin :spec)))))
    (when job-id
      (unless repeat-of
        (when spec (pichat-job--fail "Choose inline work or a saved job, not both"))
        (setq spec (plist-get (pichat-job--find data :jobs job-id) :spec)))
      (when (seq-some (lambda (run)
                        (and (equal job-id (plist-get run :job-id))
                             (not (equal (plist-get run :state) "finished")))) runs)
        (pichat-job--fail "This job already has a queued or active attempt")))
    (let* ((now (pichat-job--now))
           (run (list :id (pichat-job--id "run") :job-id job-id
                      :created-at now :updated-at now
                      :spec (pichat-job--validate-spec (pichat-job--copy spec))
                      :trigger (append '(:kind "manual")
                                       (when repeat-of (list :repeat-of repeat-of)))
                      :state "queued" :result nil
                      :attempt nil :reason nil :summary nil :runtime-id nil :session-file nil)))
      (setf (plist-get data :runs) (vconcat runs (vector run)))
      (pichat-job--commit store data)
      (copy-sequence (plist-get run :id)))))

(defun pichat-job--conflicting-resource (left right)
  "Return a resource key conflicting between LEFT and RIGHT run snapshots."
  (catch 'conflict
    (seq-doseq (a (plist-get (plist-get left :spec) :resources))
      (seq-doseq (b (plist-get (plist-get right :spec) :resources))
        (when (and (equal (plist-get a :key) (plist-get b :key))
                   (not (member "observe" (list (plist-get a :access)
                                               (plist-get b :access))))
                   (member "write" (list (plist-get a :access)
                                         (plist-get b :access))))
          (throw 'conflict (plist-get a :key)))))
    nil))

(defun pichat-job-admission (store id &optional concurrency)
  "Return admission disposition for queued ID without mutating STORE.
CONCURRENCY defaults to 3.  Uncertain attempts retain their claims and slots.
Earlier conflicting queued attempts take precedence, avoiding writer starvation.
Keys are :ready, :reason and optionally :blocking-run and :resource."
  (let* ((data (pichat-job-store-data store))
         (run (pichat-job--find data :runs id))
         (runs (plist-get data :runs))
         (limit (or concurrency 3))
         (active (seq-filter
                  (lambda (r) (member (plist-get r :state) pichat-job--active-states))
                  runs)))
    (unless (and (integerp limit) (> limit 0))
      (pichat-job--fail "Concurrency limit must be positive"))
    (pichat-job--copy
     (cond
      ((not (equal (plist-get run :state) "queued"))
       '(:ready :false :reason "Run is not queued"))
      ((>= (length active) limit)
       '(:ready :false :reason "Global concurrency limit"))
      (t
       (or (catch 'blocked
             (let ((earlier t))
               (seq-doseq (other runs)
                 (if (equal id (plist-get other :id))
                     (setq earlier nil)
                   (when (or (member (plist-get other :state) pichat-job--active-states)
                             (and earlier (equal (plist-get other :state) "queued")))
                     (when-let* ((key (pichat-job--conflicting-resource run other)))
                       (throw 'blocked
                              (list :ready :false :reason "Conflicting workspace/resource"
                                    :blocking-run (plist-get other :id) :resource key)))))))
             nil)
           '(:ready t :reason nil)))))))

(defun pichat-job-claim (store id &optional concurrency)
  "Durably admit queued ID before any spawn; return its detached run record.
The :attempt token belongs to this execution lifetime.  Blocked admission
signals an error without changing STORE.  No runtime is launched."
  (let ((admission (pichat-job-admission store id concurrency)))
    (unless (eq (plist-get admission :ready) t)
      (pichat-job--fail "%s" (plist-get admission :reason))))
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (run (pichat-job--find data :runs id)))
    (setf (plist-get run :state) "starting"
          (plist-get run :attempt) (pichat-job--id "attempt")
          (plist-get run :updated-at) (pichat-job--now))
    (pichat-job--stamp run :started-at (plist-get run :updated-at))
    (pichat-job--commit store data)
    (pichat-job--copy run)))

(defun pichat-job-advance (store id attempt state &optional details)
  "Record an executor-owned transition of ID with ATTEMPT in STORE to STATE.
Stale/duplicate transitions return nil.  DETAILS may contain :runtime-id,
:session-file, :reason and :result.  Finishing additionally requires
:safe-to-release t from the executor, not an agent-produced outcome.  Completed
or needs-review results require the settling state and :synchronized t.
Uncertainty cannot be cleared by a late callback; reconciliation is separate."
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (run (pichat-job--find data :runs id))
         (old (plist-get run :state))
         (allowed (pcase old
                    ("starting" '("running" "finished" "uncertain"))
                    ("running" '("settling" "finished" "uncertain"))
                    ("settling" '("finished" "uncertain")))))
    (when (and (pichat-job--text-p attempt)
               (equal attempt (plist-get run :attempt))
               (member state allowed))
      (when (equal state "finished")
        (unless (and (eq (plist-get details :safe-to-release) t)
                     (member (plist-get details :result) pichat-job--results)
                     (or (member (plist-get details :result) '("failed" "cancelled"))
                         (and (equal old "settling")
                              (eq (plist-get details :synchronized) t))))
          (pichat-job--fail "Finishing requires verified release/result evidence")))
      (dolist (key '(:runtime-id :session-file :reason :summary))
        (when (plist-member details key)
          (let ((value (plist-get details key)))
            (unless (or (null value) (stringp value))
              (pichat-job--fail "Invalid executor metadata"))
            (setf (plist-get run key) (and value (copy-sequence value))))))
      (setf (plist-get run :state) state
            (plist-get run :result) (and (equal state "finished")
                                         (copy-sequence (plist-get details :result)))
            (plist-get run :updated-at) (pichat-job--now))
      (when (equal state "finished")
        (pichat-job--stamp run :finished-at (plist-get run :updated-at)))
      (pichat-job--commit store data)
      (pichat-job--copy run))))

(defun pichat-job-cancel-queued (store id)
  "Cancel queued ID in STORE without claiming that a running process stopped."
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (run (pichat-job--find data :runs id)))
    (unless (equal (plist-get run :state) "queued")
      (pichat-job--fail "Only queued attempts can be cancelled without an executor"))
    (setf (plist-get run :state) "finished"
          (plist-get run :result) "cancelled"
          (plist-get run :reason) "Cancelled before dispatch"
          (plist-get run :updated-at) (pichat-job--now))
    (pichat-job--stamp run :finished-at (plist-get run :updated-at))
    (pichat-job--commit store data)))

(defun pichat-job-reconcile (store)
  "Persist restart reconciliation of STORE without replaying any work.
Call only when no executor still owns this store.  Queued work is cancelled;
possibly dispatched work becomes uncertain and retains resource claims.
This deliberately cannot infer remote survival or safe release from Emacs exit."
  (let ((data (pichat-job--copy (pichat-job-store-data store))) changed)
    (seq-doseq (run (plist-get data :runs))
      (let ((state (plist-get run :state)))
        (when (member state '("queued" "starting" "running" "settling"))
          (setq changed t)
          (setf (plist-get run :state) (if (equal state "queued") "finished" "uncertain")
                (plist-get run :result) (and (equal state "queued") "cancelled")
                (plist-get run :reason) (if (equal state "queued")
                                            "Not dispatched; queue not replayed after restart"
                                          "Execution interrupted; inspect before releasing claims")
                (plist-get run :updated-at) (pichat-job--now))
          (when (equal state "queued")
            (pichat-job--stamp run :finished-at (plist-get run :updated-at))))))
    (when changed (pichat-job--commit store data))
    changed))

(defun pichat-job-resolve-uncertain (store id acknowledgement)
  "Release uncertain ID after explicit human ACKNOWLEDGEMENT in STORE.
This records manual resolution, not verified process shutdown or completion.
The executor must ensure no callbacks can dispatch work for this attempt."
  (unless (pichat-job--text-p acknowledgement)
    (pichat-job--fail "Manual resolution requires an inspection acknowledgement"))
  (let* ((data (pichat-job--copy (pichat-job-store-data store)))
         (run (pichat-job--find data :runs id)))
    (unless (equal (plist-get run :state) "uncertain")
      (pichat-job--fail "Only uncertain attempts can be manually resolved"))
    (setf (plist-get run :state) "finished"
          (plist-get run :result) "needs-review"
          (plist-get run :reason)
          (concat "Manually released; shutdown not verified: " acknowledgement)
          (plist-get run :updated-at) (pichat-job--now))
    (pichat-job--stamp run :resolved-at (plist-get run :updated-at))
    (pichat-job--commit store data)))

(provide 'pichat-job-core)
;;; pichat-job-core.el ends here
