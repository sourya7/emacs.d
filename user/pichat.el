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
  :demand t
  :ensure `(:type file
            :main ,(my/emacs-main-dir "pichat/pichat.el")
            :files ("*.el"
                    ("bridge" "bridge/pichat-bridge.ts"
                              "bridge/pichat-tool-control.ts"))
            :inherit nil)
  :custom
  (pichat-jobs-file (my/emacs-local-dir "pichat/jobs.json"))
  :commands (pichat pichat-global pichat-launch pichat-session-manager
                    pichat-sessions-browse-files pichat-sessions-switch-files
                    pichat-status
                    pichat-select-model pichat-stop-session
                    pichat-add-reference pichat-smoke-test))

(setq pichat-append-system-prompt
      "Prefer bare URLs over descriptive Markdown links.
Prefer bullets unless a table materially helps comparison.
Keep tables narrow and pad columns for monospace readability.")

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

(my/add-all-to-list 'display-buffer-alist
                    '(("\\`\\*PiChat:" (display-buffer-same-window))
                      ("\\`\\*PiChat Sessions" (display-buffer-same-window))
                      ("\\`\\*PiChat Response:" (display-buffer-same-window))))

(declare-function bufferlo-local-buffer-p "bufferlo"
                  (buffer &optional frame tabnum include-hidden))
(defun my/pichat-bufferlo-location (buffer)
  "Return one frame and tab containing BUFFER, without prompting."
  (when (and (buffer-live-p buffer) (fboundp 'bufferlo-local-buffer-p))
    (cl-loop for frame in (cons (selected-frame)
                                (delq (selected-frame) (frame-list)))
             unless (frame-parameter frame 'no-accept-focus)
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
