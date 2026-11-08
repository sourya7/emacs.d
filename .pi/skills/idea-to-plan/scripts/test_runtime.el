;;; test_runtime.el --- Isolated intake runtime acceptance -*- lexical-binding: t; -*-

;; Run from a separate Emacs, never load into the user's live conversations.
;; Uses existing offline PiChat support; no real provider or normal state.
(require 'pichat-test-job-support)
(require 'org-capture)

(defconst intake-test-skill
  (file-name-directory (directory-file-name
                        (file-name-directory (or load-file-name buffer-file-name)))))
(defconst intake-test-plans
  (or (getenv "IDEAS_TEST_PLANS_SKILL")
      (expand-file-name "~/.pi/agent/skills/plans/")))

(defun intake-test-setup (directory script-file)
  "Create disposable intake DIRECTORY and scripted tool choices in SCRIPT-FILE."
  (let ((default-directory directory))
    (should (= 0 (process-file "git" nil nil nil "init" "-q"))))
  (dolist (entry '(("disposable-intake-fixture" . "fixture-only\n")
                   ("app.py" . "def greet():\n    return \"hello\"\n")
                   ("ideas.org" . "#+TODO: IDEA QUEUED NEEDS-INPUT | PLANNED DECLINED\n\n* Ideas\n** QUEUED Add optional greeting name\nOriginal idea notes.\n*** Keep nested notes\nNo changes here.\n")))
    (with-temp-file (expand-file-name (car entry) directory) (insert (cdr entry))))
  (with-temp-file script-file
    (insert
     (json-serialize
      (list :turns
            (vconcat
             (mapcar (lambda (path)
                       (list :toolCall (list :name "read" :arguments (list :path path))
                             :expectContextIncludes ["Idea to draft plan"]))
                     (list (expand-file-name "references/workflow.md" intake-test-skill)
                           (expand-file-name "SKILL.md" intake-test-plans)
                           (expand-file-name "references/lifecycle.md" intake-test-plans)
                           (expand-file-name "references/storage.md" intake-test-plans)
                           (expand-file-name "app.py" directory)))
             (vector
              (list :toolCall
                    (list :name "bash" :arguments
                          (list :command
                                (mapconcat
                                 #'shell-quote-argument
                                 (list "python3" (expand-file-name "scripts/fixture_handoff.py" intake-test-skill)
                                       directory (expand-file-name "scripts/plans.py" intake-test-plans))
                                 " ")))
                    :expectTool '(:name "bash"))
              (list :text "INTAKE_HANDOFF_VERIFIED" :expectContextIncludes ["PLANNED" "repeated no-op"]))))))))

(defun intake-test-assert-result (directory status-file)
  "Assert actual source/plan results and provider consumption."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "ideas.org" directory))
    (should (search-forward "** PLANNED Add optional greeting name" nil t)))
  (with-temp-buffer
    (insert-file-contents (expand-file-name "app.py" directory))
    (should (equal (buffer-string) "def greet():\n    return \"hello\"\n")))
  (should (equal (directory-files (expand-file-name ".plans" directory) nil "^[^.]")
                 '("add-optional-greeting-name")))
  (should (file-exists-p
           (expand-file-name ".plans/add-optional-greeting-name/plan.org" directory)))
  (pichat-test-assert-provider-script-consumed status-file))

(ert-deftest intake-real-pi-chat-discovery-and-handoff ()
  (pichat-test-with-job-executor (:script '(:turns []))
    (intake-test-setup project-dir script-file)
    (make-directory (expand-file-name ".pi/skills" project-dir) t)
    (copy-directory intake-test-skill (expand-file-name ".pi/skills/idea-to-plan" project-dir))
    (let* ((pichat-pi-default-args
            (remove "--no-skills" (remove "--no-approve" pichat-pi-default-args)))
           (pichat-pi-extra-args (append pichat-pi-extra-args '("--approve")))
           (session (pichat-prepare-session project-dir nil
                                             '(:preset coding :model "pichat-fake/pichat-fake"))))
      (pichat-chat-ensure session)
      (pichat-start-prepared-session session t)
      (pichat-test-rpc-call session "get_state")
      (pichat-test-rpc-call session "set_auto_retry" '(:enabled :json-false))
      (pichat-test-rpc-call session "set_auto_compaction" '(:enabled :json-false))
      (let ((commands (plist-get (plist-get (pichat-test-rpc-call session "get_commands") :data) :commands)))
        (should (seq-find (lambda (command) (equal (plist-get command :name) "skill:idea-to-plan")) commands)))
      (pichat-test-prompt-and-wait session "/skill:idea-to-plan next --unattended; disposable fixture only, draft handoff, no implementation.")
      (intake-test-assert-result project-dir status-file))))

(ert-deftest intake-real-pi-one-off-job-handoff ()
  (pichat-test-with-job-executor (:script '(:turns []))
    (intake-test-setup project-dir script-file)
    (let* ((pichat-pi-extra-args
            (append pichat-pi-extra-args (list "--skill" intake-test-skill)))
           (spec (pichat-job-launch-capture
                  "Disposable idea intake"
                  "/skill:idea-to-plan next --unattended; disposable fixture only, draft handoff, no implementation."
                  project-dir '(:preset coding :model "pichat-fake/pichat-fake" :target local)))
           (id (pichat-job-executor-submit executor spec)))
      (pichat-test-wait-until
       (lambda () (member (plist-get (pichat-job-record store 'runs id) :state) '("finished" "uncertain")))
       45 "ordinary one-off intake job")
      (let ((run (pichat-job-record store 'runs id)))
        (should (equal (plist-get run :state) "finished"))
        (should (equal (plist-get run :result) "completed")))
      (should (= 0 (length (pichat-job-records store 'jobs))))
      (intake-test-assert-result project-dir status-file))))

(ert-deftest intake-live-org-capture-and-states ()
  (should-not noninteractive)
  (pichat-test-with-temp-dir project-dir
    (let* ((source (expand-file-name "ideas.org" project-dir))
           (org-capture-templates `(("i" "Idea" entry (file+headline ,source "Ideas") "* %?\n")))
           (org-capture-use-agenda-date nil))
      (with-temp-file source
        (insert "#+TODO: IDEA QUEUED NEEDS-INPUT | PLANNED DECLINED\n\n* Ideas\n"))
      (unwind-protect
          (progn
            (org-capture nil "i")
            (insert "Capture stays simple")
            (org-capture-finalize)
            (with-current-buffer (find-file-noselect source)
              (should (equal org-todo-keywords-1 '("IDEA" "QUEUED" "NEEDS-INPUT" "PLANNED" "DECLINED")))
              (goto-char (point-min))
              (should (search-forward "** Capture stays simple" nil t))
              (org-back-to-heading)
              (should-not (org-entry-get nil "ID"))
              (let ((org-inhibit-logging t)) (org-todo "QUEUED"))
              (should (equal (org-get-todo-state) "QUEUED"))))
        (when-let* ((buffer (get-file-buffer source)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

;;; test_runtime.el ends here
