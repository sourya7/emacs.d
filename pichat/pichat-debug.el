;;; pichat-debug.el --- Bounded runtime snapshots for inspection -*- lexical-binding: t; -*-

;;; Commentary:

;; Compact, read-only views of retained PiChat runtimes for `emacsclient'
;; callers (such as agents) and `M-:'.  Nothing here sends RPC, launches
;; processes, reads files or changes runtime state.  Results are plain Lisp
;; data with bounded strings; event and buffer text can still contain prompts,
;; paths and credentials.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-chat-diagnostics)

(declare-function pichat-session-list "pichat")
(declare-function pichat-session-by-runtime-id "pichat")
(declare-function pichat-session-default-p "pichat")
(declare-function pichat-chat-owned-buffer "pichat-chat")
(declare-function pichat-chat-pending-user-input-count "pichat-chat")
(defvar pichat-chat-session)
(defvar pichat-chat--queue-counts)

(defconst pichat-debug-event-keys
  '(:type :command :id :success :error :method :name :reason :toolName :isError)
  "Event keys kept by `pichat-debug-events' summaries.")

(defconst pichat-debug-string-limit 300
  "Maximum characters kept from one string in an event summary.")

(defconst pichat-debug-noise-events
  '(("message_update")
    ("tool_execution_update")
    ("extension_ui_request" "setStatus" "setWidget" "setTitle"))
  "Events `pichat-debug-events' skips by default, as (TYPE . METHODS) entries.
These are streaming updates and display-only extension requests.  An entry
without METHODS matches every event of TYPE.")

(defun pichat-debug--noise-p (event)
  "Return non-nil when EVENT matches `pichat-debug-noise-events'."
  (when-let* ((entry (assoc (plist-get event :type) pichat-debug-noise-events)))
    (or (null (cdr entry))
        (member (plist-get event :method) (cdr entry)))))

(defun pichat-debug--clip (value)
  "Return VALUE, shortening a long string."
  (if (and (stringp value) (> (length value) pichat-debug-string-limit))
      (concat (substring-no-properties value 0 pichat-debug-string-limit) "…")
    value))

(defun pichat-debug--buffer-session (buffer)
  "Return the runtime session of chat BUFFER, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (bound-and-true-p pichat-chat-session))))

(defun pichat-debug--session (runtime)
  "Return the retained runtime session identified by RUNTIME.
RUNTIME is a session, runtime ID, chat buffer or chat buffer name."
  (or (cond
       ((pichat-session-p runtime) runtime)
       ((bufferp runtime) (pichat-debug--buffer-session runtime))
       ((stringp runtime)
        (or (pichat-session-by-runtime-id runtime)
            (pichat-debug--buffer-session (get-buffer runtime)))))
      (user-error "No retained PiChat runtime or chat buffer: %S" runtime)))

(defun pichat-debug--chat-buffer (session)
  "Return SESSION's live chat buffer or signal a `user-error'."
  (or (pichat-chat-owned-buffer session)
      (user-error "Runtime %s has no chat buffer"
                  (pichat-session-runtime-id session))))

(defun pichat-debug-runtime (runtime)
  "Return a compact status plist for RUNTIME.
RUNTIME is a session, runtime ID, chat buffer or chat buffer name.  `:queued'
is the chat's (STEERING . FOLLOW-UP) count; `:pending-responses' counts RPC
requests awaiting a reply; `:waiting-for-input' counts extension UI requests
awaiting the user."
  (let* ((session (pichat-debug--session runtime))
         (buffer (pichat-chat-owned-buffer session))
         (pending (pichat-session-pending-responses session)))
    (list :runtime (pichat-session-runtime-id session)
          :buffer (and buffer (buffer-name buffer))
          :name (pichat-session-name session)
          :state (pichat-session-state session)
          :alive (and (pichat-session-alive-p session) t)
          :preferred (and (pichat-session-default-p session) t)
          :streaming (pichat-session-streaming-p session)
          :compacting (pichat-session-compacting-p session)
          :retrying (pichat-session-retrying-p session)
          :waiting-for-input (pichat-chat-pending-user-input-count session)
          :pending-responses (if (hash-table-p pending)
                                 (hash-table-count pending)
                               0)
          :queued (and buffer
                       (buffer-local-value 'pichat-chat--queue-counts buffer))
          :preset (pichat-session-preset-name session)
          :model (pichat-session-model-label session)
          :persistence (pichat-session-persistence session)
          :session-id (pichat-session-id session)
          :session-file (pichat-session-session-file session)
          :cwd (pichat-session-runtime-cwd session))))

;;;###autoload
(defun pichat-debug-runtimes ()
  "Return a compact status plist for every retained runtime.
See `pichat-debug-runtime' for the fields."
  (mapcar #'pichat-debug-runtime (pichat-session-list)))

(defun pichat-debug--event-summary (event)
  "Return EVENT's `pichat-debug-event-keys' fields and its other key names.
Retained events can end in an omission marker instead of a full plist; the
summary then ends with `:truncated t'."
  (let ((tail event) fields other)
    (while (and (consp tail) (consp (cdr tail)))
      (if (memq (car tail) pichat-debug-event-keys)
          (push (cons (car tail) (pichat-debug--clip (cadr tail))) fields)
        (push (car tail) other))
      (setq tail (cddr tail)))
    (append
     (mapcan (lambda (key)
               (when-let* ((field (assq key fields)))
                 (list key (cdr field))))
             pichat-debug-event-keys)
     (when other (list :other-keys (nreverse other)))
     (when tail (list :truncated t)))))

;;;###autoload
(defun pichat-debug-events (runtime &optional count full types)
  "Return RUNTIME's COUNT most recent retained RPC events, oldest first.
COUNT defaults to 10.  Each event is summarized to `pichat-debug-event-keys'
plus the names of its other keys; with FULL, return the retained raw events.
TYPES selects events: nil skips `pichat-debug-noise-events', t keeps all,
and a list of type strings keeps only those.  The log is a bounded subset,
not a complete trace."
  (let* ((session (pichat-debug--session runtime))
         (keep (cond ((eq types t) #'always)
                     (types (lambda (event)
                              (member (plist-get event :type) types)))
                     (t (lambda (event)
                          (not (pichat-debug--noise-p event))))))
         (events (seq-take (seq-filter keep (pichat-session-event-log session))
                           (or count 10))))
    (mapcar (if full #'identity #'pichat-debug--event-summary)
            (reverse events))))

;;;###autoload
(defun pichat-debug-tail (runtime &optional chars)
  "Return the last CHARS (default 2000) characters of RUNTIME's chat buffer.
Text properties are removed."
  (with-current-buffer (pichat-debug--chat-buffer (pichat-debug--session runtime))
    (save-restriction
      (widen)
      (buffer-substring-no-properties
       (max (point-min) (- (point-max) (or chars 2000))) (point-max)))))

;;;###autoload
(defun pichat-debug-stderr (runtime &optional chars)
  "Return the last CHARS (default 2000) characters of RUNTIME's Pi stderr.
Return nil when no stderr buffer is retained."
  (let ((buffer (pichat-session-stderr-buffer (pichat-debug--session runtime))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (buffer-substring-no-properties
         (max (point-min) (- (point-max) (or chars 2000))) (point-max))))))

;;;###autoload
(defun pichat-debug-diagnostics (runtime)
  "Return RUNTIME's cached diagnostics as (TITLE SUMMARY...) lists.
These are the redacted problem summaries `pichat-show-diagnostics' reports."
  (mapcar (lambda (section)
            (cons (car section)
                  (mapcar #'pichat-chat-diagnostics--safe-record-line
                          (cdr section))))
          (pichat-chat-diagnostics-sections (pichat-debug--session runtime))))

(provide 'pichat-debug)

;;; pichat-debug.el ends here
