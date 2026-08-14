;;; pichat-test-launch.el --- PiChat launch tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Observable launch-profile and startup-boundary behavior.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-start-session-copies-normalized-persistence ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          started)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (session) (setq started session))))
        (let ((session
               (pichat-start-session
                "/tmp/pichat-launch/" nil
                '(:persistence ephemeral :model "run/model"))))
          (should (eq session started))
          (should (eq 'ephemeral (pichat-session-persistence session)))
          (should (equal "run/model" (pichat-session-startup-model session)))
          (should (memq session (pichat-session-list))))))))

(ert-deftest pichat-start-session-rejects-ephemeral-complete-command-before-side-effects ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
          rpc-started)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (_session) (setq rpc-started t))))
        (let ((error
               (should-error
                (pichat-start-session
                 "/tmp/pichat-launch/" nil '(:persistence ephemeral))
                :type 'user-error)))
          (should (string-match-p
                   "Ephemeral PiChat runtimes are not yet supported with"
                   (cadr error))))
        (should-not rpc-started)
        (should-not (pichat-session-list))))))

(ert-deftest pichat-start-session-rejects-run-model-wrapper-before-side-effects ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
          rpc-started)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (_session) (setq rpc-started t))))
        (let ((error
               (should-error
                (pichat-start-session
                 "/tmp/pichat-launch/" nil
                 '(:persistence persistent :model "run/model"))
                :type 'user-error)))
          (should (string-match-p
                   "Run-local PiChat models are not yet supported with"
                   (cadr error))))
        (should-not rpc-started)
        (should-not (pichat-session-list))))))

(ert-deftest pichat-start-session-retains-valid-startup-failure-in-registry ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("/definitely/missing/pichat-pi")))
      (let ((session (pichat-start-session "/tmp/pichat-launch/")))
        (should (eq 'error (pichat-session-state session)))
        (should (memq session (pichat-session-list)))))))

(ert-deftest pichat-launch-profile-defaults-are-orthogonal-and-explicit ()
  (should (equal '(:scope current :target inferred :reuse preferred
                   :persistence persistent :model default
                   :display-function pichat-chat-open)
                 (pichat--normalize-launch-profile nil)))
  (should (eq 'new
              (plist-get
               (pichat--normalize-launch-profile '(:persistence ephemeral))
               :reuse)))
  (should (eq 'new
              (plist-get
               (pichat--normalize-launch-profile '(:model prompt))
               :reuse)))
  (should (eq 'new
              (plist-get
               (pichat--normalize-launch-profile '(:model "run/model"))
               :reuse))))

(ert-deftest pichat-launch-profile-rejects-incompatible-preferred-policy ()
  (dolist (profile '((:reuse preferred :persistence ephemeral)
                     (:reuse preferred :model prompt)
                     (:reuse preferred :model "run/model")))
    (should-error (pichat--normalize-launch-profile profile)
                  :type 'user-error)))

(ert-deftest pichat-launch-profile-current-preferred-reuses-exact-runtime ()
  (pichat-test-with-clean-state
    (let ((preferred (pichat-session-make :cwd "/tmp/project/"))
          opened synchronized starts)
      (setf (pichat-session-owner-scope-key preferred) "project:/tmp/project/")
      (puthash "project:/tmp/project/" preferred pichat--sessions-by-scope)
      (cl-letf (((symbol-function 'pichat--scope-for-directory)
                 (lambda (&rest _args)
                   '("project:/tmp/project/" "/tmp/project/" "project@test")))
                ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-start-session)
                 (lambda (&rest _args) (setq starts t)))
                ((symbol-function 'pichat-chat-open)
                 (lambda (session) (setq opened session)))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (session _callback &optional _error)
                   (setq synchronized session))))
        (should (eq preferred
                    (pichat--open-launch-profile nil "/tmp/project/file.el")))
        (should-not starts)
        (should (eq preferred opened))
        (should (eq preferred synchronized))))))

(ert-deftest pichat-launch-profile-global-preferred-forces-global-owner ()
  (pichat-test-with-clean-state
    (let ((pichat-global-directory "/tmp/global/")
          captured-scope)
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-start-session)
                 (lambda (cwd scope &optional _options)
                   (setq captured-scope (list cwd scope))
                   (pichat-session-make :cwd cwd)))
                ((symbol-function 'pichat-chat-open) #'ignore)
                ((symbol-function 'pichat-rpc-get-state) #'ignore))
        (pichat--open-launch-profile '(:scope global) "/tmp/a-project/")
        (should (equal '("/tmp/global/" ("global|local" "/tmp/global/" "global"))
                       captured-scope))))))

(ert-deftest pichat-launch-profile-independent-matrix-preserves-scope-and-persistence ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-global-directory "/tmp/global/")
          calls opened synchronized)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (session)
                   (setf (pichat-session-state session) 'starting)
                   session))
                ((symbol-function 'pichat-chat-open)
                 (lambda (session) (push session opened)))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (session _callback &optional _error)
                   (push session synchronized))))
        (dolist (case '((current persistent "project|local|/tmp/project/")
                        (current ephemeral "project|local|/tmp/project/")
                        (global persistent "global|local")
                        (global ephemeral "global|local")))
          (pcase-let ((`(,scope ,persistence ,owner) case))
            (cl-letf (((symbol-function 'pichat--project-root)
                       (lambda (&optional _directory) "/tmp/project/")))
              (let ((session
                     (pichat--open-launch-profile
                      (list :scope scope :reuse 'new
                            :persistence persistence :model 'default)
                      "/tmp/project/")))
                (push (list (pichat-session-owner-scope-key session)
                            (pichat-session-persistence session))
                      calls)
                (should-not (pichat-session-default-p session))))))
        (should (equal '(("project|local|/tmp/project/" persistent)
                         ("project|local|/tmp/project/" ephemeral)
                         ("global|local" persistent)
                         ("global|local" ephemeral))
                       (nreverse calls)))
        (should (= 4 (length (pichat-session-list))))
        (should (= 4 (length opened)))
        (should (equal (sort (mapcar #'pichat-session-runtime-id opened) #'string<)
                       (sort (mapcar #'pichat-session-runtime-id synchronized)
                             #'string<)))))))

(ert-deftest pichat-launch-profile-independent-does-not-replace-preferred ()
  (pichat-test-with-clean-state
    (let ((preferred (pichat-session-make :cwd "/tmp/project/"))
          (pichat-rpc-command nil))
      (setf (pichat-session-owner-scope-key preferred) "project:/tmp/project/")
      (puthash "project:/tmp/project/" preferred pichat--sessions-by-scope)
      (cl-letf (((symbol-function 'pichat--project-root)
                 (lambda (&optional _directory) "/tmp/project/"))
                ((symbol-function 'pichat-rpc-start) #'identity)
                ((symbol-function 'pichat-chat-open) #'ignore)
                ((symbol-function 'pichat-rpc-get-state) #'ignore))
        (let ((independent
               (pichat--open-launch-profile
                '(:scope current :reuse new
                  :persistence persistent :model default)
                "/tmp/project/")))
          (should-not (eq independent preferred))
          (should (eq preferred
                      (gethash "project:/tmp/project/"
                               pichat--sessions-by-scope))))))))

(ert-deftest pichat-launch-profile-current-outside-project-resolves-global ()
  (let ((pichat-global-directory "/tmp/global/"))
    (cl-letf (((symbol-function 'pichat--project-root)
               (lambda (&optional _directory) nil)))
      (should (equal '("global|local" "/tmp/global/" "global")
                     (pichat--resolve-launch-scope 'current "/tmp/outside/"))))))

(ert-deftest pichat-selected-model-launch-matrix-starts-independent-exact-runtimes ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-global-directory "/tmp/global/")
          (pichat-default-model "unchanged/default")
          displayed)
      (cl-letf (((symbol-function 'pichat--project-root)
                 (lambda (&optional _directory) "/tmp/project/"))
                ((symbol-function 'pichat-rpc-start) #'identity)
                ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-rpc-set-model)
                 (lambda (&rest _args) (ert-fail "launch used set_model")))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (session success &optional _failure)
                   (funcall success
                            '(:success t :data
                              (:model (:provider "test" :id "chosen")))
                            session))))
        (dolist (case '((current persistent "project|local|/tmp/project/")
                        (current ephemeral "project|local|/tmp/project/")
                        (global persistent "global|local")
                        (global ephemeral "global|local")))
          (pcase-let ((`(,scope ,persistence ,owner) case))
            (let ((session
                   (pichat--open-launch-profile
                    (list :scope scope :persistence persistence
                          :model "test/chosen"
                          :display-function
                          (lambda (target) (push target displayed)))
                    "/tmp/project/")))
              (should (eq persistence (pichat-session-persistence session)))
              (should (equal "test/chosen"
                             (pichat-session-startup-model session)))
              (should (equal owner (pichat-session-owner-scope-key session)))
              (should-not (pichat-session-default-p session)))))
        (should (= 4 (length displayed)))
        (should (= 4 (length (pichat-session-list))))
        (should (equal "unchanged/default" pichat-default-model))))))

(ert-deftest pichat-launch-model-prompt-accepts-listed-or-manual-known-provider-id ()
  (let ((models '(("TestProvider" . "listed")
                  ("other" . "model")))
        (answers '("TestProvider/listed"
                   " testprovider/vendor/new/model "))
        require-match-values)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices _predicate require-match &rest _args)
                 (should (equal '("TestProvider/listed" "other/model")
                                (mapcar #'car choices)))
                 (push require-match require-match-values)
                 (pop answers))))
      (should (equal "TestProvider/listed"
                     (pichat--read-model-table-choice "Model: " models t)))
      (should (equal "TestProvider/vendor/new/model"
                     (pichat--read-model-table-choice "Model: " models t))))
    (should (equal '(nil nil) (nreverse require-match-values)))))

(ert-deftest pichat-launch-model-prompt-rejects-invalid-manual-references ()
  (let ((models '(("test" . "listed"))))
    (dolist (choice '("" "   " "listed" "/model" "test/"
                      "unknown/model" "test/model id" "te st/model"
                      "test/unlisted:high" "test/unlisted:max"))
      (should-error (pichat--normalize-launch-model-choice choice models)
                    :type 'user-error))))

(ert-deftest pichat-selected-model-prompt-precedes-runtime-creation ()
  (pichat-test-with-clean-state
    (let ((previous (pichat-session-make :cwd "/tmp/previous/"))
          (profile '(:scope current :reuse new
                     :persistence persistent :model prompt))
          opened-profile opened-directory)
      (setq pichat-current-session previous)
      (cl-letf (((symbol-function 'pichat--list-models-async)
                 (lambda (_search callback)
                   (funcall callback '(("test" . "chosen")))))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (apply function args)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt _choices _predicate require-match &rest _args)
                   (should-not require-match)
                   "TEST/vendor/chosen"))
                ((symbol-function 'pichat--open-launch-profile)
                 (lambda (selected directory)
                   (setq opened-profile selected
                         opened-directory directory))))
        (pichat--select-model-before-launch profile "/tmp/project/"))
      (should (equal "test/vendor/chosen" (plist-get opened-profile :model)))
      (should (equal "/tmp/project/" opened-directory))
      (should (eq previous pichat-current-session))
      (should-not (pichat-session-list)))))

(ert-deftest pichat-selected-model-transaction-displays-only-after-state-confirmation ()
  (pichat-test-with-clean-state
    (let ((previous (pichat-session-make :cwd "/tmp/previous/"))
          readiness session displayed)
      (setq pichat-current-session previous)
      (cl-letf (((symbol-function 'pichat--project-root)
                 (lambda (&optional _directory) "/tmp/project/"))
                ((symbol-function 'pichat-rpc-start) #'identity)
                ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-rpc-set-model)
                 (lambda (&rest _args) (ert-fail "launch used set_model")))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (target success &optional _failure)
                   (setq session target readiness success))))
        (pichat--open-launch-profile
         (list :scope 'current :reuse 'new :persistence 'persistent
               :model "test/chosen"
               :display-function (lambda (target) (setq displayed target)))
         "/tmp/project/")
        (should session)
        (should-not displayed)
        (should (eq previous pichat-current-session))
        (funcall readiness
                 '(:success t :data (:model (:provider "test" :id "chosen")))
                 session)
        (should (eq session displayed))
        (should (eq session pichat-current-session))))))

(ert-deftest pichat-selected-model-cancellation-creates-no-runtime ()
  (dolist (persistence '(persistent ephemeral))
    (pichat-test-with-clean-state
      (let ((profile (list :scope 'current :reuse 'new
                           :persistence persistence :model 'prompt))
            opened)
        (cl-letf (((symbol-function 'pichat--list-models-async)
                   (lambda (_search callback)
                     (funcall callback '(("test" . "chosen")))))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _args) (signal 'quit nil)))
                  ((symbol-function 'pichat--open-launch-profile)
                   (lambda (&rest _args) (setq opened t))))
          (pichat--select-model-before-launch profile "/tmp/project/")
          (should-not opened)
          (should-not (pichat-session-list)))))))

(ert-deftest pichat-selected-model-startup-failures-clean-runtime ()
  (dolist (stage '(readiness mismatch display))
    (pichat-test-with-clean-state
      (let (session stopped displayed)
        (cl-letf (((symbol-function 'pichat--project-root)
                   (lambda (&optional _directory) "/tmp/project/"))
                  ((symbol-function 'pichat-rpc-start) #'identity)
                  ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                  ((symbol-function 'pichat-rpc-stop)
                   (lambda (target) (setq stopped target)))
                  ((symbol-function 'pichat-rpc-get-state)
                   (lambda (target success &optional failure)
                     (setq session target)
                     (if (eq stage 'readiness)
                         (funcall failure '(:success nil :error "state failed") target)
                       (funcall success
                                (list :success t :data
                                      (list :model
                                            (if (eq stage 'mismatch)
                                                '(:provider "test" :id "other")
                                              '(:provider "test" :id "chosen"))))
                                target)))))
          (pichat--open-launch-profile
           (list :scope 'current :reuse 'new :model "test/chosen"
                 :display-function
                 (lambda (_target)
                   (if (eq stage 'display)
                       (error "display failed")
                     (setq displayed t))))
           "/tmp/project/")
          (should (eq session stopped))
          (should-not displayed)
          (should-not (pichat-session-by-runtime-id
                       (pichat-session-runtime-id session))))))))

(ert-deftest pichat-selected-model-stale-callback-cannot-display-forgotten-runtime ()
  (pichat-test-with-clean-state
    (let (session readiness displayed)
      (cl-letf (((symbol-function 'pichat--project-root)
                 (lambda (&optional _directory) "/tmp/project/"))
                ((symbol-function 'pichat-rpc-start) #'identity)
                ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (target success &optional _failure)
                   (setq session target readiness success))))
        (pichat--open-launch-profile
         (list :scope 'current :reuse 'new :model "test/chosen"
               :display-function (lambda (_target) (setq displayed t)))
         "/tmp/project/")
        (pichat-forget-session session)
        (funcall readiness
                 '(:success t :data (:model (:provider "test" :id "chosen")))
                 session)
        (should-not displayed)))))

(ert-deftest pichat-prompted-profile-defers-all-runtime-creation ()
  (pichat-test-with-clean-state
    (let (selected started)
      (cl-letf (((symbol-function 'pichat--select-model-before-launch)
                 (lambda (profile directory)
                   (setq selected (list profile directory))))
                ((symbol-function 'pichat-start-session)
                 (lambda (&rest _args) (setq started t))))
        (should-not
         (pichat--open-launch-profile
          '(:scope current :reuse new :model prompt) "/tmp/project/"))
        (should selected)
        (should-not started)
        (should-not (pichat-session-list))))))

(ert-deftest pichat-model-list-command-loads-launch-environment ()
  (let ((pichat-pi-executable "/opt/pi")
        (pichat-bridge-extension-file "/tmp/bridge.ts")
        (pichat-pi-extra-args '("--offline" "-e" "/tmp/provider.ts")))
    (should (equal '("/opt/pi" "-e" "/tmp/bridge.ts"
                     "--offline" "-e" "/tmp/provider.ts"
                     "--list-models" "sonnet")
                   (pichat--model-list-command " sonnet ")))))

(ert-deftest pichat-selected-model-rejects-complete-wrapper-before-listing ()
  (let ((pichat-rpc-command '("docker" "run" "pi"))
        listed)
    (cl-letf (((symbol-function 'pichat--list-models-async)
               (lambda (&rest _args) (setq listed t))))
      (should-error
       (pichat--select-model-before-launch
        '(:scope current :reuse new :model prompt) "/tmp/project/")
       :type 'user-error)
      (should-not listed))))

(ert-deftest pichat-launch-transient-arguments-compose-and-imply-independent ()
  (dolist (case '((nil current preferred persistent default)
                  (("--global") global preferred persistent default)
                  (("--new") current new persistent default)
                  (("--ephemeral") current new ephemeral default)
                  (("--model") current new persistent prompt)
                  (("--global" "--ephemeral" "--model")
                   global new ephemeral prompt)))
    (pcase-let* ((`(,arguments ,scope ,reuse ,persistence ,model) case)
                 (profile (pichat--launch-profile-from-arguments arguments)))
      (should (eq scope (plist-get profile :scope)))
      (should (eq reuse (plist-get profile :reuse)))
      (should (eq persistence (plist-get profile :persistence)))
      (should (eq model (plist-get profile :model))))))

(ert-deftest pichat-launch-transient-selects-a-configured-target ()
  (let ((pichat-targets '((lima-devbox :kind ssh
                           :tramp-prefix "/ssh:lima-devbox:"))))
    (let ((profile
           (pichat--launch-profile-from-arguments
            '("--target=lima-devbox"))))
      (should (eq 'lima-devbox (plist-get profile :target)))
      (should (equal 'lima-devbox
                     (plist-get (pichat--normalize-launch-profile profile)
                                :target))))))

(ert-deftest pichat-launch-transient-description-shows-normalized-profile ()
  (cl-letf (((symbol-function 'transient-get-value)
             (lambda () '("--global" "--ephemeral" "--model")))
            ((symbol-function 'transient-scope) (lambda (&rest _args) nil)))
    (should (equal "Launch: global · inferred · independent · ephemeral · choose/enter model"
                   (pichat--launch-action-description)))))

(ert-deftest pichat-launch-transient-initializes-with-safe-empty-value ()
  (let ((object (clone (get 'pichat-launch 'transient--prefix))))
    (oset object value '("--ephemeral" "--model"))
    (pichat--launch-transient-init-value object)
    (should-not (oref object value))))

(ert-deftest pichat-launch-transient-setup-has-no-runtime-side-effects ()
  (let (started)
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (&rest _args) nil))
              ((symbol-function 'pichat--open-launch-profile)
               (lambda (&rest _args) (setq started t))))
      (pichat-launch (pichat--make-launch-context))
      (should-not started))))

(ert-deftest pichat-prefix-opens-launch-transient-without-starting-runtime ()
  (let (opened started)
    (cl-letf (((symbol-function 'pichat-launch)
               (lambda (&optional _context) (setq opened t)))
              ((symbol-function 'pichat--open-launch-profile)
               (lambda (&rest _args) (setq started t))))
      (let ((current-prefix-arg '(4)))
        (call-interactively #'pichat))
      (should opened)
      (should-not started))))

(provide 'pichat-test-launch)
;;; pichat-test-launch.el ends here
