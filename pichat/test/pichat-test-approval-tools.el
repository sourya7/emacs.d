;;; pichat-test-approval-tools.el --- Pichat Test Approval Tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

;;; Tool bridge unit tests

(ert-deftest pichat-tools-load-does-not-register-demo-tools ()
  ;; Use a fresh Emacs: the suite resets the registry between scenarios.
  (with-temp-buffer
    (let ((status
           (call-process
            (expand-file-name invocation-name invocation-directory)
            nil (current-buffer) nil
            "-Q" "--batch" "-L" pichat-directory
            "--eval"
            "(progn (require 'pichat-tools) (unless (zerop (hash-table-count pichat-tools-registry)) (error \"Loading tools registered unsolicited tools\")))")))
      (ert-info ((buffer-string))
        (should (eql 0 status))))))

(ert-deftest pichat-tools-definitions-json-encodes-single-tool-as-array ()
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-json
        (:label "JSON Test"
         :description "A JSON encoding test tool"
         :parameters (:type "object" :properties (:value (:type "string")) :required ["value"]))
      "ok")
    (let* ((decoded (json-parse-string (pichat-tools-definitions-json 'all)
                                       :object-type 'plist
                                       :array-type 'list
                                       :false-object nil))
           (tools (plist-get decoded :tools)))
      (should (= 1 (length tools)))
      (should (equal "pichat-test-json" (plist-get (car tools) :name))))))

(ert-deftest pichat-tools-execute-json-encodes-string-result-content-as-array ()
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-result
        (:label "Result Test" :description "A result encoding test tool")
      "tool output")
    (let* ((decoded (json-parse-string
                     (pichat-tools-execute-json "{\"name\":\"pichat-test-result\",\"params\":{}}"
                                                nil 'all)
                     :object-type 'plist
                     :array-type 'list
                     :false-object nil))
           (content (plist-get decoded :content)))
      (should (= 1 (length content)))
      (should (equal "tool output" (plist-get (car content) :text))))))

(ert-deftest pichat-tools-execute-json-decodes-encoded-utf-8-results ()
  ;; Tools naturally return `json-serialize' output, which is UTF-8 bytes.
  (pichat-test-with-clean-state
    (let ((json (json-serialize '(:title "Résumé — 日本語"))))
      (should-not (multibyte-string-p json))
      (pichat-define-tool pichat-test-encoded-string () json)
      (pichat-define-tool pichat-test-invalid-bytes () (unibyte-string #xff #xfe))
      (let* ((reply (json-parse-string
                     (pichat-tools-execute-json
                      "{\"name\":\"pichat-test-encoded-string\",\"params\":{}}" nil 'all)
                     :object-type 'plist :array-type 'list))
             (text (plist-get (car (plist-get reply :content)) :text)))
        (should-not (plist-get reply :isError))
        (should (equal "Résumé — 日本語"
                       (plist-get (json-parse-string text :object-type 'plist) :title))))
      ;; Binary output cannot become text; the bridge turns this into an
      ;; error reply (`pichat-bridge-result-encoding-error-replies-instead-of-hanging').
      (should-error (pichat-tools-execute-json
                     "{\"name\":\"pichat-test-invalid-bytes\",\"params\":{}}" nil 'all)))))

(ert-deftest pichat-tools-non-text-results-are-tool-errors-naming-the-tool ()
  ;; nil used to reach Pi as JSON null and a list as an arbitrary object.
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-nil-result () nil)
    (pichat-define-tool pichat-test-structured-result ()
      (list :content (vector (list :type "text" :text "structured"))))
    (pichat-define-tool pichat-test-number-result () 42)
    (dolist (name '("pichat-test-nil-result" "pichat-test-structured-result"
                    "pichat-test-number-result"))
      (let* ((reply (json-parse-string
                     (pichat-tools-execute-json
                      (json-serialize (list :name name :params '())) nil 'all)
                     :object-type 'plist :array-type 'list))
             (content (plist-get reply :content)))
        (should (eq t (plist-get reply :isError)))
        (should (= 1 (length content)))
        (should (equal (format "Emacs tool %s returned no text" name)
                       (plist-get (car content) :text)))))))

(ert-deftest pichat-tools-registration-rejects-tools-the-bridge-cannot-declare ()
  ;; The bridge drops every Emacs-defined tool of a runtime when one
  ;; definition is invalid, so such a tool must never become selectable.
  (pichat-test-with-clean-state
    (let ((original (pichat-tools-register
                     (pichat-tool-create :name "kept" :function #'ignore))))
      (pcase-dolist (`(,tool . ,pattern)
                     `((,(pichat-tool-create :name "bad.name" :function #'ignore)
                        . "bad\\.name")
                       (,(pichat-tool-create :name "with space" :function #'ignore)
                        . "with space")
                       (,(pichat-tool-create :name 'symbol :function #'ignore)
                        . "symbol")
                       (,(pichat-tool-create :name "unencodable" :function #'ignore
                                             :parameters '(:type object))
                        . "cannot be encoded.*unencodable")
                       (,(pichat-tool-create :name "array-schema" :function #'ignore
                                             :parameters ["object"])
                        . "JSON object schema: array-schema")
                       (,(pichat-tool-create :name "numeric-label" :function #'ignore
                                             :label 7)
                        . "label must be a string: numeric-label")
                       (,(pichat-tool-create :name "kept" :function #'ignore
                                             :description '(:not "text"))
                        . "description must be a string: kept")))
        (let ((err (should-error (pichat-tools-register tool) :type 'error)))
          (should (string-match-p pattern (error-message-string err)))))
      (should (eq original (gethash "kept" pichat-tools-registry)))
      (should (= 1 (hash-table-count pichat-tools-registry)))
      ;; Absent label, description and parameters are omitted, not null.
      (let ((tool (car (plist-get (json-parse-string
                                   (pichat-tools-definitions-json 'all)
                                   :object-type 'plist :array-type 'list)
                                  :tools))))
        (should (equal "kept" (plist-get tool :name)))
        (should-not (plist-member tool :label))
        (should-not (plist-member tool :parameters))))))

(ert-deftest pichat-tools-missing-selection-permits-nothing ()
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-anything () "ran")
    (should-not (pichat-tools-allowed-p "pichat-test-anything" nil))
    (should-not (pichat-tools-allowed-p "pichat-test-anything" 'none))
    (should (pichat-tools-allowed-p "pichat-test-anything" 'all))
    (should (pichat-tools-allowed-p "pichat-test-anything" '("pichat-test-anything")))
    (should (equal [] (plist-get (json-parse-string (pichat-tools-definitions-json)
                                                    :object-type 'plist)
                                 :tools)))
    (let ((reply (json-parse-string
                  (pichat-tools-execute-json
                   "{\"name\":\"pichat-test-anything\",\"params\":{}}")
                  :object-type 'plist :array-type 'list)))
      (should (eq t (plist-get reply :isError)))
      (should (string-match-p "not selected"
                              (plist-get (car (plist-get reply :content)) :text))))))

(ert-deftest pichat-bridge-definitions-failure-still-answers-and-records-diagnostic ()
  ;; An unanswered definitions request blocks Pi's before_agent_start.
  (pichat-test-with-unit-session (session proc)
    (let (response)
      (pichat-define-tool pichat-test-declared () "ok")
      (pichat-test-select-emacs-tools session "pichat-test-declared")
      (cl-letf (((symbol-function 'pichat-tools-definitions-json)
                 (lambda (&rest _) (error "Definitions exploded")))
                ((symbol-function 'pichat-rpc-extension-ui-value)
                 (lambda (_session id value) (setq response (list id value)))))
        (should (pichat-bridge-transport-handle
                 session '(:id "defs" :method "editor"
                           :title "__pichat_tools_request__" :prefill "{}"))))
      (should (equal "defs" (car response)))
      (let ((reply (json-parse-string (cadr response) :object-type 'plist)))
        (should (= 1 (plist-get reply :protocolVersion)))
        (should (equal [] (plist-get reply :tools))))
      (let ((diagnostic (pichat-chat-diagnostics-latest session)))
        (should (eq 'bridge-definitions (plist-get diagnostic :origin)))
        (should (string-match-p "Definitions exploded"
                                (plist-get diagnostic :message)))))))

(ert-deftest pichat-tools-rejects-async-before-definition-or-registration ()
  (pichat-test-with-clean-state
    (should-error
     (macroexpand '(pichat-define-tool pichat-test-async
                       (:description "Unsupported" :async t)
                     "never"))
     :type 'error)
    (should-not (fboundp 'pichat-tool/pichat-test-async))
    (let ((original (pichat-tools-register
                     (pichat-tool-create :name "sentinel" :function #'ignore))))
      (should-error
       (pichat-tools-register
        (pichat-tool-create :name "sentinel" :function #'ignore :async-p t))
       :type 'error)
      (should (eq original (gethash "sentinel" pichat-tools-registry))))
    (should-not (string-match-p "pichat-test-async"
                                (pichat-tools-definitions-json 'all)))
    (pichat-define-tool pichat-test-sync (:async nil) "sync")
    (should (equal "sync" (plist-get
                           (pichat-tools-call
                            (gethash "pichat-test-sync" pichat-tools-registry)
                            nil)
                           :value)))))

(ert-deftest pichat-tools-call-reports-errors-once-and-rejects-async ()
  (pichat-test-with-clean-state
    (let* ((calls 0)
           (tool (pichat-tool-create
                  :name "failure"
                  :function (lambda (_params)
                              (cl-incf calls)
                              (error "tool failure"))))
           (result (pichat-tools-call tool nil)))
      (should (= 1 calls))
      (should (plist-get result :is-error))
      (should (string-match-p "tool failure" (plist-get result :value)))
      (setf (pichat-tool-async-p tool) t)
      (should-error (pichat-tools-call tool nil) :type 'error)
      (should (= 1 calls)))))

(ert-deftest pichat-tools-instructions-serialize-only-nonblank-guidance ()
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-guided
        (:description "Tool description" :instructions "Prefer unsaved buffers")
      "ok")
    (pichat-define-tool pichat-test-blank (:instructions "  \n") "ok")
    (pichat-define-tool pichat-test-absent () "ok")
    (let* ((tools (plist-get (json-parse-string (pichat-tools-definitions-json 'all)
                                               :object-type 'plist :array-type 'list)
                            :tools))
           (guided (cl-find "pichat-test-guided" tools :test #'equal
                            :key (lambda (tool) (plist-get tool :name)))))
      (should (equal "Tool description" (plist-get guided :description)))
      (should (equal "Prefer unsaved buffers" (plist-get guided :instructions)))
      (should (= 1 (cl-count-if (lambda (tool) (plist-member tool :instructions))
                                 tools))))
    (should-error
     (pichat-tools-register
      (pichat-tool-create :name "invalid" :function #'ignore :instructions 42))
     :type 'error)
    (should-not (gethash "invalid" pichat-tools-registry))))

;;; Approval unit tests

(defmacro pichat-test-with-approval-file (&rest body)
  "Run BODY with approval policy stored in a temp file."
  (declare (indent 0) (debug t))
  `(pichat-test-with-temp-dir dir
     (let ((pichat-approval-policy-file (expand-file-name "approvals.el" dir))
           (pichat-approval-rules nil))
       ,@body)))

(ert-deftest pichat-approval-read-only-tool-is-allowed-without-prompt ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args)
                   (ert-fail "Read-only tool should not prompt for approval"))))
        (should (pichat-approval-approve-p "read-only" nil))))))

(ert-deftest pichat-approval-explicit-deny-blocks-read-only-tool ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (setq pichat-approval-rules '(("read-only" . deny)))
      (pichat-approval-save)
      (setq pichat-approval-rules nil)
      (should-not (pichat-approval-approve-p "read-only" nil)))))

(ert-deftest pichat-approval-mutating-tool-uses-stored-allow-and-deny ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (setq pichat-approval-rules '(("mutate" . allow)))
      (pichat-approval-save)
      (setq pichat-approval-rules nil)
      (should (pichat-approval-approve-p "mutate" t))
      (setq pichat-approval-rules '(("mutate" . deny)))
      (pichat-approval-save)
      (setq pichat-approval-rules nil)
      (should-not (pichat-approval-approve-p "mutate" t)))))

(ert-deftest pichat-approval-mutating-tool-can-be-allowed-once-without-saving-rule ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args) "Allow once")))
        (should (pichat-approval-approve-p "mutate" t))
        (should (null pichat-approval-rules))
        (should-not (file-exists-p pichat-approval-policy-file))))))

(ert-deftest pichat-approval-missing-policy-file-loads-as-ask-default ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (should-not (file-exists-p pichat-approval-policy-file))
      (should (eq 'ask (pichat-approval-decision "unknown")))
      (pichat-approval-load)
      (should (eq 'ask (pichat-approval-decision "unknown"))))))

(ert-deftest pichat-approval-empty-or-malformed-policy-loads-as-ask-default ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (dolist (contents '("" "(" "not-an-alist" "((\"tool\" . invalid))"))
        (with-temp-file pichat-approval-policy-file (insert contents))
        (setq pichat-approval-rules '(("stale" . allow)))
        (pichat-approval-load)
        (should (eq 'ask (pichat-approval-decision "tool")))
        (should (eq 'ask (pichat-approval-decision "stale")))))))

(ert-deftest pichat-emacs-tool-approval-shows-arguments-and-supports-session-scope ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (let ((session (pichat-session-make :cwd default-directory))
            (params '(:path "/tmp/target"))
            prompt
            (prompts 0))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (message &rest _args)
                     (setq prompt message)
                     (cl-incf prompts)
                     "Allow for session")))
          (should (pichat-approval-approve-p "mutate" t params session))
          (should (string-match-p (regexp-quote "/tmp/target") prompt))
          (should (pichat-approval-approve-p "mutate" t params session))
          (should (= 1 prompts)))
        (setq pichat-approval-rules '(("mutate" . deny)))
        (pichat-approval-save)
        (should-not (pichat-approval-approve-p "mutate" t params session))
        (should (eq 'deny (pichat-approval-decision "mutate" session)))))))

(ert-deftest pichat-approval-resolution-separates-policy-from-prompting ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _args)
                   (ert-fail "Policy resolution must not prompt"))))
        (should (eq 'allow (pichat-approval-resolve "read-only" nil)))
        (should (eq 'ask (pichat-approval-resolve "mutate" t)))
        (setq pichat-approval-rules '(("mutate" . deny)))
        (pichat-approval-save)
        (should (eq 'deny (pichat-approval-resolve "mutate" t)))))))

(ert-deftest pichat-tools-expose-the-calling-runtime-only-during-a-call ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :cwd default-directory))
          seen)
      (pichat-define-tool pichat-test-caller ()
        (setq seen pichat-tools-calling-session)
        "ok")
      (pichat-tools-execute-json "{\"name\":\"pichat-test-caller\",\"params\":{}}" session 'all)
      (should (eq session seen))
      (should-not pichat-tools-calling-session)
      (pichat-tools-call (gethash "pichat-test-caller" pichat-tools-registry) nil)
      (should-not seen))))

(ert-deftest pichat-tools-approval-summary-describes-the-call-lazily ()
  ;; The prompt names what the call will do; raw arguments stay visible.  The
  ;; summary runs only when prompting, and a failing summary still prompts.
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (let ((session (pichat-session-make :cwd default-directory))
            (summaries 0)
            prompts)
        (pichat-define-tool pichat-test-described
            (:mutating t
             :approval-summary (lambda (params)
                                 (cl-incf summaries)
                                 (when (equal (plist-get params :target) "bad")
                                   (error "Summary failed"))
                                 (format "Change %s\nnow" (plist-get params :target))))
          "changed")
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt &rest _) (push prompt prompts) "Deny once")))
          (pichat-tools-execute-json
           "{\"name\":\"pichat-test-described\",\"params\":{\"target\":\"alpha\"}}" session 'all)
          (should (string-match-p "pichat-test-described (Change alpha now) with arguments.*alpha"
                                  (car prompts)))
          (pichat-tools-execute-json
           "{\"name\":\"pichat-test-described\",\"params\":{\"target\":\"bad\"}}" session 'all)
          (should (string-match-p "pichat-test-described with arguments.*bad" (car prompts))))
        (should (= 2 summaries))
        (setq pichat-approval-rules '(("pichat-test-described" . allow)))
        (pichat-approval-save)
        (pichat-tools-execute-json
         "{\"name\":\"pichat-test-described\",\"params\":{\"target\":\"alpha\"}}" session 'all)
        (should (= 2 summaries))))))

(ert-deftest pichat-tools-parameter-helpers-validate-bridge-values ()
  ;; The bridge decodes JSON false as nil; boolean helpers must accept it.
  (let ((params (plist-get (json-parse-string
                            "{\"params\":{\"flag\":false,\"on\":true,\"count\":3}}"
                            :object-type 'plist :false-object nil :null-object nil)
                           :params)))
    (should (eq params (pichat-tools-check-params params '(:flag :on :count) '(:count))))
    (should-error (pichat-tools-check-params params '(:flag :on)) :type 'user-error)
    (should-error (pichat-tools-check-params params '(:flag :on :count :x) '(:x))
                  :type 'user-error)
    (should (eq nil (pichat-tools-boolean-param params :flag)))
    (should (eq t (pichat-tools-boolean-param params :on)))
    (should (eq 'absent (pichat-tools-boolean-param params :missing)))
    (should-error (pichat-tools-boolean-param params :count) :type 'user-error)
    (should (= 3 (pichat-tools-count-param params :count 1 5 1)))
    (should (= 1 (pichat-tools-count-param nil :count 1 5 1)))
    (should-error (pichat-tools-count-param params :count 1 2) :type 'user-error)
    (should-error (pichat-tools-count-param '(:count 0) :count 1 5 1) :type 'user-error)
    (should (equal "a b…" (pichat-tools-display-text "a\nbcd" 4)))
    (should-error (pichat-tools-id-param '(:id "../x") :id "an ID") :type 'user-error)))

(ert-deftest pichat-mutating-bridge-tool-waits-for-owning-chat-before-approval ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-approval-file
      (let ((pichat-chat-stop-session-on-kill nil)
            (other (generate-new-buffer " *pichat-tool-unrelated*"))
            buffer callback callback-args response
            (prompts 0)
            (executions 0)
            (raw '(:id "bridge-tool" :method "editor"
                   :title "__pichat_tool_call__"
                   :prefill "{\"name\":\"pichat-test-mutate-wait\",\"params\":{\"value\":\"yes\"}}")))
        (pichat-define-tool pichat-test-mutate-wait
            (:label "Deferred mutation" :description "Mutate after approval"
             :mutating t)
          (cl-incf executions)
          (format "mutated:%s" (plist-get params :value)))
        (pichat-test-select-emacs-tools session "pichat-test-mutate-wait")
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (switch-to-buffer other)
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (&rest _args)
                           (ert-fail "Background bridge request must not prompt"))))
                (with-current-buffer buffer
                  (pichat-chat--on-extension-ui-request
                   session 'extension-ui-request (list :raw raw))
                  (should (= 1 pichat-chat--pending-ui-count))
                  (should (= 1 (pichat-chat-pending-user-input-count session)))))
              (switch-to-buffer buffer)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (_delay _repeat function &rest args)
                           (setq callback function callback-args args)
                           'deferred))
                        ((symbol-function 'completing-read)
                         (lambda (&rest _args) (cl-incf prompts) "Allow once"))
                        ((symbol-function 'pichat-rpc-extension-ui-value)
                         (lambda (_session id value)
                           (setq response (list id value)))))
                (with-current-buffer buffer
                  (pichat-chat--maybe-start-next-ui-request session))
                (should callback)
                (apply callback callback-args))
              (should (= 1 prompts))
              (should (= 1 executions))
              (should (equal "bridge-tool" (car response)))
              (should (string-match-p "mutated:yes" (cadr response)))
              (with-current-buffer buffer
                (should (zerop pichat-chat--pending-ui-count))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (buffer-live-p other) (kill-buffer other)))))))

(ert-deftest pichat-stored-bridge-deny-remains-immediate-in-background ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-approval-file
      (let ((pichat-chat-stop-session-on-kill nil)
            (other (generate-new-buffer " *pichat-tool-deny-target*"))
            buffer response
            (raw '(:id "bridge-deny" :method "editor"
                   :title "__pichat_tool_call__"
                   :prefill "{\"name\":\"pichat-test-denied-tool\",\"params\":{}}")))
        (pichat-define-tool pichat-test-denied-tool
            (:label "Denied mutation" :description "Never execute"
             :mutating t)
          (ert-fail "Denied tool must not execute"))
        (pichat-test-select-emacs-tools session "pichat-test-denied-tool")
        (setq pichat-approval-rules '(("pichat-test-denied-tool" . deny)))
        (pichat-approval-save)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (switch-to-buffer other)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _args)
                           (ert-fail "Stored deny must not enter UI queue")))
                        ((symbol-function 'completing-read)
                         (lambda (&rest _args)
                           (ert-fail "Stored deny must not prompt")))
                        ((symbol-function 'pichat-rpc-extension-ui-value)
                         (lambda (_session id value)
                           (setq response (list id value)))))
                (with-current-buffer buffer
                  (pichat-chat--on-extension-ui-request
                   session 'extension-ui-request (list :raw raw))
                  (should (zerop pichat-chat--pending-ui-count))))
              (should (equal "bridge-deny" (car response)))
              (should (string-match-p "Denied by user" (cadr response))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (buffer-live-p other) (kill-buffer other)))))))

(ert-deftest pichat-bridge-result-encoding-error-replies-instead-of-hanging ()
  (pichat-test-with-unit-session (session proc)
    (let ((executions 0) response)
      (pichat-define-tool pichat-test-bad-result ()
        (cl-incf executions)
        ;; Undecodable bytes cannot be encoded; this used to leave the
        ;; dialog pending.
        (unibyte-string #xff #xfe))
      (pichat-test-select-emacs-tools session "pichat-test-bad-result")
      (cl-letf (((symbol-function 'pichat-rpc-extension-ui-value)
                 (lambda (_session id value) (setq response (list id value)))))
        (should (pichat-bridge-transport-handle
                 session '(:id "bad-result" :method "editor" :title "__pichat_tool_call__"
                           :prefill "{\"name\":\"pichat-test-bad-result\",\"params\":{}}"))))
      (should (= executions 1))
      (should (equal "bad-result" (car response)))
      (let ((reply (json-parse-string (cadr response) :object-type 'plist :array-type 'list)))
        (should (plist-get reply :isError))
        (should (string-match-p "Emacs tool reply failed"
                                (plist-get (car (plist-get reply :content)) :text)))))))

(ert-deftest pichat-approval-policy-save-atomically-replaces-valid-policy ()
  (pichat-test-with-clean-state
    (pichat-test-with-approval-file
      (setq pichat-approval-rules '(("tool" . deny)))
      (pichat-approval-save)
      (let ((real-rename (symbol-function 'rename-file))
            observed-old observed-new)
        (setq pichat-approval-rules '(("tool" . allow)))
        (cl-letf (((symbol-function 'rename-file)
                   (lambda (source destination &optional ok-if-already-exists)
                     (setq observed-old
                           (with-temp-buffer
                             (insert-file-contents destination)
                             (read (current-buffer)))
                           observed-new
                           (with-temp-buffer
                             (insert-file-contents source)
                             (read (current-buffer))))
                     (funcall real-rename source destination ok-if-already-exists))))
          (pichat-approval-save))
        (should (equal '(("tool" . deny)) observed-old))
        (should (equal '(("tool" . allow)) observed-new))
        (setq pichat-approval-rules nil)
        (pichat-approval-load)
        (should (equal '(("tool" . allow)) pichat-approval-rules))
        (should (= #o600 (logand #o777 (file-modes pichat-approval-policy-file))))))))

(provide 'pichat-test-approval-tools)
;;; pichat-test-approval-tools.el ends here
