;;; pichat-test-ssh-reconfigure-ui.el --- Opt-in live SSH UI acceptance -*- lexical-binding: t; -*-

(require 'pichat-test-real-ssh-support)

(ert-deftest pichat-integration-ssh-reconfigure-live-ui ()
  "Drive the real launcher, preset chooser, Tools picker and restart keys."
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
         (execute-kbd-macro (kbd "n"))
         (should (member "--new" (transient-args 'pichat-launch)))
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
         (should (member "--new" (transient-args 'pichat-launch)))
         (execute-kbd-macro (kbd "r"))
         (funcall wait-for-restart-draft "restored SSH restart draft ready")
         (should (equal "Restart · manual → coding" (pichat--reconfigure-action-description)))
         (execute-kbd-macro (kbd "x"))
         (pichat-test-wait-until
          (lambda () (and (plist-get pichat-tool-picker--state :loaded)
                          (eq 'ready (pichat-tool-discovery-draft-status
                                      (plist-get pichat-tool-picker--state :discovery)))))
          30 "live SSH extension and MCP catalogue discovery")
         (should (window-live-p transient--window))
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
         (message "LIVE SSH UI: launcher toggle, separate drafts, Tools, confirmation and restart passed"))))))

(provide 'pichat-test-ssh-reconfigure-ui)
;;; pichat-test-ssh-reconfigure-ui.el ends here
