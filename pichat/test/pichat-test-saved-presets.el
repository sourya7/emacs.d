;;; pichat-test-saved-presets.el --- Named presets with MCP, model and saving -*- lexical-binding: t; -*-

;;; Commentary:
;; Preset MCP baselines and model policies, Custom-backed saving from the
;; launcher, and their effect on Tools, launch, reconfiguration and jobs.
;; Every Custom write goes to a temporary `custom-file'.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-tool-picker)
(require 'pichat-job-launch)
(require 'pichat-jobs)

(defconst pichat-test-saved-presets--custom-properties
  '(saved-value theme-value customized-value variable-comment
    saved-variable-comment customized-variable-comment)
  "Custom symbol properties restored after each saving test.")

(defmacro pichat-test-with-presets (&rest body)
  "Run BODY with isolated programmatic and saved preset registries."
  (declare (indent 0) (debug t))
  `(let ((pichat-presets (copy-tree pichat-presets))
         (pichat-saved-presets nil))
     ,@body))

(defmacro pichat-test-with-custom-file (file &rest body)
  "Run BODY with FILE bound to an isolated temporary `custom-file'.
The saved preset collection, its Custom properties and FILE are restored."
  (declare (indent 1) (debug (symbolp body)))
  `(pichat-test-with-temp-dir custom-dir
     (let* ((,file (expand-file-name "custom.el" custom-dir))
            (custom-file ,file)
            (user-init-file (expand-file-name "init.el" custom-dir))
            (saved-properties
             (mapcar (lambda (property)
                       (cons property (get 'pichat-saved-presets property)))
                     pichat-test-saved-presets--custom-properties))
            (saved-value (default-value 'pichat-saved-presets)))
       (unwind-protect
           (pichat-test-with-presets ,@body)
         (set-default 'pichat-saved-presets saved-value)
         (dolist (property saved-properties)
           (put 'pichat-saved-presets (car property) (cdr property)))
         (when-let* ((buffer (find-buffer-visiting ,file)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer))))))

(defun pichat-test-saved-presets--file-string (file)
  "Return FILE's contents."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun pichat-test-saved-presets--server (&rest tools)
  "Return a connected probe server catalogue offering eligible TOOLS."
  (list (list :name "probe" :state "connected"
              :tools (mapcar (lambda (name)
                               (list :name name :exposure "direct" :eligible t))
                             tools))))

;;; Schema and resolution

(ert-deftest pichat-saved-presets-mcp-baseline-and-model-resolve-into-snapshot ()
  (pichat-test-with-presets
    (let ((pairs (list (cons "ketch" "search")))
          (tools (list "read" "grep")))
      (pichat-make-preset 'web
        :tools tools :mcp pairs :model "provider/model")
      ;; Registration copies its input.
      (setcdr (car pairs) "crawl")
      (setcar tools "write")
      (let* ((snapshot (pichat-presets-resolve 'web))
             (selection (pichat-tool-selection-resolve snapshot)))
        (should (equal '(("ketch" . "search")) (plist-get snapshot :mcp)))
        (should (equal "provider/model" (plist-get snapshot :model)))
        (should (equal '("read" "grep") (plist-get selection :builtins)))
        (should (equal '(("ketch" . "search")) (plist-get selection :mcp)))
        (should (equal '("--tools" "read,grep,mcp__ketch__search")
                       (pichat-tool-selection-args selection)))
        ;; An explicit empty override stays empty rather than restoring it.
        (should (equal '("--tools" "read" "--no-mcp")
                       (pichat-tool-selection-args
                        (pichat-tool-selection-resolve
                         snapshot '(:builtins ("read") :mcp nil)))))
        ;; Snapshots are detached from later registry edits.
        (pichat-make-preset 'web :tools '("read"))
        (should (equal '(("ketch" . "search")) (plist-get snapshot :mcp)))))))

(ert-deftest pichat-saved-presets-old-definitions-keep-their-snapshots ()
  (dolist (name '(manual coding review standard))
    (let ((snapshot (pichat-presets-resolve name)))
      (should-not (plist-member snapshot :mcp))
      (should-not (plist-member snapshot :model))))
  (should-not (member "bash" (plist-get (pichat-presets-resolve 'manual) :tools)))
  (should (member "--no-mcp" (pichat-tool-selection-args
                              (pichat-tool-selection-resolve
                               (pichat-presets-resolve 'manual))))))

(ert-deftest pichat-saved-presets-validation-rejects-unsafe-mcp-and-models ()
  (pichat-test-with-presets
    (dolist (spec '((:mcp (("ketch" . "search")))
                    (:tools :default :mcp (("ketch" . "search")))
                    (:tools ("read") :mcp (("bad server" . "search")))
                    (:tools ("read") :mcp (("ketch" . "")))
                    (:tools ("read") :mcp ("ketch"))
                    (:tools ("read") :mcp (("ketch" . "a") ("ketch" . "a")))
                    (:tools ("read") :mcp (("x" . "a-b") ("x" . "a_b")))
                    (:tools ("read") :mcp (("x" . "y"))
                     :extensions ("mcp__x__y"))
                    (:tools ("read") :model "no-provider")
                    (:tools ("read") :model "provider/model:high")
                    (:tools ("read") :model "provider/model name")
                    (:tools ("read") :model prompt)))
      (should-error (apply #'pichat-make-preset 'invalid spec) :type 'user-error))
    (pichat-make-preset 'ok :tools '("read") :model 'default)
    (should (eq 'default (pichat-presets-model 'ok)))
    (should-not (plist-member (pichat-presets-resolve 'ok) :model))
    (pichat-make-preset 'family :tools '("read") :model "provider/family/model")
    (should (equal "provider/family/model" (pichat-presets-model 'family)))))

(ert-deftest pichat-saved-presets-named-preset-model-applies-to-launch-profile ()
  (pichat-test-with-presets
    (pichat-make-preset 'pinned :tools '("read") :model "provider/model")
    (let ((profile (pichat--normalize-launch-profile '(:preset pinned))))
      (should (equal "provider/model" (plist-get profile :model)))
      (should (eq 'new (plist-get profile :reuse))))
    ;; A run-local choice overrides the preset, including Pi's default.
    (should (equal "other/model"
                   (plist-get (pichat--normalize-launch-profile
                               '(:preset pinned :model "other/model"))
                              :model)))
    (should (eq 'default (plist-get (pichat--normalize-launch-profile
                                     '(:preset pinned :model default))
                                    :model)))
    ;; The default choice keeps Pi's model so it can reuse the preferred runtime.
    (let ((pichat-default-preset 'pinned))
      (let ((profile (pichat--normalize-launch-profile '(:preset default))))
        (should (eq 'default (plist-get profile :model)))
        (should (eq 'preferred (plist-get profile :reuse)))))))

;;; Saved definitions: registry and persistence

(ert-deftest pichat-saved-presets-take-precedence-deterministically ()
  (pichat-test-with-presets
    (setq pichat-saved-presets
          '((review :description "Saved review" :tools ("read"))
            (web :tools ("read") :mcp (("ketch" . "search")))))
    (should (equal '(manual coding review standard web) (pichat-presets-names)))
    (should (equal "Saved review" (plist-get (pichat-get-preset 'review) :description)))
    ;; A later programmatic redefinition does not override the saved one.
    (pichat-make-preset 'review :description "Programmatic" :tools '("read" "ls"))
    (should (equal '("read") (plist-get (pichat-presets-resolve 'review) :tools)))
    (should (pichat-presets-saved-p 'web))
    (should-not (pichat-presets-saved-p 'manual))
    (should (equal '("default" "manual" "coding" "review" "standard" "web")
                   (pichat--launch-preset-choices)))))

(ert-deftest pichat-saved-presets-names-are-validated ()
  (should (eq 'web-search (pichat-presets-read-name " web-search ")))
  (should (eq 'review.fast_2 (pichat-presets-read-name "review.fast_2")))
  (dolist (bad '("" "  " "default" "prompt" "-x" "has space" "a/b" ":key"))
    (should-error (pichat-presets-read-name bad) :type 'user-error))
  (should-error (pichat-presets-read-name (make-string 65 ?a)) :type 'user-error))

(ert-deftest pichat-saved-presets-save-preserves-file-and-unsaved-settings ()
  (pichat-test-with-custom-file file
    (defvar pichat-test-saved-presets--other nil)
    (put 'pichat-test-saved-presets--other 'saved-value '(1))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";;; personal header\n(setq ignored 1) ; keep this comment\n"
                    "(custom-set-variables\n '(pichat-test-saved-presets--other 1))\n"))
          ;; Set but unsaved: must not be written as a side effect.
          (put 'pichat-test-saved-presets--other 'customized-value '(2))
          (setq pichat-test-saved-presets--other 2)
          (should (equal file (pichat-presets-save-definition
                               'web '(:tools ("read") :mcp (("ketch" . "search"))))))
          (pichat-presets-save-definition 'fast '(:tools nil :model "p/m"))
          (pichat-presets-save-definition 'web '(:tools ("grep")))
          (should (equal '((web :tools ("grep")) (fast :tools nil :model "p/m"))
                         pichat-saved-presets))
          (should (equal '("grep") (plist-get (pichat-presets-resolve 'web) :tools)))
          (let ((text (pichat-test-saved-presets--file-string file)))
            (should (string-match-p "^;;; personal header$" text))
            (should (string-match-p "(setq ignored 1) ; keep this comment" text))
            (should (string-match-p "(pichat-test-saved-presets--other 1\\b" text))
            (should-not (string-match-p "(pichat-test-saved-presets--other 2" text))
            (should (= 1 (with-temp-buffer
                           (insert text)
                           (how-many "(web " (point-min) (point-max)))))))
      (dolist (property pichat-test-saved-presets--custom-properties)
        (put 'pichat-test-saved-presets--other property nil)))))

(ert-deftest pichat-saved-presets-unsafe-destinations-change-nothing ()
  (pichat-test-with-custom-file file
    (pichat-presets-save-definition 'web '(:tools ("read")))
    (let ((saved (copy-tree pichat-saved-presets))
          (saved-value (copy-tree (get 'pichat-saved-presets 'saved-value)))
          (attempt (lambda ()
                     (should-error (pichat-presets-save-definition
                                    'other '(:tools ("read")))
                                   :type 'user-error))))
      (cl-flet ((unchanged (contents)
                  (should (equal saved pichat-saved-presets))
                  (should (equal saved-value (get 'pichat-saved-presets 'saved-value)))
                  (should (equal contents (pichat-test-saved-presets--file-string file)))))
        ;; Unsaved edits in the visiting buffer are neither saved nor reverted.
        (let ((buffer (find-file-noselect file))
              (contents (pichat-test-saved-presets--file-string file)))
          (with-current-buffer buffer (goto-char (point-max)) (insert ";; draft\n"))
          (funcall attempt)
          (unchanged contents)
          (with-current-buffer buffer
            (should (buffer-modified-p))
            (should (string-suffix-p ";; draft\n" (buffer-string)))
            (set-buffer-modified-p nil))
          (kill-buffer buffer))
        ;; The visited file changed on disk.
        (let ((buffer (find-file-noselect file)))
          (sleep-for 0.01)
          (with-temp-file file
            (insert (pichat-test-saved-presets--file-string file) ";; external\n"))
          (set-file-times file (time-add nil 5))
          (let ((contents (pichat-test-saved-presets--file-string file)))
            (funcall attempt)
            (unchanged contents))
          (kill-buffer buffer))
        ;; Another Emacs saved presets this one has not loaded.
        (with-temp-file file
          (insert "(custom-set-variables\n '(pichat-saved-presets '((theirs :tools nil))))\n"))
        (let ((contents (pichat-test-saved-presets--file-string file)))
          (funcall attempt)
          (unchanged contents))
        ;; Ambiguous or unreadable structure.
        (dolist (contents (list "(custom-set-variables)\n(custom-set-variables)\n"
                                "(custom-set-variables\n '(pichat-saved-presets nil)\n"))
          (with-temp-file file (insert contents))
          (funcall attempt)
          (unchanged contents))))))

(ert-deftest pichat-saved-presets-write-failure-rolls-back-custom-state ()
  (pichat-test-with-custom-file file
    (pichat-presets-save-definition 'web '(:tools ("read")))
    (let ((saved (copy-tree pichat-saved-presets))
          (properties (mapcar (lambda (property)
                                (copy-tree (get 'pichat-saved-presets property)))
                              pichat-test-saved-presets--custom-properties))
          (contents (pichat-test-saved-presets--file-string file)))
      (cl-letf (((symbol-function 'custom-save-all)
                 (lambda () (error "Injected write failure"))))
        (should-error (pichat-presets-save-definition 'other '(:tools nil))))
      (should (equal saved pichat-saved-presets))
      (should-not (pichat-presets-defined-p 'other))
      (should (equal properties
                     (mapcar (lambda (property) (get 'pichat-saved-presets property))
                             pichat-test-saved-presets--custom-properties)))
      (should (equal contents (pichat-test-saved-presets--file-string file))))))

(ert-deftest pichat-saved-presets-require-a-real-custom-file ()
  (pichat-test-with-custom-file file
    (let ((custom-file nil))
      (should-error (pichat-presets-save-definition 'web '(:tools nil))
                    :type 'user-error))
    (let ((user-init-file nil))
      (should-error (pichat-presets-save-definition 'web '(:tools nil))
                    :type 'user-error))
    (should-error (pichat-presets-save-definition 'default '(:tools nil))
                  :type 'user-error)
    (should-error (pichat-presets-save-definition 'web '(:tools ("unknown"))))
    (should-not (file-exists-p file))
    (should-not pichat-saved-presets)))

(ert-deftest pichat-saved-presets-reload-in-fresh-emacs-regardless-of-load-order ()
  (pichat-test-with-custom-file file
    (pichat-presets-save-definition
     'web '(:tools ("read") :mcp (("ketch" . "search")) :model "provider/model"))
    (pichat-presets-save-definition 'fast '(:tools nil :model default))
    (let ((directory (file-name-directory (locate-library "pichat-presets"))))
      (dolist (order '(before after))
        (with-temp-buffer
          (let ((status
                 (call-process
                  (expand-file-name invocation-name invocation-directory) nil t nil
                  "-Q" "--batch" "-L" directory
                  "--eval"
                  (format "(progn %s (require 'pichat-presets) %s (prin1 (list (pichat-presets-names) (pichat-presets-resolve 'web) (pichat-presets-model 'fast))))"
                          (if (eq order 'before) (format "(load %S nil t)" file) "")
                          (if (eq order 'after) (format "(load %S nil t)" file) "")))))
            (should (eql 0 status))
            (goto-char (point-max))
            (backward-sexp)
            (pcase-let ((`(,names ,web ,fast) (read (current-buffer))))
              (should (equal '(manual coding review standard web fast) names))
              (should (equal '(("ketch" . "search")) (plist-get web :mcp)))
              (should (equal "provider/model" (plist-get web :model)))
              (should (eq 'default fast)))))))))

;;; Launcher model staging and Save preset as

(defmacro pichat-test-with-launcher (scope args &rest body)
  "Run BODY as a launcher suffix with transient SCOPE and ARGS.
Reopening the launcher records its (ARGS . SCOPE) in `staged'."
  (declare (indent 2) (debug t))
  `(let ((staged nil))
     (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) ,scope))
               ((symbol-function 'transient-args) (lambda (&rest _) ,args))
               ((symbol-function 'transient-setup)
                (lambda (_prefix _layout _edit &rest keys)
                  (let ((next (plist-get keys :scope)))
                    (push (cons (plist-get next :launch-args) next) staged))))
               ((symbol-function 'pichat-start-session)
                (lambda (&rest _) (ert-fail "Launcher action started a runtime")))
               ((symbol-function 'pichat--open-launch-profile)
                (lambda (&rest _) (ert-fail "Launcher action launched"))))
       ,@body)))

(ert-deftest pichat-saved-presets-launcher-stages-model-over-preset ()
  (pichat-test-with-presets
    (pichat-make-preset 'pinned :tools '("read") :model "provider/model")
    (let ((context (list :directory "/tmp/")))
      (should (equal "provider/model"
                     (plist-get (pichat--launch-profile-from-arguments
                                 '("--preset=pinned") context)
                                :model)))
      (dolist (case '(("Pi default model" default)
                      ("Choose when launching" prompt)
                      ("Preset model (provider/model)" nil)))
        (pichat-test-with-launcher context '("--preset=pinned")
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt choices &rest _)
                       (should (member "Preset model (provider/model)" choices))
                       (car case))))
            (pichat-launch-model))
          (should (equal '("--preset=pinned") (caar staged)))
          (should (eq (cadr case) (plist-get (cdar staged) :model)))
          ;; The suffix never mutates the draft it was invoked from.
          (should-not (plist-get context :model))))
      (let ((profile (pichat--launch-profile-from-arguments
                      nil (list :model "other/model"))))
        (should (equal "other/model" (plist-get profile :model)))
        (should (eq 'new (plist-get profile :reuse)))
        (should (string-match-p "model other/model"
                                (pichat--launch-profile-description profile)))))))

(ert-deftest pichat-saved-presets-selecting-a-preset-restores-its-model ()
  (let* ((scope (list :model "other/model" :tool-selection '(:builtins nil :mcp nil)))
         (transient--prefix (transient--init-prefix 'pichat-launch (list :scope scope))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "review"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (pichat--launch-read-preset "Preset: " "manual" nil))
    (should-not (plist-get scope :model))
    (should-not (plist-get scope :tool-selection))))

(ert-deftest pichat-saved-presets-model-listing-ignores-stale-callbacks ()
  (let ((context (list :directory "/tmp/"))
        (pichat-rpc-command nil)
        callbacks)
    (cl-letf (((symbol-function 'pichat--list-models-async)
               (lambda (_search callback &rest _) (push callback callbacks)))
              ((symbol-function 'run-at-time)
               (lambda (_time _repeat function &rest args) (apply function args))))
      (pichat-test-with-launcher context nil
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (if (equal prompt "Model: ") "Select or enter model…"
                       "fixture/chosen"))))
          (pichat-launch-model)
          (pichat-launch-model)
          (should (= 2 (length callbacks)))
          ;; The older listing was superseded.
          (funcall (cadr callbacks) '(("fixture" . "chosen")))
          (should-not staged)
          (funcall (car callbacks) '(("fixture" . "chosen")))
          (should (equal "fixture/chosen" (plist-get (cdar staged) :model)))
          ;; Each listing is used at most once.
          (funcall (car callbacks) '(("fixture" . "chosen")))
          (should (= 1 (length staged)))))
      ;; Cancelling the model prompt returns to the unchanged draft.
      (pichat-test-with-launcher context nil
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (if (equal prompt "Model: ") "Select or enter model…"
                       (signal 'quit nil)))))
          (pichat-launch-model)
          (funcall (car callbacks) '(("fixture" . "chosen")))
          (should staged)
          (should-not (plist-get (cdar staged) :model))))
      ;; Opening another launcher also supersedes a pending listing.
      (pichat-test-with-launcher context nil
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _)
                     (if (equal prompt "Model: ") "Select or enter model…"
                       "fixture/chosen"))))
          (pichat-launch-model)
          (pichat-launch context)
          (setq staged nil)
          (funcall (car callbacks) '(("fixture" . "chosen")))
          (should-not staged))))))

(ert-deftest pichat-saved-presets-definition-captures-effective-configuration ()
  (pichat-test-with-presets
    (pichat-test-with-temp-dir dir
      (let ((prompt-file (expand-file-name "prompt.md" dir))
            (pichat-append-system-prompt "Shared text"))
        (with-temp-file prompt-file (insert "From file"))
        (pichat-make-preset 'source
          :description "Source"
          :tools '("read" "grep" "bash")
          :extensions '("ext_tool")
          :system-prompt "Replace"
          :append-system-prompt (list "Inline" (list :file prompt-file)))
        (let* ((context (list :tool-selection
                              '(:builtins ("read") :extensions ("ext_tool")
                                :mcp (("ketch" . "search")))
                              :model "provider/model"))
               (profile (pichat--launch-profile-from-arguments
                         '("--preset=source") context))
               (spec (pichat--launch-preset-definition profile context 'web)))
          (should (equal '("read") (plist-get spec :tools)))
          (should (equal '("ext_tool") (plist-get spec :extensions)))
          (should (equal '(("ketch" . "search")) (plist-get spec :mcp)))
          (should (equal "provider/model" (plist-get spec :model)))
          (should (equal "Replace" (plist-get spec :system-prompt)))
          ;; Prompt sources stay sources; shared text is not baked in.
          (should (equal (list "Inline" (list :file prompt-file))
                         (plist-get spec :append-system-prompt)))
          (should (equal "Saved from source with customized tools"
                         (plist-get spec :description)))
          (dolist (key '(:target :scope :persistence :conversation :session))
            (should-not (plist-member spec key))))
        ;; Without Tools, the baseline itself; Pi's default model is a policy.
        (let* ((profile (pichat--launch-profile-from-arguments '("--preset=source") nil))
               (spec (pichat--launch-preset-definition profile nil 'source)))
          (should (equal '("read" "grep" "bash") (plist-get spec :tools)))
          (should (eq 'default (plist-get spec :model)))
          (should (equal "Source" (plist-get spec :description))))
        ;; Pass-through presets stay pass-through.
        (let* ((profile (pichat--launch-profile-from-arguments '("--preset=standard") nil))
               (spec (pichat--launch-preset-definition profile nil 'mine)))
          (should (eq :default (plist-get spec :tools)))
          (should-not (plist-member spec :mcp)))
        ;; A choice deferred to launch time cannot be saved.
        (should-error (pichat--launch-preset-definition
                       (pichat--launch-profile-from-arguments
                        '("--preset=source") '(:model prompt))
                       '(:model prompt) 'web)
                      :type 'user-error)))))

(ert-deftest pichat-saved-presets-launcher-save-registers-and-selects-name ()
  (pichat-test-with-custom-file file
    (let* ((context (list :directory "/tmp/"
                          :tool-selection '(:builtins ("read") :mcp (("ketch" . "search")))
                          :tool-target '("/tmp/" current inferred)
                          :model "provider/model"))
           (args '("--ephemeral" "--preset=manual"))
           (pichat-default-model nil)
           (default-preset pichat-default-preset)
           result)
      (pichat-test-with-launcher context args
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "web"))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (&rest _) (ert-fail "New names need no confirmation"))))
          (pichat-launch-save-preset))
        (setq result (car staged)))
      (should (equal '((web :description "Saved from manual with customized tools"
                            :tools ("read") :mcp (("ketch" . "search"))
                            :model "provider/model"))
                     pichat-saved-presets))
      (pcase-let ((`(,next-args . ,next) result))
        (should (equal '("--preset=web" "--ephemeral") next-args))
        (dolist (key '(:tool-selection :tool-target :model))
          (should-not (plist-get next key)))
        ;; Same effective tools and model through the newly selected name.
        (let ((profile (pichat--launch-profile-from-arguments next-args next)))
          (should (equal "provider/model" (plist-get profile :model)))
          (should (equal '(("ketch" . "search"))
                         (plist-get (pichat-tool-selection-resolve
                                     (pichat-presets-resolve 'web))
                                    :mcp)))))
      (should (eq default-preset pichat-default-preset))
      (should-not pichat-default-model)
      (should (string-match-p "(web " (pichat-test-saved-presets--file-string file))))))

(ert-deftest pichat-saved-presets-launcher-replacement-needs-confirmation ()
  (pichat-test-with-custom-file file
    (let ((context (list :directory "/tmp/" :model "provider/model"))
          questions)
      (dolist (answer '(nil t))
        (pichat-test-with-launcher context '("--preset=review")
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "manual"))
                    ((symbol-function 'yes-or-no-p)
                     (lambda (question) (push question questions) answer)))
            (pichat-launch-save-preset))
          (if answer
              (should (equal '("--preset=manual") (caar staged)))
            ;; Refusal returns to the unchanged draft without writing.
            (should (equal '("--preset=review") (caar staged)))
            (should (equal "provider/model" (plist-get (cdar staged) :model)))
            (should-not pichat-saved-presets)
            (should-not (file-exists-p file)))))
      (should (equal '("Replace preset manual? " "Replace preset manual? ") questions))
      (should (equal '("read" "grep" "find" "ls")
                     (plist-get (pichat-presets-resolve 'manual) :tools))))))

(ert-deftest pichat-saved-presets-launcher-save-failures-keep-the-draft ()
  (pichat-test-with-custom-file file
    (dolist (case '((:model prompt) (:name "default") (:name quit) (:write fail)))
      (let ((context (list :directory "/tmp/" :model (if (eq (car case) :model)
                                                          'prompt "provider/model")))
            asked)
        (pichat-test-with-launcher context '("--preset=manual")
          (cl-letf (((symbol-function 'read-string)
                     (lambda (&rest _)
                       (setq asked t)
                       (pcase (cadr case)
                         ('quit (signal 'quit nil))
                         ((pred stringp) (cadr case))
                         (_ "fresh"))))
                    ((symbol-function 'custom-save-all)
                     (lambda () (error "Injected write failure"))))
            (pichat-launch-save-preset))
          (when (eq (car case) :model) (should-not asked))
          (should (equal '("--preset=manual") (caar staged)))
          (should (equal (plist-get context :model) (plist-get (cdar staged) :model)))
          (should-not pichat-saved-presets)
          (should-not (pichat-presets-defined-p 'fresh)))))))

(ert-deftest pichat-saved-presets-launcher-renders-model-and-save-action ()
  (let* ((scope (list :directory "/tmp/" :model "provider/model"))
         (transient--prefix (transient--init-prefix 'pichat-launch (list :scope scope)))
         (transient--layout (transient--init-suffixes 'pichat-launch))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (cl-letf (((symbol-function 'transient-get-value) (lambda (&rest _) nil)))
      (should (eq 'pichat-launch-save-preset
                  (lookup-key (transient--make-transient-map) (kbd "c"))))
      (should (eq 'pichat-launch-model
                  (lookup-key (transient--make-transient-map) (kbd "m"))))
      (with-temp-buffer
        (transient--insert-groups)
        (should (string-match-p "c Save preset as…" (buffer-string)))
        (should (string-match-p "m Model provider/model" (buffer-string)))))))

;;; Tools picker, launch validation, reconfiguration and jobs

(ert-deftest pichat-saved-presets-picker-reset-restores-mcp-baseline ()
  (pichat-test-with-presets
    (pichat-make-preset 'web :tools '("read" "grep") :mcp '(("probe" . "search")))
    (let* ((preset (pichat-presets-resolve 'web))
           (pichat-tool-picker--state
            (list :preset preset :baseline '("read" "grep")
                  :draft (copy-tree (pichat-tool-selection-resolve preset))
                  :loaded t :servers (pichat-test-saved-presets--server "search")
                  :discovery (pichat-tool-discovery-draft-create :status 'ready)))
           result)
      (should (equal '(("probe" . "search"))
                     (plist-get (pichat-tool-picker--selection) :mcp)))
      (pichat-tool-picker-none)
      (pichat-tool-picker-reset)
      (should (equal '(("probe" . "search"))
                     (plist-get (pichat-tool-picker--selection) :mcp)))
      (should (equal '("read" "grep") (plist-get (pichat-tool-picker--selection) :builtins)))
      ;; Clearing MCP is a customization that stays empty.
      (pichat-tool-picker--toggle :mcp '("probe" . "search"))
      (setf (plist-get pichat-tool-picker--state :callback)
            (lambda (selection) (setq result selection)))
      (pichat-tool-picker-apply)
      (should (plist-member result :mcp))
      (should-not (plist-get result :mcp))
      (should (member "--no-mcp" (pichat-tool-selection-args
                                  (pichat-tool-selection-resolve preset result)))))))

(ert-deftest pichat-saved-presets-launch-checks-mcp-baseline-at-destination ()
  (pichat-test-with-clean-state
    (pichat-test-with-presets
      (pichat-make-preset 'web :tools '("read") :mcp '(("probe" . "search")))
      (let ((pichat-rpc-command nil)
            (directory (file-name-as-directory temporary-file-directory))
            discovered started)
        (cl-letf (((symbol-function 'pichat-mcp-discovery-start)
                   (lambda (transport cwd _executable callback)
                     (push (list transport cwd callback) discovered)
                     #'ignore))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args) (apply function args)))
                  ((symbol-function 'pichat-start-session)
                   (lambda (_cwd _scope options) (push options started) 'session))
                  ((symbol-function 'pichat--display-and-synchronize-session) #'ignore))
          (let ((profile (list :preset 'web :display-function #'ignore)))
            (should-not (pichat--open-launch-profile profile directory))
            (should (= 1 (length discovered)))
            (should-not started)
            (should (equal (nth 1 (pichat--resolve-launch-scope 'current directory 'inferred))
                           (nth 1 (car discovered))))
            ;; Absent, hidden or failed discovery cancels without starting.
            (funcall (nth 2 (car discovered))
                     (list (list :name "probe" :state "connected"
                                 :tools (list (list :name "search" :exposure "hidden"
                                                    :eligible nil))))
                     nil)
            (funcall (nth 2 (car discovered)) nil "Pi MCP discovery timed out")
            (should-not started)
            (pichat--open-launch-profile profile directory)
            (funcall (nth 2 (car discovered))
                     (pichat-test-saved-presets--server "search") nil)
            (should (= 1 (length started)))
            (should-not (plist-get (car started) :tools))
            ;; Tools already applied for the destination need no second probe.
            (setq discovered nil)
            (pichat--open-launch-profile
             (list :preset 'web :tools '(:builtins ("read") :mcp nil)
                   :display-function #'ignore)
             directory)
            (should-not discovered)
            (should (= 2 (length started)))
            (let ((pichat-rpc-command '("wrapper" "pi")))
              (should-error (pichat--open-launch-profile profile directory)
                            :type 'user-error))))))))

(ert-deftest pichat-saved-presets-reconfiguration-keeps-active-model ()
  (pichat-test-with-presets
    (pichat-make-preset 'pinned :tools '("read") :model "preset/model")
    (let* ((session (pichat-session-make :startup-model "first/model"
                                         :transport pichat-transport-local
                                         :persistence 'persistent))
           (draft (pichat-reconfigure-select-preset
                   (list :preset-spec (pichat-presets-resolve 'manual)) 'pinned))
           (argv (pichat-reconfigure-validated-command
                  session draft '(:model (:provider "active" :id "model"))))
           (models (cl-loop for (arg value) on argv
                            when (equal arg "--model") collect value)))
      (should (equal '("active/model") (last models)))
      (should-not (member "preset/model" argv))
      (should-not (pichat-reconfigure-effective-change-p
                   draft (list :preset-spec (plist-put (copy-tree (plist-get draft :preset-spec))
                                                       :model "other/model")
                               :tool-selection (plist-get draft :tool-selection)))))))

(ert-deftest pichat-saved-presets-captured-jobs-replay-without-registry ()
  (pichat-test-with-clean-state
    (pichat-test-with-presets
      (pichat-make-preset 'web :tools '("read") :mcp '(("probe" . "search"))
                          :model "preset/model")
      (let ((pichat-rpc-command nil)
            (pichat-pi-extra-args nil)
            (directory (file-name-as-directory temporary-file-directory)))
        ;; Captures are already detached JSON data, as stored on disk.
        (cl-flet ((round-trip (spec) (pichat-job--copy spec)))
          (let* ((baseline (round-trip (pichat-job-launch-capture
                                        "Job" "Do it" directory
                                        '(:preset web :model "job/model"))))
                 (empty (round-trip (pichat-job-launch-capture
                                     "Job" "Do it" directory
                                     '(:preset web :model "job/model"
                                       :tools (:builtins ("read") :mcp nil))))))
            (should (equal "job/model" (plist-get (plist-get baseline :configuration) :model)))
            (should-not (plist-member (plist-get (plist-get baseline :configuration) :preset)
                                      :model))
            ;; The registry changing or disappearing does not affect replay.
            (setq pichat-presets (assq-delete-all 'web pichat-presets))
            (pcase-let ((`(,session ,command) (pichat-job-launch-prepare baseline)))
              (should (member "read,mcp__probe__search" command))
              (should (equal '(("probe" . "search"))
                             (plist-get (pichat-session-tool-selection session) :mcp)))
              (should (equal '(("probe" . "search"))
                             (plist-get (pichat-session-preset-spec session) :mcp))))
            (pcase-let ((`(,session ,command) (pichat-job-launch-prepare empty)))
              (should (member "--no-mcp" command))
              (should-not (plist-get (pichat-session-tool-selection session) :mcp)))
            (should (string-match-p "Preset defaults: read · 1 MCP tools"
                                    (pichat-jobs--tools-summary
                                     (plist-get baseline :configuration))))))))))

(provide 'pichat-test-saved-presets)
;;; pichat-test-saved-presets.el ends here
