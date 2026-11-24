;;; pichat-test-ssh-boundaries.el --- SSH callback ordering regressions -*- lexical-binding: t; -*-

;; These scheduling fixtures use no SSH server, TRAMP implementation advice,
;; real Pi process, or remote fixture state.

(require 'pichat-test-support)
(require 'pichat-tool-picker)
(require 'pichat-reconfigure)
(require 'pichat-tool-runtime)
(require 'pichat-artifact-runner)
(require 'pichat-job-executor)
(require 'pichat-archive)
(require 'pichat-startup-cache)

(ert-deftest pichat-ssh-boundary-cache-cancel-and-independent-progress ()
  (let* ((target (pichat-test-ssh-boundary--target))
         (connection (pichat-transport--connection target))
         (peer (pichat-transport--create :kind 'ssh :tramp-prefix "/ssh:peer.invalid:"))
         calls deliveries cancel)
    (cl-letf (((symbol-function 'pichat-startup-cache--root) (lambda (_) "/cache"))
              ((symbol-function 'pichat-startup-cache--asset)
               (lambda (transport &rest _) (push transport calls) "/cached")))
      (unwind-protect
          (progn
            (let ((pichat-transport--active-connections (list connection)))
              (setq cancel
                    (pichat-startup-cache-acquire-when-idle
                     target "/helper" nil (lambda () t)
                     (lambda (&rest args) (push args deliveries))))
              (pichat-startup-cache-acquire-when-idle
               peer "/helper" nil (lambda () t)
               (lambda (&rest args) (push args deliveries)))
              (pichat-test-wait-until (lambda () deliveries) 1 "peer cache acquisition")
              (should (equal calls (list peer)))
              (should-error (pichat-startup-cache-acquire target "/helper"))
              (funcall cancel))
            (accept-process-output nil 0.09)
            (should (equal calls (list peer)))
            (should (= 1 (length deliveries))))
        (when cancel (funcall cancel))))))

(ert-deftest pichat-ssh-boundary-cache-rechecks-ownership-after-reentrant-io ()
  (let ((target (pichat-test-ssh-boundary--target))
        (owned t) outer-delivered queued-delivered cancel)
    (cl-letf (((symbol-function 'pichat-startup-cache--root) (lambda (_) "/cache"))
              ((symbol-function 'pichat-startup-cache--asset)
               (lambda (transport _root _kind source _name)
                 (should (pichat-transport-busy-p transport))
                 (when (equal source "/first")
                   (setq owned nil)
                   (pichat-startup-cache-acquire-when-idle
                    transport "/next" nil (lambda () t)
                    (lambda (assets err)
                      (should-not err)
                      (setq queued-delivered assets)))
                   (accept-process-output nil 0.07)
                   (should-not queued-delivered))
                 "/cached")))
      (unwind-protect
          (progn
            (setq cancel
                  (pichat-startup-cache-acquire-when-idle
                   target "/first" nil (lambda () owned)
                   (lambda (&rest _) (setq outer-delivered t))))
            (pichat-test-wait-until (lambda () queued-delivered) 1 "same-connection cache handoff")
            (should-not outer-delivered))
        (when cancel (funcall cancel))))))

(ert-deftest pichat-ssh-boundary-archive-reset-keeps-busy-endpoint-owned ()
  "Reset retires remote endpoints on their own connection, not the UI target."
  (let* ((transport (pichat-test-ssh-boundary--target))
         (connection (pichat-transport--connection transport))
         (remote (make-pipe-process :name "archive-remote-fixture" :noquery t))
         (local (make-pipe-process :name "archive-local-fixture" :noquery t))
         (pichat-archive--processes (list remote local))
         (pichat-archive--capability-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          ;; Use the real acquisition wrapper to capture endpoint provenance.
          (should (eq remote
                      (pichat-test-ssh-boundary--during-setup
                       transport remote #'ignore)))
          (let ((pichat-transport--active-connections (list connection)))
            (pichat-archive-reset)
            (should-not pichat-archive--processes)
            (should-not (process-live-p local))
            (should (process-live-p remote))
            ;; Service timers while still busy; a plain zero-delay timer is
            ;; insufficient, and repeated reset must not lose endpoint ownership.
            (pichat-archive-reset)
            (accept-process-output nil 0.07)
            (should (process-live-p remote)))
          (pichat-test-wait-until
           (lambda () (not (process-live-p remote))) 1 "idle archive reset"))
      (dolist (process (list remote local))
        (when (process-live-p process) (delete-process process))))))

(defun pichat-test-ssh-boundary--target ()
  "Return an inert fixture identity, never to be contacted."
  (pichat-transport--create :id 'fixture :kind 'ssh
                            :tramp-prefix "/ssh:fixture.invalid:"
                            :mappings '(("/ssh:fixture.invalid:/project/" . "/project/"))))

(defun pichat-test-ssh-boundary--during-setup (transport process callback)
  "Run CALLBACK during simulated TRANSPORT setup and return fake PROCESS.
Keep the real transport entry point so any ownership it provides is exercised."
  (let ((make (symbol-function 'make-process)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (if (equal (plist-get args :name) "pichat-fixture-setup")
                     (progn (funcall callback) process)
                   (apply make args)))))
      (pichat-transport-make-process
       transport "/project/" :name "pichat-fixture-setup" :command '("unused")))))

(defun pichat-test-ssh-boundary--picker (action)
  "Exercise ACTION with MCP completion and helper staging at a controlled seam."
  (ert-info ((format "Picker action: %s" action))
      (let* ((transport (pichat-test-ssh-boundary--target))
             (pichat-tool-picker--state nil)
             (pichat-pi-default-args nil)
             (complete-mcp nil)
             (proc nil)
             (staging nil)
             (in-sentinel nil)
             copy-overlapped staged)
        (cl-labels
            ((complete ()
               (when complete-mcp
                 (let ((callback complete-mcp))
                   (setq complete-mcp nil in-sentinel t)
                   (unwind-protect
                       (progn
                         (funcall callback)
                         ;; Model the stderr handler's tail, after PiChat's
                         ;; sentinel and any completion callback have returned.
                         (when staging (setq copy-overlapped 'stderr-teardown)))
                     (setq in-sentinel nil)))))
             (open-picker ()
               (pichat-tool-picker-open
                '(:name "fixture" :tools ("read")) nil
                "/ssh:fixture.invalid:/project/" transport "pi" #'ignore)))
          (cl-letf (((symbol-function 'transient-setup) #'ignore)
                    ((symbol-function 'pichat-tool-picker--refresh-display) #'ignore)
                    ((symbol-function 'pichat-tool-picker--refresh-children) #'ignore)
                    ((symbol-function 'pichat-transport-make-process)
                     (lambda (_target _cwd &rest args)
                       (should (equal (plist-get args :command) '("pi" "mcp" "list" "--json")))
                       (setq proc (make-process :name "pichat-fake-mcp" :noquery t
                                                :connection-type 'pipe :sentinel #'ignore
                                                :command '("sh" "-c" "exit 0")))
                       (pichat-test-wait-until (lambda () (eq (process-status proc) 'exit))
                                               1 "local MCP fixture exit")
                       (let ((child proc) (filter (plist-get args :filter))
                             (sentinel (plist-get args :sentinel)))
                         (setq complete-mcp
                               (lambda ()
                                 (funcall filter child "{\"servers\":[]}")
                                 (funcall sentinel child "finished"))))
                       proc))
                    ((symbol-function 'pichat-tool-discovery-prepare-helper)
                     (lambda (_target &optional _skill)
                       (cl-incf staged)
                       (when in-sentinel (setq copy-overlapped 'sentinel-tail))
                       (setq staging t)
                       (unwind-protect (complete) (setq staging nil))
                       ;; We test the staging boundary, not catalogue protocol.
                       (error "Fixture ends at helper staging"))))
            (setq staged 0)
            (unwind-protect
                (progn
                  (open-picker)
                  (complete)
                  (when (eq action 'reopen)
                    ;; Close after MCP completion but before owned staging.
                    (pichat-tool-picker--abandoned)
                    (open-picker)
                    (accept-process-output nil 0.02)
                    (should (= staged 0))
                    (complete))
                  (pichat-test-wait-until (lambda () (= 1 staged)) 1 "Tools staging")
                  (should (plist-get pichat-tool-picker--state :loaded))
                  (when (eq action 'refresh)
                    (setq copy-overlapped nil)
                    (pichat-tool-picker-refresh)
                    (complete)
                    (pichat-test-wait-until (lambda () (= 2 staged)) 1 "refreshed Tools staging"))
                  (should-not copy-overlapped))
              (pichat-tool-picker--abandoned)
              (when (and proc (process-live-p proc)) (delete-process proc))))))))

(ert-deftest pichat-ssh-boundary-picker-open-excludes-mcp-stderr-teardown ()
  (pichat-test-ssh-boundary--picker 'open))

(ert-deftest pichat-ssh-boundary-picker-refresh-excludes-mcp-stderr-teardown ()
  (pichat-test-ssh-boundary--picker 'refresh))

(ert-deftest pichat-ssh-boundary-picker-reopen-retires-deferred-staging ()
  (pichat-test-ssh-boundary--picker 'reopen))

(ert-deftest pichat-ssh-boundary-rpc-start-retains-output-before-process-return ()
  (pichat-test-with-unit-session (session)
    (let ((transport (pichat-test-ssh-boundary--target))
          child filter stdout stderr)
      (setf (pichat-session-transport session) transport)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-tool-runtime-prepare)
                     (lambda (&rest _) "/fixture/helper.ts"))
                    ((symbol-function 'pichat-transport-make-process)
                     (lambda (_target _cwd &rest args)
                       (setq stdout (plist-get args :buffer)
                             stderr (plist-get args :stderr)
                             child (make-pipe-process :name "pichat-fake-rpc" :buffer stdout :noquery t)
                             filter (plist-get args :filter))
                       ;; Split one JSONL record across the ownership handoff.
                       (funcall filter child "{\"type\":\"fixture_")
                       child)))
            (pichat-rpc-start session '("pi" "--mode" "rpc" "--no-skills"))
            (should (processp child))
            (should (eq child (pichat-session-process session)))
            (funcall filter child "startup\"}\n{\"type\":\"fixture_after_setup\"}\n")
            (should (= 1 (pichat-test-count-raw-events session "fixture_after_setup")))
            (should (= 1 (pichat-test-count-raw-events session "fixture_startup"))))
        (pichat-rpc-stop session)
        (dolist (buffer (list stdout stderr))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-ssh-boundary-preflight-validates-file-after-busy-reply ()
  (pichat-test-with-unit-session (session process)
    (let* ((transport (pichat-test-ssh-boundary--target))
           (file "/project/source.jsonl")
           (qualified (concat "/ssh:fixture.invalid:" file))
           (regular-p (symbol-function 'file-regular-p))
           (target-busy nil)
           reply checked completions origin)
      (setf (pichat-session-transport session) transport
            (pichat-session-id session) "source"
            (pichat-session-session-file session) file)
      (setq origin (pichat-reconfigure-capture-origin session))
      (cl-letf (((symbol-function 'pichat-rpc-get-state)
                 (lambda (_session callback _failure)
                   (setq reply callback) "fixture-state"))
                ((symbol-function 'file-regular-p)
                 (lambda (path)
                   (if (equal path qualified)
                       (progn (push (if target-busy 'busy 'free) checked) nil)
                     (funcall regular-p path)))))
        (pichat-reconfigure-request-preflight
         origin (lambda (blockers _result) (push blockers completions)))
        (should reply)
        ;; A state response arrives from the filter during unrelated work on
        ;; the target.  Keep the target occupied for another event-loop turn
        ;; to distinguish a zero timer from a target-idle handoff.
        (pichat-test-ssh-boundary--during-setup
         transport process
         (lambda ()
           (setq target-busy t)
           (unwind-protect
               (progn
                 (funcall reply (list :data (list :sessionId "source" :sessionFile file)) session)
                 (accept-process-output nil 0.02))
             (setq target-busy nil))))
        (pichat-test-wait-until (lambda () completions) 1 "fresh file validation")
        (should-not (memq 'busy checked))
        (should (memq 'free checked))
        (should (equal (length completions) 1))
        (should (member "The saved conversation file is inaccessible on the runtime target"
                        (car completions)))
        (should (eq process (pichat-session-process session)))
        (should (process-live-p process))))))

(ert-deftest pichat-ssh-boundary-preflight-rechecks-origin-and-file-on-deferred-replies ()
  (dolist (change '(source target process file))
    (ert-info ((format "Changed before deferred validation: %s" change))
      (pichat-test-with-unit-session (session process)
        (let* ((transport (pichat-test-ssh-boundary--target))
               (other (pichat-transport--create :kind 'ssh :tramp-prefix "/ssh:other.invalid:"))
               (file "/project/source.jsonl")
               (state (list :sessionId "source" :sessionFile file :pendingMessageCount 0
                            :model '(:provider "fake" :id "model") :thinkingLevel "off"
                            :steeringMode "all" :followUpMode "all" :autoCompactionEnabled nil))
               (entries '(:entries ((:type "model_change" :id "model" :parentId nil
                                          :provider "fake" :modelId "model")) :leafId "model"))
               (regular-p (symbol-function 'file-regular-p))
               (readable-p (symbol-function 'file-readable-p))
               (accessible t)
               (checks 0)
               state-reply entries-reply completions replacement)
          (setf (pichat-session-transport session) transport
                (pichat-session-state session) 'idle
                (pichat-session-persistence session) 'persistent
                (pichat-session-id session) "source"
                (pichat-session-session-file session) file)
          (process-put process 'pichat-lifetime 'fixture)
          (cl-letf (((symbol-function 'pichat-rpc-get-state)
                     (lambda (_session callback _failure)
                       (setq state-reply callback) "fixture-state"))
                    ((symbol-function 'pichat-rpc-get-entries)
                     (lambda (_session _since callback _failure)
                       (setq entries-reply callback) "fixture-entries"))
                    ((symbol-function 'pichat-reconfigure--chat-blockers) #'ignore)
                    ((symbol-function 'file-regular-p)
                     (lambda (path)
                       (if (string-suffix-p file path)
                           (progn
                             (should (equal path (concat "/ssh:fixture.invalid:" file)))
                             (should-not (pichat-transport-busy-p transport))
                             (cl-incf checks)
                             accessible)
                         (funcall regular-p path))))
                    ((symbol-function 'file-readable-p)
                     (lambda (path)
                       (or (equal path (concat "/ssh:fixture.invalid:" file))
                           (funcall readable-p path)))))
            (unwind-protect
                (progn
                  (pichat-reconfigure-request-preflight
                   (pichat-reconfigure-capture-origin session)
                   (lambda (blockers result) (push (list blockers result) completions)))
                  (unless (eq change 'source)
                    (funcall state-reply (list :data state) session)
                    (should entries-reply)
                    (should (= checks 1)))
                  (let ((reply (or entries-reply state-reply))
                        (response (list :data (if entries-reply entries state))))
                    (pichat-test-ssh-boundary--during-setup
                     transport process
                     (lambda ()
                       (when (eq change 'target)
                         (setf (pichat-session-transport session) other))
                       (funcall reply response session)
                       (pcase change
                         ('source (setf (pichat-session-id session) "rebound"))
                         ('process
                          (setq replacement (make-pipe-process :name "pichat-replacement-fixture"
                                                               :noquery t))
                          (setf (pichat-session-process session) replacement))
                         ('file (setq accessible nil)))
                       (accept-process-output nil 0.06)
                       (should-not completions)))
                    (pichat-test-wait-until (lambda () completions) 1 "settle deferred preflight")
                    (funcall reply response session))
                  (should (= 1 (length completions)))
                  (pcase-let ((`((,blockers ,result)) completions))
                    (if (eq change 'file)
                        (progn
                          (should (= checks 2))
                          (should (plist-get result :baseline))
                          (should (equal blockers
                                         '("The saved conversation file is inaccessible on the runtime target"))))
                      (should (= checks (if (eq change 'source) 0 1)))
                      (should-not result)
                      (should (equal blockers
                                     '("The originating runtime, process, or conversation changed")))))
                  (should (process-live-p process))
                  (when replacement (should (process-live-p replacement))))
              (setf (pichat-session-process session) process)
              (when (and replacement (process-live-p replacement)) (delete-process replacement)))))))))

(ert-deftest pichat-ssh-boundary-confirmed-helper-cleanup-waits-for-target ()
  (dolist (fail '(nil t))
    (pichat-test-with-unit-session (session process)
      (pichat-test-with-temp-dir directory
        (let* ((transport (pichat-test-ssh-boundary--target))
               (chat (generate-new-buffer " *pichat-fixture-chat*"))
               (operation (list :session session :transport transport :chat chat
                                :phase 'preflight :shutdown-obligations (list process)))
               (helper (expand-file-name "helper.ts" directory))
               attempts
               (cleanup (lambda ()
                          (push (pichat-transport-busy-p transport) attempts)
                          (when fail (signal 'file-error '("Injected helper deletion failure")))
                          (delete-file helper))))
          (unwind-protect
              (progn
                (write-region "fixture" nil helper nil 'silent)
                (setf (pichat-session-transport session) transport
                      (pichat-session-buffer session) chat
                      (pichat-session-restart-operation session) operation)
                (with-current-buffer chat (setq-local pichat-chat-session session))
                (pichat-process-lifetime-confirm process)
                (process-put process 'pichat-helper-cleanup cleanup)
                (pichat-reconfigure--finish operation t nil)
                (pichat-test-ssh-boundary--during-setup
                 transport process (lambda () (accept-process-output nil 0.06)))
                (should-not attempts)
                (pichat-test-wait-until (lambda () attempts) 1 "safe helper cleanup")
                (should (equal attempts '(nil)))
                (should (pichat-process-lifetime-confirmed-p process))
                (should (eq (file-exists-p helper) fail))
                (if fail
                    (progn
                      (should (eq cleanup (process-get process 'pichat-helper-cleanup)))
                      (should (equal '(file-error "Injected helper deletion failure")
                                     (process-get process 'pichat-helper-cleanup-error))))
                  (should-not (process-get process 'pichat-helper-cleanup))
                  (should-not (process-get process 'pichat-helper-cleanup-error))))
            (kill-buffer chat)))))))

(ert-deftest pichat-ssh-boundary-deferral-is-connection-qualified-and-cancellable ()
  (pichat-test-with-unit-session (_session process)
    (let* ((target (pichat-test-ssh-boundary--target))
           (other (pichat-transport--create :id 'other :kind 'ssh
                                            :tramp-prefix "/ssh:other.invalid:"))
           (alias (copy-pichat-transport target))
           seen cancel-same cancel-other cancel-stale)
      (setf (pichat-transport-id alias) 'different-configured-id)
      (unwind-protect
          (pichat-test-ssh-boundary--during-setup
           target process
           (lambda ()
             (setq cancel-same (pichat-transport-defer alias (lambda () (push 'same seen)))
                   cancel-other (pichat-transport-defer other (lambda () (push 'other seen)))
                   cancel-stale (pichat-transport-defer target (lambda () (push 'stale seen))))
             (pichat-test-wait-until (lambda () (memq 'other seen)) 1 "other target progress")
             (should (equal seen '(other)))
             (funcall cancel-stale)))
        (unwind-protect
            (progn
              (pichat-test-wait-until (lambda () (memq 'same seen)) 1 "same target resumed")
              (should (equal seen '(same other))))
          (dolist (cancel (list cancel-same cancel-other cancel-stale))
            (when cancel (funcall cancel))))))))

(ert-deftest pichat-ssh-boundary-transport-defers-composed-stderr-sentinel ()
  (let ((target (pichat-test-ssh-boundary--target))
        (child (make-pipe-process :name "pichat-boundary-sentinel" :noquery t))
        (make (symbol-function 'make-process))
        seen)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args)
                       (if (equal (plist-get args :name) "pichat-fake-fifo")
                           (progn
                             (set-process-sentinel child (lambda (&rest _) (push 'consumer seen)))
                             (add-function :after (process-sentinel child)
                                           (lambda (&rest _) (push 'stderr-tail seen)))
                             child)
                         (apply make args)))))
            (pichat-transport-make-process target "/project/" :name "pichat-fake-fifo"
                                           :command '("unused")))
          ;; Reuse the same composed sentinel for PiChat acquisition and both
          ;; installed TRAMP busy signals.  The latter have no PiChat operation
          ;; on stack, as in MCP exit during an unrelated TRAMP helper copy.
          (dolist (busy '(acquisition current-connection locked))
            (ert-info ((format "Busy signal: %s" busy))
              (let* ((connection (pichat-transport--connection target))
                     (get-process (symbol-function 'tramp-get-process))
                     cancel resumed)
                (setq seen nil)
                (unwind-protect
                    (cl-letf (((symbol-function 'tramp-get-process)
                               (lambda (vec)
                                 (if (tramp-file-name-equal-p vec connection)
                                     child
                                   (funcall get-process vec)))))
                      (cl-labels
                          ((deliver ()
                             (funcall (process-sentinel child) child "fixture exit")
                             (setq cancel (pichat-transport-defer
                                           target (lambda () (setq resumed t))))
                             ;; Service initial dispatch and a busy retry.
                             (accept-process-output nil 0.12)
                             (should-not seen)
                             (should-not resumed)))
                        (pcase busy
                          ('acquisition
                           (pichat-test-ssh-boundary--during-setup target child #'deliver))
                          ('current-connection
                           (let ((tramp-current-connection (list connection)))
                             (deliver)))
                          ('locked
                           (tramp-set-connection-property child "locked" t)
                           (unwind-protect (deliver)
                             (tramp-set-connection-property child "locked" nil))))
                        (pichat-test-wait-until
                         (lambda () (and resumed (= (length seen) 2)))
                         1 "idle composed teardown and deferred consumer")
                        (should (equal seen '(stderr-tail consumer)))))
                  (when cancel (funcall cancel)))))))
      (set-process-sentinel child #'ignore)
      (delete-process child))))

(ert-deftest pichat-ssh-boundary-artifact-quit-detaches-and-retires-owned-resources ()
  (let* ((target (pichat-test-ssh-boundary--target))
         (buffer (generate-new-buffer " *pichat-runner-boundary*"))
         (process (make-pipe-process :name "pichat-runner-boundary" :buffer buffer
                                     :sentinel #'ignore :noquery t))
         (file (make-temp-file "pichat-runner-boundary")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local pichat-artifact-runner--transport target
                        pichat-artifact-runner--process process
                        pichat-artifact-runner--file file)
            (add-hook 'kill-buffer-hook #'pichat-artifact-runner--cleanup nil t))
          (pichat-test-ssh-boundary--during-setup
           target process
           (lambda ()
             (kill-buffer buffer)
             (should-not (process-buffer process))
             (should (process-live-p process))
             (should (file-exists-p file))))
          (pichat-test-wait-until (lambda () (not (file-exists-p file)))
                                  1 "detached artifact cleanup")
          (should-not (process-live-p process)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (process-live-p process) (delete-process process))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest pichat-ssh-boundary-job-pump-waits-before-claim-and-rechecks-queue ()
  (pichat-test-with-unit-session (_session process)
    (let* ((target (pichat-test-ssh-boundary--target))
           (executor (pichat-job-executor--create))
           (configuration (list :transport (pichat-job-launch--transport target)))
           (first (list :id "cancelled" :state "queued" :spec
                        (list :configuration configuration)))
           (second (list :id "remote" :state "queued" :spec
                         (list :configuration configuration)))
           (local (list :id "local" :state "queued"))
           (runs (list first second local)) claimed started)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-job-records) (lambda (&rest _) runs))
                    ((symbol-function 'pichat-job-admission) (lambda (&rest _) '(:ready t)))
                    ((symbol-function 'pichat-job-claim)
                     (lambda (_store id _limit)
                       (push id claimed)
                       (prog1 (seq-find (lambda (run) (equal (plist-get run :id) id)) runs)
                         (setq runs (seq-remove (lambda (run) (equal (plist-get run :id) id)) runs)))))
                    ((symbol-function 'pichat-job-executor--start)
                     (lambda (_ run) (push (plist-get run :id) started))))
            (pichat-test-ssh-boundary--during-setup
             target process
             (lambda ()
               (pichat-job-executor-pump executor)
               (should (equal claimed '("local")))
               (setq runs (delq first runs))
               (pichat-job-executor--cancel-launch-wait executor "cancelled")))
            (pichat-test-wait-until (lambda () (member "remote" started))
                                    1 "queued run starts after target is free")
            (should (equal claimed started))
            (should (equal started '("remote" "local")))
            (should (= (hash-table-count (pichat-job-executor-launch-waits executor)) 0)))
        (dolist (id '("remote" "cancelled"))
          (pichat-job-executor--cancel-launch-wait executor id))))))

(provide 'pichat-test-ssh-boundaries)
;;; pichat-test-ssh-boundaries.el ends here
