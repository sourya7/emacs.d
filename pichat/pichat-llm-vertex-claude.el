;;; pichat-llm-vertex-claude.el --- Claude through Vertex for llm.el -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused llm.el provider for Anthropic models served by Google Vertex AI.
;; This module implements only documented llm provider generics and helpers.
;; PiChat lifecycle and transcript ownership intentionally live elsewhere.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'llm)
(require 'llm-provider-utils)
(require 'llm-request-plz)
(require 'plz-event-source)

(cl-defstruct (pichat-llm-vertex-claude
               (:include llm-standard-chat-provider)
               (:constructor pichat-llm-vertex-claude-create
                             (&key project region model token-function
                                   default-chat-temperature
                                   default-chat-max-tokens
                                   default-chat-non-standard-params)))
  "An llm.el provider for Claude models served by Vertex AI."
  project
  region
  model
  token-function
  token
  pending-multi-turn)

(defun pichat-llm-vertex-access-token (gcloud)
  "Return a short-lived Vertex access token using GCLOUD.
Signal a bounded provider configuration error without retaining command output."
  (unless (and (stringp gcloud) (not (string-blank-p gcloud)))
    (signal 'llm-provider-unconfigured
            '("A gcloud executable is required for Vertex authentication")))
  (with-temp-buffer
    (let ((status (condition-case err
                      (process-file gcloud nil t nil
                                    "auth" "print-access-token")
                    (file-missing
                     (signal 'llm-provider-unconfigured
                             (list "The configured gcloud executable is unavailable")))
                    (error
                     (signal 'llm-provider-error
                             (list (format "Vertex authentication failed: %s"
                                           (error-message-string err))))))))
      (unless (and (integerp status) (zerop status))
        (signal 'llm-provider-error
                (list (format "Vertex authentication failed (gcloud exit %s)"
                              status))))
      (let ((token (string-trim (buffer-string))))
        (when (string-empty-p token)
          (signal 'llm-provider-error
                  '("Vertex authentication returned an empty access token")))
        token))))

(defun pichat-llm-vertex-claude--validate (provider)
  "Validate required configuration on PROVIDER."
  (dolist (slot `((project . ,(pichat-llm-vertex-claude-project provider))
                  (region . ,(pichat-llm-vertex-claude-region provider))
                  (model . ,(pichat-llm-vertex-claude-model provider))))
    (unless (and (stringp (cdr slot)) (not (string-blank-p (cdr slot))))
      (signal 'llm-provider-unconfigured
              (list (format "Vertex Claude %s is required" (car slot))))))
  (unless (functionp (pichat-llm-vertex-claude-token-function provider))
    (signal 'llm-provider-unconfigured
            '("Vertex Claude token function is required"))))

(cl-defmethod llm-provider-request-prelude
  ((provider pichat-llm-vertex-claude))
  (pichat-llm-vertex-claude--validate provider)
  (let ((token
         (funcall (pichat-llm-vertex-claude-token-function provider))))
    (unless (and (stringp token) (not (string-blank-p token)))
      (signal 'llm-provider-error
              '("Vertex authentication returned an empty access token")))
    (setf (pichat-llm-vertex-claude-token provider) token)))

(cl-defmethod llm-provider-headers
  ((provider pichat-llm-vertex-claude))
  `(("Authorization" .
     ,(concat "Bearer " (pichat-llm-vertex-claude-token provider)))))

(defun pichat-llm-vertex-claude--url (provider method)
  "Return PROVIDER's regional Vertex URL ending in METHOD."
  (format
   "https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/anthropic/models/%s:%s"
   (pichat-llm-vertex-claude-region provider)
   (pichat-llm-vertex-claude-project provider)
   (pichat-llm-vertex-claude-region provider)
   (pichat-llm-vertex-claude-model provider)
   method))

(cl-defmethod llm-provider-chat-url
  ((provider pichat-llm-vertex-claude))
  (pichat-llm-vertex-claude--url provider "rawPredict"))

(cl-defmethod llm-provider-chat-streaming-url
  ((provider pichat-llm-vertex-claude))
  (pichat-llm-vertex-claude--url provider "streamRawPredict"))

(defun pichat-llm-vertex-claude--content (interaction)
  "Convert one llm prompt INTERACTION to Anthropic content blocks."
  (let ((content (llm-chat-prompt-interaction-content interaction))
        (multi-turn
         (llm-chat-prompt-interaction-multi-turn-plist interaction)))
    (vconcat
     (let ((thinking (plist-get multi-turn :claude-thinking))
           (signature
            (plist-get multi-turn :claude-reasoning-signature)))
       (when (and thinking signature)
         (list (list :type "thinking" :thinking thinking
                     :signature signature))))
     (let ((redacted (plist-get multi-turn :claude-redacted-thinking)))
       (when redacted
         (list (list :type "redacted_thinking" :data redacted))))
     (cond
      ((llm-chat-prompt-interaction-tool-results interaction)
       (mapcar
        (lambda (result)
          (list :type "tool_result"
                :tool_use_id (llm-chat-prompt-tool-result-call-id result)
                :content
                (format "%s" (llm-chat-prompt-tool-result-result result))))
        (llm-chat-prompt-interaction-tool-results interaction)))
      ((and (consp content)
            (llm-provider-utils-tool-use-p (car content)))
       (mapcar
        (lambda (use)
          (list :type "tool_use"
                :id (llm-provider-utils-tool-use-id use)
                :name (llm-provider-utils-tool-use-name use)
                :input (llm-provider-utils-tool-use-args use)))
        content))
      ((stringp content)
       (list (list :type "text" :text content)))
      (t nil)))))

(cl-defmethod llm-provider-chat-request
  ((_provider pichat-llm-vertex-claude) prompt streaming)
  (let* ((interactions
          (seq-remove
           (lambda (interaction)
             (eq (llm-chat-prompt-interaction-role interaction) 'system))
           (llm-chat-prompt-interactions prompt)))
         (request
          (list
           :anthropic_version "vertex-2023-10-16"
           :stream (if streaming t :false)
           :max_tokens (or (llm-chat-prompt-max-tokens prompt) 4096)
           :messages
           (vconcat
            (mapcar
             (lambda (interaction)
               (list
                :role
                (if (eq (llm-chat-prompt-interaction-role interaction)
                        'assistant)
                    "assistant"
                  "user")
                :content
                (pichat-llm-vertex-claude--content interaction)))
             interactions))))
         (system (llm-provider-utils-get-system-prompt prompt)))
    (unless (string-empty-p system)
      (setq request (plist-put request :system (string-trim-right system))))
    (when (llm-chat-prompt-temperature prompt)
      (setq request
            (plist-put request :temperature
                       (llm-chat-prompt-temperature prompt))))
    (when (llm-chat-prompt-tools prompt)
      (setq request
            (plist-put
             request :tools
             (vconcat
              (mapcar
               (lambda (tool)
                 (list
                  :name (llm-tool-name tool)
                  :description (llm-tool-description tool)
                  :input_schema
                  (llm-provider-utils-openai-arguments
                   (llm-tool-args tool))))
               (llm-chat-prompt-tools prompt))))))
    (append request (llm-provider-utils-non-standard-params-plist prompt))))

(cl-defmethod llm-provider-chat-extract-result
  ((_provider pichat-llm-vertex-claude) response)
  (cl-loop for block across (alist-get 'content response)
           when (equal (alist-get 'type block) "text")
           concat (alist-get 'text block)))

(cl-defmethod llm-provider-extract-reasoning
  ((_provider pichat-llm-vertex-claude) response)
  (cl-loop for block across (alist-get 'content response)
           when (equal (alist-get 'type block) "thinking")
           concat (alist-get 'thinking block)))

(cl-defmethod llm-provider-extract-tool-uses
  ((_provider pichat-llm-vertex-claude) response)
  (cl-loop
   for block across (alist-get 'content response)
   when (equal (alist-get 'type block) "tool_use")
   collect
   (make-llm-provider-utils-tool-use
    :id (alist-get 'id block)
    :name (alist-get 'name block)
    :args (alist-get 'input block))))

(cl-defmethod llm-provider-extract-token-use
  ((_provider pichat-llm-vertex-claude) response)
  (let ((usage (alist-get 'usage response)))
    (when usage
      (list :input-tokens (alist-get 'input_tokens usage)
            :output-tokens (alist-get 'output_tokens usage)))))

(cl-defmethod llm-provider-extract-for-multi-turn
  ((provider pichat-llm-vertex-claude) response)
  (let (state)
    (cl-loop
     for block across (alist-get 'content response)
     when (equal (alist-get 'type block) "thinking")
     do (setq state
              (append state
                      (list
                       :claude-thinking (alist-get 'thinking block)
                       :claude-reasoning-signature
                       (alist-get 'signature block))))
     when (equal (alist-get 'type block) "redacted_thinking")
     do (setq state
              (append state
                      (list :claude-redacted-thinking
                            (alist-get 'data block)))))
    ;; The public populate generic does not receive multi-turn metadata.  This
    ;; provider-local bridge is safe because PiChat gives each conversation an
    ;; independent provider and permits only one in-flight request.
    (setf (pichat-llm-vertex-claude-pending-multi-turn provider) state)
    state))

(cl-defmethod llm-provider-chat-extract-error
  ((_provider pichat-llm-vertex-claude) response)
  (let ((error-value (alist-get 'error response)))
    (when error-value
      (format "%s: %s"
              (or (alist-get 'type error-value) "Vertex Claude error")
              (or (alist-get 'message error-value) "request failed")))))

(cl-defmethod llm-provider-populate-tool-uses
  ((provider pichat-llm-vertex-claude) prompt uses)
  (llm-provider-utils-append-to-prompt
   prompt uses nil
   (pichat-llm-vertex-claude-pending-multi-turn provider)
   'assistant)
  (setf (pichat-llm-vertex-claude-pending-multi-turn provider) nil))

(cl-defmethod llm-provider-append-to-prompt
  ((_provider pichat-llm-vertex-claude) prompt result
   &optional tool-results multi-turn)
  (llm-provider-utils-append-to-prompt
   prompt result tool-results multi-turn
   (if tool-results 'user 'assistant)))

(cl-defmethod llm-provider-streaming-media-handler
  ((_provider pichat-llm-vertex-claude) receiver error-receiver)
  (cons
   'text/event-stream
   (plz-event-source:text/event-stream
    :events
    `((error
       . ,(lambda (event)
            (funcall error-receiver
                     (plz-event-source-event-data event))))
      (content_block_delta
       . ,(lambda (event)
            (let* ((object
                    (json-parse-string
                     (plz-event-source-event-data event)
                     :object-type 'alist))
                   (delta (alist-get 'delta object)))
              (pcase (alist-get 'type delta)
                ("text_delta"
                 (funcall receiver (list :text (alist-get 'text delta))))
                ("thinking_delta"
                 (funcall receiver
                          (list :reasoning
                                (alist-get 'thinking delta))))))))
      (message_delta
       . ,(lambda (event)
            (let* ((object
                    (json-parse-string
                     (plz-event-source-event-data event)
                     :object-type 'alist))
                   (usage (alist-get 'usage object)))
              (when usage
                (funcall receiver
                         (list :output-tokens
                               (alist-get 'output_tokens usage)))))))))))

(cl-defmethod llm-capabilities ((_provider pichat-llm-vertex-claude))
  ;; PiChat Phase 2 intentionally exposes only tested text/reasoning transport.
  ;; Tool and media capabilities remain gated until their later phases.
  '(streaming reasoning))

(cl-defmethod llm-name ((_provider pichat-llm-vertex-claude))
  "Vertex Claude")

(provide 'pichat-llm-vertex-claude)
;;; pichat-llm-vertex-claude.el ends here
