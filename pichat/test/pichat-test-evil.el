;;; pichat-test-evil.el --- Optional Evil key precedence tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with Evil on `load-path' to check effective keys, not just map entries.
;; The normal Emacs-only suite does not need Evil installed.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-evil-read-only-views-keep-vim-navigation-and-owned-quit ()
  (skip-unless (require 'evil nil t))
  (require 'pichat-evil)
  (require 'pichat-artifacts-embark)
  (let* ((was-active (bound-and-true-p evil-mode))
         (modes '(pichat-chat-mode pichat-chat-compose-mode
                  pichat-view-mode pichat-session-manager-mode))
         (previous-preview-hook
          (copy-sequence pichat-artifacts-preview-mode-hook))
         (previous (mapcar (lambda (mode)
                             (cons mode (evil-initial-state mode)))
                           modes)))
    (unwind-protect
        (progn
          (evil-mode 1)
          (pichat-evil-setup)
          (with-temp-buffer
            (pichat-chat-mode)
            (should (eq evil-state 'normal))
            (should (eq (key-binding (kbd "RET")) #'evil-ret))
            (should (eq (key-binding (kbd "C-c C-c"))
                        #'pichat-chat-send-input))
            (evil-insert-state)
            (should (eq (key-binding (kbd "RET")) #'pichat-chat-ret)))
          (with-temp-buffer
            (pichat-sessions-mode)
            (should (pichat-view-evil-normal-p))
            (should (eq evil-state 'normal))
            (dolist (binding '(("q" . pichat-sessions-return-to-chat)
                               ("RET" . pichat-sessions-activate-at-point)
                               ("j" . pichat-sessions-next-entry)
                               ("k" . pichat-sessions-previous-entry)
                               ("z a" . pichat-sessions-toggle-fold-at-point)
                               ("z v" . pichat-sessions-preview-branch-at-point)
                               ("g r" . pichat-sessions-list-refresh)
                               ("/" . evil-search-forward)
                               ("v" . evil-visual-char)))
              (should (eq (key-binding (kbd (car binding))) (cdr binding)))))
          (with-temp-buffer
            (pichat-sessions-preview-mode)
            (should (eq (key-binding (kbd "q")) #'pichat-view-quit))
            (should (eq (key-binding (kbd "f")) #'evil-find-char)))
          (with-temp-buffer
            (pichat-session-manager-mode)
            (should (eq evil-state 'normal))
            (should (eq (key-binding (kbd "q")) #'pichat-session-manager-quit))
            (should (eq (key-binding (kbd "RET"))
                        #'pichat-session-manager-open-chat))
            (should (eq (key-binding (kbd "g r"))
                        #'pichat-session-manager-refresh))
            (should (eq (key-binding (kbd "z v"))
                        #'pichat-session-manager-toggle-preview))
            (should (eq (key-binding (kbd "C-o")) #'evil-jump-backward)))
          (with-temp-buffer
            (pichat-session-manager-preview-mode)
            (should (eq (key-binding (kbd "q"))
                        #'pichat-session-manager-preview-quit)))
          (with-temp-buffer
            (pichat-response-view-mode)
            (should (eq (key-binding (kbd "q")) #'pichat-view-quit))
            (should (eq (key-binding (kbd "g r"))
                        #'pichat-response-view-refresh)))
          (with-temp-buffer
            (pichat-response-view-mode)
            (let ((inhibit-read-only t))
              (insert (propertize "one two" 'keymap
                                  pichat-response-view-link-map)))
            (goto-char (point-min))
            (should (eq (key-binding (kbd "w"))
                        #'pichat-response-view-link-word-or-copy))
            (call-interactively (key-binding (kbd "w")))
            (should (> (point) (point-min)))
            (let (searched)
              (cl-letf (((symbol-function 'evil-search-backward)
                         (lambda () (interactive) (setq searched t))))
                (call-interactively (key-binding (kbd "?"))))
              (should searched)))
          (save-window-excursion
            (let ((origin (generate-new-buffer " *pichat-evil-origin*"))
                  (snapshot (generate-new-buffer " *pichat-evil-snapshot*")))
              (unwind-protect
                  (progn
                    (switch-to-buffer origin)
                    (with-current-buffer snapshot (pichat-view-mode))
                    (pichat-view-display snapshot nil 'kill)
                    (call-interactively (key-binding (kbd "q")))
                    (should-not (buffer-live-p snapshot))
                    (should (eq origin (window-buffer (selected-window)))))
                (dolist (buffer (list origin snapshot))
                  (when (buffer-live-p buffer) (kill-buffer buffer))))))
          (with-temp-buffer
            (if (require 'markdown-mode nil t)
                (markdown-mode)
              (text-mode))
            (pichat-artifacts-preview-mode 1)
            (should (eq evil-state 'normal))
            (should (eq (key-binding (kbd "q")) #'pichat-view-quit))))
      (dolist (entry previous)
        (evil-set-initial-state (car entry) (cdr entry)))
      (setq pichat-artifacts-preview-mode-hook previous-preview-hook)
      (unless was-active (evil-mode -1)))))

(provide 'pichat-test-evil)
;;; pichat-test-evil.el ends here
