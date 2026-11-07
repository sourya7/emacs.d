;;; pichat-test-chat-controls.el --- PiChat model/thinking control tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for mode-line controls and the persistent context header.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-chat-controls--pending-id (session command)
  "Return pending request id for COMMAND in SESSION."
  (let (found)
    (maphash
     (lambda (id pending)
       (when (equal command (pichat-rpc--pending-command pending))
         (setq found id)))
     (pichat-session-pending-responses session))
    found))

(ert-deftest pichat-chat-controls-derive-model-specific-thinking-levels ()
  (should-not
   (pichat-chat--model-thinking-levels '(:reasoning nil)))
  (should
   (equal '("off" "minimal" "low" "medium" "high")
          (pichat-chat--model-thinking-levels '(:reasoning t))))
  (should
   (equal '("off" "high" "max")
          (pichat-chat--model-thinking-levels
           '(:reasoning t
             :thinkingLevelMap (:minimal nil :low nil :medium nil
                                :high "high" :xhigh nil :max "max")))))
  (should
   (equal '("minimal" "low" "medium" "high" "xhigh")
          (pichat-chat--model-thinking-levels
           '(:reasoning t :thinkingLevelMap (:off nil :xhigh "xhigh"))))))

(ert-deftest pichat-chat-controls-mode-line-clicks-route-to-supported-commands ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t)
            (pichat-session-thinking-level session) "medium")
      (let* ((status (pichat-chat--mode-line-status))
             (model-pos (string-match "reasoner" status))
             (thinking-pos (string-match "\\.M" status))
             (model-command
              (lookup-key (get-text-property model-pos 'local-map status)
                          [mode-line mouse-1]))
             (thinking-command
              (lookup-key (get-text-property thinking-pos 'local-map status)
                          [mode-line mouse-1]))
             selected cycled)
        (should model-pos)
        (should thinking-pos)
        (cl-letf (((symbol-function 'pichat-select-model)
                   (lambda (&optional selected-session)
                     (interactive)
                     (setq selected (or selected-session pichat-chat-session))))
                  ((symbol-function 'pichat-chat-cycle-thinking-level)
                   (lambda () (interactive) (setq cycled pichat-chat-session))))
          (funcall model-command nil)
          (funcall thinking-command nil))
        (should (eq session selected))
        (should (eq session cycled))))))

(ert-deftest pichat-chat-controls-mode-line-identifies-captured-preset-only ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (should-not (string-match-p "P:manual" (pichat-chat--mode-line-status)))
      (setf (pichat-session-preset-name session) 'manual)
      (should (string-match-p "P:manual" (pichat-chat--mode-line-status))))))

(ert-deftest pichat-chat-controls-mode-line-renders-all-runtime-states-compactly ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "plain" :reasoning nil))
      (dolist (spec '((starting "◌" "starting")
                      (idle "○" "idle")
                      (running "▶" "running")
                      (compacting "⇥" "compacting")
                      (retrying "↻" "retrying")
                      (stopped "■" "stopped")
                      (error "✕" "error")
                      (nil "?" "unknown")))
        (setf (pichat-session-state session) (nth 0 spec))
        (let ((status (pichat-chat--mode-line-status)))
          (should (string-prefix-p (nth 1 spec) status))
          (should (equal (format "Pi status: %s" (nth 2 spec))
                         (get-text-property 0 'help-echo status)))))))
  (with-temp-buffer
    (let ((status (pichat-chat--mode-line-status)))
      (should (equal "⊘" (substring-no-properties status)))
      (should (equal "Pi status: not connected"
                     (get-text-property 0 'help-echo status))))))

(ert-deftest pichat-chat-controls-compact-thinking-levels-and-preserve-model-id ()
  (should
   (equal '(("off" . "0") ("minimal" . "m") ("low" . "L")
            ("medium" . "M") ("high" . "H") ("xhigh" . "XH")
            ("max" . "MAX") ("future" . "future") (nil . "?"))
          (mapcar
           (lambda (level)
             (cons level (pichat-chat--compact-thinking-level level)))
           '("off" "minimal" "low" "medium" "high" "xhigh" "max"
             "future" nil))))
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "future" :id "future.gpt-prefix-model" :reasoning t)
            (pichat-session-thinking-level session) "high")
      (should
       (string-match-p "future\\.gpt-prefix-model\\.H"
                       (pichat-chat--mode-line-status))))))

(ert-deftest pichat-chat-controls-preserve-buffer-name-and-optional-segments ()
  (pichat-test-with-unit-session (session proc)
    (setf (pichat-session-id session) "019ffc5b-extra"
          (pichat-session-owner-directory session)
          "/home/mojo/.config/emacs.mine"
          (pichat-session-owner-scope-key session)
          "project:/home/mojo/.config/emacs.mine"
          (pichat-session-name session) "Named session"
          (pichat-session-model session)
          '(:provider "test" :id "reasoner" :reasoning t)
          (pichat-session-thinking-level session) "high")
    (should (equal (format "*pi:emacs.mine:%s*"
                           (string-remove-prefix
                            "pichat-runtime-" (pichat-session-runtime-id session)))
                   (pichat-chat-buffer-name session)))
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setq-local pichat-chat--queue-counts '(2 . 1))
      (setq-local pichat-chat--pending-ui-count 3)
      (setq-local pichat-chat--extension-title "Extension title")
      (setq-local pichat-chat--extension-widgets (make-hash-table))
      (puthash "widget" t pichat-chat--extension-widgets)
      (let ((status (substring-no-properties
                     (pichat-chat--mode-line-status))))
        (dolist (segment '("reasoner.H" "Named session" "Extension title"
                           "Q:2/1" "UI:3" "W:1"))
          (should (string-match-p (regexp-quote segment) status)))))))

(ert-deftest pichat-chat-controls-context-formatter-preserves-warning-thresholds ()
  (pichat-test-with-unit-session (session)
    (dolist (spec '((50 nil) (75 warning) (95 error)))
      (setf (pichat-session-context-usage session)
            (list :tokens 3600 :contextWindow 272000 :percent (car spec)))
      (let ((display (pichat-chat--format-context-usage session)))
        (should (equal "3.6k/272k" (substring-no-properties display)))
        (should-not (string-match-p "ctx:" display))
        (should (string-match-p "Context usage:.*tokens"
                                (get-text-property 0 'help-echo display)))
        (should (eq (cadr spec) (get-text-property 0 'face display)))))))

(ert-deftest pichat-chat-controls-annotate-disabled-and-unavailable-controls ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "plain" :reasoning nil)
            (pichat-session-thinking-level session) "off")
      (let ((status (pichat-chat--mode-line-status)))
        (should (string-match-p "plain" status))
        (should-not (string-match-p "plain\\." status)))
      (setf (pichat-session-model session) '(:id "unknown"))
      (let* ((status (pichat-chat--mode-line-status))
             (pos (string-match "\\.\\?" status)))
        (should pos)
        (should-not (get-text-property pos 'local-map status))
        (should (equal 'shadow (get-text-property pos 'face status))))
      (delete-process proc)
      (let* ((status (pichat-chat--mode-line-status))
             (pos (string-match "unknown" status)))
        (should pos)
        (should-not (get-text-property pos 'local-map status))
        (should (equal 'shadow (get-text-property pos 'face status)))))))

(ert-deftest pichat-chat-controls-cycle-response-failure-is-visible-and-retryable ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setq-local pichat-chat--source-generation 7)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t)
            (pichat-session-thinking-level session) "low")
      (pichat-chat-cycle-thinking-level)
      (let ((id (pichat-test-chat-controls--pending-id
                 session "cycle_thinking_level")))
        (should id)
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"cycle_thinking_level\",\"success\":false,\"error\":\"fixture rejection\"}\n"
                 id)))
      (should pichat-chat--thinking-control-error)
      (let* ((status (pichat-chat--mode-line-status))
             (pos (string-match "\\.!" status)))
        (should pos)
        (should (keymapp (get-text-property pos 'local-map status)))))))

(ert-deftest pichat-chat-controls-success-refreshes-authoritative-state ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setq-local pichat-chat--source-generation 2)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t)
            (pichat-session-thinking-level session) "low")
      (pichat-chat-cycle-thinking-level)
      (let ((id (pichat-test-chat-controls--pending-id
                 session "cycle_thinking_level")))
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"cycle_thinking_level\",\"success\":true,\"data\":{\"level\":\"medium\"}}\n"
                 id)))
      (let ((id (pichat-test-chat-controls--pending-id session "get_state")))
        (should id)
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"s1\",\"model\":{\"provider\":\"test\",\"id\":\"reasoner\",\"reasoning\":true},\"thinkingLevel\":\"medium\",\"isStreaming\":false}}\n"
                 id)))
      (should (equal "medium" (pichat-session-thinking-level session)))
      (should-not pichat-chat--thinking-control-error)
      (should (string-match-p "reasoner\\.M"
                              (pichat-chat--mode-line-status))))))

(ert-deftest pichat-chat-controls-direct-selection-prompts-with-supported-levels ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t
              :thinkingLevelMap (:minimal nil :low "low" :medium nil
                                 :high "high" :xhigh nil :max "max"))
            (pichat-session-thinking-level session) "low")
      (let (completion request)
        (cl-letf (((symbol-function 'completing-read)
                   (lambda (prompt collection &optional _predicate require-match
                            _initial-input _hist default _inherit)
                     (setq completion
                           (list prompt collection require-match default))
                     "high"))
                  ((symbol-function 'pichat-rpc-set-thinking-level)
                   (lambda (selected-session level callback
                            &optional error-callback)
                     (setq request
                           (list selected-session level callback error-callback)))))
          (call-interactively #'pichat-chat-set-thinking-level))
        (should (equal '("Thinking level: " ("off" "low" "high" "max")
                         t "low")
                       completion))
        (should (eq session (nth 0 request)))
        (should (equal "high" (nth 1 request)))
        (should (functionp (nth 2 request)))
        (should (functionp (nth 3 request)))))))

(ert-deftest pichat-chat-controls-direct-selection-refreshes-authoritative-state ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setq-local pichat-chat--source-generation 3)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t)
            (pichat-session-thinking-level session) "low")
      (pichat-chat-set-thinking-level "high")
      (let ((id (pichat-test-chat-controls--pending-id
                 session "set_thinking_level")))
        (should id)
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"set_thinking_level\",\"success\":true}\n"
                 id)))
      (let ((id (pichat-test-chat-controls--pending-id session "get_state")))
        (should id)
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"get_state\",\"success\":true,\"data\":{\"sessionId\":\"s1\",\"model\":{\"provider\":\"test\",\"id\":\"reasoner\",\"reasoning\":true},\"thinkingLevel\":\"high\",\"isStreaming\":false}}\n"
                 id)))
      (should (equal "high" (pichat-session-thinking-level session)))
      (should-not pichat-chat--thinking-control-error))))

(ert-deftest pichat-chat-controls-direct-selection-failure-is-visible ()
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t))
      (pichat-chat-set-thinking-level "high")
      (let ((id (pichat-test-chat-controls--pending-id
                 session "set_thinking_level")))
        (should id)
        (pichat-rpc--process-filter
         proc
         (format "{\"type\":\"response\",\"id\":%S,\"command\":\"set_thinking_level\",\"success\":false,\"error\":\"fixture rejection\"}\n"
                 id)))
      (should pichat-chat--thinking-control-error)
      (should (string-match-p "reasoner\\.!"
                              (pichat-chat--mode-line-status))))))

(ert-deftest pichat-chat-controls-direct-selection-rejects-unavailable-levels ()
  (with-temp-buffer
    (should-error (pichat-chat-set-thinking-level "high") :type 'user-error))
  (pichat-test-with-unit-session (session proc)
    (with-temp-buffer
      (setq-local pichat-chat-session session)
      (setf (pichat-session-model session)
            '(:provider "test" :id "plain" :reasoning nil))
      (should-error (pichat-chat-set-thinking-level "high") :type 'user-error)
      (setf (pichat-session-model session) '(:provider "test" :id "unknown"))
      (should-error (pichat-chat-set-thinking-level "high") :type 'user-error)
      (setf (pichat-session-model session)
            '(:provider "test" :id "reasoner" :reasoning t
              :thinkingLevelMap (:medium nil)))
      (should-error (pichat-chat-set-thinking-level "medium")
                    :type 'user-error))))

(ert-deftest pichat-chat-header-keeps-context-at-desktop-tablet-phone-widths ()
  (pichat-test-with-unit-session (session)
    (setf (pichat-session-runtime-cwd session)
          "/runtime/a/very/long/project/with/界/100%/directory/"
          (pichat-session-cwd session) "/host/not-the-runtime"
          (pichat-session-context-usage session)
          '(:tokens 84000 :contextWindow 272000 :percent 31))
    (let ((pichat-chat-header-functions nil))
      (dolist (width '(160 100 80 60 40 30 24 18 12 1))
        (cl-letf (((symbol-function 'window-body-width)
                   (lambda (&rest _) width)))
          (let ((text (pichat-chat--header-text session (selected-window))))
            (should (<= (string-width text) width))
            (should-not (string-match-p "/host/" text))
            (when (>= width 16)
              (should (string-suffix-p
                       (if (>= width 22) "Context 84k/272k · 31%"
                         "Context 84k/272k") text)))
            (when (= width 160)
              (should (string-match-p "PiChat — /runtime/" text)))
            (when (= width 60)
              (should (string-match-p "….*directory/" text)))))))))

(ert-deftest pichat-chat-header-layout-is-per-window-and-configurable ()
  (pichat-test-with-unit-session (session)
    (with-temp-buffer
      (pichat-chat-mode)
      (setq-local pichat-chat-session session)
      (setf (pichat-session-runtime-cwd session) "/runtime/project/"
            (pichat-session-context-usage session)
            '(:tokens 84000 :contextWindow 272000 :percent 31))
      (save-window-excursion
        (delete-other-windows)
        (switch-to-buffer (current-buffer))
        (let* ((wide (selected-window))
               (narrow (split-window wide -18 t)))
          (set-window-buffer narrow (current-buffer))
          (let ((a (pichat-chat--header-text session wide))
                (b (pichat-chat--header-text session narrow)))
            (should (> (string-width a) (string-width b)))
            (should (string-match-p "31%" a))
            (should-not (string-match-p "31%" b))
            (should (string-match-p "Context 84k/272k" b)))
          (setq-local pichat-chat-header-show-directory nil)
          (setq-local pichat-chat-header-show-percentage nil)
          (should (equal "Context 84k/272k"
                         (string-trim (pichat-chat--header-text session wide))))
          (should-not (string-match-p "84k/272k"
                                      (pichat-chat--mode-line-status))))))))

(ert-deftest pichat-chat-header-labels-missing-unknown-and-request-usage ()
  (pichat-test-with-unit-session (session)
    (let ((pichat-chat-header-show-directory nil)
          (pichat-chat-header-functions nil))
      (should (equal "Context unavailable"
                     (string-trim
                      (pichat-chat--header-text session (selected-window)))))
      (setf (pichat-session-context-usage session)
            '(:tokens nil :contextWindow 272000 :percent nil))
      (let ((text (pichat-chat--header-text session (selected-window))))
        (should (string-match-p (regexp-quote "Context unknown ?/272k") text))
        (should-not (string-match-p "0/272k" text)))
      (setf (pichat-session-context-usage session)
            '(:scope "accumulatedRequests" :inputTokens 3600
              :outputTokens 1000 :roundCount 2 :estimated t))
      (let ((text (pichat-chat--header-text session (selected-window))))
        (should (string-match-p "Requests ↑3.6k ↓1.0k~" text))
        (should-not (string-match-p "Context" text))
        (should (string-match-p "not context-window occupancy"
                                (get-text-property
                                 (string-match "↑" text) 'help-echo text)))))))

(ert-deftest pichat-chat-header-custom-segments-compact-drop-and-isolate-errors ()
  (pichat-test-with-unit-session (session)
    (setf (pichat-session-context-usage session)
          '(:tokens 84000 :contextWindow 272000 :percent 95))
    (let* ((pichat-chat-header-show-directory nil)
           (pichat-chat-header-show-percentage nil)
           (quota (propertize "Plan left 62%" 'face 'success
                              'help-echo "Cached allowance, not context"))
           (pichat-chat-header-functions
            (list (lambda (_runtime _window)
                    '(:id low :text "Low" :priority -1))
                  (lambda (_runtime _window) (error "Broken integration"))
                  (lambda (_runtime _window) nil)
                  (lambda (_runtime _window) '(:id invalid :text "bad\ntext"))
                  (lambda (_runtime _window)
                    (list :id 'oversized :text (make-string 257 ?x)))
                  (lambda (_runtime _window)
                    '(:id invalid-priority :text "bad" :priority "high"))
                  (lambda (runtime window)
                    (should (eq runtime session))
                    (should (window-live-p window))
                    (list :id 'quota :text quota :compact "P:62%"
                          :priority 999)))))
      (dolist (spec '((80 "Plan left 62%" t) (24 "P:62%" nil) (16 nil nil)))
        (cl-letf (((symbol-function 'window-body-width)
                   (lambda (&rest _) (car spec))))
          (let ((text (pichat-chat--header-text session (selected-window))))
            (should (string-suffix-p "Context 84k/272k" text))
            (should (eq 'error (get-text-property
                               (string-match "84k" text) 'face text)))
            (if (cadr spec)
                (should (string-match-p (regexp-quote (cadr spec)) text))
              (should-not (string-match-p "62%" text)))
            (should (eq (not (null (nth 2 spec)))
                        (not (null (string-match-p "Low" text)))))
            (should-not (string-match-p "bad" text))
            (when (= (car spec) 80)
              (should (eq 'success (get-text-property
                                   (string-match "Plan" text) 'face text)))
              (should (string-prefix-p "Plan left 62%  Low" text)))))))))

(ert-deftest pichat-chat-header-custom-configuration-is-buffer-local ()
  (pichat-test-with-unit-session (session)
    (let ((pichat-chat-header-functions
           (list (lambda (_s _w) '(:id global :text "Global cached")))))
      (with-temp-buffer
        (setq-local pichat-chat-header-functions
                    (list (lambda (_s _w) '(:id local :text "Local cached"))))
        (should (string-match-p "Local cached"
                                (pichat-chat--header-text session (selected-window))))
        (should-not (string-match-p "Global cached"
                                    (pichat-chat--header-text session (selected-window)))))
      (with-temp-buffer
        (should (string-match-p "Global cached"
                                (pichat-chat--header-text session (selected-window))))))))

(ert-deftest pichat-chat-header-preserves-literal-percent-and-properties ()
  (pichat-test-with-unit-session (session)
    (with-temp-buffer
      (pichat-chat-mode)
      (setq-local pichat-chat-session session)
      (setq-local pichat-chat-header-functions
                  (list (lambda (_s _w) '(:id quota :text "Plan left 62%"))))
      (setf (pichat-session-runtime-cwd session) "/runtime/100%/project/"
            (pichat-session-context-usage session)
            '(:tokens 84000 :contextWindow 272000 :percent 75))
      (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 120)))
        (let ((construct (pichat-chat--header-line)))
          (dolist (literal '("100%%" "62%%" "75%%"))
            (should (string-match-p (regexp-quote literal) construct)))
          (should (eq 'warning (get-text-property
                                (string-match "84k" construct) 'face construct)))))
      ;; Batch Emacs does not render mode lines; also run this test in the
      ;; isolated non-batch terminal fixture for native %-construct processing.
      (unless noninteractive
        (should (equal (pichat-chat--header-text session (selected-window))
                       (format-mode-line header-line-format nil
                                         (selected-window) (current-buffer))))))))

(ert-deftest pichat-chat-header-cache-refresh-never-edits-transcript ()
  (pichat-test-with-unit-session (session)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((before (buffer-string))
                     (undo buffer-undo-list)
                     (modified (buffer-modified-p))
                     (markers (mapcar #'marker-position
                                      (list pichat-chat--canonical-start
                                            pichat-chat--live-start
                                            pichat-chat--input-start)))
                     (cache "Plan left 62%")
                     (pichat-chat-header-functions
                      (list (lambda (_s _w)
                              (list :id 'quota :text cache)))))
                (setq cache "Plan left 55%")
                (pichat-chat-refresh-header session)
                (should (string-match-p "Plan left 55%"
                                        (pichat-chat--header-text
                                         session (selected-window))))
                (should (equal before (buffer-string)))
                (should (eq undo buffer-undo-list))
                (should (eq modified (buffer-modified-p)))
                (should (equal markers
                               (mapcar #'marker-position
                                       (list pichat-chat--canonical-start
                                             pichat-chat--live-start
                                             pichat-chat--input-start)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-chat-controls)
;;; pichat-test-chat-controls.el ends here
