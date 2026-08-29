;;; pichat-chat-activity-ui.el --- Activity group UI for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Marker-backed indexing, explicit disclosure state, and enriched formatting
;; for presentation-only activity groups.  Chat orchestration supplies all
;; mutable source state and owns reprojection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-activity-presentation)
(require 'pichat-tool-enrichment)

(declare-function pichat-chat-toggle-activity-at-point "pichat-chat" (&optional event))

(defvar pichat-chat-activity-ui-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-toggle-activity-at-point)
    (define-key map (kbd "TAB") #'pichat-chat-toggle-activity-at-point)
    (define-key map [mouse-1] #'pichat-chat-toggle-activity-at-point)
    map)
  "Keymap attached to rendered PiChat activity headers.")

(defun pichat-chat-activity-ui-live-view-key (generation anchor)
  "Return explicit live group key for GENERATION and durable ANCHOR."
  (list 'live generation 'activity anchor))

(defun pichat-chat-activity-ui-canonical-view-key (group-key)
  "Return explicit canonical group key for pure GROUP-KEY."
  (list 'canonical 'activity group-key))

(defun pichat-chat-activity-ui--state-view (state tool-ids)
  "Return STATE's view when its evidence exactly matches TOOL-IDS."
  (when (and (listp state)
             (equal (plist-get state :tool-ids) tool-ids))
    (plist-get state :view)))

(defun pichat-chat-activity-ui--tool-ids-extend-p (previous current)
  "Return non-nil when CURRENT only appends tool IDs to PREVIOUS."
  (and (listp previous)
       (listp current)
       (<= (length previous) (length current))
       (equal previous (seq-take current (length previous)))))

(defun pichat-chat-activity-ui--source-anchor (group)
  "Return GROUP's first-member source anchor."
  (when-let ((first (car (pichat-activity-group-members group))))
    (list 'source (pichat-activity-member-source-key first))))

(defun pichat-chat-activity-ui--live-explicit-view
    (view-states generation group)
  "Return the explicit live view for GROUP without mutating VIEW-STATES.
A live group may only extend its prior tool evidence.  A source-anchored choice
also follows thought-only activity when it gains its first durable tool anchor."
  (let* ((anchor (pichat-activity-group-anchor group))
         (tool-ids (pichat-activity-group-tool-ids group))
         (live-key
          (pichat-chat-activity-ui-live-view-key generation anchor))
         (source-key
          (pichat-chat-activity-ui-live-view-key
           generation (pichat-chat-activity-ui--source-anchor group)))
         (state (or (gethash live-key view-states)
                    (and (not (equal source-key live-key))
                         (gethash source-key view-states)))))
    (when (and state
               (pichat-chat-activity-ui--tool-ids-extend-p
                (plist-get state :tool-ids) tool-ids))
      (plist-get state :view))))

(defun pichat-chat-activity-ui-explicit-view
    (view-states generation group live-p)
  "Return explicit view for GROUP from VIEW-STATES.
GENERATION scopes transient choices and LIVE-P selects the owning source."
  (let* ((group-key (pichat-activity-group-key group))
         (anchor (pichat-activity-group-anchor group))
         (tool-ids (pichat-activity-group-tool-ids group))
         (canonical-key
          (pichat-chat-activity-ui-canonical-view-key group-key))
         (live-key
          (pichat-chat-activity-ui-live-view-key generation anchor)))
    (if live-p
        (pichat-chat-activity-ui--live-explicit-view
         view-states generation group)
      (or (pichat-chat-activity-ui--state-view
           (gethash canonical-key view-states) tool-ids)
          (pichat-chat-activity-ui--state-view
           (gethash live-key view-states) tool-ids)))))

(defun pichat-chat-activity-ui-presentation-state
    (transcript member-kinds show-thinking live-p generation view-states
                live-draft policy)
  "Return explicit views and latest key for rendering TRANSCRIPT.
MEMBER-KINDS and SHOW-THINKING select the pure presentation.  LIVE-P,
GENERATION, VIEW-STATES, LIVE-DRAFT, and POLICY resolve source-local state."
  (let* ((presentation
          (pichat-activity-build-presentation
           transcript member-kinds show-thinking))
         (groups (pichat-activity-groups presentation))
         (tail (car (last presentation)))
         (latest
          (and live-p
               (not (and (pichat-live-draft-p live-draft)
                         (pichat-live-draft-settled-p live-draft)))
               tail
               (eq (pichat-activity-item-kind tail) 'group)
               (pichat-activity-group-key
                (pichat-activity-item-group tail))))
         views)
    (dolist (group groups)
      (when-let ((view (pichat-chat-activity-ui-explicit-view
                        view-states generation group live-p)))
        (push (cons (pichat-activity-group-key group) view) views)))
    (list :presentation presentation
          :groups groups
          :views (nreverse views)
          :latest-key (and (eq policy 'latest) latest))))

(defun pichat-chat-activity-ui--enrichment
    (enrichments generation member)
  "Return current enrichment for MEMBER from ENRICHMENTS and GENERATION."
  (let* ((content (pichat-activity-member-content member))
         (id (pichat-activity-member-tool-call-id member))
         (record (and (eq (pichat-activity-member-kind member) 'tool)
                      (hash-table-p enrichments) (gethash id enrichments))))
    (if (and (eq (pichat-activity-member-kind member) 'tool)
             record
             (= generation (or (plist-get record :source-generation) -1)))
        record
      (and (eq (pichat-activity-member-kind member) 'tool)
           (pichat-tool-enrichment-build
            id
            (pichat-transcript-content-name content)
            (pichat-transcript-content-arguments content))))))

(defun pichat-chat-activity-ui-format-header
    (enrichments generation group expanded _context)
  "Return enriched header for GROUP with EXPANDED disclosure state."
  (let ((summary
         (pichat-activity-format-summary
          group
          (lambda (member)
            (plist-get
             (pichat-chat-activity-ui--enrichment
              enrichments generation member)
             :kind)))))
    (propertize
     (format "%s %s" (if expanded "▼" "▶") summary)
     'keymap pichat-chat-activity-ui-header-map
     'mouse-face 'highlight
     'help-echo "RET, TAB, or mouse-1: expand/collapse activity group")))

(defun pichat-chat-activity-ui-release-block (block)
  "Release markers owned by activity BLOCK."
  (dolist (key '(:start :end))
    (when-let ((marker (plist-get block key)))
      (when (markerp marker) (set-marker marker nil)))))

(defun pichat-chat-activity-ui-release-blocks (blocks)
  "Release markers owned by activity BLOCKS table."
  (when (hash-table-p blocks)
    (maphash (lambda (_key block)
               (pichat-chat-activity-ui-release-block block))
             blocks)))

(defun pichat-chat-activity-ui-index-groups
    (start end live-p generation)
  "Index rendered activity headers in START..END.
LIVE-P and GENERATION determine each block's explicit view-state key."
  (let ((blocks (make-hash-table :test #'equal))
        (position start))
    (while (< position end)
      (let* ((group-key (get-text-property position 'pichat-activity-key))
             (header-p (eq (get-text-property position 'pichat-content-kind)
                           'activity-header))
             (next (or (next-single-property-change
                        position 'pichat-activity-key nil end)
                       end)))
        (when (and group-key header-p)
          (let* ((anchor (get-text-property position 'pichat-activity-anchor))
                 (tool-ids
                  (copy-sequence
                   (or (get-text-property position 'pichat-activity-tool-ids)
                       nil)))
                 (source-anchor
                  (get-text-property position 'pichat-activity-source-anchor))
                 (block
                  (list :start (copy-marker position t)
                        :end (copy-marker next nil)
                        :key group-key :anchor anchor
                        :source-anchor source-anchor :tool-ids tool-ids
                        :display-state
                        (if (get-text-property position
                                              'pichat-activity-expanded)
                            'expanded 'collapsed)
                        :view-state-key
                        (if live-p
                            (pichat-chat-activity-ui-live-view-key
                             generation anchor)
                          (pichat-chat-activity-ui-canonical-view-key
                           group-key)))))
            (puthash group-key block blocks)))
        (setq position next)))
    blocks))

(defun pichat-chat-activity-ui-merge-block-tables (first second)
  "Return a new table containing FIRST and SECOND activity blocks."
  (let ((combined (make-hash-table :test #'equal)))
    (dolist (table (list first second))
      (when (hash-table-p table)
        (maphash (lambda (key value) (puthash key value combined)) table)))
    combined))

(defun pichat-chat-activity-ui-block-at (blocks position)
  "Return the activity header block in BLOCKS containing POSITION."
  (let (found)
    (when (hash-table-p blocks)
      (maphash
       (lambda (_key block)
         (let ((start (marker-position (plist-get block :start)))
               (end (marker-position (plist-get block :end))))
           (when (and start end (<= start position) (< position end))
             (setq found block))))
       blocks))
    found))

(defun pichat-chat-activity-ui-next-position (blocks position)
  "Return next activity header position in BLOCKS after POSITION."
  (let (next)
    (maphash
     (lambda (_key block)
       (when-let ((start (marker-position (plist-get block :start))))
         (when (and (> start position) (or (null next) (< start next)))
           (setq next start))))
     blocks)
    next))

(defun pichat-chat-activity-ui-previous-position (blocks position)
  "Return previous activity header position in BLOCKS before POSITION."
  (let (previous)
    (maphash
     (lambda (_key block)
       (when-let ((start (marker-position (plist-get block :start))))
         (when (and (< start position)
                    (or (null previous) (> start previous)))
           (setq previous start))))
     blocks)
    previous))

(defun pichat-chat-activity-ui-store-view (block view-states view)
  "Store explicit VIEW for BLOCK in VIEW-STATES."
  (puthash (plist-get block :view-state-key)
           (list :view view
                 :tool-ids (copy-sequence (plist-get block :tool-ids)))
           view-states))

(defun pichat-chat-activity-ui-refresh-live-views
    (live-blocks view-states generation)
  "Refresh compatible explicit states from committed LIVE-BLOCKS.
Tool evidence may grow only by appending IDs.  A source-anchored thought-only
state migrates to the durable tool anchor after the first tool appears."
  (maphash
   (lambda (_key block)
     (let* ((live-key (plist-get block :view-state-key))
            (source-key
             (pichat-chat-activity-ui-live-view-key
              generation (plist-get block :source-anchor)))
            (state (or (gethash live-key view-states)
                       (and (not (equal source-key live-key))
                            (gethash source-key view-states))))
            (tool-ids (plist-get block :tool-ids)))
       (when (and state
                  (pichat-chat-activity-ui--tool-ids-extend-p
                   (plist-get state :tool-ids) tool-ids))
         ;; Use a fresh value so transaction snapshots retain old evidence.
         (puthash live-key
                  (list :view (plist-get state :view)
                        :tool-ids (copy-sequence tool-ids))
                  view-states)
         (unless (equal source-key live-key)
           (remhash source-key view-states)))))
   live-blocks))

(defun pichat-chat-activity-ui-transfer-live-views
    (canonical-blocks view-states generation)
  "Transfer compatible GENERATION live views to CANONICAL-BLOCKS."
  (maphash
   (lambda (_key block)
     (let* ((live-key
             (pichat-chat-activity-ui-live-view-key
              generation (plist-get block :anchor)))
            (state (gethash live-key view-states)))
       (when (and state
                  (equal (plist-get state :tool-ids)
                         (plist-get block :tool-ids)))
         (puthash (plist-get block :view-state-key) state view-states)
         (remhash live-key view-states))))
   canonical-blocks))

(defun pichat-chat-activity-ui-prune-views
    (canonical-blocks live-blocks view-states generation)
  "Prune stale activity VIEW-STATES for current GENERATION and block tables."
  (let ((keep (make-hash-table :test #'equal)))
    (dolist (table (list canonical-blocks live-blocks))
      (when (hash-table-p table)
        (maphash (lambda (_key block)
                   (puthash (plist-get block :view-state-key) t keep))
                 table)))
    (maphash
     (lambda (key _state)
       (let ((activity-key-p
              (and (listp key)
                   (or (and (eq (car key) 'canonical)
                            (eq (cadr key) 'activity))
                       (and (eq (car key) 'live)
                            (eq (nth 2 key) 'activity)
                            (= (or (cadr key) -1) generation))))))
         (when (and activity-key-p (not (gethash key keep)))
           (remhash key view-states))))
     view-states)))

(provide 'pichat-chat-activity-ui)
;;; pichat-chat-activity-ui.el ends here
