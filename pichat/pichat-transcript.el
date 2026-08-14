;;; pichat-transcript.el --- PiChat transcript state -*- lexical-binding: t; -*-

;;; Commentary:

;; Pi-independent state containers for canonical and live transcripts.  The
;; first implementation slice defines the authoritative session-entry cache;
;; Pi schema interpretation lives in `pichat-pi'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (pichat-entry-cache
               (:constructor pichat-entry-cache-create)
               (:conc-name pichat-entry-cache-))
  "Cached authoritative session entries for one Pi session."
  session-id
  session-file
  entries-by-id
  append-order
  last-seen-id
  leaf-id)

(cl-defstruct (pichat-transcript
               (:constructor pichat-transcript-create)
               (:conc-name pichat-transcript-))
  "Pi-independent canonical transcript."
  nodes
  diagnostics
  metadata)

(cl-defstruct (pichat-transcript-node
               (:constructor pichat-transcript-node-create)
               (:conc-name pichat-transcript-node-))
  "One canonical top-level transcript node."
  kind
  key
  role
  content
  stop-reason
  error-message
  custom-type
  activity-type
  summary
  tokens-before)

(cl-defstruct (pichat-transcript-content
               (:constructor pichat-transcript-content-create)
               (:conc-name pichat-transcript-content-))
  "One ordered normalized content item."
  kind
  index
  text
  media-type
  tool-call-id
  name
  arguments
  status
  output
  is-error
  result-entry-id
  unknown-type)

(cl-defstruct (pichat-live-draft
               (:constructor pichat-live-draft-create)
               (:conc-name pichat-live-draft-))
  "Transient normalized transcript state for one source generation."
  generation
  sequence
  nodes
  current-node
  tools
  tool-argument-buffers
  diagnostics
  message-final-p
  settled-p
  event-changed-p)

(defun pichat-live-draft-empty (generation)
  "Return an empty live draft scoped to source GENERATION."
  (pichat-live-draft-create
   :generation generation
   :sequence 0
   :nodes nil
   :current-node nil
   :tools (make-hash-table :test #'equal)
   :tool-argument-buffers (make-hash-table :test #'eql)
   :diagnostics nil
   :message-final-p nil
   :settled-p nil
   :event-changed-p nil))

(defun pichat-live-draft-next-key (draft &optional prefix)
  "Return the next local identity in DRAFT using PREFIX."
  (let ((sequence (1+ (pichat-live-draft-sequence draft))))
    (setf (pichat-live-draft-sequence draft) sequence)
    (format "live-%s-%s%s"
            (pichat-live-draft-generation draft)
            (if prefix (concat prefix "-") "")
            sequence)))

(defun pichat-live-draft-as-transcript (draft)
  "Return DRAFT's nodes as a renderable transient transcript."
  (pichat-transcript-create
   :nodes (pichat-live-draft-nodes draft)
   :diagnostics (pichat-live-draft-diagnostics draft)
   :metadata nil))

(define-error 'pichat-transcript-invalid "Invalid PiChat transcript")

(defun pichat-transcript--invalid (format-string &rest args)
  "Signal `pichat-transcript-invalid' using FORMAT-STRING and ARGS."
  (signal 'pichat-transcript-invalid
          (list (apply #'format format-string args))))

(defun pichat-transcript-validate (transcript)
  "Validate TRANSCRIPT invariants and return TRANSCRIPT."
  (unless (pichat-transcript-p transcript)
    (pichat-transcript--invalid "Not a transcript"))
  (let ((keys (make-hash-table :test #'equal))
        (tool-ids (make-hash-table :test #'equal)))
    (dolist (node (pichat-transcript-nodes transcript))
      (unless (pichat-transcript-node-p node)
        (pichat-transcript--invalid "Invalid top-level node"))
      (let ((key (pichat-transcript-node-key node)))
        (unless (and (stringp key) (not (string-empty-p key)))
          (pichat-transcript--invalid "Node has no durable key"))
        (when (gethash key keys)
          (pichat-transcript--invalid "Duplicate node key: %s" key))
        (puthash key t keys))
      (unless (memq (pichat-transcript-node-kind node)
                    '(message activity tool))
        (pichat-transcript--invalid
         "Unknown node kind: %S" (pichat-transcript-node-kind node)))
      (let ((last-index -1))
        (dolist (content (pichat-transcript-node-content node))
          (unless (pichat-transcript-content-p content)
            (pichat-transcript--invalid "Invalid content in node: %s"
                                        (pichat-transcript-node-key node)))
          (let ((index (pichat-transcript-content-index content)))
            (unless (and (integerp index) (> index last-index))
              (pichat-transcript--invalid
               "Content indexes are not strictly ordered in node: %s"
               (pichat-transcript-node-key node)))
            (setq last-index index))
          (when (eq 'tool (pichat-transcript-content-kind content))
            (let ((tool-id (pichat-transcript-content-tool-call-id content)))
              (unless (and (stringp tool-id) (not (string-empty-p tool-id)))
                (pichat-transcript--invalid "Tool has no correlation id"))
              (unless (eq 'orphan (pichat-transcript-content-status content))
                (when (gethash tool-id tool-ids)
                  (pichat-transcript--invalid
                   "Duplicate declared tool id: %s" tool-id))
                (puthash tool-id t tool-ids))))))))
  transcript)

(defun pichat-entry-cache-empty (&optional session-id session-file)
  "Return an empty entry cache for SESSION-ID and SESSION-FILE."
  (pichat-entry-cache-create
   :session-id session-id
   :session-file session-file
   :entries-by-id (make-hash-table :test #'equal)
   :append-order nil
   :last-seen-id nil
   :leaf-id nil))

(provide 'pichat-transcript)
;;; pichat-transcript.el ends here
