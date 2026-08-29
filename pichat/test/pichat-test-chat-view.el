;;; pichat-test-chat-view.el --- PiChat chat window behavior tests -*- lexical-binding: t; -*-

;;; Commentary:

;; User-visible cursor, viewport, and tail-following behavior with real windows.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-chat-view--transcript (&optional suffix)
  "Return a long one-node transcript ending with optional SUFFIX."
  (let ((text (string-join
               (append
                (cl-loop for line from 1 to 70
                         collect (format "history line %02d with stable text" line))
                (when suffix (list suffix)))
               "\n")))
    (pichat-transcript-create
     :nodes
     (list
      (pichat-transcript-node-create
       :kind 'message :key "view-history" :role 'assistant
       :content
       (list (pichat-transcript-content-create
              :kind 'prose :index 0 :text text))))
     :diagnostics nil :metadata nil)))

(defun pichat-test-chat-view--project-canonical (transcript)
  "Project TRANSCRIPT into the current PiChat buffer."
  (let* ((context (pichat-chat--canonical-render-context transcript))
         (fragment (pichat-render-canonical transcript context)))
    (pichat-chat--project-canonical nil transcript fragment context)))

(defun pichat-test-chat-view--tool-event (id name path)
  "Return a tool-use event declaring ID with NAME and PATH."
  (list :type "message_end"
        :message (list :role "assistant" :stopReason "toolUse"
                       :content (list (list :type "toolCall" :id id
                                            :name name
                                            :arguments (list :path path))))))

(defun pichat-test-chat-view--tool-finish-event (id name output)
  "Return a successful tool execution event for ID, NAME, and OUTPUT."
  (list :type "tool_execution_end" :toolCallId id :toolName name
        :isError nil
        :result (list :content (list (list :type "text" :text output)))))

(defun pichat-test-chat-view--apply-events (&rest events)
  "Apply live draft EVENTS and project the resulting live tail."
  (dolist (event events)
    (pichat-pi-live-draft-apply pichat-chat--live-draft event))
  (pichat-chat--project-live-tail))

(defun pichat-test-chat-view--anchor-at (position)
  "Return the observable node key and offset at POSITION."
  (when-let ((key (get-text-property position 'pichat-node-key)))
    (let* ((candidate (previous-single-property-change
                       (1+ position) 'pichat-node-key nil (point-min)))
           (start (if (and candidate
                           (equal key (get-text-property
                                       candidate 'pichat-node-key)))
                      candidate
                    position)))
      (list key (- position start)))))

(defun pichat-test-chat-view--place-window (window position recenter-arg)
  "Place WINDOW at POSITION and RECENTER-ARG without stealing selection."
  (with-selected-window window
    (goto-char position)
    (recenter recenter-arg)))

(ert-deftest pichat-chat-view-splits-follow-independently-during-live-and-status-updates ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--project-canonical
               (pichat-test-chat-view--transcript))
              ;; Start with a non-empty live region.  Its end is within the
              ;; bottom threshold, but unlike the prompt it is swept when the
              ;; cumulative live region is replaced.
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_update"
                 :message
                 (:role "assistant"
                  :content
                  ((:type "text"
                    :text "live line 01\nlive line 02\nlive line 03")))))
              (pichat-chat--project-live-tail))
            (let* ((reader (selected-window))
                   (follower (split-window-right))
                   reader-position reader-anchor reader-start-anchor)
              (set-window-buffer follower buffer)
              (with-current-buffer buffer
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "history line 30")
                (backward-char 4)
                (setq reader-position (point)))
              (pichat-test-chat-view--place-window reader reader-position nil)
              (with-current-buffer buffer
                (pichat-test-chat-view--place-window
                 follower (marker-position pichat-chat--live-end) -1)
                (should (<= (- (point-max) (window-point follower))
                            pichat-chat-follow-bottom-threshold)))
              (select-window reader)
              (redisplay t)
              (with-current-buffer buffer
                (setq reader-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-point reader))
                      reader-start-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-start reader)))
                (should reader-anchor)
                (should reader-start-anchor)
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 `(:type "message_update"
                   :message
                   (:role "assistant"
                    :content
                    ((:type "text"
                      :text ,(string-join
                              (cl-loop for line from 1 to 24
                                       collect (format "live line %02d" line))
                              "\n"))))))
                (pichat-chat--project-live-tail)
                (redisplay t)
                (should (equal reader-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-point reader))))
                (should (equal reader-start-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-start reader))))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold))
                ;; Status projection has a distinct edit path but must retain
                ;; the same per-window reader/follower policy.
                (pichat-chat--set-status 'view "[view status update]")
                (redisplay t)
                (should (equal reader-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-point reader))))
                (should (equal reader-start-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-start reader))))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-scrolled-away-point-max-does-not-follow ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer other-buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--project-canonical
               (pichat-test-chat-view--transcript)))
            (let* ((chat-window (selected-window))
                   (other-window (split-window-right))
                   old-start old-visible-end old-start-anchor)
              (setq other-buffer (generate-new-buffer " *pichat-view-other*"))
              (set-window-buffer other-window other-buffer)
              (select-window other-window)
              (with-current-buffer buffer
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "history line 12")
                (pichat-test-chat-view--place-window
                 chat-window (point) 0)
                ;; Establish a real old viewport first, then place this
                ;; nonselected window's point at the tail without allowing
                ;; redisplay to scroll the viewport there.
                (redisplay t)
                (setq old-start (window-start chat-window)
                      old-start-anchor
                      (pichat-test-chat-view--anchor-at old-start)
                      old-visible-end
                      (save-excursion
                        (goto-char old-start)
                        (vertical-motion (window-body-height chat-window)
                                         chat-window)
                        (point)))
                (should old-start-anchor)
                (set-window-point chat-window (point-max))
                (set-window-start chat-window old-start t)
                (goto-char (point-max))
                (should (= (window-point chat-window) (point-max)))
                (should (> (- (point-max) old-visible-end)
                           pichat-chat-follow-bottom-threshold))
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 '(:type "message_update"
                   :message
                   (:role "assistant"
                    :content
                    ((:type "text"
                      :text "new live output\nwith several\nadditional lines")))))
                (pichat-chat--project-live-tail)
                (redisplay t)
                (should (equal old-start-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-start chat-window))))
                (let ((visible-end
                       (save-excursion
                         (goto-char (window-start chat-window))
                         (vertical-motion (window-body-height chat-window)
                                          chat-window)
                         (point))))
                  (should (> (- (point-max) visible-end)
                             pichat-chat-follow-bottom-threshold))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p other-buffer) (kill-buffer other-buffer))))))

(ert-deftest pichat-chat-view-nonselected-window-survives-canonical-repaint ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer other-buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--project-canonical
               (pichat-test-chat-view--transcript)))
            (let* ((reader (selected-window))
                   (follower (split-window-right))
                   (other-window (split-window reader nil 'below))
                   reader-position reader-anchor reader-start-anchor)
              (setq other-buffer (generate-new-buffer " *pichat-view-selected*"))
              (set-window-buffer follower buffer)
              (set-window-buffer other-window other-buffer)
              (with-current-buffer buffer
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "history line 35")
                (backward-char 5)
                (setq reader-position (point)))
              (pichat-test-chat-view--place-window reader reader-position nil)
              (with-current-buffer buffer
                (pichat-test-chat-view--place-window
                 follower (point-max) -1))
              (select-window other-window)
              (redisplay t)
              (with-current-buffer buffer
                (setq reader-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-point reader))
                      reader-start-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-start reader)))
                (should reader-anchor)
                (should reader-start-anchor)
                ;; Ordinary buffer point is deliberately not used as either
                ;; window's desired cursor state.
                (goto-char (marker-position pichat-chat--canonical-start))
                (pichat-test-chat-view--project-canonical
                 (pichat-test-chat-view--transcript
                  "new canonical line after repaint"))
                (redisplay t)
                (should (eq other-window (selected-window)))
                (should (equal reader-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-point reader))))
                (should (equal reader-start-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-start reader))))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p other-buffer) (kill-buffer other-buffer))))))

(ert-deftest pichat-chat-view-projection-rollback-restores-each-window ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--project-canonical
               (pichat-test-chat-view--transcript)))
            (let* ((reader (selected-window))
                   (follower (split-window-right))
                   reader-position reader-anchor reader-start-anchor before)
              (set-window-buffer follower buffer)
              (with-current-buffer buffer
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "history line 40")
                (backward-char 4)
                (setq reader-position (point)))
              (pichat-test-chat-view--place-window reader reader-position nil)
              (with-current-buffer buffer
                (pichat-test-chat-view--place-window
                 follower (point-max) -1))
              (select-window reader)
              (redisplay t)
              (with-current-buffer buffer
                (setq reader-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-point reader))
                      reader-start-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-start reader))
                      before (buffer-substring (point-min) (point-max)))
                (let ((pichat-chat-markdown-mode t))
                  (cl-letf (((symbol-function
                              'pichat-chat--markdown-fontify-region)
                             (lambda (&rest _args)
                               (error "forced view rollback"))))
                    (should-error
                     (pichat-test-chat-view--project-canonical
                      (pichat-test-chat-view--transcript
                       "projection that must roll back")))))
                (redisplay t)
                (should (equal before
                               (buffer-substring (point-min) (point-max))))
                (should (equal reader-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-point reader))))
                (should (equal reader-start-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-start reader))))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-hidden-buffer-preserves-logical-reader ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          buffer other-buffer expected-anchor)
      (cl-labels
          ((transcript
            (prefix)
            (pichat-transcript-create
             :nodes
             (list
              (pichat-transcript-node-create
               :kind 'message :key "view-prefix" :role 'assistant
               :content
               (list (pichat-transcript-content-create
                      :kind 'prose :index 0 :text prefix)))
              (pichat-transcript-node-create
               :kind 'message :key "view-reader" :role 'assistant
               :content
               (list (pichat-transcript-content-create
                      :kind 'prose :index 0
                      :text "stable hidden reader text"))))
             :diagnostics nil :metadata nil)))
        (unwind-protect
            (save-window-excursion
              (setq buffer (pichat-chat-open session))
              (with-current-buffer buffer
                (pichat-test-chat-view--project-canonical
                 (transcript "short prefix"))
                (goto-char (marker-position pichat-chat--canonical-start))
                (search-forward "hidden reader")
                (backward-char 4)
                (setq expected-anchor
                      (pichat-test-chat-view--anchor-at (point)))
                (should expected-anchor))
              (setq other-buffer
                    (generate-new-buffer " *pichat-view-hidden-other*"))
              (switch-to-buffer other-buffer)
              (should-not (get-buffer-window-list buffer nil t))
              (with-current-buffer buffer
                (pichat-test-chat-view--project-canonical
                 (transcript
                  (string-join
                   (cl-loop for line from 1 to 30
                            collect (format "expanded prefix %02d" line))
                   "\n")))
                (should (equal expected-anchor
                               (pichat-test-chat-view--anchor-at (point))))))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (buffer-live-p other-buffer) (kill-buffer other-buffer)))))))

(ert-deftest pichat-chat-view-settlement-preserves-live-reader-position ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown t)
          buffer expected-position)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (let ((chat-window (selected-window)))
              (with-current-buffer buffer
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 '(:type "message_end"
                   :message
                   (:role "assistant"
                    :content
                    ((:type "text"
                      :text "**settled response** with enough trailing text to keep point away from the prompt")))))
                (pichat-chat--project-live-tail)
                (goto-char (marker-position pichat-chat--live-start))
                (search-forward "response")
                (backward-char 4)
                (setq expected-position (point))
                (pichat-test-chat-view--place-window
                 chat-window expected-position nil)
                (let* ((transcript
                        (pichat-transcript-create
                         :nodes
                         (list
                          (pichat-transcript-node-create
                           :kind 'message :key "entry-1" :role 'assistant
                           :content
                           (list
                            (pichat-transcript-content-create
                             :kind 'prose :index 0
                             :text "**settled response** with enough trailing text to keep point away from the prompt"))))
                         :diagnostics nil :metadata nil))
                       (context
                        (pichat-chat--canonical-render-context transcript))
                       (fragment
                        (pichat-render-canonical transcript context)))
                  (pichat-chat--project-canonical
                   nil transcript fragment context))
                (should (= expected-position (window-point chat-window)))
                (should (< (window-point chat-window)
                           (marker-position pichat-chat--prompt-start)))
                (should (equal
                         "entry-1"
                         (get-text-property (window-point chat-window)
                                            'pichat-node-key))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-shorter-settlement-clamps-reader-before-prompt ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown t)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (let ((chat-window (selected-window)))
              (with-current-buffer buffer
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 '(:type "message_end"
                   :message
                   (:role "assistant"
                    :content
                    ((:type "text"
                      :text "This transient response is deliberately much longer than the persisted response so its old cursor position cannot exist in the shorter canonical transcript.")))))
                (pichat-chat--project-live-tail)
                (goto-char (marker-position pichat-chat--live-start))
                (search-forward "canonical transcript")
                (backward-char 5)
                (pichat-test-chat-view--place-window chat-window (point) nil)
                (let* ((transcript
                        (pichat-transcript-create
                         :nodes
                         (list
                          (pichat-transcript-node-create
                           :kind 'message :key "entry-1" :role 'assistant
                           :content
                           (list
                            (pichat-transcript-content-create
                             :kind 'prose :index 0 :text "Short response."))))
                         :diagnostics nil :metadata nil))
                       (context
                        (pichat-chat--canonical-render-context transcript))
                       (fragment
                        (pichat-render-canonical transcript context)))
                  (pichat-chat--project-canonical
                   nil transcript fragment context))
                (should (<= (window-point chat-window)
                            (marker-position pichat-chat--canonical-end)))
                (should (< (window-point chat-window)
                           (marker-position pichat-chat--prompt-start))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-tool-growth-keeps-reader-inside-first-tool-output ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          (pichat-chat-follow-bottom-threshold 0)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--apply-events
               (pichat-test-chat-view--tool-event
                "cursor-first" "read" "first.el")
               (pichat-test-chat-view--tool-finish-event
                "cursor-first" "read" "inspection target output")))
            (let* ((reader (selected-window))
                   (follower (split-window-right))
                   expected-tool expected-logical expected-offset
                   header-before
                   (full-count 0))
              (set-window-buffer follower buffer)
              (with-current-buffer buffer
                (let* ((block (gethash "cursor-first"
                                       pichat-chat--tool-blocks))
                       (end (marker-position (plist-get block :end))))
                  (goto-char (marker-position (plist-get block :start)))
                  (search-forward "target" end)
                  (backward-char 3)
                  (setq expected-tool
                        (get-text-property (point) 'pichat-tool-key)
                        expected-logical
                        (get-text-property (point) 'pichat-logical-key)
                        expected-offset
                        (cadr (pichat-chat--property-anchor-at
                               (point) 'pichat-logical-key)))
                  (save-excursion
                    (goto-char
                     (text-property-any
                      pichat-chat--live-start pichat-chat--live-end
                      'pichat-content-kind 'activity-header))
                    (setq header-before
                          (buffer-substring-no-properties
                           (point) (line-end-position))))
                  (pichat-test-chat-view--place-window reader (point) nil))
                (pichat-test-chat-view--place-window follower (point-max) -1))
              (select-window reader)
              (redisplay t)
              (with-current-buffer buffer
                (cl-letf (((symbol-function 'pichat-chat--replace-live-full)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--replace-live-full)))
                             (lambda (candidate)
                               (cl-incf full-count)
                               (funcall original candidate)))))
                  (pichat-test-chat-view--apply-events
                   (pichat-test-chat-view--tool-event
                    "cursor-second" "edit" "second.el")))
                (should (= 0 full-count))
                (save-excursion
                  (goto-char
                   (text-property-any
                    pichat-chat--live-start pichat-chat--live-end
                    'pichat-content-kind 'activity-header))
                  (should-not
                   (equal header-before
                          (buffer-substring-no-properties
                           (point) (line-end-position)))))
                (let ((position (window-point reader)))
                  (should (eq 'tool
                              (get-text-property position
                                                 'pichat-content-kind)))
                  (should (equal expected-tool
                                 (get-text-property position
                                                    'pichat-tool-key)))
                  (should (equal expected-logical
                                 (get-text-property position
                                                    'pichat-logical-key)))
                  (should (= expected-offset
                             (cadr (pichat-chat--property-anchor-at
                                    position 'pichat-logical-key))))
                  (should-not (eq 'activity-header
                                  (get-text-property
                                   position 'pichat-content-kind))))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold))))
        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest pichat-chat-view-full-fallback-keeps-reader-inside-later-tool ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          (pichat-chat-follow-bottom-threshold 0)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--apply-events
               (pichat-test-chat-view--tool-event "full-first" "read" "one.el")
               (pichat-test-chat-view--tool-finish-event
                "full-first" "read" "first")
               (pichat-test-chat-view--tool-event "full-second" "edit" "two.el")
               (pichat-test-chat-view--tool-finish-event
                "full-second" "edit" "second output"))
              (let* ((window (selected-window))
                     (block (gethash "full-second" pichat-chat--tool-blocks))
                     (position (marker-position (plist-get block :start)))
                     (expected-tool
                      (get-text-property position 'pichat-tool-key))
                     (expected-logical
                      (get-text-property position 'pichat-logical-key))
                     (full-count 0))
                (pichat-test-chat-view--place-window window position nil)
                (pichat-pi-live-draft-apply
                 pichat-chat--live-draft
                 (pichat-test-chat-view--tool-event
                  "full-third" "bash" "three.el"))
                (pichat-chat--release-live-projection-fragments)
                (setq pichat-chat--live-projection-fragments nil
                      pichat-chat--live-projection-fingerprint nil)
                (cl-letf (((symbol-function 'pichat-chat--replace-live-full)
                           (let ((original
                                  (symbol-function
                                   'pichat-chat--replace-live-full)))
                             (lambda (candidate)
                               (cl-incf full-count)
                               (funcall original candidate)))))
                  (pichat-chat--project-live-tail))
                (should (= 1 full-count))
                (should (equal expected-tool
                               (get-text-property (window-point window)
                                                  'pichat-tool-key)))
                (should (equal expected-logical
                               (get-text-property (window-point window)
                                                  'pichat-logical-key)))
                (should (eq 'tool
                            (get-text-property (window-point window)
                                               'pichat-content-kind))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-settlement-matches-tool-reader-by-unique-id ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown nil)
          (pichat-chat-activity-group-display 'expanded)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          (pichat-chat-follow-bottom-threshold 0)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-test-chat-view--apply-events
               (pichat-test-chat-view--tool-event
                "settle-reader" "read" "settle.el")
               (pichat-test-chat-view--tool-finish-event
                "settle-reader" "read" "settled output"))
              (let* ((window (selected-window))
                     (block (gethash "settle-reader"
                                     pichat-chat--tool-blocks))
                     (position (marker-position (plist-get block :start)))
                     (live-logical
                      (get-text-property position 'pichat-logical-key))
                     (tool
                      (pichat-transcript-content-create
                       :kind 'tool :index 0 :tool-call-id "settle-reader"
                       :name "read" :arguments '(:path "settle.el")
                       :status 'done
                       :output (list (pichat-transcript-content-create
                                      :kind 'prose :index 0
                                      :text "settled output"))))
                     (transcript
                      (pichat-transcript-create
                       :nodes
                       (list (pichat-transcript-node-create
                              :kind 'message :key "canonical-settled-node"
                              :role 'assistant :content (list tool)))
                       :diagnostics nil :metadata nil))
                     (context
                      (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-test-chat-view--place-window window position nil)
                (pichat-chat--project-canonical
                 nil transcript fragment context t)
                (let ((settled-position (window-point window)))
                  (should (eq 'tool
                              (get-text-property settled-position
                                                 'pichat-content-kind)))
                  (should (equal '("canonical-settled-node" . "settle-reader")
                                 (get-text-property settled-position
                                                    'pichat-tool-key)))
                  (should-not
                   (equal live-logical
                          (get-text-property settled-position
                                             'pichat-logical-key)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-tool-id-anchor-rejects-ambiguous-ranges ()
  (with-temp-buffer
    (insert (propertize "first" 'pichat-tool-key '("one" . "duplicate")))
    (insert "\n")
    (insert (propertize "second" 'pichat-tool-key '("two" . "duplicate")))
    (should-not (pichat-chat--tool-id-anchor-position '("duplicate" 0)))))

(ert-deftest pichat-chat-view-tool-update-keeps-folded-reader-and-follower ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"follow-fold\",\"name\":\"read_example\",\"arguments\":{\"path\":\"safe.txt\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"follow-fold\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"follow-fold\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"first output\"}]}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection))
            (let* ((reader (selected-window))
                   (follower (split-window-right))
                   reader-anchor reader-tool-key reader-logical-key)
              (set-window-buffer follower buffer)
              (with-current-buffer buffer
                (let* ((block (gethash "follow-fold"
                                       pichat-chat--tool-blocks))
                       (start (marker-position (plist-get block :start)))
                       (logical-key
                        (get-text-property start 'pichat-logical-key)))
                  (pichat-test-chat-view--place-window reader start nil)
                  (goto-char (window-point reader))
                  (pichat-chat-toggle-tool-at-point)
                  (should (eq 'summary (plist-get block :display-state)))
                  (should (equal logical-key
                                 (get-text-property
                                  (marker-position (plist-get block :start))
                                  'pichat-logical-key))))
                (pichat-test-chat-view--place-window follower (point-max) -1)
                (setq reader-anchor
                      (pichat-test-chat-view--anchor-at
                       (window-point reader))
                      reader-tool-key
                      (get-text-property (window-point reader)
                                         'pichat-tool-key)
                      reader-logical-key
                      (get-text-property (window-point reader)
                                         'pichat-logical-key))
                (should reader-anchor)
                (should reader-tool-key)
                (should reader-logical-key))
              (select-window reader)
              (redisplay t)
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"tool_execution_update\",\"toolCallId\":\"follow-fold\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"second output\"}]}}\n")
              (with-current-buffer buffer
                (pichat-chat--flush-live-projection)
                (should (eq 'summary
                            (plist-get (gethash "follow-fold"
                                                pichat-chat--tool-blocks)
                                       :display-state)))
                (should (equal reader-anchor
                               (pichat-test-chat-view--anchor-at
                                (window-point reader))))
                (should (equal reader-tool-key
                               (get-text-property (window-point reader)
                                                  'pichat-tool-key)))
                (should (equal reader-logical-key
                               (get-text-property (window-point reader)
                                                  'pichat-logical-key)))
                (should (eq 'tool
                            (get-text-property (window-point reader)
                                               'pichat-content-kind)))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-tool-update-preserves-live-separator-reader ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-collapse-tools-by-default nil)
          (pichat-chat-tool-default-display 'output)
          buffer expected-position)
      (unwind-protect
          (save-window-excursion
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"shell-separator\",\"name\":\"bash\",\"arguments\":{\"command\":\"printf lines\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"shell-separator\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"shell-separator\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"alpha\"}]}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection))
            (let ((reader (selected-window))
                  (follower (split-window-right)))
              (set-window-buffer follower buffer)
              (with-current-buffer buffer
                (setq expected-position
                      (1- (marker-position pichat-chat--live-end)))
                (should-not (get-text-property expected-position
                                               'pichat-node-key))
                (pichat-test-chat-view--place-window
                 reader expected-position nil)
                (pichat-test-chat-view--place-window follower (point-max) -1))
              (select-window reader)
              (redisplay t)
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"tool_execution_update\",\"toolCallId\":\"shell-separator\",\"toolName\":\"bash\",\"args\":{\"command\":\"printf lines\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"alpha\\nbeta\\ngamma\"}]}}\n")
              (with-current-buffer buffer
                (pichat-chat--flush-live-projection)
                (should (= expected-position (window-point reader)))
                (should (< (window-point reader)
                           (marker-position pichat-chat--prompt-start)))
                (should (= (window-point follower) (point-max)))
                (should (<= (- (point-max) (window-end follower t))
                            pichat-chat-follow-bottom-threshold)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-view-hidden-tool-reader-does-not-follow-updates ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (details-buffer-name "*PiChat Tool Details*")
          buffer expected-anchor)
      (unwind-protect
          (save-window-excursion
            (when-let ((details (get-buffer details-buffer-name)))
              (kill-buffer details))
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"details-follow\",\"name\":\"read_example\",\"arguments\":{\"path\":\"safe.txt\"}}]}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"details-follow\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\"}}\n")
            (with-current-buffer buffer
              (let ((block (gethash "details-follow"
                                    pichat-chat--tool-blocks)))
                (goto-char (marker-position (plist-get block :start)))
                (setq expected-anchor
                      (pichat-test-chat-view--anchor-at (point)))
                (should expected-anchor)
                (pichat-chat-show-tool-details)))
            (delete-other-windows)
            (should-not (get-buffer-window-list buffer nil t))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"details-follow\",\"toolName\":\"read_example\",\"args\":{\"path\":\"safe.txt\"},\"partialResult\":{\"content\":[{\"type\":\"text\",\"text\":\"new output\"}]}}\n")
            (with-current-buffer buffer
              (pichat-chat--flush-live-projection)
              (should (equal expected-anchor
                             (pichat-test-chat-view--anchor-at (point))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when-let ((details (get-buffer details-buffer-name)))
          (kill-buffer details))))))

(provide 'pichat-test-chat-view)
;;; pichat-test-chat-view.el ends here
