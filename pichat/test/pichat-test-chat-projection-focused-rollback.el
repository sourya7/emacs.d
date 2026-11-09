;;; pichat-test-chat-projection-focused-rollback.el --- Focused live rollback tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Failure-injection and structural coverage for the live-region transaction.

;;; Code:

(require 'pichat-test-chat-projection-incremental)
(require 'pichat-test-chat-support)

(defun pichat-test-focused-rollback--hash-entries (table)
  "Return stable printed entries from hash TABLE."
  (let (entries)
    (when (hash-table-p table)
      (maphash (lambda (key value)
                 (push (cons (prin1-to-string key)
                             (prin1-to-string value))
                       entries))
               table))
    (sort entries (lambda (first second)
                    (string< (car first) (car second))))))

(defun pichat-test-focused-rollback--fragment-state ()
  "Return observable committed live-fragment identity and positions."
  (mapcar
   (lambda (fragment)
     (list (plist-get fragment :key) fragment
           (plist-get fragment :start)
           (marker-position (plist-get fragment :start))
           (plist-get fragment :end)
           (marker-position (plist-get fragment :end))))
   pichat-chat--live-projection-fragments))

(defun pichat-test-focused-rollback--block-state ()
  "Return observable live tool-block identity, boundaries, and decoration."
  (let (entries)
    (maphash
     (lambda (id block)
       (let ((overlay (plist-get block :overlay)))
         (push (list id block
                     (plist-get block :start)
                     (marker-position (plist-get block :start))
                     (plist-get block :end)
                     (marker-position (plist-get block :end))
                     overlay
                     (and (overlayp overlay) (overlay-start overlay))
                     (and (overlayp overlay) (overlay-end overlay))
                     (and (overlayp overlay)
                          (overlay-get overlay 'after-string)))
               entries)))
     pichat-chat--live-tool-blocks)
    (sort entries (lambda (first second) (string< (car first) (car second))))))

(defun pichat-test-focused-rollback--activity-block-state ()
  "Return observable live activity block identity and boundaries."
  (let (entries)
    (maphash
     (lambda (key block)
       (push (list key block
                   (plist-get block :start)
                   (marker-position (plist-get block :start))
                   (plist-get block :end)
                   (marker-position (plist-get block :end))
                   (plist-get block :display-state)
                   (plist-get block :view-state-key))
             entries))
     pichat-chat--live-activity-blocks)
    (sort entries
          (lambda (first second)
            (< (nth 3 first) (nth 3 second))))))

(defun pichat-test-focused-rollback--tool-overlay-state ()
  "Return identity and geometry of all derived tool-location overlays."
  (let (entries)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'pichat-tool-location-overlay)
        (push (list overlay (overlay-start overlay) (overlay-end overlay)
                    (overlay-get overlay 'after-string))
              entries)))
    (sort entries (lambda (first second)
                    (< (or (cadr first) 0) (or (cadr second) 0))))))

(defun pichat-test-focused-rollback--state ()
  "Capture exact observable projection state around an injected failure."
  (list
   :text (buffer-substring (point-min) (point-max))
   :point (point)
   :windows
   (mapcar (lambda (window)
             (list window (window-point window) (window-start window)))
           (get-buffer-window-list (current-buffer) nil t))
   :modified (buffer-modified-p)
   :undo (copy-tree buffer-undo-list)
   :markers
   (mapcar (lambda (marker) (list marker (marker-position marker)))
           (list pichat-chat--live-start pichat-chat--live-end
                 pichat-chat--status-start pichat-chat--status-end
                 pichat-chat--widget-start pichat-chat--widget-end
                 pichat-chat--prompt-start pichat-chat--input-start))
   :fragments (pichat-test-focused-rollback--fragment-state)
   :blocks (pichat-test-focused-rollback--block-state)
   :live-block-table pichat-chat--live-tool-blocks
   :combined-block-table pichat-chat--tool-blocks
   :activity-blocks (pichat-test-focused-rollback--activity-block-state)
   :live-activity-block-table pichat-chat--live-activity-blocks
   :combined-activity-block-table pichat-chat--activity-blocks
   :fingerprint pichat-chat--live-projection-fingerprint
   :views (pichat-test-focused-rollback--hash-entries
           pichat-chat--tool-view-states)
   :activity-views (pichat-test-focused-rollback--hash-entries
                    pichat-chat--activity-view-states)
   :enrichments (pichat-test-focused-rollback--hash-entries
                 pichat-chat--tool-enrichments)
   :statuses (copy-tree pichat-chat--status-lines)
   :tool-overlays (pichat-test-focused-rollback--tool-overlay-state)))

(defun pichat-test-focused-rollback--start (draft text path)
  "Populate DRAFT with live TEXT and a located read tool for PATH."
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event
    "message_update"
    (list (list :type "text" :text text)
          (pichat-test-incremental--tool-call
           "rollback-tool" "read" (list :path path)))))
  (let ((record (pichat-tool-enrichment-build
                 "rollback-tool" "read" (list :path path))))
    (setq record (plist-put record :source-generation
                            pichat-chat--source-generation)
          record (plist-put record :host-path "/tmp/rollback-tool"))
    (puthash "rollback-tool" record pichat-chat--tool-enrichments)))

(defun pichat-test-focused-rollback--candidate (draft type text path)
  "Apply candidate TYPE with TEXT and read-tool PATH to DRAFT."
  (pichat-pi-live-draft-apply
   draft
   (pichat-test-incremental--assistant-event
    type
    (list (list :type "text" :text text)
          (pichat-test-incremental--tool-call
           "rollback-tool" "read" (list :path path)))))
  (let ((record (pichat-tool-enrichment-build
                 "rollback-tool" "read" (list :path path))))
    (setq record (plist-put record :source-generation
                            pichat-chat--source-generation)
          record (plist-put record :host-path "/tmp/rollback-tool"))
    (puthash "rollback-tool" record pichat-chat--tool-enrichments)))

(defmacro pichat-test-focused-rollback--with-buffer (&rest body)
  "Open a located live tool fixture and evaluate BODY in its chat buffer."
  (declare (indent 0) (debug t))
  `(pichat-test-with-unit-session (session proc)
     (let ((pichat-chat-activity-group-display 'latest)
           (pichat-chat-collapse-tools-by-default nil)
           (pichat-chat-tool-default-display 'output))
       (pichat-test-with-chat-buffer (buffer session)
         (pichat-test-focused-rollback--start
          pichat-chat--live-draft "committed prose" "old.el")
         (pichat-chat--project-live-tail)
         (should (overlayp
                  (plist-get
                   (gethash "rollback-tool" pichat-chat--live-tool-blocks)
                   :overlay)))
         ,@body))))

(defun pichat-test-focused-rollback--assert-failure-restores (failure-function)
  "Assert FAILURE-FUNCTION aborts projection and restores exact prior state."
  (set-buffer-modified-p nil)
  (let ((before (pichat-test-focused-rollback--state)))
    (should-error (funcall failure-function))
    (should (equal before (pichat-test-focused-rollback--state)))))

(ert-deftest pichat-chat-focused-rollback-restores-fragment-insertion-failure ()
  (pichat-test-focused-rollback--with-buffer
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "insert.el")
    (let ((original (symbol-function 'pichat-chat--protect-region)))
      (pichat-test-focused-rollback--assert-failure-restores
       (lambda ()
         (cl-letf (((symbol-function 'pichat-chat--protect-region)
                    (lambda (beg end)
                      (funcall original beg end)
                      (when (>= beg (marker-position pichat-chat--live-start))
                        (error "injected insertion failure")))))
           (pichat-chat--project-live-tail)))))))

(ert-deftest pichat-chat-focused-rollback-restores-indexing-failure ()
  (pichat-test-focused-rollback--with-buffer
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "index.el")
    (pichat-test-focused-rollback--assert-failure-restores
     (lambda ()
       (cl-letf (((symbol-function 'pichat-chat--index-canonical-tools)
                  (lambda (&rest _args) (error "injected indexing failure"))))
         (pichat-chat--project-live-tail))))))

(ert-deftest pichat-chat-focused-rollback-restores-decoration-failure ()
  (pichat-test-focused-rollback--with-buffer
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "decorate.el")
    (let ((original (symbol-function 'pichat-chat-tool-ui-decorate-block)))
      (pichat-test-focused-rollback--assert-failure-restores
       (lambda ()
         (cl-letf (((symbol-function 'pichat-chat-tool-ui-decorate-block)
                    (lambda (&rest args)
                      (apply original args)
                      (error "injected decoration failure"))))
           (pichat-chat--project-live-tail)))))))

(ert-deftest pichat-chat-focused-rollback-restores-fontification-failure ()
  (pichat-test-focused-rollback--with-buffer
    (setq pichat-chat-markdown-mode t)
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_end"
     "changed **Markdown**" "markdown.el")
    (let ((original
           (symbol-function 'pichat-chat--markdown-fontify-region)))
      (pichat-test-focused-rollback--assert-failure-restores
       (lambda ()
         (cl-letf (((symbol-function
                     'pichat-markdown-fontification-apply-region)
                    (lambda (beg end)
                      (put-text-property beg end 'font-lock-face
                                         'font-lock-keyword-face)
                      t))
                   ((symbol-function 'pichat-chat--markdown-fontify-region)
                    (lambda (beg end)
                      (funcall original beg end)
                      (error "injected Markdown fontification failure"))))
           (pichat-chat--project-live-tail)))))))

(ert-deftest pichat-chat-focused-rollback-restores-post-edit-pre-commit-failure ()
  (pichat-test-focused-rollback--with-buffer
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "commit.el")
    (pichat-test-focused-rollback--assert-failure-restores
     (lambda ()
       (cl-letf (((symbol-function
                   'pichat-chat--commit-live-projection-result)
                  (lambda (&rest _args)
                    (error "injected post-edit pre-commit failure"))))
         (pichat-chat--project-live-tail))))))

(ert-deftest pichat-chat-ordinary-live-update-uses-focused-rollback-only ()
  (pichat-test-focused-rollback--with-buffer
    (goto-char (point-max))
    (insert "unsent draft")
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "focused.el")
    (let ((full 0) (focused 0)
          (undo-before (copy-tree buffer-undo-list))
          (modified-before (buffer-modified-p))
          (full-original (symbol-function 'pichat-chat--projection-snapshot))
          (focused-original
           (symbol-function 'pichat-chat--focused-live-snapshot)))
      (cl-letf (((symbol-function 'pichat-chat--projection-snapshot)
                 (lambda () (cl-incf full) (funcall full-original)))
                ((symbol-function 'pichat-chat--focused-live-snapshot)
                 (lambda (&rest args)
                   (cl-incf focused)
                   (apply focused-original args))))
        (pichat-chat--project-live-tail))
      (should (= 1 focused))
      (should (zerop full))
      (should (equal "unsent draft" (pichat-chat--input-text)))
      (should (equal undo-before buffer-undo-list))
      (should (eq modified-before (buffer-modified-p))))))

(ert-deftest pichat-chat-compatibility-status-update-uses-full-rollback ()
  (pichat-test-focused-rollback--with-buffer
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "changed prose" "fallback.el")
    (let ((full 0)
          (original (symbol-function 'pichat-chat--projection-snapshot)))
      (cl-letf (((symbol-function
                   'pichat-chat--compatibility-diagnostics-text)
                 (lambda (_transcript) "[forced compatibility change]"))
                ((symbol-function 'pichat-chat--projection-snapshot)
                 (lambda () (cl-incf full) (funcall original))))
        (pichat-chat--project-live-tail))
      (should (= 1 full))
      (should (string-match-p "changed prose"
                              (pichat-test-buffer-text buffer))))))

(defun pichat-test-focused-rollback--source-tables ()
  "Return source-scoped presentation tables in the current chat."
  (list pichat-chat--tool-view-states pichat-chat--activity-view-states
        pichat-chat--skill-view-states pichat-chat--tool-auxiliary-details
        pichat-chat--tool-enrichments))

(ert-deftest pichat-chat-projection-failure-restores-source-presentation-ownership ()
  ;; All transaction paths must restore the same source-owned metadata.
  ;; Text/marker rollback remains path-specific.
  (dolist (path '(focused full canonical))
    (dolist (condition '(error quit))
      (pichat-test-focused-rollback--with-buffer
        (pichat-chat--set-input-text "unsent draft")
        (pichat-chat--style-live-input)
        (pichat-test-focused-rollback--candidate
         pichat-chat--live-draft "message_update" "candidate prose" "new.el")
        (dolist (table (pichat-test-focused-rollback--source-tables))
          (puthash "retained-key" '(:retained t) table))
        (set-buffer-modified-p nil)
        (let* ((tables (pichat-test-focused-rollback--source-tables))
               (contents (mapcar #'pichat-test-focused-rollback--hash-entries tables))
               (before (pichat-test-focused-rollback--state))
               (draft pichat-chat--live-draft)
               (cache pichat-chat--entry-cache)
               (transcript pichat-chat--canonical-transcript)
               (target (pichat-chat-draft-capture))
               (project
                (lambda ()
                  (if (eq path 'canonical)
                      (let* ((model (pichat-transcript-create :nodes nil))
                             (context (pichat-chat--canonical-render-context model)))
                        (pichat-chat--project-canonical
                         nil model (pichat-render-canonical model context) context))
                    (pichat-chat--project-live-tail)))))
          (let ((index (symbol-function 'pichat-chat--index-canonical-tools))
                (status (symbol-function 'pichat-chat--set-status-state))
                (fail (lambda ()
                        ;; Exercise replacement as well as in-place mutation.
                        (setq pichat-chat--skill-view-states
                              (make-hash-table :test #'equal))
                        (dolist (table (pichat-test-focused-rollback--source-tables))
                          (clrhash table)
                          (puthash "failed-key" '(:candidate t) table))
                        (signal condition '("injected presentation failure")))))
            (cl-letf (((symbol-function 'pichat-chat--index-canonical-tools)
                       (lambda (&rest args)
                         (prog1 (apply index args)
                           (unless (eq path 'canonical) (funcall fail)))))
                      ((symbol-function 'pichat-chat--set-status-state)
                       (lambda (key value)
                         (funcall status key value)
                         ;; Canonical projection has installed its candidate
                         ;; and expired auxiliary details before this boundary.
                         (when (and (eq path 'canonical) (eq key 'agent))
                           (funcall fail)))))
              (if (eq path 'full)
                  (cl-letf (((symbol-function 'pichat-chat--focused-live-rollback-safe-p)
                             (lambda (_) nil)))
                    (should (eq condition
                                (condition-case err (funcall project)
                                  ((error quit) (car err))))))
                (should (eq condition
                            (condition-case err (funcall project)
                              ((error quit) (car err))))))))
          (should (equal-including-properties
                   (plist-get before :text) (buffer-string)))
          (when (eq path 'focused)
            (should (equal before (pichat-test-focused-rollback--state))))
          (should (cl-every #'eq tables (pichat-test-focused-rollback--source-tables)))
          (should (equal contents
                         (mapcar #'pichat-test-focused-rollback--hash-entries
                                 (pichat-test-focused-rollback--source-tables))))
          (should (eq draft pichat-chat--live-draft))
          (should (eq cache pichat-chat--entry-cache))
          (should (eq transcript pichat-chat--canonical-transcript))
          (should (pichat-chat-draft-current-p target))
          (should (equal "unsent draft" (pichat-chat-draft-text target)))
          ;; A failed projection never consumes the candidate or poisons retry.
          (funcall project)
          (should (equal "unsent draft" (pichat-chat-draft-text target))))))))

(ert-deftest pichat-chat-source-reset-releases-presentation-without-losing-draft ()
  (pichat-test-focused-rollback--with-buffer
    (goto-char (point-max))
    (insert "unsent draft")
    (let* ((target (pichat-chat-draft-capture))
           (generation pichat-chat--source-generation)
           (process-generation (pichat-session-process-generation session))
           (tables (pichat-test-focused-rollback--source-tables))
           (block (gethash "rollback-tool" pichat-chat--live-tool-blocks))
           (start (plist-get block :start))
           (overlay (plist-get block :overlay))
           (pending (list 'pending-image))
           (recovery (list 'recoverable-draft))
           cancelled)
      (setq pichat-chat--pending-attachments pending
            pichat-chat--recoverable-submissions recovery
            pichat-chat--sync-request-id "old-sync"
            pichat-chat--stats-request-id "old-stats")
      (dolist (table tables) (puthash "retained-key" t table))
      (cl-letf (((symbol-function 'pichat-backend-cancel-owned-request)
                 (lambda (owner id)
                   (should (eq session owner))
                   (push id cancelled))))
        (pichat-chat--on-session-rebinding session 'session-rebinding nil))
      (should (equal '("old-stats" "old-sync") cancelled))
      (should (= (1+ generation) pichat-chat--source-generation))
      (should (equal process-generation (pichat-session-process-generation session)))
      (should-not (pichat-chat-draft-current-p target))
      (should (equal "unsent draft" (pichat-chat--input-text)))
      (should (eq pending pichat-chat--pending-attachments))
      (should (eq recovery pichat-chat--recoverable-submissions))
      (should-not (marker-position start))
      (should-not (overlay-buffer overlay))
      (should-not pichat-chat--entry-cache)
      (should-not pichat-chat--canonical-transcript)
      (should (= pichat-chat--source-generation
                 (pichat-live-draft-generation pichat-chat--live-draft)))
      (should (cl-every (lambda (table) (zerop (hash-table-count table)))
                        (pichat-test-focused-rollback--source-tables)))
      (should (cl-every (lambda (old new) (not (eq old new)))
                        tables (pichat-test-focused-rollback--source-tables)))
      ;; Returning to the old source cannot revive its captured draft target.
      (pichat-chat--reset-for-source
       (pichat-session-id session) (pichat-session-session-file session) t)
      (should-not (pichat-chat-draft-current-p target))
      ;; A second chat gets its own empty tables; no shared default hash state.
      (with-temp-buffer
        (pichat-chat-mode)
        (should (cl-every (lambda (table) (zerop (hash-table-count table)))
                          (pichat-test-focused-rollback--source-tables)))
        (should (cl-every (lambda (old new) (not (eq old new)))
                          tables (pichat-test-focused-rollback--source-tables)))))))

(ert-deftest pichat-chat-settlement-keeps-source-views-but-expires-auxiliary-details ()
  (pichat-test-focused-rollback--with-buffer
    (puthash "kept-tool" 'args pichat-chat--tool-view-states)
    (puthash "kept-skill" "original skill text" pichat-chat--skill-view-states)
    (puthash "rollback-tool" '(:details "nonpersisted")
             pichat-chat--tool-auxiliary-details)
    (let* ((enrichment (gethash "rollback-tool" pichat-chat--tool-enrichments))
           (target (pichat-chat-draft-capture))
           (generation pichat-chat--source-generation)
           (model (pichat-transcript-create :nodes nil))
           (context (pichat-chat--canonical-render-context model)))
      (pichat-chat--project-canonical
       nil model (pichat-render-canonical model context) context)
      (should (= generation pichat-chat--source-generation))
      (should (pichat-chat-draft-current-p target))
      (should (eq 'args (gethash "kept-tool" pichat-chat--tool-view-states)))
      (should (equal "original skill text"
                     (gethash "kept-skill" pichat-chat--skill-view-states)))
      (should (eq enrichment (gethash "rollback-tool" pichat-chat--tool-enrichments)))
      (should (zerop (hash-table-count pichat-chat--tool-auxiliary-details))))))

(ert-deftest pichat-chat-focused-rollback-after-prompt-edits-preserves-private-undo ()
  (ert-skip "TODO W28: preserve focused change-group undo identity after prompt edits")
  (pichat-test-focused-rollback--with-buffer
    (goto-char (point-max))
    (insert "unsent draft")
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_update" "candidate prose" "new.el")
    (set-buffer-modified-p nil)
    (let ((before (buffer-string))
          (undo-before (copy-tree buffer-undo-list))
          caught)
      (cl-letf (((symbol-function 'pichat-chat--index-canonical-tools)
                 (lambda (&rest _) (error "injected index failure"))))
        (condition-case err (pichat-chat--project-live-tail)
          (error (setq caught err))))
      (should (equal '(error "injected index failure") caught))
      (should (equal-including-properties before (buffer-string)))
      (should (equal undo-before buffer-undo-list))
      (should (equal "unsent draft" (pichat-chat--input-text))))))

(provide 'pichat-test-chat-projection-focused-rollback)
;;; pichat-test-chat-projection-focused-rollback.el ends here
