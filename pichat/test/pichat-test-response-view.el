;;; pichat-test-response-view.el --- Rendered response view tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused canonical response snapshot, rendering, and lifecycle coverage.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-response-view--response (key markdown &optional token)
  "Return a canonical response fixture with KEY, MARKDOWN, and TOKEN."
  (pichat-chat-navigation-response-create
   :node-key key :source-token (or token '(1 "source"))
   :prose-segments (unless (string-empty-p markdown) (list markdown))
   :markdown markdown))

(defun pichat-test-response-view--node (key role text)
  "Return a minimal canonical message with KEY, ROLE, and TEXT."
  (pichat-transcript-node-create
   :kind 'message :key key :role role
   :content (list (pichat-transcript-content-create
                   :kind 'prose :index 0 :text text))))

(defun pichat-test-response-view--html (_markdown)
  "Return representative rendered HTML for a response view test."
  (concat
   "<h1>Rendered heading</h1>"
   "<p>Paragraph with <a href=\"https://example.test/path\">a link</a>.</p>"
   "<blockquote><p>Quoted prose</p></blockquote>"
   "<pre><code>(message &quot;code&quot;)</code></pre>"
   "<table><thead><tr><th>Name</th><th>Value</th></tr></thead>"
   "<tbody><tr><td>Pi</td><td>Chat</td></tr></tbody></table>"))

(ert-deftest pichat-response-navigation-selects-adjacent-prose-only ()
  (let* ((nodes (list (pichat-test-response-view--node "first" 'assistant "First")
                      (pichat-test-response-view--node "user" 'user "Question")
                      (pichat-transcript-node-create
                       :kind 'message :key "tool-only" :role 'assistant
                       :content (list (pichat-transcript-content-create
                                       :kind 'tool-call :index 0)))
                      (pichat-test-response-view--node "space" 'assistant "  ")
                      (pichat-test-response-view--node "last" 'assistant "Last")))
         (transcript (pichat-transcript-create :nodes nodes))
         (token '(source generation)))
    (should (equal "space"
                   (pichat-chat-navigation-response-node-key
                    (pichat-chat-navigation-adjacent-response
                     transcript "first" 'next token))))
    (let ((previous (pichat-chat-navigation-adjacent-response
                     transcript "last" 'previous token)))
      (should (equal "  " (pichat-chat-navigation-response-markdown previous)))
      (should (equal token (pichat-chat-navigation-response-source-token
                            previous))))
    (should (equal "first"
                   (pichat-chat-navigation-response-node-key
                    (pichat-chat-navigation-adjacent-response
                     transcript "space" 'previous token))))
    (should-not (pichat-chat-navigation-adjacent-response
                 transcript "first" 'previous token))
    (should-not (pichat-chat-navigation-adjacent-response
                 transcript "last" 'next token))
    (should-error (pichat-chat-navigation-adjacent-response
                   transcript "missing" 'next token) :type 'user-error)
    (should-error (pichat-chat-navigation-adjacent-response
                   transcript "user" 'next token) :type 'user-error)))

(ert-deftest pichat-response-view-mode-has-read-only-snapshot-commands ()
  (with-temp-buffer
    (pichat-response-view-mode)
    (should (derived-mode-p 'pichat-view-mode))
    (should buffer-read-only)
    (should visual-line-mode)
    (should-not truncate-lines)
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "g"))
                #'pichat-response-view-refresh))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "n"))
                #'pichat-response-view-next))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "p"))
                #'pichat-response-view-previous))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "t"))
                #'pichat-response-view-return-to-origin))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "w"))
                #'pichat-response-view-copy-markdown))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "q"))
                #'pichat-view-quit))
    (should (assq 'shr-h1 face-remapping-alist))
    (should (assq 'shr-code face-remapping-alist))
    (should (assq 'shr-link face-remapping-alist))
    (should (eq (lookup-key pichat-response-view-link-map (kbd "RET"))
                #'pichat-response-view-open-link-at-point))
    (should (eq (lookup-key pichat-response-view-link-map (kbd "w"))
                #'pichat-response-view-link-word-or-copy))
    (should (eq (lookup-key pichat-response-view-link-map (kbd "?"))
                #'pichat-response-view-link-search-or-describe))))

(ert-deftest pichat-response-view-link-map-retains-emacs-actions ()
  (with-temp-buffer
    (pichat-response-view-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "link" 'pichat-response-view-url
                          "https://example.test" 'keymap
                          pichat-response-view-link-map)))
    (goto-char (point-min))
    (let (copied described)
      (cl-letf (((symbol-function 'pichat-response-view-copy-link-at-point)
                 (lambda () (setq copied t)))
                ((symbol-function 'pichat-response-view-describe-link-at-point)
                 (lambda () (setq described t))))
        (call-interactively (key-binding (kbd "w")))
        (call-interactively (key-binding (kbd "?"))))
      (should copied)
      (should described))))

(ert-deftest pichat-response-view-renders-reflowed-structured-html-with-faces ()
  (let ((pichat-response-view-convert-function
         #'pichat-test-response-view--html))
    (with-temp-buffer
      (pichat-response-view-mode)
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response
        "rendered" "# raw heading\n\n| Name | Value |")
       48)
      (let ((text (buffer-string)))
        (dolist (visible '("Rendered heading" "Paragraph with" "a link"
                           "Quoted prose" "message" "Name" "Value" "Pi" "Chat"))
          (should (string-match-p (regexp-quote visible) text)))
        (should-not (string-match-p (regexp-quote "| Name | Value |") text)))
      (goto-char (point-min))
      (search-forward "Rendered heading")
      (should (eq 'shr-h1 (get-text-property (1- (point)) 'face)))
      (search-forward "a link")
      (should (equal "https://example.test/path"
                     (get-text-property (1- (point)) 'shr-url)))
      (search-forward "Quoted prose")
      (should (memq 'pichat-response-view-blockquote-face
                    (ensure-list (get-text-property (1- (point)) 'face))))
      (search-forward "message")
      (should (memq 'pichat-response-view-code-face
                    (ensure-list (get-text-property (1- (point)) 'face))))
      (search-forward "Name")
      (should (memq 'pichat-response-view-table-face
                    (ensure-list (get-text-property (1- (point)) 'face)))))))

(ert-deftest pichat-response-view-opens-only-configured-safe-link-schemes ()
  (let ((pichat-response-view-convert-function
         (lambda (_markdown)
           (concat "<p><a href=\"https://safe.test/path\">safe</a> "
                   "<a href=\"javascript:alert(1)\">unsafe</a></p>")))
        (pichat-response-view-safe-link-schemes '("https"))
        opened described)
    (with-temp-buffer
      (pichat-response-view-mode)
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response "links" "links") 60)
      (goto-char (point-min))
      (search-forward "safe")
      (backward-char)
      (should (equal "https://safe.test/path"
                     (get-text-property (point) 'shr-url)))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (pichat-response-view-open-link-at-point))
      (should (equal "https://safe.test/path" opened))
      (search-forward "unsafe")
      (backward-char)
      (should-not (get-text-property (point) 'shr-url))
      (should (equal "javascript:alert(1)"
                     (get-text-property (point) 'pichat-response-view-url)))
      (let ((opened-before opened))
        (should-error (pichat-response-view-open-link-at-point)
                      :type 'user-error)
        (should (equal opened-before opened)))
      (pichat-response-view-copy-link-at-point)
      (should (equal "javascript:alert(1)" (current-kill 0 t)))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq described (apply #'format format-string args)))))
        (pichat-response-view-describe-link-at-point))
      (should (equal "javascript:alert(1)" described)))))

(ert-deftest pichat-response-view-discards-active-html-and-remote-resources ()
  (let ((pichat-response-view-convert-function
         (lambda (_markdown)
           (concat
            "<html><head><link rel=\"stylesheet\" href=\"https://bad.test/x.css\">"
            "<meta http-equiv=\"refresh\" content=\"0;url=https://bad.test\">"
            "</head><body><p onclick=\"bad()\">Safe <b>prose</b></p>"
            "<figure><img src=\"https://bad.test/pixel\" alt=\"tracker\">"
            "<figcaption>REMOTE CAPTION</figcaption></figure>"
            "<script>EXECUTE</script><iframe src=\"https://bad.test\">FRAME</iframe>"
            "<form action=\"https://bad.test\">FORM</form></body></html>")))
        (image-rendered nil)
        (external-renderer-called nil)
        (shr-external-rendering-functions
         `((p . ,(lambda (_dom) (setq external-renderer-called t))))))
    (cl-letf (((symbol-function 'shr-tag-img)
               (lambda (&rest _) (setq image-rendered t)))
              ((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) (error "unexpected resource retrieval"))))
      (with-temp-buffer
        (pichat-response-view-mode)
        (pichat-response-view--replace-rendering
         (pichat-test-response-view--response "hostile" "hostile") 60)
        (let ((text (buffer-string)))
          (should (string-match-p "Safe prose" text))
          (should (string-match-p "Image omitted: tracker" text))
          (dolist (discarded '("REMOTE CAPTION" "EXECUTE" "FRAME" "FORM"
                               "bad.test"))
            (should-not (string-match-p discarded text))))
        (should-not image-rendered)
        (should-not external-renderer-called)
        (should-not (text-property-not-all
                     (point-min) (point-max) 'shr-url nil))))))

(ert-deftest pichat-response-view-conversion-failure-shows-exact-markdown ()
  (let* ((exact "# Exact source\n\n[unsafe](file:///tmp/private)\n")
         (pichat-response-view-convert-function
          (lambda (_markdown) (user-error "converter unavailable"))))
    (with-temp-buffer
      (pichat-response-view-mode)
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response "fallback" exact) 60)
      (should (equal exact pichat-response-view-source-markdown))
      (should (string-match-p "Rendered preview unavailable"
                              (buffer-string)))
      (should (string-suffix-p exact (buffer-string)))
      (should-not (text-property-not-all
                   (point-min) (point-max) 'shr-url nil))
      (pichat-response-view-copy-markdown)
      (should (equal exact (current-kill 0 t))))))

(ert-deftest pichat-response-view-falls-back-when-sanitization-removes-everything ()
  (let ((pichat-response-view-convert-function
         (lambda (_markdown) "<html><body><script>hidden</script></body></html>"))
        (exact "Important canonical prose"))
    (with-temp-buffer
      (pichat-response-view-mode)
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response "discarded" exact) 60)
      (should (string-match-p "Rendered preview unavailable" (buffer-string)))
      (should (string-suffix-p exact (buffer-string)))
      (should-not (string-match-p "hidden" (buffer-string))))))

(ert-deftest pichat-response-view-copies-exact-source-and-shows-empty-response ()
  (let ((pichat-response-view-convert-function
         #'pichat-test-response-view--html)
        (exact "[label](https://example.test)\n\n| A | B |\n|---|---|"))
    (with-temp-buffer
      (pichat-response-view-mode)
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response "copy" exact) 60)
      (pichat-response-view-copy-markdown)
      (should (equal exact (current-kill 0 t)))
      (pichat-response-view--replace-rendering
       (pichat-test-response-view--response "empty" "") 60)
      (should (equal "" pichat-response-view-source-markdown))
      (should (string-match-p "No assistant prose" (buffer-string))))))

(ert-deftest pichat-response-view-refresh-is-transactional-and-rejects-stale-source ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-response-origin*"))
          view current
          (display-buffer-overriding-action '((display-buffer-same-window)))
          (pichat-response-view-convert-function
           (lambda (markdown) (format "<p>%s</p>" markdown))))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq current t)
            (setq view
                  (pichat-response-view-open
                   (pichat-test-response-view--response "stable" "initial")
                   (pichat-view-capture-origin)
                   (lambda (_response)
                     (if current
                         (pichat-test-response-view--response
                          "stable" "refreshed")
                       (user-error "stale fixture")))
                   (lambda (_response)
                     (if current (point-min) (user-error "stale fixture")))
                   "fixture"))
            (with-current-buffer view
              (pichat-response-view-refresh)
              (should (equal "refreshed" pichat-response-view-source-markdown))
              (let ((rendered (buffer-string)))
                (setq current nil)
                (should-error (pichat-response-view-refresh) :type 'user-error)
                (should (equal "refreshed"
                               pichat-response-view-source-markdown))
                (should (equal rendered (buffer-string))))
              (should-error (pichat-response-view-return-to-origin)
                            :type 'user-error)
              (should (buffer-live-p view))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-view-refresh-preserves-approximate-reading-position ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-response-position-origin*"))
          view
          (display-buffer-overriding-action '((display-buffer-same-window)))
          (pichat-response-view-convert-function
           (lambda (markdown) (format "<p>%s</p>" markdown))))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq view
                  (pichat-response-view-open
                   (pichat-test-response-view--response
                    "position" (make-string 500 ?x))
                   (pichat-view-capture-origin)
                   (lambda (_response)
                     (pichat-test-response-view--response
                      "position" (make-string 1000 ?x)))
                   (lambda (_response) (point-min)) "position"))
            (with-current-buffer view
              (goto-char (+ (point-min) (/ (- (point-max) (point-min)) 2)))
              (pichat-response-view-refresh)
              (should (> (point) (+ (point-min) 200)))
              (should (< (point) (- (point-max) 200)))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-view-renders-at-displayed-window-width ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-response-width-origin*"))
          view seen-width
          (pichat-response-view-convert-function
           (lambda (_markdown) "<p>width fixture</p>")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (let ((origin-width (window-body-width (selected-window)))
                  (original (symbol-function 'pichat-response-view--rendered-string)))
              (cl-letf (((symbol-function 'pichat-response-view--rendered-string)
                         (lambda (markdown width)
                           (setq seen-width width)
                           (funcall original markdown width)))
                        ((symbol-function 'pichat-view-display)
                         (lambda (buffer &rest _)
                           (let ((window (split-window-right)))
                             (set-window-buffer window buffer)
                             (select-window window))
                           buffer)))
                (setq view
                      (pichat-response-view-open
                       (pichat-test-response-view--response "width" "text")
                       (pichat-view-capture-origin) #'ignore #'ignore "width")))
              (should (= seen-width (window-body-width (selected-window))))
              (should (< seen-width origin-width))
              (should (eq view (window-buffer (selected-window))))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-view-remains-readable-after-origin-dies ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-response-dead-origin*"))
          view
          (display-buffer-overriding-action '((display-buffer-same-window)))
          (pichat-response-view-convert-function
           (lambda (_markdown) "<p>snapshot text</p>")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq view
                  (pichat-response-view-open
                   (pichat-test-response-view--response "dead" "exact")
                   (pichat-view-capture-origin) #'ignore #'ignore "dead"))
            (kill-buffer origin)
            (with-current-buffer view
              (should (string-match-p "snapshot text" (buffer-string)))
              (should-error (pichat-response-view-refresh) :type 'user-error)
              (should-error (pichat-response-view-return-to-origin)
                            :type 'user-error)
              (should (equal "exact" pichat-response-view-source-markdown))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-view-valid-return-kills-view-and-focuses-origin ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-response-return-origin*"))
          view target
          (display-buffer-overriding-action '((display-buffer-same-window)))
          (pichat-response-view-convert-function
           (lambda (_markdown) "<p>response</p>")))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (with-current-buffer origin
              (insert "before response after")
              (setq target 8))
            (setq view
                  (pichat-response-view-open
                   (pichat-test-response-view--response "return" "response")
                   (pichat-view-capture-origin) #'ignore
                   (lambda (_response) target) "return"))
            (with-current-buffer view
              (pichat-response-view-return-to-origin))
            (should-not (buffer-live-p view))
            (should (eq origin (current-buffer)))
            (should (= target (point))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-navigation-reuses-view-and-preserves-failures ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-navigation-origin*"))
          view current position refreshed returned
          (display-buffer-overriding-action '((display-buffer-same-window)))
          (pichat-response-view-convert-function
           (lambda (markdown) (format "<p>%s</p>" markdown))))
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq current t)
            (setq view
                  (pichat-response-view-open
                   (pichat-test-response-view--response "first" "First")
                   (pichat-view-capture-origin)
                   (lambda (response)
                     (setq refreshed (pichat-chat-navigation-response-node-key
                                      response))
                     response)
                   (lambda (response)
                     (setq returned (pichat-chat-navigation-response-node-key
                                     response))
                     position)
                   "navigation"
                   (lambda (response direction)
                     (unless current (user-error "source changed"))
                     (pcase (list (pichat-chat-navigation-response-node-key
                                   response) direction)
                       (`("first" next)
                        (pichat-test-response-view--response "last" "Last"))
                       (`("last" previous)
                        (pichat-test-response-view--response "first" "First"))))))
            (with-current-buffer view
              (setq position 1)
              (goto-char (point-max))
              (pichat-response-view-next)
              (should (eq view (current-buffer)))
              (should (= (point) (point-min)))
              (should (equal "Last" pichat-response-view-source-markdown))
              (pichat-response-view-copy-markdown)
              (should (equal "Last" (current-kill 0 t)))
              (pichat-response-view-refresh)
              (should (equal "last" refreshed))
              (let ((text (buffer-string))
                    (identity pichat-response-view-response))
                (goto-char (point-max))
                (let ((at-boundary (point)))
                  (pichat-response-view-next)
                  (should (= at-boundary (point))))
                (should (equal text (buffer-string)))
                (should (eq identity pichat-response-view-response))
                (cl-letf (((symbol-function 'pichat-response-view--rendered-string)
                           (lambda (&rest _) (error "render failure"))))
                  (should-error (pichat-response-view-previous)))
                (should (eq identity pichat-response-view-response))
                (should (equal text (buffer-string)))
                (setq current nil)
                (should-error (pichat-response-view-previous) :type 'user-error)
                (should (equal text (buffer-string)))
                (setq current t))
              (pichat-response-view-return-to-origin))
            (should-not (buffer-live-p view))
            (should (eq origin (current-buffer)))
            (should (equal "last" returned)))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-response-navigation-rejects-dead-origin ()
  (save-window-excursion
    (let ((origin (generate-new-buffer " *pichat-dead-navigation-origin*"))
          view)
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq view (pichat-response-view-open
                        (pichat-test-response-view--response "first" "First")
                        (pichat-view-capture-origin) #'ignore #'ignore
                        "dead" (lambda (&rest _) (error "must not run"))))
            (kill-buffer origin)
            (with-current-buffer view
              (let ((text (buffer-string)))
                (should-error (pichat-response-view-next) :type 'user-error)
                (should (equal text (buffer-string)))
                (should (equal "First" pichat-response-view-source-markdown)))))
        (dolist (buffer (list view origin))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-view-response-uses-canonical-node-at-point ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-response-view-convert-function
           (lambda (markdown) (format "<p>%s</p>" markdown)))
          chat view)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session))
            (with-current-buffer chat
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-test-response-view--node
                         "user-first" 'user "first question")
                        (pichat-test-response-view--node
                         "assistant-first" 'assistant "first response")
                        (pichat-test-response-view--node
                         "user-latest" 'user "latest question")
                        (pichat-test-response-view--node
                         "assistant-latest" 'assistant "latest response"))))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical nil transcript fragment context)
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "first response")
                (backward-char)
                (should (equal "assistant-first"
                               (get-text-property (point) 'pichat-node-key)))
                (cl-letf (((symbol-function 'pichat-view-display)
                           (lambda (buffer &rest _) (setq view buffer))))
                  (pichat-chat-view-response))))
            (with-current-buffer view
              (should (derived-mode-p 'pichat-response-view-mode))
              (should (equal "assistant-first"
                             (pichat-chat-navigation-response-node-key
                              pichat-response-view-response)))
              (should (equal "first response"
                             pichat-response-view-source-markdown))
              (pichat-response-view-next)
              (should (equal "latest response"
                             pichat-response-view-source-markdown))
              (pichat-response-view-previous)
              (should (equal "first response"
                             pichat-response-view-source-markdown))
              (with-current-buffer chat
                (cl-incf pichat-chat--source-generation))
              (should-error (pichat-response-view-next) :type 'user-error)
              (should (equal "first response"
                             pichat-response-view-source-markdown))
              (with-current-buffer chat
                (cl-decf pichat-chat--source-generation)
                (setq-local pichat-chat--canonical-transcript
                            (pichat-transcript-create
                             :nodes (list (pichat-test-response-view--node
                                           "user-only" 'user "Question")))))
              (should-error (pichat-response-view-next) :type 'user-error)
              (should (equal "first response"
                             pichat-response-view-source-markdown)))
            (should (eq (lookup-key pichat-chat-mode-map (kbd "C-c C-h"))
                        #'pichat-chat-view-response)))
        (dolist (buffer (list view chat))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-response-view)
;;; pichat-test-response-view.el ends here
