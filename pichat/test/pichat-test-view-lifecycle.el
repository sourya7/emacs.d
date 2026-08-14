;;; pichat-test-view-lifecycle.el --- Auxiliary view window tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Real multi-window coverage for the shared PiChat auxiliary-view lifecycle.

;;; Code:

(require 'pichat-test-support)

(defmacro pichat-test-view--with-windows (&rest body)
  "Run BODY with one window and restore all buffers and windows afterward."
  (declare (indent 0) (debug body))
  `(save-window-excursion
     (delete-other-windows)
     ,@body))

(defun pichat-test-view--pop-up-action ()
  "Return a display action that creates an auxiliary window."
  '((display-buffer-pop-up-window) (inhibit-same-window . t)))

(ert-deftest pichat-view-lifecycle-restores-replaced-buffer ()
  (pichat-test-view--with-windows
    (let ((origin (generate-new-buffer " *pichat-view-origin*"))
          (view (generate-new-buffer " *pichat-view-replaced*"))
          (display-buffer-overriding-action '((display-buffer-same-window))))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (pichat-view-display view nil 'bury)
            (should (= 1 (count-windows)))
            (should (eq view (window-buffer)))
            (pichat-view-return)
            (should (= 1 (count-windows)))
            (should (eq origin (window-buffer (selected-window)))))
        (dolist (buffer (list origin view))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-view-lifecycle-removes-created-split-and-reuses-target ()
  (pichat-test-view--with-windows
    (let ((origin (generate-new-buffer " *pichat-view-origin*"))
          (view (generate-new-buffer " *pichat-view-split*"))
          (display-buffer-overriding-action
           (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (pichat-view-display view nil 'bury)
            (should (= 2 (count-windows)))
            (should (get-buffer-window origin))
            (pichat-view-return origin)
            (should (= 1 (count-windows)))
            (should (eq origin (window-buffer (selected-window)))))
        (dolist (buffer (list origin view))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-view-lifecycle-preserves-unrelated-later-window ()
  (pichat-test-view--with-windows
    (let ((origin (generate-new-buffer " *pichat-view-origin*"))
          (view (generate-new-buffer " *pichat-view-owned*"))
          (unrelated (generate-new-buffer " *pichat-view-unrelated*"))
          (display-buffer-overriding-action
           (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (pichat-view-display view nil 'bury)
            (let ((view-window (selected-window))
                  (origin-window (get-buffer-window origin)))
              (select-window origin-window)
              (set-window-buffer (split-window origin-window) unrelated)
              (should (= 3 (count-windows)))
              (select-window view-window)
              (pichat-view-return origin))
            (should (= 2 (count-windows)))
            (should (get-buffer-window unrelated))
            (should (eq origin (window-buffer (selected-window)))))
        (dolist (buffer (list origin view unrelated))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-view-lifecycle-completes-nested-chain ()
  (pichat-test-view--with-windows
    (let ((target (generate-new-buffer " *pichat-view-target*"))
          (history (generate-new-buffer " *pichat-view-history*"))
          (preview (generate-new-buffer " *pichat-view-preview*"))
          (display-buffer-overriding-action
           (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (switch-to-buffer target)
            (pichat-view-display history nil 'bury)
            (pichat-view-display preview nil 'bury)
            ;; Emacs may replace History in its auxiliary window rather than
            ;; create a third window; the recorded origin chain remains nested.
            (should (= 2 (count-windows)))
            (should (eq history
                        (pichat-view-presentation-origin-buffer
                         (pichat-view-presentation preview))))
            (pichat-view-complete target preview)
            (should (= 1 (count-windows)))
            (should (eq target (window-buffer (selected-window)))))
        (dolist (buffer (list target history preview))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-view-lifecycle-does-not-reclaim-repurposed-window ()
  (pichat-test-view--with-windows
    (let ((target (generate-new-buffer " *pichat-view-target*"))
          (view (generate-new-buffer " *pichat-view-moved*"))
          (unrelated (generate-new-buffer " *pichat-view-repurposed*"))
          (display-buffer-overriding-action
           (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (switch-to-buffer target)
            (pichat-view-display view nil 'bury)
            (set-window-buffer (selected-window) unrelated)
            (pichat-view-complete target view)
            (should (= 2 (count-windows)))
            (should (get-buffer-window unrelated))
            (should (eq target (window-buffer (selected-window)))))
        (dolist (buffer (list target view unrelated))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-view-lifecycle-handles-dead-origin-and-kill-policy ()
  (pichat-test-view--with-windows
    (let ((origin (generate-new-buffer " *pichat-view-dead-origin*"))
          (view (generate-new-buffer " *pichat-view-killed*"))
          (display-buffer-overriding-action
           (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (pichat-view-display view nil 'kill)
            (kill-buffer origin)
            (should (condition-case nil
                        (progn (pichat-view-quit) t)
                      (error nil)))
            (should-not (buffer-live-p view))
            (should (= 1 (count-windows))))
        (dolist (buffer (list origin view))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-sessions-history-quit-removes-owned-split ()
  (pichat-test-view--with-windows
    (let* ((session (pichat-session-make))
           (chat (generate-new-buffer " *pichat-view-chat*"))
           (history (generate-new-buffer " *pichat-view-history*"))
           (display-buffer-overriding-action
            (pichat-test-view--pop-up-action)))
      (unwind-protect
          (progn
            (setf (pichat-session-buffer session) chat)
            (with-current-buffer history
              (pichat-sessions-mode)
              (setq-local pichat-sessions-session session))
            (switch-to-buffer chat)
            (pichat-view-display history nil 'bury)
            (should (= 2 (count-windows)))
            (pichat-sessions-return-to-chat)
            (should (= 1 (count-windows)))
            (should (eq chat (window-buffer (selected-window)))))
        (dolist (buffer (list chat history))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-view-lifecycle)
;;; pichat-test-view-lifecycle.el ends here
