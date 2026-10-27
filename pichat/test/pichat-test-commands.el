;;; pichat-test-commands.el --- Command picker freshness tests -*- lexical-binding: t; -*-

;;; Code:
(require 'pichat-test-support)
(require 'pichat-test-chat-support)
(require 'pichat-commands)

(defun pichat-test-command--scenario (stage mutate &optional valid)
  "MUTATE a command context at STAGE; expect submission only when VALID.
Exercise the public discovery entry point and its deferred picker."
  (pichat-test-with-unit-session (session proc)
    (setf (pichat-session-id session) "original"
          (pichat-session-session-file session) "/sessions/original.jsonl")
    (pichat-test-with-chat-buffer (chat session)
      (pichat-chat--set-input-text "keep this draft")
      (setq pichat-chat--pending-attachments '((:id "image" :name "image.png" :bytes 1))
            pichat-chat--recoverable-submissions '((:text "recover me")))
      (let ((before (list (pichat-chat--input-text) pichat-chat--editor-generation
                          pichat-chat--pending-attachments
                          pichat-chat--recoverable-submissions))
            callback scheduled selected arguments submitted)
        (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                   (lambda (requested success &optional _failure)
                     (should (eq requested session))
                     (setq callback success)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (setq scheduled (cons function args))))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _)
                     (setq selected t)
                     (when (eq stage 'choice) (funcall mutate session chat))
                     (car (all-completions "" choices))))
                  ((symbol-function 'read-string)
                   (lambda (&rest _)
                     (setq arguments t)
                     (when (eq stage 'arguments) (funcall mutate session chat))
                     "topic"))
                  ((symbol-function 'pichat-backend-submit-prompt)
                   (lambda (destination text &rest _)
                     (push (list destination text) submitted))))
          (pichat-command-run session)
          (should callback)
          (when (eq stage 'discovery) (funcall mutate session chat))
          (funcall callback
                   '(:success t :data (:commands ((:name "Review.Exact" :source "template"))))
                   session)
          (if (eq stage 'discovery)
              (should-not scheduled)
            (should scheduled)
            (should-not selected)
            (when (eq stage 'deferred) (funcall mutate session chat))
            ;; A timer need not run with the originating chat current.
            (with-temp-buffer (apply (car scheduled) (cdr scheduled))))
          (if valid
              (should (equal submitted (list (list session "/Review.Exact topic"))))
            (should-not submitted)
            (when (memq stage '(discovery deferred)) (should-not selected))
            (unless (eq stage 'arguments) (should-not arguments)))
          (when (buffer-live-p chat)
            (with-current-buffer chat
              (should (equal before
                             (list (pichat-chat--input-text) pichat-chat--editor-generation
                                   pichat-chat--pending-attachments
                                   pichat-chat--recoverable-submissions))))))))))

(ert-deftest pichat-command-run-rejects-source-id-change-at-every-boundary ()
  (dolist (stage '(discovery deferred choice arguments))
    (pichat-test-command--scenario
     stage (lambda (session _chat) (setf (pichat-session-id session) "rebound")))))

(ert-deftest pichat-command-run-rejects-source-file-change-at-every-boundary ()
  (dolist (stage '(discovery deferred choice arguments))
    (pichat-test-command--scenario
     stage (lambda (session _chat)
             (setf (pichat-session-session-file session) "/sessions/rebound.jsonl")))))

(ert-deftest pichat-command-run-rejects-same-id-source-rebinding ()
  (dolist (stage '(discovery deferred choice arguments))
    (pichat-test-command--scenario
     stage (lambda (_session chat)
             (with-current-buffer chat (cl-incf pichat-chat--source-generation))))))

(ert-deftest pichat-command-run-rejects-replaced-process-lifetime ()
  (dolist (stage '(discovery deferred arguments))
    (pichat-test-command--scenario
     stage (lambda (session _chat)
             (setf (pichat-session-process-generation session)
                   (1+ (or (pichat-session-process-generation session) 0)))))))

(ert-deftest pichat-command-run-rejects-changed-chat-ownership ()
  (dolist (stage '(deferred arguments))
    (pichat-test-command--scenario
     stage (lambda (_session chat)
             (with-current-buffer chat
               (setq pichat-chat-session (pichat-session-make)))))))

(ert-deftest pichat-command-run-rejects-dead-origin ()
  (dolist (stage '(discovery deferred arguments))
    (pichat-test-command--scenario stage (lambda (_session chat) (kill-buffer chat)))))

(ert-deftest pichat-command-run-rejects-stopped-runtime ()
  (dolist (stage '(discovery deferred arguments))
    (pichat-test-command--scenario
     stage (lambda (session _chat) (delete-process (pichat-session-process session))))))

(ert-deftest pichat-command-run-unchanged-source-submits-without-editing-draft ()
  (pichat-test-command--scenario nil #'ignore t))

(ert-deftest pichat-command-run-rejects-response-from-another-runtime ()
  (pichat-test-with-unit-session (session proc)
    (let (callback scheduled)
      (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                 (lambda (_session success &optional _failure) (setq callback success)))
                ((symbol-function 'run-at-time)
                 (lambda (&rest _) (setq scheduled t))))
        (pichat-command-run session)
        (funcall callback '(:success t :data (:commands nil)) (pichat-session-make))
        (should-not scheduled)))))

(ert-deftest pichat-command-catalog-shares-validated-records-and-metadata ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (let ((response
             '(:data (:commands
                      ((:name "Review.Exact" :source "template" :description "Review")
                       (:name "skill:search" :source "skill" :path "/skills/search")
                       (:name "Review.Exact" :source "extension")
                       (:name "bad name") (:name "") (:name 42)
                       (:name "odd" :source) (:name "dotted" . invalid)
                       42 "bad" (:name "status" :source 42 :description (bad))))))
            callback scheduled submitted picker-names)
        (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                   (lambda (_session success &optional _failure)
                     (setq callback success)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (setq scheduled (cons function args))))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt table &rest _)
                     (setq picker-names (all-completions "" table))
                     (let ((metadata (completion-metadata "" table nil)))
                       (should (eq 'pichat-slash-command
                                   (completion-metadata-get metadata 'category)))
                       (should (eq #'identity
                                   (completion-metadata-get metadata 'display-sort-function)))
                       (should (equal "  [template] Review"
                                      (funcall (completion-metadata-get
                                                metadata 'annotation-function)
                                               "Review.Exact"))))
                     "skill:search"))
                  ((symbol-function 'read-string) (lambda (&rest _) "exact args"))
                  ((symbol-function 'pichat-backend-submit-prompt)
                   (lambda (_session text &rest _) (setq submitted text))))
          (pichat-chat-completion-refresh session 1 'source)
          (funcall callback response session)
          (insert "/")
          (let* ((capf (pichat-chat-completion-capf (copy-marker (point-min))))
                 (names (all-completions "" (nth 2 capf))))
            (should (equal names '("Review.Exact" "skill:search" "status")))
            (should (equal "" (funcall (plist-get (nthcdr 3 capf) :annotation-function)
                                      "status")))
            (should (equal "/skills/search"
                           (plist-get (nth 1 pichat-chat-completion--commands) :path)))
            (pichat-command-run session)
            (funcall callback response session)
            (should scheduled)
            (apply (car scheduled) (cdr scheduled))
            (should (equal names picker-names))
            (should (equal "/skill:search exact args" submitted))
            (should (equal "/" (buffer-string)))))))))

(ert-deftest pichat-command-run-empty-malformed-and-failed-discovery-never-prompts ()
  (pichat-test-with-unit-session (session proc)
    (let (success failure scheduled prompted submitted)
      (cl-letf (((symbol-function 'pichat-rpc-get-commands)
                 (lambda (_session callback &optional error-callback)
                   (setq success callback failure error-callback)))
                ((symbol-function 'run-at-time) (lambda (&rest _) (setq scheduled t)))
                ((symbol-function 'completing-read) (lambda (&rest _) (setq prompted t)))
                ((symbol-function 'pichat-backend-submit-prompt)
                 (lambda (&rest _) (setq submitted t))))
        (dolist (commands '(nil 42 "bad" [(:name "vector")]
                           ((:name "bad") . invalid) ((:description "no name"))))
          (pichat-command-run session)
          (funcall success (list :data (list :commands commands)) session)
          (should-not scheduled))
        (pichat-command-run session)
        (should failure)
        (funcall failure '(:success nil :error "unavailable") session)
        (should-not scheduled)
        (should-not prompted)
        (should-not submitted)))))

(ert-deftest pichat-command-run-unrecognized-selection-does-not-request-args-or-send ()
  (pichat-test-with-unit-session (session proc)
    (let (arguments submitted)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "unknown"))
                ((symbol-function 'read-string) (lambda (&rest _) (setq arguments t)))
                ((symbol-function 'pichat-backend-submit-prompt)
                 (lambda (&rest _) (setq submitted t))))
        (pichat-command--prompt-and-run session '((:name "known")))
        (should-not arguments)
        (should-not submitted)))))

(provide 'pichat-test-commands)
;;; pichat-test-commands.el ends here
