;;; pichat-test-ssh-reconfigure-ui.el --- Opt-in live SSH UI acceptance -*- lexical-binding: t; -*-

(require 'pichat-test-real-ssh-support)
(require 'pichat-jobs)

(defun pichat-test-ssh-ui--wait-for-tools (description)
  (pichat-test-wait-until
   (lambda ()
     (and (plist-get pichat-tool-picker--state :loaded)
          (not (plist-get pichat-tool-picker--state :cancel-extension-start))
          (eq 'ready (pichat-tool-discovery-draft-status
                      (plist-get pichat-tool-picker--state :discovery)))))
   30 description)
  (should (eq 'ssh (pichat-transport-kind
                    (plist-get pichat-tool-picker--state :transport))))
  (should (cl-some (lambda (tool) (equal "probe_child" (plist-get tool :name)))
                   (pichat-tool-picker--extension-tools)))
  (should (window-live-p transient--window)))

(ert-deftest pichat-integration-ssh-reconfigure-live-ui ()
  "Drive real SSH Tools discovery from ordinary launch, Jobs and restart."
  (when noninteractive (ert-skip "Run in a separate non-batch Emacs frame"))
  (with-timeout (100 (ert-fail "Live SSH UI acceptance exceeded its deadline"))
    (pichat-test-real-ssh--run
     (lambda (fixture)
       (let* ((session (plist-get fixture :session))
              (buffer (pichat-session-buffer session))
              (runtime-id (pichat-session-runtime-id session))
              (old (pichat-session-process session))
              (transient-show-menu t)
              (wait-for-restart-draft
               (lambda (description)
                 (pichat-test-wait-until
                  (lambda ()
                    (and transient--prefix
                         (eq 'pichat-launch (oref transient--prefix command))
                         (when-let* ((scope (pichat--launch-reconfigure-scope)))
                           (null (plist-get scope :blockers)))))
                  15 description))))
         (pichat-test-chat-send-and-wait session buffer "Persist before UI restart" 30)
         (pichat-test-real-ssh--settled session)
         (switch-to-buffer buffer)
         (pichat-chat--set-input-text "UI acceptance draft")
         (execute-kbd-macro (kbd "M-x pichat-launch RET"))
         (minibuffer-with-setup-hook
             (lambda () (insert "coding") (setq unread-command-events (list ?\r)))
           (execute-kbd-macro (kbd "p")))
         (execute-kbd-macro (kbd "x"))
         (pichat-test-ssh-ui--wait-for-tools "ordinary launcher SSH Tools Open")
         (let* ((draft (plist-get pichat-tool-picker--state :discovery))
                (token (pichat-tool-discovery-draft-token draft)))
           (execute-kbd-macro (kbd "r"))
           (pichat-test-ssh-ui--wait-for-tools "ordinary launcher SSH Tools Refresh")
           (should-not (eq token (pichat-tool-discovery-draft-token draft))))
         (execute-kbd-macro (kbd "q"))
         (should (eq 'pichat-launch (oref transient--prefix command)))
         (execute-kbd-macro (kbd "C-g"))
         (let ((pichat-jobs-file (expand-file-name "ssh-ui-jobs.json" user-emacs-directory))
               (pichat-jobs--owned-store nil)
               (pichat-jobs--executor nil)
               (default-directory (plist-get fixture :project)))
           (unwind-protect
               (progn
                 (execute-kbd-macro (kbd "M-x pichat-job-new RET"))
                 (minibuffer-with-setup-hook
                     (lambda () (insert "coding") (setq unread-command-events (list ?\r)))
                   (execute-kbd-macro (kbd "p")))
                 (minibuffer-with-setup-hook
                     (lambda () (insert "real-ssh") (setq unread-command-events (list ?\r)))
                   (execute-kbd-macro (kbd "t")))
                 (execute-kbd-macro (kbd "x"))
                 (pichat-test-ssh-ui--wait-for-tools "Jobs SSH Tools Open")
                 (execute-kbd-macro (kbd "RET"))
                 (should (eq 'pichat-job-edit-menu (oref transient--prefix command)))
                 (execute-kbd-macro (kbd "q"))
                 (should (equal [] (pichat-job-records pichat-jobs--owned-store 'runs)))
                 (should (equal [] (pichat-job-records pichat-jobs--owned-store 'jobs))))
             (when transient--prefix (transient-quit-all))
             (when pichat-jobs--executor
               (pichat-job-executor-schedule-stop pichat-jobs--executor))))
         (should (eq old (pichat-session-process session)))
         (should (= 1 (plist-get fixture :spawn-checks)))
         (execute-kbd-macro (kbd "M-x pichat-launch RET"))
         (execute-kbd-macro (kbd "n"))
         ;; Between key commands, inspect the active menu, not saved args.
         (should (member "--new" (transient-get-value)))
         (execute-kbd-macro (kbd "r"))
         (funcall wait-for-restart-draft "initial SSH restart draft ready")
         (should (window-live-p transient--window))
         (should (equal "No changes · keep runtime" (pichat--reconfigure-action-description)))
         (minibuffer-with-setup-hook
             (lambda () (insert "coding") (setq unread-command-events (list ?\r)))
           (execute-kbd-macro (kbd "p")))
         (funcall wait-for-restart-draft "selected preset passed preflight")
         (execute-kbd-macro (kbd "r"))
         (should (eq 'pichat-launch (oref transient--prefix command)))
         (should-not (pichat--launch-reconfigure-scope))
         (should (member "--new" (transient-get-value)))
         (execute-kbd-macro (kbd "r"))
         (funcall wait-for-restart-draft "restored SSH restart draft ready")
         (should (equal "Restart · manual → coding" (pichat--reconfigure-action-description)))
         (execute-kbd-macro (kbd "x"))
         (pichat-test-ssh-ui--wait-for-tools "reconfiguration SSH Tools Open")
         ;; Locate the displayed keys by tool name, not catalogue ordering.
         ;; Pi reports provenance, so probe_child sits in its extension's group.
         (let* ((index (cl-position "write" (plist-get pichat-tool-picker--state :baseline)
                                    :test #'equal))
                (named (lambda (tool) (equal "probe_child" (plist-get tool :name))))
                (groups (pichat-tool-picker--extension-groups))
                (group-index (cl-position-if (lambda (group) (cl-some named (cddr group))) groups))
                (tool-index (and group-index
                                 (cl-position-if named (cddr (nth group-index groups))))))
           (should index)
           (should (pichat-tool-picker--grouped-p))
           (should tool-index)
           (execute-kbd-macro (kbd (nth index pichat-tool-picker--keys)))
           (execute-kbd-macro (kbd (concat "e" (nth group-index pichat-tool-picker--keys))))
           (should (eq 'pichat-tool-picker-extension-group (oref transient--prefix command)))
           (execute-kbd-macro (kbd (nth tool-index pichat-tool-picker--keys)))
           (execute-kbd-macro (kbd "RET"))
           (should (eq 'pichat-tool-picker (oref transient--prefix command))))
         (execute-kbd-macro (kbd "RET"))
         (funcall wait-for-restart-draft "Tools applied to restart draft")
         (should-not (pichat--reconfigure-action-inapt-p))
         (should (string-match-p "\\`Restart · " (pichat--reconfigure-action-description)))
         (pichat-test-real-ssh--write-script
          fixture '(:turns [(:text "UI-selected tools work"
                                  :expectContextIncludes "persisted SSH answer"
                                  :expectTool (:name "probe_child") :expectToolAbsent "write")]))
         (minibuffer-with-setup-hook
             (lambda ()
               (should (string-prefix-p "Restart runtime?" (minibuffer-prompt)))
               (insert "yes") (setq unread-command-events (list ?\r)))
           (execute-kbd-macro (kbd "RET")))
         (pichat-test-wait-until
          (lambda () (and (null (pichat-session-restart-operation session))
                          (eq 'coding (pichat-session-preset-name session))
                          (not (eq old (pichat-session-process session)))))
          40 "confirmed restart from live UI")
         (should (equal runtime-id (pichat-session-runtime-id session)))
         (should (pichat-process-lifetime-confirmed-p old))
         (should (= 2 (plist-get fixture :spawn-checks)))
         (with-current-buffer buffer
           (should (equal "UI acceptance draft" (pichat-chat--input-text)))
           (should (string-match-p "persisted SSH answer" (buffer-string))))
         (pichat-test-prompt-and-wait session "Verify UI-selected tools" 30)
         (pichat-test-assert-provider-script-consumed (plist-get fixture :status))
         (should (string-match-p "UI-selected tools work"
                                 (prin1-to-string (pichat-test-rpc-call session "get_entries"))))
         (message "LIVE SSH UI: launch Open/Refresh, Jobs Tools and confirmed restart passed"))))))

(provide 'pichat-test-ssh-reconfigure-ui)
;;; pichat-test-ssh-reconfigure-ui.el ends here
