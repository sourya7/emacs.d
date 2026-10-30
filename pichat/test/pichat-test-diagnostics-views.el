;;; pichat-test-diagnostics-views.el --- Owned diagnostic views -*- lexical-binding: t; -*-

;;; Commentary:

;; Runtime ownership, cached refresh, safe metadata, raw navigation and
;; auxiliary display lifecycle, without Pi processes.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-chat-diagnostics)
(require 'pichat-sessions)

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
                  (dolist (action '(pichat-diagnostics-refresh
                                    pichat-show-diagnostics
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

(ert-deftest pichat-diagnostics-refresh-reads-current-caches-only ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-register-session (pichat-session-make :id "source-a")))
           (other (pichat-register-session (pichat-session-make)))
           (pichat-current-session other)
           (chat (generate-new-buffer " *cached-chat*"))
           (history (generate-new-buffer " *cached-history*"))
           (pichat-diagnostics-section-functions
            '(pichat-chat--diagnostic-sections pichat-sessions--diagnostic-sections))
           report)
      (unwind-protect
          (progn
            (with-current-buffer chat
              ;; Inert cache fixture; do not initialize chat or start a runtime.
              (setq major-mode 'pichat-chat-mode)
              (setq-local pichat-chat-session session
                          pichat-chat--source-bound-p t
                          pichat-chat--source-session-id "source-a"
                          pichat-chat--source-session-file nil
                          pichat-chat--canonical-transcript
                          (pichat-transcript-create :diagnostics nil)
                          pichat-chat--live-draft (pichat-live-draft-create)))
            (setf (pichat-session-buffer session) chat)
            (with-current-buffer history
              (setq major-mode 'pichat-sessions-mode)
              (setq-local pichat-sessions-session session
                          pichat-sessions--source-token
                          (pichat-sessions--session-source-token session)
                          pichat-sessions--diagnostics nil))
            (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
              (setq report (pichat-show-diagnostics session)))
            (pichat-chat-diagnostics-record
             session :origin 'rpc-response :message "token=hidden-summary"
             :stderr "private-stderr" :command '("private-command")
             :response '(:secret "private-response"))
            (with-current-buffer chat
              (setf (pichat-transcript-diagnostics pichat-chat--canonical-transcript)
                    (list (pichat-diagnostic-create :summary "canonical-notice")))
              (setf (pichat-live-draft-diagnostics pichat-chat--live-draft)
                    (list (pichat-diagnostic-create :summary "live-notice"))))
            (with-current-buffer history
              (setq pichat-sessions--diagnostics
                    (list (pichat-diagnostic-create :summary "history-notice"))))
            (setf (pichat-session-event-log session) '((:secret "private-event")))
            (let ((before (copy-tree (pichat-session-diagnostics session)))
                  (events (copy-tree (pichat-session-event-log session)))
                  (no-io (lambda (&rest _) (error "Refresh attempted I/O or raw rendering"))))
              (cl-letf (((symbol-function 'pichat-rpc-send) no-io)
                        ((symbol-function 'pichat-backend-get-transcript) no-io)
                        ((symbol-function 'pichat-rpc-get-tree) no-io)
                        ((symbol-function 'pichat-transport-make-process) no-io)
                        ((symbol-function 'make-network-process) no-io)
                        ((symbol-function 'make-process) no-io)
                        ((symbol-function 'start-process) no-io)
                        ((symbol-function 'process-file) no-io)
                        ((symbol-function 'call-process) no-io)
                        ((symbol-function 'pichat-chat-diagnostics--print-value) no-io))
                (with-current-buffer report
                  (call-interactively (key-binding (kbd "g")))
                  (let ((text (buffer-string)))
                    (dolist (notice '("canonical-notice" "live-notice" "history-notice"))
                      (should (string-match-p notice text)))
                    (should (string-match-p "REDACTED" text))
                    (should-not (string-match-p "hidden-summary\\|private-" text)))
                  (should (= (point) (point-min)))
                  ;; Source rebinding drops source-bound sections, not failures.
                  (setf (pichat-session-id session) "source-b")
                  (pichat-diagnostics-refresh)
                  (let ((text (buffer-string)))
                    (dolist (title '("Canonical transcript" "Live tail" "Session History"))
                      (should (string-match-p (concat title "\n  unavailable") text)))
                    (should-not (string-match-p "canonical-notice\\|live-notice\\|history-notice" text))
                    (should (string-match-p "REDACTED" text))))
                (should (equal before (pichat-session-diagnostics session)))
                (should (equal events (pichat-session-event-log session))))))
        (setf (pichat-session-buffer session) nil)
        (dolist (buffer (list report chat history))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-diagnostics-safe-status-and-optional-record-metadata ()
  (let* ((session (pichat-session-make))
         (pichat-diagnostics-section-functions
          (list (lambda (_session)
                  '(("Canonical transcript"
                     (:severity warning :category compatibility :summary "no-time")
                     "legacy-notice"
                     (:summary "bad-time" :time invalid)
                     (:severity "token=hidden" :category "/private/path"
                      :summary "safe-labels"))
                    ("Live tail")))))
         report)
    (setf (pichat-session-diagnostics session)
          (list (list :severity 'error :category 'missing-credential
                      :summary "failure-notice" :time (encode-time 5 4 3 2 1 2020 t))))
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
          (setq report (pichat-show-diagnostics session))
          (with-current-buffer report
            (let ((text (buffer-string)))
              (should (string-match-p "cached snapshot, not a live health check" text))
              (should (string-match-p "not necessarily a failure" text))
              (should (string-match-p "Live tail\n  none" text))
              (should (string-match-p "Session History\n  unavailable" text))
              (should (string-match-p
                       (regexp-quote "[error/missing-credential; 2020-01-02T03:04:05Z] failure-notice") text))
              (should (string-match-p (regexp-quote "[warning/compatibility] no-time") text))
              (should (string-match-p "\n  legacy-notice\n  bad-time\n" text))
              (should-not (string-match-p "hidden\\|/private/path" text)))))
      (when (buffer-live-p report) (kill-buffer report)))))

(ert-deftest pichat-diagnostics-raw-action-confirms-and-refreshes-bounded-owner-snapshot ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let* ((session (pichat-register-session (pichat-session-make :state 'stopped)))
             (other (pichat-register-session (pichat-session-make)))
             (pichat-current-session other)
             (origin (generate-new-buffer " *diagnostics-ui-origin*"))
             (pichat-diagnostics-view-event-limit 1)
             (pichat-diagnostics-view-value-limit 80)
             safe raw prompt)
        (unwind-protect
            (progn
              (switch-to-buffer origin)
              (setq safe (pichat-show-diagnostics session))
              (should-not (get-buffer (format "*PiChat Transport Diagnostics %s*"
                                             (pichat-session-runtime-id session))))
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (text) (setq prompt text) nil)))
                (call-interactively (key-binding (kbd "r"))))
              (should (string-match-p "secrets, paths and prompt content" prompt))
              (should (eq safe (current-buffer)))
              (should-not (get-buffer (format "*PiChat Transport Diagnostics %s*"
                                             (pichat-session-runtime-id session))))
              (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
                (setq raw (call-interactively (key-binding (kbd "r")))))
              (should (eq raw (current-buffer)))
              (should (eq session pichat-diagnostics--owner))
              (should (= (point) (point-min)))
              (should (string-match-p "WARNING" (buffer-string)))
              (setf (pichat-session-event-log session)
                    `((:type "new-event" :raw ,(make-string 200 ?x))
                      (:type "old-event")))
              (call-interactively (key-binding (kbd "g")))
              (should (string-match-p "new-event" (buffer-string)))
              (should-not (string-match-p "old-event" (buffer-string)))
              (should (string-match-p "truncated by PiChat" (buffer-string)))
              (call-interactively (key-binding (kbd "q")))
              (should (eq safe (current-buffer)))
              (pichat-diagnostics-refresh)
              (call-interactively (key-binding (kbd "q")))
              (should (eq origin (current-buffer))))
          (dolist (buffer (list safe raw origin))
            (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest pichat-diagnostics-raw-action-revalidates-owner-after-warning ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :state 'stopped)))
          report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (pichat-forget-session session) t)))
                (should-error (pichat-diagnostics-show-raw) :type 'user-error))
              (cl-letf (((symbol-function 'y-or-n-p)
                         (lambda (&rest _) (ert-fail "Prompted for forgotten owner"))))
                (should-error (pichat-diagnostics-show-raw) :type 'user-error)))
            (should-not (get-buffer (format "*PiChat Transport Diagnostics %s*"
                                           (pichat-session-runtime-id session)))))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-refresh-requires-an-inspector ()
  (with-temp-buffer
    (should-error (pichat-diagnostics-refresh) :type 'user-error)
    (should-error (pichat-diagnostics-show-raw) :type 'user-error)))

(ert-deftest pichat-diagnostics-setup-chooser-targets-owner-and-labels-side-effects ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-register-session (pichat-session-make :state 'stopped)))
           (other (pichat-register-session (pichat-session-make)))
           (pichat-current-session other)
           report seen choices)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (setq choices collection)
                           (caar collection)))
                        ((symbol-function 'pichat-diagnostics-probe-pi)
                         (lambda (owner) (push owner seen))))
                (call-interactively (key-binding (kbd "s"))))
              (should (equal seen (list session)))
              (should (= 4 (length choices)))
              (should (string-match-p "process; not RPC/auth/model health" (caar choices)))
              (should (string-match-p "separate terminal" (car (nth 1 choices))))
              (should (string-match-p "editable" (car (nth 2 choices))))
              (dolist (action '(pichat-diagnostics-open-interactive-pi
                                pichat-diagnostics-open-settings))
                (cl-letf (((symbol-function 'completing-read)
                           (lambda (_prompt collection &rest _)
                             (car (rassq action collection))))
                          ((symbol-function action)
                           (lambda (owner) (should (eq owner session)))))
                  (pichat-diagnostics-setup)))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (car (rassq 'pichat-diagnostics-customize collection))))
                        ((symbol-function 'customize-group)
                         (lambda (group &rest _) (should (eq group 'pichat)))))
                (pichat-diagnostics-setup))))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-setup-chooser-explains-unsupported-pi-actions ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :backend 'no-pi)))
          report customized)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (prompt collection &rest _)
                           (should (string-match-p "Pi actions unavailable" prompt))
                           (should (equal collection
                                          '(("Customize PiChat" . pichat-diagnostics-customize))))
                           (caar collection)))
                        ((symbol-function 'customize-group)
                         (lambda (group &rest _) (setq customized group))))
                (pichat-diagnostics-setup))
              (should (eq customized 'pichat))
              (dolist (action '(pichat-diagnostics-probe-pi
                                pichat-diagnostics-open-interactive-pi
                                pichat-diagnostics-open-settings))
                (should-error (funcall action) :type 'user-error))))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-setup-chooser-revalidates-forgotten-owner ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :state 'stopped)))
          report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt collection &rest _)
                           (pichat-forget-session session)
                           (caar collection)))
                        ((symbol-function 'pichat-diagnostics-probe-pi)
                         (lambda (&rest _) (ert-fail "Launched for forgotten owner"))))
                (should-error (pichat-diagnostics-setup) :type 'user-error))
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _) (ert-fail "Prompted for forgotten owner"))))
                (should-error (pichat-diagnostics-setup) :type 'user-error))))
        (when (buffer-live-p report) (kill-buffer report))))))

(provide 'pichat-test-diagnostics-views)
;;; pichat-test-diagnostics-views.el ends here
