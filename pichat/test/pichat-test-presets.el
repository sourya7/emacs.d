;;; pichat-test-presets.el --- PiChat preset behavior -*- lexical-binding: t; -*-
;;; Code:
(require 'pichat-test-support)

(ert-deftest pichat-presets-captured-specification-controls-runtime-name ()
  (let* ((spec (pichat-presets-resolve 'coding))
         (tools (pichat-tool-selection-resolve spec))
         (session (pichat-session-make :preset-name 'manual
                                      :preset-spec spec :tool-selection tools)))
    (should (eq 'coding (pichat-session-preset-name session)))
    (should (equal tools (pichat-session-tool-selection session)))
    (let ((previous (pichat-reconfigure-captured-configuration session))
          (replacement (pichat-presets-resolve 'review)))
      (pichat-session-set-configuration
       session replacement (pichat-tool-selection-resolve replacement))
      (should (eq 'review (pichat-session-preset-name session)))
      (pichat-session-set-configuration
       session (plist-get previous :preset-spec) (plist-get previous :tool-selection))
      (should (eq 'coding (pichat-session-preset-name session)))
      (should (equal tools (pichat-session-tool-selection session))))))

(ert-deftest pichat-presets-validate-and-compose-emacs-readable-prompts ()
  (let ((pichat-presets (copy-tree pichat-presets))
        (file (make-temp-file "pichat-preset-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "From Emacs"))
          (pichat-make-preset 'test-compose
            :description "Initial"
            :tools '("read" "read" "write")
            :system-prompt "Replacement"
            :append-system-prompt (list "Before" (list :file file) "After"))
          (let ((snapshot (pichat-presets-resolve 'test-compose)))
            (should (equal '("read" "write") (plist-get snapshot :tools)))
            (should (equal "Replacement\n" (plist-get snapshot :system-prompt)))
            (should (equal "Before\n\nFrom Emacs\n\nAfter\n"
                           (plist-get snapshot :append-system-prompt)))
            (with-temp-file file (insert "Changed"))
            (pichat-make-preset 'test-compose :tools nil)
            (should (equal "Before\n\nFrom Emacs\n\nAfter\n"
                           (plist-get snapshot :append-system-prompt)))
            (should-not (plist-get (pichat-presets-resolve 'test-compose) :tools))))
      (delete-file file))))

(ert-deftest pichat-presets-reject-invalid-registration-and-files ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (dolist (spec '((:tools ("bash,read")) (:tools ("unknown"))
                    (:tools "read") (:tools nil :tools :default) (:append-system-prompt " ")
                    (:append-system-prompt (:file "relative.md"))
                    (:append-system-prompt (:file "/tmp/a" :extra t))
                    (:typo t) (:tools)))
      (should-error (apply #'pichat-make-preset 'invalid spec) :type 'user-error))
    (should-error (pichat-make-preset 'default :tools nil) :type 'user-error)
    (should-error (pichat-presets-resolve 'unknown) :type 'user-error)
    (pichat-make-preset 'missing :append-system-prompt
      '(:file "/definitely/missing/pichat-preset.md"))
    (should-error (pichat-presets-resolve 'missing) :type 'user-error)))

(ert-deftest pichat-presets-default-reuses-existing-runtime-without-resolution ()
  (pichat-test-with-clean-state
    (let ((pichat-default-preset 'missing))
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_s) t)))
        (let* ((scope '("scope" "/tmp/" "test"))
               (session (pichat-session-make :preset-name 'review)))
          (puthash "scope" session pichat--sessions-by-scope)
          (should (eq session (pichat--preferred-session-for-exact-scope scope)))
          (should (eq 'review (pichat-session-preset-name session))))))))

(ert-deftest pichat-presets-reject-conflicting-generic-tools-before-registration ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-pi-extra-args '("--tools" "bash")))
      (should-error (pichat-start-session "/tmp/" nil '(:preset review))
                    :type 'user-error)
      (should-not (pichat-session-list)))))

(ert-deftest pichat-presets-complete-command-allows-no-op-standard ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("wrapper" "pi" "--mode" "rpc")))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/" nil '(:preset standard))))
          (should (eq 'standard (pichat-session-preset-name session)))
          (should (equal pichat-rpc-command (pichat-rpc-build-command session))))))))

(ert-deftest pichat-presets-manual-relies-on-tool-selection-not-execution-instructions ()
  (let ((manual (pichat-presets-resolve 'manual))
        (coding (pichat-presets-resolve 'coding))
        (review (pichat-presets-resolve 'review)))
    (should (equal '("read" "grep" "find" "ls" "edit" "write")
                   (plist-get manual :tools)))
    (should-not (plist-get manual :system-prompt))
    (should-not (plist-get manual :append-system-prompt))
    (should (member "bash" (plist-get coding :tools)))
    (should (plist-get coding :append-system-prompt))
    (should (equal '("read" "grep" "find" "ls") (plist-get review :tools)))
    (should-not (string-match-p
                 "do not .*\\(modify\\|execute\\)"
                 (plist-get review :append-system-prompt)))))

(ert-deftest pichat-presets-ordinary-start-captures-manual-default ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-default-preset 'manual))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/")))
          (should (eq 'manual (pichat-session-preset-name session)))
          (should (equal '("read" "grep" "find" "ls" "edit" "write")
                         (plist-get (pichat-session-preset-spec session) :tools)))
          (should (member "--tools" (pichat-rpc-build-command session)))
          (should (member "--no-mcp" (pichat-rpc-build-command session))))))))

(ert-deftest pichat-presets-transient-reader-offers-annotated-default ()
  (let ((pichat-default-preset 'manual))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices _predicate require-match &rest _)
                 (should require-match)
                 (should (member "review" choices))
                 (should (string-match-p "manual"
                          (funcall (plist-get completion-extra-properties
                                              :annotation-function)
                                   "default")))
                 "review")))
      (should (equal "review" (pichat--launch-read-preset "Preset: " nil nil))))))

(ert-deftest pichat-presets-default-selection-keeps-independent-switches ()
  (should (eq 'preferred
              (plist-get (pichat--launch-profile-from-arguments
                          '("--preset=default")) :reuse)))
  (should (eq 'new
              (plist-get (pichat--launch-profile-from-arguments
                          '("--preset=default" "--new")) :reuse)))
  (should-error (pichat--launch-profile-from-arguments '("--preset=missing"))
                :type 'user-error))

(ert-deftest pichat-presets-explicit-tools-restrict-mcp-and-builtins ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let* ((choices '(:builtins ("read") :mcp (("ketch" . "search"))))
               (session (pichat-start-session "/tmp/" nil
                                             (list :preset 'manual :tools choices)))
               (argv (pichat-rpc-build-command session)))
          (should (member "read,mcp__ketch__search" argv))
          (should-not (member "--no-mcp" argv))
          (setcdr (car (plist-get choices :mcp)) "crawl")
          (should (equal '(("ketch" . "search"))
                         (plist-get (pichat-session-tool-selection session) :mcp))))))))

(ert-deftest pichat-presets-empty-tools-disable-everything ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/" nil
                                             '(:preset review :tools (:builtins nil :mcp nil)))))
          (should (equal '("--no-tools" "--no-mcp")
                         (cl-subseq (member "--no-tools"
                                            (pichat-rpc-build-command session))
                                    0 2))))))))

(ert-deftest pichat-presets-pass-through-rejects-customization ()
  (pichat-test-with-clean-state
    (should-error (pichat-start-session "/tmp/" nil
                                        '(:preset standard :tools (:builtins nil)))
                  :type 'user-error)
    (should-not (pichat-session-list))))

(ert-deftest pichat-presets-shared-prompt-composes-and-captures-one-argument ()
  (pichat-test-with-clean-state
    (let ((pichat-presets (copy-tree pichat-presets))
          (pichat-rpc-command nil)
          (pichat-pi-extra-args nil)
          (file (make-temp-file "pichat-shared-prompt-")))
      (unwind-protect
          (progn
            (with-temp-file file (insert "Shared file"))
            (pichat-make-preset 'test-shared
              :system-prompt "Replacement"
              :append-system-prompt '("Preset one" "Preset two"))
            (let ((pichat-append-system-prompt
                   (list "Shared text" (list :file file))))
              (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
                (let* ((session (pichat-start-session
                                 "/tmp/" nil '(:preset test-shared)))
                       (argv (pichat-rpc-build-command session))
                       (expected "Preset one\n\nPreset two\n\nShared text\n\nShared file\n"))
                  (should (= 1 (cl-count "--append-system-prompt" argv
                                         :test #'equal)))
                  (should (equal expected
                                 (cadr (member "--append-system-prompt" argv))))
                  (should (equal "Replacement\n"
                                 (cadr (member "--system-prompt" argv))))
                  (with-temp-file file (insert "Changed file"))
                  (setq pichat-append-system-prompt "Changed setting")
                  (should (equal argv (pichat-rpc-build-command session)))
                  (should (equal "Preset one\n\nPreset two\n\nChanged setting\n"
                                 (plist-get (pichat-presets-resolve 'test-shared)
                                            :append-system-prompt)))))))
        (delete-file file)))))

(ert-deftest pichat-presets-shared-prompt-applies-without-preset-additions ()
  (dolist (name '(manual standard))
    (let ((pichat-append-system-prompt "Shared"))
      (let ((snapshot (pichat-presets-resolve name)))
        (should (equal "Shared\n" (plist-get snapshot :append-system-prompt)))
        (should-not (plist-get snapshot :system-prompt))
        (should (pichat-presets-overrides-p snapshot)))))
  (let ((pichat-append-system-prompt nil))
    (should-not (plist-get (pichat-presets-resolve 'standard)
                          :append-system-prompt))))

(ert-deftest pichat-presets-shared-prompt-rejects-invalid-sources ()
  (dolist (source '(" " 42 (:file "relative.md") ("Valid" "")
                    (:file "/definitely/missing/pichat-shared.md")))
    (let ((pichat-append-system-prompt source))
      (should-error (pichat-presets-resolve 'standard) :type 'user-error))))

(ert-deftest pichat-presets-shared-prompt-rejects-conflicting-launch-options ()
  (pichat-test-with-clean-state
    (let ((pichat-append-system-prompt "Shared")
          (pichat-rpc-command nil)
          (pichat-pi-extra-args '("--append-system-prompt" "Other")))
      (should-error (pichat-start-session "/tmp/" nil '(:preset standard))
                    :type 'user-error)
      (setq pichat-pi-extra-args nil
            pichat-rpc-command '("wrapper" "pi" "--mode" "rpc"))
      (should-error (pichat-start-session "/tmp/" nil '(:preset standard))
                    :type 'user-error)
      (should-not (pichat-session-list)))))

(ert-deftest pichat-presets-grouped-tools-and-extensions-validate-and-resolve ()
  (let ((pichat-presets (copy-tree pichat-presets))
        (pichat-append-system-prompt nil))
    ;; The agreed form: built-ins and per-extension groups in :tools, the
    ;; extensions to load in :extensions.
    (pichat-make-preset 'manual-guarded
      :description "Manual tools with the secrets guard loaded."
      :tools '("read" "grep" "find" "ls" "edit" "write"
               ("npm:@pi-vault/pi-guardrails@1.2.3"
                "guardrails_status" "guardrails_policy")
               ("builtin:codemode" "codemode"))
      :extensions '("~/pi-ext/protect-secrets.ts"
                    "npm:@pi-vault/pi-guardrails@1.2.3"))
    (let* ((spec (pichat-presets-resolve 'manual-guarded))
           (tools (pichat-tool-selection-resolve spec)))
      (should (equal '("read" "grep" "find" "ls" "edit" "write") (plist-get spec :tools)))
      (should (equal '("guardrails_status" "guardrails_policy" "codemode")
                     (plist-get spec :extensions)))
      (should (equal '(("npm:@pi-vault/pi-guardrails@1.2.3"
                        "guardrails_status" "guardrails_policy")
                       ("builtin:codemode" "codemode"))
                     (plist-get spec :tool-groups)))
      (should (equal '("~/pi-ext/protect-secrets.ts" "npm:@pi-vault/pi-guardrails@1.2.3")
                     (plist-get spec :load-extensions)))
      (should (equal (plist-get spec :load-extensions) (pichat-presets-load-extensions spec)))
      (should (equal '("~/pi-ext/protect-secrets.ts" "npm:@pi-vault/pi-guardrails@1.2.3" "x.ts")
                     (pichat-presets-load-extensions
                      spec '("npm:@pi-vault/pi-guardrails@1.2.3" "x.ts"))))
      (should (eq spec (pichat-presets-validate-snapshot spec)))
      (should (equal (list "--tools" (concat "read,grep,find,ls,edit,write,"
                                             "codemode,guardrails_policy,guardrails_status")
                           "--no-mcp")
                     (pichat-tool-selection-args tools))))
    ;; Presets without the new keys resolve as before.
    (let ((spec (pichat-presets-resolve 'manual)))
      (should-not (plist-member spec :tool-groups))
      (should-not (plist-member spec :load-extensions))
      (should-not (pichat-presets-load-extensions spec)))
    ;; Extensions may be loaded with Pi's default tools.
    (pichat-make-preset 'standard-guarded :tools :default :extensions '("./guard.ts"))
    (should (equal '("./guard.ts")
                   (plist-get (pichat-presets-resolve 'standard-guarded) :load-extensions)))
    (should-not (pichat-tool-selection-args
                 (pichat-tool-selection-resolve (pichat-presets-resolve 'standard-guarded))))
    ;; Old-style tool names in :extensions get a clear refusal.
    (should (string-match-p
             "\"child\" looks like an extension tool name: select tools in :tools as (SOURCE \"child\" ...)"
             (cadr (should-error (pichat-make-preset 'old :tools '("read") :extensions '("child"))
                                 :type 'user-error))))
    (dolist (spec '((:tools ("read" ("npm:x")))                  ; empty group
                    (:tools (("-x" "tool")))                     ; source like an option
                    (:tools ((("npm:x") "tool")))                ; source not a string
                    (:tools (("npm:x" "read")))                  ; built-in in a group
                    (:tools (("npm:x" "a" . "b")))               ; improper group
                    (:tools (("npm:x" "a") ("npm:x" "b")))       ; same source twice
                    (:tools (("npm:x" . :all) ("npm:x" "b")))    ; same source, :all
                    (:tools (("npm:x" . :some)))                 ; unknown keyword
                    (:tools (("npm:x" :all)))                    ; :all as a tool name
                    (:tools (("npm:x" "a") ("npm:y" "a")))       ; same tool twice
                    (:tools :default :emacs-tools ("e"))
                    (:tools (("npm:x" "same")) :emacs-tools ("same"))
                    (:tools (("npm:x" "mcp__s__t")) :mcp (("s" . "t")))
                    (:extensions ("a.ts" "a.ts"))
                    (:extensions "a.ts")
                    (:extensions ("-e"))
                    (:extensions (" a.ts"))
                    (:extensions ("npm:x" 1))))
      (should-error (apply #'pichat-make-preset 'invalid spec) :type 'user-error))
    ;; A saved definition with the old form fails when resolved.
    (let ((pichat-saved-presets '((legacy :tools ("read") :extensions ("child")))))
      (should-error (pichat-presets-resolve 'legacy) :type 'user-error))
    ;; Captured snapshots (jobs) keep exact extension tool names.
    (should (pichat-presets-validate-snapshot
             '(:name captured :tools ("read") :extensions ("child"))))
    (dolist (snapshot '((:name bad :tools :default :extensions ("child"))
                        (:name bad :tools ("read" ("npm:x" "a")))
                        (:name bad :tools ("read") :extensions ("read"))
                        (:name bad :tools ("read") :load-extensions ("child"))))
      (should-error (pichat-presets-validate-snapshot snapshot) :type 'user-error))))

(ert-deftest pichat-presets-include-future-tools-expand-before-a-runtime-starts ()
  (let ((pichat-presets (copy-tree pichat-presets))
        (pichat-saved-presets nil)
        (pichat-append-system-prompt nil))
    (pichat-make-preset 'future
      :tools '("read" ("npm:pkg@1" . :all) ("./guard.ts" "guard_check"))
      :extensions '("npm:pkg@1" "./guard.ts"))
    (let* ((spec (pichat-presets-resolve 'future))
           (baseline (pichat-tool-selection-resolve spec)))
      ;; The :all group is kept; only exact names are in :extensions.
      (should (equal '(("npm:pkg@1" . :all) ("./guard.ts" "guard_check"))
                     (plist-get spec :tool-groups)))
      (should (equal '("guard_check") (plist-get spec :extensions)))
      (should (equal '("npm:pkg@1") (pichat-presets-all-sources spec)))
      (should (equal '("npm:pkg@1") (pichat-presets-pending-all spec)))
      ;; Its baseline cannot start a runtime: the names are incomplete.
      (should (equal '("npm:pkg@1") (plist-get baseline :all)))
      (should (equal '("npm:pkg@1") (plist-get baseline :unexpanded)))
      ;; Re-resolving that baseline as a selection keeps it incomplete.
      (should (plist-get (pichat-tool-selection-resolve spec baseline) :unexpanded))
      (should (string-match-p
               "Preset future includes future tools of npm:pkg@1"
               (cadr (should-error (pichat-tool-selection-check-expanded baseline 'future)
                                   :type 'user-error))))
      (should (string-match-p
               "includes future tools of npm:pkg@1"
               (cadr (should-error (pichat-prepare-session "/tmp/" nil '(:preset future))
                                   :type 'user-error))))
      ;; Expansion records the discovered names with the snapshot.
      (let* ((expanded (pichat-presets-expand-all
                        spec '(("npm:pkg@1" "pkg_b" "pkg_a" "guard_check"))))
             (tools (pichat-tool-selection-resolve expanded)))
        (should (equal '("guard_check" "pkg_b" "pkg_a") (plist-get expanded :extensions)))
        (should (equal '(("npm:pkg@1" "pkg_b" "pkg_a" "guard_check"))
                       (plist-get expanded :expanded-all)))
        (should-not (pichat-presets-pending-all expanded))
        (should-not (plist-get tools :unexpanded))
        (should (equal '("npm:pkg@1") (plist-get tools :all)))
        (should (equal '("--tools" "read,guard_check,pkg_a,pkg_b" "--no-mcp")
                       (pichat-tool-selection-args tools)))
        ;; The input snapshot is unchanged.
        (should (pichat-presets-pending-all spec))
        ;; A runtime records the expanded snapshot and restarts with it.
        (let* ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
               (pichat-bridge-extension-file nil) (pichat-path-mappings nil)
               (session (pichat-prepare-session "/tmp/" nil
                                                (list :preset-spec expanded))))
          (should (equal expanded (pichat-session-preset-spec session)))
          (should (equal '("--tools" "read,guard_check,pkg_a,pkg_b")
                         (seq-take (member "--tools" (pichat-rpc-build-command session)) 2)))
          (let ((base (pichat-reconfigure-captured-configuration session)))
            (should (equal expanded (plist-get base :preset-spec)))
            (should-not (pichat-reconfigure-effective-change-p base base))
            ;; Re-selecting the preset needs a new expansion first.
            (let ((reselected (pichat-reconfigure-select-preset base 'future)))
              (should (pichat-reconfigure-effective-change-p base reselected))
              (should-error (pichat-reconfigure-validated-command
                             session reselected '(:model (:provider "p" :id "m")))
                            :type 'user-error)))))
        ;; An empty expansion is complete too.
        (should-not (plist-get (pichat-tool-selection-resolve
                                (pichat-presets-expand-all spec '(("npm:pkg@1"))))
                               :unexpanded))
      ;; Missing, invalid or conflicting expansions are refused.
      (dolist (expansions '(nil (("npm:pkg@1" "read")) (("npm:pkg@1" "bad name"))))
        (should-error (pichat-presets-expand-all spec expansions) :type 'user-error))
      ;; An explicit selection is complete and may keep :all.
      (let ((tools (pichat-tool-selection-resolve
                    spec '(:builtins ("read") :extensions ("pkg_a") :all ("npm:pkg@1")))))
        (should-not (plist-get tools :unexpanded))
        (should (equal '("npm:pkg@1") (plist-get tools :all))))
      (dolist (all '(("npm:pkg@1" "npm:pkg@1") ("-x") "npm:pkg@1"))
        (should-error (pichat-tool-selection-resolve
                       spec (list :builtins '("read") :all all))
                      :type 'user-error)))
    ;; Presets without :all groups never need an expansion.
    (should-not (pichat-presets-pending-all (pichat-presets-resolve 'manual)))
    (should-not (plist-member (pichat-tool-selection-resolve (pichat-presets-resolve 'manual))
                              :all))))

(ert-deftest pichat-presets-old-style-saved-extensions-refuse-launch-and-stay-listed ()
  ;; A definition saved before :extensions meant extensions to load.
  (pichat-test-with-clean-state
    (let ((pichat-saved-presets '((legacy :tools ("read") :extensions ("project_search"))))
          (pichat-rpc-command nil) (pichat-pi-extra-args nil)
          (pichat-append-system-prompt nil))
      ;; It stays listed, so it can be found and edited or replaced.
      (should (memq 'legacy (pichat-presets-names)))
      (dolist (start (list (lambda () (pichat-start-session "/tmp/" nil '(:preset legacy)))
                           (lambda () (pichat--open-launch-profile
                                       '(:preset legacy :display-function ignore) "/tmp/"))))
        (should (string-match-p
                 (concat "\"project_search\" looks like an extension tool name: "
                         "select tools in :tools as (SOURCE \"project_search\" \\.\\.\\.)")
                 (cadr (should-error (funcall start) :type 'user-error)))))
      (should-not (pichat-session-list))
      ;; The new form of the same choice is accepted.
      (setq pichat-saved-presets
            '((legacy :tools ("read" ("git:github.com/owner/project-search" "project_search")))))
      (should (equal '("project_search")
                     (plist-get (pichat-presets-resolve 'legacy) :extensions))))))

(ert-deftest pichat-presets-readme-examples-validate-and-resolve ()
  ;; Every `pichat-make-preset' example in the README is a valid definition.
  (let ((pichat-presets (copy-tree pichat-presets))
        (pichat-saved-presets nil)
        (pichat-append-system-prompt nil)
        (readme (expand-file-name "README.md" (file-name-directory
                                               (locate-library "pichat"))))
        names)
    (with-temp-buffer
      (insert-file-contents readme)
      (while (re-search-forward "^```elisp\n" nil t)
        (let ((start (point)))
          (re-search-forward "^```$")
          (save-restriction
            (narrow-to-region start (match-beginning 0))
            (goto-char (point-min))
            (condition-case nil
                (while t
                  (let ((form (read (current-buffer))))
                    (when (eq (car-safe form) 'pichat-make-preset)
                      (push (eval form t) names))))
              (end-of-file nil))
            (goto-char (point-max))))))
    (setq names (nreverse names))
    ;; The documented preset forms are all among them.
    (dolist (name '(manual web-search project-review manual-guarded manual-guarded-all))
      (should (memq name names)))
    (dolist (name names)
      (should (eq name (plist-get (pichat-presets-resolve name) :name))))
    (let ((spec (pichat-presets-resolve 'manual-guarded)))
      (should (equal '("guardrails_status" "guardrails_policy") (plist-get spec :extensions)))
      (should (equal '("~/pi-ext/protect-secrets.ts" "npm:@pi-vault/pi-guardrails@1.2.3")
                     (plist-get spec :load-extensions))))
    (should (equal '("npm:@pi-vault/pi-guardrails@1.2.3")
                   (pichat-presets-pending-all (pichat-presets-resolve 'manual-guarded-all))))))

(provide 'pichat-test-presets)
;;; pichat-test-presets.el ends here
