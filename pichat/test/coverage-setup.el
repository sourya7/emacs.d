;;; coverage-setup.el --- PiChat coverage bootstrap and runner -*- lexical-binding: t; -*-

;;; Commentary:
;; Load this file before the PiChat test suite and call `pichat-coverage-enable'
;; before loading any PiChat source.  Loading it for runner tests alone does
;; not activate instrumentation.  Run tests and report explicitly after the
;; suite is loaded, so a report error cannot be demoted by an exit hook.

;;; Code:

(require 'seq)
(require 'ert)
(defvar undercover-force-coverage)
(defvar undercover--report-file-path)
(declare-function undercover-report "undercover" (&optional report-format))

(defconst pichat-coverage--test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the PiChat coverage tooling.")

(defun pichat-coverage-enable ()
  "Instrument supported PiChat source before loading the test suite."
  (let* ((test-directory pichat-coverage--test-directory)
         (repository-directory
          (file-name-directory
           (directory-file-name
            (file-name-directory (directory-file-name test-directory)))))
         (source-directory (expand-file-name "pichat" repository-directory))
         ;; Undercover 0.8.0 / Emacs 31.1 cannot safely instrument the
         ;; callback passed by pichat-chat--with-live-projection-rollback: its
         ;; Edebug stop points execute inside a separately instrumented callee,
         ;; whose dynamically bound counter vector belongs to that callee.
         ;; Until that instrumentation is supported, exclude this file rather
         ;; than reporting its synthetic index errors as PiChat test failures.
         (source-files
          (seq-remove (lambda (file)
                        (string= (file-name-nondirectory file) "pichat-chat.el"))
                      (directory-files source-directory t "\\.el\\'")))
         (format (or (getenv "PICHAT_COVERAGE_FORMAT") "text"))
         (report-file (getenv "PICHAT_COVERAGE_REPORT_FILE")))
    (unless (require 'undercover nil t)
      (error (concat "Cannot load undercover.el; start the configured Emacs "
                     "once to install it, or set PICHAT_COVERAGE_LOAD_PATH")))
    (setq undercover-force-coverage t)
    (message "Coverage: exclude pichat-chat.el (instrumented callback crosses Edebug counter scopes)")
    ;; Undercover stores Edebug metadata on symbols. A second definition in
    ;; another file can overwrite the original file's stop-point locations (the
    ;; runtime function and transient suffix share a reconfigure symbol).
    (advice-add
     'undercover--symbol-coverage-statistics :around
     (lambda (original symbol statistics)
       (let ((start (car (get symbol 'edebug))))
         (if (and (markerp start) (eq (marker-buffer start) (current-buffer)))
             (funcall original symbol statistics)
           (message "Coverage: omit redefined %s in %s (stop points belong elsewhere)"
                    symbol (buffer-name))))))
    (pcase format
      ("text"
       ;; Construct the public macro call at runtime so the source paths can be
       ;; absolute without depending on the caller's working directory.
       (eval `(undercover (:files ,@source-files)
                          (:report-format 'text)
                          (:report-file nil)
                          (:send-report nil)
                          (:merge-report nil)
                          (:report-on-kill nil))))
      ("lcov"
       (setq report-file
             (expand-file-name (or report-file "coverage/lcov.info")
                               repository-directory))
       (eval `(undercover (:files ,@source-files)
                          (:report-format 'lcov)
                          (:report-file ,report-file)
                          (:send-report nil)
                          (:merge-report nil)
                          (:report-on-kill nil))))
      (_ (error "Unsupported PiChat coverage format: %s" format)))))

(defun pichat-coverage-run-tests-and-report ()
  "Run all tests, then emit a report only if every required test passes.
Return the report result.  Report errors propagate instead of being demoted."
  (let ((stats (ert-run-tests-batch nil)))
    (unless (zerop (ert-stats-completed-unexpected stats))
      (error "Coverage test run had %d unexpected results; no report generated"
             (ert-stats-completed-unexpected stats)))
    (prog1 (undercover-report)
      (when (and (equal (getenv "PICHAT_COVERAGE_FORMAT") "lcov")
                 (not (file-readable-p undercover--report-file-path)))
        (error "Coverage report was not written: %s" undercover--report-file-path)))))

(provide 'pichat-coverage-setup)
;;; coverage-setup.el ends here
