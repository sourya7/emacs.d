;;; pichat-backend-llm.el --- Native llm.el backend for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; In-memory text conversations backed by llm.el.  This file is loaded only by
;; the explicit `pichat-llm' entry point (or by callers that require it).
;; Provider prompt state, PiChat's local entry journal, and rendered buffers are
;; deliberately separate authorities.

;;; Code:

(require 'auth-source)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'llm)
(require 'pichat-backend)
(require 'pichat-events)
(require 'pichat-session)

(eval-when-compile
  ;; These documented llm-vertex settings are dynamically bound only after
  ;; the provider module has defined them at runtime.
  (defvar llm-vertex-gcloud-region)
  (defvar llm-vertex-gcloud-binary))

(declare-function make-llm-openai-compatible "llm-openai" (&rest args))
(declare-function make-llm-vertex "llm-vertex" (&rest args))
(declare-function pichat-llm-vertex-access-token
                  "pichat-llm-vertex-claude" (gcloud))
(declare-function pichat-chat-open "pichat-chat" (session &optional synchronize))
(declare-function pichat-register-session "pichat" (session &optional scope))
(declare-function pichat-forget-session "pichat" (session))
(declare-function pichat-set-default-session "pichat" (session))

(defvar pichat-current-session)

(defgroup pichat-llm nil
  "Native in-memory llm.el conversations for PiChat."
  :group 'pichat)

(defconst pichat-llm-tested-version "0.32.1"
  "llm.el release covered by PiChat's offline provider fixtures.")

(defconst pichat-llm-codex-url "https://cliproxyapi.sharmaso.com/v1/"
  "Authenticated CLIProxyAPI endpoint used by the Codex provider factory.")

(defconst pichat-llm-codex-auth-host "cliproxyapi.sharmaso.com"
  "Auth-source host used for the CLIProxyAPI access key.")

(defconst pichat-llm-codex-auth-user "apikey"
  "Auth-source user used for the CLIProxyAPI access key.")

(defcustom pichat-llm-provider nil
  "Explicit provider object, provider factory, or provider specification.
A function is called without arguments for every new conversation and may
return either a provider or a provider specification.  Prefer a factory so
independent sessions cannot accidentally share mutable provider state.  PiChat
never infers a provider from a model string."
  :type 'sexp
  :group 'pichat-llm)

(defcustom pichat-llm-model nil
  "Explicit display/model identity for `pichat-llm'.
Provider helper functions include this identity in their returned specification;
bare provider objects and factories require this option or an explicit argument."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'pichat-llm)

(defcustom pichat-llm-context nil
  "Optional system context used when constructing a new retained prompt."
  :type '(choice (const :tag "None" nil) string)
  :group 'pichat-llm)

(defcustom pichat-llm-streaming t
  "Whether generic native providers should stream when they advertise support.
Provider specifications may force streaming on or off for a tested protocol."
  :type 'boolean
  :group 'pichat-llm)

(defcustom pichat-llm-vertex-gcloud-executable "gcloud"
  "Executable used by PiChat Vertex provider factories."
  :type 'file
  :group 'pichat-llm)

(defcustom pichat-llm-error-max-chars 500
  "Maximum characters retained from a native provider error."
  :type 'integer
  :group 'pichat-llm)

(cl-defstruct (pichat-llm-provider-spec
               (:constructor pichat-llm-provider-spec-create))
  "Explicit factory and call policy for one native provider family."
  factory
  label
  model
  call-wrapper
  (streaming 'auto))

(cl-defstruct (pichat-llm-query
               (:constructor pichat-llm-query-create))
  "Identity for a local snapshot request; it is not a model request handle."
  id
  cancelled)

(cl-defstruct (pichat-llm-state
               (:constructor pichat-llm-state-create))
  "Private native state owned by exactly one PiChat session."
  alive
  provider-spec
  provider
  provider-label
  model
  call-wrapper
  streaming
  context
  prompt
  journal
  leaf-id
  request
  submission-id
  stream-text
  assistant-started
  continuation-uncertain
  source-generation
  run-generation
  round-generation
  active-run
  settled-run
  sequence)

(defvar pichat-llm--claimed-providers
  (make-hash-table :test #'eq :weakness 'key)
  "Provider objects already assigned to a native conversation.
Keys are weak so this safety record does not itself retain provider objects.")

(defvar pichat-llm--launch-counter 0
  "Counter used only for human-readable native launch labels.")

(defconst pichat-backend-llm-capabilities
  '(submit abort state transcript lifecycle events new-conversation naming)
  "Capabilities exposed by the Phase 2 native text backend.")

(defun pichat-llm--nonblank-string-p (value)
  "Return non-nil when VALUE is a nonblank string."
  (and (stringp value) (not (string-blank-p value))))

(defun pichat-llm--require-public-api ()
  "Ensure the loaded llm.el exposes the public API used by PiChat.
Do not silently fall back to private or version-specific implementation
functions when a future llm.el changes one of these application seams."
  (dolist (function '(llm-make-chat-prompt
                      llm-chat-prompt-append-response
                      llm-chat-async
                      llm-chat-streaming
                      llm-capabilities
                      llm-name
                      llm-cancel-request))
    (unless (fboundp function)
      (user-error
       "llm.el %s is missing public function `%s'"
       pichat-llm-tested-version function)))
  t)

(defun pichat-llm--bounded-error (value)
  "Return bounded, single-line, credential-redacted text for VALUE."
  (let* ((case-fold-search t)
         (text (replace-regexp-in-string
                "[[:space:]\n\r\t]+" " " (format "%s" value)))
         (text (replace-regexp-in-string
                "\\bBearer[[:space:]]+[^[:space:]]+" "Bearer [REDACTED]" text))
         (text (replace-regexp-in-string
                "\\b\\(api[-_ ]?key\\|access[-_ ]?token\\|password\\)[[:space:]]*[:=][[:space:]]*[^[:space:]]+"
                "\\1=[REDACTED]" text)))
    (truncate-string-to-width text pichat-llm-error-max-chars nil nil "…")))

(defun pichat-llm--auth-source-key ()
  "Return the configured CLIProxyAPI key without caching it in PiChat state."
  (let ((secret
         (auth-source-pick-first-password
          :host pichat-llm-codex-auth-host
          :user pichat-llm-codex-auth-user)))
    (unless (pichat-llm--nonblank-string-p secret)
      (user-error
       "No CLIProxyAPI key in auth-source for %s/%s"
       pichat-llm-codex-auth-host pichat-llm-codex-auth-user))
    secret))

(defun pichat-llm-make-codex-provider (model)
  "Return an explicit provider specification for Codex MODEL via CLIProxyAPI."
  (unless (pichat-llm--nonblank-string-p model)
    (user-error "An explicit Codex model is required"))
  (let ((model model))
    (pichat-llm-provider-spec-create
     :label "Codex via CLIProxyAPI"
     :model model
     :streaming t
     :factory
     (lambda ()
       (require 'llm-openai)
       (make-llm-openai-compatible
        :url pichat-llm-codex-url
        :key #'pichat-llm--auth-source-key
        :chat-model model)))))

(defun pichat-llm--gcloud-available-p (executable)
  "Return non-nil when EXECUTABLE can be invoked."
  (and (pichat-llm--nonblank-string-p executable)
       (if (file-name-directory executable)
           (file-executable-p executable)
         (executable-find executable))))

(defun pichat-llm-make-vertex-gemini-provider
    (project region model &optional gcloud)
  "Return a Vertex Gemini specification for PROJECT, REGION, and MODEL.
GCLOUD defaults to `pichat-llm-vertex-gcloud-executable'."
  (dolist (pair `((project . ,project) (region . ,region) (model . ,model)))
    (unless (pichat-llm--nonblank-string-p (cdr pair))
      (user-error "Vertex Gemini %s is required" (car pair))))
  (let ((project project)
        (region region)
        (model model)
        (gcloud (or gcloud pichat-llm-vertex-gcloud-executable)))
    (pichat-llm-provider-spec-create
     :label "Vertex Gemini"
     :model model
     ;; llm 0.32.1 drops Gemini stream chunks without usage metadata.  Keep the
     ;; tested Phase 2 path non-streaming rather than advertising broken output.
     :streaming nil
     :call-wrapper
     (lambda (function)
       (let ((llm-vertex-gcloud-region region)
             (llm-vertex-gcloud-binary gcloud))
         (funcall function)))
     :factory
     (lambda ()
       (unless (pichat-llm--gcloud-available-p gcloud)
         (user-error "Configured gcloud executable is unavailable: %s" gcloud))
       (require 'llm-vertex)
       (make-llm-vertex :project project :chat-model model)))))

(defun pichat-llm-make-vertex-claude-provider
    (project region model &optional gcloud)
  "Return a Vertex Claude specification for PROJECT, REGION, and MODEL.
GCLOUD defaults to `pichat-llm-vertex-gcloud-executable'."
  (dolist (pair `((project . ,project) (region . ,region) (model . ,model)))
    (unless (pichat-llm--nonblank-string-p (cdr pair))
      (user-error "Vertex Claude %s is required" (car pair))))
  (let ((project project)
        (region region)
        (model model)
        (gcloud (or gcloud pichat-llm-vertex-gcloud-executable)))
    (pichat-llm-provider-spec-create
     :label "Vertex Claude"
     :model model
     :streaming t
     :factory
     (lambda ()
       (unless (pichat-llm--gcloud-available-p gcloud)
         (user-error "Configured gcloud executable is unavailable: %s" gcloud))
       (require 'pichat-llm-vertex-claude)
       (pichat-llm-vertex-claude-create
        :project project
        :region region
        :model model
        :token-function
        (lambda () (pichat-llm-vertex-access-token gcloud)))))))

(defun pichat-llm--normalize-provider-spec (provider model)
  "Return a provider specification for explicit PROVIDER and MODEL."
  (let* ((provider (or provider pichat-llm-provider))
         (model (or model pichat-llm-model)))
    (unless provider
      (user-error
       "Configure `pichat-llm-provider' with an explicit provider or factory"))
    (if (pichat-llm-provider-spec-p provider)
        (progn
          (when (and model
                     (pichat-llm-provider-spec-model provider)
                     (not (equal model
                                 (pichat-llm-provider-spec-model provider))))
            (user-error "Model argument does not match the provider specification"))
          (unless (functionp (pichat-llm-provider-spec-factory provider))
            (user-error "PiChat llm provider specification has no factory"))
          provider)
      (unless (or (functionp provider)
                  (pichat-llm--nonblank-string-p model))
        (user-error "An explicit model identity is required"))
      (pichat-llm-provider-spec-create
       :factory (if (functionp provider)
                    provider
                  (let ((object provider)) (lambda () object)))
       :label (and model "llm.el")
       :model model
       :streaming 'auto))))

(defun pichat-llm--invoke-provider-factory (spec)
  "Invoke SPEC's factory and return its value with a bounded setup error."
  (condition-case err
      (funcall (pichat-llm-provider-spec-factory spec))
    (error
     (user-error "Cannot configure native provider: %s"
                 (pichat-llm--bounded-error
                  (error-message-string err))))))

(defun pichat-llm--prepare-provider (source-spec)
  "Resolve and validate a fresh provider from SOURCE-SPEC.
Return a plist containing the provider, its effective specification, model,
label, capabilities, call wrapper, and streaming policy.  Resolution is
side-effect free with respect to PiChat session state, so callers can preserve
an existing conversation when provider construction fails."
  (let ((spec source-spec)
        (model (pichat-llm-provider-spec-model source-spec))
        seen
        provider)
    (while (not provider)
      (unless (pichat-llm-provider-spec-p spec)
        (user-error "Invalid native provider specification: %s"
                    (pichat-llm--bounded-error spec)))
      (unless (functionp (pichat-llm-provider-spec-factory spec))
        (user-error "PiChat llm provider specification has no factory"))
      (when (memq spec seen)
        (user-error "Native provider factory returned a cyclic specification"))
      (push spec seen)
      (let ((produced (pichat-llm--invoke-provider-factory spec)))
        (unless produced
          (user-error "Native provider factory returned nil"))
        (if (pichat-llm-provider-spec-p produced)
            (let ((produced-model
                   (pichat-llm-provider-spec-model produced)))
              (when (and model produced-model
                         (not (equal model produced-model)))
                (user-error
                 "Model argument does not match the provider factory specification"))
              (setq model (or produced-model model)
                    spec produced))
          (setq provider produced))))
    (unless (pichat-llm--nonblank-string-p model)
      (user-error "An explicit model identity is required"))
    (when (gethash provider pichat-llm--claimed-providers)
      (user-error "Native provider object was already used; configure a factory"))
    (let* ((capabilities
            (condition-case err
                (llm-capabilities provider)
              (error
               (user-error "Invalid native provider: %s"
                           (pichat-llm--bounded-error
                            (error-message-string err))))))
           (label
            (condition-case err
                (or (pichat-llm-provider-spec-label spec)
                    (llm-name provider))
              (error
               (user-error "Invalid native provider: %s"
                           (pichat-llm--bounded-error
                            (error-message-string err)))))))
      (list :provider provider
            :spec spec
            :model model
            :label label
            :capabilities capabilities
            :call-wrapper (pichat-llm-provider-spec-call-wrapper spec)
            :streaming
            (pcase (pichat-llm-provider-spec-streaming spec)
              ('auto (and pichat-llm-streaming
                          (memq 'streaming capabilities)))
              ((pred null) nil)
              (_ t))))))

(defun pichat-llm--install-provider (session state prepared)
  "Install PREPARED provider data into SESSION and STATE."
  (let ((provider (plist-get prepared :provider))
        (model (plist-get prepared :model))
        (label (plist-get prepared :label)))
    (puthash provider session pichat-llm--claimed-providers)
    (setf (pichat-llm-state-provider state) provider
          (pichat-llm-state-provider-label state) label
          (pichat-llm-state-model state) model
          (pichat-llm-state-call-wrapper state)
          (plist-get prepared :call-wrapper)
          (pichat-llm-state-streaming state)
          (plist-get prepared :streaming)
          (pichat-session-model session)
          (list :id model :name model :provider label))))

(defun pichat-llm--state (session)
  "Return SESSION's validated native backend state."
  (let ((state (pichat-session-backend-state session)))
    (unless (pichat-llm-state-p state)
      (error "PiChat llm session has invalid backend state"))
    state))

(defun pichat-llm--next-sequence (state)
  "Increment and return STATE's local sequence."
  (setf (pichat-llm-state-sequence state)
        (1+ (or (pichat-llm-state-sequence state) 0))))

(defun pichat-llm--source-id (state)
  "Return a fresh source identity for STATE."
  (format "llm-%d-%d"
          (or (pichat-llm-state-source-generation state) 0)
          (pichat-llm--next-sequence state)))

(defun pichat-llm--entry-id (state prefix)
  "Return a fresh journal identity in STATE using PREFIX."
  (format "%s-%s-%d"
          (or (pichat-llm-state-source-generation state) 0)
          prefix (pichat-llm--next-sequence state)))

(defun pichat-llm--emit-raw (session event raw)
  "Emit Pi-compatible RAW through generic and specific EVENT channels."
  (pichat-emit session 'rpc-event :raw raw)
  (pichat-emit session event :raw raw))

(defun pichat-llm--message (role text &optional stop-reason error-message)
  "Return a private Pi-shaped message for ROLE and TEXT."
  (append
   (list :role role
         :content (list (list :type "text"
                                :text (if (stringp text) text ""))))
   (when stop-reason (list :stopReason stop-reason))
   (when error-message (list :errorMessage error-message))))

(defun pichat-llm--commit-message
    (session role text &optional stop-reason error-message)
  "Commit an immutable local message entry for SESSION."
  (let* ((state (pichat-llm--state session))
         (id (pichat-llm--entry-id state role))
         (entry
          (list :id id
                :parentId (pichat-llm-state-leaf-id state)
                :type "message"
                :message
                (pichat-llm--message role text stop-reason error-message))))
    (setf (pichat-llm-state-journal state)
          (append (pichat-llm-state-journal state) (list entry))
          (pichat-llm-state-leaf-id state) id)
    entry))

(defun pichat-llm--run-current-p (state run)
  "Return non-nil when RUN still owns live STATE."
  (and (pichat-llm-state-alive state)
       (equal run (pichat-llm-state-active-run state))
       (= run (pichat-llm-state-run-generation state))))

(defun pichat-llm--call-with-provider-settings (state function)
  "Call FUNCTION through STATE's provider-specific public settings wrapper."
  (if (pichat-llm-state-call-wrapper state)
      (funcall (pichat-llm-state-call-wrapper state) function)
    (funcall function)))

(defun pichat-llm--cancel-model-request (request)
  "Cancel llm REQUEST while suppressing cancellation transport failures."
  (when (and request (not (eq request 'starting)))
    (condition-case nil
        (llm-cancel-request request)
      (error nil))))

(defun pichat-llm--invalidate-run (state)
  "Invalidate STATE's active callbacks before returning its request handle."
  (let ((request (pichat-llm-state-request state)))
    (setf (pichat-llm-state-run-generation state)
          (1+ (or (pichat-llm-state-run-generation state) 0))
          (pichat-llm-state-active-run state) nil
          (pichat-llm-state-request state) nil
          (pichat-llm-state-submission-id state) nil)
    request))

(defun pichat-llm--emit-assistant-snapshot (session state text type)
  "Emit cumulative assistant TEXT for SESSION as Pi-compatible TYPE."
  (unless (pichat-llm-state-assistant-started state)
    (setf (pichat-llm-state-assistant-started state) t)
    (pichat-llm--emit-raw
     session 'message-start
     (list :type "message_start"
           :message (pichat-llm--message "assistant" ""))))
  (pichat-llm--emit-raw
   session
   (if (equal type "message_end") 'message-end 'message-update)
   (list :type type
         :message (pichat-llm--message "assistant" text))))

(defun pichat-llm--partial (session run value)
  "Apply cumulative multi-output VALUE for SESSION's RUN."
  (let ((state (pichat-llm--state session)))
    (when (and (pichat-llm--run-current-p state run)
               (listp value)
               (plist-member value :text))
      (let ((text (or (plist-get value :text) "")))
        (when (and (stringp text)
                   (not (equal text (pichat-llm-state-stream-text state))))
          (setf (pichat-llm-state-stream-text state) text)
          (pichat-llm--emit-assistant-snapshot
           session state text "message_update"))))))

(defun pichat-llm--settle (session run text stop-reason &optional error-message)
  "Commit and settle SESSION's RUN with authoritative TEXT."
  (let ((state (pichat-llm--state session)))
    (when (and (pichat-llm--run-current-p state run)
               (not (equal run (pichat-llm-state-settled-run state))))
      (let* ((safe-error
              (and error-message (pichat-llm--bounded-error error-message)))
             (message
              (pichat-llm--message "assistant" text stop-reason safe-error)))
        (setf (pichat-llm-state-request state) nil
              (pichat-llm-state-submission-id state) nil
              (pichat-llm-state-active-run state) nil
              (pichat-llm-state-settled-run state) run
              (pichat-session-streaming-p session) nil
              (pichat-session-state session) 'idle)
        (pichat-llm--commit-message
         session "assistant" text stop-reason safe-error)
        (pichat-llm--emit-raw
         session 'message-end (list :type "message_end" :message message))
        (pichat-llm--emit-raw session 'turn-end '(:type "turn_end"))
        (pichat-llm--emit-raw
         session 'agent-settled '(:type "agent_settled"))
        t))))

(defun pichat-llm--final (session run value)
  "Handle final multi-output VALUE for SESSION's RUN."
  (let ((state (pichat-llm--state session)))
    (when (pichat-llm--run-current-p state run)
      (if (plist-get value :tool-uses)
          (progn
            (setf (pichat-llm-state-continuation-uncertain state) t)
            (pichat-llm--settle
             session run (or (pichat-llm-state-stream-text state) "")
             "error" "Native tools are disabled until PiChat Phase 4"))
        (let ((text
               (if (and (listp value) (plist-member value :text))
                   (or (plist-get value :text) "")
                 (or (pichat-llm-state-stream-text state) ""))))
          (pichat-llm--settle session run text "stop"))))))

(defun pichat-llm--error (session run type message)
  "Settle SESSION's RUN after provider TYPE and MESSAGE."
  (let ((state (pichat-llm--state session)))
    (when (pichat-llm--run-current-p state run)
      (let ((summary
             (pichat-llm--bounded-error
              (format "%s: %s" type message))))
        (setf (pichat-llm-state-continuation-uncertain state) t)
        (when (pichat-llm--settle
               session run (or (pichat-llm-state-stream-text state) "")
               "error" summary)
          (pichat-emit session 'error
                       :message summary
                       :diagnostic (list :origin 'llm :summary summary)))))))

(defun pichat-llm--accept-submission
    (session state run submission-id message callback)
  "Commit MESSAGE and announce accepted SUBMISSION-ID for SESSION's RUN."
  (when (pichat-llm--run-current-p state run)
    (pichat-llm--commit-message session "user" message)
    ;; The submission callback is an acceptance boundary, not run settlement.
    (when callback
      (funcall callback (list :id submission-id :success t) session))
    (when (pichat-llm--run-current-p state run)
      (let ((raw-message (pichat-llm--message "user" message)))
        (pichat-llm--emit-raw
         session 'agent-start '(:type "agent_start"))
        (pichat-llm--emit-raw
         session 'message-start
         (list :type "message_start" :message raw-message))
        (pichat-llm--emit-raw
         session 'message-end
         (list :type "message_end" :message raw-message))))))

(defun pichat-llm--submission-rejected
    (session state run submission-id first-p error-callback type message)
  "Reject SESSION submission without adding a journal entry."
  (when (pichat-llm--run-current-p state run)
    (setf (pichat-llm-state-request state) nil
          (pichat-llm-state-active-run state) nil
          (pichat-llm-state-submission-id state) nil
          (pichat-session-streaming-p session) nil
          (pichat-session-state session) 'idle)
    (if first-p
        (setf (pichat-llm-state-prompt state) nil)
      ;; The documented API has already appended a user turn and exposes no
      ;; rollback operation.  Do not inspect provider-owned prompt internals.
      (setf (pichat-llm-state-continuation-uncertain state) t))
    (when error-callback
      (funcall
       error-callback
       (list :id submission-id :success nil
             :error (pichat-llm--bounded-error
                     (format "%s: %s" type message)))
       session))))

(cl-defmethod pichat-backend-id ((_backend (eql llm))) 'llm)

(cl-defmethod pichat-backend-label ((_backend (eql llm))) "llm.el")

(cl-defmethod pichat-backend-capabilities ((_backend (eql llm)))
  pichat-backend-llm-capabilities)

(cl-defmethod pichat-backend-start ((_backend (eql llm)) session)
  (pichat-llm--require-public-api)
  (let* ((state (pichat-llm--state session))
         (source-spec (pichat-llm-state-provider-spec state))
         (prepared (pichat-llm--prepare-provider source-spec)))
    ;; Retain SOURCE-SPEC rather than a factory-produced nested specification:
    ;; every later new conversation must start resolution at the user-owned
    ;; factory boundary and receive independent provider state.
    (pichat-llm--install-provider session state prepared)
    (setf (pichat-llm-state-alive state) t
          (pichat-llm-state-source-generation state) 1
          (pichat-llm-state-run-generation state) 0
          (pichat-llm-state-round-generation state) 0
          (pichat-llm-state-sequence state) 0
          (pichat-llm-state-journal state) nil
          (pichat-llm-state-leaf-id state) nil
          (pichat-llm-state-continuation-uncertain state) nil)
    (let ((id (pichat-llm--source-id state)))
      (setf (pichat-session-id session) id
            (pichat-session-session-file session) nil
            (pichat-session-persistence session) 'memory
            (pichat-session-state session) 'idle
            (pichat-session-streaming-p session) nil))
    session))

(cl-defmethod pichat-backend-stop ((_backend (eql llm)) session)
  (let ((state (pichat-llm--state session)))
    (when (pichat-llm-state-alive state)
      (let* ((active (pichat-llm-state-active-run state))
             (text (or (pichat-llm-state-stream-text state) ""))
             (request (pichat-llm--invalidate-run state)))
        (pichat-llm--cancel-model-request request)
        (when active
          (pichat-llm--commit-message
           session "assistant" text "aborted" "Session stopped")
          (pichat-llm--emit-raw
           session 'message-end
           (list :type "message_end"
                 :message
                 (pichat-llm--message
                  "assistant" text "aborted" "Session stopped")))
          (pichat-llm--emit-raw
           session 'agent-settled '(:type "agent_settled")))
        ;; Keep the weak claim while an external reference exists: a stopped
        ;; conversation must not make a mutated provider reusable by accident.
        (setf (pichat-llm-state-alive state) nil
              (pichat-llm-state-provider state) nil
              (pichat-llm-state-provider-spec state) nil
              (pichat-llm-state-call-wrapper state) nil
              (pichat-llm-state-prompt state) nil
              (pichat-llm-state-stream-text state) nil
              (pichat-session-streaming-p session) nil
              (pichat-session-state session) 'stopped)
        (pichat-emit session 'session-ended :reason 'stopped)))
    session))

(cl-defmethod pichat-backend-alive-p ((_backend (eql llm)) session)
  (eq t (pichat-llm-state-alive (pichat-llm--state session))))

(cl-defmethod pichat-backend-submit-preflight
  ((_backend (eql llm)) session _message images _streaming-behavior)
  (let ((state (pichat-llm--state session)))
    (unless (pichat-llm-state-alive state)
      (user-error "Native PiChat session is stopped"))
    (when images
      (user-error "Image input is not available for native text chat yet"))
    (when (pichat-llm-state-active-run state)
      (user-error "A native PiChat response is already running"))
    (when (pichat-llm-state-continuation-uncertain state)
      (user-error
       "Provider conversation state is uncertain; start a new conversation"))
    t))

(cl-defmethod pichat-backend-submit
  ((_backend (eql llm)) session message _images _streaming-behavior
   callback error-callback)
  (let* ((state (pichat-llm--state session))
         (first-p (null (pichat-llm-state-prompt state)))
         (prompt
          (if first-p
              (llm-make-chat-prompt
               message :context (pichat-llm-state-context state))
            (progn
              ;; `llm-chat-prompt-append-response' mutates the retained
              ;; provider prompt and returns its interaction list; retain the
              ;; prompt object itself as the value passed to llm APIs.
              (llm-chat-prompt-append-response
               (pichat-llm-state-prompt state) message)
              (pichat-llm-state-prompt state))))
         (run (1+ (or (pichat-llm-state-run-generation state) 0)))
         (round (1+ (or (pichat-llm-state-round-generation state) 0)))
         (submission-id (format "llm-submit-%d-%d" run round))
         (invoking t)
         queued
         returned)
    (setf (pichat-llm-state-prompt state) prompt
          (pichat-llm-state-run-generation state) run
          (pichat-llm-state-round-generation state) round
          (pichat-llm-state-active-run state) run
          (pichat-llm-state-settled-run state) nil
          (pichat-llm-state-submission-id state) submission-id
          (pichat-llm-state-request state) 'starting
          (pichat-llm-state-stream-text state) nil
          (pichat-llm-state-assistant-started state) nil
          (pichat-session-streaming-p session) t
          (pichat-session-state session) 'running)
    (cl-labels
        ((deliver (kind &rest args)
           (if invoking
               (setq queued (append queued (list (cons kind args))))
             (pcase kind
               ('partial (pichat-llm--partial session run (car args)))
               ('final (pichat-llm--final session run (car args)))
               ('error (pichat-llm--error
                        session run (car args) (cadr args)))))))
      (condition-case err
          (setq returned
                (pichat-llm--call-with-provider-settings
                 state
                 (lambda ()
                   (if (pichat-llm-state-streaming state)
                       (llm-chat-streaming
                        (pichat-llm-state-provider state) prompt
                        (lambda (value) (deliver 'partial value))
                        (lambda (value) (deliver 'final value))
                        (lambda (type value) (deliver 'error type value))
                        t)
                     (llm-chat-async
                      (pichat-llm-state-provider state) prompt
                      (lambda (value) (deliver 'final value))
                      (lambda (type value) (deliver 'error type value))
                      t)))))
        (error
         (setq invoking nil)
         (setf (pichat-llm-state-request state) nil
               (pichat-llm-state-active-run state) nil
               (pichat-llm-state-submission-id state) nil
               (pichat-session-streaming-p session) nil
               (pichat-session-state session) 'idle)
         (if first-p
             (setf (pichat-llm-state-prompt state) nil)
           (setf (pichat-llm-state-continuation-uncertain state) t))
         (user-error "Native provider request failed: %s"
                     (pichat-llm--bounded-error
                      (error-message-string err)))))
      (setq invoking nil)
      (when (and (null returned) (null queued))
        (setf (pichat-llm-state-request state) nil
              (pichat-llm-state-active-run state) nil
              (pichat-llm-state-submission-id state) nil
              (pichat-session-streaming-p session) nil
              (pichat-session-state session) 'idle)
        (if first-p
            (setf (pichat-llm-state-prompt state) nil)
          (setf (pichat-llm-state-continuation-uncertain state) t))
        (user-error "Native provider returned no request handle"))
      (let ((inline-error (seq-find (lambda (item) (eq (car item) 'error))
                                    queued)))
        (if inline-error
            (apply #'pichat-llm--submission-rejected
                   session state run submission-id first-p error-callback
                   (cdr inline-error))
          (when (pichat-llm--run-current-p state run)
            (setf (pichat-llm-state-request state) returned)
            (pichat-llm--accept-submission
             session state run submission-id message callback)
            (dolist (item queued)
              (when (pichat-llm--run-current-p state run)
                (apply #'deliver (car item) (cdr item))))))))
    submission-id))

(cl-defmethod pichat-backend-abort
  ((_backend (eql llm)) session _retrying-p callback)
  (let* ((state (pichat-llm--state session))
         (active (pichat-llm-state-active-run state))
         (text (or (pichat-llm-state-stream-text state) ""))
         (request (and active (pichat-llm--invalidate-run state))))
    (when active
      (pichat-llm--cancel-model-request request)
      (setf (pichat-llm-state-continuation-uncertain state) t
            (pichat-session-streaming-p session) nil
            (pichat-session-state session) 'idle)
      (pichat-llm--commit-message
       session "assistant" text "aborted" "Request aborted")
      (pichat-llm--emit-raw
       session 'message-end
       (list :type "message_end"
             :message
             (pichat-llm--message
              "assistant" text "aborted" "Request aborted")))
      (pichat-llm--emit-raw session 'agent-settled '(:type "agent_settled")))
    (when callback
      (funcall callback
               (list :success t :data (list :aborted (and active t))) session))
    active))

(cl-defmethod pichat-backend-new-conversation
  ((_backend (eql llm)) session callback)
  (let* ((state (pichat-llm--state session))
         (prepared
          ;; Resolve first.  A bad factory or accidentally reused provider must
          ;; leave the current conversation, request, and transcript untouched.
          (pichat-llm--prepare-provider
           (pichat-llm-state-provider-spec state)))
         (active (pichat-llm-state-active-run state))
         (request (pichat-llm--invalidate-run state)))
    (pichat-emit session 'session-rebinding :command "new-conversation")
    (pichat-llm--cancel-model-request request)
    (pichat-llm--install-provider session state prepared)
    (setf (pichat-llm-state-source-generation state)
          (1+ (or (pichat-llm-state-source-generation state) 0))
          (pichat-llm-state-prompt state) nil
          (pichat-llm-state-journal state) nil
          (pichat-llm-state-leaf-id state) nil
          (pichat-llm-state-stream-text state) nil
          (pichat-llm-state-assistant-started state) nil
          (pichat-llm-state-continuation-uncertain state) nil
          (pichat-session-streaming-p session) nil
          (pichat-session-state session) 'idle
          (pichat-session-id session) (pichat-llm--source-id state))
    (pichat-emit session 'session-state-changed
                 :state (pichat-llm--state-data session))
    (when callback
      (funcall callback
               (list :success t :data (list :cancelled (and active t)))
               session))
    session))

(defun pichat-llm--state-data (session)
  "Return a Pi-compatible bounded state snapshot for SESSION."
  (let ((state (pichat-llm--state session)))
    (list :sessionId (pichat-session-id session)
          :sessionName (pichat-session-name session)
          :sessionFile nil
          :model (pichat-session-model session)
          :isStreaming (and (pichat-llm-state-active-run state) t)
          :isCompacting nil)))

(cl-defmethod pichat-backend-request-state
  ((_backend (eql llm)) session callback _error-callback)
  (let* ((state (pichat-llm--state session))
         (id (format "llm-state-%d" (pichat-llm--next-sequence state)))
         (response (list :id id :success t
                         :data (pichat-llm--state-data session))))
    (when callback (funcall callback response session))
    (pichat-emit session 'session-state-changed
                 :state (plist-get response :data))
    id))

(defun pichat-llm--entries-after (journal cursor)
  "Return JOURNAL entries after CURSOR, or the symbol `missing'."
  (if (null cursor)
      journal
    (let ((tail (member cursor
                        (mapcar (lambda (entry) (plist-get entry :id)) journal))))
      (if tail
          (nthcdr (- (length journal) (length tail) -1) journal)
        'missing))))

(cl-defmethod pichat-backend-request-transcript
  ((_backend (eql llm)) session cursor callback error-callback)
  (let* ((state (pichat-llm--state session))
         (query
          (pichat-llm-query-create
           :id (format "llm-query-%d" (pichat-llm--next-sequence state))))
         (entries (pichat-llm--entries-after
                   (pichat-llm-state-journal state) cursor)))
    (if (eq entries 'missing)
        (when error-callback
          (funcall error-callback
                   (list :id (pichat-llm-query-id query) :success nil
                         :error "Unknown native transcript cursor")
                   session))
      (when callback
        (funcall callback
                 (list :id (pichat-llm-query-id query) :success t
                       :data
                       (list :entries (copy-tree entries t)
                             :leafId (pichat-llm-state-leaf-id state)))
                 session)))
    query))

(cl-defmethod pichat-backend-set-name
  ((_backend (eql llm)) session name callback)
  (unless (stringp name) (user-error "Session name must be a string"))
  (setf (pichat-session-name session) name)
  (let ((response (list :success t :data (list :name name))))
    (when callback (funcall callback response session))
    response))

(cl-defmethod pichat-backend-cancel-request
  ((_backend (eql llm)) _session request)
  (when (pichat-llm-query-p request)
    (setf (pichat-llm-query-cancelled request) t))
  request)

(defun pichat-backend-llm-launch (&optional provider model directory)
  "Start and display an independent native conversation.
PROVIDER is an explicit provider object, zero-argument factory, or
`pichat-llm-provider-spec'.  MODEL is required for bare objects/factories.
DIRECTORY defaults to `default-directory'."
  (let* ((spec (pichat-llm--normalize-provider-spec provider model))
         (directory
          (file-name-as-directory
           (expand-file-name (or directory default-directory))))
         (launch-id (cl-incf pichat-llm--launch-counter))
         (scope-key (format "native-memory|%d" launch-id))
         (label (format "llm:%s#%d"
                        (file-name-nondirectory
                         (directory-file-name directory))
                        launch-id))
         (scope (list scope-key directory label))
         (state
          (pichat-llm-state-create
           :provider-spec spec
           :context pichat-llm-context
           :source-generation 0
           :run-generation 0
           :round-generation 0
           :sequence 0))
         (session
          (pichat-session-make
           :backend 'llm
           :backend-state state
           :cwd directory
           :emacs-cwd directory
           :runtime-cwd directory
           :owner-directory directory
           :scope-key scope-key
           :scope-label label
           :owner-scope-key scope-key
           :owner-scope-label label
           :persistence 'memory)))
    (condition-case err
        (progn
          (pichat-backend-start-session session)
          (pichat-register-session session scope)
          (setq pichat-current-session session)
          (pichat-chat-open session t)
          session)
      (error
       (when (pichat-session-alive-p session)
         (pichat-backend-stop-session session))
       (when (fboundp 'pichat-forget-session)
         (pichat-forget-session session))
       (signal (car err) (cdr err))))))

(provide 'pichat-backend-llm)
;;; pichat-backend-llm.el ends here
