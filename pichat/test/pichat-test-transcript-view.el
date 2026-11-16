;;; pichat-test-transcript-view.el --- Transcript region tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Emacs-only component tests: no runtime or source-file acquisition.

;;; Code:

(require 'ert)
(require 'pichat-transcript-view)

(defun pichat-test-transcript-view--transcript ()
  "Build a small settled branch with a merged tool result."
  (pichat-pi-build-canonical-transcript-from-entries
   '((:id "user" :type "message"
      :message (:role "user" :content "Full user request"))
     (:id "call" :type "message"
      :message (:role "assistant"
                :content ((:type "thinking" :thinking "Private reasoning")
                          (:type "toolCall" :id "tool" :name "bash"
                           :arguments (:command "printf example")))))
     (:id "result" :type "message"
      :message (:role "toolResult" :toolCallId "tool" :toolName "bash"
                :content ((:type "text" :text "Complete output"))))
     (:id "answer" :type "message"
      :message (:role "assistant" :content "Final answer")))
   "answer"))

(ert-deftest pichat-transcript-view-owns-only-its-region ()
  (let ((transcript (pichat-test-transcript-view--transcript))
        (pichat-chat-activity-group-display 'expanded)
        (pichat-chat-show-thinking t)
        (pichat-chat-tool-default-display 'output))
    (with-temp-buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (insert (propertize "Header\n" 'owner 'caller) "old"
                (propertize "\nFooter" 'owner 'caller)))
      (should (= 0 (pichat-transcript-view-render transcript 8 11)))
      (should (eq major-mode 'special-mode))
      (should buffer-read-only)
      (should-error (insert "not writable") :type 'buffer-read-only)
      (should (equal (buffer-substring-no-properties 1 8) "Header\n"))
      (should (eq (get-text-property 1 'owner) 'caller))
      (should (string-suffix-p "\nFooter" (buffer-string)))
      (should (eq (get-text-property (1- (point-max)) 'owner) 'caller))
      (dolist (text '("Full user request" "Private reasoning" "Complete output"
                      "printf example" "Final answer"))
        (should (string-match-p (regexp-quote text) (buffer-string))))
      (let* ((block (gethash "tool" pichat-transcript-view--tool-blocks))
             (marker (plist-get block :start)))
        (should (markerp marker))
        (should (= 1 (hash-table-count pichat-transcript-view--activity-blocks)))
        (should-not (overlays-in (point-min) (point-max)))
        ;; Caller header changes move the region; footer insertions are not
        ;; swallowed by subsequent repaint, even at the exact end boundary.
        (let ((inhibit-read-only t))
          (goto-char 1) (insert "New ")
          (goto-char pichat-transcript-view--end) (insert "Outside"))
        (setq-local pichat-chat-show-thinking nil)
        (pichat-transcript-view-repaint)
        (should-not (marker-buffer marker))
        (should (string-prefix-p "New Header\n" (buffer-string)))
        (should (string-suffix-p "Outside\nFooter" (buffer-string)))
        (should-not (string-match-p "Private reasoning" (buffer-string)))
        (should (gethash "tool" pichat-transcript-view--tool-blocks)))
      (let ((text (buffer-string))
            (marker pichat-transcript-view--start)
            (tool-marker (plist-get (gethash "tool" pichat-transcript-view--tool-blocks)
                                   :start)))
        (pichat-transcript-view-clear)
        (should (equal text (buffer-string)))
        (should-not (marker-buffer marker))
        (should-not (marker-buffer tool-marker))))))

(ert-deftest pichat-transcript-view-bounds-nodes-before-rendering ()
  (let* ((transcript (pichat-test-transcript-view--transcript))
         (original (copy-tree (pichat-transcript-nodes transcript) t))
         (pichat-chat-activity-group-display 'expanded)
         (pichat-chat-tool-default-display 'output))
    (with-temp-buffer
      (insert "Header\nFooter")
      ;; Result is merged into the call: the last two nodes include both.
      (should (= 1 (pichat-transcript-view-render transcript 8 8 2)))
      (should-not (string-match-p "Full user request" (buffer-string)))
      (should (string-match-p "Complete output" (buffer-string)))
      (should (gethash "tool" pichat-transcript-view--tool-blocks))
      (should (= 2 (pichat-transcript-view-render
                    transcript pichat-transcript-view--start
                    pichat-transcript-view--end 1)))
      (should (string-match-p "Final answer" (buffer-string)))
      (should (= 0 (hash-table-count pichat-transcript-view--tool-blocks)))
      (should (= 3 (pichat-transcript-view-render
                    transcript pichat-transcript-view--start
                    pichat-transcript-view--end 0)))
      (should (equal (buffer-string) "Header\nFooter"))
      (should (= 0 (pichat-transcript-view-render
                    (pichat-transcript-create) 8 8)))
      (should (equal (buffer-string) "Header\nFooter")))
    (should (equal original (pichat-transcript-nodes transcript)))))

(ert-deftest pichat-transcript-view-empty-boundary-insertions-stay-caller-owned ()
  (dolist (bounded '(nil t))
    (with-temp-buffer
      (insert "Header\nFooter")
      (pichat-transcript-view-render
       (if bounded (pichat-test-transcript-view--transcript)
         (pichat-transcript-create))
       8 8 (and bounded 0))
      (let ((inhibit-read-only t))
        (goto-char 8)
        (insert (propertize "Caller\n" 'owner 'caller)))
      ;; Repainting an empty region must neither delete nor adopt caller text.
      (pichat-transcript-view-repaint)
      (should (equal (buffer-string) "Header\nCaller\nFooter"))
      (should (= 8 pichat-transcript-view--start))
      (should (= 8 pichat-transcript-view--end))
      ;; Removing the zero-node bound paints before the caller's insertion.
      (setq pichat-transcript-view--max-nodes nil)
      (pichat-transcript-view-repaint)
      (should (= 8 pichat-transcript-view--start))
      (when bounded
        (should (string-match-p "Full user request" (buffer-string)))
        (should (< 8 pichat-transcript-view--end)))
      (should (equal (buffer-substring-no-properties
                      pichat-transcript-view--end (point-max))
                     "Caller\nFooter"))
      (should (eq (get-text-property pichat-transcript-view--end 'owner)
                  'caller)))))

(ert-deftest pichat-transcript-view-local-choices-reset-on-new-render ()
  (let ((transcript (pichat-test-transcript-view--transcript))
        (pichat-chat-activity-group-display 'expanded)
        (pichat-chat-tool-default-display 'summary)
        (first (generate-new-buffer " *transcript-first*"))
        (second (generate-new-buffer " *transcript-second*")))
    (unwind-protect
        (progn
          (with-current-buffer first
            (pichat-transcript-view-render transcript 1 1)
            (puthash (pichat-chat-tool-ui-canonical-view-key "call" "tool")
                     'output pichat-transcript-view--tool-view-states)
            (pichat-transcript-view-repaint)
            (should (string-match-p "Complete output" (buffer-string))))
          (with-current-buffer second
            (pichat-transcript-view-render transcript 1 1)
            (should-not (string-match-p "Complete output" (buffer-string)))
            (should-not (eq pichat-transcript-view--tool-view-states
                            (buffer-local-value
                             'pichat-transcript-view--tool-view-states first))))
          (with-current-buffer first
            (let ((marker (plist-get
                           (gethash "tool" pichat-transcript-view--tool-blocks)
                           :start)))
              (pichat-transcript-view-render
               transcript pichat-transcript-view--start pichat-transcript-view--end)
              (should-not (marker-buffer marker)))
            (should-not (string-match-p "Complete output" (buffer-string)))
            (let ((marker pichat-transcript-view--start))
              (fundamental-mode)
              (should-not (marker-buffer marker))))
          (with-current-buffer second
            (let ((marker pichat-transcript-view--start)
                  (block-marker
                   (plist-get (gethash "tool" pichat-transcript-view--tool-blocks)
                              :start)))
              (kill-buffer second)
              (should-not (marker-buffer marker))
              (should-not (marker-buffer block-marker)))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest pichat-transcript-view-cold-load-has-no-chat-lifecycle ()
  (with-temp-buffer
    (should
     (zerop
      (call-process
       (expand-file-name invocation-name invocation-directory) nil t nil
       "-Q" "--batch" "-L"
       (file-name-directory (locate-library "pichat-transcript-view"))
       "--eval"
       (prin1-to-string
        '(progn
           (require 'pichat-transcript-view)
           (when (featurep 'pichat-chat) (error "Loaded chat"))
           (with-temp-buffer
             (let ((hooks (copy-tree kill-buffer-hook))
                   (post-hooks (copy-tree post-command-hook))
                   (completion (copy-tree completion-at-point-functions))
                   (pichat-tool-enrichment-path-context 'ambient))
               (pichat-transcript-view-render (pichat-transcript-create) 1 1)
               (unless (and (equal post-hooks post-command-hook)
                            (equal completion completion-at-point-functions)
                            (= 0 (hash-table-count
                                  pichat-transcript-view--tool-enrichments)))
                 (error "Unexpected runtime setup"))
               (dolist (hook kill-buffer-hook)
                 (unless (or (eq hook #'pichat-transcript-view-clear)
                             (eq hook t) (memq hook hooks))
                   (error "Unexpected kill hook: %S" hook))))))))))))

(provide 'pichat-test-transcript-view)
;;; pichat-test-transcript-view.el ends here
