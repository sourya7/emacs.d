;;; pichat-transcript-view.el --- Settled transcript regions -*- lexical-binding: t; -*-

;;; Commentary:

;; Render a settled canonical transcript in a caller-owned read-only buffer.
;; Callers retain their major mode, headers, footer and display lifecycle.
;; This component owns one region and its presentation state per buffer, not a
;; runtime, prompt, live draft, or source synchronization machinery.

;;; Code:

(require 'cl-lib)
(require 'pichat-display)
(require 'pichat-render)
(require 'pichat-chat-tool-ui)
(require 'pichat-chat-activity-ui)

(defconst pichat-transcript-view--generation 0
  "Fixed generation for presentation without live source state.")

(defvar-local pichat-transcript-view--transcript nil
  "Full canonical transcript supplied by the caller; treated as immutable.")
(defvar-local pichat-transcript-view--visible-transcript nil
  "Node-bounded transcript used for the current projection.")
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
           (text (pichat-render-fragment-propertized-string
                  (pichat-render-canonical visible context)))
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

(defun pichat-transcript-view-render (transcript start end &optional max-nodes)
  "Render canonical TRANSCRIPT into START..END of the current buffer.
Replace only that region and retain the caller's major mode and surrounding
text.  The buffer becomes read-only.  Own one region per buffer; each call
resets all local choices and releases earlier block markers and overlays.
Optional nonnegative MAX-NODES bounds the tail before context construction,
rendering and indexing.  Tool results remain merged with their calls.  Return
the number of omitted nodes, not entries; caller headers remain caller-owned.
TRANSCRIPT and its diagnostics are read-only inputs, never runtime updates."
  (pichat-transcript-validate transcript)
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
        pichat-transcript-view--max-nodes max-nodes
        pichat-transcript-view--start (copy-marker start t)
        pichat-transcript-view--end (copy-marker end nil))
  (dolist (variable '(pichat-transcript-view--tool-view-states
                      pichat-transcript-view--activity-view-states
                      pichat-transcript-view--skill-view-states
                      pichat-transcript-view--history-view-states
                      pichat-transcript-view--tool-enrichments))
    (set variable (make-hash-table :test #'equal)))
  (add-hook 'kill-buffer-hook #'pichat-transcript-view-clear nil t)
  (add-hook 'change-major-mode-hook #'pichat-transcript-view-clear nil t)
  (prog1 (pichat-transcript-view-repaint)
    (setq buffer-read-only t)))

(provide 'pichat-transcript-view)
;;; pichat-transcript-view.el ends here
