;;; pichat-test-chat-projection-focused-rollback.el --- Focused live rollback tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Failure-injection and structural coverage for the live-region transaction.

;;; Code:

(require 'pichat-test-chat-projection-incremental)

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

(defun pichat-test-focused-rollback--markdown-overlay-state ()
  "Return identity and geometry of owned Markdown presentation overlays."
  (let (entries)
    (dolist (overlay (overlays-in (point-min) (point-max)))
      (when (overlay-get overlay 'pichat-markdown-presentation)
        (push (list overlay (overlay-start overlay) (overlay-end overlay)
                    (overlay-properties overlay))
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
   :tool-overlays (pichat-test-focused-rollback--tool-overlay-state)
   :markdown-overlays (pichat-test-focused-rollback--markdown-overlay-state)))

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
     (let ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (pichat-chat-collapse-tools-by-default nil)
           (pichat-chat-tool-default-display 'output)
           buffer)
       (unwind-protect
           (progn
             (setq buffer (pichat-chat-open session))
             (with-current-buffer buffer
               (pichat-test-focused-rollback--start
                pichat-chat--live-draft "committed prose" "old.el")
               (pichat-chat--project-live-tail)
               (should (overlayp
                        (plist-get
                         (gethash "rollback-tool"
                                  pichat-chat--live-tool-blocks)
                         :overlay)))
               ,@body))
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

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

(ert-deftest pichat-chat-focused-rollback-restores-markdown-presentation-failure ()
  (pichat-test-focused-rollback--with-buffer
    (setq pichat-chat-markdown-mode t)
    (pichat-markdown-presentation--metadata-overlay
     (marker-position pichat-chat--live-start)
     (1+ (marker-position pichat-chat--live-start))
     'link '(phase-5 existing-link) 'compact t)
    (should (pichat-test-focused-rollback--markdown-overlay-state))
    (pichat-test-focused-rollback--candidate
     pichat-chat--live-draft "message_end"
     "changed [Markdown](https://example.com/new)" "markdown.el")
    (let ((original
           (symbol-function 'pichat-chat--refresh-final-live-presentation)))
      (pichat-test-focused-rollback--assert-failure-restores
       (lambda ()
         (cl-letf (((symbol-function
                     'pichat-chat--refresh-final-live-presentation)
                    (lambda ()
                      (funcall original)
                      (error "injected Markdown presentation failure"))))
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

(provide 'pichat-test-chat-projection-focused-rollback)
;;; pichat-test-chat-projection-focused-rollback.el ends here
