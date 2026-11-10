;;; pichat-test-presets-live-ui.el --- Isolated live Save preset as checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Opt-in separate Emacs only; not loaded by the regular suite.  Drives the real
;; launcher, Tools picker and model keys in a non-batch Emacs with a private
;; `custom-file', isolated Pi state, the offline fake provider and the offline
;; MCP fixture.  No runtime is launched.  This is a programmatic check, not
;; human visual review.  See TESTING_GUIDELINES.md.

;;; Code:

(require 'pichat-test-support)
(require 'pichat)

(defvar pichat-test-presets-live--answers nil
  "Queue of (PROMPT-REGEXP . INPUT) answered as minibuffers open.")

(defun pichat-test-presets-live--answer ()
  "Feed the queued answer whose regexp matches the current minibuffer prompt."
  (let* ((prompt (minibuffer-prompt))
         (entry (and prompt (cl-find-if (lambda (entry) (string-match-p (car entry) prompt))
                                        pichat-test-presets-live--answers))))
    (if (not entry)
        (message "Unanswered live prompt: %S" prompt)
      (setq pichat-test-presets-live--answers
            (delq entry pichat-test-presets-live--answers))
      (setq unread-command-events
            (append (listify-key-sequence (concat (cdr entry) "\r"))
                    unread-command-events)))))

(defun pichat-test-presets-live--expect (&rest answers)
  "Queue ANSWERS, alternating prompt regexps and inputs."
  (while answers
    (setq pichat-test-presets-live--answers
          (append pichat-test-presets-live--answers
                  (list (cons (pop answers) (pop answers)))))))

(defun pichat-test-presets-live--menu ()
  "Return the visible Transient menu text."
  (with-current-buffer (get-buffer " *transient*") (buffer-string)))

(defun pichat-test-presets-live--wait-menu (prefix regexp what)
  "Wait until Transient PREFIX shows REGEXP, described by WHAT."
  (condition-case err
      (pichat-test-wait-until
       (lambda ()
         (and transient--prefix (eq (oref transient--prefix command) prefix)
              (get-buffer " *transient*")
              (string-match-p regexp (pichat-test-presets-live--menu))))
       30 what)
    (ert-test-failed
     (ert-fail (format "%s; prefix %S, value %S, menu:\n%s" (cadr err)
                       (and transient--prefix (oref transient--prefix command))
                       (and transient--prefix (ignore-errors (transient-get-value)))
                       (if (get-buffer " *transient*")
                           (pichat-test-presets-live--menu)
                         "<none>"))))))

(defun pichat-test-presets-live--file (file)
  "Return FILE's contents or nil."
  (when (file-exists-p file)
    (with-temp-buffer (insert-file-contents file) (buffer-string))))

(ert-deftest pichat-integration-presets-live-ui-save-preset-as ()
  (should-not noninteractive)
  (pichat-test-require-pi)
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir project-dir
      (pichat-test-with-temp-dir agent-dir
        (let* ((python (or (executable-find "python3") (ert-fail "MCP fixture needs python3")))
               (fixture (expand-file-name "fixtures/mcp-server.py"
                                          (file-name-directory
                                           (locate-library "pichat-test-support"))))
               (process-environment
                (append (list "PI_OFFLINE=1" "PI_SKIP_VERSION_CHECK=1" "PI_TELEMETRY=0"
                              (concat "PI_CODING_AGENT_DIR=" agent-dir))
                        process-environment))
               (custom-file (expand-file-name "custom.el" agent-dir))
               (user-init-file (expand-file-name "init.el" agent-dir))
               (user-emacs-directory agent-dir)
               (transient-history nil)
               (transient-history-file (expand-file-name "transient-history.el" agent-dir))
               (pichat-presets (copy-tree pichat-presets))
               (pichat-saved-presets nil)
               (pichat-default-preset 'manual)
               (pichat-default-model nil)
               (pichat-rpc-command nil)
               (pichat-bridge-extension-file nil)
               (pichat-pi-executable pichat-test-pi-executable)
               (pichat-pi-default-args
                '("--mode" "rpc" "--offline" "--no-approve" "--no-context-files"
                  "--no-skills" "--no-prompt-templates" "--no-themes" "--no-extensions"))
               (pichat-pi-extra-args (list "-e" pichat-test-fake-provider-extension))
               (default-directory project-dir)
               (use-dialog-box nil)
               (pichat-test-presets-live--answers nil)
               (prefix (lambda () (and transient--prefix (oref transient--prefix command)))))
          (with-temp-file custom-file
            (insert ";;; private fixture custom file\n(custom-set-variables)\n"))
          (with-temp-file (expand-file-name "mcp.json" agent-dir)
            (insert (json-serialize
                     (list :mcpServers
                           (list :probe (list :command python :args (vector fixture)
                                              :exposure "direct")))
                     :null-object nil :false-object :json-false)))
          (add-hook 'minibuffer-setup-hook #'pichat-test-presets-live--answer)
          (unwind-protect
              (progn
                (execute-kbd-macro (kbd "M-x pichat-launch RET"))
                (pichat-test-presets-live--wait-menu
                 'pichat-launch "c Save preset as…" "launcher with Save preset as")
                ;; p: select manual explicitly.
                (pichat-test-presets-live--expect "Preset" "manual")
                (execute-kbd-macro (kbd "p"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "manual" "manual preset")
                ;; x Tools: select the fixture's direct MCP tool, then Apply.
                (execute-kbd-macro (kbd "x"))
                (pichat-test-presets-live--wait-menu
                 'pichat-tool-picker "probe (connected" "MCP discovery in Tools")
                (execute-kbd-macro (kbd "A"))
                (pichat-test-presets-live--wait-menu 'pichat-tool-picker-server "search" "probe tools")
                (execute-kbd-macro (kbd "1"))
                (execute-kbd-macro (kbd "RET"))
                (pichat-test-presets-live--wait-menu 'pichat-tool-picker "probe (connected, 1/" "one MCP tool")
                (execute-kbd-macro (kbd "RET"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "Save preset as" "Tools applied")
                (should (equal '(("probe" . "search"))
                               (plist-get (plist-get (transient-scope) :tool-selection) :mcp)))
                ;; Tools Cancel keeps the applied selection and writes nothing.
                (let ((before (pichat-test-presets-live--file custom-file)))
                  (execute-kbd-macro (kbd "x"))
                  (pichat-test-presets-live--wait-menu 'pichat-tool-picker "probe" "Tools reopened")
                  (execute-kbd-macro (kbd "n"))
                  (execute-kbd-macro (kbd "q"))
                  (pichat-test-presets-live--wait-menu 'pichat-launch "Save preset as" "Tools cancelled")
                  (should (equal '(("probe" . "search"))
                                 (plist-get (plist-get (transient-scope) :tool-selection) :mcp)))
                  (should (equal before (pichat-test-presets-live--file custom-file))))
                ;; m: list real (offline) models and stage a concrete one.
                (pichat-test-presets-live--expect
                 "\\`Model: " "Select or enter model…"
                 "Model for this launch" "pichat-fake/pichat-fake")
                (execute-kbd-macro (kbd "m"))
                (pichat-test-presets-live--wait-menu
                 'pichat-launch "Model pichat-fake/pichat-fake" "staged model")
                ;; c: save under a new name.
                (pichat-test-presets-live--expect "Preset name" "web-search")
                (execute-kbd-macro (kbd "c"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "Launch · independent · web-search"
                                                     "web-search selected")
                (should-not (plist-get (transient-scope) :tool-selection))
                (should (string-match-p "Model pichat-fake/pichat-fake"
                                        (pichat-test-presets-live--menu)))
                (should (equal '(("probe" . "search"))
                               (plist-get (pichat-get-preset 'web-search) :mcp)))
                (let ((saved (pichat-test-presets-live--file custom-file)))
                  (should (string-match-p ";;; private fixture custom file" saved))
                  (should (string-match-p "(web-search " saved))
                  ;; Replacement is refused, then confirmed, through real prompts.
                  (pichat-test-presets-live--expect "Preset name" "web-search"
                                                    "Replace preset web-search" "no")
                  (execute-kbd-macro (kbd "c"))
                  (pichat-test-presets-live--wait-menu 'pichat-launch "web-search" "refusal returns")
                  (should (equal saved (pichat-test-presets-live--file custom-file))))
                ;; A second name with Pi's default model policy.
                (pichat-test-presets-live--expect "\\`Model: " "Pi default model")
                (execute-kbd-macro (kbd "m"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "Model Pi default" "default model staged")
                (pichat-test-presets-live--expect "Preset name" "review-fast")
                (execute-kbd-macro (kbd "c"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "review-fast" "review-fast selected")
                (should (eq 'default (plist-get (pichat-get-preset 'review-fast) :model)))
                ;; Both appear in p; selecting web-search restores its model.
                ;; A set Transient option clears on its first key press.
                (execute-kbd-macro (kbd "p"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "default (manual)" "preset cleared")
                (pichat-test-presets-live--expect "Preset" "web-search")
                (execute-kbd-macro (kbd "p"))
                (pichat-test-presets-live--wait-menu
                 'pichat-launch "Model pichat-fake/pichat-fake" "preset model restored")
                ;; A model chosen at launch cannot be saved; no name is asked.
                (pichat-test-presets-live--expect "\\`Model: " "Choose when launching")
                (execute-kbd-macro (kbd "m"))
                (pichat-test-presets-live--wait-menu 'pichat-launch "choose when launching" "deferred model")
                (let ((before (pichat-test-presets-live--file custom-file)))
                  (execute-kbd-macro (kbd "c"))
                  (pichat-test-presets-live--wait-menu 'pichat-launch "Save preset as" "refused save")
                  (should (equal before (pichat-test-presets-live--file custom-file))))
                (should-not pichat-test-presets-live--answers)
                (should (equal '(web-search review-fast) (mapcar #'car pichat-saved-presets)))
                (should-not (pichat-session-list))
                (execute-kbd-macro (kbd "C-g"))
                (should-not (funcall prefix))
                ;; A fresh Emacs reloads both from the private custom file.
                (with-temp-buffer
                  (should (eql 0 (call-process
                                  (expand-file-name invocation-name invocation-directory)
                                  nil t nil "-Q" "--batch" "-L"
                                  (file-name-directory (locate-library "pichat-presets"))
                                  "--eval"
                                  (format "(progn (load %S nil t) (require 'pichat-presets) (prin1 (pichat-presets-names)))"
                                          custom-file))))
                  (should (string-match-p "(manual coding review standard web-search review-fast)"
                                          (buffer-string))))
                (message "PICHAT-PRESETS-LIVE-OK evil=%s" (bound-and-true-p evil-mode)))
            (remove-hook 'minibuffer-setup-hook #'pichat-test-presets-live--answer)
            (when transient--prefix (transient-quit-all))))))))

(provide 'pichat-test-presets-live-ui)
;;; pichat-test-presets-live-ui.el ends here
