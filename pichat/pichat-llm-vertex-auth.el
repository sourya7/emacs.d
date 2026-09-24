;;; pichat-llm-vertex-auth.el --- ADC authentication for native Vertex -*- lexical-binding: t; -*-

;;; Commentary:

;; Use the credentials created by `gcloud auth application-default login',
;; not the independent account selected by `gcloud auth login'.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'llm)
(require 'llm-vertex)

(defun pichat-llm-vertex-access-token (gcloud)
  "Return an ADC access token using GCLOUD without exposing command output."
  (unless (and (stringp gcloud) (not (string-blank-p gcloud)))
    (signal 'llm-provider-unconfigured
            '("A gcloud executable is required for Vertex authentication")))
  (with-temp-buffer
    (let ((status (condition-case nil
                      (process-file gcloud nil t nil
                                    "auth" "application-default" "print-access-token")
                    (file-missing
                     (signal 'llm-provider-unconfigured
                             '("The configured gcloud executable is unavailable")))
                    (error
                     (signal 'llm-provider-error
                             '("Vertex ADC authentication failed"))))))
      (unless (and (integerp status) (zerop status))
        (signal 'llm-provider-error
                (list (format "Vertex ADC authentication failed (gcloud exit %s)"
                              status))))
      (let ((token (string-trim (buffer-string))))
        (when (string-empty-p token)
          (signal 'llm-provider-error
                  '("Vertex ADC authentication returned an empty access token")))
        token))))

(defun pichat-llm-vertex--adc-file ()
  "Return the ADC file path for the current Emacs environment."
  (or (getenv "GOOGLE_APPLICATION_CREDENTIALS")
      (expand-file-name
       "application_default_credentials.json"
       (or (getenv "CLOUDSDK_CONFIG")
           (expand-file-name "gcloud" (or (getenv "XDG_CONFIG_HOME")
                                           (expand-file-name "~/.config")))))))

(defun pichat-llm-vertex-quota-project (&optional override)
  "Return the ADC quota project, preferring explicit OVERRIDE.
Honor the Google auth library's GOOGLE_CLOUD_QUOTA_PROJECT override.  Do not
confuse the resource project in a Vertex URL with its quota project."
  (let ((project
         (or override (getenv "GOOGLE_CLOUD_QUOTA_PROJECT")
             (let ((file (pichat-llm-vertex--adc-file)))
               (when (file-readable-p file)
                 (condition-case nil
                     (with-temp-buffer
                       (insert-file-contents file)
                       (alist-get 'quota_project_id
                                  (json-parse-buffer :object-type 'alist)))
                   (error nil)))))))
    (when project
      (unless (and (stringp project)
                   (string-match-p "\\`[a-zA-Z0-9][a-zA-Z0-9._:-]*\\'" project))
        (signal 'llm-provider-unconfigured
                '("Invalid Vertex ADC quota project")))
      project)))

(cl-defstruct (pichat-llm-vertex-gemini
               (:include llm-vertex)
               (:constructor pichat-llm-vertex-gemini-create
                             (&key project chat-model gcloud quota-project)))
  "Vertex Gemini provider authenticated with ADC instead of CLI login."
  gcloud
  quota-project)

(cl-defmethod llm-provider-request-prelude
  ((provider pichat-llm-vertex-gemini))
  ;; Refresh before expiry.  Never call the parent's shell-command-to-string
  ;; prelude, which selects the unrelated active gcloud CLI account.
  (unless (and (llm-vertex-key provider)
               (llm-vertex-key-gentime provider)
               (< (float-time (time-subtract
                               (current-time) (llm-vertex-key-gentime provider)))
                  (* 50 60)))
    (setf (llm-vertex-key provider)
          (encode-coding-string
           (pichat-llm-vertex-access-token
            (pichat-llm-vertex-gemini-gcloud provider)) 'utf-8)
          (llm-vertex-key-gentime provider) (current-time))))

(cl-defmethod llm-provider-headers ((provider pichat-llm-vertex-gemini))
  (append (cl-call-next-method)
          (when-let* ((quota (pichat-llm-vertex-quota-project
                              (pichat-llm-vertex-gemini-quota-project provider))))
            `(("x-goog-user-project" . ,quota)))))

(provide 'pichat-llm-vertex-auth)
;;; pichat-llm-vertex-auth.el ends here
