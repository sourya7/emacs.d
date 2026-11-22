;;; pichat-test-ssh-boundaries.el --- SSH callback ordering regressions -*- lexical-binding: t; -*-

;; Load explicitly while these regressions are red.  There is no SSH server,
;; TRAMP implementation advice, real Pi process, or remote fixture state.

(require 'pichat-test-support)
(require 'pichat-tool-picker)
(require 'pichat-reconfigure)
(require 'pichat-tool-runtime)

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

(ert-deftest pichat-ssh-boundary-confirmed-helper-cleanup-waits-for-target ()
  (pichat-test-with-unit-session (session process)
    (let* ((transport (pichat-test-ssh-boundary--target))
           (chat (generate-new-buffer " *pichat-fixture-chat*"))
           (operation (list :session session :transport transport :chat chat
                            :phase 'preflight :shutdown-obligations (list process)))
           (target-busy nil)
           cleaned)
      (setf (pichat-session-transport session) transport
            (pichat-session-buffer session) chat
            (pichat-session-restart-operation session) operation)
      (with-current-buffer chat (setq-local pichat-chat-session session))
      (pichat-process-lifetime-confirm process)
      (process-put process 'pichat-helper-cleanup
                   (lambda () (push (if target-busy 'busy 'free) cleaned)))
      (unwind-protect
          (progn
            (pichat-reconfigure--finish operation t nil)
            (pichat-test-ssh-boundary--during-setup
             transport process
             (lambda ()
               (let (yielded)
                 (setq target-busy t)
                 (unwind-protect
                     (progn
                       (run-at-time 0 nil (lambda () (setq yielded t)))
                       (pichat-test-wait-until (lambda () yielded) 1
                                               "event loop inside same-target setup"))
                   (setq target-busy nil)))))
            (should-not (memq 'busy cleaned))
            (pichat-test-wait-until (lambda () cleaned) 1 "safe helper cleanup")
            (should (equal cleaned '(free)))
            (should-not (process-get process 'pichat-helper-cleanup)))
        (kill-buffer chat)))))

(provide 'pichat-test-ssh-boundaries)
;;; pichat-test-ssh-boundaries.el ends here
