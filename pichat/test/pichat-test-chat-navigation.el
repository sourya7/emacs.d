;;; pichat-test-chat-navigation.el --- PiChat navigation tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused logical navigation, compose lifecycle, and canonical export tests.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-chat-navigation)

(defvar-local pichat-test-chat-navigation--source-token nil)

(defun pichat-test-chat-navigation--node (key role text)
  "Return a minimal message node with KEY, ROLE, and TEXT."
  (pichat-transcript-node-create
   :kind 'message :key key :role role
   :content (list (pichat-transcript-content-create
                   :kind 'prose :index 0 :text text))))

(ert-deftest pichat-navigation-user-turns-use-logical-role-not-faces ()
  (with-temp-buffer
    (insert "header\n")
    (let ((first (point)))
      (insert (propertize "first user" 'pichat-node-key "u1"
                          'pichat-node-role 'user
                          'font-lock-face 'error))
      (insert (propertize "\nassistant\n" 'pichat-node-key "a1"
                          'pichat-node-role 'assistant
                          'font-lock-face 'pichat-user-block-face))
      (let ((second (point)))
        (insert (propertize "second user" 'pichat-node-key "u2"
                            'pichat-node-role 'user))
        (insert (propertize "\nassistant two\n" 'pichat-node-key "a2"
                            'pichat-node-role 'assistant))
        (let ((third (point)))
          (insert (propertize "third user" 'pichat-node-key "u3"
                              'pichat-node-role 'user))
          (should
           (= second
              (pichat-chat-navigation-turn-position
               (point-min) (point-max) (+ first 2) 1)))
          (should
           (= second
              (pichat-chat-navigation-turn-position
               (point-min) (point-max) (+ third 2) -1)))
          (should
           (= first
              (pichat-chat-navigation-turn-position
               (point-min) (point-max) (point-min) 1)))
          (should-not
           (pichat-chat-navigation-turn-position
            (point-min) (point-max) (+ third 2) 1)))))))

(ert-deftest pichat-render-projects-stable-node-role-properties ()
  (let* ((transcript
          (pichat-transcript-create
           :nodes
           (list (pichat-test-chat-navigation--node "user-key" 'user "hello")
                 (pichat-test-chat-navigation--node
                  "assistant-key" 'assistant "reply"))))
         (text
          (pichat-render-fragment-propertized-string
           (pichat-render-canonical transcript))))
    (let ((user-position
           (text-property-any 0 (length text) 'pichat-node-role 'user text))
          (assistant-position
           (text-property-any 0 (length text)
                              'pichat-node-role 'assistant text)))
      (should (equal "user-key"
                     (get-text-property user-position 'pichat-node-key text)))
      (should (equal "assistant-key"
                     (get-text-property assistant-position
                                        'pichat-node-key text))))))

(ert-deftest pichat-chat-user-turn-commands-follow-projected-logical-properties ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          chat)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session))
            (with-current-buffer chat
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-test-chat-navigation--node "u1" 'user "one")
                        (pichat-test-chat-navigation--node
                         "a1" 'assistant "reply")
                        (pichat-test-chat-navigation--node "u2" 'user "two"))))
                     (context (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context)
                (goto-char
                 (text-property-any
                  (marker-position pichat-chat--canonical-start)
                  (marker-position pichat-chat--canonical-end)
                  'pichat-node-role 'user))
                ;; Deliberately replace presentation faces; navigation remains
                ;; tied to logical role properties.
                (pichat-chat--with-buffer-edit
                  (put-text-property
                   (marker-position pichat-chat--canonical-start)
                   (marker-position pichat-chat--canonical-end)
                   'font-lock-face 'error))
                (pichat-chat-next-user-turn)
                (should (equal "u2"
                               (get-text-property (point) 'pichat-node-key)))
                (pichat-chat-previous-user-turn)
                (should (equal "u1"
                               (get-text-property (point) 'pichat-node-key))))))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-navigation-active-target-has-explicit-priority ()
  (with-temp-buffer
    (insert "01234567890123456789")
    (let ((blocks (make-hash-table :test #'equal)))
      (puthash "old"
               (list :status "running" :start (copy-marker 3)) blocks)
      (puthash "new"
               (list :status "running" :start (copy-marker 8)) blocks)
      (should
       (equal '(:kind tool :position 8)
              (pichat-chat-navigation-active-target
               blocks 2 12 14 18 19 t)))
      (setf (plist-get (gethash "old" blocks) :status) "done"
            (plist-get (gethash "new" blocks) :status) "error")
      (should
       (equal '(:kind extension-request :position 12)
              (pichat-chat-navigation-active-target
               blocks 2 12 14 18 19 t)))
      (should
       (equal '(:kind live-tail :position 14)
              (pichat-chat-navigation-active-target
               blocks 0 12 14 18 19 t)))
      (should
       (equal '(:kind prompt :position 19)
              (pichat-chat-navigation-active-target
               blocks 0 12 18 18 19 t)))
      (should-not
       (pichat-chat-navigation-active-target
        blocks 0 12 18 18 19 nil)))))

(ert-deftest pichat-chat-jump-active-observes-pending-extension-request ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (setf (pichat-session-state session) 'running)
              (setq pichat-chat--pending-ui-count 1)
              (goto-char (point-min))
              (pichat-chat-jump-to-active-item)
              (should (= (point)
                         (marker-position pichat-chat--prompt-start)))
              ;; A running tool outranks the pending request.
              (let ((marker (copy-marker
                             (marker-position pichat-chat--canonical-start))))
                (puthash "active"
                         (list :status "running" :start marker)
                         pichat-chat--tool-blocks)
                (pichat-chat-jump-to-active-item)
                (should (= (point) (marker-position marker))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-compose-reuses-unsaved-editor-without-refreshing ()
  (let ((target (generate-new-buffer " *pichat-compose-target*"))
        compose)
    (unwind-protect
        (progn
          (setq compose
                (pichat-chat-navigation-open-compose
                 target #'ignore "initial prompt" 3))
          (with-current-buffer compose
            (should (equal "initial prompt" (buffer-string)))
            (should (= 3 (- (point) (point-min))))
            (erase-buffer)
            (insert "unsaved compose edit"))
          (should
           (eq compose
               (pichat-chat-navigation-open-compose
                target #'ignore "new prompt must not replace it" 0)))
          (with-current-buffer compose
            (should (equal "unsaved compose edit" (buffer-string)))))
      (when (buffer-live-p compose) (kill-buffer compose))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest pichat-compose-apply-trims-replaces-transfers-point-and-closes ()
  (let ((target (generate-new-buffer " *pichat-compose-apply-target*"))
        compose received received-point)
    (unwind-protect
        (progn
          (setq compose
                (pichat-chat-navigation-open-compose
                 target
                 (lambda (text point-offset)
                   (setq received text received-point point-offset)
                   (erase-buffer)
                   (insert text)
                   (goto-char (+ (point-min) point-offset))
                   (point))
                 "old" 0))
          (with-current-buffer compose
            (erase-buffer)
            (insert "  replacement text  ")
            (goto-char (+ (point-min) 7))
            (pichat-chat-compose-apply))
          (should-not (buffer-live-p compose))
          (should (equal "replacement text" received))
          (should (= 5 received-point))
          (with-current-buffer target
            (should (= (point) (+ (point-min) 5)))))
      (when (buffer-live-p compose) (kill-buffer compose))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest pichat-compose-target-death-retains-text-and-does-not-reassign ()
  (let ((target (generate-new-buffer " *pichat-dead-target*"))
        compose)
    (setq compose
          (pichat-chat-navigation-open-compose target #'ignore "unsent text" 0))
    (kill-buffer target)
    (unwind-protect
        (with-current-buffer compose
          (should-error (pichat-chat-compose-apply) :type 'user-error)
          (should (equal "unsent text" (buffer-string))))
      (when (buffer-live-p compose) (kill-buffer compose)))))

(ert-deftest pichat-compose-replacement-failure-preserves-text ()
  (let ((target (generate-new-buffer " *pichat-failing-target*"))
        compose)
    (unwind-protect
        (progn
          (setq compose
                (pichat-chat-navigation-open-compose
                 target (lambda (_text _point) (error "replacement failed"))
                 "preserve on failure" 4))
          (with-current-buffer compose
            (should-error (pichat-chat-compose-apply) :type 'error)
            (should (equal "preserve on failure" (buffer-string))))
          (should (buffer-live-p compose)))
      (when (buffer-live-p compose) (kill-buffer compose))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest pichat-compose-source-rebind-preserves-old-text-separately ()
  (let ((target (generate-new-buffer " *pichat-rebound-target*"))
        old-compose new-compose received)
    (unwind-protect
        (progn
          (with-current-buffer target
            (setq-local pichat-test-chat-navigation--source-token 'old))
          (setq old-compose
                (pichat-chat-navigation-open-compose
                 target (lambda (text _point) (setq received text) (point))
                 "old source text" 0 'old
                 (lambda (token)
                   (eq token pichat-test-chat-navigation--source-token))))
          (with-current-buffer target
            (setq pichat-test-chat-navigation--source-token 'new))
          (with-current-buffer old-compose
            (should-error (pichat-chat-compose-apply) :type 'user-error)
            (should (equal "old source text" (buffer-string))))
          (setq new-compose
                (pichat-chat-navigation-open-compose
                 target (lambda (text _point) (setq received text) (point))
                 "new source text" 0 'new
                 (lambda (token)
                   (eq token pichat-test-chat-navigation--source-token))))
          (should-not (eq old-compose new-compose))
          (should (buffer-live-p old-compose))
          (should (equal "old source text"
                         (with-current-buffer old-compose (buffer-string))))
          (should (equal "new source text"
                         (with-current-buffer new-compose (buffer-string))))
          (should-not received))
      (when (buffer-live-p old-compose) (kill-buffer old-compose))
      (when (buffer-live-p new-compose) (kill-buffer new-compose))
      (when (buffer-live-p target) (kill-buffer target)))))

(ert-deftest pichat-chat-compose-replaces-input-without-submitting ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          chat compose attachment)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session)
                  attachment (list :id "keep-attachment"))
            (with-current-buffer chat
              (pichat-chat--set-input-text "  existing input  ")
              (setq pichat-chat--pending-attachments (list attachment))
              (goto-char (+ (marker-position pichat-chat--input-start) 7))
              (pichat-chat-open-compose-buffer))
            (setq compose (window-buffer (selected-window)))
            (with-current-buffer compose
              (should (derived-mode-p 'pichat-chat-compose-mode))
              (should (equal "existing input" (buffer-string)))
              (should (= 5 (- (point) (point-min))))
              (erase-buffer)
              (insert "  replacement prompt  ")
              (goto-char (+ (point-min) 13)))
            ;; Compose wins over prompt edits made while its editor is live.
            (with-current-buffer chat
              (pichat-chat--set-input-text "concurrent prompt edit"))
            (with-current-buffer compose
              (pichat-chat-compose-apply))
            (should-not (buffer-live-p compose))
            (should (eq (current-buffer) chat))
            (with-current-buffer chat
              (should (equal "replacement prompt" (pichat-chat--input-text)))
              (should (= 11 (- (point)
                               (marker-position pichat-chat--input-start))))
              (should (equal (list attachment)
                             pichat-chat--pending-attachments))
              (should-not
               (cl-loop for pending being the hash-values of
                        (pichat-session-pending-responses session)
                        thereis (equal "prompt"
                                       (pichat-rpc--pending-command pending))))
              ;; Opening again uses the latest normal prompt and, when point is
              ;; outside the editor, starts at the end.
              (goto-char (point-min))
              (pichat-chat-open-compose-buffer))
            (setq compose (window-buffer (selected-window)))
            (with-current-buffer compose
              (should (equal "replacement prompt" (buffer-string)))
              (should (= (point) (point-max)))
              (pichat-chat-compose-cancel)))
        (when (buffer-live-p compose) (kill-buffer compose))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-chat-compose-empty-apply-clears-input ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          chat compose)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session))
            (with-current-buffer chat
              (pichat-chat--set-input-text "clear me")
              (pichat-chat-open-compose-buffer))
            (setq compose (window-buffer (selected-window)))
            (with-current-buffer compose
              (erase-buffer)
              (insert " \n\t ")
              (pichat-chat-compose-apply))
            (should-not (buffer-live-p compose))
            (with-current-buffer chat
              (should (string-empty-p (pichat-chat--input-text)))))
        (when (buffer-live-p compose) (kill-buffer compose))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-chat-compose-cancel-discards-editor-only ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          chat compose attachment)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session)
                  attachment (list :id "keep-on-cancel"))
            (with-current-buffer chat
              (pichat-chat--set-input-text "unchanged prompt")
              (setq pichat-chat--pending-attachments (list attachment))
              (pichat-chat-open-compose-buffer))
            (setq compose (window-buffer (selected-window)))
            (with-current-buffer compose
              (erase-buffer)
              (insert "discard this")
              (pichat-chat-compose-cancel))
            (should-not (buffer-live-p compose))
            (should (eq (current-buffer) chat))
            (with-current-buffer chat
              (should (equal "unchanged prompt" (pichat-chat--input-text)))
              (should (equal (list attachment)
                             pichat-chat--pending-attachments))))
        (when (buffer-live-p compose) (kill-buffer compose))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-response-selection-prefers-assistant-at-point-then-latest ()
  (let* ((first (pichat-test-chat-navigation--node
                 "assistant-one" 'assistant "first"))
         (latest (pichat-test-chat-navigation--node
                  "assistant-two" 'assistant "latest"))
         (transcript
          (pichat-transcript-create
           :nodes (list first
                        (pichat-test-chat-navigation--node
                         "user-between" 'user "question")
                        latest)))
         (at-point
          (pichat-chat-navigation-select-response
           transcript "assistant-one" '(7 "session-a")))
         (fallback
          (pichat-chat-navigation-select-response
           transcript "user-between" '(7 "session-a"))))
    (should (equal "assistant-one"
                   (pichat-chat-navigation-response-node-key at-point)))
    (should (equal "first"
                   (pichat-chat-navigation-response-markdown at-point)))
    (should (equal "assistant-two"
                   (pichat-chat-navigation-response-node-key fallback)))
    (should (equal "latest"
                   (pichat-chat-navigation-response-markdown fallback)))
    (should-not
     (pichat-chat-navigation-select-response
      (pichat-transcript-create
       :nodes (list (pichat-test-chat-navigation--node
                     "only-user" 'user "question")))
      nil '(7 "session-a")))))

(ert-deftest pichat-response-extraction-preserves-only-exact-ordered-prose ()
  (let* ((first "# Heading\n\n| Name | URL |\n|---|---|\n")
         (second "| Pi | [site](https://example.test) |\n\n```elisp\n(message \"ok\")\n```\n")
         (tool
          (pichat-transcript-content-create
           :kind 'tool :index 2 :tool-call-id "response-tool" :name "bash"
           :arguments '(:command "secret-command") :status 'done
           :output (list (pichat-transcript-content-create
                          :kind 'prose :index 0 :text "secret output"))))
         (node
          (pichat-transcript-node-create
           :kind 'message :key "mixed-assistant" :role 'assistant
           :stop-reason "error" :error-message "display annotation"
           :content
           (list
            (pichat-transcript-content-create
             :kind 'prose :index 0 :text first)
            (pichat-transcript-content-create
             :kind 'thinking :index 1 :text "secret thinking")
            tool
            (pichat-transcript-content-create
             :kind 'prose :index 3 :text second)
            (pichat-transcript-content-create
             :kind 'image :index 4 :text "[display image]"))))
         (response
          (pichat-chat-navigation-select-response
           (pichat-transcript-create :nodes (list node))
           "mixed-assistant" '(11 "source"))))
    (should (equal (list first second)
                   (pichat-chat-navigation-response-prose-segments response)))
    (should (equal (concat first second)
                   (pichat-chat-navigation-response-markdown response)))
    (dolist (excluded '("secret thinking" "secret-command" "secret output"
                        "display annotation" "[display image]"))
      (should-not
       (string-match-p
        (regexp-quote excluded)
        (pichat-chat-navigation-response-markdown response))))))

(ert-deftest pichat-response-selection-represents-empty-prose-exactly ()
  (let* ((tool-only
          (pichat-transcript-node-create
           :kind 'message :key "tool-only" :role 'assistant
           :content
           (list
            (pichat-transcript-content-create
             :kind 'thinking :index 0 :text "thinking")
            (pichat-transcript-content-create
             :kind 'tool :index 1 :tool-call-id "only-tool" :name "read"
             :status 'done :output nil))))
         (response
          (pichat-chat-navigation-select-response
           (pichat-transcript-create :nodes (list tool-only))
           nil 'source-token)))
    (should (equal "tool-only"
                   (pichat-chat-navigation-response-node-key response)))
    (should-not (pichat-chat-navigation-response-prose-segments response))
    (should (equal ""
                   (pichat-chat-navigation-response-markdown response)))))

(ert-deftest pichat-response-identity-detects-source-rebind-and-removed-node ()
  (let* ((node (pichat-test-chat-navigation--node
                "stable-assistant" 'assistant "settled"))
         (transcript (pichat-transcript-create :nodes (list node)))
         (token '(3 "session-a" "/tmp/a.jsonl"))
         (response
          (pichat-chat-navigation-select-response transcript nil token)))
    ;; The captured token is independent of later mutation by the caller.
    (setcar token 99)
    (should
     (pichat-chat-navigation-response-current-p
      response transcript '(3 "session-a" "/tmp/a.jsonl")))
    (should-not
     (pichat-chat-navigation-response-current-p
      response transcript '(4 "session-b" "/tmp/b.jsonl")))
    (should-not
     (pichat-chat-navigation-response-current-p
      response
      (pichat-transcript-create
       :nodes (list (pichat-test-chat-navigation--node
                     "replacement" 'assistant "new source")))
      '(3 "session-a" "/tmp/a.jsonl")))))

(ert-deftest pichat-canonical-markdown-export-ignores-display-and-truncation ()
  (let* ((full-output (concat "0123456789\n~~~ embedded fence\n" "tail"))
         (tool
          (pichat-transcript-content-create
           :kind 'tool :index 1 :tool-call-id "export-tool"
           :name "bash" :arguments '(:command "printf full") :status 'done
           :output
           (list (pichat-transcript-content-create
                  :kind 'prose :index 0 :text full-output))))
         (transcript
          (pichat-transcript-create
           :nodes
           (list
            (pichat-test-chat-navigation--node
             "export-user" 'user "# exact user Markdown")
            (pichat-transcript-node-create
             :kind 'message :key "export-assistant" :role 'assistant
             :content
             (list
              (pichat-transcript-content-create
               :kind 'prose :index 0 :text "[exact link](https://example.test)")
              tool)))))
         (markdown
          (pichat-chat-navigation-transcript-markdown transcript)))
    (should (string-match-p (regexp-quote "## User\n\n# exact user Markdown")
                            markdown))
    (should (string-match-p
             (regexp-quote "[exact link](https://example.test)") markdown))
    (should (string-match-p (regexp-quote full-output) markdown))
    (should (string-match-p (regexp-quote "\"command\":\"printf full\"")
                            markdown))
    (should-not (string-match-p "chars omitted\|Command (non-interactive)"
                                markdown))
    ;; A longer fence is selected instead of corrupting canonical output.
    (should (string-match-p "~~~~text\n0123456789" markdown))))

(ert-deftest pichat-chat-export-command-uses-canonical-model-not-buffer-text ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          chat export)
      (unwind-protect
          (progn
            (setq chat (pichat-chat-open session))
            (with-current-buffer chat
              (setq pichat-chat--canonical-transcript
                    (pichat-transcript-create
                     :nodes
                     (list (pichat-test-chat-navigation--node
                            "model-user" 'user "authoritative full text"))))
              (pichat-chat--with-buffer-edit
                (goto-char (marker-position pichat-chat--canonical-start))
                (insert "misleading truncated display"))
              (cl-letf (((symbol-function 'pop-to-buffer)
                         (lambda (buffer &rest _) (setq export buffer))))
                (pichat-chat-export-transcript-to-markdown)))
            (with-current-buffer export
              (should (string-match-p "authoritative full text"
                                      (buffer-string)))
              (should-not (string-match-p "misleading truncated display"
                                          (buffer-string)))))
        (when (buffer-live-p export) (kill-buffer export))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(provide 'pichat-test-chat-navigation)
;;; pichat-test-chat-navigation.el ends here
