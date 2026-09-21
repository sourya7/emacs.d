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
(defvar pichat-llm-error-max-chars)
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
(declare-function pichat-llm--auth-source-key "pichat-backend-llm" ())
(declare-function pichat-llm--require-public-api "pichat-backend-llm" ())

(when (pichat-test-llm-available-p)
  (pichat-test-llm-install-offline-parser-shims)
  (require 'llm)
  (require 'pichat-backend-llm)

  (cl-defstruct pichat-test-llm-request cancelled)
  (cl-defstruct pichat-test-llm-provider scripts calls pending streaming)
  (cl-defstruct pichat-test-invalid-llm-provider)

  (cl-defmethod llm-name ((_provider pichat-test-llm-provider))
    "offline-test")

  (cl-defmethod llm-capabilities ((provider pichat-test-llm-provider))
    (when (pichat-test-llm-provider-streaming provider) '(streaming)))

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
            (content (car (plist-get message :content))))
       (list (plist-get message :role) (plist-get content :text))))
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
              (should (eq (car prompts) (cadr prompts)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
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

(defun pichat-test-llm--openai-response (text)
  "Return an OpenAI-compatible fixture containing TEXT."
  `((choices . [((message . ((content . ,text))))])
    (usage . ((prompt_tokens . 3) (completion_tokens . 2)))))

(defun pichat-test-llm--gemini-response (text)
  "Return a Vertex Gemini fixture containing TEXT."
  `((candidates . [((content . ((role . "model")
                                (parts . [((text . ,text))]))))])
    (usageMetadata . ((promptTokenCount . 3)
                      (candidatesTokenCount . 2)))))

(defun pichat-test-llm--claude-response (text)
  "Return a Vertex Claude fixture containing TEXT."
  `((content . [((type . "text") (text . ,text))])
    (usage . ((input_tokens . 3) (output_tokens . 2)))))

(defun pichat-test-llm--submit-twice (session)
  "Submit two inline-completing turns to SESSION."
  (pichat-backend-submit-prompt session "first" nil nil #'ignore #'ignore)
  (pichat-backend-submit-prompt session "second" nil nil #'ignore #'ignore))

(ert-deftest pichat-backend-llm-mandatory-provider-two-turn-fixtures ()
  "Codex proxy, Vertex Gemini, and Vertex Claude build offline two-turn calls."
  (pichat-test-llm--require)
  (require 'llm-openai)
  (require 'llm-vertex)
  (require 'pichat-llm-vertex-claude)
  (let ((llm-warn-on-nonfree nil)
        (secret "offline-api-key")
        codex-calls gemini-calls claude-calls provider-journals)
    ;; Codex through the fixed authenticated HTTPS endpoint.
    (cl-letf (((symbol-function 'auth-source-pick-first-password)
               (lambda (&rest args)
                 (should (equal (plist-get args :host)
                                "cliproxyapi.sharmaso.com"))
                 (should (equal (plist-get args :user) "apikey"))
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
              (pichat-test-llm--submit-twice session)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals))
          (pichat-backend-stop-session session))))
    (setq codex-calls (nreverse codex-calls))
    (should (= 2 (length codex-calls)))
    (dolist (call codex-calls)
      (should (equal (car call)
                     "https://cliproxyapi.sharmaso.com/v1/chat/completions"))
      (should (equal (cdr (assoc "Authorization"
                                 (plist-get (cdr call) :headers)))
                     (concat "Bearer " secret))))
    (should (= 3 (length
                  (plist-get (plist-get (cdr (cadr codex-calls)) :data)
                             :messages))))
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
              (pichat-test-llm--submit-twice session)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals))
          (pichat-backend-stop-session session))))
    (setq gemini-calls (nreverse gemini-calls))
    (should (= 2 (length gemini-calls)))
    (dolist (call gemini-calls)
      (should (string-match-p
               "us-east5-aiplatform.*projects/project/locations/us-east5.*gemini-2.5-pro:generateContent"
               (car call))))
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
              (pichat-test-llm--submit-twice session)
              (push (copy-tree
                     (pichat-llm-state-journal
                      (pichat-session-backend-state session)) t)
                    provider-journals))
          (pichat-backend-stop-session session))))
    (setq claude-calls (nreverse claude-calls))
    (should (= 2 (length claude-calls)))
    (dolist (call claude-calls)
      (should (string-match-p
               "europe-west1-aiplatform.*publishers/anthropic/models/claude-sonnet-4-5@20250929:rawPredict"
               (car call))))
    (should-not
     (string-match-p
      (regexp-opt (list secret "offline-vertex-token" "offline-claude-token"))
      (format "%S" provider-journals)))
    (should (= 3 (length provider-journals)))))

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
  (cl-letf (((symbol-function 'auth-source-pick-first-password)
             (lambda (&rest _args) nil)))
    (should-error (pichat-llm--auth-source-key) :type 'user-error))
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
            (dolist (capability '(stats commands session-history saved-sessions
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
