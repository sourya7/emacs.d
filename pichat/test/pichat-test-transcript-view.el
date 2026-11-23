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
   t))

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
       "-L" (file-name-directory (locate-library "pichat-test-transcript-view"))
       "--eval"
       (prin1-to-string
        '(progn
           (require 'pichat-transcript-view)
           (require 'pichat-test-transcript-view)
           ;; Run real controls/selection/rejection with chat locals genuinely
           ;; undeclared, not merely nil after the full suite loaded chat.
           (let ((stats (ert-run-tests-batch
                         '(member
                           pichat-transcript-view-controls-are-local-and-preserve-boundaries
                           pichat-transcript-view-skill-and-history-disclosures
                           pichat-transcript-view-selection-resolves-messages-records-and-results
                           pichat-transcript-view-rejection-preserves-caller-region-and-resets))))
             (unless (zerop (ert-stats-completed-unexpected stats))
               (error "Cold component controls failed")))
           (when (featurep 'pichat-chat) (error "Loaded chat"))
           (dolist (variable '(pichat-chat--session pichat-chat--tool-view-states
                               pichat-chat--activity-view-states
                               pichat-chat--skill-view-states))
             (when (boundp variable) (error "Bound chat local: %S" variable)))
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

(ert-deftest pichat-transcript-view-selection-resolves-messages-records-and-results ()
  (let* ((transcript (pichat-test-transcript-view--transcript))
         (pichat-chat-activity-group-display 'collapsed)
         (pichat-chat-show-thinking t)
         (original (copy-tree transcript t)))
    (dolist (selection '("user" "call" "result" "answer" "missing"))
      (with-temp-buffer
        (insert "Header\nFooter")
        (pichat-transcript-view-render transcript 8 8 nil (copy-sequence selection))
        (let ((position (pichat-transcript-view-selected-position)))
          (if (equal selection "missing")
              (should-not position)
            (should (<= 8 position))
            (should (< position pichat-transcript-view--end))
            (if (equal selection "result")
                (should (equal (get-text-property position 'pichat-tool-key)
                               '("call" . "tool")))
              (should (equal (get-text-property position 'pichat-node-key)
                             selection)))))
        (when (member selection '("call" "result"))
          (should (gethash "tool" pichat-transcript-view--tool-blocks))
          (should (string-match-p "Private reasoning" (buffer-string)))
          ;; Pre-expansion is initial policy, not an override on every repaint.
          (maphash (lambda (key value)
                     (puthash key (plist-put (copy-sequence value) :view 'collapsed)
                              pichat-transcript-view--activity-view-states))
                   pichat-transcript-view--activity-view-states)
          (pichat-transcript-view-repaint)
          (should-not (gethash "tool" pichat-transcript-view--tool-blocks)))))
    (with-temp-buffer
      (pichat-transcript-view-render transcript 1 1 1 "result")
      (should-not (pichat-transcript-view-selected-position)))
    (should (equal original transcript)))
  ;; A tail bound can split a group and change its anchor.  Expand the visible
  ;; group, not the full transcript's now-absent first tool.
  (with-temp-buffer
    (let ((pichat-chat-activity-group-display 'collapsed))
      (pichat-transcript-view-render-entries
       '((:id "first" :type "message"
          :message (:role "assistant" :stopReason "toolUse"
                    :content ((:type "toolCall" :id "one" :name "bash"))))
         (:id "second" :type "message"
          :message (:role "assistant" :stopReason "toolUse"
                    :content ((:type "toolCall" :id "two" :name "bash"))))
         (:id "result" :type "message"
          :message (:role "toolResult" :toolCallId "two" :content "output")))
       1 1 1 "result")
      (should (gethash "two" pichat-transcript-view--tool-blocks))
      (should-not (gethash "one" pichat-transcript-view--tool-blocks))
      (should (equal (get-text-property
                      (pichat-transcript-view-selected-position) 'pichat-tool-key)
                     '("second" . "two")))))
  ;; The caller can supply an alternate path; no active-branch cache is read.
  (with-temp-buffer
    (pichat-transcript-view-render-entries
     '((:id "other-user" :type "message"
        :message (:role "user" :content "Alternate request"))
       (:id "record" :type "model_change" :provider "example" :modelId "test"))
     1 1 nil (copy-sequence "record"))
    (should (string-match-p "Alternate request" (buffer-string)))
    (should (equal (get-text-property
                    (pichat-transcript-view-selected-position) 'pichat-node-key)
                   "record"))))

(ert-deftest pichat-transcript-view-rejection-preserves-caller-region-and-resets ()
  (dolist (builder '(nil t))
    (with-temp-buffer
      (insert (propertize "Header\n" 'owner 'caller) "old\nFooter")
      (pichat-transcript-view-render
       (pichat-test-transcript-view--transcript) 8 11 nil "result")
      (let ((marker (plist-get (gethash "tool" pichat-transcript-view--tool-blocks)
                              :start))
            (bad (pichat-test-transcript-view--transcript)))
        (if builder
            (pichat-transcript-view-render-entries
             '((:id "a" :type "message"
                :message (:role "assistant"
                          :content ((:type "toolCall" :id "duplicate" :name "bash")
                                    (:type "toolCall" :id "duplicate" :name "bash")))))
             pichat-transcript-view--start pichat-transcript-view--end)
          (setf (pichat-transcript-nodes bad)
                (append (pichat-transcript-nodes bad)
                        (list (car (pichat-transcript-nodes bad)))))
          (pichat-transcript-view-render
           bad pichat-transcript-view--start pichat-transcript-view--end))
        (should-not (marker-buffer marker)))
      (should buffer-read-only)
      (should (string-prefix-p "Header\nTranscript unavailable: " (buffer-string)))
      (should (string-match-p (if builder "Duplicate declared tool id" "Duplicate node key")
                              (buffer-string)))
      (should (eq (get-text-property 1 'owner) 'caller))
      (should (string-suffix-p "\nFooter" (buffer-string)))
      (should-not (pichat-transcript-view-selected-position))
      (should (= 0 (hash-table-count pichat-transcript-view--tool-blocks)))
      (let ((text (buffer-string)))
        (pichat-transcript-view-repaint)
        (should (equal text (buffer-string))))
      (pichat-transcript-view-render
       (pichat-test-transcript-view--transcript)
       pichat-transcript-view--start pichat-transcript-view--end)
      (should-not (string-match-p "unavailable" (buffer-string)))
      (should (string-match-p "Final answer" (buffer-string)))))
  (with-temp-buffer
    (let* ((key (concat "bad\n" (make-string 1000 ?x)))
           (node (pichat-transcript-node-create :kind 'activity :key key)))
      (pichat-transcript-view-render
       (pichat-transcript-create :nodes (list node node)) 1 1)
      (should (< (buffer-size) 350))
      (should (= 1 (cl-count ?\n (buffer-string)))))))

(ert-deftest pichat-transcript-view-controls-are-local-and-preserve-boundaries ()
  (let ((overriding-local-map nil)
        (overriding-terminal-local-map nil)
        (transcript (pichat-test-transcript-view--transcript))
        (pichat-chat-activity-group-display 'collapsed)
        (pichat-chat-tool-default-display 'summary)
        (pichat-chat-max-tool-args-chars 5)
        (pichat-chat-show-thinking t))
    (with-temp-buffer
      (special-mode)
      (let ((inhibit-read-only t)) (insert "Header\nFooter"))
      (pichat-transcript-view-render transcript 8 8)
      (goto-char 1)
      (should-error (pichat-transcript-view-toggle) :type 'user-error)
      (goto-char 8)
      (search-forward "Full user request")
      (should-error (pichat-transcript-view-toggle) :type 'user-error)
      (let ((group (car (hash-table-values pichat-transcript-view--activity-blocks))))
        (goto-char (plist-get group :start))
        ;; Resolve the rendered header's real key, including its chat remap.
        (should (eq (key-binding (kbd "RET")) #'pichat-transcript-view-toggle))
        (call-interactively (key-binding (kbd "RET")))
        (should (string-match-p "Private reasoning" (buffer-string)))
        (should (= (point) (plist-get (car (hash-table-values
                                          pichat-transcript-view--activity-blocks))
                                     :start))))
      (let* ((block (gethash "tool" pichat-transcript-view--tool-blocks))
             (answer (pichat-transcript-view--property-position
                      'pichat-node-key "answer")))
        (goto-char (plist-get block :start))
        (call-interactively (key-binding (kbd "TAB")))
        (should (eq (plist-get block :display-state) 'args))
        (should (= 1 (hash-table-count pichat-transcript-view--tool-view-states)))
        (should (> (pichat-transcript-view--property-position
                    'pichat-node-key "answer") answer))
        ;; Tool disclosure replaces only its block, not all indexes.
        (should (eq block (gethash "tool" pichat-transcript-view--tool-blocks)))
        (let (details)
          (cl-letf (((symbol-function 'pichat-view-display)
                     (lambda (buffer &rest _)
                       (setq details (with-current-buffer buffer (buffer-string)))
                       (kill-buffer buffer))))
            (call-interactively (key-binding (kbd "C-c C-d"))))
          (should (string-match-p "printf example" details))
          (should (string-match-p "Complete output" details))
          (should (string-match-p "non-persisted execution details unavailable" details)))
        (pichat-transcript-view-toggle-thinking)
        (should-not pichat-chat-show-thinking)
        (should-not (string-match-p "Private reasoning" (buffer-string))))
      (goto-char (plist-get (car (hash-table-values
                                 pichat-transcript-view--activity-blocks)) :start))
      (call-interactively (key-binding (kbd "C-c ;")))
      (should-not (gethash "tool" pichat-transcript-view--tool-blocks))
      (call-interactively (key-binding (kbd "C-c C-;")))
      (should (eq (plist-get (gethash "tool" pichat-transcript-view--tool-blocks)
                            :display-state) 'args))
      (should (string-prefix-p "Header\n" (buffer-string)))
      (should (string-suffix-p "Footer" (buffer-string)))
      (should-not (overlays-in (point-min) (point-max)))
      (pichat-transcript-view-clear)
      (should-not pichat-transcript-view-mode))
    (should pichat-chat-show-thinking)
    (with-temp-buffer
      (pichat-transcript-view-render transcript 1 1)
      (should (= 0 (hash-table-count pichat-transcript-view--tool-view-states)))
      (should-not (string-match-p "Private reasoning" (buffer-string))))))

(ert-deftest pichat-transcript-view-disclosure-keys-do-not-shadow-ordinary-text ()
  (let ((overriding-local-map nil)
        (overriding-terminal-local-map nil)
        (pichat-chat-activity-group-display 'expanded)
        (pichat-chat-tool-default-display 'summary))
    (save-window-excursion
      (with-temp-buffer
        (switch-to-buffer (current-buffer))
        (special-mode)
        (let ((inhibit-read-only t)
              (map (copy-keymap (current-local-map))))
          (dolist (key '("RET" "TAB" "<return>" "<tab>"))
            (define-key map (kbd key) #'ignore))
          (define-key map [mouse-1] #'mouse-set-point)
          (use-local-map map)
          (insert "Header\nFooter"))
        (let ((transcript (pichat-test-transcript-view--transcript))
              (summary (pichat-pi-build-canonical-transcript-from-entries
                        '((:id "summary" :type "branch_summary"
                           :summary "Full summary body")) t)))
          (setf (pichat-transcript-nodes transcript)
                (append (pichat-transcript-nodes transcript)
                        (pichat-transcript-nodes summary)))
          (pichat-transcript-view-render transcript 8 8))
        (dolist (position (list 1 (pichat-transcript-view--property-position
                                  'pichat-node-key "answer")
                               (marker-position pichat-transcript-view--end)))
          (goto-char position)
          (dolist (key '("RET" "TAB" "<return>" "<tab>"))
            (should (eq (key-binding (kbd key)) #'ignore)))
          (should (eq (key-binding [mouse-1]) #'mouse-set-point)))
        (dolist (target '((pichat-tool-key . ("call" . "tool"))
                          (pichat-history-key . "summary")))
          (goto-char (pichat-transcript-view--property-position
                      (car target) (cdr target)))
          (dolist (key '("RET" "TAB" "<return>" "<tab>"))
            (should (eq (key-binding (kbd key)) #'pichat-transcript-view-toggle)))
          (call-interactively (key-binding (kbd "RET")))
          (should (string-match-p (if (eq (car target) 'pichat-tool-key)
                                     "Command (non-interactive):" "Full summary body")
                                 (buffer-string)))
          (let* ((position (point))
                 (command (key-binding [mouse-1]))
                 (event (list 'mouse-1 (list (selected-window) position '(0 . 0) 0))))
            (should (eq command #'pichat-transcript-view-toggle))
            ;; Click dispatch must use the event position, not the old point.
            (goto-char 1)
            (funcall command event))
          (if (eq (car target) 'pichat-tool-key)
              (should (eq (plist-get
                           (gethash "tool" pichat-transcript-view--tool-blocks)
                           :display-state) 'summary))
            (should-not (string-match-p "Full summary body" (buffer-string)))))))))

(ert-deftest pichat-transcript-view-last-tool-keeps-region-end-and-caller-actions ()
  (let* ((transcript (pichat-test-transcript-view--transcript))
         (pichat-chat-activity-group-display 'expanded)
         (pichat-chat-tool-default-display 'summary))
    (setf (pichat-transcript-nodes transcript)
          (butlast (pichat-transcript-nodes transcript)))
    (with-temp-buffer
      (special-mode)
      (let ((map (copy-keymap (current-local-map))) (inhibit-read-only t))
        (define-key map (kbd "d") #'ignore)
        (use-local-map map)
        (insert "Header\nFooter"))
      (pichat-transcript-view-render transcript 8 8)
      (let ((block (gethash "tool" pichat-transcript-view--tool-blocks)))
        (goto-char (plist-get block :start))
        (pichat-transcript-view-toggle-tool)
        (should (= pichat-transcript-view--end (plist-get block :end)))
        (should (eq (lookup-key (current-local-map) (kbd "d")) #'ignore))
        (pichat-transcript-view-repaint)
        (should (string-suffix-p "Footer" (buffer-string)))
        (should (= 1 (how-many "Footer" (point-min) (point-max))))))))

(ert-deftest pichat-transcript-view-skill-and-history-disclosures ()
  (let* ((overriding-local-map nil)
         (overriding-terminal-local-map nil)
         (skill "<skill name=\"example\" location=\"/fixture/SKILL.md\">\nExact skill body\n</skill>\n\nRequest")
         (transcript
          (pichat-pi-build-canonical-transcript-from-entries
           (list (list :id "skill" :type "message"
                       :message (list :role "user" :content skill))
                 '(:id "summary" :type "branch_summary" :summary "Full summary body"))
           t)))
    (with-temp-buffer
      (special-mode)
      (pichat-transcript-view-render transcript 1 1)
      (goto-char (pichat-transcript-view--property-position 'pichat-skill-key "skill"))
      (should (eq (key-binding (kbd "w")) #'pichat-transcript-view-copy-skill))
      (let ((kill-ring nil))
        (call-interactively (key-binding (kbd "w")))
        (should (equal (car kill-ring) skill)))
      (call-interactively (key-binding (kbd "RET")))
      (should (string-match-p "Exact skill body" (buffer-string)))
      (call-interactively (key-binding (kbd "TAB")))
      (should-not (string-match-p "Exact skill body" (buffer-string)))
      (goto-char (pichat-transcript-view--property-position 'pichat-history-key "summary"))
      (call-interactively (key-binding (kbd "RET")))
      (should (string-match-p "Full summary body" (buffer-string)))
      (call-interactively (key-binding (kbd "TAB")))
      (should-not (string-match-p "Full summary body" (buffer-string)))
      (pichat-transcript-view-render transcript pichat-transcript-view--start
                                     pichat-transcript-view--end)
      (should (= 0 (hash-table-count pichat-transcript-view--skill-view-states)))
      (should (= 0 (hash-table-count pichat-transcript-view--history-view-states))))))

(ert-deftest pichat-transcript-view-markdown-is-region-local-and-reapplied ()
  (let ((transcript (pichat-test-transcript-view--transcript))
        (aliases '((face caller-face) (help-echo caller-help)))
        (pichat-chat-render-markdown t)
        sources)
    ;; Exercise the real prose selector and face application, independently of
    ;; the optional Markdown package and of chat orchestration.
    (cl-letf (((symbol-function 'pichat-markdown-fontification--face-runs)
               (lambda (source)
                 (push source sources)
                 (list (list 0 (length source) 'font-lock-keyword-face)))))
      (with-temp-buffer
        (special-mode)
        (setq-local char-property-alias-alist aliases)
        (let ((inhibit-read-only t))
          (insert (propertize "Header\n" 'pichat-prose t 'face 'bold)
                  "old" (propertize "\nFooter" 'pichat-prose t)))
        (pichat-transcript-view-render transcript 8 11)
        (should (equal sources '("Final answer")))
        (should (equal aliases '((face caller-face) (help-echo caller-help))))
        (should (equal (alist-get 'face char-property-alias-alist)
                       '(font-lock-face caller-face)))
        (should (equal (alist-get 'help-echo char-property-alias-alist)
                       '(caller-help)))
        (should-not font-lock-mode)
        (should (eq (get-text-property 1 'face) 'bold))
        (should-not (get-text-property 1 'font-lock-face))
        (should-not (get-text-property (1- (point-max)) 'font-lock-face))
        (let ((position (pichat-transcript-view--property-position
                         'pichat-node-key "answer"))
              (exact (buffer-substring-no-properties 1 (point-max))))
          (should (eq (get-text-property position 'font-lock-face)
                      'font-lock-keyword-face))
          (pichat-transcript-view-repaint)
          (should (= 2 (length sources)))
          (should (equal exact (buffer-substring-no-properties 1 (point-max))))
          (setq-local pichat-chat-render-markdown nil)
          (pichat-transcript-view-repaint)
          (should (= 2 (length sources)))
          (should-not (get-text-property position 'font-lock-face))
          (setq-local pichat-chat-render-markdown t)
          (cl-letf (((symbol-function 'pichat-markdown-fontification--face-runs)
                     (lambda (_) (error "Optional fontifier failed"))))
            (pichat-transcript-view-repaint))
          (should (equal exact (buffer-substring-no-properties 1 (point-max))))
          (should buffer-read-only)
          (should-not (pichat-transcript-view-selected-position)))))))

(ert-deftest pichat-transcript-view-history-stays-source-ordered-and-reachable ()
  (let* ((records
          '((:id "model" :type "model_change" :provider "example" :modelId "model")
            (:id "thinking" :type "thinking_level_change" :thinkingLevel "high")
            (:id "info" :type "session_info" :name "Historical name")
            (:id "label" :type "label" :label "Historical label")
            (:id "edit" :type "context_edit" :targetId "model" :replacement "SECRET")
            (:id "custom" :type "custom" :customType "extension")
            (:id "hidden" :type "custom_message" :content "Hidden message")
            (:id "system" :type "message" :message (:role "system" :content "System text"))
            (:id "bash" :type "message" :message
             (:role "bashExecution" :command "echo history" :output "Historical output"))
            (:id "compact" :type "compaction" :summary "Compaction body")
            (:id "branch" :type "branch_summary" :summary "Branch body")
            (:id "compact-role" :type "message" :message
             (:role "compactionSummary" :content "Compaction role body"))
            (:id "branch-role" :type "message" :message
             (:role "branchSummary" :content "Branch role body"))))
         (original (copy-tree records t)))
    (with-temp-buffer
      (special-mode)
      (pichat-transcript-view-render-entries records 1 1)
      (let ((previous 0))
        (dolist (entry records)
          ;; Selection is checked through the public entry API for every record.
          (pichat-transcript-view-render-entries
           records pichat-transcript-view--start pichat-transcript-view--end
           nil (copy-sequence (plist-get entry :id)))
          (let ((position (pichat-transcript-view-selected-position)))
            (should position)
            (should (> position previous))
            (setq previous position))))
      (dolist (text '("example/model" "high" "Historical name" "Historical label"
                      "Replace model" "extension" "Hidden message" "System text"
                      "echo history" "Historical output"))
        (should (string-match-p (regexp-quote text) (buffer-string))))
      (should-not (string-match-p "SECRET" (buffer-string)))
      (dolist (pair '(("compact" . "Compaction body") ("branch" . "Branch body")
                      ("compact-role" . "Compaction role body")
                      ("branch-role" . "Branch role body")))
        (should-not (string-match-p (regexp-quote (cdr pair)) (buffer-string)))
        (goto-char (pichat-transcript-view--property-position
                    'pichat-history-key (car pair)))
        (pichat-transcript-view-toggle)
        (should (string-match-p (regexp-quote (cdr pair)) (buffer-string))))
      (should buffer-read-only)
      (should-not (overlays-in (point-min) (point-max))))
    (should (equal records original))))

(provide 'pichat-test-transcript-view)
;;; pichat-test-transcript-view.el ends here
