;;; pichat-test-reference.el --- Reference destination freshness tests -*- lexical-binding: t; -*-

;;; Code:
(require 'pichat-test-support)
(require 'pichat-test-chat-support)
(require 'pichat-reference)

(defun pichat-test-reference--draft-state ()
  "Return the current chat's draft and related editor state."
  (list (pichat-chat--input-text) pichat-chat--editor-generation
        pichat-chat--pending-attachments pichat-chat--recoverable-submissions))

(defun pichat-test-reference--collect-scenario (mutate &optional valid)
  "MUTATE the destination during file collection; insert only when VALID."
  (pichat-test-with-temp-dir dir
    (let ((file (expand-file-name "selected.el" dir)))
      (with-temp-file file (insert "source\n"))
      (pichat-test-with-unit-session (session proc)
        (setf (pichat-session-id session) "original"
              (pichat-session-session-file session) "/sessions/original.jsonl"
              (pichat-session-path-context session)
              (pichat-transport-path-context
               pichat-transport-local (list (cons dir "/workspace"))))
        (pichat-test-with-chat-buffer (chat session)
          (pichat-chat--set-input-text
           "keep draft\n\nReferences:\n- `/workspace/existing.el`\n\n")
          (setq pichat-chat--pending-attachments '((:id "keep-image"))
                pichat-chat--recoverable-submissions '((:text "recover me")))
          (let (baseline collected displayed)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _)
                         (setq collected t)
                         (funcall mutate session chat)
                         (when (buffer-live-p chat)
                           (with-current-buffer chat
                             (setq baseline (pichat-test-reference--draft-state))))
                         file))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) (setq displayed buffer)))
                      ((symbol-function 'pichat-backend-submit-prompt)
                       (lambda (&rest _) (ert-fail "References must not submit"))))
              (if valid
                  (pichat-add-reference)
                (let ((error (should-error (pichat-add-reference) :type 'user-error)))
                  (should (string-match-p "Reference destination changed"
                                          (error-message-string error)))))
              (should collected)
              (if valid
                  (progn
                    (should (eq displayed chat))
                    (should (equal (pichat-chat--input-text)
                                   (concat (string-trim-right (car baseline))
                                           "\n- `/workspace/selected.el`")))
                    (should (> pichat-chat--editor-generation (nth 1 baseline)))
                    (should (equal (cddr baseline)
                                   (cddr (pichat-test-reference--draft-state)))))
                (should-not displayed)
                (when (buffer-live-p chat)
                  (with-current-buffer chat
                    (should (equal baseline
                                   (pichat-test-reference--draft-state)))))))))))))

(ert-deftest pichat-reference-rejects-source-change-during-file-prompt ()
  (pichat-test-reference--collect-scenario
   (lambda (_session chat)
     (with-current-buffer chat
       (pichat-chat--reset-for-source "rebound" "/sessions/rebound.jsonl" t)))))

(ert-deftest pichat-reference-rejects-source-round-trip-during-file-prompt ()
  (pichat-test-reference--collect-scenario
   (lambda (_session chat)
     (with-current-buffer chat
       (pichat-chat--reset-for-source "rebound" "/sessions/rebound.jsonl" t)
       (pichat-chat--reset-for-source "original" "/sessions/original.jsonl" t)))))

(ert-deftest pichat-reference-rejects-source-path-change-during-file-prompt ()
  (pichat-test-reference--collect-scenario
   (lambda (session chat)
     (setf (pichat-session-session-file session) "/sessions/new-path.jsonl")
     (with-current-buffer chat
       (let ((generation pichat-chat--source-generation))
         (pichat-chat--refresh-source-identity session)
         (should (= generation pichat-chat--source-generation)))))))

(ert-deftest pichat-reference-rejects-changed-runtime-ownership ()
  (pichat-test-reference--collect-scenario
   (lambda (_session chat)
     (with-current-buffer chat
       (setq pichat-chat-session
             (pichat-session-make :id "original"
                                  :session-file "/sessions/original.jsonl"))))))

(ert-deftest pichat-reference-rejects-dead-origin-without-retargeting ()
  (let ((other (generate-new-buffer " *reference must not retarget*")))
    (unwind-protect
        (progn
          (with-current-buffer other
            (setq-local major-mode 'pichat-chat-mode)
            (insert "leave this other draft alone"))
          (pichat-test-reference--collect-scenario
           (lambda (_session chat)
             (kill-buffer chat)
             (setq pichat-current-session (pichat-session-make :buffer other))))
          (should (equal (with-current-buffer other (buffer-string))
                         "leave this other draft alone")))
      (kill-buffer other))))

(ert-deftest pichat-reference-unchanged-source-merges-with-editor-bookkeeping ()
  (pichat-test-reference--collect-scenario #'ignore t))

(ert-deftest pichat-reference-stopped-runtime-remains-draft-editable ()
  (pichat-test-reference--collect-scenario
   (lambda (session _chat) (delete-process (pichat-session-process session))) t))

(ert-deftest pichat-reference-preserves-concurrent-same-source-draft-edits ()
  (pichat-test-reference--collect-scenario
   (lambda (_session chat)
     (with-current-buffer chat
       (pichat-chat--set-input-text
        "newer draft\n\nReferences:\n- `/workspace/newer.el`\n\n"))) t))

(ert-deftest pichat-reference-public-insertion-preserves-mapped-region-precedence ()
  (pichat-test-with-temp-dir dir
    (pichat-test-with-unit-session (session proc)
      (setf (pichat-session-path-context session)
            (pichat-transport-path-context
             pichat-transport-local (list (cons dir "/workspace"))))
      (pichat-test-with-chat-buffer (chat session)
        (pichat-chat--set-input-text "keep draft")
        (let ((generation pichat-chat--editor-generation)
              (transient-mark-mode t))
          (cl-letf (((symbol-function 'pichat-reference--target-buffer)
                     (lambda (&optional _) chat))
                    ((symbol-function 'read-file-name)
                     (lambda (&rest _) (ert-fail "Region must take precedence")))
                    ((symbol-function 'pichat-reference--write-temp-reference)
                     (lambda (&rest _) (ert-fail "File region needs no snapshot")))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (with-temp-buffer
              (setq-local buffer-file-name (expand-file-name "region.el" dir))
              (insert "before\nselected\nafter\n")
              (goto-char (point-min))
              (forward-line 1)
              (set-mark (line-end-position))
              (setq mark-active t)
              (pichat-add-reference)
              (should-not mark-active)))
          (should (string-prefix-p "keep draft\n\nReferences:\n"
                                   (pichat-chat--input-text)))
          (should (string-match-p (regexp-quote "`/workspace/region.el`:2")
                                  (pichat-chat--input-text)))
          (should-not (string-match-p (regexp-quote dir) (pichat-chat--input-text)))
          (should (> pichat-chat--editor-generation generation)))))))

(provide 'pichat-test-reference)
;;; pichat-test-reference.el ends here
