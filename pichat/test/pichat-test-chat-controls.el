;;; pichat-test-chat-controls.el --- PiChat model/thinking control tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for mode-line model and thinking controls.

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
    (should (equal "*PiChat:emacs.mine:019ffc5b*"
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

(ert-deftest pichat-chat-controls-mode-line-compacts-context-with-warnings ()
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

(provide 'pichat-test-chat-controls)
;;; pichat-test-chat-controls.el ends here
