;;; pichat-test-queue-live-ui.el --- Opt-in terminal queue checks -*- lexical-binding: t; -*-

;; Load only in a private non-batch Emacs; not part of the ordinary runner.
(require 'pichat-test-support)

;; Fixture bindings unwind before the runner's `kill-emacs'.
(setq transient-save-history nil)

(ert-deftest pichat-integration-queue-live-ui-hold-recall-and-native-queue ()
  (should-not noninteractive)
  (should (frame-live-p (selected-frame)))
  (pichat-test-with-integration-session
      (session :settings '(:compaction (:reserveTokens 1000 :keepRecentTokens 100))
               :script '(:turns [(:text "history one") (:text "history two")
                                 (:text "summary" :delayMs 2000)
                                 (:text "delivered" :delayMs 2500)]))
    (pichat-test-prompt-and-wait session (make-string 2000 ?a))
    (pichat-test-prompt-and-wait session (make-string 2000 ?b))
    (let* ((pichat-chat-stop-session-on-kill nil)
           (buffer (pichat-chat-open session))
           (starts (pichat-test-count-raw-events session "agent_start"))
           (settled (pichat-test-count-raw-events session "agent_settled"))
           (image '(:id "terminal-image" :type "image" :mimeType "image/png"
                    :name "terminal.png" :bytes 68
                    :data "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")))
      (unwind-protect
          (progn
            (switch-to-buffer buffer)
            (delete-other-windows)
            (when (bound-and-true-p evil-mode)
              (evil-local-mode 1)
              ;; Enter through the command loop, including deferred Evil setup.
              (execute-kbd-macro (kbd "<escape> i")))
            (execute-kbd-macro (kbd "C-c C-o"))
            (pichat-test-wait-for-raw-event session "compaction_start")
            (execute-kbd-macro "deliver")
            (execute-kbd-macro (kbd "RET"))
            (execute-kbd-macro "recall me")
            (setq pichat-chat--pending-attachments (list image))
            (execute-kbd-macro (kbd "M-RET"))
            (should (= 2 (length pichat-chat--held-submissions)))
            (redisplay t)
            (should (string-match-p "2 held · steering · recall me \\[1 img\\]" (buffer-string)))
            (execute-kbd-macro (kbd "C-c C-y"))
            (should (equal "recall me" (pichat-chat--input-text)))
            (should (equal (list image) pichat-chat--pending-attachments))
            ;; Submit it again, then delete that held item through its keymap.
            (execute-kbd-macro (kbd "M-RET"))
            (goto-char (point-min)) (search-forward "2 held")
            (when (bound-and-true-p evil-mode) (evil-normal-state))
            (execute-kbd-macro "d")
            (should (= 1 (length pichat-chat--held-submissions)))
            (goto-char (point-min)) (search-forward "1 held")
            (execute-kbd-macro (kbd "RET"))
            (should (equal "deliver" (pichat-chat--input-text)))
            (when (bound-and-true-p evil-mode) (evil-insert-state))
            (execute-kbd-macro (kbd "RET"))
            (pichat-test-wait-for-raw-event session "agent_start" 10 starts)
            (goto-char (point-max))
            (execute-kbd-macro "queued follow")
            (setq pichat-chat--pending-attachments (list image))
            (execute-kbd-macro (kbd "RET"))
            (execute-kbd-macro "queued steer")
            (execute-kbd-macro (kbd "M-RET"))
            (pichat-test-wait-until (lambda () (= 2 (length pichat-chat--pi-queue))) 5)
            (redisplay t)
            (should (string-match-p "1 queued in Pi · steering · queued steer" (buffer-string)))
            (should (string-match-p "2 queued in Pi · follow-up · queued follow \\[1 img\\]" (buffer-string)))
            (goto-char (point-min)) (search-forward "1 queued in Pi")
            (should (get-text-property (point) 'read-only))
            (should (< (point) pichat-chat--prompt-start))
            (when (bound-and-true-p evil-mode) (evil-normal-state))
            (execute-kbd-macro (kbd "RET"))
            (pichat-test-wait-until
             (lambda () (equal "queued steer\n\nqueued follow" (pichat-chat--input-text))) 5)
            (should (equal (list image) pichat-chat--pending-attachments))
            (should-not pichat-chat--pi-queue)
            (should-not (string-match-p "queued in Pi" (buffer-string)))
            (pichat-test-wait-for-raw-event session "agent_settled" 10 settled)
            (let ((texts (mapcar #'pichat-render-message-text
                                 (pichat-test-compaction-users session))))
              (should (= 1 (cl-count "deliver" texts :test #'equal)))
              (should-not (member "recall me [image]" texts))
              (should-not (member "queued steer" texts))
              (should-not (member "queued follow [image]" texts))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-queue-live-ui)
;;; pichat-test-queue-live-ui.el ends here
