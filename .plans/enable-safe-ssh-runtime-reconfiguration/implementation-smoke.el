;;; implementation-smoke.el --- Saved SSH restart implementation check -*- lexical-binding: t; -*-

(require 'pichat-test-ssh)

(ert-deftest pichat-ssh-implementation-saved-restart-smoke ()
  "Reuse the isolated real-SSH fixture, restarting only its saved runtime."
  (let ((open-profile (symbol-function 'pichat--open-launch-profile))
        (wait-until (symbol-function 'pichat-test-wait-until))
        selected exercised)
    (cl-letf (((symbol-function 'pichat--open-launch-profile)
               (lambda (&rest args)
                 (setq selected (apply open-profile args))))
              ((symbol-function 'pichat-test-wait-until)
               (lambda (predicate seconds description)
                 (prog1 (funcall wait-until predicate seconds description)
                   (when (equal description "selected SSH session fully synchronized")
                     ;; The fixture's header-only saved file has transient,
                     ;; unpersisted startup entries.  Persist a real offline
                     ;; turn before testing exact saved-transcript reload.
                     (pichat-test-prompt-and-wait selected "Saved restart fixture" 20)
                     (funcall wait-until
                              (lambda ()
                                (with-current-buffer (pichat-session-buffer selected)
                                  (and (not pichat-chat--sync-in-flight)
                                       (not pichat-chat--sync-pending)
                                       (> (length (pichat-entry-cache-append-order
                                                   (pichat-chat-canonical-entry-cache selected))) 2))))
                              10 "saved source settled")
                     (let* ((old (pichat-session-process selected))
                            (runtime-id (pichat-session-runtime-id selected))
                            (session-id (pichat-session-id selected))
                            (saved-file (pichat-session-session-file selected))
                            (configuration (pichat-reconfigure-captured-configuration selected))
                            (preset (plist-get configuration :preset-spec))
                            result)
                       (should (pichat-process-lifetime-supported-p old))
                       (plist-put preset :append-system-prompt "SSH implementation smoke.\n")
                       (pichat-reconfigure-restart
                        (pichat-reconfigure-capture-origin selected) configuration
                        (lambda (success reason) (setq result (list success reason))))
                       (unwind-protect
                           (funcall wait-until (lambda () result) 35 "SSH implementation restart")
                         (unless result
                           (message "SMOKE timeout phase=%S state=%S pending=%S diagnostics=%S"
                                    (plist-get (pichat-session-restart-operation selected) :phase)
                                    (pichat-session-state selected)
                                    (hash-table-count (pichat-session-pending-responses selected))
                                    (pichat-session-diagnostics selected))))
                       (should (equal result '(t nil)))
                       (should (pichat-process-lifetime-confirmed-p old))
                       (should-not (eq old (pichat-session-process selected)))
                       (should (equal runtime-id (pichat-session-runtime-id selected)))
                       (should (equal session-id (pichat-session-id selected)))
                       (should (pichat-process-lifetime-supported-p (pichat-session-process selected)))
                       (should-not (pichat-session-restart-operation selected))
                       ;; Force a post-stop verification failure, then restore.
                       ;; Recovery must confirm the failed replacement too.
                       (setq configuration (pichat-reconfigure-captured-configuration selected)
                             result nil)
                       (plist-put (plist-get configuration :preset-spec)
                                  :append-system-prompt "Deliberately failing replacement.\n")
                       (cl-letf (((symbol-function 'pichat-reconfigure-validate-reload)
                                  (lambda (&rest _args) (error "Injected reload failure"))))
                         (pichat-reconfigure-restart
                          (pichat-reconfigure-capture-origin selected) configuration
                          (lambda (success reason) (setq result (list success reason))))
                         (funcall wait-until (lambda () result) 35 "injected SSH reload failure"))
                       (should-not (car result))
                       (should (string-match-p "Injected reload failure" (cadr result)))
                       (let ((failed-process (pichat-session-process selected)))
                         (should-not (pichat-process-lifetime-confirmed-p failed-process))
                         (setq result nil)
                         (pichat-reconfigure-recover
                          selected 'restore
                          (lambda (success reason) (setq result (list success reason))))
                         (funcall wait-until (lambda () result) 35 "SSH restore after failed replacement")
                         (should (equal result '(t nil)))
                         (should (pichat-process-lifetime-confirmed-p failed-process))
                         (should (equal runtime-id (pichat-session-runtime-id selected)))
                         (should (equal session-id (pichat-session-id selected)))
                         (should-not (pichat-session-restart-operation selected)))
                       ;; The unwritten path uses target-native file checks
                       ;; and intentionally changes Pi session identity.
                       (with-current-buffer (pichat-session-buffer selected)
                         (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t)))
                           (pichat-chat-new-session)))
                       (funcall wait-until
                                (lambda ()
                                  (and (not (equal session-id (pichat-session-id selected)))
                                       (pichat-reconfigure--empty-unwritten-source-p
                                        (pichat-reconfigure-capture-origin selected))
                                       (with-current-buffer (pichat-session-buffer selected)
                                         (and (not pichat-chat--sync-in-flight)
                                              (not pichat-chat--sync-pending)))))
                                15 "SSH unwritten source settled")
                       (let ((unwritten-id (pichat-session-id selected)))
                         (setq configuration (pichat-reconfigure-captured-configuration selected)
                               result nil)
                         (plist-put (plist-get configuration :preset-spec)
                                    :append-system-prompt "Unwritten SSH replacement.\n")
                         (pichat-reconfigure-restart
                          (pichat-reconfigure-capture-origin selected) configuration
                          (lambda (success reason) (setq result (list success reason))))
                         (funcall wait-until (lambda () result) 35 "unwritten SSH restart")
                         (should (equal result '(t nil)))
                         (should-not (equal unwritten-id (pichat-session-id selected)))
                         (should (equal runtime-id (pichat-session-runtime-id selected))))
                       ;; Return the enclosing launch fixture to its source.
                       (pichat-test-rpc-call selected "switch_session"
                                            (list :sessionPath saved-file) 15)
                       (pichat-test-rpc-call selected "get_state" nil 15)
                       (funcall wait-until
                                (lambda ()
                                  (with-current-buffer (pichat-session-buffer selected)
                                    (and (not pichat-chat--sync-in-flight)
                                         (not pichat-chat--sync-pending)
                                         (equal saved-file
                                                (pichat-entry-cache-session-file
                                                 (pichat-chat-canonical-entry-cache selected))))))
                                10 "enclosing saved-source fixture settled")
                       (should (equal saved-file (pichat-session-session-file selected)))
                       (setq exercised t)))))))
      (funcall (ert-test-body
                (ert-get-test 'pichat-integration-ssh-rpc-streams-and-stops-cleanly))))
    (should exercised)))
