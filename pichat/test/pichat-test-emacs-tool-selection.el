;;; pichat-test-emacs-tool-selection.el --- Grouped per-runtime Emacs tool exposure -*- lexical-binding: t; -*-

;;; Commentary:

;; Registration makes an Emacs-defined tool selectable; only a runtime's
;; captured exact selection exposes or dispatches it.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-tool-picker)
(require 'pichat-tool-bridge)
(require 'pichat-bridge-transport)
(require 'pichat-reconfigure)
(require 'pichat-job-launch)

(defmacro pichat-test-with-emacs-tools (&rest body)
  "Run BODY with grouped read/mutating Emacs tools registered."
  (declare (indent 0) (debug t))
  `(pichat-test-with-clean-state
     (pichat-define-tool pichat_test_list (:group "Jobs" :description "List") "listed")
     (pichat-define-tool pichat_test_set (:group "Jobs" :description "Set" :mutating t) "set")
     (pichat-define-tool pichat_test_buffer (:group "Buffers" :description "Buffer") "buffer")
     (pichat-define-tool pichat_test_plain (:description "Ungrouped") "plain")
     ,@body))

(defun pichat-test-emacs-declared (session)
  "Return names the bridge would declare for SESSION."
  (mapcar (lambda (tool) (plist-get tool :name))
          (plist-get (json-parse-string
                      (pichat-bridge-transport-startup-reply
                       (list :title pichat-bridge-transport-tools-title) session)
                      :object-type 'plist :array-type 'list)
                     :tools)))

(defun pichat-test-emacs-preset (&rest emacs)
  "Return an explicit-tool preset snapshot with EMACS baseline names."
  (append (pichat-presets-resolve 'manual)
          (when emacs (list :emacs-tools emacs))))

(ert-deftest pichat-emacs-tools-registration-lists-groups-without-exposure ()
  (pichat-test-with-emacs-tools
    (let ((catalogue (pichat-tools-catalogue)))
      (should (equal '(("Buffers" "pichat_test_buffer")
                       ("Jobs" "pichat_test_list" "pichat_test_set")
                       ("Other" "pichat_test_plain"))
                     (let (groups)
                       (dolist (tool catalogue (nreverse groups))
                         (if (equal (caar groups) (plist-get tool :group))
                             (setcdr (car groups)
                                     (append (cdar groups) (list (plist-get tool :name))))
                           (push (list (plist-get tool :group) (plist-get tool :name))
                                 groups))))))
      (should (plist-get (cl-find "pichat_test_set" catalogue :test #'equal
                                  :key (lambda (tool) (plist-get tool :name)))
                         :mutating)))
    ;; No runtime, no selection, or a pass-through runtime declares nothing.
    (should-not (pichat-test-emacs-declared nil))
    (let ((session (pichat-session-make :cwd default-directory)))
      (should-not (pichat-test-emacs-declared session))
      (pichat-session-set-configuration session (pichat-presets-resolve 'standard) nil)
      (should-not (pichat-test-emacs-declared session)))
    (should-error (pichat-tools-register
                   (pichat-tool-create :name "bad" :function #'ignore :group " "))
                  :type 'error)))

(ert-deftest pichat-emacs-tools-selection-resolves-exact-opt-in-names ()
  (pichat-test-with-emacs-tools
    (let ((manual (pichat-presets-resolve 'manual)))
      (should-not (plist-get (pichat-tool-selection-resolve manual) :emacs))
      (let ((snapshot (pichat-tool-selection-resolve
                       manual '(:builtins ("read") :emacs ("pichat_test_set" "pichat_test_list")))))
        (should (equal '("pichat_test_list" "pichat_test_set") (plist-get snapshot :emacs)))
        ;; Pi's allowlist admits exactly the selected bridge tools as well.
        (should (equal '("--tools" "read,pichat_test_list,pichat_test_set" "--no-mcp")
                       (pichat-tool-selection-args snapshot)))
        (should (string-match-p "no PiChat bridge.*pichat_test_list, pichat_test_set"
                                (pichat-tool-selection-emacs-note snapshot))))
      (should (equal '("pichat_test_list")
                     (plist-get (pichat-tool-selection-resolve
                                 (pichat-test-emacs-preset "pichat_test_list"))
                                :emacs)))
      (dolist (bad '((:emacs ("x" "x")) (:emacs ("bad name")) (:emacs ("read"))
                     (:extensions ("same") :emacs ("same"))))
        (should-error (pichat-tool-selection-resolve manual bad) :type 'user-error))
      (should-error (pichat-tool-selection-resolve
                     (pichat-presets-resolve 'standard) '(:emacs ("pichat_test_list")))
                    :type 'user-error))
    (let ((pichat-presets (copy-tree pichat-presets)))
      (should-error (pichat-make-preset 'pichat-test-pass :tools :default
                      :emacs-tools '("pichat_test_list"))
                    :type 'user-error)
      (pichat-make-preset 'pichat-test-jobs :tools '("read") :emacs-tools '("pichat_test_list"))
      (should (equal '("pichat_test_list")
                     (plist-get (pichat-presets-resolve 'pichat-test-jobs) :emacs-tools)))
      (should-not (plist-member (pichat-presets-resolve 'manual) :emacs-tools)))))

(ert-deftest pichat-emacs-tools-bridge-declares-and-dispatches-only-owning-runtime-selection ()
  (pichat-test-with-emacs-tools
    (pichat-test-with-temp-dir dir
      (let* ((pichat-approval-policy-file (expand-file-name "approvals.el" dir))
             (first (pichat-test-select-emacs-tools
                     (pichat-session-make :cwd default-directory) "pichat_test_list"))
             (second (pichat-test-select-emacs-tools
                      (pichat-session-make :cwd default-directory)
                      "pichat_test_set" "pichat_test_missing"))
             (call (lambda (name) (format "{\"name\":\"%s\",\"params\":{}}" name)))
             (executions 0))
        (pichat-define-tool pichat_test_counted (:group "Jobs") (cl-incf executions) "ran")
        (should (equal '("pichat_test_list") (pichat-test-emacs-declared first)))
        ;; A missing selected tool is omitted, never replaced by others.
        (should (equal '("pichat_test_set") (pichat-test-emacs-declared second)))
        ;; Registering more tools (even in a selected group) adds nothing.
        (pichat-define-tool pichat_test_late (:group "Jobs") "late")
        (should (equal '("pichat_test_list") (pichat-test-emacs-declared first)))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _) (ert-fail "Unselected calls must not prompt"))))
          (dolist (name '("pichat_test_set" "pichat_test_counted" "pichat_test_late"))
            (should-not (pichat-tool-bridge-approval-required-p (funcall call name) first))
            (let ((result (json-parse-string
                           (pichat-tool-bridge-execute-json (funcall call name) first)
                           :object-type 'plist :array-type 'list :false-object nil)))
              (should (plist-get result :isError))
              (should (string-match-p "not selected" (format "%S" result)))))
          (should (= 0 executions))
          (should (string-match-p
                   "listed" (pichat-tool-bridge-execute-json (funcall call "pichat_test_list") first))))
        ;; Selection exposes; it never approves.  The selected mutating tool asks.
        (should (pichat-tool-bridge-approval-required-p (funcall call "pichat_test_set") second))
        (should-not (pichat-tool-bridge-approval-required-p (funcall call "pichat_test_set") first))))))

(ert-deftest pichat-emacs-tools-restart-replacement-uses-requested-selection ()
  (pichat-test-with-emacs-tools
    (let ((session (pichat-test-select-emacs-tools
                    (pichat-session-make :cwd default-directory) "pichat_test_list"))
          (requested '(:builtins nil :mcp nil :names nil :emacs ("pichat_test_buffer"))))
      (setf (pichat-session-restart-operation session)
            (list :phase 'stopping :active-configuration (list :tool-selection requested)))
      (should (equal '("pichat_test_list") (pichat-test-emacs-declared session)))
      (dolist (phase '(starting loading synchronizing))
        (plist-put (pichat-session-restart-operation session) :phase phase)
        (should (equal '("pichat_test_buffer") (pichat-test-emacs-declared session)))))))

(ert-deftest pichat-emacs-tools-reconfiguration-and-job-capture-preserve-exact-selection ()
  (pichat-test-with-emacs-tools
    (let* ((spec (pichat-presets-resolve 'manual))
           (before (list :preset-spec spec
                         :tool-selection (pichat-tool-selection-resolve spec)))
           (after (pichat-reconfigure-select-tools
                   before '(:builtins ("read" "grep" "find" "ls" "edit" "write")
                            :emacs ("pichat_test_list")))))
      (should (equal '("pichat_test_list")
                     (plist-get (plist-get after :tool-selection) :emacs)))
      (should (pichat-reconfigure-effective-change-p before after))
      (should-not (pichat-reconfigure-effective-change-p after after))
      ;; Captured jobs round-trip exact names without consulting registries.
      (let* ((preset (pichat-test-emacs-preset "pichat_test_list"))
             (tools (plist-get after :tool-selection))
             (encoded-preset (pichat-job--copy (pichat-job-launch--preset preset)))
             (encoded-tools (pichat-job--copy (pichat-job-launch--tools tools)))
             (decoded-preset (pichat-job-launch--unpreset encoded-preset)))
        (should (equal '("pichat_test_list") (plist-get decoded-preset :emacs-tools)))
        (should (equal tools (pichat-job-launch--untools decoded-preset encoded-tools)))
        ;; Captures predating Emacs-defined selection decode to none.
        (let ((legacy (pichat-job--copy (pichat-job-launch--tools
                                         (pichat-tool-selection-resolve spec)))))
          (should-not (plist-member legacy :emacs))
          (should-not (plist-get (pichat-job-launch--untools spec legacy) :emacs)))
        (should-not (plist-member (pichat-job-launch--preset spec) :emacs-tools))))))

(ert-deftest pichat-emacs-tools-selection-loads-the-bundled-bridge ()
  (pichat-test-with-emacs-tools
    (let* ((spec (pichat-presets-resolve 'manual))
           (pichat-bridge-extension-file nil)
           (pichat-rpc-command nil)
           (pichat-pi-extra-args nil)
           (session (lambda (emacs)
                      (pichat-session-make
                       :cwd default-directory :preset-spec spec
                       :tool-selection (pichat-tool-selection-resolve
                                        spec (list :builtins '("read") :emacs emacs)))))
           (ssh (pichat-transport--create :id "ssh:host" :kind (quote ssh) :label "host")))
      (should (equal pichat-rpc-bundled-bridge
                     (cadr (member "-e" (pichat-rpc-build-command
                                         (funcall session '("pichat_test_list")))))))
      (should-not (member pichat-rpc-bundled-bridge
                          (pichat-rpc-build-command (funcall session nil))))
      (should-not (pichat-rpc-bridge-file ssh '(:emacs ("pichat_test_list"))))
      ;; A configured bridge wins and is not loaded twice.
      (let ((pichat-bridge-extension-file "/custom/bridge.ts"))
        (should (equal "/custom/bridge.ts"
                       (pichat-rpc-bridge-file nil '(:emacs ("pichat_test_list"))))))
      (let ((pichat-pi-extra-args '("-e" "/x/pichat-bridge.ts")))
        (should-not (pichat-rpc-bridge-file nil '(:emacs ("pichat_test_list"))))
        (should (pichat-rpc-bridge-p nil))))))

(ert-deftest pichat-emacs-tools-missing-selection-starts-without-it-and-says-so ()
  (pichat-test-with-emacs-tools
    (let* ((spec (pichat-presets-resolve 'manual))
           (session (pichat-session-make
                     :cwd default-directory :preset-spec spec
                     :tool-selection (pichat-tool-selection-resolve
                                      spec '(:builtins ("read")
                                             :emacs ("pichat_test_gone" "pichat_test_list")))))
           (pichat-bridge-extension-file "/bridge.ts")
           (pichat-rpc-command nil) spawned messages)
      (cl-letf (((symbol-function 'pichat-transport-make-process)
                 (lambda (&rest args) (setq spawned args) (error "Stop after spawn")))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format-message format args) messages))))
        (pichat-rpc-start session))
      (should (string-match-p "read,pichat_test_list\"" (format "%S" spawned)))
      (should-not (string-match-p "pichat_test_gone" (format "%S" spawned)))
      (should (cl-some (lambda (text) (string-match-p "not available (not loaded): pichat_test_gone" text))
                       messages))
      ;; Background starts (job runs) skip the same note.
      (setq messages nil)
      (cl-letf (((symbol-function 'pichat-transport-make-process)
                 (lambda (&rest _) (error "Stop after spawn")))
                ((symbol-function 'message)
                 (lambda (format &rest args) (push (apply #'format-message format args) messages))))
        (let ((non-essential t)) (pichat-rpc-start session)))
      (should-not (cl-some (lambda (text) (string-match-p "not available" text)) messages)))))

(defmacro pichat-test-with-emacs-picker (preset draft &rest body)
  "Run BODY with an Emacs-tool picker state for PRESET and DRAFT."
  (declare (indent 2))
  `(let* ((pichat-tool-picker--state
           (list :preset ,preset :baseline (copy-sequence (plist-get ,preset :tools))
                 :draft ,draft :discovery (pichat-tool-discovery-draft-create :status 'ready)
                 :servers nil :loaded t :page 0
                 :emacs-catalogue (pichat-tools-catalogue) :emacs-group nil)))
     ,@body))

(ert-deftest pichat-emacs-tools-picker-groups-support-all-none-and-partial-selection ()
  (pichat-test-with-emacs-tools
    (let ((preset (pichat-test-emacs-preset "pichat_test_buffer")))
      (pichat-test-with-emacs-picker preset
          (copy-tree (pichat-tool-selection-resolve preset))
        (let* ((transient--prefix (transient--init-prefix 'pichat-tool-picker))
               (transient--layout (transient--init-suffixes 'pichat-tool-picker))
               (transient--suffixes (transient--flatten-suffixes transient--layout)))
          (with-temp-buffer
            (transient--insert-groups)
            (should (string-match-p "Emacs-defined tools" (buffer-string)))
            (should (string-match-p "Buffers (1/1)" (buffer-string)))
            (should (string-match-p "Jobs (0/2)" (buffer-string)))
            (should (string-match-p "Other (0/1)" (buffer-string)))))
        ;; Global select-all leaves Emacs-defined tools explicit.
        (pichat-tool-picker-all)
        (should (equal '("pichat_test_buffer")
                       (plist-get (pichat-tool-picker--selection) :emacs)))
        (setf (plist-get pichat-tool-picker--state :emacs-group) "Jobs")
        (let* ((transient--prefix (transient--init-prefix 'pichat-tool-picker-emacs-group))
               (transient--layout (transient--init-suffixes 'pichat-tool-picker-emacs-group))
               (transient--suffixes (transient--flatten-suffixes transient--layout)))
          (with-temp-buffer
            (transient--insert-groups)
            (should (string-match-p "\\[ \\] pichat_test_set — Set (asks approval)" (buffer-string)))
            (should (string-match-p "does not approve" (buffer-string)))))
        (pichat-tool-picker-emacs-group-all)
        (should (equal '("pichat_test_buffer" "pichat_test_list" "pichat_test_set")
                       (plist-get (pichat-tool-picker--selection) :emacs)))
        (pichat-tool-picker--toggle :emacs "pichat_test_set")
        (should (equal '("pichat_test_buffer" "pichat_test_list")
                       (plist-get (pichat-tool-picker--selection) :emacs)))
        (pichat-tool-picker-emacs-group-none)
        (should (equal '("pichat_test_buffer")
                       (plist-get (pichat-tool-picker--selection) :emacs)))
        (pichat-tool-picker-none)
        (should-not (plist-get (pichat-tool-picker--selection) :emacs))
        (pichat-tool-picker-reset)
        (should (equal '("pichat_test_buffer")
                       (plist-get (pichat-tool-picker--selection) :emacs)))))))

(ert-deftest pichat-emacs-tools-picker-apply-cancel-and-refresh-keep-exact-selection ()
  (pichat-test-with-emacs-tools
    (let ((preset (pichat-presets-resolve 'manual)) result)
      (pichat-test-with-emacs-picker preset
          (copy-tree (pichat-tool-selection-resolve preset))
        (setf (plist-get pichat-tool-picker--state :callback) (lambda (value) (setq result value)))
        (setf (plist-get pichat-tool-picker--state :emacs-group) "Jobs")
        (pichat-tool-picker-emacs-group-all)
        ;; A tool registered later in the same group is listed, not selected.
        (pichat-define-tool pichat_test_new (:group "Jobs") "new")
        (cl-letf (((symbol-function 'pichat-tool-picker--discover) #'ignore)
                  ((symbol-function 'pichat-tool-picker--discover-extensions) #'ignore))
          (pichat-tool-picker-refresh))
        (should (= 3 (length (pichat-tool-picker--emacs-group-tools "Jobs"))))
        (should (equal '("pichat_test_list" "pichat_test_set")
                       (plist-get (pichat-tool-picker--selection) :emacs)))
        (pichat-tool-picker-apply)
        (should (equal '("pichat_test_list" "pichat_test_set") (plist-get result :emacs))))
      (pichat-test-with-emacs-picker preset
          (list :builtins nil :emacs '("pichat_test_list"))
        (setf (plist-get pichat-tool-picker--state :callback) (lambda (value) (setq result value)))
        (remhash "pichat_test_list" pichat-tools-registry)
        (cl-letf (((symbol-function 'pichat-tool-picker--discover) #'ignore)
                  ((symbol-function 'pichat-tool-picker--discover-extensions) #'ignore))
          (pichat-tool-picker-refresh))
        ;; The section says what will be skipped; Apply still succeeds.
        (let ((pichat-bridge-extension-file "/bridge.ts"))
          (should (string-match-p "will be skipped: pichat_test_list"
                                  (pichat-tool-picker--emacs-heading))))
        (let ((pichat-rpc-bundled-bridge "/missing/pichat-bridge.ts"))
          (should (string-match-p "inactive: no PiChat bridge"
                                  (pichat-tool-picker--emacs-heading))))
        (pichat-tool-picker-apply)
        (should (equal '("pichat_test_list") (plist-get result :emacs)))))))

(provide 'pichat-test-emacs-tool-selection)
;;; pichat-test-emacs-tool-selection.el ends here
