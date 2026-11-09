;;; pichat-test-chat-bridge-tools.el --- Chats group Emacs-defined tools -*- lexical-binding: t; -*-

;;; Commentary:

;; Contracts for the read-only Chats tools: they describe retained runtimes
;; from cached state and read bounded messages from an open chat's canonical
;; entry cache and live draft, without side effects on chats, runtimes or Jobs.

;;; Code:

(require 'pichat-test-job-support)
(require 'pichat-jobs)
(require 'pichat-chat-tools)
(require 'pichat-tool-bridge)

(defun pichat-test-chat-tool (name &optional params session)
  "Call Chats tool NAME with PARAMS from SESSION.
Return (ERRORP . DECODED-OR-TEXT)."
  (let* ((result (pichat-tools-call (gethash name pichat-tools-registry) params session))
         (value (plist-get result :value)))
    (cons (plist-get result :is-error)
          (if (plist-get result :is-error) value
            (json-parse-string value :object-type 'plist :array-type 'list
                               :null-object nil :false-object :false)))))

(defun pichat-test-chat-tool-ok (name &optional params session)
  "Return NAME's decoded successful result for PARAMS from SESSION."
  (let ((result (pichat-test-chat-tool name params session)))
    (ert-info ((format "%S" (cdr result)))
      (should-not (car result)))
    (cdr result)))

(defconst pichat-test-chat-tools-entries
  `((:type "message" :id "u1" :parentId nil
     :message (:role "user" :content "Please review the parser"))
    (:type "message" :id "a1" :parentId "u1"
     :message (:role "assistant"
               :content ((:type "thinking" :thinking "SECRET THOUGHT")
                         (:type "text" :text "Reading it now.")
                         (:type "toolCall" :id "call-1" :name "read"
                          :arguments (:path "parser.el")))))
    (:type "message" :id "r1" :parentId "a1"
     :message (:role "toolResult" :toolCallId "call-1" :toolName "read"
               :content ((:type "text" :text "SECRET TOOL OUTPUT"))))
    (:type "message" :id "a2" :parentId "r1"
     :message (:role "assistant" :stopReason "aborted"
               :content ((:type "text" :text ,(concat "Found it. " (make-string 1200 ?x)))))))
  "A settled branch with thinking, a tool call and result, and a long reply.")

(defmacro pichat-test-with-chats (&rest body)
  "Run BODY with CHATTY (open chat with transcript) and QUIET (no chat) runtimes."
  (declare (indent 0) (debug t))
  `(pichat-test-with-clean-state
     (pichat-chat-tools-register)
     (let* ((pichat-jobs--executor nil)
            (chatty (pichat-session-make :id "source-a" :name "Parser review" :state 'idle
                                         :cwd "/tmp/project/"
                                         :model '(:provider "pichat-fake" :id "fake-1")))
            (quiet (pichat-session-make :state 'stopped :cwd "/tmp/other/"))
            (buffer (generate-new-buffer " *pichat-chat-tools*")))
       (unwind-protect
           (progn
             (with-current-buffer buffer
               (pichat-chat-mode)
               (setq pichat-chat-session chatty
                     pichat-chat--entry-cache
                     (pichat-pi-entry-cache-full "source-a" nil pichat-test-chat-tools-entries "a2")))
             (setf (pichat-session-buffer chatty) buffer)
             (pichat-register-session chatty)
             (pichat-register-session quiet)
             ,@body)
         (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-tools-register-a-read-only-chats-group ()
  (pichat-test-with-clean-state
    (should (equal '("pichat_chat_read" "pichat_chats_list")
                   (sort (pichat-chat-tools-register) #'string<)))
    (dolist (entry (pichat-tools-catalogue))
      (should (equal "Chats" (plist-get entry :group)))
      (should-not (plist-get entry :mutating)))))

(ert-deftest pichat-chat-tools-list-describes-runtimes-without-starting-jobs ()
  (pichat-test-with-chats
    (with-current-buffer buffer (setq pichat-chat--pending-ui-count 1))
    (let* ((result (pichat-test-chat-tool-ok "pichat_chats_list" nil chatty))
           (chats (plist-get result :chats))
           (first (car chats))
           (second (cadr chats)))
      (should (= 2 (plist-get result :total)))
      (should (equal (pichat-session-runtime-id chatty) (plist-get first :runtime_id)))
      (should (equal "Parser review" (plist-get first :name)))
      (should (equal "/tmp/project/" (plist-get first :directory)))
      (should (equal "idle" (plist-get first :state)))
      (should (equal "pichat-fake/fake-1" (plist-get first :model)))
      (should (eq t (plist-get first :waiting_for_input)))
      (should (eq t (plist-get first :chat_open)))
      (should (eq t (plist-get first :self)))
      (should (equal "stopped" (plist-get second :state)))
      (should (eq :false (plist-get second :chat_open)))
      (should-not (plist-member second :self))
      (should-not (plist-member second :job_run_id))
      ;; Listing never starts the Jobs owner.
      (should-not pichat-jobs--executor))
    (should (string-match-p "Unknown argument"
                            (cdr (pichat-test-chat-tool "pichat_chats_list" '(:limit 5)))))))

(ert-deftest pichat-chat-tools-list-marks-job-workers ()
  (pichat-test-with-job-executor ()
    (pichat-chat-tools-register)
    (let* ((job (pichat-job-save store (pichat-test-job-spec project-dir)))
           (run (pichat-job-enqueue store nil job))
           (claim (pichat-job-claim store run))
           (worker (pichat-session-make :cwd project-dir :session-file "/tmp/worker.jsonl"))
           (pichat-jobs--executor executor)
           (chat (lambda ()
                   (car (plist-get (pichat-test-chat-tool-ok "pichat_chats_list") :chats)))))
      (puthash run (pichat-job-execution--create :executor executor :id run
                                                 :token (plist-get claim :attempt)
                                                 :session worker)
               (pichat-job-executor-contexts executor))
      (pichat-register-session worker)
      (should (equal run (plist-get (funcall chat) :job_run_id)))
      ;; An unnamed worker is named after its job.
      (should (equal "Review files" (plist-get (funcall chat) :name)))
      ;; After the run retires, its record still links the retained runtime...
      (pichat-job-advance store run (plist-get claim :attempt) "running"
                          (list :runtime-id (pichat-session-runtime-id worker)
                                :session-file "/tmp/worker.jsonl"))
      (remhash run (pichat-job-executor-contexts executor))
      (should (equal run (plist-get (funcall chat) :job_run_id)))
      ;; ...but not a runtime that reuses its ID for another Pi session.
      (setf (pichat-session-session-file worker) "/tmp/other.jsonl")
      (should-not (plist-member (funcall chat) :job_run_id))
      (should-not (plist-get (funcall chat) :name)))))

(ert-deftest pichat-chat-tools-read-returns-bounded-settled-messages ()
  (pichat-test-with-chats
    (let* ((id (pichat-session-runtime-id chatty))
           (all (pichat-test-chat-tool-ok "pichat_chat_read" (list :runtime_id id)))
           (messages (plist-get all :messages))
           (assistant (nth 1 messages))
           (last (nth 2 messages)))
      (should (eq t (plist-get all :transcript_available)))
      (should (= 3 (plist-get all :total_messages)))
      (should (= 0 (plist-get all :earlier_omitted)))
      (should (equal '("user" "assistant" "assistant")
                     (mapcar (lambda (m) (plist-get m :role)) messages)))
      (should (equal "Please review the parser" (plist-get (car messages) :text)))
      (should (equal "Reading it now." (plist-get assistant :text)))
      (should (equal '("read") (plist-get assistant :tool_calls)))
      (should (= pichat-chat-tools-message-limit (length (plist-get last :text))))
      (should (eq t (plist-get last :text_truncated)))
      (should (equal "aborted" (plist-get last :stop_reason)))
      ;; Thinking, tool arguments and tool results never leave Emacs.
      (should-not (string-match-p "SECRET\\|parser\\.el" (format "%S" all)))
      (let ((recent (pichat-test-chat-tool-ok "pichat_chat_read" (list :runtime_id id :messages 1))))
        (should (= 1 (length (plist-get recent :messages))))
        (should (= 2 (plist-get recent :earlier_omitted)))))))

(ert-deftest pichat-chat-tools-read-includes-the-reply-in-progress ()
  (pichat-test-with-chats
    (let ((id (pichat-session-runtime-id chatty))
          (draft (with-current-buffer buffer
                   (pichat-live-draft-empty pichat-chat--source-generation))))
      (dolist (event '((:type "message_start" :message (:role "user" :content "Next step?"))
                       (:type "message_end" :message (:role "user" :content "Next step?"))
                       (:type "message_start"
                        :message (:role "assistant"
                                  :content ((:type "text" :text "Working on")
                                            (:type "toolCall" :id "call-2" :name "grep"
                                             :arguments (:pattern "x")))))))
        (pichat-pi-live-draft-apply draft event))
      (with-current-buffer buffer (setq pichat-chat--live-draft draft))
      (let* ((result (pichat-test-chat-tool-ok "pichat_chat_read" (list :runtime_id id :messages 3)))
             (messages (plist-get result :messages)))
        ;; Settled messages first, then the live tail, marked and never duplicated.
        (should (= 5 (plist-get result :total_messages)))
        (should (equal '("assistant" "user" "assistant")
                       (mapcar (lambda (m) (plist-get m :role)) messages)))
        (should-not (plist-member (car messages) :settled))
        (should (equal "Next step?" (plist-get (nth 1 messages) :text)))
        (should (eq :false (plist-get (nth 1 messages) :settled)))
        (should (equal "Working on" (plist-get (nth 2 messages) :text)))
        (should (equal '("grep") (plist-get (nth 2 messages) :tool_calls)))
        (should (eq :false (plist-get (nth 2 messages) :settled))))
      ;; A draft from an earlier source generation is not this chat's tail.
      (with-current-buffer buffer (cl-incf pichat-chat--source-generation))
      (should (= 3 (plist-get (pichat-test-chat-tool-ok "pichat_chat_read" (list :runtime_id id))
                              :total_messages))))))

(ert-deftest pichat-chat-tools-read-has-no-side-effects-and-clear-errors ()
  (pichat-test-with-chats
    (let ((buffers (buffer-list))
          (current (current-buffer))
          (window-buffer (window-buffer))
          (tick (buffer-chars-modified-tick buffer))
          (selected pichat-current-session))
      (pichat-test-chat-tool-ok "pichat_chat_read" (list :runtime_id (pichat-session-runtime-id chatty)))
      ;; A runtime without an open chat has no readable transcript; nothing opens.
      (let ((result (pichat-test-chat-tool-ok "pichat_chat_read"
                                              (list :runtime_id (pichat-session-runtime-id quiet)))))
        (should (eq :false (plist-get result :transcript_available)))
        (should (string-match-p "No open chat buffer" (plist-get result :reason)))
        (should-not (plist-member result :messages)))
      (should (equal buffers (buffer-list)))
      (should (eq current (current-buffer)))
      (should (eq window-buffer (window-buffer)))
      (should (= tick (buffer-chars-modified-tick buffer)))
      (should (eq selected pichat-current-session))
      (should-not (pichat-session-buffer quiet)))
    (dolist (case '(((:runtime_id "pichat-runtime-99") "Unknown runtime ID")
                    ((:runtime_id "../x") "runtime_id must be")
                    ((:runtime_id "pichat-runtime-1" :messages 0) "messages must be")
                    ((:runtime_id "pichat-runtime-1" :messages 31) "messages must be")
                    (nil "Missing required argument: runtime_id")))
      (let ((result (pichat-test-chat-tool "pichat_chat_read" (car case))))
        (should (car result))
        (ert-info ((cdr result))
          (should (string-match-p (cadr case) (cdr result))))))))

;; Integration: an orchestrator chat lists the runtimes and reads another
;; real chat's settled reply.
(when pichat-test-include-integration
  (ert-deftest pichat-integration-chat-tools-list-and-read-another-chat ()
    (pichat-test-with-job-executor ()
      (pichat-test-require-pi)
      (pichat-chat-tools-register)
      (let ((pichat-chat-stop-session-on-kill nil)
            (other-status (expand-file-name "other-status.json" project-dir))
            (status (expand-file-name "orchestrator-status.json" project-dir))
            other orchestrator)
        (unwind-protect
            (progn
              (setq other (pichat-test-start-bridge-chat
                           project-dir '(:turns [(:text "OTHER CHAT SAYS HELLO")]) other-status nil))
              (pichat-test-prompt-and-wait other "say hello")
              (pichat-test-assert-provider-script-consumed other-status)
              (let ((id (pichat-session-runtime-id other)))
                (setq orchestrator
                      (pichat-test-start-bridge-chat
                       project-dir
                       `(:turns
                         [(:expectTool (:name "pichat_chats_list")
                           :toolCall (:id "list" :name "pichat_chats_list"))
                          (:expectContextIncludes [,id "waiting_for_input"]
                           :toolCall (:id "read" :name "pichat_chat_read"
                                      :arguments (:runtime_id ,id :messages 5)))
                          (:expectContextIncludes ["OTHER CHAT SAYS HELLO" "say hello"] :text "read it")])
                       status '("pichat_chat_read" "pichat_chats_list")))
                (pichat-test-prompt-and-wait orchestrator "what are the other chats doing?")
                (pichat-test-assert-provider-script-consumed status)))
          (dolist (chat (list orchestrator other))
            (when chat
              (ignore-errors (pichat-rpc-stop chat))
              (when-let* ((buffer (pichat-session-buffer chat)))
                (when (buffer-live-p buffer) (kill-buffer buffer))))))))))

(provide 'pichat-test-chat-bridge-tools)
;;; pichat-test-chat-bridge-tools.el ends here
