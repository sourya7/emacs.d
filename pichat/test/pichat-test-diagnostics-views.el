;;; pichat-test-diagnostics-views.el --- Owned diagnostic views -*- lexical-binding: t; -*-

;;; Commentary:

;; Runtime ownership and auxiliary display lifecycle, without Pi processes.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-chat-diagnostics)

(ert-deftest pichat-diagnostics-views-coexist-and-reuse-runtime-not-source ()
  (pichat-test-with-clean-state
    (let ((a (pichat-register-session (pichat-session-make :state 'stopped)))
          (b (pichat-register-session (pichat-session-make :state 'error)))
          buffers)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (dolist (show '(pichat-show-diagnostics pichat-show-transport-diagnostics))
              (let ((av (funcall show a)) (bv (funcall show b)))
                (push av buffers)
                (push bv buffers)
                (should-not (eq av bv))
                (should (string-match-p (pichat-session-runtime-id a)
                                        (buffer-name av)))
                (setf (pichat-session-id a) "a-different-pi-session")
                (should (eq av (funcall show a)))
                (with-current-buffer av
                  (should buffer-read-only)
                  (should (derived-mode-p 'pichat-diagnostics-mode))
                  (should (derived-mode-p 'pichat-view-mode))
                  (should (eq a pichat-diagnostics--owner)))
                (with-current-buffer bv
                  (should (eq b pichat-diagnostics--owner))))))
        (mapc #'kill-buffer buffers)))))

(ert-deftest pichat-diagnostics-reinvocation-retains-owner-after-stop ()
  (pichat-test-with-clean-state
    (let* ((a (pichat-register-session (pichat-session-make :state 'idle)))
           (b (pichat-register-session (pichat-session-make)))
           (pichat-current-session b)
           safe raw)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore)
                    ((symbol-function 'pichat-session-for-directory)
                     (lambda (&rest _) b)))
            (setq safe (pichat-show-diagnostics a))
            (setf (pichat-session-state a) 'stopped)
            (with-current-buffer safe
              (should (eq safe (pichat-show-diagnostics)))
              (should (string-match-p "State: stopped" (buffer-string)))
              (setq raw (pichat-show-transport-diagnostics)))
            (with-current-buffer raw
              (should (eq a pichat-diagnostics--owner))
              (should (eq raw (pichat-show-transport-diagnostics)))
              (should (eq safe (pichat-show-diagnostics)))))
        (when (buffer-live-p safe) (kill-buffer safe))
        (when (buffer-live-p raw) (kill-buffer raw))))))

(ert-deftest pichat-diagnostics-forgotten-owner-preserves-snapshots-rejects-actions ()
  (pichat-test-with-clean-state
    (let* ((a (pichat-register-session (pichat-session-make :state 'stopped)))
           (b (pichat-register-session (pichat-session-make)))
           (pichat-current-session b)
           buffers)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq buffers (list (pichat-show-diagnostics a)
                                (pichat-show-transport-diagnostics a)))
            (pichat-forget-session a)
            (dolist (buffer buffers)
              (with-current-buffer buffer
                (let ((snapshot (buffer-string)))
                  (dolist (action '(pichat-show-diagnostics
                                    pichat-show-transport-diagnostics
                                    pichat-diagnostics-open-settings
                                    pichat-diagnostics-probe-pi
                                    pichat-diagnostics-open-interactive-pi))
                    (let ((err (should-error (funcall action) :type 'user-error)))
                      (should (string-match-p "no longer registered"
                                              (error-message-string err))))
                    (should (equal snapshot (buffer-string))))))))
        (mapc #'kill-buffer buffers)))))

(ert-deftest pichat-diagnostics-setup-actions-receive-inspected-owner ()
  (pichat-test-with-clean-state
    (let* ((a (pichat-register-session (pichat-session-make :state 'stopped)))
           (b (pichat-register-session (pichat-session-make)))
           (pichat-current-session b)
           buffer seen)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq buffer (pichat-show-diagnostics a))
            (with-current-buffer buffer
              ;; Stop at the capability boundary before any file/process I/O.
              (cl-letf (((symbol-function 'pichat-backend-require-capability)
                         (lambda (owner &rest _)
                           (push owner seen)
                           (user-error "Captured action owner"))))
                (dolist (action '(pichat-diagnostics-open-settings
                                  pichat-diagnostics-probe-pi
                                  pichat-diagnostics-open-interactive-pi))
                  (should-error (funcall action) :type 'user-error))))
            (should (equal seen (list a a a))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-diagnostics-safe-identity-excludes-paths-and-unsafe-labels ()
  (let* ((transport (pichat-transport--create
                     :id 'target :kind 'local :label "token=label-secret\n/secret"
                     :pi-executable "/secret/pi"))
         (session (pichat-session-make
                   :transport transport :cwd "/secret/project/"
                   :rpc-command '("pi" "--secret") :state 'error))
         buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
          (setq buffer (pichat-show-diagnostics session))
          (with-current-buffer buffer
            (let ((text (buffer-string)))
              (should (string-match-p (pichat-session-runtime-id session) text))
              (should (string-match-p "Backend: pi\nTarget: target (local)" text))
              (should (string-match-p "State: error\nSnapshot: [0-9].*Z" text))
              (should-not (string-match-p "secret\|label-secret" text)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest pichat-diagnostics-nested-quit-returns-through-safe-view-after-refresh ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let ((session (pichat-register-session (pichat-session-make :state 'stopped)))
            (origin (generate-new-buffer " *diagnostics-origin*"))
            safe raw)
        (unwind-protect
            (progn
              (switch-to-buffer origin)
              (setq safe (pichat-show-diagnostics session))
              (should (eq safe (window-buffer (selected-window))))
              ;; Reopening in place must not replace the origin with itself.
              (pichat-show-diagnostics)
              (setq raw (pichat-show-transport-diagnostics))
              (should (eq raw (window-buffer (selected-window))))
              (pichat-show-transport-diagnostics)
              (call-interactively (key-binding (kbd "q")))
              (should (eq safe (window-buffer (selected-window))))
              (should (buffer-live-p raw))
              (call-interactively (key-binding (kbd "q")))
              (should (eq origin (window-buffer (selected-window))))
              (should (buffer-live-p safe)))
          (dolist (buffer (list safe raw origin))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(provide 'pichat-test-diagnostics-views)
;;; pichat-test-diagnostics-views.el ends here
