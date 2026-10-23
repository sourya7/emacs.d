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
    (should (equal "Launch · independent · review · global · ephemeral · choose model"
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
      (should (equal (concat "Selected: what tools are available here · "
                             "01a16663abc…\nSaved cwd: /home/mojo · "
                             "owner: global\nAction")
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
      (transient--insert-groups)
      (should (string-match-p "RET Launch ·" (buffer-string)))
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

(ert-deftest pichat-launch-removed-native-backend-is-rejected ()
  (should-error (pichat--normalize-launch-profile '(:backend llm))
                :type 'user-error)
  (should-error (pichat--launch-profile-from-arguments '("--native"))
                :type 'user-error))

(ert-deftest pichat-launch-conversation-intents-preserve-independent-switches ()
  (let* ((context (list :display-function #'pichat-chat-open
                        :conversation '(:kind new)))
         (with-new (pichat--launch-profile-from-arguments
                    '("--global" "--preset=review") context)))
    (should (eq 'new (plist-get with-new :reuse)))
    (should (eq 'global (plist-get with-new :scope)))
    (should (eq 'review (plist-get with-new :preset)))
    (plist-put context :conversation nil)
    (should (eq 'new (plist-get
                      (pichat--launch-profile-from-arguments
                       '("--global" "--preset=review") context)
                      :reuse)))
    (should (eq 'preferred (plist-get
                            (pichat--launch-profile-from-arguments nil context)
                            :reuse)))))

(ert-deftest pichat-launch-source-key-collapses-local-file-aliases ()
  (pichat-test-with-temp-dir dir
    (let ((file (expand-file-name "conversation.jsonl" dir))
          (alias (expand-file-name "alias.jsonl" dir)))
      (write-region "{}\n" nil file nil 'silent)
      (make-symbolic-link file alias)
      (should (equal (pichat--selected-file-key pichat-transport-local file)
                     (pichat--selected-file-key pichat-transport-local alias))))))

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
                              (pichat--reconfigure-action-description)))
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
      (should (string-match-p "update tools"
                              (pichat--reconfigure-action-description)))
      (plist-put (plist-get definition :preset-spec)
                 :append-system-prompt "A genuinely different prompt")
      (plist-put scope :draft definition)
      (should (string-match-p "definition changed"
                              (pichat--reconfigure-action-description))))))

(ert-deftest pichat-reconfigure-transient-labels-new-empty-pi-session ()
  (let* ((base (pichat-reconfigure-select-preset
                (list :preset-spec (pichat-presets-resolve 'standard)) 'manual))
         (draft (pichat-reconfigure-select-preset base 'coding))
         (scope (list :base base :draft draft :empty-unwritten t)))
    (cl-letf (((symbol-function 'transient-scope) (lambda (&rest _) scope)))
      (should (string-match-p "new empty Pi session; keep chat and draft"
                              (pichat--reconfigure-action-description))))))

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
                (pichat-reconfigure-execute)
                (should (equal "Restart this runtime with coding? " prompt))
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
              (pichat-reconfigure-execute)
              (should (equal "Restart this runtime with coding? " prompt))
              (setq scope (list :session session))
              (dolist (empty '(nil t))
                (setf (pichat-session-restart-operation session)
                      (list :failure "Startup failed" :empty-unwritten empty))
                (should (string-match-p
                         (if empty "new Pi session" "snapshot retained$")
                         (pichat--reconfigure-recovery-description)))
                (pichat--reconfigure-recovery-run 'retry)
                (should (equal "Retry this runtime restart? " prompt))
                (pichat--reconfigure-recovery-run 'restore)
                (should (equal "Restore the previous runtime configuration? "
                               prompt)))
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
                (pichat-reconfigure-execute)
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
      (should (string-match-p "No configuration changes" (buffer-string)))))
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
                (pichat-launch-reconfigure)
                (should-not started))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-launch)
;;; pichat-test-launch.el ends here
