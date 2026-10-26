;;; pichat-test-coverage-tooling.el --- Coverage runner contracts -*- lexical-binding: t; -*-

;;; Code:
(require 'ert)
(require 'cl-lib)
(defvar undercover--report-file-path)
(declare-function pichat-coverage-run-tests-and-report "coverage-setup")
(unless (featurep 'pichat-coverage-setup)
  (load (expand-file-name "coverage-setup.el"
                          (file-name-directory (or load-file-name buffer-file-name)))))

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

(provide 'pichat-test-coverage-tooling)
;;; pichat-test-coverage-tooling.el ends here
