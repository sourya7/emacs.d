;;; pichat-test-launch-extensions.el --- Extensions added for one launch -*- lexical-binding: t; -*-

;;; Commentary:

;; The launcher's Extensions menu and the launch-context state it edits.
;; No test starts Pi: discovery results are fixture drafts, and every
;; Custom write goes to a temporary `custom-file'.

;;; Code:

(require 'pichat-test-support)
(require 'pichat)

(defconst pichat-test-launch-extensions--probe
  '(:transport local :cwd "/tmp/" :args ("--offline"))
  "Probe context fixture; drafts captured with it are reused as they are.")

(defun pichat-test-launch-extensions--draft ()
  "Return a ready discovery draft with extension tools and commands."
  (pichat-tool-discovery-draft-create
   :status 'ready :context (copy-tree pichat-test-launch-extensions--probe)
   :tools '((:name "read" :source (:path "builtin:read" :source "builtin"))
            (:name "codemode" :source (:path "builtin:codemode" :source "builtin"))
            (:name "tool_search" :source (:path "builtin:tool-search" :source "builtin"))
            (:name "mcp__ketch__search" :source (:path "builtin:mcp" :source "builtin"))
            (:name "guardrails_status"
             :source (:path "/cache/pi-guardrails/index.ts" :source "npm:@pi-vault/pi-guardrails@1.2.3"))
            (:name "legacy_tool"))
   :commands '((:name "archive" :description ""
                :source (:path "/home/user/.pi/git/pi-archive/index.ts"
                         :source "git:github.com/sourya7/pi-archive")))))

(defun pichat-test-launch-extensions--render ()
  "Return the open Extensions menu's text."
  (let* ((transient--prefix (transient--init-prefix 'pichat-launch-extensions-menu))
         (transient--layout (transient--init-suffixes 'pichat-launch-extensions-menu))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (with-temp-buffer
      (transient--insert-groups)
      (buffer-string))))

(defun pichat-test-launch-extensions--press (key)
  "Run the open Extensions menu's suffix bound to KEY."
  (let* ((transient--prefix (transient--init-prefix 'pichat-launch-extensions-menu))
         (transient--layout (transient--init-suffixes 'pichat-launch-extensions-menu))
         (transient--suffixes (transient--flatten-suffixes transient--layout))
         (suffix (cl-find key transient--suffixes
                          :key (lambda (object)
                                 (and (slot-boundp object 'key) (oref object key)))
                          :test #'equal)))
    (should suffix)
    (call-interactively (oref suffix command))))

(defmacro pichat-test-launch-extensions--with-menu (added result &rest body)
  "Open the Extensions menu on ADDED; run BODY, storing its result in RESULT.
`transient-setup' only records that it was called, so nothing is shown."
  (declare (indent 2) (debug t))
  `(let ((pichat-launch-extensions--state nil)
         (pichat-recent-extensions nil)
         (custom-file nil)
         (,result 'pending))
     (cl-letf (((symbol-function 'transient-setup) #'ignore)
               ((symbol-function 'pichat-tool-discovery-draft-refresh)
                (lambda (&rest _) (ert-fail "Started discovery"))))
       (pichat-launch-extensions-open
        ,added (pichat-test-launch-extensions--draft)
        (lambda () (copy-tree pichat-test-launch-extensions--probe))
        (lambda (value) (setq ,result value)))
       ,@body)))

(ert-deftest pichat-launch-extensions-checked-entries-imply-an-independent-runtime ()
  (let* ((added '(("~/pi-ext/protect-secrets.ts" . t) ("npm:some-ext" . nil)))
         (profile (pichat--launch-profile-from-arguments nil (list :extensions added))))
    (should (equal '("~/pi-ext/protect-secrets.ts") (plist-get profile :extensions)))
    (should (eq 'new (plist-get profile :reuse))))
  ;; Unchecked additions leave the preferred profile exactly as before.
  (let ((profile (pichat--launch-profile-from-arguments
                  nil (list :extensions '(("npm:some-ext" . nil))))))
    (should (eq 'preferred (plist-get profile :reuse)))
    (should-not (plist-member profile :extensions)))
  (should (eq 'new (plist-get (pichat--normalize-launch-profile '(:extensions ("a.ts")))
                              :reuse)))
  (dolist (profile '((:reuse preferred :extensions ("a.ts"))
                     (:extensions ("-x"))
                     (:extensions ("a\nb"))
                     (:extensions (" a.ts"))
                     (:extensions ("a.ts" "a.ts"))
                     (:extensions "a.ts")))
    (ert-info ((format "Profile: %S" profile))
      (should-error (pichat--normalize-launch-profile profile) :type 'user-error))))

(ert-deftest pichat-launch-extensions-launch-passes-checked-specs-to-a-new-runtime ()
  (pichat-test-with-clean-state
    (let ((context (list :directory "/tmp/" :display-function #'ignore
                         :extensions '(("~/pi-ext/protect-secrets.ts" . t)
                                       ("npm:unchecked" . nil)
                                       ("npm:@pi-vault/pi-guardrails@1.2.3" . t))))
          started)
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (_cwd _scope options) (setq started options) 'runtime))
                ((symbol-function 'pichat--preferred-session-for-exact-scope)
                 (lambda (&rest _) (ert-fail "Reused the preferred runtime")))
                ((symbol-function 'pichat--display-and-synchronize-session) #'ignore)
                ((symbol-function 'transient-args) (lambda (_) nil))
                ((symbol-function 'transient-scope) (lambda (&rest _) context)))
        (call-interactively #'pichat-launch-execute)
        (should (equal '("~/pi-ext/protect-secrets.ts" "npm:@pi-vault/pi-guardrails@1.2.3")
                       (plist-get started :extensions)))))))

(ert-deftest pichat-launch-extensions-load-with-e-on-start-restart-and-reconfiguration ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model nil)
        (pichat-pi-session-dir nil)
        (pichat-bridge-extension-file "/tmp/bridge.ts")
        (pichat-pi-extra-args '("--offline"))
        (pichat-path-mappings nil)
        (specs '("~/pi-ext/protect-secrets.ts" "npm:@pi-vault/pi-guardrails@1.2.3")))
    (let* ((session (pichat-prepare-session
                     "/tmp/" nil (list :preset 'manual :extensions (copy-sequence specs))))
           (argv (pichat-rpc-build-command session)))
      ;; Captured with the runtime, in order, after the bridge.
      (should (equal specs (pichat-session-extensions session)))
      (should (equal (list "-e" "/tmp/bridge.ts" "-e" (nth 0 specs) "-e" (nth 1 specs))
                     (seq-take (member "-e" argv) 6)))
      ;; Every later start of the runtime rebuilds the same argv.
      (should (equal argv (pichat-rpc-build-command session)))
      ;; A reconfiguration replacement keeps them with the new Tools.
      (let ((replacement (pichat-reconfigure-validated-command
                          session
                          (pichat-reconfigure-select-tools
                           (pichat-reconfigure-captured-configuration session)
                           '(:builtins ("read")))
                          '(:model (:provider "p" :id "m")))))
        (should (equal (list "-e" (nth 0 specs) "-e" (nth 1 specs))
                       (seq-take (cddr (member "-e" replacement)) 4)))
        (should (equal '("--tools" "read")
                       (seq-take (member "--tools" replacement) 2)))))
    ;; Without added extensions the argv is unchanged.
    (should (equal '("/opt/pi" "--mode" "rpc" "-e" "/tmp/bridge.ts" "--offline")
                   (pichat-rpc-build-command
                    (pichat-prepare-session "/tmp/" nil '(:preset standard)))))
    ;; SSH targets get the specs unchanged; they name remote paths.
    (let* ((transport (pichat-transport--create
                       :id 'remote :kind 'ssh :label "remote"
                       :tramp-prefix "/ssh:remote:" :pi-executable "pi"))
           (session (pichat-session-make :transport transport :extensions specs)))
      (should (equal (list "-e" (nth 0 specs) "-e" (nth 1 specs))
                     (seq-take (member "-e" (pichat-rpc-build-command session)) 4))))
    ;; Invalid specs, and a complete command wrapper that would drop them,
    ;; are refused before any runtime exists.
    (dolist (extensions '(("-x") ("a.ts" "a.ts") "a.ts"))
      (should-error (pichat-prepare-session "/tmp/" nil (list :extensions extensions))
                    :type 'user-error))
    (let ((pichat-rpc-command '("/opt/pi-wrapper")))
      (should (pichat-prepare-session "/tmp/" nil '(:preset standard)))
      (should (string-match-p
               "extensions cannot be loaded through"
               (cadr (should-error (pichat-prepare-session
                                    "/tmp/" nil (list :preset 'standard :extensions specs))
                                   :type 'user-error)))))))

(ert-deftest pichat-launch-extensions-tools-discovery-loads-checked-extensions ()
  (let ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
        (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
        (pichat-bridge-extension-file nil) (pichat-path-mappings nil)
        (context (list :directory "/tmp/" :display-function #'ignore
                       :extensions '(("a.ts" . t) ("npm:b" . nil))))
        opened)
    (cl-letf (((symbol-function 'transient-args) (lambda (_) nil))
              ((symbol-function 'transient-scope) (lambda (&rest _) context))
              ((symbol-function 'pichat-tool-picker-open)
               (lambda (&rest args) (setq opened args))))
      ;; x Tools probes with the checked extensions, so their tools show.
      (call-interactively #'pichat-launch-tools)
      (should (equal '("a.ts") (nth 8 opened))))
    (let* ((spec (pichat-presets-resolve 'manual))
           (probe (lambda (extensions)
                    (plist-get (cdr (pichat-tool-picker-discovery-context
                                     spec "/tmp/" pichat-transport-local "pi" nil extensions))
                               :args)))
           (draft (pichat-tool-discovery-draft-create
                   :status 'ready :tools '((:name "x"))
                   :context (list :args (funcall probe '("a.ts"))))))
      (should (equal '("--mode" "rpc" "-e" "a.ts" "-e" "npm:b")
                     (funcall probe '("a.ts" "npm:b"))))
      (should (equal '("--mode" "rpc") (funcall probe nil)))
      ;; A changed list of extensions invalidates cached discovery.
      (pichat-tool-discovery-draft-reset draft (list :args (funcall probe '("a.ts" "npm:b"))))
      (should-not (pichat-tool-discovery-draft-status draft))
      (should-not (pichat-tool-discovery-draft-tools draft)))
    ;; The Extensions menu lists what Pi discovers by itself.
    (should-not (member "-e" (plist-get (pichat--launch-discovery-context nil context)
                                        :args)))))

(ert-deftest pichat-launch-extensions-launcher-entry-counts-checked-and-round-trips ()
  (let* ((context (list :directory "/tmp/" :display-function #'ignore
                        :extensions '(("a.ts" . t) ("b.ts" . nil))))
         (pichat-launch-extensions--state nil)
         reopened)
    (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) context))
              ((symbol-function 'transient-get-value) (lambda (&rest _) nil))
              ((symbol-function 'transient-args) (lambda (_) '("--global")))
              ((symbol-function 'pichat-tool-discovery-draft-refresh) #'ignore)
              ((symbol-function 'transient-setup)
               (lambda (prefix &rest args)
                 (when (eq prefix 'pichat-launch)
                   (setq reopened (plist-get (nthcdr 2 args) :scope))))))
      (should (equal "Extensions (1 added) →"
                     (substring-no-properties (pichat--launch-extensions-description))))
      (should (equal "Launch independent (default: manual)"
                     (let ((pichat-default-preset 'manual))
                       (pichat--launch-action-description))))
      (call-interactively #'pichat-launch-extensions)
      ;; The menu edits a copy and shares the launcher's discovery cache.
      (should (equal '(("a.ts" . t) ("b.ts" . nil)) (pichat-launch-extensions--added)))
      (should (eq (plist-get context :tool-discovery)
                  (plist-get pichat-launch-extensions--state :discovery)))
      (pichat-launch-extensions--set-added '(("b.ts" . t)))
      (pichat-launch-extensions-cancel)
      (should (equal '(("a.ts" . t) ("b.ts" . nil)) (plist-get reopened :extensions)))
      (should (equal '("--global") (plist-get reopened :launch-args)))
      (call-interactively #'pichat-launch-extensions)
      (pichat-launch-extensions--set-added '(("b.ts" . t)))
      (let ((pichat-recent-extensions nil) (custom-file nil))
        (pichat-launch-extensions-done))
      (should-not pichat-launch-extensions--state)
      (should (equal '(("b.ts" . t)) (plist-get reopened :extensions))))
    (should (equal "Extensions →"
                   (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) nil)))
                     (pichat--launch-extensions-description))))))

(ert-deftest pichat-launch-extensions-menu-shows-added-recent-and-discovered ()
  (pichat-test-launch-extensions--with-menu
      '(("~/pi-ext/protect-secrets.ts" . t) ("npm:@pi-vault/pi-guardrails@1.2.3" . nil))
      result
    (setq pichat-recent-extensions
          '("npm:@pi-vault/pi-guardrails@1.2.3" "~/pi-ext/read-audit.ts" "npm:some-ext"))
    (let ((text (pichat-test-launch-extensions--render)))
      (should (string-match-p "^Added for this launch$" text))
      (should (string-match-p "1 \\[✓\\] ~/pi-ext/protect-secrets.ts" text))
      (should (string-match-p "2 \\[ \\] npm:@pi-vault/pi-guardrails@1.2.3" text))
      ;; Recent excludes entries already added.
      (should (string-match-p "^Recent (2)$" text))
      (should (string-match-p "A ~/pi-ext/read-audit.ts" text))
      (should (string-match-p "B npm:some-ext" text))
      (should (string-match-p "pi-guardrails  npm:@pi-vault/pi-guardrails@1.2.3" text))
      (should (string-match-p "pi-archive  git:github.com/sourya7/pi-archive" text))
      (should (string-match-p "Unattributed  1 without provenance" text))
      (should (string-match-p "Pi built-in  builtin:codemode, builtin:tool-search" text))
      (should-not (string-match-p "builtin:read\\|builtin:mcp" text))
      (should (string-match-p "RET Done" text)))
    (should (eq 'pending result))))

(ert-deftest pichat-launch-extensions-menu-adds-toggles-removes-and-applies ()
  (pichat-test-launch-extensions--with-menu '(("a.ts" . t)) result
    (setq pichat-recent-extensions '("npm:recent"))
    (pichat-test-launch-extensions--press "1")
    (should (equal '(("a.ts" . nil)) (pichat-launch-extensions--added)))
    (pichat-test-launch-extensions--press "A")
    (should (equal '(("a.ts" . nil) ("npm:recent" . t)) (pichat-launch-extensions--added)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  git:github.com/o/r@v1 ")))
      (pichat-launch-extensions-add))
    (should (equal '(("a.ts" . nil) ("npm:recent" . t) ("git:github.com/o/r@v1" . t))
                   (pichat-launch-extensions--added)))
    ;; Repeated or option-like input is refused with a message; the menu stays.
    (dolist (input '("a.ts" "--no-extensions" ""))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input)))
        (pichat-launch-extensions-add)))
    (should (= 3 (length (pichat-launch-extensions--added))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "npm:recent")))
      (pichat-launch-extensions-remove))
    (should (equal '(("a.ts" . nil) ("git:github.com/o/r@v1" . t))
                   (pichat-launch-extensions--added)))
    (should (eq 'pending result))
    (pichat-launch-extensions-done)
    (should (equal '(("a.ts" . nil) ("git:github.com/o/r@v1" . t)) result))
    ;; Only checked extensions become recent; without `custom-file' the
    ;; value lasts for this session.
    (should (equal '("git:github.com/o/r@v1" "npm:recent") pichat-recent-extensions))
    (should-not pichat-launch-extensions--state)))

(ert-deftest pichat-launch-extensions-cancel-discards-the-draft ()
  (pichat-test-launch-extensions--with-menu '(("a.ts" . t)) result
    (pichat-test-launch-extensions--press "1")
    (pichat-launch-extensions-cancel)
    (should (eq :cancel result))
    (should-not pichat-recent-extensions)
    (should-not pichat-launch-extensions--state)))

(ert-deftest pichat-launch-extensions-discovery-follows-the-launch-probe ()
  (let ((pichat-launch-extensions--state nil)
        (draft (pichat-tool-discovery-draft-create))
        refreshed result)
    (cl-letf (((symbol-function 'transient-setup) #'ignore)
              ((symbol-function 'pichat-tool-discovery-draft-refresh)
               (lambda (refreshed-draft _callback)
                 (should (eq draft refreshed-draft))
                 (push (pichat-tool-discovery-draft-context refreshed-draft) refreshed)
                 (setf (pichat-tool-discovery-draft-status refreshed-draft) 'loading))))
      ;; Opening discovers once with the probe context; Refresh again.
      (pichat-launch-extensions-open
       nil draft (lambda () (copy-tree pichat-test-launch-extensions--probe))
       (lambda (value) (setq result value)))
      (should (equal (list pichat-test-launch-extensions--probe) refreshed))
      (should (string-match-p "Discovering…" (pichat-test-launch-extensions--render)))
      (should (string-match-p "None; \\+ to add one" (pichat-test-launch-extensions--render)))
      (pichat-launch-extensions-refresh)
      (should (= 2 (length refreshed)))
      ;; Leaving cancels pending discovery.
      (let (cancelled)
        (setf (pichat-tool-discovery-draft-cancel draft) (lambda () (setq cancelled t)))
        (pichat-launch-extensions-cancel)
        (should cancelled)
        (should-not (pichat-tool-discovery-draft-status draft))))
    (should (eq :cancel result))
    ;; A launch where discovery is unavailable shows why and starts nothing.
    (cl-letf (((symbol-function 'transient-setup) #'ignore)
              ((symbol-function 'pichat-tool-discovery-draft-refresh)
               (lambda (&rest _) (ert-fail "Started discovery"))))
      (pichat-launch-extensions-open
       nil (pichat-tool-discovery-draft-create)
       (lambda () (user-error "Discovery cannot use a complete Pi command wrapper"))
       #'ignore)
      (should (string-match-p "Unavailable: Discovery cannot use a complete"
                              (pichat-test-launch-extensions--render)))
      (pichat-launch-extensions--abandoned)
      (should-not pichat-launch-extensions--state))))

(ert-deftest pichat-launch-extensions-recent-list-is-capped-and-saved ()
  (pichat-test-with-temp-dir custom-dir
    (let* ((file (expand-file-name "custom.el" custom-dir))
           (custom-file file)
           (user-init-file (expand-file-name "init.el" custom-dir))
           (properties (mapcar (lambda (property)
                                 (cons property (get 'pichat-recent-extensions property)))
                               '(saved-value theme-value customized-value)))
           (value (default-value 'pichat-recent-extensions)))
      (unwind-protect
          (progn
            (set-default 'pichat-recent-extensions '("old-1" "-invalid" "old-2" "old-3"))
            (should (equal '("old-1" "old-2" "old-3") (pichat-presets-recent-extensions)))
            (should-not (pichat-presets-note-recent-extensions '("new" "old-2")))
            (should (equal '("new" "old-2" "old-1") pichat-recent-extensions))
            (with-temp-buffer
              (insert-file-contents file)
              (should (string-match-p
                       "pichat-recent-extensions '(\"new\" \"old-2\" \"old-1\")"
                       (buffer-string))))
            ;; An unsafe `custom-file' keeps the value for this session.
            (let ((custom-file nil))
              (should (string-match-p "\\`Saving recent extensions requires"
                                      (pichat-presets-note-recent-extensions '("other"))))
              (should (equal '("other" "new" "old-2") pichat-recent-extensions))))
        (set-default 'pichat-recent-extensions value)
        (dolist (property properties)
          (put 'pichat-recent-extensions (car property) (cdr property)))
        (when-let* ((buffer (find-buffer-visiting file)))
          (kill-buffer buffer))))))

(defconst pichat-test-launch-extensions--fixture
  (expand-file-name "fixtures/tool-control-extension.ts" pichat-test-directory)
  "Extension registering the probe tools, loaded only when added.")

(declare-function pichat-test-extension-tools-active "pichat-test-extension-tools" (session))

(when pichat-test-include-integration
  (ert-deftest pichat-launch-extensions-real-pi-discovery-loads-added-extensions ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      (let ((pichat-pi-default-args
             (list "--mode" "rpc" "--offline" "--no-approve" "--no-context-files"
                   "--no-skills" "--no-prompt-templates" "--no-themes" "--no-extensions"
                   "--no-mcp" "-e" pichat-test-fake-provider-extension
                   "--model" "pichat-fake/pichat-fake"))
            (fixture (file-truename pichat-test-launch-extensions--fixture))
            (draft (pichat-tool-discovery-draft-create)))
        (cl-flet ((discover (extensions)
                    (let (done)
                      (pichat-tool-discovery-draft-reset
                       draft (cdr (pichat-tool-picker-discovery-context
                                   (pichat-presets-resolve 'standard) project-dir
                                   pichat-transport-local pichat-test-pi-executable
                                   nil extensions)))
                      (pichat-tool-discovery-draft-refresh draft (lambda (_) (setq done t)))
                      (pichat-test-wait-until (lambda () done) 15 "real discovery probe")
                      (should (eq 'ready (pichat-tool-discovery-draft-status draft)))
                      (cl-find "probe_child" (pichat-tool-discovery-draft-tools draft)
                               :key (lambda (tool) (plist-get tool :name)) :test #'equal))))
          (unwind-protect
              (progn
                (should-not (discover nil))
                (let ((tool (discover (list pichat-test-launch-extensions--fixture))))
                  (should tool)
                  (should (equal fixture (file-truename
                                          (plist-get (plist-get tool :source) :path))))))
            (when-let* ((cancel (pichat-tool-discovery-draft-cancel draft)))
              (funcall cancel)))))))

  (ert-deftest pichat-launch-extensions-real-pi-loads-added-extension-at-start-and-restart ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            (fixture pichat-test-launch-extensions--fixture)
            added buffer result)
        (unwind-protect
            (progn
              ;; The fixture is not otherwise loaded: only as an added extension.
              (setq added (pichat-start-session
                           project-dir nil
                           (list :preset 'manual :extensions (list fixture)
                                 :tools '(:builtins ("read") :extensions ("probe_child")))))
              (pichat-rpc-get-state added (lambda (value _s) (setq result value))
                                    (lambda (value _s) (setq result value)))
              (pichat-test-wait-until (lambda () result) 15 "runtime with added extension")
              (should (plist-get result :success))
              (should (equal (list fixture) (pichat-session-extensions added)))
              (should (equal "-e" (nth (1- (cl-position fixture (pichat-session-rpc-command added)
                                                        :test #'equal))
                                       (pichat-session-rpc-command added))))
              (should (member "probe_child" (pichat-test-extension-tools-active added)))
              ;; Reconfiguration restarts Pi with the same added extension.
              (setq buffer (pichat-chat-open added t))
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache added))
                                      5 "initial empty cache")
              (setq result nil)
              (pichat-reconfigure-restart
               (pichat-reconfigure-capture-origin added)
               (pichat-reconfigure-select-tools
                (pichat-reconfigure-captured-configuration added)
                '(:builtins ("read") :extensions ("probe_session")))
               (lambda (success reason) (setq result (list success reason))))
              (pichat-test-wait-until (lambda () result) 15 "restart with added extension")
              (should (car result))
              (should (member fixture (pichat-session-rpc-command added)))
              (let ((active (pichat-test-extension-tools-active added)))
                (should (member "probe_session" active))
                (should-not (member "probe_child" active))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (pichat-session-p added)
            (pichat-rpc-stop added)
            (pichat-forget-session added)))))))

(provide 'pichat-test-launch-extensions)
;;; pichat-test-launch-extensions.el ends here
