;;; pichat.el --- Local PiChat setup -*- lexical-binding: t; -*-

;;; Commentary:

;; Local integration for the in-repo PiChat package.

;;; Code:

(require 'cl-lib)

;; Development-only dependency used by pichat/test/run-coverage.sh.  Keeping it
;; deferred avoids loading coverage instrumentation in normal Emacs sessions.
(use-package undercover
  :defer t)

(use-package pichat
  :ensure `(:type file
            :main ,(my/emacs-main-dir "pichat/pichat.el")
            :files ("*.el"
                    ("bridge" "bridge/pichat-bridge.ts"
                              "bridge/pichat-tool-control.ts")
                    ("skills" "skills/pichat-jobs/SKILL.md"))
            :inherit nil)
  :custom
  (pichat-jobs-file (my/emacs-local-dir "pichat/jobs.json"))
  (pichat-approval-policy-file (my/emacs-local-dir "pichat/approvals.el"))
  :commands (pichat pichat-global pichat-launch pichat-session-manager
                    pichat-jobs
                    pichat-sessions-browse-files pichat-sessions-switch-files
                    pichat-status
                    pichat-select-model pichat-stop-session
                    pichat-add-reference pichat-smoke-test))

(setq pichat-append-system-prompt
      "Prefer bare URLs over descriptive Markdown links.
Prefer bullets unless a table materially helps comparison.
Keep tables narrow and pad columns for monospace readability.")

;; Updating an alist reads its current value: wait for its defining module,
;; not Elpaca activation or a particular entry command to load PiChat.
(with-eval-after-load 'pichat-transport
  ;; Use Pi's absolute path because non-interactive SSH lacks the mise PATH.
  (setf (alist-get 'agent-dev pichat-targets)
        '(:kind ssh
          :tramp-prefix "/ssh:agent-dev:"
          :pi-executable "/home/dev/.local/share/mise/installs/pi/latest/pi/pi"
          :remote-path (tramp-own-remote-path)
          :runtime-home "/home/dev"
          :path-mappings (("/ssh:agent-dev:/" . "/")))))

;; (setq pichat-targets
;;       '((lima-devbox
;;          :kind ssh
;;          :tramp-prefix "/ssh:lima-devbox:"
;;          :pi-executable "/etc/profiles/per-user/dev/bin/pi"
;;          :remote-path (tramp-own-remote-path)
;;          :runtime-home "/home/dev.guest"
;;          :path-mappings
;;          (("/home/mojo/Dev" . "/home/mojo/Dev")
;;           ("/ssh:lima-devbox:/home/dev.guest" . "/home/dev.guest")))))

;; (setq pichat-project-target-alist '(("/home/mojo/Dev" . lima-devbox)))

;; Preset for the authored plan-loop reviewer job (.pi/jobs/plan-reviewer.json).
;; Read-only tools, the job tools it needs to restart the worker, and the
;; plan-review MCP tools each repository defines in its .pi/mcp.json.
(with-eval-after-load 'pichat-presets
  (pichat-make-preset 'plan-reviewer
    :description "Review a plan-loop worker's change and restart it with findings."
    :tools '("read" "grep" "find" "ls")
    :mcp '(("plan-review" . "plan_show") ("plan-review" . "workspace_show")
           ("plan-review" . "change_log") ("plan-review" . "change_diff")
           ("plan-review" . "test"))
    :emacs-tools '("pichat_job_inspect" "pichat_job_run_now"
                   "pichat_job_run_inspect"))

  ;; Plan-loop orchestrator chat: starts the worker job for a plan's next task
  ;; (approval prompt), reports the reviewer's verdict, and lands or closes the
  ;; plan's workspace with the plans skill.
  (pichat-make-preset 'plan-orchestrator
    :description "Start a plan's next scope as a plan-loop run; land and close its workspace."
    :model "cliproxyapi/claude-opus-5-5"
    :tools '("read" "grep" "find" "ls" "bash")
    :emacs-tools '("pichat_jobs_list" "pichat_job_inspect" "pichat_job_run_now"
                   "pichat_job_run_inspect")
    :append-system-prompt
    "You orchestrate plan-loop runs for this repository; you do not implement or review. Use the plans skill for everything about plans and their workspaces.
- Start work: find the plan's next task (plans show), check with workspace show and pichat_job_inspect that no worker is running, then run the plan-worker job with pichat_job_run_now and input `plan: <plan-id>; scope: <exact task heading>`. Tasks that start with Decide or are BLOCKED go back to the user.
- Status: inspect the worker run and the plan-reviewer job's latest run, and report the reviewer's verdict.
- Try, land, close: only when the user asks for that action by name, following the plans skill.
Never edit code, commit or push; change a plan record only where the plans skill's land or close says to."))

(my/add-all-to-list 'display-buffer-alist
                    '(("\\`\\*pi:" (display-buffer-same-window))
                      ("\\`\\*PiChat Sessions" (display-buffer-same-window))
                      ("\\`\\*PiChat Response:" (display-buffer-same-window))
                      ("\\`\\*PiChat Jobs" (display-buffer-same-window))))

(declare-function bufferlo-local-buffer-p "bufferlo"
                  (buffer &optional frame tabnum include-hidden))
(defun my/pichat-bufferlo-location (buffer)
  "Return a frame and tab containing BUFFER on the current terminal.
Never redirect input to another terminal client's frame."
  (when (and (buffer-live-p buffer) (fboundp 'bufferlo-local-buffer-p))
    (cl-loop for frame in (cons (selected-frame)
                                (delq (selected-frame) (frame-list)))
             when (and (eq (frame-terminal frame)
                           (frame-terminal (selected-frame)))
                       (not (frame-parameter frame 'no-accept-focus)))
             thereis (let ((tabs (funcall tab-bar-tabs-function frame)))
                       (if tabs
                           (cl-loop for index below (length tabs)
                                    when (bufferlo-local-buffer-p
                                          buffer frame index t)
                                    return (cons frame (1+ index)))
                         (when (bufferlo-local-buffer-p buffer frame nil t)
                           (cons frame nil)))))))

(defun my/pichat-project-tab-name (session)
  "Return the configured project-tab name for SESSION's owner directory."
  (when-let* ((directory (pichat-session-owner-directory session)))
    (unless (or (equal (pichat-session-owner-scope-key session) "global")
                (string-prefix-p
                 "global|" (or (pichat-session-owner-scope-key session) "")))
      (file-name-nondirectory (directory-file-name directory)))))

(defun my/pichat-tab-name-exists-p (name)
  "Return non-nil when the selected frame has a tab named NAME."
  (cl-some (lambda (tab) (equal name (alist-get 'name tab)))
           (funcall tab-bar-tabs-function (selected-frame))))

(defun my/pichat-display-chat-with-bufferlo (session)
  "Display SESSION in its project tab or an existing Bufferlo location."
  (let* ((name (and (fboundp 'tab-bar-switch-to-tab)
                    (my/pichat-project-tab-name session)))
         (location (my/pichat-bufferlo-location
                    (pichat-session-buffer session))))
    (cond
     ;; Prefer the owner's project tab even if Bufferlo also lists the chat
     ;; in other tabs (for example, the manager's tab).
     (name
      (if (my/pichat-tab-name-exists-p name)
          (tab-bar-switch-to-tab name)
        (tab-bar-new-tab)
        (tab-bar-rename-tab name)))
     (location
      (pcase-let ((`(,frame . ,tab) location))
        (select-frame-set-input-focus frame)
        (when tab (tab-bar-select-tab tab)))))
    (pichat-session-manager-display-chat-current-tab session)))

(setq pichat-session-manager-display-chat-function
      #'my/pichat-display-chat-with-bufferlo
      pichat-launch-display-chat-function
      #'my/pichat-display-chat-with-bufferlo
      pichat-sessions-display-chat-function
      #'my/pichat-display-chat-with-bufferlo)

(defun my/pichat-rebuild ()
  "Rebuild the local PiChat Elpaca package."
  (interactive)
  (elpaca-rebuild 'pichat t))

;; For local verification, PiChat defaults to launching:
;;   pi --mode rpc
;;
;; To verify with Docker later, set `pichat-rpc-command' and
;; `pichat-path-mappings', e.g.  A complete command remains authoritative, so
;; ephemeral and run-local-model profiles from `pichat-launch' are not yet
;; supported with this wrapper configuration.
;;
;; (setq pichat-rpc-command
;;       '("docker" "run" "--rm" "-i"
;;         "-v" "/home/mojo/.config/emacs.mine:/workspace"
;;         "-w" "/workspace"
;;         "my-pi-image"
;;         "pi" "--mode" "rpc"))
;;
;; (setq pichat-path-mappings
;;       '(("/home/mojo/.config/emacs.mine" . "/workspace")))

(with-eval-after-load 'evil
  ;; The package retains native Emacs bindings; this optional layer gives
  ;; PiChat's read-only views and runtime manager intentional Evil bindings.
  (with-eval-after-load 'pichat
    (require 'pichat-evil)
    (pichat-evil-setup)))

(with-eval-after-load 'pichat
  (general-define-key
   :states 'emacs
   :keymaps '(pichat-view-mode-map
              pichat-session-manager-mode-map)
   "SPC"
   (general-simulate-key
    "M-SPC"
    :state 'emacs
    :name my/pichat-space-leader
    :docstring "Open the leader menu in PiChat Emacs-state buffers."
    :which-key "leader")))

(sharmaso/leader-keys
  "x" '(:which-key "PiChat")
  "x p" '(pichat :which-key "Open current")
  "x g" '(pichat-global :which-key "Open global")
  "x n" '(pichat-launch :which-key "Launch runtime")
  "x l" '(pichat-session-manager :which-key "Manage sessions")
  "x j" '(pichat-jobs :which-key "Launch Jobs")
  "x b" '(pichat-sessions-browse-files :which-key "Browse saved sessions")
  "x s" '(pichat-status :which-key "Status")
  "x m" '(pichat-select-model :which-key "Select model")
  "x k" '(pichat-stop-session :which-key "Stop")
  "x r" '(pichat-add-reference :which-key "Add reference")
  "x S" '(pichat-smoke-test :which-key "Smoke test"))

;; Optional artifact adapter: PiChat itself has no Embark/Avy dependency.
(with-eval-after-load 'pichat-chat
  (require 'pichat-chat-artifacts)
  (require 'pichat-artifacts-embark))

(with-eval-after-load 'pichat
  (sharmaso/mode-keys
    :keymaps 'pichat-chat-mode-map
    "s" '(pichat-chat-send-input :which-key "Send")
    "a" '(pichat-chat-abort :which-key "Abort")
    "n" '(pichat-chat-new-session :which-key "New session")
    "m" '(pichat-chat-cycle-model :which-key "Cycle model")
    "t" '(pichat-chat-cycle-thinking-level :which-key "Cycle thinking")
    "r" '(pichat-chat-refresh-status :which-key "Refresh")
    "R" '(pichat-chat-repaint :which-key "Repaint")
    "b" '(pichat-sessions-switch-files :which-key "Switch saved session")
    "p" '(pichat-sessions-list :which-key "Session history")
    "[" '(pichat-sessions-return-to-origin :which-key "Return to source session")
    "]" '(pichat-sessions-forward-to-fork :which-key "Forward to fork")
    "z" '(pichat-chat-toggle-tool-at-point :which-key "Cycle tool display")
    "d" '(pichat-chat-show-tool-details :which-key "Tool details")
    "D" '(pichat-show-diagnostics :which-key "Diagnostics")
    "A" '(pichat-chat-select-visible-artifact :which-key "Select artifact")
    "x" '(pichat-command-run :which-key "Command picker")
    "o" '(pichat-chat-compact :which-key "Compact")
    "f" '(pichat-chat-follow-up :which-key "Follow up")
    "S" '(pichat-chat-steer :which-key "Steer"))
  (sharmaso/mode-keys
    :keymaps 'pichat-sessions-mode-map
    "/" '(pichat-sessions-search :which-key "Search history metadata")
    "F" '(pichat-sessions-cycle-filter :which-key "Cycle history filter")
    "v" '(pichat-sessions-preview-branch-at-point :which-key "Preview branch")
    "f" '(pichat-sessions-fork-at-point :which-key "Fork at entry")
    "C" '(pichat-sessions-clone-current :which-key "Clone current branch")
    "d" '(pichat-sessions-show-details-at-point :which-key "Entry details")
    "b" '(pichat-sessions-browse-files :which-key "Browse saved sessions")
    "r" '(pichat-sessions-list-refresh :which-key "Refresh history"))
  (sharmaso/mode-keys
    :keymaps 'pichat-session-manager-mode-map
    "v" '(pichat-session-manager-toggle-preview :which-key "Toggle preview")
    "n" '(pichat-session-manager-new :which-key "New runtime")
    "N" '(pichat-session-manager-new-in-scope :which-key "New in owner scope")
    "l" '(pichat-session-manager-launch :which-key "Launch runtime")
    "b" '(pichat-session-manager-browse-saved :which-key "Open saved independently")
    "e" '(pichat-session-manager-name :which-key "Name session")
    "k" '(pichat-session-manager-stop :which-key "Stop runtime")
    "d" '(pichat-session-manager-forget :which-key "Forget stopped runtime")
    "m" '(pichat-session-manager-make-default :which-key "Make preferred")
    "D" '(pichat-session-manager-diagnostics :which-key "Diagnostics")
    "r" '(pichat-session-manager-refresh :which-key "Refresh runtimes"))
  (sharmaso/mode-keys
    :keymaps 'pichat-sessions-preview-mode-map
    "f" '(pichat-sessions-preview-fork :which-key "Fork branch")
    "d" '(pichat-sessions-preview-show-details :which-key "Entry details")
    "t" '(pichat-sessions-preview-return-to-history :which-key "Return to history"))
  (sharmaso/mode-keys
    :keymaps 'pichat-session-manager-preview-mode-map
    "r" '(pichat-session-manager-preview-refresh :which-key "Refresh preview"))
  (sharmaso/mode-keys
    :keymaps 'pichat-diagnostics-mode-map
    "r" '(pichat-diagnostics-refresh :which-key "Refresh snapshot")
    "q" '(pichat-view-quit :which-key "Return"))
  (sharmaso/mode-keys
    :keymaps 'pichat-response-view-mode-map
    "r" '(pichat-response-view-refresh :which-key "Refresh response")
    "n" '(pichat-response-view-next :which-key "Next response")
    "p" '(pichat-response-view-previous :which-key "Previous response")
    "t" '(pichat-response-view-return-to-origin :which-key "Return to response")
    "w" '(pichat-response-view-copy-markdown :which-key "Copy Markdown")
    "y" '(pichat-response-view-copy-link-at-point :which-key "Copy link URL")))

(global-set-key (kbd "C-c p c") #'pichat)
(global-set-key (kbd "C-c p m") #'pichat-session-manager)
(global-set-key (kbd "C-c p b") #'pichat-sessions-browse-files)
(global-set-key (kbd "C-c p s") #'pichat-smoke-test)
(global-set-key (kbd "C-c p k") #'pichat-stop-session)
(global-set-key (kbd "C-c p r") #'pichat-add-reference)

(provide 'user-pichat)
;;; pichat.el ends here
