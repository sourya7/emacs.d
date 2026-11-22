;;; pichat-test-diagnostics-views.el --- Owned diagnostic views -*- lexical-binding: t; -*-

;;; Commentary:

;; Runtime ownership, cached refresh, bounded evidence and
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
            (dolist (show '(pichat-show-diagnostics))
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
           safe)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore)
                    ((symbol-function 'pichat-session-for-directory)
                     (lambda (&rest _) b)))
            (setq safe (pichat-show-diagnostics a))
            (setf (pichat-session-state a) 'stopped)
            (with-current-buffer safe
              (should (eq safe (pichat-show-diagnostics)))
              (should (string-match-p "^Runtime +pi · stopped" (buffer-string)))
              (should (eq a pichat-diagnostics--owner))))
        (when (buffer-live-p safe) (kill-buffer safe))))))

(ert-deftest pichat-diagnostics-forgotten-owner-preserves-snapshots-rejects-actions ()
  (pichat-test-with-clean-state
    (let* ((a (pichat-register-session (pichat-session-make :state 'stopped)))
           (b (pichat-register-session (pichat-session-make)))
           (pichat-current-session b)
           buffers)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq buffers (list (pichat-show-diagnostics a)))
            (pichat-forget-session a)
            (dolist (buffer buffers)
              (with-current-buffer buffer
                (let ((snapshot (buffer-string)))
                  (dolist (action '(pichat-diagnostics-refresh
                                    pichat-show-diagnostics
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

(ert-deftest pichat-diagnostics-overview-distinguishes-runtime-context-and-launch-evidence ()
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
              (should (equal (substring-no-properties header-line-format)
                             (format "PiChat diagnostics (%s)"
                                     (pichat-session-runtime-id session))))
              (should (eq 'bold (get-text-property 0 'face header-line-format)))
              (should (string-match-p "^Runtime +pi · error" text))
              (should (string-match-p "^Context +.* · /secret/project/$" text))
              (should (string-match-p "^ +executable /secret/pi$" text))
              ;; Header-level caveats and render timestamps are not repeated.
              (should-not (string-match-p "Snapshot:\\|cached snapshot,\\|before sharing" text))
              (should-not (string-match-p "Unavailable.*configured executable" text))
              (should-not (string-match-p "--secret" text))
              (should-not (string-match-p "g / Evil\\|asks first" text)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest pichat-diagnostics-quit-returns-to-origin-after-refresh ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let ((session (pichat-register-session (pichat-session-make :state 'stopped)))
            (origin (generate-new-buffer " *diagnostics-origin*"))
            safe)
        (unwind-protect
            (progn
              (switch-to-buffer origin)
              (setq safe (pichat-show-diagnostics session))
              (should (eq safe (window-buffer (selected-window))))
              ;; Reopening in place must not replace the origin with itself.
              (pichat-show-diagnostics)
              (pichat-diagnostics-refresh)
              (call-interactively (key-binding (kbd "q")))
              (should (eq origin (window-buffer (selected-window))))
              (should (buffer-live-p safe)))
          (dolist (buffer (list safe origin))
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
            (let ((comp-enable-subr-trampolines nil)
                  (before (copy-tree (pichat-session-diagnostics session)))
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
                        ((symbol-function 'file-exists-p) no-io)
                        ((symbol-function 'file-attributes) no-io)
                        ((symbol-function 'file-readable-p) no-io))
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
                    (should (string-match-p
                             (concat "^Unavailable .*Canonical transcript snapshot, "
                                     "Live tail snapshot, Session History snapshot$")
                             text))
                    (should (string-match-p "^Problems\n  Runtime / transport\n    " text))
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
              (should-not (string-match-p "not a live health check\\|not necessarily a failure" text))
              (should (string-match-p "^  none retained (Live tail)$" text))
              (should (string-match-p "^Unavailable .*Session History snapshot$" text))
              ;; Empty or unavailable domains get no evidence heading.
              (should (string-match-p "Canonical transcript evidence (4)" text))
              (should-not (string-match-p "Live tail evidence\\|Session History evidence" text))
              (should (string-match-p
                       (regexp-quote "[error/missing-credential; 2020-01-02T03:04:05Z] failure-notice") text))
              (should (string-match-p (regexp-quote "[warning/compatibility] no-time") text))
              (should (string-match-p "\n    legacy-notice\n    bad-time\n" text))
              (should-not (string-match-p "hidden\\|/private/path" text)))))
      (when (buffer-live-p report) (kill-buffer report)))))

(ert-deftest pichat-diagnostics-refresh-requires-an-inspector ()
  (with-temp-buffer
    (should-error (pichat-diagnostics-refresh) :type 'user-error)))

(ert-deftest pichat-diagnostics-standalone-setup-respects-backend-capability ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :backend 'no-pi)))
          report customized)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (cl-letf (((symbol-function 'customize-group)
                         (lambda (group &rest _) (setq customized group))))
                (pichat-diagnostics-customize))
              (should (eq customized 'pichat))
              (dolist (action '(pichat-diagnostics-probe-pi
                                pichat-diagnostics-open-interactive-pi
                                pichat-diagnostics-open-settings))
                (should-error (funcall action) :type 'user-error))))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-reload-retires-raw-view-without-losing-report-or-records ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-register-session (pichat-session-make :state 'stopped)))
           (legacy (generate-new-buffer " *legacy-raw-diagnostics*"))
           (source (locate-library "pichat-chat-diagnostics.el"))
           report records)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (pichat-chat-diagnostics-record session :origin 'rpc-response :message "retained")
            (setq report (pichat-show-diagnostics session)
                  records (copy-tree (pichat-session-diagnostics session)))
            ;; Simulate definitions/buffers left by the previous package version.
            (with-current-buffer legacy (setq major-mode 'pichat-transport-diagnostics-mode))
            (dolist (symbol '(pichat-show-transport-diagnostics pichat-diagnostics-show-raw
                              pichat-diagnostics-setup pichat-transport-diagnostics-mode))
              (fset symbol #'ignore))
            (set 'pichat-transport-diagnostics-mode-map (make-sparse-keymap))
            (define-key pichat-diagnostics-mode-map (kbd "r") 'pichat-diagnostics-show-raw)
            (define-key pichat-diagnostics-mode-map (kbd "s") 'pichat-diagnostics-setup)
            (load source nil t)
            (should-not (buffer-live-p legacy))
            (dolist (symbol '(pichat-show-transport-diagnostics pichat-diagnostics-show-raw
                              pichat-diagnostics-setup pichat-transport-diagnostics-mode))
              (should-not (fboundp symbol)))
            (should-not (boundp 'pichat-transport-diagnostics-mode-map))
            (with-current-buffer report
              (should (eq report (pichat-show-diagnostics)))
              (should (eq session pichat-diagnostics--owner))
              (dolist (key '("r" "s"))
                (should (memq (key-binding (kbd key)) '(nil undefined)))))
            (should (equal records (pichat-session-diagnostics session))))
        (when (buffer-live-p legacy) (kill-buffer legacy))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-mode-help-owns-actions-not-report-legends ()
  (save-window-excursion
    (with-temp-buffer
      (pichat-diagnostics-mode)
      (describe-mode)
      (with-current-buffer "*Help*"
        (dolist (text '("TAB" "RET" "gr refreshes" "q returns" "credentials"
                        "pichat-diagnostics-open-settings" "pichat-diagnostics-customize"
                        "pichat-diagnostics-open-interactive-pi" "pichat-diagnostics-probe-pi"))
          (should (string-match-p (regexp-quote text) (buffer-string))))))))

(defconst pichat-test-diagnostics-unavailable-process
  "^Unavailable +\\(?:.*, \\)?process\\(?:,\\|$\\)"
  "Match the overview row listing an unavailable process.")

(defun pichat-test-diagnostics-toggle (title)
  "Activate the report evidence heading with exact TITLE."
  (goto-char (point-min))
  (search-forward title)
  (beginning-of-line)
  (forward-char 2)
  (call-interactively (key-binding (kbd "TAB"))))

(ert-deftest pichat-diagnostics-report-paths-folds-and-return-survive-refresh ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let* ((session (pichat-register-session
                       (pichat-session-make
                        :id "pi-source" :session-file "/runtime/session.jsonl"
                        :model '(:provider "fake" :id "offline") :thinking-level "low"
                        :rpc-command '("pi" "--prompt" "token=explicit-secret")
                        :preset-spec '(:name fixture :tools ("read")))))
             (origin (generate-new-buffer " *report-origin*"))
             report)
        (unwind-protect
            (progn
              (switch-to-buffer origin)
              (cl-letf (((symbol-function 'pichat-session-emacs-session-file)
                         (lambda (_) "/emacs/session.jsonl")))
                (setq report (pichat-show-diagnostics session)))
              (should (string-match-p "^Pi session +pi-source" (buffer-string)))
              (should (string-match-p "^ +runtime /runtime/session.jsonl\n +Emacs /emacs/session.jsonl$"
                                      (buffer-string)))
              (should (string-match-p "^Config +fake/offline · thinking low" (buffer-string)))
              (should (string-match-p "Startup tool selections (builtins 1)" (buffer-string)))
              (should (string-match-p pichat-test-diagnostics-unavailable-process (buffer-string)))
              (should-not (string-match-p "explicit-secret" (buffer-string)))
              (pichat-test-diagnostics-toggle "Captured launch command")
              (should (string-match-p "explicit-secret" (buffer-string)))
              (pichat-chat-diagnostics-record session :origin 'rpc-response :message "late-failure-secret")
              (pichat-diagnostics-refresh)
              ;; First-appearing failure on refresh must not auto-expand.
              (should-not (string-match-p ":message[[:space:]]+\"late-failure-secret\"" (buffer-string)))
              (should (string-match-p "explicit-secret" (buffer-string)))
              (pichat-test-diagnostics-toggle "Captured launch command")
              (setf (pichat-session-id session) "replacement-source"
                    (pichat-session-state session) 'stopped)
              (pichat-diagnostics-refresh)
              (should (eq report (current-buffer)))
              (should (string-match-p "^Pi session +replacement-source" (buffer-string)))
              (should-not (string-match-p "explicit-secret" (buffer-string)))
              (call-interactively (key-binding (kbd "q")))
              (should (eq origin (current-buffer))))
          (mapc (lambda (buffer) (when (buffer-live-p buffer) (kill-buffer buffer)))
                (list report origin)))))))

(ert-deftest pichat-diagnostics-report-shows-preset-prompt-mode-not-prompt-text ()
  (pichat-test-with-clean-state
    (let* ((argv '("pi" "--system-prompt" "private base instructions"
                   "--append-system-prompt=private additions" "--model" "fake/offline"))
           (session (pichat-register-session (pichat-session-make)))
           report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (dolist (fixture '((nil nil "Pi default without additions")
                               (nil "private additions" "Pi default with additions")
                               ("private base instructions" nil "replaced without additions")
                               ("private base instructions" "private additions" "replaced with additions")))
              (pcase-let ((`(,base ,append ,mode) fixture))
                (pichat-session-set-configuration
                 session (list :name 'fixture :description "Fixture description\nSecond line"
                               :tools :default :system-prompt base :append-system-prompt append)
                 nil)
                (setq report (pichat-show-diagnostics session))
                (with-current-buffer report
                  (should (string-match-p "Fixture description Second line" (buffer-string)))
                  (should (string-match-p (concat "system prompt: " mode "$") (buffer-string)))
                  (should (string-match-p "Startup tool selections (Pi defaults)" (buffer-string)))
                  (should-not (string-match-p "private " (buffer-string))))))
            (setf (pichat-session-rpc-command session) argv)
            (with-current-buffer report
              (pichat-diagnostics-refresh)
              (pichat-test-diagnostics-toggle "Captured launch command")
              (should (string-match-p (regexp-quote "--system-prompt\" \"[omitted]") (buffer-string)))
              (should (string-match-p (regexp-quote "--append-system-prompt=[omitted]") (buffer-string)))
              (should (string-match-p (regexp-quote "--model") (buffer-string)))
              (should-not (string-match-p "private " (buffer-string))))
            (should (equal (pichat-session-rpc-command session) argv)))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-report-provider-sections-keep-stable-independent-folds ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-register-session (pichat-session-make)))
           (present t)
           (pichat-diagnostics-section-functions
            (list (lambda (_)
                    (when present '(("Extra domain" (:summary "extra" :type "extra-evidence")))))))
           report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (pichat-chat-diagnostics-record session :origin 'rpc-response :message "first-secret")
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (should (string-match-p ":message[[:space:]]+\"first-secret\"" (buffer-string)))
              (pichat-test-diagnostics-toggle "Latest retained runtime failure")
              (pichat-test-diagnostics-toggle "Extra domain evidence")
              (should (string-match-p "extra-evidence" (buffer-string)))
              (setq present nil)
              (pichat-diagnostics-refresh)
              (should-not (string-match-p "Extra domain" (buffer-string)))
              (setq present t)
              (pichat-chat-diagnostics-record session :origin 'rpc-response :message "second-secret")
              (pichat-diagnostics-refresh)
              (should (string-match-p "extra-evidence" (buffer-string)))
              (should-not (string-match-p ":message[[:space:]]+\"second-secret\"" (buffer-string)))
              (pichat-forget-session session)
              ;; Readable snapshots still fold; owner-dependent refresh rejects.
              (pichat-test-diagnostics-toggle "Extra domain evidence")
              (should-error (pichat-diagnostics-refresh) :type 'user-error)))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-report-bounds-retained-events-and-keeps-collectors ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-register-session
                     (pichat-session-make :event-log
                                          `((:type "newest" :text ,(make-string 500 ?x))
                                            (:type "omitted-event")))))
           (before (copy-tree (pichat-session-event-log session)))
           (pichat-diagnostics-view-event-limit 1)
           (pichat-diagnostics-view-value-limit 100)
           (comp-enable-subr-trampolines nil)
           (no-io (lambda (&rest _) (ert-fail "Report inspection attempted I/O")))
           report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore)
                    ((symbol-function 'pichat-rpc-send) no-io)
                    ((symbol-function 'pichat-backend-get-transcript) no-io)
                    ((symbol-function 'pichat-rpc-get-tree) no-io)
                    ((symbol-function 'make-process) no-io)
                    ((symbol-function 'process-file) no-io)
                    ((symbol-function 'file-exists-p) no-io)
                    ((symbol-function 'file-attributes) no-io)
                    ((symbol-function 'file-readable-p) no-io))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (should (string-match-p "Retained incoming events (1 of 2)" (buffer-string)))
              (pichat-test-diagnostics-toggle "Retained incoming events")
              (pichat-diagnostics-refresh)
              (should (string-match-p "Retained incoming events (1 of 2)" (buffer-string)))
              (should (string-match-p "newest" (buffer-string)))
              (should-not (string-match-p "omitted-event" (buffer-string)))
              (should (string-match-p "truncated by PiChat" (buffer-string)))
              (should (equal before (pichat-session-event-log session)))))
        (when (buffer-live-p report) (kill-buffer report))))))

(ert-deftest pichat-diagnostics-report-stderr-rejects-stale-process-and-buffer ()
  (pichat-test-with-unit-session (session process)
    (pichat-register-session session)
    (let ((stderr (generate-new-buffer " *report-stderr*"))
          (pichat-diagnostics-stderr-limit 12)
          report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setf (pichat-session-stderr-buffer session) stderr
                  (pichat-session-process-generation session) 7)
            (process-put process 'pichat-process-generation 7)
            (process-put process 'pichat-stderr-buffer stderr)
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (should (string-match-p "Current stderr (empty)" (buffer-string)))
              (pichat-test-diagnostics-toggle "Current stderr")
              (should (string-match-p "empty (owning live stderr buffer)" (buffer-string)))
              (with-current-buffer stderr (insert "stderr-secret-long-value"))
              (pichat-diagnostics-refresh)
              (should (string-match-p "stderr-secre" (buffer-string)))
              (should (string-match-p "stderr truncated" (buffer-string)))
              (process-put process 'pichat-stderr-buffer nil)
              (pichat-diagnostics-refresh)
              (should-not (string-match-p "stderr-secre" (buffer-string)))
              (process-put process 'pichat-stderr-buffer stderr)
              (setf (pichat-session-process-generation session) 8)
              (pichat-diagnostics-refresh)
              (should (string-match-p pichat-test-diagnostics-unavailable-process (buffer-string)))
              (should-not (string-match-p "stderr-secre" (buffer-string)))))
        (when (buffer-live-p report) (kill-buffer report))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(ert-deftest pichat-diagnostics-report-disabled-persistence-and-backend-boundaries ()
  (dolist (backend '(pi no-pi))
    (let ((session (pichat-session-make :backend backend :persistence 'ephemeral
                                      :rpc-command '("secret-launch") :event-log '((:secret "event"))))
          report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              (should (string-match-p "ephemeral (--no-session)$" (buffer-string)))
              (should-not (string-match-p "saved-session path" (buffer-string)))
              (pichat-test-diagnostics-toggle "Captured launch command")
              (if (eq backend 'pi)
                  (should (string-match-p "secret-launch" (buffer-string)))
                (should-not (string-match-p "secret-launch" (buffer-string)))
                (should (string-match-p "unavailable for this backend" (buffer-string))))))
        (when (buffer-live-p report) (kill-buffer report))))))

(defun pichat-test-diagnostics-face (regexp &optional group)
  "Return the face at the start of GROUP of the first REGEXP match."
  (goto-char (point-min))
  (re-search-forward regexp)
  (get-text-property (match-beginning (or group 0)) 'face))

(ert-deftest pichat-diagnostics-report-highlights-only-abnormal-values ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session
                    (pichat-session-make :state 'idle :persistence 'persistent
                                         :session-file "/runtime/dir/session.jsonl")))
          report)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-view-display) #'ignore))
            (setq report (pichat-show-diagnostics session))
            (with-current-buffer report
              ;; Healthy: bold labels, dimmed descriptors, plain values.
              (should (eq 'bold (pichat-test-diagnostics-face "^Runtime")))
              (should-not (pichat-test-diagnostics-face "^Runtime +pi · \\(idle\\)" 1))
              (should (eq 'shadow (pichat-test-diagnostics-face "^Runtime +pi\\( · \\)" 1)))
              (should-not (pichat-test-diagnostics-face "send gate \\(open\\)" 1))
              (should (eq 'shadow (pichat-test-diagnostics-face "send gate")))
              (should-not (pichat-test-diagnostics-face "\\(0\\) pending" 1))
              (should (eq 'shadow (pichat-test-diagnostics-face "0\\( pending\\)" 1)))
              (should (eq 'shadow (pichat-test-diagnostics-face "/runtime/dir/")))
              (should-not (pichat-test-diagnostics-face "session\\.jsonl"))
              (should (eq 'shadow (pichat-test-diagnostics-face "^Unavailable")))
              (should (eq 'shadow (pichat-test-diagnostics-face "Session History snapshot")))
              (should (eq 'bold (pichat-test-diagnostics-face "^Problems")))
              (should (eq 'shadow (pichat-test-diagnostics-face "none retained")))
              (should (eq 'shadow (pichat-test-diagnostics-face "Retained incoming events\\( (none)\\)" 1)))
              ;; Abnormal: state, closed gate, nonzero counts and problems stand out.
              (setf (pichat-session-state session) 'error
                    (pichat-session-rpc-ready-p session) nil
                    (pichat-session-rpc-send-queue session) '(queued))
              (puthash 1 'request (pichat-session-pending-responses session))
              (pichat-chat-diagnostics-record session :origin 'rpc-response :message "failed")
              (pichat-diagnostics-refresh)
              (should (eq 'error (pichat-test-diagnostics-face "^Runtime +pi · \\(error\\)" 1)))
              (should (eq 'warning (pichat-test-diagnostics-face "send gate \\(closed\\)" 1)))
              (should (eq 'warning (pichat-test-diagnostics-face "\\(1\\) pending" 1)))
              (should (eq 'warning (pichat-test-diagnostics-face "\\(1\\) queued" 1)))
              (should (equal '(bold error) (pichat-test-diagnostics-face "^Problems")))
              (should (eq 'error (pichat-test-diagnostics-face "^  \\(Runtime / transport\\)" 1)))
              (should (eq 'shadow (pichat-test-diagnostics-face
                                   "Runtime / transport evidence\\( (1)\\)" 1)))))
        (when (buffer-live-p report) (kill-buffer report))))))

(provide 'pichat-test-diagnostics-views)
;;; pichat-test-diagnostics-views.el ends here
