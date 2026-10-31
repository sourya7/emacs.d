;;; pichat-test-job-core.el --- Durable jobs and admission tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Isolated metadata-only behavior.  These tests never launch Pi or use user state.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'pichat-job-core)

(defmacro pichat-test-job--with-store (&rest body)
  "Run BODY with a temporary directory, file and store."
  (declare (indent 0) (debug t))
  `(let* ((directory (make-temp-file "pichat-job-test-" t))
          (file (expand-file-name "jobs.json" directory))
          (store (pichat-job-store-open file)))
     (unwind-protect (progn ,@body)
       (delete-directory directory t))))

(defun pichat-test-job--spec (&optional resource access)
  "Make a captured spec for RESOURCE with ACCESS."
  (list :title "Review dependencies" :instructions "Inspect; do not change files."
        :directory "/example/project/"
        :configuration '(:model "test/model" :target "local"
                         :preset (:name "review" :tools ["read"]))
        :resources (vector (list :key (or resource "local:/example/project/")
                                 :access (or access "write")))))

(defun pichat-test-job--enqueue (store &optional resource access)
  "Enqueue a fresh spec in STORE for RESOURCE and ACCESS."
  (pichat-job-enqueue store (pichat-test-job--spec resource access)))

(ert-deftest pichat-job-read-and-save-do-not-enqueue-or-recover ()
  (pichat-test-job--with-store
    (should-not (file-exists-p file))
    (should (equal (pichat-job-records store 'jobs) []))
    (pichat-job-save store (pichat-test-job--spec))
    (should (equal (pichat-job-records store 'runs) []))
    (let* ((run (pichat-test-job--enqueue store))
           (_claimed (pichat-job-claim store run))
           (before (pichat-job--read-bytes file))
           (reopened (pichat-job-store-open file)))
      (should (equal (plist-get (pichat-job-record reopened 'runs run) :state)
                     "starting"))
      (should (equal before (pichat-job--read-bytes file))))))

(ert-deftest pichat-job-roundtrip-private-versioned-json ()
  (pichat-test-job--with-store
    (let* ((spec (pichat-test-job--spec))
           (_ (setf (plist-get spec :instructions) "Review λ and 日本語"))
           (job (pichat-job-save store spec))
           (run (pichat-job-enqueue store nil job))
           (reopened (pichat-job-store-open file)))
      (should (equal (pichat-job-record store 'jobs job)
                     (pichat-job-record reopened 'jobs job)))
      (should (equal (plist-get (pichat-job-record reopened 'runs run) :spec) spec))
      (should (= (logand (file-modes file) #o777) #o600))
      (should (= (plist-get (json-parse-string (decode-coding-string
                                               (pichat-job--read-bytes file) 'utf-8)
                                              :object-type 'plist) :version) 1)))))

(ert-deftest pichat-job-snapshots-do-not-alias-input-readers-or-definition-edits ()
  (pichat-test-job--with-store
    (let* ((spec (pichat-test-job--spec))
           (job (pichat-job-save store spec))
           (run (pichat-job-enqueue store nil job))
           (view (pichat-job-record store 'runs run))
           (original (pichat-job-record store 'runs run)))
      (aset (plist-get spec :title) 0 ?X)
      (aset (plist-get (plist-get view :spec) :title) 0 ?Y)
      (setf (plist-get spec :instructions) "A changed definition")
      (pichat-job-save store spec job)
      (should (equal (pichat-job-record store 'runs run) original))
      (should-not (equal (plist-get (pichat-job-record store 'jobs job) :spec)
                         (plist-get original :spec))))))

(ert-deftest pichat-job-inline-work-needs-no-definition-or-plan ()
  (pichat-test-job--with-store
    (let ((id (pichat-test-job--enqueue store)))
      (should (equal (pichat-job-records store 'jobs) []))
      (should-not (plist-get (pichat-job-record store 'runs id) :job-id))
      (should (equal (plist-get (pichat-job-record store 'runs id) :trigger)
                     '(:kind "manual"))))))

(ert-deftest pichat-job-queue-and-definition-overlap-are-bounded ()
  (pichat-test-job--with-store
    (let* ((job (pichat-job-save store (pichat-test-job--spec)))
           (id (pichat-job-enqueue store nil job)))
      (should-error (pichat-job-enqueue store nil job) :type 'pichat-job-error)
      (should-error (pichat-job-enqueue store (pichat-test-job--spec) nil 1)
                    :type 'pichat-job-error)
      (pichat-job-claim store id)
      (should-error (pichat-job-enqueue store nil job) :type 'pichat-job-error)
      (should-error (pichat-job-cancel-queued store id) :type 'pichat-job-error)
      (should (= (length (pichat-job-records store 'runs)) 1)))))

(ert-deftest pichat-job-cancel-queued-permits-new-occurrence ()
  (pichat-test-job--with-store
    (let* ((job (pichat-job-save store (pichat-test-job--spec)))
           (id (pichat-job-enqueue store nil job)))
      (pichat-job-cancel-queued store id)
      (should (equal (plist-get (pichat-job-record store 'runs id) :result) "cancelled"))
      (should (pichat-job-enqueue store nil job)))))

(ert-deftest pichat-job-resource-conflict-matrix ()
  (dolist (case '(("read" "read" t) ("read" "write" nil)
                  ("write" "read" nil) ("write" "write" nil)
                  ("observe" "write" t) ("write" "observe" t)))
    (pichat-test-job--with-store
      (let* ((a (pichat-test-job--enqueue store "workspace" (nth 0 case)))
             (_claimed (pichat-job-claim store a))
             (b (pichat-test-job--enqueue store "workspace" (nth 1 case)))
             (decision (pichat-job-admission store b)))
        (should (eq (eq (plist-get decision :ready) t) (nth 2 case)))
        (unless (nth 2 case)
          (should (equal (plist-get decision :blocking-run) a))
          (should-error (pichat-job-claim store b) :type 'pichat-job-error))))))

(ert-deftest pichat-job-no-project-wide-limit-but-shared-resources-conflict ()
  (pichat-test-job--with-store
    (let* ((a (pichat-test-job--enqueue store "worktree-a"))
           (_claimed (pichat-job-claim store a))
           (b (pichat-test-job--enqueue store "worktree-b")))
      ;; Same project label/directory does not replace actual resource identity.
      (should (eq (plist-get (pichat-job-admission store b) :ready) t))
      (pichat-job-claim store b)
      (should (equal (plist-get (pichat-job-record store 'runs b) :state) "starting"))))
  (pichat-test-job--with-store
    (let* ((a (pichat-test-job--spec "worktree-a"))
           (b (pichat-test-job--spec "worktree-b")))
      (dolist (spec (list a b))
        (setf (plist-get spec :resources)
              (vconcat (plist-get spec :resources)
                       [(:key "shared-plan" :access "write")])))
      (pichat-job-claim store (pichat-job-enqueue store a))
      (let ((decision (pichat-job-admission store (pichat-job-enqueue store b))))
        (should (equal (plist-get decision :resource) "shared-plan"))))))

(ert-deftest pichat-job-earlier-writer-is-not-starved-by-later-readers ()
  (pichat-test-job--with-store
    (let* ((reader (pichat-test-job--enqueue store "workspace" "read"))
           (_claimed (pichat-job-claim store reader))
           (writer (pichat-test-job--enqueue store "workspace" "write"))
           (later-reader (pichat-test-job--enqueue store "workspace" "read"))
           (other (pichat-test-job--enqueue store "other" "write")))
      (should (equal (plist-get (pichat-job-admission store later-reader) :blocking-run)
                     writer))
      (should (eq (plist-get (pichat-job-admission store other) :ready) t)))))

(ert-deftest pichat-job-concurrency-counts-uncertain-executions ()
  (pichat-test-job--with-store
    (let* ((id (pichat-test-job--enqueue store "a"))
           (claim (pichat-job-claim store id 1))
           (other (pichat-test-job--enqueue store "b")))
      (pichat-job-advance store id (plist-get claim :attempt) "uncertain"
                          '(:reason "Transport lost"))
      (should (equal (plist-get (pichat-job-admission store other 1) :reason)
                     "Global concurrency limit"))
      (should (eq (plist-get (pichat-job-admission store other 2) :ready) t)))))

(ert-deftest pichat-job-completion-requires-synchronization-and-release-evidence ()
  (pichat-test-job--with-store
    (let* ((id (pichat-test-job--enqueue store))
           (claim (pichat-job-claim store id))
           (token (plist-get claim :attempt)))
      (pichat-job-advance store id token "running" '(:runtime-id "runtime-1"))
      (should-error (pichat-job-advance store id token "finished"
                                        '(:result "completed" :safe-to-release t
                                          :synchronized t))
                    :type 'pichat-job-error)
      (pichat-job-advance store id token "settling")
      (should-error (pichat-job-advance store id token "finished"
                                        '(:result "completed" :safe-to-release t))
                    :type 'pichat-job-error)
      (should-error (pichat-job-advance store id token "finished"
                                        '(:result "completed" :synchronized t))
                    :type 'pichat-job-error)
      (pichat-job-advance store id token "finished"
                          '(:result "needs-review" :synchronized t :safe-to-release t
                            :session-file "/remote/session.jsonl"))
      (let ((run (pichat-job-record store 'runs id)))
        (should (equal (plist-get run :result) "needs-review"))
        (should (equal (plist-get run :session-file) "/remote/session.jsonl")))
      (should-not (pichat-job-advance store id token "finished"
                                     '(:result "completed" :synchronized t
                                       :safe-to-release t))))))

(ert-deftest pichat-job-stale-or-uncertain-callbacks-cannot-release-claims ()
  (pichat-test-job--with-store
    (let* ((id (pichat-test-job--enqueue store))
           (token (plist-get (pichat-job-claim store id) :attempt))
           (before (pichat-job--read-bytes file)))
      (should-not (pichat-job-advance store id "stale" "running"))
      (should (equal before (pichat-job--read-bytes file)))
      (pichat-job-advance store id token "uncertain")
      (should-not (pichat-job-advance store id token "finished"
                                     '(:result "cancelled" :safe-to-release t)))
      (let ((next (pichat-test-job--enqueue store)))
        (should-not (eq (plist-get (pichat-job-admission store next) :ready) t))))))

(ert-deftest pichat-job-restart-preserves-history-and-claims-without-replay ()
  (pichat-test-job--with-store
    (let* ((active (pichat-test-job--enqueue store))
           (claim (pichat-job-claim store active))
           (queued (pichat-test-job--enqueue store "other"))
           (finished (pichat-test-job--enqueue store "third")))
      (pichat-job-cancel-queued store finished)
      (let* ((before (pichat-job-record store 'runs finished))
             (reopened (pichat-job-store-open file)))
        (should (pichat-job-reconcile reopened))
        (should (equal before (pichat-job-record reopened 'runs finished)))
        (should (equal (plist-get (pichat-job-record reopened 'runs queued) :result)
                       "cancelled"))
        (should (equal (plist-get (pichat-job-record reopened 'runs active) :state)
                       "uncertain"))
        (should-not (pichat-job-advance reopened active (plist-get claim :attempt)
                                       "running"))
        (should-not (pichat-job-reconcile reopened))
        (let ((next (pichat-test-job--enqueue reopened)))
          (should (equal (plist-get (pichat-job-admission reopened next) :blocking-run)
                         active)))))))

(ert-deftest pichat-job-corrupt-or-future-store-is-not-overwritten ()
  (pichat-test-job--with-store
    (dolist (text '("not json" "#.(error \"do not evaluate\")"
                    "{\"version\":2,\"jobs\":[],\"runs\":[]}"
                    "{\"version\":1,\"jobs\":[{}],\"runs\":[]}"))
      (with-temp-file file (insert text))
      (should-error (pichat-job-store-open file))
      (should (equal (decode-coding-string (pichat-job--read-bytes file) 'utf-8) text)))))

(ert-deftest pichat-job-persistence-failure-does-not-publish-or-dispatch ()
  (pichat-test-job--with-store
    (let* ((id (pichat-test-job--enqueue store))
           (before (pichat-job--read-bytes file)))
      (cl-letf (((symbol-function 'rename-file)
                 (lambda (&rest _) (signal 'file-error '("Injected rename failure")))))
        (should-error (pichat-job-claim store id)))
      (should (equal before (pichat-job--read-bytes file)))
      (should (equal (plist-get (pichat-job-record store 'runs id) :state) "queued"))
      (should (= (length (directory-files directory nil "\\`[^.]")) 1))
      (should-not (file-locked-p file)))))

(ert-deftest pichat-job-stale-writer-cannot-overwrite-newer-store ()
  (pichat-test-job--with-store
    (let ((stale (pichat-job-store-open file)))
      (pichat-test-job--enqueue store)
      (let ((before (pichat-job--read-bytes file)))
        (should-error (pichat-test-job--enqueue stale) :type 'pichat-job-error)
        (should (equal before (pichat-job--read-bytes file)))
        (should (equal (pichat-job-records stale 'runs) []))))))

(ert-deftest pichat-job-invalid-input-and-duplicate-claims-are-rejected ()
  (pichat-test-job--with-store
    (should-error (pichat-job-enqueue store nil) :type 'pichat-job-error)
    (let ((spec (pichat-test-job--spec)))
      (setf (plist-get spec :resources)
            [(:key "same" :access "write") (:key "same" :access "read")])
      (should-error (pichat-job-enqueue store spec) :type 'pichat-job-error))
    (should-not (file-exists-p file))))

(ert-deftest pichat-job-historical-repeat-keeps-provenance-and-definition-exclusion ()
  (pichat-test-job--with-store
    (let* ((job (pichat-job-save store (pichat-test-job--spec)))
           (origin (pichat-job-enqueue store nil job)))
      (should-error (pichat-job-enqueue store nil nil nil origin)
                    :type 'pichat-job-error)
      (pichat-job-cancel-queued store origin)
      (let* ((changed (pichat-test-job--spec))
             (_ (setf (plist-get changed :instructions) "Current definition"))
             (_ (pichat-job-save store changed job))
             (repeated (pichat-job-enqueue store nil nil nil origin))
             (run (pichat-job-record store 'runs repeated)))
        (should (equal (plist-get run :job-id) job))
        (should (equal (plist-get (plist-get run :trigger) :repeat-of) origin))
        (should-not (equal (plist-get (plist-get run :spec) :instructions)
                           "Current definition"))
        (should-error (pichat-job-enqueue store nil job) :type 'pichat-job-error)))))

(ert-deftest pichat-job-timeline-persists-without-inventing-exit-time ()
  (pichat-test-job--with-store
    (let ((now "2026-10-31T01:00:00Z"))
      (cl-letf (((symbol-function 'pichat-job--now) (lambda () now)))
        (let ((run (pichat-test-job--enqueue store)))
          (setq now "2026-10-31T01:01:00Z")
          (let ((claim (pichat-job-claim store run)))
            (setq now "2026-10-31T01:02:00Z")
            (pichat-job-advance store run (plist-get claim :attempt) "finished"
                                '(:result "failed" :safe-to-release t)))
          (let ((record (pichat-job-record (pichat-job-store-open file) 'runs run)))
            (should (equal (plist-get record :created-at) "2026-10-31T01:00:00Z"))
            (should (equal (plist-get record :started-at) "2026-10-31T01:01:00Z"))
            (should (equal (plist-get record :finished-at) "2026-10-31T01:02:00Z"))))
        (let* ((run (pichat-test-job--enqueue store))
               (claim (pichat-job-claim store run)))
          (pichat-job-advance store run (plist-get claim :attempt) "uncertain")
          (setq now "2026-10-31T01:03:00Z")
          (pichat-job-resolve-uncertain store run "Inspected workspace/processes")
          (let ((record (pichat-job-record (pichat-job-store-open file) 'runs run)))
            (should (equal (plist-get record :resolved-at) now))
            (should-not (plist-get record :finished-at))))))))

(provide 'pichat-test-job-core)
;;; pichat-test-job-core.el ends here
