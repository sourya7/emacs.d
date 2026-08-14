;;; pichat-test-sessions-command-map.el --- History command-map tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused Phase 10 tests for the final Session History interactions.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-sessions-final-command-map-dispatches-public-commands ()
  (dolist (binding
           '(("RET" . pichat-sessions-activate-at-point)
             ("f" . pichat-sessions-fork-at-point)
             ("v" . pichat-sessions-preview-branch-at-point)
             ("TAB" . pichat-sessions-toggle-fold-at-point)
             ("n" . pichat-sessions-next-entry)
             ("p" . pichat-sessions-previous-entry)
             ("M-n" . pichat-sessions-next-branch-segment)
             ("M-p" . pichat-sessions-previous-branch-segment)
             ("/" . pichat-sessions-search)
             ("F" . pichat-sessions-cycle-filter)
             ("g" . pichat-sessions-list-refresh)
             ("d" . pichat-sessions-show-details-at-point)
             ("C" . pichat-sessions-clone-current)
             ("b" . pichat-sessions-browse-files)
             ("q" . pichat-sessions-return-to-chat)
             ("?" . describe-mode)))
    (should (eq (lookup-key pichat-sessions-mode-map (kbd (car binding)))
                (cdr binding)))
    (should (commandp (cdr binding)))))

(ert-deftest pichat-sessions-phase-twelve-command-documentation-is-current ()
  (should (string-match-p
           "Session History"
           (documentation 'pichat-chat-mode)))
  (should (string-match-p
           "same-file tree navigation"
           (documentation 'pichat-chat-mode)))
  (should (string-match-p
           "active leaf"
           (documentation 'pichat-sessions-list)))
  (should (string-match-p
           "separate from current-file Session History"
           (documentation 'pichat-sessions-browse-files)))
  (should (string-match-p
           "projected visible-model index"
           (documentation 'pichat-sessions-parent-at-point)))
  (should (string-match-p
           "projected visible-model index"
           (documentation 'pichat-sessions-first-child-at-point)))
  (should (get 'pichat-sessions-switch-at-point 'byte-obsolete-info)))

(ert-deftest pichat-sessions-ret-jumps-to-active-chat-node-without-forking ()
  (let* ((session (pichat-session-make :id "session" :session-file "/one"))
         (chat (generate-new-buffer " *pichat-ret-chat*"))
         completed forked previewed)
    (unwind-protect
        (progn
          (setf (pichat-session-buffer session) chat)
          (with-current-buffer chat
            (insert "before\n")
            (insert (propertize "selected entry" 'pichat-node-key "selected"))
            (insert "\nafter"))
          (with-temp-buffer
            (setq-local pichat-sessions-session session
                        pichat-sessions--source-token '("session" "/one"))
            (cl-letf (((symbol-function 'pichat-sessions--entry-id-at-point)
                       (lambda () "selected"))
                      ((symbol-function 'pichat-view-complete)
                       (lambda (target source)
                         (setq completed (list target source))))
                      ((symbol-function 'pichat-sessions-fork-at-point)
                       (lambda () (setq forked t)))
                      ((symbol-function 'pichat-sessions-preview-branch-at-point)
                       (lambda () (setq previewed t))))
              (pichat-sessions-activate-at-point)
              (should (equal (list chat (current-buffer)) completed))))
          (with-current-buffer chat
            (should (equal "selected"
                           (get-text-property (point) 'pichat-node-key))))
          (should (equal "session" (pichat-session-id session)))
          (should (equal "/one" (pichat-session-session-file session)))
          (should-not forked)
          (should-not previewed))
      (kill-buffer chat))))

(ert-deftest pichat-sessions-ret-directs-hidden-entry-to-preview ()
  (let* ((session (pichat-session-make :id "session" :session-file "/one"))
         (chat (generate-new-buffer " *pichat-ret-hidden-chat*")))
    (unwind-protect
        (progn
          (setf (pichat-session-buffer session) chat)
          (with-temp-buffer
            (setq-local pichat-sessions-session session
                        pichat-sessions--source-token '("session" "/one"))
            (cl-letf (((symbol-function 'pichat-sessions--entry-id-at-point)
                       (lambda () "alternate")))
              (let ((error (should-error
                            (pichat-sessions-activate-at-point)
                            :type 'user-error)))
                (should (string-match-p
                         "not in the active transcript; press v"
                         (cadr error)))))))
      (kill-buffer chat))))

(ert-deftest pichat-sessions-ret-rejects-stale-history-and-dead-chat ()
  (let ((session (pichat-session-make :id "session" :session-file "/one")))
    (with-temp-buffer
      (setq-local pichat-sessions-session session
                  pichat-sessions--source-token '("old" "/old"))
      (cl-letf (((symbol-function 'pichat-sessions--entry-id-at-point)
                 (lambda () "selected")))
        (let ((error (should-error (pichat-sessions-activate-at-point)
                                   :type 'user-error)))
          (should (string-match-p "history is stale" (cadr error))))))
    (with-temp-buffer
      (setq-local pichat-sessions-session session
                  pichat-sessions--source-token '("session" "/one"))
      (cl-letf (((symbol-function 'pichat-sessions--entry-id-at-point)
                 (lambda () "selected")))
        (let ((error (should-error (pichat-sessions-activate-at-point)
                                   :type 'user-error)))
          (should (string-match-p "chat buffer is no longer live"
                                  (cadr error))))))))

(ert-deftest pichat-sessions-return-to-chat-prefers-owning-live-buffer ()
  (let* ((session (pichat-session-make))
         (chat (generate-new-buffer " *pichat-command-map-chat*"))
         popped
         quit)
    (unwind-protect
        (progn
          (setf (pichat-session-buffer session) chat)
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _args) (setq popped buffer)))
                    ((symbol-function 'quit-window)
                     (lambda (&rest _args) (setq quit t))))
            (with-temp-buffer
              (setq-local pichat-sessions-session session)
              (pichat-sessions-return-to-chat)))
          (should (eq chat popped))
          (should-not quit)
          (should (eq chat (pichat-session-buffer session))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-sessions-return-to-chat-quits-when-chat-is-not-live ()
  (let ((session (pichat-session-make))
        popped
        quit)
    (cl-letf (((symbol-function 'pop-to-buffer)
               (lambda (buffer &rest _args) (setq popped buffer)))
              ((symbol-function 'quit-window)
               (lambda (&rest _args) (setq quit t))))
      (with-temp-buffer
        (setq-local pichat-sessions-session session)
        (pichat-sessions-return-to-chat)))
    (should quit)
    (should-not popped)
    (should-not (pichat-session-buffer session))))

(provide 'pichat-test-sessions-command-map)
;;; pichat-test-sessions-command-map.el ends here
