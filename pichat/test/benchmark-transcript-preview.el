;;; benchmark-transcript-preview.el --- Settled transcript pipeline profile -*- lexical-binding: t; -*-

;;; Commentary:

;; Run explicitly, never as part of ERT:
;;   emacs -Q --batch -L pichat -L /path/to/markdown-mode \
;;     -l pichat/test/benchmark-transcript-preview.el
;; Set PICHAT_BENCHMARK_SESSION to opt into reading one local JSONL file.
;; Its last entry selects the branch; other branches are not replicated.
;; Set PICHAT_BENCHMARK_5X=1 to also profile five concatenated branch copies.
;; No file names or transcript content are printed.  No files are written,
;; no runtime is acquired, and no Pi process or network request is made.
;; Markdown-mode is required: silently omitting fontification skews results.
;; Each stage is one wall-clock sample after GC, with ordinary GC enabled.
;; Run several fresh processes for comparisons on the same Emacs/machine.
;; These are pipeline timings, NOT redisplay/first-paint or interactive toggle
;; measurements, and have no pass/fail timing thresholds.  Additional component
;; timings exercise render-entries, fold commands and a 24-node cached tail;
;; these include complete operations but still exclude caller UI and redisplay.
;; Expanded means
;; activity groups expanded, with the ordinary completed-tool summary default.
;; Buffer sizes are UTF-8 text bytes.  Legacy preview baseline measurements
;; are retained in the plan record; that renderer has been removed.

;;; Code:

(require 'benchmark)
(require 'json)
(require 'pichat-chat)
(require 'pichat-transcript-view)
(require 'markdown-mode)

(defun pichat-benchmark-preview--synthetic ()
  "Return a deterministic linear branch with prose, thinking and settled tools."
  (let (entries parent (serial 0))
    (cl-labels
        ((emit (message)
           (let ((id (format "entry-%d" (cl-incf serial))))
             (push (list :type "message" :id id :parentId parent
                         :message message) entries)
             (setq parent id))))
      (dotimes (turn 160)
        (emit (list :role "user" :content
                    (list (list :type "text" :text
                                (format "Inspect example %d." turn)))))
        (dotimes (tool 8)
          (let ((id (format "tool-%d-%d" turn tool)))
            (emit (list :role "assistant" :stopReason "toolUse" :content
                        (list (list :type "thinking" :thinking
                                    "Check the source before changing it.")
                              (list :type "toolCall" :id id :name "read"
                                    :arguments (list :path "example.el")))))
            (emit (list :role "toolResult" :toolCallId id :toolName "read"
                        :isError :false :content
                        (list (list :type "text" :text
                                    (concat ";;; Example source\n"
                                            (make-string 4096 ?x))))))))
        (emit (list :role "assistant" :stopReason "stop" :content
                    (list (list :type "text" :text
                                (concat "## Result\n\nChecked **example** `code`.\n"
                                        "```elisp\n(message \"ok\")\n```\n"
                                        "[Reference](https://example.org)\n")))))))
    (nreverse entries)))

(defun pichat-benchmark-preview--read (file)
  "Read entries from explicitly supplied local JSONL FILE, without visiting it."
  (when (file-remote-p file) (error "Benchmark requires a local session file"))
  (with-temp-buffer
    (insert-file-contents file)
    (let (entries)
      (while (not (eobp))
        (unless (looking-at-p "[ \t]*$")
          (let ((entry (json-parse-string
                        (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position))
                        :object-type 'plist :array-type 'list
                        :null-object nil :false-object :false)))
            (unless (equal (plist-get entry :type) "session")
              (push entry entries))))
        (forward-line 1))
      (nreverse entries))))

(defun pichat-benchmark-preview--cache (entries)
  "Build a cache for ENTRIES, selecting the last entry as leaf."
  (pichat-pi-entry-cache-full
   "benchmark" nil entries (plist-get (car (last entries)) :id)))

(defun pichat-benchmark-preview--repeat (branch count)
  "Concatenate COUNT independent copies of BRANCH with unique entry/tool IDs."
  (let (result parent)
    (dotimes (copy count)
      (let ((ids (make-hash-table :test #'equal)))
        (dolist (entry branch)
          (puthash (plist-get entry :id)
                   (format "copy-%d-%s" copy (plist-get entry :id)) ids))
        (dolist (entry branch)
          (let* ((new (copy-tree entry t))
                 (message (plist-get new :message)))
            (setq new (plist-put new :id (gethash (plist-get entry :id) ids)))
            (setq new (plist-put new :parentId parent))
            (when-let* ((id (plist-get message :toolCallId)))
              (plist-put message :toolCallId (format "copy-%d-%s" copy id)))
            (dolist (part (let ((content (plist-get message :content)))
                            (and (listp content) content)))
              (when (and (listp part)
                         (equal (plist-get part :type) "toolCall"))
                (plist-put part :id
                           (format "copy-%d-%s" copy (plist-get part :id)))))
            (setq parent (plist-get new :id))
            (push new result)))))
    (nreverse result)))

(defun pichat-benchmark-preview--measure (function)
  "Return (VALUE SECONDS GC-COUNT GC-SECONDS) for one call of FUNCTION."
  (garbage-collect)
  (let (value)
    (let ((timing (benchmark-call (lambda () (setq value (funcall function))))))
      (cons value timing))))

(defun pichat-benchmark-preview--profile (entries expanded)
  "Measure ENTRIES with activity groups EXPANDED or collapsed."
  (with-temp-buffer
    ;; Use the real chat context constructor without starting chat mode, whose
    ;; hooks/markers/runtime lifecycle are not part of this pipeline profile.
    (let ((pichat-chat-activity-group-display (if expanded 'expanded 'collapsed))
          (pichat-chat--tool-enrichments (make-hash-table :test #'equal))
          (pichat-chat--tool-view-states (make-hash-table :test #'equal))
          (pichat-chat--activity-view-states (make-hash-table :test #'equal))
          (pichat-chat--skill-view-states (make-hash-table :test #'equal))
          cache transcript context fragment blocks rows)
      (cl-labels ((stage (label function)
                    (let ((sample (pichat-benchmark-preview--measure function)))
                      (push (cons label (cdr sample)) rows)
                      (car sample))))
        (setq cache (stage "Entry cache" (lambda ()
                                          (pichat-benchmark-preview--cache entries)))
              transcript (stage "Build canonical transcript"
                                (lambda () (pichat-pi-build-canonical-transcript cache)))
              context (stage "Render context (views)"
                             (lambda () (pichat-chat--canonical-render-context transcript)))
              fragment (stage "pichat-render-canonical"
                              (lambda () (pichat-render-canonical transcript context))))
        (stage "Insert rendered text"
               (lambda () (insert (pichat-render-fragment-propertized-string fragment))))
        (stage "Markdown fontify, all prose"
               (lambda () (pichat-markdown-fontification-apply-region
                           (point-min) (point-max))))
        (unwind-protect
            (setq blocks (stage "Index tool blocks"
                                (lambda () (pichat-chat-tool-ui-index-tools
                                            transcript (point-min) (point-max)
                                            context nil 0 pichat-chat--tool-enrichments))))
          (when blocks (pichat-chat-tool-ui-release-blocks blocks)))
        (let ((bytes (string-bytes (buffer-substring-no-properties
                                   (point-min) (point-max)))))
          (list :rows (nreverse rows) :bytes bytes
                :nodes (length (pichat-transcript-nodes transcript))
                :tools (cl-loop for node in (pichat-transcript-nodes transcript)
                                sum (cl-count 'tool
                                              (pichat-transcript-node-content node)
                                              :key #'pichat-transcript-content-kind))
                :prose (cl-loop for node in (pichat-transcript-nodes transcript)
                                when (eq (pichat-transcript-node-role node) 'assistant)
                                sum (cl-count 'prose
                                              (pichat-transcript-node-content node)
                                              :key #'pichat-transcript-content-kind))))))))

(defun pichat-benchmark-preview--component (entries)
  "Measure actual component entry points for cached linear ENTRIES.
These include validation, region replacement, fontification and all indexes,
not source acquisition or redisplay.  Manager callers are not yet migrated."
  (with-temp-buffer
    (setq-local pichat-chat-show-thinking t)
    (let ((pichat-chat-activity-group-display 'collapsed)
          (pichat-chat-render-markdown t)
          rows)
      (cl-labels
          ((stage (label function)
             (let ((sample (pichat-benchmark-preview--measure function)))
               (push (cons label (cdr sample)) rows))))
        (stage "Entries to full region (<=.5s)"
               (lambda () (pichat-transcript-view-render-entries entries 1 1)))
        (let ((group (car (sort (hash-table-values
                                pichat-transcript-view--activity-blocks)
                               (lambda (a b) (< (plist-get a :start)
                                                (plist-get b :start)))))))
          (unless group (error "Benchmark branch has no activity group"))
          (goto-char (plist-get group :start))
          (stage "Activity toggle (<=.5s)" #'pichat-transcript-view-toggle))
        (goto-char pichat-transcript-view--start)
        (stage "Thinking toggle (<=.5s)" #'pichat-transcript-view-toggle-thinking)
        (let ((tool (car (sort (hash-table-values
                               pichat-transcript-view--tool-blocks)
                              (lambda (a b) (< (plist-get a :start)
                                               (plist-get b :start)))))))
          (unless tool (error "Benchmark group has no visible tool"))
          (goto-char (plist-get tool :start))
          (stage "Tool toggle (size independent)"
                 #'pichat-transcript-view-toggle-tool))
        ;; Restore defaults after the thinking toggle.  Each fresh render
        ;; below also resets the explicit activity/tool choices.
        (setq-local pichat-chat-show-thinking t)
        (let ((transcript pichat-transcript-view--transcript))
          (stage "Cached canonical tail (diagnostic)"
                 (lambda ()
                   (pichat-transcript-view-render
                    transcript pichat-transcript-view--start
                    pichat-transcript-view--end 24)))
          (stage "Cached entries tail (<=.06s)"
                 (lambda ()
                   (pichat-transcript-view-render-entries
                    entries pichat-transcript-view--start
                    pichat-transcript-view--end 24))))
        (nreverse rows)))))

(defun pichat-benchmark-preview--run ()
  "Print the base and optional 5x collapsed/expanded pipeline table."
  (let* ((file (getenv "PICHAT_BENCHMARK_SESSION"))
         (entries (if file (pichat-benchmark-preview--read file)
                    (pichat-benchmark-preview--synthetic)))
         (branch (pichat-pi-entry-cache-active-branch
                  (pichat-benchmark-preview--cache entries)))
         (scales (if (equal (getenv "PICHAT_BENCHMARK_5X") "1") '(1 5) '(1)))
         samples labels)
    (unless branch (error "No entries in benchmark branch"))
    (princ (format "Emacs %s; %s; branch entries=%d; GC threshold=%d, percentage=%s\n"
                   emacs-version (if file "explicit local session" "synthetic")
                   (length branch) gc-cons-threshold gc-cons-percentage))
    (princ "One sample/stage; pre-stage GC excluded; in-stage GC included. Seconds.\n")
    (dolist (scale scales)
      (let ((input (if (= scale 1) branch
                     (pichat-benchmark-preview--repeat branch scale))))
        (dolist (expanded '(nil t))
          (push (format "%dx %s" scale (if expanded "expanded" "collapsed")) labels)
          (push (pichat-benchmark-preview--profile input expanded) samples))))
    (setq samples (nreverse samples) labels (nreverse labels))
    (princ (format "%-29s" "Stage"))
    (dolist (label labels) (princ (format " %13s" label)))
    (princ "\n")
    (dolist (row (plist-get (car samples) :rows))
      (princ (format "%-29s" (car row)))
      (dolist (sample samples)
        (princ (format " %13.6f" (cadr (assoc (car row) (plist-get sample :rows))))))
      (princ "\n"))
    (dolist (field '((:nodes . "Canonical nodes") (:tools . "Tool calls")
                     (:prose . "Assistant prose runs") (:bytes . "Rendered text bytes")))
      (princ (format "%-29s" (cdr field)))
      (dolist (sample samples) (princ (format " %13d" (plist-get sample (car field)))))
      (princ "\n"))
    (princ "GC counts / GC seconds (all timed stages):\n")
    (cl-mapc (lambda (label sample)
               (princ (format "%s: %d / %.6f\n" label
                              (cl-loop for row in (plist-get sample :rows)
                                       sum (nth 2 row))
                              (cl-loop for row in (plist-get sample :rows)
                                       sum (nth 3 row)))))
             labels samples)
    (princ "\nComponent operations: seconds / GC count / GC seconds.\n")
    (princ "Cached input only; no RPC, caller headers or actual redisplay.\n")
    (princ "Tail=24 canonical nodes; entries tail includes full history build.\n")
    (dolist (scale scales)
      (princ (format "%dx component:\n" scale))
      (dolist (row (pichat-benchmark-preview--component
                    (if (= scale 1) branch
                      (pichat-benchmark-preview--repeat branch scale))))
        (princ (format "%-34s %.6f / %d / %.6f\n"
                       (car row) (nth 1 row) (nth 2 row) (nth 3 row)))))))

(pichat-benchmark-preview--run)

;;; benchmark-transcript-preview.el ends here
