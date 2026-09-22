;;; pichat-test-backend-llm.el --- Native llm backend tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Offline tests around the real pinned llm public lifecycle.  Provider HTTP is
;; always replaced before invocation; no credential, gcloud, or network state is
;; read.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-llm-support)

(defvar pichat-llm-provider)
(defvar pichat-llm-model)
(defvar pichat-llm-reasoning)
(defvar pichat-llm-codex-url)
(defvar pichat-llm-codex-auth-host)
(defvar pichat-llm-codex-auth-user)
(defvar pichat-llm-error-max-chars)
(defvar pichat-backend-llm-capabilities)
(declare-function pichat-test-llm--invoke nil
                  (provider prompt partial-callback final-callback error-callback))
(declare-function pichat-llm-provider-spec-create "pichat-backend-llm"
                  (&rest args))
(declare-function pichat-llm-make-codex-provider "pichat-backend-llm" (model))
(declare-function pichat-llm-make-vertex-gemini-provider
                  "pichat-backend-llm" (project region model &optional gcloud))
(declare-function pichat-llm-make-vertex-claude-provider
                  "pichat-backend-llm" (project region model &optional gcloud))
(declare-function pichat-backend-llm-launch "pichat-backend-llm"
                  (&optional provider model directory))
(declare-function pichat-llm--auth-source-key "pichat-backend-llm"
                  (&optional host user))
(declare-function pichat-llm--require-public-api "pichat-backend-llm" ())
(declare-function pichat-llm--usage-data "pichat-backend-llm" (state))

(when (pichat-test-llm-available-p)
  (pichat-test-llm-install-offline-parser-shims)
  (require 'llm)
  (require 'pichat-backend-llm)

  (cl-defstruct pichat-test-llm-request cancelled)
  (cl-defstruct pichat-test-llm-provider
    scripts calls pending streaming capabilities)
  (cl-defstruct pichat-test-invalid-llm-provider)

  (cl-defmethod llm-name ((_provider pichat-test-llm-provider))
    "offline-test")

  (cl-defmethod llm-capabilities ((provider pichat-test-llm-provider))
    (append (when (pichat-test-llm-provider-streaming provider) '(streaming))
            (copy-sequence
             (pichat-test-llm-provider-capabilities provider))))

  (cl-defmethod llm-capabilities ((_provider pichat-test-invalid-llm-provider))
    (error "Invalid offline provider"))

  (cl-defmethod llm-cancel-request ((request pichat-test-llm-request))
    (setf (pichat-test-llm-request-cancelled request) t))

  (defun pichat-test-llm--invoke
      (provider prompt partial-callback final-callback error-callback)
    "Run PROVIDER's next script against callbacks for PROMPT."
    (let ((request (make-pichat-test-llm-request))
          (script (pop (pichat-test-llm-provider-scripts provider))))
      (setf (pichat-test-llm-provider-calls provider)
            (append (pichat-test-llm-provider-calls provider)
                    (list (list :prompt prompt :request request))))
      (if (eq script 'delayed)
          (setf (pichat-test-llm-provider-pending provider)
                (append
                 (pichat-test-llm-provider-pending provider)
                 (list (list :request request :partial partial-callback
                             :final final-callback :error error-callback))))
        (dolist (event script)
          (pcase (car event)
            ('partial (when partial-callback
                        (funcall partial-callback (cdr event))))
            ('final (funcall final-callback (cdr event)))
            ('error (apply error-callback (cdr event))))))
      request))

  (cl-defmethod llm-chat-streaming
    ((provider pichat-test-llm-provider) prompt partial-callback
     response-callback error-callback &optional _multi-output)
    (pichat-test-llm--invoke
     provider prompt partial-callback response-callback error-callback))

  (cl-defmethod llm-chat-async
    ((provider pichat-test-llm-provider) prompt response-callback error-callback
     &optional _multi-output)
    (pichat-test-llm--invoke
     provider prompt nil response-callback error-callback)))

(defun pichat-test-llm--require ()
  "Require the native backend for one test."
  (pichat-test-require-llm-backend))

(defun pichat-test-llm--session (provider &optional streaming)
  "Return a started native session owning PROVIDER."
  (let* ((spec
          (pichat-llm-provider-spec-create
           :factory (let ((provider provider)) (lambda () provider))
           :label "offline"
           :model "offline-model"
           :streaming (if (null streaming) 'auto streaming)))
         (state
          (pichat-llm-state-create
           :provider-spec spec :source-generation 0 :run-generation 0
           :round-generation 0 :sequence 0))
         (session
          (pichat-session-make
           :backend 'llm :backend-state state :cwd default-directory
           :persistence 'memory)))
    (pichat-backend-start-session session)
    session))

(defun pichat-test-llm--send (buffer text)
  "Send TEXT through native chat BUFFER."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (pichat-chat-send-input)))

(defun pichat-test-llm--journal-texts (session)
  "Return (ROLE TEXT) records from SESSION's local journal."
  (mapcar
   (lambda (entry)
     (let* ((message (plist-get entry :message))
            (content
             (seq-find
              (lambda (part) (equal (plist-get part :type) "text"))
              (plist-get message :content))))
       (list (plist-get message :role) (or (plist-get content :text) ""))))
   (pichat-llm-state-journal (pichat-session-backend-state session))))

(defun pichat-test-llm--buffer-count (buffer text)
  "Count literal TEXT occurrences in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((count 0))
        (while (search-forward text nil t) (cl-incf count))
        count))))

(ert-deftest pichat-backend-contract-inline-completion-does-not-leak-submission ()
  "Inline completion is accepted first and cannot resurrect pending state."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t
             :scripts '(((partial . (:text "inline"))
                         (final . (:text "inline final"))))))
           (session (pichat-test-llm--session provider))
           (pichat-chat-stop-session-on-kill nil)
           buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (pichat-test-llm--send buffer "first")
            (with-current-buffer buffer
              (should (= 0 (hash-table-count
                            pichat-chat--pending-submissions)))
              (should (= 0 (hash-table-count
                            pichat-chat--in-flight-attachments)))
              (should (string-empty-p (pichat-chat--input-text))))
            (should (equal (pichat-test-llm--journal-texts session)
                           '(("user" "first")
                             ("assistant" "inline final"))))
            (should (eq 'idle (pichat-session-state session))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-contract-capability-rejection-preserves-draft ()
  "Images, concurrent sends, and Pi commands reject before editor mutation."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           (pichat-chat-stop-session-on-kill nil)
           buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (with-current-buffer buffer
              (let (read-called)
                (cl-letf (((symbol-function 'pichat-attachments-read-image-file)
                           (lambda (&rest _args)
                             (setq read-called t)
                             (error "must not read"))))
                  (should-error
                   (pichat-chat-attach-image-file "/not/read.png")
                   :type 'user-error)
                  (should-not read-called)))
              (setq pichat-chat--pending-attachments
                    '((:id "image" :name "offline.png" :bytes 1
                           :data "AA==" :mimeType "image/png")))
              (insert "image draft")
              (should-error (pichat-chat-send-input) :type 'user-error)
              (should (equal "image draft" (pichat-chat--input-text)))
              (should (= 1 (length pichat-chat--pending-attachments)))
              (should-not pichat-chat--prompt-history)
              (setq pichat-chat--pending-attachments nil)
              (pichat-chat-send-input)
              (insert "second draft")
              (should-error (pichat-chat-send-input) :type 'user-error)
              (should (equal "second draft" (pichat-chat--input-text)))
              (should-error (pichat-chat-compact) :type 'user-error)
              (should-error (pichat-command-run session) :type 'user-error)
              (should (= 1 (length pichat-chat--prompt-history))))
            (should (= 1 (length
                          (pichat-llm-state-journal
                           (pichat-session-backend-state session))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-contract-acceptance-is-not-settlement ()
  "Acceptance commits the user while final settlement remains independent."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           (state (pichat-session-backend-state session))
           (settlements 0)
           accepted)
      (pichat-on 'agent-settled
                 (lambda (&rest _args) (cl-incf settlements)) session)
      (pichat-backend-submit-prompt
       session "accepted"
       nil nil (lambda (&rest _args) (setq accepted t)) #'ignore)
      (should accepted)
      (should (eq 'running (pichat-session-state session)))
      (should (= settlements 0))
      (should (equal (pichat-test-llm--journal-texts session)
                     '(("user" "accepted"))))
      (let ((pending (car (pichat-test-llm-provider-pending provider))))
        (funcall (plist-get pending :final) '(:text "settled")))
      (should (= settlements 1))
      (should (eq 'idle (pichat-session-state session)))
      (should (equal (pichat-llm-state-leaf-id state)
                     (plist-get (car (last (pichat-llm-state-journal state)))
                                :id)))
      (pichat-backend-stop-session session))))

(ert-deftest pichat-backend-contract-cancel-query-is-not-abort-run ()
  "Snapshot cancellation is distinct from aborting the provider request."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           query model-request
           (settlements 0))
      (pichat-on 'agent-settled
                 (lambda (&rest _args) (cl-incf settlements)) session)
      (pichat-backend-submit-prompt session "wait" nil nil #'ignore #'ignore)
      (setq model-request
            (plist-get (car (pichat-test-llm-provider-pending provider))
                       :request)
            query (pichat-backend-get-transcript
                   session nil #'ignore #'ignore))
      (pichat-backend-cancel-owned-request session query)
      (should (pichat-llm-query-cancelled query))
      (should-not (pichat-test-llm-request-cancelled model-request))
      (pichat-backend-abort-session session)
      (should (pichat-test-llm-request-cancelled model-request))
      (should (= settlements 1))
      (let ((pending (car (pichat-test-llm-provider-pending provider))))
        (funcall (plist-get pending :final) '(:text "late"))
        (funcall (plist-get pending :error) 'error "late secret"))
      (should (= settlements 1))
      (should-not (string-match-p
                   "late"
                   (format "%S" (pichat-test-llm--journal-texts session))))
      (pichat-backend-stop-session session))))

(ert-deftest pichat-backend-contract-source-rebind-rejects-old-callbacks ()
  "New conversations and stop invalidate delayed callbacks and isolate state."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider-a
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (provider-a-rebound
            (make-pichat-test-llm-provider
             :streaming t
             :scripts '(((final . (:text "fresh conversation"))))))
           (provider-a-queue (list provider-a provider-a-rebound))
           (provider-a-spec
            (pichat-llm-provider-spec-create
             :factory (lambda () (pop provider-a-queue))
             :label "offline" :model "offline-model" :streaming t))
           (provider-b
            (make-pichat-test-llm-provider
             :streaming t
             :scripts '(((final . (:text "independent"))))))
           (session-a (pichat-test-llm--session-from-spec provider-a-spec))
           (session-b (pichat-test-llm--session provider-b))
           (old-id (pichat-session-id session-a)))
      (unwind-protect
          (progn
            (pichat-backend-submit-prompt
             session-a "old" nil nil #'ignore #'ignore)
            (let ((pending
                   (car (pichat-test-llm-provider-pending provider-a))))
              (pichat-backend-start-new-conversation session-a #'ignore)
              (should-not (equal old-id (pichat-session-id session-a)))
              (should
               (eq provider-a-rebound
                   (pichat-llm-state-provider
                    (pichat-session-backend-state session-a))))
              (should-not
               (eq provider-a
                   (pichat-llm-state-provider
                    (pichat-session-backend-state session-a))))
              (should-not provider-a-queue)
              (funcall (plist-get pending :partial) '(:text "stale"))
              (funcall (plist-get pending :final) '(:text "stale final")))
            (should-not
             (pichat-llm-state-journal
              (pichat-session-backend-state session-a)))
            (pichat-backend-submit-prompt
             session-a "fresh" nil nil #'ignore #'ignore)
            (should (equal (pichat-test-llm--journal-texts session-a)
                           '(("user" "fresh")
                             ("assistant" "fresh conversation"))))
            (pichat-backend-submit-prompt
             session-b "other" nil nil #'ignore #'ignore)
            (should-not
             (eq (pichat-llm-state-prompt
                  (pichat-session-backend-state session-a))
                 (pichat-llm-state-prompt
                  (pichat-session-backend-state session-b))))
            (should-not
             (eq (pichat-llm-state-provider
                  (pichat-session-backend-state session-a))
                 (pichat-llm-state-provider
                  (pichat-session-backend-state session-b))))
            (pichat-backend-stop-session session-a)
            (should-not
             (pichat-llm-state-provider
              (pichat-session-backend-state session-a)))
            (should-not
             (pichat-llm-state-prompt
              (pichat-session-backend-state session-a))))
        (pichat-backend-stop-session session-a)
        (pichat-backend-stop-session session-b)))))

(ert-deftest pichat-backend-contract-streaming-chunks-settle-authoritatively ()
  "Cumulative snapshots and final correction produce one canonical outcome."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t
             :scripts
             '(((partial . (:text "one"))
                (partial . (:text "one"))
                (partial . (:input-tokens 2))
                (partial . (:text "one two"))
                (final . (:text "corrected")))
               ((final)))))
           (session (pichat-test-llm--session provider))
           (pichat-chat-stop-session-on-kill nil)
           (settlements 0)
           buffer)
      (pichat-on 'agent-settled
                 (lambda (&rest _args) (cl-incf settlements)) session)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (pichat-test-llm--send buffer "first")
            (should (= settlements 1))
            (should (= 1 (pichat-test-llm--buffer-count buffer "corrected")))
            (should (= 0 (pichat-test-llm--buffer-count buffer "one two")))
            (with-current-buffer buffer (pichat-chat-repaint))
            (should (= 1 (pichat-test-llm--buffer-count buffer "corrected")))
            (pichat-test-llm--send buffer "second")
            (should (= settlements 2))
            (should (equal (pichat-test-llm--journal-texts session)
                           '(("user" "first") ("assistant" "corrected")
                             ("user" "second") ("assistant" ""))))
            (let ((prompts
                   (mapcar (lambda (call) (plist-get call :prompt))
                           (pichat-test-llm-provider-calls provider))))
              (should (eq (car prompts) (cadr prompts))))
            (let* ((usage
                    (pichat-llm--usage-data
                     (pichat-session-backend-state session)))
                   (rounds (append (plist-get usage :usageRounds) nil)))
              (should (equal (plist-get usage :usageStatus) "reported"))
              (should (equal (mapcar (lambda (round)
                                      (plist-get round :status))
                                    rounds)
                             '("reported" "missing")))
              (should (= (plist-get (plist-get usage :contextUsage)
                                    :reportedRoundCount)
                         1))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-reasoning-usage-and-canonical-views ()
  "Normalize reasoning corrections and reported usage through shared views."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :capabilities '(reasoning) :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           (state (pichat-session-backend-state session))
           (pichat-chat-stop-session-on-kill nil)
           updates buffer export-buffer compose-buffer)
      (pichat-on
       'message-update
       (lambda (_session _event plist)
         (push (plist-get (plist-get plist :raw) :message) updates))
       session)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (pichat-test-llm--send buffer "explain")
            (let ((pending
                   (car (pichat-test-llm-provider-pending provider))))
              (funcall (plist-get pending :partial)
                       '(:reasoning "draft reason"))
              (funcall (plist-get pending :partial)
                       '(:text "draft answer" :input-tokens 10))
              ;; An absent :text preserves its prior cumulative snapshot.
              (funcall (plist-get pending :partial)
                       '(:reasoning "revised reason" :output-tokens 3))
              (funcall (plist-get pending :final)
                       '(:reasoning "final reason" :text "final answer"
                         :input-tokens 12 :output-tokens 4)))
            (should (= 3 (length updates)))
            (let* ((assistant
                    (plist-get
                     (car (last (pichat-llm-state-journal state))) :message))
                   (content (plist-get assistant :content)))
              (should (equal (mapcar (lambda (part) (plist-get part :type))
                                     content)
                             '("thinking" "text")))
              (should (equal (plist-get (car content) :thinking)
                             "final reason"))
              (should (equal (plist-get (cadr content) :text)
                             "final answer")))
            (should
             (equal (pichat-session-context-usage session)
                    '(:kind "reported" :scope "accumulatedRequests"
                      :estimated nil :tokens 16 :inputTokens 12
                      :outputTokens 4 :roundCount 1
                      :reportedRoundCount 1)))
            (with-current-buffer buffer
              (let ((response
                     (pichat-chat-navigation-select-response
                      pichat-chat--canonical-transcript nil '(native))))
                (should (equal
                         (pichat-chat-navigation-response-markdown response)
                         "final answer")))
              (setq export-buffer
                    (pichat-chat-navigation-export-buffer
                     pichat-chat--canonical-transcript "native")))
            (with-current-buffer export-buffer
              (should (string-match-p "\\*\\*Thinking\\*\\*"
                                      (buffer-string)))
              (should (string-match-p "final reason" (buffer-string)))
              (should (string-match-p "final answer" (buffer-string))))
            (let ((pichat-chat-show-thinking t)
                  (pichat-chat-activity-group-display 'collapsed))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (should (= 0 (pichat-test-llm--buffer-count
                          buffer "final reason")))
            (let ((pichat-chat-show-thinking t)
                  (pichat-chat-activity-group-display 'expanded))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (should (= 1 (pichat-test-llm--buffer-count
                          buffer "final reason")))
            (let ((pichat-chat-show-thinking nil))
              (with-current-buffer buffer (pichat-chat-repaint)))
            (should (= 0 (pichat-test-llm--buffer-count
                          buffer "final reason")))
            (should (= 1 (pichat-test-llm--buffer-count
                          buffer "final answer")))
            (with-current-buffer buffer
              (let ((status (pichat-chat--mode-line-status)))
                (should (string-match-p "offline/offline-model" status))
                (should (string-match "↑12 ↓4" status))
                (should (string-match-p
                         "not context-window occupancy"
                         (get-text-property (match-beginning 0)
                                            'help-echo status))))
              (goto-char (marker-position pichat-chat--canonical-start))
              (search-forward "final answer"
                              (marker-position pichat-chat--canonical-end))
              (pichat-chat-previous-user-turn)
              (should (eq (get-text-property (point) 'pichat-node-role)
                          'user))
              (goto-char (point-max))
              (insert "compose draft")
              (setq compose-buffer (pichat-chat-open-compose-buffer)))
            (with-current-buffer compose-buffer
              (should (equal (buffer-string) "compose draft")))
            (with-current-buffer buffer
              (let ((copied
                     (buffer-substring-no-properties
                      (marker-position pichat-chat--canonical-start)
                      (marker-position pichat-chat--canonical-end))))
                (kill-new copied)
                (should (string-match-p "final answer" (current-kill 0 t))))))
        (when (buffer-live-p compose-buffer) (kill-buffer compose-buffer))
        (when (buffer-live-p export-buffer) (kill-buffer export-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-image-media-and-recovery ()
  "Convert bounded images to owned media and preserve rejection recovery."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((bytes (encode-coding-string "offline-image-bytes" 'binary))
           (attachment
            (list :id "image-1" :type "image" :name "offline.png"
                  :bytes (length bytes) :mimeType "image/png"
                  :data (base64-encode-string bytes t)))
           (provider
            (make-pichat-test-llm-provider
             :streaming nil :capabilities '(image-input)
             :scripts '(((final . (:text "seen")))
                       ((error error "image request rejected")))))
           (session (pichat-test-llm--session provider nil))
           (pichat-chat-stop-session-on-kill nil)
           buffer)
      (unwind-protect
          (progn
            (should (pichat-backend-capable-p session 'image-input))
            (setq buffer (pichat-chat-open session t))
            (with-current-buffer buffer
              (let ((invalid (copy-tree attachment)))
                (setq invalid (plist-put invalid :data "%%%")
                      pichat-chat--pending-attachments (list invalid))
                (goto-char (point-max))
                (insert "invalid image")
                (should-error (pichat-chat-send-input) :type 'user-error)
                (should (equal (pichat-chat--input-text) "invalid image"))
                (should (equal pichat-chat--pending-attachments
                               (list invalid)))
                (pichat-chat--set-input-text ""))
              (setq pichat-chat--pending-attachments (list attachment))
              (goto-char (point-max))
              (insert "inspect")
              (pichat-chat-send-input))
            (let* ((prompt
                    (plist-get
                     (car (pichat-test-llm-provider-calls provider)) :prompt))
                   (interaction (car (llm-chat-prompt-interactions prompt)))
                   (multipart
                    (llm-chat-prompt-interaction-content interaction))
                   (parts (llm-multipart-parts multipart))
                   (media (cadr parts)))
              (should (equal (car parts) "inspect"))
              (should (llm-media-p media))
              (should (equal (llm-media-mime-type media) "image/png"))
              (should (equal (llm-media-data media) bytes)))
            (let* ((user-entry
                    (car (pichat-llm-state-journal
                          (pichat-session-backend-state session))))
                   (content (plist-get (plist-get user-entry :message) :content))
                   (image (cadr content)))
              (should (equal (plist-get image :type) "image"))
              (should-not (plist-member image :data)))
            (should (= 1 (pichat-test-llm--buffer-count buffer "[image]")))
            (should (= 0 (pichat-test-llm--buffer-count
                          buffer "aW1hZ2U=")))
            (with-current-buffer buffer
              (setq pichat-chat--pending-attachments (list attachment))
              (goto-char (point-max))
              (insert "recover image")
              (pichat-chat-send-input)
              (should (equal (pichat-chat--input-text) "recover image"))
              (should (equal pichat-chat--pending-attachments
                             (list attachment)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-provider-capabilities-change-on-rebind ()
  "A fresh provider atomically replaces image capability and clears usage."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((plain (make-pichat-test-llm-provider :streaming nil))
           (vision
            (make-pichat-test-llm-provider
             :streaming nil :capabilities '(image-input reasoning)))
           (providers (list plain vision))
           (spec
            (pichat-llm-provider-spec-create
             :factory (lambda () (pop providers))
             :label "changing" :model "changing-model" :streaming nil))
           (session (pichat-test-llm--session-from-spec spec)))
      (unwind-protect
          (progn
            (should-not (pichat-backend-capable-p session 'image-input))
            (should-not (pichat-backend-capable-p session 'reasoning-output))
            (pichat-backend-start-new-conversation session #'ignore)
            (should (pichat-backend-capable-p session 'image-input))
            (should (pichat-backend-capable-p session 'reasoning-output))
            (should (equal (plist-get (pichat-session-model session) :input)
                           '("image")))
            (should-not (pichat-session-context-usage session)))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-prompt-undo-isolates-projection ()
  "Undo edits only the draft after native live and canonical projection."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           (pichat-chat-stop-session-on-kill nil)
           buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (pichat-test-llm--send buffer "project safely")
            (let ((pending
                   (car (pichat-test-llm-provider-pending provider))))
              (funcall (plist-get pending :partial) '(:text "live text"))
              (funcall (plist-get pending :final) '(:text "canonical text")))
            (with-current-buffer buffer
              (buffer-enable-undo)
              (setq buffer-undo-list nil)
              (goto-char (point-max))
              (insert "draft")
              (undo-boundary)
              ;; Native transcript synchronization is synchronous here.  Its
              ;; canonical repaint must not enter the prompt's undo history.
              (pichat-chat-repaint)
              (let ((inhibit-message t)) (undo 1))
              (should (string-empty-p (pichat-chat--input-text))))
            (should (= 1 (pichat-test-llm--buffer-count
                          buffer "canonical text")))
            (should (equal (pichat-test-llm--journal-texts session)
                           '(("user" "project safely")
                             ("assistant" "canonical text")))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-nonstreaming-errors-and-draft-recovery ()
  "Non-streaming text works and inline rejection restores the exact draft."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming nil
             :scripts '(((final . (:text "async result")))
                       ((error error "Bearer top-secret")))))
           (session (pichat-test-llm--session provider nil))
           (pichat-chat-stop-session-on-kill nil)
           buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session t))
            (pichat-test-llm--send buffer "one")
            (pichat-test-llm--send buffer "restore exactly")
            (with-current-buffer buffer
              (should (equal "restore exactly" (pichat-chat--input-text)))
              (should (= 0 (hash-table-count
                            pichat-chat--pending-submissions))))
            (should-not
             (string-match-p
              "top-secret"
              (format "%S"
                      (pichat-llm-state-journal
                       (pichat-session-backend-state session))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-errors-redact-ui-and-retain-explicit-detail ()
  "Bound normal errors while retaining raw detail only for explicit inspection."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (session (pichat-test-llm--session provider))
           (secret "Bearer provider-secret")
           diagnostic)
      (unwind-protect
          (progn
            (pichat-backend-submit-prompt
             session "fail" nil nil #'ignore #'ignore)
            (let ((pending
                   (car (pichat-test-llm-provider-pending provider))))
              (funcall (plist-get pending :error)
                       'llm-provider-error
                       (concat secret " " (make-string 800 ?x))))
            (setq diagnostic (car (pichat-session-diagnostics session)))
            (should (equal (plist-get diagnostic :origin) 'llm-provider))
            (should (string-match-p "provider-secret"
                                    (plist-get diagnostic :message)))
            (should-not (string-match-p
                         "provider-secret"
                         (plist-get diagnostic :summary)))
            (let ((details (pichat-show-transport-diagnostics session)))
              (unwind-protect
                  (with-current-buffer details
                    (should (string-match-p "provider-secret"
                                            (buffer-string))))
                (when (buffer-live-p details) (kill-buffer details))))
            (let* ((assistant
                    (plist-get
                     (car (last (pichat-llm-state-journal
                                 (pichat-session-backend-state session))))
                     :message))
                   (error-message (plist-get assistant :errorMessage)))
              (should-not (string-match-p "provider-secret" error-message))
              (should (<= (length error-message)
                          pichat-llm-error-max-chars))))
        (pichat-backend-stop-session session)))))

(defun pichat-test-llm--openai-response (text)
  "Return an OpenAI-compatible reasoning fixture containing TEXT."
  `((choices . [((message . ((content . ,text)
                             (reasoning_content . ,(concat "why " text)))))])
    (usage . ((prompt_tokens . 3) (completion_tokens . 2)))))

(defun pichat-test-llm--gemini-response (text)
  "Return a Vertex Gemini thought fixture containing TEXT."
  `((candidates . [((content . ((role . "model")
                                (parts . [((thought . t)
                                           (text . ,(concat "why " text))
                                           (thoughtSignature . "thought-signature"))
                                          ((text . ,text))]))))])
    (usageMetadata . ((promptTokenCount . 3)
                      (candidatesTokenCount . 2)))))

(defun pichat-test-llm--claude-response (text)
  "Return a signed/redacted Vertex Claude fixture containing TEXT."
  `((content . [((type . "thinking")
                 (thinking . ,(concat "why " text))
                 (signature . ,(concat "signature-" text)))
                ((type . "redacted_thinking")
                 (data . ,(concat "redacted-" text)))
                ((type . "text") (text . ,text))])
    (usage . ((input_tokens . 3) (output_tokens . 2)))))

(defun pichat-test-llm--submit-twice (session &optional first-images)
  "Submit two inline-completing turns to SESSION, with FIRST-IMAGES."
  (pichat-backend-submit-prompt
   session "first" first-images nil #'ignore #'ignore)
  (pichat-backend-submit-prompt session "second" nil nil #'ignore #'ignore))

(ert-deftest pichat-backend-llm-mandatory-provider-two-turn-fixtures ()
  "Codex proxy, Vertex Gemini, and Vertex Claude build offline two-turn calls."
  (pichat-test-llm--require)
  (require 'llm-openai)
  (require 'llm-vertex)
  (require 'pichat-llm-vertex-claude)
  (let ((llm-warn-on-nonfree nil)
        (pichat-llm-codex-url "https://proxy.example.test/v1")
        (pichat-llm-codex-auth-host "proxy.example.test")
        (pichat-llm-codex-auth-user "fixture-user")
        (secret "offline-api-key")
        (images [(:type "image" :data "aW1hZ2U=" :mimeType "image/png")])
        codex-calls gemini-calls claude-calls gemini-provider
        provider-journals provider-usages)
    ;; Codex through the fixed authenticated HTTPS endpoint.
    (cl-letf (((symbol-function 'auth-source-pick-first-password)
               (lambda (&rest args)
                 (should (equal (plist-get args :host)
                                "proxy.example.test"))
                 (should (equal (plist-get args :user) "fixture-user"))
                 secret))
              ((symbol-function 'llm-request-plz-async)
               (lambda (url &rest args)
                 (push (cons url args) codex-calls)
                 (funcall (plist-get args :on-success)
                          (pichat-test-llm--openai-response
                           (if (cdr codex-calls) "codex-2" "codex-1")))
                 (make-pichat-test-llm-request))))
      (let* ((spec (pichat-llm-make-codex-provider "gpt-5.3-codex"))
             (_ (setf (pichat-llm-provider-spec-streaming spec) nil))
             (session
              (pichat-test-llm--session-from-spec spec)))
        (unwind-protect
            (progn
              (pichat-test-llm--submit-twice session images)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals)
              (push (pichat-llm--usage-data
                     (pichat-session-backend-state session))
                    provider-usages))
          (pichat-backend-stop-session session))))
    (setq codex-calls (nreverse codex-calls))
    (should (= 2 (length codex-calls)))
    (dolist (call codex-calls)
      (should (equal (car call)
                     "https://proxy.example.test/v1/chat/completions"))
      (should (equal (cdr (assoc "Authorization"
                                 (plist-get (cdr call) :headers)))
                     (concat "Bearer " secret))))
    (should (= 3 (length
                  (plist-get (plist-get (cdr (cadr codex-calls)) :data)
                             :messages))))
    (let ((payload (format "%S" (plist-get (cdr (car codex-calls)) :data))))
      (should (string-match-p "image_url" payload))
      (should (string-match-p "aW1hZ2U=" payload)))
    ;; Gemini snapshots documented global settings for each request.
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_name) "/offline/gcloud"))
              ((symbol-function 'shell-command-to-string)
               (lambda (command)
                 (should (string-prefix-p
                          "offline-gcloud auth print-access-token" command))
                 "offline-vertex-token\n"))
              ((symbol-function 'llm-request-plz-async)
               (lambda (url &rest args)
                 (push (cons url args) gemini-calls)
                 (funcall (plist-get args :on-success)
                          (pichat-test-llm--gemini-response
                           (if (cdr gemini-calls) "gemini-2" "gemini-1")))
                 (make-pichat-test-llm-request))))
      (let ((session
             (pichat-test-llm--session-from-spec
              (pichat-llm-make-vertex-gemini-provider
               "project" "us-east5" "gemini-2.5-pro" "offline-gcloud"))))
        (unwind-protect
            (progn
              (setq gemini-provider
                    (pichat-llm-state-provider
                     (pichat-session-backend-state session)))
              (pichat-test-llm--submit-twice session images)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals)
              (push (pichat-llm--usage-data
                     (pichat-session-backend-state session))
                    provider-usages))
          (pichat-backend-stop-session session))))
    (setq gemini-calls (nreverse gemini-calls))
    (should (= 2 (length gemini-calls)))
    (dolist (call gemini-calls)
      (should (string-match-p
               "us-east5-aiplatform.*projects/project/locations/us-east5.*gemini-2.5-pro:generateContent"
               (car call))))
    (let ((payload (format "%S" (plist-get (cdr (car gemini-calls)) :data))))
      (should (string-match-p "inline_data" payload))
      (should (string-match-p "aW1hZ2U=" payload)))
    ;; Gemini tool thought signatures are provider-owned opaque state.  Verify
    ;; the provider round-trip without enabling PiChat's Phase 4 tool loop.
    (let* ((response
            '((candidates
               . [((content
                    . ((parts
                        . [((functionCall
                             . ((name . "lookup")
                                (args . ((key . "value")))))
                            (thoughtSignature . "gemini-signature"))]))))])))
           (uses (llm-provider-extract-tool-uses gemini-provider response))
           (prompt (llm-make-chat-prompt "tool fixture")))
      (llm-provider-populate-tool-uses gemini-provider prompt uses)
      (let ((payload (format "%S"
                             (llm-provider-chat-request
                              gemini-provider prompt nil))))
        (should (string-match-p "gemini-signature" payload)))
      (should-not (memq 'tools pichat-backend-llm-capabilities)))
    ;; Claude uses regional Anthropic rawPredict and a process-file token seam.
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_name) "/offline/gcloud"))
              ((symbol-function 'process-file)
               (lambda (_program _in _destination _display &rest args)
                 (should (equal args '("auth" "print-access-token")))
                 (insert "offline-claude-token\n")
                 0))
              ((symbol-function 'llm-request-plz-async)
               (lambda (url &rest args)
                 (push (cons url args) claude-calls)
                 (funcall (plist-get args :on-success)
                          (pichat-test-llm--claude-response
                           (if (cdr claude-calls) "claude-2" "claude-1")))
                 (make-pichat-test-llm-request))))
      (let* ((spec
              (pichat-llm-make-vertex-claude-provider
               "project" "europe-west1"
               "claude-sonnet-4-5@20250929" "offline-gcloud"))
             (_ (setf (pichat-llm-provider-spec-streaming spec) nil))
             (session (pichat-test-llm--session-from-spec spec)))
        (unwind-protect
            (progn
              (setf (pichat-llm-state-reasoning
                     (pichat-session-backend-state session))
                    'medium)
              (pichat-test-llm--submit-twice session images)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals)
              (push (pichat-llm--usage-data
                     (pichat-session-backend-state session))
                    provider-usages))
          (pichat-backend-stop-session session))))
    (setq claude-calls (nreverse claude-calls))
    (should (= 2 (length claude-calls)))
    (dolist (call claude-calls)
      (should (string-match-p
               "europe-west1-aiplatform.*publishers/anthropic/models/claude-sonnet-4-5@20250929:rawPredict"
               (car call))))
    (let* ((request (plist-get (cdr (car claude-calls)) :data))
           (payload (format "%S" request)))
      (should (string-match-p (regexp-quote ":type \"image\"") payload))
      (should (string-match-p "aW1hZ2U=" payload))
      (should (equal (plist-get request :thinking)
                     '(:type "enabled" :budget_tokens 2048))))
    (should-not
     (string-match-p
      (regexp-opt (list secret "offline-vertex-token" "offline-claude-token"
                        "aW1hZ2U="))
      (format "%S" provider-journals)))
    (should (= 3 (length provider-journals)))
    (dolist (journal provider-journals)
      (let* ((assistant
              (plist-get (nth 1 journal) :message))
             (types
              (mapcar (lambda (part) (plist-get part :type))
                      (plist-get assistant :content))))
        ;; llm.el's non-streaming multi-output plist exposes :text before
        ;; :reasoning for these providers; preserve that observable order.
        (should (equal types '("text" "thinking")))))
    (dolist (usage provider-usages)
      (should (equal (plist-get usage :usageStatus) "reported"))
      (let ((context (plist-get usage :contextUsage)))
        (should (equal (plist-get context :kind) "reported"))
        (should (equal (plist-get context :scope) "accumulatedRequests"))
        (should-not (plist-get context :estimated))
        (should (= (plist-get context :inputTokens) 6))
        ;; llm.el 0.32.1's compatible Chat Completions extractor omits
        ;; completion tokens; do not fabricate them.  Vertex reports both.
        (should (memq (plist-get context :outputTokens) '(nil 4)))
        (should (= (plist-get context :tokens)
                   (+ (or (plist-get context :inputTokens) 0)
                      (or (plist-get context :outputTokens) 0))))
        (should (= (plist-get context :roundCount) 2))
        (should (= (plist-get context :reportedRoundCount) 2))))
    (let* ((second-request (plist-get (cdr (cadr claude-calls)) :data))
           (messages (plist-get second-request :messages))
           (assistant-content (plist-get (aref messages 1) :content)))
      (should (equal (mapcar (lambda (part) (plist-get part :type))
                             (append assistant-content nil))
                     '("thinking" "redacted_thinking" "text")))
      (should (string-prefix-p
               "signature-"
               (plist-get (aref assistant-content 0) :signature))))))

(defun pichat-test-llm--session-from-spec (spec)
  "Return a started native session using provider SPEC."
  (let* ((state
          (pichat-llm-state-create
           :provider-spec spec :source-generation 0 :run-generation 0
           :round-generation 0 :sequence 0))
         (session
          (pichat-session-make
           :backend 'llm :backend-state state :cwd default-directory
           :persistence 'memory)))
    (pichat-backend-start-session session)
    session))

(ert-deftest pichat-backend-llm-provider-resolution-and-rebind-failure ()
  "Resolve nested specs and preserve the conversation if replacement fails."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t
             :scripts '(((final . (:text "settled"))))))
           (nested
            (pichat-llm-provider-spec-create
             :factory (lambda () provider)
             :label "nested" :model "nested-model" :streaming t))
           (source
            (pichat-llm-provider-spec-create
             :factory (lambda () nested)
             :model "nested-model" :streaming 'auto))
           (session (pichat-test-llm--session-from-spec source))
           (state (pichat-session-backend-state session)))
      (unwind-protect
          (progn
            (should (eq source (pichat-llm-state-provider-spec state)))
            (should (eq provider (pichat-llm-state-provider state)))
            (should (equal "nested-model" (pichat-llm-state-model state)))
            (pichat-backend-submit-prompt
             session "keep this" nil nil #'ignore #'ignore)
            (let ((old-id (pichat-session-id session))
                  (old-prompt (pichat-llm-state-prompt state))
                  (old-journal (copy-tree (pichat-llm-state-journal state) t)))
              ;; SOURCE deliberately returns the already claimed provider.  A
              ;; failed replacement must be atomic and retain the old source.
              (should-error
               (pichat-backend-start-new-conversation session #'ignore)
               :type 'user-error)
              (should (pichat-session-alive-p session))
              (should (equal old-id (pichat-session-id session)))
              (should (eq provider (pichat-llm-state-provider state)))
              (should (eq old-prompt (pichat-llm-state-prompt state)))
              (should (equal old-journal (pichat-llm-state-journal state)))))
        (pichat-backend-stop-session session)))
    (let ((mismatched
           (pichat-llm-provider-spec-create
            :model "outer-model"
            :factory
            (lambda ()
              (pichat-llm-provider-spec-create
               :model "inner-model"
               :factory
               (lambda ()
                 (make-pichat-test-llm-provider :streaming t)))))))
      (should-error (pichat-test-llm--session-from-spec mismatched)
                    :type 'user-error))))

(ert-deftest pichat-backend-llm-public-api-compatibility-guard ()
  "Reject an llm installation missing a required public function."
  (pichat-test-llm--require)
  (let ((definition (symbol-function 'llm-name)))
    (unwind-protect
        (progn
          (fmakunbound 'llm-name)
          (should-error (pichat-llm--require-public-api)
                        :type 'user-error))
      (fset 'llm-name definition)))
  (should (pichat-llm--require-public-api)))

(ert-deftest pichat-backend-llm-provider-setup-errors-are-bounded ()
  "Reject missing credentials, executables, and invalid factory products."
  (pichat-test-llm--require)
  (let ((pichat-llm-codex-url nil)
        (pichat-llm-codex-auth-host nil))
    (should-error (pichat-llm-make-codex-provider "model")
                  :type 'user-error))
  (cl-letf (((symbol-function 'auth-source-pick-first-password)
             (lambda (&rest _args) nil)))
    (should-error (pichat-llm--auth-source-key "proxy.example.test" "user")
                  :type 'user-error))
  (dolist (spec
           (list
            (pichat-llm-make-vertex-gemini-provider
             "project" "region" "model" "/missing/pichat-gcloud")
            (pichat-llm-make-vertex-claude-provider
             "project" "region" "model" "/missing/pichat-gcloud")
            (pichat-llm-provider-spec-create
             :model "model" :factory (lambda () nil))
            (pichat-llm-provider-spec-create
             :model "model"
             :factory (lambda () (make-pichat-test-invalid-llm-provider)))))
    (let ((message
           (condition-case err
               (progn
                 (pichat-test-llm--session-from-spec spec)
                 nil)
             (user-error (error-message-string err)))))
      (should (stringp message))
      (should (<= (length message) (+ pichat-llm-error-max-chars 80))))))

(ert-deftest pichat-backend-llm-launch-config-and-local-naming ()
  "Launch configuration fails cleanly and native naming remains local."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let ((pichat-llm-provider nil)
          (pichat-llm-model nil))
      (should-error (pichat-backend-llm-launch nil nil default-directory)
                    :type 'user-error)
      (should-not (pichat-session-list)))
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t
             :scripts '(((final . (:text "named"))))))
           (session (pichat-test-llm--session provider)))
      (unwind-protect
          (progn
            (pichat-backend-name-session session "Local name" #'ignore)
            (should (equal (pichat-session-name session) "Local name"))
            (should (eq 'memory (pichat-session-persistence session)))
            (should-not (pichat-session-session-file session))
            (should (pichat-backend-capable-p session 'stats))
            (let (stats)
              (pichat-backend-get-stats
               session
               (lambda (response _session)
                 (setq stats (plist-get response :data)))
               #'ignore)
              (should (equal (plist-get stats :usageStatus) "missing"))
              (should-not (plist-get stats :contextUsage)))
            (should (pichat-backend-capable-p session 'diagnostic-view))
            (dolist (capability '(commands session-history saved-sessions
                                  archive diagnostics transport models thinking))
              (should-not (pichat-backend-capable-p session capability))))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-explicit-launch-and-chat-kill-cleanup ()
  "Explicit launch needs no process and chat kill makes late callbacks inert."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let* ((provider
            (make-pichat-test-llm-provider
             :streaming t :scripts '(delayed)))
           (pichat-llm-reasoning 'medium)
           (session
            (pichat-backend-llm-launch
             (let ((provider provider))
               (lambda ()
                 (pichat-llm-provider-spec-create
                  :factory (lambda () provider)
                  :label "offline" :model "offline-model"
                  :streaming t)))
             nil default-directory))
           (buffer (pichat-session-buffer session)))
      (should (pichat-session-alive-p session))
      (should-not (pichat-session-process session))
      (pichat-test-llm--send buffer "kill me")
      (should
       (eq (llm-chat-prompt-reasoning
            (plist-get (car (pichat-test-llm-provider-calls provider))
                       :prompt))
           'medium))
      (let ((pending (car (pichat-test-llm-provider-pending provider))))
        (kill-buffer buffer)
        (should-not (pichat-session-alive-p session))
        (should-not (pichat-llm-state-provider
                     (pichat-session-backend-state session)))
        (should-not (pichat-llm-state-prompt
                     (pichat-session-backend-state session)))
        (let ((before
               (copy-tree
                (pichat-llm-state-journal
                 (pichat-session-backend-state session)) t)))
          (funcall (plist-get pending :partial) '(:text "late partial"))
          (funcall (plist-get pending :final) '(:text "late final"))
          (should
           (equal before
                  (pichat-llm-state-journal
                   (pichat-session-backend-state session))))))
      (should-not (memq session (pichat-session-list))))))

(provide 'pichat-test-backend-llm)
;;; pichat-test-backend-llm.el ends here
