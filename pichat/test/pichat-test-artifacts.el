;;; pichat-test-artifacts.el --- Settled artifact tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pichat-artifacts)
(require 'pichat-chat-artifacts)
(require 'pichat-artifacts-embark)
(defvar embark-target-finders)
(declare-function embark--act "embark" (action target &optional quit))
(declare-function embark-select "embark" ())
(declare-function embark-collect-direct-action-minor-mode "embark" (&optional arg))

(ert-deftest pichat-artifacts-fences-preserve-body-and-info ()
  (let* ((source "before `inline`\n~~~~js extra\na\n\n~~~~\n```\n```\n~~~oops\n")
         (blocks (cl-remove-if-not (lambda (a) (eq (pichat-artifact-type a) 'code))
                                   (pichat-artifacts-parse source))))
    (should (= 2 (length blocks)))
    (should (equal "a\n\n" (pichat-artifact-payload (car blocks))))
    (should (equal "js" (pichat-artifact-metadata (car blocks))))
    (should (equal "~~~~js extra\na\n\n~~~~\n" (pichat-artifact-source (car blocks))))
    (should (equal "" (pichat-artifact-payload (cadr blocks))))
    (should (eq (pichat-artifacts-at blocks (pichat-artifact-start (car blocks)))
                (car blocks)))))

(ert-deftest pichat-artifacts-nested-and-ambiguous-syntax ()
  (let* ((source "```sh\n[x](file:///bad)\n```\n| h | v |\n| --- | --- |\n| [x](https://ok) | `a|b` |\n\\(x+y\\) $12 and $x$\n")
         (artifacts (pichat-artifacts-parse source))
         (link (cl-find 'link artifacts :key #'pichat-artifact-type)))
    (should (= 1 (cl-count 'link artifacts :key #'pichat-artifact-type)))
    (should (equal "https://ok" (pichat-artifact-payload link)))
    (should (eq 'link (pichat-artifact-type
                       (pichat-artifacts-at artifacts (pichat-artifact-start link)))))
    (should (= 1 (cl-count 'table artifacts :key #'pichat-artifact-type)))
    (should (= 2 (cl-count 'latex artifacts :key #'pichat-artifact-type)))))

(ert-deftest pichat-artifacts-prose-bounds-and-source-rebind ()
  (with-temp-buffer
    (pichat-chat-mode)
    (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
      (insert (propertize "```sh\necho hi\n```\n" 'pichat-prose t
                          'pichat-node-role 'assistant 'pichat-node-key 'a))
      (insert (propertize "```sh\nbad\n```\n" 'pichat-prose t
                          'pichat-node-role 'user 'pichat-node-key 'b))
      (set-marker pichat-chat--canonical-start (point-min))
      (set-marker pichat-chat--canonical-end (point-max)))
    (let ((items (pichat-chat-artifacts-all)))
      (should (= 1 (length items)))
      (should (equal "echo hi\n" (pichat-artifact-payload (caar items))))
      (should (pichat-chat-artifacts-valid-bounds (caar items)))
      (cl-incf pichat-chat--source-generation)
      (should-not (pichat-chat-artifacts-valid-bounds (caar items))))))

(ert-deftest pichat-artifacts-embark-target-has-flat-highlight-bounds ()
  (with-temp-buffer
    (pichat-chat-mode)
    (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
      (insert (propertize "~~~js\nconsole.log(1);\n~~~\n" 'pichat-prose t
                          'pichat-node-role 'assistant 'pichat-node-key 'a))
      (set-marker pichat-chat--canonical-start (point-min))
      (set-marker pichat-chat--canonical-end (point-max)))
    (goto-char (point-min))
    (let* ((found (pichat-artifacts-embark-target))
           ;; Embark takes (cdr (cdr FOUND)) as its :bounds value.
           (bounds (cddr found))
           (overlay (make-overlay (car bounds) (cdr bounds))))
      (unwind-protect
          (progn
            (should (eq (car found) 'pichat-code-block))
            (should (equal bounds (cons (point-min) (point-max))))
            (should (pichat-artifact-p (get-text-property 0 'pichat-artifact
                                                        (cadr found))))
            (should (equal (buffer-substring-no-properties
                            (overlay-start overlay) (overlay-end overlay))
                           "~~~js\nconsole.log(1);\n~~~\n")))
        (delete-overlay overlay)))))

(ert-deftest pichat-artifacts-embark-actions-capture-payload-and-reject-unsafe-url ()
  (let* ((code (car (pichat-artifacts-parse "```python\na\n```\n")))
         (target (propertize (pichat-artifact-source code) 'pichat-artifact code))
         (rpc-called nil))
    (cl-letf (((symbol-function 'pichat-rpc-request)
               (lambda (&rest _) (setq rpc-called t))))
      (pichat-artifacts-embark-copy-body target)
      (should (equal "a\n" (current-kill 0)))
      (pichat-artifacts-embark-copy-source target)
      (should (equal "```python\na\n```\n" (current-kill 0)))
      (should-not rpc-called)))
  (let* ((link (car (pichat-artifacts-parse "[x](javascript:alert)")))
         (target (propertize (pichat-artifact-source link) 'pichat-artifact link))
         (opened nil))
    (cl-letf (((symbol-function 'browse-url) (lambda (&rest _) (setq opened t)))
              ((symbol-function 'browse-url-default-browser)
               (lambda (&rest _) (setq opened t))))
      (should-error (pichat-artifacts-embark-open-link target) :type 'user-error)
      (should-error (pichat-artifacts-embark-open-link-externally target)
                    :type 'user-error)
      (should-not opened))))

(ert-deftest pichat-artifacts-embark-external-link-action-uses-default-browser ()
  (let* ((link (car (pichat-artifacts-parse "[x](https://example.org/path)")))
         (target (propertize (pichat-artifact-source link) 'pichat-artifact link))
         (opened nil))
    (should (eq (lookup-key pichat-link-map (kbd "x"))
                #'pichat-artifacts-embark-open-link-externally))
    (cl-letf (((symbol-function 'browse-url-default-browser)
               (lambda (url &rest _) (setq opened url)))
              ((symbol-function 'browse-url)
               (lambda (&rest _) (ert-fail "Opened configured browser"))))
      (pichat-artifacts-embark-open-link-externally target)
      (should (equal opened "https://example.org/path")))))

(ert-deftest pichat-artifacts-edit-uses-fence-language-mode-or-text-fallback ()
  (let ((real-require (symbol-function 'require))
        buffers)
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest args)
                     (if (eq feature 'markdown-mode) nil
                       (apply real-require feature args))))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (push buffer buffers))))
          (dolist (case '(("elisp" emacs-lisp-mode) ("unknown" text-mode)))
            (let* ((source (format "```%s\n(+ 1 2)\n```\n" (car case)))
                   (artifact (car (pichat-artifacts-parse source)))
                   (target (propertize source 'pichat-artifact artifact)))
              (pichat-artifacts-embark-edit target)
              (with-current-buffer (car buffers)
                (should (eq major-mode (cadr case)))
                (should (equal (buffer-string) "(+ 1 2)\n"))))))
      (mapc #'kill-buffer buffers))))

(ert-deftest pichat-artifacts-edit-consults-markdown-language-mapping ()
  (let* ((source "```ruby\nputs 'hello'\n```\n")
         (artifact (car (pichat-artifacts-parse source)))
         (target (propertize source 'pichat-artifact artifact))
         (real-require (symbol-function 'require))
         preview seen-language)
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest args)
                     (if (eq feature 'markdown-mode) t
                       (apply real-require feature args))))
                  ((symbol-function 'markdown-get-lang-mode)
                   (lambda (language)
                     (setq seen-language language)
                     'emacs-lisp-mode))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq preview buffer))))
          (pichat-artifacts-embark-edit target)
          (should (equal seen-language "ruby"))
          (with-current-buffer preview
            (should (eq major-mode 'emacs-lisp-mode))
            (should (equal (buffer-string) "puts 'hello'\n"))))
      (when (buffer-live-p preview) (kill-buffer preview)))))

(ert-deftest pichat-artifacts-run-preserves-destination-across-rebind-and-other-chat ()
  (let ((chat (generate-new-buffer " *artifact-origin*"))
        (other (generate-new-buffer " *artifact-other*"))
        target session calls)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pichat-chat-mode)
            (setq session (pichat-session-create :transport pichat-transport-local)
                  pichat-chat-session session)
            (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
              (insert (propertize "```sh\necho hi\n```\n" 'pichat-prose t
                                  'pichat-node-role 'assistant 'pichat-node-key 'a))
              (set-marker pichat-chat--canonical-start (point-min))
              (set-marker pichat-chat--canonical-end (point-max)))
            (goto-char (point-min))
            (setq target (cadr (pichat-artifacts-embark-target))))
          (with-current-buffer other
            (pichat-chat-mode)
            (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local)))
          (cl-letf (((symbol-function 'pichat-artifact-runner--script)
                     (lambda (&rest args) (push args calls) chat))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
            (with-current-buffer other (pichat-artifacts-embark-run target))
            (with-current-buffer chat
              (should (equal (caar calls) "echo hi\n"))
              (should (equal (cadar calls) default-directory))
              (should (equal (pichat-session-transport (nth 2 (car calls)))
                             (pichat-session-transport session)))
              (should-not (eq (nth 2 (car calls)) session))
              (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local))
              (cl-incf pichat-chat--source-generation)
              (setq default-directory "/changed/"))
            (let ((before (car calls)))
              (with-current-buffer other
                (pichat-artifacts-embark-run target)
                (pichat-artifacts-embark-copy-body target)
                (should (equal (current-kill 0) "echo hi\n")))
              (should (equal (car calls) before)))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p other) (kill-buffer other)))))

(ert-deftest pichat-artifacts-run-keeps-captured-destination-through-runner-selection ()
  (with-temp-buffer
    (pichat-chat-mode)
    (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local))
    (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
      (insert (propertize "```unknown\nx\n```\n" 'pichat-prose t
                          'pichat-node-role 'assistant 'pichat-node-key 'a))
      (set-marker pichat-chat--canonical-start (point-min))
      (set-marker pichat-chat--canonical-end (point-max)))
    (goto-char (point-min))
    (let ((target (cadr (pichat-artifacts-embark-target))) calls)
      (cl-letf (((symbol-function 'pichat-artifact-runner-select)
                 (lambda (_) (cl-incf pichat-chat--source-generation)
                   (car pichat-artifact-runner-specs)))
                ((symbol-function 'pichat-artifact-runner--script)
                 (lambda (&rest _) (setq calls t) nil))
                ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
        (pichat-artifacts-embark-run target)
        (should calls)))))

(ert-deftest pichat-artifacts-embark-dispatch-preserves-stale-run-destination ()
  (unless (require 'embark nil t) (ert-skip "Embark unavailable"))
  (let ((chat (generate-new-buffer " *artifact-embark-stale*")) target calls)
    (unwind-protect
        (save-window-excursion
          (switch-to-buffer chat)
          (pichat-chat-mode)
          (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local))
          (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
            (insert (propertize "```sh\necho hi\n```\n" 'pichat-prose t
                                'pichat-node-role 'assistant 'pichat-node-key 'a))
            (set-marker pichat-chat--canonical-start (point-min))
            (set-marker pichat-chat--canonical-end (point-max)))
          (goto-char (point-min))
          (setq target (cadr (pichat-artifacts-embark-target)))
          (cl-incf pichat-chat--source-generation)
          (cl-letf (((symbol-function 'pichat-artifact-runner--script)
                     (lambda (code directory session _spec)
                       (setq calls (list code directory session)) nil))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
            (embark--act 'pichat-artifacts-embark-run
                         (list :type 'pichat-code-block :target target))
            (should (equal (car calls) "echo hi\n"))
            (should (equal (cadr calls) default-directory))
            (should-not (eq (nth 2 calls) pichat-chat-session))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-artifacts-embark-collect-export-retain-delayed-destination ()
  (unless (require 'embark nil t) (ert-skip "Embark unavailable"))
  ;; Also runnable unchanged in an isolated interactive terminal Emacs.
  ;; Export for this custom type intentionally uses Embark's collect fallback.
  (dolist (command '(embark-collect embark-export))
    (pichat-test-with-unit-session (session proc)
      (pichat-test-with-temp-dir directory
        (let ((pichat-chat-stop-session-on-kill nil)
              (kill-ring nil)
              (source "```sh\nprintf 'w11:'; pwd\n```\n")
              chat collection result)
          (unwind-protect
              (save-window-excursion
                (delete-other-windows)
                (setq chat (pichat-chat-open session))
                (with-current-buffer chat
                  (setq default-directory directory)
                  (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
                    (goto-char pichat-chat--canonical-start)
                    (insert (propertize source 'pichat-prose t
                                        'pichat-node-role 'assistant 'pichat-node-key 'a))
                    (set-marker pichat-chat--canonical-end (point)))
                  (goto-char pichat-chat--canonical-start)
                  (let ((embark-target-finders '(pichat-artifacts-embark-target)))
                    (call-interactively #'embark-select))
                  (let ((before (buffer-list)))
                    (call-interactively command)
                    (setq collection
                          (cl-find-if (lambda (buffer)
                                        (and (not (memq buffer before))
                                             (with-current-buffer buffer
                                               (derived-mode-p 'embark-collect-mode))))
                                      (buffer-list))))
                  ;; Rebind after collection, before acting on its snapshot.
                  (pichat-chat--reset-for-source "new-source" "/tmp/new-source.jsonl" t)
                  (setq default-directory temporary-file-directory)
                  (pichat-chat--set-input-text "new source draft"))
                (should (buffer-live-p collection))
                (pop-to-buffer collection)
                (goto-char (point-min))
                (embark-collect-direct-action-minor-mode 1)
                (execute-kbd-macro (kbd "c"))
                (should (equal "printf 'w11:'; pwd\n" (current-kill 0)))
                (let ((before (buffer-list)))
                  (execute-kbd-macro (kbd "r"))
                  (setq result
                        (cl-find-if (lambda (buffer)
                                      (and (not (memq buffer before))
                                           (with-current-buffer buffer
                                             (derived-mode-p
                                              'pichat-artifact-runner-result-mode))))
                                    (buffer-list))))
                (should (buffer-live-p result))
                (should (get-buffer-window result))
                (pichat-test-wait-until
                 (lambda ()
                   (with-current-buffer result
                     (not (eq pichat-artifact-runner--status 'running))))
                 5 "delayed collected artifact shell completion")
                (with-current-buffer result
                  (should (equal (concat "w11:" (directory-file-name directory) "\n")
                                 pichat-artifact-runner--captured-output))
                  (should-error (pichat-artifact-result-share) :type 'user-error)
                  (should (buffer-live-p result)))
                (with-current-buffer chat
                  (should (equal "new source draft" (pichat-chat--input-text))))
                (kill-buffer chat)
                (with-current-buffer result
                  (pichat-artifact-result-copy-report)
                  (should (string-search "w11:" (current-kill 0)))
                  (should-error (pichat-artifact-result-share) :type 'user-error)))
            (dolist (buffer (list result collection chat))
              (when (buffer-live-p buffer) (kill-buffer buffer)))))))))

(ert-deftest pichat-artifacts-run-retains-destination-after-origin-death ()
  (let ((chat (generate-new-buffer " *artifact-dead*")) target calls)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pichat-chat-mode)
            (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local))
            (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
              (insert (propertize "```sh\nx\n```\n" 'pichat-prose t
                                  'pichat-node-role 'assistant 'pichat-node-key 'a))
              (set-marker pichat-chat--canonical-start (point-min))
              (set-marker pichat-chat--canonical-end (point-max)))
            (goto-char (point-min))
            (setq target (cadr (pichat-artifacts-embark-target)))
            (setq default-directory "/tmp/"))
          (cl-letf (((symbol-function 'pichat-artifact-runner--script)
                     (lambda (&rest args) (push args calls) nil))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
            (pichat-artifacts-embark-run target)
            (kill-buffer chat)
            (pichat-artifacts-embark-run target)
            (should (= (length calls) 2))
            (should (equal (car calls) (cadr calls)))))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-artifacts-execution-snapshot-retains-ssh-and-path-provenance ()
  (let* ((transport (pichat-transport--create
                     :kind 'ssh :tramp-prefix "/ssh:old-host:" :remote-path '("/old/bin")
                     :mappings '(("/mounted" . "/remote"))))
         (paths (pichat-path-context--create :mappings '(("/mounted" . "/remote"))))
         (session (pichat-session-create :transport transport :path-context paths
                                         :runtime-cwd "/old/project/"
                                         :rpc-command '("wrapper" "pi")))
         (captured (pichat-artifact-runner-capture-session session)))
    ;; Mutate both the runtime's slots and nested configuration in place.
    (setf (pichat-session-runtime-cwd session) "/new/project/"
          (pichat-transport-tramp-prefix transport) "/ssh:new-host:"
          (car (pichat-transport-remote-path transport)) "/new/bin"
          (cdar (pichat-path-context-mappings paths)) "/new-remote"
          (car (pichat-session-rpc-command session)) "new-wrapper")
    (should (equal (pichat-session-runtime-cwd captured) "/old/project/"))
    (should (equal (pichat-transport-tramp-prefix (pichat-session-transport captured))
                   "/ssh:old-host:"))
    (should (equal (pichat-transport-remote-path (pichat-session-transport captured))
                   '("/old/bin")))
    (should (equal (pichat-path-context-mappings (pichat-session-path-context captured))
                   '(("/mounted" . "/remote"))))
    (should (equal (pichat-session-rpc-command captured) '("wrapper" "pi")))
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t)))
      (should (equal (cdr (pichat-artifact-runner--context "/mounted/project/" captured))
                     '("/old/project/" "/ssh:old-host:/old/project/"))))))

(ert-deftest pichat-artifacts-unavailable-origin-host-never-falls-back ()
  (let ((session (pichat-session-create :transport pichat-transport-local)) called)
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) nil))
              ((symbol-function 'pichat-transport-make-process)
               (lambda (&rest _) (setq called t))))
      (should-error (pichat-artifact-runner-start
                     "echo x" (assq 'shell pichat-artifact-runner-specs)
                     "/unavailable-captured-directory/" session)
                    :type 'user-error)
      (should-not called))))

(ert-deftest pichat-artifacts-runners-require-declared-context ()
  (let ((pichat-artifact-runner-specs nil) called)
    (should-error (pichat-artifact-runner-register '(bad :aliases ("bad") :start ignore)))
    (dolist (policy '(nil unknown))
      (should-error
       (pichat-artifact-runner-start
        "x" (list 'bad :context policy :start (lambda (&rest _) (setq called t)))
        "/tmp/" nil)
       :type 'user-error))
    (should-not called)))

(ert-deftest pichat-artifacts-local-independent-policy-survives-stale-and-dead-chat ()
  (let ((chat (generate-new-buffer " *artifact-generic-render*"))
        (view (generate-new-buffer " *artifact-generic-result*"))
        (pichat-artifact-runner-specs (copy-tree pichat-artifact-runner-specs))
        target token seen)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pichat-chat-mode)
            (setq pichat-chat-session
                  (pichat-session-create :transport
                   (pichat-transport--create :kind 'ssh :tramp-prefix "/ssh:origin:")))
            (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
              (insert (propertize "```test-render\ndiagram\n```\n" 'pichat-prose t
                                  'pichat-node-role 'assistant 'pichat-node-key 'a))
              (set-marker pichat-chat--canonical-start (point-min))
              (set-marker pichat-chat--canonical-end (point-max)))
            (goto-char (point-min))
            (setq target (cadr (pichat-artifacts-embark-target))
                  token (pichat-chat--source-token))
            (cl-incf pichat-chat--source-generation))
          (pichat-artifact-runner-register
           '(test-render :context local-independent :aliases ("test-render")
                         :start pichat-test-artifacts--unused))
          (cl-letf (((symbol-function 'pichat-test-artifacts--unused)
                     (lambda (code directory session _spec)
                       (setq seen (list code directory default-directory session))
                       (with-current-buffer view
                         ;; A future local renderer can use the existing result API.
                         (pichat-artifact-result-setup (current-buffer) nil (lambda () "report")))
                       view))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
            (with-temp-buffer (pichat-artifacts-embark-run target))
            (should (equal (car seen) "diagram\n"))
            (should (equal (nth 1 seen) (file-name-as-directory temporary-file-directory)))
            (should (equal (nth 1 seen) (nth 2 seen)))
            (with-current-buffer view
              (should (eq pichat-artifact-result--origin chat))
              (should (equal pichat-artifact-result--token token))
              (should-error (pichat-artifact-result-share) :type 'user-error))
            (kill-buffer chat)
            (pichat-artifacts-embark-run target)
            (with-current-buffer view
              (should-error (pichat-artifact-result-share) :type 'user-error)
              (pichat-artifact-result-copy-report)
              (should (equal (current-kill 0) "report")))))
      (when (buffer-live-p chat) (kill-buffer chat))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest pichat-artifacts-embark-run-focuses-result-after-menu-restore ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((source "```elisp\n(+ 1 2)\n```\n")
           (artifact (car (pichat-artifacts-parse source)))
           (target (propertize source 'pichat-artifact artifact))
           (chat (generate-new-buffer " *pichat-embark-run-focus*"))
           (other (generate-new-buffer " *pichat-embark-other*"))
           (origin-window (selected-window)) view deferred)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (setq pichat-chat-session (pichat-session-create :transport pichat-transport-local))
            (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
              (insert (propertize source 'pichat-prose t
                                  'pichat-node-role 'assistant 'pichat-node-key 'a))
              (set-marker pichat-chat--canonical-start (point-min))
              (set-marker pichat-chat--canonical-end (point-max)))
            (goto-char (point-min))
            (setq target (cadr (pichat-artifacts-embark-target)))
            (let ((display-buffer-overriding-action
                   '((display-buffer-pop-up-window)
                     (inhibit-same-window . t))))
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (_time _repeat fn &rest args)
                           (setq deferred (cons fn args)))))
                (setq view (pichat-artifacts-embark-run target))))
            (should (= 2 (count-windows)))
            (should (eq view (window-buffer (selected-window))))
            ;; Simulate Embark returning focus to the source window.
            (select-window origin-window)
            (apply (car deferred) (cdr deferred))
            (should (eq view (window-buffer (selected-window))))
            ;; A later user window choice must not be overridden.
            (set-window-buffer (split-window origin-window) other)
            (select-window (get-buffer-window other))
            (apply (car deferred) (cdr deferred))
            (should (eq other (window-buffer (selected-window)))))
        (when (buffer-live-p view) (kill-buffer view))
        (dolist (buffer (list chat other))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-artifacts-table-preview-aligns-only-the-private-buffer ()
  (let* ((source "a | wider\n--- | :---\nx | y\n")
         (artifact (car (pichat-artifacts-parse source)))
         (target (propertize source 'pichat-artifact artifact))
         (original (generate-new-buffer " *PiChat table origin*"))
         preview aligned)
    (unwind-protect
        (with-current-buffer original
          (insert source)
          (let ((real-require (symbol-function 'require)))
            (cl-letf (((symbol-function 'require)
                       (lambda (feature &rest args)
                         (if (eq feature 'markdown-mode) t
                           (apply real-require feature args))))
                      ((symbol-function 'markdown-mode)
                       (lambda () (setq major-mode 'markdown-mode)
                         (use-local-map (make-sparse-keymap))))
                      ((symbol-function 'font-lock-ensure) (lambda (&rest _) nil))
                      ((symbol-function 'markdown-table-at-point-p) (lambda () t))
                      ((symbol-function 'markdown-table-align)
                       (lambda ()
                         (setq aligned t)
                         (should (equal (buffer-string)
                                        "|a | wider|\n|--- | :---|\n|x | y|\n"))))
                      ((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _) (setq preview buffer))))
              (pichat-artifacts-embark-preview target)))
          (should aligned)
          (should (equal (buffer-string) source))
          (should (eq (with-current-buffer preview major-mode) 'markdown-mode))
          (should (with-current-buffer preview pichat-artifacts-preview-mode))
          (should (with-current-buffer preview buffer-read-only))
          (should (equal (pichat-artifact-source artifact) source)))
      (when (buffer-live-p preview) (kill-buffer preview))
      (when (buffer-live-p original) (kill-buffer original)))))

(ert-deftest pichat-artifacts-table-preview-keeps-source-without-markdown-mode ()
  (let* ((source "| a | b |\n| --- | --- |\n| x | y |\n")
         (artifact (car (pichat-artifacts-parse source)))
         (target (propertize source 'pichat-artifact artifact))
         preview
         (real-require (symbol-function 'require)))
    (unwind-protect
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &rest args)
                     (if (eq feature 'markdown-mode) nil
                       (apply real-require feature args))))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq preview buffer))))
          (pichat-artifacts-embark-preview target)
          (with-current-buffer preview
            (should (derived-mode-p 'special-mode))
            (should pichat-artifacts-preview-mode)
            (should (equal (buffer-string) source))
            (should buffer-read-only)))
      (when (buffer-live-p preview) (kill-buffer preview)))))

(ert-deftest pichat-artifact-preview-quit-kills-snapshot-and-returns ()
  (save-window-excursion
    (delete-other-windows)
    (let* ((source "$x+y$")
           (artifact (car (pichat-artifacts-parse source)))
           (target (propertize source 'pichat-artifact artifact))
           (origin (generate-new-buffer " *pichat-artifact-origin*"))
           preview)
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (setq preview (pichat-artifacts-embark-preview target))
            (should (pichat-view-presentation preview))
            (with-current-buffer preview
              (should (eq (key-binding (kbd "q")) #'pichat-view-quit))
              (pichat-view-quit))
            (should-not (buffer-live-p preview))
            (should (eq origin (window-buffer (selected-window)))))
        (dolist (buffer (list origin preview))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-artifacts-runner-report-is-compact-and-self-contained ()
  (with-temp-buffer
    (setq-local pichat-artifact-runner--executable "/usr/bin/sh"
                pichat-artifact-runner--status 'exit
                pichat-artifact-runner--exit 0
                pichat-artifact-runner--code "printf hello\n"
                pichat-artifact-runner--captured-output "hello"
                pichat-artifact-runner--share-limit 4000)
    (should (equal (pichat-artifact-runner--report)
                   (concat "Ran with sh — exit 0\n\nExecuted script:\n"
                           "```\nprintf hello\n```\n\nOutput:\n```\nhello\n```")))
    ;; Delimit source containing Markdown fences without closing it early.
    (setq pichat-artifact-runner--code "printf '```'\n")
    (should (string-search "````\nprintf '```'\n````"
                           (pichat-artifact-runner--report)))
    (setq pichat-artifact-runner--session (pichat-session-make)
          pichat-artifact-runner--output-file "/tmp/test-output.txt"
          pichat-artifact-runner--output-bytes 5000)
    (let ((report (pichat-artifact-runner--report)))
      (should (string-search
               "Output excerpt — full output: /tmp/test-output.txt" report))
      (should-not (string-match-p "view\\|Host:\\|Cwd:\\|5000" report)))
    (setq pichat-artifact-runner--discarded-bytes 100)
    (should (string-search "INCOMPLETE output at /tmp/test-output.txt"
                           (pichat-artifact-runner--report)))
    (should (string-search "5000 bytes captured; 100 discarded"
                           (pichat-artifact-runner--report)))))

(ert-deftest pichat-artifacts-runner-selection-and-rejections ()
  (require 'pichat-artifact-runner)
  (should (eq 'javascript (car (pichat-artifact-runner-select "js"))))
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "shell")))
    (should (eq 'shell (car (pichat-artifact-runner-select "unknown")))))
  (should-error (pichat-artifact-runner-run "" "sh" "/ssh:invalid:/tmp/")
                :type 'user-error)
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (should-error (pichat-artifact-runner-run "" "sh" temporary-file-directory)
                  :type 'user-error)))

(ert-deftest pichat-artifacts-runner-argv-cwd-and-script-cleanup-with-stubs ()
  (require 'pichat-artifact-runner)
  (let (argv cwd output script buffer delay)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/stub/sh"))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq argv (plist-get args :command)
                       output (plist-get args :buffer)
                       cwd default-directory
                       script (cadr argv))
                 nil))
              ((symbol-function 'run-at-time)
               (lambda (seconds &rest _) (setq delay seconds) nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (setq buffer (pichat-artifact-runner-run "echo stub\n" "sh"
                                                 temporary-file-directory))
      (unwind-protect
          (progn
            (should (equal (car argv) "/stub/sh"))
            (should (= delay 120))
            (should (equal cwd temporary-file-directory))
            (should (eq output buffer))
            (should (equal (with-temp-buffer
                             (insert-file-contents script)
                             (buffer-string)) "echo stub\n"))
            (with-current-buffer buffer
              (should (string-match-p "Submitted code:" (buffer-string)))
              (should (string-match-p "stdout/stderr:" (buffer-string)))))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (should-not (file-exists-p script)))))

(ert-deftest pichat-artifacts-runner-overflow-does-not-stop-process ()
  (require 'pichat-artifact-runner)
  (with-temp-buffer
    (let ((buffer (current-buffer)) (stops 0) staging)
      (setq-local pichat-artifact-runner--captured-output "")
      (setq-local pichat-artifact-runner--status 'running)
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'delete-process) (lambda (_) (cl-incf stops))))
        (unwind-protect
            (let ((pichat-artifact-runner-output-limit 4))
              (pichat-artifact-runner--filter 'stub "abcd")
              (should-not pichat-artifact-runner--staging)
              (pichat-artifact-runner--filter 'stub "ef")
              (pichat-artifact-runner--filter 'stub "gh")
              (setq staging pichat-artifact-runner--staging)
              (should (= stops 0))
              (should (equal "abcd" pichat-artifact-runner--captured-output))
              (should (string-match-p "\\[Preview limit reached; run continues\\]"
                                      (buffer-string)))
              (with-temp-buffer
                (insert-file-contents staging)
                (should (equal (buffer-string) "abcdefgh")))
              (pichat-artifact-runner--timeout 'stub)
              (should (= stops 1))
              (should (string-match-p "\\[Timed out\\]" (buffer-string))))
          (when staging (delete-file staging)))))))

(ert-deftest pichat-artifacts-runner-share-limit-spill-keeps-growing-preview ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (pichat-artifact-runner-output-limit 8)
          (pichat-artifact-result-share-limit 4)
          stage)
      (setq-local pichat-artifact-runner--captured-output "")
      (setq-local pichat-artifact-runner--status 'running)
      (setq-local pichat-artifact-runner--preview-limit 8)
      (setq-local pichat-artifact-runner--share-limit 4)
      (setq-local pichat-artifact-runner--transport pichat-transport-local)
      (setq-local pichat-artifact-runner--directory temporary-file-directory)
      (setq-local pichat-artifact-runner--executable "sh")
      (setq-local pichat-artifact-runner--code "test")
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer)))
        (unwind-protect
            (progn
              (pichat-artifact-runner--filter 'stub "abcd")
              (should-not pichat-artifact-runner--staging)
              (pichat-artifact-runner--filter 'stub "ef")
              (setq stage pichat-artifact-runner--staging)
              (should stage)
              (should (equal "abcdef" pichat-artifact-runner--captured-output))
              (should-not (string-search "Preview limit reached" (buffer-string)))
              (pichat-artifact-runner--filter 'stub "gh")
              (pichat-artifact-runner--filter 'stub "ijk")
              (should (equal "abcdefgh" pichat-artifact-runner--captured-output))
              (should (= 1 (how-many "Preview limit reached" (point-min) (point-max))))
              (with-temp-buffer
                (insert-file-contents stage)
                (should (equal "abcdefghijk" (buffer-string))))
              ;; A later customization change cannot silently truncate a
              ;; result that was collected under the original share limit.
              (let ((pichat-artifact-result-share-limit 2))
                (should (string-match-p
                         "```\nabcd\n\\[Section truncated for sharing\\]"
                         (pichat-artifact-runner--report)))))
          (when stage (delete-file stage)))))))

(ert-deftest pichat-artifacts-runner-spill-byte-cap-preserves-characters ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (pichat-artifact-runner-output-limit 2)
          (pichat-artifact-runner-output-max-bytes 5)
          file)
      (setq-local pichat-artifact-runner--captured-output "")
      (setq-local pichat-artifact-runner--status 'running)
      (setq-local pichat-artifact-runner--transport pichat-transport-local)
      (setq-local pichat-artifact-runner--directory temporary-file-directory)
      (setq-local pichat-artifact-runner--code "test")
      (setq-local pichat-artifact-runner--executable "sh")
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer)))
        (unwind-protect
            (progn
              (pichat-artifact-runner--filter 'stub "aéédef")
              (setq file pichat-artifact-runner--staging)
              (should (equal "aé" pichat-artifact-runner--captured-output))
              (should (= 5 pichat-artifact-runner--output-bytes))
              (should (= 3 pichat-artifact-runner--discarded-bytes))
              (with-temp-buffer
                (insert-file-contents file)
                (should (equal "aéé" (buffer-string))))
              (pichat-artifact-runner--publish)
              (should (equal file pichat-artifact-runner--output-file))
              (should (string-match-p "INCOMPLETE output at"
                                      (pichat-artifact-runner--report))))
          (when file (delete-file file)))))))

(ert-deftest pichat-artifacts-runner-unmapped-publication-keeps-local-file ()
  (let* ((session (pichat-session-make
                   :path-context (pichat-path-context--create
                                  :transport-id 'local
                                  :mappings '(("/unrelated" . "/container"))
                                  :strict-p t)))
         (file (make-temp-file "pichat-output-" nil ".txt" "abcdef")))
    (unwind-protect
        (with-temp-buffer
          (setq-local pichat-artifact-runner--transport pichat-transport-local)
          (setq-local pichat-artifact-runner--session session)
          (setq-local pichat-artifact-runner--staging file)
          (setq-local pichat-artifact-runner--output-bytes 6)
          (setq-local pichat-artifact-runner--directory temporary-file-directory)
          (setq-local pichat-artifact-runner--executable "sh")
          (setq-local pichat-artifact-runner--code "echo")
          (setq-local pichat-artifact-runner--captured-output "abc")
          (pichat-artifact-runner--publish)
          (should-not pichat-artifact-runner--output-file)
          (should (string-match-p "not mapped" pichat-artifact-runner--capture-error))
          (should (file-exists-p file))
          (should-not (string-match-p (regexp-quote file)
                                      (pichat-artifact-runner--report)))
          (should (string-match-p (regexp-quote file)
                                  (pichat-artifact-runner--output-description))))
      (delete-file file))))

(ert-deftest pichat-artifacts-runner-share-only-publication-failure-keeps-staging ()
  (let ((directory (make-temp-file "pichat-share-failed-" t))
        (pichat-artifact-runner-output-limit 80)
        (pichat-artifact-result-share-limit 40)
        stage)
    (unwind-protect
        (with-temp-buffer
          (let ((buffer (current-buffer))
                (pichat-artifact-runner-output-directory directory))
            (setq-local pichat-artifact-runner--captured-output ""
                        pichat-artifact-runner--share-limit 40
                        pichat-artifact-runner--preview-limit 80
                        pichat-artifact-runner--status 'running
                        pichat-artifact-runner--transport pichat-transport-local
                        pichat-artifact-runner--directory temporary-file-directory
                        pichat-artifact-runner--executable "sh"
                        pichat-artifact-runner--code "test")
            (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer)))
              (pichat-artifact-runner--filter 'stub (make-string 50 ?a)))
            (setq stage pichat-artifact-runner--staging)
            (should stage)
            (should (equal (make-string 50 ?a)
                           pichat-artifact-runner--captured-output))
            (setq-local pichat-artifact-runner--status 'exit
                        pichat-artifact-runner--exit 7)
            (cl-letf (((symbol-function 'copy-file)
                       (lambda (&rest _) (error "copy unavailable"))))
              (pichat-artifact-runner--publish))
            (should (file-exists-p stage))
            (should-not pichat-artifact-runner--output-file)
            (let ((report (pichat-artifact-runner--report)))
              (should (string-match-p "Ran with sh — exit 7" report))
              (should (string-match-p "output publication failed" report))
              (should (string-match-p "```\naaaa" report))
              (should-not (string-match-p (regexp-quote stage) report)))))
      (when (and stage (file-exists-p stage)) (delete-file stage))
      (delete-directory directory t))))

(ert-deftest pichat-artifacts-runner-mapped-output-directory-publishes-native-path ()
  (let* ((directory (make-temp-file "pichat-mapped-output-" t))
         (pichat-artifact-runner-output-directory directory)
         (session (pichat-session-make
                   :path-context (pichat-path-context--create
                                  :transport-id 'local
                                  :mappings (list (cons directory "/runtime"))
                                  :strict-p t)))
         (stage (make-temp-file "pichat-output-" nil ".txt" "abcdef"))
         output)
    (unwind-protect
        (with-temp-buffer
          (setq-local pichat-artifact-runner--transport pichat-transport-local)
          (setq-local pichat-artifact-runner--session session)
          (setq-local pichat-artifact-runner--staging stage)
          (setq-local pichat-artifact-runner--output-bytes 6)
          (pichat-artifact-runner--publish)
          (setq output pichat-artifact-runner--output-file)
          (should (string-prefix-p "/runtime/pichat-output-" output))
          (should-not (file-exists-p stage))
          (should (= #o600 (file-modes (expand-file-name
                                      (file-name-nondirectory output)
                                      directory))))
          (with-temp-buffer
            (insert-file-contents (expand-file-name
                                   (file-name-nondirectory output) directory))
            (should (equal "abcdef" (buffer-string)))))
      (when (file-exists-p stage) (delete-file stage))
      (delete-directory directory t))))

(ert-deftest pichat-artifacts-runner-failed-copy-retains-staging-without-agent-path ()
  (let* ((directory (make-temp-file "pichat-failed-output-" t))
         (pichat-artifact-runner-output-directory directory)
         (stage (make-temp-file "pichat-output-" nil ".txt" "abcdef")))
    (unwind-protect
        (with-temp-buffer
          (setq-local pichat-artifact-runner--transport pichat-transport-local)
          (setq-local pichat-artifact-runner--staging stage)
          (setq-local pichat-artifact-runner--output-bytes 6)
          (setq-local pichat-artifact-runner--directory temporary-file-directory)
          (setq-local pichat-artifact-runner--executable "sh")
          (setq-local pichat-artifact-runner--code "echo")
          (setq-local pichat-artifact-runner--captured-output "abc")
          (cl-letf (((symbol-function 'copy-file)
                     (lambda (&rest _) (error "copy unavailable"))))
            (pichat-artifact-runner--publish))
          (should-not pichat-artifact-runner--output-file)
          (should (string-match-p "copy unavailable"
                                  pichat-artifact-runner--capture-error))
          (should (file-exists-p stage))
          (should-not (string-match-p (regexp-quote stage)
                                      (pichat-artifact-runner--report)))
          (should (null (directory-files directory nil "pichat-output-"))))
      (when (file-exists-p stage) (delete-file stage))
      (delete-directory directory t))))

(ert-deftest pichat-artifacts-runner-ssh-session-selects-runtime-host-and-cwd ()
  (let* ((transport (pichat-transport--create
                     :id 'other :kind 'ssh :label "other"
                     :tramp-prefix "/ssh:other:"
                     :remote-path '(tramp-own-remote-path)))
         (session (pichat-session-make
                   :transport transport :cwd "/mounted/project/"
                   :runtime-cwd "/srv/project/"))
         (origin (generate-new-buffer " *pichat-remote-run-test*"))
         (real-make-temp-file (symbol-function 'make-temp-file))
         buffer prefix spawned args script)
    (unwind-protect
        (cl-letf (((symbol-function 'file-directory-p)
                   (lambda (directory)
                     (should (equal directory "/ssh:other:/srv/project/")) t))
                  ((symbol-function 'executable-find)
                   (lambda (_name &optional remote)
                     (should remote)
                     (should (equal default-directory
                                    "/ssh:other:/srv/project/"))
                     "/ssh:other:/usr/bin/sh"))
                  ((symbol-function 'make-temp-file)
                   (lambda (name &optional dir suffix &rest rest)
                     (if (string-prefix-p "/ssh:other:/tmp/pichat-code-" name)
                         (progn (setq prefix name)
                                (funcall real-make-temp-file
                                         "pichat-test-code-" dir suffix))
                       (apply real-make-temp-file name dir suffix rest))))
                  ((symbol-function 'make-process)
                   (lambda (&rest process-args)
                     (setq spawned default-directory args process-args
                           script (cadr (plist-get args :command)))
                     nil))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'pichat-view-display)
                   (lambda (result &rest _) result)))
          (with-current-buffer origin
            (setq buffer (pichat-artifact-runner-run
                          "pwd\n" "sh" "/mounted/project/" session)))
          (should (equal prefix "/ssh:other:/tmp/pichat-code-"))
          (should (equal spawned "/ssh:other:/srv/project/"))
          (should (plist-get args :file-handler))
          (should (equal (car (plist-get args :command)) "/usr/bin/sh"))
          (should (string-prefix-p "/tmp/" script))
          (with-current-buffer buffer
            (should (string-match-p "Cwd: /srv/project/" (buffer-string)))
            (should (string-match-p "Host: other (ssh)" (buffer-string)))
            (should-not (string-match-p "Host:\\|Cwd:"
                                        (pichat-artifact-runner--report)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest pichat-artifacts-runner-ssh-rejects-mismatched-directory-and-elisp ()
  (let* ((transport (pichat-transport--create
                     :id 'remote :kind 'ssh :label "remote"
                     :tramp-prefix "/ssh:remote:"))
         (session (pichat-session-make
                   :transport transport :runtime-cwd "/tmp/")))
    (should-error (pichat-artifact-runner-run
                   "echo nope" "sh" "/ssh:wrong:/tmp/" session)
                  :type 'user-error)
    (cl-letf (((symbol-function 'file-directory-p) (lambda (_) t)))
      (should-error (pichat-artifact-runner-run
                     "(+ 1 2)" "elisp" "/mounted/" session)
                    :type 'user-error))))

(ert-deftest pichat-artifacts-runner-spill-write-failure-does-not-kill-run ()
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (pichat-artifact-runner-output-limit 2)
          file)
      (setq-local pichat-artifact-runner--captured-output "")
      (setq-local pichat-artifact-runner--status 'running)
      (setq-local pichat-artifact-runner--transport pichat-transport-local)
      (setq-local pichat-artifact-runner--directory temporary-file-directory)
      (setq-local pichat-artifact-runner--code "test")
      (setq-local pichat-artifact-runner--executable "sh")
      (unwind-protect
          (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer))
                    ((symbol-function 'write-region)
                     (lambda (&rest _) (error "disk unavailable"))))
            (pichat-artifact-runner--filter 'stub "abcdef")
            (setq file pichat-artifact-runner--staging)
            (should (eq 'running pichat-artifact-runner--status))
            (should (string-match-p "disk unavailable"
                                    pichat-artifact-runner--capture-error))
            (should-not pichat-artifact-runner--output-file)
            (should-not (string-match-p (regexp-quote file)
                                        (pichat-artifact-runner--report))))
        (when file (delete-file file))))))

(ert-deftest pichat-artifacts-avy-cancellation-preserves-point ()
  (with-temp-buffer
    (pichat-chat-mode)
    (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
      (insert (propertize "```sh\necho ok\n```\n" 'pichat-prose t
                          'pichat-node-role 'assistant 'pichat-node-key 'a))
      (set-marker pichat-chat--canonical-start (point-min))
      (set-marker pichat-chat--canonical-end (point-max)))
    (goto-char (point-max))
    (let ((origin (point)) (acted nil))
      (cl-letf (((symbol-function 'require) (lambda (&rest _) t))
                ((symbol-function 'avy-process) (lambda (&rest _) nil))
                ((symbol-function 'embark-act) (lambda (&rest _) (setq acted t)))
                ((symbol-function 'window-end) (lambda (&rest _) (point-max))))
        (pichat-chat-select-visible-artifact))
      (should (= origin (point)))
      (should-not acted))))
(defvar pichat-artifact-elisp--test-dynamic nil)

(ert-deftest pichat-artifacts-elisp-evaluates-in-current-emacs-private-buffer ()
  (require 'pichat-artifact-elisp)
  (let* ((pichat-artifact-elisp--test-dynamic 21)
         (code "(princ \"hi\")\n(list pichat-artifact-elisp--test-dynamic (buffer-name) default-directory)")
         (result (pichat-artifact-elisp--evaluate
                  code temporary-file-directory nil nil)))
    (should (eq 'ok (pichat-artifact-elisp-result-status result)))
    (should (equal "hi" (pichat-artifact-elisp-result-output result)))
    (should (string-match-p "21.*PiChat Elisp eval.*" (pichat-artifact-elisp-result-value result)))
    (should (string-match-p (regexp-quote temporary-file-directory)
                            (pichat-artifact-elisp-result-value result)))
    (should-not (get-buffer " *PiChat Elisp eval*"))))

(ert-deftest pichat-artifacts-elisp-errors-quit-and-bounded-printing ()
  (let ((pichat-artifact-elisp-output-limit 3))
    (let ((result (pichat-artifact-elisp--evaluate
                   "(princ \"abcd\") (error \"oops\")"
                   temporary-file-directory nil nil)))
      (should (eq 'error (pichat-artifact-elisp-result-status result)))
      (should (string-match-p "oops" (pichat-artifact-elisp-result-error result)))
      (should (equal "abc\n[Output truncated]\n"
                     (pichat-artifact-elisp-result-output result))))
    (let ((result (pichat-artifact-elisp--evaluate
                   "(" temporary-file-directory nil nil)))
      (should (eq 'error (pichat-artifact-elisp-result-status result))))
    (let ((result (pichat-artifact-elisp--evaluate
                   "(signal 'quit nil)" temporary-file-directory nil nil)))
      (should (eq 'quit (pichat-artifact-elisp-result-status result))))
    (let ((result (pichat-artifact-elisp--evaluate
                   "\"abcdef\"" temporary-file-directory nil nil)))
      (should (equal "\"ab\n[Output truncated]\n"
                     (pichat-artifact-elisp-result-value result))))))

(ert-deftest pichat-artifacts-elisp-lexical-evaluation-comments-and-empty ()
  (let ((result (pichat-artifact-elisp--evaluate
                 "; comment\n(let ((x 7)) (funcall (lambda () x))) ; trailing\n"
                 temporary-file-directory nil nil)))
    (should (eq 'ok (pichat-artifact-elisp-result-status result)))
    (should (equal "7" (pichat-artifact-elisp-result-value result))))
  (let ((result (pichat-artifact-elisp--evaluate
                 "; only comment\n" temporary-file-directory nil nil)))
    (should (eq 'ok (pichat-artifact-elisp-result-status result)))
    (should (equal "nil" (pichat-artifact-elisp-result-value result)))))

(ert-deftest pichat-artifacts-elisp-dispatch-and-result-view ()
  (should (eq 'elisp (car (pichat-artifact-runner-select "emacs-lisp"))))
  (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "elisp")))
    (should (eq 'elisp (car (pichat-artifact-runner-select "unknown")))))
  (let (view)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-view-display)
                   (lambda (buffer &rest _) (setq view buffer))))
          (pichat-artifact-runner-run "(+ 1 2)" "elisp" temporary-file-directory)
          (with-current-buffer view
            (should (eq major-mode 'pichat-artifact-elisp-result-mode))
            (should (string-prefix-p "Cwd: " (buffer-string)))
            (should (string-search "Code:\n(+ 1 2)" (buffer-string)))
            (should (string-match-p "Output:\n(none)" (buffer-string)))
            (should (string-match-p "Last value: 3" (buffer-string)))
            (should-not (string-match-p "Synchronous: no timeout" (buffer-string)))
            (should-not (string-match-p "Emacs Lisp in this Emacs" (buffer-string)))
            (should (eq (key-binding (kbd "s")) #'pichat-artifact-result-share))
            (should (eq (key-binding (kbd "q")) #'pichat-view-quit))))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest pichat-artifacts-elisp-errors-appear-in-view-and-agent-report ()
  (let (view)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-view-display)
                   (lambda (buffer &rest _) (setq view buffer))))
          (pichat-artifact-runner-run
           "(princ \"before\") (void-function)" "elisp" temporary-file-directory)
          (with-current-buffer view
            (should (string-match-p "Output:\nbefore" (buffer-string)))
            (should (string-match-p "Error: void-function:" (buffer-string)))
            (should-not (string-match-p "Last value:" (buffer-string)))
            (let ((report (pichat-artifact-elisp--report
                           pichat-artifact-elisp--result)))
              (should (string-match-p "Status: error" report))
              (should (string-match-p "Printed output:\nbefore" report))
              (should (string-match-p "Error: void-function:" report)))))
      (when (buffer-live-p view) (kill-buffer view))))
  (let ((result (pichat-artifact-elisp--evaluate
                 "(" temporary-file-directory nil nil)))
    (should (eq (pichat-artifact-elisp-result-status result) 'error))
    (should (string-match-p "end-of-file:"
                            (pichat-artifact-elisp-result-error result))))
  (let ((result (pichat-artifact-elisp--evaluate
                 "(princ \"before\") (signal 'quit nil)"
                 temporary-file-directory nil nil)))
    (should (equal "before" (pichat-artifact-elisp-result-output result)))
    (should (string-match-p "Status: quit" (pichat-artifact-elisp--report result)))
    (should (string-match-p "Quit: Evaluation quit"
                            (pichat-artifact-elisp--report result)))))

(ert-deftest pichat-artifacts-elisp-share-preserves-draft-and-closes-view ()
  (save-window-excursion
    (delete-other-windows)
    (let ((chat (generate-new-buffer " *pichat-elisp-share-chat*"))
          (pichat-artifact-elisp-share-limit 8)
          result-view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "existing draft  ")
            (setq-local pichat-chat--pending-attachments '(pending-image))
            (let ((display-buffer-overriding-action
                   '((display-buffer-pop-up-window)
                     (inhibit-same-window . t))))
              (setq result-view
                    (pichat-artifact-runner-run
                     "(princ \"hello world\") (+ 1 2)"
                     "elisp" temporary-file-directory)))
            (should (= 2 (count-windows)))
            (with-current-buffer result-view
              (should (string-match-p "Section truncated for sharing"
                                      (pichat-artifact-elisp--report
                                       pichat-artifact-elisp--result)))
              (pichat-artifact-elisp-share))
            (should-not (buffer-live-p result-view))
            (should (= 1 (count-windows)))
            (should (eq chat (window-buffer (selected-window))))
            (with-current-buffer chat
              (should (string-prefix-p "existing draft  \n\n"
                                       (buffer-substring-no-properties
                                        pichat-chat--input-start (point-max))))
              (should (string-match-p "Emacs Lisp run in my current Emacs"
                                      (buffer-string)))
              (should (equal pichat-chat--pending-attachments '(pending-image)))))
        (when (buffer-live-p result-view) (kill-buffer result-view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-elisp-view-quit-kills-only-result ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-elisp-view-origin*")) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (setq view (pichat-artifact-runner-run
                        "(+ 1 2)" "elisp" temporary-file-directory))
            (should (pichat-view-presentation view))
            (with-current-buffer view (pichat-view-quit))
            (should-not (buffer-live-p view))
            (should (eq (window-buffer (selected-window)) chat)))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-elisp-share-closes-owned-split-not-other-windows ()
  (save-window-excursion
    (delete-other-windows)
    (let ((chat (generate-new-buffer " *pichat-elisp-split-chat*"))
          (other (generate-new-buffer " *pichat-elisp-other*")) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "")
            (let ((display-buffer-overriding-action
                   '((display-buffer-pop-up-window)
                     (inhibit-same-window . t))))
              (setq view (pichat-artifact-runner-run
                          "42" "elisp" temporary-file-directory)))
            (should (= 2 (count-windows)))
            (set-window-buffer (split-window (get-buffer-window chat)) other)
            (should (= 3 (count-windows)))
            (with-current-buffer view (pichat-artifact-elisp-share))
            (should-not (buffer-live-p view))
            (should (= 2 (count-windows)))
            (should (get-buffer-window other))
            (should (eq (window-buffer (selected-window)) chat)))
        (dolist (buffer (list chat other view))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-artifacts-elisp-run-keeps-chat-context-and-does-not-send ()
  (let ((chat (generate-new-buffer " *pichat-elisp-origin*")) view (rpc-called nil))
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pichat-chat-mode)
            (pichat-chat--set-input-text "")
            (setq-local pichat-chat--pending-attachments '(pending-image))
            (cl-letf (((symbol-function 'pichat-view-display)
                       (lambda (buffer &rest _) (setq view buffer)))
                      ((symbol-function 'pichat-rpc-request)
                       (lambda (&rest _) (setq rpc-called t))))
              ;; Source may change while user code runs: the view is readable,
              ;; but its share action may not attach to the new conversation.
              (let ((code "(with-current-buffer (get-buffer \" *pichat-elisp-origin*\") (setq pichat-chat--source-generation (1+ pichat-chat--source-generation)))"))
                (pichat-artifact-runner-run code "elisp" temporary-file-directory))))
          (with-current-buffer view
            (should-error (pichat-artifact-elisp-share) :type 'user-error)
            (pichat-artifact-elisp-copy-report))
          (with-current-buffer chat
            (should (equal pichat-chat--pending-attachments '(pending-image)))
            (should (equal (pichat-chat--input-text) "")))
          (should-not rpc-called)
          (kill-buffer chat)
          (with-current-buffer view
            (should-error (pichat-artifact-elisp-share) :type 'user-error)
            (pichat-artifact-elisp-copy-report)))
      (when (buffer-live-p view) (kill-buffer view))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-artifacts-elisp-share-stale-keeps-view-and-copy ()
  (save-window-excursion
    (delete-other-windows)
    (let ((chat (generate-new-buffer " *pichat-elisp-stale-chat*")) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "original")
            (setq view (pichat-artifact-runner-run
                        "42" "elisp" temporary-file-directory))
            (with-current-buffer chat (cl-incf pichat-chat--source-generation))
            (with-current-buffer view
              (should-error (pichat-artifact-elisp-share) :type 'user-error)
              (should (buffer-live-p view))
              (should (eq (window-buffer (selected-window)) view))
              (pichat-artifact-elisp-copy-report)
              (should (string-match-p "Last value: 42" (current-kill 0)))
              (pichat-view-quit))
            (with-current-buffer chat
              (should (equal (pichat-chat--input-text) "original"))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-subprocess-quit-stops-and-cleans-up ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-run-origin*")) view process file)
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (let ((display-buffer-overriding-action
                   '((display-buffer-pop-up-window)
                     (inhibit-same-window . t))))
              (setq view (pichat-artifact-runner-run
                          "exec sleep 10\n" "sh" temporary-file-directory)))
            (should (= 2 (count-windows)))
            (with-current-buffer view
              (should (eq major-mode 'pichat-artifact-runner-result-mode))
              (should (eq (key-binding (kbd "q")) #'pichat-view-quit))
              (setq process pichat-artifact-runner--process
                    file pichat-artifact-runner--file)
              (should (process-live-p process))
              (should (file-exists-p file))
              (pichat-view-quit))
            (should-not (buffer-live-p view))
            (should-not (process-live-p process))
            (should-not (file-exists-p file))
            (should (= 1 (count-windows)))
            (should (eq origin (window-buffer (selected-window)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (process-live-p process) (delete-process process))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(defun pichat-test-artifacts--wait-for-run (buffer)
  "Wait briefly for BUFFER's subprocess to settle."
  (let ((deadline (+ (float-time) 3)))
    (while (and (buffer-live-p buffer)
                (with-current-buffer buffer
                  (eq pichat-artifact-runner--status 'running))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (should-not (with-current-buffer buffer
                  (eq pichat-artifact-runner--status 'running)))))

(ert-deftest pichat-artifacts-subprocess-timeout-publishes-partial-output ()
  (let ((pichat-artifact-runner-output-limit 3) view output script)
    (unwind-protect
        (progn
          (setq view (pichat-artifact-runner-run
                      "printf 'abcdefgh'; exec sleep 10\n"
                      "sh" temporary-file-directory))
          (with-current-buffer view (setq script pichat-artifact-runner--file))
          (let ((deadline (+ (float-time) 3)))
            (while (and (< (float-time) deadline)
                        (with-current-buffer view
                          (null pichat-artifact-runner--staging)))
              (accept-process-output nil 0.02)))
          (with-current-buffer view
            (should pichat-artifact-runner--staging)
            (pichat-artifact-runner--timeout pichat-artifact-runner--process))
          (pichat-test-artifacts--wait-for-run view)
          (with-current-buffer view
            (setq output pichat-artifact-runner--output-file)
            (should (eq 'timeout pichat-artifact-runner--status))
            (should (string-match-p "Ran with sh — timed out"
                                    (pichat-artifact-runner--report)))
            (should (string-match-p (regexp-quote output)
                                    (pichat-artifact-runner--report))))
          (should-not (file-exists-p script))
          (with-temp-buffer
            (insert-file-contents output)
            (should (equal "abcdefgh" (buffer-string)))))
      (when (buffer-live-p view) (kill-buffer view))
      (when output (delete-file output)))))

(ert-deftest pichat-artifact-result-path-availability-preserves-copy-not-share ()
  (pichat-test-with-unit-session (session proc)
    (setf (pichat-session-id session) "same"
          (pichat-session-session-file session) nil)
    (pichat-test-with-chat-buffer (chat session)
      (let ((view (generate-new-buffer " *pichat-path-result*")))
        (unwind-protect
            (progn
              (pichat-chat--set-input-text "original")
              (with-current-buffer view
                (pichat-artifact-result-mode)
                (pichat-artifact-result-setup
                 chat (pichat-artifact-result-source-token chat)
                 (lambda () "captured report")))
              (setf (pichat-session-session-file session) "/sessions/same.jsonl")
              (with-current-buffer chat
                (pichat-chat--refresh-source-identity session))
              (with-current-buffer view
                (should-error (pichat-artifact-result-share) :type 'user-error)
                (pichat-artifact-result-copy-report)
                (should (equal "captured report" (current-kill 0))))
              (with-current-buffer chat
                (should (equal "original" (pichat-chat--input-text)))))
          (when (buffer-live-p view) (kill-buffer view)))))))

(ert-deftest pichat-artifacts-subprocess-spill-share-retains-readable-file ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-spill-share-chat*"))
        (pichat-artifact-runner-output-limit 3) view output)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (pichat-chat-mode)
            (pichat-chat--set-input-text "draft")
            (setq view (pichat-artifact-runner-run
                        "printf 'abcdefgh'\n" "sh" temporary-file-directory)))
          (pichat-test-artifacts--wait-for-run view)
          (with-current-buffer view
            (setq output pichat-artifact-runner--output-file)
            (should (string-match-p (regexp-quote output)
                                    (pichat-artifact-runner--report)))
            (let ((pichat-artifact-runner--status 'publishing))
              (should-error (pichat-artifact-result-share) :type 'user-error))
            (pichat-artifact-result-share))
          (should-not (buffer-live-p view))
          (should (file-exists-p output))
          (with-current-buffer chat
            (should (string-match-p (regexp-quote output)
                                    (pichat-chat--input-text)))
            (should (string-match-p "```\nabc"
                                    (pichat-chat--input-text)))))
      (when (buffer-live-p view) (kill-buffer view))
      (when (buffer-live-p chat) (kill-buffer chat))
      (when output (delete-file output))))))

(ert-deftest pichat-artifacts-subprocess-spill-exact-boundaries-and-snapshot ()
  (dolist (count '(3 4 5 8 9))
    (let ((pichat-artifact-runner-output-limit 8)
          (pichat-artifact-result-share-limit 4)
          view output)
      (unwind-protect
          (progn
            (setq view (pichat-artifact-runner-run
                        (format "printf '%%0%dd' 0\n" count)
                        "sh" temporary-file-directory))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (setq output pichat-artifact-runner--output-file)
              (should (eq (not (null output)) (> count 4)))
              (should (eq pichat-artifact-runner--preview-truncated (> count 8)))
              (should (= (length pichat-artifact-runner--captured-output)
                         (min 8 count)))
              (when output
                (with-temp-buffer
                  (insert-file-contents output)
                  (should (equal (buffer-string) (make-string count ?0)))))))
        (when (buffer-live-p view) (kill-buffer view))
        (when output (delete-file output)))))
  (let ((pichat-artifact-runner-output-limit 8)
        (pichat-artifact-result-share-limit 10)
        view)
    (unwind-protect
        (progn
          (setq view (pichat-artifact-runner-run
                      "printf 000000\n" "sh" temporary-file-directory))
          (pichat-test-artifacts--wait-for-run view)
          (with-current-buffer view
            (should-not pichat-artifact-runner--output-file)
            (let ((pichat-artifact-result-share-limit 2))
              (should (string-match-p "```\n000000\n```\\'"
                                      (pichat-artifact-runner--report))))))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest pichat-artifacts-subprocess-share-truncation-retains-full-file ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-share-truncation-chat*"))
          (pichat-artifact-runner-output-limit 65536)
          (pichat-artifact-result-share-limit 4000)
          view output)
      (unwind-protect
          (progn
            (with-current-buffer chat
              (pichat-chat-mode)
              (pichat-chat--set-input-text "draft")
              (setq view (pichat-artifact-runner-run
                          "printf '%010000d' 0; exit 7\n"
                          "sh" temporary-file-directory)))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (setq output pichat-artifact-runner--output-file)
              (should (and output (file-exists-p output)))
              (should (= #o600 (file-modes output)))
              (should (eq 'exit pichat-artifact-runner--status))
              (should (= 7 pichat-artifact-runner--exit))
              (should (= 10000 (length pichat-artifact-runner--captured-output)))
              (should-not pichat-artifact-runner--preview-truncated)
              (should-not (string-search "Preview limit reached" (buffer-string)))
              (let ((report (pichat-artifact-runner--report)))
                (should (string-match-p "Ran with sh — exit 7" report))
                (should (string-match-p (regexp-quote output) report))
                (should (string-match-p
                         "```\n0000" report))
                (should (string-match-p "Section truncated for sharing" report)))
              (pichat-artifact-result-share))
            (should-not (buffer-live-p view))
            (with-current-buffer chat
              (should (string-match-p (regexp-quote output)
                                      (pichat-chat--input-text)))
              (should (string-match-p "```\n0000"
                                      (pichat-chat--input-text))))
            (with-temp-buffer
              (insert-file-contents output)
              (should (equal (buffer-string) (make-string 10000 ?0)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))
        (when output (delete-file output))))))

(ert-deftest pichat-artifacts-python-and-javascript-use-shared-result-actions ()
  (dolist (case '(("py" "python3" ".py") ("js" "node" ".js")))
    (let (view script)
      (unwind-protect
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (name) (concat "/stub/" name)))
                    ((symbol-function 'make-process)
                     (lambda (&rest args)
                       (setq script (cadr (plist-get args :command))) nil))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'pichat-view-display)
                     (lambda (buffer &rest _) (setq view buffer))))
            (pichat-artifact-runner-run "test code" (car case)
                                        temporary-file-directory)
            (should (string-suffix-p (nth 2 case) script))
            (with-current-buffer view
              (should (eq major-mode 'pichat-artifact-runner-result-mode))
              (should (eq (key-binding (kbd "s")) #'pichat-artifact-result-share))
              (should (eq (key-binding (kbd "w"))
                          #'pichat-artifact-result-copy-report))
              (should (string-match-p (regexp-quote (nth 1 case))
                                      (pichat-artifact-runner--report)))))
        (when (buffer-live-p view) (kill-buffer view))
        (should-not (and script (file-exists-p script)))))))

(ert-deftest pichat-artifacts-subprocess-shares-finished-result-with-draft ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-subprocess-share*")) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "draft")
            (setq-local pichat-chat--pending-attachments '(image))
            (setq view (pichat-artifact-runner-run
                        "printf 'hello\\n'; exit 3\n" "sh" temporary-file-directory))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (should (eq (key-binding (kbd "s")) #'pichat-artifact-result-share))
              (let ((report (pichat-artifact-runner--report)))
                (should (string-match-p "Ran with sh — exit 3" report))
                (should (string-match-p "Output:\n```\nhello" report)))
              (pichat-artifact-result-share))
            (should-not (buffer-live-p view))
            (with-current-buffer chat
              (should (string-prefix-p "draft\n\nRan with sh — "
                                       (buffer-substring-no-properties
                                        pichat-chat--input-start (point-max))))
              (should (string-match-p "Ran with sh — exit 3" (buffer-string)))
              (should (equal pichat-chat--pending-attachments '(image)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-subprocess-running-copy-and-timeout-status ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-subprocess-active*")) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "original")
            (setq view (pichat-artifact-runner-run
                        "printf partial; exec sleep 10\n" "sh"
                        temporary-file-directory))
            (with-current-buffer view
              (should-error (pichat-artifact-result-share) :type 'user-error)
              (should (buffer-live-p view))
              (should (string-match-p "Ran with sh — running (partial output)"
                                      (pichat-artifact-runner--report)))
              (pichat-artifact-result-copy-report)
              (should (string-match-p "Ran with sh — running" (current-kill 0)))
              (pichat-artifact-runner--timeout pichat-artifact-runner--process))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (should (string-match-p "Ran with sh — timed out"
                                      (pichat-artifact-runner--report)))
              (pichat-artifact-result-share))
            (with-current-buffer chat
              (should (string-prefix-p "original\n\nRan with sh — "
                                       (buffer-substring-no-properties
                                        pichat-chat--input-start (point-max))))
              (should (string-match-p "Ran with sh — timed out" (buffer-string)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-subprocess-output-limit-and-stale-source ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-subprocess-stale*"))
          (pichat-artifact-runner-output-limit 4) view published)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "keep")
            (setq view (pichat-artifact-runner-run
                        "printf abcdefghijkl\n" "sh" temporary-file-directory))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (setq published pichat-artifact-runner--output-file)
              (let ((report (pichat-artifact-runner--report)))
                (should (string-match-p "Ran with sh — exit 0" report))
                (should (string-match-p "```\nabcd\n```\\'" report))
                (should (string-match-p (regexp-quote published) report)))
              (with-temp-buffer
                (insert-file-contents published)
                (should (equal (buffer-string) "abcdefghijkl"))))
            (with-current-buffer chat (cl-incf pichat-chat--source-generation))
            (with-current-buffer view
              (should-error (pichat-artifact-result-share) :type 'user-error)
              (should (buffer-live-p view))
              (pichat-artifact-result-copy-report)
              (should (string-match-p "Ran with sh — exit 0" (current-kill 0))))
            (with-current-buffer chat
              (should (equal "keep" (pichat-chat--input-text)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when published (should (file-exists-p published))
              (delete-file published))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(provide 'pichat-test-artifacts)
;;; pichat-test-artifacts.el ends here
