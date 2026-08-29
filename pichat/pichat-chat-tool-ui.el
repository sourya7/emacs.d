;;; pichat-chat-tool-ui.el --- Tool presentation for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused presentation helpers for live and canonical tool blocks.  The chat
;; orchestration layer passes all mutable state explicitly; this module neither
;; requires `pichat-chat' nor owns canonical transcript state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-pi)
(require 'pichat-render)
(require 'pichat-tool-enrichment)
(require 'pichat-shell-presentation)

(declare-function pichat-chat-visit-tool-location "pichat-chat" (&optional event))

(defvar pichat-chat-tool-location-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-visit-tool-location)
    (define-key map [mouse-1] #'pichat-chat-visit-tool-location)
    map)
  "Keymap attached to derived tool-location presentation text.")

(defun pichat-chat-tool-ui-release-block (block)
  "Release markers and overlay owned by BLOCK."
  (dolist (key '(:start :end))
    (when-let ((marker (plist-get block key)))
      (when (markerp marker) (set-marker marker nil))))
  (when-let ((overlay (plist-get block :overlay)))
    (when (overlayp overlay) (delete-overlay overlay))
    (setf (plist-get block :overlay) nil)))

(defun pichat-chat-tool-ui-release-blocks (blocks)
  "Release markers and overlays owned by BLOCKS."
  (when (hash-table-p blocks)
    (maphash (lambda (_id block)
               (pichat-chat-tool-ui-release-block block))
             blocks)))

(defun pichat-chat-tool-ui-live-view-key (generation tool-id)
  "Return explicit live view key for GENERATION and TOOL-ID."
  (list 'live generation tool-id))

(defun pichat-chat-tool-ui-canonical-view-key (node-key tool-id)
  "Return durable explicit view key for NODE-KEY and TOOL-ID."
  (list 'canonical node-key tool-id))

(defun pichat-chat-tool-ui-explicit-view
    (view-states generation node-key tool-id live-p)
  "Return explicit view from VIEW-STATES for TOOL-ID.
GENERATION scopes live state.  NODE-KEY identifies canonical ownership, and
LIVE-P selects live state while a candidate canonical projection may fall back
to the matching live choice."
  (if live-p
      (gethash (pichat-chat-tool-ui-live-view-key generation tool-id)
               view-states)
    (or (gethash (pichat-chat-tool-ui-canonical-view-key node-key tool-id)
                 view-states)
        (gethash (pichat-chat-tool-ui-live-view-key generation tool-id)
                 view-states))))

(defun pichat-chat-tool-ui-completed-display-state (collapse-p default)
  "Return completed display state from COLLAPSE-P and DEFAULT."
  (if collapse-p 'summary default))

(defun pichat-chat-tool-ui-views-for-transcript
    (transcript live-p generation view-states live-draft collapse-p default)
  "Return per-tool render views for TRANSCRIPT.
LIVE-P keeps active tools expanded.  GENERATION and VIEW-STATES scope explicit
choices; LIVE-DRAFT determines whether incomplete live tools are settled."
  (let (views)
    (dolist (node (pichat-transcript-nodes transcript))
      (dolist (content (pichat-transcript-node-content node))
        (when (eq 'tool (pichat-transcript-content-kind content))
          (let* ((node-key (pichat-transcript-node-key node))
                 (tool-id (pichat-transcript-content-tool-call-id content))
                 (status (pichat-transcript-content-status content))
                 (explicit
                  (pichat-chat-tool-ui-explicit-view
                   view-states generation node-key tool-id live-p))
                 (active-p
                  (and live-p
                       (or (eq status 'running)
                           (and (eq status 'incomplete)
                                (not (pichat-live-draft-settled-p live-draft))))))
                 (view (or explicit
                           (if active-p 'output
                             (pichat-chat-tool-ui-completed-display-state
                              collapse-p default)))))
            (push (cons (cons node-key tool-id) view) views)))))
    views))

(defun pichat-chat-tool-ui--canonical-tool (transcript tool-key)
  "Return normalized tool in TRANSCRIPT identified by TOOL-KEY."
  (let* ((node-key (car-safe tool-key))
         (tool-id (cdr-safe tool-key))
         (node (cl-find node-key (pichat-transcript-nodes transcript)
                        :key #'pichat-transcript-node-key :test #'equal)))
    (cl-find tool-id (and node (pichat-transcript-node-content node))
             :key #'pichat-transcript-content-tool-call-id :test #'equal)))

(defun pichat-chat-tool-ui--canonical-output (tool)
  "Return plain persisted output text for normalized TOOL."
  (mapconcat (lambda (content)
               (or (pichat-transcript-content-text content) ""))
             (pichat-transcript-content-output tool) ""))

(defun pichat-chat-tool-ui-enrichment (table generation tool-id)
  "Return current GENERATION's enrichment for TOOL-ID from TABLE."
  (when (and (hash-table-p table) (stringp tool-id))
    (let ((record (gethash tool-id table)))
      (and (= generation (or (plist-get record :source-generation) -1))
           record))))

(defun pichat-chat-tool-ui-location-string (record)
  "Return RECORD's host location as a concise string, or nil."
  (when-let ((path (plist-get record :host-path)))
    (concat path
            (when-let ((line (plist-get record :line)))
              (format ":%d" line))
            (when-let ((column (plist-get record :column)))
              (format ":%d" column)))))

(defun pichat-chat-tool-ui-decorate-block (block enrichments generation)
  "Add derived actionable location presentation to BLOCK.
ENRICHMENTS is scoped to GENERATION.  The overlay changes only presentation;
the underlying canonical/live source text and block display state are intact."
  (when-let ((old (plist-get block :overlay)))
    (when (overlayp old) (delete-overlay old))
    (setf (plist-get block :overlay) nil))
  (let* ((raw (plist-get block :raw))
         (id (plist-get raw :toolCallId))
         (record (pichat-chat-tool-ui-enrichment enrichments generation id))
         (location (and record
                        (pichat-chat-tool-ui-location-string record)))
         (start (marker-position (plist-get block :start)))
         (end (marker-position (plist-get block :end))))
    (when (and location start end (< start end))
      (save-excursion
        (goto-char start)
        (let* ((line-end (min end (line-end-position)))
               (found (search-forward location line-end t))
               (overlay
                (if found
                    (make-overlay (- found (length location)) found nil t nil)
                  (make-overlay line-end line-end nil t nil))))
          (overlay-put overlay 'font-lock-face 'link)
          (overlay-put overlay 'mouse-face 'highlight)
          (overlay-put overlay 'help-echo
                       "RET or mouse-1: visit; C-c C-w: copy location")
          (overlay-put overlay 'keymap pichat-chat-tool-location-map)
          (overlay-put overlay 'pichat-tool-location location)
          (unless found
            (overlay-put
             overlay 'after-string
             (propertize
              (format " [%s]" location)
              'font-lock-face 'link
              'mouse-face 'highlight
              'help-echo
              "RET or mouse-1: visit; C-c C-w: copy location"
              'keymap pichat-chat-tool-location-map
              'pichat-tool-location location)))
          (overlay-put overlay 'evaporate t)
          (overlay-put overlay 'pichat-tool-location-overlay t)
          (setf (plist-get block :overlay) overlay))))))

(defun pichat-chat-tool-ui-refresh-decorations (blocks enrichments generation)
  "Recreate location decorations for BLOCKS in GENERATION."
  (when (hash-table-p blocks)
    (maphash (lambda (_id block)
               (pichat-chat-tool-ui-decorate-block
                block enrichments generation))
             blocks)))

(defun pichat-chat-tool-ui--raw-tool (tool)
  "Return the interactive raw-tool shape for normalized TOOL."
  (list :toolCallId (pichat-transcript-content-tool-call-id tool)
        :toolName (pichat-transcript-content-name tool)
        :args (pichat-transcript-content-arguments tool)))

(defun pichat-chat-tool-ui-render-tool-text
    (enrichments generation notice-format tool node-key context)
  "Return final specialized text for TOOL, or nil for generic rendering.
ENRICHMENTS and GENERATION select current derived presentation data.
NOTICE-FORMAT controls output truncation.  NODE-KEY and CONTEXT select the
pure render view.  This function reads only its explicit inputs and never
edits a buffer or mutates transcript state."
  (let* ((raw (pichat-chat-tool-ui--raw-tool tool))
         (tool-id (plist-get raw :toolCallId))
         (enrichment
          (or (pichat-chat-tool-ui-enrichment
               enrichments generation tool-id)
              (pichat-tool-enrichment-build
               tool-id (plist-get raw :toolName) (plist-get raw :args)))))
    (pichat-chat-tool-ui-text
     raw
     (symbol-name
      (or (pichat-transcript-content-status tool) 'incomplete))
     (pichat-chat-tool-ui--canonical-output tool)
     (pichat-render-tool-view-for context node-key tool-id)
     (pichat-render-context-max-tool-args context)
     (pichat-render-context-max-tool-output context)
     notice-format enrichment)))

(defun pichat-chat-tool-ui-index-tools
    (transcript start end context live-p generation enrichments)
  "Build interactive tool blocks for TRANSCRIPT between START and END.
CONTEXT supplies display state.  LIVE-P selects source-scoped view keys.
GENERATION and ENRICHMENTS supply derived presentation.  This function only
creates block records, markers, and overlays; rendered text is never edited."
  (let ((blocks (make-hash-table :test #'equal))
        (pos start))
    (while (< pos end)
      (let* ((tool-key (get-text-property pos 'pichat-tool-key))
             (next (or (next-single-property-change
                        pos 'pichat-tool-key nil end) end)))
        (when tool-key
          (when-let ((tool (pichat-chat-tool-ui--canonical-tool
                            transcript tool-key)))
            (let* ((tool-id (pichat-transcript-content-tool-call-id tool))
                   (block
                    (list :start (copy-marker pos t)
                          :end (copy-marker next nil)
                          :raw (pichat-chat-tool-ui--raw-tool tool)
                          :overlay nil :started-at nil
                          :status (symbol-name
                                   (pichat-transcript-content-status tool))
                          :display-state
                          (pichat-render-tool-view-for
                           context (car tool-key) tool-id)
                          :view-state-key
                          (if live-p
                              (pichat-chat-tool-ui-live-view-key
                               generation tool-id)
                            (pichat-chat-tool-ui-canonical-view-key
                             (car tool-key) tool-id))
                          :full-text
                          (pichat-chat-tool-ui--canonical-output tool)
                          :canonical-key tool-key)))
              (puthash tool-id block blocks)
              (pichat-chat-tool-ui-decorate-block
               block enrichments generation))))
        (setq pos next)))
    blocks))

(defun pichat-chat-tool-ui-merge-block-tables (first second)
  "Return FIRST after merging tool blocks from SECOND."
  (maphash (lambda (key value) (puthash key value first)) second)
  first)

(defun pichat-chat-tool-ui-truncate-output (text limit notice-format)
  "Return TEXT truncated at LIMIT using NOTICE-FORMAT."
  (let ((text (or text "")))
    (if (<= (length text) limit) text
      (concat (substring text 0 limit)
              (format notice-format (- (length text) limit))))))

(defun pichat-chat-tool-ui-truncate-args (args limit)
  "Return compact display string for ARGS bounded by LIMIT."
  (when args
    (let ((text (pichat-render-tool-args args)))
      (unless (or (string-empty-p text) (string= text "null"))
        (if (<= (length text) limit) text
          (concat (substring text 0 limit)
                  (format "…[%d chars omitted]" (- (length text) limit))))))))

(defun pichat-chat-tool-ui--single-line (value limit fallback)
  "Return VALUE flattened and bounded to LIMIT, or FALLBACK."
  (let ((text (replace-regexp-in-string
               "[[:space:]\n\r]+" " "
               (string-trim (if (stringp value) value "")))))
    (if (string-empty-p text)
        fallback
      (truncate-string-to-width text limit nil nil "…"))))

(defun pichat-chat-tool-ui-status-glyph (status)
  "Return concise status glyph for normalized STATUS."
  (pcase (if (symbolp status) status (intern (or status "incomplete")))
    ('done "✓")
    ('error "✗")
    ('orphan "?")
    ((or 'running 'incomplete) "…")
    (_ "?")))

(defun pichat-chat-tool-ui-kind-label (kind)
  "Return concise row label for enrichment KIND."
  (pcase kind
    ('execute "run")
    ('read "read")
    ('write "write")
    ('edit "edit")
    ('search "search")
    ('fetch "fetch")
    (_ "tool")))

(defun pichat-chat-tool-ui--exception-label (enrichment status)
  "Return exceptional outcome suffix for ENRICHMENT and STATUS, or nil."
  (when (pichat-shell-presentation-execute-p enrichment)
    (let ((label (pichat-shell-presentation-outcome-label
                  (plist-get enrichment :shell-outcome) status)))
      (unless (member label '("running" "completed" "incomplete"))
        label))))

(defun pichat-chat-tool-ui-format-header (raw status enrichment)
  "Return a concise enriched header for RAW with STATUS and ENRICHMENT."
  (let* ((kind (or (plist-get enrichment :kind) 'other))
         (title (pichat-chat-tool-ui--single-line
                 (plist-get enrichment :title) 120
                 (pichat-chat-tool-ui--single-line
                  (plist-get raw :toolName) 60 "unknown tool")))
         (exception (pichat-chat-tool-ui--exception-label enrichment status)))
    (propertize
     (format "%s %-6s %s%s"
             (pichat-chat-tool-ui-status-glyph status)
             (pichat-chat-tool-ui-kind-label kind)
             title
             (if exception (format " · %s" exception) ""))
     'font-lock-face 'pichat-tool-label-face)))

(defun pichat-chat-tool-ui--replace-first-line (text header)
  "Return TEXT with its first line replaced by HEADER."
  (if (string-match "\n" text)
      (concat header (substring text (match-beginning 0)))
    header))

(defun pichat-chat-tool-ui-text
    (raw status text state max-args max-output notice-format &optional enrichment)
  "Return rendered tool text for RAW, STATUS, TEXT, and display STATE.
ENRICHMENT enables kind-specific presentation; it is derived from RAW when
omitted.  Complete raw values remain available through the block details UI."
  (let* ((state (or state 'output))
         (enrichment
          (or enrichment
              (pichat-tool-enrichment-build
               (plist-get raw :toolCallId)
               (plist-get raw :toolName)
               (plist-get raw :args))))
         (header (pichat-chat-tool-ui-format-header raw status enrichment)))
    (if (pichat-shell-presentation-execute-p enrichment)
        (pichat-chat-tool-ui--replace-first-line
         (pichat-shell-presentation-text
          enrichment status text state max-args max-output notice-format)
         header)
      (let ((args (pichat-chat-tool-ui-truncate-args
                   (plist-get raw :args) max-args)))
        (pcase state
          ('summary (format "%s\n" header))
          ('args
           (if args
               (format "%s\nArguments:\n%s\n" header args)
             (format "%s\n" header)))
          (_
           (format "%s%sOutput:\n%s\n"
                   header
                   (if args (format "\nArguments:\n%s\n" args) "\n")
                   (pichat-chat-tool-ui-truncate-output
                    text max-output notice-format))))))))

(defun pichat-chat-tool-ui-indent-text (text)
  "Return a copy of TEXT with visual activity member/body prefixes."
  (let* ((copy (copy-sequence text))
         (newline (string-match "\n" copy))
         (first-end (if newline (1+ newline) (length copy))))
    (when (> first-end 0)
      (add-text-properties 0 first-end
                           '(line-prefix "  " wrap-prefix "  ") copy))
    (when (< first-end (length copy))
      (add-text-properties first-end (length copy)
                           '(line-prefix "    " wrap-prefix "    ") copy))
    copy))

(defun pichat-chat-tool-ui-replace-region
    (block text tracked-markers edit-function)
  "Replace BLOCK with TEXT while updating TRACKED-MARKERS.
EDIT-FUNCTION receives a thunk and supplies the chat layer's transactional
buffer-edit and view-preservation mechanics."
  (let* ((start-marker (plist-get block :start))
         (end-marker (plist-get block :end))
         (start-pos (marker-position start-marker))
         (end-pos (marker-position end-marker))
         (logical-properties
          (cl-loop for property in '(pichat-node-key pichat-node-role
                                      pichat-content-kind pichat-tool-key
                                      pichat-activity-key
                                      pichat-activity-member)
                   for value = (get-text-property start-pos property)
                   when value append (list property value)))
         (tracked
          (delq nil
                (mapcar (lambda (marker)
                          (when (and (markerp marker)
                                     (marker-position marker))
                            (cons marker (marker-position marker))))
                        tracked-markers))))
    (funcall
     edit-function
     (lambda ()
       (set-marker-insertion-type start-marker nil)
       (goto-char start-pos)
       (delete-region start-pos end-pos)
       (let ((beg (point)))
         (insert text)
         (add-text-properties beg (point) logical-properties)
         (add-text-properties
          beg (point)
          '(read-only t front-sticky t rear-nonsticky t
            pichat-transcript t)))
       (let ((new-end (+ start-pos (length text)))
             (delta (- (length text) (- end-pos start-pos))))
         (set-marker start-marker start-pos)
         (set-marker-insertion-type start-marker t)
         (set-marker end-marker new-end)
         (dolist (entry tracked)
           (when (>= (cdr entry) end-pos)
             (set-marker (car entry) (+ (cdr entry) delta)))))
       (setq buffer-undo-list nil)))))

(defun pichat-chat-tool-ui-render-block (block context)
  "Re-render BLOCK according to its display state using CONTEXT."
  (when-let ((overlay (plist-get block :overlay)))
    (when (overlayp overlay) (delete-overlay overlay))
    (setf (plist-get block :overlay) nil))
  (let* ((raw (plist-get block :raw))
         (enrichment
          (or (pichat-chat-tool-ui-enrichment
               (plist-get context :enrichments)
               (plist-get context :generation)
               (plist-get raw :toolCallId))
              (pichat-tool-enrichment-build
               (plist-get raw :toolCallId)
               (plist-get raw :toolName)
               (plist-get raw :args))))
         (new
          (pichat-chat-tool-ui-indent-text
           (concat
            (or (plist-get block :prefix) "")
            (pichat-chat-tool-ui-text
             raw (or (plist-get block :status) "done")
             (or (plist-get block :full-text) "")
             (or (plist-get block :display-state) 'summary)
             (plist-get context :max-args)
             (plist-get context :max-output)
             (plist-get context :truncation-notice)
             enrichment)))))
    (pichat-chat-tool-ui-replace-region
     block new (plist-get context :tracked-markers)
     (plist-get context :edit-function))
    (pichat-chat-tool-ui-decorate-block
     block (plist-get context :enrichments) (plist-get context :generation))))

(defun pichat-chat-tool-ui-cycle-state (state)
  "Return top-level display state after STATE."
  (if (eq state 'summary) 'args 'summary))

(defun pichat-chat-tool-ui-collapse-block (block view-states context)
  "Set BLOCK to an explicit summary display and render it."
  (when block
    (setf (plist-get block :display-state) 'summary)
    (puthash (plist-get block :view-state-key) 'summary view-states)
    (pichat-chat-tool-ui-render-block block context)))

(defun pichat-chat-tool-ui-block-at (blocks position)
  "Return innermost BLOCKS entry containing POSITION."
  (let (found found-start)
    (maphash
     (lambda (_id block)
       (let ((start (marker-position (plist-get block :start)))
             (end (marker-position (plist-get block :end))))
         (when (and start end (<= start position) (< position end)
                    (or (null found-start) (> start found-start)))
           (setq found block found-start start))))
     blocks)
    found))

(defun pichat-chat-tool-ui-next-position (blocks position)
  "Return next tool start in BLOCKS after POSITION."
  (let (next)
    (maphash (lambda (_id block)
               (let ((start (marker-position (plist-get block :start))))
                 (when (and (> start position)
                            (or (null next) (< start next)))
                   (setq next start))))
             blocks)
    next))

(defun pichat-chat-tool-ui-previous-position (blocks position)
  "Return previous tool start in BLOCKS before POSITION."
  (let (previous)
    (maphash (lambda (_id block)
               (let ((start (marker-position (plist-get block :start))))
                 (when (and (< start position)
                            (or (null previous) (> start previous)))
                   (setq previous start))))
             blocks)
    previous))

(defun pichat-chat-tool-ui-toggle-block (block view-states context)
  "Toggle BLOCK, persist the choice in VIEW-STATES, and render via CONTEXT."
  (setf (plist-get block :display-state)
        (pichat-chat-tool-ui-cycle-state
         (or (plist-get block :display-state) 'summary)))
  (puthash (plist-get block :view-state-key)
           (plist-get block :display-state) view-states)
  (pichat-chat-tool-ui-render-block block context))

(defun pichat-chat-tool-ui-details-text (block auxiliary enrichment)
  "Return full details text for BLOCK, AUXILIARY data, and ENRICHMENT."
  (let ((raw (plist-get block :raw)))
    (concat
     (format "Tool: %s\n" (or (plist-get raw :toolName) "?"))
     (format "Started: %s\n" (or (plist-get block :started-at) "?"))
     (when enrichment
       (concat
        (format "Kind: %s\n" (or (plist-get enrichment :kind) 'other))
        (format "Title: %s\n" (or (plist-get enrichment :title) "?"))
        (when (pichat-shell-presentation-execute-p enrichment)
          (concat
           (format "Outcome: %s\n"
                   (pichat-shell-presentation-outcome-label
                    (plist-get enrichment :shell-outcome)
                    (plist-get block :status)))
           (format "Command (non-interactive):\n%s\n"
                   (or (pichat-shell-presentation-command enrichment)
                       "[command unavailable]"))))
        (if-let ((location
                  (pichat-chat-tool-ui-location-string enrichment)))
            (format "Location: %s\n" location)
          (when-let ((reason (plist-get enrichment :unavailable-reason)))
            (format "Location: [unavailable: %s]\n" reason)))))
     "\nArgs:\n" (pichat-render-tool-args (plist-get raw :args))
     "\n\nOutput:\n" (or (plist-get block :full-text) "")
     "\n\nAuxiliary execution details:\n"
     (if auxiliary
         (concat
          (truncate-string-to-width
           (pichat-render-tool-args (plist-get auxiliary :details))
           4000 nil nil "…")
          (when-let ((path (plist-get auxiliary :full-output-path)))
            (concat "\nFull output: "
                    (truncate-string-to-width path 1000 nil nil "…"))))
       "[non-persisted execution details unavailable]"))))

(provide 'pichat-chat-tool-ui)
;;; pichat-chat-tool-ui.el ends here
