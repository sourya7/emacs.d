;;; pichat-test-ssh-startup-cache.el --- Isolated real SSH cache reuse -*- lexical-binding: t; -*-

(require 'pichat-test-real-ssh-support)
(require 'pichat-startup-cache)

(defun pichat-test-ssh-cache--digest (file)
  "Hash the literal bytes at FILE (local or TRAMP)."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun pichat-test-ssh-cache--verify (transport path digest)
  "Check the published native PATH independently of cache acquisition."
  (let ((file (pichat-transport-runtime-file-name transport path)))
    (should-not (file-symlink-p file))
    (should (file-regular-p file))
    (should (= #o400 (file-modes file)))
    (should (= #o700 (file-modes (file-name-directory file))))
    (should (equal digest (pichat-test-ssh-cache--digest file)))))

(defun pichat-test-ssh-cache--probe (session)
  "Run a fresh discovery probe without sending a model turn."
  (let* ((transport (pichat-session-transport session))
         result
         (cancel (pichat-tool-discovery-start
                  transport (pichat-session-runtime-cwd session)
                  (pichat-transport-pi-executable transport)
                  (lambda (tools error) (setq result (list tools error)))
                  :model (pichat-session-startup-model session))))
    (unwind-protect
        (progn
          (pichat-test-wait-until (lambda () result) 30 "SSH cache discovery probe")
          (should-not (cadr result)) ; includes unsuccessful or uncertain exit
          (should (cl-find "probe_child" (car result) :test #'equal
                           :key (lambda (tool) (plist-get tool :name)))))
      (funcall cancel))))

(ert-deftest pichat-integration-ssh-startup-cache-reuses-and-retains-versions ()
  "A cold runtime publishes both assets; warm consumers verify without uploads."
  (let* ((scratch (make-temp-file "pichat-ssh-symlinks-" t))
         (helper (expand-file-name "helper.ts" scratch))
         (skill (expand-file-name "SKILL.md" scratch))
         (prepare (symbol-function 'pichat-tool-discovery-prepare-helper))
         (command (symbol-function 'pichat-startup-cache--command))
         (copy (symbol-function 'copy-file))
         (uploads 0) (operations 0) assets)
    (unwind-protect
        (progn
          (copy-file (file-truename pichat-tool-discovery-helper) helper)
          (copy-file (file-truename pichat-rpc-job-authoring-skill) skill)
          (let ((pichat-tool-discovery-helper (expand-file-name "linked.ts" scratch))
                (pichat-rpc-job-authoring-skill (expand-file-name "linked.md" scratch)))
            (make-symbolic-link helper pichat-tool-discovery-helper)
            (make-symbolic-link skill pichat-rpc-job-authoring-skill)
            (cl-letf (((symbol-function 'pichat-tool-discovery-prepare-helper)
                       (lambda (&rest args) (setq assets (apply prepare args))))
                      ((symbol-function 'pichat-startup-cache--command)
                       (lambda (&rest args) (cl-incf operations) (apply command args)))
                      ((symbol-function 'copy-file)
                       (lambda (from to &rest args)
                         (when (and (file-remote-p to)
                                    (string-match-p "/\\.pichat-assets/" to))
                           ;; The copy must receive the dereferenced local source.
                           (should (member from (list helper skill)))
                           (cl-incf uploads))
                         (apply copy from to args))))
              (cl-labels ((counts (label expected-uploads)
                            (message "SSH startup cache %s: %d uploads, %d cache shell calls"
                                     label uploads operations)
                            (should (= expected-uploads uploads))
                            (should (> operations 0))
                            (setq uploads 0 operations 0))
                          (has-skill (session)
                            (let ((commands (plist-get
                                             (plist-get (pichat-test-rpc-call session "get_commands") :data)
                                             :commands)))
                              (should (cl-find "skill:pichat-jobs" commands :test #'equal
                                               :key (lambda (item) (plist-get item :name)))))))
                (pichat-test-real-ssh--run
                 (lambda (fixture)
                   (let* ((session (plist-get fixture :session))
                          (transport (pichat-session-transport session))
                          (old-helper (plist-get assets :path))
                          (old-skill (plist-get assets :skill))
                          (helper-hash (pichat-test-ssh-cache--digest helper))
                          (skill-hash (pichat-test-ssh-cache--digest skill))
                          (configuration (pichat-reconfigure-captured-configuration session))
                          (coding (pichat-reconfigure-select-preset configuration 'coding)))
                     (counts "cold runtime" 2)
                     (has-skill session)
                     (should (string-suffix-p "/pichat-jobs/SKILL.md" old-skill))
                     (should (equal '(t nil) (pichat-test-real-ssh--restart session coding)))
                     (counts "warm runtime" 0)
                     (has-skill session)
                     (should (equal assets (list :path old-helper :skill old-skill)))
                     (pichat-test-ssh-cache--probe session)
                     (counts "warm probe" 0)
                     (should (equal assets (list :path old-helper :skill nil)))
                     (write-region "\n// Cache version two\n" nil helper t 'silent)
                     (write-region "\nCache version two.\n" nil skill t 'silent)
                     (pichat-test-ssh-cache--probe session)
                     (counts "changed helper probe" 1)
                     (let ((new-helper (plist-get assets :path))
                           (old-process (pichat-session-process session)))
                       (should-not (equal old-helper new-helper))
                       (should (pichat-test-real-ssh--alive-p fixture old-process))
                       (pichat-test-ssh-cache--verify transport old-helper helper-hash)
                       (pichat-test-ssh-cache--verify transport old-skill skill-hash)
                       (should (equal '(t nil) (pichat-test-real-ssh--restart session configuration)))
                       (counts "changed skill runtime" 1)
                       (has-skill session)
                       (let ((new-skill (plist-get assets :skill)))
                         (should (equal new-helper (plist-get assets :path)))
                         (should-not (equal old-skill new-skill))
                         (should-not (pichat-test-real-ssh--alive-p fixture old-process))
                         (pichat-test-ssh-cache--probe session)
                         (counts "warm probe after change" 0)
                         (should (equal assets (list :path new-helper :skill nil)))
                         (pichat-test-real-ssh--stop-starter fixture)
                         (pichat-test-ssh-cache--verify transport old-helper helper-hash)
                         (pichat-test-ssh-cache--verify transport old-skill skill-hash)
                         (pichat-test-ssh-cache--verify transport new-helper
                                                        (pichat-test-ssh-cache--digest helper))
                         (pichat-test-ssh-cache--verify transport new-skill
                                                        (pichat-test-ssh-cache--digest skill))
                         (let ((cache (expand-file-name ".pichat-assets/"
                                                        (plist-get fixture :root))))
                           (should (= #o700 (file-modes cache)))
                           (dolist (kind '("v1-helper" "v1-skill"))
                             (should-not (directory-files (expand-file-name kind cache)
                                                          nil "\\`\\.stage\\."))))))))
                 t)))))
      (delete-directory scratch t))))

(provide 'pichat-test-ssh-startup-cache)
;;; pichat-test-ssh-startup-cache.el ends here
