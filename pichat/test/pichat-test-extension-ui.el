;;; pichat-test-extension-ui.el --- Pichat Test Extension Ui -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-extension-notifications-are-anchored-multiline-content ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "notify" :notifyType "info"
                       :message "Sandbox Configuration\n  Active mode: default")))
              (goto-char (point-min))
              (search-forward "Sandbox Configuration")
              (let ((position (match-beginning 0)))
                (should (get-text-property
                         position 'pichat-extension-notification))
                (should (eq 'shadow
                            (get-text-property position 'font-lock-face)))
                (should (get-text-property position 'read-only)))
              (should (string-match-p
                       "Sandbox Configuration\n  Active mode: default"
                       (pichat-test-buffer-text buffer)))
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "notify" :notifyType "warning"
                       :message "second notice")))
              (goto-char (point-min))
              (search-forward "second notice")
              (should (eq 'warning
                          (get-text-property (match-beginning 0)
                                             'font-lock-face)))
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-transcript-node-create
                         :kind 'message :key "entry-1" :role 'assistant
                         :content
                         (list (pichat-transcript-content-create
                                :kind 'prose :index 0
                                :text "later response"))))
                       :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (let ((text (pichat-test-buffer-text buffer)))
                (should (< (string-match "Sandbox Configuration" text)
                           (string-match "second notice" text)
                           (string-match "later response" text))))
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "setStatus" :statusKey "build"
                       :statusText "working")))
              (goto-char (point-min))
              (search-forward "working")
              (let ((position (match-beginning 0)))
                (should (get-text-property position 'pichat-status))
                (should (get-text-property position 'pichat-extension-status))
                (should (<= (marker-position
                             pichat-chat--extension-status-start)
                            position))
                (should (< position
                           (marker-position
                            pichat-chat--extension-status-end)))
                (should (< position
                           (marker-position pichat-chat--canonical-start))))
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "setStatus" :statusKey "build"
                       :statusText nil)))
              (should-not (string-match-p "working"
                                          (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-status-burst-coalesces-reprojection ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer callback callback-args
          (timer (timer-create))
          (projections 0))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-with-idle-timer)
                       (lambda (_delay _repeat function &rest args)
                         (setq callback function callback-args args)
                         timer))
                      ((symbol-function 'cancel-timer) #'ignore)
                      ((symbol-function 'pichat-chat--project-extension-statuses)
                       (lambda () (cl-incf projections))))
              (with-current-buffer buffer
                (dolist (text '("usage 1" "usage 2" "usage 3"))
                  (pichat-chat--on-extension-ui-request
                   session 'extension-ui-request
                   (list :raw (list :method "setStatus"
                                    :statusKey "usage"
                                    :statusText text))))
                (should (= 1 projections))
                (should (equal "usage 3"
                               (gethash "usage"
                                        pichat-chat--extension-statuses))))
              (apply callback callback-args)
              (should (= 2 projections))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-status-stays-below-header-as-content-grows ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer status-position)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "setStatus" :statusKey "sandbox"
                       :statusText "Sandbox: default")))
              (goto-char (point-min))
              (search-forward "Sandbox: default")
              (setq status-position (match-beginning 0))
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_end"
                 :message (:role "assistant"
                           :content ((:type "text" :text "live response")))))
              (pichat-chat--project-live-tail)
              (goto-char (point-min))
              (search-forward "Sandbox: default")
              (should (= status-position (match-beginning 0)))
              (should (< (match-beginning 0)
                         (marker-position pichat-chat--canonical-start)))
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-transcript-node-create
                         :kind 'message :key "entry-1" :role 'assistant
                         :content
                         (list (pichat-transcript-content-create
                                :kind 'prose :index 0
                                :text "canonical response"))))
                       :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (goto-char (point-min))
              (search-forward "Sandbox: default")
              (should (= status-position (match-beginning 0)))
              (should (< (match-beginning 0)
                         (marker-position pichat-chat--canonical-start)))
              (should (string-match-p "canonical response"
                                      (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-fire-and-forget-ui-updates-native-chat-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "setWidget" :widgetKey "plan"
                       :widgetLines ["Step one" "Step two"]
                       :widgetPlacement "aboveEditor")))
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "setTitle" :title "Pi plan mode")))
              (pichat-chat--on-extension-ui-request
               session 'extension-ui-request
               '(:raw (:method "set_editor_text" :text "prefilled prompt")))
              (should (equal "Pi plan mode" pichat-chat--extension-title))
              (should (gethash "plan" pichat-chat--extension-widgets))
              (should (pichat-chat--prompt-live-p))
              (should (<= (marker-position pichat-chat--widget-end)
                          (marker-position pichat-chat--prompt-start)))
              (should (string-match-p "Step one" (pichat-test-buffer-text buffer)))
              (should (equal "prefilled prompt" (pichat-chat--input-text)))
              (should (string-match-p "Pi plan mode" (pichat-chat--mode-line-status)))
              (pichat-chat--set-status 'test "[status] keep")
              (let* ((transcript (pichat-transcript-create
                                  :nodes nil :diagnostics nil :metadata nil))
                     (context (pichat-chat--canonical-render-context))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical nil transcript fragment context))
              (should (pichat-chat--prompt-live-p))
              (should (string-match-p "Step one" (pichat-test-buffer-text buffer)))
              (should (string-match-p "status.*keep"
                                      (pichat-test-buffer-text buffer)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-ui-cancels-when-owning-chat-buffer-dies ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer cancelled)
      (setq buffer (pichat-chat-open session))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _args) 'deferred))
                ((symbol-function 'pichat-rpc-extension-ui-cancel)
                 (lambda (_session id) (push id cancelled))))
        (with-current-buffer buffer
          (pichat-chat--on-extension-ui-request
           session 'extension-ui-request
           '(:raw (:id "dialog-1" :method "input" :title "Question")))
          (should (= 1 pichat-chat--pending-ui-count)))
        (kill-buffer buffer)
        (should (equal '("dialog-1") cancelled))))))

(ert-deftest pichat-extension-ui-clears-pending-request-when-session-dies ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest _args) 'deferred)))
              (with-current-buffer buffer
                (pichat-chat--on-extension-ui-request
                 session 'extension-ui-request
                 '(:raw (:id "dialog-death" :method "confirm" :title "Question")))
                (should (= 1 pichat-chat--pending-ui-count))))
            (delete-process proc)
            (pichat-test-wait-until
             (lambda ()
               (with-current-buffer buffer
                 (zerop pichat-chat--pending-ui-count)))
             2 "extension dialog cleanup after process death"))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-ui-background-request-waits-for-owning-chat ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (other (generate-new-buffer " *pichat-unrelated*"))
          buffer observed-counts)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-on
             'user-input-pending-changed
             (lambda (_session _event plist)
               (push (plist-get plist :count) observed-counts)))
            (switch-to-buffer other)
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest _args)
                         (ert-fail "Background request must not schedule a reader"))))
              (with-current-buffer buffer
                (pichat-chat--on-extension-ui-request
                 session 'extension-ui-request
                 '(:raw (:id "background-dialog" :method "input"
                         :title "Question")))
                (should (= 1 (pichat-chat-pending-user-input-count session)))
                (should (equal '(1) observed-counts)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest pichat-extension-ui-rechecks-selection-before-reader-runs ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (other (generate-new-buffer " *pichat-race-target*"))
          buffer callback callback-args
          (reader-calls 0)
          responses)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_delay _repeat function &rest args)
                         (setq callback function callback-args args)
                         'deferred))
                      ((symbol-function 'yes-or-no-p)
                       (lambda (&rest _args) (cl-incf reader-calls) t))
                      ((symbol-function 'pichat-rpc-extension-ui-confirm)
                       (lambda (_session id value)
                         (push (list id value) responses))))
              (with-current-buffer buffer
                (pichat-chat--on-extension-ui-request
                 session 'extension-ui-request
                 '(:raw (:id "racy-dialog" :method "confirm"
                         :title "Approve" :message "Proceed?"))))
              (should callback)
              (switch-to-buffer other)
              (apply callback callback-args)
              (should (= 0 reader-calls))
              (with-current-buffer buffer
                (should (= 1 pichat-chat--pending-ui-count)))
              (switch-to-buffer buffer)
              (with-current-buffer buffer
                (pichat-chat--maybe-start-next-ui-request session))
              (apply callback callback-args)
              (should (= 1 reader-calls))
              (should (equal '(("racy-dialog" t)) responses))
              (with-current-buffer buffer
                (should (zerop pichat-chat--pending-ui-count)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p other) (kill-buffer other))))))

(ert-deftest pichat-extension-ui-eligibility-requires-focus-and-free-minibuffer ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (puthash "eligible" '(:id "eligible")
                       pichat-chat--pending-ui-requests)
              (let ((noninteractive nil))
                (cl-letf (((symbol-function 'frame-focus-state)
                           (lambda (&optional _frame) nil)))
                  (should-not
                   (pichat-chat--ui-request-eligible-p session "eligible"))))
              (cl-letf (((symbol-function 'active-minibuffer-window)
                         (lambda () (selected-window))))
                (should-not
                 (pichat-chat--ui-request-eligible-p session "eligible")))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-ui-serializes-multiple-requests-in-arrival-order ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer callback callback-args responses)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (_delay _repeat function &rest args)
                         (setq callback function callback-args args)
                         'deferred))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                      ((symbol-function 'pichat-rpc-extension-ui-confirm)
                       (lambda (_session id _value) (push id responses))))
              (with-current-buffer buffer
                (pichat-chat--on-extension-ui-request
                 session 'extension-ui-request
                 '(:raw (:id "first" :method "confirm")))
                (pichat-chat--on-extension-ui-request
                 session 'extension-ui-request
                 '(:raw (:id "second" :method "confirm")))
                (should (= 2 pichat-chat--pending-ui-count)))
              (apply callback callback-args)
              (with-current-buffer buffer
                (should (= 1 pichat-chat--pending-ui-count)))
              (apply callback callback-args)
              (should (equal '("first" "second") (nreverse responses)))
              (with-current-buffer buffer
                (should (zerop pichat-chat--pending-ui-count)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-extension-ui-pending-count-requires-exact-owning-chat ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (puthash "one" '(:id "one") pichat-chat--pending-ui-requests)
              (setq pichat-chat--pending-ui-count 1))
            (should (= 1 (pichat-chat-pending-user-input-count session)))
            (let ((other-session (pichat-session-make)))
              (should (zerop
                       (pichat-chat-pending-user-input-count other-session)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-extension-ui)
;;; pichat-test-extension-ui.el ends here
