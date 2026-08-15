;;; pichat.el --- Local PiChat setup -*- lexical-binding: t; -*-

;;; Commentary:

;; Local integration for the in-repo PiChat package.

;;; Code:

(require 'cl-lib)

(use-package visual-fill-column
  :defer t)

;; Development-only dependency used by pichat/test/run-coverage.sh.  Keeping it
;; deferred avoids loading coverage instrumentation in normal Emacs sessions.
(use-package undercover
  :defer t)

(use-package pichat
  :ensure `(:type file
            :main ,(my/emacs-main-dir "pichat/pichat.el")
            :files ("*.el"
                    ("bridge" "bridge/pichat-bridge.ts"))
            :inherit nil)
  :commands (pichat pichat-global pichat-launch pichat-session-manager
                    pichat-sessions-browse-files pichat-status
                    pichat-select-model pichat-stop-session
                    pichat-add-reference pichat-smoke-test))

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
                      ("\\`\\*PiChat Sessions" (display-buffer-same-window))))

(declare-function bufferlo-local-buffer-p "bufferlo"
                  (buffer &optional frame tabnum include-hidden))
(declare-function bufferlo-find-buffer-switch "bufferlo" (buffer-or-name))

(defun my/pichat-bufferlo-local-anywhere-p (buffer)
  "Return non-nil when BUFFER belongs to any Bufferlo frame/tab list."
  (and (fboundp 'bufferlo-local-buffer-p)
       (cl-some
        (lambda (frame)
          (let ((tabs (funcall tab-bar-tabs-function frame)))
            (if tabs
                (cl-loop for index below (length tabs)
                         thereis (bufferlo-local-buffer-p
                                  buffer frame index t))
              (bufferlo-local-buffer-p buffer frame nil t))))
        (frame-list))))

(defun my/pichat-project-tab-name (session)
  "Return the configured project-tab name for SESSION's owner directory."
  (when-let ((directory (pichat-session-owner-directory session)))
    (unless (or (equal (pichat-session-owner-scope-key session) "global")
                (string-prefix-p
                 "global|" (or (pichat-session-owner-scope-key session) "")))
      (file-name-nondirectory (directory-file-name directory)))))

(defun my/pichat-tab-name-exists-p (name)
  "Return non-nil when the selected frame has a tab named NAME."
  (cl-some (lambda (tab) (equal name (alist-get 'name tab)))
           (funcall tab-bar-tabs-function (selected-frame))))

(defun my/pichat-display-chat-with-bufferlo (session)
  "Display SESSION in an existing Bufferlo location or its project tab."
  (let ((buffer (pichat-session-buffer session)))
    (cond
     ((and (buffer-live-p buffer)
           (fboundp 'bufferlo-find-buffer-switch)
           (my/pichat-bufferlo-local-anywhere-p buffer))
      (bufferlo-find-buffer-switch buffer))
     ((and (fboundp 'tab-bar-switch-to-tab)
           (my/pichat-project-tab-name session))
      (let ((name (my/pichat-project-tab-name session)))
        (if (my/pichat-tab-name-exists-p name)
            (tab-bar-switch-to-tab name)
          (tab-bar-new-tab)
          (tab-bar-rename-tab name))
        (pichat-session-manager-display-chat-current-tab session)))
     (t
      (pichat-session-manager-display-chat-current-tab session)))))

(setq pichat-session-manager-display-chat-function
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
  ;; Editable PiChat buffers start in Normal state.  Read-only views use Emacs
  ;; state so their documented single-key commands override Evil keys.
  (evil-set-initial-state 'pichat-chat-mode 'normal)
  (evil-set-initial-state 'pichat-chat-compose-mode 'normal)
  (evil-set-initial-state 'pichat-view-mode 'emacs)
  (evil-set-initial-state 'pichat-session-manager-mode 'emacs))

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
    "b" '(pichat-sessions-browse-files :which-key "Browse saved sessions")
    "p" '(pichat-sessions-list :which-key "Session history")
    "[" '(pichat-sessions-return-to-origin :which-key "Return to source session")
    "]" '(pichat-sessions-forward-to-fork :which-key "Forward to fork")
    "z" '(pichat-chat-toggle-tool-at-point :which-key "Cycle tool display")
    "d" '(pichat-chat-show-tool-details :which-key "Tool details")
    "J" '(pichat-chat-next-tool :which-key "Next tool")
    "K" '(pichat-chat-previous-tool :which-key "Previous tool")
    "x" '(pichat-command-run :which-key "Command picker")
    "o" '(pichat-chat-compact :which-key "Compact")
    "f" '(pichat-chat-follow-up :which-key "Follow up")
    "S" '(pichat-chat-steer :which-key "Steer")))

(global-set-key (kbd "C-c p c") #'pichat)
(global-set-key (kbd "C-c p m") #'pichat-session-manager)
(global-set-key (kbd "C-c p b") #'pichat-sessions-browse-files)
(global-set-key (kbd "C-c p s") #'pichat-smoke-test)
(global-set-key (kbd "C-c p k") #'pichat-stop-session)
(global-set-key (kbd "C-c p r") #'pichat-add-reference)

(provide 'user-pichat)
;;; pichat.el ends here
