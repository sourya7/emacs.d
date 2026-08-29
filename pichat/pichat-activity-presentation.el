;;; pichat-activity-presentation.el --- Pure activity grouping for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Derive presentation-only activity groups from normalized transcripts.  This
;; module owns no buffers, protocol state, or persisted session data.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pichat-transcript)

(cl-defstruct (pichat-activity-member
               (:constructor pichat-activity-member-create)
               (:conc-name pichat-activity-member-))
  "One source-ordered member of an activity group."
  kind node-key role content-index content tool-call-id source-key
  node-stop-reason node-error-message)

(cl-defstruct (pichat-activity-group
               (:constructor pichat-activity-group-create)
               (:conc-name pichat-activity-group-))
  "One derived, presentation-only activity group."
  key anchor members tool-ids status complete-count tool-count)

(cl-defstruct (pichat-activity-item
               (:constructor pichat-activity-item-create)
               (:conc-name pichat-activity-item-))
  "One item in the source-ordered presentation stream.
KIND is `group', `assistant-content', `annotation', or `node'."
  kind key node content group)

(defun pichat-activity--valid-tool-id-p (value)
  "Return non-nil when VALUE is usable as a durable tool anchor."
  (and (stringp value) (not (string-empty-p value))))

(defun pichat-activity--member-kind (content)
  "Return generic activity member kind for normalized CONTENT."
  (pcase (pichat-transcript-content-kind content)
    ('tool 'tool)
    ('thinking 'thinking)
    (_ nil)))

(defun pichat-activity--content-visible-p (content show-thinking)
  "Return non-nil when CONTENT is visible under SHOW-THINKING."
  (pcase (pichat-transcript-content-kind content)
    ('thinking
     (and show-thinking
          (not (string-empty-p
                (string-trim
                 (or (pichat-transcript-content-text content) ""))))))
    ('tool t)
    ((or 'prose 'image 'unknown)
     (not (string-empty-p
           (or (pichat-transcript-content-text content) ""))))
    (_ nil)))

(defun pichat-activity--member (node content ordinal)
  "Build an activity member for NODE CONTENT at global ORDINAL."
  (let* ((node-key (pichat-transcript-node-key node))
         (index (pichat-transcript-content-index content))
         (tool-id (pichat-transcript-content-tool-call-id content)))
    (pichat-activity-member-create
     :kind (pichat-activity--member-kind content)
     :node-key node-key
     :role (pichat-transcript-node-role node)
     :content-index index
     :content content
     :tool-call-id tool-id
     :source-key (list node-key index)
     :node-stop-reason (pichat-transcript-node-stop-reason node)
     :node-error-message (pichat-transcript-node-error-message node))))

(defun pichat-activity--group-status (members)
  "Reduce normalized activity status from MEMBERS conservatively.
Thought-only activity is active until its owning assistant node settles."
  (let ((statuses
         (mapcar (lambda (member)
                   (pichat-transcript-content-status
                    (pichat-activity-member-content member)))
                 (seq-filter
                  (lambda (member)
                    (eq (pichat-activity-member-kind member) 'tool))
                  members)))
        (thinking-p (seq-some
                     (lambda (member)
                       (and (eq (pichat-activity-member-kind member) 'thinking)
                            (let ((text (pichat-transcript-content-text
                                         (pichat-activity-member-content member))))
                              (not (string-empty-p (string-trim (or text "")))))))
                     members))
        (node-failure-p (seq-some
                         (lambda (member)
                           (or (member (pichat-activity-member-node-stop-reason member)
                                       '("error" "aborted" error aborted))
                               (pichat-activity-member-node-error-message member)))
                         members))
        (node-settled-p (seq-some
                         (lambda (member)
                           (pichat-activity-member-node-stop-reason member))
                         members)))
    (cond
     ((seq-some (lambda (status) (memq status '(running incomplete))) statuses)
      'active)
     ((memq 'error statuses) 'failed)
     ((memq 'orphan statuses) 'orphaned)
     (node-failure-p 'failed)
     ((and statuses (cl-every (lambda (status) (eq status 'done)) statuses))
      'complete)
     (statuses 'active)
     ((and thinking-p node-settled-p) 'complete)
     (thinking-p 'active)
     (t 'complete))))

(defun pichat-activity--make-group (members ordinal)
  "Return a derived group from source-ordered MEMBERS and group ORDINAL."
  (let* ((first (car members))
         (valid-ids
          (delq nil
                (mapcar (lambda (member)
                          (let ((id (pichat-activity-member-tool-call-id member)))
                            (and (pichat-activity--valid-tool-id-p id) id)))
                        members)))
         (first-tool (seq-find
                      (lambda (member)
                        (eq (pichat-activity-member-kind member) 'tool))
                      members))
         (anchor
          (or (car valid-ids)
              (list 'source (pichat-activity-member-source-key first))))
         ;; A tool-anchored group keeps its Stage 1 identity when thinking is
         ;; prepended or inserted between tool calls.  Thought-only groups use
         ;; their first normalized content position as a source-local key.
         (key (if first-tool
                  (list 'activity
                        (pichat-activity-member-node-key first-tool)
                        (pichat-activity-member-content-index first-tool)
                        anchor)
                (list 'activity 'thinking
                      (pichat-activity-member-node-key first)
                      (pichat-activity-member-content-index first))))
         (tools (seq-filter
                 (lambda (member)
                   (eq (pichat-activity-member-kind member) 'tool))
                 members))
         (complete
          (cl-count-if
           (lambda (member)
             (eq (pichat-transcript-content-status
                  (pichat-activity-member-content member))
                 'done))
           tools)))
    (pichat-activity-group-create
     :key key :anchor anchor :members members :tool-ids valid-ids
     :status (pichat-activity--group-status members)
     :complete-count complete :tool-count (length tools))))

(defun pichat-activity-build-presentation
    (transcript enabled-member-kinds &optional show-thinking)
  "Return presentation items for normalized TRANSCRIPT.
ENABLED-MEMBER-KINDS selects generic activity kinds.  SHOW-THINKING controls
whether non-member thinking is a visible boundary.  Source order is retained."
  (let (items pending-members pending-content pending-node
              (member-ordinal 0) (group-ordinal 0) (item-ordinal 0))
    (cl-labels
        ((emit-item
          (item)
          (push item items)
          (cl-incf item-ordinal))
         (flush-group
          ()
          (when pending-members
            (let ((group (pichat-activity--make-group
                          (nreverse pending-members) group-ordinal)))
              (cl-incf group-ordinal)
              (emit-item
               (pichat-activity-item-create
                :kind 'group :key (pichat-activity-group-key group)
                :group group)))
            (setq pending-members nil)))
         (flush-content
          ()
          (when pending-content
            (let ((content (nreverse pending-content)))
              (emit-item
               (pichat-activity-item-create
                :kind 'assistant-content
                :key (list 'content
                           (pichat-transcript-node-key pending-node)
                           (pichat-transcript-content-index (car content))
                           item-ordinal)
                :node pending-node :content content)))
            (setq pending-content nil pending-node nil)))
         (visible-boundary
          (node content)
          (flush-group)
          (if (and pending-node (eq pending-node node))
              (push content pending-content)
            (flush-content)
            (setq pending-node node pending-content (list content)))))
      (dolist (node (pichat-transcript-nodes transcript))
        (let ((assistant-p
               (and (eq (pichat-transcript-node-kind node) 'message)
                    (eq (pichat-transcript-node-role node) 'assistant))))
          (cond
           (assistant-p
            (dolist (content (pichat-transcript-node-content node))
              (let ((member-kind (pichat-activity--member-kind content)))
                (cond
                 ((and member-kind
                       (memq member-kind enabled-member-kinds)
                       (or (not (eq member-kind 'thinking))
                           (pichat-activity--content-visible-p
                            content show-thinking)))
                  (flush-content)
                  (push (pichat-activity--member
                         node content member-ordinal)
                        pending-members)
                  (cl-incf member-ordinal))
                 ((pichat-activity--content-visible-p content show-thinking)
                  (visible-boundary node content)))))
            (flush-content)
            (when (or (pichat-transcript-node-stop-reason node)
                      (pichat-transcript-node-error-message node))
              (flush-group)
              (emit-item
               (pichat-activity-item-create
                :kind 'annotation
                :key (list 'annotation
                           (pichat-transcript-node-key node) item-ordinal)
                :node node))))
           ((eq (pichat-transcript-node-kind node) 'tool)
            (dolist (content (pichat-transcript-node-content node))
              (let ((member-kind (pichat-activity--member-kind content)))
                (if (and member-kind
                         (memq member-kind enabled-member-kinds)
                         (or (not (eq member-kind 'thinking))
                             (pichat-activity--content-visible-p
                              content show-thinking)))
                    (progn
                      (flush-content)
                      (push (pichat-activity--member
                             node content member-ordinal)
                            pending-members)
                      (cl-incf member-ordinal))
                  (when (pichat-activity--content-visible-p
                         content show-thinking)
                    (visible-boundary node content))))))
           (t
            (flush-content)
            (flush-group)
            (emit-item
             (pichat-activity-item-create
              :kind 'node
              :key (list 'node (pichat-transcript-node-key node) item-ordinal)
              :node node))))))
      (flush-content)
      (flush-group))
    (nreverse items)))

(defun pichat-activity-groups (presentation)
  "Return source-ordered activity groups from PRESENTATION items."
  (delq nil
        (mapcar (lambda (item)
                  (and (eq (pichat-activity-item-kind item) 'group)
                       (pichat-activity-item-group item)))
                presentation)))

(defun pichat-activity-resolve-expanded-p
    (group policy explicit-views latest-key live-p)
  "Resolve whether GROUP is expanded under display POLICY.
EXPLICIT-VIEWS is an alist keyed by pure group key.  LATEST-KEY names the live
tail group eligible for `latest'; LIVE-P distinguishes transient projection."
  (let ((explicit (alist-get (pichat-activity-group-key group)
                             explicit-views nil nil #'equal)))
    (pcase (or explicit policy 'latest)
      ('expanded t)
      ('collapsed nil)
      ('latest (and live-p
                    latest-key
                    (equal latest-key (pichat-activity-group-key group))))
      (_ nil))))

(defun pichat-activity--fallback-kind (member)
  "Return a conservative presentation kind for MEMBER without dependencies."
  (let ((name (downcase
               (or (pichat-transcript-content-name
                    (pichat-activity-member-content member))
                   ""))))
    (cond
     ((string-match-p (regexp-opt '("bash" "shell" "exec" "command")) name)
      'execute)
     ((string-match-p (regexp-opt '("grep" "search" "find" "glob")) name)
      'search)
     ((string-match-p (regexp-opt '("fetch" "http" "url" "web")) name)
      'fetch)
     ((string-match-p (regexp-opt '("write" "create")) name) 'write)
     ((string-match-p (regexp-opt '("edit" "patch" "replace")) name) 'edit)
     ((or (string= name "ls")
          (string-match-p (regexp-opt '("read" "view" "list")) name))
      'read)
     (t 'other))))

(defun pichat-activity--count-kinds (group kind-function)
  "Return ordered kind counts for GROUP using KIND-FUNCTION."
  (let (order counts)
    (dolist (member (pichat-activity-group-members group))
      (when (eq (pichat-activity-member-kind member) 'tool)
        (let ((kind (or (and kind-function (funcall kind-function member))
                        (pichat-activity--fallback-kind member)
                        'other)))
          (unless (assq kind counts) (setq order (append order (list kind))))
          (setf (alist-get kind counts) (1+ (or (alist-get kind counts) 0))))))
    (mapcar (lambda (kind) (cons kind (alist-get kind counts))) order)))

(defun pichat-activity--thinking-count (group)
  "Return the number of visible thinking members in GROUP."
  (cl-count-if (lambda (member)
                 (eq (pichat-activity-member-kind member) 'thinking))
               (pichat-activity-group-members group)))

(defun pichat-activity--kind-phrase (kind count group)
  "Return a bounded summary phrase for KIND COUNT in GROUP."
  (pcase kind
    ('execute (if (= count 1) "ran a command" (format "ran %d commands" count)))
    ('read (if (= count 1) "read a file" (format "read %d files" count)))
    ('write (if (= count 1) "wrote a file" (format "wrote %d files" count)))
    ('edit (if (= count 1) "edited a file" (format "edited %d files" count)))
    ('search (if (= count 1) "searched" (format "searched %d times" count)))
    ('fetch (if (= count 1) "fetched data" (format "fetched data %d times" count)))
    (_
     (if (= (pichat-activity-group-tool-count group) 1)
         (let* ((member (or (seq-find
                              (lambda (candidate)
                                (eq (pichat-activity-member-kind candidate) 'tool))
                              (pichat-activity-group-members group))
                            (car (pichat-activity-group-members group))))
                (name (replace-regexp-in-string
                       "[[:space:]\n\r]+" " "
                       (string-trim
                        (or (pichat-transcript-content-name
                             (pichat-activity-member-content member))
                            "tool")))))
           (format "used %s" (truncate-string-to-width name 40 nil nil "…")))
       (format "used %d tools" count)))))

(defun pichat-activity--join-phrases (phrases)
  "Join PHRASES with compact English punctuation."
  (pcase (length phrases)
    (0 "used tools")
    (1 (car phrases))
    (2 (concat (car phrases) " and " (cadr phrases)))
    (_ (concat (string-join (butlast phrases) ", ")
               ", and " (car (last phrases))))))

(defun pichat-activity-format-summary (group &optional kind-function)
  "Return a bounded deterministic tool summary for GROUP.
KIND-FUNCTION receives an activity member and may return an enrichment kind."
  (let* ((phrases
          (mapcar (lambda (entry)
                    (pichat-activity--kind-phrase
                     (car entry) (cdr entry) group))
                  (pichat-activity--count-kinds group kind-function)))
         (thinking-count (pichat-activity--thinking-count group))
         (phrase (pichat-activity--join-phrases
                  (if (> thinking-count 0)
                      (cons "Thought" phrases)
                    phrases)))
         (summary (if (string-empty-p phrase) phrase
                    (concat (upcase (substring phrase 0 1))
                            (substring phrase 1))))
         (total (pichat-activity-group-tool-count group))
         (complete (pichat-activity-group-complete-count group))
         (suffix
          (pcase (pichat-activity-group-status group)
            ('active (and (> total 0)
                          (format " · %d/%d complete" complete total)))
            ('failed (and (> total 0)
                          (format " · %d/%d complete, failed" complete total)))
            ('orphaned (and (> total 0)
                            (format " · %d/%d complete, orphaned" complete total)))
            ('complete (and (> total 1)
                            (format " · %d/%d complete" complete total))))))
    (truncate-string-to-width (concat summary suffix) 160 nil nil "…")))

(provide 'pichat-activity-presentation)
;;; pichat-activity-presentation.el ends here
