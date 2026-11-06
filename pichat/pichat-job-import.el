;;; pichat-job-import.el --- Reviewed authored job import -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit preparation and commit against a caller-supplied owning store.
;; No executor initialization, reconciliation, timer ownership or UI policy.
;; Preparation captures settings without registering/spawning Pi; commit saves
;; without submitting work.

;;; Code:
(require 'pichat-job-definition)
(require 'pichat-job-launch)

(cl-defstruct (pichat-job-import-review (:constructor pichat-job-import--review))
  "Prepared import.  Treat as immutable; commit rejects stale store/source data."
  store baseline bytes record job-id previous spec source action diverged)

(defun pichat-job-import--current (record)
  "Reread RECORD's exact scope/file and reject changed or conflicting data."
  (let* ((scope (plist-get record :scope))
         (root (plist-get record :root))
         (file (plist-get record :file)))
    (unless (and (member scope '("global" "project")) (stringp root) (stringp file))
      (pichat-job-definition--fail "Invalid source record; discover definitions again"))
    (let* ((scan (pichat-job-definition-discover
                  (when (equal scope "global") root)
                  (when (equal scope "project") root)))
           (diagnostic (seq-find (lambda (item)
                                   (member (plist-get item :file)
                                           (list file (file-name-directory file) root)))
                                 (plist-get scan :diagnostics)))
           (current (seq-find (lambda (item) (equal (plist-get item :file) file))
                              (plist-get scan :definitions))))
      (unless (equal current record)
        (pichat-job-definition--fail
         "%s: %s" file (if diagnostic (plist-get diagnostic :message)
                        "Source missing, changed or unavailable; discover and review again")))
      current)))

(defun pichat-job-import--job (store identity)
  "Find the unique saved job in STORE with authored IDENTITY."
  (let ((matches (seq-filter (lambda (job)
                               (equal (plist-get (plist-get job :source) :identity) identity))
                             (pichat-job-records store 'jobs))))
    (when (> (length matches) 1)
      (pichat-job--fail "Conflicting saved source identities; inspect the store"))
    (car matches)))

(defun pichat-job-import--authored-digest (record)
  "Hash RECORD's semantic fields, normalizing omitted cwd/target defaults."
  (let ((data (plist-get record :definition)))
    (pichat-job-data-digest
     (append (cl-loop for key in '(:version :id :title :instructions :model :preset)
                      append (list key (plist-get data key)))
             (list :directory (plist-get record :directory)
                   :target (or (plist-get (plist-get data :target) :name) "local"))))))

(defun pichat-job-import--capture (record previous)
  "Capture RECORD through ordinary launch APIs, retaining PREVIOUS add-ons."
  (let* ((data (plist-get record :definition))
         (preset-name (plist-get data :preset))
         (target-name (or (plist-get (plist-get data :target) :name) "local"))
         (preset (car (seq-find (lambda (entry) (equal (symbol-name (car entry)) preset-name))
                                pichat-presets)))
         (target (if (equal target-name "local") 'local
                   (car (seq-find (lambda (entry) (equal (symbol-name (car entry)) target-name))
                                  pichat-targets)))))
    (unless preset (user-error "Unknown named preset: %s" preset-name))
    (unless target (user-error "Unknown named target: %s (no local fallback)" target-name))
    (let ((spec (pichat-job-launch-capture
                 (plist-get data :title) (plist-get data :instructions)
                 (plist-get record :directory)
                 (list :preset preset :model (plist-get data :model) :target target))))
      (dolist (key '(:after-job-id :resources))
        (when (plist-member (plist-get previous :spec) key)
          (setq spec (plist-put spec key (plist-get (plist-get previous :spec) key)))))
      spec)))

(defun pichat-job-import-prepare (store record &optional refresh)
  "Prepare importing discovered RECORD into its owning STORE, without saving.
Return an immutable-by-convention review with action create/update/refresh or
unchanged.  Unchanged semantic data does not recapture settings unless REFRESH
is non-nil.  Native divergence is flagged for explicit replacement confirmation.
Never initializes an executor, starts a runtime, enables timing or submits
work."
  (condition-case err
      (progn
        (pichat-job-store-check store)
        (pichat-job-import--current record)
        (let* ((baseline (pichat-job--copy (pichat-job-store-data store)))
               (bytes (pichat-job-store-bytes store))
               (previous (pichat-job-import--job store (plist-get record :identity)))
               (digest (pichat-job-import--authored-digest record))
               (diverged (pichat-job-source-diverged-p previous))
               (unchanged (and previous (not refresh) (not diverged)
                               (equal digest (plist-get (plist-get previous :source) :authored-digest))))
               (spec (unless unchanged (pichat-job-import--capture record previous)))
               (source (unless unchanged
                         (list :version 1 :identity (plist-get record :identity)
                               :file (plist-get record :file) :authored-digest digest
                               :spec-digest (pichat-job-spec-digest spec)))))
          (pichat-job-import--review
           :store store :baseline baseline :bytes bytes :record (pichat-job--copy record)
           :job-id (plist-get previous :id) :previous previous :spec spec :source source
           :action (cond (unchanged "unchanged") ((not previous) "create")
                         (refresh "refresh") (t "update"))
           :diverged diverged)))
    (error (pichat-job-definition--fail "%s: %.500s" (plist-get record :file)
                                          (error-message-string err)))))

(defun pichat-job-import-commit (review &optional replace-native-edits)
  "Save prepared REVIEW into its exact owning store; return the saved job ID.
Require REPLACE-NATIVE-EDITS to replace reviewed native divergence.  Reread the
source scope and reject stale source/store state, including on no-op imports.
Unchanged imports perform no capture, timestamp update, write or path relink.
The source path records the last modifying import, not each observed rename."
  (let ((store (pichat-job-import-review-store review)))
    (condition-case err
        (progn
          (pichat-job-import--current (pichat-job-import-review-record review))
          (pichat-job-store-check store)
          (unless (and (equal (pichat-job-store-data store) (pichat-job-import-review-baseline review))
                       (equal (pichat-job-store-bytes store) (pichat-job-import-review-bytes review)))
            (pichat-job--fail "Store changed since import review; prepare and review again"))
          (when (and (pichat-job-import-review-diverged review) (not replace-native-edits))
            (user-error "Saved job has native edits; explicitly confirm their reviewed replacement"))
          (if (equal (pichat-job-import-review-action review) "unchanged")
              (pichat-job-import-review-job-id review)
            (pichat-job-save store (pichat-job-import-review-spec review)
                             (pichat-job-import-review-job-id review)
                             (pichat-job-import-review-source review))))
      (error (pichat-job-definition--fail
              "%s: %.500s" (plist-get (pichat-job-import-review-record review) :file)
              (error-message-string err))))))

(provide 'pichat-job-import)
;;; pichat-job-import.el ends here
