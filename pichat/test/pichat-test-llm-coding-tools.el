;;; pichat-test-llm-coding-tools.el --- Bounded native coding tool tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Isolated local-filesystem fixtures.  These tests perform no network access,
;; start no provider, and never inspect user credentials or configuration.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-llm-support)
(require 'pichat-llm-coding-tools)

(declare-function pichat-llm--context-with-tools "pichat-backend-llm"
                  (base names directory))

(defun pichat-test-coding-tool--call (name params &optional session)
  "Call registered coding tool NAME with PARAMS and optional SESSION."
  (let ((tool (gethash name pichat-tools-registry)))
    (should tool)
    (pichat-tools-call tool params session)))

(defun pichat-test-coding-tool--value (name params &optional session)
  "Return successful coding tool NAME value for PARAMS and SESSION."
  (let ((result (pichat-test-coding-tool--call name params session)))
    (should-not (plist-get result :is-error))
    (plist-get result :value)))

(defun pichat-test-coding-tool--error (name params &optional session)
  "Return coding tool NAME error value for PARAMS and SESSION."
  (let ((result (pichat-test-coding-tool--call name params session)))
    (should (plist-get result :is-error))
    (plist-get result :value)))

(defun pichat-test-coding-tool--call-async (name params &optional session)
  "Run asynchronous tool NAME with PARAMS and optional SESSION to completion."
  (let ((tool (gethash name pichat-tools-registry)) result)
    (should tool)
    (pichat-tools-call-async
     tool params (lambda (value) (setq result value)) session)
    (pichat-test-wait-until (lambda () result) 3 "coding tool callback")
    result))

(ert-deftest pichat-llm-coding-tools-require-explicit-registration-and-selection ()
  "Loading is inert; explicit registration returns the selectable bounded set."
  (pichat-test-with-clean-state
    (should-not (gethash "read" pichat-tools-registry))
    (should (equal '("read" "find" "grep" "write" "edit" "bash" "ls")
                   pichat-llm-coding-tool-names))
    (should (equal '("read" "find" "grep" "write" "edit" "bash" "ls")
                   pichat-llm-coding-tool-default-names))
    (should (equal pichat-llm-coding-tool-default-names
                   (pichat-llm-coding-tools-register)))
    (dolist (name pichat-llm-coding-tool-names)
      (let ((tool (gethash name pichat-tools-registry)))
        (should (pichat-tool-p tool))
        (should (stringp (pichat-tool-instructions tool)))
        (should-not (eq t (plist-get (pichat-tool-parameters tool)
                                     :additionalProperties)))))
    (dolist (name '("read" "find" "grep" "ls"))
      (should-not (pichat-tool-mutating-p
                   (gethash name pichat-tools-registry))))
    (should (pichat-tool-async-p (gethash "find" pichat-tools-registry)))
    (should (pichat-tool-async-p (gethash "grep" pichat-tools-registry)))
    (should (pichat-tool-mutating-p
             (gethash "write" pichat-tools-registry)))
    (should (pichat-tool-mutating-p
             (gethash "edit" pichat-tools-registry)))
    (should (pichat-tool-async-p (gethash "bash" pichat-tools-registry)))
    (should (eq 'allow (pichat-approval-resolve "find" nil)))
    (should (eq 'allow (pichat-approval-resolve "grep" nil)))
    (should (eq 'ask (pichat-approval-resolve "bash" t)))
    (should (string-match-p
             "Use offset/limit"
             (pichat-tool-description (gethash "read" pichat-tools-registry))))
    (should (string-match-p
             "oldText must match exactly one"
             (pichat-tool-description (gethash "edit" pichat-tools-registry))))
    (should (string-match-p
             "always enforces a timeout"
             (pichat-tool-description (gethash "bash" pichat-tools-registry))))
    (let* ((wire (json-parse-string
                  (pichat-tools-definitions-json)
                  :object-type 'plist :array-type 'list :false-object nil))
           (names (mapcar (lambda (tool) (plist-get tool :name))
                          (plist-get wire :tools))))
      (dolist (name pichat-llm-coding-tool-names)
        (should-not (member name names))))))

(ert-deftest pichat-llm-coding-tools-read-list-search-are-bounded ()
  "Read, directory, and literal search results obey explicit fixture bounds."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir)
            (pichat-llm-coding-tools-max-output-chars 10000)
            (pichat-llm-coding-tools-max-read-lines 2)
            (pichat-llm-coding-tools-max-directory-entries 2))
        (pichat-llm-coding-tools-register)
        (make-directory (expand-file-name "sub" dir))
        (write-region "alpha\nneedle one\nomega\n" nil
                      (expand-file-name "a.txt" dir) nil 'silent)
        (write-region "needle two\n" nil
                      (expand-file-name "b.txt" dir) nil 'silent)
        (write-region "needle three\n" nil
                      (expand-file-name "sub/c.txt" dir) nil 'silent)
        (let ((read (pichat-test-coding-tool--value
                     "read" '(:path "a.txt" :offset 2 :limit 99)))
              (listing (pichat-test-coding-tool--value
                        "ls" '(:path "." :limit 99)))
              (search-result (pichat-test-coding-tool--call-async
                              "grep"
                              '(:path "." :pattern "needle"
                                :limit 1)))
              search)
          (should-not (plist-get search-result :is-error))
          (setq search (plist-get search-result :value))
          (should (string-search "needle one\nomega" read))
          (should-not (string-match-p "alpha" read))
          (should (string-match-p "entry limit reached" listing))
          (should (= 1 (length (seq-filter
                                (lambda (line) (string-match-p ":.*needle" line))
                                (split-string search "\n" t)))))
          (should (string-match-p "matching-line limit reached" search)))))))

(ert-deftest pichat-llm-coding-tools-confine-paths-and-reject-remote-or-binary ()
  "Traversal, escaping symlinks, remote roots, and non-UTF-8 input fail safely."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (pichat-test-with-temp-dir outside
        (let ((default-directory dir))
          (pichat-llm-coding-tools-register)
          (write-region "outside" nil (expand-file-name "outside.txt" outside)
                        nil 'silent)
          (make-symbolic-link outside (expand-file-name "escape" dir))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (unibyte-string 255 254))
            (let ((coding-system-for-write 'no-conversion))
              (write-region nil nil (expand-file-name "binary.txt" dir)
                            nil 'silent)))
          (should (string-match-p
                   "escapes"
                   (pichat-test-coding-tool--error
                    "read" '(:path "../outside.txt"))))
          (should (string-match-p
                   "escapes"
                   (pichat-test-coding-tool--error
                    "read" '(:path "escape/outside.txt"))))
          (should (string-match-p
                   "UTF-8"
                   (pichat-test-coding-tool--error
                    "read" '(:path "binary.txt")))))))
    (let ((default-directory "/ssh:pichat-invalid.example:/tmp/"))
      (pichat-llm-coding-tools-register)
      (should (string-match-p
               "remote"
               (pichat-test-coding-tool--error
                "ls" '(:path ".")))))))

(ert-deftest pichat-llm-coding-tools-create-and-edit-are-guarded-and-atomic ()
  "Create refuses overwrite; edit requires a unique, current exact match."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (should (string-match-p
                 "Created created.txt"
                 (pichat-test-coding-tool--value
                  "write"
                  '(:path "created.txt" :content "first\nsecond\n"))))
        (should (= #o600
                   (logand #o777 (file-modes (expand-file-name "created.txt" dir)))))
        (should (string-match-p
                 "creates new files only"
                 (pichat-test-coding-tool--error
                  "write"
                  '(:path "created.txt" :content "overwrite"))))
        (let* ((path (expand-file-name "created.txt" dir))
               (digest (secure-hash 'sha256
                                    (with-temp-buffer
                                      (set-buffer-multibyte nil)
                                      (insert-file-contents-literally path)
                                      (buffer-string)))))
          (should (string-match-p
                   "Edited created.txt"
                   (pichat-test-coding-tool--value
                    "edit"
                    `(:path "created.txt" :oldText "first"
                      :newText "changed" :expectedSha256 ,digest))))
          (should (equal "changed\nsecond\n"
                         (with-temp-buffer
                           (insert-file-contents path)
                           (buffer-string))))
          (should (string-match-p
                   "does not match"
                   (pichat-test-coding-tool--error
                    "edit"
                    '(:path "created.txt" :oldText "changed"
                      :newText "bad"
                      :expectedSha256
                      "0000000000000000000000000000000000000000000000000000000000000000"))))
          (write-region "same same" nil path nil 'silent)
          (should (string-match-p
                   "not unique"
                   (pichat-test-coding-tool--error
                    "edit"
                    '(:path "created.txt" :oldText "same" :newText "one")))))))))

(ert-deftest pichat-llm-coding-tools-reject-unsaved-buffer-edits ()
  "A modified visiting buffer prevents disk mutation and retains both versions."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let* ((default-directory dir)
             (path (expand-file-name "guarded.txt" dir))
             buffer)
        (pichat-llm-coding-tools-register)
        (write-region "disk text" nil path nil 'silent)
        (unwind-protect
            (progn
              (setq buffer (find-file-noselect path))
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert " unsaved"))
              (should (string-match-p
                       "unsaved Emacs buffer"
                       (pichat-test-coding-tool--error
                        "edit"
                        '(:path "guarded.txt" :oldText "disk"
                          :newText "changed"))))
              (should (equal "disk text"
                             (with-temp-buffer
                               (insert-file-contents path)
                               (buffer-string))))
              (with-current-buffer buffer
                (should (equal "disk text unsaved" (buffer-string)))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (set-buffer-modified-p nil))
            (kill-buffer buffer)))))))

(ert-deftest pichat-llm-coding-tools-use-owning-session-directory ()
  "Structured execution binds an owning session's directory, not caller cwd."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir root
      (pichat-test-with-temp-dir caller
        (pichat-llm-coding-tools-register)
        (write-region "owned" nil (expand-file-name "owned.txt" root)
                      nil 'silent)
        (let ((default-directory caller)
              (session (pichat-session-make :cwd root :emacs-cwd root)))
          (should (string-match-p
                   "owned"
                   (pichat-test-coding-tool--value
                    "read" '(:path "owned.txt") session))))))))

(ert-deftest pichat-llm-coding-tools-mutations-require-approval-and-denial-is-inert ()
  "The real write tool asks by default; denial leaves the filesystem untouched."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir)
            (pichat-approval-policy-file (expand-file-name "approvals.el" dir)))
        (pichat-llm-coding-tools-register)
        (should (eq 'ask (pichat-approval-resolve "write" t)))
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (&rest _args) "Deny once")))
          (should-not
           (pichat-approval-approve-p
            "write" t '(:path "denied.txt" :content "no"))))
        (should-not (file-exists-p (expand-file-name "denied.txt" dir)))
        (should-error
         (pichat-tools-execute-json
          "{\"name\":\"write\",\"params\":{\"path\":\"denied.txt\",\"content\":\"no\"}}")
         :type 'error)))))

(ert-deftest pichat-llm-coding-tools-bash-bounds-output-and-times-out ()
  "The canonical bash tool is asynchronous, bounded, and always timed."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir)
            (pichat-llm-coding-tools-max-output-chars 80)
            (pichat-llm-coding-tools-command-timeout 1)
            (pichat-llm-coding-tools-max-command-timeout 2))
        (pichat-llm-coding-tools-register)
        (let ((success (pichat-test-coding-tool--call-async
                        "bash"
                        '(:command "printf 'abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz'"))))
          (should-not (plist-get success :is-error))
          (should (<= (length (plist-get success :value)) 80))
          (should (string-match-p "truncated" (plist-get success :value))))
        (let ((timeout (pichat-test-coding-tool--call-async
                        "bash" '(:command "sleep 2" :timeout 1))))
          (should (plist-get timeout :is-error))
          (should (string-match-p "timed out after 1 second"
                                  (plist-get timeout :value))))))))

(ert-deftest pichat-llm-coding-tools-bash-resolves-bare-emacs-shell-name ()
  "A configured shell name is found through exec-path before execution."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let* ((default-directory dir)
             (shell (or (executable-find "sh")
                        (ert-fail "Test requires a local sh executable")))
             (shell-file-name "fixture-shell"))
        (pichat-llm-coding-tools-register)
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (name)
                     (and (equal name "fixture-shell") shell))))
          (let ((result (pichat-test-coding-tool--call-async
                         "bash" '(:command "printf resolved"))))
            (should-not (plist-get result :is-error))
            (should (equal (plist-get result :value) "resolved"))))
        (let ((shell-file-name "missing-fixture-shell"))
          (cl-letf (((symbol-function 'executable-find) (lambda (_name) nil)))
            (let ((result (pichat-test-coding-tool--call-async
                           "bash" '(:command "printf unreachable"))))
              (should (plist-get result :is-error))
              (should (string-match-p
                       "Configured Emacs shell is unavailable: missing-fixture-shell"
                       (plist-get result :value))))))))))

(ert-deftest pichat-llm-coding-tools-bash-cancellation-stops-side-effects ()
  "Cancelling an executing command suppresses its callback and later mutation."
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir)
            (pichat-llm-coding-tools-command-timeout 5)
            callback-called)
        (pichat-llm-coding-tools-register)
        (let* ((tool (gethash "bash" pichat-tools-registry))
               (cancel
                (pichat-tools-call-async
                 tool '(:command "sleep 1; printf late > cancelled.txt")
                 (lambda (_result) (setq callback-called t)))))
          (should (functionp cancel))
          (funcall cancel)
          (accept-process-output nil 1.2)
          (should-not callback-called)
          (should-not (file-exists-p (expand-file-name "cancelled.txt" dir))))))))

(ert-deftest pichat-llm-coding-tools-add-explicit-system-context ()
  "Selected tools contribute bounded semantics without claiming Pi behavior."
  (pichat-test-with-clean-state
    (pichat-test-require-llm-backend)
    (pichat-llm-coding-tools-register)
    (let ((context (pichat-llm--context-with-tools
                    "User context" '("read" "find" "grep" "edit" "bash")
                    "/tmp/project/")))
      (should (string-match-p "User context" context))
      (should (string-match-p (regexp-quote "/tmp/project/") context))
      (should (string-match-p "Use find to locate" context))
      (should (string-match-p "combine related patterns" context))
      (should (string-match-p "No matches is successful" context))
      (should (string-match-p "Prefer find/grep" context))
      (should (string-match-p "requires approval" context))
      (should (string-match-p "do not assume Pi skills" context)))))

(provide 'pichat-test-llm-coding-tools)
;;; pichat-test-llm-coding-tools.el ends here
