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
(defvar pichat-llm-coding-tools-command-timeout)
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
(declare-function pichat-llm-coding-tools-register
                  "pichat-llm-coding-tools" ())

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
            ('tools
             (let* ((calls (cdr event))
                    (remaining (length calls))
                    results)
               (dolist (call calls)
                 (let* ((name (car call))
                        (values (cdr call))
                        (tool
                         (seq-find
                          (lambda (candidate)
                            (equal name (llm-tool-name candidate)))
                          (llm-chat-prompt-tools prompt))))
                   (unless tool (error "Missing fixture tool %s" name))
                   (apply
                    (llm-tool-function tool)
                    (append
                     (list
                      (lambda (result)
                        (push (cons name result) results)
                        (cl-decf remaining)
                        (when (zerop remaining)
                          (funcall final-callback
                                   (list :tool-uses calls
                                         :tool-results (nreverse results))))))
                     values))))))
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

(defun pichat-test-llm--session (provider &optional streaming tools)
  "Return a started native session owning PROVIDER, optionally exposing TOOLS."
  (let* ((spec
          (pichat-llm-provider-spec-create
           :factory (let ((provider provider)) (lambda () provider))
           :label "offline"
           :model "offline-model"
           :streaming (if (null streaming) 'auto streaming)))
         (state
          (pichat-llm-state-create
           :provider-spec spec :tool-names tools
           :source-generation 0 :run-generation 0
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

(ert-deftest pichat-backend-contract-tools-are-correlated-and-loop-is-bounded ()
  "Repeated tools retain local identity and continue on the same prompt."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let ((executions 0))
      (pichat-define-tool pichat-test-native-echo
          (:description "Native echo"
           :parameters
           (:type "object" :properties
                  (:value (:type "string" :description "Value"))
                  :required ["value"] :additionalProperties nil))
        (cl-incf executions)
        (concat "native:" (plist-get params :value)))
      (let* ((provider
              (make-pichat-test-llm-provider
               :capabilities '(tool-use)
               :scripts
               '(((tools ("pichat-test-native-echo" "same")
                         ("pichat-test-native-echo" "same")))
                 ((final . (:text "finished"))))))
             (session
              (pichat-test-llm--session
               provider nil '("pichat-test-native-echo")))
             (state (pichat-session-backend-state session))
             (settlements 0))
        (unwind-protect
            (progn
              (pichat-on 'agent-settled
                         (lambda (&rest _args) (cl-incf settlements)) session)
              (pichat-backend-submit-prompt
               session "use tools" nil nil #'ignore #'ignore)
              (should (= executions 2))
              (should (= settlements 1))
              (should (= 2 (length (pichat-test-llm-provider-calls provider))))
              (should (eq
                       (plist-get (nth 0 (pichat-test-llm-provider-calls provider))
                                  :prompt)
                       (plist-get (nth 1 (pichat-test-llm-provider-calls provider))
                                  :prompt)))
              (let* ((journal (pichat-llm-state-journal state))
                     (tool-message (plist-get (nth 1 journal) :message))
                     (calls
                      (seq-filter
                       (lambda (part)
                         (equal (plist-get part :type) "toolCall"))
                       (plist-get tool-message :content))))
                (should (= 5 (length journal)))
                (should (= 2 (length calls)))
                (should-not (equal (plist-get (nth 0 calls) :id)
                                   (plist-get (nth 1 calls) :id)))
                (should (equal
                         (mapcar
                          (lambda (entry)
                            (plist-get (plist-get entry :message) :role))
                          journal)
                         '("user" "assistant" "toolResult" "toolResult"
                           "assistant"))))
              (should (equal (pichat-test-llm--journal-texts session)
                             '(("user" "use tools")
                               ("assistant" "")
                               ("toolResult" "native:same")
                               ("toolResult" "native:same")
                               ("assistant" "finished")))))
          (pichat-backend-stop-session session))))))

(ert-deftest pichat-backend-llm-tool-schema-rejects-before-request ()
  "Unsupported schemas and provider capabilities fail before model I/O."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-native-invalid
        (:parameters (:type "object" :additionalProperties t))
      "never")
    (let ((provider
           (make-pichat-test-llm-provider :capabilities '(tool-use))))
      (should-error
       (pichat-test-llm--session
        provider nil '("pichat-test-native-invalid"))
       :type 'user-error)
      (should-error
       (pichat-test-llm--session
        provider nil '("pichat-test-native-unknown"))
       :type 'user-error)
      (should-not (pichat-test-llm-provider-calls provider)))
    (pichat-define-tool pichat-test-native-valid
        (:parameters (:type "object" :properties nil
                      :additionalProperties nil))
      "ok")
    (let ((provider (make-pichat-test-llm-provider)))
      (should-error
       (pichat-test-llm--session
        provider nil '("pichat-test-native-valid"))
       :type 'user-error)
      (should-not (pichat-test-llm-provider-calls provider)))))

(ert-deftest pichat-backend-llm-parallel-tools-complete-out-of-order ()
  "Immediate tools may finish before an earlier queued approval without mixing IDs."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir directory
      (let ((pichat-approval-policy-file
             (expand-file-name "approvals.el" directory))
            completions scheduled-function scheduled-args)
        (pichat-define-tool pichat-test-native-ask
            (:mutating t :parameters
             (:type "object" :properties (:value (:type "string"))
                    :required ["value"] :additionalProperties nil))
          (push (concat "ask:" (plist-get params :value)) completions)
          (car completions))
        (pichat-define-tool pichat-test-native-now
            (:parameters
             (:type "object" :properties (:value (:type "string"))
                    :required ["value"] :additionalProperties nil))
          (push (concat "now:" (plist-get params :value)) completions)
          (car completions))
        (let* ((provider
                (make-pichat-test-llm-provider
                 :capabilities '(tool-use)
                 :scripts
                 '(((tools ("pichat-test-native-ask" "first")
                           ("pichat-test-native-now" "second")))
                   ((final . (:text "ordered"))))))
               (session
                (pichat-test-llm--session
                 provider nil
                 '("pichat-test-native-ask" "pichat-test-native-now"))))
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_delay _repeat function &rest args)
                       (setq scheduled-function function scheduled-args args)
                       'approval-timer))
                    ((symbol-function 'pichat-llm--chat-focused-p)
                     (lambda (_session) t))
                    ((symbol-function 'pichat-approval-prompt)
                     (lambda (&rest _args) t)))
            (unwind-protect
                (progn
                  (pichat-backend-submit-prompt
                   session "parallel" nil nil #'ignore #'ignore)
                  (should (equal completions '("now:second")))
                  (should (= 1 (length
                                (pichat-test-llm-provider-calls provider))))
                  (apply scheduled-function scheduled-args)
                  (should (equal completions
                                 '("ask:first" "now:second")))
                  (should (= 2 (length
                                (pichat-test-llm-provider-calls provider))))
                  (let ((tools
                         (seq-filter
                          (lambda (part)
                            (equal (plist-get part :type) "toolCall"))
                          (plist-get
                           (plist-get
                            (nth 1
                                 (pichat-llm-state-journal
                                  (pichat-session-backend-state session)))
                            :message)
                           :content))))
                    (should (= 2 (length tools)))
                    (should-not (equal (plist-get (nth 0 tools) :id)
                                       (plist-get (nth 1 tools) :id)))))
              (pichat-backend-stop-session session))))))))

(ert-deftest pichat-backend-llm-tool-budget-prevents-another-round ()
  "Tool-call exhaustion settles exactly once without another request."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-native-budget
        (:parameters (:type "object" :properties
                      (:value (:type "string"))
                      :required ["value"] :additionalProperties nil))
      (plist-get params :value))
    (let* ((pichat-llm-max-tool-calls 1)
           (provider
            (make-pichat-test-llm-provider
             :capabilities '(tool-use)
             :scripts
             '(((tools ("pichat-test-native-budget" "one")
                       ("pichat-test-native-budget" "two"))))))
           (session
            (pichat-test-llm--session
             provider nil '("pichat-test-native-budget")))
           (settlements 0))
      (unwind-protect
          (progn
            (pichat-on 'agent-settled
                       (lambda (&rest _args) (cl-incf settlements)) session)
            (pichat-backend-submit-prompt
             session "budget" nil nil #'ignore #'ignore)
            (should (= settlements 1))
            (should (= 1 (length (pichat-test-llm-provider-calls provider))))
            (should (eq 'idle (pichat-session-state session)))
            (should (string-match-p
                     "budget exhausted"
                     (format "%S" (pichat-llm-state-journal
                                    (pichat-session-backend-state session))))))
        (pichat-backend-stop-session session)))))

(ert-deftest pichat-backend-llm-round-and-output-budgets-stop-loop ()
  "Round and aggregate output limits each prevent another provider call."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-native-limits
        (:parameters (:type "object" :properties
                      (:value (:type "string"))
                      :required ["value"] :additionalProperties nil))
      (concat "long-output-" (plist-get params :value)))
    (dolist (limits '((1 100000 "provider-round")
                      (8 2 "tool output")))
      (let* ((pichat-llm-max-rounds (nth 0 limits))
             (pichat-llm-max-tool-output-chars (nth 1 limits))
             (provider
              (make-pichat-test-llm-provider
               :capabilities '(tool-use)
               :scripts '(((tools ("pichat-test-native-limits" "x"))))))
             (session
              (pichat-test-llm--session
               provider nil '("pichat-test-native-limits"))))
        (unwind-protect
            (progn
              (pichat-backend-submit-prompt
               session "limits" nil nil #'ignore #'ignore)
              (should (= 1 (length
                            (pichat-test-llm-provider-calls provider))))
              (should (string-match-p
                       (nth 2 limits)
                       (downcase
                        (format "%S"
                                (pichat-llm-state-journal
                                 (pichat-session-backend-state session)))))))
          (pichat-backend-stop-session session))))))

(ert-deftest pichat-backend-llm-denial-and-tool-error-become-results ()
  "Denied mutations and execution failures are bounded provider results."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir directory
      (let ((pichat-approval-policy-file
             (expand-file-name "approvals.el" directory))
            (denied-executions 0))
        (pichat-define-tool pichat-test-native-denied
            (:mutating t :parameters
             (:type "object" :properties (:value (:type "string"))
                    :required ["value"] :additionalProperties nil))
          (cl-incf denied-executions)
          "must not run")
        (pichat-define-tool pichat-test-native-error
            (:parameters
             (:type "object" :properties (:value (:type "string"))
                    :required ["value"] :additionalProperties nil))
          (error "bounded fixture failure"))
        (setq pichat-approval-rules
              '(("pichat-test-native-denied" . deny)))
        (pichat-approval-save)
        (let* ((provider
                (make-pichat-test-llm-provider
                 :capabilities '(tool-use)
                 :scripts
                 '(((tools ("pichat-test-native-denied" "no")
                           ("pichat-test-native-error" "bad")))
                   ((final . (:text "after errors"))))))
               (session
                (pichat-test-llm--session
                 provider nil
                 '("pichat-test-native-denied" "pichat-test-native-error"))))
          (unwind-protect
              (progn
                (pichat-backend-submit-prompt
                 session "errors" nil nil #'ignore #'ignore)
                (should (= denied-executions 0))
                (let ((journal
                       (format "%S"
                               (pichat-llm-state-journal
                                (pichat-session-backend-state session)))))
                  (should (string-match-p "Denied by policy" journal))
                  (should (string-match-p "bounded fixture failure" journal)))
                (should (= 2 (length
                              (pichat-test-llm-provider-calls provider)))))
            (pichat-backend-stop-session session)))))))

(ert-deftest pichat-backend-llm-cancelled-approval-has-no-side-effect ()
  "Abort removes a queued approval and makes its late activation inert."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (let ((executions 0) scheduled-function scheduled-args)
      (pichat-define-tool pichat-test-native-mutate
          (:mutating t :parameters
           (:type "object" :properties (:value (:type "string"))
                  :required ["value"] :additionalProperties nil))
        (cl-incf executions)
        "mutated")
      (let* ((provider
              (make-pichat-test-llm-provider
               :capabilities '(tool-use)
               :scripts
               '(((tools ("pichat-test-native-mutate" "value"))))))
             session)
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_delay _repeat function &rest args)
                     (setq scheduled-function function scheduled-args args)
                     'fixture-timer))
                  ((symbol-function 'timerp)
                   (lambda (value) (eq value 'fixture-timer)))
                  ((symbol-function 'cancel-timer) #'ignore))
          (setq session
                (pichat-test-llm--session
                 provider nil '("pichat-test-native-mutate")))
          (unwind-protect
              (progn
                (pichat-backend-submit-prompt
                 session "mutate" nil nil #'ignore #'ignore)
                (should scheduled-function)
                (pichat-backend-abort-session session)
                (apply scheduled-function scheduled-args)
                (should (= executions 0))
                (should-not
                 (pichat-llm-state-pending-tools
                  (pichat-session-backend-state session))))
            (pichat-backend-stop-session session)))))))

(ert-deftest pichat-backend-llm-coding-tool-context-is-installed-at-start ()
  "Canonical selected tools add their exact local policy to retained context."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir directory
      (let ((default-directory directory))
        (require 'pichat-llm-coding-tools)
        (pichat-llm-coding-tools-register)
        (let* ((provider
                (make-pichat-test-llm-provider :capabilities '(tool-use)))
               (session (pichat-test-llm--session provider nil '("read" "edit")))
               (context
                (pichat-llm-state-context
                 (pichat-session-backend-state session))))
          (unwind-protect
              (progn
                (should (string-match-p (regexp-quote directory) context))
                (should (string-match-p "Use read to examine files" context))
                (should (string-match-p "oldText must match" context))
                (should (string-match-p "do not assume Pi skills" context)))
            (pichat-backend-stop-session session)))))))

(ert-deftest pichat-backend-llm-abort-cancels-asynchronous-tool-process ()
  "Abort invokes an executing tool's cancellation closure before later effects."
  (pichat-test-llm--require)
  (pichat-test-with-clean-state
    (pichat-test-with-temp-dir directory
      (let ((default-directory directory)
            (pichat-approval-policy-file
             (expand-file-name "approvals.el" directory))
            (pichat-llm-coding-tools-command-timeout 5))
        (require 'pichat-llm-coding-tools)
        (pichat-llm-coding-tools-register)
        (setq pichat-approval-rules '(("bash" . allow)))
        (pichat-approval-save)
        (let* ((provider
                (make-pichat-test-llm-provider
                 :capabilities '(tool-use)
                 :scripts
                 '(((tools
                     ("bash"
                      "sleep 1; printf late > cancelled-by-backend.txt"
                      5))))))
               (session (pichat-test-llm--session provider nil '("bash")))
               (state (pichat-session-backend-state session)))
          (unwind-protect
              (progn
                (pichat-backend-submit-prompt
                 session "run then abort" nil nil #'ignore #'ignore)
                (should (eq 'executing
                            (pichat-llm-tool-invocation-status
                             (car (pichat-llm-state-round-tools state)))))
                (pichat-backend-abort-session session)
                (accept-process-output nil 1.2)
                (should-not
                 (file-exists-p
                  (expand-file-name "cancelled-by-backend.txt" directory)))
                (should (eq 'cancelled
                            (pichat-llm-tool-invocation-status
                             (car (pichat-llm-state-round-tools state)))))
                (should-not
                 (pichat-llm-tool-invocation-cancel-function
                  (car (pichat-llm-state-round-tools state)))))
            (pichat-backend-stop-session session)))))))

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

(defun pichat-test-llm--openai-tool-response (&optional suffix)
  "Return one OpenAI-compatible native tool call fixture using SUFFIX."
  (json-parse-string
   (format
    "{\"choices\":[{\"message\":{\"content\":\"\",\"tool_calls\":[{\"id\":\"codex-call%s\",\"type\":\"function\",\"function\":{\"name\":\"pichat-test-provider-tool\",\"arguments\":\"{\\\"value\\\":\\\"codex%s\\\"}\"}}]}}]}"
    (or suffix "") (or suffix ""))
   :object-type 'alist :array-type 'array))

(defun pichat-test-llm--gemini-tool-response (&optional suffix)
  "Return one Vertex Gemini native tool call fixture using SUFFIX."
  (json-parse-string
   (format
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"pichat-test-provider-tool\",\"args\":{\"value\":\"gemini%s\"}},\"thoughtSignature\":\"tool-signature%s\"}]}}]}"
    (or suffix "") (or suffix ""))
   :object-type 'alist :array-type 'array))

(defun pichat-test-llm--claude-tool-response (&optional suffix)
  "Return one Vertex Claude native tool call fixture using SUFFIX."
  (json-parse-string
   (format
    "{\"content\":[{\"type\":\"tool_use\",\"id\":\"claude-call%s\",\"name\":\"pichat-test-provider-tool\",\"input\":{\"value\":\"claude%s\"}}],\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
    (or suffix "") (or suffix ""))
   :object-type 'alist :array-type 'array))

(ert-deftest pichat-backend-llm-mandatory-provider-tool-round-fixtures ()
  "Codex, Gemini, and Claude execute two offline tool rounds then prose."
  (pichat-test-llm--require)
  (require 'llm-openai)
  (require 'llm-vertex)
  (require 'pichat-llm-vertex-claude)
  (pichat-test-with-clean-state
    (pichat-define-tool pichat-test-provider-tool
        (:parameters (:type "object" :properties
                      (:value (:type "string"))
                      :required ["value"] :additionalProperties nil))
      (concat "provider-result:" (plist-get params :value)))
    (let ((llm-warn-on-nonfree nil)
          (pichat-llm-codex-url "https://proxy.example.test/v1")
          (pichat-llm-codex-auth-host "proxy.example.test")
          (pichat-llm-codex-auth-user "fixture")
          calls)
      (cl-letf (((symbol-function 'auth-source-pick-first-password)
                 (lambda (&rest _args) "fixture-key"))
                ((symbol-function 'llm-request-plz-async)
                 (lambda (url &rest args)
                   (push (cons url args) calls)
                   (funcall
                    (plist-get args :on-success)
                    (pcase (length calls)
                      (1 (pichat-test-llm--openai-tool-response "-1"))
                      (2 (pichat-test-llm--openai-tool-response "-2"))
                      (_ (pichat-test-llm--openai-response "codex done"))))
                   (make-pichat-test-llm-request))))
        (let* ((spec (pichat-llm-make-codex-provider "codex-model"))
               (_ (setf (pichat-llm-provider-spec-streaming spec) nil))
               (session
                (pichat-test-llm--session-from-spec
                 spec '("pichat-test-provider-tool"))))
          (unwind-protect
              (pichat-backend-submit-prompt
               session "tool" nil nil #'ignore #'ignore)
            (pichat-backend-stop-session session))))
      (setq calls (nreverse calls))
      (should (= 3 (length calls)))
      (should (string-match-p
               "codex-call"
               (format "%S" (plist-get (cdr (nth 1 calls)) :data)))))
    (let (calls)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_name) "/offline/gcloud"))
                ((symbol-function 'shell-command-to-string)
                 (lambda (_command) "fixture-token\n"))
                ((symbol-function 'llm-request-plz-async)
                 (lambda (url &rest args)
                   (push (cons url args) calls)
                   (funcall
                    (plist-get args :on-success)
                    (pcase (length calls)
                      (1 (pichat-test-llm--gemini-tool-response "-1"))
                      (2 (pichat-test-llm--gemini-tool-response "-2"))
                      (_ (pichat-test-llm--gemini-response "gemini done"))))
                   (make-pichat-test-llm-request))))
        (let ((session
               (pichat-test-llm--session-from-spec
                (pichat-llm-make-vertex-gemini-provider
                 "project" "region" "gemini-2.5-pro" "offline-gcloud")
                '("pichat-test-provider-tool"))))
          (unwind-protect
              (pichat-backend-submit-prompt
               session "tool" nil nil #'ignore #'ignore)
            (pichat-backend-stop-session session))))
      (setq calls (nreverse calls))
      (should (= 3 (length calls)))
      (should (string-match-p
               "tool-signature"
               (format "%S" (plist-get (cdr (nth 1 calls)) :data)))))
    (let (calls)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (_name) "/offline/gcloud"))
                ((symbol-function 'process-file)
                 (lambda (&rest _args) (insert "fixture-token\n") 0))
                ((symbol-function 'llm-request-plz-async)
                 (lambda (url &rest args)
                   (push (cons url args) calls)
                   (funcall
                    (plist-get args :on-success)
                    (pcase (length calls)
                      (1 (pichat-test-llm--claude-tool-response "-1"))
                      (2 (pichat-test-llm--claude-tool-response "-2"))
                      (_ (pichat-test-llm--claude-response "claude done"))))
                   (make-pichat-test-llm-request))))
        (let* ((spec
                (pichat-llm-make-vertex-claude-provider
                 "project" "region" "claude-model" "offline-gcloud"))
               (_ (setf (pichat-llm-provider-spec-streaming spec) nil))
               (session
                (pichat-test-llm--session-from-spec
                 spec '("pichat-test-provider-tool"))))
          (unwind-protect
              (pichat-backend-submit-prompt
               session "tool" nil nil #'ignore #'ignore)
            (pichat-backend-stop-session session))))
      (setq calls (nreverse calls))
      (should (= 3 (length calls)))
      (should (string-match-p
               "claude-call"
               (format "%S" (plist-get (cdr (nth 1 calls)) :data)))))))

(defun pichat-test-llm--session-from-spec (spec &optional tools)
  "Return a started native session using provider SPEC and optional TOOLS."
  (let* ((state
          (pichat-llm-state-create
           :provider-spec spec :tool-names tools
           :source-generation 0 :run-generation 0
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
