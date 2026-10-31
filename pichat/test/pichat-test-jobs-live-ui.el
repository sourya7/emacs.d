;;; pichat-test-jobs-live-ui.el --- Isolated graphical jobs checks -*- lexical-binding: t; -*-

;;; Commentary:
;; Opt-in separate Emacs only; not loaded by the regular suite.  No user state,
;; real provider, or user's live Emacs is used.  These drive controls/geometry;
;; they do not replace visible human layout review.  See TESTING_GUIDELINES.md.

;;; Code:
(require 'pichat-test-job-support)
(require 'pichat-jobs)

(ert-deftest pichat-integration-jobs-live-ui-manual-flow ()
  (should (display-graphic-p))
  (pichat-test-with-job-executor
      (:script '(:turns [(:text "LIVE_JOB_RESULT" :delayMs 100)]))
    (let ((pichat-jobs--executor executor)
          (pichat-jobs-file (pichat-job-store-file store))
          (origin (window-buffer (selected-window))) setup job)
      (unwind-protect
          (progn
            (call-interactively #'pichat-job-new)
            (setq setup (current-buffer))
            (should (derived-mode-p 'pichat-job-setup-mode))
            (call-interactively (key-binding (kbd "C-c C-e")))
            (insert "Inspect the supplied files.\nExplain the result briefly.")
            (call-interactively (key-binding (kbd "C-c C-c")))
            (should (eq (current-buffer) setup))
            (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Live review")))
              (pichat-test-job-press "Save job…"))
            (setq job (plist-get (aref (pichat-job-records store 'jobs) 0) :id))
            (should (equal (pichat-job-records store 'runs) []))
            (pichat-test-job-press "Run once")
            (should (eq (current-buffer) origin))
            (let* ((id (plist-get (aref (pichat-job-records store 'runs) 0) :id))
                   (execution (gethash id (pichat-job-executor-contexts executor))))
              (pichat-test-job-wait store id "finished")
              (should (eq (current-buffer) origin))
              (should-not (get-buffer-window
                           (pichat-session-buffer (pichat-job-execution-session execution)) t))
              (call-interactively #'pichat-jobs)
              (call-interactively (key-binding (kbd "TAB")))
              (goto-char (point-min))
              (call-interactively (key-binding (kbd "RET")))
              (should (string-match-p "LIVE_JOB_RESULT" (buffer-string)))
              (should-not (string-match-p (regexp-quote pichat-test-fake-provider-extension) (buffer-string)))
              (pichat-test-job-press "Instructions & settings")
              (should (string-match-p "Explain the result briefly" (buffer-string)))
              (pichat-test-job-press "Inspect raw settings (sensitive)…")
              (should (string-match-p (regexp-quote pichat-test-fake-provider-extension) (buffer-string)))
              (call-interactively (key-binding (kbd "q")))
              (call-interactively (key-binding (kbd "q")))
              (pichat-test-job-press "Open chat")
              (should (eq pichat-chat-session (pichat-job-execution-session execution))))
            (pichat-test-assert-provider-script-consumed status-file)
            (with-temp-file script-file (insert "{\"turns\":[{\"text\":\"SAVED_JOB_RESULT\",\"delayMs\":100}]}"))
            ;; The saved definition is distinct from the unsaved Run once.
            (call-interactively #'pichat-jobs)
            (call-interactively (key-binding (kbd "TAB")))
            (goto-char (point-min))
            (call-interactively (key-binding (kbd "RET")))
            (should (string-match-p "Never run" (buffer-string)))
            (let ((details (current-buffer)))
              (pichat-test-job-press "Run job")
              (let ((id (plist-get (pichat-jobs--latest store job) :id)))
                (pichat-test-job-wait store id "finished")
                (should (eq (current-buffer) details))
                (pichat-test-job-press "Open latest run")
                (should (equal pichat-jobs--detail (cons 'runs id)))
                (should (string-match-p "SAVED_JOB_RESULT" (buffer-string)))))
            (pichat-test-job-press "Job history")
            (should (= (length tabulated-list-entries) 1))
            (should (string-match-p job mode-line-process))
            ;; Real window sizes, not a mocked formatter width.
            (delete-other-windows)
            (dolist (width '(70 140))
              (set-frame-width (selected-frame) width)
              (pichat-test-wait-until
               (lambda () (if (< width 110) (< (window-body-width) 110)
                            (>= (window-body-width) 110)))
               3 "graphical Jobs window to resize")
              (pichat-jobs-refresh)
              (should (string-match-p "local" (buffer-string)))
              (if (< width 110)
                  (should-not (string-match-p "Queued UTC" (format-mode-line header-line-format)))
                (should (string-match-p "Queued UTC" (format-mode-line header-line-format)))))
            (call-interactively (key-binding (kbd "TAB")))
            (should (equal (tabulated-list-get-id) job))
            (pichat-test-assert-provider-script-consumed status-file))
        (maphash (lambda (_id execution) (pichat-job-executor--retire execution))
                 (pichat-job-executor-contexts executor))
        (dolist (buffer (buffer-list))
          (when (and (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (or (eq pichat-jobs--owner executor)
                           (bound-and-true-p pichat-job-executor--buffer-execution))))
            (kill-buffer buffer)))))))

(ert-deftest pichat-integration-jobs-live-ui-attention-and-uncertainty ()
  (should (display-graphic-p))
  ;; Cached attention states use an inert owned process, not a model/provider.
  (pichat-test-with-owned-job
    (let ((waiter (pichat-job-enqueue store (pichat-test-job-spec project-dir)))
          (chat (pichat-chat-ensure session)) confirmation)
      (pichat-jobs--show-detail executor 'runs waiter)
      (pichat-test-job-press "Open blocking run")
      (should (equal pichat-jobs--detail (cons 'runs id)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (setq confirmation prompt) nil)))
        (pichat-test-job-press "Cancel run…"))
      (should (string-match-p (regexp-quote project-dir) confirmation))
      (should (string-match-p "local" confirmation))
      (pichat-job-executor--advance execution "running")
      (with-current-buffer chat
        (pichat-chat--on-extension-ui-request
         session 'extension-ui-request
         '(:raw (:type "extension_ui_request" :id "live-input" :method "input"
                       :title "Review required"))))
      (pichat-jobs--render-detail)
      (should (string-match-p "Needs input" (buffer-string)))
      (should (string-match-p "Review required" (buffer-string)))
      (should-not (get-buffer-window chat t))
      (should-not (active-minibuffer-window))
      (setf (pichat-job-execution-cancelling execution) t)
      (pichat-job-executor--advance execution "settling")
      (should (string-match-p "Execution: Cancelling" (buffer-string)))
      (pichat-job-executor--advance execution "uncertain" '(:reason "Inspect descendants/workspace"))
      (should (string-match-p "Held resource:" (buffer-string)))
      (should (string-match-p "recheck unavailable" (buffer-string)))
      (should-not (string-match-p "Recheck remote Pi exit" (buffer-string)))
      (should-not (eq (plist-get (pichat-job-admission store waiter) :ready) t)))))

(provide 'pichat-test-jobs-live-ui)
;;; pichat-test-jobs-live-ui.el ends here
