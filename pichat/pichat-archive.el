;;; pichat-archive.el --- pi-archive protocol boundary for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Capability discovery, process ownership, and strict normalization for the
;; versioned pi-archive query protocol.  This module deliberately owns no UI,
;; SQLite knowledge, session switching, or source-navigation state.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-rpc)
(require 'pichat-transport)

(defgroup pichat-archive nil
  "Archive-backed saved-session browsing for PiChat."
  :group 'pichat)

(defcustom pichat-archive-node-program "node"
  "Node.js executable used for archive query helpers."
  :type 'string
  :group 'pichat-archive)

(defcustom pichat-archive-standalone-source nil
  "Optional host path to a trusted pi-archive extension source file.
When no live PiChat RPC process exists, derive the package query helper from
this source and validate its status directly.  A live process remains
authoritative when one exists.  Nil disables standalone discovery."
  :type '(choice (const :tag "Disabled" nil)
                 (file :tag "pi-archive extension source"))
  :group 'pichat-archive)

(defcustom pichat-archive-discovery-timeout 5
  "Seconds allowed for command discovery and helper status validation."
  :type 'number
  :group 'pichat-archive)

(defcustom pichat-archive-query-timeout 15
  "Seconds allowed for an ordinary archive helper operation."
  :type 'number
  :group 'pichat-archive)

(defcustom pichat-archive-output-limit (* 8 1024 1024)
  "Maximum number of helper stdout bytes accepted by PiChat."
  :type 'natnum
  :group 'pichat-archive)

(defconst pichat-archive--marker "pi-archive-status-v1")
(defconst pichat-archive--helper-relative-path "../bin/pi-archive-query.mjs")
(defconst pichat-archive--query-protocol-version 1)
(defconst pichat-archive--schema-version 3)
(defconst pichat-archive--stable-api-version 1)
(defconst pichat-archive--search-policy-version 1)
(defconst pichat-archive--session-metadata-keys
  '(:sessionId :sessionFile :cwd :sessionName :firstUserPrompt
    :branchFirstUserPrompt :title :displayTitle :createdAt :latestActivityAt
    :sourceExists :syncStatus :parentSessionPath :parentSessionId
    :parentResolution :childCount))

(defvar pichat-archive--capability-cache
  (make-hash-table :test #'eq :weakness 'key)
  "Validated capabilities keyed by PiChat session object.")

(defvar pichat-archive--request-sequence 0
  "Monotonic sequence for helper and discovery ownership.")

(defvar pichat-archive--discovery-sequence 0
  "Monotonic sequence used to supersede browse discovery.")

(defvar pichat-archive--active-discovery-cancel nil
  "Cancellation closure for the one active capability discovery.")

(defvar pichat-archive--processes nil
  "Live helper processes owned by the archive boundary.")

(defun pichat-archive-reset ()
  "Cancel archive work and clear all validated capabilities and result caches."
  (interactive)
  (pichat-archive-cancel-discovery)
  (dolist (process (copy-sequence pichat-archive--processes))
    (when (process-live-p process) (delete-process process)))
  (setq pichat-archive--processes nil)
  (clrhash pichat-archive--capability-cache))

(defun pichat-archive-node-executable ()
  "Return the configured Node executable, or nil when unavailable."
  (if (file-name-absolute-p pichat-archive-node-program)
      (and (file-executable-p pichat-archive-node-program)
           (not (file-directory-p pichat-archive-node-program))
           pichat-archive-node-program)
    (executable-find pichat-archive-node-program)))

(defun pichat-archive--nonblank-string-p (value)
  "Return non-nil when VALUE is a nonblank string."
  (and (stringp value) (not (string-empty-p (string-trim value)))))

(defun pichat-archive--nullable-string-p (value)
  "Return non-nil when VALUE is nil or a string."
  (or (null value) (stringp value)))

(defun pichat-archive--json-boolean-p (value)
  "Return non-nil when VALUE is a decoded JSON boolean."
  (or (eq value t) (eq value :json-false)))

(defun pichat-archive--boolean (value)
  "Normalize decoded JSON boolean VALUE to an Emacs boolean."
  (unless (pichat-archive--json-boolean-p value)
    (error "Expected JSON boolean, got %S" value))
  (eq value t))

(defun pichat-archive--natural-p (value)
  "Return non-nil when VALUE is an integer at least zero."
  (and (integerp value) (>= value 0)))

(defun pichat-archive--require-key (object key predicate)
  "Return OBJECT's KEY value after requiring PREDICATE."
  (unless (and (listp object) (plist-member object key))
    (error "Missing archive field %s" key))
  (let ((value (plist-get object key)))
    (unless (funcall predicate value)
      (error "Invalid archive field %s: %S" key value))
    value))

(defun pichat-archive--enum-p (value values)
  "Return non-nil when string VALUE is a member of VALUES."
  (and (stringp value) (member value values)))

(defun pichat-archive--normalize-path (path)
  "Return a lexical absolute normalized form of PATH."
  (when (stringp path)
    (directory-file-name (expand-file-name path))))

(defun pichat-archive-standard-database (&optional runtime-home)
  "Return the standard archive path under optional RUNTIME-HOME."
  (pichat-archive--normalize-path
   (if runtime-home
       (expand-file-name ".pi/agent/archive.db" runtime-home)
     "~/.pi/agent/archive.db")))

(defun pichat-archive--pseudo-path-p (path)
  "Return non-nil when PATH is a Pi pseudo source path."
  (and (stringp path) (string-prefix-p "<" path)))

(defun pichat-archive-command-source-path (command)
  "Return an acceptable extension source path from COMMAND, or nil."
  (when (and (listp command)
             (equal (plist-get command :name) pichat-archive--marker)
             (equal (plist-get command :source) "extension"))
    (let ((path (or (plist-get (plist-get command :sourceInfo) :path)
                    (plist-get command :path))))
      (and (pichat-archive--nonblank-string-p path)
           (file-name-absolute-p path)
           (not (pichat-archive--pseudo-path-p path))
           path))))

(defun pichat-archive-find-marker (commands)
  "Return the unique valid marker command from COMMANDS.
Return an unavailable reason plist when absent or ambiguous."
  (let ((matches (cl-remove-if-not #'pichat-archive-command-source-path commands)))
    (cond
     ((null matches) (list :unavailable 'marker-absent))
     ((cdr matches) (list :unavailable 'marker-ambiguous))
     (t (car matches)))))

(defun pichat-archive-helper-for-source (source &optional transport)
  "Return runtime helper derived from SOURCE and validated via TRANSPORT."
  (let* ((transport (or transport pichat-transport-local))
         (source-file
          (pichat-transport-runtime-file-name transport source)))
    (unless (and (pichat-archive--nonblank-string-p source)
                 (file-name-absolute-p source)
                 (not (pichat-archive--pseudo-path-p source))
                 (file-regular-p source-file)
                 (file-readable-p source-file))
      (error "Archive extension source is not readable through its transport"))
    (let* ((helper (expand-file-name pichat-archive--helper-relative-path
                                     (file-name-directory source)))
           (helper-file
            (pichat-transport-runtime-file-name transport helper)))
      (unless (and (file-name-absolute-p helper)
                   (file-regular-p helper-file)
                   (file-readable-p helper-file))
        (error "Archive query helper is not readable through its transport"))
      helper)))

(defun pichat-archive--source-token (session)
  "Return the source identity currently associated with SESSION."
  (list (pichat-session-id session)
        (pichat-session-session-file session)))

(defun pichat-archive-capability-current-p (capability)
  "Return non-nil when CAPABILITY still identifies its validated owner.
A live capability belongs to one exact Pi process and source token.  A
standalone capability remains current while its trusted source and derived
helper remain directly readable."
  (let* ((source (plist-get capability :source))
         (helper (plist-get capability :helper))
         (transport (or (plist-get capability :transport)
                        pichat-transport-local)))
    (and (file-readable-p
          (pichat-transport-runtime-file-name transport helper))
         (file-readable-p
          (pichat-transport-runtime-file-name transport source))
         (if (eq (plist-get capability :kind) 'standalone)
             (and (null (plist-get capability :session))
                  (null (plist-get capability :process))
                  (pichat-archive--nonblank-string-p
                   pichat-archive-standalone-source)
                  (equal source
                         (expand-file-name
                          pichat-archive-standalone-source)))
           (let ((session (plist-get capability :session))
                 (process (plist-get capability :process)))
             (and session process
                  (eq process (pichat-session-process session))
                  (process-live-p process)
                  (equal (plist-get capability :source-token)
                         (pichat-archive--source-token session))
                  (equal (plist-get capability :transport-id)
                         (pichat-transport-id
                          (pichat-session-transport session)))))))))

(defun pichat-archive-cached-capability (session)
  "Return SESSION's still-current capability, invalidating stale state."
  (let ((capability (gethash session pichat-archive--capability-cache)))
    (if (and capability (pichat-archive-capability-current-p capability))
        capability
      (remhash session pichat-archive--capability-cache)
      nil)))

(defun pichat-archive-invalidate (capability)
  "Invalidate CAPABILITY without affecting unrelated PiChat sessions."
  (when-let ((session (plist-get capability :session)))
    (when (eq capability (gethash session pichat-archive--capability-cache))
      (remhash session pichat-archive--capability-cache))))

(defun pichat-archive--decode-json (text)
  "Decode one compact JSON object from TEXT."
  (json-parse-string text :object-type 'plist :array-type 'list
                     :null-object nil :false-object :json-false))

(defun pichat-archive-decode-jsonl (text)
  "Decode nonblank LF-delimited JSON objects from bounded TEXT."
  (when (> (string-bytes text) pichat-archive-output-limit)
    (error "Archive helper output exceeded %d bytes" pichat-archive-output-limit))
  (let (objects)
    (dolist (line (split-string text "\n" t "[[:space:]\r]+") (nreverse objects))
      (push (pichat-archive--decode-json line) objects))))

(defun pichat-archive--error-class (code exit-status)
  "Classify helper CODE and EXIT-STATUS."
  (cond
   ((member code '("INVALID_ARGUMENT" "INVALID_QUERY")) 'caller)
   ((or (= exit-status 3)
        (member code '("DATABASE_NOT_FOUND" "UNSUPPORTED_SCHEMA"
                       "UNSUPPORTED_STABLE_API" "UNSUPPORTED_SEARCH_POLICY"
                       "DATABASE_CORRUPT"))) 'availability)
   (t 'process)))

(defun pichat-archive-decode-error (stderr exit-status)
  "Return structured helper error from STDERR and EXIT-STATUS."
  (let* ((trimmed (string-trim (or stderr "")))
         (object (condition-case nil
                     (and (not (string-empty-p trimmed))
                          (pichat-archive--decode-json trimmed))
                   (error nil)))
         (code (and object (plist-get object :code)))
         (message-text (and object (plist-get object :message))))
    (list :class (pichat-archive--error-class code exit-status)
          :code (and (stringp code) code)
          :message (if (pichat-archive--nonblank-string-p message-text)
                       (truncate-string-to-width message-text 512 nil nil "…")
                     "Archive helper failed")
          :exit-status exit-status)))

(defun pichat-archive--buffer-text (buffer)
  "Return BUFFER contents without properties."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties (point-min) (point-max)))
    ""))

(defun pichat-archive-run
    (command callback error-callback &optional timeout transport runtime-cwd)
  "Run helper COMMAND through optional TRANSPORT in RUNTIME-CWD.
CALLBACK receives stdout and ERROR-CALLBACK receives a structured error."
  (let* ((stdout (generate-new-buffer " *pichat-archive-output*"))
         (stderr (generate-new-buffer " *pichat-archive-error*"))
         (sequence (cl-incf pichat-archive--request-sequence))
         process timer done)
    (cl-labels
        ((finish (ok value)
           (unless done
             (setq done t)
             (when (timerp timer) (cancel-timer timer))
             (setq pichat-archive--processes
                   (delq process pichat-archive--processes))
             (unwind-protect
                 (funcall (if ok callback error-callback) value)
               (when (buffer-live-p stdout) (kill-buffer stdout))
               (when (buffer-live-p stderr) (kill-buffer stderr)))))
         (sentinel (proc _event)
           (unless (process-live-p proc)
             (if (= 0 (process-exit-status proc))
                 (let ((text (pichat-archive--buffer-text stdout)))
                   (if (> (string-bytes text) pichat-archive-output-limit)
                       (finish nil (list :class 'process :code "OUTPUT_LIMIT"
                                         :message "Archive helper output was too large"
                                         :exit-status 1))
                     (finish t text)))
               (finish nil
                       (pichat-archive-decode-error
                        (pichat-archive--buffer-text stderr)
                        (process-exit-status proc))))))
         (expire ()
           (when (and (not done) (process-live-p process))
             (delete-process process)
             (finish nil (list :class 'availability :code "TIMEOUT"
                               :message "Archive helper timed out"
                               :exit-status 1)))))
      (condition-case condition
          (progn
            (setq process
                  (pichat-transport-make-process
                   (or transport pichat-transport-local)
                   (or runtime-cwd default-directory)
                   :name (format "pichat-archive-%d" sequence)
                   :buffer stdout :stderr stderr :command command
                   :sentinel #'sentinel))
            (set-process-query-on-exit-flag process nil)
            (set-process-coding-system process 'utf-8-unix 'utf-8-unix)
            (push process pichat-archive--processes)
            (when (and timeout (> timeout 0))
              (setq timer (run-at-time timeout nil #'expire)))
            process)
        (error
         (finish nil (list :class 'availability :code "PROCESS_START"
                           :message (error-message-string condition)
                           :exit-status 1))
         nil)))))

(defun pichat-archive-command (capability operation &rest args)
  "Build argv for CAPABILITY OPERATION followed by validated ARGS."
  (unless (member operation '(status projects recent search session
                              session-info relations))
    (error "Unsupported archive operation: %S" operation))
  (append (list (plist-get capability :node)
                (plist-get capability :helper)
                (symbol-name operation))
          args))

(defun pichat-archive--option (name value)
  "Return option NAME and string VALUE when VALUE is non-nil."
  (when value (list name (format "%s" value))))

(defun pichat-archive-build-command (capability operation options)
  "Build exact protocol-v1 command for CAPABILITY, OPERATION, and OPTIONS."
  (let ((limit (plist-get options :limit))
        args)
    (pcase operation
      ('status nil)
      ('projects
       (setq args (append (when (plist-get options :loadable-only)
                            '("--loadable-only"))
                          (pichat-archive--option "--limit" limit))))
      ('recent
       (setq args (append (pichat-archive--option "--cwd" (plist-get options :cwd))
                          (when (plist-get options :loadable-only)
                            '("--loadable-only"))
                          (pichat-archive--option "--limit" limit))))
      ('search
       (setq args
             (append
              (pichat-archive--option "--query" (plist-get options :query))
              (pichat-archive--option "--name-query" (plist-get options :name-query))
              (pichat-archive--option "--text-query" (plist-get options :text-query))
              (pichat-archive--option "--roles" (plist-get options :roles))
              (pichat-archive--option "--cwd" (plist-get options :cwd))
              (pichat-archive--option "--kinds" (plist-get options :kinds))
              (pichat-archive--option "--after" (plist-get options :after))
              (pichat-archive--option "--before" (plist-get options :before))
              (when (plist-get options :loadable-only) '("--loadable-only"))
              (pichat-archive--option "--limit" limit)
              (pichat-archive--option "--per-session"
                                      (plist-get options :per-session)))))
      ('session
       (setq args
             (append (pichat-archive--option "--id" (plist-get options :id))
                     (pichat-archive--option "--entry-id"
                                             (plist-get options :entry-id))
                     (pichat-archive--option "--kinds" (plist-get options :kinds))
                     (pichat-archive--option "--context" (plist-get options :context))
                     (pichat-archive--option "--limit" limit))))
      ('session-info
       (setq args (pichat-archive--option "--id" (plist-get options :id))))
      ('relations
       (setq args
             (append (pichat-archive--option "--id" (plist-get options :id))
                     (pichat-archive--option "--direction"
                                             (plist-get options :direction))
                     (pichat-archive--option "--limit" limit)))))
    (apply #'pichat-archive-command capability operation args)))

(defun pichat-archive-normalize-status (object &optional runtime-home)
  "Validate archive status OBJECT for optional RUNTIME-HOME."
  (let ((database (pichat-archive--require-key
                   object :database #'pichat-archive--nonblank-string-p)))
    (dolist (spec `((:queryProtocolVersion ,pichat-archive--query-protocol-version)
                    (:schemaVersion ,pichat-archive--schema-version)
                    (:stableApiVersion ,pichat-archive--stable-api-version)
                    (:searchPolicyVersion ,pichat-archive--search-policy-version)))
      (unless (= (pichat-archive--require-key object (car spec) #'integerp)
                 (cadr spec))
        (error "Unsupported archive status field %s" (car spec))))
    (unless (equal (pichat-archive--normalize-path database)
                   (pichat-archive-standard-database runtime-home))
      (error "Archive helper opened a nonstandard database"))
    (dolist (key '(:backfillStatus :lastCompleteScanAt :lastSuccessfulSyncAt
                    :lastErrorAt :lastErrorCode :lastErrorMessage))
      (pichat-archive--require-key object key #'pichat-archive--nullable-string-p))
    object))

(defun pichat-archive-normalize-session-metadata (object)
  "Validate OBJECT and return a PiChat-owned session metadata plist."
  (let* ((session-id (pichat-archive--require-key
                      object :sessionId #'pichat-archive--nonblank-string-p))
         (parent-path (pichat-archive--require-key
                       object :parentSessionPath
                       #'pichat-archive--nullable-string-p))
         (parent-id (pichat-archive--require-key
                     object :parentSessionId
                     #'pichat-archive--nullable-string-p))
         (resolution (pichat-archive--require-key
                      object :parentResolution
                      (lambda (value)
                        (pichat-archive--enum-p
                         value '("none" "resolved" "missing" "ambiguous")))))
         (result (list :session-id session-id)))
    (if (equal resolution "resolved")
        (unless (and (pichat-archive--nonblank-string-p parent-path)
                     (pichat-archive--nonblank-string-p parent-id))
          (error "Resolved archive parent lacks path or session ID"))
      (when parent-id
        (error "Unresolved archive parent has session ID"))
      (if (equal resolution "none")
          (when parent-path
            (error "Parentless archive session has a parent path"))
        (unless (pichat-archive--nonblank-string-p parent-path)
          (error "Unresolved archive parent lacks a reference path"))))
    (dolist (spec '((:sessionFile :session-file)
                    (:cwd :cwd) (:sessionName :session-name)
                    (:firstUserPrompt :first-user-prompt)
                    (:branchFirstUserPrompt :branch-first-user-prompt)
                    (:createdAt :created-at)
                    (:latestActivityAt :latest-activity-at)
                    (:syncStatus :sync-status)))
      (setq result
            (plist-put result (cadr spec)
                       (pichat-archive--require-key
                        object (car spec) #'pichat-archive--nullable-string-p))))
    (dolist (spec '((:title :title) (:displayTitle :display-title)))
      (setq result
            (plist-put result (cadr spec)
                       (pichat-archive--require-key object (car spec) #'stringp))))
    (setq result
          (plist-put result :source-exists
                     (pichat-archive--boolean
                      (pichat-archive--require-key
                       object :sourceExists #'pichat-archive--json-boolean-p))))
    (append result
            (list :parent-session-path parent-path
                  :parent-session-id parent-id
                  :parent-resolution (intern resolution)
                  :child-count (pichat-archive--require-key
                                object :childCount
                                #'pichat-archive--natural-p)))))

(defun pichat-archive-normalize-project (object)
  "Validate and normalize archive project OBJECT."
  (list :kind 'project
        :cwd (pichat-archive--require-key object :cwd
                                         #'pichat-archive--nonblank-string-p)
        :count (pichat-archive--require-key object :sessionCount
                                           #'pichat-archive--natural-p)
        :loadable-count
        (pichat-archive--require-key object :loadableSessionCount
                                    #'pichat-archive--natural-p)
        :latest-activity-at
        (pichat-archive--require-key object :latestActivityAt
                                    #'pichat-archive--nullable-string-p)))

(defun pichat-archive--normalize-context (object)
  "Validate one visible session context OBJECT."
  (list :entry-id (pichat-archive--require-key
                   object :entryId #'pichat-archive--nonblank-string-p)
        :role (pichat-archive--require-key object :role
                                          #'pichat-archive--nullable-string-p)
        :timestamp (pichat-archive--require-key
                    object :timestamp #'pichat-archive--nullable-string-p)
        :text (pichat-archive--require-key object :text #'stringp)
        :match (pichat-archive--boolean
                (pichat-archive--require-key
                 object :match #'pichat-archive--json-boolean-p))))

(defun pichat-archive--normalize-occurrence (object)
  "Validate one archive search occurrence OBJECT."
  (let ((context (pichat-archive--require-key object :context #'listp)))
    (list :entry-id (pichat-archive--require-key
                     object :entryId #'pichat-archive--nullable-string-p)
          :entry-row-id (pichat-archive--require-key
                         object :entryRowId
                         (lambda (value) (or (null value)
                                             (pichat-archive--natural-p value))))
          :role (pichat-archive--require-key
                 object :role #'pichat-archive--nullable-string-p)
          :result-kind (pichat-archive--require-key
                        object :resultKind #'pichat-archive--nonblank-string-p)
          :timestamp (pichat-archive--require-key
                      object :timestamp #'pichat-archive--nullable-string-p)
          :snippet (pichat-archive--require-key object :snippet #'stringp)
          :entry-loadable
          (pichat-archive--boolean
           (pichat-archive--require-key object :entryLoadable
                                       #'pichat-archive--json-boolean-p))
          :context (mapcar #'pichat-archive--normalize-context context))))

(defun pichat-archive-normalize-recent (object)
  "Validate recent session OBJECT and add explicit candidate defaults."
  (append (pichat-archive-normalize-session-metadata object)
          (list :match-kind 'recent :match-count 0 :entry-id nil
                :entry-row-id nil :entry-loadable nil :score nil
                :occurrences nil :highlight-terms nil)))

(defun pichat-archive-normalize-search (object)
  "Validate and normalize aggregate archive search OBJECT."
  (let ((kind (pichat-archive--require-key
               object :matchKind
               (lambda (value) (pichat-archive--enum-p
                                value '("name" "title" "content")))))
        (terms (pichat-archive--require-key object :highlightTerms #'listp))
        (occurrences (pichat-archive--require-key object :occurrences #'listp)))
    (unless (cl-every #'stringp terms)
      (error "Invalid archive highlight terms"))
    (append
     (pichat-archive-normalize-session-metadata object)
     (list :match-kind (intern kind)
           :match-count (pichat-archive--require-key
                         object :matchCount #'pichat-archive--natural-p)
           :entry-id (pichat-archive--require-key
                      object :entryId #'pichat-archive--nullable-string-p)
           :entry-row-id (pichat-archive--require-key
                          object :entryRowId
                          (lambda (value) (or (null value)
                                              (pichat-archive--natural-p value))))
           :entry-loadable
           (let ((value (pichat-archive--require-key
                         object :entryLoadable
                         (lambda (item) (or (null item)
                                            (pichat-archive--json-boolean-p item))))))
             (and value (pichat-archive--boolean value)))
           :score (pichat-archive--require-key object :score #'numberp)
           :occurrences (mapcar #'pichat-archive--normalize-occurrence occurrences)
           :highlight-terms terms))))

(defun pichat-archive-normalize-session-row (object)
  "Validate one `session' operation output OBJECT."
  (list :session-id (pichat-archive--require-key
                     object :sessionId #'pichat-archive--nonblank-string-p)
        :entry-id (pichat-archive--require-key
                   object :entryId #'pichat-archive--nonblank-string-p)
        :entry-row-id (pichat-archive--require-key
                       object :entryRowId #'pichat-archive--natural-p)
        :result-kind (pichat-archive--require-key
                      object :resultKind #'pichat-archive--nonblank-string-p)
        :role (pichat-archive--require-key
               object :role #'pichat-archive--nullable-string-p)
        :tool-name (pichat-archive--require-key
                    object :toolName #'pichat-archive--nullable-string-p)
        :timestamp (pichat-archive--require-key
                    object :timestamp #'pichat-archive--nullable-string-p)
        :text (pichat-archive--require-key object :text #'stringp)
        :entry-loadable
        (pichat-archive--boolean
         (pichat-archive--require-key object :entryLoadable
                                     #'pichat-archive--json-boolean-p))
        :match (pichat-archive--boolean
                (pichat-archive--require-key object :match
                                            #'pichat-archive--json-boolean-p))))

(defun pichat-archive--normalize-fork-evidence (object)
  "Validate and normalize fork-point fields from OBJECT."
  (let* ((status (pichat-archive--require-key
                  object :forkPointStatus
                  (lambda (value)
                    (pichat-archive--enum-p
                     value '("observed" "derived" "none" "missing" "ambiguous")))))
         (position (pichat-archive--require-key
                    object :forkPosition
                    (lambda (value) (or (null value)
                                        (pichat-archive--enum-p
                                         value '("before" "at"))))))
         (selected (pichat-archive--require-key
                    object :selectedEntryId #'pichat-archive--nullable-string-p))
         (shared (pichat-archive--require-key
                  object :sharedBaseEntryId #'pichat-archive--nullable-string-p)))
    (pcase status
      ("observed"
       (unless (and position (pichat-archive--nonblank-string-p selected)
                    (or (not (equal position "at"))
                        (equal selected shared)))
         (error "Invalid observed fork-point evidence")))
      ("derived"
       (unless (and (null position) (null selected)
                    (pichat-archive--nonblank-string-p shared))
         (error "Invalid derived fork-point evidence")))
      (_
       (unless (and (null position) (null selected) (null shared))
         (error "Invalid nullable fork-point evidence"))))
    (list :fork-point-status (intern status)
          :fork-position (and position (intern position))
          :selected-entry-id selected
          :shared-base-entry-id shared)))

(defun pichat-archive-normalize-session-info (object)
  "Validate and normalize `session-info' OBJECT."
  (let* ((metadata (pichat-archive-normalize-session-metadata object))
         (resolution (plist-get metadata :parent-resolution))
         (evidence (pichat-archive--normalize-fork-evidence object))
         (fork-status (plist-get evidence :fork-point-status)))
    (when (and (memq resolution '(none missing ambiguous))
               (not (eq resolution fork-status)))
      (error "Parent resolution and fork-point status disagree"))
    (append metadata evidence)))

(defun pichat-archive-normalize-relation (object)
  "Validate and normalize one `relations' OBJECT."
  (let* ((direction (pichat-archive--require-key
                     object :direction
                     (lambda (value) (pichat-archive--enum-p
                                      value '("parent" "child")))))
         (resolution (pichat-archive--require-key
                      object :parentResolution
                      (lambda (value) (pichat-archive--enum-p
                                       value '("none" "resolved" "missing"
                                               "ambiguous")))))
         (reference (pichat-archive--require-key
                     object :parentReferencePath
                     #'pichat-archive--nullable-string-p))
         (related-raw (pichat-archive--require-key
                       object :relatedSession
                       (lambda (value) (or (null value) (listp value)))))
         (related (and related-raw
                       (pichat-archive-normalize-session-metadata related-raw))))
    (unless (pichat-archive--nonblank-string-p reference)
      (error "Emitted archive relation lacks parent reference path"))
    (when (and (equal direction "child") (null related))
      (error "Child archive relation lacks related session"))
    (when (and (equal direction "parent")
               (equal resolution "resolved") (null related))
      (error "Resolved parent archive relation lacks related session"))
    (when (and (equal direction "parent")
               (member resolution '("missing" "ambiguous")) related)
      (error "Unresolved parent archive relation has related session"))
    (append
     (list :session-id (pichat-archive--require-key
                        object :sessionId #'pichat-archive--nonblank-string-p)
           :related-session related :direction (intern direction)
           :parent-reference-path reference
           :parent-resolution (intern resolution))
     (pichat-archive--normalize-fork-evidence object))))

(defun pichat-archive-normalize-output (operation objects)
  "Normalize decoded OBJECTS for archive OPERATION."
  (pcase operation
    ('projects (mapcar #'pichat-archive-normalize-project objects))
    ('recent (mapcar #'pichat-archive-normalize-recent objects))
    ('search (mapcar #'pichat-archive-normalize-search objects))
    ('session (mapcar #'pichat-archive-normalize-session-row objects))
    ('session-info
     (unless (= (length objects) 1)
       (error "session-info returned %d records" (length objects)))
     (pichat-archive-normalize-session-info (car objects)))
    ('relations (mapcar #'pichat-archive-normalize-relation objects))
    (_ (error "Cannot normalize archive operation %S" operation))))

(defun pichat-archive-request (capability operation options callback error-callback)
  "Run OPERATION with OPTIONS for CAPABILITY and normalize its output.
CALLBACK receives normalized data.  ERROR-CALLBACK receives a structured error."
  (if (not (pichat-archive-capability-current-p capability))
      (funcall error-callback
               (list :class 'availability :code "STALE_CAPABILITY"
                     :message "Archive capability is stale" :exit-status 1))
    (let ((identity (plist-get capability :identity)))
      (pichat-archive-run
       (pichat-archive-build-command capability operation options)
       (lambda (stdout)
         (if (not (and (pichat-archive-capability-current-p capability)
                       (equal identity (plist-get capability :identity))))
             (funcall error-callback
                      (list :class 'cancelled :code "STALE_CALLBACK"
                            :message "Archive result became stale" :exit-status 1))
           (condition-case condition
               (funcall callback
                        (pichat-archive-normalize-output
                         operation (pichat-archive-decode-jsonl stdout)))
             (error
              (pichat-archive-invalidate capability)
              (funcall error-callback
                       (list :class 'availability :code "MALFORMED_OUTPUT"
                             :message (error-message-string condition)
                             :exit-status 1))))))
       (lambda (failure)
         (when (memq (plist-get failure :class) '(availability process))
           (pichat-archive-invalidate capability))
         (funcall error-callback failure))
       pichat-archive-query-timeout
       (plist-get capability :transport)
       (plist-get capability :runtime-cwd)))))

(defun pichat-archive--discovery-current-p (token session process buffer)
  "Return non-nil when discovery TOKEN still owns its initiating context."
  (and (= token pichat-archive--discovery-sequence)
       (buffer-live-p buffer)
       (eq process (pichat-session-process session))
       (process-live-p process)))

(defun pichat-archive-cancel-discovery ()
  "Cancel or supersede the current archive capability discovery."
  (interactive)
  (cl-incf pichat-archive--discovery-sequence)
  (when-let ((cancel pichat-archive--active-discovery-cancel))
    (setq pichat-archive--active-discovery-cancel nil)
    (funcall cancel)))

(defun pichat-archive--discover-standalone
    (buffer callback unavailable-callback)
  "Discover configured standalone archive capability for initiating BUFFER."
  (let ((token (cl-incf pichat-archive--discovery-sequence))
        (finished nil)
        status-process cancel-function)
    (cl-labels
        ((current-p ()
           (and (not finished)
                (= token pichat-archive--discovery-sequence)
                (buffer-live-p buffer)))
         (release ()
           (when (eq pichat-archive--active-discovery-cancel cancel-function)
             (setq pichat-archive--active-discovery-cancel nil)))
         (cancel-owned ()
           (unless finished
             (setq finished t)
             (when (process-live-p status-process)
               (delete-process status-process))
             (release)))
         (finish (ok value)
           (when (current-p)
             (setq finished t)
             (release)
             (funcall (if ok callback unavailable-callback) value)))
         (unavailable (reason message-text)
           (finish nil (list :class 'availability :reason reason
                             :message message-text))))
      (setq cancel-function #'cancel-owned
            pichat-archive--active-discovery-cancel cancel-function)
      (condition-case condition
          (let* ((source (expand-file-name pichat-archive-standalone-source))
                 (helper (pichat-archive-helper-for-source source))
                 (node (pichat-archive-node-executable)))
            (unless node (error "Node.js is unavailable"))
            (setq status-process
                  (pichat-archive-run
                   (list node helper "status")
                   (lambda (stdout)
                     (when (current-p)
                       (condition-case status-condition
                           (let* ((objects (pichat-archive-decode-jsonl stdout))
                                  (_ (unless (= 1 (length objects))
                                       (error "Archive status returned %d records"
                                              (length objects))))
                                  (status
                                   (pichat-archive-normalize-status
                                    (car objects))))
                             (finish
                              t
                              (list
                               :kind 'standalone :session nil :process nil
                               :transport pichat-transport-local
                               :transport-id 'local
                               :runtime-cwd default-directory
                               :source source :helper helper :node node
                               :status status
                               :identity
                               (list 'standalone source helper
                                     (cl-incf pichat-archive--request-sequence))
                               :preview-cache (make-hash-table :test #'equal)
                               :session-info-cache
                               (make-hash-table :test #'equal)
                               :relations-cache
                               (make-hash-table :test #'equal))))
                         (error
                          (unavailable 'status-invalid
                                       (error-message-string
                                        status-condition))))))
                   (lambda (failure)
                     (unavailable 'status-failed
                                  (plist-get failure :message)))
                   pichat-archive-discovery-timeout)))
        (error
         (unavailable 'standalone-invalid
                      (error-message-string condition))))
      token)))

(defun pichat-archive-discover (session buffer callback unavailable-callback)
  "Discover archive capability for SESSION and initiating BUFFER.
A live SESSION is authoritative.  Without one, an explicitly configured
`pichat-archive-standalone-source' may supply a host-local capability.  CALLBACK
receives a validated capability.  UNAVAILABLE-CALLBACK receives one structured
reason.  Exactly one callback runs while this request remains current."
  (pichat-archive-cancel-discovery)
  (let ((cached (and session (pichat-archive-cached-capability session)))
        (process (and session (pichat-session-process session))))
    (cond
     (cached (funcall callback cached))
     ((or (null session) (null process) (not (process-live-p process)))
      (if (pichat-archive--nonblank-string-p
           pichat-archive-standalone-source)
          (pichat-archive--discover-standalone
           buffer callback unavailable-callback)
        (funcall unavailable-callback
                 (list :class 'availability :reason 'no-live-session
                       :message "No live PiChat RPC session"))))
     (t
      (let ((token (cl-incf pichat-archive--discovery-sequence))
            (finished nil)
            (transport (pichat-session-transport session))
            (runtime-cwd (pichat-session-runtime-cwd session))
            rpc-id rpc-timer status-process cancel-function)
        (cl-labels
            ((current-p ()
               (and (not finished)
                    (pichat-archive--discovery-current-p
                     token session process buffer)))
             (release ()
               (when (timerp rpc-timer) (cancel-timer rpc-timer))
               (when (eq pichat-archive--active-discovery-cancel
                         cancel-function)
                 (setq pichat-archive--active-discovery-cancel nil)))
             (cancel-owned ()
               (unless finished
                 (setq finished t)
                 (when rpc-id (pichat-rpc-cancel-request session rpc-id))
                 (when (process-live-p status-process)
                   (delete-process status-process))
                 (release)))
             (finish (ok value)
               (when (current-p)
                 (setq finished t)
                 (release)
                 (funcall (if ok callback unavailable-callback) value)))
             (unavailable (reason &optional message-text)
               (finish nil (list :class 'availability :reason reason
                                 :message
                                 (or message-text
                                     (format "Archive unavailable: %s" reason)))))
             (expire-rpc ()
               (unless finished
                 (if (current-p)
                     (progn
                       (when rpc-id
                         (pichat-rpc-cancel-request session rpc-id))
                       (unavailable 'command-timeout))
                   (cancel-owned))))
             (status-ok (stdout source helper node)
               (when (current-p)
                 (condition-case condition
                     (let* ((objects (pichat-archive-decode-jsonl stdout))
                            (_ (unless (= 1 (length objects))
                                 (error "Archive status returned %d records"
                                        (length objects))))
                            (status
                             (pichat-archive-normalize-status
                              (car objects)
                              (pichat-transport-runtime-home transport)))
                            (capability
                             (list
                              :kind 'live :session session :process process
                              :transport transport
                              :transport-id (pichat-transport-id transport)
                              :runtime-cwd runtime-cwd
                              :source source
                              :helper helper :node node :status status
                              :source-token
                              (pichat-archive--source-token session)
                              :identity
                              (list process source helper
                                    (cl-incf pichat-archive--request-sequence))
                              :preview-cache (make-hash-table :test #'equal)
                              :session-info-cache
                              (make-hash-table :test #'equal)
                              :relations-cache
                              (make-hash-table :test #'equal))))
                       (puthash session capability
                                pichat-archive--capability-cache)
                       (finish t capability))
                   (error
                    (unavailable 'status-invalid
                                 (error-message-string condition))))))
             (commands-ok (response response-session)
               (when (and (current-p) (eq response-session session))
                 (when (timerp rpc-timer) (cancel-timer rpc-timer))
                 (condition-case condition
                     (let* ((commands
                             (plist-get (plist-get response :data) :commands))
                            (marker (pichat-archive-find-marker commands)))
                       (if (plist-get marker :unavailable)
                           (unavailable (plist-get marker :unavailable))
                         (let* ((source
                                 (pichat-archive-command-source-path marker))
                                (helper
                                 (pichat-archive-helper-for-source
                                  source transport))
                                (node
                                 (if (eq (pichat-transport-kind transport) 'ssh)
                                     pichat-archive-node-program
                                   (pichat-archive-node-executable))))
                           (unless node (error "Node.js is unavailable"))
                           (setq status-process
                                 (pichat-archive-run
                                  (list node helper "status")
                                  (lambda (stdout)
                                    (status-ok stdout source helper node))
                                  (lambda (failure)
                                    (unavailable
                                     'status-failed
                                     (plist-get failure :message)))
                                  pichat-archive-discovery-timeout
                                  transport runtime-cwd)))))
                   (error
                    (unavailable 'provenance-invalid
                                 (error-message-string condition))))))
             (commands-failed (response response-session)
               (when (and (current-p) (eq response-session session))
                 (unavailable 'command-discovery-failed
                              (format "%s" (plist-get response :error))))))
          (setq cancel-function #'cancel-owned
                pichat-archive--active-discovery-cancel cancel-function
                rpc-id (pichat-rpc-get-commands
                        session #'commands-ok #'commands-failed))
          (when (and (not finished) (> pichat-archive-discovery-timeout 0))
            (setq rpc-timer
                  (run-at-time pichat-archive-discovery-timeout nil
                               #'expire-rpc)))
          token))))))

(provide 'pichat-archive)
;;; pichat-archive.el ends here
