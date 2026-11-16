;;; pichat-transcript-view.el --- Settled transcript regions -*- lexical-binding: t; -*-

;;; Commentary:

;; Render a settled canonical transcript in a caller-owned read-only buffer.
;; Callers retain their major mode, headers, footer and display lifecycle.
;; This component owns one region and its presentation state per buffer, not a
;; runtime, prompt, live draft, or source synchronization machinery.

;;; Code:

(require 'cl-lib)
(require 'pichat-display)
(require 'pichat-pi)
(require 'pichat-render)
(require 'pichat-chat-tool-ui)
(require 'pichat-chat-activity-ui)

(defconst pichat-transcript-view--generation 0
  "Fixed generation for presentation without live source state.")

(defvar-local pichat-transcript-view--transcript nil
  "Full canonical transcript supplied by the caller; treated as immutable.")
(defvar-local pichat-transcript-view--visible-transcript nil
  "Node-bounded transcript used for the current projection.")
(defvar-local pichat-transcript-view--rejection nil
  "Bounded construction or validation error displayed instead of a transcript.")
(defvar-local pichat-transcript-view--selection nil
  "Selected logical target: node key and optional tool key.")
(defvar-local pichat-transcript-view--max-nodes nil
  "Optional tail bound, in canonical nodes, not source entries.")
(defvar-local pichat-transcript-view--start nil
  "Start marker of the component-owned region.")
(defvar-local pichat-transcript-view--end nil
  "End marker of the component-owned region.")
(defvar-local pichat-transcript-view--tool-view-states nil
  "Equal-keyed explicit tool choices belonging only to this buffer.")
(defvar-local pichat-transcript-view--activity-view-states nil
  "Equal-keyed explicit activity choices belonging only to this buffer.")
(defvar-local pichat-transcript-view--skill-view-states nil
  "Equal-keyed explicit skill choices belonging only to this buffer.")
(defvar-local pichat-transcript-view--history-view-states nil
  "Equal-keyed explicit history-summary choices belonging to this buffer.")
(defvar-local pichat-transcript-view--tool-blocks nil
  "Marker-backed visible tool blocks belonging only to this buffer.")
(defvar-local pichat-transcript-view--activity-blocks nil
  "Marker-backed visible activity headers belonging only to this buffer.")
(defvar-local pichat-transcript-view--tool-enrichments nil
  "Empty enrichment table; previews create no tool location links.")

(defun pichat-transcript-view--release-blocks ()
  "Release the previous projection's markers and overlays."
  (pichat-chat-tool-ui-release-blocks pichat-transcript-view--tool-blocks)
  (pichat-chat-activity-ui-release-blocks
   pichat-transcript-view--activity-blocks)
  (setq pichat-transcript-view--tool-blocks nil
        pichat-transcript-view--activity-blocks nil))

(defun pichat-transcript-view-clear ()
  "Release this buffer's transcript presentation state without editing text.
Call before discarding the caller-owned region.  Also runs on buffer death
and major-mode changes; it has no runtime lifecycle side effects."
  (pichat-transcript-view--release-blocks)
  (dolist (marker (list pichat-transcript-view--start
                        pichat-transcript-view--end))
    (when (markerp marker) (set-marker marker nil)))
  (setq pichat-transcript-view--start nil
        pichat-transcript-view--end nil
        pichat-transcript-view--transcript nil
        pichat-transcript-view--visible-transcript nil
        pichat-transcript-view--max-nodes nil
        pichat-transcript-view--rejection nil
        pichat-transcript-view--selection nil
        pichat-transcript-view--tool-view-states nil
        pichat-transcript-view--activity-view-states nil
        pichat-transcript-view--skill-view-states nil
        pichat-transcript-view--history-view-states nil
        pichat-transcript-view--tool-enrichments nil))

(defun pichat-transcript-view--alist (table)
  "Return an alist of choices from equal-keyed TABLE."
  (let (choices)
    (maphash (lambda (key value) (push (cons key value) choices)) table)
    choices))

(defun pichat-transcript-view--context (transcript)
  "Return settled rendering policy for TRANSCRIPT using local choices."
  (let ((activity
         (pichat-chat-activity-ui-presentation-state
          transcript '(thinking tool) pichat-chat-show-thinking nil
          pichat-transcript-view--generation
          pichat-transcript-view--activity-view-states nil
          pichat-chat-activity-group-display)))
    (pichat-render-context-create
     :show-thinking pichat-chat-show-thinking
     :tool-view pichat-chat-tool-default-display
     :tool-views
     (pichat-chat-tool-ui-views-for-transcript
      transcript nil pichat-transcript-view--generation
      pichat-transcript-view--tool-view-states nil
      pichat-chat-tool-default-display)
     :tool-renderer
     (apply-partially #'pichat-chat-tool-ui-render-tool-text
                      pichat-transcript-view--tool-enrichments
                      pichat-transcript-view--generation
                      pichat-chat-tool-truncation-notice-format)
     :max-tool-args pichat-chat-max-tool-args-chars
     :max-tool-output pichat-chat-max-tool-output-chars
     :activity-member-kinds '(thinking tool)
     :activity-display pichat-chat-activity-group-display
     :activity-views (plist-get activity :views)
     :activity-live-p nil
     :activity-latest-key nil
     :activity-header-renderer
     (apply-partially #'pichat-chat-activity-ui-format-header
                      pichat-transcript-view--tool-enrichments
                      pichat-transcript-view--generation)
     :skill-views (pichat-transcript-view--alist
                   pichat-transcript-view--skill-view-states)
     :history-views (pichat-transcript-view--alist
                     pichat-transcript-view--history-view-states))))

(defun pichat-transcript-view--resolve-entry (transcript entry-id)
  "Resolve ENTRY-ID in TRANSCRIPT to a node key and optional tool key."
  (when entry-id
    (catch 'target
      (dolist (node (pichat-transcript-nodes transcript))
        (let ((key (pichat-transcript-node-key node)))
          (when (equal key entry-id)
            (throw 'target (list :node key)))
          (dolist (content (pichat-transcript-node-content node))
            (when (and (eq (pichat-transcript-content-kind content) 'tool)
                       (equal entry-id
                              (pichat-transcript-content-result-entry-id content)))
              (throw 'target
                     (list :node key :tool
                           (cons key (pichat-transcript-content-tool-call-id
                                      content)))))))))))

(defun pichat-transcript-view--expand-selection (transcript)
  "Pre-expand groups containing the selected target in TRANSCRIPT."
  (when pichat-transcript-view--selection
    (dolist (item (pichat-activity-build-presentation
                   transcript '(thinking tool) pichat-chat-show-thinking))
      (when-let* ((group (pichat-activity-item-group item)))
        (when (cl-some
               (lambda (member)
                 (if-let* ((tool (plist-get pichat-transcript-view--selection :tool)))
                     (equal tool (cons (pichat-activity-member-node-key member)
                                       (pichat-activity-member-tool-call-id member)))
                   (equal (plist-get pichat-transcript-view--selection :node)
                          (pichat-activity-member-node-key member))))
               (pichat-activity-group-members group))
          (puthash (pichat-chat-activity-ui-canonical-view-key
                    (pichat-activity-group-key group))
                   (list :view 'expanded
                         :tool-ids (pichat-activity-group-tool-ids group))
                   pichat-transcript-view--activity-view-states))))))

(defun pichat-transcript-view-selected-position ()
  "Return the selected entry's visible position, or nil if absent or bounded out.
Tool-result entries resolve to their merged tool block.  Compare logical keys
with `equal', not object identity; never search caller-owned header text."
  (when pichat-transcript-view--selection
    (let* ((tool (plist-get pichat-transcript-view--selection :tool))
           (property (if tool 'pichat-tool-key 'pichat-node-key))
           (key (or tool (plist-get pichat-transcript-view--selection :node))))
      (let ((position (marker-position pichat-transcript-view--start))
            (end (marker-position pichat-transcript-view--end)))
        (catch 'found
          (while (< position end)
            (when (equal key (get-text-property position property))
              (throw 'found position))
            (setq position (next-single-property-change
                            position property nil end))))))))

(defun pichat-transcript-view--rejection-text (condition)
  "Return a bounded, plain single-line reason for CONDITION."
  (let ((print-length 8) (print-level 4))
    (concat "Transcript unavailable: "
            (truncate-string-to-width
             (replace-regexp-in-string "[\n\r\t]+" " "
                                       (error-message-string condition))
             300 nil nil "…")
            "\n")))

(defun pichat-transcript-view-render-entries
    (entries start end &optional max-nodes selected-entry-id)
  "Render root-to-leaf ENTRIES into START..END.
Include historical records.  The caller selects the branch; this function
performs no fetch or branch traversal.  MAX-NODES and SELECTED-ENTRY-ID have
the same meaning as in `pichat-transcript-view-render'.  Invalid session data
shows a bounded note, not a fallback renderer or runtime diagnostic."
  (condition-case condition
      (pichat-transcript-view-render
       (pichat-pi-build-canonical-transcript-from-entries entries t)
       start end max-nodes selected-entry-id)
    ((pichat-pi-invalid-session pichat-transcript-invalid)
     (pichat-transcript-view-render (pichat-transcript-create) start end max-nodes)
     (setq pichat-transcript-view--rejection
           (pichat-transcript-view--rejection-text condition))
     (pichat-transcript-view-repaint))))

(defun pichat-transcript-view-repaint ()
  "Replace only the owned transcript region, retaining local choices.
Read shared display options afresh.  Return the number of omitted nodes.
No data is fetched and transcript diagnostics are not published.
An empty region stays anchored at its end marker: caller text inserted at
that boundary remains after the transcript, including on a later repaint."
  (unless (and (markerp pichat-transcript-view--start)
               (eq (marker-buffer pichat-transcript-view--start) (current-buffer))
               (markerp pichat-transcript-view--end)
               (eq (marker-buffer pichat-transcript-view--end) (current-buffer)))
    (error "No transcript view region"))
  (let* ((nodes (pichat-transcript-nodes pichat-transcript-view--transcript))
         (omitted (if pichat-transcript-view--max-nodes
                      (max 0 (- (length nodes) pichat-transcript-view--max-nodes))
                    0))
         (visible (copy-pichat-transcript pichat-transcript-view--transcript))
         ;; Do not inherit an ambient chat's path mappings, even dynamically.
         (pichat-tool-enrichment-path-context nil)
         (end (marker-position pichat-transcript-view--end))
         ;; Empty-region boundary insertions can move start past end.  They
         ;; are caller-owned, not a reversed region to delete: render at end.
         (start (min (marker-position pichat-transcript-view--start) end)))
    (setf (pichat-transcript-nodes visible) (nthcdr omitted nodes))
    (let* ((context (pichat-transcript-view--context visible))
           (text (or pichat-transcript-view--rejection
                     (pichat-render-fragment-propertized-string
                      (pichat-render-canonical visible context))))
           (inhibit-read-only t))
      (save-excursion
        (atomic-change-group
          (delete-region start end)
          (goto-char start)
          (insert text))
        (pichat-transcript-view--release-blocks)
        ;; Explicitly reset endpoints after insertion, including empty regions.
        ;; Outside insertions at either boundary remain caller-owned.
        (set-marker pichat-transcript-view--start start)
        (set-marker pichat-transcript-view--end (+ start (length text)))
        (setq pichat-transcript-view--visible-transcript visible
              pichat-transcript-view--tool-blocks
              (pichat-chat-tool-ui-index-tools
               visible start (+ start (length text)) context nil
               pichat-transcript-view--generation
               pichat-transcript-view--tool-enrichments)
              pichat-transcript-view--activity-blocks
              (pichat-chat-activity-ui-index-groups
               start (+ start (length text)) nil
               pichat-transcript-view--generation))))
    omitted))

(defun pichat-transcript-view-render
    (transcript start end &optional max-nodes selected-entry-id)
  "Render canonical TRANSCRIPT into START..END of the current buffer.
Replace only that region and retain the caller's major mode and surrounding
text.  The buffer becomes read-only.  Own one region per buffer; each call
resets all local choices and releases earlier block markers and overlays.
Optional nonnegative MAX-NODES bounds the tail before context construction,
rendering and indexing.  Tool results remain merged with their calls.  Return
the number of omitted nodes, not entries; caller headers remain caller-owned.
SELECTED-ENTRY-ID pre-expands containing activity groups on initial render;
use `pichat-transcript-view-selected-position' to locate it, without moving
point.
Absent or bounded-out selections have no position.  Repaint retains choices,
including later explicit collapses.  Invalid transcripts show a bounded note.
TRANSCRIPT and its diagnostics are read-only inputs, never runtime updates."
  (let ((rejection
         (condition-case condition
             (progn (pichat-transcript-validate transcript) nil)
           (pichat-transcript-invalid
            (pichat-transcript-view--rejection-text condition)))))
    (when rejection (setq transcript (pichat-transcript-create)))
    (unless (or (null max-nodes) (and (integerp max-nodes) (>= max-nodes 0)))
      (error "Invalid transcript node bound: %S" max-nodes))
    (dolist (position (list start end))
      (unless (and (integer-or-marker-p position)
                   (or (integerp position)
                       (eq (marker-buffer position) (current-buffer)))
                   (<= (point-min) position (point-max)))
        (error "Invalid transcript region position: %S" position)))
    (unless (<= start end) (error "Reversed transcript region"))
    ;; Positions may be our own markers, which clear will detach.
    (setq start (+ start 0) end (+ end 0))
    (pichat-transcript-view-clear)
    (setq pichat-transcript-view--transcript transcript
          pichat-transcript-view--rejection rejection
          pichat-transcript-view--selection
          (pichat-transcript-view--resolve-entry transcript selected-entry-id)
          pichat-transcript-view--max-nodes max-nodes
          pichat-transcript-view--start (copy-marker start t)
          pichat-transcript-view--end (copy-marker end nil))
    (dolist (variable '(pichat-transcript-view--tool-view-states
                        pichat-transcript-view--activity-view-states
                        pichat-transcript-view--skill-view-states
                        pichat-transcript-view--history-view-states
                        pichat-transcript-view--tool-enrichments))
      (set variable (make-hash-table :test #'equal)))
    (let ((visible (copy-pichat-transcript transcript)))
      (when max-nodes
        (setf (pichat-transcript-nodes visible)
              (last (pichat-transcript-nodes transcript) max-nodes)))
      (pichat-transcript-view--expand-selection visible))
    (add-hook 'kill-buffer-hook #'pichat-transcript-view-clear nil t)
    (add-hook 'change-major-mode-hook #'pichat-transcript-view-clear nil t)
    (prog1 (pichat-transcript-view-repaint)
      (setq buffer-read-only t))))

(provide 'pichat-transcript-view)
;;; pichat-transcript-view.el ends here
