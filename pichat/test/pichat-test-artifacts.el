;;; pichat-test-artifacts.el --- Settled artifact tests -*- lexical-binding: t; -*-
;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'pichat-artifacts)
(require 'pichat-chat-artifacts)
(require 'pichat-artifacts-embark)

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
  (let (argv cwd output script buffer)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/stub/sh"))
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq argv (plist-get args :command)
                       output (plist-get args :buffer)
                       cwd default-directory
                       script (cadr argv))
                 nil))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'pop-to-buffer) (lambda (&rest _) nil)))
      (setq buffer (pichat-artifact-runner-run "echo stub\n" "sh"
                                                 temporary-file-directory))
      (unwind-protect
          (progn
            (should (equal (car argv) "/stub/sh"))
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

(ert-deftest pichat-artifacts-runner-output-limit-and-timeout-with-stubs ()
  (require 'pichat-artifact-runner)
  (with-temp-buffer
    (let ((buffer (current-buffer)) (stops 0))
      (setq-local pichat-artifact-runner--output-start (point-min))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buffer))
                ((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'delete-process) (lambda (_) (cl-incf stops))))
        (let ((pichat-artifact-runner-output-limit 4))
          (pichat-artifact-runner--filter 'stub "abcdef")
          (should (string-match-p "abcd\n\\[Output limit reached\\]" (buffer-string)))
          (should (= stops 1)))
        (pichat-artifact-runner--timeout 'stub)
        (should (= stops 2))
        (should (string-match-p "\\[Timed out\\]" (buffer-string)))))))

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
                (should (string-match-p "Status: exit 3" report))
                (should (string-match-p "stdout/stderr:\nhello" report)))
              (pichat-artifact-result-share))
            (should-not (buffer-live-p view))
            (with-current-buffer chat
              (should (string-prefix-p "draft\n\nCode run: "
                                       (buffer-substring-no-properties
                                        pichat-chat--input-start (point-max))))
              (should (string-match-p "Status: exit 3" (buffer-string)))
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
              (should (string-match-p "Status: running (partial output)"
                                      (pichat-artifact-runner--report)))
              (pichat-artifact-result-copy-report)
              (should (string-match-p "Status: running" (current-kill 0)))
              (pichat-artifact-runner--timeout pichat-artifact-runner--process))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (should (string-match-p "Status: timed out"
                                      (pichat-artifact-runner--report)))
              (pichat-artifact-result-share))
            (with-current-buffer chat
              (should (string-prefix-p "original\n\nCode run: "
                                       (buffer-substring-no-properties
                                        pichat-chat--input-start (point-max))))
              (should (string-match-p "Status: timed out" (buffer-string)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(ert-deftest pichat-artifacts-subprocess-output-limit-and-stale-source ()
  (save-window-excursion
    (let ((chat (generate-new-buffer " *pichat-subprocess-stale*"))
          (pichat-artifact-runner-output-limit 4) view)
      (unwind-protect
          (progn
            (switch-to-buffer chat)
            (pichat-chat-mode)
            (pichat-chat--set-input-text "keep")
            (setq view (pichat-artifact-runner-run
                        "printf abcdefghijkl\n" "sh" temporary-file-directory))
            (pichat-test-artifacts--wait-for-run view)
            (with-current-buffer view
              (let ((report (pichat-artifact-runner--report)))
                (should (string-match-p "Status: output limit reached" report))
                (should (string-match-p "stdout/stderr:\nabcd\\'" report))))
            (with-current-buffer chat (cl-incf pichat-chat--source-generation))
            (with-current-buffer view
              (should-error (pichat-artifact-result-share) :type 'user-error)
              (should (buffer-live-p view))
              (pichat-artifact-result-copy-report)
              (should (string-match-p "Status: output limit reached"
                                      (current-kill 0))))
            (with-current-buffer chat
              (should (equal "keep" (pichat-chat--input-text)))))
        (when (buffer-live-p view) (kill-buffer view))
        (when (buffer-live-p chat) (kill-buffer chat))))))

(provide 'pichat-test-artifacts)
;;; pichat-test-artifacts.el ends here
