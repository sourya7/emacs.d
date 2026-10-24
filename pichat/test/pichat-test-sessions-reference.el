;;; pichat-test-sessions-reference.el --- Pichat Test Sessions Reference -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

(defvar bufferlo-mode)

;;; Session, scope, reference, and UI fixture tests

(ert-deftest pichat-chat-new-session-cancellation-does-not-refresh-or-claim-success ()
  (let ((session (pichat-session-make))
        callback
        status
        (state-requests 0))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
              ((symbol-function 'pichat-rpc-new-session)
               (lambda (_session cb &optional _parent)
                 (setq callback cb)))
              ((symbol-function 'pichat-chat--set-status)
               (lambda (&rest args) (setq status args)))
              ((symbol-function 'pichat-rpc-get-state)
               (lambda (&rest _args) (cl-incf state-requests))))
      (with-temp-buffer
        (setq-local pichat-chat-session session)
        (pichat-chat-new-session)
        (funcall callback '(:success t :data (:cancelled t)) session)))
    (should-not status)
    (should (= 0 state-requests))))

(ert-deftest pichat-sessions-switch-files-cancellation-does-not-refresh-or-claim-success ()
  (let* ((session (pichat-session-make))
         (file "/sanitized/session.jsonl")
         switch-callback
         (state-requests 0)
         messages)
    (cl-letf (((symbol-function 'pichat-consult-available-p)
               (lambda () nil))
              ((symbol-function 'pichat-sessions--root-dir)
               (lambda () "/sanitized/"))
              ((symbol-function 'pichat-sessions--files)
               (lambda () (list file)))
              ((symbol-function 'pichat-sessions--file-choices)
               (lambda (&rest _args) (list (cons "saved" file))))
              ((symbol-function 'pichat-sessions--file-summary)
               (lambda (_file) '(:cwd "/sanitized/project")))
              ((symbol-function 'completing-read)
               (lambda (&rest _args) "saved"))
              ((symbol-function 'pichat-sessions--active-session)
               (lambda () session))
              ((symbol-function 'pichat-rpc-switch-session)
               (lambda (_session _file cb &optional _error)
                 (setq switch-callback cb)))
              ((symbol-function 'pichat-rpc-get-state)
               (lambda (&rest _args) (cl-incf state-requests)))
              ((symbol-function 'message)
               (lambda (&rest args) (push args messages))))
      (pichat-sessions-switch-files)
      (funcall switch-callback '(:success t :data (:cancelled t)) session))
    (should (= 0 state-requests))
    (should (cl-some (lambda (args)
                       (string-match-p "cancelled" (car args)))
                     messages))
    (should-not (cl-some (lambda (args)
                           (string-match-p "switched session" (car args)))
                         messages))))

(ert-deftest pichat-saved-session-switch-preserves-direct-host-paths ()
  (let ((session (pichat-session-make :cwd "/host/current/"))
        (pichat-path-mappings nil)
        sent-file)
    (cl-letf (((symbol-function 'pichat-sessions--active-session)
               (lambda () session))
              ((symbol-function 'pichat-rpc-switch-session)
               (lambda (_session file _callback &optional _error)
                 (setq sent-file file))))
      (pichat-sessions-switch-file "/host/sessions/session.jsonl")
      (should (equal "/host/sessions/session.jsonl" sent-file)))))

(ert-deftest pichat-saved-session-switch-translates-file-and-working-directory ()
  (let* ((pichat-path-mappings
          '(("/host/mirror" . "/runtime/sessions")
            ("/host/project" . "/workspace")))
         (session (pichat-session-make :cwd "/host/current/"))
         (buffer (generate-new-buffer " *pichat mapped session test*"))
         sent-file
         ready-session)
    (setf (pichat-session-buffer session) buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-sessions--active-session)
                   (lambda () session))
                  ((symbol-function 'pichat-rpc-switch-session)
                   (lambda (_session file callback &optional _error)
                     (setq sent-file file)
                     (funcall callback '(:success t :data nil) session)))
                  ((symbol-function 'pichat-rpc-get-state)
                   (lambda (s callback &optional _error)
                     (funcall callback '(:success t :data nil) s)))
                  ((symbol-function 'pichat--scope-for-directory)
                   (lambda (cwd &rest _args) (list nil cwd "mapped")))
                  ((symbol-function 'pichat--unregister-session) #'ignore)
                  ((symbol-function 'pichat-chat--rename-buffer-maybe) #'ignore)
                  ((symbol-function 'pichat-chat-repaint) #'ignore)
                  ((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (pichat-sessions-switch-file
           "/host/mirror/project/session.jsonl" "/workspace"
           (lambda (s) (setq ready-session s)))
          (should (equal "/runtime/sessions/project/session.jsonl" sent-file))
          (should (equal "/host/project/" (pichat-session-cwd session)))
          (with-current-buffer buffer
            (should (equal "/host/project/" default-directory)))
          (should (eq session ready-session)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest pichat-saved-session-switch-rejects-uncovered-host-file ()
  (let ((pichat-path-mappings '(("/host/mirror" . "/runtime/sessions")))
        active-called
        rpc-called)
    (cl-letf (((symbol-function 'pichat-sessions--active-session)
               (lambda () (setq active-called t)))
              ((symbol-function 'pichat-rpc-switch-session)
               (lambda (&rest _args) (setq rpc-called t))))
      (should-error
       (pichat-sessions-switch-file "/other/session.jsonl")
       :type 'user-error))
    (should-not active-called)
    (should-not rpc-called)))

(ert-deftest pichat-saved-session-switch-keeps-cwd-when-runtime-cwd-is-unmapped ()
  (let* ((pichat-path-mappings '(("/host/mirror" . "/runtime/sessions")))
         (session (pichat-session-make :cwd "/host/current/"))
         messages)
    (cl-letf (((symbol-function 'pichat-sessions--active-session)
               (lambda () session))
              ((symbol-function 'pichat-rpc-switch-session)
               (lambda (_session _file callback &optional _error)
                 (funcall callback '(:success t :data nil) session)))
              ((symbol-function 'pichat-rpc-get-state)
               (lambda (s callback &optional _error)
                 (funcall callback '(:success t :data nil) s)))
              ((symbol-function 'pichat-chat-open) (lambda (&rest _args) nil))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) messages))))
      (pichat-sessions-switch-file
       "/host/mirror/project/session.jsonl" "/unmapped/project"))
    (should (equal "/host/current/" (pichat-session-cwd session)))
    (should (cl-some (lambda (text)
                       (string-match-p "working directory is not mapped" text))
                     messages))))

(ert-deftest pichat-strict-path-resolution-uses-longest-prefix ()
  (let ((pichat-path-mappings
         '(("/host/mirror" . "/runtime/sessions")
           ("/host/mirror/project" . "/runtime/special"))))
    (should
     (equal "/runtime/special/session.jsonl"
            (plist-get
             (pichat-path-resolve-to-runtime
              "/host/mirror/project/session.jsonl")
             :path)))
    (should
     (equal "/host/mirror/project/session.jsonl"
            (plist-get
             (pichat-path-resolve-from-runtime
              "/runtime/special/session.jsonl")
             :path)))))

(ert-deftest pichat-session-history-has-no-row-level-switch-binding ()
  (should-not (lookup-key pichat-sessions-mode-map (kbd "s"))))

(ert-deftest pichat-session-history-compatibility-switch-never-guesses-a-path ()
  (let (prompted sent)
    (cl-letf (((symbol-function 'pichat-sessions--node-at-point)
               (lambda () '(:sessionFile "/must/not/use.jsonl")))
              ((symbol-function 'read-file-name)
               (lambda (&rest _args) (setq prompted t)))
              ((symbol-function 'pichat-rpc-switch-session)
               (lambda (&rest args) (setq sent args))))
      (let ((error
             (with-suppressed-warnings
                 ((obsolete pichat-sessions-switch-at-point))
               (should-error (pichat-sessions-switch-at-point)
                             :type 'user-error))))
        (should (equal (cadr error)
                       "History entries are not session files; use pichat-sessions-browse-files"))))
    (should-not prompted)
    (should-not sent)))

(ert-deftest pichat-chat-switches-saved-sessions-while-independent-browser-remains-invokable ()
  (should (commandp #'pichat-sessions-browse-files))
  (should (commandp #'pichat-sessions-switch-files))
  (should (eq (lookup-key pichat-chat-mode-map (kbd "C-c C-b"))
              #'pichat-sessions-switch-files))
  (should-not (eq (lookup-key pichat-chat-mode-map (kbd "C-c C-p"))
                  #'pichat-sessions-browse-files)))

(ert-deftest pichat-current-session-tree-opens-as-session-history ()
  (pichat-test-with-unit-session (session)
    (let (callback buffer)
      (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                 (lambda (_session cb &optional _error)
                   (setq callback cb)))
                ((symbol-function 'pop-to-buffer)
                 (lambda (target &rest _args) (setq buffer target))))
        (pichat-sessions-list session)
        (funcall callback '(:data (:tree nil :leafId nil)) session))
      (unwind-protect
          (progn
            (should (equal "*PiChat Session History*" (buffer-name buffer)))
            (with-current-buffer buffer
              (should (derived-mode-p 'pichat-sessions-mode))
              (should (equal "PiChat-History" mode-name))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-history-can-focus-requested-search-entry ()
  (pichat-test-with-unit-session (session)
    (let (callback focused buffer)
      (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                 (lambda (_session cb &optional _error) (setq callback cb)))
                ((symbol-function 'pichat-sessions--goto-id)
                 (lambda (id) (setq focused id)))
                ((symbol-function 'pop-to-buffer)
                 (lambda (target &rest _args) (setq buffer target))))
        (pichat-sessions-list session "entry-1")
        (funcall callback '(:data (:tree nil :leafId nil)) session))
      (unwind-protect
          (progn
            (should (equal "entry-1" focused))
            (should (buffer-live-p buffer)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-sessions-fork-and-clone-cancellation-do-not-refresh ()
  (let ((session (pichat-session-make))
        callbacks
        (state-requests 0)
        messages)
    (cl-letf (((symbol-function 'pichat-sessions--entry-id-at-point)
               (lambda () "user-1"))
              ((symbol-function 'pichat-sessions--entry-for-id)
               (lambda (_id) '(:type "message" :message (:role "user"))))
              ((symbol-function 'pichat-rpc-fork)
               (lambda (_session _id cb &optional _error)
                 (push cb callbacks)))
              ((symbol-function 'pichat-rpc-clone)
               (lambda (_session cb &optional _error)
                 (push cb callbacks)))
              ((symbol-function 'pichat-rpc-get-state)
               (lambda (&rest _args) (cl-incf state-requests)))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
              ((symbol-function 'message)
               (lambda (&rest args) (push args messages))))
      (with-temp-buffer
        (setq-local pichat-sessions-session session)
        (setq-local pichat-sessions--source-token
                    (pichat-sessions--session-source-token session))
        (pichat-sessions-fork-at-point)
        (pichat-sessions-clone-current))
      (dolist (callback callbacks)
        (funcall callback '(:success t :data (:cancelled t)) session)))
    (should (= 0 state-requests))
    (should (= 2 (cl-count-if (lambda (args)
                                (string-match-p "cancelled" (car args)))
                              messages)))
    (should-not (cl-some (lambda (args)
                           (string-match-p "requested" (car args)))
                         messages))))

(ert-deftest pichat-session-scope-reuses-live-project-and-global-sessions ()
  (pichat-test-with-clean-state
    (let ((project-session (pichat-session-make :cwd "/tmp/project/"))
          (global-session (pichat-session-make :cwd "/tmp/global/"))
          (starts 0))
      (cl-letf (((symbol-function 'pichat--project-root)
                 (lambda (&optional directory)
                   (and (string-prefix-p "/tmp/project" (or directory ""))
                        "/tmp/project/")))
                ((symbol-function 'pichat-session-alive-p) (lambda (_session) t))
                ((symbol-function 'pichat-start-session)
                 (lambda (cwd &optional _scope _options)
                   (cl-incf starts)
                   (if (string= cwd "/tmp/project/") project-session global-session))))
        (let ((first (pichat--session-for-scope "/tmp/project/file.el"))
              (second (pichat--session-for-scope "/tmp/project/other.el"))
              (global (pichat--session-for-scope "/tmp/outside/" t)))
          (should (eq first project-session))
          (should (eq second project-session))
          (should (eq global global-session))
          (should (= 2 starts)))))))

(ert-deftest pichat-structured-new-profile-preserves-independent-runtime-behavior ()
  (pichat-test-with-clean-state
    (let ((registered (pichat-session-make :cwd "/tmp/project/"))
          (started (pichat-session-make :cwd "/tmp/project/"))
          started-args opened state-requested)
      (puthash "project:/tmp/project/" registered pichat--sessions-by-scope)
      (cl-letf (((symbol-function 'pichat--scope-for-directory)
                 (lambda (&rest _args)
                   '("project:/tmp/project/" "/tmp/project/" "project@test")))
                ((symbol-function 'pichat-start-session)
                 (lambda (&rest args)
                   (setq started-args args)
                   started))
                ((symbol-function 'pichat-chat-open)
                 (lambda (session) (setq opened session)))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (session _callback &optional _error)
                   (setq state-requested session))))
        (should (eq started
                    (pichat--open-launch-profile
                     '(:scope current :reuse new
                       :persistence persistent :model default)
                     "/tmp/project/")))
        (should (equal "/tmp/project/" (car started-args)))
        (should (eq started opened))
        (should (eq started state-requested))
        (should (eq registered
                    (gethash "project:/tmp/project/" pichat--sessions-by-scope)))))))

(ert-deftest pichat-manual-sessions-have-distinct-provisional-buffer-names ()
  (let ((first (pichat-session-make :scope-label "manual:project#1"))
        (second (pichat-session-make :scope-label "manual:project#2")))
    (should-not (equal (pichat-chat-buffer-name first)
                       (pichat-chat-buffer-name second)))
    (should (string-match-p "manual:project#1"
                            (pichat-chat-buffer-name first)))
    (should (string-match-p "manual:project#2"
                            (pichat-chat-buffer-name second)))))

(ert-deftest pichat-chat-transcript-is-protected-while-current-input-is-editable ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (goto-char (point-min))
              (should-error (insert "corrupt transcript"))
              (goto-char (point-max))
              (insert "editable prompt")
              (should (equal "editable prompt" (pichat-chat--input-text)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-reference-targets-current-bufferlo-tab-not-last-runtime ()
  (let* ((here (generate-new-buffer " *reference here*"))
         (elsewhere (generate-new-buffer " *reference elsewhere*"))
         (pichat-current-session nil)
         (bufferlo-mode t))
    (unwind-protect
        (progn
          (dolist (buffer (list here elsewhere))
            (with-current-buffer buffer
              (setq-local major-mode 'pichat-chat-mode)))
          (let ((pichat-current-session
                 (pichat-session-make :buffer elsewhere)))
            (cl-letf (((symbol-function 'bufferlo-local-buffer-p)
                       (lambda (buffer &rest _args) (eq buffer here)))
                      ((symbol-function 'completing-read)
                       (lambda (&rest _args) (ert-fail "Should not prompt"))))
              (with-temp-buffer
                (should (eq here (pichat-reference--target-buffer)))))))
      (kill-buffer here)
      (kill-buffer elsewhere))))

(ert-deftest pichat-reference-asks-when-tab-has-no-chat-or-multiple-chats ()
  (let* ((first (generate-new-buffer " *reference first*"))
         (second (generate-new-buffer " *reference second*"))
         (bufferlo-mode t)
         choices)
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (with-current-buffer buffer
              (setq-local major-mode 'pichat-chat-mode)))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt names &rest _args)
                       (push names choices)
                       (buffer-name second)))
                    ((symbol-function 'bufferlo-local-buffer-p)
                     (lambda (&rest _args) nil)))
            (with-temp-buffer
              (should (eq second (pichat-reference--target-buffer)))
              (should (= 2 (length (car choices))))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt names &rest _args)
                       (should (= 2 (length names)))
                       (buffer-name second)))
                    ((symbol-function 'bufferlo-local-buffer-p)
                     (lambda (&rest _args) t)))
            (with-temp-buffer
              (should (eq second (pichat-reference--target-buffer)))
              (should (eq second (pichat-reference--target-buffer t))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest pichat-reference-does-not-auto-target-sole-chat-in-another-tab ()
  (let ((chat (generate-new-buffer " *reference other tab*"))
        (bufferlo-mode t)
        prompted)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (setq-local major-mode 'pichat-chat-mode))
          (cl-letf (((symbol-function 'bufferlo-local-buffer-p)
                     (lambda (&rest _args) nil))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args)
                       (setq prompted t)
                       (buffer-name chat))))
            (with-temp-buffer
              (should (eq chat (pichat-reference--target-buffer)))
              (should prompted))))
      (kill-buffer chat))))

(ert-deftest pichat-reference-falls-back-to-project-scope-without-bufferlo ()
  (let* ((first (generate-new-buffer " *reference project*"))
         (second (generate-new-buffer " *reference other*"))
         (bufferlo-mode nil))
    (unwind-protect
        (progn
          (dolist (pair (list (cons first "project") (cons second "other")))
            (with-current-buffer (car pair)
              (setq-local major-mode 'pichat-chat-mode)
              (setq-local pichat-chat-session
                          (pichat-session-make
                           :owner-scope-key (cdr pair)))))
          (cl-letf (((symbol-function 'pichat--project-root)
                     (lambda (&rest _args) "/project/"))
                    ((symbol-function 'pichat--scope-for-directory)
                     (lambda (&rest _args) '("project" "/project/" "project")))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _args) (ert-fail "Should not prompt"))))
            (with-temp-buffer
              (should (eq first (pichat-reference--target-buffer))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest pichat-reference-asks-between-independent-project-chats ()
  (let* ((first (generate-new-buffer " *reference project one*"))
         (second (generate-new-buffer " *reference project two*"))
         (bufferlo-mode nil))
    (unwind-protect
        (progn
          (dolist (buffer (list first second))
            (with-current-buffer buffer
              (setq-local major-mode 'pichat-chat-mode)
              (setq-local pichat-chat-session
                          (pichat-session-make :owner-scope-key "project"))))
          (cl-letf (((symbol-function 'pichat--project-root)
                     (lambda (&rest _args) "/project/"))
                    ((symbol-function 'pichat--scope-for-directory)
                     (lambda (&rest _args) '("project" "/project/" "project")))
                    ((symbol-function 'completing-read)
                     (lambda (_prompt names &rest _args)
                       (should (= 2 (length names)))
                       (buffer-name second))))
            (with-temp-buffer
              (should (eq second (pichat-reference--target-buffer))))))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest pichat-reference-chat-without-region-asks-for-file-not-chat-snapshot ()
  (pichat-test-with-temp-dir dir
    (let ((file (expand-file-name "source.el" dir))
          (snapshot nil))
      (with-temp-file file (insert "source"))
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _args) file))
                ((symbol-function 'pichat-reference--buffer-temp-reference)
                 (lambda () (setq snapshot t))))
        (with-temp-buffer
          (setq-local major-mode 'pichat-chat-mode)
          (should (string-match-p "source.el" (pichat-reference--dwim-text)))
          (should-not snapshot))))))

(ert-deftest pichat-reference-file-region-uses-runtime-path-and-lines ()
  (pichat-test-with-temp-dir dir
    (let* ((file (expand-file-name "sample.el" dir))
           (pichat-path-mappings (list (cons dir "/workspace/"))))
      (with-temp-buffer
        (insert "first\nsecond value\nthird\n")
        (write-region (point-min) (point-max) file nil 'silent)
        (set-visited-file-name file t t)
        (goto-char (point-min))
        (forward-line 1)
        (set-mark (line-end-position))
        (setq mark-active t)
        (let ((text (pichat-reference--region)))
          (should (string-match-p (regexp-quote "`/workspace/sample.el`:2") text))
          (should-not (string-match-p (regexp-quote dir) text)))))))

(ert-deftest pichat-reference-nonfile-buffer-writes-temp-file ()
  (pichat-test-with-temp-dir dir
    (let ((pichat-reference-temp-directory dir)
          (pichat-path-mappings nil))
      (with-temp-buffer
        (rename-buffer "*pichat temp source*" t)
        (insert "(message \"snapshot\")")
        (let* ((text (pichat-reference--buffer-temp-reference))
               (file (progn
                       (should (string-match "- `\\([^`]+\\)`" text))
                       (match-string 1 text))))
          (unwind-protect
              (progn
                (should (string-match-p "References:" text))
                (should (string-match-p "from \\*pichat temp source\\*" text))
                (should (equal (with-temp-buffer
                                 (insert-file-contents file)
                                 (buffer-string))
                               "(message \"snapshot\")")))
            (delete-file file)))))))

(ert-deftest pichat-reference-chat-region-writes-only-selected-text ()
  (pichat-test-with-temp-dir dir
    (let ((pichat-reference-temp-directory dir)
          (pichat-path-mappings nil))
      (with-temp-buffer
        (setq-local major-mode 'pichat-chat-mode)
        (insert "transcript\nselected\nprompt")
        (goto-char (point-min))
        (forward-line 1)
        (set-mark (line-end-position))
        (setq mark-active t)
        (let* ((text (pichat-reference--dwim-text))
               (file (progn
                       (should (string-match "- `\\([^`]+\\)`" text))
                       (match-string 1 text))))
          (unwind-protect
              (should (equal (with-temp-buffer
                               (insert-file-contents file)
                               (buffer-string))
                             "selected"))
            (delete-file file)))))))

(ert-deftest pichat-reference-nonfile-region-writes-only-selected-text ()
  (pichat-test-with-temp-dir dir
    (let ((pichat-reference-temp-directory dir)
          (pichat-path-mappings (list (cons dir "/workspace/"))))
      (with-temp-buffer
        (insert "before\nselected\nafter")
        (goto-char (point-min))
        (forward-line 1)
        (set-mark (line-end-position))
        (setq mark-active t)
        (let* ((text (pichat-reference--region))
               (runtime-file (progn
                               (should (string-match "- `\\([^`]+\\)`" text))
                               (match-string 1 text)))
               (file (expand-file-name (file-name-nondirectory runtime-file) dir)))
          (unwind-protect
              (progn
                (should (string-prefix-p "/workspace/pichat-reference-" runtime-file))
                (should (equal (with-temp-buffer
                                 (insert-file-contents file)
                                 (buffer-string))
                               "selected")))
            (delete-file file)))))))

(ert-deftest pichat-reference-ssh-default-uses-remote-temp-not-project-mappings ()
  (let* ((pichat-targets
          '((reference-ssh :kind ssh :tramp-prefix "/ssh:example:"
                           :path-mappings (("/local/project" . "/project")))))
         (pichat-reference--transport
          (pichat-transport-resolve "/local/project" 'reference-ssh))
         (pichat-reference--path-context
          (pichat-transport-path-context pichat-reference--transport))
         (pichat-reference-temp-directory nil)
         (temporary-file-directory "/local/tmp/")
         created-prefix)
    (cl-letf (((symbol-function 'make-temp-file)
               (lambda (prefix _dir-flag _suffix text)
                 (should (equal text "remote contents"))
                 (setq created-prefix prefix)
                 (concat prefix "123.txt"))))
      (let ((reference (pichat-reference--write-temp-reference
                        "notes" "remote contents")))
        (should (equal created-prefix "/ssh:example:/tmp/pichat-reference-"))
        (should (string-match-p
                 (regexp-quote "`/tmp/pichat-reference-123.txt`") reference))
        (should-not (string-match-p "/ssh:example:" reference))))))

(ert-deftest pichat-reference-unmapped-temp-directory-does-not-write ()
  (pichat-test-with-temp-dir dir
    (let ((pichat-reference-temp-directory dir)
          (pichat-path-mappings '(("/other" . "/workspace"))))
      (with-temp-buffer
        (insert "private")
        (should-error (pichat-reference--buffer-temp-reference) :type 'user-error)
        (should-not (directory-files dir nil "^pichat-reference-"))))))

(ert-deftest pichat-session-file-summary-ignores-malformed-lines ()
  (pichat-test-with-temp-dir dir
    (let ((file (expand-file-name "session_test.jsonl" dir)))
      (with-temp-file file
        (insert "{malformed}\n")
        (insert "{\"type\":\"session\",\"id\":\"s1\",\"cwd\":\"/tmp/work\"}\n")
        (insert "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"first prompt\"}]}}\n"))
      (let ((summary (pichat-sessions--file-summary file)))
        (should (equal "s1" (plist-get summary :id)))
        (should (equal "/tmp/work" (plist-get summary :cwd)))
        (should (equal "first prompt" (plist-get summary :first-user-prompt)))))))

(ert-deftest pichat-vui-status-command-falls-back-without-vui-dependency ()
  (let (called)
    (cl-letf (((symbol-function 'pichat-status)
               (lambda () (interactive) (setq called t))))
      (call-interactively #'pichat-vui-status-dashboard)
      (should called))))

(ert-deftest pichat-rpc-event-log-is-bounded ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-rpc-event-log-limit 3))
      (dotimes (index 5)
        (pichat-rpc--process-filter
         proc (format "{\"type\":\"test_event\",\"index\":%d}\n" index)))
      (should (= 3 (length (pichat-session-event-log session))))
      (should (equal '(4 3 2)
                     (mapcar (lambda (event) (plist-get event :index))
                             (pichat-session-event-log session)))))))

(ert-deftest pichat-saved-session-summary-cache-invalidates-on-change-and-delete ()
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir dir
      (let* ((pichat-pi-session-dir dir)
             (file (expand-file-name "session_cache.jsonl" dir))
             (original (symbol-function 'pichat-sessions--file-summary-uncached))
             (parses 0))
        (with-temp-file file
          (insert "{\"type\":\"session\",\"id\":\"cached\",\"cwd\":\"/tmp\"}\n"))
        (cl-letf (((symbol-function 'pichat-sessions--file-summary-uncached)
                   (lambda (path)
                     (cl-incf parses)
                     (funcall original path))))
          (let ((first (pichat-sessions--file-summary file)))
            (should (eq first (pichat-sessions--file-summary file)))
            (should (= 1 parses)))
          (with-temp-buffer
            (insert "{\"type\":\"session_info\",\"name\":\"changed\"}\n")
            (append-to-file (point-min) (point-max) file))
          (should (equal "changed" (plist-get (pichat-sessions--file-summary file) :name)))
          (should (= 2 parses)))
        (delete-file file)
        (should-not (pichat-sessions--files))
        (should-not (gethash file pichat-sessions--summary-cache))))))

(provide 'pichat-test-sessions-reference)
;;; pichat-test-sessions-reference.el ends here
