;;; pichat-test-bookmarks-integration.el --- Offline Pi bookmark workflow -*- lexical-binding: t; -*-

;;; Code:

(require 'bookmark)
(require 'pichat-test-support)
(require 'pichat-sessions)

(defun pichat-test-bookmark--write-branches (file project)
  "Write a saved Pi session FILE with two branches in PROJECT."
  (let ((stamp "2026-07-25T16:00:00.000Z"))
    (with-temp-file file
      (insert (json-serialize
               (list :type "session" :version 3 :id "bookmark-fixture"
                     :timestamp stamp :cwd project)) "\n")
      (dolist (row '(("root" nil "Root prompt")
                     ("alternate" "root" "Inactive prompt")
                     ("active" "root" "Active prompt")))
        (pcase-let ((`(,id ,parent ,text) row))
          (insert (json-serialize
                   (list :type "message" :id id :parentId parent :timestamp stamp
                         :message (list :role "user" :timestamp 1784995200000
                                        :content (vector (list :type "text" :text text)))))
                  "\n"))))))

(defun pichat-test-bookmark--command (action name)
  "Perform bookmark ACTION for NAME, using ordinary keys in a live frame."
  (if noninteractive
      (funcall (if (eq action 'set) #'bookmark-set #'bookmark-jump) name)
    (execute-kbd-macro
     (vconcat (kbd (if (eq action 'set) "C-x r m" "C-x r b"))
              name (kbd "RET")))))

(defun pichat-test-bookmark--leaf (session)
  "Return the active leaf reported by Pi for SESSION."
  (plist-get (plist-get (pichat-test-rpc-call session "get_tree") :data) :leafId))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-bookmark-persist-reopen-and-reuse ()
    (pichat-test-with-integration-session (origin :script '(:turns []))
      (let* ((file (expand-file-name "branched.jsonl" session-dir))
             (bookmark-default-file (expand-file-name "bookmarks" project-dir))
             (bookmark-save-flag nil)
             (bookmark-alist nil)
             (bookmark-alist-modification-count 0)
             (bookmark-bookmarks-timestamp nil)
             (bookmark-current-bookmark nil)
             (bookmark-history nil)
             (pichat-chat-render-markdown nil)
             (pichat-chat-stop-session-on-kill nil)
             origin-chat reopened)
        (pichat-test-bookmark--write-branches file project-dir)
        (save-window-excursion
          (unwind-protect
              (progn
                (should (plist-get (pichat-test-rpc-call
                                    origin "switch_session" (list :sessionPath file))
                                   :success))
                (pichat-test-rpc-call origin "get_state")
                (setq origin-chat (pichat-chat-ensure origin t))
                (pichat-test-wait-for-buffer-contains origin-chat "Active prompt")
                (switch-to-buffer origin-chat)
                (pichat-test-bookmark--command 'set "Conversation")
                (let (history failure)
                  (pichat-sessions-list origin "alternate"
                                        (lambda (buffer error) (setq history buffer failure error)))
                  (pichat-test-wait-until (lambda () (or history failure))
                                          nil "alternate history row selected")
                  (should-not failure)
                  (switch-to-buffer history)
                  (should (equal "alternate" (pichat-sessions--entry-id-at-point))))
                (pichat-test-bookmark--command 'set "Alternate")
                (bookmark-save)
                (kill-buffer (current-buffer))
                (kill-buffer origin-chat)
                (pichat-stop-session origin)
                (pichat-test-wait-until (lambda () (not (pichat-session-alive-p origin)))
                                        nil "bookmark origin stopped")
                (pichat-forget-session origin)
                (setq bookmark-alist nil)
                (bookmark-load bookmark-default-file t)
                ;; Jump from outside the originating project and buffers.
                (switch-to-buffer (get-buffer-create " *Bookmark jump origin*"))
                (setq default-directory session-dir)
                (pichat-test-bookmark--command 'jump "Conversation")
                (should (derived-mode-p 'pichat-chat-mode))
                (setq reopened pichat-chat-session)
                (should (pichat-session-alive-p reopened))
                (should-not (eq reopened origin))
                (should (equal "bookmark-fixture" (pichat-session-id reopened)))
                (should (equal file (pichat-session-session-file reopened)))
                (should (equal (directory-file-name project-dir)
                               (directory-file-name (pichat-session-cwd reopened))))
                (should-not (pichat-session-default-p reopened))
                (should (string-search "Active prompt" (pichat-test-buffer-text (current-buffer))))
                (should-not (string-search "Inactive prompt" (pichat-test-buffer-text (current-buffer))))
                (let ((process (pichat-session-process reopened))
                      (leaf (pichat-test-bookmark--leaf reopened)))
                  (should (stringp leaf))
                  (should-not (equal "alternate" leaf))
                  (pichat-test-bookmark--command 'jump "Alternate")
                  (should (derived-mode-p 'pichat-sessions-mode))
                  (should (equal "alternate" (pichat-sessions--entry-id-at-point)))
                  (should (equal (list reopened) (pichat-session-list)))
                  (should (eq process (pichat-session-process reopened)))
                  (should (equal leaf (pichat-test-bookmark--leaf reopened)))))
            (dolist (buffer (list origin-chat (get-buffer "*PiChat Session History*")
                                  (get-buffer " *Bookmark jump origin*")))
              (when (buffer-live-p buffer) (kill-buffer buffer)))
            (dolist (runtime (pichat-session-list))
              (let ((process (pichat-session-process runtime))
                    (chat (pichat-session-buffer runtime)))
                (when (buffer-live-p chat) (kill-buffer chat))
                (ignore-errors (pichat-rpc-stop runtime))
                (when (process-live-p process) (delete-process process))
                (when (and process (buffer-live-p (process-buffer process)))
                  (kill-buffer (process-buffer process)))))))))))

(provide 'pichat-test-bookmarks-integration)
;;; pichat-test-bookmarks-integration.el ends here
