;;; pichat-pi.el --- Pi protocol compatibility for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; This module is the boundary for Pi session-entry schemas.  It constructs
;; and validates authoritative entry caches and selects the active branch.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-transcript)

(define-error 'pichat-pi-invalid-session "Invalid Pi session entries")

(defun pichat-pi--invalid (format-string &rest args)
  "Signal `pichat-pi-invalid-session' using FORMAT-STRING and ARGS."
  (signal 'pichat-pi-invalid-session
          (list (apply #'format format-string args))))

(defun pichat-pi--entry-id (entry)
  "Return ENTRY's durable id, or signal when it is invalid."
  (let ((id (plist-get entry :id)))
    (unless (and (stringp id) (not (string-empty-p id)))
      (pichat-pi--invalid "Entry has no non-empty string id"))
    id))

(defun pichat-pi--copy-entry (entry)
  "Return a cache-owned copy of raw Pi ENTRY."
  (copy-tree entry t))

(defun pichat-pi-entry-cache-full (session-id session-file entries leaf-id)
  "Build and validate a full entry cache.
SESSION-ID and SESSION-FILE identify the source.  ENTRIES are in Pi append
order and LEAF-ID identifies the active branch leaf."
  (let ((cache (pichat-entry-cache-empty session-id session-file))
        order)
    (dolist (entry entries)
      (let ((id (pichat-pi--entry-id entry)))
        (when (gethash id (pichat-entry-cache-entries-by-id cache))
          (pichat-pi--invalid "Duplicate entry id: %s" id))
        (puthash id (pichat-pi--copy-entry entry)
                 (pichat-entry-cache-entries-by-id cache))
        (push id order)))
    (setq order (nreverse order))
    (setf (pichat-entry-cache-append-order cache) order
          (pichat-entry-cache-last-seen-id cache) (car (last order))
          (pichat-entry-cache-leaf-id cache) leaf-id)
    (pichat-pi-entry-cache-active-branch cache)
    cache))

(defun pichat-pi--copy-entry-table (table)
  "Return a cache-owned copy of entry hash TABLE."
  (let ((copy (make-hash-table :test #'equal :size (hash-table-count table))))
    (maphash (lambda (id entry)
               (puthash id (pichat-pi--copy-entry entry) copy))
             table)
    copy))

(defun pichat-pi-entry-cache-merge (cache entries leaf-id)
  "Return a validated CACHE with incremental ENTRIES and LEAF-ID merged.
CACHE is not modified.  Repeated identical entries are idempotent; an existing
id with different data is rejected."
  (unless (pichat-entry-cache-p cache)
    (pichat-pi--invalid "Cannot merge into a non-entry-cache value"))
  (let* ((table (pichat-pi--copy-entry-table
                 (pichat-entry-cache-entries-by-id cache)))
         (order (copy-sequence (pichat-entry-cache-append-order cache)))
         new-ids
         (candidate
          (pichat-entry-cache-create
           :session-id (pichat-entry-cache-session-id cache)
           :session-file (pichat-entry-cache-session-file cache)
           :entries-by-id table
           :append-order order
           :last-seen-id (pichat-entry-cache-last-seen-id cache)
           :leaf-id leaf-id)))
    (dolist (entry entries)
      (let* ((id (pichat-pi--entry-id entry))
             (existing (gethash id table))
             (owned (pichat-pi--copy-entry entry)))
        (cond
         ((null existing)
          (puthash id owned table)
          (push id new-ids))
         ((not (equal existing owned))
          (pichat-pi--invalid "Conflicting entry id: %s" id)))))
    (setq order (append order (nreverse new-ids)))
    (setf (pichat-entry-cache-append-order candidate) order
          (pichat-entry-cache-last-seen-id candidate) (car (last order)))
    (pichat-pi-entry-cache-active-branch candidate)
    candidate))

(defun pichat-pi-entry-cache-active-branch (cache)
  "Return CACHE's active entries in root-to-leaf order.
Signal `pichat-pi-invalid-session' for inconsistent leaves, missing parents, or
parent cycles."
  (let* ((table (pichat-entry-cache-entries-by-id cache))
         (leaf-id (pichat-entry-cache-leaf-id cache))
         (empty (= 0 (hash-table-count table))))
    (cond
     ((and empty leaf-id)
      (pichat-pi--invalid "Empty entry cache has leaf id: %s" leaf-id))
     ((and (not empty) (null leaf-id))
      (pichat-pi--invalid "Non-empty entry cache has no leaf id"))
     ((null leaf-id) nil)
     (t
      (let ((id leaf-id)
            (seen (make-hash-table :test #'equal))
            branch)
        (while id
          (when (gethash id seen)
            (pichat-pi--invalid "Parent cycle at entry: %s" id))
          (puthash id t seen)
          (let ((entry (gethash id table)))
            (unless entry
              (pichat-pi--invalid "Missing active-branch entry: %s" id))
            (push entry branch)
            (setq id (plist-get entry :parentId))))
        branch)))))

(defconst pichat-pi--diagnostic-limit 100
  "Maximum compatibility diagnostics retained in one transcript build.")

(defun pichat-pi--bounded-type-name (type)
  "Return a bounded non-sensitive display name for TYPE."
  (let ((name (cond
               ((stringp type) type)
               ((symbolp type) (symbol-name type))
               (t "invalid"))))
    (substring name 0 (min 80 (length name)))))

(defun pichat-pi--nested-text (value)
  "Return safe text represented by nested provider VALUE."
  (cond
   ((stringp value) value)
   ((listp value)
    (mapconcat
     (lambda (part)
       (if (and (listp part)
                (equal (plist-get part :type) "text")
                (stringp (plist-get part :text)))
           (plist-get part :text)
         ""))
     value ""))
   (t "")))

(defun pichat-pi--normalize-content (content entry-id diagnose)
  "Normalize message CONTENT owned by ENTRY-ID.
DIAGNOSE is called with category, entry id, and bounded source type."
  (let ((parts (if (stringp content)
                   (list (list :type "text" :text content))
                 (if (listp content) content nil)))
        normalized)
    (cl-loop
     for part in parts
     for index from 0
     do
     (let ((type (and (listp part) (plist-get part :type))))
       (pcase type
         ("text"
          (push (pichat-transcript-content-create
                 :kind 'prose :index index
                 :text (if (stringp (plist-get part :text))
                           (plist-get part :text)
                         ""))
                normalized))
         ("thinking"
          (push (pichat-transcript-content-create
                 :kind 'thinking :index index
                 :text (pichat-pi--nested-text (plist-get part :thinking)))
                normalized))
         ("image"
          (push (pichat-transcript-content-create
                 :kind 'image :index index :text "[image]"
                 :media-type (and (stringp (plist-get part :mediaType))
                                  (plist-get part :mediaType)))
                normalized))
         ((or "toolCall" "tool_call")
          (let ((tool-id (plist-get part :id)))
            (if (and (stringp tool-id) (not (string-empty-p tool-id)))
                (push (pichat-transcript-content-create
                       :kind 'tool :index index :tool-call-id tool-id
                       :name (and (stringp (plist-get part :name))
                                  (plist-get part :name))
                       :arguments (copy-tree (plist-get part :arguments) t)
                       :status 'incomplete :is-error nil)
                      normalized)
              (funcall diagnose 'invalid-tool-call entry-id type)
              (push (pichat-transcript-content-create
                     :kind 'unknown :index index :text "[invalid tool call]"
                     :unknown-type "toolCall")
                    normalized))))
         (_
          (let ((name (pichat-pi--bounded-type-name type)))
            (funcall diagnose 'unknown-content entry-id name)
            (push (pichat-transcript-content-create
                   :kind 'unknown :index index
                   :text (format "[unsupported content: %s]" name)
                   :unknown-type name)
                  normalized))))))
    (nreverse normalized)))

(defun pichat-pi--tool-result-equivalent-p (tool output is-error)
  "Return non-nil when TOOL already contains OUTPUT and IS-ERROR."
  (and (pichat-transcript-content-result-entry-id tool)
       (equal output (pichat-transcript-content-output tool))
       (eq is-error (pichat-transcript-content-is-error tool))))

(defun pichat-pi-build-canonical-transcript (cache)
  "Build a validated canonical transcript from CACHE's active branch."
  (let ((nodes nil)
        (diagnostics nil)
        (diagnostic-count 0)
        (diagnostic-keys (make-hash-table :test #'equal))
        (metadata nil)
        (tools (make-hash-table :test #'equal)))
    (cl-labels
        ((diagnose
          (category entry-id type)
          (let ((key (list category entry-id
                           (pichat-pi--bounded-type-name type))))
            (when (and (< diagnostic-count pichat-pi--diagnostic-limit)
                       (not (gethash key diagnostic-keys)))
              (puthash key t diagnostic-keys)
              (cl-incf diagnostic-count)
              (push (list :category category
                          :entry-id entry-id
                          :type (caddr key))
                    diagnostics))))
         (normalize (content entry-id)
          (pichat-pi--normalize-content content entry-id #'diagnose))
         (register-tools
          (content entry-id)
          (dolist (item content)
            (when (eq 'tool (pichat-transcript-content-kind item))
              (let ((tool-id (pichat-transcript-content-tool-call-id item)))
                (when (gethash tool-id tools)
                  (pichat-pi--invalid
                   "Duplicate declared tool id %s at entry %s"
                   tool-id entry-id))
                (puthash tool-id item tools)))))
         (append-message
          (entry role message-content &optional custom-type)
          (let* ((entry-id (plist-get entry :id))
                 (content (normalize message-content entry-id)))
            (register-tools content entry-id)
            (push (pichat-transcript-node-create
                   :kind 'message :key entry-id :role role :content content
                   :stop-reason (plist-get (plist-get entry :message) :stopReason)
                   :error-message (plist-get (plist-get entry :message) :errorMessage)
                   :custom-type custom-type)
                  nodes)))
         (apply-tool-result
          (entry message)
          (let* ((entry-id (plist-get entry :id))
                 (tool-id (plist-get message :toolCallId))
                 (name (plist-get message :toolName))
                 (is-error (eq t (plist-get message :isError)))
                 (output (normalize (plist-get message :content) entry-id))
                 (tool (and (stringp tool-id) (gethash tool-id tools))))
            (if tool
                (unless (pichat-pi--tool-result-equivalent-p
                         tool output is-error)
                  (when (pichat-transcript-content-result-entry-id tool)
                    (diagnose 'conflicting-tool-result entry-id tool-id))
                  (setf (pichat-transcript-content-output tool) output
                        (pichat-transcript-content-is-error tool) is-error
                        (pichat-transcript-content-status tool)
                        (if is-error 'error 'done)
                        (pichat-transcript-content-result-entry-id tool) entry-id
                        (pichat-transcript-content-name tool)
                        (or (pichat-transcript-content-name tool) name)))
              (let ((orphan
                     (pichat-transcript-content-create
                      :kind 'tool :index 0 :tool-call-id
                      (if (and (stringp tool-id) (not (string-empty-p tool-id)))
                          tool-id
                        (format "orphan:%s" entry-id))
                      :name (and (stringp name) name)
                      :status 'orphan :output output :is-error is-error
                      :result-entry-id entry-id)))
                (push (pichat-transcript-node-create
                       :kind 'tool :key entry-id :content (list orphan))
                      nodes))))))
      (dolist (entry (pichat-pi-entry-cache-active-branch cache))
        (let ((type (or (plist-get entry :type)
                        (plist-get entry :entryType)))
              (entry-id (plist-get entry :id)))
          (pcase type
            ("message"
             (let* ((message (plist-get entry :message))
                    (role (plist-get message :role)))
               (pcase role
                 ("user"
                  (append-message entry 'user (plist-get message :content)))
                 ("assistant"
                  (append-message entry 'assistant (plist-get message :content)))
                 ((or "toolResult" "tool_result")
                  (apply-tool-result entry message))
                 ("custom"
                  (when (eq t (plist-get message :display))
                    (append-message entry 'custom (plist-get message :content)
                                    (plist-get message :customType))))
                 ((or "compactionSummary" "branchSummary" "bashExecution") nil)
                 (_ (diagnose 'unknown-message-role entry-id role)))))
            ((or "custom_message" "customMessage")
             (when (eq t (plist-get entry :display))
               (append-message entry 'custom (plist-get entry :content)
                               (plist-get entry :customType))))
            ((or "compaction" "compaction_summary")
             (push (pichat-transcript-node-create
                    :kind 'activity :key entry-id :activity-type 'compaction
                    :summary (and (stringp (plist-get entry :summary))
                                  (plist-get entry :summary))
                    :tokens-before (plist-get entry :tokensBefore))
                   nodes))
            ("model_change"
             (setq metadata
                   (plist-put metadata :model
                              (list :provider (plist-get entry :provider)
                                    :model-id (plist-get entry :modelId)))))
            ("thinking_level_change"
             (setq metadata
                   (plist-put metadata :thinking-level
                              (plist-get entry :thinkingLevel))))
            ("session_info"
             (setq metadata
                   (plist-put metadata :session-name (plist-get entry :name))))
            ("label"
             (setq metadata
                   (plist-put metadata :labels
                              (append (plist-get metadata :labels)
                                      (list (list :target-id
                                                  (plist-get entry :targetId)
                                                  :label
                                                  (plist-get entry :label)))))))
            ((or "custom" "custom_entry" "branch_summary") nil)
            (_ (diagnose 'unknown-entry entry-id type)))))
      (pichat-transcript-validate
       (pichat-transcript-create
        :nodes (nreverse nodes)
        :diagnostics (nreverse diagnostics)
        :metadata metadata)))))

(defun pichat-pi--live-diagnose (draft category entry-id type)
  "Append a bounded live compatibility diagnostic to DRAFT."
  (let* ((diagnostic (list :category category
                           :entry-id entry-id
                           :type (pichat-pi--bounded-type-name type)))
         (diagnostics (pichat-live-draft-diagnostics draft)))
    (when (and (< (length diagnostics) pichat-pi--diagnostic-limit)
               (not (cl-find diagnostic diagnostics :test #'equal)))
      (setf (pichat-live-draft-diagnostics draft)
            (append diagnostics (list diagnostic))))))

(defun pichat-pi--live-normalize (draft content key)
  "Normalize live CONTENT for DRAFT node KEY."
  (pichat-pi--normalize-content
   content key
   (lambda (category entry-id type)
     (pichat-pi--live-diagnose draft category entry-id type))))

(defun pichat-pi--live-append-node (draft node)
  "Append NODE to DRAFT and return it."
  (setf (pichat-live-draft-nodes draft)
        (append (pichat-live-draft-nodes draft) (list node)))
  node)

(defun pichat-pi--live-tool-attached-p (draft tool)
  "Return non-nil when TOOL is owned by a message node in DRAFT."
  (cl-some
   (lambda (node)
     (and (eq 'message (pichat-transcript-node-kind node))
          (memq tool (pichat-transcript-node-content node))))
   (pichat-live-draft-nodes draft)))

(defun pichat-pi--live-remove-unattached-tool (draft tool)
  "Remove a standalone node containing TOOL from DRAFT."
  (setf (pichat-live-draft-nodes draft)
        (cl-remove-if
         (lambda (node)
           (and (eq 'tool (pichat-transcript-node-kind node))
                (eq tool (car (pichat-transcript-node-content node)))))
         (pichat-live-draft-nodes draft))))

(defun pichat-pi--live-ensure-unattached-tool (draft tool)
  "Ensure DRAFT has a standalone node displaying TOOL."
  (unless (cl-some
           (lambda (node)
             (and (eq 'tool (pichat-transcript-node-kind node))
                  (eq tool (car (pichat-transcript-node-content node)))))
           (pichat-live-draft-nodes draft))
    (pichat-pi--live-append-node
     draft
     (pichat-transcript-node-create
      :kind 'tool
      :key (pichat-live-draft-next-key draft "unattached-tool")
      :content (list tool)))))

(defun pichat-pi--live-tool (draft raw &optional status)
  "Return RAW's correlated tool in DRAFT, creating a standalone one.
When provided, STATUS becomes the new tool status."
  (let* ((tool-id (plist-get raw :toolCallId))
         (valid-id (and (stringp tool-id) (not (string-empty-p tool-id))))
         (tool (and valid-id (gethash tool-id
                                      (pichat-live-draft-tools draft)))))
    (unless valid-id
      (setq tool-id (pichat-live-draft-next-key draft "tool"))
      (pichat-pi--live-diagnose draft 'invalid-tool-event tool-id
                                (plist-get raw :type)))
    (unless tool
      (setq tool
            (pichat-transcript-content-create
             :kind 'tool :index 0 :tool-call-id tool-id
             :name (plist-get raw :toolName)
             :arguments (copy-tree (plist-get raw :args) t)
             :status (or status 'incomplete)))
      (puthash tool-id tool (pichat-live-draft-tools draft))
      (pichat-pi--live-append-node
       draft
       (pichat-transcript-node-create
        :kind 'tool
        :key (pichat-live-draft-next-key draft "unattached-tool")
        :content (list tool))))
    (when (plist-get raw :toolName)
      (setf (pichat-transcript-content-name tool)
            (plist-get raw :toolName)))
    (when (plist-member raw :args)
      (setf (pichat-transcript-content-arguments tool)
            (copy-tree (plist-get raw :args) t)))
    (when status
      (setf (pichat-transcript-content-status tool) status))
    tool))

(defun pichat-pi--live-reconcile-content (draft node raw-content)
  "Replace NODE content from RAW-CONTENT while preserving correlated tools."
  (let ((normalized
         (pichat-pi--live-normalize
          draft raw-content (pichat-transcript-node-key node)))
        result)
    (dolist (content normalized)
      (if (eq 'tool (pichat-transcript-content-kind content))
          (let* ((tool-id (pichat-transcript-content-tool-call-id content))
                 (existing (gethash tool-id
                                    (pichat-live-draft-tools draft)))
                 (tool (or existing content)))
            (when existing
              (setf (pichat-transcript-content-index existing)
                    (pichat-transcript-content-index content)
                    (pichat-transcript-content-name existing)
                    (or (pichat-transcript-content-name content)
                        (pichat-transcript-content-name existing))
                    (pichat-transcript-content-arguments existing)
                    (pichat-transcript-content-arguments content))
              (pichat-pi--live-remove-unattached-tool draft existing)
              (when (eq 'orphan
                        (pichat-transcript-content-status existing))
                (setf (pichat-transcript-content-status existing)
                      (if (pichat-transcript-content-is-error existing)
                          'error
                        'done))))
            (unless existing
              (puthash tool-id tool (pichat-live-draft-tools draft)))
            (push tool result))
        (push content result)))
    (setf (pichat-transcript-node-content node) (nreverse result))))

(defun pichat-pi--live-clear-stream-state (draft)
  "Clear incomplete assistant stream assembly state in DRAFT."
  (clrhash (pichat-live-draft-tool-argument-buffers draft)))

(defun pichat-pi--live-stream-index-p (index)
  "Return non-nil when INDEX is a valid assistant content index."
  (and (integerp index) (>= index 0)))

(defun pichat-pi--live-stream-node (draft event-type)
  "Return DRAFT's current assistant node, diagnosing EVENT-TYPE if absent."
  (let ((node (pichat-live-draft-current-node draft)))
    (if (and node (eq 'assistant (pichat-transcript-node-role node)))
        node
      (pichat-pi--live-diagnose draft 'orphan-assistant-delta nil event-type)
      nil)))

(defun pichat-pi--live-content-at (node index)
  "Return NODE content at protocol INDEX."
  (cl-find index (pichat-transcript-node-content node)
           :key #'pichat-transcript-content-index :test #'=))

(defun pichat-pi--live-insert-stream-content (node content)
  "Insert CONTENT into NODE in protocol index order."
  (setf (pichat-transcript-node-content node)
        (sort (append (pichat-transcript-node-content node) (list content))
              (lambda (left right)
                (< (pichat-transcript-content-index left)
                   (pichat-transcript-content-index right)))))
  content)

(defun pichat-pi--live-ensure-stream-content (draft node index kind event-type)
  "Return NODE's INDEX block of KIND, creating it for EVENT-TYPE."
  (let ((content (pichat-pi--live-content-at node index)))
    (cond
     ((and content (eq kind (pichat-transcript-content-kind content))) content)
     (content
      (pichat-pi--live-diagnose
       draft 'inconsistent-assistant-delta
       (pichat-transcript-node-key node) event-type)
      nil)
     (t
      (setq content
            (pichat-transcript-content-create
             :kind kind :index index :text (and (memq kind '(prose thinking)) "")
             :tool-call-id
             (and (eq kind 'tool)
                  (format "%s-stream-tool-%d"
                          (pichat-transcript-node-key node) index))
             :status (and (eq kind 'tool) 'incomplete)))
      (pichat-pi--live-insert-stream-content node content)
      (when (eq kind 'tool)
        (puthash (pichat-transcript-content-tool-call-id content) content
                 (pichat-live-draft-tools draft)))
      (setf (pichat-live-draft-event-changed-p draft) t)
      content))))

(defun pichat-pi--live-stream-text (draft event kind)
  "Apply text or thinking assistant EVENT of normalized KIND to DRAFT."
  (let* ((type (plist-get event :type))
         (index (plist-get event :contentIndex))
         (node (and (pichat-pi--live-stream-index-p index)
                    (pichat-pi--live-stream-node draft type))))
    (if (not (pichat-pi--live-stream-index-p index))
        (pichat-pi--live-diagnose draft 'invalid-assistant-delta nil type)
      (when node
        (let ((content (pichat-pi--live-ensure-stream-content
                        draft node index kind type)))
          (when content
            (let* ((terminal (string-suffix-p "_end" type))
                   (field (if terminal :content :delta))
                   (value (plist-get event field)))
              (if (not (stringp value))
                  (pichat-pi--live-diagnose
                   draft 'invalid-assistant-delta
                   (pichat-transcript-node-key node) type)
                (let ((updated
                       (if terminal value
                         (concat (or (pichat-transcript-content-text content) "")
                                 value))))
                  (unless (equal updated (pichat-transcript-content-text content))
                    (setf (pichat-transcript-content-text content) updated
                          (pichat-live-draft-event-changed-p draft) t)))))))))))

(defun pichat-pi--live-parse-tool-arguments (text)
  "Parse complete tool argument JSON TEXT, returning (SUCCESS . VALUE)."
  (condition-case nil
      (cons t (json-parse-string text :object-type 'plist :array-type 'list
                                 :null-object nil :false-object nil))
    (error (cons nil nil))))

(defun pichat-pi--live-stream-tool (draft event)
  "Apply a tool-call assistant EVENT to DRAFT."
  (let* ((type (plist-get event :type))
         (index (plist-get event :contentIndex)))
    (if (not (pichat-pi--live-stream-index-p index))
        (pichat-pi--live-diagnose draft 'invalid-assistant-delta nil type)
      (when-let* ((node (pichat-pi--live-stream-node draft type))
                  (tool (pichat-pi--live-ensure-stream-content
                         draft node index 'tool type)))
        (pcase type
          ("toolcall_start"
           (puthash index "" (pichat-live-draft-tool-argument-buffers draft)))
          ("toolcall_delta"
           (let ((delta (plist-get event :delta)))
             (if (not (stringp delta))
                 (pichat-pi--live-diagnose
                  draft 'invalid-assistant-delta
                  (pichat-transcript-node-key node) type)
               (let* ((buffers (pichat-live-draft-tool-argument-buffers draft))
                      (text (concat (or (gethash index buffers) "") delta))
                      (parsed (pichat-pi--live-parse-tool-arguments text)))
                 (puthash index text buffers)
                 (when (and (car parsed)
                            (not (equal (cdr parsed)
                                        (pichat-transcript-content-arguments tool))))
                   (setf (pichat-transcript-content-arguments tool)
                         (copy-tree (cdr parsed) t)
                         (pichat-live-draft-event-changed-p draft) t))))))
          ("toolcall_end"
           (let* ((raw (plist-get event :toolCall))
                  (tool-id (plist-get raw :id))
                  (name (plist-get raw :name)))
             (remhash index (pichat-live-draft-tool-argument-buffers draft))
             (if (not (and (stringp tool-id) (not (string-empty-p tool-id))))
                 (pichat-pi--live-diagnose
                  draft 'invalid-assistant-delta
                  (pichat-transcript-node-key node) type)
               (let ((old-id (pichat-transcript-content-tool-call-id tool)))
                 (when (and old-id (eq tool (gethash old-id
                                                     (pichat-live-draft-tools draft))))
                   (remhash old-id (pichat-live-draft-tools draft)))
                 (setf (pichat-transcript-content-tool-call-id tool) tool-id
                       (pichat-transcript-content-name tool)
                       (and (stringp name) name)
                       (pichat-transcript-content-arguments tool)
                       (copy-tree (plist-get raw :arguments) t)
                       (pichat-live-draft-event-changed-p draft) t)
                 (puthash tool-id tool (pichat-live-draft-tools draft)))))))))))

(defun pichat-pi--live-apply-assistant-event (draft event)
  "Apply one incremental assistant EVENT to DRAFT."
  (let ((type (plist-get event :type)))
    (pcase type
      ((or "text_start" "thinking_start" "toolcall_start")
       (let ((index (plist-get event :contentIndex)))
         (if (not (pichat-pi--live-stream-index-p index))
             (pichat-pi--live-diagnose draft 'invalid-assistant-delta nil type)
           (pcase type
             ("text_start"
              (when-let ((node (pichat-pi--live-stream-node draft type)))
                (pichat-pi--live-ensure-stream-content
                 draft node index 'prose type)))
             ("thinking_start"
              (when-let ((node (pichat-pi--live-stream-node draft type)))
                (pichat-pi--live-ensure-stream-content
                 draft node index 'thinking type)))
             (_ (pichat-pi--live-stream-tool draft event))))))
      ((or "text_delta" "text_end")
       (pichat-pi--live-stream-text draft event 'prose))
      ((or "thinking_delta" "thinking_end")
       (pichat-pi--live-stream-text draft event 'thinking))
      ((or "toolcall_delta" "toolcall_end")
       (pichat-pi--live-stream-tool draft event))
      ((or "start" "done" "error") nil)
      (_ (pichat-pi--live-diagnose draft 'unknown-assistant-delta nil type)))))

(defun pichat-pi--live-message-role (message)
  "Return normalized transcript role for live MESSAGE."
  (pcase (plist-get message :role)
    ("user" 'user)
    ("assistant" 'assistant)
    ("custom" 'custom)))

(defun pichat-pi--live-start-message (draft message)
  "Start or append authoritative live MESSAGE in DRAFT."
  (let ((role (pichat-pi--live-message-role message)))
    (when (and role
               (or (not (eq role 'custom))
                   (eq t (plist-get message :display))))
      (setf (pichat-live-draft-message-final-p draft) nil)
      (when (eq role 'assistant)
        (pichat-pi--live-clear-stream-state draft))
      (let* ((key (pichat-live-draft-next-key draft "message"))
             (node (pichat-transcript-node-create
                    :kind 'message :key key :role role
                    :custom-type (plist-get message :customType))))
        (pichat-pi--live-reconcile-content
         draft node (plist-get message :content))
        (pichat-pi--live-append-node draft node)
        (setf (pichat-live-draft-current-node draft) node)
        node))))

(defun pichat-pi--live-update-message (draft message final)
  "Update DRAFT's current MESSAGE; when FINAL, end its lifecycle."
  (let ((role (pichat-pi--live-message-role message)))
    (when role
      (let ((node (pichat-live-draft-current-node draft)))
        (unless (and node (eq role (pichat-transcript-node-role node)))
          (setq node (pichat-pi--live-start-message draft message)))
        (when node
          (pichat-pi--live-reconcile-content
           draft node (plist-get message :content))
          (setf (pichat-transcript-node-stop-reason node)
                (plist-get message :stopReason)
                (pichat-transcript-node-error-message node)
                (plist-get message :errorMessage)
                (pichat-transcript-node-custom-type node)
                (or (plist-get message :customType)
                    (pichat-transcript-node-custom-type node)))
          (when final
            (pichat-pi--live-clear-stream-state draft)
            (setf (pichat-live-draft-current-node draft) nil
                  (pichat-live-draft-message-final-p draft) t))
          node)))))

(defun pichat-pi--live-apply-tool-result (draft message orphan-status)
  "Apply tool result MESSAGE to DRAFT, using ORPHAN-STATUS if undeclared."
  (let* ((tool-id (plist-get message :toolCallId))
         (existing (and (stringp tool-id)
                        (gethash tool-id (pichat-live-draft-tools draft))))
         (tool (or existing
                   (pichat-pi--live-tool
                    draft
                    (list :type "tool_result"
                          :toolCallId tool-id
                          :toolName (plist-get message :toolName))
                    orphan-status)))
         (is-error (eq t (plist-get message :isError))))
    (setf (pichat-transcript-content-output tool)
          (pichat-pi--live-normalize
           draft (plist-get message :content)
           (pichat-transcript-content-tool-call-id tool))
          (pichat-transcript-content-is-error tool) is-error
          (pichat-transcript-content-status tool)
          (if existing (if is-error 'error 'done) orphan-status))
    tool))

(defun pichat-pi-live-draft-apply (draft event)
  "Apply one raw normalized Pi EVENT to transient live DRAFT.
Return DRAFT for convenient reducer composition."
  (setf (pichat-live-draft-event-changed-p draft) nil)
  (pcase (plist-get event :type)
    ("message_start"
     (let ((message (plist-get event :message)))
       (unless (member (plist-get message :role)
                       '("toolResult" "tool_result"))
         (when (pichat-pi--live-start-message draft message)
           (setf (pichat-live-draft-event-changed-p draft) t)))))
    ("message_update"
     (let ((assistant-event (plist-get event :assistantMessageEvent)))
       (if (and assistant-event
                (stringp (plist-get assistant-event :type)))
           (pichat-pi--live-apply-assistant-event draft assistant-event)
         (when (pichat-pi--live-update-message
                draft (plist-get event :message) nil)
           (setf (pichat-live-draft-event-changed-p draft) t)))))
    ("message_end"
     (let ((message (plist-get event :message)))
       (when (if (member (plist-get message :role)
                         '("toolResult" "tool_result"))
                 (pichat-pi--live-apply-tool-result draft message 'orphan)
               (pichat-pi--live-update-message draft message t))
         (setf (pichat-live-draft-event-changed-p draft) t))))
    ("tool_execution_start"
     (pichat-pi--live-tool draft event 'running))
    ("tool_execution_update"
     (let* ((tool (pichat-pi--live-tool draft event 'running))
            (partial (plist-get event :partialResult)))
       (setf (pichat-transcript-content-output tool)
             (pichat-pi--live-normalize
              draft (plist-get partial :content)
              (pichat-transcript-content-tool-call-id tool)))))
    ("tool_execution_end"
     (let* ((tool (pichat-pi--live-tool draft event))
            (attached (pichat-pi--live-tool-attached-p draft tool))
            (result (plist-get event :result))
            (is-error (eq t (plist-get event :isError))))
       (setf (pichat-transcript-content-output tool)
             (pichat-pi--live-normalize
              draft (plist-get result :content)
              (pichat-transcript-content-tool-call-id tool))
             (pichat-transcript-content-is-error tool) is-error
             (pichat-transcript-content-status tool)
             (if attached (if is-error 'error 'done) 'orphan))
       (unless attached
         (pichat-pi--live-ensure-unattached-tool draft tool))))
    ("compaction_end"
     (unless (or (eq t (plist-get event :aborted))
                 (plist-get event :error))
       (let ((result (plist-get event :result)))
         (pichat-pi--live-append-node
          draft
          (pichat-transcript-node-create
           :kind 'activity
           :key (pichat-live-draft-next-key draft "compaction")
           :activity-type 'compaction
           :summary (and (stringp (plist-get result :summary))
                         (plist-get result :summary))
           :tokens-before (plist-get result :tokensBefore))))))
    ("agent_settled"
     (pichat-pi--live-clear-stream-state draft)
     (maphash
      (lambda (_id tool)
        (unless (memq (pichat-transcript-content-status tool)
                      '(done error orphan))
          (setf (pichat-transcript-content-status tool) 'incomplete)))
      (pichat-live-draft-tools draft))
     (setf (pichat-live-draft-current-node draft) nil
           (pichat-live-draft-message-final-p draft) t
           (pichat-live-draft-settled-p draft) t)))
  draft)

(provide 'pichat-pi)
;;; pichat-pi.el ends here
