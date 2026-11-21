;;; pichat-test-transient-width.el --- PiChat menus fit a narrow terminal -*- lexical-binding: t; -*-

;;; Commentary:

;; Every PiChat Transient menu, rendered in one column as in a 42-column
;; terminal (an iPhone over SSH), keeps each line inside the frame.  A
;; terminal keeps the last column for the continuation glyph, so a line
;; fits when it is at most 41 columns wide.  The fixtures use realistic
;; values; only user data longer than the frame on its own may wrap.
;; Each case also checks that the state a choice depends on is still shown.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-job-support)
(require 'pichat)
(require 'pichat-jobs)
(require 'pichat-job-definition-ui)
(require 'pichat-job-tools)
(require 'pichat-tool-picker)

(defconst pichat-test-transient-width-columns 42
  "Frame width of the narrowest known terminal (iPhone, portrait).")

(defun pichat-test-transient-width--render (prefix scope)
  "Return PREFIX's menu text for SCOPE in one column in the narrow frame."
  (cl-letf (((symbol-function 'frame-width)
             (lambda (&rest _) pichat-test-transient-width-columns)))
    (let* ((transient--prefix (transient--init-prefix prefix (list :scope scope)))
           (transient--layout (transient--init-suffixes prefix))
           (transient--suffixes (transient--flatten-suffixes transient--layout))
           (transient-force-single-column t))
      (with-temp-buffer
        (transient--insert-groups)
        (buffer-string)))))

(defun pichat-test-transient-width--check (prefix scope &rest expected)
  "Render PREFIX with SCOPE; assert it fits and shows each EXPECTED regexp."
  (let* ((text (pichat-test-transient-width--render prefix scope))
         (wide (seq-filter (lambda (line)
                             (>= (string-width line) pichat-test-transient-width-columns))
                           (split-string text "\n"))))
    (should (equal (list prefix nil) (list prefix wide)))
    (dolist (regexp expected)
      (should (equal (list prefix regexp t)
                     (list prefix regexp (and (string-match-p regexp text) t)))))
    text))

(defmacro pichat-test-transient-width--capturing (var &rest body)
  "Run BODY with `transient-setup' storing the scope it was given in VAR."
  (declare (indent 1))
  `(let (,var)
     (cl-letf (((symbol-function 'transient-setup)
                (lambda (_prefix &rest args)
                  (setq ,var (plist-get (nthcdr 2 args) :scope)))))
       ,@body)))

(ert-deftest pichat-transient-width-launcher-fits-narrow-frame ()
  (with-temp-buffer
    (let* ((pichat-targets '((devbox :transport ssh :host "devbox")))
           (local (pichat-transport-resolve "/tmp/" nil))
           (base (list :origin-buffer (current-buffer) :directory "/tmp/"
                       :display-function #'ignore))
           (saved (lambda (title cwd transport)
                    (list :kind 'saved
                          :selection (list :title title :cwd cwd :transport transport
                                           :session-id "01a16663-abcd-7000-8000-123456789abc")))))
      (pichat-test-transient-width--check
       'pichat-launch (copy-sequence base) "RET Launch preferred (default: ")
      (pichat-test-transient-width--check
       'pichat-launch
       (append (list :launch-args '("--global" "--new" "--ephemeral" "--target=devbox"
                                    "--preset=coding")
                     :model "anthropic/claude-sonnet-4-5"
                     :tool-selection '(:builtins ("read")))
               base)
       "RET Launch independent (coding)" "--target=devbox" "--ephemeral"
       "Model anthropic/claude-sonnet-4-5" "Default conversation")
      (cl-letf (((symbol-function 'pichat--resolve-launch-scope)
                 (lambda (&rest _)
                   (list "project|local|/home/user/src/project/"
                         "/home/user/src/project/" "project"))))
        (pichat-test-transient-width--check
         'pichat-launch
         (append (list :conversation
                       (funcall saved "Refactor the session manager and its tests"
                                "/home/user/src/emacs-packages/pichat/" local))
                 base)
         "^Selected: Refactor the session" "^ID: 01a16663-ab… · owner: project"
         "^Saved cwd: ….*/pichat/$" "RET Launch independent")
        (pichat-test-transient-width--check
         'pichat-launch
         (append (list :launch-args '("--ephemeral")
                       :conversation (funcall saved "Short" "/tmp/" local))
                 base)
         "RET Blocked · ephemeral can't load saved")
        (pichat-test-transient-width--check
         'pichat-launch
         (append (list :conversation (funcall saved "Short" "/tmp/" 'other)) base)
         "RET Blocked · session on another target")))))

(ert-deftest pichat-transient-width-reconfigure-menus-fit-narrow-frame ()
  (let* ((session (pichat-session-create
                   :id "runtime" :name "Refactor the session manager and its tests"
                   :transport pichat-transport-local))
         (base (pichat-reconfigure-select-preset
                (list :preset-spec (pichat-presets-resolve 'standard)) 'manual))
         (origin (list :session session :session-id "01a16663-abcd-7000"))
         (switch (pichat-reconfigure-select-preset base 'coding))
         (tools (copy-tree base t)))
    (plist-put tools :tool-selection
               (pichat-tool-selection-resolve (pichat-presets-resolve 'manual) '("read")))
    (cl-flet ((check (draft extras &rest expected)
                (apply #'pichat-test-transient-width--check 'pichat-launch
                       (list :mode 'reconfigure :reconfigure
                             (append (list :origin origin :base base :draft draft) extras))
                       expected)))
      (check (copy-tree base t) '(:blockers ("Checking current Pi state…"))
             "r Reconfigure" "Preset manual" "RET No changes · keep runtime")
      (check switch '(:blockers ("SSH restart requires verified Linux actual-Pi process identity"))
             "^Blocked: SSH restart requires verified" "RET Restart · manual → coding")
      (check switch '(:empty-unwritten t)
             "^New empty Pi session; keep chat and draft$" "RET Restart · manual → coding")
      (check tools nil "RET Restart · new tools"))
    (setf (pichat-session-restart-operation session)
          (list :phase 'failed :empty-unwritten t
                :failure "Pi exited with code 1 before reporting its state"))
    (pichat-test-transient-width--check
     'pichat-reconfigure-recovery (list :session session)
     "^Restart failed: Pi exited" "^Snapshot retained$"
     "^Recovery starts a new Pi session$" "r Retry requested")))

(ert-deftest pichat-transient-width-jobs-menus-fit-narrow-frame ()
  (pichat-test-with-job-executor ()
    (let* ((pichat-jobs--executor executor)
           (pichat-jobs-file (pichat-job-store-file store))
           (spec (pichat-test-job-spec project-dir))
           (job (pichat-job-save store spec))
           (run (pichat-job-enqueue store spec))
           (claim (pichat-job-claim store run)))
      (pichat-job-advance store run (plist-get claim :attempt) "finished"
                          '(:result "failed" :safe-to-release t))
      (pichat-jobs--show-detail executor 'jobs job)
      (pichat-test-transient-width--capturing scope (pichat-jobs-actions)
        (pichat-test-transient-width--check
         'pichat-jobs-actions-menu scope "r Run job" "s Set schedule…"))
      (pichat-test-transient-width--capturing scope (pichat-job--edit-saved executor job)
        (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) scope)))
          (pichat-test-transient-width--check
           'pichat-job-edit-menu scope "Name: Review files" "Model: pichat-fake/" "RET Save")))
      (pichat-test-transient-width--capturing scope (pichat-job-schedule-ui-open executor job)
        (pichat-test-transient-width--check
         'pichat-job-schedule-menu scope "Timing: Once" "When: ")
        (pichat-test-transient-width--check
         'pichat-job-schedule-menu
         (plist-put (copy-sequence scope) :rule
                    (list :kind "interval" :start (float-time) :seconds 7200))
         "Timing: Every 2 hours" "Start: " "Interval: Every 2 hours"))
      (pichat-jobs--show-detail executor 'runs run)
      (pichat-test-transient-width--capturing scope (pichat-jobs-actions)
        (pichat-test-transient-width--check
         'pichat-jobs-actions-menu scope "c Continue work…" "r Repeat…"))
      (with-temp-buffer
        (pichat-jobs-mode)
        (setq pichat-jobs--owner executor pichat-jobs--kind 'runs)
        (pichat-jobs-refresh)
        (pichat-jobs--select run)
        (pichat-test-transient-width--capturing scope (pichat-jobs-actions)
          (let ((text (pichat-test-transient-width--check
                       'pichat-jobs-actions-menu scope "r Repeat…" "^List$"
                       "a Needs attention only")))
            (should-not (string-match-p "Copy response Markdown" text)))))
      (pichat-test-transient-width--capturing scope (pichat-job--compose executor 'new spec)
        (pichat-test-transient-width--check
         'pichat-job-edit-menu scope "^New job" "r Run once" "s Save job")
        (let ((schedule (copy-sequence scope)))
          (setf (plist-get schedule :kind) 'schedule
                (plist-get schedule :conversation) '(:destination (:session-id "s"))
                (plist-get schedule :due) (+ (float-time) 3600))
          (pichat-test-transient-width--check
           'pichat-job-edit-menu schedule "^Schedule · This conversation" "When: "))))))

(ert-deftest pichat-transient-width-job-definition-menu-fits-narrow-frame ()
  (pichat-test-with-job-executor ()
    (let* ((record (pichat-test-job-author project-dir))
           (pichat-jobs--executor nil) (pichat-jobs--owned-store store)
           (pichat-jobs-file (pichat-job-store-file store)))
      (cl-letf (((symbol-function 'transient-setup) #'ignore)
                ((symbol-function 'frame-width)
                 (lambda (&rest _) pichat-test-transient-width-columns)))
        (with-temp-buffer
          (pichat-job-definition-preview record)
          (let ((session pichat-job-definition-ui--session))
            (pichat-test-transient-width--check
             'pichat-job-definition-menu session "Preset: " "i Review")
            (pichat-job-definition-import)
            (pichat-test-transient-width--check
             'pichat-job-definition-menu session "— Create" "RET Save")))))))

(ert-deftest pichat-transient-width-tool-pickers-fit-narrow-frame ()
  (pichat-test-with-clean-state
    (pichat-job-tools-register)
    (let ((pichat-tool-picker--state
           (list :preset (pichat-presets-resolve 'manual)
                 :baseline '("read" "bash" "edit" "write")
                 :draft '(:builtins ("read") :mcp nil :extensions nil
                          :emacs ("pichat_job_run_now" "pichat_gone_tool"))
                 :discovery (pichat-tool-discovery-draft-create
                             :status 'ready
                             :tools '((:name "subagent" :eligible t
                                       :description "Delegate a task to a child agent with its own context")
                                      (:name "hidden" :description "Hidden" :eligible nil)))
                 :loaded t :page 0 :server "github" :transport pichat-transport-local
                 :emacs-catalogue (pichat-tools-catalogue) :emacs-group "Jobs"
                 :servers (list (list :name "github" :state "connected"
                                      :tools (list (list :name "search_repositories"
                                                         :exposure "direct" :eligible t)
                                                   (list :name "create_issue"
                                                         :exposure "proxy" :eligible nil))))))
          (pichat-bridge-extension-file "/bridge.ts"))
      (pichat-test-transient-width--check
       'pichat-tool-picker nil "\\[✓\\] read" "\\[ \\] subagent — Delegate"
       "hidden (unavailable)" "github (connected, 0/2)"
       "^Not loaded, skipped: pichat_gone_tool" "Jobs (1/6) →" "a All eligible")
      (pichat-test-transient-width--check
       'pichat-tool-picker-server nil "search_repositories" "create_issue (proxy)")
      (pichat-test-transient-width--check
       'pichat-tool-picker-emacs-group nil "^Jobs: 1/6 selected$"
       "does not approve" "\\[✓\\] pichat_job_run_now (approval)"
       "pichat_job_run_cancel (approval)" "pichat_jobs_list — List")
      (setf (plist-get pichat-tool-picker--state :transport)
            (pichat-transport-resolve "/ssh:devbox:/tmp/" nil))
      (pichat-test-transient-width--check
       'pichat-tool-picker nil "^Emacs-defined tools (not over SSH)$"))))

(ert-deftest pichat-transient-width-launch-extensions-menu-fits-narrow-frame ()
  (with-temp-buffer
    (pichat-test-transient-width--check
     'pichat-launch
     (list :origin-buffer (current-buffer) :directory "/tmp/" :display-function #'ignore
           :extensions '(("~/pi-ext/protect-secrets.ts" . t)))
     "l Extensions (1 added) →" "RET Launch independent"))
  (let ((pichat-launch-extensions--state
         (list :added '(("~/pi-ext/protect-secrets.ts" . t)
                        ("npm:@pi-vault/pi-guardrails@1.2.3" . nil)
                        ("git:github.com/kirang89/pi-sentry-with-a-long-name@v0.1.0" . nil))
               :discovery (pichat-tool-discovery-draft-create
                           :status 'ready
                           :commands '((:name "archive" :description ""
                                        :source (:path "/x/index.ts"
                                                 :source "git:github.com/sourya7/pi-archive"))))))
        (pichat-recent-extensions '("~/pi-ext/read-audit.ts")))
    (pichat-test-transient-width--check
     'pichat-launch-extensions-menu nil
     "1 \\[✓\\] ~/pi-ext/protect-secrets.ts" "3 \\[ \\] …" "^Recent (1)$"
     "A ~/pi-ext/read-audit.ts" "pi-archive  …" "RET Done")))

(provide 'pichat-test-transient-width)
;;; pichat-test-transient-width.el ends here
