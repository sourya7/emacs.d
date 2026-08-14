;;; pichat-test-chat-input.el --- Pichat Test Chat Input -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-chat-input-restores-fork-text-with-callback-time-conflicts ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (attachment '(:id "pending" :name "pending.png" :bytes 1))
          (in-flight '(:id "sending" :name "sending.png" :bytes 1))
          (recoverable (list :text "recoverable" :attachments nil))
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setq pichat-chat--pending-attachments (list attachment)
                    pichat-chat--recoverable-submissions (list recoverable))
              (puthash "request" (list in-flight)
                       pichat-chat--in-flight-attachments)
              (should (eq 'inserted
                          (pichat-chat-input-restore-fork-text "fork prompt")))
              (should (equal "fork prompt" (pichat-chat--input-text)))
              (should (equal (list attachment)
                             pichat-chat--pending-attachments))
              (should (equal (list in-flight)
                             (gethash "request"
                                      pichat-chat--in-flight-attachments)))
              (should (equal (list recoverable)
                             pichat-chat--recoverable-submissions))
              ;; This edit occurs after a hypothetical fork request was sent;
              ;; the helper must inspect it at callback time.
              (pichat-chat--set-input-text "typed while fork was pending")
              (cl-letf (((symbol-function 'yes-or-no-p)
                         (lambda (&rest _args) t)))
                (should (eq 'replaced
                            (pichat-chat-input-restore-fork-text
                             "replacement prompt"))))
              (should (equal "replacement prompt" (pichat-chat--input-text)))
              (pichat-chat--set-input-text "keep current draft")
              (let ((kill-ring nil))
                (cl-letf (((symbol-function 'yes-or-no-p)
                           (lambda (&rest _args) nil)))
                  (should (eq 'copied
                              (pichat-chat-input-restore-fork-text
                               "copied fork prompt"))))
                (should (equal "keep current draft"
                               (pichat-chat--input-text)))
                (should (equal "copied fork prompt" (current-kill 0))))
              (should (equal (list attachment)
                             pichat-chat--pending-attachments))
              (should (equal (list in-flight)
                             (gethash "request"
                                      pichat-chat--in-flight-attachments)))
              (should (equal (list recoverable)
                             pichat-chat--recoverable-submissions))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-accepted-extension-command-restores-prompt ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer success-callback)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (_session _message &optional _images _behavior
                                success _error)
                         (setq success-callback success)
                         "extension-command")))
              (with-current-buffer buffer
                (setq pichat-chat-completion--status 'ready
                      pichat-chat-completion--commands
                      '((:name "codex-status" :source "extension")))
                (goto-char (point-max))
                ;; Classification must use the trimmed wire message, not the
                ;; raw editor text, and survive later cache invalidation.
                (insert "  /codex-status  ")
                (pichat-chat-send-input)
                (should-not (pichat-chat--prompt-live-p))
                (setq pichat-chat-completion--status 'loading
                      pichat-chat-completion--commands nil)))
            (funcall success-callback
                     '(:id "extension-command" :success t) session)
            (with-current-buffer buffer
              (should (pichat-chat--prompt-live-p))
              (should (string-empty-p (pichat-chat--input-text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-rejected-submission-restores-unchanged-empty-editor ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer error-callback)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (_session _message &optional _images _behavior
                                _success error)
                         (setq error-callback error)
                         "request-rejected")))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "restore this exact draft")
                (pichat-chat-send-input)))
            (funcall error-callback
                     '(:id "request-rejected" :success nil
                       :error "explicit rejection")
                     session)
            (with-current-buffer buffer
              (should (equal "restore this exact draft"
                             (pichat-chat--input-text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-recovery-chooses-among-drafts-and-can-discard ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setq pichat-chat--recoverable-submissions
                    (list (list :text "newest failed draft")
                          (list :text "older chosen draft")))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest _args)
                           (car (rassoc (cadr pichat-chat--recoverable-submissions)
                                       choices)))))
                (pichat-chat-recover-submission))
              (should (equal "older chosen draft" (pichat-chat--input-text)))
              (should (= 1 (length pichat-chat--recoverable-submissions)))
              (pichat-chat--clear-input)
              (pichat-chat-discard-recoverable-submissions)
              (should-not pichat-chat--recoverable-submissions)
              (should (eq #'pichat-chat-recover-submission
                          (lookup-key pichat-chat-mode-map
                                      (kbd "C-c C-y"))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-programmatic-replacement-blocks-stale-rejection-restore ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer error-callback)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (_session _message &optional _images _behavior
                                _success error)
                         (setq error-callback error)
                         "stale-rejection")))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "old submission")
                (pichat-chat-send-input)
                (pichat-chat--set-input-text "programmatic replacement")
                (pichat-chat--set-input-text "")))
            (funcall error-callback
                     '(:id "stale-rejection" :success nil
                       :error "rejected") session)
            (with-current-buffer buffer
              (should (string-empty-p (pichat-chat--input-text)))
              (should (= 1 (length
                            pichat-chat--recoverable-submissions)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-timeout-preserves-manual-recovery-without-auto-restore ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer error-callback)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (_session _message &optional _images _behavior
                                _success error)
                         (setq error-callback error)
                         "request-timeout")))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "recover only on command")
                (pichat-chat-send-input)))
            (funcall error-callback
                     '(:id "request-timeout" :success nil
                       :pichat-failure-kind timeout :error "timed out")
                     session)
            (with-current-buffer buffer
              (should (string-empty-p (pichat-chat--input-text)))
              (should (= 1 (length pichat-chat--recoverable-submissions)))
              (pichat-chat-recover-submission)
              (should (equal "recover only on command"
                             (pichat-chat--input-text)))
              (should-not pichat-chat--recoverable-submissions)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-prompt-history-restores-submissions-and-current-draft ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-prompt)
                       (lambda (&rest _args) "accepted")))
              (with-current-buffer buffer
                (insert "first prompt")
                (pichat-chat-send-input)
                (pichat-chat--insert-prompt)
                (insert "second prompt")
                (pichat-chat-send-input)
                (pichat-chat--insert-prompt)
                (insert "current draft")
                (pichat-chat-history-previous)
                (should (equal "second prompt" (pichat-chat--input-text)))
                (pichat-chat-history-previous)
                (should (equal "first prompt" (pichat-chat--input-text)))
                (pichat-chat-history-next)
                (should (equal "second prompt" (pichat-chat--input-text)))
                (pichat-chat-history-next)
                (should (equal "current draft" (pichat-chat--input-text)))
                (should (equal '("second prompt" "first prompt")
                               pichat-chat--prompt-history))
                (let ((text (buffer-substring-no-properties
                             (point-min) (point-max))))
                  (should-not (string-match-p "first prompt" text))
                  (should-not (string-match-p "second prompt" text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-attachments-enforce-type-byte-count-and-total-limits ()
  (pichat-test-with-temp-dir dir
    (let ((png (expand-file-name "one.png" dir))
          (txt (expand-file-name "not-image.txt" dir))
          (pichat-attachments-max-file-bytes 4)
          (pichat-attachments-max-total-bytes 6)
          (pichat-attachments-max-count 2))
      (with-temp-file png (insert "12345"))
      (with-temp-file txt (insert "x"))
      (should-error (pichat-attachments-read-image-file txt) :type 'user-error)
      (should-error (pichat-attachments-read-image-file png) :type 'user-error)
      (let ((first '(:id "one" :name "one.png" :bytes 3))
            (second '(:id "two" :name "two.png" :bytes 3))
            (third '(:id "three" :name "three.png" :bytes 1)))
        (should (= 2 (length (pichat-attachments-validate-set
                              (list first second)))))
        (should-error (pichat-attachments-validate-set
                       (list first second third))
                      :type 'user-error))
      (let ((small-one (expand-file-name "small-one.png" dir))
            (small-two (expand-file-name "small-two.png" dir))
            (pichat-attachments-max-file-bytes 10)
            (pichat-attachments-max-total-bytes 10)
            (pichat-attachments-max-count 1))
        (with-temp-file small-one (insert "1"))
        (with-temp-file small-two (insert "2"))
        (let ((retained (pichat-attachments-read-image-file small-one)))
          (should-error
           (pichat-attachments-read-image-file small-two (list retained))
           :type 'user-error))))))

(ert-deftest pichat-chat-attachments-select-removal-and-compact-presentation ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (one (expand-file-name "one.png" dir))
            (two (expand-file-name "two.jpg" dir))
            buffer)
        (with-temp-file one (insert "one"))
        (with-temp-file two (insert "two"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file one)
                (pichat-chat-attach-image-file two)
                (let ((status (cdr (assq 'attachments
                                         pichat-chat--status-lines))))
                  (should (string-match-p "2 pending" status))
                  (should (string-match-p "one.png" status))
                  (should-not (string-match-p
                               (regexp-quote
                                (plist-get
                                 (car pichat-chat--pending-attachments) :data))
                               (buffer-substring-no-properties
                                (point-min) (point-max)))))
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (_prompt choices &rest _args)
                             (caar choices))))
                  (pichat-chat-remove-attachment))
                (should (equal '("two.jpg")
                               (mapcar (lambda (attachment)
                                         (plist-get attachment :name))
                                       pichat-chat--pending-attachments)))
                (should (eq #'pichat-chat-remove-attachment
                            (lookup-key pichat-chat-mode-map
                                        (kbd "C-c C-q"))))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-attachments-remain-in-flight-until-success ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (path (expand-file-name "sent.png" dir))
            buffer success-callback captured-images)
        (with-temp-file path (insert "image bytes"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file path)
                (insert "describe")
                (cl-letf (((symbol-function 'pichat-rpc-prompt)
                           (lambda (_session _message images _behavior success _error)
                             (setq captured-images images
                                   success-callback success)
                             "image-success")))
                  (pichat-chat-send-input))
                (should-not pichat-chat--pending-attachments)
                (should (= 1 (length
                              (gethash "image-success"
                                       pichat-chat--in-flight-attachments))))
                (should (string-match-p
                         "1 sending"
                         (cdr (assq 'attachments pichat-chat--status-lines))))
                (should (vectorp captured-images))
                (should-not (plist-member (aref captured-images 0) :name)))
              (funcall success-callback '(:id "image-success" :success t) session)
              (with-current-buffer buffer
                (should (zerop (hash-table-count
                                pichat-chat--in-flight-attachments)))
                (should-not (assq 'attachments pichat-chat--status-lines))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-rejected-attachments-restore-exactly-once ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (path (expand-file-name "retry.png" dir))
            buffer error-callback submitted)
        (with-temp-file path (insert "retry bytes"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file path)
                (setq submitted (car pichat-chat--pending-attachments))
                (insert "retry me")
                (cl-letf (((symbol-function 'pichat-rpc-prompt)
                           (lambda (_session _message _images _behavior _success error)
                             (setq error-callback error)
                             "image-rejected")))
                  (pichat-chat-send-input))
                ;; Simulate the same identity already being visible pending;
                ;; rejection must merge rather than duplicate it.
                (setq pichat-chat--pending-attachments (list submitted)))
              (funcall error-callback
                       '(:id "image-rejected" :success nil :error "rejected")
                       session)
              (with-current-buffer buffer
                (should (equal "retry me" (pichat-chat--input-text)))
                (should (= 1 (length pichat-chat--pending-attachments)))
                (should-not pichat-chat--recoverable-submissions)
                (should (zerop (hash-table-count
                                pichat-chat--in-flight-attachments)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-ambiguous-failure-keeps-new-and-recoverable-images-separate ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (old (expand-file-name "old.png" dir))
            (new (expand-file-name "new.png" dir))
            buffer error-callback)
        (with-temp-file old (insert "old"))
        (with-temp-file new (insert "new"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file old)
                (insert "ambiguous")
                (cl-letf (((symbol-function 'pichat-rpc-prompt)
                           (lambda (_session _message _images _behavior _success error)
                             (setq error-callback error)
                             "image-timeout")))
                  (pichat-chat-send-input))
                (pichat-chat-attach-image-file new))
              (funcall error-callback
                       '(:id "image-timeout" :success nil
                         :pichat-failure-kind timeout :error "timed out")
                       session)
              (with-current-buffer buffer
                (should (equal '("new.png")
                               (mapcar (lambda (attachment)
                                         (plist-get attachment :name))
                                       pichat-chat--pending-attachments)))
                (should (= 1 (length pichat-chat--recoverable-submissions)))
                (should (zerop (hash-table-count
                                pichat-chat--in-flight-attachments)))
                (pichat-chat-clear-attachments)
                (pichat-chat-recover-submission)
                (should (equal "ambiguous" (pichat-chat--input-text)))
                (should (equal '("old.png")
                               (mapcar (lambda (attachment)
                                         (plist-get attachment :name))
                                       pichat-chat--pending-attachments)))
                (should-not pichat-chat--recoverable-submissions)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-source-rebind-retains-in-flight-images-for-recovery ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (path (expand-file-name "rebind.png" dir))
            buffer success-callback)
        (with-temp-file path (insert "rebind"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file path)
                (insert "before rebind")
                (cl-letf (((symbol-function 'pichat-rpc-prompt)
                           (lambda (_session _message _images _behavior success _error)
                             (setq success-callback success)
                             "rebind-request")))
                  (pichat-chat-send-input))
                (pichat-chat--reset-for-source "new-source" nil t)
                (should (zerop (hash-table-count
                                pichat-chat--in-flight-attachments)))
                (should (= 1 (length pichat-chat--recoverable-submissions)))
                (should (= 1 (length
                              (plist-get
                               (car pichat-chat--recoverable-submissions)
                               :attachments)))))
              ;; A callback from the abandoned request cannot erase the
              ;; source-transition recovery record.
              (funcall success-callback
                       '(:id "rebind-request" :success t) session)
              (with-current-buffer buffer
                (should (= 1 (length pichat-chat--recoverable-submissions)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-image-only-submission-obeys-policy ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (let ((pichat-chat-stop-session-on-kill nil)
            (path (expand-file-name "only.png" dir))
            buffer captured-message captured-images)
        (with-temp-file path (insert "only"))
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat-attach-image-file path)
                (let ((pichat-attachments-allow-image-only-prompts nil))
                  (should-error (pichat-chat-send-input) :type 'user-error))
                (should (= 1 (length pichat-chat--pending-attachments)))
                (let ((pichat-attachments-allow-image-only-prompts t))
                  (cl-letf (((symbol-function 'pichat-rpc-prompt)
                             (lambda (_session message images &rest _args)
                               (setq captured-message message
                                     captured-images images)
                               "image-only")))
                    (pichat-chat-send-input)))
                (should (equal "" captured-message))
                (should (= 1 (length captured-images)))
                (should-not pichat-chat--prompt-history)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-attachments-clipboard-and-screenshot-adapters-remain-bounded ()
  (let ((pichat-attachments-clipboard-image-handlers
         '((:command "fake-clipboard" :arguments nil :output stdout)))
        (pichat-attachments-screenshot-command '("fake-screenshot"))
        (pichat-attachments-max-file-bytes 20))
    (cl-letf (((symbol-function 'executable-find) (lambda (_command) t))
              ((symbol-function 'call-process)
               (lambda (command &optional _in destination _display &rest args)
                 (cond
                  ((equal command "fake-clipboard")
                   (ignore destination)
                   (insert "clipboard"))
                  ((equal command "fake-screenshot")
                   (with-temp-file (car (last args)) (insert "screenshot"))))
                 0)))
      (let ((clipboard (pichat-attachments-read-clipboard nil))
            (screenshot (pichat-attachments-capture-screenshot nil)))
        (should (equal "image/png" (plist-get clipboard :mimeType)))
        (should (= 9 (plist-get clipboard :bytes)))
        (should (equal "image/png" (plist-get screenshot :mimeType)))
        (should (= 10 (plist-get screenshot :bytes)))))))

(provide 'pichat-test-chat-input)
;;; pichat-test-chat-input.el ends here
