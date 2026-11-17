;;; pichat-test-sessions-preview.el --- Branch preview tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Immutable root-to-entry branch previews and shared transcript presentation.

;;; Code:

(require 'pichat-test-history-support)

(defmacro pichat-test-sessions-preview--with-history (&rest body)
  "Install the preview fixture in a temporary history buffer and run BODY."
  (declare (indent 0) (debug body))
  `(let ((session (pichat-session-make :id "session" :session-file "/one")))
     (unwind-protect
         (pichat-test-with-history (session (pichat-test-sessions-preview--response))
           ,@body)
       (pichat-test-sessions-preview--kill-buffers))))

(ert-deftest pichat-sessions-preview-path-and-status-follow-exact-branch ()
  (pichat-test-sessions-preview--with-history
    (let ((model (pichat-sessions--current-model)))
      (should (equal '("root" "assistant" "result"
                       "alternate-user" "alternate-leaf")
                     (mapcar (lambda (node) (plist-get node :id))
                             (pichat-sessions--preview-path
                              model "alternate-leaf"))))
      (should (eq 'active-leaf
                  (pichat-sessions--preview-status model "active-leaf")))
      (should (eq 'active-ancestor
                  (pichat-sessions--preview-status model "assistant")))
      (should (eq 'alternate
                  (pichat-sessions--preview-status
                   model "alternate-leaf"))))))

(ert-deftest pichat-sessions-preview-renders-transcript-tools-and-ownership ()
  (pichat-test-sessions-preview--with-history
    (let* ((origin (current-buffer))
           (nodes pichat-sessions--nodes)
           (parents pichat-sessions--parents)
           (chat (generate-new-buffer " *pichat-preview-chat*"))
           (pichat-chat-activity-group-display 'expanded)
           (pichat-chat-tool-default-display 'output))
      (unwind-protect
          (progn
            (with-current-buffer chat (insert "canonical chat unchanged"))
            (pichat-sessions--goto-id "alternate-leaf")
            (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
              (pichat-sessions-preview-branch-at-point))
            (with-current-buffer "*PiChat Branch Preview*"
              (should (derived-mode-p 'pichat-sessions-preview-mode))
              (should (eq origin pichat-sessions-preview--origin-buffer))
              (should (eq session pichat-sessions-preview--session))
              (should (equal '("session" "/one")
                             pichat-sessions-preview--source-token))
              (should (equal "alternate-leaf"
                             pichat-sessions-preview--selected-id))
              (should (equal '("root" "assistant" "result"
                               "alternate-user" "alternate-leaf")
                             (mapcar (lambda (node) (plist-get node :id))
                                     pichat-sessions-preview--path)))
              (let* ((text (buffer-string))
                     (root-pos (string-match "Initial prompt" text))
                     (call-pos (string-match "README.md" text))
                     (result-pos (string-match "tool output" text))
                     (alternate-pos (string-match "Alternate prompt" text)))
                (should (string-match-p "Status: alternate branch\n\n" text))
                (should-not (string-match-p "f fork · t history" text))
                (should-not (string-match-p "q close · fork" text))
                (should (string-match-p "Selected entry: assistant at 18:42" text))
                (should (string-match-p "README.md" text))
                (should (string-match-p "tool output" text))
                (should (< root-pos call-pos result-pos alternate-pos))
                (should buffer-read-only)
                (should pichat-transcript-view-mode)
                (should-not (memq #'pichat-stop-session kill-buffer-hook)))
              (goto-char (point-min))
              (search-forward "README.md")
              (beginning-of-line)
              (call-interactively (key-binding (kbd "TAB")))
              (should-not (string-match-p "tool output" (buffer-string)))
              ;; A whole-region repaint retains the caller's provenance/actions
              ;; and the explicit tool choice, not just its initial text.
              (pichat-transcript-view-toggle-thinking)
              (should-not (string-match-p "tool output" (buffer-string)))
              (should (string-match-p "Status: alternate branch" (buffer-string)))
              (should (string-match-p "Alternate answer" (buffer-string)))
              (should (eq (key-binding (kbd "f")) #'pichat-sessions-preview-fork))
              (should (eq (key-binding (kbd "d")) #'pichat-sessions-preview-show-details)))
            (should (eq nodes pichat-sessions--nodes))
            (should (eq parents pichat-sessions--parents))
            (with-current-buffer chat
              (should (equal "canonical chat unchanged" (buffer-string)))))
        (kill-buffer chat)))))

(ert-deftest pichat-sessions-preview-opens-and-reuses-at-selected-entry ()
  (pichat-test-sessions-preview--with-history
    (setq pichat-sessions--filter 'all)
    (pichat-sessions--refresh-from-response
     (pichat-test-sessions-preview--response) session (current-buffer))
    (let ((history (current-buffer)))
      (save-window-excursion
        (switch-to-buffer history)
        (dolist (id '("alternate-leaf" "assistant" "result" "active-leaf"))
          (pichat-sessions--goto-id id)
          (pichat-sessions-preview-branch-at-point)
          (should (equal "*PiChat Branch Preview*" (buffer-name)))
          (if (equal id "result")
              (should (equal '("assistant" . "call-1")
                             (get-text-property (point) 'pichat-tool-key)))
            (should (equal id (get-text-property (point) 'pichat-node-key))))
          (should (= (point) (window-point (selected-window))))
          (should (= (point) (window-start (selected-window))))
          (should (save-excursion
                    (search-backward "Initial prompt" nil t)))
          (pichat-sessions-preview-return-to-history)
          (should (eq history (current-buffer))))))))

(ert-deftest pichat-sessions-preview-resolves-nearest-user-and-no-user-path ()
  (pichat-test-sessions-preview--with-history
    (let* ((model (pichat-sessions--current-model))
           (path (pichat-sessions--preview-path model "alternate-leaf")))
      (should (equal "alternate-user"
                     (plist-get
                      (pichat-sessions--preview-nearest-user path) :id))))
    (let* ((assistant
            (pichat-test-sessions-tree--message "assistant-only" "assistant" "hi"))
           (info
            (pichat-test-sessions-tree--set-children
             (pichat-test-sessions-tree--entry
              "info" "session_info" :name "empty")
             (list assistant)))
           (model (pichat-sessions--tree-model-from-data
                   (list :tree (list info) :leafId "assistant-only"))))
      (should-not
       (pichat-sessions--preview-nearest-user
        (pichat-sessions--preview-path model "assistant-only"))))))

(ert-deftest pichat-sessions-preview-fork-targets-branch-and-reports-image-limit ()
  (pichat-test-sessions-preview--with-history
    (pichat-sessions--goto-id "alternate-leaf")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (pichat-sessions-preview-branch-at-point))
    (let (notice sent-id sent-session)
      (with-current-buffer "*PiChat Branch Preview*"
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (ert-fail "Fork needs no confirmation")))
                  ((symbol-function 'message)
                   (lambda (format-string &rest args)
                     (setq notice (apply #'format format-string args))))
                  ((symbol-function 'pichat-rpc-fork)
                   (lambda (rpc-session id _success &optional _error)
                     (setq sent-session rpc-session sent-id id)
                     "fork-request")))
          (pichat-sessions-preview-fork)))
      (should (eq session sent-session))
      (should (equal "alternate-user" sent-id))
      (should (string-match-p "text only" notice)))))

(ert-deftest pichat-sessions-preview-no-user-sends-no-fork ()
  (let* ((session (pichat-session-make :id "session" :session-file "/one"))
         (assistant (pichat-test-sessions-tree--message
                     "assistant-only" "assistant" "hello"))
         (response (list :data (list :tree (list assistant)
                                     :leafId "assistant-only")))
         sent)
    (unwind-protect
        (with-temp-buffer
          (pichat-sessions--refresh-from-response response session (current-buffer))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (pichat-sessions-preview-branch-at-point))
          (with-current-buffer "*PiChat Branch Preview*"
            (cl-letf (((symbol-function 'pichat-rpc-fork)
                       (lambda (&rest _args) (setq sent t))))
              (should-error (pichat-sessions-preview-fork)
                            :type 'user-error)))
          (should-not sent))
      (pichat-test-sessions-preview--kill-buffers))))

(ert-deftest pichat-sessions-preview-rebind-marks-stale-and-disables-fork ()
  (pichat-test-sessions-preview--with-history
    (pichat-sessions--goto-id "alternate-leaf")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (pichat-sessions-preview-branch-at-point))
    (let ((preview (get-buffer "*PiChat Branch Preview*")) sent)
      (with-current-buffer preview
        ;; A stale notification must not reset folds, reindex blocks or repaint
        ;; Markdown.  Preserve both the rendered properties and owned markers.
        (let* ((start pichat-transcript-view--start)
               (end pichat-transcript-view--end)
               (tools pichat-transcript-view--tool-blocks)
               (states pichat-transcript-view--activity-view-states)
               (text (buffer-substring start end))
               (selected (copy-marker (point))))
          (unwind-protect
              (progn
                (pichat-emit session 'session-rebinding :command "fork")
                (pichat-emit session 'session-rebinding :command "switch_session")
                (should (eq start pichat-transcript-view--start))
                (should (eq end pichat-transcript-view--end))
                (should (eq tools pichat-transcript-view--tool-blocks))
                (should (eq states pichat-transcript-view--activity-view-states))
                (should (equal-including-properties
                         text (buffer-substring start end)))
                (should (= (point) selected))
                (should (= 1 (how-many "STALE" (point-min) (point-max)))))
            (set-marker selected nil)))
        (should pichat-sessions-preview--stale-p)
        (should (string-match-p "STALE" (buffer-string)))
        (should (string-match-p "Alternate answer" (buffer-string)))
        (cl-letf (((symbol-function 'pichat-rpc-fork)
                   (lambda (&rest _args) (setq sent t))))
          (should-error (pichat-sessions-preview-fork)
                        :type 'user-error)))
      (should-not sent)
      (kill-buffer preview)
      (should-not (gethash 'session-rebinding
                           (pichat-session-event-handlers session))))))

(ert-deftest pichat-sessions-preview-return-details-and-bindings ()
  (pichat-test-sessions-preview--with-history
    (let ((origin (current-buffer)) returned)
      (pichat-sessions--goto-id "alternate-leaf")
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (pichat-sessions-preview-branch-at-point))
      (with-current-buffer "*PiChat Branch Preview*"
        (should (derived-mode-p 'pichat-view-mode))
        (should (eq (key-binding (kbd "f"))
                    #'pichat-sessions-preview-fork))
        (should (eq (key-binding (kbd "t"))
                    #'pichat-sessions-preview-return-to-history))
        (should (eq (key-binding (kbd "q"))
                    #'pichat-view-quit))
        (should (eq (key-binding (kbd "d"))
                    #'pichat-sessions-preview-show-details))
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _args) (setq returned buffer))))
          (pichat-sessions-preview-return-to-history))
        (should (eq origin returned))
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
          (pichat-sessions-preview-show-details))
        (with-current-buffer "*PiChat Session Entry*"
          (should (derived-mode-p 'pichat-view-mode))
          (should (string-match-p "ID: alternate-leaf" (buffer-string))))))
    (should (eq (lookup-key pichat-sessions-mode-map (kbd "v"))
                #'pichat-sessions-preview-branch-at-point))))

(ert-deftest pichat-sessions-preview-rejected-transcript-retains-header-and-details ()
  (let* ((session (pichat-session-make :id "session"))
         (node (pichat-test-sessions-tree--entry
                "duplicate" "message"
                :message '(:role "assistant"
                           :content ((:type "toolCall" :id "same" :name "read"
                                      :arguments (:path "one"))
                                     (:type "toolCall" :id "same" :name "read"
                                      :arguments (:path "two")))))))
    (unwind-protect
        (pichat-test-with-history
            (session (pichat-test-sessions-tree--response
                      (list node) "duplicate"))
          (pichat-sessions--goto-id "duplicate")
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (pichat-sessions-preview-branch-at-point)
            (with-current-buffer "*PiChat Branch Preview*"
              (should buffer-read-only)
              (should (string-match-p "Branch Preview" (buffer-string)))
              (should (string-match-p "Status: active leaf" (buffer-string)))
              (should (string-match-p "Transcript unavailable:" (buffer-string)))
              (should (= (point) (point-min)))
              (pichat-sessions-preview-show-details))
            (with-current-buffer "*PiChat Session Entry*"
              (should (string-match-p "ID: duplicate" (buffer-string)))
              (should (string-match-p "two" (buffer-string))))))
      (pichat-test-sessions-preview--kill-buffers))))

(provide 'pichat-test-sessions-preview)
;;; pichat-test-sessions-preview.el ends here
