;;; pichat-test-session-completion.el --- Saved-session completion tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused contracts for the synchronous saved-session completion picker.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-session-completion--write-session (file id cwd name)
  "Write a minimal saved session FILE with ID, CWD, and NAME."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (insert (json-serialize (list :type "session" :id id :cwd cwd)) "\n")
    (insert (json-serialize (list :type "session_info" :name name)) "\n")))

(ert-deftest pichat-session-completion-separates-identity-and-affixation ()
  (cl-letf (((symbol-function 'pichat-sessions--file-summary)
             (lambda (_file)
               '(:id "12345678-abcd" :cwd "/fixture/project"
                 :name "Named session")))
            ((symbol-function 'file-attributes)
             (lambda (_file) (list nil 1 nil nil nil '(0 0 0 0))))
            ((symbol-function 'format-time-string)
             (lambda (&rest _args) "2026-08-10 14:00")))
    (let* ((choices (pichat-sessions--file-choices
                     '("/sessions/project/session.jsonl") "/sessions/"))
           (candidate (caar choices))
           (table (pichat-sessions--completion-table choices))
           (metadata (completion-metadata "" table nil))
           (affixation (completion-metadata-get metadata 'affixation-function))
           (row (car (funcall affixation (list candidate))))
           (annotation (nth 2 row)))
      (should (string-prefix-p "12345678  Named session" candidate))
      (should (string-match-p "Named session" candidate))
      (should-not (string-match-p "2026-08-10\|/fixture/project" candidate))
      (should (equal candidate (car row)))
      (should (string-match-p "2026-08-10 14:00" annotation))
      (should (string-match-p "/fixture/project" annotation))
      (should (= (+ 12 pichat-sessions-completion-title-width)
                 (string-width
                  (substring (concat candidate annotation) 0
                             (string-match "│" (concat candidate annotation)))))))))

(ert-deftest pichat-session-completion-identity-bounds-titles-and-falls-back-to-id ()
  (should (equal "12345678"
                 (pichat-sessions--completion-identity "" "12345678-abcd")))
  (should (equal "id  short"
                 (pichat-sessions--completion-identity "short" "id")))
  (let ((identity
         (pichat-sessions--completion-identity (make-string 200 ?x)
                                               "12345678-abcd")))
    (should (string-prefix-p "12345678  " identity))
    (should (string-suffix-p "…" identity))
    (should (<= (string-width identity)
                (+ 10 pichat-sessions-completion-title-width))))
  (let* ((pichat-sessions-completion-title-width 12)
         (identity (pichat-sessions--completion-identity
                    (make-string 20 ?界) "12345678-abcd"))
         (row (concat identity
                      (pichat-sessions--completion-annotation-prefix identity)))
         (separator (string-match "│" row)))
    (should (<= (string-width identity) 22))
    (should (= 24 (string-width (substring row 0 separator))))))

(ert-deftest pichat-session-completion-disambiguates-duplicate-identities ()
  (cl-letf (((symbol-function 'pichat-sessions--file-presentation-record)
             (lambda (file root)
               (list :candidate "12345678  Same title" :file file
                     :relative-file (file-relative-name file root)))))
    (let ((choices (pichat-sessions--file-choices
                    '("/sessions/first.jsonl" "/sessions/second.jsonl")
                    "/sessions/")))
      (should (equal '("12345678  Same title"
                       "12345678  Same title  —  second.jsonl")
                     (mapcar #'car choices)))
      (should (equal '("/sessions/first.jsonl" "/sessions/second.jsonl")
                     (mapcar #'pichat-sessions--choice-file choices))))))

(ert-deftest pichat-session-completion-preserves-order-and-standard-metadata ()
  (let* ((choices '(("first" . "/sessions/first.jsonl")
                    ("second" . "/sessions/second.jsonl")))
         (table (pichat-sessions--completion-table choices))
         (metadata (completion-metadata "" table nil))
         (affixation (completion-metadata-get metadata 'affixation-function)))
    (should (equal '("first" "second")
                   (all-completions "" table nil)))
    (should (eq 'pichat-session
                (completion-metadata-get metadata 'category)))
    (should (eq #'identity
                (completion-metadata-get metadata 'display-sort-function)))
    (should (eq #'identity
                (completion-metadata-get metadata 'cycle-sort-function)))
    (should (functionp affixation))
    (should (equal '(("first" "" "") ("second" "" ""))
                   (funcall affixation '("first" "second"))))))

(ert-deftest pichat-session-completion-basic-selection-returns-exact-file-and-cached-cwd ()
  (pichat-test-with-temp-dir root
    (let* ((first (expand-file-name "one/session_first-id.jsonl" root))
           (second (expand-file-name "two/session_second-id.jsonl" root))
           (pichat-sessions--summary-cache (make-hash-table :test #'equal))
           (uncached (symbol-function 'pichat-sessions--file-summary-uncached))
           (parse-count 0)
           read-arguments)
      (pichat-test-session-completion--write-session
       first "first-id" "/fixture/first" "First session")
      (pichat-test-session-completion--write-session
       second "second-id" "/fixture/second" "Second session")
      (cl-letf (((symbol-function 'pichat-sessions--root-dir)
                 (lambda () root))
                ((symbol-function 'pichat-sessions--files)
                 (lambda () (list first second)))
                ((symbol-function 'pichat-sessions--file-summary-uncached)
                 (lambda (file)
                   (cl-incf parse-count)
                   (funcall uncached file)))
                ((symbol-function 'completing-read)
                 (lambda (&rest arguments)
                   (setq read-arguments arguments)
                   (cadr (all-completions "" (nth 1 arguments)
                                          (nth 2 arguments))))))
        (should (equal (list second "/fixture/second")
                       (pichat-sessions--choose-basic-file))))
      (should (equal "Pi session: " (nth 0 read-arguments)))
      (should (eq t (nth 3 read-arguments)))
      ;; Each file is parsed once while choices are built.  Looking up the
      ;; selected CWD must reuse the cached summary rather than parse again.
      (should (= 2 parse-count)))))

(ert-deftest pichat-session-completion-searches-bounded-aliases-without-displaying-them ()
  (let* ((record (list :candidate "12345678  Named session"
                       :file "/sessions/group/session_12345678-abcd.jsonl"
                       :title "Named session" :session-id "12345678-abcd"
                       :short-id "12345678" :mtime "2026-08-10 14:00"
                       :full-cwd "/fixture/project" :display-cwd "/fixture/project"
                       :relative-file "group/session_12345678-abcd.jsonl"))
         (choices (list (cons (plist-get record :candidate) record)))
         (table (pichat-sessions--completion-table choices))
         (completion-styles '(basic)))
    (dolist (query '("Named session" "12345678-abcd" "/fixture/project"
                     "2026-08-10" "group/session_12345678-abcd.jsonl"))
      (should (equal "12345678  Named session"
                     (substring-no-properties
                      (car (completion-all-completions
                            query table nil (length query)))))))
    (should-not (string-match-p
                 "2026-08-10\|/fixture/project\|group/session"
                 (caar choices)))))

(ert-deftest pichat-session-completion-orderless-matches-identity-and-metadata-aliases ()
  (skip-unless (require 'orderless nil t))
  (let* ((record (list :candidate "12345678  Named session"
                       :title "Named session" :session-id "12345678-abcd"
                       :short-id "12345678" :mtime "2026-08-10 14:00"
                       :full-cwd "/fixture/project" :display-cwd "/fixture/project"
                       :relative-file "group/session.jsonl"))
         (table (pichat-sessions--completion-table
                 (list (cons (plist-get record :candidate) record))))
         (completion-styles '(orderless basic))
         (query "project Named"))
    (should (equal "12345678  Named session"
                   (substring-no-properties
                    (car (completion-all-completions
                          query table nil (length query))))))))

(provide 'pichat-test-session-completion)
;;; pichat-test-session-completion.el ends here
