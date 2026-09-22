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
(require 'pichat-attachments)
(require 'pichat-backend)
(require 'pichat-chat-diagnostics)
(require 'pichat-events)
(require 'pichat-session)
(require 'pichat-tools)

(eval-when-compile
  ;; These documented llm-vertex settings are dynamically bound only after
  ;; the provider module has defined them at runtime.
  (defvar llm-vertex-gcloud-region)
  (defvar llm-vertex-gcloud-binary))

(declare-function make-llm-openai-compatible "llm-openai" (&rest args))
(declare-function make-llm-vertex "llm-vertex" (&rest args))
(declare-function pichat-llm-vertex-access-token
                  "pichat-llm-vertex-claude" (gcloud))
(declare-function pichat-llm-vertex-claude-create
                  "pichat-llm-vertex-claude" (&rest args))
(declare-function pichat-chat-open "pichat-chat" (session &optional synchronize))
(declare-function pichat-register-session "pichat" (session &optional scope))
(declare-function pichat-forget-session "pichat" (session))
(declare-function pichat-set-default-session "pichat" (session))
(declare-function pichat-chat-diagnostics-record "pichat-chat-diagnostics"
                  (session &rest args))

(defvar pichat-current-session)
(defvar pichat-chat-session)

(defgroup pichat-llm nil
  "Native in-memory llm.el conversations for PiChat."
  :group 'pichat)

(defconst pichat-llm-tested-version "0.32.1"
  "llm.el release covered by PiChat's offline provider fixtures.")

(defcustom pichat-llm-codex-url nil
  "CLIProxyAPI base URL used by the Codex provider factory.
Set this explicitly to the API root, including its version path.  PiChat adds a
trailing slash when needed and does not discover or administer the service."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'pichat-llm)

(defcustom pichat-llm-codex-auth-host nil
  "Auth-source host used for the CLIProxyAPI access key.
This is independent of `pichat-llm-codex-url' so deployments can use an
explicit auth-source identity."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'pichat-llm)

(defcustom pichat-llm-codex-auth-user "apikey"
  "Auth-source user used for the CLIProxyAPI access key."
  :type 'string
  :group 'pichat-llm)

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

(defcustom pichat-llm-reasoning nil
  "Reasoning effort requested for new native conversations.
Nil leaves the provider default unchanged.  Other values are public llm.el
reasoning settings; unsupported providers may ignore them.  PiChat exposes no
mutable reasoning control for native sessions because changing this retained
prompt setting mid-conversation cannot be round-tripped safely."
  :type '(choice (const :tag "Provider default" nil)
                 (const none) (const light) (const medium) (const maximum))
  :group 'pichat-llm)

(defcustom pichat-llm-vertex-gcloud-executable "gcloud"
  "Executable used by PiChat Vertex provider factories."
  :type 'file
  :group 'pichat-llm)

(defcustom pichat-llm-error-max-chars 500
  "Maximum characters retained in an ordinary native provider error."
  :type 'integer
  :group 'pichat-llm)

(defcustom pichat-llm-diagnostic-max-chars 20000
  "Maximum unredacted provider-error characters retained for explicit inspection."
  :type 'integer
  :group 'pichat-llm)

(defcustom pichat-llm-tools nil
  "Names of registered Emacs tools exposed to new native conversations.
Nil keeps native tools disabled.  Every named tool must already be registered,
and its schema must fit PiChat's documented llm.el conversion subset."
  :type '(repeat string)
  :group 'pichat-llm)

(defcustom pichat-llm-max-rounds 8
  "Maximum provider rounds in one native agent run."
  :type 'integer
  :group 'pichat-llm)

(defcustom pichat-llm-max-tool-calls 32
  "Maximum Emacs tool invocations in one native agent run."
  :type 'integer
  :group 'pichat-llm)

(defcustom pichat-llm-max-tool-output-chars 100000
  "Maximum aggregate tool-result characters in one native agent run."
  :type 'integer
  :group 'pichat-llm)

(defcustom pichat-llm-tool-result-max-chars 20000
  "Maximum characters returned by one native Emacs tool invocation."
  :type 'integer
  :group 'pichat-llm)

(cl-defstruct (pichat-llm-provider-spec
               (:constructor pichat-llm-provider-spec-create))
  "Explicit factory and call policy for one native provider family."
  factory
  label
  model
  call-wrapper
  capabilities
  (streaming 'auto))

(cl-defstruct (pichat-llm-query
               (:constructor pichat-llm-query-create))
  "Identity for a local snapshot request; it is not a model request handle."
  id
  cancelled)

(cl-defstruct (pichat-llm-tool-invocation
               (:constructor pichat-llm-tool-invocation-create))
  "One locally identified native tool invocation."
  id name args status result is-error callback run round timer cancel-function)

(cl-defstruct (pichat-llm-state
               (:constructor pichat-llm-state-create))
  "Private native state owned by exactly one PiChat session."
  alive
  provider-spec
  provider
  provider-label
  provider-capabilities
  model
  call-wrapper
  streaming
  base-context
  context
  reasoning
  prompt
  journal
  leaf-id
  request
  submission-id
  stream-text
  stream-reasoning
  stream-order
  round-usage
  usage-rounds
  assistant-started
  tool-names
  tools
  round-tools
  pending-tools
  tool-sequence
  run-round-count
  run-tool-count
  run-tool-output-chars
  budget-error
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
  '(submit abort state transcript stats lifecycle events new-conversation naming
    diagnostic-view)
  "Backend-level capabilities exposed by native memory conversations.
Provider-dependent capabilities such as image input are added per session.")

(defun pichat-llm--nonblank-string-p (value)
  "Return non-nil when VALUE is a nonblank string."
  (and (stringp value) (not (string-blank-p value))))

(defun pichat-llm--require-public-api ()
  "Ensure the loaded llm.el exposes the public API used by PiChat.
Do not silently fall back to private or version-specific implementation
functions when a future llm.el changes one of these application seams."
  (dolist (function '(llm-make-chat-prompt
                      llm-make-tool
                      llm-make-multipart
                      make-llm-media
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

(defun pichat-llm--schema-properties (schema)
  "Return ordered (NAME . SCHEMA) pairs from object SCHEMA."
  (let ((properties (plist-get schema :properties)) pairs)
    (unless (or (null properties) (proper-list-p properties))
      (user-error "Native tool properties must be a plist"))
    (while properties
      (let ((name (pop properties))
            (value (pop properties)))
        (unless (and (or (keywordp name) (symbolp name) (stringp name))
                     (listp value))
          (user-error "Native tool has an invalid property schema"))
        (push (cons (if (stringp name) name
                      (string-remove-prefix ":" (symbol-name name)))
                    value)
              pairs)))
    (nreverse pairs)))

(defun pichat-llm--schema-arg (name schema required)
  "Convert property NAME with SCHEMA and REQUIRED names to an llm argument."
  (let* ((type-name (plist-get schema :type))
         (type (and (stringp type-name) (intern type-name)))
         (items (plist-get schema :items)))
    (unless (memq type '(string integer number boolean array))
      (user-error "Native tool argument %s has unsupported type %S" name type-name))
    (when (and (eq type 'array)
               (not (and (listp items)
                         (member (plist-get items :type)
                                 '("string" "integer" "number" "boolean")))))
      (user-error "Native tool array %s requires primitive items" name))
    (dolist (key '(:oneOf :anyOf :allOf :not :patternProperties))
      (when (plist-member schema key)
        (user-error "Native tool argument %s uses unsupported schema %s"
                    name key)))
    (append
     (list :name name :type type
           :optional (not (member name required)))
     (when (stringp (plist-get schema :description))
       (list :description (plist-get schema :description)))
     (when (vectorp (plist-get schema :enum))
       (list :enum (plist-get schema :enum)))
     (when items
       (list :items
             (list :type (intern (plist-get items :type))))))))

(defun pichat-llm--tool-args (tool)
  "Convert TOOL's documented JSON Schema subset to llm.el arguments."
  (let* ((schema (pichat-tool-parameters tool))
         (required (append (plist-get schema :required) nil)))
    (unless (and (listp schema) (equal (plist-get schema :type) "object"))
      (user-error "Native tool %s requires an object parameter schema"
                  (pichat-tool-name tool)))
    (when (eq (plist-get schema :additionalProperties) t)
      (user-error "Native tool %s allows unsupported arbitrary properties"
                  (pichat-tool-name tool)))
    (dolist (name required)
      (unless (stringp name)
        (user-error "Native tool %s has an invalid required name"
                    (pichat-tool-name tool))))
    (let ((properties (pichat-llm--schema-properties schema)))
      (dolist (name required)
        (unless (assoc name properties)
          (user-error "Native tool %s requires unknown property %s"
                      (pichat-tool-name tool) name)))
      (mapcar (lambda (property)
                (pichat-llm--schema-arg
                 (car property) (cdr property) required))
              properties))))

(defun pichat-llm--tool-params (names values)
  "Return keyword plist pairing tool argument NAMES and VALUES."
  (let (params)
    (while names
      (setq params
            (append params
                    (list (intern (concat ":" (pop names))) (pop values)))))
    params))

(defun pichat-llm--context-with-tools (base names directory)
  "Return BASE plus explicit instructions for tool NAMES in DIRECTORY."
  (let ((instructions (pichat-tools-instructions names)))
    (if (null instructions)
        base
      (string-join
       (delq nil
             (list (and (pichat-llm--nonblank-string-p base) base)
                   (format
                    "Selected Emacs tools operate relative to the local working directory %s. Use only the tools actually provided; do not assume Pi skills, context files, arbitrary Lisp evaluation, additional tools, or paths outside this directory."
                    directory)
                   (string-join instructions "\n")))
       "\n\n"))))

(defun pichat-llm--tool-result-text (result)
  "Return bounded provider text for structured tool RESULT."
  (let* ((value (plist-get result :value))
         (text
          (cond
           ((stringp value) value)
           ((or (listp value) (vectorp value))
            (condition-case nil
                (json-serialize value :false-object :json-false :null-object nil)
              (error (format "%S" value))))
           (t (format "%S" value)))))
    (truncate-string-to-width
     text pichat-llm-tool-result-max-chars nil nil "…")))

(defun pichat-llm--auth-source-key (&optional host user)
  "Return the configured CLIProxyAPI key without caching it in PiChat state.
HOST and USER default to `pichat-llm-codex-auth-host' and
`pichat-llm-codex-auth-user'."
  (let ((host (or host pichat-llm-codex-auth-host))
        (user (or user pichat-llm-codex-auth-user)))
    (unless (and (pichat-llm--nonblank-string-p host)
                 (pichat-llm--nonblank-string-p user))
      (user-error "CLIProxyAPI auth-source host and user must be configured"))
    (let ((secret
           (auth-source-pick-first-password :host host :user user)))
      (unless (pichat-llm--nonblank-string-p secret)
        (user-error "No CLIProxyAPI key in auth-source for %s/%s" host user))
      secret)))

(defun pichat-llm-make-codex-provider (model)
  "Return an explicit provider specification for Codex MODEL via CLIProxyAPI."
  (unless (pichat-llm--nonblank-string-p model)
    (user-error "An explicit Codex model is required"))
  (dolist (pair `((url . ,pichat-llm-codex-url)
                  (auth-host . ,pichat-llm-codex-auth-host)
                  (auth-user . ,pichat-llm-codex-auth-user)))
    (unless (pichat-llm--nonblank-string-p (cdr pair))
      (user-error "CLIProxyAPI %s must be configured" (car pair))))
  (let ((model model)
        (url (if (string-suffix-p "/" pichat-llm-codex-url)
                 pichat-llm-codex-url
               (concat pichat-llm-codex-url "/")))
        (auth-host pichat-llm-codex-auth-host)
        (auth-user pichat-llm-codex-auth-user))
    (pichat-llm-provider-spec-create
     :label "Codex via CLIProxyAPI"
     :model model
     :streaming t
     ;; llm-openai-compatible only advertises model-catalog capabilities;
     ;; CLIProxyAPI's Chat Completions tool path is fixture-tested by PiChat.
     :capabilities '(tool-use)
     :factory
     (lambda ()
       (require 'llm-openai)
       (make-llm-openai-compatible
        :url url
        :key (lambda () (pichat-llm--auth-source-key auth-host auth-user))
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
           ;; llm 0.32.1's Vertex provider misspells these two documented
           ;; capabilities in the plural.  Normalize only that known public
           ;; result shape; PiChat still uses the provider's public methods.
           (capabilities
            (append capabilities
                    (pichat-llm-provider-spec-capabilities spec)
                    (when (memq 'tool-uses capabilities) '(tool-use))
                    (when (memq 'streaming-tool-uses capabilities)
                      '(streaming-tool-use))))
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
          (pichat-llm-state-provider-capabilities state)
          (copy-sequence (plist-get prepared :capabilities))
          (pichat-llm-state-model state) model
          (pichat-llm-state-call-wrapper state)
          (plist-get prepared :call-wrapper)
          (pichat-llm-state-streaming state)
          (plist-get prepared :streaming)
          (pichat-session-model session)
          (list :id model :name model :provider label
                :reasoning
                (and (memq 'reasoning (plist-get prepared :capabilities)) t)
                :input
                (when (memq 'image-input (plist-get prepared :capabilities))
                  '("image"))))))

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

(defun pichat-llm--message-content (text reasoning order images &optional tools)
  "Return ordered Pi-shaped content for TEXT, REASONING, ORDER, IMAGES and TOOLS.
Image data is deliberately excluded from the journal and rendered transcript."
  (let (content)
    (dolist (kind order)
      (pcase kind
        ('reasoning
         (when (and (stringp reasoning) (not (string-empty-p reasoning)))
           (setq content
                 (append content
                         (list (list :type "thinking"
                                     :thinking reasoning))))))
        ('text
         (when (and (stringp text) (not (string-empty-p text)))
           (setq content
                 (append content
                         (list (list :type "text" :text text))))))))
    (unless (or (member 'text order) (string-empty-p (or text "")))
      (setq content (append content (list (list :type "text" :text text)))))
    (dolist (image (append images nil))
      (setq content
            (append content
                    (list (list :type "image"
                                :mediaType (plist-get image :mimeType))))))
    (dolist (invocation tools)
      (setq content
            (append
             content
             (list (list :type "toolCall"
                         :id (pichat-llm-tool-invocation-id invocation)
                         :name (pichat-llm-tool-invocation-name invocation)
                         :arguments
                         (copy-tree
                          (pichat-llm-tool-invocation-args invocation) t))))))
    (or content (list (list :type "text" :text "")))))

(defun pichat-llm--message
    (role text &optional stop-reason error-message reasoning order images tools)
  "Return a private Pi-shaped message for ROLE and normalized output."
  (append
   (list :role role
         :content (pichat-llm--message-content
                   (if (stringp text) text "") reasoning
                   (or order '(text)) images tools))
   (when stop-reason (list :stopReason stop-reason))
   (when error-message (list :errorMessage error-message))))

(defun pichat-llm--commit-message
    (session role text &optional stop-reason error-message reasoning order images tools)
  "Commit an immutable local message entry for SESSION."
  (let* ((state (pichat-llm--state session))
         (id (pichat-llm--entry-id state role))
         (entry
          (list :id id
                :parentId (pichat-llm-state-leaf-id state)
                :type "message"
                :message
                (pichat-llm--message
                 role text stop-reason error-message reasoning order images tools))))
    (setf (pichat-llm-state-journal state)
          (append (pichat-llm-state-journal state) (list entry))
          (pichat-llm-state-leaf-id state) id)
    entry))

(defun pichat-llm--commit-tool-result (session invocation)
  "Commit INVOCATION's immutable tool-result entry for SESSION."
  (let* ((state (pichat-llm--state session))
         (id (pichat-llm--entry-id state "tool-result"))
         (entry
          (list :id id :parentId (pichat-llm-state-leaf-id state)
                :type "message"
                :message
                (list :role "toolResult"
                      :toolCallId (pichat-llm-tool-invocation-id invocation)
                      :toolName (pichat-llm-tool-invocation-name invocation)
                      :isError
                      (if (pichat-llm-tool-invocation-is-error invocation)
                          t :json-false)
                      :content
                      (list (list :type "text"
                                  :text
                                  (or (pichat-llm-tool-invocation-result invocation)
                                      "")))))))
    (setf (pichat-llm-state-journal state)
          (append (pichat-llm-state-journal state) (list entry))
          (pichat-llm-state-leaf-id state) id)
    entry))

(defun pichat-llm--run-current-p (state run)
  "Return non-nil when RUN still owns live STATE."
  (and (pichat-llm-state-alive state)
       (equal run (pichat-llm-state-active-run state))
       (= run (pichat-llm-state-run-generation state))))

(defun pichat-llm--chat-focused-p (session)
  "Return non-nil when SESSION's chat owns the selected focused window."
  (let ((buffer
         (seq-find
          (lambda (candidate)
            (and (buffer-live-p candidate)
                 (local-variable-p 'pichat-chat-session candidate)
                 (eq session
                     (buffer-local-value 'pichat-chat-session candidate))))
          (buffer-list))))
    (and buffer
         (eq buffer (window-buffer (selected-window)))
         (or noninteractive (frame-focus-state (selected-frame))))))

(defun pichat-llm--emit-tool-event (session event invocation &optional result)
  "Emit Pi-compatible tool EVENT for INVOCATION and optional RESULT."
  (let ((raw
         (pcase event
           ('tool-execution-start
            (list :type "tool_execution_start"
                  :toolCallId (pichat-llm-tool-invocation-id invocation)
                  :toolName (pichat-llm-tool-invocation-name invocation)
                  :args (pichat-llm-tool-invocation-args invocation)))
           ('tool-execution-end
            (list :type "tool_execution_end"
                  :toolCallId (pichat-llm-tool-invocation-id invocation)
                  :toolName (pichat-llm-tool-invocation-name invocation)
                  :result
                  (list :content
                        (vector (list :type "text" :text (or result ""))))
                  :isError
                  (if (pichat-llm-tool-invocation-is-error invocation)
                      t :json-false))))))
    (pichat-llm--emit-raw session event raw)))

(defun pichat-llm--finish-tool (session state invocation result is-error)
  "Finish INVOCATION with RESULT when it still belongs to live STATE."
  (let ((run (pichat-llm-tool-invocation-run invocation))
        (callback (pichat-llm-tool-invocation-callback invocation)))
    (when (and callback
               (pichat-llm--run-current-p state run)
               (eq (pichat-llm-tool-invocation-status invocation) 'pending))
      (let* ((text (pichat-llm--tool-result-text
                    (list :is-error is-error :value result)))
             (total (+ (or (pichat-llm-state-run-tool-output-chars state) 0)
                       (length text))))
        (when (> total pichat-llm-max-tool-output-chars)
          (setq text "Tool output budget exhausted"
                is-error t)
          (setf (pichat-llm-state-budget-error state)
                "Native tool output budget exhausted"))
        (setf (pichat-llm-state-run-tool-output-chars state) total
              (pichat-llm-tool-invocation-result invocation) text
              (pichat-llm-tool-invocation-is-error invocation) is-error
              (pichat-llm-tool-invocation-status invocation) 'done
              (pichat-llm-tool-invocation-callback invocation) nil)
        (pichat-llm--emit-tool-event
         session 'tool-execution-end invocation text)
        (funcall callback (if is-error (concat "Error: " text) text))))))

(defun pichat-llm--execute-tool (session state invocation tool)
  "Execute TOOL for INVOCATION if its run remains current."
  (when (and (pichat-llm--run-current-p
              state (pichat-llm-tool-invocation-run invocation))
             (eq (pichat-llm-tool-invocation-status invocation) 'pending))
    (setf (pichat-llm-tool-invocation-status invocation) 'executing)
    (let ((cancel
           (pichat-tools-call-async
            tool (pichat-llm-tool-invocation-args invocation)
            (lambda (result)
              (when (eq (pichat-llm-tool-invocation-status invocation)
                        'executing)
                ;; `pichat-llm--finish-tool' accepts pending invocations.  Move
                ;; back atomically only for this callback; cancellation changes
                ;; the state to `cancelled' first and therefore stays inert.
                (setf (pichat-llm-tool-invocation-status invocation) 'pending)
                (pichat-llm--finish-tool
                 session state invocation (plist-get result :value)
                 (plist-get result :is-error))))
            session)))
      (when (eq (pichat-llm-tool-invocation-status invocation) 'executing)
        (setf (pichat-llm-tool-invocation-cancel-function invocation) cancel)))))

(defun pichat-llm--run-next-approval (session state)
  "Prompt for STATE's oldest queued native tool when SESSION is focused."
  (let ((invocation (car (pichat-llm-state-pending-tools state))))
    (when invocation
      (setf (pichat-llm-tool-invocation-timer invocation) nil)
      (if (not (and (pichat-llm--run-current-p
                     state (pichat-llm-tool-invocation-run invocation))
                    (eq (pichat-llm-tool-invocation-status invocation)
                        'pending)))
          (setf (pichat-llm-state-pending-tools state)
                (cdr (pichat-llm-state-pending-tools state)))
        (if (not (pichat-llm--chat-focused-p session))
            (setf (pichat-llm-tool-invocation-timer invocation)
                  (run-at-time 0.1 nil #'pichat-llm--run-next-approval
                               session state))
          (let* ((tool (gethash (pichat-llm-tool-invocation-name invocation)
                                pichat-tools-registry))
                 (allowed
                  (and tool
                       (pichat-approval-prompt
                        (pichat-tool-name tool)
                        (pichat-llm-tool-invocation-args invocation)
                        session))))
            (setf (pichat-llm-state-pending-tools state)
                  (cdr (pichat-llm-state-pending-tools state)))
            (if allowed
                (pichat-llm--execute-tool session state invocation tool)
              (pichat-llm--finish-tool
               session state invocation "Denied by user" t))
            (pichat-llm--schedule-next-approval session state)))))))

(defun pichat-llm--schedule-next-approval (session state)
  "Schedule STATE's oldest approval request for focused SESSION."
  (let ((invocation (car (pichat-llm-state-pending-tools state))))
    (when (and invocation
               (null (pichat-llm-tool-invocation-timer invocation)))
      (setf (pichat-llm-tool-invocation-timer invocation)
            (run-at-time 0 nil #'pichat-llm--run-next-approval
                         session state)))))

(defun pichat-llm--cancel-pending-tools (state)
  "Cancel approvals/executions and invalidate pending callbacks in STATE."
  (dolist (invocation
           (delete-dups
            (append (pichat-llm-state-round-tools state)
                    (pichat-llm-state-pending-tools state))))
    (when (memq (pichat-llm-tool-invocation-status invocation)
                '(pending executing))
      (let ((timer (pichat-llm-tool-invocation-timer invocation))
            (cancel (pichat-llm-tool-invocation-cancel-function invocation)))
        (when (timerp timer) (cancel-timer timer))
        (setf (pichat-llm-tool-invocation-status invocation) 'cancelled
              (pichat-llm-tool-invocation-callback invocation) nil
              (pichat-llm-tool-invocation-timer invocation) nil
              (pichat-llm-tool-invocation-cancel-function invocation) nil)
        (when (functionp cancel)
          (condition-case nil (funcall cancel) (error nil))))))
  (setf (pichat-llm-state-pending-tools state) nil))

(defun pichat-llm--invoke-tool
    (session state tool arg-names callback values)
  "Start one async TOOL invocation with VALUES for SESSION and STATE."
  (let* ((run (pichat-llm-state-active-run state))
         (count (1+ (or (pichat-llm-state-run-tool-count state) 0)))
         (invocation
          (pichat-llm-tool-invocation-create
           :id (format "native-tool-%d-%d"
                       run (1+ (or (pichat-llm-state-tool-sequence state) 0)))
           :name (pichat-tool-name tool)
           :args (pichat-llm--tool-params arg-names values)
           :status 'pending :callback callback :run run
           :round (pichat-llm-state-round-generation state))))
    (setf (pichat-llm-state-tool-sequence state)
          (1+ (or (pichat-llm-state-tool-sequence state) 0))
          (pichat-llm-state-run-tool-count state) count
          (pichat-llm-state-round-tools state)
          (append (pichat-llm-state-round-tools state) (list invocation)))
    (pichat-llm--emit-tool-event session 'tool-execution-start invocation)
    (if (> count pichat-llm-max-tool-calls)
        (progn
          (setf (pichat-llm-state-budget-error state)
                "Native tool-call budget exhausted")
          (pichat-llm--finish-tool
           session state invocation "Tool-call budget exhausted" t))
      (pcase (pichat-approval-resolve
              (pichat-tool-name tool) (pichat-tool-mutating-p tool) session)
        ('allow (pichat-llm--execute-tool session state invocation tool))
        ('deny (pichat-llm--finish-tool
                session state invocation "Denied by policy" t))
        (_
         (setf (pichat-llm-state-pending-tools state)
               (append (pichat-llm-state-pending-tools state)
                       (list invocation)))
         (pichat-llm--schedule-next-approval session state))))))

(defun pichat-llm--build-tools (session state capabilities)
  "Build configured llm tools for SESSION and STATE under CAPABILITIES."
  (when (pichat-llm-state-tool-names state)
    (unless (memq 'tool-use capabilities)
      (user-error "Native provider lacks tested tool-use support"))
    (mapcar
     (lambda (name)
       (let ((tool (gethash name pichat-tools-registry)))
         (unless tool (user-error "Unknown configured Emacs tool: %s" name))
         (unless (string-match-p "\\`[A-Za-z0-9_-]+\\'" name)
           (user-error "Native tool name is not provider-safe: %s" name))
         (let* ((args (pichat-llm--tool-args tool))
                (arg-names (mapcar (lambda (arg) (plist-get arg :name)) args)))
           (llm-make-tool
            :name name :description (pichat-tool-description tool) :args args
            :async t
            :function
            (lambda (callback &rest values)
              (pichat-llm--invoke-tool
               session state tool arg-names callback values))))))
     (pichat-llm-state-tool-names state))))

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
    (pichat-llm--cancel-pending-tools state)
    (setf (pichat-llm-state-run-generation state)
          (1+ (or (pichat-llm-state-run-generation state) 0))
          (pichat-llm-state-active-run state) nil
          (pichat-llm-state-request state) nil
          (pichat-llm-state-submission-id state) nil)
    request))

(defun pichat-llm--emit-assistant-snapshot (session state type)
  "Emit cumulative assistant STATE for SESSION as Pi-compatible TYPE."
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
         :message
         (pichat-llm--message
          "assistant"
          (or (pichat-llm-state-stream-text state) "") nil nil
          (pichat-llm-state-stream-reasoning state)
          (pichat-llm-state-stream-order state)))))

(defun pichat-llm--output-key-kind (key)
  "Return normalized output kind for multi-output KEY, or nil."
  (pcase key (:text 'text) (:reasoning 'reasoning) (_ nil)))

(defun pichat-llm--apply-output (state value)
  "Apply cumulative multi-output VALUE to STATE.
Absent keys preserve prior snapshots; present string values authoritatively
replace them.  Return non-nil when visible output changed."
  (let ((changed nil))
    (when (listp value)
      (cl-loop for (key item) on value by #'cddr
               for kind = (pichat-llm--output-key-kind key)
               when kind
               do
               (when (stringp item)
                 (unless (memq kind (pichat-llm-state-stream-order state))
                   (setf (pichat-llm-state-stream-order state)
                         (append (pichat-llm-state-stream-order state)
                                 (list kind))))
                 (pcase kind
                   ('text
                    (unless (equal item (pichat-llm-state-stream-text state))
                      (setf (pichat-llm-state-stream-text state) item
                            changed t)))
                   ('reasoning
                    (unless (equal
                             item
                             (pichat-llm-state-stream-reasoning state))
                      (setf (pichat-llm-state-stream-reasoning state) item
                            changed t))))))
      (dolist (pair '((:input-tokens . :inputTokens)
                      (:output-tokens . :outputTokens)))
        (let ((value-key (car pair))
              (usage-key (cdr pair)))
          (when (and (plist-member value value-key)
                     (numberp (plist-get value value-key))
                     (>= (plist-get value value-key) 0))
            (setf (pichat-llm-state-round-usage state)
                  (plist-put (pichat-llm-state-round-usage state)
                             usage-key (plist-get value value-key)))))))
    changed))

(defun pichat-llm--finish-round-usage (state run)
  "Commit STATE's reported or explicitly missing usage for RUN."
  (let* ((usage (pichat-llm-state-round-usage state))
         (record
          (append (list :run run
                        :status (if usage "reported" "missing")
                        :estimated nil)
                  usage)))
    (setf (pichat-llm-state-usage-rounds state)
          (append (pichat-llm-state-usage-rounds state) (list record)))))

(defun pichat-llm--partial (session run value)
  "Apply cumulative multi-output VALUE for SESSION's RUN."
  (let ((state (pichat-llm--state session)))
    (when (and (pichat-llm--run-current-p state run)
               (pichat-llm--apply-output state value))
      (pichat-llm--emit-assistant-snapshot
       session state "message_update"))))

(defun pichat-llm--settle
    (session run stop-reason &optional error-message round-committed)
  "Commit and settle SESSION's RUN with its authoritative output.
When ROUND-COMMITTED is non-nil, tool-round entries and usage already exist."
  (let ((state (pichat-llm--state session)))
    (when (and (pichat-llm--run-current-p state run)
               (not (equal run (pichat-llm-state-settled-run state))))
      (let* ((text (or (pichat-llm-state-stream-text state) ""))
             (reasoning (pichat-llm-state-stream-reasoning state))
             (order (pichat-llm-state-stream-order state))
             (safe-error
              (and error-message (pichat-llm--bounded-error error-message)))
             (message
              (pichat-llm--message
               "assistant" text stop-reason safe-error reasoning order)))
        (unless round-committed
          (pichat-llm--finish-round-usage state run))
        (setf (pichat-llm-state-request state) nil
              (pichat-llm-state-submission-id state) nil
              (pichat-llm-state-active-run state) nil
              (pichat-llm-state-settled-run state) run
              (pichat-session-streaming-p session) nil
              (pichat-session-state session) 'idle)
        (unless round-committed
          (pichat-llm--commit-message
           session "assistant" text stop-reason safe-error reasoning order))
        (pichat-llm--emit-raw
         session 'message-end (list :type "message_end" :message message))
        (pichat-llm--emit-raw session 'turn-end '(:type "turn_end"))
        (pichat-llm--emit-raw
         session 'agent-settled '(:type "agent_settled"))
        t))))

(defun pichat-llm--settle-budget (session run message)
  "Commit explicit budget MESSAGE and settle SESSION's RUN."
  (let ((state (pichat-llm--state session)))
    (setf (pichat-llm-state-stream-text state) nil
          (pichat-llm-state-stream-reasoning state) nil
          (pichat-llm-state-stream-order state) nil)
    (pichat-llm--commit-message session "assistant" "" "error" message)
    (pichat-llm--settle session run "error" message t)))

(defun pichat-llm--continue-round (session run)
  "Issue the next provider round for SESSION's current RUN and retained prompt."
  (let* ((state (pichat-llm--state session))
         (rounds (1+ (or (pichat-llm-state-run-round-count state) 0))))
    (if (> rounds pichat-llm-max-rounds)
        (progn
          (setf (pichat-llm-state-budget-error state)
                "Native provider-round budget exhausted")
          (pichat-llm--settle-budget
           session run (pichat-llm-state-budget-error state)))
      (setf (pichat-llm-state-run-round-count state) rounds
            (pichat-llm-state-round-generation state)
            (1+ (or (pichat-llm-state-round-generation state) 0))
            (pichat-llm-state-request state) 'starting
            (pichat-llm-state-stream-text state) nil
            (pichat-llm-state-stream-reasoning state) nil
            (pichat-llm-state-stream-order state) nil
            (pichat-llm-state-round-usage state) nil
            (pichat-llm-state-round-tools state) nil
            (pichat-llm-state-assistant-started state) nil)
      (let ((invoking t) queued returned)
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
                       ;; Tool-enabled rounds deliberately use the tested
                       ;; non-streaming tool-use path in llm 0.32.1.
                       (llm-chat-async
                        (pichat-llm-state-provider state)
                        (pichat-llm-state-prompt state)
                        (lambda (value) (deliver 'final value))
                        (lambda (type value) (deliver 'error type value))
                        t))))
            (error
             (setq invoking nil)
             (pichat-llm--error session run 'error
                                (error-message-string err))))
          (setq invoking nil)
          (when (and (pichat-llm--run-current-p state run) returned)
            (setf (pichat-llm-state-request state) returned))
          (when (and (pichat-llm--run-current-p state run)
                     (null returned) (null queued))
            (pichat-llm--error
             session run 'error "Native provider returned no request handle"))
          (dolist (item queued)
            (when (pichat-llm--run-current-p state run)
              (apply #'deliver (car item) (cdr item)))))))))

(defun pichat-llm--final (session run value)
  "Handle final multi-output VALUE for SESSION's RUN."
  (let ((state (pichat-llm--state session)))
    (when (pichat-llm--run-current-p state run)
      (pichat-llm--apply-output state value)
      (let ((tools (pichat-llm-state-round-tools state)))
        (if tools
            (progn
              (pichat-llm--finish-round-usage state run)
              (pichat-llm--commit-message
               session "assistant"
               (or (pichat-llm-state-stream-text state) "")
               "toolUse" nil
               (pichat-llm-state-stream-reasoning state)
               (pichat-llm-state-stream-order state) nil tools)
              (pichat-llm--emit-raw
               session 'message-end
               (list :type "message_end"
                     :message
                     (pichat-llm--message
                      "assistant"
                      (or (pichat-llm-state-stream-text state) "")
                      "toolUse" nil
                      (pichat-llm-state-stream-reasoning state)
                      (pichat-llm-state-stream-order state) nil tools)))
              (dolist (invocation tools)
                (pichat-llm--commit-tool-result session invocation))
              (if (pichat-llm-state-budget-error state)
                  (pichat-llm--settle-budget
                   session run (pichat-llm-state-budget-error state))
                (pichat-llm--continue-round session run)))
          (pichat-llm--settle session run "stop"))))))

(defun pichat-llm--error (session run type message)
  "Settle SESSION's RUN after provider TYPE and MESSAGE."
  (let ((state (pichat-llm--state session)))
    (when (pichat-llm--run-current-p state run)
      (let ((summary
             (pichat-llm--bounded-error
              (format "%s: %s" type message))))
        (setf (pichat-llm-state-continuation-uncertain state) t)
        (when (pichat-llm--settle session run "error" summary)
          (when (fboundp 'pichat-chat-diagnostics-record)
            (let ((raw
                   (truncate-string-to-width
                    (format "%s" message)
                    pichat-llm-diagnostic-max-chars nil nil "…")))
              (pichat-chat-diagnostics-record
               session :origin 'llm-provider :message raw
               :condition (list type))))
          (pichat-emit session 'error
                       :message summary
                       :diagnostic (list :origin 'llm :summary summary)))))))

(defun pichat-llm--accept-submission
    (session state run submission-id message images callback)
  "Commit MESSAGE and IMAGES and announce accepted SUBMISSION-ID for RUN."
  (when (pichat-llm--run-current-p state run)
    (pichat-llm--commit-message
     session "user" message nil nil nil '(text) images)
    ;; The submission callback is an acceptance boundary, not run settlement.
    (when callback
      (funcall callback (list :id submission-id :success t) session))
    (when (pichat-llm--run-current-p state run)
      (let ((raw-message
             (pichat-llm--message
              "user" message nil nil nil '(text) images)))
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

(cl-defmethod pichat-backend-session-capabilities
  ((_backend (eql llm)) session)
  (let* ((state (pichat-llm--state session))
         (provider-capabilities
          (pichat-llm-state-provider-capabilities state)))
    (append pichat-backend-llm-capabilities
            (when (pichat-llm-state-tools state) '(tools))
            (when (memq 'image-input provider-capabilities) '(image-input))
            (when (memq 'reasoning provider-capabilities)
              '(reasoning-output)))))

(defun pichat-llm--media-parts (images)
  "Validate wire-format IMAGES and return independent llm media objects."
  (unless (or (vectorp images) (proper-list-p images))
    (user-error "Invalid native image attachment set"))
  (when (> (length images) pichat-attachments-max-count)
    (user-error "PiChat attachment limit is %d images"
                pichat-attachments-max-count))
  (let ((total 0) media)
    (dolist (image (append images nil) (nreverse media))
      (let ((type (plist-get image :type))
            (mime-type (plist-get image :mimeType))
            (encoded (plist-get image :data))
            decoded)
        (unless (and (equal type "image")
                     (stringp mime-type)
                     (member mime-type pichat-attachments-allowed-mime-types)
                     (stringp encoded))
          (user-error "Invalid native image attachment"))
        (when (> (length encoded)
                 (+ 4 (* 4 (/ (+ pichat-attachments-max-file-bytes 2) 3))))
          (user-error "Encoded native image exceeds the bounded input size"))
        (setq decoded
              (condition-case nil
                  (base64-decode-string encoded)
                (error (user-error "Invalid native image attachment data"))))
        (when (zerop (length decoded))
          (user-error "Native image attachment is empty"))
        (when (> (length decoded) pichat-attachments-max-file-bytes)
          (user-error "Native image exceeds the %d byte limit"
                      pichat-attachments-max-file-bytes))
        (cl-incf total (length decoded))
        (when (> total pichat-attachments-max-total-bytes)
          (user-error "Native image total exceeds the %d byte limit"
                      pichat-attachments-max-total-bytes))
        (push (make-llm-media
               :mime-type mime-type :data (encode-coding-string decoded 'binary))
              media)))))

(defun pichat-llm--prompt-content (message images)
  "Return llm prompt content containing MESSAGE and wire-format IMAGES."
  (if images
      (apply #'llm-make-multipart
             (cons message (pichat-llm--media-parts images)))
    message))

(cl-defmethod pichat-backend-start ((_backend (eql llm)) session)
  (pichat-llm--require-public-api)
  (let* ((state (pichat-llm--state session))
         (source-spec (pichat-llm-state-provider-spec state))
         (prepared (pichat-llm--prepare-provider source-spec))
         (tools (pichat-llm--build-tools
                 session state (plist-get prepared :capabilities))))
    ;; Retain SOURCE-SPEC rather than a factory-produced nested specification:
    ;; every later new conversation must start resolution at the user-owned
    ;; factory boundary and receive independent provider state.
    (pichat-llm--install-provider session state prepared)
    (let ((base-context (or (pichat-llm-state-base-context state)
                            (pichat-llm-state-context state))))
      (setf (pichat-llm-state-base-context state) base-context
            (pichat-llm-state-context state)
            (pichat-llm--context-with-tools
             base-context (pichat-llm-state-tool-names state)
             (pichat-session-emacs-cwd session))))
    (setf (pichat-llm-state-tools state) tools
          (pichat-llm-state-alive state) t
          (pichat-llm-state-source-generation state) 1
          (pichat-llm-state-run-generation state) 0
          (pichat-llm-state-round-generation state) 0
          (pichat-llm-state-sequence state) 0
          (pichat-llm-state-journal state) nil
          (pichat-llm-state-leaf-id state) nil
          (pichat-llm-state-stream-text state) nil
          (pichat-llm-state-stream-reasoning state) nil
          (pichat-llm-state-stream-order state) nil
          (pichat-llm-state-round-usage state) nil
          (pichat-llm-state-usage-rounds state) nil
          (pichat-llm-state-round-tools state) nil
          (pichat-llm-state-pending-tools state) nil
          (pichat-llm-state-tool-sequence state) 0
          (pichat-llm-state-run-round-count state) 0
          (pichat-llm-state-run-tool-count state) 0
          (pichat-llm-state-run-tool-output-chars state) 0
          (pichat-llm-state-budget-error state) nil
          (pichat-llm-state-continuation-uncertain state) nil
          (pichat-session-context-usage session) nil)
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
           session "assistant" text "aborted" "Session stopped"
           (pichat-llm-state-stream-reasoning state)
           (pichat-llm-state-stream-order state))
          (pichat-llm--emit-raw
           session 'message-end
           (list :type "message_end"
                 :message
                 (pichat-llm--message
                  "assistant" text "aborted" "Session stopped"
                  (pichat-llm-state-stream-reasoning state)
                  (pichat-llm-state-stream-order state))))
          (pichat-llm--emit-raw
           session 'agent-settled '(:type "agent_settled")))
        ;; Keep the weak claim while an external reference exists: a stopped
        ;; conversation must not make a mutated provider reusable by accident.
        (setf (pichat-llm-state-alive state) nil
              (pichat-llm-state-provider state) nil
              (pichat-llm-state-provider-spec state) nil
              (pichat-llm-state-provider-capabilities state) nil
              (pichat-llm-state-call-wrapper state) nil
              (pichat-llm-state-tools state) nil
              (pichat-llm-state-round-tools state) nil
              (pichat-llm-state-prompt state) nil
              (pichat-llm-state-stream-text state) nil
              (pichat-llm-state-stream-reasoning state) nil
              (pichat-llm-state-stream-order state) nil
              (pichat-llm-state-round-usage state) nil
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
      ;; Validate the bounded wire records without mutating prompt/session state.
      (pichat-llm--media-parts images))
    (when (pichat-llm-state-active-run state)
      (user-error "A native PiChat response is already running"))
    (when (pichat-llm-state-continuation-uncertain state)
      (user-error
       "Provider conversation state is uncertain; start a new conversation"))
    t))

(cl-defmethod pichat-backend-submit
  ((_backend (eql llm)) session message images _streaming-behavior
   callback error-callback)
  (let* ((state (pichat-llm--state session))
         (content (pichat-llm--prompt-content message images))
         (first-p (null (pichat-llm-state-prompt state)))
         (prompt
          (if first-p
              (llm-make-chat-prompt
               content :context (pichat-llm-state-context state)
               :reasoning (pichat-llm-state-reasoning state)
               :tools (pichat-llm-state-tools state))
            (progn
              ;; `llm-chat-prompt-append-response' mutates the retained
              ;; provider prompt and returns its interaction list; retain the
              ;; prompt object itself as the value passed to llm APIs.
              (llm-chat-prompt-append-response
               (pichat-llm-state-prompt state) content)
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
          (pichat-llm-state-stream-reasoning state) nil
          (pichat-llm-state-stream-order state) nil
          (pichat-llm-state-round-usage state) nil
          (pichat-llm-state-round-tools state) nil
          (pichat-llm-state-pending-tools state) nil
          (pichat-llm-state-tool-sequence state) 0
          (pichat-llm-state-run-round-count state) 1
          (pichat-llm-state-run-tool-count state) 0
          (pichat-llm-state-run-tool-output-chars state) 0
          (pichat-llm-state-budget-error state) nil
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
                   (if (and (pichat-llm-state-streaming state)
                            (null (pichat-llm-state-tools state)))
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
             session state run submission-id message images callback)
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
       session "assistant" text "aborted" "Request aborted"
       (pichat-llm-state-stream-reasoning state)
       (pichat-llm-state-stream-order state))
      (pichat-llm--emit-raw
       session 'message-end
       (list :type "message_end"
             :message
             (pichat-llm--message
              "assistant" text "aborted" "Request aborted"
              (pichat-llm-state-stream-reasoning state)
              (pichat-llm-state-stream-order state))))
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
         (tools (pichat-llm--build-tools
                 session state (plist-get prepared :capabilities)))
         (active (pichat-llm-state-active-run state))
         (request (pichat-llm--invalidate-run state)))
    (pichat-emit session 'session-rebinding :command "new-conversation")
    (pichat-llm--cancel-model-request request)
    (pichat-llm--install-provider session state prepared)
    (setf (pichat-llm-state-tools state) tools
          (pichat-llm-state-source-generation state)
          (1+ (or (pichat-llm-state-source-generation state) 0))
          (pichat-llm-state-prompt state) nil
          (pichat-llm-state-journal state) nil
          (pichat-llm-state-leaf-id state) nil
          (pichat-llm-state-stream-text state) nil
          (pichat-llm-state-stream-reasoning state) nil
          (pichat-llm-state-stream-order state) nil
          (pichat-llm-state-round-usage state) nil
          (pichat-llm-state-usage-rounds state) nil
          (pichat-llm-state-assistant-started state) nil
          (pichat-llm-state-round-tools state) nil
          (pichat-llm-state-pending-tools state) nil
          (pichat-llm-state-tool-sequence state) 0
          (pichat-llm-state-run-round-count state) 0
          (pichat-llm-state-run-tool-count state) 0
          (pichat-llm-state-run-tool-output-chars state) 0
          (pichat-llm-state-budget-error state) nil
          (pichat-llm-state-continuation-uncertain state) nil
          (pichat-session-context-usage session) nil
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

(defun pichat-llm--usage-data (state)
  "Return explicit reported/missing usage data for STATE."
  (let* ((rounds (pichat-llm-state-usage-rounds state))
         (reported
          (seq-filter
           (lambda (round) (equal (plist-get round :status) "reported"))
           rounds))
         (input-values
          (cl-loop for round in reported
                   for value = (plist-get round :inputTokens)
                   when (numberp value) collect value))
         (output-values
          (cl-loop for round in reported
                   for value = (plist-get round :outputTokens)
                   when (numberp value) collect value))
         (input (and input-values (apply #'+ input-values)))
         (output (and output-values (apply #'+ output-values)))
         (latest (car (last rounds))))
    (if (null reported)
        (list :usageStatus "missing" :contextUsage nil
              :roundUsage (and latest (copy-tree latest t))
              :usageRounds (vconcat (copy-tree rounds t)))
      (list
       :usageStatus "reported"
       :roundUsage (copy-tree latest t)
       :usageRounds (vconcat (copy-tree rounds t))
       ;; This is accumulated request usage, not current context occupancy.
       ;; Deliberately omit contextWindow and percent.
       :contextUsage
       (list :kind "reported" :scope "accumulatedRequests"
             :estimated nil :tokens (+ (or input 0) (or output 0))
             :inputTokens input :outputTokens output
             :roundCount (length rounds)
             :reportedRoundCount (length reported))))))

(cl-defmethod pichat-backend-request-stats
  ((_backend (eql llm)) session callback _error-callback)
  (let* ((state (pichat-llm--state session))
         (query
          (pichat-llm-query-create
           :id (format "llm-stats-%d" (pichat-llm--next-sequence state))))
         (data (pichat-llm--usage-data state))
         (response (list :id (pichat-llm-query-id query)
                         :success t :data data)))
    (pichat-session-apply-rpc-stats session data)
    (when callback (funcall callback response session))
    query))

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
           :base-context pichat-llm-context
           :context pichat-llm-context
           :reasoning pichat-llm-reasoning
           :tool-names (copy-sequence pichat-llm-tools)
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
