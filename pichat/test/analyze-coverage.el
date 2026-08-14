;;; analyze-coverage.el --- Agent-readable PiChat coverage report -*- lexical-binding: t; -*-

;;; Commentary:

;; Convert an LCOV report and its ERT log into one self-contained Markdown
;; document intended for direct review by a person or coding agent.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defconst pichat-coverage--test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the PiChat coverage tooling.")

(defun pichat-coverage--percent (covered relevant)
  "Return COVERED as a percentage of RELEVANT."
  (if (zerop relevant) 100.0 (* 100.0 (/ (float covered) relevant))))

(defun pichat-coverage--read-lcov (file)
  "Return an alist of source paths and line-count tables parsed from FILE."
  (let (sources current counts)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (cond
           ((string-prefix-p "SF:" line)
            (when current (push (cons current counts) sources))
            (setq current (substring line 3)
                  counts (make-hash-table :test #'eql)))
           ((and current
                 (string-match "\\`DA:\\([0-9]+\\),\\([0-9]+\\)" line))
            (puthash (string-to-number (match-string 1 line))
                     (string-to-number (match-string 2 line))
                     counts))
           ((and current (string= line "end_of_record"))
            (push (cons current counts) sources)
            (setq current nil counts nil))))
        (forward-line 1)))
    (when current (push (cons current counts) sources))
    (nreverse sources)))

(defun pichat-coverage--table-statistics (counts)
  "Return (RELEVANT COVERED MISSED) for line COUNTS."
  (let ((relevant 0) (covered 0))
    (maphash (lambda (_line count)
               (cl-incf relevant)
               (when (> count 0) (cl-incf covered)))
             counts)
    (list relevant covered (- relevant covered))))

(defun pichat-coverage--definition-form-p (form)
  "Return non-nil when FORM defines a named top-level Lisp construct."
  (and (consp form)
       (memq (car form)
             '(defun cl-defun defmacro cl-defmacro defsubst cl-defsubst
               define-derived-mode define-minor-mode
               define-globalized-minor-mode))))

(defun pichat-coverage--line-counts-in-range (counts start end)
  "Return coverage entries from COUNTS between START and END inclusive."
  (let (entries)
    (maphash (lambda (line count)
               (when (<= start line end)
                 (push (cons line count) entries)))
             counts)
    (sort entries (lambda (a b) (< (car a) (car b))))))

(defun pichat-coverage--line-ranges (lines)
  "Return compact contiguous ranges for sorted line numbers LINES."
  (when lines
    (let ((start (car lines))
          (previous (car lines))
          ranges)
      (dolist (line (cdr lines))
        (if (= line (1+ previous))
            (setq previous line)
          (push (if (= start previous)
                    (number-to-string start)
                  (format "%d-%d" start previous))
                ranges)
          (setq start line previous line)))
      (push (if (= start previous)
                (number-to-string start)
              (format "%d-%d" start previous))
            ranges)
      (string-join (nreverse ranges) ", "))))

(defun pichat-coverage--source-definitions (path relative-path counts)
  "Return coverage records for definitions in PATH using COUNTS.
RELATIVE-PATH is used in generated source references."
  (let (definitions)
    (with-temp-buffer
      (insert-file-contents path)
      (emacs-lisp-mode)
      (goto-char (point-min))
      (condition-case nil
          (while t
            (forward-comment (point-max))
            (let* ((start (line-number-at-pos))
                   (form (read (current-buffer)))
                   (end (line-number-at-pos))
                   (entries (and (pichat-coverage--definition-form-p form)
                                 (pichat-coverage--line-counts-in-range
                                  counts start end))))
              (when entries
                (let* ((relevant (length entries))
                       (covered (cl-count-if (lambda (entry) (> (cdr entry) 0))
                                             entries))
                       (missed (- relevant covered))
                       (uncovered-lines
                        (mapcar #'car
                                (cl-remove-if (lambda (entry) (> (cdr entry) 0))
                                              entries))))
                  (push (list :name (cadr form)
                              :path relative-path
                              :line start
                              :relevant relevant
                              :covered covered
                              :missed missed
                              :ranges (pichat-coverage--line-ranges
                                       uncovered-lines))
                        definitions)))))
        (end-of-file nil)))
    (nreverse definitions)))

(defun pichat-coverage--parse-test-log (file)
  "Return test summary and skipped test names parsed from FILE."
  (let (summary skipped)
    (when (and file (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (when (re-search-forward
               "Ran \\([0-9]+\\) tests, \\([0-9]+\\) results as expected, \\([0-9]+\\) unexpected, \\([0-9]+\\) skipped"
               nil t)
          (setq summary
                (list :tests (string-to-number (match-string 1))
                      :expected (string-to-number (match-string 2))
                      :unexpected (string-to-number (match-string 3))
                      :skipped (string-to-number (match-string 4)))))
        (goto-char (point-min))
        (let ((case-fold-search nil))
          (while (re-search-forward
                  "^[[:blank:]]*SKIPPED[[:blank:]]+\\([^[:space:]]+\\)"
                  nil t)
            (cl-pushnew (match-string-no-properties 1) skipped :test #'equal)))))
    (list summary (nreverse skipped))))

(defun pichat-coverage--relative-path (path root)
  "Return PATH relative to ROOT when it is inside ROOT."
  (let ((expanded (expand-file-name path))
        (root (file-name-as-directory (expand-file-name root))))
    (if (string-prefix-p root expanded)
        (file-relative-name expanded root)
      expanded)))

(defun pichat-coverage-analyze (lcov-file test-log output-file)
  "Write an agent-readable report from LCOV-FILE and TEST-LOG to OUTPUT-FILE."
  (let* ((repository-directory
          (file-name-directory
           (directory-file-name
            (file-name-directory
             (directory-file-name pichat-coverage--test-directory)))))
         (sources (pichat-coverage--read-lcov lcov-file))
         file-records definitions
         (total-relevant 0) (total-covered 0) (total-missed 0))
    (dolist (source sources)
      (pcase-let* ((`(,path . ,counts) source)
                   (`(,relevant ,covered ,missed)
                    (pichat-coverage--table-statistics counts))
                   (relative (pichat-coverage--relative-path
                              path repository-directory)))
        (cl-incf total-relevant relevant)
        (cl-incf total-covered covered)
        (cl-incf total-missed missed)
        (push (list :path relative :relevant relevant :covered covered
                    :missed missed)
              file-records)
        (when (file-readable-p path)
          (setq definitions
                (nconc definitions
                       (pichat-coverage--source-definitions
                        path relative counts))))))
    (setq file-records
          (sort file-records
                (lambda (a b) (> (plist-get a :missed)
                                 (plist-get b :missed)))))
    (let* ((missed-definitions
            (sort (cl-remove-if-not
                   (lambda (record) (> (plist-get record :missed) 0))
                   definitions)
                  (lambda (a b) (> (plist-get a :missed)
                                   (plist-get b :missed)))))
           (uncovered-definitions
            (cl-remove-if-not
             (lambda (record) (zerop (plist-get record :covered)))
             missed-definitions))
           (test-data (pichat-coverage--parse-test-log test-log))
           (test-summary (car test-data))
           (skipped-tests (cadr test-data)))
      (make-directory (file-name-directory (expand-file-name output-file)) t)
      (with-temp-file output-file
        (insert "# PiChat coverage analysis\n\n")
        (insert (format "Generated: `%s`  \n"
                        (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
        (insert (format "Emacs: `%s`  \n" emacs-version))
        (insert (format "Coverage input: `%s`\n\n" lcov-file))
        (insert "## Test run\n\n")
        (if test-summary
            (insert (format "- Tests: **%d**\n- Expected results: **%d**\n- Unexpected results: **%d**\n- Skipped: **%d**\n"
                            (plist-get test-summary :tests)
                            (plist-get test-summary :expected)
                            (plist-get test-summary :unexpected)
                            (plist-get test-summary :skipped)))
          (insert "Test totals could not be extracted from the ERT log.\n"))
        (when skipped-tests
          (insert "\n### Skipped tests\n\n")
          (dolist (test skipped-tests)
            (insert (format "- `%s`\n" test))))
        (insert "\n## Overall coverage\n\n")
        (insert (format "- Relevant forms: **%d**\n- Covered forms: **%d**\n- Missed forms: **%d**\n- Weighted coverage: **%.1f%%**\n"
                        total-relevant total-covered total-missed
                        (pichat-coverage--percent total-covered total-relevant)))
        (insert "\n## Coverage by file, largest deficit first\n\n")
        (insert "| Source | Covered | Missed | Relevant | Coverage | Share of misses |\n")
        (insert "|---|---:|---:|---:|---:|---:|\n")
        (dolist (record file-records)
          (insert (format "| `%s` | %d | %d | %d | %.1f%% | %.1f%% |\n"
                          (plist-get record :path)
                          (plist-get record :covered)
                          (plist-get record :missed)
                          (plist-get record :relevant)
                          (pichat-coverage--percent
                           (plist-get record :covered)
                           (plist-get record :relevant))
                          (pichat-coverage--percent
                           (plist-get record :missed) total-missed))))
        (insert "\n## Largest definition-level deficits\n\n")
        (insert "The table is limited to the 40 definitions with the most missed forms.\n\n")
        (insert "| Definition | Source | Covered | Missed | Coverage | Uncovered lines |\n")
        (insert "|---|---|---:|---:|---:|---|\n")
        (dolist (record (seq-take missed-definitions 40))
          (insert (format "| `%s` | `%s:%d` | %d | %d | %.1f%% | %s |\n"
                          (plist-get record :name)
                          (plist-get record :path)
                          (plist-get record :line)
                          (plist-get record :covered)
                          (plist-get record :missed)
                          (pichat-coverage--percent
                           (plist-get record :covered)
                           (plist-get record :relevant))
                          (or (plist-get record :ranges) ""))))
        (insert "\n## Completely uncovered definitions\n\n")
        (if uncovered-definitions
            (progn
              (insert "| Definition | Source | Missed forms | Uncovered lines |\n")
              (insert "|---|---|---:|---|\n")
              (dolist (record uncovered-definitions)
                (insert (format "| `%s` | `%s:%d` | %d | %s |\n"
                                (plist-get record :name)
                                (plist-get record :path)
                                (plist-get record :line)
                                (plist-get record :missed)
                                (or (plist-get record :ranges) "")))))
          (insert "No completely uncovered top-level definitions were found.\n"))
        (insert "\n## Interpretation notes\n\n")
        (insert "- Undercover uses Edebug and measures instrumented forms, not conventional branch coverage.\n")
        (insert "- A low percentage in a tiny adapter can represent less risk than a modest deficit in a large orchestration module.\n")
        (insert "- Skipped optional-dependency tests can make related modules appear less covered.\n")
        (insert "- Completely uncovered code should be checked for reachability before tests are added; it may be obsolete.\n")))
    output-file))

(provide 'pichat-analyze-coverage)
;;; analyze-coverage.el ends here
