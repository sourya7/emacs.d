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
    (let* ((decoded (json-parse-string (pichat-tools-definitions-json)
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
                     (pichat-tools-execute-json "{\"name\":\"pichat-test-result\",\"params\":{}}")
                     :object-type 'plist
                     :array-type 'list
                     :false-object nil))
           (content (plist-get decoded :content)))
      (should (= 1 (length content)))
      (should (equal "tool output" (plist-get (car content) :text))))))

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
                                (pichat-tools-definitions-json)))
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
    (let* ((tools (plist-get (json-parse-string (pichat-tools-definitions-json)
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
