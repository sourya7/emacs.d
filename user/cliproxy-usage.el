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

(defvar my/cliproxy-usage--snapshot nil
  "Last valid account-wide quota snapshot, or nil before a successful fetch.")

(defvar my/cliproxy-usage-updated-hook nil
  "Hook run after publishing a valid snapshot; no arguments.
Consumers may read `my/cliproxy-usage-snapshot'.  Loading or reading the cache
never accesses auth-source or the network.")

(defvar-local my/cliproxy-usage-display-policy 'report
  "Presentation for manually fetched quota: `report' or `header-only'.
The command captures this policy before starting asynchronous requests.")

(defun my/cliproxy-usage-snapshot ()
  "Return a copy of the last successfully fetched account-wide quota.
The plist contains :updated-at (Emacs time) and :windows (a list of plists).
Each window has :label, :used, :remaining, optional :reset-at (Unix seconds)
and :seconds (duration).  No credentials or account identifiers are retained.
This is last-fetched allowance, not live usage or runtime/model consumption."
  (copy-tree my/cliproxy-usage--snapshot))

(defun my/cliproxy-usage--normalize-window (label window)
  "Validate and normalize a reported WINDOW with fallback LABEL.
Absent windows return nil; malformed present windows reject the response."
  (when window
    (let ((used (alist-get 'used_percent window))
          (reset (alist-get 'reset_at window))
          (seconds (alist-get 'limit_window_seconds window)))
      (unless (and (numberp used) (<= 0 used 100)
                   (or (null reset)
                       (and (integerp reset) (<= 0 reset 253402300799)))
                   (or (null seconds)
                       (and (integerp seconds) (< 0 seconds 253402300799))))
        (error "Invalid quota window"))
      (list :label (cond ((equal seconds 18000) "5-hour")
                         ((equal seconds 604800) "Weekly")
                         (t label))
            :used used :remaining (- 100 used)
            :reset-at reset :seconds seconds))))

(defun my/cliproxy-usage--publish (payload)
  "Validate PAYLOAD and atomically publish only normalized quota data."
  (let* ((limits (alist-get 'rate_limit payload))
         (windows (delq nil
                        (list (my/cliproxy-usage--normalize-window
                               "Primary" (alist-get 'primary_window limits))
                              (my/cliproxy-usage--normalize-window
                               "Secondary" (alist-get 'secondary_window limits))))))
    (unless windows (error "No Codex quota windows returned"))
    (setq my/cliproxy-usage--snapshot
          (list :updated-at (current-time) :windows windows))
    (run-hooks 'my/cliproxy-usage-updated-hook)))

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
                          (if (and (integerp url-http-response-status)
                                   (<= 100 url-http-response-status 599))
                              url-http-response-status "unavailable")))
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

(defun my/cliproxy-usage--window (window)
  "Format a normalized quota WINDOW."
  (let ((reset (plist-get window :reset-at))
        (seconds (plist-get window :seconds)))
    (format "%-18s %6.1f%% used   %6.1f%% remaining\n  Resets: %s%s\n\n"
            (plist-get window :label)
            (plist-get window :used) (plist-get window :remaining)
            (if reset
                (format-time-string "%Y-%m-%d %H:%M %Z"
                                    (seconds-to-time reset))
              "not reported")
            (if seconds
                (format "  (%.1f-hour window)" (/ seconds 3600.0))
              ""))))

(defun my/cliproxy-usage--display ()
  "Display the last successful Codex quota snapshot in a read-only buffer."
  (let ((snapshot (my/cliproxy-usage-snapshot)))
    (with-current-buffer (get-buffer-create "*CLIProxyAPI Usage*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Codex subscription quota (account-wide, last fetched)\n\n"
                "Updated: " (format-time-string
                             "%Y-%m-%d %H:%M %Z"
                             (plist-get snapshot :updated-at))
                "\n\n"
                (mapconcat #'my/cliproxy-usage--window
                           (plist-get snapshot :windows) "")
                "g: refresh    q: quit\n")
        (goto-char (point-min)))
      (special-mode)
      (use-local-map (copy-keymap special-mode-map))
      (local-set-key (kbd "g") #'my/cliproxy-usage)
      (display-buffer (current-buffer)))))

(defun my/cliproxy-usage (&optional display-policy)
  "Fetch the single Codex account's quota through CLIProxyAPI.
Derive the HTTPS host and management key from the unique auth-source
entry with login mankey.  Provider OAuth credentials stay on the proxy server.
Requests run asynchronously; invoking again supersedes older results.
DISPLAY-POLICY defaults to `my/cliproxy-usage-display-policy': `report'
shows the usage buffer, while `header-only' only publishes the shared cache."
  (interactive)
  (let* ((generation (cl-incf my/cliproxy-usage--generation))
         (policy (or display-policy my/cliproxy-usage-display-policy))
         (connection (my/cliproxy-usage--connection))
         (base-url (car connection))
         (key (cdr connection)))
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
                      (if (and (integerp status) (<= 200 status 299))
                          (condition-case nil
                              (progn
                                (my/cliproxy-usage--publish
                                 (if (stringp body)
                                     (json-parse-string body :object-type 'alist
                                                        :array-type 'list
                                                        :null-object nil
                                                        :false-object nil)
                                   body))
                                ;; An update hook may itself start a new request.
                                (when (= generation my/cliproxy-usage--generation)
                                  (if (eq policy 'header-only)
                                      (message "Codex quota updated (account-wide, last fetched)")
                                    (my/cliproxy-usage--display))))
                            (error (message "CLIProxyAPI: could not process quota response")))
                        (message "CLIProxyAPI: Codex quota request failed (HTTP %s)"
                                 (if (and (integerp status) (<= 100 status 599))
                                     status "unavailable")))))))))))))))

(provide 'user/cliproxy-usage)
;;; cliproxy-usage.el ends here
