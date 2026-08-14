;;; pichat-test-archive.el --- pi-archive boundary tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused protocol, provenance, normalization, and ownership tests.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-archive--metadata (&rest overrides)
  "Return complete raw session metadata with OVERRIDES."
  (let ((value (copy-tree
                '(:sessionId "session-1"
                  :sessionFile "/sessions/session-1.jsonl"
                  :cwd "/project" :sessionName "Named"
                  :firstUserPrompt "First" :branchFirstUserPrompt nil
                  :title "Named" :displayTitle "Named"
                  :createdAt "2026-01-01T00:00:00.000Z"
                  :latestActivityAt "2026-01-01T01:00:00.000Z"
                  :sourceExists t :syncStatus "current"
                  :parentSessionPath nil :parentSessionId nil
                  :parentResolution "none" :childCount 0))))
    (while overrides
      (setq value (plist-put value (pop overrides) (pop overrides))))
    value))

(defun pichat-test-archive--status (&rest overrides)
  "Return complete protocol status with OVERRIDES."
  (let ((value (list :queryProtocolVersion 1 :schemaVersion 3
                     :stableApiVersion 1 :searchPolicyVersion 1
                     :database (pichat-archive-standard-database)
                     :backfillStatus "complete" :lastCompleteScanAt nil
                     :lastSuccessfulSyncAt nil :lastErrorAt nil
                     :lastErrorCode nil :lastErrorMessage nil)))
    (while overrides
      (setq value (plist-put value (pop overrides) (pop overrides))))
    value))

(cl-defmacro pichat-test-archive--with-package ((source helper) &rest body)
  "Create a host-readable archive package and bind SOURCE and HELPER for BODY."
  (declare (indent 1))
  `(pichat-test-with-temp-dir package-root
     (let* ((extension-dir (expand-file-name "extensions" package-root))
            (bin-dir (expand-file-name "bin" package-root))
            (,source (expand-file-name "archive.ts" extension-dir))
            (,helper (expand-file-name "pi-archive-query.mjs" bin-dir)))
       (make-directory extension-dir)
       (make-directory bin-dir)
       (with-temp-file ,source (insert "// fixture\n"))
       (with-temp-file ,helper (insert "// fixture\n"))
       ,@body)))

(ert-deftest pichat-archive-recognizes-only-exact-extension-marker-provenance ()
  (pichat-test-archive--with-package (source _helper)
    (let ((current (list :name "pi-archive-status-v1" :source "extension"
                         :sourceInfo (list :path source)))
          (legacy (list :name "pi-archive-status-v1" :source "extension"
                        :path source)))
      (should (equal source (pichat-archive-command-source-path current)))
      (should (equal source (pichat-archive-command-source-path legacy)))
      (should-not (pichat-archive-command-source-path
                   (list :name "pi-archive-status-v1" :source "prompt"
                         :path source)))
      (should-not (pichat-archive-command-source-path
                   '(:name "pi-archive-status-v1" :source "extension"
                     :path "<inline:test>")))
      (should (eq 'marker-absent
                  (plist-get (pichat-archive-find-marker nil) :unavailable)))
      (should (eq 'marker-ambiguous
                  (plist-get (pichat-archive-find-marker (list current legacy))
                             :unavailable))))))

(ert-deftest pichat-archive-derives-only-readable-regular-relative-helper ()
  (pichat-test-archive--with-package (source helper)
    (should (equal helper (pichat-archive-helper-for-source source)))
    (should-error (pichat-archive-helper-for-source "relative/archive.ts"))
    (should-error (pichat-archive-helper-for-source "<inline:test>"))
    (delete-file helper)
    (should-error (pichat-archive-helper-for-source source))
    (make-directory helper)
    (should-error (pichat-archive-helper-for-source source))))

(ert-deftest pichat-archive-status-requires-exact-v1-and-standard-database ()
  (should (equal 3 (plist-get
                    (pichat-archive-normalize-status
                     (pichat-test-archive--status))
                    :schemaVersion)))
  (dolist (change '((:queryProtocolVersion 2)
                    (:schemaVersion 2)
                    (:stableApiVersion 2)
                    (:searchPolicyVersion 2)
                    (:database "/tmp/other.db")))
    (should-error
     (pichat-archive-normalize-status
      (apply #'pichat-test-archive--status change)))))

(ert-deftest pichat-archive-builds-all-seven-shell-free-commands ()
  (let* ((capability '(:node "/usr/bin/node" :helper "/pkg/bin/query.mjs"))
         (status (pichat-archive-build-command capability 'status nil))
         (projects (pichat-archive-build-command
                    capability 'projects '(:loadable-only t :limit 20)))
         (recent (pichat-archive-build-command
                  capability 'recent '(:cwd "/work tree" :limit 10)))
         (search (pichat-archive-build-command
                  capability 'search
                  '(:query "\"one\" AND \"two\"" :name-query "\"name\""
                    :text-query "\"text\"" :roles "user,assistant"
                    :cwd "/work tree" :kinds "session_name,user,assistant"
                    :after "2026-01-01T00:00:00Z"
                    :before "2026-02-01T00:00:00Z"
                    :loadable-only t :limit 30 :per-session 4)))
         (session (pichat-archive-build-command
                   capability 'session
                   '(:id "s" :entry-id "e" :kinds "user,assistant"
                     :context 2 :limit 9)))
         (info (pichat-archive-build-command
                capability 'session-info '(:id "s")))
         (relations (pichat-archive-build-command
                     capability 'relations
                     '(:id "s" :direction "both" :limit 12))))
    (should (equal '("/usr/bin/node" "/pkg/bin/query.mjs" "status") status))
    (should (equal '("--loadable-only" "--limit" "20") (nthcdr 3 projects)))
    (should (member "/work tree" recent))
    (should (member "--after" search))
    (should (member "--before" search))
    (should (member "--roles" search))
    (should (equal '("--id" "s" "--entry-id" "e" "--kinds"
                     "user,assistant" "--context" "2" "--limit" "9")
                   (nthcdr 3 session)))
    (should (equal '("--id" "s") (nthcdr 3 info)))
    (should (equal '("--id" "s" "--direction" "both" "--limit" "12")
                   (nthcdr 3 relations)))))

(ert-deftest pichat-archive-decodes-bounded-jsonl-and-structured-errors ()
  (should (equal '((:a 1) (:b :json-false))
                 (pichat-archive-decode-jsonl
                  "{\"a\":1}\n{\"b\":false}\n")))
  (let ((caller (pichat-archive-decode-error
                 "{\"code\":\"INVALID_QUERY\",\"message\":\"bad fts\"}" 2))
        (missing (pichat-archive-decode-error
                  "{\"code\":\"DATABASE_NOT_FOUND\",\"message\":\"gone\"}" 3))
        (garbled (pichat-archive-decode-error "not-json" 1)))
    (should (eq 'caller (plist-get caller :class)))
    (should (eq 'availability (plist-get missing :class)))
    (should (eq 'process (plist-get garbled :class)))))

(ert-deftest pichat-archive-normalizes-search-and-recent-candidates ()
  (let* ((recent (pichat-archive-normalize-recent
                  (pichat-test-archive--metadata)))
         (search-raw
          (append (pichat-test-archive--metadata)
                  '(:matchKind "content" :score 4.5 :matchCount 1
                    :entryId "entry-1" :entryRowId 9 :entryLoadable t
                    :highlightTerms ("needle")
                    :occurrences
                    ((:entryId "entry-1" :entryRowId 9 :role "user"
                      :resultKind "user" :timestamp nil :snippet "needle"
                      :entryLoadable t
                      :context ((:entryId "entry-1" :role "user"
                                 :timestamp nil :text "needle" :match t)))))))
         (search (pichat-archive-normalize-search search-raw)))
    (should (eq 'recent (plist-get recent :match-kind)))
    (should (= 0 (plist-get recent :match-count)))
    (should-not (plist-get recent :entry-id))
    (should (eq 'content (plist-get search :match-kind)))
    (should (plist-get search :entry-loadable))
    (should (equal "needle"
                   (plist-get
                    (car (plist-get (car (plist-get search :occurrences))
                                    :context))
                    :text)))
    (should-error
     (pichat-archive-normalize-search
      (plist-put search-raw :matchKind "unknown")))))

(ert-deftest pichat-archive-session-metadata-requires-amended-v1-fields ()
  (let ((normalized (pichat-archive-normalize-session-metadata
                     (pichat-test-archive--metadata :extra "ignored"))))
    (should (equal "session-1" (plist-get normalized :session-id)))
    (should (equal "Named" (plist-get normalized :display-title)))
    (should-not (plist-get normalized :branch-first-user-prompt))
    (should (eq 'none (plist-get normalized :parent-resolution)))
    (should-not (plist-get normalized :parent-session-id))
    (should (= 0 (plist-get normalized :child-count)))
    (should (plist-get normalized :source-exists))
    (should-not (plist-member normalized :extra)))
  (should-error
   (pichat-archive-normalize-session-metadata
    (pichat-test-archive--metadata :sourceExists nil)))
  (dolist (key '(:title :branchFirstUserPrompt :displayTitle :parentSessionId
                  :parentResolution :childCount))
    (let ((value (pichat-test-archive--metadata)))
      (cl-remf value key)
      (should-error (pichat-archive-normalize-session-metadata value)))))

(ert-deftest pichat-archive-session-metadata-validates-relation-invariants ()
  (let ((resolved
         (pichat-archive-normalize-session-metadata
          (pichat-test-archive--metadata
           :parentSessionPath "/sessions/parent.jsonl"
           :parentSessionId "parent" :parentResolution "resolved"
           :childCount 2 :branchFirstUserPrompt "Continue"
           :displayTitle "Continue"))))
    (should (equal "parent" (plist-get resolved :parent-session-id)))
    (should (equal "Continue" (plist-get resolved :branch-first-user-prompt)))
    (should (= 2 (plist-get resolved :child-count))))
  (dolist (metadata
           (list
            (pichat-test-archive--metadata
             :parentSessionId "parent" :parentResolution "resolved")
            (pichat-test-archive--metadata
             :parentSessionPath "/parent" :parentSessionId "parent")
            (pichat-test-archive--metadata :parentResolution "missing")
            (pichat-test-archive--metadata
             :parentSessionPath "/parent" :parentSessionId "parent"
             :parentResolution "ambiguous")
            (pichat-test-archive--metadata :childCount -1)
            (pichat-test-archive--metadata :displayTitle nil)
            (pichat-test-archive--metadata :parentResolution "unknown")))
    (should-error (pichat-archive-normalize-session-metadata metadata))))

(ert-deftest pichat-archive-validates-session-info-fork-invariants ()
  (let* ((base (pichat-test-archive--metadata
                :parentSessionPath "/sessions/parent.jsonl"
                :parentSessionId "parent" :parentResolution "resolved"
                :childCount 2))
         (observed (append base '(:forkPosition "at" :selectedEntryId "entry"
                                  :sharedBaseEntryId "entry"
                                  :forkPointStatus "observed")))
         (derived (append base '(:forkPosition nil :selectedEntryId nil
                                 :sharedBaseEntryId "base"
                                 :forkPointStatus "derived"))))
    (should (eq 'observed
                (plist-get (pichat-archive-normalize-session-info observed)
                           :fork-point-status)))
    (should (eq 'derived
                (plist-get (pichat-archive-normalize-session-info derived)
                           :fork-point-status)))
    (dolist (invalid
             (list (plist-put (copy-sequence observed) :selectedEntryId nil)
                   (plist-put (copy-sequence derived) :forkPosition "before")
                   (append base '(:forkPosition nil :selectedEntryId nil
                                  :sharedBaseEntryId "bad"
                                  :forkPointStatus "none"))))
      (should-error (pichat-archive-normalize-session-info invalid)))))

(ert-deftest pichat-archive-validates-nested-relations-and-resolution ()
  (let* ((evidence '(:forkPosition nil :selectedEntryId nil
                     :sharedBaseEntryId nil :forkPointStatus "missing"))
         (missing (append
                   (list :sessionId "child" :relatedSession nil
                         :direction "parent" :parentReferencePath "/parent.jsonl"
                         :parentResolution "missing") evidence))
         (child (append
                 (list :sessionId "parent"
                       :relatedSession (pichat-test-archive--metadata)
                       :direction "child" :parentReferencePath "/parent.jsonl"
                       :parentResolution "resolved")
                 '(:forkPosition "before" :selectedEntryId "selected"
                   :sharedBaseEntryId nil :forkPointStatus "observed"))))
    (should-not (plist-get (pichat-archive-normalize-relation missing)
                           :related-session))
    (let ((related (plist-get (pichat-archive-normalize-relation child)
                              :related-session)))
      (should (equal "session-1" (plist-get related :session-id)))
      (should (equal "Named" (plist-get related :display-title)))
      (should (eq 'none (plist-get related :parent-resolution)))
      (should (= 0 (plist-get related :child-count))))
    (should-error
     (pichat-archive-normalize-relation
      (plist-put (copy-sequence child) :relatedSession nil)))
    (should-error
     (pichat-archive-normalize-relation
      (plist-put (copy-sequence missing) :parentReferencePath nil)))))

(ert-deftest pichat-archive-discovery-validates-exact-live-process-and-caches ()
  (pichat-test-with-unit-session (session process)
    (pichat-test-archive--with-package (source helper)
      (with-temp-file helper
        (insert "import os from 'node:os'; import path from 'node:path';\n"
                "console.log(JSON.stringify({queryProtocolVersion:1,schemaVersion:3,stableApiVersion:1,searchPolicyVersion:1,database:path.join(os.homedir(),'.pi','agent','archive.db'),backfillStatus:'running',lastCompleteScanAt:null,lastSuccessfulSyncAt:null,lastErrorAt:null,lastErrorCode:null,lastErrorMessage:null}));\n"))
      (let ((commands-calls 0) capability unavailable)
        (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                   (lambda (owner callback &optional _error)
                     (cl-incf commands-calls)
                     (funcall callback
                              (list :data
                                    (list :commands
                                          (list (list :name "pi-archive-status-v1"
                                                      :source "extension"
                                                      :sourceInfo (list :path source)))))
                              owner)
                     "request")))
          (pichat-archive-discover session (current-buffer)
                                   (lambda (value) (setq capability value))
                                   (lambda (value) (setq unavailable value)))
          (pichat-test-wait-until (lambda () (or capability unavailable)) 3
                                  "archive discovery")
          (should capability)
          (should-not unavailable)
          (should (eq process (plist-get capability :process)))
          (should (equal helper (plist-get capability :helper)))
          (pichat-archive-discover session (current-buffer)
                                   (lambda (value) (setq capability value))
                                   (lambda (value) (setq unavailable value)))
          (should (= 1 commands-calls))
          (setf (pichat-session-session-file session) "/new-source.jsonl")
          (should-not (pichat-archive-cached-capability session)))))))

(ert-deftest pichat-archive-discovers-configured-standalone-source-without-session ()
  (pichat-test-archive--with-package (source helper)
    (with-temp-file helper
      (insert "import os from 'node:os'; import path from 'node:path';\n"
              "console.log(JSON.stringify({queryProtocolVersion:1,schemaVersion:3,stableApiVersion:1,searchPolicyVersion:1,database:path.join(os.homedir(),'.pi','agent','archive.db'),backfillStatus:'complete',lastCompleteScanAt:null,lastSuccessfulSyncAt:null,lastErrorAt:null,lastErrorCode:null,lastErrorMessage:null}));\n"))
    (let ((pichat-archive-standalone-source source) capability unavailable)
      (pichat-archive-discover nil (current-buffer)
                               (lambda (value) (setq capability value))
                               (lambda (value) (setq unavailable value)))
      (pichat-test-wait-until (lambda () (or capability unavailable)) 3
                              "standalone archive discovery")
      (should capability)
      (should-not unavailable)
      (should (eq 'standalone (plist-get capability :kind)))
      (should-not (plist-get capability :session))
      (should (equal helper (plist-get capability :helper)))
      (should (pichat-archive-capability-current-p capability))
      (delete-file source)
      (should-not (pichat-archive-capability-current-p capability)))))

(ert-deftest pichat-archive-standalone-discovery-rejects-invalid-source ()
  (let ((pichat-archive-standalone-source "/missing/archive.ts") success failure)
    (pichat-archive-discover nil (current-buffer)
                             (lambda (value) (setq success value))
                             (lambda (value) (setq failure value)))
    (should-not success)
    (should (eq 'standalone-invalid (plist-get failure :reason)))))

(ert-deftest pichat-archive-discovery-fails-closed-without-live-session ()
  (let ((pichat-archive-standalone-source nil) success failure)
    (pichat-archive-discover nil (current-buffer)
                             (lambda (value) (setq success value))
                             (lambda (value) (setq failure value)))
    (should-not success)
    (should (eq 'no-live-session (plist-get failure :reason)))))

(ert-deftest pichat-archive-discovery-superseding-request-cancels-and-rejects-stale-callback ()
  (pichat-test-with-unit-session (session _process)
    (let (requests cancelled first-result second-result)
      (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                 (lambda (owner success failure)
                   (let ((id (format "request-%d" (1+ (length requests)))))
                     (push (list id owner success failure) requests)
                     id)))
                ((symbol-function 'pichat-rpc-cancel-request)
                 (lambda (_owner id) (push id cancelled))))
        (pichat-archive-discover
         session (current-buffer) (lambda (value) (setq first-result value))
         (lambda (value) (setq first-result value)))
        (let ((first-request (car requests)))
          (pichat-archive-discover
           session (current-buffer) (lambda (value) (setq second-result value))
           (lambda (value) (setq second-result value)))
          (should (member (car first-request) cancelled))
          (funcall (nth 3 first-request) '(:error "late") session)
          (should-not first-result)
          (let ((second-request (car requests)))
            (funcall (nth 3 second-request) '(:error "current") session)
            (should (eq 'command-discovery-failed
                        (plist-get second-result :reason)))))))))

(ert-deftest pichat-archive-discovery-buffer-death-is-bounded-and-silent ()
  (pichat-test-with-unit-session (session _process)
    (let ((buffer (generate-new-buffer " *pichat-archive-owner*"))
          (pichat-archive-discovery-timeout 0.02)
          cancelled result)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                     (lambda (_owner _success _failure) "owned-request"))
                    ((symbol-function 'pichat-rpc-cancel-request)
                     (lambda (_owner id) (setq cancelled id))))
            (pichat-archive-discover session buffer
                                     (lambda (value) (setq result value))
                                     (lambda (value) (setq result value)))
            (kill-buffer buffer)
            (pichat-test-wait-until (lambda () cancelled) 1
                                    "dead-buffer discovery cancellation")
            (should (equal "owned-request" cancelled))
            (should-not result))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-archive-stale-preview-and-relation-outputs-are-rejected ()
  (pichat-test-with-unit-session (session process)
    (let* ((capability
            (list :session session :process process :source-token '(nil nil)
                  :source "/tmp/source" :helper "/tmp/helper" :node "node"
                  :identity '(identity)))
           error-value)
      (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
                 (lambda (_capability) nil)))
        (pichat-archive-request capability 'session '(:id "s") #'ignore
                                (lambda (value) (setq error-value value))))
      (should (equal "STALE_CAPABILITY" (plist-get error-value :code))))))

(ert-deftest pichat-archive-status-uses-runtime-home-for-remote-database ()
  (let ((status (pichat-test-archive--status
                 :database "/home/dev/.pi/agent/archive.db")))
    (should (eq status
                (pichat-archive-normalize-status status "/home/dev")))
    (should-error
     (pichat-archive-normalize-status status "/home/other"))))

(ert-deftest pichat-archive-request-runs-through-capability-transport ()
  (let* ((transport
          (pichat-transport--create
           :id 'remote :kind 'ssh :label "remote"
           :tramp-prefix "/ssh:remote:" :pi-executable "pi"))
         (capability
          (list :transport transport :runtime-cwd "/work"
                :node "node" :helper "/helper" :identity 'remote))
         captured result)
    (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
               (lambda (_capability) t))
              ((symbol-function 'pichat-archive-run)
               (lambda (command callback _failure timeout run-transport cwd)
                 (setq captured (list command timeout run-transport cwd))
                 (funcall callback "")
                 'process)))
      (pichat-archive-request capability 'projects nil
                              (lambda (value) (setq result value)) #'ignore))
    (should (equal nil result))
    (should (eq transport (nth 2 captured)))
    (should (equal "/work" (nth 3 captured)))))

(ert-deftest pichat-rpc-queues-initial-ssh-input-until-transport-is-ready ()
  (let* ((pichat-rpc-remote-startup-delay 30)
         (transport
          (pichat-transport--create
           :id 'remote :kind 'ssh :label "remote"
           :tramp-prefix "/ssh:remote:" :pi-executable "pi"))
         (session
          (pichat-session-make
           :cwd "/ssh:remote:/work/" :runtime-cwd "/work/"
           :transport transport))
         process)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (_transport _cwd &rest args)
                     (setq process
                           (make-process
                            :name "pichat-remote-queue-test"
                            :buffer (plist-get args :buffer)
                            :command '("sh" "-c" "cat >/dev/null")
                            :connection-type 'pipe :noquery t
                            :filter (plist-get args :filter)
                            :sentinel (plist-get args :sentinel)))
                     process)))
          (pichat-rpc-start session)
          (pichat-rpc-get-state session #'ignore)
          (should-not (pichat-session-rpc-ready-p session))
          (should (= 1 (length (pichat-session-rpc-send-queue session))))
          (pichat-rpc--mark-ready session process)
          (should (pichat-session-rpc-ready-p session))
          (should-not (pichat-session-rpc-send-queue session)))
      (when session (ignore-errors (pichat-rpc-stop session)))
      (when (and process (process-live-p process)) (delete-process process))
      (when-let ((buffer (and process (process-buffer process))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-archive)
;;; pichat-test-archive.el ends here
