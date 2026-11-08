;;; pichat-test-session-manager.el --- Global runtime manager tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Observable registry, manager, and independent-source behavior.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-manager-open-reuses-owned-chat-after-source-id-change ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          first second)
      (unwind-protect
          (progn
            (setf (pichat-session-id session) "old-source")
            (setq first (pichat-chat-open session))
            ;; Match a verified restart that has committed a new Pi session ID
            ;; while retaining the existing chat and its old display name.
            (setf (pichat-session-id session) "new-source")
            (with-current-buffer first
              (setq pichat-chat--source-session-id "new-source")
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update" :message
                 (:role "assistant" :content
                  ((:type "text" :text "Progress before device switch")))))
              (pichat-chat--project-live-tail))
            (let ((handlers (copy-sequence
                             (gethash 'rpc-event (pichat-session-event-handlers session)))))
              (dotimes (_ 3)
                (pichat-session-manager-display-chat-current-tab session)
                (setq second (pichat-session-buffer session))
                (should (eq first second)))
              (should (equal handlers (gethash 'rpc-event
                                               (pichat-session-event-handlers session)))))
            (should (string-match-p "Progress before device switch"
                                    (with-current-buffer second (buffer-string))))
            (should (equal (buffer-name second) (pichat-chat-buffer-name session))))
        (dolist (b (delete-dups (list first second)))
          (when (buffer-live-p b) (kill-buffer b)))))))

(ert-deftest pichat-manager-open-new-chat-synchronizes-existing-history ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer requests)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-backend-get-transcript)
                     (lambda (_session cursor success _failure)
                       (push cursor requests)
                       (funcall success
                                '(:data (:entries
                                         ((:id "earlier" :parentId nil :type "message"
                                           :message (:role "user" :content
                                                     ((:type "text" :text "Earlier history")))))
                                         :leafId "earlier")) session)
                       "initial-history")))
            (pichat-session-manager-display-chat-current-tab session)
            (setq buffer (pichat-session-buffer session))
            (should (equal '(nil) requests))
            (should (string-match-p "Earlier history"
                                    (with-current-buffer buffer (buffer-string))))
            (pichat-session-manager-display-chat-current-tab session)
            (should (= 1 (length requests))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-manager-open-stopped-chat-does-not-request-rpc ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make :cwd default-directory :state 'stopped))
          (pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (cl-letf (((symbol-function 'pichat-backend-get-transcript)
                     (lambda (&rest _) (ert-fail "Stopped runtime requested RPC"))))
            (pichat-session-manager-display-chat-current-tab session)
            (setq buffer (pichat-session-buffer session))
            (should (eq buffer (pichat-chat-owned-buffer session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-distinct-runtimes-never-share-a-display-name-buffer ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (peer (pichat-session-make :cwd default-directory))
          first second)
      (unwind-protect
          (progn
            (setf (pichat-session-id session) "same-source"
                  (pichat-session-id peer) "same-source")
            (setq first (pichat-chat-open session)
                  second (pichat-chat-open peer))
            (should-not (eq first second))
            (should (eq first (pichat-chat-owned-buffer session)))
            (should (eq second (pichat-chat-owned-buffer peer))))
        (dolist (b (delete-dups (list first second)))
          (when (buffer-live-p b) (kill-buffer b)))))))

(ert-deftest pichat-chat-nonowning-legacy-buffer-does-not-consume-events ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          old owner received)
      (unwind-protect
          (progn
            (setq old (pichat-chat-open session))
            ;; Simulate duplicate subscriptions retained by a pre-fix Emacs.
            (setq owner (generate-new-buffer " *PiChat duplicate fixture*"))
            (with-current-buffer owner
              (pichat-chat-mode)
              (setq pichat-chat-session session)
              (setf (pichat-session-buffer session) owner)
              (pichat-chat--install-handlers session owner))
            (cl-letf (((symbol-function 'pichat-chat--on-rpc-event)
                       (lambda (&rest _) (push (current-buffer) received))))
              (pichat-emit session 'rpc-event :raw '(:type "message_end")))
            (should (equal (list owner) received)))
        (dolist (b (list old owner))
          (when (buffer-live-p b) (kill-buffer b)))))))

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

(ert-deftest pichat-restart-restores-preference-only-with-unchanged-scope-revision ()
  (pichat-test-with-clean-state
    (let ((original (pichat-session-make :cwd "/tmp/"))
          (peer (pichat-session-make :cwd "/tmp/"))
          (elsewhere (pichat-session-make :cwd "/tmp/other/"))
          ticket)
      (pichat-register-session original '("scope" "/tmp/" "scope"))
      (pichat-register-session peer '("scope" "/tmp/" "scope"))
      (pichat-register-session elsewhere '("other" "/tmp/other/" "other"))
      (cl-letf (((symbol-function 'pichat-session-alive-p)
                 (lambda (_s) t)))
        (pichat-set-default-session original)
        (setq ticket (pichat--suspend-default-for-restart original))
        (should-not (pichat-session-default-p original))
        (pichat-set-default-session elsewhere)
        (should (pichat--restore-default-after-restart original ticket))
        (should (pichat-session-default-p original))
        (setq ticket (pichat--suspend-default-for-restart original))
        (pichat-set-default-session peer)
        (pichat-clear-default-session peer)
        (should-not (pichat--restore-default-after-restart original ticket))
        (should-not (pichat-session-default-p original))))))

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

(ert-deftest pichat-session-manager-diagnostics-inspects-selected-stopped-runtime ()
  (pichat-test-with-clean-state
    (let* ((selected (pichat-register-session (pichat-session-make :state 'stopped)))
           (other (pichat-register-session (pichat-session-make :state 'error)))
           (pichat-current-session other)
           report)
      (unwind-protect
          (with-temp-buffer
            (pichat-session-manager-mode)
            (setq tabulated-list-entries
                  (list (pichat-session-manager--entry selected)
                        (pichat-session-manager--entry other)))
            (tabulated-list-print)
            (goto-char (point-min))
            (should (equal (tabulated-list-get-id)
                           (pichat-session-runtime-id selected)))
            (cl-letf (((symbol-function 'pichat-view-display) #'ignore)
                      ((symbol-function 'pichat-rpc-send)
                       (lambda (&rest _) (ert-fail "Manager diagnostics issued RPC"))))
              (setq report (call-interactively (key-binding (kbd "D")))))
            (with-current-buffer report
              (should (eq selected pichat-diagnostics--owner))
              (should (eq major-mode 'pichat-diagnostics-mode))
              (should (string-match-p "cached snapshot" (buffer-string))))
            ;; Capability rejection uses the unified operation's name, not
            ;; transport-only wording, and does not silently select OTHER.
            (setf (pichat-session-backend selected) 'unsupported)
            (let ((err (should-error (pichat-session-manager-diagnostics)
                                     :type 'user-error)))
              (should (string-match-p "Cached diagnostics is unavailable"
                                      (error-message-string err)))))
        (when (buffer-live-p report) (kill-buffer report))))))

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
      (let ((entry (pichat-session-manager--entry session)))
        (should (equal (pichat-session-runtime-id session) (car entry)))
        (dolist (pair '(("Name" . "Improve session manager")
                        ("Project" . "emacs.mine") ("Status" . "idle")
                        ("Model" . "openai/gpt-5.4") ("" . "★")))
          (should (equal (cdr pair)
                         (pichat-session-manager--sort-value entry (car pair))))))
      (cl-letf (((symbol-function 'pop-to-buffer) (lambda (&rest _args) nil)))
        (setq buffer (pichat-session-manager)))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal '("" "ID" "Name" "Status" "Project")
                           (seq-take (mapcar #'car (append tabulated-list-format nil)) 5)))
            (should (equal "Project" (car pichat-session-manager--logical-sort))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-runtime-id-links-chat-and-survives-source-changes ()
  (pichat-test-with-clean-state
    (let* ((pichat-session--runtime-counter 98)
           (session (pichat-session-make :owner-scope-key "global"))
           (next (pichat-session-make :owner-scope-key "global")))
      (pichat-register-session session)
      (pichat-register-session next)
      (should (equal "*pi:99*" (pichat-chat-buffer-name session)))
      (dolist (state '((:sessionId "source-a" :sessionName "First")
                       (:sessionId "source-b" :sessionName "Renamed")))
        (pichat-session-apply-rpc-state session state)
        (should (equal "99" (pichat-session-manager--field session "ID")))
        (should (equal (plist-get state :sessionId)
                       (pichat-session-manager--field session "Pi source ID"))))
      (with-temp-buffer
        (pichat-session-manager-mode)
        (cl-letf (((symbol-function 'pichat-session-manager--display-width)
                   (lambda () 12)))
          (setq pichat-session-manager--logical-sort '("ID"))
          (pichat-session-manager-refresh)
          (should (equal '("" "ID" "Name")
                         (mapcar #'car (append tabulated-list-format nil))))
          (should (= 3 (cadr (assoc "ID" (append tabulated-list-format nil)))))
          (should (equal '("99" "100")
                         (mapcar (lambda (entry)
                                   (pichat-session-manager--sort-value entry "ID"))
                                 tabulated-list-entries)))
          (should (string-match-p "99" (buffer-string))))))))

(ert-deftest pichat-session-manager-compact-row-handles-global-unnamed-source ()
  (let* ((session (pichat-session-make
                   :state 'starting
                   :owner-scope-key "global"
                   :owner-scope-label "global"))
         (entry (pichat-session-manager--entry session)))
    (should (equal "global" (pichat-session-manager--sort-value entry "Project")))
    (should (equal "starting" (pichat-session-manager--sort-value entry "Status")))
    (should (string-match-p "\\`[a-z]+ [a-z]+\\'"
                            (pichat-session-manager--sort-value entry "Name")))))

(ert-deftest pichat-session-manager-identifies-captured-preset ()
  (let* ((session (pichat-session-make
                   :preset-name 'manual :preset-spec (pichat-presets-resolve 'manual)))
         (entry (pichat-session-manager--entry session)))
    (should (equal "manual" (pichat-session-manager--sort-value entry "Preset")))
    (with-temp-buffer
      (pichat-session-manager-mode)
      (pichat-session-manager--render-preview session nil)
      (unwind-protect
          (with-current-buffer pichat-session-manager-preview-buffer-name
            (should (string-match-p "Preset: manual" (buffer-string)))
            (should (string-match-p "Built-in tools: read" (buffer-string))))
        (when-let* ((buffer (get-buffer pichat-session-manager-preview-buffer-name)))
          (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-aliases-follow-runtime-not-source-or-name ()
  (let ((pichat-session-manager--aliases (make-hash-table :test #'equal))
        (pichat-session-manager--reserved-aliases (make-hash-table :test #'equal))
        (session (pichat-session-make :id "source-a")))
    (let ((alias (pichat-session-manager--row-session-name session)))
      (should (string-match-p "[a-z]+ [a-z]+" alias))
      (setf (pichat-session-name session) "Explicit")
      (should (equal "Explicit" (pichat-session-manager--row-session-name session)))
      (pichat-session-apply-rpc-state session '(:sessionId "source-b" :sessionName "  "))
      (should (equal alias (pichat-session-manager--row-session-name session)))
      (with-temp-buffer (pichat-session-manager-mode))
      (with-temp-buffer
        (pichat-session-manager-mode)
        (should (equal alias (pichat-session-manager--row-session-name session))))
      (should (equal "  " (pichat-session-name session))))))

(ert-deftest pichat-session-manager-alias-allocation-is-bounded-and-reserves-forgotten-labels ()
  (let ((pichat-session-manager--adjectives ["calm"])
        (pichat-session-manager--nouns ["fox" "owl"])
        (pichat-session-manager--aliases (make-hash-table :test #'equal))
        (pichat-session-manager--reserved-aliases (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'random) (lambda (&rest _) 0)))
      (should (equal "calm fox" (pichat-session-manager--alias "runtime-a")))
      (should (equal "calm owl" (pichat-session-manager--alias "runtime-b")))
      (should-not (pichat-session-manager--alias "runtime-c"))
      (should-not (pichat-session-manager--alias nil))
      (let ((session (pichat-session-make :id "last-resort")))
        (should (equal "last-resort" (pichat-session-manager--row-session-name session)))
        (setf (pichat-session-id session) nil)
        (should (equal (pichat-session-runtime-id session)
                       (pichat-session-manager--row-session-name session))))
      (should (= 2 (hash-table-count pichat-session-manager--reserved-aliases))))))

(ert-deftest pichat-session-manager-explicit-names-may-match-generated-aliases ()
  (let* ((session (pichat-session-make))
         (alias (pichat-session-manager--row-session-name session))
         (named (pichat-session-make :name alias)))
    (should (equal alias (pichat-session-manager--row-session-name named)))
    (should-not (equal (pichat-session-runtime-id session)
                       (pichat-session-runtime-id named)))))

(ert-deftest pichat-session-manager-responsive-rows-fit-all-width-budgets ()
  (pichat-test-with-clean-state
    (let ((session (pichat-session-make
                    :name (concat "Long\n\t" (make-string 80 ?界))
                    :model (make-string 80 ?界)
                    :preset-name 'a-very-long-preset-name
                    :owner-directory "/tmp/a-very-long-project-directory/")))
      (pichat-register-session session)
      (with-temp-buffer
        (pichat-session-manager-mode)
        (cl-loop for width from 1 to 240 do
                 (cl-letf (((symbol-function 'pichat-session-manager--display-width)
                            (lambda () width)))
                   (pichat-session-manager-refresh)
                   (should (= 1 (count-lines (point-min) (point-max))))
                   (should (<= (string-width (string-trim-right (buffer-string))) width))
                   (should (equal "ID"
                                  (car (seq-find (lambda (c) (not (equal "" (car c))))
                                                 tabulated-list-format))))))))))

(ert-deftest pichat-session-manager-truncated-cells-retain-full-help-and-input-warning ()
  (let ((session (pichat-session-make :name (make-string 80 ?x)
                                     :state 'a-very-long-runtime-status)))
    (with-temp-buffer
      (pichat-session-manager-mode)
      (cl-letf (((symbol-function 'pichat-chat-pending-user-input-count) (lambda (_) 1)))
        (let* ((entry (pichat-session-manager--entry session))
               (columns (append tabulated-list-format nil))
               (status (aref (cadr entry) (cl-position "Status" columns :key #'car :test #'equal)))
               (name (aref (cadr entry) (cl-position "Name" columns :key #'car :test #'equal))))
          (should (string-suffix-p "!" status))
          (should (<= (string-width status) 11))
          (should (eq 'warning (get-text-property (1- (length status)) 'face status)))
          (should (equal "a-very-long-runtime-status!" (get-text-property 0 'help-echo status)))
          (should (equal (pichat-session-name session) (get-text-property 0 'help-echo name))))))))

(ert-deftest pichat-session-manager-width-excludes-hidden-frames-across-terminals ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'get-buffer-window-list)
               (lambda (_buffer _minibuffer frames)
                 (should (eq t frames)) '(wide narrow hidden)))
              ((symbol-function 'window-frame) #'identity)
              ((symbol-function 'frame-visible-p) (lambda (frame) (not (eq frame 'hidden))))
              ((symbol-function 'window-body-width)
               (lambda (window) (pcase window ('wide 120) ('narrow 40) ('hidden 20)))))
      (should (= 40 (pichat-session-manager--display-width))))))

(ert-deftest pichat-session-manager-column-admission-preserves-priority-and-useful-name ()
  (let ((last-count 0))
    (cl-loop for width from 1 to 240 do
             (let* ((layout (append (pichat-session-manager--layout width) nil))
                    (names (delete "" (mapcar #'car layout))))
               (should (equal names (seq-take (mapcar #'car pichat-session-manager--columns)
                                            (length names))))
               (should (>= (length names) last-count))
               (when (> (length names) 2)
                 (should (>= (cadr (assoc "Name" layout)) 16)))
               (when-let* ((name (assoc "Name" layout)))
                 (should (<= (cadr name) 40)))
               (setq last-count (length names))))))

(ert-deftest pichat-session-manager-hidden-sort-and-native-sort-use-full-values ()
  (pichat-test-with-clean-state
    (let ((a (pichat-session-make :name "Same prefix, z" :owner-directory "/tmp/z/"
                                         :owner-scope-key "project:/tmp/z/"))
          (b (pichat-session-make :name "Same prefix, a" :owner-directory "/tmp/a/"
                                         :owner-scope-key "project:/tmp/a/"))
          (width 80))
      (pichat-register-session a)
      (pichat-register-session b)
      (with-temp-buffer
        (pichat-session-manager-mode)
        (cl-letf (((symbol-function 'pichat-session-manager--display-width) (lambda () width)))
          (pichat-session-manager-refresh)
          (should (equal (pichat-session-runtime-id b) (car (car tabulated-list-entries))))
          (goto-char (point-min))
          (forward-line 1)
          (let ((selected (tabulated-list-get-id)))
            (setq width 8)
            (pichat-session-manager-refresh)
            (should-not tabulated-list-sort-key)
            (should (equal selected (tabulated-list-get-id)))
            (should (equal "Project" (car pichat-session-manager--logical-sort)))
            (setq width 80)
            (pichat-session-manager-refresh)
            (should (equal '("Project") tabulated-list-sort-key)))
          ;; Native header/keyboard sorting remains usable, including direction.
          (tabulated-list-sort 2)
          (should (equal (pichat-session-runtime-id b) (tabulated-list-get-id (point-min))))
          (tabulated-list-sort 2)
          (setq width 8)
          (pichat-session-manager-refresh)
          (should (equal '("Name" . t) pichat-session-manager--logical-sort))
          (should (equal (pichat-session-runtime-id a) (car (car tabulated-list-entries)))))))))

(ert-deftest pichat-session-manager-window-changes-coalesce-and-remove-narrowest-display ()
  (save-window-excursion
    (let ((buffer (generate-new-buffer " *manager geometry*")) handler)
      (unwind-protect
          (progn
            (delete-other-windows)
            (switch-to-buffer buffer)
            (with-current-buffer buffer
              (pichat-session-manager-mode)
              (setq handler pichat-session-manager--window-handler)
              (pichat-session-manager-refresh))
            (let* ((wide (selected-window))
                   (narrow (split-window wide 26 'right)))
              (set-window-buffer narrow buffer)
              (with-current-buffer buffer
                (should (= (min (window-body-width wide) (window-body-width narrow))
                           (pichat-session-manager--display-width)))
                (funcall handler (selected-frame))
                (let ((timer pichat-session-manager--refresh-timer))
                  (should (timerp timer))
                  (funcall handler (selected-frame))
                  (should (eq timer pichat-session-manager--refresh-timer))
                  (cancel-timer timer)
                  (pichat-session-manager--run-refresh buffer))
                (funcall handler (selected-frame))
                (should-not pichat-session-manager--refresh-timer))
              (delete-window narrow)
              (with-current-buffer buffer
                (funcall handler (selected-frame))
                (should (timerp pichat-session-manager--refresh-timer))))
            (kill-buffer buffer)
            (should-not (memq handler (default-value 'window-state-change-functions))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-naming-reads-authoritative-state-after-success ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :name "Before")))
          setter readback buffer)
      (setq buffer (generate-new-buffer " *manager naming*"))
      (unwind-protect
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Requested"))
                    ((symbol-function 'pichat-backend-name-session)
                     (lambda (_session name callback)
                       (should (equal "Requested" name))
                       (setq setter callback)))
                    ((symbol-function 'pichat-backend-get-state)
                     (lambda (s callback &rest _)
                       (should (eq s session))
                       (setq readback callback))))
            (with-current-buffer buffer
              (pichat-session-manager-mode)
              (pichat-session-manager-refresh)
              (goto-char (point-min))
              (pichat-session-manager-name)
              (should-not readback)
              (should (equal "Before" (pichat-session-name session))))
            ;; Success/readback must not depend on the manager buffer surviving.
            (kill-buffer buffer)
            (funcall setter '(:success t) session)
            (should readback)
            (should (equal "Before" (pichat-session-name session)))
            (pichat-session-apply-rpc-state session '(:sessionName "Authoritative"))
            (funcall readback nil session)
            (should (equal "Authoritative" (pichat-session-name session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-session-manager-naming-rejects-source-changes-during-prompt ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :id "before"))))
      (with-temp-buffer
        (pichat-session-manager-mode)
        (pichat-session-manager-refresh)
        (goto-char (point-min))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _)
                     (setf (pichat-session-id session) "after") "Requested"))
                  ((symbol-function 'pichat-backend-name-session)
                   (lambda (&rest _) (ert-fail "Named a rebound source"))))
          (should-error (pichat-session-manager-name) :type 'user-error))))))

(ert-deftest pichat-session-manager-naming-does-not-read-back-after-source-rebinding ()
  (pichat-test-with-clean-state
    (let ((session (pichat-register-session (pichat-session-make :id "before"))) setter)
      (with-temp-buffer
        (pichat-session-manager-mode)
        (pichat-session-manager-refresh)
        (goto-char (point-min))
        (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Requested"))
                  ((symbol-function 'pichat-backend-name-session)
                   (lambda (_session _name callback) (setq setter callback)))
                  ((symbol-function 'pichat-backend-get-state)
                   (lambda (&rest _) (ert-fail "Read state for rebound source"))))
          (pichat-session-manager-name)
          (setf (pichat-session-id session) "after")
          (funcall setter nil session))))))

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
         (persistent-row (pichat-session-manager--entry persistent))
         (ephemeral-row (pichat-session-manager--entry ephemeral)))
    (should (equal "file" (pichat-session-manager--sort-value persistent-row "Store")))
    (should (equal "none" (pichat-session-manager--sort-value ephemeral-row "Store")))))

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
              (should-not (string-match-p "q close ·" text))
              (should (string-match-p "Source: /tmp/pi-source.jsonl" text))
              (should (string-match-p "Fix the parser" text))
              (should (string-match-p "Working on the parser now" text)))))))))

(ert-deftest pichat-session-manager-preview-quit-releases-owned-side-window ()
  (pichat-test-with-clean-state
    (save-window-excursion
      (delete-other-windows)
      (let ((manager (get-buffer-create pichat-session-manager-buffer-name)))
        (with-current-buffer manager (pichat-session-manager-mode))
        (switch-to-buffer manager)
        (cl-letf (((symbol-function 'pichat-session-manager--preview-selected)
                   #'ignore))
          (with-current-buffer manager
            (pichat-session-manager-toggle-preview)))
        (let ((preview (get-buffer pichat-session-manager-preview-buffer-name)))
          (should (get-buffer-window preview))
          (select-window (get-buffer-window preview))
          (with-current-buffer preview
            (pichat-session-manager-preview-quit))
          (should (eq manager (window-buffer (selected-window))))
          (with-current-buffer manager
            (should-not pichat-session-manager--preview-window)))))))

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
      (when-let* ((buffer
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

(ert-deftest pichat-independent-source-open-rejects-unknown-readiness-before-start ()
  (let (started)
    (cl-letf (((symbol-function 'pichat-start-session)
               (lambda (&rest _) (setq started t))))
      (should-error
       (pichat-sessions-open-file-independently
        "/saved/session.jsonl" :readiness 'unknown :display-function nil)
       :type 'user-error)
      (should-not started))))

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
