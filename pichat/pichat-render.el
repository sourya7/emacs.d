;;; pichat-render.el --- Rendering helpers for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Minimal standard-buffer rendering.  This intentionally avoids VUI.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'pichat-transcript)
(require 'pichat-activity-presentation)

(cl-defstruct (pichat-render-context
               (:constructor pichat-render-context-create)
               (:conc-name pichat-render-context-))
  "Explicit display policy for pure transcript rendering."
  show-thinking
  tool-view
  tool-views
  tool-renderer
  max-tool-args
  max-tool-output
  activity-member-kinds
  activity-display
  activity-views
  activity-latest-key
  activity-live-p
  activity-header-renderer)

(cl-defstruct (pichat-render-fragment
               (:constructor pichat-render-fragment-create)
               (:conc-name pichat-render-fragment-))
  "Rendered text and zero-based logical property ranges."
  text
  ranges)

(defun pichat-render-default-context ()
  "Return the default immutable rendering policy."
  (pichat-render-context-create
   :show-thinking t
   :tool-view 'summary
   :max-tool-args 1200
   :max-tool-output 4000
   :activity-member-kinds '(thinking tool)
   :activity-display 'expanded
   :activity-views nil
   :activity-latest-key nil
   :activity-live-p nil))

(defun pichat-render--text-fragment (text &optional properties)
  "Return a fragment containing TEXT and optional PROPERTIES."
  (let ((text (or text "")))
    (pichat-render-fragment-create
     :text text
     :ranges (when (and properties (> (length text) 0))
               (list (list :start 0 :end (length text)
                           :properties properties))))))

(defun pichat-render--concat (fragments &optional separator)
  "Concatenate FRAGMENTS with SEPARATOR and adjust logical ranges."
  (let ((separator (or separator ""))
        (offset 0)
        texts
        ranges)
    (dolist (fragment fragments)
      (when (> offset 0)
        (push separator texts)
        (cl-incf offset (length separator)))
      (push (pichat-render-fragment-text fragment) texts)
      (dolist (range (pichat-render-fragment-ranges fragment))
        (push (list :start (+ offset (plist-get range :start))
                    :end (+ offset (plist-get range :end))
                    :properties (copy-sequence
                                 (plist-get range :properties)))
              ranges))
      (cl-incf offset (length (pichat-render-fragment-text fragment))))
    (pichat-render-fragment-create
     :text (apply #'concat (nreverse texts))
     :ranges (nreverse ranges))))

(defun pichat-render--wrap-properties (fragment properties)
  "Apply PROPERTIES to the whole non-empty FRAGMENT."
  (if (string-empty-p (pichat-render-fragment-text fragment))
      fragment
    (pichat-render-fragment-create
     :text (pichat-render-fragment-text fragment)
     :ranges (cons (list :start 0
                         :end (length (pichat-render-fragment-text fragment))
                         :properties properties)
                   (pichat-render-fragment-ranges fragment)))))

(defun pichat-render-fragment-propertized-string (fragment)
  "Return a propertized copy of rendered FRAGMENT text."
  (let ((text (copy-sequence (pichat-render-fragment-text fragment))))
    (dolist (range (pichat-render-fragment-ranges fragment))
      (add-text-properties (plist-get range :start)
                           (plist-get range :end)
                           (plist-get range :properties)
                           text))
    text))

(defun pichat-render-content (content)
  "Return human-readable text for Pi message CONTENT.
Only model-visible text/image placeholders are rendered here.  Thinking blocks
and tool-call blocks are rendered through dedicated event/tool UI paths, not as
assistant transcript text."
  (cond
   ((stringp content) content)
   ((listp content)
    (string-join
     (delq nil
           (mapcar
            (lambda (part)
              (cond
               ((stringp part) part)
               ((and (listp part) (string= (plist-get part :type) "text"))
                (or (plist-get part :text) ""))
               ((and (listp part) (string= (plist-get part :type) "image"))
                "[image]")
               ;; Suppress thinking/toolCall content here.  These otherwise
               ;; appear as huge raw plists/signatures in the transcript.
               ((and (listp part)
                     (member (plist-get part :type) '("thinking" "toolCall")))
                nil)
               (t "[unsupported content]")))
            content))
     ""))
   (t "[unsupported content]")))

(defun pichat-render-message-text (message)
  "Return readable text for Agent MESSAGE plist."
  (pichat-render-content (plist-get message :content)))

(defun pichat-render-thinking-texts (content)
  "Return non-empty thinking strings from Pi message CONTENT."
  (when (listp content)
    (delq nil
          (mapcar
           (lambda (part)
             (when (and (listp part)
                        (string= (plist-get part :type) "thinking"))
               (let ((thinking (plist-get part :thinking)))
                 (cond
                  ((and (stringp thinking)
                        (not (string-empty-p (string-trim thinking))))
                   thinking)
                  ;; Some providers persist nested text chunks for thinking in
                  ;; provider-native forms; accept them defensively.
                  ((listp thinking)
                   (let ((text (pichat-render-content thinking)))
                     (unless (string-empty-p (string-trim text)) text)))))))
           content))))

(defun pichat-render-tool-args (args)
  "Return compact string for tool ARGS."
  (condition-case _
      (json-serialize args :false-object :json-false :null-object nil)
    (error "[unavailable arguments]")))

(defun pichat-render--bounded-line-value (value)
  "Return VALUE as bounded single-line protocol text."
  (truncate-string-to-width
   (replace-regexp-in-string "[[:space:]]+" " "
                             (if (stringp value) value ""))
   240 nil nil "…"))

(defun pichat-render-event-line (event)
  "Return a bounded one-line rendering for raw EVENT plist."
  (let ((type (pichat-render--bounded-line-value
               (plist-get event :type))))
    (pcase type
      ("agent_start" "[agent started]")
      ("agent_settled" "[agent settled]")
      ("compaction_start"
       (format "[compaction started: %s]"
               (or (pichat-render--bounded-line-value
                    (plist-get event :reason)) "unknown")))
      ("compaction_end"
       (format "[compaction ended: %s]"
               (or (pichat-render--bounded-line-value
                    (plist-get event :reason)) "unknown")))
      ("auto_retry_start" (format "[retry %s/%s: %s]"
                                   (or (plist-get event :attempt) "?")
                                   (or (plist-get event :maxAttempts) "?")
                                   (pichat-render--bounded-line-value
                                    (plist-get event :errorMessage))))
      ("auto_retry_end" "[retry ended]")
      (_ (format "[%s]" type)))))

(defun pichat-render-entry-text (entry)
  "Return readable text for a Pi session ENTRY plist."
  (let ((type (or (plist-get entry :type) (plist-get entry :entryType))))
    (pcase type
      ("message" (pichat-render-message-text (plist-get entry :message)))
      ("custom_message" (format "[custom:%s]\n%s"
                                 (or (plist-get entry :customType) "custom")
                                 (pichat-render-content (plist-get entry :content))))
      ("custom_entry" (format "[entry:%s]"
                               (or (plist-get entry :customType) "custom")))
      ("compaction_summary" (format "[compaction summary]\n%s"
                                     (or (plist-get entry :summary)
                                         "[summary unavailable]")))
      ("branch_summary" (format "[branch summary]\n%s"
                                 (or (plist-get entry :summary)
                                     "[summary unavailable]")))
      (_ (format "[%s]" (or type "entry"))))))

(defun pichat-render--truncate (text limit)
  "Truncate TEXT according to LIMIT with a deterministic notice."
  (let ((text (or text "")))
    (if (or (not (integerp limit))
            (< limit 0)
            (<= (length text) limit))
        text
      (concat (substring text 0 limit)
              (format "…[%d chars omitted]" (- (length text) limit))))))

(defun pichat-render--normalized-thinking (text)
  "Return compact display form of thinking TEXT."
  (replace-regexp-in-string
   "\n[ \t\n]*\n+" "\n" (string-trim (or text ""))))

(defun pichat-render--content-text (content)
  "Return plain display text for normalized CONTENT."
  (pcase (pichat-transcript-content-kind content)
    ('thinking (pichat-render--normalized-thinking
                (pichat-transcript-content-text content)))
    ((or 'prose 'image 'unknown)
     (or (pichat-transcript-content-text content) ""))
    (_ "")))

(defun pichat-render--output-text (content)
  "Return plain display text for normalized output CONTENT items."
  (mapconcat #'pichat-render--content-text content ""))

(defun pichat-render-tool-view-for (context node-key tool-id)
  "Return CONTEXT's display state for NODE-KEY and TOOL-ID."
  (or (alist-get (cons node-key tool-id)
                 (pichat-render-context-tool-views context)
                 nil nil #'equal)
      (pichat-render-context-tool-view context)))

(defun pichat-render--indent-fragment (fragment first-prefix rest-prefix)
  "Apply visual FIRST-PREFIX and REST-PREFIX to FRAGMENT lines.
The prefixes are display properties and do not alter the fragment's text."
  (let* ((text (pichat-render-fragment-text fragment))
         (newline (string-match "\n" text))
         (first-end (if newline (1+ newline) (length text)))
         (ranges (copy-sequence (pichat-render-fragment-ranges fragment))))
    (when (> first-end 0)
      (push (list :start 0 :end first-end
                  :properties (list 'line-prefix first-prefix
                                    'wrap-prefix first-prefix))
            ranges))
    (when (< first-end (length text))
      (push (list :start first-end :end (length text)
                  :properties (list 'line-prefix rest-prefix
                                    'wrap-prefix rest-prefix))
            ranges))
    (pichat-render-fragment-create :text text :ranges (nreverse ranges))))

(defun pichat-render--assistant-indent (fragment)
  "Apply the ordinary two-column assistant content indent to FRAGMENT."
  (pichat-render--indent-fragment fragment "  " "  "))

(defun pichat-render--tool-fragment (tool node-key context &optional activity-member-p)
  "Render normalized TOOL owned by NODE-KEY under CONTEXT.
When CONTEXT supplies a tool renderer, it may return final presentation text.
A nil return keeps the generic pure renderer as the fallback.  When
ACTIVITY-MEMBER-P is non-nil, apply the activity member/body visual levels."
  (let* ((name (or (pichat-transcript-content-name tool) "?"))
         (status (or (pichat-transcript-content-status tool) 'incomplete))
         (view (pichat-render-tool-view-for
                context node-key
                (pichat-transcript-content-tool-call-id tool)))
         (renderer (pichat-render-context-tool-renderer context))
         (custom-text (and renderer
                           (funcall renderer tool node-key context)))
         (body
          (if custom-text
              (pichat-render--text-fragment custom-text)
            (let* ((header (format "[tool:%s %s]" name status))
                   (header-fragment
                    (pichat-render--text-fragment
                     header '(font-lock-face pichat-tool-label-face))))
              (if (eq view 'summary)
                  header-fragment
                (let* ((args-value
                        (pichat-transcript-content-arguments tool))
                       (args
                        (unless (null args-value)
                          (pichat-render--truncate
                           (pichat-render-tool-args args-value)
                           (pichat-render-context-max-tool-args context))))
                       (output
                        (and (not (eq view 'args))
                             (pichat-render--truncate
                              (pichat-render--output-text
                               (pichat-transcript-content-output tool))
                              (pichat-render-context-max-tool-output context))))
                       (line
                        (pichat-render--concat
                         (delq nil
                               (list
                                header-fragment
                                (and args
                                     (pichat-render--text-fragment args))))
                         " ")))
                  (if (or (eq view 'args) (string-empty-p output))
                      line
                    (pichat-render--concat
                     (list line (pichat-render--text-fragment output))
                     "\n"))))))))
    (setq body
          (pichat-render--wrap-properties
           body
           (list 'pichat-content-kind 'tool
                 'pichat-tool-key
                 (cons node-key (pichat-transcript-content-tool-call-id tool))
                 'pichat-activity-member (and activity-member-p t))))
    (if activity-member-p
        (pichat-render--indent-fragment body "  " "    ")
      body)))

(defun pichat-render--content-fragment (content node-key context)
  "Render normalized CONTENT owned by NODE-KEY under CONTEXT."
  (pcase (pichat-transcript-content-kind content)
    ('tool (pichat-render--tool-fragment content node-key context))
    ('thinking
     (pichat-render--assistant-indent
      (pichat-render--text-fragment
       (pichat-render--content-text content)
       '(pichat-content-kind thinking
         font-lock-face pichat-thinking-face))))
    ('prose
     (pichat-render--assistant-indent
      (pichat-render--text-fragment
       (pichat-render--content-text content)
       '(pichat-content-kind prose pichat-prose t))))
    ('image
     (pichat-render--text-fragment
      (pichat-render--content-text content)
      '(pichat-content-kind image font-lock-face shadow)))
    (_
     (pichat-render--text-fragment
      (pichat-render--content-text content)
      '(pichat-content-kind unknown font-lock-face warning)))))

(defun pichat-render--content-separator (previous current)
  "Return separator between PREVIOUS and CURRENT content kinds."
  (cond
   ((null previous) "")
   ((or (eq previous 'tool) (eq current 'tool)) "\n")
   ((and (eq previous 'thinking) (eq current 'thinking)) "\n")
   ((or (eq previous 'thinking) (eq current 'thinking)) "\n\n")
   (t "")))

(defun pichat-render--assistant-content (node context)
  "Render assistant NODE content under CONTEXT."
  (let (result previous-kind)
    (dolist (content (pichat-transcript-node-content node))
      (let ((kind (pichat-transcript-content-kind content)))
        (unless (and (eq kind 'thinking)
                     (not (pichat-render-context-show-thinking context)))
          (let* ((fragment (pichat-render--content-fragment
                            content (pichat-transcript-node-key node) context))
                 (separator (pichat-render--content-separator
                             previous-kind kind)))
            (setq result
                  (if result
                      (pichat-render--concat (list result fragment) separator)
                    fragment)
                  previous-kind kind)))))
    (or result (pichat-render--text-fragment ""))))

(defun pichat-render--plain-content (content)
  "Return visible plain text for normalized CONTENT list."
  (mapconcat #'pichat-render--content-text
             (cl-remove-if
              (lambda (item)
                (memq (pichat-transcript-content-kind item)
                      '(thinking tool)))
              content)
             ""))

(defun pichat-render--user-block (text)
  "Return Pi-style user block for TEXT."
  (mapconcat (lambda (line) (concat "▌ " line))
             (split-string (or text "") "\n" nil)
             "\n"))

(defun pichat-render--assistant-annotation (node)
  "Return completed stop annotation for assistant NODE, or nil."
  (let ((reason (pichat-transcript-node-stop-reason node))
        (message (pichat-transcript-node-error-message node)))
    (cond
     ((equal reason "aborted")
      (format "[assistant aborted%s]"
              (if (and (stringp message) (not (string-empty-p message)))
                  (concat ": " message)
                "")))
     ((equal reason "error")
      (format "[assistant error%s]"
              (if (and (stringp message) (not (string-empty-p message)))
                  (concat ": " message)
                "")))
     ((equal reason "length") "[assistant stopped: length]"))))

(defun pichat-render--node-fragment (node context)
  "Render canonical NODE under CONTEXT."
  (let* ((kind (pichat-transcript-node-kind node))
         (role (pichat-transcript-node-role node))
         (body
          (pcase kind
            ('activity
             (pichat-render--text-fragment
              (format "[compaction: %s tokens]"
                      (or (pichat-transcript-node-tokens-before node) "?"))
              '(pichat-content-kind activity font-lock-face shadow)))
            ('tool
             (pichat-render--tool-fragment
              (car (pichat-transcript-node-content node))
              (pichat-transcript-node-key node) context))
            (_
             (pcase role
               ('user
                (pichat-render--text-fragment
                 (pichat-render--user-block
                  (pichat-render--plain-content
                   (pichat-transcript-node-content node)))
                 '(font-lock-face pichat-user-block-face)))
               ('custom
                (pichat-render--concat
                 (list
                  (pichat-render--text-fragment
                   (format "[context:%s]"
                           (or (pichat-transcript-node-custom-type node)
                               "custom"))
                   '(font-lock-face font-lock-constant-face))
                  (pichat-render--text-fragment
                   (pichat-render--plain-content
                    (pichat-transcript-node-content node))))
                 "\n"))
               ('assistant
                (let* ((content (pichat-render--assistant-content node context))
                       (annotation (pichat-render--assistant-annotation node)))
                  (if annotation
                      (pichat-render--concat
                       (delq nil
                             (list
                              (unless (string-empty-p
                                       (pichat-render-fragment-text content))
                                content)
                              (pichat-render--text-fragment
                               annotation
                               '(pichat-content-kind annotation
                                 font-lock-face error))))
                       "\n\n")
                    content)))
               (_ (pichat-render--text-fragment "")))))))
    (pichat-render--wrap-properties
     body (list 'pichat-node-key (pichat-transcript-node-key node)
                'pichat-node-role role))))

(defun pichat-render--assistant-slice-fragment (item context)
  "Render assistant-content presentation ITEM under CONTEXT."
  (let* ((node (pichat-activity-item-node item))
         (node-key (pichat-transcript-node-key node))
         result previous-kind)
    (dolist (content (pichat-activity-item-content item))
      (let* ((kind (pichat-transcript-content-kind content))
             (fragment (pichat-render--content-fragment
                        content node-key context))
             (separator (pichat-render--content-separator previous-kind kind)))
        (setq result (if result
                         (pichat-render--concat
                          (list result fragment) separator)
                       fragment)
              previous-kind kind)))
    (pichat-render--wrap-properties
     (or result (pichat-render--text-fragment ""))
     (list 'pichat-node-key node-key
           'pichat-node-role (pichat-transcript-node-role node)))))

(defun pichat-render--annotation-fragment (node)
  "Render NODE's assistant stop annotation as a structural fragment."
  (let ((annotation (pichat-render--assistant-annotation node)))
    (if annotation
        (pichat-render--wrap-properties
         (pichat-render--text-fragment
          annotation '(pichat-content-kind annotation font-lock-face error))
         (list 'pichat-node-key (pichat-transcript-node-key node)
               'pichat-node-role (pichat-transcript-node-role node)))
      (pichat-render--text-fragment ""))))

(defun pichat-render--activity-header-fragment (group expanded context)
  "Render GROUP header with EXPANDED state under CONTEXT."
  (let* ((renderer (pichat-render-context-activity-header-renderer context))
         (text (or (and renderer (funcall renderer group expanded context))
                   (format "%s %s"
                           (if expanded "▼" "▶")
                           (pichat-activity-format-summary group))))
         (first (car (pichat-activity-group-members group))))
    (pichat-render--text-fragment
     text
     (list 'pichat-content-kind 'activity-header
           'pichat-activity-key (pichat-activity-group-key group)
           'pichat-activity-anchor (pichat-activity-group-anchor group)
           'pichat-activity-source-anchor
           (list 'source (pichat-activity-member-source-key first))
           'pichat-activity-tool-ids (pichat-activity-group-tool-ids group)
           'pichat-activity-expanded expanded
           'pichat-activity-member-kinds
           (mapcar #'pichat-activity-member-kind
                   (pichat-activity-group-members group))
           'pichat-activity-status (pichat-activity-group-status group)
           'pichat-node-key (pichat-activity-member-node-key first)
           'pichat-node-role (pichat-activity-member-role first)
           'font-lock-face 'pichat-tool-label-face))))

(defun pichat-render--activity-member-fragment (member group context)
  "Render MEMBER as a child of GROUP under CONTEXT."
  (let* ((content (pichat-activity-member-content member))
         (node-key (pichat-activity-member-node-key member))
         (fragment
          (pcase (pichat-activity-member-kind member)
            ('tool (pichat-render--tool-fragment
                    content node-key context t))
            (_ (pichat-render--assistant-indent
                (pichat-render--content-fragment
                 content node-key context))))))
    (pichat-render--wrap-properties
     fragment
     (list 'pichat-activity-member t
           'pichat-activity-key (pichat-activity-group-key group)
           'pichat-node-key node-key
           'pichat-node-role (pichat-activity-member-role member)))))

(defun pichat-render--trailing-newlines (text)
  "Return the number of trailing newline characters in TEXT."
  (let ((position (1- (length text))) (count 0))
    (while (and (>= position 0) (eq (aref text position) ?\n))
      (cl-incf count)
      (cl-decf position))
    count))

(defun pichat-render--prefix-for-separation (previous-text desired)
  "Return display separator after PREVIOUS-TEXT with DESIRED newlines."
  (if (null previous-text) ""
    (make-string (max 0 (- desired
                           (pichat-render--trailing-newlines previous-text)))
                 ?\n)))

(defun pichat-render--presentation-records (transcript context)
  "Return shared logical fragment records for TRANSCRIPT under CONTEXT."
  (let* ((member-kinds
          (or (pichat-render-context-activity-member-kinds context) '(tool)))
         (presentation
          (pichat-activity-build-presentation
           transcript member-kinds
           (pichat-render-context-show-thinking context)))
         records previous-text)
    (cl-labels
        ((emit
          (key node-key tool-id activity-key fragment desired-newlines)
          (unless (string-empty-p (pichat-render-fragment-text fragment))
            (let* ((prefix (pichat-render--prefix-for-separation
                            previous-text desired-newlines))
                   (complete (if (string-empty-p prefix)
                                 fragment
                               (pichat-render--concat
                                (list (pichat-render--text-fragment prefix)
                                      fragment)
                                ""))))
              (push (list :key key :node-key node-key :tool-id tool-id
                          :activity-key activity-key :fragment complete)
                    records)
              (setq previous-text
                    (pichat-render-fragment-text complete))))))
      (dolist (item presentation)
        (pcase (pichat-activity-item-kind item)
          ('group
           (let* ((group (pichat-activity-item-group item))
                  (group-key (pichat-activity-group-key group))
                  (expanded
                   (pichat-activity-resolve-expanded-p
                    group
                    (or (pichat-render-context-activity-display context)
                        'expanded)
                    (pichat-render-context-activity-views context)
                    (pichat-render-context-activity-latest-key context)
                    (pichat-render-context-activity-live-p context))))
             (emit (list 'activity group-key)
                   (pichat-activity-member-node-key
                    (car (pichat-activity-group-members group)))
                   nil group-key
                   (pichat-render--activity-header-fragment
                    group expanded context)
                   2)
             (when expanded
               (dolist (member (pichat-activity-group-members group))
                 (let ((tool-id (pichat-activity-member-tool-call-id member)))
                   (emit (list (pichat-activity-member-kind member)
                               (pichat-activity-member-node-key member)
                               (or tool-id
                                   (pichat-activity-member-source-key member)))
                         (pichat-activity-member-node-key member)
                         tool-id group-key
                         (pichat-render--activity-member-fragment
                          member group context)
                         1))))))
          ('assistant-content
           (emit (pichat-activity-item-key item)
                 (pichat-transcript-node-key
                  (pichat-activity-item-node item))
                 nil nil
                 (pichat-render--assistant-slice-fragment item context)
                 2))
          ('annotation
           (emit (pichat-activity-item-key item)
                 (pichat-transcript-node-key
                  (pichat-activity-item-node item))
                 nil nil
                 (pichat-render--annotation-fragment
                  (pichat-activity-item-node item))
                 2))
          ('node
           (let ((node (pichat-activity-item-node item)))
             (emit (pichat-activity-item-key item)
                   (pichat-transcript-node-key node) nil nil
                   (pichat-render--node-fragment node context) 2))))))
    (nreverse records)))

(defun pichat-render-logical-strings (transcript &optional context)
  "Return stable logical rendered records for TRANSCRIPT.
Canonical and logical rendering consume the same presentation sequence, and
concatenating every returned `:text' exactly equals `pichat-render-canonical'."
  (let ((context (or context (pichat-render-default-context))))
    (mapcar
     (lambda (record)
       (list :key (plist-get record :key)
             :node-key (plist-get record :node-key)
             :tool-id (plist-get record :tool-id)
             :activity-key (plist-get record :activity-key)
             :text (pichat-render-fragment-propertized-string
                    (plist-get record :fragment))))
     (pichat-render--presentation-records transcript context))))

(defun pichat-render-canonical (transcript &optional context)
  "Purely render canonical TRANSCRIPT using explicit CONTEXT."
  (let* ((context (or context (pichat-render-default-context)))
         (records (pichat-render--presentation-records transcript context)))
    (pichat-render--concat
     (mapcar (lambda (record) (plist-get record :fragment)) records)
     "")))

(provide 'pichat-render)
;;; pichat-render.el ends here
