;;; pichat-consult.el --- Consult archive browsing for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Consult rendering and actions for normalized records supplied by
;; pichat-archive.  Capability discovery, protocol validation, and helper
;; process ownership remain outside this UI module.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-archive)
(require 'pichat-sessions)
(require 'pichat-view)
(require 'consult nil t)

(declare-function consult--async-min-input "consult")
(declare-function consult--async-options "consult")
(declare-function consult--async-pipeline "consult")
(declare-function consult--async-throttle "consult")
(declare-function consult--async-transform "consult")
(declare-function consult--buffer-preview "consult")
(declare-function consult--lookup-candidate "consult")
(declare-function consult--read "consult")
(declare-function consult--tofu-encode "consult")

(defvar embark-around-action-hooks)
(defvar embark-keymap-alist)
(defvar consult-async-split-style)
(defvar consult--completion-candidate-hook)
(defvar consult--narrow)

(defgroup pichat-consult nil
  "Consult integration for PiChat."
  :group 'pichat)

(defcustom pichat-consult-session-search-limit 100
  "Maximum number of archive session candidates returned by one search."
  :type 'natnum
  :group 'pichat-consult)

(defcustom pichat-consult-session-search-per-session-limit 5
  "Maximum number of archive occurrences retained for one session."
  :type 'natnum
  :group 'pichat-consult)

(defcustom pichat-consult-session-search-debounce 0.15
  "Idle delay before starting an archive session search for changed input."
  :type 'number
  :group 'pichat-consult)

(defcustom pichat-consult-session-search-throttle 0.1
  "Minimum interval between successive archive search processes."
  :type 'number
  :group 'pichat-consult)

(defcustom pichat-consult-session-preview-key "C-o"
  "Key which previews the selected saved session."
  :type '(choice (const :tag "Automatic" any)
                 (const :tag "Disabled" nil)
                 key-sequence)
  :group 'pichat-consult)

(defcustom pichat-consult-relation-indicator-style 'unicode
  "Style used for parent and direct-child indicators.
Unicode uses arrows such as `↑↓2'; ASCII uses forms such as `P/C2'."
  :type '(choice (const :tag "Unicode arrows" unicode)
                 (const :tag "ASCII letters" ascii))
  :group 'pichat-consult)

(defcustom pichat-consult-relations-limit 200
  "Maximum number of parent and direct-child relation candidates.
The archive query protocol limits this value to the inclusive range 1..200."
  :type '(integer :tag "Relation limit")
  :group 'pichat-consult)

(defface pichat-consult-relation-face
  '((t :inherit shadow))
  "Face for ordinary archive relation indicators."
  :group 'pichat-consult)

(defface pichat-consult-relation-warning-face
  '((t :inherit warning))
  "Face for missing or ambiguous archive parent indicators."
  :group 'pichat-consult)

(defvar pichat-consult--session-history nil)
(defvar pichat-consult--project-history nil)
(defvar pichat-consult--relations-sequence 0)
(defvar pichat-consult--relations-process nil)
(defvar pichat-consult--pending-action nil)
(defvar pichat-consult-session-minibuffer-map)
(defconst pichat-consult--cache-missing (make-symbol "pichat-cache-missing"))

(defvar pichat-consult-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "q") #'pichat-view-quit)
    map))

(define-derived-mode pichat-consult-preview-mode pichat-view-mode
  "PiChat-Search-Preview"
  "Display a bounded, immutable archive session preview."
  (setq-local truncate-lines nil))

(defun pichat-consult-available-p ()
  "Return non-nil when Consult UI and Node.js are available.
This does not assert that the active Pi process has an archive capability."
  (and (or (featurep 'consult) (require 'consult nil t))
       (fboundp 'consult--read)
       (fboundp 'consult--async-pipeline)
       (pichat-archive-node-executable)))

(defun pichat-consult--abort-current-minibuffer (buffer)
  "Abort archive minibuffer BUFFER when it still owns the active minibuffer."
  (when (and (buffer-live-p buffer)
             (active-minibuffer-window)
             (eq buffer (window-buffer (active-minibuffer-window))))
    (with-current-buffer buffer (abort-recursive-edit))))

(defun pichat-consult--report-process-failure
    (capability stderr exit-status minibuffer-buffer)
  "Report archive STDERR and EXIT-STATUS for CAPABILITY.
Terminate MINIBUFFER-BUFFER only for availability or process failures."
  (let ((failure (pichat-archive-decode-error stderr exit-status)))
    (if (eq (plist-get failure :class) 'caller)
        (message "PiChat archive query error: %s" (plist-get failure :message))
      (pichat-archive-invalidate capability)
      (message "PiChat archive search ended: %s" (plist-get failure :message))
      (run-at-time 0 nil #'pichat-consult--abort-current-minibuffer
                   minibuffer-buffer))))

(defun pichat-consult--async-archive-process (builder capability)
  "Return a Consult async process stage using BUILDER and CAPABILITY.
Unlike Consult's generic process stage, this classifies helper failures and
invalidates an unavailable capability without opening a different picker."
  (lambda (sink)
    (let (process process-timer stderr-buffer last-command minibuffer-buffer)
      (lambda (action)
        (cond
          ((eq action 'setup)
           (setq minibuffer-buffer (current-buffer))
           (funcall sink action))
          ((stringp action)
           (funcall sink action)
           (let ((command (funcall builder action)))
             (unless (equal command last-command)
               (setq last-command command)
               (when process
                 (when (timerp process-timer) (cancel-timer process-timer))
                 (setq process-timer nil)
                 (process-put process 'pichat-consult-cancelled t)
                 (delete-process process)
                 (when (buffer-live-p stderr-buffer)
                   (kill-buffer stderr-buffer))
                 (setq process nil stderr-buffer nil))
               (when command
                 (let ((rest "")
                       (bytes 0)
                       (flush t))
                   (setq stderr-buffer
                         (generate-new-buffer " *pichat-archive-consult-error*"))
                   (funcall sink [indicator running])
                   (setq
                    process
                    (pichat-transport-make-process
                     (or (plist-get capability :transport)
                         pichat-transport-local)
                     (or (plist-get capability :runtime-cwd)
                         default-directory)
                     :name "pichat-archive-consult" :buffer nil
                     :stderr stderr-buffer :command command
                     :filter
                     (lambda (owner output)
                       (setq bytes (+ bytes (string-bytes output)))
                       (if (> bytes pichat-archive-output-limit)
                           (progn
                             (process-put owner 'pichat-consult-output-limit t)
                             (delete-process owner))
                         (when flush
                           (setq flush nil)
                           (funcall sink 'flush))
                         (let ((lines (split-string output "[\r\n]+")))
                           (if (null (cdr lines))
                               (setq rest (concat rest (car lines)))
                             (setcar lines (concat rest (car lines)))
                             (setq rest (car (last lines))
                                   lines (butlast lines))
                             (when lines (funcall sink lines))))))
                     :sentinel
                     (lambda (owner _event)
                       (unless (process-live-p owner)
                         (let ((cancelled
                                (process-get owner 'pichat-consult-cancelled))
                               (output-limit
                                (process-get owner
                                             'pichat-consult-output-limit))
                               (timed-out
                                (process-get owner 'pichat-consult-timeout))
                               (exit-status (process-exit-status owner)))
                           (when (timerp process-timer)
                             (cancel-timer process-timer))
                           (setq process-timer nil)
                           (unless cancelled
                             (when flush
                               (setq flush nil)
                               (funcall sink 'flush))
                             (when (and (= exit-status 0)
                                        (not output-limit)
                                        (not (string-empty-p rest)))
                               (funcall sink (list rest)))
                             (funcall sink
                                      `[indicator ,(if (and (= exit-status 0)
                                                            (not output-limit))
                                                       'finished
                                                     'failed)])
                             (cond
                              (timed-out
                               (pichat-archive-invalidate capability)
                               (message "PiChat archive search timed out")
                               (run-at-time
                                0 nil #'pichat-consult--abort-current-minibuffer
                                minibuffer-buffer))
                              (output-limit
                               (pichat-archive-invalidate capability)
                               (message "PiChat archive search output was too large")
                               (run-at-time
                                0 nil #'pichat-consult--abort-current-minibuffer
                                minibuffer-buffer))
                              ((not (= exit-status 0))
                               (pichat-consult--report-process-failure
                                capability
                                (pichat-archive--buffer-text stderr-buffer)
                                exit-status minibuffer-buffer))))
                           (when (buffer-live-p stderr-buffer)
                             (kill-buffer stderr-buffer)))))))
                   (set-process-query-on-exit-flag process nil)
                   (set-process-coding-system process 'utf-8-unix
                                              'utf-8-unix)
                   (when (and pichat-archive-query-timeout
                              (> pichat-archive-query-timeout 0))
                     (setq process-timer
                           (run-at-time
                            pichat-archive-query-timeout nil
                            (lambda (owner)
                              (when (process-live-p owner)
                                (process-put owner 'pichat-consult-timeout t)
                                (delete-process owner)))
                            process))))))
           nil))
          ((memq action '(cancel destroy))
           (when (timerp process-timer) (cancel-timer process-timer))
           (setq process-timer nil)
           (when process
             (process-put process 'pichat-consult-cancelled t)
             (delete-process process)
             (setq process nil))
           (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
           (setq stderr-buffer nil last-command nil)
           (funcall sink action))
          (t (funcall sink action)))))))

(defun pichat-consult--archive-process-collection
    (builder capability transform)
  "Return throttled Consult collection for BUILDER and CAPABILITY.
TRANSFORM converts complete JSONL lines into candidates."
  (consult--async-pipeline
   (consult--async-options)
   (consult--async-min-input 0)
   (consult--async-throttle pichat-consult-session-search-throttle
                            pichat-consult-session-search-debounce)
   (pichat-consult--async-archive-process builder capability)
   transform))

(defun pichat-consult--current-project (projects)
  "Return the most specific member of PROJECTS containing current context.
The current project is derived from the invoking directory's live session or,
when that directory has no live session, from `default-directory' itself.
The global fallback session is deliberately ignored so an unrelated active
runtime never marks its own project as current."
  (let* ((session (and (fboundp 'pichat-session-for-directory)
                       (pichat-session-for-directory default-directory)))
         (context (file-name-as-directory
                   (expand-file-name
                    (or (and session (pichat-session-runtime-cwd session))
                        default-directory))))
         matches)
    (dolist (project projects)
      (let ((cwd (file-name-as-directory
                  (expand-file-name (plist-get project :cwd)))))
        (when (string-prefix-p cwd context)
          (push project matches))))
    (car (sort matches
               (lambda (left right)
                 (> (length (plist-get left :cwd))
                    (length (plist-get right :cwd))))))))

(defun pichat-consult--project-candidate (record &optional current)
  "Return display candidate for project RECORD, marked CURRENT when non-nil."
  (let* ((cwd (abbreviate-file-name (plist-get record :cwd)))
         (count (plist-get record :count))
         (display (format "%-8s  %-45s  %3d session%s"
                          (if current "current" "project") cwd count
                          (if (= count 1) "" "s"))))
    (propertize display 'consult--candidate record)))

(defun pichat-consult--select-project (projects)
  "Select and return a project from normalized archive PROJECTS."
  (unless projects (user-error "The archive contains no saved-session projects"))
  (let* ((current (pichat-consult--current-project projects))
         (all (list :kind 'all :cwd nil :label "All projects"
                    :count (apply #'+ (mapcar (lambda (row)
                                               (plist-get row :count))
                                             projects))))
         (ordered (append (and current (list current))
                          (list all)
                          (delq current (copy-sequence projects))))
         (candidates
          (mapcar
           (lambda (record)
             (if (eq (plist-get record :kind) 'all)
                 (propertize
                  (format "%-8s  %-45s  %3d sessions"
                          "all" "All projects" (plist-get record :count))
                  'consult--candidate record)
               (pichat-consult--project-candidate record (eq record current))))
           ordered)))
    (consult--read candidates :prompt "Pi archive project: "
                   :lookup #'consult--lookup-candidate :require-match t
                   :category 'pichat-project
                   :history 'pichat-consult--project-history
                   :default (car candidates) :sort nil)))

(defun pichat-consult--scan-query (input)
  "Parse user-facing saved-session INPUT into categorized values."
  (let ((position 0) free names texts roles)
    (while (< position (length input))
      (if (and (string-match "[[:space:]]+" input position)
               (= position (match-beginning 0)))
          (setq position (match-end 0))
        (let ((start position) field value)
          (when (string-match "\\([[:alpha:]-]+\\):" input position)
            (when (= position (match-beginning 0))
              (setq field (downcase (match-string 1 input))
                    position (match-end 0))))
          (if (and (< position (length input))
                   (= (aref input position) ?\"))
              (let ((end (string-match "\"" input (1+ position))))
                (unless end (user-error "Unterminated quoted search value"))
                (setq value (substring input (1+ position) end)
                      position (1+ end)))
            (let ((end (or (string-match "[[:space:]]" input position)
                           (length input))))
              (setq value (substring input position end)
                    position end)))
          (when (string-empty-p value)
            (user-error "Empty saved-session search value"))
          (pcase field
            ("name" (push value names))
            ("text" (push value texts))
            ("role" (setq roles (append (split-string value "," t) roles)))
            ((or 'nil "") (push value free))
            (_ (push (substring input start position) free))))))
    (list :free (nreverse free) :name (nreverse names)
          :text (nreverse texts) :roles (delete-dups (nreverse roles)))))

(defun pichat-consult--fts-expression (terms)
  "Return a conservative FTS5 AND expression for TERMS."
  (when terms
    (string-join
     (mapcar (lambda (term)
               (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" term t t)))
             terms)
     " AND ")))

(defun pichat-consult--query-options (input cwd)
  "Translate user INPUT and selected CWD into archive options."
  (let* ((query (pichat-consult--scan-query (string-trim input)))
         (free (plist-get query :free))
         (names (plist-get query :name))
         (texts (plist-get query :text))
         (roles (plist-get query :roles)))
    (dolist (role roles)
      (unless (member role '("user" "assistant"))
        (user-error "Unsupported role: %s" role)))
    (when (and roles (null free) (null texts))
      (user-error "role: requires free text or text: search terms"))
    (list :query (pichat-consult--fts-expression free)
          :name-query (pichat-consult--fts-expression names)
          :text-query (pichat-consult--fts-expression texts)
          :roles (and roles (string-join roles ","))
          :cwd cwd :kinds "session_name,user,assistant"
          :loadable-only t
          :limit pichat-consult-session-search-limit
          :per-session pichat-consult-session-search-per-session-limit)))

(defun pichat-consult--search-command (capability cwd input)
  "Return archive helper command for CAPABILITY, CWD, and minibuffer INPUT."
  (if (string-empty-p (string-trim input))
      (pichat-archive-build-command
       capability 'recent
       (list :cwd cwd :loadable-only t
             :limit pichat-consult-session-search-limit))
    (pichat-archive-build-command
     capability 'search (pichat-consult--query-options input cwd))))

(defun pichat-consult--highlight-terms (string terms face)
  "Apply FACE to every case-insensitive occurrence of TERMS in STRING."
  (let ((case-fold-search t))
    (dolist (term terms string)
      (when (pichat-archive--nonblank-string-p term)
        (let ((start 0))
          (while (string-match (regexp-quote term) string start)
            (add-face-text-property (match-beginning 0) (match-end 0)
                                    face nil string)
            (setq start (match-end 0))))))))

(defun pichat-consult--short-id (id)
  "Return the fixed display prefix for session ID."
  (let ((value (or id "")))
    (if (> (length value) 8) (substring value 0 8) value)))

(defun pichat-consult--bounded-child-count (count)
  "Return bounded display text for direct-child COUNT."
  (if (> count 999) "999+" (number-to-string count)))

(defun pichat-consult--relation-indicator (record)
  "Return a fixed-width relation indicator for normalized RECORD."
  (let* ((resolution (or (plist-get record :parent-resolution) 'none))
         (children (or (plist-get record :child-count) 0))
         (ascii (eq pichat-consult-relation-indicator-style 'ascii))
         (parent
          (pcase resolution
            ('resolved (if ascii "P" "↑"))
            ('missing (if ascii "P!" "↑!"))
            ('ambiguous (if ascii "P?" "↑?"))
            (_ "")))
         (child (if (> children 0)
                    (concat (if ascii "C" "↓")
                            (pichat-consult--bounded-child-count children))
                  ""))
         (separator (if (and ascii (not (string-empty-p parent))
                             (not (string-empty-p child)))
                        "/" ""))
         (parent-face (if (memq resolution '(missing ambiguous))
                          'pichat-consult-relation-warning-face
                        'pichat-consult-relation-face))
         (text (concat (propertize parent 'face parent-face)
                       separator
                       (propertize child 'face 'pichat-consult-relation-face))))
    (concat text (make-string (max 0 (- 8 (string-width text))) ?\s))))

(defun pichat-consult--identity-number (value)
  "Return an injective nonnegative integer encoding of string VALUE."
  (let ((number 1))
    (dolist (byte (string-to-list (encode-coding-string (or value "") 'utf-8 t))
                  number)
      (setq number (+ (* number 257) (1+ byte))))))

(defun pichat-consult--tofu-encode (value)
  "Return an invisible Consult-compatible uniqueness token for VALUE."
  (if (fboundp 'consult--tofu-encode)
      (consult--tofu-encode (pichat-consult--identity-number value))
    (let ((number (pichat-consult--identity-number value))
          token char)
      (while (progn
               (setq char (char-to-string (+ #x100000 (% number #xFFFE)))
                     token (if token (concat char token) char))
               (and (>= number #xFFFE)
                    (setq number (/ number #xFFFE)))))
      (add-text-properties
       0 (length token)
       '(invisible t consult-strip t rear-nonsticky t cursor-intangible t)
       token)
      token)))

(defun pichat-consult--candidate-identity (record)
  "Return the primary completion identity for archive RECORD."
  (pichat-sessions--completion-identity
   (or (plist-get record :display-title)
       (plist-get record :title)
       (plist-get record :session-id))
   (plist-get record :session-id)))

(defun pichat-consult--candidate-annotation (candidate)
  "Return aligned display metadata for archive session CANDIDATE."
  (when-let ((record (pichat-consult--candidate-record candidate)))
    (let* ((identity (pichat-consult--candidate-identity record))
           (time (pichat-consult--short-time
                  (plist-get record :latest-activity-at)))
           (kind (symbol-name (or (plist-get record :match-kind) 'recent)))
           (relation (pichat-consult--relation-indicator record))
           (cwd (pichat-sessions--short-cwd (or (plist-get record :cwd) "")))
           (hits (or (plist-get record :match-count) 0))
           (ordinary
            (lambda (value width)
              (propertize (pichat-sessions--completion-field value width)
                          'face 'completions-annotations)))
           (metadata
            (string-trim-right
             (concat
              (funcall ordinary time 16) "  "
              (funcall ordinary kind 7) "  "
              relation "  "
              (funcall ordinary cwd 32)
              (when (> hits 0)
                (concat "  "
                        (funcall ordinary
                                 (format "[%d hit%s]" hits
                                         (if (= hits 1) "" "s"))
                                 10))))))
           (annotation
            (concat (pichat-sessions--completion-annotation-prefix identity)
                    metadata)))
      (pichat-consult--highlight-terms
       annotation (plist-get record :highlight-terms) 'consult-highlight-match))))

(defun pichat-consult--decode-candidate (line capability &optional browse-context)
  "Decode archive output LINE and attach CAPABILITY and BROWSE-CONTEXT."
  (condition-case nil
      (let* ((object (pichat-archive--decode-json line))
             (record (if (plist-member object :matchKind)
                         (pichat-archive-normalize-search object)
                       (pichat-archive-normalize-recent object)))
             (record (plist-put record :archive-capability capability))
             (record (plist-put record :browse-context browse-context))
             (identity (pichat-consult--candidate-identity record))
             (uniqueness-key
              (format "%s\0%s" (or (plist-get record :session-id) "")
                      (or (plist-get record :session-file) "")))
             (candidate (concat identity
                                (pichat-consult--tofu-encode uniqueness-key))))
        (pichat-consult--highlight-terms
         candidate (plist-get record :highlight-terms) 'consult-highlight-match)
        (add-text-properties 0 (length candidate)
                             (list 'consult--candidate record) candidate)
        candidate)
    (error
     (pichat-archive-invalidate capability)
     (message "PiChat archive returned a malformed candidate")
     nil)))

(defun pichat-consult--decode-candidates (lines capability &optional browse-context)
  "Decode archive LINES for CAPABILITY and optional BROWSE-CONTEXT."
  (delq nil (mapcar (lambda (line)
                      (pichat-consult--decode-candidate
                       line capability browse-context))
                    lines)))

(defun pichat-consult--target (candidate)
  "Return the opaque PiChat target carried by CANDIDATE."
  (cond
   ((and (listp candidate)
         (or (plist-get candidate :session-id)
             (eq (plist-get candidate :pichat-target-kind) 'relation)))
    candidate)
   ((stringp candidate)
    (get-text-property 0 'consult--candidate candidate))))

(defun pichat-consult--candidate-record (candidate)
  "Return the normalized nested session record carried by CANDIDATE."
  (let ((target (pichat-consult--target candidate)))
    (if (eq (plist-get target :pichat-target-kind) 'relation)
        (plist-get target :session-record)
      target)))

(defun pichat-consult--candidate-relation (candidate)
  "Return the complete normalized relation carried by CANDIDATE."
  (let ((target (pichat-consult--target candidate)))
    (and (eq (plist-get target :pichat-target-kind) 'relation)
         (plist-get target :relation))))

(defun pichat-consult--candidate-context (candidate)
  "Return the browser return context carried by CANDIDATE."
  (plist-get (pichat-consult--target candidate) :browse-context))

(defun pichat-consult--selection-function (candidate)
  "Return the contextual selection function carried by CANDIDATE."
  (plist-get (pichat-consult--candidate-context candidate)
             :selection-function))

(defun pichat-consult--insert-preview-entry (entry)
  "Insert one readable preview ENTRY into the current buffer."
  (let ((role (or (plist-get entry :role) "message"))
        (text (or (plist-get entry :text) (plist-get entry :snippet) "")))
    (insert (propertize (format "%s\n" role)
                        'face (if (equal role "user")
                                  'pichat-sessions-user-face
                                'pichat-sessions-assistant-face)))
    (insert text "\n\n")))

(defun pichat-consult--occurrence-context (record)
  "Return deduplicated visible context rows from normalized RECORD."
  (let ((seen (make-hash-table :test #'equal)) rows)
    (dolist (occurrence (plist-get record :occurrences))
      (dolist (entry (plist-get occurrence :context))
        (let ((id (plist-get entry :entry-id)))
          (unless (gethash id seen)
            (puthash id t seen)
            (push entry rows)))))
    (nreverse rows)))

(defun pichat-consult--relation-description (record)
  "Return a concise relation summary for normalized RECORD."
  (let* ((resolution (or (plist-get record :parent-resolution) 'none))
         (children (or (plist-get record :child-count) 0))
         (parent
          (pcase resolution
            ('resolved
             (format "parent %s"
                     (pichat-consult--short-id
                      (plist-get record :parent-session-id))))
            ('missing "missing parent reference")
            ('ambiguous "ambiguous parent reference")
            (_ nil)))
         (child (when (> children 0)
                  (format "%d direct child%s" children
                          (if (= children 1) "" "ren")))))
    (if (or parent child)
        (string-join (delq nil (list parent child)) " · ")
      "none")))

(defun pichat-consult--fork-evidence-description (relation)
  "Return concise fork evidence text for normalized RELATION."
  (let ((status (plist-get relation :fork-point-status))
        (position (plist-get relation :fork-position)))
    (format "%s%s" status (if position (format "/%s" position) ""))))

(defun pichat-consult--insert-relation-preview (relation subject)
  "Insert RELATION-to-SUBJECT details into the current preview buffer."
  (when relation
    (insert (format "Selected relation: %s of %s\n"
                    (plist-get relation :direction)
                    (or (plist-get subject :display-title)
                        (plist-get subject :title)
                        (plist-get relation :session-id))))
    (insert (format "Resolution: %s\nFork evidence: %s\n"
                    (plist-get relation :parent-resolution)
                    (pichat-consult--fork-evidence-description relation)))
    (when-let ((reference (plist-get relation :parent-reference-path)))
      (insert (format "Parent reference: %s\n" reference)))))

(defun pichat-consult--render-preview
    (buffer record &optional context info loading relation subject)
  "Render RECORD, optional CONTEXT and INFO into preview BUFFER.
LOADING is non-nil while lazy context or metadata remains pending.  RELATION
and SUBJECT describe a relation-picker target when present."
  (with-current-buffer buffer
    (let ((inhibit-read-only t)
          (terms (plist-get record :highlight-terms))
          (display-title (or (plist-get record :display-title)
                             (plist-get record :title) "Untitled session"))
          (compatibility-title (plist-get record :title)))
      (erase-buffer)
      (pichat-consult-preview-mode)
      (insert (propertize display-title 'face 'bold) "\n")
      (when (and compatibility-title
                 (not (equal display-title compatibility-title)))
        (insert (format "Original title: %s\n" compatibility-title)))
      (pichat-consult--insert-relation-preview relation subject)
      (insert "Relation: ")
      (let ((start (point)))
        (insert (pichat-consult--relation-description record))
        (when (memq (plist-get record :parent-resolution)
                    '(missing ambiguous))
          (add-face-text-property start (point)
                                  'pichat-consult-relation-warning-face)))
      (insert "\n")
      (when info
        (insert (format "Fork evidence: %s%s\n"
                        (plist-get info :fork-point-status)
                        (if-let ((position (plist-get info :fork-position)))
                            (format " (%s)" position) ""))))
      (insert (format "Project: %s\nMatches: %s\nSession: %s\n"
                      (abbreviate-file-name (or (plist-get record :cwd) ""))
                      (or (plist-get record :match-count) 0)
                      (or (plist-get record :session-id) "")))
      (when loading (insert "Loading archive preview details…\n"))
      (insert "\n")
      (dolist (entry (or context (pichat-consult--occurrence-context record)))
        (pichat-consult--insert-preview-entry entry))
      (let ((case-fold-search t))
        (save-excursion
          (dolist (term terms)
            (goto-char (point-min))
            (while (and (pichat-archive--nonblank-string-p term)
                        (search-forward term nil t))
              (add-face-text-property (match-beginning 0) (match-end 0)
                                      'consult-preview-match nil)))))
      (goto-char (point-min)))))

(defun pichat-consult--render-unresolved-relation-preview
    (buffer relation subject)
  "Render unresolved RELATION to SUBJECT in preview BUFFER."
  (with-current-buffer buffer
    (let ((inhibit-read-only t))
      (erase-buffer)
      (pichat-consult-preview-mode)
      (insert (propertize "Unavailable parent session\n" 'face 'bold))
      (pichat-consult--insert-relation-preview relation subject)
      (insert "\nThis historical parent reference did not resolve to an archived session.\n")
      (goto-char (point-min)))))

(defun pichat-consult--cache-get (table key)
  "Return cached TABLE value for KEY or the private missing sentinel."
  (gethash key table pichat-consult--cache-missing))

(defun pichat-consult--preview-state ()
  "Return cancellation-aware Consult state for archive previews."
  (let ((buffer (get-buffer-create "*PiChat Saved Session Preview*"))
        (display-state (consult--buffer-preview))
        (sequence 0) processes)
    (lambda (action candidate)
      (pcase action
        ('setup
         (funcall display-state action candidate))
        ('preview
         (cl-incf sequence)
         (dolist (process processes)
           (when (process-live-p process) (delete-process process)))
         (setq processes nil)
         (let* ((target (pichat-consult--target candidate))
                (record (pichat-consult--candidate-record target))
                (relation (pichat-consult--candidate-relation target))
                (subject (and (eq (plist-get target :pichat-target-kind) 'relation)
                              (plist-get target :subject-record)))
                (capability (or (and record
                                     (plist-get record :archive-capability))
                                (plist-get target :archive-capability)))
                (session-id (and record (plist-get record :session-id))))
           (cond
            ((and record capability session-id)
             (let* ((token sequence)
                    (context-cache (plist-get capability :preview-cache))
                    (info-cache (plist-get capability :session-info-cache))
                    (inline-context (pichat-consult--occurrence-context record))
                    (cached-context
                     (pichat-consult--cache-get context-cache session-id))
                    (cached-info
                     (pichat-consult--cache-get info-cache session-id))
                    (context (or inline-context
                                 (unless (eq cached-context
                                             pichat-consult--cache-missing)
                                   cached-context)))
                    (info (unless (eq cached-info pichat-consult--cache-missing)
                            cached-info))
                    (context-pending
                     (and (null inline-context)
                          (eq cached-context pichat-consult--cache-missing)))
                    (info-pending
                     (eq cached-info pichat-consult--cache-missing)))
               (cl-labels
                   ((current-p ()
                      (and (= token sequence) (buffer-live-p buffer)))
                    (rerender ()
                      (when (current-p)
                        (pichat-consult--render-preview
                         buffer record context info
                         (or context-pending info-pending) relation subject)))
                    (ignore-failure (_failure)
                      (when (current-p)
                        (setq context-pending nil info-pending nil)
                        (rerender))))
                 (rerender)
                 (funcall display-state 'preview (buffer-name buffer))
                 (when context-pending
                   (push
                    (pichat-archive-request
                     capability 'session
                     (list :id session-id :kinds "user,assistant"
                           :context 2 :limit 20)
                     (lambda (rows)
                       (when (current-p)
                         (setq context rows context-pending nil)
                         (puthash session-id rows context-cache)
                         (rerender)))
                     #'ignore-failure)
                    processes))
                 (when info-pending
                   (push
                    (pichat-archive-request
                     capability 'session-info (list :id session-id)
                     (lambda (value)
                       (when (current-p)
                         (setq info value info-pending nil)
                         (puthash session-id value info-cache)
                         (rerender)))
                     #'ignore-failure)
                    processes)))))
            (relation
             (pichat-consult--render-unresolved-relation-preview
              buffer relation subject)
             (funcall display-state 'preview (buffer-name buffer)))
            (t (funcall display-state 'preview nil)))))
        ((or 'return 'exit)
         (cl-incf sequence)
         (dolist (process processes)
           (when (process-live-p process) (delete-process process)))
         (setq processes nil)
         (funcall display-state action candidate)
         (when (and (eq action 'exit) (buffer-live-p buffer))
           (kill-buffer buffer)))))))

(defun pichat-consult--loadable-record (candidate)
  "Return loadable normalized record for CANDIDATE or signal a user error."
  (let ((record (pichat-consult--candidate-record candidate))
        (relation (pichat-consult--candidate-relation candidate)))
    (unless record
      (if relation
          (user-error "This parent reference is %s and has no resolved session"
                      (plist-get relation :parent-resolution))
        (user-error "No PiChat session candidate")))
    (unless (and (plist-get record :source-exists)
                 (pichat-archive--nonblank-string-p
                  (plist-get record :session-file)))
      (user-error "This archived session source is unavailable"))
    record))

(defun pichat-consult-load-session (candidate)
  "Load the full saved session represented by CANDIDATE.
When CANDIDATE belongs to a browser with a contextual selection function,
call that function with the saved FILE and CWD instead of mutating the active
runtime.  Without a contextual selection function and without a live session
for the invoking directory, open FILE in an independent runtime owned by the
selected session's project rather than replacing an unrelated active session
through the global fallback." 
  (interactive "sSession: ")
  (let* ((record (pichat-consult--loadable-record candidate))
         (selection-function (pichat-consult--selection-function candidate))
         (file (plist-get record :session-file))
         (cwd (plist-get record :cwd)))
    (cond
     (selection-function
      (funcall selection-function file cwd))
     ((and (fboundp 'pichat-session-for-directory)
           (fboundp 'pichat-sessions-open-file-independently)
           (not (pichat-session-for-directory default-directory))
           (pichat-session-current))
      ;; The invoking directory has no live session, so the switch path below
      ;; would hijack the global fallback runtime.  Preserve it by opening an
      ;; independent runtime rooted at the selected session's own project.
      (pichat-sessions-open-file-independently
       file :cwd cwd :owner-directory cwd))
     (t
      (pichat-sessions-switch-file file cwd)))))

(defun pichat-consult-open-session-independently (candidate)
  "Load CANDIDATE in a newly created independent PiChat runtime.
A contextual independent browser function takes precedence so manager-owned
scope and display policy remain intact."
  (interactive "sSession: ")
  (let* ((record (pichat-consult--loadable-record candidate))
         (selection-function (pichat-consult--selection-function candidate))
         (capability
          (plist-get (pichat-consult--candidate-context candidate) :capability))
         (source-session (and capability (plist-get capability :session))))
    (if selection-function
        (funcall selection-function
                 (plist-get record :session-file) (plist-get record :cwd))
      (pichat-sessions-open-file-independently
       (plist-get record :session-file)
       :cwd (plist-get record :cwd)
       :source-session source-session))))

(defun pichat-consult-jump-to-match (candidate)
  "Load CANDIDATE and open Session History at its best known entry.
Relation metadata has no content occurrence, so relation targets open History
at its ordinary current position rather than treating fork evidence as an
entry-loadability claim."
  (interactive "sSession: ")
  (let* ((relation (pichat-consult--candidate-relation candidate))
         (record (pichat-consult--loadable-record candidate))
         (entry-id (plist-get record :entry-id)))
    (when (pichat-consult--selection-function candidate)
      (user-error
       "Open this session first; contextual independent browsing cannot jump in another runtime"))
    (unless (or relation (and entry-id (plist-get record :entry-loadable)))
      (user-error "This result has no currently loadable content occurrence"))
    (pichat-sessions-switch-file
     (plist-get record :session-file) (plist-get record :cwd)
     (lambda (session) (pichat-sessions-list session entry-id)))))

(defun pichat-consult--short-time (timestamp)
  "Return minute-resolution display text for TIMESTAMP."
  (let ((value (or timestamp "")))
    (if (>= (length value) 16)
        (replace-regexp-in-string "T" " " (substring value 0 16))
      value)))

(defun pichat-consult--relations-limit ()
  "Return the validated archive relation candidate limit."
  (unless (and (integerp pichat-consult-relations-limit)
               (<= 1 pichat-consult-relations-limit 200))
    (user-error "pichat-consult-relations-limit must be between 1 and 200"))
  pichat-consult-relations-limit)

(defun pichat-consult--relation-annotation (candidate)
  "Return aligned display metadata for relation CANDIDATE."
  (let* ((target (pichat-consult--target candidate))
         (relation (pichat-consult--candidate-relation target))
         (record (pichat-consult--candidate-record target))
         (identity (or (plist-get target :display-identity)
                       (and record (pichat-consult--candidate-identity record))
                       ""))
         (direction (and relation (plist-get relation :direction)))
         (resolution (and relation (plist-get relation :parent-resolution)))
         (available (and record
                         (plist-get record :source-exists)
                         (pichat-archive--nonblank-string-p
                          (plist-get record :session-file))))
         (ordinary
          (lambda (value width)
            (propertize (pichat-sessions--completion-field value width)
                        'face 'completions-annotations)))
         (indicator
          (pichat-consult--relation-indicator
           (or record (list :parent-resolution resolution :child-count 0))))
         (resolution-text
          (propertize
           (pichat-sessions--completion-field
            (symbol-name (or resolution 'none)) 9)
           'face (if (memq resolution '(missing ambiguous))
                     'pichat-consult-relation-warning-face
                   'completions-annotations)))
         (metadata
          (and relation
               (string-trim-right
                (concat
                 (funcall ordinary (symbol-name direction) 6) "  "
                 (funcall ordinary
                          (if record
                              (pichat-consult--short-time
                               (plist-get record :latest-activity-at))
                            "")
                          16)
                 "  " indicator "  " resolution-text "  "
                 (funcall ordinary
                          (pichat-consult--fork-evidence-description relation)
                          15)
                 (unless available
                   (concat "  "
                           (propertize "[unavailable]" 'face 'warning))))))))
    (and relation
         (concat (pichat-sessions--completion-annotation-prefix identity)
                 metadata))))

(defun pichat-consult--relation-candidate
    (relation capability subject browse-context)
  "Return an identity-first Consult candidate for RELATION to SUBJECT."
  (let* ((related (plist-get relation :related-session))
         (record (and related (copy-sequence related)))
         (direction (plist-get relation :direction))
         (resolution (plist-get relation :parent-resolution))
         (title (or (and record (plist-get record :display-title))
                    (and record (plist-get record :title))
                    (format "[%s parent: %s]" resolution
                            (plist-get relation :parent-reference-path))))
         (target (list :pichat-target-kind 'relation
                       :relation relation :session-record record
                       :subject-record subject :archive-capability capability
                       :browse-context browse-context)))
    (when record
      (setq record (plist-put record :archive-capability capability)
            record (plist-put record :browse-context browse-context))
      (plist-put target :session-record record))
    (let* ((identity
            (if record
                (pichat-sessions--completion-identity
                 title (plist-get record :session-id))
              (format "????????  %s"
                      (pichat-sessions--truncate-display
                       title (max 12 pichat-sessions-completion-title-width)))))
           (_ (setq target (plist-put target :display-identity identity)))
           (uniqueness-key
            (format "%s\0%s\0%s\0%s"
                    (or (plist-get subject :session-id) "") direction
                    (or (and record (plist-get record :session-id)) "")
                    (or (plist-get relation :parent-reference-path) "")))
           (candidate (concat identity
                              (pichat-consult--tofu-encode uniqueness-key))))
      (add-text-properties
       0 (length candidate)
       (list 'consult--candidate target
             'pichat-relation-direction direction
             'consult--type (if (eq direction 'parent) ?p ?c))
       candidate)
      candidate)))

(defun pichat-consult--relation-group (candidate transform)
  "Group relation CANDIDATE by direction unless TRANSFORM is non-nil."
  (if transform candidate
    (if (eq (get-text-property 0 'pichat-relation-direction candidate) 'parent)
        "Parent" "Direct children")))

(defun pichat-consult--relation-narrow-config ()
  "Return Consult narrowing configuration for relation candidates."
  (list :predicate
        (lambda (candidate)
          (eq (get-text-property 0 'consult--type candidate) consult--narrow))
        :keys '((?p . "Parent") (?c . "Direct children"))))

(defun pichat-consult--schedule-resume (context)
  "Schedule resumption of browser CONTEXT outside the current minibuffer."
  (when context
    (run-at-time 0 nil #'pichat-consult--resume-context context)))

(defun pichat-consult--resume-context (context)
  "Resume the archive or relation browser represented by CONTEXT."
  (pcase (plist-get context :kind)
    ('archive
     (let ((capability (plist-get context :capability)))
       (if (pichat-archive-capability-current-p capability)
           (pichat-consult--run-project-search
            capability (plist-get context :project) (plist-get context :input)
            (plist-get context :selection-function))
         (message "PiChat archive search cannot resume: capability is stale"))))
    ('relations
     (pichat-consult--read-relations
      (plist-get context :capability) (plist-get context :subject)
      (plist-get context :relations) (plist-get context :parent)))))

(defun pichat-consult--read-relations
    (capability subject relations parent-context)
  "Browse normalized SUBJECT RELATIONS and return to PARENT-CONTEXT on quit."
  (if (null relations)
      (progn
        (message "No parent or direct-child PiChat archive relations were found")
        (pichat-consult--schedule-resume parent-context))
    (let* ((selection-function
            (and (listp parent-context)
                 (plist-get parent-context :selection-function)))
           (context (list :kind 'relations :capability capability
                          :subject subject :relations relations
                          :parent parent-context
                          :selection-function selection-function))
           (candidates
            (mapcar (lambda (relation)
                      (pichat-consult--relation-candidate
                       relation capability subject context))
                    relations))
           (pichat-consult--pending-action nil)
           selected)
      (condition-case nil
          (setq selected
                (consult--read
                 candidates
                 :prompt (format "Related sessions [%s] [RET %s, C-o preview]: "
                                 (pichat-sessions--shorten
                                  (or (plist-get subject :display-title)
                                      (plist-get subject :title)
                                      (plist-get subject :session-id)) 45)
                                 (if selection-function "open" "load"))
                 :lookup #'consult--lookup-candidate :require-match t
                 :category 'pichat-session :sort nil
                 :annotate #'pichat-consult--relation-annotation
                 :group #'pichat-consult--relation-group
                 :narrow (pichat-consult--relation-narrow-config)
                 :state (pichat-consult--preview-state)
                 :preview-key pichat-consult-session-preview-key
                 :keymap pichat-consult-session-minibuffer-map))
        (quit (pichat-consult--schedule-resume parent-context)))
      (cond
       (pichat-consult--pending-action
        (funcall (car pichat-consult--pending-action)
                 (cdr pichat-consult--pending-action)))
       (selected (pichat-consult-load-session selected))))))

(defun pichat-consult--schedule-current-relations
    (capability subject token)
  "Open SUBJECT relations for CAPABILITY while TOKEN remains current."
  (let ((record (copy-sequence subject)))
    (setq record (plist-put record :archive-capability capability)
          record (plist-put record :browse-context nil))
    (run-at-time
     0 nil
     (lambda ()
       (when (= token pichat-consult--relations-sequence)
         (if (pichat-archive-capability-current-p capability)
             (pichat-consult-show-relations record)
           (message "PiChat related sessions unavailable: capability is stale")))))))

(defun pichat-consult-show-current-relations (capability session)
  "Browse relations for the active persisted SESSION using CAPABILITY.
Resolve SESSION through archive `session-info' first so the existing relation
picker receives the same normalized subject record as archive search actions."
  (let* ((session-id (and session (pichat-session-id session)))
         (cache (plist-get capability :session-info-cache))
         (cached (and cache (pichat-consult--cache-get cache session-id)))
         (cached-p (not (eq cached pichat-consult--cache-missing)))
         (token (cl-incf pichat-consult--relations-sequence)))
    (unless (pichat-archive--nonblank-string-p session-id)
      (user-error "Current PiChat session has no archive session ID"))
    (unless (pichat-archive-capability-current-p capability)
      (user-error "PiChat archive capability is unavailable or stale"))
    (unless (hash-table-p cache)
      (user-error "PiChat archive capability has no session-info cache"))
    (when (process-live-p pichat-consult--relations-process)
      (delete-process pichat-consult--relations-process))
    (setq pichat-consult--relations-process nil)
    (if cached-p
        (pichat-consult--schedule-current-relations capability cached token)
      (message "Loading current PiChat session relations…")
      (setq
       pichat-consult--relations-process
       (pichat-archive-request
        capability 'session-info (list :id session-id)
        (lambda (subject)
          (when (= token pichat-consult--relations-sequence)
            (setq pichat-consult--relations-process nil)
            (if (equal session-id (plist-get subject :session-id))
                (progn
                  (puthash session-id subject cache)
                  (pichat-consult--schedule-current-relations
                   capability subject token))
              (message "PiChat archive returned a different current session"))))
        (lambda (failure)
          (when (= token pichat-consult--relations-sequence)
            (setq pichat-consult--relations-process nil)
            (message "PiChat current-session lookup failed: %s"
                     (plist-get failure :message)))))))))

(defun pichat-consult-show-relations (candidate)
  "Browse parent and direct-child archive relations for CANDIDATE."
  (interactive "sSession: ")
  (let* ((target (pichat-consult--target candidate))
         (record (pichat-consult--candidate-record target))
         (capability (or (and record (plist-get record :archive-capability))
                         (plist-get target :archive-capability)))
         (parent-context (pichat-consult--candidate-context target))
         (session-id (and record (plist-get record :session-id)))
         (limit (pichat-consult--relations-limit))
         (cache (and capability (plist-get capability :relations-cache)))
         (key (list session-id "both" limit))
         (cached (and cache (pichat-consult--cache-get cache key)))
         (cached-p (not (eq cached pichat-consult--cache-missing)))
         (token (cl-incf pichat-consult--relations-sequence)))
    (unless (and record capability session-id)
      (user-error "No resolved archive relation target"))
    (unless (pichat-archive-capability-current-p capability)
      (user-error "PiChat archive capability is unavailable or stale"))
    (unless (hash-table-p cache)
      (user-error "PiChat archive capability has no relation cache"))
    (when (process-live-p pichat-consult--relations-process)
      (delete-process pichat-consult--relations-process))
    (setq pichat-consult--relations-process nil)
    (if cached-p
        (pichat-consult--read-relations
         capability record cached parent-context)
      (message "Loading PiChat archive relations…")
      (setq
       pichat-consult--relations-process
       (pichat-archive-request
        capability 'relations
        (list :id session-id :direction "both" :limit limit)
        (lambda (relations)
          (when (= token pichat-consult--relations-sequence)
            (setq pichat-consult--relations-process nil)
            (puthash key relations cache)
            (run-at-time 0 nil #'pichat-consult--read-relations
                         capability record relations parent-context)))
        (lambda (failure)
          (when (= token pichat-consult--relations-sequence)
            (setq pichat-consult--relations-process nil)
            (message "PiChat relation lookup failed: %s"
                     (plist-get failure :message))
            (pichat-consult--schedule-resume parent-context))))))))

(defun pichat-consult-show-selected-relations ()
  "Exit the active Consult search and show relations for its selection."
  (interactive)
  (let ((candidate
         (run-hook-with-args-until-success
          'consult--completion-candidate-hook)))
    (unless (pichat-consult--candidate-record candidate)
      (user-error "No PiChat archive session is selected"))
    (setq pichat-consult--pending-action
          (cons #'pichat-consult-show-relations
                (pichat-consult--target candidate)))
    (funcall (or (command-remapping #'exit-minibuffer)
                 #'exit-minibuffer))))

(defvar pichat-consult-session-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'pichat-consult-show-selected-relations)
    map)
  "Command-specific keymap for archive-backed saved-session search.")

(cl-defun pichat-consult--embark-session-action
    (&key action target &allow-other-keys)
  "Run archive ACTION with the complete session record from Embark TARGET.
Embark's ordinary interactive injection removes text properties before ACTION
reads its argument.  Bypass that injection for PiChat actions while the
original Consult candidate still carries `consult--candidate'."
  (let ((candidate (pichat-consult--target target)))
    (unless candidate (user-error "No PiChat archive session target"))
    (funcall action candidate)))

(defvar pichat-consult-session-action-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-consult-load-session)
    (define-key map (kbd "o") #'pichat-consult-open-session-independently)
    (define-key map (kbd "j") #'pichat-consult-jump-to-match)
    (define-key map (kbd "r") #'pichat-consult-show-relations)
    map)
  "Embark actions for archive-backed `pichat-session' candidates.")

(with-eval-after-load 'embark
  (add-to-list 'embark-keymap-alist
               '(pichat-session . pichat-consult-session-action-map))
  (dolist (action '(pichat-consult-load-session
                    pichat-consult-open-session-independently
                    pichat-consult-jump-to-match
                    pichat-consult-show-relations))
    (cl-pushnew #'pichat-consult--embark-session-action
                (alist-get action embark-around-action-hooks))))

(defun pichat-consult--search
    (capability project &optional initial selection-function)
  "Run Consult archive search for CAPABILITY and selected PROJECT.
SELECTION-FUNCTION, when non-nil, receives the selected saved FILE and CWD."
  (let* ((cwd (plist-get project :cwd))
         (scope-label (or cwd "all projects"))
         (consult-async-split-style 'none)
         (pichat-consult--pending-action nil)
         (browse-context (list :kind 'archive :capability capability
                               :project project :input (or initial "")
                               :selection-function selection-function))
         (builder (lambda (input)
                    (plist-put browse-context :input input)
                    (pichat-consult--search-command capability cwd input)))
         (selected
          (consult--read
           (pichat-consult--archive-process-collection
            builder capability
            (consult--async-transform
             (lambda (lines)
               (pichat-consult--decode-candidates
                lines capability browse-context))))
           :prompt (format "Pi sessions [%s] [RET %s, C-o preview, C-c C-r relations]: "
                           (if cwd (abbreviate-file-name cwd) scope-label)
                           (if selection-function "open" "load"))
           :lookup #'consult--lookup-candidate
           :require-match t :category 'pichat-session
           :annotate #'pichat-consult--candidate-annotation
           :history '(:input pichat-consult--session-history)
           :initial initial :state (pichat-consult--preview-state)
           :preview-key pichat-consult-session-preview-key
           :keymap pichat-consult-session-minibuffer-map :sort nil)))
    (cond
     (pichat-consult--pending-action
      (funcall (car pichat-consult--pending-action)
               (cdr pichat-consult--pending-action)))
     (selected (pichat-consult-load-session selected)))))

(defun pichat-consult--run-project-search
    (capability project &optional initial selection-function replay-command)
  "Search CAPABILITY in PROJECT through one replayable command.
INITIAL and SELECTION-FUNCTION are forwarded to `pichat-consult--search'.
REPLAY-COMMAND, when non-nil, is the command previously made for this exact
search context.  A new context receives an uninterned interactive command whose
closure preserves its project and selection policy independently."
  (unless (pichat-archive-capability-current-p capability)
    (user-error "PiChat archive capability is unavailable or stale"))
  (let ((command replay-command))
    (unless command
      (setq command (make-symbol "pichat-consult-project-search"))
      (fset command
            (lambda ()
              (interactive)
              (pichat-consult--run-project-search
               capability project nil selection-function command))))
    ;; The project picker exits immediately before this reader opens.  Give
    ;; Embark the replayable search command instead of inheriting that exit
    ;; command as the session minibuffer's origin.
    (let ((this-command command))
      (pichat-consult--search
       capability project initial selection-function))))

;;;###autoload
(defun pichat-consult-sessions
    (capability &optional initial selection-function)
  "Browse saved sessions through validated archive CAPABILITY.
Archive projects are loaded first.  Empty search input lists recent sessions;
name:, text:, and role: fields are translated to conservative FTS expressions.
When SELECTION-FUNCTION is non-nil, RET passes it the selected saved FILE and
CWD instead of switching the active runtime.  `C-c C-r' shows relations,
Embark `j' loads and jumps, and Embark `r' also shows relations."
  (unless (pichat-consult-available-p)
    (user-error "PiChat archive search requires Consult and Node.js"))
  (unless (pichat-archive-capability-current-p capability)
    (user-error "PiChat archive capability is unavailable or stale"))
  (pichat-archive-request
   capability 'projects (list :loadable-only t :limit 200)
   (lambda (projects)
     (condition-case nil
         (when-let ((project (pichat-consult--select-project projects)))
           (pichat-consult--run-project-search
            capability project initial selection-function))
       (quit nil)))
   (lambda (failure)
     (message "PiChat archive project lookup failed: %s"
              (plist-get failure :message)))))

(provide 'pichat-consult)
;;; pichat-consult.el ends here
