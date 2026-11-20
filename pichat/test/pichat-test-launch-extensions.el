;;; pichat-test-launch-extensions.el --- Extensions added for one launch -*- lexical-binding: t; -*-

;;; Commentary:

;; The launcher's Extensions menu and the launch-context state it edits.
;; No test starts Pi: discovery results are fixture drafts, and every
;; Custom write goes to a temporary `custom-file'.

;;; Code:

(require 'pichat-test-support)
(require 'pichat)
(require 'pichat-tool-runtime)

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

(ert-deftest pichat-launch-extensions-preset-extensions-load-with-grouped-tools ()
  (let ((pichat-rpc-command nil)
        (pichat-pi-executable "/opt/pi")
        (pichat-pi-default-args '("--mode" "rpc"))
        (pichat-default-model nil)
        (pichat-pi-session-dir nil)
        (pichat-bridge-extension-file "/tmp/bridge.ts")
        (pichat-pi-extra-args nil)
        (pichat-path-mappings nil)
        (pichat-append-system-prompt nil)
        (pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'guarded
      :tools '("read" ("./guard.ts" "guard_check"))
      :extensions '("./guard.ts" "npm:pkg@1"))
    (let* ((session (pichat-prepare-session
                     "/tmp/" nil '(:preset guarded :extensions ("npm:pkg@1" "extra.ts"))))
           (argv (pichat-rpc-build-command session)))
      ;; The runtime keeps its added extensions; the preset's load first.
      (should (equal '("npm:pkg@1" "extra.ts") (pichat-session-extensions session)))
      (should (equal '("./guard.ts" "npm:pkg@1" "extra.ts")
                     (pichat-rpc-session-extensions session)))
      (should (equal '("-e" "/tmp/bridge.ts" "-e" "./guard.ts" "-e" "npm:pkg@1" "-e" "extra.ts")
                     (seq-take (member "-e" argv) 8)))
      (should (equal '("--tools" "read,guard_check") (seq-take (member "--tools" argv) 2)))
      (should (equal argv (pichat-rpc-build-command session)))
      ;; Reconfiguring to another preset drops the old preset's extensions
      ;; and keeps the added ones; that is an effective change.
      (let* ((before (pichat-reconfigure-captured-configuration session))
             (after (pichat-reconfigure-select-preset before 'manual))
             (replacement (pichat-reconfigure-validated-command
                           session after '(:model (:provider "p" :id "m")))))
        (should (equal '("-e" "/tmp/bridge.ts" "-e" "npm:pkg@1" "-e" "extra.ts")
                       (seq-take (member "-e" replacement) 6)))
        (should-not (member "./guard.ts" replacement))
        (should (pichat-reconfigure-effective-change-p before after))
        (let ((unloaded (list :preset-spec
                              (plist-put (copy-sequence (plist-get before :preset-spec))
                                         :load-extensions nil)
                              :tool-selection (plist-get before :tool-selection))))
          (should (pichat-reconfigure-effective-change-p before unloaded))
          (should-not (pichat-reconfigure-effective-change-p before before)))))
    ;; A preset's extensions alone make it use the startup failure checks.
    (let ((session (pichat-prepare-session "/tmp/" nil '(:preset guarded))))
      (should-not (pichat-session-extensions session))
      (should (equal '("./guard.ts" "npm:pkg@1") (pichat-rpc-session-extensions session))))
    ;; A complete wrapper would drop them.
    (let ((pichat-rpc-command '("/opt/pi-wrapper")))
      (should (string-match-p
               "extensions cannot be loaded through"
               (cadr (should-error (pichat-prepare-session "/tmp/" nil '(:preset guarded))
                                   :type 'user-error)))))
    ;; Launcher x Tools probes with the preset's and the checked extensions.
    (let ((context (list :directory "/tmp/" :display-function #'ignore
                         :extensions '(("extra.ts" . t) ("./guard.ts" . t))))
          opened)
      (cl-letf (((symbol-function 'transient-args) (lambda (_) '("--preset=guarded")))
                ((symbol-function 'transient-scope) (lambda (&rest _) context))
                ((symbol-function 'pichat-tool-picker-open)
                 (lambda (&rest args) (setq opened args))))
        (call-interactively #'pichat-launch-tools)
        (should (equal '("./guard.ts" "npm:pkg@1" "extra.ts") (nth 8 opened)))))))

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
      (should (string-match-p "Unattributed  1 without a known source" text))
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

(ert-deftest pichat-launch-extensions-menu-refuses-extensions-pi-already-loads ()
  (pichat-test-with-temp-dir dir
    (let* ((real (expand-file-name "guard" dir))
           (link (expand-file-name "guard-link" dir))
           (single (expand-file-name "single.ts" dir))
           (draft (pichat-test-launch-extensions--draft)))
      (make-directory real)
      (make-symbolic-link real link)
      (setf (pichat-tool-discovery-draft-commands draft)
            (append (pichat-tool-discovery-draft-commands draft)
                    `((:name "guard" :source (:path ,(expand-file-name "index.ts" real)
                                              :source "local" :base-dir ,real))
                      (:name "single" :source (:path ,single :source "auto")))))
      ;; Package sources match exactly; paths after resolution against the
      ;; probe's directory and symbolic links, by path or base directory.
      (dolist (case `(("npm:@pi-vault/pi-guardrails@1.2.3" . "npm:@pi-vault/pi-guardrails@1.2.3")
                      ("git:github.com/sourya7/pi-archive" . "git:github.com/sourya7/pi-archive")
                      (,(concat link "/") . ,real)
                      (,single . ,single)
                      ("npm:@pi-vault/pi-guardrails@1.2.4" . nil)
                      ("builtin:codemode" . nil)
                      ("/cache/pi-guardrails" . nil)))
        (ert-info ((format "Spec: %s" (car case)))
          (should (equal (cdr case) (pichat-launch-extensions-duplicate (car case) draft)))))
      (let ((relative (pichat-tool-discovery-draft-create
                       :status 'ready :context (list :cwd (file-name-as-directory dir))
                       :tools `((:name "t" :source (:path ,single :source "cli"))))))
        (should (equal single (pichat-launch-extensions-duplicate "single.ts" relative))))
      ;; Remote paths are the target's: `~' is never resolved on this host.
      (let ((remote (pichat-tool-discovery-draft-create
                     :status 'ready
                     :context (list :cwd "/srv/" :transport (pichat-transport--create
                                                            :id 'remote :kind 'ssh))
                     :tools '((:name "t" :source (:path "/srv/ext/x.ts" :source "local"))))))
        (should (equal "/srv/ext/x.ts" (pichat-launch-extensions-duplicate "ext/x.ts" remote)))
        (should-not (pichat-launch-extensions-duplicate "~/ext/x.ts" remote)))
      ;; Without ready results nothing is judged.
      (setf (pichat-tool-discovery-draft-status draft) 'failed)
      (should-not (pichat-launch-extensions-duplicate
                   "git:github.com/sourya7/pi-archive" draft))))
  ;; Add and Recent refuse a duplicate with a message; the menu stays.
  (pichat-test-launch-extensions--with-menu nil result
    (setq pichat-recent-extensions '("npm:@pi-vault/pi-guardrails@1.2.3"))
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages)))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "git:github.com/sourya7/pi-archive")))
        (pichat-launch-extensions-add)
        (pichat-test-launch-extensions--press "A"))
      (should-not (pichat-launch-extensions--added))
      (should (string-match-p "\\`git:github.com/sourya7/pi-archive is not added: Pi already loads it"
                              (cadr messages)))
      (should (string-match-p "discovered as npm:@pi-vault/pi-guardrails@1.2.3" (car messages))))
    (should (eq 'pending result)))
  ;; An entry added before discovery was ready: Done refuses while it is
  ;; checked, and applies once it is unchecked.
  (pichat-test-launch-extensions--with-menu
      '(("git:github.com/sourya7/pi-archive" . t) ("a.ts" . t)) result
    (let (messages)
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format format args) messages))))
        (pichat-launch-extensions-done))
      (should (eq 'pending result))
      (should pichat-launch-extensions--state)
      (should (equal (concat "Pi already loads git:github.com/sourya7/pi-archive (discovered as "
                             "git:github.com/sourya7/pi-archive); uncheck or remove it")
                     (car messages))))
    (pichat-test-launch-extensions--press "1")
    (pichat-launch-extensions-done)
    (should (equal '(("git:github.com/sourya7/pi-archive" . nil) ("a.ts" . t)) result)))
  ;; Refresh reports duplicates among the checked entries when it completes.
  (let ((pichat-launch-extensions--state nil)
        (draft (pichat-tool-discovery-draft-create))
        messages)
    (cl-letf (((symbol-function 'transient-setup) #'ignore)
              ((symbol-function 'message)
               (lambda (format &rest args) (push (apply #'format format args) messages)))
              ((symbol-function 'pichat-tool-discovery-draft-refresh)
               (lambda (refreshed callback)
                 (let ((ready (pichat-test-launch-extensions--draft)))
                   (setf (pichat-tool-discovery-draft-status refreshed) 'ready
                         (pichat-tool-discovery-draft-tools refreshed)
                         (pichat-tool-discovery-draft-tools ready)
                         (pichat-tool-discovery-draft-commands refreshed)
                         (pichat-tool-discovery-draft-commands ready)))
                 (funcall callback refreshed))))
      (pichat-launch-extensions-open
       '(("npm:@pi-vault/pi-guardrails@1.2.3" . t)) draft
       (lambda () (copy-tree pichat-test-launch-extensions--probe)) #'ignore)
      (should (string-match-p "\\`Pi already loads npm:@pi-vault/pi-guardrails@1.2.3"
                              (car messages)))
      (pichat-launch-extensions--abandoned))))

(ert-deftest pichat-launch-extensions-pi-stderr-failures-refuse-added-extensions ()
  (let ((install "Warning: Extension package \"npm:bad@1\": failed to install (npm install bad@1 failed with code 1). Check the source and try again.")
        (load "Error: Failed to load extension \"/tmp/nope.ts\": Extension path does not exist: /tmp/nope.ts"))
    ;; An added spec that failed to install, or any extension load error.
    (should (equal install (pichat-rpc-extension-failure
                            (concat "Cloning…\n" install "\n") '("a.ts" "npm:bad@1"))))
    (should (equal load (pichat-rpc-extension-failure (concat load "\nHint: …\n") '("x.ts"))))
    ;; A settings package's failure is not about the added extensions.
    (should-not (pichat-rpc-extension-failure
                 "Warning: Extension package \"npm:other\": failed to install (x)." '("npm:bad@1")))
    ;; Without added extensions stderr stays informational.
    (should-not (pichat-rpc-extension-failure (concat install "\n" load) nil))
    (should-not (pichat-rpc-extension-failure "added 1 package in 189ms" '("npm:bad@1")))
    ;; A probe loading added extensions fails with Pi's line; one without
    ;; them keeps its ordinary error.
    (dolist (case `((,install ("npm:bad@1") 0 ,install)
                    (,load ("/tmp/nope.ts") 1 ,load)
                    (,install nil 0 nil)))
      (pcase-let ((`(,line ,extensions ,status ,expected) case)
                  (result nil))
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (_transport _cwd &rest args)
                     (apply #'make-process
                            (plist-put args :command
                                       (list "sh" "-c" (format "printf '%%s\\n' \"$1\" >&2; exit %d"
                                                               status)
                                             "sh" line))))))
          (pichat-tool-discovery-start
           pichat-transport-local temporary-file-directory "pi"
           (lambda (tools error) (setq result (list tools error)))
           :args nil :extensions extensions)
          (pichat-test-wait-until (lambda () result) 5 "failed probe")
          (should-not (car result))
          (if expected
              (should (equal (pichat-rpc-extension-failure-message expected) (cadr result)))
            (should (equal "Pi tool probe exited before discovery completed"
                           (cadr result)))))))
    ;; The discovery context names the added extensions for the probe.
    (let ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
          (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
          (pichat-bridge-extension-file nil) (pichat-path-mappings nil)
          (spec (pichat-presets-resolve 'manual)))
      (should (equal '("a.ts") (plist-get (cdr (pichat-tool-picker-discovery-context
                                                spec "/tmp/" pichat-transport-local "pi"
                                                nil '("a.ts")))
                                          :extensions)))
      (should-not (plist-member (cdr (pichat-tool-picker-discovery-context
                                      spec "/tmp/" pichat-transport-local "pi"))
                                :extensions)))
    ;; Pi starts without a package that failed to install: the startup
    ;; barrier reads its stderr and refuses the runtime.
    (with-temp-buffer
      (insert install "\n")
      (let ((session (pichat-session-make :extensions '("npm:bad@1")
                                          :stderr-buffer (current-buffer))))
        (should (equal install (pichat-tool-runtime--extension-failure session)))
        (setf (pichat-session-extensions session) nil)
        (should-not (pichat-tool-runtime--extension-failure session))))))

(ert-deftest pichat-launch-extensions-include-future-tools-expand-before-launch ()
  (pichat-test-with-clean-state
    (let* ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
           (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
           (pichat-bridge-extension-file nil) (pichat-path-mappings nil)
           (pichat-append-system-prompt nil)
           (pichat-presets (copy-tree pichat-presets)) (pichat-saved-presets nil)
           (cache "/a/tmp/extensions/npm/abcdef01/node_modules/pkg/index.ts")
           (tools (list (list :name "pkg_a" :eligible t
                              :source (list :path cache :source "cli"
                                            :scope "temporary" :origin "top-level"))
                        (list :name "read" :eligible t
                              :source '(:path "builtin:read" :source "builtin"))))
           (probe-error nil)
           probes mcp-checks started messages)
      (pichat-make-preset 'future
        :tools '("read" ("npm:pkg@1" . :all)) :extensions '("npm:pkg@1"))
      (pichat-make-preset 'future-mcp
        :tools '("read" ("npm:pkg@1" . :all)) :extensions '("npm:pkg@1")
        :mcp '(("s" . "t")))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args) (apply function args) nil))
                ((symbol-function 'pichat-tool-discovery-draft-refresh)
                 (lambda (draft callback)
                   (push (pichat-tool-discovery-draft-context draft) probes)
                   (setf (pichat-tool-discovery-draft-tools draft) (and (not probe-error) tools)
                         (pichat-tool-discovery-draft-error draft) probe-error
                         (pichat-tool-discovery-draft-status draft)
                         (if probe-error 'failed 'ready))
                   (funcall callback draft)))
                ((symbol-function 'pichat-mcp-discovery-start)
                 (lambda (_transport _cwd _executable callback)
                   (push 'mcp mcp-checks)
                   (funcall callback '((:name "s" :tools ((:name "t" :eligible t)))) nil)))
                ((symbol-function 'pichat-start-session)
                 (lambda (_cwd _scope options) (push options started) 'runtime))
                ((symbol-function 'pichat--display-and-synchronize-session) #'ignore)
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format-message format args) messages))))
        ;; Without Tools, one probe with the preset's extensions expands the
        ;; group silently, and the runtime records the expanded snapshot.
        (should-not (pichat--open-launch-profile '(:preset future :display-function ignore)
                                                 "/tmp/"))
        (should (= 1 (length probes)))
        (should (equal '("npm:pkg@1") (plist-get (car probes) :extensions)))
        (should (member "npm:pkg@1" (plist-get (car probes) :args)))
        (let ((options (car started)))
          (should-not (plist-member options :preset))
          (should (equal '(("npm:pkg@1" "pkg_a"))
                         (plist-get (plist-get options :preset-spec) :expanded-all)))
          (should (equal '("pkg_a") (plist-get (plist-get options :preset-spec) :extensions))))
        (should-not (cl-some (lambda (text) (string-search "pkg_a" text)) messages))
        ;; With MCP too, each check runs once, then the runtime starts.
        (setq probes nil started nil)
        (pichat--open-launch-profile '(:preset future-mcp :display-function ignore) "/tmp/")
        (should (= 1 (length probes)))
        (should (equal '(mcp) mcp-checks))
        (should (= 1 (length started)))
        (should (plist-get (plist-get (car started) :preset-spec) :expanded-all))
        ;; Tools chosen in the picker are exact names: no probe.
        (setq probes nil started nil)
        (pichat--open-launch-profile
         '(:preset future :display-function ignore
           :tools (:builtins ("read") :extensions ("pkg_a") :all ("npm:pkg@1")))
         "/tmp/")
        (should-not probes)
        (should (eq 'future (plist-get (car started) :preset)))
        ;; A failed probe cancels the launch with its reason.
        (setq probes nil started nil messages nil probe-error "Pi exited")
        (pichat--open-launch-profile '(:preset future :display-function ignore) "/tmp/")
        (should-not started)
        (should (cl-some (lambda (text)
                           (string-match-p "\\`PiChat launch cancelled: Tool discovery failed: Pi exited"
                                           text))
                         messages))))))

(ert-deftest pichat-launch-extensions-reconfigure-expands-a-reselected-preset ()
  (let* ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
         (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
         (pichat-bridge-extension-file nil) (pichat-path-mappings nil)
         (pichat-append-system-prompt nil)
         (pichat-presets (copy-tree pichat-presets)) (pichat-saved-presets nil)
         (tools (list (list :name "pkg_a" :eligible t
                            :source (list :path "/a/tmp/extensions/npm/abcdef01/node_modules/pkg/x.ts"
                                          :source "cli" :scope "temporary" :origin "top-level"))))
         refresh)
    (pichat-make-preset 'future
      :tools '("read" ("npm:pkg@1" . :all)) :extensions '("npm:pkg@1"))
    (let* ((session (pichat-prepare-session "/tmp/" nil '(:preset manual :extensions ("x.ts"))))
           (base (pichat-reconfigure-captured-configuration session))
           (scope (list :origin (pichat-reconfigure-capture-origin session) :base base
                        :draft (pichat-reconfigure-select-preset base 'future))))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args) (apply function args) nil))
                ((symbol-function 'pichat-tool-discovery-draft-refresh)
                 (lambda (draft callback) (setq refresh (list draft callback)))))
        ;; While the probe runs the restart is blocked.
        (pichat--reconfigure-expand-draft scope)
        (should (equal '("Discovering included future tools…")
                       (pichat--reconfigure-blockers scope)))
        (should (equal '("npm:pkg@1" "x.ts")
                       (plist-get (pichat-tool-discovery-draft-context (car refresh))
                                  :extensions)))
        ;; A failure keeps it blocked with the reason.
        (pcase-let ((`(,draft ,callback) refresh))
          (setf (pichat-tool-discovery-draft-status draft) 'failed
                (pichat-tool-discovery-draft-error draft) "boom")
          (funcall callback draft))
        (should (equal '("Included future tools: Tool discovery failed: boom")
                       (pichat--reconfigure-blockers scope)))
        ;; A successful probe replaces the draft with the expanded preset.
        (pichat--reconfigure-expand-draft scope)
        (pcase-let ((`(,draft ,callback) refresh))
          (setf (pichat-tool-discovery-draft-status draft) 'ready
                (pichat-tool-discovery-draft-tools draft) tools)
          (funcall callback draft))
        (should-not (pichat--reconfigure-blockers scope))
        (let ((draft (plist-get scope :draft)))
          (should (equal '(("npm:pkg@1" "pkg_a"))
                         (plist-get (plist-get draft :preset-spec) :expanded-all)))
          (should (equal '("--tools" "read,pkg_a")
                         (seq-take (member "--tools"
                                           (pichat-reconfigure-validated-command
                                            session draft '(:model (:provider "p" :id "m"))))
                                   2))))
        ;; A result for an older draft is ignored.
        (plist-put scope :draft (pichat-reconfigure-select-preset base 'future))
        (pichat--reconfigure-expand-draft scope)
        (let ((stale refresh))
          (plist-put scope :draft (pichat-reconfigure-select-preset base 'manual))
          (setf (pichat-tool-discovery-draft-status (car stale)) 'ready)
          (funcall (cadr stale) (car stale))
          (should (eq 'manual (plist-get (plist-get (plist-get scope :draft) :preset-spec)
                                         :name))))))))

(defconst pichat-test-launch-extensions--fixture
  (expand-file-name "fixtures/tool-control-extension.ts" pichat-test-directory)
  "Extension registering the probe tools, loaded only when added.")

(defconst pichat-test-launch-extensions--guard
  (expand-file-name "fixtures/hook-only-guard-extension.ts" pichat-test-directory)
  "Secrets guard with only a `tool_call' hook: no tools, no commands.")

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

  (ert-deftest pichat-launch-extensions-real-pi-groups-added-extension-tools-under-their-spec ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      (let ((pichat-pi-default-args
             (list "--mode" "rpc" "--offline" "--no-approve" "--no-context-files"
                   "--no-skills" "--no-prompt-templates" "--no-themes" "--no-extensions"
                   "--no-mcp" "-e" pichat-test-fake-provider-extension
                   "--model" "pichat-fake/pichat-fake"))
            (spec "ext/guard.ts")
            (draft (pichat-tool-discovery-draft-create))
            done)
        ;; A relative path, resolved by Pi against the probe's directory.
        (make-directory (expand-file-name "ext" project-dir) t)
        (copy-file pichat-test-launch-extensions--fixture
                   (expand-file-name spec project-dir))
        (unwind-protect
            (progn
              (pichat-tool-discovery-draft-reset
               draft (cdr (pichat-tool-picker-discovery-context
                           (pichat-presets-resolve 'standard) project-dir
                           pichat-transport-local pichat-test-pi-executable nil (list spec))))
              (pichat-tool-discovery-draft-refresh draft (lambda (_) (setq done t)))
              (pichat-test-wait-until (lambda () done) 15 "real discovery probe")
              (should (eq 'ready (pichat-tool-discovery-draft-status draft)))
              (let* ((pichat-tool-picker--state (list :servers nil :discovery draft))
                     (groups (pichat-tool-picker--extension-groups))
                     (group (assoc spec groups)))
                (should group)
                (should (equal "guard" (cadr group)))
                (should (member "probe_child" (mapcar (lambda (tool) (plist-get tool :name))
                                                      (cddr group))))
                (should-not (assq :unattributed groups))))
          (when-let* ((cancel (pichat-tool-discovery-draft-cancel draft)))
            (funcall cancel))))))

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
            (pichat-forget-session added))))))

  (ert-deftest pichat-launch-extensions-real-pi-preset-loads-its-extensions-and-grouped-tools ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            (pichat-presets (copy-tree pichat-presets))
            (fixture pichat-test-launch-extensions--fixture)
            runtime buffer result)
        ;; The fixture is loaded only because the preset names it.
        (pichat-make-preset 'fixture-guarded
          :tools (list "read" (list fixture "probe_child"))
          :extensions (list fixture))
        (unwind-protect
            (progn
              (setq runtime (pichat-start-session project-dir nil '(:preset fixture-guarded)))
              (pichat-rpc-get-state runtime (lambda (value _s) (setq result value))
                                    (lambda (value _s) (setq result value)))
              (pichat-test-wait-until (lambda () result) 15 "runtime of the preset")
              (should (plist-get result :success))
              (should-not (pichat-session-extensions runtime))
              (should (member fixture (pichat-session-rpc-command runtime)))
              (let ((active (pichat-test-extension-tools-active runtime)))
                (should (member "probe_child" active))
                (should-not (member "probe_session" active)))
              ;; Reconfiguring to manual restarts Pi without the fixture.
              (setq buffer (pichat-chat-open runtime t))
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache runtime))
                                      5 "initial empty cache")
              (setq result nil)
              (pichat-reconfigure-restart
               (pichat-reconfigure-capture-origin runtime)
               (pichat-reconfigure-select-preset
                (pichat-reconfigure-captured-configuration runtime) 'manual)
               (lambda (success reason) (setq result (list success reason))))
              (pichat-test-wait-until (lambda () result) 15 "restart without the fixture")
              (should (car result))
              ;; (The fixture's /probe-report is gone with it, so argv is the
              ;; evidence here.)
              (should-not (member fixture (pichat-session-rpc-command runtime)))
              (should (equal '("--tools" "read,grep,find,ls,edit,write")
                             (seq-take (member "--tools" (pichat-session-rpc-command runtime))
                                       2))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (pichat-session-p runtime)
            (pichat-rpc-stop runtime)
            (pichat-forget-session runtime))))))

  (ert-deftest pichat-launch-extensions-real-pi-include-future-tools-expand-at-launch ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil)
            (pichat-presets (copy-tree pichat-presets))
            (fixture pichat-test-launch-extensions--fixture)
            ;; Discovery takes no session directory; the runtime needs none.
            (pichat-pi-default-args
             (list "--mode" "rpc" "--offline" "--no-approve" "--no-context-files"
                   "--no-skills" "--no-prompt-templates" "--no-themes" "--no-extensions"
                   "-e" pichat-test-fake-provider-extension
                   "--model" "pichat-fake/pichat-fake"))
            runtime result)
        ;; Every tool of the fixture, which only the preset loads.
        (pichat-make-preset 'fixture-future
          :tools (list "read" (cons fixture :all))
          :extensions (list fixture))
        (unwind-protect
            (progn
              ;; Launching without Tools probes first, then starts the runtime.
              (should-not (pichat--open-launch-profile
                           (list :preset 'fixture-future :display-function #'ignore)
                           project-dir))
              (pichat-test-wait-until
               (lambda ()
                 (setq runtime (cl-find 'fixture-future (pichat-session-list)
                                        :key #'pichat-session-preset-name)))
               30 "runtime launched after the probe")
              (pichat-rpc-get-state runtime (lambda (value _s) (setq result value))
                                    (lambda (value _s) (setq result value)))
              (pichat-test-wait-until (lambda () result) 15 "expanded runtime")
              (should (plist-get result :success))
              (let* ((expanded (cdr (assoc fixture (plist-get (pichat-session-preset-spec runtime)
                                                              :expanded-all))))
                     (active (pichat-test-extension-tools-active runtime)))
                ;; The probe found the fixture's tools; they are recorded with
                ;; the runtime and enabled by exact name.
                (should (member "probe_child" expanded))
                (should (member "probe_loader" expanded))
                (should (cl-subsetp expanded active :test #'equal))
                (should (string-search "probe_child"
                                       (cadr (member "--tools"
                                                     (pichat-session-rpc-command runtime)))))))
          (when (pichat-session-p runtime)
            (pichat-rpc-stop runtime)
            (pichat-forget-session runtime))))))

  (ert-deftest pichat-launch-extensions-real-pi-hook-only-guard-protects-a-manual-runtime ()
    ;; The motivating case: a hook-only secrets guard added for a `manual'
    ;; runtime.  Pi lists nothing for it, yet it is loaded and blocks.
    (pichat-test-with-integration-session
        (session :preset 'manual
                 :script '(:turns [(:toolCall (:id "read-env" :name "read"
                                               :arguments (:path ".env")))
                                   (:expectToolResultError "read"
                                    :expectContextIncludes "hook-only-guard: secrets are protected"
                                    :text "guard observed")]))
      (let ((pichat-chat-stop-session-on-kill nil)
            (guard pichat-test-launch-extensions--guard)
            (draft (pichat-tool-discovery-draft-create))
            added result)
        (with-temp-file (expand-file-name ".env" project-dir)
          (insert "PICHAT_TEST_SECRET=do-not-read\n"))
        (unwind-protect
            (progn
              ;; Discovery loads it without error, but it registers nothing:
              ;; no Tools group and no Discovered entry.
              (let ((pichat-pi-default-args
                     (list "--mode" "rpc" "--offline" "--no-approve" "--no-context-files"
                           "--no-skills" "--no-prompt-templates" "--no-themes" "--no-extensions"
                           "--no-mcp" "-e" pichat-test-fake-provider-extension
                           "--model" "pichat-fake/pichat-fake"))
                    done)
                (pichat-tool-discovery-draft-reset
                 draft (cdr (pichat-tool-picker-discovery-context
                             (pichat-presets-resolve 'standard) project-dir
                             pichat-transport-local pichat-test-pi-executable nil (list guard))))
                (pichat-tool-discovery-draft-refresh draft (lambda (_) (setq done t)))
                (pichat-test-wait-until (lambda () done) 15 "real discovery probe")
                (should (eq 'ready (pichat-tool-discovery-draft-status draft)))
                (let* ((pichat-tool-picker--state (list :servers nil :discovery draft))
                       (groups (pichat-tool-picker--extension-groups)))
                  (should-not (assoc guard groups))
                  (should-not (assq :unattributed groups)))
                (should-not (rassoc guard (pichat-launch-extensions-discovered draft))))
              ;; The runtime starts with the guard and Pi's manual tools.
              (setq added (pichat-start-session
                           project-dir nil (list :preset 'manual :extensions (list guard))))
              (pichat-rpc-get-state added (lambda (value _s) (setq result value))
                                    (lambda (value _s) (setq result value)))
              (pichat-test-wait-until (lambda () result) 15 "runtime with the guard")
              (should (plist-get result :success))
              (should (member guard (pichat-session-rpc-command added)))
              (should (equal '("--tools" "read,grep,find,ls,edit,write")
                             (seq-take (member "--tools" (pichat-session-rpc-command added)) 2)))
              ;; The guard blocks reading the secrets file.
              (pichat-test-prompt-and-wait added "read the secrets")
              (let* ((messages (plist-get (plist-get (pichat-test-rpc-call added "get_messages")
                                                     :data)
                                          :messages))
                     (tool-result (cl-find "toolResult" messages
                                           :key (lambda (message) (plist-get message :role))
                                           :test #'equal)))
                (should (plist-get tool-result :isError))
                (should (string-search "hook-only-guard: secrets are protected"
                                       (format "%S" (plist-get tool-result :content))))
                (should-not (string-search "do-not-read" (format "%S" messages)))))
          (when-let* ((cancel (pichat-tool-discovery-draft-cancel draft)))
            (funcall cancel))
          (when (pichat-session-p added)
            (pichat-rpc-stop added)
            (pichat-forget-session added))))))

  (ert-deftest pichat-launch-extensions-real-pi-refuses-failed-installs-and-missing-paths ()
    (pichat-test-with-integration-session (session :preset 'manual :script '(:turns []))
      ;; A missing local path makes Pi exit; a package that fails to install
      ;; (a missing local tarball: npm needs no network) lets Pi start
      ;; without it.  Installs need Pi online, so drop the offline setting.
      (let* ((process-environment (cons "PI_OFFLINE" process-environment))
             (pichat-pi-default-args
              (list "--mode" "rpc" "--no-approve" "--no-context-files" "--no-skills"
                    "--no-prompt-templates" "--no-themes" "--no-extensions"
                    "-e" pichat-test-fake-provider-extension
                    "--model" "pichat-fake/pichat-fake"))
             (missing (expand-file-name "missing-extension.ts" project-dir))
             (package (concat "npm:" (expand-file-name "missing-package.tgz" project-dir)))
             (draft (pichat-tool-discovery-draft-create)))
        (dolist (case (list (list missing (format "Failed to load extension \"%s\"" missing))
                            (list package (format "Extension package \"%s\": failed to install"
                                                  package))))
          (pcase-let ((`(,spec ,reported) case))
            (ert-info ((format "Spec: %s" spec))
              ;; Discovery for x Tools refuses with Pi's reason.
              (let (done)
                (pichat-tool-discovery-draft-reset
                 draft (cdr (pichat-tool-picker-discovery-context
                             (pichat-presets-resolve 'standard) project-dir
                             pichat-transport-local pichat-test-pi-executable nil (list spec))))
                (pichat-tool-discovery-draft-refresh draft (lambda (_) (setq done t)))
                (pichat-test-wait-until (lambda () done) 60 "failed discovery probe")
                (should (eq 'failed (pichat-tool-discovery-draft-status draft)))
                (should (string-match-p (concat "\\`Added extension failed.*" (regexp-quote reported))
                                        (pichat-tool-discovery-draft-error draft))))
              ;; The launch is refused: the runtime stops with the reason and
              ;; never accepts input.
              (let ((added (pichat-start-session
                            project-dir nil (list :preset 'manual :extensions (list spec))))
                    answered)
                (unwind-protect
                    (progn
                      (pichat-rpc-get-state added (lambda (&rest _) (setq answered 'success))
                                            (lambda (&rest _) (setq answered 'failure)))
                      (pichat-test-wait-until
                       (lambda () (memq (pichat-session-state added) '(error stopped)))
                       60 "refused runtime")
                      (should-not (eq answered 'success))
                      (should-not (process-live-p (pichat-session-process added)))
                      (let ((summary (pichat-chat-diagnostics-latest-summary added)))
                        (should (string-match-p "\\`Added extension failed" summary))
                        (should (string-search (truncate-string-to-width reported 40) summary))))
                  (pichat-rpc-stop added)
                  (pichat-forget-session added))))))))))

(provide 'pichat-test-launch-extensions)
;;; pichat-test-launch-extensions.el ends here
