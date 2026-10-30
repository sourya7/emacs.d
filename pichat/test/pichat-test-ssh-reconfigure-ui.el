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
              (transient-show-menu t))
         (pichat-test-chat-send-and-wait session buffer "Persist before UI restart" 30)
         (pichat-test-real-ssh--settled session)
         (with-current-buffer buffer (pichat-chat--set-input-text "UI acceptance draft"))
         (call-interactively #'pichat-launch)
         (execute-kbd-macro (kbd "r"))
         (pichat-test-wait-until
          (lambda () (and transient--prefix
                          (eq 'pichat-reconfigure-menu (oref transient--prefix command))
                          (null (plist-get (transient-scope) :blockers))))
          15 "SSH reconfiguration menu enabled after fresh state")
         (should (window-live-p transient--window))
         (minibuffer-with-setup-hook
             (lambda () (insert "coding") (setq unread-command-events (list ?\r)))
           (execute-kbd-macro (kbd "p")))
         (pichat-test-wait-until
          (lambda () (null (plist-get (transient-scope) :blockers)))
          15 "selected preset preflight")
         (execute-kbd-macro (kbd "x"))
         (pichat-test-wait-until
          (lambda () (and (plist-get pichat-tool-picker--state :loaded)
                          (eq 'ready (pichat-tool-discovery-draft-status
                                      (plist-get pichat-tool-picker--state :discovery)))))
          30 "live SSH extension and MCP catalogue discovery")
         (should (window-live-p transient--window))
         ;; Locate the displayed keys by tool name, not catalogue ordering.
         (let ((index (cl-position "write" (plist-get pichat-tool-picker--state :baseline)
                                   :test #'equal))
               (extension-index
                (cl-position "probe_child" (pichat-tool-picker--extension-tools)
                             :key (lambda (tool) (plist-get tool :name)) :test #'equal)))
           (should index)
           (should extension-index)
           (execute-kbd-macro (kbd (nth index pichat-tool-picker--keys)))
           (execute-kbd-macro (kbd (concat "e" (nth extension-index pichat-tool-picker--keys)))))
         (execute-kbd-macro (kbd "RET"))
         (pichat-test-wait-until
          (lambda () (and transient--prefix
                          (eq 'pichat-reconfigure-menu (oref transient--prefix command))
                          (null (plist-get (transient-scope) :blockers))))
          15 "Tools applied to reconfiguration draft")
         (should-not (pichat--reconfigure-action-inapt-p))
         (should (string-match-p "Restart runtime" (pichat--reconfigure-action-description)))
         (pichat-test-real-ssh--write-script
          fixture '(:turns [(:text "UI-selected tools work"
                                  :expectContextIncludes "persisted SSH answer"
                                  :expectTool (:name "probe_child") :expectToolAbsent "write")]))
         (minibuffer-with-setup-hook
             (lambda ()
               (should (string-match-p "Restart this runtime with coding" (minibuffer-prompt)))
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
         (message "LIVE SSH UI: launcher r, preset p, Tools x, checkboxes, confirmation and restart passed"))))))

(provide 'pichat-test-ssh-reconfigure-ui)
;;; pichat-test-ssh-reconfigure-ui.el ends here
