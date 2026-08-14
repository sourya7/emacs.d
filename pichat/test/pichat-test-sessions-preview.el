;;; pichat-test-sessions-preview.el --- Branch preview tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused Phase 6 tests for immutable root-to-entry branch previews.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-sessions-tree)

(defun pichat-test-sessions-preview--response ()
  "Return a branched response with explicit tool activity."
  (let* ((active-leaf
          (pichat-test-sessions-tree--message
           "active-leaf" "assistant" "Active answer"))
         (active-user
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--message
            "active-user" "user" "Active prompt")
           (list active-leaf)))
         (alternate-leaf
          (pichat-test-sessions-tree--entry
           "alternate-leaf" "message" :timestamp "2026-07-25T18:42:00Z"
           :message '(:role "assistant" :content "Alternate answer")))
         (alternate-user
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "alternate-user" "message"
            :message '(:role "user"
                       :content ((:type "text" :text "Alternate prompt")
                                 (:type "image" :mediaType "image/png"
                                  :data "omitted"))))
           (list alternate-leaf)))
         (result
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "result" "message"
            :message '(:role "toolResult" :toolCallId "call-1"
                       :toolName "read"
                       :content ((:type "text" :text "tool output"))))
           (list active-user alternate-user)))
         (assistant
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--entry
            "assistant" "message"
            :message '(:role "assistant"
                       :content ((:type "text" :text "Checking")
                                 (:type "toolCall" :id "call-1" :name "read"
                                  :arguments (:path "README.md")))))
           (list result)))
         (root
          (pichat-test-sessions-tree--set-children
           (pichat-test-sessions-tree--message
            "root" "user" "Initial prompt")
           (list assistant))))
    (list :data (list :tree (list root) :leafId "active-leaf"))))

(defun pichat-test-sessions-preview--kill-buffers ()
  "Kill Phase 6 auxiliary buffers when present."
  (dolist (name '("*PiChat Branch Preview*" "*PiChat Session Entry*"))
    (when-let ((buffer (get-buffer name)))
      (kill-buffer buffer))))

(defmacro pichat-test-sessions-preview--with-history (&rest body)
  "Install the preview fixture in a temporary history buffer and run BODY."
  (declare (indent 0) (debug body))
  `(let ((session (pichat-session-make :id "session" :session-file "/one")))
     (unwind-protect
         (with-temp-buffer
           (pichat-sessions--refresh-from-response
            (pichat-test-sessions-preview--response)
            session (current-buffer))
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
           (chat (generate-new-buffer " *pichat-preview-chat*")))
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
                     (call-pos (string-match "TOOL CALL: read" text))
                     (result-pos (string-match "TOOL RESULT: read" text))
                     (alternate-pos (string-match "Alternate prompt" text)))
                (should (string-match-p "Status: alternate branch" text))
                (should (string-match-p "Selected entry: assistant at 18:42" text))
                (should (string-match-p
                         (regexp-quote "{\"path\":\"README.md\"}") text))
                (should (string-match-p "tool output" text))
                (should (< root-pos call-pos result-pos alternate-pos))))
            (should (eq nodes pichat-sessions--nodes))
            (should (eq parents pichat-sessions--parents))
            (with-current-buffer chat
              (should (equal "canonical chat unchanged" (buffer-string)))))
        (kill-buffer chat)))))

(ert-deftest pichat-sessions-preview-opens-and-reuses-at-selected-entry ()
  (pichat-test-sessions-preview--with-history
    (let ((history (current-buffer)))
      (save-window-excursion
        (switch-to-buffer history)
        (dolist (id '("alternate-leaf" "assistant"))
          (pichat-sessions--goto-id id)
          (pichat-sessions-preview-branch-at-point)
          (should (equal "*PiChat Branch Preview*" (buffer-name)))
          (should (equal id
                         (get-text-property
                          (point) 'pichat-preview-entry-id)))
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

(ert-deftest pichat-sessions-preview-fork-confirms-summary-id-and-image-limit ()
  (pichat-test-sessions-preview--with-history
    (pichat-sessions--goto-id "alternate-leaf")
    (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
      (pichat-sessions-preview-branch-at-point))
    (let (prompt sent-id sent-session)
      (with-current-buffer "*PiChat Branch Preview*"
        (cl-letf (((symbol-function 'yes-or-no-p)
                   (lambda (text) (setq prompt text) t))
                  ((symbol-function 'pichat-rpc-fork)
                   (lambda (rpc-session id _success &optional _error)
                     (setq sent-session rpc-session sent-id id)
                     "fork-request")))
          (pichat-sessions-preview-fork)))
      (should (eq session sent-session))
      (should (equal "alternate-user" sent-id))
      (should (string-match-p "Alternate prompt" prompt))
      (should (string-match-p "alternate-user" prompt))
      (should (string-match-p "text only" prompt)))))

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
      (pichat-emit session 'session-rebinding :command "fork")
      (with-current-buffer preview
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
        (should (eq (lookup-key pichat-sessions-preview-mode-map (kbd "f"))
                    #'pichat-sessions-preview-fork))
        (should (eq (lookup-key pichat-sessions-preview-mode-map (kbd "t"))
                    #'pichat-sessions-preview-return-to-history))
        (should (eq (lookup-key pichat-sessions-preview-mode-map (kbd "q"))
                    #'pichat-view-quit))
        (should (eq (lookup-key pichat-sessions-preview-mode-map (kbd "d"))
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

(provide 'pichat-test-sessions-preview)
;;; pichat-test-sessions-preview.el ends here
