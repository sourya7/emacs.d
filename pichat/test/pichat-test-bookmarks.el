;;; pichat-test-bookmarks.el --- Durable bookmark capture tests -*- lexical-binding: t; -*-

;;; Code:

(require 'bookmark)
(require 'pichat-test-history-support)
(require 'pichat-chat)
(require 'pichat-bookmark)

(defun pichat-test-bookmark--write-session (file id cwd)
  "Write a minimal saved session header to FILE for ID and CWD."
  (with-temp-file file
    (insert (json-serialize (list :type "session" :version 3 :id id :cwd cwd))
            "\n")))

(defmacro pichat-test-bookmark--with-store (&rest body)
  "Run BODY with isolated saved sessions and an ordinary Emacs bookmark store."
  (declare (indent 0))
  `(let* ((root (make-temp-file "pichat-bookmarks-" t))
          (bookmark-default-file (expand-file-name "bookmarks" root))
          (bookmark-alist nil)
          (bookmark-alist-modification-count 0)
          (bookmark-bookmarks-timestamp nil)
          (bookmark-current-bookmark nil)
          (bookmark-save-flag nil)
          (bookmark-history nil)
          (pichat-path-mappings nil)
          (pichat-chat-stop-session-on-kill nil))
     (unwind-protect (progn ,@body)
       (delete-directory root t))))

(ert-deftest pichat-bookmark-chat-record-survives-source-rebinding-and-reload ()
  (pichat-test-bookmark--with-store
    (let* ((cwd (expand-file-name "my-project" root))
           (file (expand-file-name "a.jsonl" root))
           (session (pichat-session-make :id "12345678-source" :session-file file
                                         :runtime-id "ephemeral-runtime-number"
                                         :cwd root :owner-directory root)))
      (pichat-test-bookmark--write-session file "12345678-source" cwd)
      (with-temp-buffer
        (pichat-chat-mode)
        (setq pichat-chat-session session)
        (setf (pichat-session-buffer session) (current-buffer))
        (pichat-chat--refresh-source-identity session)
        (let ((pichat-chat--inhibit-edit-guard t))
          (insert (propertize "private draft" 'pichat-node-key "not-an-entry")))
        (should (string-match-p "my-project.*12345678" (car (bookmark-make-record))))
        (bookmark-set "Conversation")
        (pichat-chat--on-session-rebinding session 'session-rebinding nil)
        (setf (pichat-session-id session) "replacement"
              (pichat-session-session-file session) (expand-file-name "b.jsonl" root))
        (should-error (bookmark-set "Transitional chat") :type 'user-error))
      (bookmark-save)
      (setq bookmark-alist nil)
      (bookmark-load bookmark-default-file t)
      (let ((record (bookmark-get-bookmark "Conversation")))
        (should (eq 'pichat-bookmark-jump (bookmark-get-handler record)))
        (should (eql 1 (bookmark-prop-get record 'pichat-version)))
        (should (equal file (bookmark-get-filename record)))
        (should (equal "12345678-source" (bookmark-prop-get record 'pichat-session-id)))
        (should (equal cwd (bookmark-prop-get record 'pichat-runtime-cwd)))
        (should (equal cwd (bookmark-prop-get record 'pichat-host-cwd)))
        (should-not (bookmark-prop-get record 'pichat-entry-id))
        (should-not (bookmark-get-position record))
        (dolist (needle '("ephemeral-runtime-number" "private draft" "replacement"))
          (should-not (string-search needle (prin1-to-string record))))))))

(ert-deftest pichat-bookmark-history-captures-exact-inactive-row-not-old-tree ()
  (pichat-test-bookmark--with-store
    (let* ((file (expand-file-name "saved.jsonl" root))
           (session (pichat-session-make :id "saved" :session-file file))
           (replacement (pichat-session-make :id "different" :session-file file)))
      (pichat-test-bookmark--write-session file "saved" root)
      (pichat-test-with-history (session (pichat-test-sessions-preview--response))
        (pichat-sessions--goto-id "alternate-leaf")
        (bookmark-set "Alternate branch")
        (goto-char (point-min))
        ;; A header isn't the last selected row.
        (should-error (bookmark-set "Header") :type 'user-error)
        (pichat-sessions--goto-id "alternate-leaf")
        ;; A new request owns the view before its tree replaces the old rows.
        (pichat-sessions--install-request-owner replacement (current-buffer))
        (should-error (bookmark-set "Pending history") :type 'user-error)
        (pichat-sessions--refresh-from-response
         (pichat-test-sessions-preview--response) replacement (current-buffer))
        (pichat-sessions--on-session-rebinding replacement 'session-rebinding nil)
        (should-error (bookmark-set "Stale history") :type 'user-error))
      (bookmark-save)
      (setq bookmark-alist nil)
      (bookmark-load bookmark-default-file t)
      (should (equal "alternate-leaf"
                     (bookmark-prop-get "Alternate branch" 'pichat-entry-id)))
      (should (equal "saved"
                     (bookmark-prop-get "Alternate branch" 'pichat-session-id))))))

(ert-deftest pichat-bookmark-capture-rejects-unsaved-or-wrong-sources ()
  (pichat-test-bookmark--with-store
    (let* ((file (expand-file-name "unwritten.jsonl" root))
           (session (pichat-session-make :id "source" :session-file file)))
      (should-error (pichat-bookmark-make-record session) :type 'user-error)
      (pichat-test-bookmark--write-session file "other-source" root)
      (should-error (pichat-bookmark-make-record session) :type 'user-error)
      (pichat-test-bookmark--write-session file "source" root)
      (should (pichat-bookmark-make-record session))
      (setf (pichat-session-persistence session) 'ephemeral)
      (should-error (pichat-bookmark-make-record session) :type 'user-error)
      (setf (pichat-session-persistence session) 'persistent
            (pichat-session-backend session) 'unsupported)
      (should-error (pichat-bookmark-make-record session) :type 'user-error))))

(ert-deftest pichat-bookmark-capture-keeps-mapped-project-and-file-provenance ()
  (pichat-test-bookmark--with-store
    (let* ((pichat-path-mappings (list (cons root "/runtime")))
           (file (expand-file-name "saved.jsonl" root))
           (session (pichat-session-make :id "saved" :session-file "/runtime/saved.jsonl")))
      (pichat-test-bookmark--write-session file "saved" "/runtime/project")
      (let ((record (pichat-bookmark-make-record session)))
        (should (equal (bookmark-get-filename record) file))
        (should (equal (bookmark-prop-get record 'pichat-runtime-file) "/runtime/saved.jsonl"))
        (should (equal (bookmark-prop-get record 'pichat-runtime-cwd) "/runtime/project"))
        (should (equal (bookmark-prop-get record 'pichat-host-cwd)
                       (expand-file-name "project" root)))))))

(provide 'pichat-test-bookmarks)
;;; pichat-test-bookmarks.el ends here
