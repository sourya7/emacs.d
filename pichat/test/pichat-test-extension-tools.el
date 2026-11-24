;;; pichat-test-extension-tools.el --- Discovery-backed configuration -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-test-startup-cache)
(require 'pichat-tool-picker)
(require 'pichat-tool-runtime)
(require 'pichat-reconfigure)

(defconst pichat-test-extension-tools-fixture
  (expand-file-name "fixtures/tool-control-extension.ts" pichat-test-directory))

(ert-deftest pichat-extension-tools-presets-are-explicit-and-pass-through-is-unchanged ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'custom :tools '("read" ("npm:pkg" "child")))
    (should (equal '("--tools" "read,child" "--no-mcp")
                   (pichat-tool-selection-args (pichat-tool-selection-resolve (pichat-presets-resolve 'custom)))))
    (dolist (names '(("read") ("powershell") ("child" "child") ("wild*") ("comma,name") ("")))
      (should-error (pichat-make-preset 'bad :tools (list (cons "npm:pkg" names)))
                    :type 'user-error))
    ;; Old-style tool names in :extensions are refused.
    (should-error (pichat-make-preset 'bad :tools '("read") :extensions '("child"))
                  :type 'user-error)
    (should-not (plist-get (pichat-tool-selection-resolve (pichat-presets-resolve 'manual)) :extensions))
    (should-not (pichat-tool-selection-args (pichat-tool-selection-resolve (pichat-presets-resolve 'standard))))))

(ert-deftest pichat-extension-tools-selections-preserve-boundaries-and-effective-identity ()
  (let* ((before (list :preset-spec (pichat-presets-resolve 'manual)
                       :tool-selection '(:builtins ("read") :mcp nil :extensions ("child"))))
         (after (pichat-reconfigure-select-tools before '(:builtins ("read") :extensions ("other")))))
    (should (pichat-reconfigure-effective-change-p before after))
    (should (equal '("child") (plist-get (plist-get before :tool-selection) :extensions)))
    (should (equal '("--tools" "read,other" "--no-mcp")
                   (pichat-tool-selection-args (plist-get after :tool-selection))))
    (should-error (pichat-reconfigure-select-tools before '(:builtins ("bash") :extensions ("child"))))
    (should-error (pichat-tool-selection-resolve
                   (pichat-presets-resolve 'standard) '(:extensions ("child"))))
    (should-error (pichat-reconfigure-select-tools
                   before '(:builtins nil :mcp (("s" . "t")) :extensions ("mcp__s__t")))))
  (let* ((spec (pichat-presets-resolve 'manual))
         (a (list :preset-spec spec :tool-selection '(:builtins nil :extensions ("b" "a"))))
         (b (list :preset-spec spec :tool-selection '(:builtins nil :extensions ("a" "b")))))
    (should-not (pichat-reconfigure-effective-change-p a b))))

(ert-deftest pichat-extension-tools-picker-checks-descriptions-eligibility-reset-and-cancel ()
  (let* ((spec (append (list :extensions '("child")) (pichat-presets-resolve 'manual)))
         (cache (pichat-tool-discovery-draft-create
                 :status 'ready :tools '((:name "child" :description "Useful child" :eligible t)
                                         (:name "hidden" :description "Hidden" :eligible nil))))
         (pichat-tool-picker--state
          (list :preset spec :baseline '("read") :draft '(:builtins ("read") :extensions ("child"))
                :discovery cache :servers nil :loaded t :page 0))
         (transient--prefix (transient--init-prefix 'pichat-tool-picker))
         (transient--layout (transient--init-suffixes 'pichat-tool-picker))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (with-temp-buffer
      (transient--insert-groups)
      (should (string-match-p "Extension tools" (buffer-string)))
      (should (string-match-p "Useful child" (buffer-string)))
      (should (string-match-p "\\[✓\\] child" (buffer-string)))
      (should-not (string-match-p "inactive" (buffer-string))))
    (let ((hidden (cl-find "e2" transient--suffixes :key (lambda (suffix) (oref suffix key)) :test #'equal)))
      (should hidden)
      (should-error (funcall (oref hidden command)) :type 'user-error))
    (pichat-tool-picker-none)
    (should-not (plist-get (pichat-tool-picker--selection) :extensions))
    (pichat-tool-picker-reset)
    (should (equal '("child") (plist-get (pichat-tool-picker--selection) :extensions)))
    (let (result)
      (setf (plist-get pichat-tool-picker--state :callback) (lambda (value) (setq result value)))
      (pichat-tool-picker--toggle :extensions "child")
      (pichat-tool-picker-cancel)
      (should (eq result :cancel))
      (should (equal '("child") (plist-get spec :extensions))))))

(ert-deftest pichat-extension-tools-picker-partitions-exact-known-names-without-prefix-guesses ()
  (let ((pichat-tool-picker--state
         (list :servers '((:name "known" :tools ((:name "tool"))))
               :discovery
               (pichat-tool-discovery-draft-create
                :status 'ready
                :tools '((:name "read") (:name "powershell")
                         (:name "mcp__known__tool") (:name "mcp__unlisted__tool")
                         (:name "codemode") (:name "child"))))))
    (should (equal '("mcp__unlisted__tool" "codemode" "child")
                   (mapcar (lambda (tool) (plist-get tool :name))
                           (pichat-tool-picker--extension-tools))))
    ;; Without provenance (older Pi) the picker keeps one flat list.
    (should-not (pichat-tool-picker--grouped-p))))

(defun pichat-test-extension-tools-source (source path &optional base-dir)
  "Return discovery provenance for SOURCE and PATH, with BASE-DIR."
  (append (list :path path :source source
                :scope (if (equal source "builtin") "temporary" "user")
                :origin (if base-dir "package" "top-level"))
          (when base-dir (list :base-dir base-dir))))

(defun pichat-test-extension-tools-grouped-state (&optional extra-tools)
  "Return a Tools picker state whose discovery reports provenance.
EXTRA-TOOLS are appended to the catalogue."
  (let ((guardrails (pichat-test-extension-tools-source
                     "npm:@pi-vault/pi-guardrails@1.2.3"
                     "/cache/node_modules/@pi-vault/pi-guardrails/index.ts"
                     "/cache/node_modules/@pi-vault/pi-guardrails"))
        (builtin (lambda (name) (pichat-test-extension-tools-source "builtin" (concat "builtin:" name)))))
    (list :preset (pichat-presets-resolve 'manual) :baseline '("read")
          :draft '(:builtins ("read") :mcp nil :extensions ("guardrails_status") :emacs nil)
          :servers '((:name "known" :tools ((:name "tool")))) :loaded t :page 0
          :discovery
          (pichat-tool-discovery-draft-create
           :status 'ready
           :tools
           (append
            (list (list :name "read" :eligible t :description "Read" :source (funcall builtin "read"))
                  (list :name "codemode" :eligible t :description "Run code"
                        :source (funcall builtin "codemode"))
                  (list :name "guardrails_status" :eligible t :description "Status" :source guardrails)
                  (list :name "mcp__known__tool" :eligible t :description "Listed MCP"
                        :source (funcall builtin "mcp"))
                  (list :name "mcp__unlisted__tool" :eligible t :description "Unlisted MCP"
                        :source (funcall builtin "mcp"))
                  (list :name "archive_search" :eligible t :description "Search"
                        :source (pichat-test-extension-tools-source
                                 "git:github.com/example/pi-archive@v1" "/git/pi-archive/index.ts"
                                 "/git/pi-archive"))
                  (list :name "guardrails_policy" :eligible t :description "Policy" :source guardrails)
                  (list :name "guardrails_hidden" :eligible nil :description "Hidden" :source guardrails)
                  (list :name "probe_child" :eligible t :description "Child"
                        :source (pichat-test-extension-tools-source "cli" "/ext/probe.ts"))
                  (list :name "legacy" :eligible t :description "No provenance")
                  (list :name "tool_search" :eligible t :description "Find tools"
                        :source (funcall builtin "tool-search")))
            extra-tools)))))

(defun pichat-test-extension-tools-render (prefix)
  "Return the text of PREFIX for the current picker state."
  (let* ((transient--prefix (transient--init-prefix prefix))
         (transient--layout (transient--init-suffixes prefix))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (with-temp-buffer (transient--insert-groups) (buffer-string))))

(defun pichat-test-extension-tools-run (prefix key)
  "Run the suffix bound to KEY in PREFIX for the current picker state."
  (let* ((transient--prefix (transient--init-prefix prefix))
         (transient--layout (transient--init-suffixes prefix))
         (suffix (cl-find key (transient--flatten-suffixes transient--layout)
                          :key (lambda (suffix) (oref suffix key)) :test #'equal)))
    (should suffix)
    (funcall (oref suffix command))))

(ert-deftest pichat-extension-tools-picker-groups-by-provenance-with-pi-built-in-last ()
  (let ((pichat-tool-picker--state (pichat-test-extension-tools-grouped-state)))
    ;; Core built-ins and listed or builtin:mcp tools are not extension tools.
    (should (equal '("codemode" "guardrails_status" "archive_search" "guardrails_policy"
                     "guardrails_hidden" "probe_child" "legacy" "tool_search")
                   (mapcar (lambda (tool) (plist-get tool :name))
                           (pichat-tool-picker--extension-tools))))
    (should (equal '(("npm:@pi-vault/pi-guardrails@1.2.3" "pi-guardrails"
                      "guardrails_status" "guardrails_policy" "guardrails_hidden")
                     ("git:github.com/example/pi-archive@v1" "pi-archive" "archive_search")
                     ("/ext/probe.ts" "probe" "probe_child")
                     (:unattributed "Unattributed" "legacy")
                     (:builtin "Pi built-in" "codemode" "tool_search"))
                   (mapcar (lambda (group)
                             (append (list (car group) (cadr group))
                                     (mapcar (lambda (tool) (plist-get tool :name)) (cddr group))))
                           (pichat-tool-picker--extension-groups))))
    (let ((text (pichat-test-extension-tools-render 'pichat-tool-picker)))
      (should (string-match-p "e1 pi-guardrails (1/3) →" text))
      (should (string-match-p "e2 pi-archive (0/1) →" text))
      (should (string-match-p "e3 probe (0/1) →" text))
      (should (string-match-p "e4 Unattributed (0/1) →" text))
      (should (string-match-p "e5 Pi built-in (0/2) →" text))
      (should-not (string-match-p "guardrails_policy\\|mcp__" text)))
    ;; Labels shared by two packages fall back to the exact source.
    (let ((pichat-tool-picker--state
           (pichat-test-extension-tools-grouped-state
            (list (list :name "other_status" :eligible t :description ""
                        :source (pichat-test-extension-tools-source
                                 "npm:pi-guardrails" "/cache/node_modules/pi-guardrails/index.ts"
                                 "/cache/node_modules/pi-guardrails"))))))
      (should (equal '("npm:@pi-vault/pi-guardrails@1.2.3" "pi-archive" "probe" "npm:pi-guardrails")
                     (cl-subseq (mapcar #'cadr (pichat-tool-picker--extension-groups)) 0 4))))))

(ert-deftest pichat-extension-tools-picker-group-page-checks-pages-and-returns ()
  (let ((pichat-tool-picker--state
         (pichat-test-extension-tools-grouped-state
          ;; 21 more guardrails tools need a second group page.
          (cl-loop for index from 1 to 21
                   collect (list :name (format "guard_%02d" index) :eligible t :description "More"
                                 :source (pichat-test-extension-tools-source
                                          "npm:@pi-vault/pi-guardrails@1.2.3" "/cache/g/index.ts"
                                          "/cache/node_modules/@pi-vault/pi-guardrails")))))
        opened)
    (setf (plist-get pichat-tool-picker--state :draft)
          '(:builtins ("read") :mcp nil :extensions ("guardrails_status" "codemode") :emacs nil))
    (cl-letf (((symbol-function 'transient-setup) (lambda (prefix &rest _) (setq opened prefix))))
      (pichat-test-extension-tools-run 'pichat-tool-picker "e1")
      (should (eq opened 'pichat-tool-picker-extension-group))
      (should (equal "npm:@pi-vault/pi-guardrails@1.2.3"
                     (plist-get pichat-tool-picker--state :extension-group)))
      (let ((text (pichat-test-extension-tools-render 'pichat-tool-picker-extension-group)))
        (should (string-match-p "^pi-guardrails: 1/24 selected$" text))
        (should (string-match-p "npm:@pi-vault/pi-guardrails@1\\.2\\.3" text))
        (should (string-match-p "\\[✓\\] guardrails_status — Status" text))
        (should (string-match-p "guardrails_hidden (unavailable)" text))
        (should (string-match-p "All in extension" text))
        (should-not (string-match-p "guard_21\\|archive_search" text)))
      ;; Checkboxes toggle exact names; hidden tools cannot be enabled.
      (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "2")
      (should (member "guardrails_policy" (plist-get (pichat-tool-picker--selection) :extensions)))
      (should-error (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "3")
                    :type 'user-error)
      ;; All/None change only this group's current eligible tools.
      (pichat-tool-picker-extension-group-all)
      (let ((checked (plist-get (pichat-tool-picker--selection) :extensions)))
        (should (= 24 (length checked)))
        (should (member "codemode" checked))
        (should (member "guard_21" checked))
        (should-not (member "guardrails_hidden" checked)))
      (pichat-tool-picker-extension-group-none)
      (should (equal '("codemode") (plist-get (pichat-tool-picker--selection) :extensions)))
      ;; Paging stays within the group's tools.
      (pichat-tool-picker--page 1 'pichat-tool-picker-extension-group)
      (should (= 1 (plist-get pichat-tool-picker--state :page)))
      (pichat-tool-picker--page 1 'pichat-tool-picker-extension-group)
      (should (= 1 (plist-get pichat-tool-picker--state :page)))
      (should (string-match-p "guard_21" (pichat-test-extension-tools-render
                                          'pichat-tool-picker-extension-group)))
      (pichat-tool-picker-back)
      (should (eq opened 'pichat-tool-picker))
      (should (= 0 (plist-get pichat-tool-picker--state :page)))
      (should (string-match-p "e5 Pi built-in (1/2) →"
                              (pichat-test-extension-tools-render 'pichat-tool-picker)))
      ;; Top-level All checks every visible eligible extension tool.
      (pichat-tool-picker-all)
      (should (equal (cl-loop for tool in (pichat-tool-picker--extension-tools)
                              when (plist-get tool :eligible) collect (plist-get tool :name))
                     (plist-get (pichat-tool-picker--selection) :extensions))))))

(ert-deftest pichat-extension-tools-picker-include-future-tools-checks-current-tools ()
  (let ((pichat-presets (copy-tree pichat-presets))
        (pichat-saved-presets nil)
        (pichat-append-system-prompt nil)
        (guardrails "npm:@pi-vault/pi-guardrails@1.2.3")
        result opened)
    (pichat-make-preset 'future
      :tools '("read" ("npm:@pi-vault/pi-guardrails@1.2.3" . :all)))
    (let* ((preset (pichat-presets-resolve 'future))
           (pichat-tool-picker--state (pichat-test-extension-tools-grouped-state)))
      ;; The picker opens on the unexpanded baseline; once discovery is
      ;; ready the group's current eligible tools show checked.
      (setf (plist-get pichat-tool-picker--state :preset) preset
            (plist-get pichat-tool-picker--state :draft) (pichat-tool-selection-resolve preset)
            (plist-get pichat-tool-picker--state :callback) (lambda (value) (setq result value)))
      (should (plist-get (pichat-tool-picker--selection) :unexpanded))
      (pichat-tool-picker--materialize-all)
      (should-not (plist-member (pichat-tool-picker--selection) :unexpanded))
      (should (equal '("guardrails_status" "guardrails_policy")
                     (plist-get (pichat-tool-picker--selection) :extensions)))
      (should (string-match-p "e1 pi-guardrails (all) →"
                              (pichat-test-extension-tools-render 'pichat-tool-picker)))
      (cl-letf (((symbol-function 'transient-setup) (lambda (prefix &rest _) (setq opened prefix))))
        (pichat-test-extension-tools-run 'pichat-tool-picker "e1")
        (should (eq opened 'pichat-tool-picker-extension-group))
        (let ((text (pichat-test-extension-tools-render 'pichat-tool-picker-extension-group)))
          (should (string-match-p "^ \\* \\[✓\\] Include future tools$" text))
          (should (string-match-p "\\[✓\\] guardrails_policy" text)))
        ;; Unchecking a tool of the group keeps exact names, without :all.
        (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "2")
        (should-not (plist-get (pichat-tool-picker--selection) :all))
        (should (equal '("guardrails_status") (plist-get (pichat-tool-picker--selection) :extensions)))
        (should (string-match-p "\\[ \\] Include future tools"
                                (pichat-test-extension-tools-render
                                 'pichat-tool-picker-extension-group)))
        (should (string-match-p "e1 pi-guardrails (1/3) →"
                                (pichat-test-extension-tools-render 'pichat-tool-picker)))
        ;; Turning it on checks every current eligible tool again.
        (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "*")
        (should (equal (list guardrails) (plist-get (pichat-tool-picker--selection) :all)))
        (should (equal '("guardrails_status" "guardrails_policy")
                       (plist-get (pichat-tool-picker--selection) :extensions)))
        ;; Turning it off keeps the tools checked; None also turns it off.
        (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "*")
        (should-not (plist-get (pichat-tool-picker--selection) :all))
        (should (equal '("guardrails_status" "guardrails_policy")
                       (plist-get (pichat-tool-picker--selection) :extensions)))
        (pichat-test-extension-tools-run 'pichat-tool-picker-extension-group "*")
        (pichat-tool-picker-extension-group-none)
        (should-not (plist-get (pichat-tool-picker--selection) :all))
        (should-not (plist-get (pichat-tool-picker--selection) :extensions))
        ;; Groups without a stable source, such as Pi built-in, have no row.
        (setf (plist-get pichat-tool-picker--state :extension-group) :builtin)
        (should-not (string-match-p "Include future tools"
                                    (pichat-test-extension-tools-render
                                     'pichat-tool-picker-extension-group))))
      ;; Reset restores the preset's :all with its current tools; top-level
      ;; All never adds :all, None clears it.
      (pichat-tool-picker-reset)
      (should (equal (list guardrails) (plist-get (pichat-tool-picker--selection) :all)))
      (should (equal '("guardrails_status" "guardrails_policy")
                     (plist-get (pichat-tool-picker--selection) :extensions)))
      (pichat-tool-picker-none)
      (pichat-tool-picker-all)
      (should-not (plist-get (pichat-tool-picker--selection) :all))
      (pichat-tool-picker-reset)
      ;; Apply returns the exact names found now with :all; the snapshot is
      ;; complete, so a runtime can start from it.
      (pichat-tool-picker-apply)
      (should (equal (list guardrails) (plist-get result :all)))
      (let ((tools (pichat-tool-selection-resolve preset result)))
        (should-not (plist-get tools :unexpanded))
        (should (equal '("--tools" "read,guardrails_policy,guardrails_status" "--no-mcp")
                       (pichat-tool-selection-args tools)))))
    ;; Without ready discovery the baseline cannot be applied.
    (let* ((preset (pichat-presets-resolve 'future))
           (pichat-tool-picker--state
            (list :preset preset :baseline '("read")
                  :draft (pichat-tool-selection-resolve preset)
                  :discovery (pichat-tool-discovery-draft-create :status 'failed :error "boom")
                  :servers nil :loaded t :page 0)))
      (pichat-tool-picker--materialize-all)
      (should (plist-get (pichat-tool-picker--selection) :unexpanded))
      (should-error (pichat-tool-picker-apply) :type 'user-error)
      (setf (plist-get pichat-tool-picker--state :extension-group) guardrails)
      (setf (plist-get pichat-tool-picker--state :draft) '(:builtins ("read")))
      (should-error (pichat-tool-picker--toggle-future guardrails) :type 'user-error))))

(ert-deftest pichat-extension-tools-expand-all-uses-provenance-and-eligibility ()
  (let* ((builtin (lambda (name) (pichat-test-extension-tools-source "builtin" (concat "builtin:" name))))
         (cache "/home/u/.pi/agent/tmp/extensions/npm/f35b2129/node_modules/@probe/pkg/index.ts")
         (cli (list :path cache :source "cli" :scope "temporary" :origin "top-level"))
         (draft (pichat-tool-discovery-draft-create
                 :status 'ready
                 :context (list :transport pichat-transport-local :cwd "/w/"
                                :extensions '("npm:@probe/pkg@1"))
                 :tools (list (list :name "pkg_a" :eligible t :source cli)
                              (list :name "pkg_hidden" :eligible nil :source cli)
                              (list :name "read" :eligible t :source (funcall builtin "read"))
                              (list :name "codemode" :eligible t :source (funcall builtin "codemode"))
                              (list :name "mcp__s__t" :eligible t :source (funcall builtin "mcp"))
                              (list :name "other" :eligible t
                                    :source (pichat-test-extension-tools-source
                                             "git:github.com/o/r" "/git/r/index.ts" "/git/r")))))
         (preset (list :name 'future :tools '("read") :extensions '("other")
                       :tool-groups '(("npm:@probe/pkg@1" . :all) ("builtin:codemode" . :all)
                                      ("git:github.com/o/r" "other") ("npm:absent" . :all))))
         (expanded (pichat-tool-picker-expand-all preset draft)))
    ;; Added specs match by attribution, built-ins by their path; hidden,
    ;; core built-in and MCP tools are never included.
    (should (equal '(("npm:@probe/pkg@1" "pkg_a") ("builtin:codemode" "codemode") ("npm:absent"))
                   (plist-get expanded :expanded-all)))
    (should (equal '("other" "pkg_a" "codemode") (plist-get expanded :extensions)))
    (should-not (pichat-tool-picker-group-tool-names "builtin:read" (pichat-tool-discovery-draft-tools draft)))))

(ert-deftest pichat-extension-tools-tool-sources-name-the-saved-group-of-each-tool ()
  (let* ((cache "/home/u/.pi/agent/tmp/extensions/npm/f35b2129/node_modules/@probe/pkg/index.ts")
         (stray "/home/u/.pi/agent/tmp/extensions/npm/0123abcd/node_modules/other/index.ts")
         (cli (lambda (path) (list :path path :source "cli" :scope "temporary" :origin "top-level")))
         (draft (pichat-tool-discovery-draft-create
                 :status 'ready
                 :context (list :transport pichat-transport-local :cwd "/w/"
                                :extensions '("npm:@probe/pkg@1"))
                 :tools (list (list :name "pkg_a" :eligible t :source (funcall cli cache))
                              (list :name "stray" :eligible t :source (funcall cli stray))
                              (list :name "codemode" :eligible t
                                    :source (pichat-test-extension-tools-source
                                             "builtin" "builtin:codemode"))
                              (list :name "git_tool" :eligible t
                                    :source (pichat-test-extension-tools-source
                                             "git:github.com/o/r" "/git/r/index.ts" "/git/r"))
                              (list :name "local_tool" :eligible t
                                    :source (pichat-test-extension-tools-source
                                             "local" "/ext/pkg/index.ts" "/ext/pkg"))
                              (list :name "old_pi" :eligible t)))))
    ;; The Tools picker's group key, as a preset source: the added spec,
    ;; package source or path; Pi built-ins by their path.  Unattributed
    ;; and undiscovered tools have none.
    (should (equal '(("pkg_a" . "npm:@probe/pkg@1") ("codemode" . "builtin:codemode")
                     ("git_tool" . "git:github.com/o/r") ("local_tool" . "/ext/pkg")
                     ("stray") ("old_pi") ("absent"))
                   (pichat-tool-picker-tool-sources
                    '("pkg_a" "codemode" "git_tool" "local_tool" "stray" "old_pi" "absent")
                    draft)))
    ;; Without ready discovery nothing is known.
    (should (equal '(("pkg_a"))
                   (pichat-tool-picker-tool-sources
                    '("pkg_a") (pichat-tool-discovery-draft-create :status 'failed))))
    (should (equal '(("pkg_a")) (pichat-tool-picker-tool-sources '("pkg_a") nil)))))

(ert-deftest pichat-extension-tools-picker-labels-sources-and-pages-groups ()
  ;; Path-loaded sources group by package directory (or file) and are
  ;; labelled by file name, or by directory name for index files.
  (dolist (case `(("local" "/ext/pkg/index.ts" "/ext/pkg" "/ext/pkg" "pkg")
                  ("auto" "/ext/auto-tool.ts" nil "/ext/auto-tool.ts" "auto-tool")
                  ("cli" "/ext/dir/index.js" nil "/ext/dir/index.js" "dir")
                  ("sdk" "/ext/sdk-tool.ts" nil "/ext/sdk-tool.ts" "sdk-tool")
                  ("npm:@scope/name" "/c/index.ts" "/c" "npm:@scope/name" "name")
                  ("npm:plain@1.0.0" "/c/index.ts" "/c" "npm:plain@1.0.0" "plain")
                  ("git:https://github.com/owner/repo.git" "/g/index.ts" "/g"
                   "git:https://github.com/owner/repo.git" "repo")
                  ("builtin" "builtin:codemode" nil :builtin "Pi built-in")))
    (pcase-let* ((`(,source ,path ,base-dir ,key ,label) case)
                 (tool (list :name "t" :source (pichat-test-extension-tools-source source path base-dir))))
      (should (equal key (pichat-tool-picker--extension-group-key tool)))
      (should (equal label (pichat-tool-picker--extension-group-label key)))))
  (should (eq :unattributed (pichat-tool-picker--extension-group-key '(:name "t"))))
  ;; More groups than one page: the main page pages groups, not tools.
  (let ((pichat-tool-picker--state
         (pichat-test-extension-tools-grouped-state
          (cl-loop for index from 1 to 20
                   collect (list :name (format "extra_%02d" index) :eligible t :description ""
                                 :source (pichat-test-extension-tools-source
                                          "cli" (format "/ext/extra-%02d.ts" index)))))))
    (should (= 25 (length (pichat-tool-picker--extension-groups))))
    (should-not (string-match-p "Pi built-in" (pichat-test-extension-tools-render 'pichat-tool-picker)))
    (cl-letf (((symbol-function 'transient-setup) #'ignore))
      (pichat-tool-picker--page 1 'pichat-tool-picker))
    (should (= 1 (plist-get pichat-tool-picker--state :page)))
    (let ((text (pichat-test-extension-tools-render 'pichat-tool-picker)))
      (should (string-match-p "e1 extra-18 (0/1) →" text))
      (should (string-match-p "e5 Pi built-in (0/2) →" text)))))

(ert-deftest pichat-extension-tools-picker-attributes-added-extension-tools-by-resolved-path ()
  (let* ((dir (make-temp-file "pichat-added-" t))
         (cwd (file-name-as-directory dir))
         (agent "/home/u/.pi/agent/tmp/extensions/")
         (cli (lambda (name path)
                (list :name name :eligible t :description ""
                      :source (list :path path :source "cli" :scope "temporary"
                                    :origin "top-level"))))
         (specs '("./guard.ts" "pkg-link/" "npm:@pi-vault/pi-guardrails@1.2.3"
                  "git:github.com/kirang89/pi-sentry@v0.1.0"
                  "https://gitlab.com/owner/tool.git"))
         (tools nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "pkg/extensions" dir) t)
          (write-region "" nil (expand-file-name "guard.ts" dir))
          (make-symbolic-link (expand-file-name "pkg" dir) (expand-file-name "pkg-link" dir))
          (setq tools
                (list (funcall cli "guard_check" (expand-file-name "guard.ts" dir))
                      (funcall cli "pkg_tool" (expand-file-name "pkg/extensions/index.ts" dir))
                      (funcall cli "guardrails_status"
                               (concat agent "npm/f35b2129/node_modules/@pi-vault/pi-guardrails/"
                                       "extensions/index.ts"))
                      (funcall cli "sentry_scan"
                               (concat agent "git-github.com/cf56c0b2/kirang89/pi-sentry/index.ts"))
                      (funcall cli "tool_run"
                               (concat agent "git-gitlab.com/0123abcd/owner/tool/ext.ts"))
                      ;; Loaded with -e but not an added extension (Pi arguments).
                      (funcall cli "other_npm"
                               (concat agent "npm/f35b2129/node_modules/other/index.ts"))
                      (funcall cli "probe_child" "/ext/probe.ts")))
          ;; Added specs, as given, become the group keys.
          (let ((pichat-tool-picker--state
                 (list :preset (pichat-presets-resolve 'manual) :baseline '("read")
                       :draft '(:builtins ("read") :mcp nil :extensions ("guard_check") :emacs nil)
                       :servers nil :loaded t :page 0
                       :discovery (pichat-tool-discovery-draft-create
                                   :status 'ready :tools tools
                                   :context (list :transport pichat-transport-local :cwd cwd
                                                  :extensions specs)))))
            (should (equal '(("./guard.ts" "guard" "guard_check")
                             ("pkg-link/" "pkg-link" "pkg_tool")
                             ("npm:@pi-vault/pi-guardrails@1.2.3" "pi-guardrails" "guardrails_status")
                             ("git:github.com/kirang89/pi-sentry@v0.1.0" "pi-sentry" "sentry_scan")
                             ("https://gitlab.com/owner/tool.git" "tool" "tool_run")
                             ("/ext/probe.ts" "probe" "probe_child")
                             (:unattributed "Unattributed" "other_npm"))
                           (mapcar (lambda (group)
                                     (append (list (car group) (cadr group))
                                             (mapcar (lambda (tool) (plist-get tool :name))
                                                     (cddr group))))
                                   (pichat-tool-picker--extension-groups))))
            (let ((text (pichat-test-extension-tools-render 'pichat-tool-picker)))
              (should (string-match-p "e1 guard (1/1) →" text))
              (should (string-match-p "e3 pi-guardrails (0/1) →" text)))
            (setf (plist-get pichat-tool-picker--state :extension-group) "./guard.ts")
            (should (string-match-p "^guard: 1/1 selected\n.*\\./guard\\.ts"
                                    (pichat-test-extension-tools-render
                                     'pichat-tool-picker-extension-group))))
          ;; Without added extensions: paths group as before, and package
          ;; cache paths, which name no stable extension, are unattributed.
          (should (equal (expand-file-name "guard.ts" dir)
                         (pichat-tool-picker--extension-group-key (car tools))))
          (should (eq :unattributed (pichat-tool-picker--extension-group-key (nth 2 tools))))
          (should-not (pichat-tool-picker-added-attribution (list :cwd cwd))))
      (delete-directory dir t)))
  ;; The most specific path spec wins; other git spec forms.
  (let ((attribution (pichat-tool-picker-added-attribution
                      (list :cwd "/w/" :extensions '("/w/ext/" "/w/ext/a.ts" "git:git@github.com:o/r"
                                                     "github:o2/r2#main" "npm:plain")))))
    (should (equal "/w/ext/a.ts" (pichat-tool-picker--added-extension "/w/ext/a.ts" attribution)))
    (should (equal "/w/ext/" (pichat-tool-picker--added-extension "/w/ext/b.ts" attribution)))
    (should-not (pichat-tool-picker--added-extension "/w/extra/b.ts" attribution))
    (should (equal "git:git@github.com:o/r"
                   (pichat-tool-picker--added-extension
                    "/a/tmp/extensions/git-github.com/00000000/o/r/x.ts" attribution)))
    (should (equal "github:o2/r2#main"
                   (pichat-tool-picker--added-extension
                    "/a/tmp/extensions/git-github.com/11111111/o2/r2/x.ts" attribution)))
    (should (equal "npm:plain"
                   (pichat-tool-picker--added-extension
                    "/a/tmp/extensions/npm/abcdef01/node_modules/plain/x.ts" attribution)))
    (should-not (pichat-tool-picker--added-extension
                 "/a/tmp/extensions/npm/abcdef01/node_modules/plainer/x.ts" attribution)))
  ;; Package specs are labelled by package or repository name.
  (dolist (case '(("npm:@probe/fixture-pkg@file:/tmp/p/fixture-pkg-1.2.3.tgz" . "fixture-pkg")
                  ("git:git@github.com:o/r@v1" . "r")
                  ("github:o2/r2#main" . "r2")
                  ("ssh://git@example.com:22/team/tool.git" . "tool")))
    (should (equal (cdr case) (pichat-tool-picker--extension-group-label (car case)))))
  ;; Over SSH, paths are the target's: no symbolic links, never `~'.
  (let ((attribution (pichat-tool-picker-added-attribution
                      (list :cwd "/srv/" :extensions '("ext/x.ts" "~/y.ts")
                            :transport (pichat-transport--create :id 'remote :kind 'ssh)))))
    (should (equal "ext/x.ts" (pichat-tool-picker--added-extension "/srv/ext/x.ts" attribution)))
    (should-not (pichat-tool-picker--added-extension "/home/u/y.ts" attribution))
    (should (equal "/home/u/y.ts"
                   (pichat-tool-picker--extension-group-key
                    '(:name "y" :source (:path "/home/u/y.ts" :source "cli")) attribution)))))

(ert-deftest pichat-extension-tools-picker-fails-closed-on-stale-or-hidden-selection ()
  (let ((pichat-tool-picker--state
         (list :preset (pichat-presets-resolve 'manual) :baseline '("read")
               :draft '(:builtins ("read") :extensions ("missing"))
               :discovery (pichat-tool-discovery-draft-create :status 'ready :tools nil))))
    (should-error (pichat-tool-picker-apply) :type 'user-error)
    (setf (pichat-tool-discovery-draft-status (plist-get pichat-tool-picker--state :discovery)) 'failed)
    (should-error (pichat-tool-picker-apply) :type 'user-error)))

(ert-deftest pichat-extension-tools-picker-reuses-draft-and-invalidates-model-and-prompt-context ()
  (let ((pichat-rpc-command nil) (pichat-pi-extra-args nil)
        (pichat-pi-default-args '("--mode" "rpc")) (pichat-default-model nil)
        (pichat-bridge-extension-file nil) (pichat-tool-picker--state nil)
        (cache (pichat-tool-discovery-draft-create))
        (spec '(:name test :tools ("read") :append-system-prompt "Captured instructions\n"))
        (calls 0) captured)
    (cl-letf (((symbol-function 'transient-setup) #'ignore)
              ((symbol-function 'pichat-tool-picker--refresh-display) #'ignore)
              ((symbol-function 'pichat-tool-picker--refresh-children) #'ignore)
              ((symbol-function 'pichat-mcp-discovery-start)
               (lambda (_transport _cwd _exe callback) (funcall callback nil nil) #'ignore))
              ((symbol-function 'pichat-tool-discovery-start)
               (lambda (_transport _cwd _exe callback &rest options)
                 (cl-incf calls) (setq captured (plist-get options :args))
                 (funcall callback '((:name "child" :description "Child" :eligible t)) nil) #'ignore)))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/a" cache)
      (should (= calls 1))
      (should (member "provider/a" captured))
      (should (member "Captured instructions\n" captured))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/a" cache)
      (should (= calls 1))
      (pichat-tool-picker-refresh)
      (should (= calls 2))
      (pichat-tool-picker-open spec nil default-directory pichat-transport-local "pi" #'ignore "provider/b" cache)
      (should (= calls 3))
      (should (member "provider/b" captured))
      (pichat-tool-picker--abandoned)
      (should-not pichat-tool-picker--state))))

(defun pichat-test-extension-tools-active (session)
  "Query the fixture's real observed active names in SESSION, without a model."
  (let ((count (pichat-test-count-raw-events session "extension_ui_request")))
    (pichat-test-rpc-call session "prompt" '(:message "/probe-report"))
    (let ((event (pichat-test-wait-for-raw-event session "extension_ui_request" nil count)))
      (should (string-prefix-p "probe-active:" (plist-get event :message)))
      (json-parse-string (substring (plist-get event :message) (length "probe-active:")) :array-type 'list))))

(when pichat-test-include-integration
  (ert-deftest pichat-extension-tools-real-launch-enables-before-readiness-without-model-turns ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child" "probe_session"))
                 :extensions (list pichat-test-extension-tools-fixture pichat-test-bridge-extension) :script '(:turns []))
      (should (plist-get (pichat-session-rpc-startup-control session) :verified))
      (should (member "--extension" (pichat-session-rpc-command session)))
      (let ((active (pichat-test-extension-tools-active session)))
        (should (member "probe_child" active))
        (should (member "probe_session" active))
        (should-not (member "probe_loader" active)))
      (should-not (cl-find-if (lambda (event) (equal (plist-get event :title) pichat-tool-discovery--title))
                              (pichat-session-event-log session)))
      (let ((entries (plist-get (pichat-test-rpc-call session "get_entries") :data)))
        (should (pichat-pi-startup-metadata-only-p (plist-get entries :entries) (plist-get entries :leafId))))
      (pichat-test-rpc-call session "prompt" '(:message "/probe-deactivate"))
      (pichat-test-rpc-call session "get_state")
      (should-not (member "probe_child" (pichat-test-extension-tools-active session)))))

  (ert-deftest pichat-extension-tools-real-probe-supports-bridge-startup-without-executing-tools ()
    (pichat-test-with-integration-session
        (session :preset 'manual :script '(:turns []))
      (let (result)
        (pichat-tool-discovery-start
         pichat-transport-local project-dir pichat-test-pi-executable
         (lambda (tools error) (setq result (list tools error)))
         :args (list "--offline" "--no-approve" "--no-context-files" "--no-skills"
                     "--no-prompt-templates" "--no-themes" "--no-extensions" "--no-mcp"
                     "-e" pichat-test-fake-provider-extension "-e" pichat-test-bridge-extension
                     "-e" pichat-test-extension-tools-fixture "--model" "pichat-fake/pichat-fake"))
        (pichat-test-wait-until (lambda () result) 10 "probe with optional Emacs bridge")
        (should-not (cadr result))
        (should (cl-find "probe_child" (car result) :key (lambda (tool) (plist-get tool :name)) :test #'equal)))))

  (ert-deftest pichat-extension-tools-real-launch-rejects-missing-hidden-and-absent-helper ()
    (pichat-test-with-integration-session
        (session :preset 'manual :extensions (list pichat-test-extension-tools-fixture) :script '(:turns []))
      (dolist (choice '("missing" "probe_hidden" "helper-absent"))
        (let* ((pichat-tool-discovery-helper
                (if (equal choice "helper-absent") pichat-test-fake-provider-extension pichat-tool-discovery-helper))
               (failed (pichat-start-session
                        project-dir nil (list :preset 'manual :tools
                                              (list :builtins '("read") :extensions
                                                    (list (if (equal choice "helper-absent") "probe_child" choice))))))
               response)
          (unwind-protect
              (progn
                (pichat-rpc-get-state failed (lambda (value _s) (setq response value))
                                      (lambda (value _s) (setq response value)))
                (pichat-test-wait-until (lambda () response) 10 "failed selected tool startup")
                (should-not (plist-get response :success))
                (should-not (pichat-session-alive-p failed))
                (should-not (pichat-session-rpc-startup-control failed)))
            (pichat-rpc-stop failed)
            (pichat-forget-session failed))))))

  (ert-deftest pichat-extension-tools-real-saved-restart-and-independent-open-verify-after-reload ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child"))
                 :extensions (list pichat-test-extension-tools-fixture)
                 :script '(:turns [(:text "Saved source before extension restart")]))
      (let ((pichat-chat-stop-session-on-kill nil) buffer opened result)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session t))
              (pichat-test-chat-send-and-wait session buffer "Create a saved source")
              (pichat-test-assert-provider-script-consumed status-file)
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache session)) 5 "saved source cache")
              ;; Subsequent processes must not request any model turn.  The
              ;; initial explicit fake-model turn exists only to persist Pi's file.
              (with-temp-file script-file (insert "{\"turns\":[]}"))
              (let ((id (pichat-session-id session)) (file (pichat-session-session-file session)))
                (pichat-reconfigure-restart
                 (pichat-reconfigure-capture-origin session)
                 (pichat-reconfigure-select-tools
                  (pichat-reconfigure-captured-configuration session)
                  '(:builtins ("read") :extensions ("probe_child" "probe_session")))
                 (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "saved source extension restart")
                (should (car result))
                (should (equal id (pichat-session-id session)))
                (should (member "probe_child" (pichat-test-extension-tools-active session)))
                (should (member "probe_session" (pichat-test-extension-tools-active session)))
                (pichat-rpc-stop session)
                (setq result nil)
                (setq opened
                      (pichat-sessions-open-file-independently
                       file :cwd project-dir :owner-directory project-dir :source-session session
                       :readiness 'transcript-ready :expected-session-id id
                       :launch-options '(:preset manual :tools (:builtins ("read") :extensions ("probe_child")))
                       :ready (lambda (_session) (setq result '(t)))
                       :error-callback (lambda (response _session) (setq result (list nil response)))))
                (pichat-test-wait-until (lambda () result) 15 "independent saved-source extension verification")
                (should (car result))
                (should (equal id (pichat-session-id opened)))
                (should (member "probe_child" (pichat-test-extension-tools-active opened)))))
          (when (pichat-session-p opened)
            (when-let* ((chat (pichat-session-buffer opened))) (when (buffer-live-p chat) (kill-buffer chat)))
            (pichat-rpc-stop opened) (pichat-forget-session opened))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))

  (ert-deftest pichat-extension-tools-real-restart-keeps-snapshots-and-restores-after-failure ()
    (pichat-test-with-integration-session
        (session :preset 'manual :selection '(:builtins ("read") :extensions ("probe_child"))
                 :extensions (list pichat-test-extension-tools-fixture) :script '(:turns []))
      (let ((pichat-chat-stop-session-on-kill nil) buffer result)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session t))
              (pichat-test-wait-until (lambda () (pichat-chat-canonical-entry-cache session)) 5 "initial empty cache")
              (let* ((before (pichat-reconfigure-captured-configuration session))
                     (requested (pichat-reconfigure-select-tools
                                 before '(:builtins ("read") :extensions ("missing"))))
                     (runtime-id (pichat-session-runtime-id session)))
                (pichat-reconfigure-restart (pichat-reconfigure-capture-origin session) requested
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "missing-tool replacement failure")
                (should-not (car result))
                (should-not (pichat-session-alive-p session))
                (should (equal before (pichat-reconfigure-captured-configuration session)))
                (should (equal '("missing")
                               (plist-get (plist-get (plist-get (pichat-session-restart-operation session) :requested)
                                                     :tool-selection) :extensions)))
                (setq result nil)
                (pichat-reconfigure-recover session 'retry
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "retry preserves requested extension snapshot")
                (should-not (car result))
                (setq result nil)
                (pichat-reconfigure-recover session 'restore
                                            (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "restore previous extension selection")
                (should (car result))
                (should (equal runtime-id (pichat-session-runtime-id session)))
                (should (equal before (pichat-reconfigure-captured-configuration session)))
                (should (member "probe_child" (pichat-test-extension-tools-active session)))
                (setq result nil)
                (pichat-reconfigure-restart
                 (pichat-reconfigure-capture-origin session)
                 (pichat-reconfigure-select-tools before '(:builtins ("read") :extensions ("probe_session")))
                 (lambda (success reason) (setq result (list success reason))))
                (pichat-test-wait-until (lambda () result) 15 "successful changed extension selection")
                (should (car result))
                (should (equal '("probe_session") (plist-get (pichat-session-tool-selection session) :extensions)))
                (should-not (member "probe_child" (pichat-test-extension-tools-active session)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-job-skill-only-actual-structured-start-adds-resource ()
  (pichat-test-with-clean-state
    (let ((pichat-pi-default-args '("--mode" "rpc"))
          (pichat-pi-extra-args '("--skill" "/example/user/SKILL.md"))
          (pichat-rpc-command nil) (pichat-bridge-extension-file nil)
          (pichat-pi-session-dir nil) (pichat-default-model nil))
      (dolist (case '(structured long-disabled short-disabled wrapper captured))
        (let* ((pichat-pi-default-args
                (append pichat-pi-default-args
                        (pcase case ('long-disabled '("--no-skills")) ('short-disabled '("-ns")))))
               (pichat-rpc-command (when (memq case '(wrapper captured)) '("wrapper" "pi")))
               (session (pichat-session-make :transport pichat-transport-local)) command)
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (_transport _cwd &rest options)
                       (setq command (plist-get options :command))
                       (error "Injected no-spawn boundary"))))
            (let ((base (if (eq case 'captured) '("pi" "--mode" "rpc")
                          (pichat-rpc-build-command session))))
              (should-not (member pichat-rpc-job-authoring-skill base))
              (pichat-rpc-start session (when (eq case 'captured) base))
              (should (equal (not (null (member pichat-rpc-job-authoring-skill command)))
                             (not (null (memq case '(structured captured))))))
              (when (memq case '(structured long-disabled short-disabled))
                (should (member "/example/user/SKILL.md" command)))
              (when (eq case 'wrapper) (should (equal command '("wrapper" "pi")))))))))))

(ert-deftest pichat-job-skill-ssh-failed-spawn-retains-verified-assets ()
  (pichat-test-startup-cache--with-fixture
    (let (asset-paths)
      (let ((pichat-rpc-job-authoring-skill skill))
        (pichat-test-with-unit-session (session)
          (let ((pichat-rpc-command nil) (pichat-pi-default-args '("--mode" "rpc"))
                (pichat-pi-extra-args nil) (pichat-pi-session-dir nil)
                (pichat-default-model nil)
                (operation (list :phase 'starting :shutdown-obligations nil))
                (generation (pichat-session-process-generation session))
                stdout stderr outcomes)
            (setf (pichat-session-transport session) transport
                  (pichat-session-restart-operation session) operation)
            (dolist (event '(session-started error session-ended))
              (pichat-on event (lambda (_session kind _) (push kind outcomes)) session))
            (cl-letf (((symbol-function 'pichat-transport-make-process)
                       (lambda (target _cwd &rest options)
                         (should (eq target transport))
                         (setq stdout (plist-get options :buffer)
                               stderr (plist-get options :stderr))
                         (should (buffer-live-p stdout))
                         (should (buffer-live-p stderr))
                         (let ((command (plist-get options :command)))
                           (setq asset-paths (list (cadr (member "--extension" command))
                                                   (cadr (member "--skill" command))))
                           (should-not (member pichat-rpc-job-authoring-skill command))
                           (should (cl-every #'file-readable-p asset-paths)))
                         (signal 'file-error '("Injected SSH acquisition failure")))))
              (pichat-rpc-start session))
            (should (equal outcomes '(session-ended error)))
            (should (eq (pichat-session-state session) 'error))
            (let ((diagnostic (pichat-chat-diagnostics-latest session)))
              (should (eq 'process-start (plist-get diagnostic :origin)))
              (should (string-match-p "Injected SSH acquisition failure"
                                      (plist-get diagnostic :message))))
            (should (eql generation (pichat-session-process-generation session)))
            (should-not (plist-get operation :shutdown-obligations))
            (should-not (pichat-session-process session))
            (should-not (pichat-session-stderr-buffer session))
            (should-not (pichat-session-rpc-ready-timer session))
            (should-not (pichat-session-rpc-startup-control session))
            (should (and (bufferp stdout) (not (buffer-live-p stdout))))
            (should (and (bufferp stderr) (not (buffer-live-p stderr))))
            (should (cl-every #'file-readable-p asset-paths))
            (should-not (pichat-test-startup-cache--staging root))))))))

(when pichat-test-include-integration
  (ert-deftest pichat-job-skill-real-local-discovery-preserves-user-skills-and-disabling ()
    (pichat-test-with-integration-session (session :preset 'standard :script '(:turns []))
      (let* ((home (expand-file-name "private-home/" agent-dir))
             (user-skill (expand-file-name "user-skill/SKILL.md" project-dir))
             (process-environment (cons (concat "HOME=" home) process-environment)))
        (make-directory home t)
        (make-directory (file-name-directory user-skill) t)
        (with-temp-file user-skill
          (insert "---\nname: fixture-user\ndescription: An explicitly selected user skill.\n---\nFixture only.\n"))
        (dolist (disable '(nil "--no-skills" "-ns"))
          (let* ((pichat-pi-default-args
                  (append (remove "--no-skills" pichat-pi-default-args)
                          (when disable (list disable)) (list "--skill" user-skill)))
                 (runtime (pichat-start-session project-dir nil '(:preset standard))))
            (unwind-protect
                (let* ((_state (pichat-test-rpc-call runtime "get_state"))
                       (commands (plist-get (plist-get (pichat-test-rpc-call runtime "get_commands") :data) :commands)))
                  (should (seq-find (lambda (item) (equal (plist-get item :name) "skill:fixture-user")) commands))
                  (should (equal (not (null (seq-find (lambda (item) (equal (plist-get item :name) "skill:pichat-jobs")) commands)))
                                 (null disable))))
              (pichat-rpc-stop runtime)
              (pichat-forget-session runtime))))
        (should-not (file-exists-p (expand-file-name "skills/" agent-dir)))
        (should-not (file-exists-p (expand-file-name ".pi/skills/" project-dir)))))))

(provide 'pichat-test-extension-tools)
;;; pichat-test-extension-tools.el ends here
