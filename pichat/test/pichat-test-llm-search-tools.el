;;; pichat-test-llm-search-tools.el --- Native fd/rg search tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline fixtures for the direct-process native search adapters.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-llm-coding-tools)

(defun pichat-test-search--call (name params &optional timeout)
  "Call async search tool NAME with PARAMS, waiting up to TIMEOUT seconds."
  (let ((tool (gethash name pichat-tools-registry)) result callbacks)
    (should tool)
    (pichat-tools-call-async
     tool params (lambda (value) (push value callbacks) (setq result value)))
    (pichat-test-wait-until (lambda () result) (or timeout 3) "search callback")
    (should (= 1 (length callbacks)))
    result))

(defun pichat-test-search--write (root relative text &optional literal)
  "Write TEXT beneath ROOT at RELATIVE, optionally LITERAL bytes."
  (let ((path (expand-file-name relative root)))
    (make-directory (file-name-directory path) t)
    (with-temp-buffer
      (when literal (set-buffer-multibyte nil))
      (insert text)
      (let ((coding-system-for-write (if literal 'no-conversion 'utf-8-unix)))
        (write-region nil nil path nil 'silent)))
    path))

(defun pichat-test-search--stub (directory name body)
  "Create executable shell stub NAME in DIRECTORY with BODY."
  (let ((path (expand-file-name name directory)))
    (with-temp-file path
      (insert "#!/bin/sh\nset -eu\n" body "\n"))
    (set-file-modes path #o700)
    path))

(defun pichat-test-search--require-executables (&rest names)
  "Skip the current real integration test unless executable NAMES exist."
  (dolist (name names)
    (unless (or (executable-find name)
                (and (equal name "fd") (executable-find "fdfind")))
      (ert-skip (format "Real search integration requires %s" name)))))

(ert-deftest pichat-llm-search-tools-real-find-honors-glob-hidden-ignore-and-limit ()
  (pichat-test-search--require-executables "fd")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (make-directory (expand-file-name ".git" dir))
        (pichat-test-search--write dir ".gitignore" "ignored.el\n.hidden.el\n")
        (pichat-test-search--write dir "one.el" "one")
        (pichat-test-search--write dir "sub/two.el" "two")
        (pichat-test-search--write dir "ignored.el" "ignored")
        (pichat-test-search--write dir ".hidden.el" "hidden")
        (let* ((result (pichat-test-search--call
                        "find" '(:pattern "*.el" :hidden t :limit 1)))
               (text (plist-get result :value)))
          (should-not (plist-get result :is-error))
          (should (string-match-p "\\.el" text))
          (should (string-match-p "file limit reached" text))
          (should-not (string-match-p "ignored\\|hidden" text)))
        (let ((none (pichat-test-search--call
                     "find" '(:pattern "*.missing"))))
          (should-not (plist-get none :is-error))
          (should (equal "[no files found]" (plist-get none :value))))))))

(ert-deftest pichat-llm-search-tools-real-grep-covers-or-regex-case-glob-context ()
  (pichat-test-search--require-executables "rg")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (pichat-test-search--write
         dir "a.el" "before\nAlpha literal.*\nafter\nfar one\nfar two\nfar three\nbeta 42\n")
        (pichat-test-search--write dir "b.txt" "alpha ignored by glob\n")
        (let* ((literal (pichat-test-search--call
                         "grep" '(:patterns ["alpha" "beta"] :ignoreCase t
                                  :glob "*.el" :context 1)))
               (text (plist-get literal :value)))
          (should-not (plist-get literal :is-error))
          (should (string-match-p "a\\.el:2:Alpha literal\\.\\*" text))
          (should (string-match-p "a\\.el-1-before" text))
          (should (string-match-p "a\\.el:7:beta 42" text))
          (should (string-match-p "^--$" text))
          (should-not (string-match-p "b\\.txt" text)))
        (let ((regex (pichat-test-search--call
                      "grep" '(:pattern "beta [0-9]+" :literal nil))))
          (should-not (plist-get regex :is-error))
          (should (string-match-p "beta 42" (plist-get regex :value))))
        (let ((none (pichat-test-search--call
                     "grep" '(:pattern "ABSENT"))))
          (should-not (plist-get none :is-error))
          (should (equal "[no matches]" (plist-get none :value))))))))

(ert-deftest pichat-llm-search-tools-ignore-recursion-but-search-explicit-file ()
  (pichat-test-search--require-executables "rg")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (make-directory (expand-file-name ".git" dir))
        (pichat-test-search--write dir ".gitignore" "ignored.txt\n")
        (pichat-test-search--write dir "ignored.txt" "target\n")
        (should (equal "[no matches]"
                       (plist-get (pichat-test-search--call
                                   "grep" '(:pattern "target" :path "."))
                                  :value)))
        (let ((explicit (pichat-test-search--call
                         "grep" '(:pattern "target" :path "ignored.txt"))))
          (should-not (plist-get explicit :is-error))
          (should (string-match-p "ignored\\.txt:1:target"
                                  (plist-get explicit :value))))))))

(ert-deftest pichat-llm-search-tools-global-limit-and-invalid-utf8-are-explicit ()
  (pichat-test-search--require-executables "rg")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (pichat-test-search--write dir "a.txt" "hit\n")
        (pichat-test-search--write dir "b.txt" "hit\n")
        (let ((limited (pichat-test-search--call
                        "grep" '(:pattern "hit" :limit 1))))
          (should-not (plist-get limited :is-error))
          (should (string-match-p "matching-line limit reached"
                                  (plist-get limited :value))))
        (pichat-test-search--write dir "long.txt"
                                   (concat "wide " (make-string 200 ?x) "\n"))
        (let* ((pichat-llm-coding-tools-max-output-chars 80)
               (bounded (pichat-test-search--call
                         "grep" '(:pattern "wide" :path "long.txt"))))
          (should-not (plist-get bounded :is-error))
          (should (<= (length (plist-get bounded :value)) 80))
          (should (string-match-p "output limit reached"
                                  (plist-get bounded :value))))
        (pichat-test-search--write
         dir "bad.txt" (unibyte-string 255 ?b ?a ?d ?\n) t)
        (let ((invalid (pichat-test-search--call
                        "grep" '(:pattern "bad" :path "bad.txt"))))
          (should (plist-get invalid :is-error))
          (should (string-match-p "not valid UTF-8"
                                  (plist-get invalid :value))))))))

(ert-deftest pichat-llm-search-tools-validates-exclusive-patterns-and-path-policy ()
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (pichat-test-with-temp-dir outside
        (let ((default-directory dir))
          (pichat-llm-coding-tools-register)
          (make-symbolic-link outside (expand-file-name "link" dir))
          (dolist (params '((:path ".")
                            (:pattern "x" :patterns ["y"])
                            (:patterns [])
                            (:patterns [""])
                            (:pattern "x" :context -1)
                            (:pattern "x" :literal "yes")))
            (let ((result (pichat-test-search--call "grep" params)))
              (should (plist-get result :is-error))))
          (dolist (params '((:pattern "a/b")
                            (:path "../")
                            (:path "link")))
            (let ((result (pichat-test-search--call "find" params)))
              (should (plist-get result :is-error)))))))))

(ert-deftest pichat-llm-search-tools-leading-dash-values-are-not-flags ()
  (pichat-test-search--require-executables "fd" "rg")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (pichat-test-search--write dir "-name.txt" "-needle\n")
        (let ((found (pichat-test-search--call
                      "find" '(:pattern "-*.txt")))
              (matched (pichat-test-search--call
                        "grep" '(:pattern "-needle"))))
          (should-not (plist-get found :is-error))
          (should (string-match-p "-name\\.txt" (plist-get found :value)))
          (should-not (plist-get matched :is-error))
          (should (string-match-p "-needle" (plist-get matched :value))))))))

(ert-deftest pichat-llm-search-tools-argv-is-allowlisted-and-no-shell-is-used ()
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let* ((default-directory dir)
             (log (expand-file-name "argv" dir))
             (process-environment
              (cons (concat "PICHAT_ARGV=" log) process-environment))
             (stub (pichat-test-search--stub
                    dir "rg-stub"
                    "printf '%s\\n' \"$@\" > \"$PICHAT_ARGV\""))
             (pichat-llm-search-tools-rg-executable stub))
        (pichat-llm-coding-tools-register)
        (let ((result (pichat-test-search--call
                       "grep" '(:patterns ["-first" "second"]
                                :glob "*.el" :hidden t))))
          (should-not (plist-get result :is-error)))
        (let ((argv (with-temp-buffer
                      (insert-file-contents log) (buffer-string))))
          (dolist (flag '("--json\n" "--no-config\n" "--no-ignore-global\n"
                          "--hidden\n" "--glob\n" "*.el\n" "-e\n-first\n"
                          "-e\nsecond\n" "--\n"))
            (should (string-match-p (regexp-quote flag) argv)))
          (should-not (string-match-p "sh -c" argv)))))))

(ert-deftest pichat-llm-search-tools-errors-timeouts-and-oversized-records ()
  (pichat-test-search--require-executables "rg")
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let ((default-directory dir))
        (pichat-llm-coding-tools-register)
        (pichat-test-search--write dir "a.txt" "text\n")
        (let ((bad-regex (pichat-test-search--call
                          "grep" '(:pattern "[" :literal nil))))
          (should (plist-get bad-regex :is-error))
          (should (string-match-p "regex parse error"
                                  (plist-get bad-regex :value))))
        (let* ((stub (pichat-test-search--stub dir "slow-rg" "sleep 2"))
               (pichat-llm-search-tools-rg-executable stub)
               (pichat-llm-search-tools-timeout 0.05)
               (timeout (pichat-test-search--call
                         "grep" '(:pattern "x") 2)))
          (should (plist-get timeout :is-error))
          (should (string-match-p "timed out" (plist-get timeout :value))))
        (let* ((stub (pichat-test-search--stub
                      dir "large-rg"
                      "awk 'BEGIN { for (i=0;i<10000;i++) printf \"x\" }'"))
               (pichat-llm-search-tools-rg-executable stub)
               (pichat-llm-search-tools-max-record-bytes 100)
               (large (pichat-test-search--call "grep" '(:pattern "x"))))
          (should (plist-get large :is-error))
          (should (string-match-p "oversized" (plist-get large :value))))
        (let* ((stub (pichat-test-search--stub
                      dir "partial-rg"
                      "printf '{\"type\":\"match\",\"data\":{\"path\":{\"text\":\"%s/a.txt\"},\"lines\":{\"text\":\"text\\\\n\"},\"line_number\":1}}\\n' \"$PWD\"; echo fixture-failure >&2; exit 2"))
               (pichat-llm-search-tools-rg-executable stub)
               (partial (pichat-test-search--call "grep" '(:pattern "text"))))
          (should (plist-get partial :is-error))
          (should (string-match-p "a\\.txt:1:text" (plist-get partial :value)))
          (should (string-match-p "fixture-failure" (plist-get partial :value))))
        (let ((pichat-llm-search-tools-rg-executable "missing-pichat-rg"))
          (let ((missing (pichat-test-search--call "grep" '(:pattern "x"))))
            (should (plist-get missing :is-error))
            (should (string-match-p "executable is unavailable"
                                    (plist-get missing :value)))))))))

(ert-deftest pichat-llm-search-tools-cancellation-suppresses-late-callback ()
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let* ((default-directory dir)
             (stub (pichat-test-search--stub dir "cancel-rg" "sleep 1"))
             (pichat-llm-search-tools-rg-executable stub)
             (pichat-llm-search-tools-timeout 3)
             callback)
        (pichat-llm-coding-tools-register)
        (let ((cancel (pichat-tools-call-async
                       (gethash "grep" pichat-tools-registry)
                       '(:pattern "x")
                       (lambda (_result) (setq callback t)))))
          (should (functionp cancel))
          (funcall cancel)
          (accept-process-output nil 1.1)
          (should-not callback))))))

(provide 'pichat-test-llm-search-tools)
;;; pichat-test-llm-search-tools.el ends here
