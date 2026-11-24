;;; pichat-test-startup-cache.el --- Startup cache filesystem fixtures -*- lexical-binding: t; -*-

(require 'ert)
(require 'pichat-test-support)
(require 'pichat-startup-cache)
(require 'pichat-tool-runtime)

(defmacro pichat-test-startup-cache--with-fixture (&rest body)
  "Run BODY with real filesystem operations, but no SSH connection."
  (declare (indent 0) (debug t))
  `(let* ((fixture (file-truename (make-temp-file "pichat-startup-cache-" t)))
          (root (expand-file-name "cache with 'spaces' and ~$" fixture))
          (helper (expand-file-name "helper" fixture))
          (skill (expand-file-name "skill" fixture))
          (transport (pichat-transport--create
                      :kind 'ssh :id 'cache-fixture :label "cache-fixture"
                      :tramp-prefix "/ssh:cache.invalid:" :startup-cache-root root))
          (call (symbol-function 'process-file))
          (copy (symbol-function 'copy-file))
          (after-command nil) (before-copy nil) (uploads nil) (operations nil))
     (ignore uploads operations)
     (unwind-protect
         (cl-letf (((symbol-function 'process-file)
                    (lambda (&rest args)
                      (should (file-remote-p default-directory))
                      (push (cons (file-remote-p default-directory) (nth 7 args)) operations)
                      (let ((status (let ((default-directory "/")) (apply call args))))
                        (when after-command (funcall after-command (nth 7 args) status))
                        status)))
                   ((symbol-function 'copy-file)
                    (lambda (source dest &rest args)
                      (push (cons (file-remote-p dest) source) uploads)
                      (when before-copy (funcall before-copy source dest))
                      (apply copy source (file-local-name dest) args))))
           (write-region "helper bytes\n" nil helper nil 'silent)
           (write-region "skill bytes\n" nil skill nil 'silent)
           ,@body)
       (delete-directory fixture t))))

(defun pichat-test-startup-cache--bytes (file)
  "Read literal bytes from FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun pichat-test-startup-cache--staging (root)
  "List staging directories under fixture ROOT."
  (directory-files-recursively root "\\`\\.stage\\." t))

(ert-deftest pichat-startup-cache-cold-warm-and-changed-bytes ()
  (pichat-test-startup-cache--with-fixture
    (let ((helper-link (concat helper "-link")) (skill-link (concat skill "-link")))
      (make-symbolic-link helper helper-link)
      (make-symbolic-link skill skill-link)
      (let* ((cold (let ((default-directory "/ssh:unrelated.invalid:/project/"))
                     (pichat-startup-cache-acquire transport helper-link skill-link)))
             (old (plist-get cold :path))
             (old-skill (plist-get cold :skill)))
        (should (= (length uploads) 2))
        (should (= (length operations) 6))
        (should (equal (mapcar #'cdr uploads) (list skill helper)))
        (setq operations nil uploads nil)
        (should (equal cold (pichat-startup-cache-acquire transport helper-link skill-link)))
        (should (= (length operations) 2))
        (should-not uploads)
        (should (string-suffix-p "/pichat-jobs/SKILL.md" old-skill))
        (should (= #o400 (file-modes old)))
        (should (equal (pichat-test-startup-cache--bytes old-skill) "skill bytes\n"))
        (write-region (unibyte-string 0 255 13 10) nil helper nil 'silent)
        (let* ((updated (pichat-startup-cache-acquire transport helper-link skill-link))
               (new (plist-get updated :path)))
          (should (= (length uploads) 1))
          (should-not (equal new old))
          (should (equal (plist-get updated :skill) old-skill))
          (should (equal (pichat-test-startup-cache--bytes new) (unibyte-string 0 255 13 10)))
          (should-not (plist-get cold :cleanup))
          (should (equal (pichat-test-startup-cache--bytes old) "helper bytes\n"))
          (should-not (pichat-test-startup-cache--staging root)))))))

(ert-deftest pichat-startup-cache-target-paths-and-optional-skill ()
  (pichat-test-startup-cache--with-fixture
    (let* ((peer-root (concat root "-peer"))
           (pichat-targets
            `((peer :tramp-prefix "/ssh:peer.invalid:" :startup-cache-root ,peer-root)))
           (peer (pichat-transport-resolve fixture 'peer))
           (first (pichat-startup-cache-acquire transport helper)))
      (setq pichat-targets nil operations nil uploads nil)
      (let ((second (pichat-startup-cache-acquire peer helper)))
        (should-not (plist-get first :skill))
        (should-not (plist-get second :skill))
        (should (string-prefix-p (concat peer-root "/") (plist-get second :path)))
        (should (equal (mapcar #'car uploads) '("/ssh:peer.invalid:")))
        (should (cl-every (lambda (op) (equal (car op) "/ssh:peer.invalid:")) operations))))))

(ert-deftest pichat-startup-cache-concurrent-publication-keeps-first-inode ()
  (pichat-test-startup-cache--with-fixture
    (let (winner inode)
      (setq before-copy
            (lambda (_source _dest)
              ;; Model a second Emacs: it observes the miss while our stage
              ;; exists, then publishes before our in-flight upload completes.
              (setq before-copy nil)
              (let ((pichat-transport--active-connections nil))
                (setq winner (pichat-startup-cache-acquire transport helper)
                      inode (file-attribute-inode-number
                             (file-attributes (plist-get winner :path)))))))
      (let ((ours (pichat-startup-cache-acquire transport helper)))
        (should (equal winner ours)))
      (should (= (length uploads) 2))
      (should (equal inode (file-attribute-inode-number
                            (file-attributes (plist-get winner :path)))))
      (should-not (pichat-test-startup-cache--staging root)))))

(ert-deftest pichat-startup-cache-rejects-corrupt-unsafe-and-symlink-entries ()
  (pichat-test-startup-cache--with-fixture
    (let ((path (plist-get (pichat-startup-cache-acquire transport helper) :path)))
      (setq uploads nil)
      (set-file-modes path #o600)
      (should-error (pichat-startup-cache-acquire transport helper))
      (write-region "corrupt" nil path nil 'silent)
      (set-file-modes path #o400)
      (let ((failure (should-error (pichat-startup-cache-acquire transport helper))))
        (should (string-match-p "SHA-256 mismatch" (error-message-string failure))))
      (should (equal (pichat-test-startup-cache--bytes path) "corrupt"))
      (delete-file path)
      (make-symbolic-link (concat path "-missing") path)
      (should-error (pichat-startup-cache-acquire transport helper))
      (should (file-symlink-p path))
      (should-not uploads))))

(ert-deftest pichat-startup-cache-rejects-untrusted-directory-chain ()
  (pichat-test-startup-cache--with-fixture
    (let ((elsewhere (make-temp-file (expand-file-name "elsewhere" fixture) t)))
      (make-symbolic-link elsewhere root)
      (should-error (pichat-startup-cache-acquire transport helper))
      (delete-file root)
      (make-directory root)
      (set-file-modes root #o755)
      (should-error (pichat-startup-cache-acquire transport helper))
      (set-file-modes root #o700)
      (set-file-modes fixture #o777)
      (unwind-protect
          (should-error (pichat-startup-cache-acquire transport helper))
        (set-file-modes fixture #o700))
      (should-not uploads))))

(ert-deftest pichat-startup-cache-cleans-stage-on-failed-copy-or-publish ()
  (pichat-test-startup-cache--with-fixture
    (setq before-copy (lambda (_source _dest) (error "fixture copy failure")))
    (should-error (pichat-startup-cache-acquire transport helper))
    (should-not (pichat-test-startup-cache--staging root))
    (setq before-copy (lambda (source _dest)
                        (write-region "changed after hashing" nil source nil 'silent)))
    (let ((failure (should-error (pichat-startup-cache-acquire transport helper))))
      (should (string-match-p "SHA-256 mismatch" (error-message-string failure))))
    (should-not (directory-files-recursively root "pichat-tool-control\\.ts\\'"))
    (should-not (pichat-test-startup-cache--staging root))))

(ert-deftest pichat-startup-cache-quit-cleans-stage-and-propagates ()
  (dolist (interrupt '(probe copy))
    (pichat-test-startup-cache--with-fixture
      (setq after-command
            (lambda (op status)
              (should-not inhibit-quit)
              (should (eql status 0))
              (when (and (eq interrupt 'probe) (equal op "probe"))
                ;; The shell has allocated staging, but Lisp has no reply yet.
                (should (= 1 (length (pichat-test-startup-cache--staging root))))
                (signal 'quit '(probe)))))
      (when (eq interrupt 'copy)
        (setq before-copy
              (lambda (source dest)
                (should-not inhibit-quit)
                (funcall copy source (file-local-name dest))
                (signal 'quit '(copy)))))
      (should (equal (condition-case err
                         (pichat-startup-cache-acquire transport helper)
                       (quit err))
                     (list 'quit interrupt)))
      (should (equal (mapcar #'cdr operations) '("clean" "probe")))
      (should-not (pichat-test-startup-cache--staging root))
      (should-not (directory-files-recursively root "pichat-tool-control\\.ts\\'")))))

(ert-deftest pichat-startup-cache-stage-collision-preserves-peer-storage ()
  (pichat-test-startup-cache--with-fixture
    (let* ((name ".stage.fixture")
           (peer-stage (expand-file-name (concat "v1-helper/" name) root))
           (peer-asset (expand-file-name "asset" peer-stage)))
      (make-directory peer-stage t)
      (dolist (dir (list root (file-name-directory peer-stage) peer-stage))
        (set-file-modes dir #o700))
      (write-region "peer bytes" nil peer-asset nil 'silent)
      (cl-letf (((symbol-function 'pichat-startup-cache--stage-name) (lambda () name)))
        (let ((failure (should-error (pichat-startup-cache-acquire transport helper))))
          (should (string-match-p "staging name already exists" (error-message-string failure)))))
      (should (equal (pichat-test-startup-cache--bytes peer-asset) "peer bytes"))
      (should-not uploads))))

(ert-deftest pichat-startup-cache-runtime-stop-retains-helper-and-skill ()
  (dolist (confirmed '(nil t))
    (pichat-test-startup-cache--with-fixture
      (pichat-test-with-unit-session (session process)
        (setf (pichat-session-transport session) transport)
        (let* ((pichat-tool-discovery-helper helper)
               (path (pichat-tool-runtime-prepare session nil skill))
               (control (pichat-session-rpc-startup-control session))
               (skill-path (plist-get (plist-get control :helper) :skill)))
          (setf (plist-get control :process) process)
          (when confirmed (pichat-process-lifetime-confirm process))
          (pichat-rpc-stop session)
          ;; The unit process has no RPC sentinel; explicitly deliver its exit.
          (process-put process 'pichat-session session)
          (process-put process 'pichat-process-generation
                       (pichat-session-process-generation session))
          (pichat-rpc--process-sentinel process "finished")
          (should-not (pichat-session-rpc-startup-control session))
          (should-not (process-get process 'pichat-helper-cleanup))
          (should (eq confirmed (pichat-process-lifetime-confirmed-p process)))
          (unless confirmed
            (should (string-match-p
                     "actual Pi exit is unverified"
                     (plist-get (pichat-chat-diagnostics-latest session) :message))))
          (should (equal "helper bytes\n" (pichat-test-startup-cache--bytes path)))
          (should (equal "skill bytes\n" (pichat-test-startup-cache--bytes skill-path)))
          (should-not (pichat-test-startup-cache--staging root)))))))

(ert-deftest pichat-startup-cache-probe-reuses-runtime-path-and-preserves-it-on-failure ()
  (pichat-test-startup-cache--with-fixture
    (let* ((pichat-tool-discovery-helper helper)
           (session (pichat-session-make :transport transport))
           (path (pichat-tool-runtime-prepare session nil skill))
           result child)
      (setq uploads nil operations nil)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-transport-make-process)
                     (lambda (target _cwd &rest args)
                       (should (eq target transport))
                       (should (equal path (cadr (member "--extension" (plist-get args :command)))))
                       (should-not (member "--skill" (plist-get args :command)))
                       (setq child (make-process :name "pichat-cache-probe" :noquery t
                                                 :command '("sh" "-c" "exit 1")
                                                 :sentinel (plist-get args :sentinel))))))
            (pichat-tool-discovery-start transport "/fixture/" "pi"
                                         (lambda (&rest value) (setq result value)) :args nil)
            (pichat-test-wait-until (lambda () result) 2 "cache probe failure")
            (should-not (car result))
            (should (string-match-p "Remote tool probe exit is uncertain" (cadr result)))
            (should-not uploads)
            (should (equal (mapcar #'cdr operations) '("probe")))
            (should (equal "helper bytes\n" (pichat-test-startup-cache--bytes path))))
        (when (process-live-p child) (delete-process child))
        (pichat-tool-runtime-dispose session)))))

(ert-deftest pichat-startup-cache-probe-cancellation-suppresses-spawn-and-callback ()
  (dolist (timing '(queued in-copy))
    (pichat-test-startup-cache--with-fixture
      (let ((pichat-tool-discovery-helper helper) cancel copied spawned replied)
        (setq before-copy (lambda (&rest _)
                            (setq copied t)
                            (funcall cancel)))
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (&rest _) (setq spawned t) (error "Unexpected probe spawn"))))
          (unwind-protect
              (progn
                (setq cancel (pichat-tool-discovery-start
                              transport "/fixture/" "pi"
                              (lambda (&rest _) (setq replied t)) :args nil))
                (if (eq timing 'queued)
                    (progn (funcall cancel) (accept-process-output nil 0.1)
                           (should-not operations))
                  (pichat-test-wait-until (lambda () copied) 2 "cancellation inside cache copy")
                  (should-not (pichat-test-startup-cache--staging root))
                  (should (equal (mapcar #'cdr operations) '("clean" "publish" "probe"))))
                (should-not spawned)
                (should-not replied))
            (when cancel (funcall cancel))))))))

(ert-deftest pichat-startup-cache-runtime-stop-during-acquisition-prevents-spawn ()
  (pichat-test-startup-cache--with-fixture
    (pichat-test-with-unit-session (session)
      (setf (pichat-session-transport session) transport)
      (let ((pichat-tool-discovery-helper helper) spawned)
        (setq before-copy (lambda (&rest _) (pichat-rpc-stop session)))
        (cl-letf (((symbol-function 'pichat-transport-make-process)
                   (lambda (&rest _) (setq spawned t) (error "Unexpected RPC spawn"))))
          (should (eq session (pichat-rpc-start session '("pi" "--no-skills"))))
          (should-not spawned)
          (should (eq 'stopped (pichat-session-state session)))
          (should-not (pichat-session-rpc-startup-control session))
          (should (equal (mapcar #'cdr uploads) (list helper)))
          (should-not (pichat-test-startup-cache--staging root)))))))

(provide 'pichat-test-startup-cache)
;;; pichat-test-startup-cache.el ends here
