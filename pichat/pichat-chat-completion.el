;;; pichat-chat-completion.el --- Slash completion for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Generation-scoped command discovery and completion-at-point support.  This
;; module owns no transcript state and does not require `pichat-chat'.  Chat
;; orchestration supplies source identity, generation, and prompt boundaries.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-rpc)

(defvar-local pichat-chat-completion--commands nil
  "Pi command records cached for the current chat source.")

(defvar-local pichat-chat-completion--status 'unavailable
  "Command cache status: `unavailable', `loading', `ready', or `failed'.")

(defvar-local pichat-chat-completion--last-error nil
  "Most recent command refresh error response, or nil.")

(defvar-local pichat-chat-completion--source-generation nil
  "Source generation associated with the command cache.")

(defvar-local pichat-chat-completion--source-key nil
  "Stable session-id or session-file key associated with the command cache.")

(defvar-local pichat-chat-completion--session nil
  "Pi session associated with the current command refresh.")

(defvar-local pichat-chat-completion--request-sequence 0
  "Monotonic sequence used to reject stale command refresh callbacks.")

(defvar-local pichat-chat-completion--request-id nil
  "Current command refresh RPC request id, or nil.")

(defun pichat-chat-completion-reset (source-generation source-key)
  "Clear command state and bind it to SOURCE-GENERATION and SOURCE-KEY."
  (cl-incf pichat-chat-completion--request-sequence)
  (setq pichat-chat-completion--commands nil
        pichat-chat-completion--status 'unavailable
        pichat-chat-completion--last-error nil
        pichat-chat-completion--source-generation source-generation
        pichat-chat-completion--source-key source-key
        pichat-chat-completion--session nil
        pichat-chat-completion--request-id nil))

(defun pichat-chat-completion--current-request-p
    (session source-generation source-key sequence)
  "Return non-nil when callback context still identifies the current request."
  (and (eq session pichat-chat-completion--session)
       (equal source-generation
              pichat-chat-completion--source-generation)
       (equal source-key pichat-chat-completion--source-key)
       (= sequence pichat-chat-completion--request-sequence)))

(defun pichat-chat-completion--response-commands (response)
  "Return valid command records from successful RESPONSE, preserving order."
  (let ((commands (plist-get (plist-get response :data) :commands)))
    (when (listp commands)
      (cl-remove-if-not
       (lambda (command)
         (and (listp command)
              (stringp (plist-get command :name))
              (not (string-empty-p (plist-get command :name)))))
       commands))))

(defun pichat-chat-completion--accept-success
    (buffer session source-generation source-key sequence response
            response-session)
  "Accept a command RESPONSE when its captured context is still current."
  (when (and (buffer-live-p buffer) (eq session response-session))
    (with-current-buffer buffer
      (when (pichat-chat-completion--current-request-p
             session source-generation source-key sequence)
        (setq pichat-chat-completion--commands
              (pichat-chat-completion--response-commands response)
              pichat-chat-completion--status 'ready
              pichat-chat-completion--last-error nil
              pichat-chat-completion--request-id nil)))))

(defun pichat-chat-completion--accept-failure
    (buffer session source-generation source-key sequence response
            response-session)
  "Record failed command RESPONSE when its captured context is still current."
  (when (and (buffer-live-p buffer) (eq session response-session))
    (with-current-buffer buffer
      (when (pichat-chat-completion--current-request-p
             session source-generation source-key sequence)
        (setq pichat-chat-completion--commands nil
              pichat-chat-completion--status 'failed
              pichat-chat-completion--last-error response
              pichat-chat-completion--request-id nil)))))

(defun pichat-chat-completion-refresh
    (session source-generation source-key &optional buffer)
  "Refresh commands for SESSION and captured source context.
SOURCE-GENERATION and SOURCE-KEY identify the chat source.  BUFFER defaults to
`current-buffer'.  Return the RPC request id, or nil when SESSION is
unavailable."
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (and (equal source-generation
                            pichat-chat-completion--source-generation)
                     (equal source-key pichat-chat-completion--source-key))
          (pichat-chat-completion-reset source-generation source-key))
        (cl-incf pichat-chat-completion--request-sequence)
        (setq pichat-chat-completion--session session
              pichat-chat-completion--request-id nil
              pichat-chat-completion--last-error nil)
        (if (not (pichat-session-alive-p session))
            (progn
              (setq pichat-chat-completion--commands nil
                    pichat-chat-completion--status 'unavailable)
              nil)
          (let ((sequence pichat-chat-completion--request-sequence))
            (setq pichat-chat-completion--status 'loading
                  pichat-chat-completion--request-id
                  (pichat-rpc-get-commands
                   session
                   (apply-partially
                    #'pichat-chat-completion--accept-success
                    buffer session source-generation source-key sequence)
                   (apply-partially
                    #'pichat-chat-completion--accept-failure
                    buffer session source-generation source-key sequence)))
            pichat-chat-completion--request-id))))))

(defun pichat-chat-completion-extension-command-p (text)
  "Return non-nil when TEXT invokes a cached Pi extension command."
  (when (and (eq pichat-chat-completion--status 'ready)
             (stringp text)
             (string-prefix-p "/" text))
    ;; Pi treats only a literal space as the command/argument separator.
    (let* ((space-index (string-match " " text))
           (name (substring text 1 space-index)))
      (cl-some
       (lambda (command)
         (and (equal name (plist-get command :name))
              (equal "extension" (plist-get command :source))))
       pichat-chat-completion--commands))))

(defun pichat-chat-completion--annotation (name)
  "Return source and description annotation for command NAME."
  (when-let ((command
              (cl-find name pichat-chat-completion--commands
                       :key (lambda (item) (plist-get item :name))
                       :test #'equal)))
    (let ((source (plist-get command :source))
          (description (plist-get command :description)))
      (concat (if (and (stringp source) (not (string-empty-p source)))
                  (format "  [%s]" source)
                "")
              (if (and (stringp description)
                       (not (string-empty-p description)))
                  (concat " " description)
                "")))))

(defun pichat-chat-completion--table (names)
  "Return completion table for NAMES preserving Pi's order."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata
          (category . pichat-slash-command)
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action names string predicate))))

(defun pichat-chat-completion-capf (input-start)
  "Return slash-command completion data relative to INPUT-START.
Completion is offered only for a slash token at the beginning of the editable
input and only while a successful command cache is available."
  (let ((start (and (markerp input-start) (marker-position input-start))))
    (when (and (eq pichat-chat-completion--status 'ready)
               (consp pichat-chat-completion--commands)
               start
               (<= start (point)))
      (let ((text (buffer-substring-no-properties start (point))))
        (when (string-match "\\`/\\([^[:space:]]*\\)\\'" text)
          (list (+ start (match-beginning 1))
                (point)
                (pichat-chat-completion--table
                 (mapcar (lambda (command) (plist-get command :name))
                         pichat-chat-completion--commands))
                :annotation-function #'pichat-chat-completion--annotation
                :exclusive 'no))))))

(provide 'pichat-chat-completion)
;;; pichat-chat-completion.el ends here
