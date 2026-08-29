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

(ert-deftest pichat-response-view-mode-has-read-only-snapshot-commands ()
  (with-temp-buffer
    (pichat-response-view-mode)
    (should (derived-mode-p 'pichat-view-mode))
    (should buffer-read-only)
    (should visual-line-mode)
    (should-not truncate-lines)
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "g"))
                #'pichat-response-view-refresh))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "t"))
                #'pichat-response-view-return-to-origin))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "w"))
                #'pichat-response-view-copy-markdown))
    (should (eq (lookup-key pichat-response-view-mode-map (kbd "q"))
                #'pichat-view-quit))
    (should (assq 'shr-h1 face-remapping-alist))
    (should (assq 'shr-code face-remapping-alist))
    (should (assq 'shr-link face-remapping-alist))))

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
                             pichat-response-view-source-markdown)))
            (should (eq (lookup-key pichat-chat-mode-map (kbd "C-c C-h"))
                        #'pichat-chat-view-response)))
        (dolist (buffer (list view chat))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-response-view)
;;; pichat-test-response-view.el ends here
