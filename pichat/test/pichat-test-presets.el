;;; pichat-test-presets.el --- PiChat preset behavior -*- lexical-binding: t; -*-
;;; Code:
(require 'pichat-test-support)

(ert-deftest pichat-presets-captured-specification-controls-runtime-name ()
  (let* ((spec (pichat-presets-resolve 'coding))
         (tools (pichat-tool-selection-resolve spec))
         (session (pichat-session-make :preset-name 'manual
                                      :preset-spec spec :tool-selection tools)))
    (should (eq 'coding (pichat-session-preset-name session)))
    (should (equal tools (pichat-session-tool-selection session)))
    (let ((previous (pichat-reconfigure-captured-configuration session))
          (replacement (pichat-presets-resolve 'review)))
      (pichat-session-set-configuration
       session replacement (pichat-tool-selection-resolve replacement))
      (should (eq 'review (pichat-session-preset-name session)))
      (pichat-session-set-configuration
       session (plist-get previous :preset-spec) (plist-get previous :tool-selection))
      (should (eq 'coding (pichat-session-preset-name session)))
      (should (equal tools (pichat-session-tool-selection session))))))

(ert-deftest pichat-presets-validate-and-compose-emacs-readable-prompts ()
  (let ((pichat-presets (copy-tree pichat-presets))
        (file (make-temp-file "pichat-preset-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "From Emacs"))
          (pichat-make-preset 'test-compose
            :description "Initial"
            :tools '("read" "read" "write")
            :system-prompt "Replacement"
            :append-system-prompt (list "Before" (list :file file) "After"))
          (let ((snapshot (pichat-presets-resolve 'test-compose)))
            (should (equal '("read" "write") (plist-get snapshot :tools)))
            (should (equal "Replacement\n" (plist-get snapshot :system-prompt)))
            (should (equal "Before\n\nFrom Emacs\n\nAfter\n"
                           (plist-get snapshot :append-system-prompt)))
            (with-temp-file file (insert "Changed"))
            (pichat-make-preset 'test-compose :tools nil)
            (should (equal "Before\n\nFrom Emacs\n\nAfter\n"
                           (plist-get snapshot :append-system-prompt)))
            (should-not (plist-get (pichat-presets-resolve 'test-compose) :tools))))
      (delete-file file))))

(ert-deftest pichat-presets-reject-invalid-registration-and-files ()
  (let ((pichat-presets (copy-tree pichat-presets)))
    (dolist (spec '((:tools ("bash,read")) (:tools ("unknown"))
                    (:tools "read") (:tools nil :tools :default) (:append-system-prompt " ")
                    (:append-system-prompt (:file "relative.md"))
                    (:append-system-prompt (:file "/tmp/a" :extra t))
                    (:typo t) (:tools)))
      (should-error (apply #'pichat-make-preset 'invalid spec) :type 'user-error))
    (should-error (pichat-make-preset 'default :tools nil) :type 'user-error)
    (should-error (pichat-presets-resolve 'unknown) :type 'user-error)
    (pichat-make-preset 'missing :append-system-prompt
      '(:file "/definitely/missing/pichat-preset.md"))
    (should-error (pichat-presets-resolve 'missing) :type 'user-error)))

(ert-deftest pichat-presets-default-reuses-existing-runtime-without-resolution ()
  (pichat-test-with-clean-state
    (let ((pichat-default-preset 'missing))
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_s) t)))
        (let* ((scope '("scope" "/tmp/" "test"))
               (session (pichat-session-make :preset-name 'review)))
          (puthash "scope" session pichat--sessions-by-scope)
          (should (eq session (pichat--preferred-session-for-exact-scope scope)))
          (should (eq 'review (pichat-session-preset-name session))))))))

(ert-deftest pichat-presets-reject-conflicting-generic-tools-before-registration ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-pi-extra-args '("--tools" "bash")))
      (should-error (pichat-start-session "/tmp/" nil '(:preset review))
                    :type 'user-error)
      (should-not (pichat-session-list)))))

(ert-deftest pichat-presets-complete-command-allows-no-op-standard ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command '("wrapper" "pi" "--mode" "rpc")))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/" nil '(:preset standard))))
          (should (eq 'standard (pichat-session-preset-name session)))
          (should (equal pichat-rpc-command (pichat-rpc-build-command session))))))))

(ert-deftest pichat-presets-manual-relies-on-tool-selection-not-execution-instructions ()
  (let ((manual (pichat-presets-resolve 'manual))
        (coding (pichat-presets-resolve 'coding))
        (review (pichat-presets-resolve 'review)))
    (should (equal '("read" "grep" "find" "ls" "edit" "write")
                   (plist-get manual :tools)))
    (should-not (plist-get manual :system-prompt))
    (should-not (plist-get manual :append-system-prompt))
    (should (member "bash" (plist-get coding :tools)))
    (should (plist-get coding :append-system-prompt))
    (should (equal '("read" "grep" "find" "ls") (plist-get review :tools)))
    (should-not (string-match-p
                 "do not .*\\(modify\\|execute\\)"
                 (plist-get review :append-system-prompt)))))

(ert-deftest pichat-presets-ordinary-start-captures-manual-default ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil)
          (pichat-default-preset 'manual))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/")))
          (should (eq 'manual (pichat-session-preset-name session)))
          (should (equal '("read" "grep" "find" "ls" "edit" "write")
                         (plist-get (pichat-session-preset-spec session) :tools)))
          (should (member "--tools" (pichat-rpc-build-command session)))
          (should (member "--no-mcp" (pichat-rpc-build-command session))))))))

(ert-deftest pichat-presets-transient-reader-offers-annotated-default ()
  (let ((pichat-default-preset 'manual))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices _predicate require-match &rest _)
                 (should require-match)
                 (should (member "review" choices))
                 (should (string-match-p "manual"
                          (funcall (plist-get completion-extra-properties
                                              :annotation-function)
                                   "default")))
                 "review")))
      (should (equal "review" (pichat--launch-read-preset "Preset: " nil nil))))))

(ert-deftest pichat-presets-default-selection-keeps-independent-switches ()
  (should (eq 'preferred
              (plist-get (pichat--launch-profile-from-arguments
                          '("--preset=default")) :reuse)))
  (should (eq 'new
              (plist-get (pichat--launch-profile-from-arguments
                          '("--preset=default" "--new")) :reuse)))
  (should-error (pichat--launch-profile-from-arguments '("--preset=missing"))
                :type 'user-error))

(ert-deftest pichat-presets-explicit-tools-restrict-mcp-and-builtins ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let* ((choices '(:builtins ("read") :mcp (("ketch" . "search"))))
               (session (pichat-start-session "/tmp/" nil
                                             (list :preset 'manual :tools choices)))
               (argv (pichat-rpc-build-command session)))
          (should (member "read,mcp__ketch__search" argv))
          (should-not (member "--no-mcp" argv))
          (setcdr (car (plist-get choices :mcp)) "crawl")
          (should (equal '(("ketch" . "search"))
                         (plist-get (pichat-session-tool-selection session) :mcp))))))))

(ert-deftest pichat-presets-empty-tools-disable-everything ()
  (pichat-test-with-clean-state
    (let ((pichat-rpc-command nil))
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
        (let ((session (pichat-start-session "/tmp/" nil
                                             '(:preset review :tools (:builtins nil :mcp nil)))))
          (should (equal '("--no-tools" "--no-mcp")
                         (cl-subseq (member "--no-tools"
                                            (pichat-rpc-build-command session))
                                    0 2))))))))

(ert-deftest pichat-presets-pass-through-rejects-customization ()
  (pichat-test-with-clean-state
    (should-error (pichat-start-session "/tmp/" nil
                                        '(:preset standard :tools (:builtins nil)))
                  :type 'user-error)
    (should-not (pichat-session-list))))

(ert-deftest pichat-presets-shared-prompt-composes-and-captures-one-argument ()
  (pichat-test-with-clean-state
    (let ((pichat-presets (copy-tree pichat-presets))
          (pichat-rpc-command nil)
          (pichat-pi-extra-args nil)
          (file (make-temp-file "pichat-shared-prompt-")))
      (unwind-protect
          (progn
            (with-temp-file file (insert "Shared file"))
            (pichat-make-preset 'test-shared
              :system-prompt "Replacement"
              :append-system-prompt '("Preset one" "Preset two"))
            (let ((pichat-append-system-prompt
                   (list "Shared text" (list :file file))))
              (cl-letf (((symbol-function 'pichat-rpc-start) #'identity))
                (let* ((session (pichat-start-session
                                 "/tmp/" nil '(:preset test-shared)))
                       (argv (pichat-rpc-build-command session))
                       (expected "Preset one\n\nPreset two\n\nShared text\n\nShared file\n"))
                  (should (= 1 (cl-count "--append-system-prompt" argv
                                         :test #'equal)))
                  (should (equal expected
                                 (cadr (member "--append-system-prompt" argv))))
                  (should (equal "Replacement\n"
                                 (cadr (member "--system-prompt" argv))))
                  (with-temp-file file (insert "Changed file"))
                  (setq pichat-append-system-prompt "Changed setting")
                  (should (equal argv (pichat-rpc-build-command session)))
                  (should (equal "Preset one\n\nPreset two\n\nChanged setting\n"
                                 (plist-get (pichat-presets-resolve 'test-shared)
                                            :append-system-prompt)))))))
        (delete-file file)))))

(ert-deftest pichat-presets-shared-prompt-applies-without-preset-additions ()
  (dolist (name '(manual standard))
    (let ((pichat-append-system-prompt "Shared"))
      (let ((snapshot (pichat-presets-resolve name)))
        (should (equal "Shared\n" (plist-get snapshot :append-system-prompt)))
        (should-not (plist-get snapshot :system-prompt))
        (should (pichat-presets-overrides-p snapshot)))))
  (let ((pichat-append-system-prompt nil))
    (should-not (plist-get (pichat-presets-resolve 'standard)
                          :append-system-prompt))))

(ert-deftest pichat-presets-shared-prompt-rejects-invalid-sources ()
  (dolist (source '(" " 42 (:file "relative.md") ("Valid" "")
                    (:file "/definitely/missing/pichat-shared.md")))
    (let ((pichat-append-system-prompt source))
      (should-error (pichat-presets-resolve 'standard) :type 'user-error))))

(ert-deftest pichat-presets-shared-prompt-rejects-conflicting-launch-options ()
  (pichat-test-with-clean-state
    (let ((pichat-append-system-prompt "Shared")
          (pichat-rpc-command nil)
          (pichat-pi-extra-args '("--append-system-prompt" "Other")))
      (should-error (pichat-start-session "/tmp/" nil '(:preset standard))
                    :type 'user-error)
      (setq pichat-pi-extra-args nil
            pichat-rpc-command '("wrapper" "pi" "--mode" "rpc"))
      (should-error (pichat-start-session "/tmp/" nil '(:preset standard))
                    :type 'user-error)
      (should-not (pichat-session-list)))))

(provide 'pichat-test-presets)
;;; pichat-test-presets.el ends here
