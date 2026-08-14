;;; pichat-test-sessions-fork.el --- Complete history fork transaction tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused Phase 7 tests for history/preview fork UI transactions.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-sessions-preview)

(defmacro pichat-test-sessions-fork--with-origin (&rest body)
  "Install a forkable history fixture and run BODY in its origin buffer."
  (declare (indent 0) (debug body))
  `(let ((session (pichat-session-make :id "source" :session-file "/source")))
     (with-temp-buffer
       (pichat-sessions--refresh-from-response
        (pichat-test-sessions-preview--response) session (current-buffer))
       ,@body)))

(ert-deftest pichat-sessions-fork-direct-validates-source-and-user-target ()
  (pichat-test-sessions-fork--with-origin
    (let (sent-id sent-session)
      (cl-letf (((symbol-function 'pichat-rpc-fork)
                 (lambda (rpc-session id _success &optional _error)
                   (setq sent-session rpc-session sent-id id)
                   "fork-request")))
        (pichat-sessions--goto-id "alternate-user")
        (pichat-sessions-fork-at-point)
        (should (eq session sent-session))
        (should (equal "alternate-user" sent-id))
        (setq sent-id nil)
        (pichat-sessions--goto-id "alternate-leaf")
        (let ((error (should-error (pichat-sessions-fork-at-point)
                                   :type 'user-error)))
          (should (equal
                   "Select a user prompt to fork; press v to preview this branch"
                   (cadr error))))
        (should-not sent-id)
        (pichat-sessions--goto-id "alternate-user")
        (setq pichat-sessions--stale-p t)
        (should-error (pichat-sessions-fork-at-point) :type 'user-error)
        (should-not sent-id)))))

(ert-deftest pichat-sessions-fork-cancellation-and-failure-preserve-origin ()
  (pichat-test-sessions-fork--with-origin
    (let (success failure state-requested popped messages)
      (pichat-sessions--goto-id "alternate-user")
      (let ((before (buffer-string))
            (position (point)))
        (cl-letf (((symbol-function 'pichat-rpc-fork)
                   (lambda (_session _id ok error)
                     (setq success ok failure error)
                     "fork-request"))
                  ((symbol-function 'pichat-rpc-get-state)
                   (lambda (&rest _args) (setq state-requested t)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest args) (setq popped args)))
                  ((symbol-function 'message)
                   (lambda (&rest args) (push args messages))))
          (pichat-sessions-fork-at-point)
          (funcall success '(:success t :data (:cancelled t)) session)
          (should-not state-requested)
          (should-not popped)
          (should (equal before (buffer-string)))
          (should (= position (point)))
          (should (equal "alternate-user"
                         (pichat-sessions--entry-id-at-point)))
          (funcall failure '(:success nil :error "fork denied") session)
          (should-not state-requested)
          (should-not popped)
          (should (equal before (buffer-string)))
          (should (= position (point)))
          (should (cl-some (lambda (args)
                             (string-match-p "cancelled" (apply #'format args)))
                           messages))
          (should (cl-some (lambda (args)
                             (string-match-p "fork denied" (apply #'format args)))
                           messages)))))))

(ert-deftest pichat-sessions-fork-success-syncs-restores-and-focuses-prompt ()
  (pichat-test-sessions-fork--with-origin
    (let ((chat (generate-new-buffer " *pichat-fork-chat*"))
          fork-success state-success state-failure restored-text
          restore-result focused repaint-called messages)
      (unwind-protect
          (progn
            (setf (pichat-session-buffer session) chat)
            (with-current-buffer chat
              (setq-local pichat-chat--editor-generation 7))
            (pichat-sessions--goto-id "alternate-user")
            (cl-letf (((symbol-function 'pichat-rpc-fork)
                       (lambda (_session id ok _error)
                         (should (equal "alternate-user" id))
                         (setq fork-success ok)
                         "fork-request"))
                      ((symbol-function 'pichat-rpc-get-state)
                       (lambda (_session ok error)
                         (setq state-success ok state-failure error)
                         "state-request"))
                      ((symbol-function 'pichat-chat-input-restore-fork-text)
                       (lambda (text)
                         (setq restored-text text)
                         restore-result))
                      ((symbol-function 'pichat-chat-repaint)
                       (lambda () (setq repaint-called t)))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _args) (setq focused buffer)))
                      ((symbol-function 'message)
                       (lambda (&rest args) (push args messages))))
              (pichat-sessions-fork-at-point)
              (setq restore-result 'inserted)
              (funcall fork-success
                       '(:success t :data (:text "Alternate prompt")) session)
              (should state-success)
              (should-not restored-text)
              (funcall state-success '(:success t :data (:sessionId "forked"))
                       session)
              (should (equal "Alternate prompt" restored-text))
              (should (eq chat focused))
              (should-not repaint-called)
              (should (cl-some
                       (lambda (args)
                         (string-match-p "edit the restored prompt"
                                         (apply #'format args)))
                       messages))))
        (kill-buffer chat)))))

(ert-deftest pichat-sessions-fork-success-preserves-draft-result-and-image-warning ()
  (pichat-test-sessions-fork--with-origin
    (let ((chat (generate-new-buffer " *pichat-fork-chat*"))
          fork-success state-success messages)
      (unwind-protect
          (progn
            (setf (pichat-session-buffer session) chat)
            (pichat-sessions--goto-id "alternate-user")
            (cl-letf (((symbol-function 'pichat-rpc-fork)
                       (lambda (_session _id ok _error)
                         (setq fork-success ok)))
                      ((symbol-function 'pichat-rpc-get-state)
                       (lambda (_session ok _error) (setq state-success ok)))
                      ((symbol-function 'pichat-chat-input-restore-fork-text)
                       (lambda (_text) 'copied))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'message)
                       (lambda (&rest args) (push args messages))))
              (pichat-sessions-fork-at-point)
              (funcall fork-success
                       '(:success t :data (:text "Alternate prompt")) session)
              (funcall state-success '(:success t :data nil) session)
              (should (cl-some
                       (lambda (args)
                         (let ((text (apply #'format args)))
                           (and (string-match-p "existing draft kept" text)
                                (string-match-p "text only" text))))
                       messages))))
        (kill-buffer chat)))))

(ert-deftest pichat-sessions-fork-protocol-and-state-failures-are-distinct ()
  (pichat-test-sessions-fork--with-origin
    (let ((chat (generate-new-buffer " *pichat-fork-chat*"))
          fork-success state-success state-failure restored messages)
      (unwind-protect
          (progn
            (setf (pichat-session-buffer session) chat)
            (pichat-sessions--goto-id "alternate-user")
            (cl-letf (((symbol-function 'pichat-rpc-fork)
                       (lambda (_session _id ok _error)
                         (setq fork-success ok)))
                      ((symbol-function 'pichat-rpc-get-state)
                       (lambda (_session ok error)
                         (setq state-success ok state-failure error)))
                      ((symbol-function 'pichat-chat-input-restore-fork-text)
                       (lambda (&rest _args) (setq restored t)))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'message)
                       (lambda (&rest args) (push args messages))))
              (pichat-sessions-fork-at-point)
              (funcall fork-success '(:success t :data nil) session)
              (should state-success)
              (funcall state-success '(:success t :data nil) session)
              (should-not restored)
              (should (cl-some
                       (lambda (args)
                         (string-match-p "did not return prompt text"
                                         (apply #'format args)))
                       messages))
              (setq state-success nil messages nil)
              (pichat-sessions-fork-at-point)
              (funcall fork-success
                       '(:success t :data (:text "prompt")) session)
              (funcall state-failure '(:success nil :error "state timeout") session)
              (should-not restored)
              (should (cl-some
                       (lambda (args)
                         (let ((text (apply #'format args)))
                           (and (string-match-p "session changed" text)
                                (string-match-p "state timeout" text))))
                       messages))))
        (kill-buffer chat)))))

(ert-deftest pichat-sessions-fork-sync-before-or-after-restore-preserves-prompt ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer (sync-count 0))
      (setf (pichat-session-id session) "forked"
            (pichat-session-session-file session) "/forked")
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                     (lambda (_session &optional since callback _error)
                       (cl-incf sync-count)
                       (should-not (and (not (functionp since)) since))
                       (funcall (pichat-test--rpc-get-entries-callback
                                 since callback)
                                '(:data
                                  (:entries
                                   ((:type "message" :id "fork-user"
                                     :parentId nil
                                     :message
                                     (:role "user"
                                      :content "Authoritative ancestor")))
                                   :leafId "fork-user"))
                                session)
                       "entries-request")))
            ;; Opening after get_state owns the initial authoritative sync.
            (setq buffer (pichat-chat-open session t))
            (with-current-buffer buffer
              (should (= 1 sync-count))
              (should (string-match-p "Authoritative ancestor"
                                      (buffer-string)))
              (should (eq 'inserted
                          (pichat-chat-input-restore-fork-text
                           "restored after sync")))
              (should (equal "restored after sync"
                             (pichat-chat--input-text)))
              ;; A later canonical synchronization also preserves the choice.
              (pichat-chat-repaint)
              (should (= 2 sync-count))
              (should (equal "restored after sync"
                             (pichat-chat--input-text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-sessions-fork)
;;; pichat-test-sessions-fork.el ends here
