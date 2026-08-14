;;; pichat-test-transport.el --- Transport behavior tests -*- lexical-binding: t; -*-

(require 'pichat-test-support)

(ert-deftest pichat-transport-resolves-configured-project-and-captures-mappings ()
  (let ((pichat-targets
         '((devbox :kind ssh :tramp-prefix "/ssh:devbox:"
                   :pi-executable "/usr/bin/pi"
                   :runtime-home "/home/dev"
                   :path-mappings
                   (("/host/project" . "/workspace")
                    ("/ssh:devbox:/home/dev" . "/home/dev")))))
        (pichat-project-target-alist '(("/host/project" . devbox))))
    (let* ((transport (pichat-transport-resolve "/host/project/a/"))
           (context (pichat-transport-path-context transport)))
      (should (eq 'devbox (pichat-transport-id transport)))
      (should (eq 'ssh (pichat-transport-kind transport)))
      (should (equal "/workspace/a/file.el"
                     (pichat-path-to-runtime
                      "/host/project/a/file.el" context)))
      (should (equal "/ssh:devbox:/home/dev/private.el"
                     (pichat-path-from-runtime
                      "/home/dev/private.el" context))))))

(ert-deftest pichat-transport-project-association-uses-longest-prefix ()
  (let ((pichat-targets
         '((broad :kind ssh :tramp-prefix "/ssh:broad:")
           (specific :kind ssh :tramp-prefix "/ssh:specific:")))
        (pichat-project-target-alist
         '(("/projects" . broad) ("/projects/one" . specific))))
    (should (eq 'specific
                (pichat-transport-id
                 (pichat-transport-resolve "/projects/one/src/"))))))

(ert-deftest pichat-transport-rejects-ambiguous-runtime-mappings ()
  (let ((pichat-targets
         '((bad :kind ssh :tramp-prefix "/ssh:bad:"
                :path-mappings
                (("/one" . "/workspace") ("/two" . "/workspace"))))))
    (should-error (pichat-transport-resolve "/tmp" 'bad)
                  :type 'user-error)))

(ert-deftest pichat-transport-ssh-process-enables-file-handler-and-runtime-cwd ()
  (let* ((transport
          (pichat-transport--create
           :id 'devbox :kind 'ssh :label "devbox"
           :tramp-prefix "/ssh:devbox:" :pi-executable "pi"
           :remote-path '(tramp-own-remote-path)))
         captured-directory captured-args)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq captured-directory default-directory
                       captured-args args)
                 'fake-process)))
      (should (eq 'fake-process
                  (pichat-transport-make-process
                   transport "/workspace/project/"
                   :name "test" :command '("pi" "--version"))))
      (should (equal "/ssh:devbox:/workspace/project/" captured-directory))
      (should (plist-get captured-args :file-handler))
      (should (eq 'pipe (plist-get captured-args :connection-type)))
      (should (equal '("pi" "--version")
                     (plist-get captured-args :command))))))

(ert-deftest pichat-session-path-context-is-immutable-after-launch ()
  (let* ((pichat-path-mappings '(("/host" . "/runtime")))
         (session (pichat-session-make :cwd "/host/project/"))
         (context (pichat-session-path-context session)))
    (setq pichat-path-mappings '(("/other" . "/changed")))
    (should (equal "/runtime/project/file"
                   (pichat-path-to-runtime "/host/project/file" context)))))

(ert-deftest pichat-scope-identity-separates-local-and-remote-mounted-project ()
  (let ((pichat-targets
         '((devbox :kind ssh :tramp-prefix "/ssh:devbox:"
                   :runtime-home "/home/dev"
                   :path-mappings (("/projects" . "/projects")))))
        (pichat-project-target-alist nil))
    (cl-letf (((symbol-function 'pichat--project-root)
               (lambda (&optional _directory) "/projects/app/")))
      (let ((local (pichat--scope-for-directory "/projects/app/" nil 'local))
            (remote (pichat--scope-for-directory "/projects/app/" nil 'devbox)))
        (should-not (equal (car local) (car remote)))
        (should (string-prefix-p "project|local|" (car local)))
        (should (string-prefix-p "project|devbox|" (car remote)))))))

(ert-deftest pichat-rpc-command-for-ssh-uses-target-pi-and-no-host-extension ()
  (let* ((pichat-rpc-command '("docker" "run" "pi" "--mode" "rpc"))
         (pichat-bridge-extension-file "/host/bridge.ts")
         (pichat-pi-extra-args '("--host-only"))
         (transport
          (pichat-transport--create
           :id 'devbox :kind 'ssh :label "devbox"
           :tramp-prefix "/ssh:devbox:"
           :pi-executable "/remote/bin/pi"))
         (session
          (pichat-session-make
           :cwd "/ssh:devbox:/workspace/" :runtime-cwd "/workspace/"
           :transport transport :persistence 'ephemeral
           :startup-model "remote/model"
           :path-context
           (pichat-path-context--create
            :transport-id 'devbox
            :mappings '(("/ssh:devbox:/" . "/")) :strict-p t))))
    (should (equal '("/remote/bin/pi" "--mode" "rpc" "--no-session"
                     "--model" "remote/model")
                   (pichat-rpc-build-command session)))))

(provide 'pichat-test-transport)
;;; pichat-test-transport.el ends here
