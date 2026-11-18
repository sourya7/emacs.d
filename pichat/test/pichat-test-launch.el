;;; pichat-test-launch.el --- PiChat launch tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Observable launch-profile and startup-boundary behavior.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-session-manager)

(ert-deftest pichat-launch-and-history-load-without-saved-session-adapters ()
  ;; The suite itself loads optional adapters, so every entry starts cold.
  (dolist (entry '(pichat pichat-sessions))
    (pichat-test-eval-in-fresh-emacs
     `(progn
        (require ',entry)
        (with-temp-buffer (pichat-sessions-mode))
        ,@(when (eq entry 'pichat)
            '((with-temp-buffer (pichat-chat-mode))
              (should (commandp #'pichat))
              (should (commandp #'pichat-launch))
              (dolist (command '(pichat-archive-reset
                                 pichat-consult-load-session
                                 pichat-consult-switch-session
                                 pichat-consult-open-session-independently
                                 pichat-consult-jump-to-match
                                 pichat-consult-show-relations
                                 pichat-consult-show-selected-relations
                                 pichat-consult-select-session))
                (should (commandp command)))))
        (dolist (command '(pichat-sessions-list pichat-sessions-browse-files
                           pichat-sessions-switch-files
                           pichat-sessions-browse-related))
          (should (commandp command)))
        (dolist (feature '(pichat-archive pichat-consult consult
                          pichat-jobs pichat-job-executor))
          (should-not (featurep feature)))))))

(ert-deftest pichat-launch-optional-commands-load-their-owning-adapters ()
  (pichat-test-eval-in-fresh-emacs
   '(progn
      (require 'pichat)
      (should-not (featurep 'pichat-archive))
      (call-interactively #'pichat-archive-reset)
      (should (featurep 'pichat-archive))
      (should-not (featurep 'pichat-consult))
      ;; An invalid direct action loads its owner, then fails before any work.
      (should-error (pichat-consult-select-session "") :type 'user-error)
      (should (featurep 'pichat-consult))
      (should-not pichat-archive--processes)
      (should-not (featurep 'pichat-jobs)))))

(ert-deftest pichat-launch-preset-reader-does-not-filter-to-current-preset ()
  (let ((pichat-presets '((standard :description "Default tools")
                          (review :description "Read-only tools"))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices _predicate require-match initial _history default &rest _)
                 (should require-match)
                 (should-not initial)
                 (should (equal default "standard"))
                 (should (equal choices '("standard" "review")))
                 "review")))
      (should (equal (pichat--read-configuration-preset "Preset: " "standard" nil)
                     "review")))))

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

(ert-deftest pichat-start-session-rejects-manual-runner-wrapper-before-side-effects ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("docker" "run" "image" "pi" "--mode" "rpc"))
          rpc-started)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (_session) (setq rpc-started t))))
        (should-error
         (pichat-start-session
          "/tmp/pichat-launch/" nil '(:preset manual))
         :type 'user-error)
        (should-not rpc-started)
        (should-not (pichat-session-list))))))

(ert-deftest pichat-start-session-retains-valid-startup-failure-in-registry ()
  (pichat-test-with-clean-state
    (let ((pichat-default-preset 'standard)
          (pichat-rpc-command '("/definitely/missing/pichat-pi")))
      (let ((session (pichat-start-session "/tmp/pichat-launch/")))
        (should (eq 'error (pichat-session-state session)))
        (should (memq session (pichat-session-list)))))))

(ert-deftest pichat-launch-profile-defaults-are-orthogonal-and-explicit ()
  (should (equal '(:backend pi :scope current :target inferred :reuse preferred
                   :persistence persistent :preset default :tools nil :model default
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
               :reuse)))
  (should (eq 'new
              (plist-get
               (pichat--normalize-launch-profile '(:preset manual))
               :reuse))))

(ert-deftest pichat-launch-profile-rejects-incompatible-preferred-policy ()
  (dolist (profile '((:reuse preferred :persistence ephemeral)
                     (:reuse preferred :model prompt)
                     (:reuse preferred :model "run/model")
                     (:reuse preferred :preset manual)))
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
        (dolist (case '((current persistent)
                        (current ephemeral)
                        (global persistent)
                        (global ephemeral)))
          (pcase-let ((`(,scope ,persistence) case))
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

(ert-deftest pichat-launch-explicit-preset-retains-preferred-and-captures-name ()
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
        (let ((manual
               (pichat--open-launch-profile
                '(:scope current :preset manual) "/tmp/project/")))
          (should (eq 'manual (pichat-session-preset-name manual)))
          (should-not (pichat-session-preset-name preferred))
          (should (eq preferred (gethash "project:/tmp/project/"
                                         pichat--sessions-by-scope)))
          (should (not (eq preferred manual))))))))

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
                     :persistence persistent :preset manual
                     :model prompt))
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
      (should (eq 'manual (plist-get opened-profile :preset)))
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

(ert-deftest pichat-model-list-process-applies-extra-pi-environment ()
  (let ((process-environment
         (cons "PICHAT_MODEL_ENV=inherited" process-environment))
        (pichat-pi-extra-env '(("PICHAT_MODEL_ENV" . "models")))
        captured buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (_transport _runtime-cwd &rest args)
                     (setq captured (getenv "PICHAT_MODEL_ENV")
                           buffers (list (plist-get args :buffer)
                                         (plist-get args :stderr)))
                     'fake-process)))
          (pichat--list-models-async nil #'ignore temporary-file-directory 'local)
          (should (equal "models" captured)))
      (dolist (buffer buffers)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

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
  (dolist (case '((nil current preferred persistent default default)
                  (("--global") global preferred persistent default default)
                  (("--new") current new persistent default default)
                  (("--ephemeral") current new ephemeral default default)
                  (("--model") current new persistent default prompt)
                  (("--preset=manual") current new persistent manual default)
                  (("--global" "--ephemeral" "--model" "--preset=review")
                   global new ephemeral review prompt)))
    (pcase-let* ((`(,arguments ,scope ,reuse ,persistence ,preset ,model) case)
                 (profile (pichat--launch-profile-from-arguments arguments)))
      (should (eq scope (plist-get profile :scope)))
      (should (eq reuse (plist-get profile :reuse)))
      (should (eq persistence (plist-get profile :persistence)))
      (should (eq preset (plist-get profile :preset)))
      (should (eq model (plist-get profile :model))))))

(ert-deftest pichat-launch-context-uses-configured-display-policy ()
  (let* ((display (lambda (_session) nil))
         (pichat-launch-display-chat-function display)
         (context (pichat--make-launch-context))
         (profile (pichat--launch-profile-from-arguments nil context)))
    (should (eq display (plist-get profile :display-function)))
    (should (eq #'pichat-chat-open
                (plist-get
                 (pichat--launch-profile-from-arguments
                  nil (pichat--make-launch-context #'pichat-chat-open))
                 :display-function)))))

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
             (lambda () '("--global" "--ephemeral" "--model" "--preset=review")))
            ((symbol-function 'transient-scope) (lambda (&rest _args) nil)))
    (should (equal "Launch independent (review)"
                   (pichat--launch-action-description)))))

(ert-deftest pichat-launch-selected-conversation-details-are-full-width ()
  (let* ((selection (list :title "what tools are available here"
                          :session-id "01a16663abcdef"
                          :cwd "/home/mojo"))
         (scope (list :directory "/home/mojo/"
                      :conversation (list :kind 'saved :selection selection)))
         (transient--prefix (transient--init-prefix 'pichat-launch))
         (transient--layout (transient--init-suffixes 'pichat-launch))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (cl-letf (((symbol-function 'transient-scope)
               (lambda (&rest _) scope))
              ((symbol-function 'transient-get-value)
               (lambda (&rest _) nil))
              ((symbol-function 'pichat--resolve-launch-scope)
               (lambda (&rest _) (list nil nil "global"))))
      (should (equal "Selected saved conversation"
                     (pichat--launch-conversation-description)))
      (should (equal (concat "Selected: what tools are available here\n"
                             "ID: 01a16663abc… · owner: global\n"
                             "Saved cwd: /home/mojo\nAction")
                     (pichat--launch-action-heading)))
      (with-temp-buffer
        (transient--insert-groups)
        (let ((rendered (buffer-string)))
          (should (string-match-p "^Conversation +Configuration" rendered))
          (should (string-match-p "Selected saved conversation" rendered))
          (should (string-match-p "^Selected: what tools" rendered))
          (should (string-match-p "^Saved cwd: /home/mojo" rendered))
          (should (string-match-p "^Action$" rendered)))))))

(ert-deftest pichat-launch-transient-accepts-terminal-and-gui-return ()
  (let* ((transient--prefix (transient--init-prefix 'pichat-launch))
         (transient--layout (transient--init-suffixes 'pichat-launch))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (dolist (key '("RET" "<return>"))
      (should (eq (lookup-key (transient--make-transient-map) (kbd key))
                  'pichat-launch-execute)))
    (with-temp-buffer
      (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) nil))
                ((symbol-function 'transient-get-value) (lambda (&rest _) nil)))
        (transient--insert-groups))
      (should (string-match-p "s Default conversation" (buffer-string)))
      (should (string-match-p "RET Launch preferred" (buffer-string)))
      (should-not (string-match-p "<return>" (buffer-string))))))

(ert-deftest pichat-launch-transient-initializes-with-safe-empty-value ()
  (let ((object (clone (get 'pichat-launch 'transient--prefix))))
    (oset object value '("--ephemeral" "--model" "--preset=manual"))
    (pichat--launch-transient-init-value object)
    (should-not (oref object value))))

(ert-deftest pichat-launch-transient-setup-has-no-runtime-side-effects ()
  (let (started)
    (cl-letf (((symbol-function 'transient-setup)
               (lambda (&rest _args) nil))
              ((symbol-function 'pichat--open-launch-profile)
               (lambda (&rest _args) (setq started t))))
      (call-interactively #'pichat-launch)
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

(ert-deftest pichat-launch-removed-native-backend-is-rejected ()
  (should-error (pichat--normalize-launch-profile '(:backend llm))
                :type 'user-error)
  (should-error (pichat--launch-profile-from-arguments '("--native"))
                :type 'user-error))

(ert-deftest pichat-launch-saved-selection-composes-with-scope-and-preset ()
  (let* ((conversation '(:kind saved :selection (:file "/tmp/saved.jsonl")))
         (profile (pichat--launch-profile-from-arguments
                   '("--global" "--preset=review")
                   (list :conversation conversation))))
    (should (equal conversation (plist-get profile :conversation)))
    (should (eq 'new (plist-get profile :reuse)))
    (should (eq 'global (plist-get profile :scope)))
    (should (eq 'review (plist-get profile :preset))))
  (should-not (plist-get (pichat--launch-profile-from-arguments '("--new"))
                         :conversation))
  (should-error (pichat--normalize-launch-profile
                 '(:reuse new :conversation (:kind unsupported)))
                :type 'user-error))

(defun pichat-test-launch-ret (arguments context)
  "Run the launcher RET suffix for ARGUMENTS and captured CONTEXT."
  (cl-letf (((symbol-function 'transient-args) (lambda (_) arguments))
            ((symbol-function 'transient-scope) (lambda (&rest _) context)))
    (call-interactively #'pichat-launch-execute)))

(ert-deftest pichat-launch-untouched-opens-independent-chat-without-rpc ()
  (pichat-test-with-clean-state
    (with-temp-buffer
      (let* ((default-directory "/tmp/launcher-project/")
             (pichat-global-directory "/tmp/launcher-global/")
             (key "project|local|/tmp/launcher-project/")
             (preferred (pichat-session-create :owner-scope-key key))
             (origin (pichat-session-create :buffer (current-buffer)
                                            :owner-scope-key key))
             (pichat-current-session preferred)
             args displayed
             (context (pichat--make-launch-context
                       (lambda (session) (push session displayed)))))
        (puthash key preferred pichat--sessions-by-scope)
        (setq-local major-mode 'pichat-chat-mode
                    pichat-chat-session origin)
        (cl-letf (((symbol-function 'pichat--project-root) (lambda (_) default-directory))
                  ((symbol-function 'pichat-session-alive-p) (lambda (_) t))
                  ((symbol-function 'pichat-start-session)
                   (lambda (&rest _) (ert-fail "Started a runtime")))
                  ((symbol-function 'pichat-backend-get-state)
                   (lambda (&rest _) (ert-fail "Requested RPC state")))
                  ((symbol-function 'transient-scope) (lambda (&rest _) context))
                  ((symbol-function 'transient-get-value) (lambda () args)))
          (dolist (case `((nil . ,key)
                          (("--target=local") . ,key)
                          (("--global") . "global|local")))
            (ert-info ((format "Launch arguments: %S" (car case)))
              (setq args (car case) displayed nil)
              (setf (pichat-session-owner-scope-key origin) (cdr case))
              (should (equal "Current chat" (pichat--launch-conversation-description)))
              (should (equal "Open current chat" (pichat--launch-action-description)))
              (should (eq origin (pichat-test-launch-ret args context)))
              (should (equal (list origin) displayed))
              (should (eq preferred pichat-current-session))
              (should (eq preferred (gethash key pichat--sessions-by-scope))))))))))

(ert-deftest pichat-launch-touched-draft-keeps-normal-profile-from-chat ()
  (with-temp-buffer
    (let* ((default-directory "/tmp/launcher-project/")
           (pichat-default-preset 'manual)
           (pichat-targets '((devbox :kind ssh :tramp-prefix "/ssh:devbox:")))
           (key "project|local|/tmp/launcher-project/")
           (conversation '(:kind saved :selection (:file "/tmp/saved.jsonl")))
           (origin (pichat-session-create :buffer (current-buffer)
                                          :owner-scope-key key))
           (context (pichat--make-launch-context
                     (lambda (_) (ert-fail "Displayed the origin chat"))))
           launched)
      (setq-local major-mode 'pichat-chat-mode
                  pichat-chat-session origin)
      (cl-letf (((symbol-function 'pichat--project-root) (lambda (_) default-directory))
                ((symbol-function 'pichat-session-alive-p) (lambda (_) t))
                ((symbol-function 'pichat--open-launch-profile)
                 (lambda (profile directory)
                   (should (equal directory default-directory))
                   (setq launched profile))))
        (dolist (case `((("--new") nil :reuse new)
                        (("--ephemeral") nil :reuse new :persistence ephemeral)
                        (("--preset=review") nil :reuse new :preset review)
                        (("--model") nil :reuse new :model prompt)
                        (nil (:model "fixture/model") :reuse new :model "fixture/model")
                        (nil (:tool-selection ("read")
                              :tool-target (,default-directory current inferred))
                             :reuse new :tools ("read"))
                        (nil (:conversation ,conversation)
                             :reuse new :conversation ,conversation)
                        (("--global") nil :reuse preferred :scope global)
                        (("--target=devbox") nil :reuse preferred :target devbox)))
          (pcase-let ((`(,args ,staged . ,expected) case))
            (ert-info ((format "Draft: %S %S" args staged))
              (setq launched nil)
              (pichat-test-launch-ret args (append staged context))
              (should launched)
              (cl-loop for (key value) on expected by #'cddr
                       do (should (equal value (plist-get launched key)))))))))))

(ert-deftest pichat-launch-unusable-current-chat-falls-back-with-reason ()
  (pichat-test-with-clean-state
    (with-temp-buffer
      (let* ((default-directory "/tmp/launcher-project/")
             (scope '("project|local|/tmp/launcher-project/" "/tmp/launcher-project/" "project"))
             (origin (pichat-session-create :buffer (current-buffer)))
             (preferred (pichat-session-create :state 'idle))
             (context (pichat--make-launch-context
                       (lambda (session) (should (eq preferred session)))))
             (synchronized nil)
             alive notice)
        (pichat-register-session origin scope)
        (puthash (car scope) preferred pichat--sessions-by-scope)
        (setq-local major-mode 'pichat-chat-mode
                    pichat-chat-session origin)
        (cl-letf (((symbol-function 'pichat--project-root) (lambda (_) default-directory))
                  ((symbol-function 'pichat-session-alive-p)
                   (lambda (session) (or (eq session preferred) alive)))
                  ((symbol-function 'pichat-start-session)
                   (lambda (&rest _) (ert-fail "Started a runtime")))
                  ((symbol-function 'pichat-backend-get-state)
                   (lambda (session &rest _) (setq synchronized session)))
                  ((symbol-function 'message)
                   (lambda (fmt &rest values) (setq notice (apply #'format fmt values)))))
          (dolist (case '((nil stopped nil "runtime is not live")
                          (t error nil "runtime is in error")
                          (t idle failed "restart or recovery is pending")
                          (t idle starting "restart or recovery is pending")))
            (pcase-let ((`(,live ,state ,phase ,reason) case))
              (ert-info ((format "Origin status: %S" case))
                (setq alive live notice nil synchronized nil)
                (setf (pichat-session-state origin) state
                      (pichat-session-restart-operation origin) (and phase (list :phase phase)))
                (if (eq phase 'starting)
                    (progn
                      (should (string-match-p
                               "A PiChat runtime is restarting in this scope"
                               (cadr (should-error (pichat-test-launch-ret nil context)
                                                   :type 'user-error))))
                      (should-not synchronized))
                  (should (eq preferred (pichat-test-launch-ret nil context)))
                  (should (eq preferred synchronized)))
                (should (equal (format "PiChat: current chat unavailable (%s); using preferred launch"
                                       reason)
                               notice))))))))))

(ert-deftest pichat-launch-non-chat-and-manager-keep-preferred-launch ()
  (with-temp-buffer
    (let* ((scope '("project|local|/tmp/manager-choice/" "/tmp/manager-choice/" "choice"))
           captured context directory)
      (cl-letf (((symbol-function 'pichat--open-launch-profile)
                 (lambda (profile cwd) (setq captured profile directory cwd)))
                ((symbol-function 'pichat-session-manager--read-project-directory)
                 (lambda () (nth 1 scope)))
                ((symbol-function 'pichat-launch) (lambda (draft) (setq context draft))))
        (pichat-test-launch-ret nil (pichat--make-launch-context))
        (should (eq 'preferred (plist-get captured :reuse)))
        (should (eq 'current (plist-get captured :scope)))
        (should (equal default-directory directory))
        (pichat-session-manager-mode)
        (call-interactively #'pichat-session-manager-launch)
        (pichat-test-launch-ret nil context)
        (should (eq 'preferred (plist-get captured :reuse)))
        (should (equal (seq-take (plist-get captured :scope) 2) (seq-take scope 2)))
        (should (eq #'pichat-session-manager--display (plist-get captured :display-function)))
        (should-not directory)))))

(ert-deftest pichat-launch-conversation-direct-picker-and-clear ()
  (with-temp-buffer
    (let* ((context (pichat--make-launch-context))
           (draft context)
           (args '("--global" "--target=local"))
           (selection (pichat-sessions-selection
                       "/tmp/example.jsonl" "/tmp" pichat-transport-local))
           (picks 0)
           (reopens 0)
           accept)
      (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) draft))
                ((symbol-function 'transient-args) (lambda (_) args))
                ((symbol-function 'transient-setup)
                 (lambda (_prefix _child _keys &rest options)
                   (cl-incf reopens)
                   (setq draft (plist-get options :scope))))
                ((symbol-function 'pichat-sessions-select-file)
                 (cl-function
                  (lambda (callback &key session)
                    (should-not session)
                    (cl-incf picks)
                    (when accept (funcall callback selection))))))
        (call-interactively #'pichat-launch-conversation) ; No callback on cancel.
        (should (= picks 1))
        (should (= reopens 0))
        (should (eq draft context))
        (should-not (plist-get draft :conversation))
        (should (equal "Default conversation" (pichat--launch-conversation-description)))
        (setq accept t)
        (call-interactively #'pichat-launch-conversation)
        (should (= picks 2))
        (should (= reopens 1))
        (should (equal (list :kind 'saved :selection selection)
                       (plist-get draft :conversation)))
        (should (equal args (plist-get draft :launch-args)))
        (should-not (plist-get context :conversation))
        (should (equal "Selected saved conversation"
                       (pichat--launch-conversation-description)))
        (call-interactively #'pichat-launch-conversation)
        (should (= picks 2))
        (should (= reopens 2))
        (should (equal args (plist-get draft :launch-args)))
        (should-not (plist-get draft :conversation))
        (should (equal "Default conversation"
                       (pichat--launch-conversation-description)))))))

(ert-deftest pichat-launch-conversation-ssh-requires-same-target-origin ()
  (with-temp-buffer
    (let* ((pichat-targets '((devbox :kind ssh :tramp-prefix "/ssh:devbox:")))
           (context (pichat--make-launch-context))
           (transport (pichat-transport-resolve "/ssh:devbox:/tmp/" 'devbox))
           (runtime (pichat-session-create :buffer (current-buffer)
                                           :transport transport))
           (picked nil))
      (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) context))
                ((symbol-function 'transient-args) (lambda (_) '("--target=devbox")))
                ((symbol-function 'pichat--resolve-launch-scope)
                 (lambda (&rest _) '("scope" "/ssh:devbox:/tmp/" "test")))
                ((symbol-function 'pichat-sessions-select-file)
                 (cl-function (lambda (_callback &key session) (setq picked session)))))
        (should-error (call-interactively #'pichat-launch-conversation) :type 'user-error)
        (setq-local pichat-chat-session
                    (pichat-session-create :transport pichat-transport-local))
        (should-error (call-interactively #'pichat-launch-conversation) :type 'user-error)
        (should-not picked)
        (setq-local pichat-chat-session runtime)
        (call-interactively #'pichat-launch-conversation)
        (should (eq picked runtime))))))

(ert-deftest pichat-launch-source-key-collapses-local-file-aliases ()
  (pichat-test-with-temp-dir dir
    (let ((file (expand-file-name "conversation.jsonl" dir))
          (alias (expand-file-name "alias.jsonl" dir)))
      (write-region "{}\n" nil file nil 'silent)
      (make-symbolic-link file alias)
      (should (equal (pichat--selected-file-key pichat-transport-local file)
                     (pichat--selected-file-key pichat-transport-local alias))))))

(ert-deftest pichat-launch-selected-file-claim-release-requires-owner-token ()
  (let* ((pichat--source-reservations (make-hash-table :test #'equal))
         (key '(local . "/tmp/selected.jsonl"))
         (token (pichat--claim-selected-file key)))
    (should (eq token (pichat--selected-file-reserved-p key)))
    (should-error (pichat--claim-selected-file key) :type 'user-error)
    (pichat--release-selected-file key (make-symbol "stale"))
    (should (eq token (pichat--selected-file-reserved-p key)))
    (pichat--release-selected-file key token)
    (should-not (pichat--selected-file-reserved-p key))))

(ert-deftest pichat-launch-hosted-saved-session-offers-only-open-or-cancel ()
  (pichat-test-with-temp-dir dir
    (let* ((file (expand-file-name "saved.jsonl" dir))
           (selection (pichat-sessions-selection file dir pichat-transport-local))
           (profile (list :scope (list "global|local|hosted-test" dir "test")
                          :target 'local :reuse 'new :persistence 'persistent
                          :conversation (list :kind 'saved :selection selection)))
           (host (pichat-session-make)))
      (write-region "{}\n" nil file nil 'silent)
      (dolist (choice '(?c ?o))
        (let (opened)
          (cl-letf (((symbol-function 'pichat--selected-file-conflict) (lambda (_) host))
                    ((symbol-function 'read-multiple-choice)
                     (lambda (prompt choices &rest _)
                       (should (equal prompt (format "Open in runtime %s: "
                                                     (pichat-session-runtime-id host))))
                       (should (equal choices '((?o "Open") (?c "Cancel"))))
                       (list choice)))
                    ((symbol-function 'pichat-chat-open) (lambda (owner) (setq opened owner)))
                    ((symbol-function 'pichat-sessions-open-file-independently)
                     (lambda (&rest _) (ert-fail "Started another writer"))))
            (should-error (pichat--open-launch-profile profile dir) :type 'user-error))
          (should (eq opened (and (eq choice ?o) host))))))))

(ert-deftest pichat-launch-selected-file-reservation-blocks-racing-writers ()
  (pichat-test-with-temp-dir dir
    (let* ((file (expand-file-name "saved.jsonl" dir))
           (selection (pichat-sessions-selection
                       file dir pichat-transport-local
                       '(:session-id "saved" :title "Saved title")))
           (profile (list :scope (list "global|local|reservation-test"
                                       dir "reservation-test")
                          :target 'local :reuse 'new :persistence 'persistent
                          :conversation (list :kind 'saved :selection selection)))
           (pichat--source-reservations (make-hash-table :test #'equal))
           (starts 0)
           failure)
      (write-region "{}\n" nil file nil 'silent)
      (cl-letf (((symbol-function 'pichat--selected-file-conflict)
                 (lambda (_key) nil))
                ((symbol-function 'pichat-sessions-open-file-independently)
                 (lambda (_file &rest keys)
                   (cl-incf starts)
                   (setq failure (plist-get keys :error-callback))
                   'pending)))
        (pichat--open-launch-profile profile dir)
        (should (= starts 1))
        (should-error (pichat--open-launch-profile profile dir)
                      :type 'user-error)
        (should (= starts 1))
        (funcall failure '(:error "injected startup failure") nil)
        (should (= 0 (hash-table-count pichat--source-reservations)))
        (pichat--open-launch-profile profile dir)
        (should (= starts 2))))))

(ert-deftest pichat-launch-selected-conversation-rejects-ephemeral-and-cross-target ()
  (pichat-test-with-temp-dir dir
    (let* ((selection (pichat-sessions-selection
                       (expand-file-name "saved.jsonl" dir) dir
                       pichat-transport-local))
           (profile (list :scope (list "global|local|selected-test" dir "test")
                          :target 'local :reuse 'new :persistence 'ephemeral
                          :conversation (list :kind 'saved :selection selection))))
      (should-error (pichat--open-launch-profile profile dir) :type 'user-error)
      (setq profile (plist-put profile :persistence 'persistent))
      (setq selection (plist-put selection :transport-id 'different-target))
      (should-error (pichat--open-launch-profile profile dir)
                    :type 'user-error))))

(ert-deftest pichat-sessions-selector-returns-structured-record-without-loading ()
  (let (chosen)
    (cl-letf (((symbol-function 'pichat-sessions--choose-basic-file)
               (lambda (&optional _session _record)
                 (list "/saved/test.jsonl" "/saved/cwd"
                       '(:session-id "exact-id" :candidate "bounded title"))))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (&rest _) (ert-fail "Selection opened a runtime")))
              ((symbol-function 'pichat-sessions-switch-file)
               (lambda (&rest _) (ert-fail "Selection switched a runtime"))))
      (pichat-sessions-select-file (lambda (selection) (setq chosen selection))
                                   :basic t)
      (should (equal 'local (plist-get chosen :transport-id)))
      (should (equal "/saved/test.jsonl" (plist-get chosen :file)))
      (should (equal "exact-id" (plist-get chosen :session-id)))
      (should (equal "/saved/cwd" (plist-get chosen :cwd))))))

(ert-deftest pichat-reconfigure-transient-heading-identifies-conversation-concisely ()
  (let* ((session (pichat-session-create :id "runtime" :name "Conversation"
                                          :transport pichat-transport-local))
         (scope (list :origin (list :session session :session-id "session-123456")
                      :empty-unwritten t)))
    (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) scope)))
      (should (equal "Reconfigure · Conversation\nPi session: session-123…"
                     (pichat--reconfigure-menu-description))))))

(ert-deftest pichat-reconfigure-transient-renders-blocked-restart ()
  (let* ((base (list :preset-spec (pichat-presets-resolve 'manual)))
         (draft (pichat-reconfigure-select-preset base 'coding))
         (session (pichat-session-create :id "test" :name "Conversation"
                                         :transport pichat-transport-local))
         (scope (list :origin (list :session session)
                      :base base :draft draft :blockers '("Pi is busy")))
         (prefix (transient--init-prefix 'pichat-reconfigure-menu)))
    (oset prefix scope scope)
    (let* ((transient--prefix prefix)
           (transient--layout (transient--init-suffixes 'pichat-reconfigure-menu))
           (transient--suffixes (transient--flatten-suffixes transient--layout)))
      (should (string-match-p "Blocked.*Pi is busy"
                              (pichat--reconfigure-action-heading)))
      (with-temp-buffer
        (transient--insert-groups)
        (should (string-match-p "Blocked.*Pi is busy" (buffer-string)))))))

(ert-deftest pichat-reconfigure-transient-distinguishes-tools-and-definition-changes ()
  (let* ((base (pichat-reconfigure-select-preset
                (list :preset-spec (pichat-presets-resolve 'standard)) 'manual))
         (tools (copy-tree base t))
         (definition (copy-tree base t))
         (scope (list :base base :draft tools)))
    (plist-put tools :tool-selection
               (pichat-tool-selection-resolve
                (pichat-presets-resolve 'manual) '("read")))
    (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) scope)))
      (should (string-match-p "new tools"
                              (pichat--reconfigure-action-description)))
      (plist-put (plist-get definition :preset-spec)
                 :append-system-prompt "A genuinely different prompt")
      (plist-put scope :draft definition)
      (should (string-match-p "new manual definition"
                              (pichat--reconfigure-action-description))))))

(ert-deftest pichat-reconfigure-transient-labels-new-empty-pi-session ()
  (let* ((base (pichat-reconfigure-select-preset
                (list :preset-spec (pichat-presets-resolve 'standard)) 'manual))
         (draft (pichat-reconfigure-select-preset base 'coding))
         (scope (list :base base :draft draft :empty-unwritten t)))
    (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) scope)))
      (should (string-match-p "New empty Pi session; keep chat and draft"
                              (pichat--reconfigure-action-heading))))))

(ert-deftest pichat-reconfigure-empty-restart-confirms-concisely ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer prompt)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let* ((base (pichat-reconfigure-select-preset
                          (list :preset-spec (pichat-presets-resolve 'standard))
                          'manual))
                   (scope (list :origin (pichat-reconfigure-capture-origin session)
                                :base base
                                :draft (pichat-reconfigure-select-preset
                                        base 'coding)
                                :empty-unwritten t)))
              (cl-letf (((symbol-function 'transient-scope)
                         (lambda (&rest _) scope))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (question) (setq prompt question) nil))
                        ((symbol-function 'pichat-reconfigure-restart)
                         (lambda (&rest _) (ert-fail "Confirmation declined"))))
                (call-interactively #'pichat-reconfigure-execute)
                (should (equal "Restart runtime? " prompt))
                (should (process-live-p proc)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-saved-restart-and-recovery-prompts-are-concise ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer prompt scope)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((base (pichat-reconfigure-select-preset
                         (list :preset-spec (pichat-presets-resolve 'standard))
                         'manual)))
              (setq scope (list :origin (pichat-reconfigure-capture-origin session)
                                :base base
                                :draft (pichat-reconfigure-select-preset
                                        base 'coding))))
            (cl-letf (((symbol-function 'transient-scope)
                       (lambda (&rest _) scope))
                      ((symbol-function 'yes-or-no-p)
                       (lambda (question) (setq prompt question) nil))
                      ((symbol-function 'pichat-reconfigure-restart)
                       (lambda (&rest _) (ert-fail "Confirmation declined"))))
              (call-interactively #'pichat-reconfigure-execute)
              (should (equal "Restart runtime? " prompt))
              (setq scope (list :session session))
              (dolist (empty '(nil t))
                (setf (pichat-session-restart-operation session)
                      (list :failure "Startup failed" :empty-unwritten empty))
                (should (string-match-p
                         (if empty "new Pi session" "Snapshot retained\\'")
                         (pichat--reconfigure-recovery-description)))
                (let (choices)
                  (cl-letf (((symbol-function 'yes-or-no-p)
                             (lambda (&rest _) (ert-fail "Recovery needs no confirmation")))
                            ((symbol-function 'pichat-reconfigure-recover)
                             (lambda (owner choice _callback)
                               (should (eq session owner))
                               (push choice choices))))
                    (pichat--reconfigure-recovery-run 'retry)
                    (pichat--reconfigure-recovery-run 'restore))
                  (should (equal '(restore retry) choices))))
              (should (process-live-p proc))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-transient-noop-does-not-confirm-or-stop ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let* ((base (pichat-reconfigure-select-preset
                          (list :preset-spec (pichat-presets-resolve 'standard))
                          'manual))
                   (scope (list :origin (pichat-reconfigure-capture-origin session)
                                :base base :draft (copy-tree base t)
                                :blockers '("Busy"))))
              (cl-letf (((symbol-function 'transient-scope)
                         (lambda (&rest _) scope))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _) (ert-fail "No-op prompted to restart")))
                        ((symbol-function 'pichat-reconfigure-restart)
                         (lambda (&rest _) (ert-fail "No-op restarted"))))
                (call-interactively #'pichat-reconfigure-execute)
                (should (process-live-p proc)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reconfigure-transient-ret-and-cancellation-are-side-effect-free ()
  (let* ((base (pichat-reconfigure-select-preset
                (list :preset-spec (pichat-presets-resolve 'standard)) 'manual))
         (scope (list :origin (list :session-id "session"
                                    :session (pichat-session-create
                                              :name "Test conversation"
                                              :transport pichat-transport-local))
                      :base base :draft (copy-tree base t)
                      :blockers nil))
         (transient--prefix (transient--init-prefix 'pichat-reconfigure-menu))
         (transient--layout (transient--init-suffixes 'pichat-reconfigure-menu))
         (transient--suffixes (transient--flatten-suffixes transient--layout)))
    (oset transient--prefix scope scope)
    (dolist (key '("RET" "<return>"))
      (should (eq 'pichat-reconfigure-execute
                  (lookup-key (transient--make-transient-map) (kbd key)))))
    (with-temp-buffer
      (transient--insert-groups)
      (should (string-match-p "No changes · keep runtime" (buffer-string)))))
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (started nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (let ((scope (list :origin-buffer buffer :directory default-directory)))
              (cl-letf (((symbol-function 'transient-scope)
                         (lambda (&rest _) scope))
                        ((symbol-function 'transient-args) (lambda (&rest _) nil))
                        ((symbol-function 'pichat--reconfigure-show)
                         (lambda (menu)
                           (should (eq session (plist-get (plist-get menu :origin)
                                                           :session)))))
                        ((symbol-function 'pichat-rpc-stop)
                         (lambda (&rest _) (setq started t))))
                (call-interactively #'pichat-launch-reconfigure)
                (should-not started))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-launch)
;;; pichat-test-launch.el ends here
