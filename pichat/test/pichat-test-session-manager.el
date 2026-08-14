;;; pichat-test-session-manager.el --- Global runtime manager tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Observable registry, manager, and independent-source behavior.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-runtime-registry-retains-default-and-independent-sessions ()
  (pichat-test-with-clean-state
    (let (first second)
      (cl-letf (((symbol-function 'pichat-rpc-start) #'identity)
                ((symbol-function 'pichat--project-root)
                 (lambda (&optional _directory) "/tmp/project/")))
        (setq first (pichat-start-session "/tmp/project/")
              second (pichat-start-session "/tmp/project/")))
      (should (= 2 (length (pichat-session-list))))
      (should (memq first (pichat-session-list)))
      (should (memq second (pichat-session-list)))
      (should-not (equal (pichat-session-runtime-id first)
                         (pichat-session-runtime-id second)))
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_s) t)))
        (pichat-set-default-session first))
      (should (pichat-session-default-p first))
      (should-not (pichat-session-default-p second)))))

(ert-deftest pichat-startup-failure-remains-inspectable-in-runtime-registry ()
  (pichat-test-with-clean-state
    (let (session)
      (cl-letf (((symbol-function 'pichat-rpc-start)
                 (lambda (s)
                   (setf (pichat-session-state s) 'error)
                   s)))
        (setq session (pichat-start-session "/tmp/failed/")))
      (should (eq 'error (pichat-session-state session)))
      (should (eq session
                  (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session)))))))

(ert-deftest pichat-runtime-id-survives-source-rebinding ()
  (let* ((session (pichat-session-make :id "source-one"))
         (runtime-id (pichat-session-runtime-id session)))
    (pichat-session-apply-rpc-state
     session '(:sessionId "source-two" :sessionFile "/tmp/two.jsonl"))
    (should (equal runtime-id (pichat-session-runtime-id session)))
    (should (equal "source-two" (pichat-session-id session)))))

(ert-deftest pichat-stopping-runtime-clears-default-but-retains-inspection-row ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make
                    :cwd "/tmp/project/"
                    :owner-scope-key "project:/tmp/project/")))
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_s) t)))
        (pichat-set-default-session session))
      (cl-letf (((symbol-function 'pichat-rpc-stop)
                 (lambda (s) (setf (pichat-session-state s) 'stopped))))
        (pichat-stop-session session))
      (should (eq session
                  (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session))))
      (should-not (pichat-session-default-p session))
      (should (eq 'stopped (pichat-session-state session))))))

(ert-deftest pichat-forgetting-one-runtime-does-not-affect-scope-peer ()
  (pichat-test-with-clean-state
    (let ((first (pichat-session-make
                  :owner-scope-key "project:/tmp/project/"))
          (second (pichat-session-make
                   :owner-scope-key "project:/tmp/project/")))
      (pichat-register-session first)
      (pichat-register-session second)
      (pichat-forget-session first)
      (should-not (pichat-session-by-runtime-id
                   (pichat-session-runtime-id first)))
      (should (eq second
                  (pichat-session-by-runtime-id
                   (pichat-session-runtime-id second)))))))

(ert-deftest pichat-chat-kill-stops-and-forgets-only-own-runtime ()
  (pichat-test-with-unit-session (session proc)
    (let ((other (pichat-session-make :cwd default-directory))
          buffer)
      (pichat-register-session session)
      (pichat-register-session other)
      (setq buffer (pichat-chat-open session))
      (kill-buffer buffer)
      (should-not (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session)))
      (should (eq other
                  (pichat-session-by-runtime-id
                   (pichat-session-runtime-id other)))))))

(ert-deftest pichat-session-manager-rows-use-immutable-runtime-identity ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-session-make
                     :id "source-one"
                     :cwd "/tmp/project/"
                     :owner-scope-key "project:/tmp/project/"
                     :owner-scope-label "project@test"))
           (runtime-id (pichat-session-runtime-id session))
           buffer)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (&rest _args)
                   (ert-fail "manager refresh must not request RPC state"))))
        (setq buffer (pichat-session-manager)))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal runtime-id (caar tabulated-list-entries)))
            (pichat-session-apply-rpc-state
             session '(:sessionId "source-two" :sessionFile "/tmp/two.jsonl"))
            (pichat-session-manager-refresh)
            (should (equal runtime-id (caar tabulated-list-entries)))
            (should (equal "source-two" (pichat-session-id session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-rows-present-compact-user-fields ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-session-make
                     :id "8ab3111a-more"
                     :name "Improve session manager"
                     :state 'idle
                     :model '(:provider "openai" :id "gpt-5.4")
                     :cwd "/tmp/emacs.mine/"
                     :owner-scope-key "project:/tmp/emacs.mine/"
                     :owner-scope-label "emacs.mine@12345678"))
           buffer)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pichat-session-alive-p) (lambda (_s) t)))
        (pichat-set-default-session session))
      (let* ((entry (pichat-session-manager--entry session))
             (columns (mapcar #'substring-no-properties
                              (append (cadr entry) nil))))
        (should (equal (pichat-session-runtime-id session) (car entry)))
        (should (equal '("★" "8ab3111a" "idle" "file" "emacs.mine"
                         "local" "openai/gpt-5.4" "Improve session manager")
                       columns)))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
        (setq buffer (pichat-session-manager)))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal '("" "ID" "Status" "Store" "Project" "Target" "Model" "Session")
                           (mapcar #'car (append tabulated-list-format nil))))
            (should (equal '("Project")
                           (list (car tabulated-list-sort-key)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-compact-row-handles-global-unnamed-source ()
  (let* ((session (pichat-session-make
                   :state 'starting
                   :owner-scope-key "global"
                   :owner-scope-label "global"))
         (columns (append (cadr (pichat-session-manager--entry session)) nil)))
    (should (equal '("" "—" "starting" "file" "global" "local" "—" "—") columns))))

(ert-deftest pichat-session-manager-status-marks-pending-user-input-minimally ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setf (pichat-session-state session) 'compacting)
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (puthash "waiting" '(:id "waiting")
                       pichat-chat--pending-ui-requests)
              (setq pichat-chat--pending-ui-count 1))
            (let* ((status (pichat-session-manager--status-label session))
                   (marker-position (1- (length status))))
              (should (equal "compacting!" (substring-no-properties status)))
              (should (= 11 (string-width status)))
              (should (eq 'warning
                          (get-text-property marker-position 'face status)))
              (should (string-match-p
                       "Waiting for user input"
                       (get-text-property marker-position 'help-echo status))))
            (with-current-buffer buffer
              (clrhash pichat-chat--pending-ui-requests)
              (setq pichat-chat--pending-ui-count 0))
            (should (equal "compacting"
                           (pichat-session-manager--status-label session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-listens-for-pending-user-input-changes ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make))
          buffer scheduled)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
        (setq buffer (pichat-session-manager)))
      (unwind-protect
          (with-current-buffer buffer
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (&rest _args) (setq scheduled t) 'deferred)))
              (pichat-emit session 'user-input-pending-changed :count 1)
              (should scheduled))
            (should (assq 'user-input-pending-changed
                          pichat-session-manager--event-handlers)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-action-targets-selected-runtime-explicitly ()
  (pichat-test-with-clean-state
    (let ((first (pichat-session-make :name "first"))
          (second (pichat-session-make :name "second"))
          displayed buffer)
      (pichat-register-session first)
      (pichat-register-session second)
      (let ((pichat-session-manager-display-chat-function
             (lambda (session) (setq displayed session))))
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
          (setq buffer (pichat-session-manager)))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "second")
              (beginning-of-line)
              (pichat-session-manager-open-chat)
              (should (eq second displayed)))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-session-manager-persistence-presentation-uses-launch-metadata ()
  (let* ((persistent (pichat-session-make :persistence 'persistent))
         (ephemeral (pichat-session-make :persistence 'ephemeral))
         (persistent-columns
          (append (cadr (pichat-session-manager--entry persistent)) nil))
         (ephemeral-columns
          (append (cadr (pichat-session-manager--entry ephemeral)) nil)))
    (should (equal "file" (nth 3 persistent-columns)))
    (should (equal "none" (nth 3 ephemeral-columns)))))

(ert-deftest pichat-session-manager-new-prompts-for-and-remembers-project ()
  (let ((project-prompter (lambda () "/tmp/recent-project/"))
        (project 'fake-project)
        checked-directory remembered)
    (cl-letf (((symbol-function 'project-current)
               (lambda (maybe-prompt directory)
                 (should-not maybe-prompt)
                 (setq checked-directory directory)
                 project))
              ((symbol-function 'project-remember-project)
               (lambda (selected) (setq remembered selected))))
      (should (equal "/tmp/recent-project/"
                     (pichat-session-manager--read-project-directory))))
    (should (equal "/tmp/recent-project/" checked-directory))
    (should (eq project remembered))))

(ert-deftest pichat-session-manager-launch-opens-shared-transient-with-policy ()
  (let (context)
    (cl-letf (((symbol-function 'pichat-launch)
               (lambda (&optional value) (setq context value))))
      (with-temp-buffer
        (pichat-session-manager-launch)))
    (should (eq #'pichat-session-manager--display
                (plist-get context :display-function)))
    (should (eq #'pichat-session-manager--read-launch-scope
                (plist-get context :current-scope-function)))
    (should (plist-get context :manager))))

(ert-deftest pichat-session-manager-launch-current-profile-prompts-for-exact-scope ()
  (let (profile directory prompted)
    (cl-letf (((symbol-function 'pichat-session-manager--read-launch-scope)
               (lambda ()
                 (setq prompted t)
                 '("project:/tmp/chosen/" "/tmp/chosen/" "chosen@test")))
              ((symbol-function 'pichat--open-launch-profile)
               (lambda (value &optional cwd)
                 (setq profile value directory cwd))))
      (pichat-launch-execute
       nil
       (list :display-function #'pichat-session-manager--display
             :current-scope-function
             #'pichat-session-manager--read-launch-scope
             :manager t)))
    (should prompted)
    (should (equal '("project:/tmp/chosen/" "/tmp/chosen/" "chosen@test")
                   (plist-get profile :scope)))
    (should (eq #'pichat-session-manager--display
                (plist-get profile :display-function)))
    (should-not directory)))

(ert-deftest pichat-session-manager-launch-global-profile-skips-project-prompt ()
  (let (profile prompted)
    (cl-letf (((symbol-function 'pichat-session-manager--read-launch-scope)
               (lambda () (setq prompted t)))
              ((symbol-function 'pichat--open-launch-profile)
               (lambda (value &optional _cwd) (setq profile value))))
      (pichat-launch-execute
       '("--global" "--ephemeral")
       (list :display-function #'pichat-session-manager--display
             :current-scope-function
             #'pichat-session-manager--read-launch-scope
             :manager t)))
    (should-not prompted)
    (should (eq 'global (plist-get profile :scope)))
    (should (eq 'ephemeral (plist-get profile :persistence)))))

(ert-deftest pichat-session-manager-read-launch-scope-uses-project-prompter ()
  (let ((project-prompter (lambda () "/tmp/chosen-project/")))
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _args) nil)))
      (with-temp-buffer
        (setq default-directory "/tmp/manager-global/")
        (should (equal
                 '("project|local|/tmp/chosen-project/" "/tmp/chosen-project/"
                   "chosen-project@60749fc7")
                 (pichat-session-manager--read-launch-scope)))))))

(ert-deftest pichat-session-manager-launch-binding-preserves-fast-new-bindings ()
  (should (eq #'pichat-session-manager-launch
              (lookup-key pichat-session-manager-mode-map (kbd "+"))))
  (should (eq #'pichat-session-manager-new
              (lookup-key pichat-session-manager-mode-map (kbd "n"))))
  (should (eq #'pichat-session-manager-new-in-scope
              (lookup-key pichat-session-manager-mode-map (kbd "N")))))

(ert-deftest pichat-session-manager-new-accepts-manual-non-project-directory ()
  (let ((project-prompter (lambda () "/tmp/manual-directory/"))
        started-directory)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt _directory) nil))
              ((symbol-function 'project-remember-project)
               (lambda (&rest _args)
                 (ert-fail "A non-project directory must not be remembered")))
              ((symbol-function 'pichat-session-manager--start-in-directory)
               (lambda (directory &optional _scope)
                 (setq started-directory directory))))
      (call-interactively #'pichat-session-manager-new))
    (should (equal "/tmp/manual-directory/" started-directory))))

(ert-deftest pichat-session-manager-saved-browser-separates-discovery-from-placement ()
  (pichat-test-with-clean-state
    (let* ((session (pichat-session-make
                     :name "selected"
                     :cwd "/owner/"
                     :owner-scope-key "project:/owner/"
                     :owner-scope-label "owner@test"))
           arguments buffer)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil))
                ((symbol-function 'pichat-sessions-browse-files-independently)
                 (lambda (&rest args) (setq arguments args))))
        (setq buffer (pichat-session-manager))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "selected")
              (beginning-of-line)
              (pichat-session-manager-browse-saved)
              (should (eq session (plist-get arguments :session)))
              (should-not (plist-member arguments :owner-directory))
              (should-not (plist-member arguments :owner-scope))
              (should (eq #'pichat-session-manager--display
                          (plist-get arguments :display-function))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-session-manager-stop-default-and-forget-affect-selected-only ()
  (pichat-test-with-clean-state
    (let ((selected (pichat-session-make :name "selected" :state 'idle))
          (peer (pichat-session-make :name "peer" :state 'idle))
          (selected-live t)
          buffer)
      (setf (pichat-session-owner-scope-key selected) "project:/tmp/project/"
            (pichat-session-owner-scope-key peer) "project:/tmp/project/")
      (pichat-register-session selected)
      (pichat-register-session peer)
      (cl-letf (((symbol-function 'pichat-session-alive-p)
                 (lambda (session)
                   (if (eq session selected) selected-live t)))
                ((symbol-function 'pichat-rpc-stop)
                 (lambda (session)
                   (when (eq session selected) (setq selected-live nil))
                   (setf (pichat-session-state session) 'stopped)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _args) t))
                ((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
        (setq buffer (pichat-session-manager))
        (unwind-protect
            (with-current-buffer buffer
              (goto-char (point-min))
              (search-forward "selected")
              (beginning-of-line)
              (pichat-session-manager-make-default)
              (should (pichat-session-default-p selected))
              (pichat-session-manager-stop)
              (should-not (pichat-session-default-p selected))
              (should (pichat-session-by-runtime-id
                       (pichat-session-runtime-id selected)))
              (goto-char (point-min))
              (search-forward "selected")
              (beginning-of-line)
              (pichat-session-manager-forget)
              (should-not (pichat-session-by-runtime-id
                           (pichat-session-runtime-id selected)))
              (should (eq peer
                          (pichat-session-by-runtime-id
                           (pichat-session-runtime-id peer)))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun pichat-test-session-manager--tree-response (user-text assistant-text)
  "Return a minimal get_tree response for USER-TEXT and ASSISTANT-TEXT."
  (let ((user (list :type "message" :id "user-entry" :parentId nil
                    :timestamp "2026-08-01T10:00:00Z"
                    :message (list :role "user" :content user-text)))
        (assistant (list :type "message" :id "assistant-entry"
                         :parentId "user-entry"
                         :timestamp "2026-08-01T10:01:00Z"
                         :message (list :role "assistant"
                                        :content assistant-text))))
    (list :success t
          :data (list :tree
                      (list (list :entry user
                                  :children
                                  (list (list :entry assistant
                                              :children nil))))
                      :leafId "assistant-entry"))))

(ert-deftest pichat-session-manager-preview-requests-and-renders-selected-runtime ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let* ((session (pichat-session-make
                       :id "pi-source" :name "parser work"
                       :state 'idle :cwd "/tmp/project/"
                       :session-file "/tmp/pi-source.jsonl"))
             (response (pichat-test-session-manager--tree-response
                        "Fix the parser" "Working on the parser now."))
             requested buffer)
        (pichat-register-session session)
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil))
                  ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                  ((symbol-function 'display-buffer-in-side-window)
                   (lambda (preview _action)
                     (set-window-buffer (selected-window) preview)
                     (selected-window)))
                  ((symbol-function 'pichat-rpc-get-tree)
                   (lambda (selected callback &optional _error)
                     (setq requested selected)
                     (funcall callback response selected)
                     41)))
          (setq buffer (pichat-session-manager))
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "parser work")
            (beginning-of-line)
            (should (eq #'pichat-session-manager-toggle-preview
                        (lookup-key pichat-session-manager-mode-map
                                    (kbd "C-o"))))
            (pichat-session-manager-toggle-preview))
          (should (eq session requested))
          (with-current-buffer pichat-session-manager-preview-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "Runtime Preview" text))
              (should (string-match-p "Runtime: pichat-runtime-" text))
              (should (string-match-p "Preferred: no" text))
              (should (string-match-p "Pi ID: pi-source" text))
              (should (string-match-p "Persistence: persisted source file" text))
              (should (string-match-p "Source: /tmp/pi-source.jsonl" text))
              (should (string-match-p "Fix the parser" text))
              (should (string-match-p "Working on the parser now" text)))))))))

(ert-deftest pichat-session-manager-preview-shows-ephemeral-launch-metadata ()
  (let ((session (pichat-session-make
                  :cwd "/tmp/project/" :persistence 'ephemeral)))
    (unwind-protect
        (with-temp-buffer
          (pichat-session-manager-mode)
          (pichat-session-manager--render-preview session nil)
          (with-current-buffer pichat-session-manager-preview-buffer-name
            (should (string-match-p "Persistence: none (--no-session)"
                                    (buffer-string)))))
      (when-let ((buffer
                  (get-buffer pichat-session-manager-preview-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest pichat-session-manager-preview-reuses-stopped-chat-cache ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let* ((session (pichat-session-make
                       :id "cached-source" :name "cached work"
                       :state 'stopped :cwd "/tmp/project/"))
             (response (pichat-test-session-manager--tree-response
                        "Cached user task" "Cached assistant result"))
             (data (plist-get response :data))
             (tree (car (plist-get data :tree)))
             (user (plist-get tree :entry))
             (assistant (plist-get (car (plist-get tree :children)) :entry))
             (cache (pichat-pi-entry-cache-full
                     "cached-source" nil (list user assistant)
                     "assistant-entry"))
             (chat (generate-new-buffer " *pichat-cached-chat*"))
             manager)
        (unwind-protect
            (progn
              (with-current-buffer chat
                (pichat-chat-mode)
                (setq pichat-chat-session session
                      pichat-chat--entry-cache cache))
              (setf (pichat-session-buffer session) chat)
              (pichat-register-session session)
              (cl-letf (((symbol-function 'pop-to-buffer)
                         (lambda (&rest _args) nil))
                        ((symbol-function 'pichat-session-alive-p)
                         (lambda (_s) nil))
                        ((symbol-function 'display-buffer-in-side-window)
                         (lambda (preview _action)
                           (set-window-buffer (selected-window) preview)
                           (selected-window)))
                        ((symbol-function 'pichat-rpc-get-tree)
                         (lambda (&rest _args)
                           (ert-fail "stopped cached preview must not request Pi"))))
                (setq manager (pichat-session-manager))
                (with-current-buffer manager
                  (goto-char (point-min))
                  (search-forward "cached work")
                  (beginning-of-line)
                  (pichat-session-manager-toggle-preview))
                (with-current-buffer pichat-session-manager-preview-buffer-name
                  (let ((text (buffer-string)))
                    (should (string-match-p "Cached user task" text))
                    (should (string-match-p "Cached assistant result" text))
                    (should-not (string-match-p "preview unavailable" text))))))
          (when (buffer-live-p chat) (kill-buffer chat)))))))

(ert-deftest pichat-session-manager-preview-rejects-prior-row-callback ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (let* ((first (pichat-session-make :id "one" :name "first work"
                                         :state 'idle))
             (second (pichat-session-make :id "two" :name "second work"
                                          :state 'idle))
             first-callback manager)
        (pichat-register-session first)
        (pichat-register-session second)
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil))
                  ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                  ((symbol-function 'pichat-rpc-cancel-request) #'ignore)
                  ((symbol-function 'display-buffer-in-side-window)
                   (lambda (preview _action)
                     (set-window-buffer (selected-window) preview)
                     (selected-window)))
                  ((symbol-function 'pichat-rpc-get-tree)
                   (lambda (session callback &optional _error)
                     (if (eq session first)
                         (progn (setq first-callback callback) 51)
                       (funcall callback
                                (pichat-test-session-manager--tree-response
                                 "Second task" "Second result")
                                session)
                       52))))
          (setq manager (pichat-session-manager))
          (with-current-buffer manager
            (goto-char (point-min))
            (search-forward "first work")
            (beginning-of-line)
            (pichat-session-manager-toggle-preview)
            (goto-char (point-min))
            (search-forward "second work")
            (beginning-of-line)
            (pichat-session-manager--track-preview-selection))
          (pichat-test-wait-until
           (lambda ()
             (with-current-buffer pichat-session-manager-preview-buffer-name
               (string-match-p "Second task" (buffer-string))))
           1 "runtime preview to follow the selected manager row")
          (funcall first-callback
                   (pichat-test-session-manager--tree-response
                    "Stale first task" "Stale first result")
                   first)
          (with-current-buffer pichat-session-manager-preview-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "Second task" text))
              (should-not (string-match-p "Stale first task" text)))))))))

(ert-deftest pichat-session-manager-kill-cleans-ui-handlers-not-runtimes ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make))
          event-handlers registry-handler buffer)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
        (setq buffer (pichat-session-manager)))
      (with-current-buffer buffer
        (setq event-handlers (copy-sequence
                              pichat-session-manager--event-handlers)
              registry-handler pichat-session-manager--registry-handler))
      (kill-buffer buffer)
      (should (eq session
                  (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session))))
      (should-not (memq registry-handler
                        pichat-session-registry-changed-hook))
      (dolist (pair event-handlers)
        (should-not (memq (cdr pair)
                          (gethash (car pair) pichat--global-handlers)))))))

(ert-deftest pichat-independent-source-open-preserves-origin-and-owner-scope ()
  (pichat-test-with-clean-state
    (let* ((origin (pichat-session-make :id "origin"))
           (independent
            (pichat-session-make
             :cwd "/owner/"
             :owner-scope-key "project:/owner/"
             :owner-scope-label "owner@test"))
           displayed ready sent-file started-scope)
      (pichat-register-session origin)
      (pichat-register-session independent)
      (setq pichat-current-session origin)
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (_cwd &optional scope)
                   (setq started-scope scope)
                   independent))
                ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                ((symbol-function 'pichat-rpc-switch-session)
                 (lambda (session file callback &optional _error)
                   (setq sent-file file)
                   (funcall callback '(:success t :data nil) session)))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (session callback &optional _error)
                   (pichat-session-apply-rpc-state
                    session '(:sessionId "loaded" :sessionFile "/saved/runtime.jsonl"))
                   (funcall callback '(:success t :data nil) session)))
                ((symbol-function 'message) #'ignore))
        (pichat-sessions-open-file-independently
         "/saved/host.jsonl" :cwd "/loaded/"
         :owner-directory "/owner/"
         :owner-scope '("project:/owner/" "/owner/" "owner@test")
         :display-function (lambda (session) (setq displayed session))
         :ready (lambda (session) (setq ready session))))
      (should (equal "/saved/host.jsonl" sent-file))
      (should (equal '("project:/owner/" "/owner/" "owner@test")
                     started-scope))
      (should (eq origin pichat-current-session))
      (should (eq independent displayed))
      (should (eq independent ready))
      (should (equal "project:/owner/"
                     (pichat-session-owner-scope-key independent)))
      (should (equal "/loaded/" (pichat-session-cwd independent))))))

(ert-deftest pichat-independent-source-open-infers-placement-from-saved-cwd ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make)) started-cwd started-scope ready)
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (cwd &optional scope)
                   (setq started-cwd cwd
                         started-scope scope)
                   session))
                ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                ((symbol-function 'pichat-rpc-switch-session)
                 (lambda (s _file callback &optional _error)
                   (funcall callback '(:success t :data nil) s)))
                ((symbol-function 'pichat-rpc-get-state)
                 (lambda (s callback &optional _error)
                   (funcall callback '(:success t :data nil) s)))
                ((symbol-function 'message) #'ignore))
        (pichat-sessions-open-file-independently
         "/saved/session.jsonl" :cwd "/saved-project/"
         :display-function nil
         :ready (lambda (s) (setq ready s))))
      (should (equal "/saved-project/" started-cwd))
      (should-not started-scope)
      (should (eq session ready)))))

(ert-deftest pichat-independent-source-open-requests-transcript-sync-before-ready ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :cwd "/owner/"))
          buffer order sync-buffer)
      (pichat-register-session session)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-start-session)
                     (lambda (_cwd &optional _scope) session))
                    ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                    ((symbol-function 'pichat-rpc-switch-session)
                     (lambda (s _file callback &optional _error)
                       (funcall callback '(:success t :data nil) s)))
                    ((symbol-function 'pichat-rpc-get-state)
                     (lambda (s callback &optional _error)
                       (pichat-session-apply-rpc-state
                        s '(:sessionId "loaded"
                            :sessionFile "/saved/runtime.jsonl"))
                       (funcall callback '(:success t :data nil) s)))
                    ((symbol-function 'pichat-chat-repaint)
                     (lambda ()
                       (push 'sync order)
                       (setq sync-buffer (current-buffer))))
                    ((symbol-function 'message) #'ignore))
            (pichat-sessions-open-file-independently
             "/saved/host.jsonl"
             :display-function
             (lambda (s)
               (push 'display order)
               (setq buffer (generate-new-buffer " *pichat-independent-sync*"))
               (setf (pichat-session-buffer s) buffer))
             :ready (lambda (_s) (push 'ready order))))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (should (equal '(display sync ready) (nreverse order)))
      (should (eq buffer sync-buffer)))))

(ert-deftest pichat-independent-source-cancellation-cleans-new-runtime ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :cwd "/tmp/")) stopped failure)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (_cwd &optional _scope) session))
                ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                ((symbol-function 'pichat-rpc-switch-session)
                 (lambda (s _file callback &optional _error)
                   (funcall callback '(:success t :data (:cancelled t)) s)))
                ((symbol-function 'pichat-stop-session)
                 (lambda (_s) (setq stopped t)))
                ((symbol-function 'message) #'ignore))
        (pichat-sessions-open-file-independently
         "/saved/host.jsonl"
         :error-callback (lambda (response _s) (setq failure response))))
      (should stopped)
      (should (eq 'cancelled (plist-get failure :pichat-failure-kind)))
      (should-not (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session))))))

(ert-deftest pichat-independent-source-failure-stops-and-forgets-new-runtime ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :cwd "/tmp/"))
          stopped failure)
      (pichat-register-session session)
      (cl-letf (((symbol-function 'pichat-start-session)
                 (lambda (_cwd &optional _scope) session))
                ((symbol-function 'pichat-session-alive-p) (lambda (_s) t))
                ((symbol-function 'pichat-rpc-switch-session)
                 (lambda (s _file _callback &optional error-callback)
                   (funcall error-callback '(:success nil :error "switch failed") s)))
                ((symbol-function 'pichat-stop-session)
                 (lambda (_s) (setq stopped t)))
                ((symbol-function 'message) #'ignore))
        (pichat-sessions-open-file-independently
         "/saved/host.jsonl"
         :display-function #'ignore
         :error-callback (lambda (response _s) (setq failure response))))
      (should stopped)
      (should (equal "switch failed" (plist-get failure :error)))
      (should-not (pichat-session-by-runtime-id
                   (pichat-session-runtime-id session))))))

(provide 'pichat-test-session-manager)
;;; pichat-test-session-manager.el ends here
