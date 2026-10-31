;;; cliproxy-usage.el --- Read Codex quota through CLIProxyAPI -*- lexical-binding: t; -*-

;;; Commentary:
;; `my/cliproxy-usage' reads the management key from auth-source:
;; machine <PROXY-HOST> login mankey password <MANAGEMENT-KEY>
;; An optional numeric port field selects a non-default HTTPS port.
;; The inference API key (login apikey) is neither needed nor read.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-http)

(defvar my/cliproxy-usage--generation 0
  "Generation of the most recent quota request.")

(defun my/cliproxy-usage--connection ()
  "Return (BASE-URL . KEY) from the unique auth-source login mankey.
Derive the HTTPS destination solely from the entry's host and optional
numeric port.  Reject ambiguous entries and non-host machine values."
  (let* ((entries (auth-source-search :user "mankey" :host t
                                      :require '(:host :secret) :max 2))
         (entry (car entries))
         (host (plist-get entry :host))
         (port (plist-get entry :port)))
    (unless (= (length entries) 1)
      (user-error "Expected one auth-source entry with login mankey; found %d"
                  (length entries)))
    (unless (and (stringp host)
                 (string-match-p "\\`[[:alnum:]][[:alnum:].-]*\\'" host))
      (user-error "The mankey entry must have a hostname as its machine value"))
    (when (and port (not (equal port "https"))
               (not (string-match-p "\\`[0-9]+\\'" (format "%s" port))))
      (user-error "The mankey entry's port must be numeric or https"))
    (let* ((secret (plist-get entry :secret))
           (key (if (functionp secret) (funcall secret) secret)))
      (unless (and (stringp key) (not (string-empty-p key)))
        (user-error "No password in the auth-source entry with login mankey"))
      (cons (concat "https://" host
                    (if (and port (not (equal port "https")))
                        (format ":%s" port)
                      "")
                    "/v8/management")
            key))))

(defun my/cliproxy-usage--request (base-url path key data callback)
  "Request management PATH at BASE-URL with KEY and optional JSON DATA.
Call CALLBACK with the parsed response.  Do not follow redirects or
include response bodies in errors, since they may contain account data."
  (let ((url-request-method (if data "POST" "GET"))
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " key))
           ("Content-Type" . "application/json")
           ("Accept" . "application/json")))
        (url-request-data (and data (encode-coding-string
                                    (json-serialize data) 'utf-8)))
        (url-max-redirections 0))
    (url-retrieve
     (concat base-url path)
     (lambda (status)
       (unwind-protect
           (condition-case nil
               (cond
                ((not (equal url-http-response-status 200))
                 (message "CLIProxyAPI: management request failed (HTTP %s)"
                          (or url-http-response-status "unavailable")))
                ((plist-get status :error)
                 (message "CLIProxyAPI: network request failed"))
                (t
                 (goto-char url-http-end-of-headers)
                 (funcall callback
                          (json-parse-buffer :object-type 'alist
                                             :array-type 'list
                                             :null-object nil
                                             :false-object nil))))
             (error (message "CLIProxyAPI: could not process quota response")))
         (kill-buffer (current-buffer))))
     nil t t)))

(defun my/cliproxy-usage--window (label window)
  "Format quota WINDOW with LABEL, or return nil when absent."
  (let ((used (alist-get 'used_percent window))
        (reset (alist-get 'reset_at window))
        (seconds (alist-get 'limit_window_seconds window)))
    (when (numberp used)
      (format "%-18s %6.1f%% used   %6.1f%% remaining\n  Resets: %s%s\n\n"
              (cond ((equal seconds 18000) "5-hour")
                    ((equal seconds 604800) "Weekly")
                    (t label))
              used (max 0 (- 100 used))
              (if (numberp reset)
                  (format-time-string "%Y-%m-%d %H:%M %Z"
                                      (seconds-to-time reset))
                "not reported")
              (if (numberp seconds)
                  (format "  (%.1f-hour window)" (/ seconds 3600.0))
                "")))))

(defun my/cliproxy-usage--display (payload)
  "Display Codex quota PAYLOAD in a read-only buffer."
  (let* ((limits (alist-get 'rate_limit payload))
         (primary (my/cliproxy-usage--window
                   "Primary" (alist-get 'primary_window limits)))
         (secondary (my/cliproxy-usage--window
                     "Secondary" (alist-get 'secondary_window limits))))
    (unless (or primary secondary)
      (user-error "No Codex quota windows returned"))
    (with-current-buffer (get-buffer-create "*CLIProxyAPI Usage*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Codex subscription quota\n\n"
                "Updated: " (format-time-string "%Y-%m-%d %H:%M %Z") "\n"
                "Plan: " (format "%s" (or (alist-get 'plan_type payload)
                                           "not reported"))
                "\n\n" (or primary "") (or secondary "")
                "g: refresh    q: quit\n")
        (goto-char (point-min)))
      (special-mode)
      (use-local-map (copy-keymap special-mode-map))
      (local-set-key (kbd "g") #'my/cliproxy-usage)
      (display-buffer (current-buffer)))))

(defun my/cliproxy-usage ()
  "Show the single Codex account's quota through CLIProxyAPI.
Derive the HTTPS host and management key from the unique auth-source
entry with login mankey.  Provider OAuth credentials stay on the proxy server.
Requests run asynchronously; invoking again supersedes older results."
  (interactive)
  (let* ((connection (my/cliproxy-usage--connection))
         (base-url (car connection))
         (key (cdr connection))
         (generation (cl-incf my/cliproxy-usage--generation)))
    (message "Fetching Codex quota…")
    (my/cliproxy-usage--request
     base-url "/credentials" key nil
     (lambda (response)
       (when (= generation my/cliproxy-usage--generation)
         (let ((accounts
                (cl-remove-if-not
                 (lambda (file)
                   (and (or (equal (alist-get 'provider file) "codex")
                            (equal (alist-get 'type file) "codex"))
                        (not (alist-get 'disabled file))))
                 (alist-get 'files response))))
           (if (/= (length accounts) 1)
               (message "CLIProxyAPI: expected one enabled Codex account, found %d"
                        (length accounts))
             (let* ((account (car accounts))
                    (index (alist-get 'auth_index account))
                    (claims (alist-get 'id_token account))
                    (account-id (or (alist-get 'chatgpt_account_id account)
                                    (and (listp claims)
                                         (alist-get 'chatgpt_account_id claims))))
                    (headers
                     `((Authorization . "Bearer $TOKEN$")
                       (Accept . "application/json")
                       (User-Agent . "codex-tui"))))
               (unless (and (stringp index) (not (string-empty-p index)))
                 (user-error "Codex account has no auth_index"))
               (when (stringp account-id)
                 (push (cons 'Chatgpt-Account-Id account-id) headers))
               (my/cliproxy-usage--request
                base-url "/requests/api-call" key
                `((auth_index . ,index)
                  (method . "GET")
                  (url . "https://chatgpt.com/backend-api/wham/usage")
                  (header . ,headers))
                (lambda (result)
                  (when (= generation my/cliproxy-usage--generation)
                    (let ((status (alist-get 'status_code result))
                          (body (alist-get 'body result)))
                      (if (and (numberp status) (<= 200 status) (< status 300))
                          (my/cliproxy-usage--display
                           (if (stringp body)
                               (json-parse-string body :object-type 'alist
                                                  :array-type 'list
                                                  :null-object nil
                                                  :false-object nil)
                             body))
                        (message "CLIProxyAPI: Codex quota request failed (HTTP %s)"
                                 status))))))))))))))

(provide 'user/cliproxy-usage)
;;; cliproxy-usage.el ends here
