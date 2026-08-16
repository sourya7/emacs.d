;;; tools.el --- tools -*- lexical-binding: t; -*-

;;; Commentary:
;;; Common useful tools

;; Author: Sourya Sharma <sourya.s7@gmail.com>

;;; Code:

(require 'load-relative)
(require 'ansi-color)

(declare-function magit-get-current-branch "magit-git.el")
;;; Docker utilities

(defun my/docker-run (container command volumes &optional sys-admin args)
  "Run CONTAINER with COMMAND, VOLUMES, optional SYS-ADMIN and ARGS."
  (let ((docker-args (append '("run")
                             (when sys-admin '("--cap-add=SYS_ADMIN"))
                             ;(list "--rm")
                             (apply #'append
                                    (mapcar (lambda (vol)
                                              (list "-v" (concat (car vol) ":" (cdr vol))))
                                            volumes))
                             (list container command)
                             (or args '()))))
    (message "Docker run %s" container)
    (with-temp-buffer
      (let ((status (apply #'call-process "docker" nil t nil docker-args)))
        (if (and (integerp status) (zerop status))
            t
          (message "Docker extraction failed (%s): %s"
                   status (string-trim (buffer-string)))
          nil)))))

;;; Content extraction utilities

(defun my/extract-pdf-to-text (workspace filename)
  "Convert PDF FILENAME in WORKSPACE to text format."
  (my/docker-run
   "minidocks/poppler"
   "pdftotext"
   `((,workspace . "/workspace/"))
   nil
   `("-layout" "-nopgbrk" ,(format "/workspace/%s" filename))))

(defun my/docker-extract-url-content (url mode workspace extractors)
  "Extract content from URL in MODE to WORKSPACE using EXTRACTORS."
  (my/docker-run
   "zenika/alpine-chrome:with-playwright"
   "node"
   `((,workspace . "/workspace/")
     (,extractors . "/usr/src/app/scripts"))
   t
   `(,(format "/usr/src/app/scripts/default-%s.js" mode) ,url)))

;;; Content rendering utilities

(defun my/get-text-from-file (file)
  "Get text content from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun my/render-html-in-buffer (buffer html-content url)
  "Render HTML-CONTENT in BUFFER with URL context."
  (with-current-buffer buffer
    (setq-local buffer-read-only nil)
    (erase-buffer)
    (shr-insert-document
     (with-temp-buffer
       (insert html-content)
       (libxml-parse-html-region (point-min) (point-max))))
    (goto-char (point-min))
    (setq-local buffer-read-only t)
    (set-buffer-modified-p nil)))

(defun my/html-to-markdown (html-content)
  "Convert HTML-CONTENT to markdown-ish text preserving links."
  (with-temp-buffer
    (shr-insert-document
     (with-temp-buffer
       (insert html-content)
       (libxml-parse-html-region (point-min) (point-max))))
    (goto-char (point-min))
    (let ((result "")
          (pos (point-min)))
      (while (< pos (point-max))
        (let* ((next-change (or (next-single-property-change pos 'shr-url) (point-max)))
               (url (get-text-property pos 'shr-url))
               (text (buffer-substring-no-properties pos next-change)))
          (if url
              (setq result (concat result (format "[%s](%s)" (string-trim text) url)))
            (setq result (concat result text)))
          (setq pos next-change)))
      result)))

(defun my/render-readable-content (workspace _url &optional buffer _text-only)
  "Render extracted readable content from WORKSPACE into optional BUFFER."
  (let ((json-file (expand-file-name "page.json" workspace)))
    (when (file-exists-p json-file)
      (let* ((json-data (with-temp-buffer
                          (insert-file-contents json-file)
                          (json-parse-buffer :object-type 'alist)))
             (content (alist-get 'content json-data))
             (rendered (when (and (stringp content)
                                  (not (string-empty-p content)))
                         (my/html-to-markdown content))))
        (when (and rendered (not (string-empty-p rendered)))
          (if buffer
              (progn
                (with-current-buffer buffer
                  (let ((inhibit-read-only t))
                    (erase-buffer)
                    (insert rendered)
                    (goto-char (point-min))
                    (setq-local buffer-read-only t)
                    (set-buffer-modified-p nil)))
                buffer)
            rendered))))))

(defun my/render-html-content (workspace url &optional buffer)
  "Render HTML content from WORKSPACE with URL.
If BUFFER is provided, render in buffer and return it.
Otherwise, return text content."
  (let ((html-file (expand-file-name "page.html" workspace)))
    (when (file-exists-p html-file)
      (let ((content (my/get-text-from-file html-file)))
        (if buffer
            (progn
              (my/render-html-in-buffer buffer content url)
              buffer)
          content)))))

(defun my/render-pdf-content (workspace &optional buffer)
  "Render PDF text content from WORKSPACE.
If BUFFER is provided, insert text in buffer and return it.
Otherwise, return text content."
  (let ((text-file (expand-file-name "page.txt" workspace)))
    (when (file-exists-p text-file)
      (let ((content (my/get-text-from-file text-file)))
        (if buffer
            (progn
              (with-current-buffer buffer
                (setq-local buffer-read-only nil)
                (erase-buffer)
                (insert content)
                (goto-char (point-min))
                (setq-local buffer-read-only t)
                (set-buffer-modified-p nil))
              buffer)
          content)))))

(defun my/extract-url-content-multi (url &optional mode buffer)
  "Extract content from URL using specified MODE and return text content in BUFFER.
MODE can be \"readable\", \"text\", \"pdf\", or \"html\"."
  (let* ((mode (or mode "readable"))
         (temporary-file-directory (my/emacs-local-dir "temp"))
         (workspace (make-temp-file "extract-workspace-" t))
         (extractors (my/emacs-shared-dir "extractors"))
         (result nil))
    (unwind-protect
        (cond
         ;; Direct PDF URL - download and extract without Docker/Playwright
         ((string-match-p "\\.pdf\\(?:[?#]\\|$\\)" url)
          (let ((pdf-file (expand-file-name "page.pdf" workspace)))
            (when (zerop (call-process "curl" nil nil nil "-L" "-o" pdf-file url))
              (when (my/extract-pdf-to-text workspace "page.pdf")
                (setq result (my/render-pdf-content workspace buffer))))))
         (t
          (when (my/docker-extract-url-content url (if (string= mode "text") "readable" mode) workspace extractors)
            (setq result
                  (pcase mode
                    ("pdf"
                     (when (my/extract-pdf-to-text workspace "page.pdf")
                       (my/render-pdf-content workspace buffer)))
                    ("text"
                     (my/render-readable-content workspace url buffer t))
                    ("readable"
                     (my/render-readable-content workspace url buffer nil))
                    (_
                     (my/render-html-content workspace url buffer)))))))
      (when (file-exists-p workspace)
        (delete-directory workspace t)))
    result))

(defun my/extract-url-content-web (url)
  "Extract content from URL and display in a buffer.
Default URL is taken from kill ring if it's a valid URL."
  (interactive
   (let* ((kill-text (current-kill 0 t))
          (valid-url (when kill-text
                       (ignore-errors
                         (when (url-type (url-generic-parse-url kill-text))
                           kill-text)))))
     (list (read-string "URL: " valid-url))))
  (let ((buffer (get-buffer-create "*extracted-content*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (if (my/extract-url-content-multi url nil buffer)
        (switch-to-buffer buffer)
      (user-error "Could not extract readable content from %s" url))))

;;; Search utilities

(declare-function request "request.el")
(declare-function request-response-status-code "request.el")
(declare-function request-response-data "request.el")
(declare-function auth-source-pick-first-password "auth-source.el")

(defun my/format-search-results-markdown (results query)
  "Format search RESULTS as markdown with QUERY."
  (concat
   "**Query:** " query "\n"
   (if (zerop (length results))
       "**No results found!**"
     (cl-loop for i from 0
              for result in results
              concat (let* ((title (alist-get "title" result nil nil #'equal))
                            (url (alist-get "url" result nil nil #'equal))
                            (content (alist-get "content" result nil nil #'equal))
                            (engine (alist-get "engine" result nil nil #'equal)))
                       (format "\n%d. [%s](%s) - (%s)\n%s\n%s\n"
                               (1+ i) title url (or engine "unknown") url (or content "")))))))

(defcustom my/web-search-backend 'kagi
  "Backend used by `my/web-search'.
`searx' queries the self-hosted SearXNG instance; `kagi' queries Kagi
via a private-session token (see `my/kagi-session-token').  When `kagi'
is selected but the token is missing or expired, the search falls back
to SearXNG automatically."
  :type '(choice (const :tag "SearXNG (self-hosted)" searx)
                 (const :tag "Kagi (private session token)" kagi))
  :group 'convenience)

(defconst my/kagi-user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
  "Browser User-Agent presented to Kagi's HTML search endpoint.
Kagi may serve a degraded page to non-browser user agents.")

(defun my/kagi-session-token ()
  "Return the Kagi private-session token from auth-source, or nil if unset.
Store it (encrypted) in ~/.authinfo.gpg as:

  machine kagi.com login session password <TOKEN>

where <TOKEN> is the `token' value from a Kagi Session Link (Settings ->
Privacy -> Private Browser Sessions).  The token grants full account
access; never commit it."
  (require 'auth-source)
  (auth-source-pick-first-password :host "kagi.com" :user "session"))

(defun my/kagi--raw-text (node)
  "Concatenate all text descendants of NODE without separators."
  (if (stringp node)
      node
    (mapconcat #'my/kagi--raw-text (dom-children node) "")))

(defun my/kagi--text (node)
  "Return NODE's text content, whitespace-collapsed and trimmed.
Mirrors cheerio's .text() followed by .trim()."
  (string-trim
   (replace-regexp-in-string "[ \t\n\r]+" " " (my/kagi--raw-text node))))

(defun my/kagi--by-class (node class)
  "Return descendant nodes of NODE whose class attribute includes the CLASS token.
Matches a whole space-separated class token, so \"__srgi\" will not match
\"__srgi-title\"."
  (dom-search node
              (lambda (n)
                (let ((c (dom-attr n 'class)))
                  (and c (member class (split-string c)))))))

(defun my/kagi--result-from-link (element link)
  "Build a result alist for search-result ELEMENT given its title LINK node."
  (when link
    (let ((url (dom-attr link 'href))
          (title (my/kagi--text link))
          (desc (car (my/kagi--by-class element "__sri-desc"))))
      (when (and (stringp url) (not (string-empty-p url))
                 (not (string-empty-p title)))
        (list (cons "title" title)
              (cons "url" url)
              (cons "content" (if desc (my/kagi--text desc) ""))
              (cons "engine" "kagi"))))))

(defun my/kagi--parse-results (html limit)
  "Parse Kagi /html/search HTML into a result-list of at most LIMIT entries.
Selectors mirror the unofficial kagi-ken project and may break if Kagi
changes its HTML markup."
  (let* ((dom (with-temp-buffer
                (insert html)
                (libxml-parse-html-region (point-min) (point-max))))
         (results '()))
    ;; Main web results: .search-result -> .__sri_title_link / .__sri-desc
    (dolist (el (my/kagi--by-class dom "search-result"))
      (when (< (length results) limit)
        (when-let ((r (my/kagi--result-from-link
                       el (car (my/kagi--by-class el "__sri_title_link")))))
          (push r results))))
    ;; Grouped sub-results: .sr-group .__srgi -> .__srgi-title a / .__sri-desc
    (dolist (group (my/kagi--by-class dom "sr-group"))
      (dolist (el (my/kagi--by-class group "__srgi"))
        (when (< (length results) limit)
          (let ((tc (car (my/kagi--by-class el "__srgi-title"))))
            (when-let ((r (my/kagi--result-from-link
                           el (and tc (car (dom-by-tag tc 'a))))))
              (push r results))))))
    (nreverse results)))

(defun my/kagi-search (query &optional limit)
  "Search Kagi for QUERY via the private-session token; return a result-list.
Each result is an alist with keys \"title\", \"url\", \"content\", \"engine\".
Signals an error when the token is missing, the session is expired, or the
request fails, so `my/web-search' can fall back to SearXNG."
  (require 'request)
  (require 'dom)
  (let ((token (my/kagi-session-token))
        (limit (or limit 10)))
    (unless token
      (error "Kagi session token not found in auth-source (machine kagi.com login session)"))
    (let* ((response (request "https://kagi.com/html/search"
                       :params `(("q" . ,query))
                       :headers `(("User-Agent" . ,my/kagi-user-agent)
                                  ("Cookie" . ,(concat "kagi_session=" token)))
                       :parser #'buffer-string
                       :sync t))
           (status (request-response-status-code response))
           (html (request-response-data response)))
      (cond
       ((null status)
        (error "Kagi search: network error (no response from kagi.com)"))
       ((memq status '(401 403))
        (error "Kagi search: invalid or expired session token (HTTP %s)" status))
       ((not (and (integerp status) (<= 200 status 299)))
        (error "Kagi search: unexpected HTTP %s" status))
       (t (my/kagi--parse-results (or html "") limit))))))

(defun my/searx-search (query &optional limit)
  "Search the self-hosted SearXNG instance for QUERY; return a result-list."
  (require 'request)
  (let* ((limit (or limit 10))
         (encoded-query (url-encode-url query))
         (result-list nil))
    (request
      "http://localhost:8080/search"
      :params `(("q" . ,encoded-query)
                ("format" . "json"))
      :parser 'json-read
      :sync t
      :complete
      (cl-function
       (lambda (&key data &allow-other-keys)
         (setq result-list
               (cl-loop for result across (seq-take (assoc-default 'results data) limit)
                        collect
                        (list (cons "title" (alist-get 'title result))
                              (cons "url" (alist-get 'url result))
                              (cons "content" (alist-get 'content result))
                              (cons "engine" (alist-get 'engine result))))))))
    result-list))

(defun my/web-search--fetch (query limit)
  "Return a result-list for QUERY, honoring `my/web-search-backend'.
With the `kagi' backend, fall back to SearXNG if the Kagi request fails
\(e.g. a missing or expired session token)."
  (pcase my/web-search-backend
    ('kagi
     (condition-case err
         (my/kagi-search query limit)
       (error
        (message "%s; falling back to SearXNG" (error-message-string err))
        (my/searx-search query limit))))
    (_ (my/searx-search query limit))))

(defun my/web-search (query &optional limit output-format)
  "Web search for QUERY with LIMIT and OUTPUT-FORMAT.
The search backend is selected by `my/web-search-backend'."
  (let* ((limit (or limit 10))
         (output-format (or output-format 'markdown))
         (result-list (my/web-search--fetch query limit)))
    (pcase (intern (format "%s" output-format))
      ('json (json-encode result-list))
      ('markdown (my/format-search-results-markdown result-list query))
      (_ (error "Unsupported output format: %s" output-format)))))

(defun my/web-search-interactive (query)
  "Interactive web search for QUERY that displays results in a markdown buffer."
  (interactive "sSearch query: ")
  (let ((results (my/web-search query 10 'markdown))
        (buffer-name "*web-search-results*"))
    (with-current-buffer (get-buffer-create buffer-name)
      (goto-char (point-min))
      (let ((search-header (format "\n# Search: %s\n\n" query)))
        (insert search-header)
        (insert results)
        (insert "\n---\n"))
      (markdown-mode)
      (goto-char (point-min))
      (switch-to-buffer buffer-name))))

(defun my/process-compose--execute-action (action status-filter prompt-text)
  "Execute ACTION on a process-compose process that matches STATUS-FILTER.
Prompt user with PROMPT-TEXT to select the process."
  (let* ((filter-cmd (if (string= status-filter "Running")
                        "select(.status == \"Running\")"
                        "select(.status != \"Running\")"))
         ;; requires (shell-command-switch "-c") if changed in term.el
         (output (shell-command-to-string (format "process-compose list -o json | jq -r '.[] | %s | .name'" filter-cmd)))
         (process-names (split-string output "\n" t))
         (selected (completing-read prompt-text process-names)))
    (when selected
      (shell-command (concat "process-compose process " action " " selected))
      (message "%s process: %s" (capitalize action) selected))))

(defun my/process-compose-restart-process ()
  "Restart a running process-compose process interactively."
  (interactive)
  (my/process-compose--execute-action "restart" "Running" "Select process to restart: "))

(defun my/process-compose-stop-process ()
  "Stop a running process-compose process interactively."
  (interactive)
  (my/process-compose--execute-action "stop" "Running" "Select process to stop: "))

(defun my/process-compose-start-process ()
  "Start a stopped process-compose process interactively."
  (interactive)
  (my/process-compose--execute-action "start" "!Running" "Select process to start: "))

(defun my/process-compose-down ()
  "Bring down process-compose without displaying the output window."
  (interactive)
  (let ((display-buffer-alist
         (cons (list shell-command-buffer-name-async
                    'display-buffer-no-window)
               display-buffer-alist)))
    (async-shell-command "process-compose down")))

(defun my/process-compose-up ()
  "Bring up the process compose for the project."
  (interactive)
  (let ((project-dir (when (and (fboundp 'project-root) (project-current))
                       (project-root (project-current)))))
    (if project-dir
        (let ((default-directory project-dir))
          (message "Current directory is %s" default-directory)
          (async-shell-command "process-compose up -D"))
      (message "The command can only be run from a project"))))

(defun my/process-compose-list-process ()
  "Display process-compose processes in a tabular format."
  (interactive)
  (when-let* ((output (shell-command-to-string "process-compose list -o json"))
              (json-or-nil (if (string-match-p "failed to list" output)
                               (progn (message "Error listing processes.") nil)
                             output))
              (processes (json-parse-string json-or-nil :object-type 'alist))
              (buffer (get-buffer-create "*process-compose-list*")))
    (with-current-buffer buffer
      (read-only-mode 0)
      (erase-buffer)
      (insert (format "%-8s %-15s %-10s %-9s %-8s %-8s %-9s %-9s\n"
                     "PID" "NAME" "NAMESPACE" "STATUS" "AGE" "HEALTH" "RESTARTS" "EXITCODE"))
      (seq-doseq (proc processes)
        (insert (format "%-8s %-15s %-10s %-9s %-8s %-8s %-9d %-9d\n"
                       (or (number-to-string (alist-get 'pid proc)) "-")
                       (or (alist-get 'name proc) "-")
                       (or (alist-get 'namespace proc) "-")
                       (or (alist-get 'status proc) "-")
                       (or (alist-get 'system_time proc) "-")
                       (or (alist-get 'is_ready proc) "-")
                       (or (alist-get 'restarts proc) 0)
                       (or (alist-get 'exit_code proc) -1))))
      (read-only-mode 1)
      (tabulated-list-mode))
    (pop-to-buffer buffer)))

(provide 'user/tools)
;;; tools.el ends here
