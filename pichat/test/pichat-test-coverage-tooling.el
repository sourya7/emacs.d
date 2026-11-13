;;; pichat-test-coverage-tooling.el --- Coverage runner contracts -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(defvar undercover--report-file-path)
(declare-function pichat-coverage-run-tests-and-report "coverage-setup")
(declare-function pichat-test-overlap-analyze-records "test-overlap")
(declare-function pichat-test-overlap-analyze "test-overlap")
(declare-function pichat-test-overlap-coupling "test-overlap")
(let ((directory (file-name-directory (or load-file-name buffer-file-name))))
  (unless (featurep 'pichat-coverage-setup)
    (load (expand-file-name "coverage-setup.el" directory)))
  (unless (featurep 'pichat-test-overlap)
    (load (expand-file-name "test-overlap.el" directory))))

(ert-deftest pichat-coverage-tooling-does-not-report-failed-tests ()
  (let (reported)
    (cl-letf (((symbol-function 'ert-run-tests-batch) (lambda (&rest _) 'stats))
              ((symbol-function 'ert-stats-completed-unexpected) (lambda (_) 1))
              ((symbol-function 'undercover-report)
               (lambda (&rest _) (setq reported t))))
      (should-error (pichat-coverage-run-tests-and-report) :type 'error)
      (should-not reported))))

(ert-deftest pichat-coverage-tooling-propagates-report-failure ()
  (cl-letf (((symbol-function 'ert-run-tests-batch) (lambda (&rest _) 'stats))
            ((symbol-function 'ert-stats-completed-unexpected) (lambda (_) 0))
            ((symbol-function 'undercover-report) (lambda (&rest _) (error "report failed"))))
    (should-error (pichat-coverage-run-tests-and-report) :type 'error)))

(ert-deftest pichat-coverage-tooling-requires-lcov-file ()
  (let ((undercover--report-file-path (make-temp-name
                                        (expand-file-name "pichat-no-report-"
                                                          temporary-file-directory)))
        (process-environment (cons "PICHAT_COVERAGE_FORMAT=lcov" process-environment)))
    (cl-letf (((symbol-function 'ert-run-tests-batch) (lambda (&rest _) 'stats))
              ((symbol-function 'ert-stats-completed-unexpected) (lambda (_) 0))
              ((symbol-function 'undercover-report) (lambda (&rest _) t)))
      (should-error (pichat-coverage-run-tests-and-report) :type 'error))))

(ert-deftest pichat-coverage-tooling-reports-successful-run ()
  (let ((process-environment (cons "PICHAT_COVERAGE_FORMAT=text" process-environment))
        (reported nil))
    (cl-letf (((symbol-function 'ert-run-tests-batch) (lambda (&rest _) 'stats))
              ((symbol-function 'ert-stats-completed-unexpected) (lambda (_) 0))
              ((symbol-function 'undercover-report)
               (lambda (&rest _) (setq reported t) 'written)))
      (should (eq 'written (pichat-coverage-run-tests-and-report)))
      (should reported))))

(defun pichat-coverage-tooling-test--overlap-row (rows name)
  "Return the overlap row for test NAME in ROWS."
  (seq-find (lambda (row) (eq (plist-get row :name) name)) rows))

(ert-deftest pichat-coverage-tooling-overlap-separates-unique-contained-and-unknown ()
  (let ((rows (pichat-test-overlap-analyze-records
               7
               '((wide "a.el" passed [0 1 2 3])
                 (narrow "a.el" passed [1 2])
                 (other-file "b.el" passed [1 2 3 6])
                 (spread "b.el" passed [0 6])
                 (alone "b.el" passed [4])
                 (blind "b.el" passed [])
                 (skipped "a.el" skipped [5])))))
    ;; A form only one passed test executes makes that test unique.
    (should (= 1 (plist-get (pichat-coverage-tooling-test--overlap-row rows 'alone)
                            :unique)))
    (should-not (plist-get (pichat-coverage-tooling-test--overlap-row rows 'alone)
                           :contained))
    ;; Containers: every test holding all forms, same test file first.
    (should (equal '(wide other-file)
                   (plist-get (pichat-coverage-tooling-test--overlap-row rows 'narrow)
                              :containers)))
    ;; Contained by the union of several tests, but by no single one.
    (let ((spread (pichat-coverage-tooling-test--overlap-row rows 'spread)))
      (should (plist-get spread :contained))
      (should-not (plist-get spread :containers)))
    ;; A test without instrumented forms is unknown, not redundant.
    (should-not (plist-get (pichat-coverage-tooling-test--overlap-row rows 'blind)
                           :contained))
    ;; Skipped tests neither contain others nor make forms shared.
    (let ((skipped (pichat-coverage-tooling-test--overlap-row rows 'skipped)))
      (should (eq 'skipped (plist-get skipped :result)))
      (should-not (plist-get skipped :contained)))))

(ert-deftest pichat-coverage-tooling-overlap-report-reads-written-records ()
  (let ((directory (make-temp-file "pichat-overlap-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "forms.eld" directory)
            (insert "(:version 1)\n(0 \"pichat-x.el\" pichat-x 0 3)\n"
                    "(1 \"pichat-x.el\" pichat-x 1 4)\n"))
          (with-temp-file (expand-file-name "tests.eld" directory)
            (insert "(:version 1)\n(t-small \"t.el\" passed [1])\n"
                    "(t-large \"t.el\" passed [0 1])\n"))
          (let ((report (with-temp-buffer
                          (insert-file-contents (pichat-test-overlap-analyze directory))
                          (buffer-string))))
            (should (string-match-p "`t-small` (1) ⊆ `t-large`" report)))
          (with-temp-buffer
            (insert-file-contents (expand-file-name "tests.tsv" directory))
            (should (= 3 (count-lines (point-min) (point-max))))))
      (delete-directory directory t))))

(ert-deftest pichat-coverage-tooling-coupling-counts-source-details-only ()
  (let ((file (make-temp-file "pichat-test-coupling-" nil ".el"))
        (test-defined (make-hash-table :test #'eq)))
    (puthash 'pichat-helper--made-in-tests t test-defined)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";; pichat-jobs--in-a-comment\n"
                    "(ert-deftest sample ()\n"
                    "  (cl-letf (((symbol-function 'pichat-jobs--render) #'ignore))\n"
                    "    (pichat-helper--made-in-tests)\n"
                    "    (pichat-test--support-helper)\n"
                    "    (should (equal \"pichat-jobs--in-a-string\" (pichat-jobs--title)))\n"
                    "    (should-not (pichat-jobs-visible-p))))\n"))
          (let ((counts (pichat-test-overlap-coupling file test-defined)))
            (should (= 1 (plist-get counts :tests)))
            ;; Only pichat-jobs--render and pichat-jobs--title: not comments,
            ;; strings, test-defined helpers or pichat-test symbols.
            (should (= 2 (plist-get counts :private)))
            (should (= 1 (plist-get counts :stubs)))
            (should (= 1 (plist-get counts :string-assertions)))))
      (delete-file file))))

(provide 'pichat-test-coverage-tooling)
;;; pichat-test-coverage-tooling.el ends here
