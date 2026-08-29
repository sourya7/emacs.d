;;; pichat-test-consult.el --- Archive Consult UI tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for archive query translation, rendering, actions, and routing.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-consult-translates-fields-to-conservative-fts-argv ()
  (let* ((options (pichat-consult--query-options
                   "alpha beta name:\"Named session\" text:\"exact phrase\" role:user"
                   "/project")))
    (should (equal "\"alpha\" AND \"beta\"" (plist-get options :query)))
    (should (equal "\"Named session\"" (plist-get options :name-query)))
    (should (equal "\"exact phrase\"" (plist-get options :text-query)))
    (should (equal "user" (plist-get options :roles)))
    (should (equal "/project" (plist-get options :cwd)))
    (should (equal "session_name,user,assistant" (plist-get options :kinds)))
    (should (plist-get options :loadable-only))))

(ert-deftest pichat-consult-rejects-role-only-and-invalid-query-syntax ()
  (should-error (pichat-consult--query-options "role:user" nil)
                :type 'user-error)
  (should-error (pichat-consult--query-options "name:foo role:assistant" nil)
                :type 'user-error)
  (should-error (pichat-consult--query-options "text:foo role:tool" nil)
                :type 'user-error)
  (should-error (pichat-consult--query-options "text:\"unterminated" nil)
                :type 'user-error))

(ert-deftest pichat-consult-empty-input-routes-to-recent-and-search-uses-argv ()
  (let ((capability '(:node "node" :helper "/pkg/query.mjs")))
    (should (equal "recent"
                   (nth 2 (pichat-consult--search-command capability "/p" ""))))
    (let ((command (pichat-consult--search-command
                    capability "/project with spaces" "needle role:user")))
      (should (equal "search" (nth 2 command)))
      (should (member "/project with spaces" command))
      (should (member "\"needle\"" command))
      (should-not (cl-some (lambda (arg) (string-match-p "[|;&]" arg))
                           command)))))

(ert-deftest pichat-consult-search-preserves-async-read-contract ()
  (let* ((capability '(:identity test))
         (project '(:cwd "/fixture/project"))
         (pichat-consult-session-preview-key "C-z")
         builder collection-capability transform-function
         read-collection read-options split-style command-call)
    (cl-letf (((symbol-function 'consult--async-transform)
               (lambda (function)
                 (setq transform-function function)
                 'fixture-transform))
              ((symbol-function 'pichat-consult--archive-process-collection)
               (lambda (value capability-value transform)
                 (setq builder value
                       collection-capability capability-value)
                 (should (eq 'fixture-transform transform))
                 'fixture-collection))
              ((symbol-function 'pichat-consult--preview-state)
               (lambda () 'fixture-preview-state))
              ((symbol-function 'pichat-consult--search-command)
               (lambda (capability-value cwd input)
                 (setq command-call (list capability-value cwd input))
                 '(fixture-command)))
              ((symbol-function 'consult--read)
               (lambda (items &rest options)
                 (setq read-collection items
                       read-options options
                       split-style consult-async-split-style)
                 (should (equal '(fixture-command)
                                (funcall builder "archive terms")))
                 nil)))
      (pichat-consult--search capability project "initial terms"))
    (should (eq 'fixture-collection read-collection))
    (should (eq capability collection-capability))
    (should (functionp transform-function))
    (should (equal (list capability "/fixture/project" "archive terms")
                   command-call))
    (should (eq 'none split-style))
    (should (eq #'consult--lookup-candidate
                (plist-get read-options :lookup)))
    (should (eq t (plist-get read-options :require-match)))
    (should (eq 'pichat-session (plist-get read-options :category)))
    (should (equal '(:input pichat-consult--session-history)
                   (plist-get read-options :history)))
    (should (equal "initial terms" (plist-get read-options :initial)))
    (should (eq 'fixture-preview-state (plist-get read-options :state)))
    (should (equal "C-z" (plist-get read-options :preview-key)))
    (should (eq pichat-consult-session-minibuffer-map
                (plist-get read-options :keymap)))
    (should (plist-member read-options :sort))
    (should-not (plist-get read-options :sort))
    (should (eq #'pichat-consult--candidate-annotation
                (plist-get read-options :annotate)))))

(ert-deftest pichat-consult-project-picker-opens-a-rerunnable-search-command ()
  (let* ((capability '(:identity fixture-capability))
         (project '(:kind project :cwd "/fixture/project"))
         (selection-function (lambda (_file _cwd)))
         calls (project-requests 0) (project-selections 0))
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-archive-capability-current-p)
               (lambda (value) (eq value capability)))
              ((symbol-function 'pichat-archive-request)
               (lambda (_capability operation _options success _failure)
                 (should (eq operation 'projects))
                 (cl-incf project-requests)
                 (funcall success (list project))))
              ((symbol-function 'pichat-consult--select-project)
               (lambda (_projects)
                 ;; This is the command left by exiting the project picker.
                 (cl-incf project-selections)
                 (setq this-command 'vertico-exit)
                 project))
              ((symbol-function 'pichat-consult--search)
               (lambda (capability-value project-value &optional initial selection)
                 (push (list :capability capability-value
                             :project project-value :initial initial
                             :selection selection :command this-command)
                       calls))))
      (let ((this-command 'pichat-sessions-browse-files))
        (pichat-consult-sessions
         capability "initial terms" selection-function))
      (let ((command (plist-get (car calls) :command)))
        (should (commandp command))
        (should-not (eq command 'vertico-exit))
        (command-execute command)
        (setq calls (nreverse calls))
        (should (= 1 project-requests))
        (should (= 1 project-selections))
        (should (= 2 (length calls)))
        (should (equal "initial terms" (plist-get (car calls) :initial)))
        ;; Embark restores its captured input into this new minibuffer.
        (should-not (plist-get (cadr calls) :initial))
        (dolist (call calls)
          (should (eq capability (plist-get call :capability)))
          (should (eq project (plist-get call :project)))
          (should (eq selection-function (plist-get call :selection)))
          (should (eq command (plist-get call :command))))))))

(ert-deftest pichat-consult-embark-reruns-the-recorded-project-search-command ()
  (skip-unless (require 'embark nil t))
  (let ((capability '(:identity fixture-capability))
        (project '(:cwd "/fixture/project"))
        (origin (generate-new-buffer " *pichat-embark-origin*"))
        (collect (generate-new-buffer " *pichat-embark-collect*"))
        calls recorded quit-argument)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
                   (lambda (value) (eq value capability)))
                  ((symbol-function 'pichat-consult--search)
                   (lambda (&rest args)
                     (push args calls)
                     (with-temp-buffer
                       (embark--record-this-command)
                       (setq recorded embark--command)))))
          (let ((this-command 'vertico-exit))
            (pichat-consult--run-project-search capability project "query"))
          (should (commandp recorded))
          (should-not (eq recorded 'vertico-exit))
          (with-current-buffer collect
            (setq-local embark--target-buffer origin
                        embark--command recorded)
            (cl-letf (((symbol-function 'minibufferp) (lambda (&optional _) t))
                      ((symbol-function 'minibuffer-contents-no-properties)
                       (lambda () "query")))
              (setq-local embark--rerun-function
                          (embark--rerun-function 'embark-collect)))
            (cl-letf (((symbol-function 'quit-window)
                       (lambda (&optional argument _window)
                         (setq quit-argument argument))))
              (embark-rerun-collect-or-export)))
          (should (eq quit-argument 'kill-buffer))
          (should (= 2 (length calls)))
          (should (equal (list capability project nil nil) (car calls))))
      (when (buffer-live-p collect) (kill-buffer collect))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest pichat-consult-project-search-reruns-are-independent-and-reject-stale-capabilities ()
  (let* ((capability-a '(:identity capability-a))
         (capability-b '(:identity capability-b))
         (project-a '(:cwd "/project/a"))
         (project-b '(:cwd "/project/b"))
         (current (list capability-a capability-b))
         calls command-a command-b)
    (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
               (lambda (capability) (memq capability current)))
              ((symbol-function 'pichat-consult--search)
               (lambda (capability project &optional initial selection)
                 (push (list capability project initial selection this-command)
                       calls))))
      (pichat-consult--run-project-search capability-a project-a "query a")
      (setq command-a (nth 4 (car calls)))
      (pichat-consult--run-project-search capability-b project-b "query b")
      (setq command-b (nth 4 (car calls)))
      (should (commandp command-a))
      (should (commandp command-b))
      (should-not (eq command-a command-b))
      (command-execute command-a)
      (should (equal (list capability-a project-a nil nil command-a)
                     (car calls)))
      (setq current (delq capability-b current))
      (should-error (command-execute command-b) :type 'user-error)
      (should (= 3 (length calls))))))

(ert-deftest pichat-consult-embark-wrapper-uses-attached-target-not-display-text ()
  (let* ((record '(:session-id "session-1" :session-file "/saved.jsonl"
                   :cwd "/project" :source-exists t))
         (candidate (propertize "display text with no encoded identity"
                               'consult--candidate record))
         received)
    (pichat-consult--embark-session-action
     :action (lambda (target) (setq received target))
     :target candidate)
    (should (eq record received))))

(ert-deftest pichat-consult-decodes-normalized-archive-candidates ()
  (let* ((object (append
                  (pichat-test-archive--metadata)
                  '(:matchKind "content" :score 1.5 :matchCount 1
                    :entryId "entry-1" :entryRowId 1 :entryLoadable t
                    :highlightTerms ["needle"]
                    :occurrences
                    [(:entryId "entry-1" :entryRowId 1 :role "user"
                      :resultKind "user" :timestamp nil :snippet "needle"
                      :entryLoadable t
                      :context [(:entryId "entry-1" :role "user"
                                 :timestamp nil :text "needle" :match t)])])))
         (line (json-serialize object :false-object :json-false :null-object nil))
         (capability '(:identity test))
         (candidate (pichat-consult--decode-candidate line capability))
         (record (get-text-property 0 'consult--candidate candidate)))
    (should (string-match-p "Named" candidate))
    (should (string-match-p "session-" candidate))
    (should-not (string-match-p "/project\|content\|2026-" candidate))
    (let ((annotation (pichat-consult--candidate-annotation candidate)))
      (should (string-match-p "/project" annotation))
      (should (string-match-p "content" annotation))
      (should (string-match-p "1 hit" annotation)))
    (should (equal "/sessions/session-1.jsonl"
                   (plist-get record :session-file)))
    (should (equal "entry-1" (plist-get record :entry-id)))
    (should (eq capability (plist-get record :archive-capability)))
    (should-not (pichat-consult--decode-candidate "not json" capability))))

(ert-deftest pichat-consult-archive-identities-use-hidden-exact-uniqueness ()
  (let* ((search-fields
          '(:matchKind "content" :score 1.0 :matchCount 1
            :entryId "entry" :entryRowId 1 :entryLoadable t
            :highlightTerms ["project"] :occurrences []))
         (first (append
                 (pichat-test-archive--metadata
                  :sessionId "12345678-first" :sessionFile "/sessions/first.jsonl"
                  :displayTitle "Same title" :title "Same title")
                 search-fields))
         (second (append
                  (pichat-test-archive--metadata
                   :sessionId "12345678-second" :sessionFile "/sessions/second.jsonl"
                   :displayTitle "Same title" :title "Same title")
                  search-fields))
         (capability '(:identity test))
         (candidate-1
          (pichat-consult--decode-candidate
           (json-serialize first :false-object :json-false :null-object nil)
           capability))
         (candidate-2
          (pichat-consult--decode-candidate
           (json-serialize second :false-object :json-false :null-object nil)
           capability))
         (tofu-regexp (format "[%c-%c]" #x100000 (+ #x100000 #xFFFE -1)))
         (visible-1 (replace-regexp-in-string tofu-regexp "" candidate-1))
         (visible-2 (replace-regexp-in-string tofu-regexp "" candidate-2))
         (annotation (pichat-consult--candidate-annotation candidate-1))
         (project-position (string-match "project" annotation)))
    (should (equal visible-1 visible-2))
    (should-not (equal candidate-1 candidate-2))
    (should (equal "12345678-first"
                   (plist-get (pichat-consult--target candidate-1) :session-id)))
    (should (equal "12345678-second"
                   (plist-get (pichat-consult--target candidate-2) :session-id)))
    (when (fboundp 'consult--lookup-candidate)
      (should (equal "12345678-first"
                     (plist-get
                      (consult--lookup-candidate
                       candidate-1 (list candidate-1 candidate-2))
                      :session-id)))
      (should (equal "12345678-second"
                     (plist-get
                      (consult--lookup-candidate
                       candidate-2 (list candidate-1 candidate-2))
                      :session-id))))
    (should project-position)
    (let ((face (get-text-property project-position 'face annotation)))
      (should (or (eq face 'consult-highlight-match)
                  (and (listp face) (memq 'consult-highlight-match face)))))))

(ert-deftest pichat-consult-renders-relation-indicators-and-display-title ()
  (let ((pichat-consult-relation-indicator-style 'unicode))
    (dolist (case '(((:parent-resolution none :child-count 0) "        ")
                    ((:parent-resolution resolved :child-count 0) "↑       ")
                    ((:parent-resolution missing :child-count 0) "↑!      ")
                    ((:parent-resolution ambiguous :child-count 0) "↑?      ")
                    ((:parent-resolution none :child-count 2) "↓2      ")
                    ((:parent-resolution resolved :child-count 1) "↑↓1     ")
                    ((:parent-resolution missing :child-count 1200)
                     "↑!↓999+ ")))
      (should (equal (cadr case)
                     (substring-no-properties
                      (pichat-consult--relation-indicator (car case)))))))
  (let ((pichat-consult-relation-indicator-style 'ascii))
    (should (equal "P!/C999+"
                   (substring-no-properties
                    (pichat-consult--relation-indicator
                     '(:parent-resolution missing :child-count 1200))))))
  (let* ((record
          '(:session-id "session-12345" :latest-activity-at "2026-08-05T23:42:00Z"
            :match-kind recent :cwd "/project" :title "Inherited title"
            :display-title "Branch title" :parent-resolution resolved
            :parent-session-id "parent" :child-count 1 :match-count 0))
         (candidate
          (propertize (pichat-consult--candidate-identity record)
                      'consult--candidate record))
         (annotation (pichat-consult--candidate-annotation candidate)))
    (should (string-match-p "session-" candidate))
    (should (string-match-p "Branch title" candidate))
    (should-not (string-match-p "Inherited title\|/project\|2026-" candidate))
    (should (string-match-p "2026-08-05 23:42" annotation))
    (should (string-match-p "recent" annotation))
    (should (string-match-p "↑↓1" annotation))
    (should (string-match-p "/project" annotation))
    (let* ((row (concat candidate annotation))
           (separator (string-match "│" row)))
      (should (= (+ 12 pichat-sessions-completion-title-width)
                 (string-width (substring row 0 separator))))
      (should (= (+ separator 20) (string-match "recent" row)))
      (should (= (+ separator 29) (string-match "↑↓1" row)))))
  (let* ((record '(:session-id "empty" :display-title "Empty"
                   :match-kind recent :parent-resolution none
                   :child-count 0 :match-count 0))
         (candidate (propertize "Empty · empty" 'consult--candidate record))
         (annotation (pichat-consult--candidate-annotation candidate)))
    (should (string-match-p "│ +recent" (substring-no-properties annotation)))
    (should-not (string-match-p "\n" annotation))))

(ert-deftest pichat-consult-archive-process-uses-capability-transport-and-cwd ()
  (let* ((node (executable-find "node"))
         (transport (make-symbol "remote-transport"))
         (capability (list :transport transport
                           :runtime-cwd "/runtime/project"))
         captured-transport captured-cwd events)
    (should node)
    (cl-letf (((symbol-function 'pichat-transport-make-process)
               (lambda (actual-transport actual-cwd &rest args)
                 (setq captured-transport actual-transport
                       captured-cwd actual-cwd)
                 (apply #'make-process args))))
      (let* ((builder
              (lambda (_input)
                (list node "-e"
                      "console.log(JSON.stringify({sessionId:'fixture'}))")))
             (stage (funcall (pichat-consult--async-archive-process
                              builder capability)
                             (lambda (action) (push action events)))))
        (with-temp-buffer (funcall stage 'setup))
        (funcall stage "query")
        (pichat-test-wait-until
         (lambda ()
           (cl-find-if
            (lambda (event)
              (and (vectorp event) (eq (aref event 1) 'finished)))
            events))
         2 "archive Consult transport process")
        (should (eq transport captured-transport))
        (should (equal "/runtime/project" captured-cwd))))))

(ert-deftest pichat-consult-archive-process-classifies-caller-and-availability-failures ()
  (let ((node (executable-find "node")))
    (should node)
    (dolist (spec '((2 "INVALID_QUERY" nil)
                    (3 "DATABASE_NOT_FOUND" t)))
      (let* ((exit-status (nth 0 spec))
             (code (nth 1 spec))
             (should-invalidate (nth 2 spec))
             (capability '(:session fake))
             events invalidated)
        (cl-letf (((symbol-function 'pichat-archive-invalidate)
                   (lambda (_capability) (setq invalidated t))))
          (let* ((builder
                  (lambda (_input)
                    (list node "-e"
                          (format
                           "console.error(JSON.stringify({code:%S,message:'fixture'}));process.exit(%d)"
                           code exit-status))))
                 (stage (funcall (pichat-consult--async-archive-process
                                  builder capability)
                                 (lambda (action) (push action events)))))
            (with-temp-buffer (funcall stage 'setup))
            (funcall stage "query")
            (pichat-test-wait-until
             (lambda ()
               (cl-find-if
                (lambda (event)
                  (and (vectorp event) (eq (aref event 1) 'failed)))
                events))
             2 "archive Consult process failure")
            (should (eq should-invalidate (and invalidated t)))))))))

(ert-deftest pichat-consult-selects-most-specific-current-archive-project ()
  (let* ((default-directory "/project/subdir/deeper/")
         (projects '((:kind project :cwd "/project" :count 2)
                     (:kind project :cwd "/project/subdir" :count 1)
                     (:kind project :cwd "/other" :count 4)))
         (current (pichat-consult--current-project projects)))
    (should (equal "/project/subdir" (plist-get current :cwd)))))

(ert-deftest pichat-consult-current-project-ignores-global-fallback-session ()
  "A stale global session must not mark its own project as current."
  (let ((pichat-current-session (pichat-session-create :runtime-cwd "/emacs.d/")))
    (cl-letf (((symbol-function 'pichat-session-for-directory)
               (lambda (&optional _directory) nil)))
      ;; No live session for the invoking directory: the unrelated global
      ;; session rooted at /emacs.d/ must never mark that project current.
      (let ((default-directory "/deploy-jobs/"))
        (should-not (pichat-consult--current-project
                     '((:kind project :cwd "/emacs.d" :count 8)
                       (:kind project :cwd "/blog" :count 1)))))
      ;; The invoking directory itself still wins when it is an archive
      ;; project, so plain browsing labels it instead of nothing.
      (let ((default-directory "/deploy-jobs/"))
        (should (equal "/deploy-jobs"
                       (plist-get (pichat-consult--current-project
                                   '((:kind project :cwd "/emacs.d" :count 8)
                                     (:kind project :cwd "/deploy-jobs" :count 4)))
                                  :cwd)))))))

(ert-deftest pichat-consult-preview-highlights-visible-archive-context ()
  (let ((buffer (generate-new-buffer " *pichat-consult-preview-test*"))
        (record '(:title "Search session" :cwd "/project"
                  :session-id "session-1" :match-count 1
                  :highlight-terms ("needle")
                  :occurrences ((:entry-id "user-1"
                                 :context ((:entry-id "user-1" :role "user"
                                            :text "A needle appears")))))))
    (unwind-protect
        (progn
          (pichat-consult--render-preview buffer record)
          (with-current-buffer buffer
            (goto-char (point-min))
            (search-forward "needle")
            (should (memq 'consult-preview-match
                          (ensure-list (get-text-property
                                        (1- (point)) 'face))))))
      (kill-buffer buffer))))

(ert-deftest pichat-consult-preview-state-uses-standard-consult-window-lifecycle ()
  (let ((context-cache (make-hash-table :test #'equal))
        (info-cache (make-hash-table :test #'equal))
        (preview-name "*PiChat Saved Session Preview*")
        events state)
    (puthash "session-1" nil context-cache)
    (puthash "session-1" nil info-cache)
    (when-let ((buffer (get-buffer preview-name)))
      (kill-buffer buffer))
    (unwind-protect
        (cl-letf (((symbol-function 'consult--buffer-preview)
                   (lambda ()
                     (lambda (action candidate)
                       (push (list action candidate) events))))
                  ((symbol-function 'pichat-archive-request)
                   (lambda (&rest _args)
                     (ert-fail "Cached preview unexpectedly requested archive data"))))
          (setq state (pichat-consult--preview-state))
          (funcall state 'setup nil)
          (funcall state 'preview
                   (list :session-id "session-1" :title "Session"
                         :archive-capability
                         (list :preview-cache context-cache
                               :session-info-cache info-cache)))
          (should (buffer-live-p (get-buffer preview-name)))
          (funcall state 'preview nil)
          (funcall state 'exit nil)
          (funcall state 'return nil)
          (should-not (get-buffer preview-name))
          (should (equal (nreverse events)
                         (list (list 'setup nil)
                               (list 'preview preview-name)
                               (list 'preview nil)
                               (list 'exit nil)
                               (list 'return nil)))))
      (when-let ((buffer (get-buffer preview-name)))
        (kill-buffer buffer)))))

(ert-deftest pichat-consult-relation-preview-resolves-nested-and-unresolved-targets ()
  (let* ((context-cache (make-hash-table :test #'equal))
         (info-cache (make-hash-table :test #'equal))
         (capability (list :preview-cache context-cache
                           :session-info-cache info-cache))
         (subject '(:session-id "subject" :display-title "Subject"))
         (resolved
          '(:session-id "subject" :direction child
            :parent-reference-path "/subject.jsonl"
            :parent-resolution resolved :fork-point-status observed
            :fork-position at :selected-entry-id "selected"
            :shared-base-entry-id "selected"
            :related-session
            (:session-id "child" :session-file "/child.jsonl" :cwd "/project"
             :latest-activity-at nil :source-exists t
             :parent-resolution resolved :parent-session-id "subject"
             :child-count 0 :title "Child" :display-title "Child")))
         (unresolved
          '(:session-id "subject" :direction parent
            :parent-reference-path "/missing.jsonl"
            :parent-resolution missing :fork-point-status missing
            :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
            :related-session nil))
         (preview-name "*PiChat Saved Session Preview*") state)
    (puthash "child" nil context-cache)
    (puthash "child" nil info-cache)
    (when-let ((buffer (get-buffer preview-name))) (kill-buffer buffer))
    (unwind-protect
        (cl-letf (((symbol-function 'consult--buffer-preview)
                   (lambda () (lambda (&rest _args))))
                  ((symbol-function 'pichat-archive-request)
                   (lambda (&rest _args)
                     (ert-fail "Relation preview unexpectedly queried archive"))))
          (setq state (pichat-consult--preview-state))
          (funcall state 'setup nil)
          (funcall state 'preview
                   (pichat-consult--relation-candidate
                    resolved capability subject nil))
          (with-current-buffer preview-name
            (should (string-match-p "Selected relation: child of Subject"
                                    (buffer-string)))
            (should (string-match-p "Fork evidence: observed/at"
                                    (buffer-string))))
          (funcall state 'preview
                   (pichat-consult--relation-candidate
                    unresolved capability subject nil))
          (with-current-buffer preview-name
            (should (string-match-p "Unavailable parent session"
                                    (buffer-string)))
            (should (string-match-p "Resolution: missing" (buffer-string))))
          (funcall state 'exit nil))
      (when-let ((buffer (get-buffer preview-name))) (kill-buffer buffer)))))

(ert-deftest pichat-consult-preview-shows-summary-before-and-evidence-after-info ()
  (let ((buffer (generate-new-buffer " *pichat-consult-preview-relations*"))
        (record '(:title "Inherited title" :display-title "Branch title"
                  :cwd "/project" :session-id "child-session" :match-count 0
                  :parent-resolution resolved :parent-session-id "parent-session"
                  :child-count 2 :highlight-terms nil :occurrences nil))
        (info '(:fork-point-status observed :fork-position before)))
    (unwind-protect
        (progn
          (pichat-consult--render-preview buffer record nil nil t)
          (with-current-buffer buffer
            (should (string-match-p "Branch title" (buffer-string)))
            (should (string-match-p "Original title: Inherited title"
                                    (buffer-string)))
            (should (string-match-p
                     "Relation: parent parent-s · 2 direct children"
                     (buffer-string)))
            (should-not (string-match-p "Fork evidence:" (buffer-string))))
          (pichat-consult--render-preview buffer record nil info nil)
          (with-current-buffer buffer
            (should (= 1 (how-many "^Relation:" (point-min) (point-max))))
            (should (= 1 (how-many "^Fork evidence:" (point-min) (point-max))))
            (should (string-match-p "Fork evidence: observed (before)"
                                    (buffer-string)))))
      (kill-buffer buffer))))

(ert-deftest pichat-consult-load-and-jump-enforce-archive-loadability ()
  (let* ((record '(:session-file "/sessions/example.jsonl" :cwd "/project"
                   :source-exists t :entry-id "entry-1" :entry-loadable t))
         (candidate (propertize "candidate" 'consult--candidate record))
         ready listed)
    (cl-letf (((symbol-function 'pichat-sessions-switch-file)
               (lambda (_file _cwd callback) (setq ready callback)))
              ((symbol-function 'pichat-sessions-list)
               (lambda (session entry-id) (setq listed (list session entry-id)))))
      (pichat-consult-jump-to-match candidate)
      (funcall ready 'session)
      (should (equal '(session "entry-1") listed)))
    (should-error
     (pichat-consult-load-session
      '(:session-id "missing" :session-file "/gone" :source-exists nil))
     :type 'user-error)
    (should-error
     (pichat-consult-jump-to-match
      '(:session-id "entry-gone" :session-file "/exists" :source-exists t
        :entry-id "old" :entry-loadable nil))
     :type 'user-error)))

(ert-deftest pichat-consult-direct-relations-action-preserves-selected-record ()
  (let ((record '(:session-id "session-1" :display-title "Branch"
                  :archive-capability (:identity test)))
        remapped-exit raw-exit)
    (let ((pichat-consult--pending-action nil))
      (cl-letf (((symbol-function 'run-hook-with-args-until-success)
                 (lambda (&rest _args) record))
                ((symbol-function 'command-remapping)
                 (lambda (&rest _args)
                   (lambda () (setq remapped-exit t))))
                ((symbol-function 'exit-minibuffer)
                 (lambda () (setq raw-exit t))))
        (pichat-consult-show-selected-relations))
      (should remapped-exit)
      (should-not raw-exit)
      (should (eq #'pichat-consult-show-relations
                  (car pichat-consult--pending-action)))
      (should (eq record (cdr pichat-consult--pending-action)))))
  (should (eq #'pichat-consult-show-selected-relations
              (lookup-key pichat-consult-session-minibuffer-map
                          (kbd "C-c C-r")))))

(ert-deftest pichat-consult-current-session-relations-resolve-and-cache-subject ()
  (let* ((cache (make-hash-table :test #'equal))
         (capability (list :identity 'test :session-info-cache cache))
         (session (pichat-session-make :id "current" :session-file "/current"))
         (subject '(:session-id "current" :session-file "/current"
                    :source-exists t :display-title "Current"
                    :parent-resolution resolved :child-count 1))
         requests opened)
    (let ((pichat-consult--relations-process nil))
      (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
                 (lambda (_capability) t))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (apply function args)))
                ((symbol-function 'pichat-archive-request)
                 (lambda (_capability operation options success _failure)
                   (push (list operation options) requests)
                   (funcall success subject)
                   nil))
                ((symbol-function 'pichat-consult-show-relations)
                 (lambda (record) (push record opened))))
        (pichat-consult-show-current-relations capability session)
        (should (equal 'session-info (caar requests)))
        (should (equal "current" (plist-get (cadar requests) :id)))
        (should (eq subject (gethash "current" cache)))
        (should (equal "current" (plist-get (car opened) :session-id)))
        (should (eq capability
                    (plist-get (car opened) :archive-capability)))
        (setq opened nil)
        (cl-letf (((symbol-function 'pichat-archive-request)
                   (lambda (&rest _args)
                     (ert-fail "Cached current session lookup unexpectedly ran"))))
          (pichat-consult-show-current-relations capability session))
        (should (= 1 (length opened)))))))

(ert-deftest pichat-consult-embark-relations-preserves-complete-candidate ()
  (skip-unless (and (require 'embark nil t)
                    (fboundp 'embark--run-around-action-hooks)))
  (let* ((capability '(:identity test))
         (subject '(:session-id "subject" :display-title "Subject"))
         (relation
          '(:session-id "subject" :direction child
            :parent-reference-path "/subject.jsonl"
            :parent-resolution resolved :fork-point-status none
            :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
            :related-session
            (:session-id "child" :session-file "/child.jsonl" :cwd "/project"
             :latest-activity-at nil :source-exists t
             :parent-resolution resolved :child-count 0
             :title "Child" :display-title "Child")))
         (candidate (pichat-consult--relation-candidate
                     relation capability subject 'browse-context))
         (opaque (pichat-consult--target candidate))
         (target (list :type 'pichat-session :target candidate))
         received)
    (cl-letf (((symbol-function 'pichat-consult-show-relations)
               (lambda (value)
                 (interactive "sSession: ")
                 (setq received value))))
      (embark--run-around-action-hooks
       'pichat-consult-show-relations target t)
      (should (eq opaque received))
      (should (eq relation (pichat-consult--candidate-relation received)))
      (should (equal "child"
                     (plist-get (pichat-consult--candidate-record received)
                                :session-id))))))

(ert-deftest pichat-consult-relation-candidates-preserve-records-and-summary ()
  (let* ((capability '(:identity test))
         (subject '(:session-id "subject" :display-title "Subject branch"))
         (relation
          '(:session-id "subject" :direction parent
            :parent-reference-path "/parent.jsonl"
            :parent-resolution resolved :fork-point-status observed
            :fork-position before :selected-entry-id "selected"
            :shared-base-entry-id nil
            :related-session
            (:session-id "parent-session" :session-file "/parent.jsonl"
             :cwd "/project" :latest-activity-at "2026-08-05T23:10:00Z"
             :source-exists t :parent-resolution none :child-count 2
             :title "Parent old" :display-title "Parent title")))
         (candidate (pichat-consult--relation-candidate
                     relation capability subject 'parent-context))
         (target (pichat-consult--target candidate))
         (record (pichat-consult--candidate-record candidate)))
    (should (string-match-p "parent-s.*Parent title" candidate))
    (should-not (string-match-p
                 "parent.*2026-08-05\|↓2\|resolved\|observed/before"
                 candidate))
    (let ((annotation (pichat-consult--relation-annotation candidate)))
      (should (string-match-p "parent" annotation))
      (should (string-match-p "2026-08-05 23:10" annotation))
      (should (string-match-p "↓2" annotation))
      (should (string-match-p "resolved" annotation))
      (should (string-match-p "observed/before" annotation)))
    (should (eq relation (pichat-consult--candidate-relation candidate)))
    (should (eq (plist-get relation :related-session)
                (plist-get (plist-get target :relation) :related-session)))
    (should (equal "parent-session" (plist-get record :session-id)))
    (should (eq capability (plist-get record :archive-capability)))
    (should (eq 'parent-context
                (pichat-consult--candidate-context candidate)))
    (should (eq ?p (get-text-property 0 'consult--type candidate)))))

(ert-deftest pichat-consult-related-actions-use-nested-record-and-loadability ()
  (let* ((capability '(:identity test))
         (subject '(:session-id "subject" :display-title "Subject"))
         (available
          '(:session-id "subject" :direction child
            :parent-reference-path "/subject.jsonl"
            :parent-resolution resolved :fork-point-status derived
            :fork-position nil :selected-entry-id nil
            :shared-base-entry-id "base"
            :related-session
            (:session-id "child" :session-file "/child.jsonl" :cwd "/child"
             :latest-activity-at nil :source-exists t
             :parent-resolution resolved :child-count 0
             :title "Child" :display-title "Child")))
         (unresolved
          '(:session-id "subject" :direction parent
            :parent-reference-path "/missing.jsonl"
            :parent-resolution missing :fork-point-status missing
            :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
            :related-session nil))
         (available-candidate
          (pichat-consult--relation-candidate
           available capability subject nil))
         (missing-candidate
          (pichat-consult--relation-candidate
           unresolved capability subject nil))
         switched ready listed)
    (cl-letf (((symbol-function 'pichat-sessions-switch-file)
               (lambda (file cwd &optional callback)
                 (setq switched (list file cwd) ready callback)))
              ((symbol-function 'pichat-sessions-list)
               (lambda (session &optional entry-id)
                 (setq listed (list session entry-id)))))
      (pichat-consult-load-session available-candidate)
      (should (equal '("/child.jsonl" "/child") switched))
      (pichat-consult-jump-to-match available-candidate)
      (funcall ready 'session)
      (should (equal '(session nil) listed))
      (should-error (pichat-consult-load-session missing-candidate)
                    :type 'user-error)
      (should-error (pichat-consult-jump-to-match missing-candidate)
                    :type 'user-error))))

(ert-deftest pichat-consult-contextual-selection-preserves-browser-open-policy ()
  (let* ((opened nil)
         (context
          (list :kind 'archive
                :selection-function
                (lambda (file cwd) (push (list file cwd) opened))))
         (candidate
          (list :session-id "saved" :session-file "/saved.jsonl" :cwd "/project"
                :source-exists t :browse-context context)))
    (cl-letf (((symbol-function 'pichat-sessions-switch-file)
               (lambda (&rest _args)
                 (ert-fail "contextual selection mutated the active runtime")))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (&rest _args)
                 (ert-fail "contextual selection discarded manager policy"))))
      (pichat-consult-load-session candidate)
      (pichat-consult-open-session-independently candidate)
      (should-error (pichat-consult-jump-to-match candidate) :type 'user-error))
    (should (equal '(("/saved.jsonl" "/project")
                     ("/saved.jsonl" "/project"))
                   opened))))

(ert-deftest pichat-consult-load-session-preserves-unrelated-active-runtime ()
  "Plain browse from a directory without a live session opens independently."
  (let* ((candidate
          '(:session-id "saved" :session-file "/project/saved.jsonl"
            :cwd "/project" :source-exists t))
         independent switched)
    (cl-letf (((symbol-function 'pichat-session-for-directory)
               (lambda (&optional _directory) nil))
              ((symbol-function 'pichat-session-current)
               (lambda (&optional _session) 'stale-global-session))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (file &rest keys)
                 (setq independent
                       (list file
                             (plist-get keys :cwd)
                             (plist-get keys :owner-directory)))))
              ((symbol-function 'pichat-sessions-switch-file)
               (lambda (&rest _args)
                 (ert-fail "plain browse replaced an unrelated active runtime"))))
      (pichat-consult-load-session candidate)
      (should (equal '("/project/saved.jsonl" "/project" "/project")
                     independent))))
  ;; With a live session for the invoking directory, the switch path is kept.
  (let* ((candidate
          '(:session-id "saved" :session-file "/project/saved.jsonl"
            :cwd "/project" :source-exists t))
         switched)
    (cl-letf (((symbol-function 'pichat-session-for-directory)
               (lambda (&optional _directory) 'live-directory-session))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (&rest _args)
                 (ert-fail "live directory session should use the switch path")))
              ((symbol-function 'pichat-sessions-switch-file)
               (lambda (file cwd &optional _callback)
                 (setq switched (list file cwd)))))
      (pichat-consult-load-session candidate)
      (should (equal '("/project/saved.jsonl" "/project") switched)))))

(ert-deftest pichat-consult-relation-reader-is-bounded-narrowable-and-record-backed ()
  (let* ((capability '(:identity test))
         (subject '(:session-id "subject" :display-title "Subject"))
         (relations
          '((:session-id "subject" :direction parent
             :parent-reference-path "/missing.jsonl"
             :parent-resolution missing :fork-point-status missing
             :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
             :related-session nil)
            (:session-id "subject" :direction child
             :parent-reference-path "/subject.jsonl"
             :parent-resolution resolved :fork-point-status none
             :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
             :related-session
             (:session-id "child" :session-file nil :cwd "/project"
              :latest-activity-at nil :source-exists nil
              :parent-resolution resolved :child-count 0
              :title "Child" :display-title "Child"))))
         collection options)
    (cl-letf (((symbol-function 'pichat-consult--preview-state)
               (lambda () #'ignore))
              ((symbol-function 'consult--read)
               (lambda (items &rest args)
                 (setq collection items options args)
                 nil)))
      (pichat-consult--read-relations capability subject relations nil))
    (should (= 2 (length collection)))
    (should (eq 'pichat-session (plist-get options :category)))
    (should (eq t (plist-get options :require-match)))
    (should-not (plist-get options :sort))
    (should (plist-get options :narrow))
    (should (eq #'pichat-consult--relation-annotation
                (plist-get options :annotate)))
    (should (eq 'missing
                (plist-get (pichat-consult--candidate-relation (car collection))
                           :parent-resolution)))
    (should (string-match-p "missing parent:" (car collection)))
    (should-not (string-match-p "unavailable\|↑!" (car collection)))
    (let ((annotation
           (pichat-consult--relation-annotation (car collection))))
      (should (string-match-p "↑!" annotation))
      (should (string-match-p "unavailable" annotation)))))

(ert-deftest pichat-consult-relation-lookup-covers-cache-request-empty-stale-and-failure ()
  (let* ((cache (make-hash-table :test #'equal))
         (capability (list :identity 'test :relations-cache cache))
         (record (list :session-id "subject" :display-title "Subject"
                       :archive-capability capability))
         (relation
          '(:session-id "subject" :direction parent
            :parent-reference-path "/parent.jsonl"
            :parent-resolution resolved :fork-point-status none
            :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
            :related-session
            (:session-id "parent" :session-file "/parent.jsonl" :cwd "/p"
             :latest-activity-at nil :source-exists t
             :parent-resolution none :child-count 0
             :title "Parent" :display-title "Parent")))
         (key (list "subject" "both" pichat-consult-relations-limit))
         reads requests failure-callback)
    (let ((pichat-consult--relations-process nil))
      (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
                 (lambda (_capability) t))
                ((symbol-function 'pichat-consult--read-relations)
                 (lambda (_capability _subject rows _parent)
                   (push rows reads)))
                ((symbol-function 'pichat-archive-request)
                 (lambda (&rest _args)
                   (ert-fail "Cached relation lookup unexpectedly ran"))))
        (puthash key (list relation) cache)
        (pichat-consult-show-relations record)
        (should (equal (list relation) (car reads)))))
    (clrhash cache)
    (setq reads nil)
    (let ((pichat-consult--relations-process nil))
      (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
                 (lambda (_capability) t))
                ((symbol-function 'pichat-consult--read-relations)
                 (lambda (_capability _subject rows _parent)
                   (push rows reads)))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest args)
                   (apply function args)))
                ((symbol-function 'pichat-archive-request)
                 (lambda (_capability operation options success failure)
                   (push (list operation options) requests)
                   (setq failure-callback failure)
                   (funcall success (list relation))
                   nil)))
        (pichat-consult-show-relations record)
        (should (equal 'relations (caar requests)))
        (should (= pichat-consult-relations-limit
                   (plist-get (cadar requests) :limit)))
        (should (equal (list relation) (gethash key cache)))
        (should (equal (list relation) (car reads)))
        (clrhash cache)
        (setq reads nil)
        (funcall failure-callback '(:message "fixture failure"))
        (should-not reads)
        (should-not (gethash key cache))))
    (puthash key (list relation) cache)
    (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
               (lambda (_capability) nil))
              ((symbol-function 'pichat-consult--read-relations)
               (lambda (&rest _args) (ert-fail "Stale cache was opened"))))
      (should-error (pichat-consult-show-relations record) :type 'user-error))
    (let (consult-called resumed)
      (cl-letf (((symbol-function 'consult--read)
                 (lambda (&rest _args) (setq consult-called t)))
                ((symbol-function 'pichat-consult--schedule-resume)
                 (lambda (context) (setq resumed context))))
        (pichat-consult--read-relations capability record nil 'parent-context))
      (should-not consult-called)
      (should (eq 'parent-context resumed)))))

(ert-deftest pichat-consult-archive-resume-reopens-a-rerunnable-project-search ()
  (let* ((capability '(:identity fixture-capability))
         (project '(:cwd "/fixture/project"))
         (selection-function (lambda (_file _cwd)))
         (context (list :kind 'archive :capability capability :project project
                        :input "restored query"
                        :selection-function selection-function))
         received)
    (cl-letf (((symbol-function 'pichat-archive-capability-current-p)
               (lambda (value) (eq value capability)))
              ((symbol-function 'pichat-consult--run-project-search)
               (lambda (&rest args) (setq received args))))
      (pichat-consult--resume-context context))
    (should (equal (list capability project "restored query"
                         selection-function)
                   received))))

(ert-deftest pichat-consult-relation-quit-resumes-one-browser-level ()
  (let ((capability '(:identity test))
        (subject '(:session-id "subject" :display-title "Subject"))
        (relations
         '((:session-id "subject" :direction parent
            :parent-reference-path "/missing"
            :parent-resolution missing :fork-point-status missing
            :fork-position nil :selected-entry-id nil :shared-base-entry-id nil
            :related-session nil)))
        resumed)
    (cl-letf (((symbol-function 'pichat-consult--preview-state)
               (lambda () #'ignore))
              ((symbol-function 'consult--read)
               (lambda (&rest _args) (signal 'quit nil)))
              ((symbol-function 'pichat-consult--schedule-resume)
               (lambda (context) (setq resumed context))))
      (pichat-consult--read-relations
       capability subject relations 'parent-context))
    (should (eq 'parent-context resumed))))

(ert-deftest pichat-sessions-related-browser-discovers-for-active-persisted-source ()
  (let ((session (pichat-session-make :id "current" :session-file "/current"))
        success failure opened messages)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-session-current)
               (lambda (&optional _session) session))
              ((symbol-function 'pichat-archive-discover)
               (lambda (owner _buffer ok unavailable)
                 (should (eq session owner))
                 (setq success ok failure unavailable)))
              ((symbol-function 'pichat-consult-show-current-relations)
               (lambda (capability owner)
                 (setq opened (list capability owner))))
              ((symbol-function 'message)
               (lambda (&rest args) (push (apply #'format args) messages))))
      (with-temp-buffer
        (pichat-sessions-browse-related))
      (funcall success 'capability)
      (funcall failure '(:message "late failure")))
    (should (equal (list 'capability session) opened))
    (should-not messages)
    (should (eq #'pichat-sessions-browse-related
                (lookup-key pichat-chat-mode-map (kbd "C-c C-r"))))))

(ert-deftest pichat-sessions-related-browser-requires-persisted-identity ()
  (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t)))
    (dolist (session (list nil
                           (pichat-session-make :id nil :session-file "/source")
                           (pichat-session-make :id "current" :session-file nil)))
      (cl-letf (((symbol-function 'pichat-session-current)
                 (lambda (&optional _owner) session)))
        (should-error (pichat-sessions-browse-related) :type 'user-error)))))

(ert-deftest pichat-sessions-browser-lazily-loads-consult-before-routing ()
  (let ((original-featurep (symbol-function 'featurep))
        required required-feature discovered discovered-session basic)
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature &optional subfeature)
                 (and (not (eq feature 'pichat-consult))
                      (funcall original-featurep feature subfeature))))
              ((symbol-function 'require)
               (lambda (feature &optional _filename _noerror)
                 (setq required t required-feature feature)))
              ((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-session-current) (lambda (&optional _s) nil))
              ((symbol-function 'pichat-archive-discover)
               (lambda (session _buffer _ok _unavailable)
                 (setq discovered t discovered-session session)))
              ((symbol-function 'pichat-sessions-browse-files-basic)
               (lambda () (setq basic t))))
      (pichat-sessions-browse-files))
    (should required)
    (should (eq required-feature 'pichat-consult))
    (should discovered)
    (should-not discovered-session)
    (should-not basic)))

(ert-deftest pichat-sessions-browser-prefix-and-availability-use-basic-picker ()
  (let (discover basic)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-archive-discover)
               (lambda (&rest _args) (setq discover t)))
              ((symbol-function 'pichat-sessions-browse-files-basic)
               (lambda () (setq basic t))))
      (pichat-sessions-browse-files t)
      (should basic)
      (should-not discover)))
  (let (basic)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () nil))
              ((symbol-function 'pichat-sessions-browse-files-basic)
               (lambda () (setq basic t))))
      (pichat-sessions-browse-files)
      (should basic))))

(ert-deftest pichat-sessions-browser-discovery-continues-exactly-once ()
  (let ((session (pichat-session-make)) archive basic success failure)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-session-current) (lambda (&optional _s) session))
              ((symbol-function 'pichat-archive-discover)
               (lambda (_session _buffer ok unavailable)
                 (setq success ok failure unavailable)))
              ((symbol-function 'pichat-consult-sessions)
               (lambda (capability &optional _initial)
                 (setq archive capability)))
              ((symbol-function 'pichat-sessions-browse-files-basic)
               (lambda () (cl-incf basic))))
      (pichat-sessions-browse-files)
      (funcall success 'capability)
      (funcall failure 'unavailable)
      (should (eq archive 'capability))
      (should-not basic))))

(ert-deftest pichat-independent-browser-uses-consult-with-explicit-runtime-and-policy ()
  (let* ((session (pichat-session-make))
         (owner-scope '("project:/owner/" "/owner/" "owner@test"))
         (display-function #'ignore)
         discover-buffer success unavailable consult-call selection opened basic)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-archive-discover)
               (lambda (owner buffer ok fallback)
                 (should (eq session owner))
                 (setq discover-buffer buffer success ok unavailable fallback)))
              ((symbol-function 'pichat-consult-sessions)
               (lambda (capability &optional initial selection-function)
                 (setq consult-call (list capability initial)
                       selection selection-function)))
              ((symbol-function 'pichat-sessions--choose-basic-file)
               (lambda ()
                 (cl-incf basic)
                 '("/basic.jsonl" "/basic")))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (file &rest args)
                 (setq opened (cons file args)))))
      (with-temp-buffer
        (let ((expected-buffer (current-buffer)))
          (pichat-sessions-browse-files-independently
           :session session :owner-directory "/owner/" :owner-scope owner-scope
           :display-function display-function)
          (should (eq expected-buffer discover-buffer))))
      (funcall success 'capability)
      (should (equal '(capability nil) consult-call))
      (should (functionp selection))
      (funcall selection "/saved.jsonl" "/saved-cwd")
      (should (equal "/saved.jsonl" (car opened)))
      (should (equal "/saved-cwd" (plist-get (cdr opened) :cwd)))
      (should (equal "/owner/" (plist-get (cdr opened) :owner-directory)))
      (should (equal owner-scope (plist-get (cdr opened) :owner-scope)))
      (should (eq display-function
                  (plist-get (cdr opened) :display-function)))
      (funcall unavailable 'late-failure)
      (should-not basic))))

(ert-deftest pichat-independent-browser-archive-failure-falls-back-once ()
  (let (success unavailable opened consult)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-archive-discover)
               (lambda (_owner _buffer ok fallback)
                 (setq success ok unavailable fallback)))
              ((symbol-function 'pichat-consult-sessions)
               (lambda (&rest _args) (setq consult t)))
              ((symbol-function 'pichat-sessions--choose-basic-file)
               (lambda () '("/basic.jsonl" "/basic")))
              ((symbol-function 'pichat-sessions-open-file-independently)
               (lambda (file &rest _args) (push file opened))))
      (pichat-sessions-browse-files-independently)
      (funcall unavailable 'not-available)
      (funcall success 'late-capability))
    (should (equal '("/basic.jsonl") opened))
    (should-not consult)))

(ert-deftest pichat-sessions-browser-no-live-session-falls-back-without-starting-pi ()
  (let (basic started)
    (cl-letf (((symbol-function 'pichat-consult-available-p) (lambda () t))
              ((symbol-function 'pichat-session-current) (lambda (&optional _s) nil))
              ((symbol-function 'pichat-start-session)
               (lambda (&rest _args) (setq started t)))
              ((symbol-function 'pichat-archive-discover)
               (lambda (_session _buffer _ok unavailable)
                 (funcall unavailable '(:reason no-live-session))))
              ((symbol-function 'pichat-sessions-browse-files-basic)
               (lambda () (setq basic t))))
      (pichat-sessions-browse-files)
      (should basic)
      (should-not started))))

(provide 'pichat-test-consult)
;;; pichat-test-consult.el ends here
