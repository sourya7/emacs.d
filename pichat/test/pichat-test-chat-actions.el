;;; pichat-test-chat-actions.el --- Chat discovery tests -*- lexical-binding: t; -*-

;;; Code:

(require 'pichat-test-support)
(require 'pichat-chat-actions)

(defun pichat-test-chat-actions--exit ()
  "Close the fixture menu, including its command-loop hooks."
  (when transient--prefix
    (transient--pre-exit)
    (transient--post-exit))
  (when-let* ((buffer (get-buffer transient--buffer-name)))
    (kill-buffer buffer)))

(defmacro pichat-test-chat-actions--with-chat (&rest body)
  "Run BODY in a disposable chat without synchronizing it."
  (declare (indent 0))
  `(pichat-test-with-unit-session (session proc)
     (let ((pichat-chat-stop-session-on-kill nil) chat)
       (unwind-protect
           (progn
             (setq chat (pichat-chat-ensure session))
             (with-current-buffer chat ,@body))
         (pichat-test-chat-actions--exit)
         (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-chat-actions-requires-an-owning-chat ()
  (with-temp-buffer
    (should-error (pichat-chat-actions) :type 'user-error)))

(ert-deftest pichat-chat-actions-opening-and-closing-is-read-only ()
  (pichat-test-chat-actions--with-chat
    (pichat-chat--set-input-text "keep draft")
    (let ((text (buffer-string)) (position (point))
          (seq (pichat-session-rpc-seq session))
          (attachments pichat-chat--pending-attachments))
      (pichat-chat-actions)
      (should (eq (key-binding (kbd "C-c C-k")) #'pichat-chat-abort))
      (pichat-test-chat-actions--exit)
      (should (equal text (buffer-string)))
      (should (= position (point)))
      (should (equal seq (pichat-session-rpc-seq session)))
      (should (equal attachments pichat-chat--pending-attachments)))))

(ert-deftest pichat-chat-actions-suffix-captures-origin-not-selected-buffer ()
  (pichat-test-chat-actions--with-chat
    (pichat-chat-actions)
    (let ((command (lookup-key transient--transient-map (kbd "D"))) called)
      (should (commandp command))
      (pichat-test-chat-actions--exit)
      (cl-letf (((symbol-function 'pichat-show-diagnostics)
                 (lambda () (interactive) (setq called (current-buffer)))))
        (with-temp-buffer (call-interactively command))
        (should (eq called chat))))))

(ert-deftest pichat-chat-actions-compose-from-another-buffer-returns-to-owner ()
  (pichat-test-chat-actions--with-chat
    (let ((scope (pichat-chat-actions--capture))
          (other (generate-new-buffer " *actions-other*")) compose)
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer other)
            (pichat-chat-actions--invoke scope #'pichat-chat-open-compose-buffer)
            (setq compose (current-buffer))
            (should (derived-mode-p 'pichat-chat-compose-mode))
            (pichat-chat-compose-cancel)
            (should (eq (window-buffer (selected-window)) chat)))
        (when (buffer-live-p compose) (kill-buffer compose))
        (kill-buffer other)))))

(ert-deftest pichat-chat-actions-rejects-source-process-and-owner-changes ()
  (dolist (mutation '(generation id file process owner buffer-owner))
    (pichat-test-chat-actions--with-chat
      (let ((scope (pichat-chat-actions--capture)) called)
        (pcase mutation
          ('generation (cl-incf pichat-chat--source-generation))
          ('id (setf (pichat-session-id session) "other"))
          ('file (setf (pichat-session-session-file session) "/other.jsonl"))
          ('process (setf (pichat-session-process-generation session) 'replacement))
          ('owner (setq-local pichat-chat-session (pichat-session-make)))
          ('buffer-owner (setf (pichat-session-buffer session) nil)))
        (should-error
         (pichat-chat-actions--invoke scope (lambda () (interactive) (setq called t)))
         :type 'user-error)
        (should-not called)))))

(ert-deftest pichat-chat-actions-rejects-away-and-back-and-dead-chat ()
  (pichat-test-chat-actions--with-chat
    (let ((scope (pichat-chat-actions--capture)))
      (pichat-chat--reset-for-source "other" "/other.jsonl" t)
      (pichat-chat--reset-for-source
       (plist-get scope :id) (plist-get scope :file) t)
      (should-error (pichat-chat-actions--buffer scope) :type 'user-error)
      (setq scope (pichat-chat-actions--capture))
      (kill-buffer chat)
      (should-error (pichat-chat-actions--buffer scope) :type 'user-error))))

(ert-deftest pichat-chat-actions-compose-works-in-stopped-chat-without-sending ()
  (pichat-test-chat-actions--with-chat
    (delete-process proc)
    (setf (pichat-session-process session) nil
          (pichat-session-state session) 'stopped)
    (pichat-chat--set-input-text "draft in stopped runtime")
    (let ((seq (pichat-session-rpc-seq session)) compose)
      (unwind-protect
          (progn
            (pichat-chat-actions)
            (let ((command (lookup-key transient--transient-map (kbd "c"))))
              (pichat-test-chat-actions--exit)
              (call-interactively command))
            (setq compose (current-buffer))
            (should (derived-mode-p 'pichat-chat-compose-mode))
            (should (equal (buffer-string) "draft in stopped runtime"))
            (should (equal seq (pichat-session-rpc-seq session)))
            (should (equal (pichat-chat-draft-text
                            (pichat-chat-draft-capture chat))
                           "draft in stopped runtime")))
        (when (and (buffer-live-p compose) (not (eq compose chat)))
          (kill-buffer compose))))))

(ert-deftest pichat-chat-actions-export-matches-direct-canonical-export ()
  (pichat-test-chat-actions--with-chat
    (setq pichat-chat--canonical-transcript
          (pichat-transcript-create
           :nodes (list (pichat-transcript-node-create
                         :kind 'message :key "u1" :role 'user
                         :content (list (pichat-transcript-content-create
                                         :kind 'prose :text "canonical, not display"))))))
    (let (direct exported)
      (unwind-protect
          (save-window-excursion
            (pichat-chat-export-transcript-to-markdown)
            (setq exported (current-buffer) direct (buffer-string))
            (set-buffer chat)
            (pichat-chat-actions)
            (let ((command (lookup-key transient--transient-map (kbd "e"))))
              (pichat-test-chat-actions--exit)
              (call-interactively command))
            (should (equal direct (buffer-string)))
            (should (string-match-p "canonical, not display" (buffer-string))))
        (when (buffer-live-p exported) (kill-buffer exported))))))

(ert-deftest pichat-chat-actions-preserves-command-validation ()
  (pichat-test-chat-actions--with-chat
    ;; No canonical transcript: both direct and menu export must fail rather
    ;; than scraping visible text or issuing RPC to manufacture an export.
    (should-error (pichat-chat-export-transcript-to-markdown) :type 'user-error)
    (pichat-chat-actions)
    (let ((command (lookup-key transient--transient-map (kbd "e"))))
      (pichat-test-chat-actions--exit)
      (should-error (call-interactively command) :type 'user-error))))

(ert-deftest pichat-chat-actions-adapts-to-narrow-frame ()
  (pichat-test-chat-actions--with-chat
    (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) 42)))
      (pichat-chat-actions)
      (with-current-buffer (get-buffer transient--buffer-name)
        (should transient-force-single-column)
        (should pichat-transient--no-wrap)
        (should (string-match-p "Compose draft" (buffer-string))))
      (pichat-test-chat-actions--exit))))

(provide 'pichat-test-chat-actions)
;;; pichat-test-chat-actions.el ends here
