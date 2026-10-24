;;; pichat-test-lifecycle.el --- Pichat Test Lifecycle -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-reconfigure-preset-label-commits-and-rolls-back-with-configuration ()
  (dolist (empty '(nil t))
    (dolist (fail '(nil t))
      (with-temp-buffer
        (let* ((session (pichat-session-make
                         :preset-name 'manual :preset-spec '(:name manual)))
               (operation (list :session session :chat (current-buffer)
                                :empty-unwritten empty
                                :previous '(:preset-spec (:name manual))
                                :active-configuration '(:preset-spec (:name coding))))
               (commit (lambda (&rest _)
                         (should (eq 'coding (pichat-session-preset-name session)))
                         (let ((pichat-chat-session session))
                           (should (string-match-p "P:coding"
                                                   (pichat-chat--mode-line-status))))
                         (when fail (error "Injected commit failure"))))
               finished)
          (cl-letf (((symbol-function 'pichat-reconfigure--verify-idle-state) #'ignore)
                    ((symbol-function 'pichat-reconfigure-settings-mismatches) #'ignore)
                    ((symbol-function 'pichat-reconfigure-validate-empty-replacement) #'ignore)
                    ((symbol-function 'pichat-reconfigure-validate-reload) #'ignore)
                    ((symbol-function 'pichat-reconfigure--send)
                     (lambda (_op _phase _command _args callback)
                       (funcall callback nil)))
                    ((symbol-function 'pichat-chat-commit-staged-restart) commit)
                    ((symbol-function 'pichat-chat-commit-staged-empty-restart) commit)
                    ((symbol-function 'pichat-reconfigure--finish)
                     (lambda (&rest _) (setq finished t))))
            (if fail
                (should-error (pichat-reconfigure--synchronize operation nil))
              (pichat-reconfigure--synchronize operation nil))
            (should (eq finished (not fail)))
            (should (eq (pichat-session-preset-name session)
                        (if fail 'manual 'coding)))
            (should (eq (plist-get (pichat-session-preset-spec session) :name)
                        (pichat-session-preset-name session)))))))))

(ert-deftest pichat-reconfigure-tools-use-captured-preset-not-changed-registry ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'test-snapshot :tools '("read" "edit"))
    (let* ((spec (pichat-presets-resolve 'test-snapshot))
           (session (pichat-session-make
                     :preset-name 'test-snapshot :preset-spec spec
                     :tool-selection (pichat-tool-selection-resolve spec)))
           (captured (pichat-reconfigure-captured-configuration session)))
      (pichat-make-preset 'test-snapshot :tools '("read" "bash"))
      (let ((tools-only
             (pichat-reconfigure-select-tools
              captured '(:builtins ("read") :mcp nil)))
            (explicit (pichat-reconfigure-select-preset captured 'test-snapshot)))
        (should (equal '("read" "edit")
                       (plist-get (plist-get tools-only :preset-spec) :tools)))
        (should (equal '("read" "bash")
                       (plist-get (plist-get explicit :preset-spec) :tools)))
        (should (pichat-reconfigure-effective-change-p captured tools-only))
        (should (pichat-reconfigure-effective-change-p captured explicit)))
      (setf (pichat-session-preset-spec session)
            '(:name changed :tools ("bash")))
      (should (equal '("read" "edit")
                     (plist-get (plist-get captured :preset-spec) :tools))))))

(ert-deftest pichat-reconfigure-removed-preset-can-be-retained-but-not-reselected ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'test-removed :tools '("read"))
    (let* ((spec (pichat-presets-resolve 'test-removed))
           (session (pichat-session-make
                     :preset-name 'test-removed :preset-spec spec
                     :tool-selection (pichat-tool-selection-resolve spec)))
           (captured (pichat-reconfigure-captured-configuration session)))
      (setq pichat-presets (assq-delete-all 'test-removed pichat-presets))
      (should-not (pichat-reconfigure-effective-change-p captured captured))
      (should (equal '("read")
                     (plist-get (plist-get
                                 (pichat-reconfigure-select-tools
                                  captured '(:builtins ("read")))
                                 :preset-spec) :tools)))
      (should-error (pichat-reconfigure-select-preset captured 'test-removed)
                    :type 'user-error))))

(ert-deftest pichat-reconfigure-equivalent-preset-does-not-trigger-restart ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (pichat-make-preset 'test-same-a :tools '("read")
      :append-system-prompt "same")
    (pichat-make-preset 'test-same-b :tools '("read")
      :append-system-prompt "same")
    (let* ((spec (pichat-presets-resolve 'test-same-a))
           (session (pichat-session-make
                     :preset-name 'test-same-a :preset-spec spec
                     :tool-selection (pichat-tool-selection-resolve spec)))
           (captured (pichat-reconfigure-captured-configuration session))
           (selected (pichat-reconfigure-select-preset captured 'test-same-b)))
      (should-not (pichat-reconfigure-effective-change-p captured selected))
      (pichat-make-preset 'test-same-b :tools '("read")
        :append-system-prompt "different")
      (should (pichat-reconfigure-effective-change-p
               captured (pichat-reconfigure-select-preset captured 'test-same-b))))))

(ert-deftest pichat-reconfigure-preferred-lookup-does-not-create-during-restart ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat--sessions-by-id (make-hash-table :test #'equal))
          (pichat--session-order nil)
          (pichat--sessions-by-scope (make-hash-table :test #'equal))
          (scope '("project|local|/tmp/restarting/" "/tmp/restarting/" "test"))
          (started 0))
      (pichat-register-session session scope)
      (setf (pichat-session-restart-operation session)
            (list :token (make-symbol "restart") :phase 'stopping))
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (&rest _) (cl-incf started))))
        (should-error (pichat--preferred-session-for-exact-scope scope)
                      :type 'user-error)
        (should (= started 0)))
      (setf (pichat-session-restart-operation session)
            (list :token (make-symbol "restart") :phase 'failed))
      (should-not (pichat--restarting-runtime-for-scope (car scope))))))

(ert-deftest pichat-chat-restart-staging-retains-snapshot-until-verified-commit ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (fixture (pichat-test-read-json-fixture "canonical-session.json"))
           (data (list :entries (plist-get fixture :entries)
                       :leafId (plist-get fixture :leafId)))
           buffer)
      (setf (pichat-session-id session) (plist-get fixture :sessionId)
            (pichat-session-session-file session) (plist-get fixture :sessionFile)
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--apply-sync-response (list :data data) t nil)
              (pichat-chat--set-input-text "unsent draft")
              (let ((retained pichat-chat--entry-cache)
                    (compose-token (pichat-chat--compose-source-token))
                    (generation pichat-chat--source-generation))
                (pichat-chat-stage-restart session)
                (should-not (pichat-chat-canonical-entry-cache session))
                (pichat-emit session 'agent-start
                             :raw '(:type "agent_start"))
                (pichat-emit session 'turn-end
                             :raw '(:type "turn_end"))
                (should (eq retained pichat-chat--entry-cache))
                (pichat-chat--on-session-rebinding session nil nil)
                (pichat-chat--on-state-changed session nil nil)
                (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                           (lambda (&rest _) (ert-fail "Staged restart must not repaint"))))
                  (pichat-chat-repaint))
                (should (eq retained pichat-chat--entry-cache))
                (should (= generation pichat-chat--source-generation))
                (should (pichat-chat--compose-source-valid-p compose-token))
                (should (string-match-p "Final persisted answer"
                                        (buffer-string)))
                (should (equal "unsent draft" (pichat-chat--input-text)))
                (should-error
                 (pichat-chat-commit-staged-restart
                  session (pichat-entry-cache-empty "other" "/tmp/other.jsonl"))
                 :type 'user-error)
                (should (eq retained pichat-chat--entry-cache))
                (cl-letf (((symbol-function 'pichat-render-canonical)
                           (lambda (&rest _) (error "render failure"))))
                  (should-error
                   (pichat-chat-commit-staged-restart session retained)))
                (should (eq retained pichat-chat--entry-cache))
                (should pichat-chat--restart-staging)
                (pichat-chat-commit-staged-restart
                 session (pichat-pi-entry-cache-full
                          (plist-get fixture :sessionId)
                          (plist-get fixture :sessionFile)
                          (plist-get fixture :entries) (plist-get fixture :leafId)))
                (should-not pichat-chat--restart-staging)
                (should-not pichat-chat--source-rebinding-p)
                (should (pichat-chat--compose-source-valid-p compose-token))
                (should (equal "unsent draft" (pichat-chat--input-text))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-empty-restart-projection-failure-retains-snapshot-and-draft ()
  (pichat-test-with-unit-session (session proc)
    (let* ((pichat-chat-stop-session-on-kill nil)
           (pichat-chat-render-markdown nil)
           (old '(:type "model_change" :id "old-model" :parentId nil))
           (new '(:type "model_change" :id "new-model" :parentId nil))
           (old-file "/tmp/pichat-empty-before.jsonl")
           (new-file "/tmp/pichat-empty-after.jsonl")
           buffer compose)
      (setf (pichat-session-id session) "old-empty"
            (pichat-session-session-file session) old-file
            (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--apply-sync-response
               (list :data (list :entries (list old) :leafId "old-model")) t nil)
              (pichat-chat--set-input-text "retained draft")
              (setq compose
                    (pichat-chat-navigation-open-compose
                     buffer #'pichat-chat--replace-from-compose
                     "compose draft" 0 (pichat-chat--compose-source-token)
                     #'pichat-chat--compose-source-valid-p))
              (pichat-chat-stage-restart session))
            (setf (pichat-session-id session) "new-empty"
                  (pichat-session-session-file session) new-file)
            (let ((cache (pichat-pi-entry-cache-full
                          "new-empty" new-file (list new) "new-model")))
              (with-current-buffer buffer
                (let ((retained pichat-chat--entry-cache)
                      (generation pichat-chat--source-generation))
                  (cl-letf (((symbol-function 'pichat-render-canonical)
                             (lambda (&rest _) (error "injected render failure"))))
                    (should-error
                     (pichat-chat-commit-staged-empty-restart session cache)))
                  (should (eq retained pichat-chat--entry-cache))
                  (should pichat-chat--restart-staging)
                  (should (= generation pichat-chat--source-generation))
                  (should (equal "retained draft" (pichat-chat--input-text)))
                  (pichat-chat-commit-staged-empty-restart session cache)
                  (should-not pichat-chat--restart-staging)
                  (should (= (1+ generation) pichat-chat--source-generation))
                  (should (equal "retained draft" (pichat-chat--input-text)))
                  (should (pichat-chat--compose-source-valid-p
                           (buffer-local-value
                            'pichat-chat-compose-target-token compose)))))))
        (when (buffer-live-p compose) (kill-buffer compose))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-transaction-preflight-blocks-before-stop ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer result)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-reconfigure-request-preflight)
                       (lambda (_origin callback)
                         (funcall callback '("Pi is busy") nil)))
                      ((symbol-function 'pichat-rpc-stop)
                       (lambda (&rest _) (ert-fail "Preflight stopped Pi"))))
              (pichat-reconfigure-restart
               (pichat-reconfigure-capture-origin session)
               '(:preset-spec (:name coding))
               (lambda (success reason) (setq result (list success reason)))))
            (should (equal '(nil "Pi is busy") result))
            (should-not (pichat-session-restart-operation session))
            (should (eq proc (pichat-session-process session)))
            (should (process-live-p proc)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-bridge-handshake-is-owned-but-tools-are-denied ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-rpc--dispatch-process proc)
          (token (make-symbol "restart"))
          replies)
      (setf (pichat-session-restart-operation session)
            (list :token token :phase 'loading))
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (_proc line) (push (pichat-rpc--json-decode line) replies)))
                ((symbol-function 'pichat-tool-bridge-execute-json)
                 (lambda (&rest _) (ert-fail "Restart executed an Emacs tool"))))
        (should (pichat-bridge-transport-handle
                 session (list :id "handshake" :title
                               pichat-bridge-transport-handshake-title)))
        (should (pichat-bridge-transport-handle
                 session (list :id "tool" :title
                               pichat-bridge-transport-tool-call-title
                               :prefill "{}")))
        (should (= 2 (length replies)))
        (should (equal "tool" (plist-get (car replies) :id)))
        (should (plist-get (pichat-rpc--json-decode
                            (plist-get (car replies) :value)) :isError))))))

(ert-deftest pichat-reconfigure-external-stop-retires-operation-before-shutdown ()
  (pichat-test-with-unit-session (session proc)
    (let ((operation (list :token (make-symbol "restart") :phase 'loading
                           :requested '(:preset coding))))
      (setf (pichat-session-restart-operation session) operation)
      (pichat-stop-session session)
      (should-not (eq operation (pichat-session-restart-operation session)))
      (should (eq 'failed (plist-get (pichat-session-restart-operation session)
                                   :phase)))
      (should (equal '(:preset coding)
                     (plist-get (pichat-session-restart-operation session)
                                :requested)))
      (should-not (process-live-p proc)))))

(ert-deftest pichat-reconfigure-killed-chat-cancels-restart-even-without-stop-on-kill ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (operation (list :token (make-symbol "restart") :phase 'starting))
          buffer)
      (setq buffer (pichat-chat-open session))
      (setf (pichat-session-restart-operation session) operation)
      (kill-buffer buffer)
      (should-not (eq operation (pichat-session-restart-operation session)))
      (should (eq 'failed (plist-get (pichat-session-restart-operation session)
                                   :phase)))
      (should-not (process-live-p proc)))))

(ert-deftest pichat-reconfigure-shutdown-waits-for-exit-and-sentinel ()
  (pichat-test-with-unit-session (session proc)
    (let ((operation (list :token (make-symbol "restart") :phase 'stopping))
          (pichat-reconfigure-shutdown-timeout 0.2)
          result)
      (setf (pichat-session-restart-operation session) operation)
      (pichat-reconfigure-stop-and-wait
       session operation (lambda (success reason)
                           (push (list success reason) result)))
      (pichat-test-wait-until (lambda () result) 2 "local shutdown barrier")
      (should (equal '((t nil)) result))
      (should-not (process-live-p proc))
      (should (eq 'stopped (pichat-session-state session))))))

(ert-deftest pichat-reconfigure-shutdown-times-out-without-confirmed-exit ()
  (pichat-test-with-unit-session (session proc)
    (let ((operation (list :token (make-symbol "restart") :phase 'stopping))
          (pichat-reconfigure-shutdown-timeout 0.02)
          result)
      (setf (pichat-session-restart-operation session) operation)
      (cl-letf (((symbol-function 'pichat-rpc-stop) #'ignore))
        (pichat-reconfigure-stop-and-wait
         session operation (lambda (success reason)
                             (setq result (list success reason))))
        (pichat-test-wait-until (lambda () result) 2 "local shutdown timeout")
        (should-not (car result))
        (should (string-match-p "Timed out confirming" (cadr result)))
        (should (process-live-p proc))))))

(ert-deftest pichat-reconfigure-stop-then-start-ignores-retired-callback ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer stop-callback started)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((operation (list :session session :chat buffer :phase 'stopping)))
              (setf (pichat-session-restart-operation session) operation)
              (cl-letf (((symbol-function 'pichat-reconfigure-stop-and-wait)
                         (lambda (_session _operation callback)
                           (setq stop-callback callback)))
                        ((symbol-function 'pichat-reconfigure--start-replacement)
                         (lambda (_operation) (setq started t))))
                (pichat-reconfigure--stop-then-start operation)
                (should stop-callback)
                (pichat-reconfigure-cancel-operation session "cancelled")
                (funcall stop-callback t nil)
                (should-not started)
                (should (process-live-p proc)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-stop-then-start-reports-synchronous-shutdown-error ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer result)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((operation (list :session session :chat buffer :phase 'stopping)))
              (setf (pichat-session-restart-operation session) operation)
              (cl-letf (((symbol-function 'pichat-reconfigure-stop-and-wait)
                         (lambda (&rest _) (error "injected shutdown error")))
                        ((symbol-function 'pichat-reconfigure--finish)
                         (lambda (_operation success reason)
                           (setq result (list success reason)))))
                (pichat-reconfigure--stop-then-start operation)
                (should (equal result '(nil "injected shutdown error")))
                (should (process-live-p proc)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-command-is-validated-without-early-commit ()
  (pichat-test-with-unit-session (session proc)
    (let* ((old (pichat-presets-resolve 'manual))
           (new (pichat-presets-resolve 'coding))
           (tools (pichat-tool-selection-resolve new))
           (configuration (list :preset-spec new :tool-selection tools))
           (state '(:model (:provider "test-provider" :id "test-model")))
           (pichat-rpc-command nil)
           (pichat-pi-extra-args nil)
           (pichat-default-model nil))
      (setf (pichat-session-preset-spec session) old
            (pichat-session-tool-selection session)
            (pichat-tool-selection-resolve old)
            (pichat-session-startup-model session) "old-model")
      (let ((command (pichat-reconfigure-validated-command
                      session configuration state)))
        (should (equal '("--model" "test-provider/test-model")
                       (last command 2)))
        (should (member "--append-system-prompt" command))
        (should (equal "old-model" (pichat-session-startup-model session)))
        (should (eq 'manual (plist-get (pichat-session-preset-spec session)
                                        :name))))
      (should-error
       (pichat-reconfigure-validated-command session configuration
                                              '(:model (:provider "test")))
       :type 'user-error))))

(ert-deftest pichat-reconfigure-settings-validation-detects-unknown-and-changed ()
  (let* ((expected '(:model (:provider "fake" :id "model" :contextWindow 100)
                    :thinkingLevel "medium" :steeringMode "all"
                    :followUpMode "one-at-a-time"
                    :autoCompactionEnabled nil))
         (actual '(:model (:provider "fake" :id "model" :contextWindow 200)
                   :thinkingLevel "medium" :steeringMode "all"
                   :followUpMode "one-at-a-time"
                   :autoCompactionEnabled nil)))
    (should-not (pichat-reconfigure-settings-mismatches expected actual))
    (should (equal '(:thinkingLevel :followUpMode)
                   (pichat-reconfigure-settings-mismatches
                    expected (list :model (plist-get actual :model)
                                   :thinkingLevel "high" :steeringMode "all"
                                   :autoCompactionEnabled nil))))
    (should (equal '(:autoCompactionEnabled)
                   (pichat-reconfigure-settings-mismatches
                    expected (plist-put (copy-sequence actual)
                                        :autoCompactionEnabled t))))))

(ert-deftest pichat-reconfigure-reload-validates-source-branch-and-full-entries ()
  (let* ((fixture (pichat-test-read-json-fixture "canonical-session.json"))
         (id (plist-get fixture :sessionId))
         (file (plist-get fixture :sessionFile))
         (entries (plist-get fixture :entries))
         (leaf (plist-get fixture :leafId))
         (retained (pichat-pi-entry-cache-full id file entries leaf))
         (origin (list :session-id id :session-file file))
         (state (list :sessionId id :sessionFile file))
         (response (list :entries entries :leafId leaf)))
    (let ((reloaded (pichat-reconfigure-validate-reload
                     origin retained state response)))
      (should (pichat-entry-cache-p reloaded))
      (should-not (eq retained reloaded)))
    (should-error (pichat-reconfigure-validate-reload
                   origin retained (plist-put (copy-sequence state)
                                              :sessionId "another") response)
                  :type 'user-error)
    (should-error (pichat-reconfigure-validate-reload
                   origin retained state
                   (list :entries entries :leafId "entry-abandoned"))
                  :type 'user-error)
    (let* ((modified (copy-tree entries t))
           (message (plist-get (car modified) :message))
           (content (car (plist-get message :content))))
      (plist-put content :text "modified by another writer")
      (should-error (pichat-reconfigure-validate-reload
                     origin retained state (list :entries modified :leafId leaf))
                    :type 'user-error))
    (should (equal (plist-get (plist-get
                              (gethash "entry-user"
                                       (pichat-entry-cache-entries-by-id retained))
                              :message) :content)
                   (plist-get (plist-get (car entries) :message) :content)))
    (should-error (pichat-reconfigure-validate-reload
                   origin retained state (list :entries entries))
                  :type 'user-error)))

(ert-deftest pichat-reconfigure-preflight-request-rechecks-origin-after-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((origin (pichat-reconfigure-capture-origin session))
          (pichat-reconfigure-preflight-timeout 2)
          state-callback result)
      (cl-letf (((symbol-function 'pichat-rpc-get-state)
                 (lambda (_session success _failure)
                   (setq state-callback success)
                   "request"))
                ((symbol-function 'pichat-reconfigure-preflight-blockers)
                 (lambda (_origin _state &optional _kind)
                   (ert-fail "Stale intent should not reach validation"))))
        (pichat-reconfigure-request-preflight
         origin (lambda (blockers _state) (setq result blockers)))
        (setf (pichat-session-id session) "changed")
        (funcall state-callback '(:data (:sessionId "changed")) session)
        (should (member "The originating runtime, process, or conversation changed"
                        result))))))

(ert-deftest pichat-reconfigure-preflight-request-reports-fresh-state-once ()
  (pichat-test-with-unit-session (session proc)
    (let ((origin (pichat-reconfigure-capture-origin session))
          (pichat-reconfigure-preflight-timeout 2)
          success failure received)
      (cl-letf (((symbol-function 'pichat-rpc-get-state)
                 (lambda (_session callback error-callback)
                   (setq success callback failure error-callback)
                   "request"))
                ((symbol-function 'pichat-reconfigure-preflight-blockers)
                 (lambda (_origin state &optional _kind)
                   (should (equal state '(:sessionId "source"))) nil)))
        (pichat-reconfigure-request-preflight
         origin (lambda (blockers state)
                  (push (list blockers state) received)))
        (funcall success '(:data (:sessionId "source")) session)
        (funcall failure '(:error "late failure") session)
        (should (equal received
                       '((nil (:state (:sessionId "source")
                               :source-kind saved)))))))))

(ert-deftest pichat-reconfigure-preflight-source-kind-is-not-taken-from-pi-state ()
  (pichat-test-with-unit-session (session proc)
    (let ((origin (pichat-reconfigure-capture-origin session)) result)
      (cl-letf (((symbol-function 'pichat-rpc-get-state)
                 (lambda (_session callback _failure)
                   (funcall callback
                            '(:data (:sessionId "source"
                                     :pichat-empty-unwritten t)) session)))
                ((symbol-function 'pichat-reconfigure-preflight-blockers)
                 (lambda (_origin _state kind)
                   (should (eq kind 'saved)) nil)))
        (pichat-reconfigure-request-preflight
         origin (lambda (_blockers data) (setq result data)))
        (should (eq (plist-get result :source-kind) 'saved))
        (should (plist-get (plist-get result :state)
                           :pichat-empty-unwritten))))))

(ert-deftest pichat-reconfigure-preflight-request-times-out-without-stopping ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-reconfigure-preflight-timeout 0.01)
          (origin (pichat-reconfigure-capture-origin session))
          cancelled result)
      (cl-letf (((symbol-function 'pichat-rpc-get-state)
                 (lambda (&rest _) "pending-request"))
                ((symbol-function 'pichat-rpc-cancel-request)
                 (lambda (_session id) (setq cancelled id))))
        (pichat-reconfigure-request-preflight
         origin (lambda (blockers _state) (setq result blockers)))
        (pichat-test-wait-until (lambda () result) 2 "preflight timeout")
        (should (equal cancelled "pending-request"))
        (should (member "Timed out waiting for Pi state; the runtime was not stopped"
                        result))
        (should (eq (pichat-session-process session) proc))
        (should (process-live-p proc))))))

(ert-deftest pichat-reconfigure-preflight-rejects-stale-process-and-source ()
  (pichat-test-with-unit-session (session proc)
    (let ((origin (pichat-reconfigure-capture-origin session)))
      (should (pichat-reconfigure-origin-current-p origin))
      (setf (pichat-session-process-generation session) 2)
      (should-not (pichat-reconfigure-origin-current-p origin))
      (should (member "The originating runtime, process, or conversation changed"
                      (pichat-reconfigure-preflight-blockers origin nil)))
      (setf (pichat-session-process-generation session) nil
            (pichat-session-id session) "other")
      (should-not (pichat-reconfigure-origin-current-p origin)))))

(ert-deftest pichat-reconfigure-ssh-shutdown-gate-rejects-before-stop ()
  (pichat-test-with-unit-session (session proc)
    (let* ((remote (pichat-transport--create :id 'test-ssh :kind 'ssh
                                              :label "test"))
           (origin (pichat-reconfigure-capture-origin session))
           (operation (list :token (make-symbol "restart") :phase 'stopping)))
      (setf (pichat-session-transport session) remote
            (pichat-session-restart-operation session) operation)
      (should (member "Remote Pi shutdown cannot yet be confirmed; restart is unavailable on SSH"
                      (pichat-reconfigure-preflight-blockers origin nil)))
      (should-error
       (pichat-reconfigure-stop-and-wait session operation #'ignore)
       :type 'user-error)
      (should (process-live-p proc)))))

(ert-deftest pichat-reconfigure-preflight-requires-authoritative-idle-settings-and-file ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-temp-dir dir
      (let* ((file (expand-file-name "conversation.jsonl" dir))
             (pichat-rpc-command nil)
             (state (list :sessionId "source" :sessionFile file
                          :isStreaming nil :isCompacting nil
                          :pendingMessageCount 0
                          :model '(:provider "fake" :id "model")
                          :thinkingLevel "medium"
                          :steeringMode "all" :followUpMode "one-at-a-time"
                          :autoCompactionEnabled nil)))
        (write-region "{}\n" nil file nil 'silent)
        (setf (pichat-session-state session) 'idle
              (pichat-session-id session) "source"
              (pichat-session-session-file session) file)
        (let ((origin (pichat-reconfigure-capture-origin session)))
          (cl-letf (((symbol-function 'pichat-reconfigure--chat-blockers)
                     (lambda (_session) nil)))
            (should-not (pichat-reconfigure-preflight-blockers origin state))
            (should (member "Pi is busy or its pending-message count is unknown"
                            (pichat-reconfigure-preflight-blockers
                             origin (plist-put (copy-sequence state)
                                               :pendingMessageCount 1))))
            (should (member "Pi did not supply all settings required for safe restoration"
                            (pichat-reconfigure-preflight-blockers
                             origin (cl-loop for (key value) on state by #'cddr
                                             unless (eq key :steeringMode)
                                             append (list key value)))))
            (delete-file file)
            (should (member "The saved conversation file is inaccessible on the runtime target"
                            (pichat-reconfigure-preflight-blockers origin state)))))))))

(ert-deftest pichat-reconfigure-unwritten-preflight-requires-authoritative-metadata-only ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-temp-dir dir
      (let* ((pichat-chat-stop-session-on-kill nil)
             (pichat-chat-render-markdown nil)
             (pichat-rpc-command nil)
             (file (expand-file-name "not-yet-written.jsonl" dir))
             (model-entry '(:type "model_change" :id "model" :parentId nil
                                  :provider "fake" :modelId "model"))
             (state (list :sessionId "empty-source" :sessionFile file
                          :isStreaming nil :isCompacting nil :pendingMessageCount 0
                          :model '(:provider "fake" :id "model")
                          :thinkingLevel "off" :steeringMode "all"
                          :followUpMode "one-at-a-time"
                          :autoCompactionEnabled nil))
             (entries (list :entries (list model-entry) :leafId "model"))
             buffer result)
        (setf (pichat-session-id session) "empty-source"
              (pichat-session-session-file session) file
              (pichat-session-persistence session) 'persistent
              (pichat-session-state session) 'idle)
        (unwind-protect
            (progn
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-chat--apply-sync-response (list :data entries) t nil))
              (let ((origin (pichat-reconfigure-capture-origin session)))
                (cl-letf (((symbol-function 'pichat-rpc-get-state)
                           (lambda (_session callback _failure)
                             (funcall callback (list :data state) session)))
                          ((symbol-function 'pichat-rpc-get-entries)
                           (lambda (_session _since callback _failure)
                             (funcall callback (list :data entries) session))))
                  (pichat-reconfigure-request-preflight
                   origin (lambda (blockers fresh)
                            (setq result (list blockers fresh))))
                  (should-not (car result))
                  (should (eq 'unwritten
                              (plist-get (cadr result) :source-kind)))
                  (should (equal state (plist-get (cadr result) :state)))
                  (should (process-live-p proc))
                  (let (raced)
                    (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                               (lambda (_session _since callback _failure)
                                 (write-region "{}\n" nil file nil 'silent)
                                 (funcall callback (list :data entries) session))))
                      (pichat-reconfigure-request-preflight
                       origin (lambda (blockers _result)
                                (setq raced blockers))))
                    (should (member
                             "The unwritten Pi session is not empty or changed during preflight"
                             raced))
                    (should (process-live-p proc))
                    (delete-file file))
                  (setq entries
                        (list :entries (list model-entry
                                             '(:type "message" :id "user"
                                                     :parentId "model"
                                                     :message (:role "user")))
                              :leafId "user")
                        result nil)
                  (pichat-reconfigure-request-preflight
                   origin (lambda (blockers _fresh) (setq result blockers)))
                  (should (member
                           "The unwritten Pi session is not empty or changed during preflight"
                           result))
                  (should (process-live-p proc)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-reconfigure-startup-metadata-policy-is-shared-by-cache-and-rpc ()
  (let* ((model '(:type "model_change" :id "model" :parentId nil))
         (thinking '(:type "thinking_level_change" :id "thinking"
                            :parentId "model"))
         (entries (list model thinking))
         (cache (pichat-pi-entry-cache-full
                 "source" "/tmp/source.jsonl" entries "thinking")))
    (should (pichat-pi-startup-metadata-only-p entries "thinking"))
    (should (pichat-pi-entry-cache-startup-metadata-only-p cache))
    (should (pichat-pi-entry-cache-startup-metadata-only-p
             (pichat-pi-entry-cache-full "source" "/tmp/source.jsonl" nil nil)))
    (should-not (pichat-pi-startup-metadata-only-p entries "model"))
    (should-not (pichat-pi-startup-metadata-only-p
                 (append entries (list '(:type "custom" :id "ext"))) "ext"))
    (should-not (pichat-pi-entry-cache-startup-metadata-only-p
                 (pichat-pi-entry-cache-full
                  "source" "/tmp/source.jsonl" entries "model")))))

(ert-deftest pichat-reconfigure-validate-empty-replacement-rejects-old-or-nonempty ()
  (let ((origin '(:session-id "old" :session-file "/tmp/old.jsonl"))
        (state '(:sessionId "new" :sessionFile "/tmp/new.jsonl"))
        (entries '(:entries nil :leafId nil)))
    (should (pichat-entry-cache-p
             (pichat-reconfigure-validate-empty-replacement
              origin state entries)))
    (should-error
     (pichat-reconfigure-validate-empty-replacement
      origin '(:sessionId "old" :sessionFile "/tmp/new.jsonl") entries)
     :type 'user-error)
    (should-error
     (pichat-reconfigure-validate-empty-replacement
      origin state
      '(:entries ((:type "custom" :id "extension" :parentId nil))
                 :leafId "extension"))
     :type 'user-error)))

(ert-deftest pichat-reconfigure-preflight-blocks-unreloadable-historical-leaf ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-chat-canonical-entry-cache)
                       (lambda (_session)
                         (pichat-entry-cache-create
                          :leaf-id "historical" :last-seen-id "latest"))))
              (should (member "The active branch cannot be restored by Pi RPC after reload"
                              (pichat-reconfigure--chat-blockers session)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-preflight-blocks-pending-submission-without-losing-draft ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-input-text "unsent draft")
              (puthash "prompt" '(:text "sent")
                       pichat-chat--pending-submissions))
            (should (member "A prompt submission is pending or in flight"
                            (pichat-reconfigure--chat-blockers session)))
            (with-current-buffer buffer
              (should (equal "unsent draft" (pichat-chat--input-text)))
              (should (gethash "prompt" pichat-chat--pending-submissions))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-idle-custom-message-and-compaction-trigger-sync ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session &optional since _callback _error)
                         (push (and (not (functionp since)) since) calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"visible-note\",\"content\":\"idle update\",\"display\":true}}\n")
              (should (= 1 (length calls)))
              (with-current-buffer buffer
                (setq pichat-chat--sync-in-flight nil))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (should (= 2 (length calls))))
            (with-current-buffer buffer
              (should (equal '(nil nil) calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-live-draft-preserves-successful-compaction-preview ()
  (let ((draft (pichat-live-draft-empty 0)))
    (pichat-pi-live-draft-apply
     draft
     '(:type "compaction_end"
       :result (:summary "bounded summary" :tokensBefore 42)))
    (let ((node (car (pichat-live-draft-nodes draft))))
      (should (eq 'activity (pichat-transcript-node-kind node)))
      (should (= 42 (pichat-transcript-node-tokens-before node)))
      (should (equal "bounded summary"
                     (pichat-transcript-node-summary node))))))

(ert-deftest pichat-chat-abort-restores-cleared-queue-before-current-draft ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          clear-callback abort-args buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-chat--set-input-text "current draft")
              (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
                         (lambda (_session callback &optional _error-callback)
                           (setq clear-callback callback)))
                        ((symbol-function 'pichat-backend-abort-session)
                         (lambda (&rest args) (setq abort-args args))))
                (pichat-chat-abort)
                (should clear-callback)
                (should-not abort-args)
                (funcall clear-callback
                         '(:success t
                           :data (:steering ("steer one" "steer two")
                                  :followUp ("follow later")))
                         session))
              (should (equal "steer one\n\nsteer two\n\nfollow later\n\ncurrent draft"
                             (pichat-chat--input-text)))
              (should (equal (list session nil) abort-args))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-abort-falls-back-when-clear-queue-is-unsupported ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          clear-error-callback abort-args buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (cl-letf (((symbol-function 'pichat-backend-clear-session-queue)
                         (lambda (_session _callback &optional error-callback)
                           (setq clear-error-callback error-callback)))
                        ((symbol-function 'pichat-backend-abort-session)
                         (lambda (&rest args) (setq abort-args args))))
                (pichat-chat-abort)
                (funcall clear-error-callback '(:success nil) session))
              (should (equal (list session nil) abort-args))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-aborted-compaction-does-not-request-sync-or-stats ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (sync-calls 0) (stats-calls 0) buffer)
      (setf (pichat-session-state session) 'compacting)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf sync-calls)))
                      ((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (&rest _args) (cl-incf stats-calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":true}\n"))
            (should (= 0 sync-calls))
            (should (= 0 stats-calls))
            (should (eq 'idle (pichat-session-state session)))
            (should (string-match-p "compaction aborted"
                                    (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-failed-compaction-uses-error-message-without-refresh ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (sync-calls 0) (stats-calls 0) buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf sync-calls)))
                      ((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (&rest _args) (cl-incf stats-calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false,\"errorMessage\":\"summary failed\"}\n"))
            (should (= 0 sync-calls))
            (should (= 0 stats-calls))
            (should (string-match-p "compaction failed: summary failed"
                                    (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-compaction-displays-unknown-context-usage ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          stats-callback buffer)
      (setf (pichat-session-context-usage session)
            '(:tokens 90 :contextWindow 100 :percent 90))
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional _error-callback)
                         (setq stats-callback callback)
                         "stats"))
                      ((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "entries")))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (should stats-callback)
              (pichat-session-apply-rpc-stats
               session '(:contextUsage
                         (:tokens nil :contextWindow 100 :percent nil)))
              (funcall stats-callback '(:success t) session))
            (with-current-buffer buffer
              (should (string-match-p
                       "?/100" (pichat-chat--mode-line-status)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-successful-compaction-covers-settlement-stats ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          stats-callback
          (stats-calls 0)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-session-stats)
                       (lambda (_session callback &optional _error-callback)
                         (cl-incf stats-calls)
                         (setq stats-callback callback)
                         "stats"))
                      ((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) "entries")))
              (pichat-rpc--process-filter proc "{\"type\":\"agent_start\"}\n")
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
              (funcall stats-callback '(:success t) session)
              (pichat-rpc--process-filter proc "{\"type\":\"agent_settled\"}\n")
              (should (= 1 stats-calls))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-idle-custom-sync-coalesces-one-settlement-follow-up ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          callbacks buffer)
      (setf (pichat-session-state session) 'idle)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (_session _since callback &optional _error)
                         (setq callbacks (append callbacks (list callback))))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"extension-visible\",\"display\":true,\"content\":\"persisted extension message\"}}\n")
              (should (= 1 (length callbacks)))
              (pichat-rpc--process-filter
               proc "{\"type\":\"agent_settled\"}\n")
              (should (= 1 (length callbacks)))
              (funcall (car callbacks)
                       '(:data (:entries nil :leafId nil)) session)
              (should (= 2 (length callbacks)))
              (funcall (cadr callbacks)
                       '(:data (:entries nil :leafId nil)) session)
              (with-current-buffer buffer
                (should-not pichat-chat--sync-in-flight)
                (should-not pichat-chat--sync-pending))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-running-custom-message-defers-to-settlement-sync ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          calls buffer)
      (setf (pichat-session-state session) 'running)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-rpc-get-entries)
                       (lambda (&rest _args) (cl-incf calls))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"custom\",\"customType\":\"visible-note\",\"content\":\"running update\",\"display\":true}}\n"))
            (should-not calls))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-lifecycle-notices-use-dedicated-status-region ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n")
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "compaction started")
              (let ((position (match-beginning 0)))
                (should (<= (marker-position pichat-chat--status-start)
                            position))
                (should (< position
                           (marker-position pichat-chat--status-end)))
                (should (get-text-property position 'pichat-status))
                (should-not (get-text-property position
                                               'pichat-node-key))))
            (pichat-rpc--process-filter
             proc "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
            (should-not (string-match-p "compaction started"
                                        (pichat-test-buffer-text buffer))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-compaction-and-retry-events-are-visible ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter proc
             "{\"type\":\"compaction_start\",\"reason\":\"manual\"}\n")
            (should (eq 'compacting (pichat-session-state session)))
            (should (string-match-p "compaction started"
                                    (pichat-test-buffer-text buffer)))
            (pichat-rpc--process-filter proc
             "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":false}\n")
            (pichat-rpc--process-filter proc
             "{\"type\":\"auto_retry_start\",\"attempt\":1,\"maxAttempts\":3,\"delayMs\":20,\"errorMessage\":\"busy\"}\n")
            (should (eq 'retrying (pichat-session-state session)))
            (with-current-buffer buffer
              (should (string-prefix-p "↻" (pichat-chat--mode-line-status))))
            (should (string-match-p "retry 1/3"
                                    (pichat-test-buffer-text buffer)))
            (pichat-rpc--process-filter proc
             "{\"type\":\"auto_retry_end\",\"success\":true,\"attempt\":1}\n")
            (should (eq 'idle (pichat-session-state session)))
            (let ((text (pichat-test-buffer-text buffer)))
              (should-not (string-match-p "compaction started" text))
              (should-not (string-match-p "retry 1/3" text))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-lifecycle)
;;; pichat-test-lifecycle.el ends here
