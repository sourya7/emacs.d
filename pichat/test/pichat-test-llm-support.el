;;; pichat-test-llm-support.el --- Offline llm.el test support -*- lexical-binding: t; -*-

;;; Commentary:

;; Locate the pinned llm source without making Pi-only production loading depend
;; on it.  Split plz parser shims are inert: every provider test replaces the
;; request function before a request is constructed.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'seq)

(defconst pichat-test-llm-source-directory
  (seq-find
   #'file-directory-p
   (delq nil
         (list
          (getenv "PICHAT_TEST_LLM_LOAD_PATH")
          (expand-file-name ".local/elpaca/builds/llm" default-directory)
          (expand-file-name ".local/elpaca/sources/llm" default-directory)
          "/tmp/pi-github-repos/ahyatt/llm@main")))
  "Available source directory for the pinned llm test dependency.")

(when pichat-test-llm-source-directory
  (add-to-list 'load-path pichat-test-llm-source-directory))

(defun pichat-test-llm-available-p ()
  "Return non-nil when the real llm.el test dependency is available."
  (and pichat-test-llm-source-directory (locate-library "llm")))

(defun pichat-test-llm-install-offline-parser-shims ()
  "Install inert parser constructors missing from this checkout."
  (unless (featurep 'plz)
    (cl-defstruct plz-response status body)
    (cl-defstruct plz-error response curl-error message)
    (define-error 'plz-error "Offline plz error")
    (define-error 'plz-http-error "Offline plz HTTP error" 'plz-error)
    (define-error 'plz-curl-error "Offline plz curl error" 'plz-error)
    (defun plz (&rest _args)
      (error "Network disabled by PiChat llm test shim"))
    (provide 'plz))
  (unless (featurep 'plz-event-source)
    (cl-defstruct (pichat-test-llm-event
                   (:constructor pichat-test-llm-event-create))
      data)
    (declare-function pichat-test-llm-event-data nil (event))
    (defalias 'plz-event-source-event-data #'pichat-test-llm-event-data)
    (defun plz-event-source:text/event-stream (&rest args) args)
    (provide 'plz-event-source))
  (unless (featurep 'plz-media-type)
    (defvar plz-media-types nil)
    (defun plz-media-type:application/json-array (&rest args) args)
    (defun plz-media-type-request (&rest _args)
      (error "Network disabled by PiChat llm test shim"))
    (provide 'plz-media-type)))

(defun pichat-test-require-llm-backend ()
  "Load the real pinned llm API and PiChat adapter, or skip this test."
  (unless (pichat-test-llm-available-p)
    (ert-skip "Pinned llm.el test dependency is unavailable"))
  (pichat-test-llm-install-offline-parser-shims)
  (require 'llm)
  (require 'pichat-backend-llm))

(provide 'pichat-test-llm-support)
;;; pichat-test-llm-support.el ends here
