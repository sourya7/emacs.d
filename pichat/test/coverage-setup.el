;;; coverage-setup.el --- PiChat coverage bootstrap -*- lexical-binding: t; -*-

;;; Commentary:

;; Load this file before the PiChat test suite.  It enables Undercover while
;; none of the PiChat source files have been loaded yet.

;;; Code:

(let* ((test-directory
        (file-name-directory (or load-file-name buffer-file-name)))
       (repository-directory
        (file-name-directory
         (directory-file-name
          (file-name-directory (directory-file-name test-directory)))))
       (source-directory (expand-file-name "pichat" repository-directory))
       (source-files (directory-files source-directory t "\\.el\\'"))
       (format (or (getenv "PICHAT_COVERAGE_FORMAT") "text"))
       (report-file (getenv "PICHAT_COVERAGE_REPORT_FILE")))
  (unless (require 'undercover nil t)
    (error (concat "Cannot load undercover.el; start the configured Emacs "
                   "once to install it, or set PICHAT_COVERAGE_LOAD_PATH")))
  (setq undercover-force-coverage t)
  (pcase format
    ("text"
     ;; Construct the public macro call at runtime so the source paths can be
     ;; absolute without depending on the caller's working directory.
     (eval `(undercover (:files ,@source-files)
                        (:report-format 'text)
                        (:report-file nil)
                        (:send-report nil)
                        (:merge-report nil))))
    ("lcov"
     (setq report-file
           (expand-file-name (or report-file "coverage/lcov.info")
                             repository-directory))
     (eval `(undercover (:files ,@source-files)
                        (:report-format 'lcov)
                        (:report-file ,report-file)
                        (:send-report nil)
                        (:merge-report nil))))
    (_ (error "Unsupported PiChat coverage format: %s" format))))

(provide 'pichat-coverage-setup)
;;; coverage-setup.el ends here
