;;; pichat-bookmark.el --- Durable PiChat bookmarks -*- lexical-binding: t; -*-

;;; Commentary:

;; Chat and Session History validate their displayed source before passing it
;; here.  Records describe saved Pi sessions, not the runtimes hosting them.

;;; Code:

(require 'bookmark)
(require 'json)
(require 'subr-x)
(require 'pichat-session)
(require 'pichat-path)

(defconst pichat-bookmark--version 1)
(defconst pichat-bookmark--header-limit (* 64 1024)
  "Maximum bytes to read when checking a saved Pi session header.")

(defun pichat-bookmark--native-path-p (path)
  "Return non-nil if PATH is an absolute runtime-native file name."
  (and (stringp path) (string-prefix-p "/" path)
       (not (file-remote-p path))))

(defun pichat-bookmark--saved-header (file)
  "Read only the first JSONL record of the saved session FILE."
  (condition-case nil
      (progn
        (unless (file-regular-p file)
          (user-error "PiChat bookmark requires an existing saved session file; try after Pi saves it"))
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8-unix))
            (insert-file-contents file nil 0 pichat-bookmark--header-limit))
          (goto-char (point-min))
          (unless (search-forward "\n" nil t)
            (user-error "PiChat saved session has no complete header"))
          (let ((header (json-parse-string
                         (buffer-substring-no-properties (point-min) (1- (point)))
                         :object-type 'plist)))
            (unless (and (listp header) (equal (plist-get header :type) "session"))
              (user-error "PiChat saved session has no session header"))
            header)))
    (file-error (user-error "Cannot read the PiChat saved session file; check the target and access"))
    (json-parse-error (user-error "PiChat saved session header is not valid JSON"))))

(defun pichat-bookmark-make-record (session &optional entry-id)
  "Make an ordinary Emacs bookmark for SESSION's saved source and ENTRY-ID.
ENTRY-ID must come from a synchronized history row, not chat point."
  (unless (eq (pichat-session-backend-id session) 'pi)
    (user-error "This PiChat backend does not support saved-session bookmarks"))
  (when (eq (pichat-session-persistence session) 'ephemeral)
    (user-error "Cannot bookmark an ephemeral PiChat session; use a persistent runtime"))
  (let ((id (pichat-session-id session))
        (runtime-file (pichat-session-session-file session))
        (transport (pichat-session-transport session))
        (context (pichat-session-path-context session))
        (owner (pichat-session-owner-directory session)))
    (unless (and (stringp id) (not (string-blank-p id))
                 (pichat-bookmark--native-path-p runtime-file))
      (user-error "PiChat has no saved session file yet; try after Pi saves it"))
    (unless (and (pichat-transport-p transport)
                 (memq (pichat-transport-kind transport) '(local ssh)))
      (user-error "This PiChat target does not support saved-session bookmarks"))
    (let* ((kind (pichat-transport-kind transport))
           (target (pichat-transport-id transport))
           (prefix (when-let* ((raw (pichat-transport-tramp-prefix transport)))
                     (file-remote-p raw))))
      (unless (and (or (and target (symbolp target)) (stringp target))
                   (or (eq kind 'local) prefix))
        (user-error "PiChat bookmark cannot identify the saved session target"))
      (let* ((file (if (eq kind 'ssh)
                       ;; Validate the authoritative remote file, not a mirror.
                       (pichat-transport-runtime-file-name transport runtime-file)
                     (or (plist-get (pichat-path-resolve-from-runtime runtime-file context)
                                    :path)
                         runtime-file)))
             (header (pichat-bookmark--saved-header file))
             (cwd (plist-get header :cwd)))
        (unless (equal id (plist-get header :id))
          (user-error "PiChat saved session file does not match the displayed Pi session ID"))
        (unless (pichat-bookmark--native-path-p cwd)
          (user-error "PiChat saved session has no absolute project directory"))
        (let* ((project (file-name-nondirectory (directory-file-name cwd)))
               (name (format "PiChat %s [%s]%s"
                             (if (string-empty-p project) "/" project)
                             (substring id 0 (min 8 (length id)))
                             (if entry-id (format " / %s" entry-id) "")))
               (host-cwd
                (or (plist-get (pichat-path-resolve-from-runtime cwd context) :path)
                    (pichat-transport-runtime-file-name transport cwd))))
          (cons (substring-no-properties name)
                (mapcar (lambda (field)
                          ;; Detach strings and never persist buffer text properties.
                          (if (stringp (cdr field))
                              (cons (car field) (substring-no-properties (cdr field)))
                            field))
                        `((handler . pichat-bookmark-jump)
                          (filename . ,file)
                          (pichat-version . ,pichat-bookmark--version)
                          (pichat-session-id . ,id)
                          (pichat-runtime-file . ,runtime-file)
                          (pichat-target-id . ,target)
                          (pichat-target-kind . ,kind)
                          (pichat-runtime-cwd . ,cwd)
                          (pichat-host-cwd . ,host-cwd)
                          ,@(when (eq kind 'ssh) `((pichat-tramp-prefix . ,prefix)))
                          ,@(when (stringp owner) `((pichat-owner-directory . ,owner)))
                          ,@(when entry-id `((pichat-entry-id . ,entry-id)))))))))))

(declare-function pichat--selected-file-key "pichat" (transport runtime-file &optional context))
(declare-function pichat--claim-selected-file "pichat" (key))
(declare-function pichat--release-selected-file "pichat" (key token))
(declare-function pichat-session-list "pichat" ())
(declare-function pichat-reconfigure-source-claim "pichat-reconfigure" (session))
(declare-function pichat-process-lifetime-confirmed-p "pichat-process-lifetime" (process))
(declare-function pichat-sessions-open-file-independently "pichat-sessions" (file &rest options))
(declare-function pichat-sessions-list "pichat-sessions" (&optional session entry-id completion accept-p))
(declare-function pichat-chat-ensure "pichat-chat" (session &optional synchronize))
(defvar pichat-sessions-selection-timeout)
(defvar pichat-rpc-request-timeout)

(defun pichat-bookmark--resolve (bookmark)
  "Resolve BOOKMARK's saved identity and project against current target settings."
  (let* ((get (lambda (key) (bookmark-prop-get bookmark key)))
         (id (funcall get 'pichat-session-id))
         (entry (funcall get 'pichat-entry-id))
         (target (funcall get 'pichat-target-id))
         (kind (funcall get 'pichat-target-kind))
         (prefix (funcall get 'pichat-tramp-prefix))
         (runtime-file (funcall get 'pichat-runtime-file))
         (cwd (funcall get 'pichat-runtime-cwd)))
    (unless (eql (funcall get 'pichat-version) pichat-bookmark--version)
      (user-error "Unsupported PiChat bookmark version; recreate the bookmark"))
    (unless (and (stringp id) (not (string-blank-p id))
                 (or (null entry) (and (stringp entry) (not (string-blank-p entry))))
                 (pichat-bookmark--native-path-p runtime-file)
                 (pichat-bookmark--native-path-p cwd)
                 target (or (symbolp target) (stringp target))
                 (pcase kind
                   ('local (null prefix))
                   ('ssh (and (stringp prefix) (equal prefix (file-remote-p prefix))))))
      (user-error "Invalid PiChat bookmark identity or target provenance; recreate the bookmark"))
    (let* ((transport (pichat-transport-resolve
                       (if prefix (concat prefix "/") "/")
                       (unless (and prefix (equal target (concat "tramp:" prefix)))
                         target)))
           (context (pichat-transport-path-context transport pichat-path-mappings))
           (mapped-file (plist-get (pichat-path-resolve-from-runtime runtime-file context) :path))
           (file (if prefix (pichat-transport-runtime-file-name transport runtime-file)
                   mapped-file))
           (host-cwd (plist-get (pichat-path-resolve-from-runtime cwd context) :path)))
      (unless (and (eq kind (pichat-transport-kind transport))
                   (equal target (pichat-transport-id transport))
                   (equal prefix (pichat-transport-tramp-prefix transport))
                   file (equal file (bookmark-get-filename bookmark))
                   (or prefix (and (not (file-remote-p file))
                                   (equal runtime-file (plist-get (pichat-path-resolve-to-runtime
                                                                   file context) :path))))
                   host-cwd (equal host-cwd (funcall get 'pichat-host-cwd))
                   (or (not (file-remote-p host-cwd))
                       (equal prefix (file-remote-p host-cwd)))
                   (equal (directory-file-name cwd)
                          (when-let* ((path (plist-get (pichat-path-resolve-to-runtime
                                                        host-cwd context) :path)))
                            (directory-file-name path))))
        (user-error "PiChat bookmark target or path mapping changed; restore it or recreate the bookmark"))
      (when (pichat-transport-busy-p transport)
        (user-error "PiChat bookmark target is busy; retry the jump"))
      (let ((header (pichat-bookmark--saved-header file)))
        (unless (equal id (plist-get header :id))
          (user-error "PiChat saved session ID does not match the bookmark"))
        (unless (equal cwd (plist-get header :cwd))
          (user-error "PiChat saved project directory does not match the bookmark")))
      (list transport context file runtime-file id cwd host-cwd entry))))

(defun pichat-bookmark--live-host (transport key runtime-file id)
  "Return the exact compatible live host for KEY or reject a competing writer.
TRANSPORT, RUNTIME-FILE and ID describe the bookmarked source."
  (let (host)
    (dolist (session (pichat-session-list) host)
      (let* ((claim (pichat-reconfigure-source-claim session))
             (candidate (pichat-session-transport session))
             (candidate-file (pichat-session-session-file session)))
        (when (equal key (plist-get claim :key))
          (user-error "PiChat restart holds the saved session writer claim; resolve it before jumping"))
        (when (and (pichat-session-alive-p session) candidate-file
                   (eq (pichat-transport-kind transport) (pichat-transport-kind candidate))
                   (equal (pichat-transport-tramp-prefix transport)
                          (pichat-transport-tramp-prefix candidate))
                   (equal key (pichat--selected-file-key
                               candidate candidate-file (pichat-session-path-context session))))
          (unless (and (not host)
                       (not (pichat-session-restart-operation session))
                       (eq (pichat-session-backend-id session) 'pi)
                       (equal (pichat-transport-id transport) (pichat-transport-id candidate))
                       (equal runtime-file candidate-file)
                       (equal id (pichat-session-id session)))
            (user-error "A conflicting PiChat runtime hosts this saved file; inspect the runtime manager"))
          (setq host session))))))

(defun pichat-bookmark--await (start seconds)
  "Run START with a completion callback and an ownership predicate.
Wait at most SECONDS for RPC delivery, returning the callback result or
signalling a user error.  The predicate expires on timeout, quit or return."
  (let ((waiting t) done result reason)
    (unwind-protect
        (with-timeout (seconds (user-error "PiChat bookmark timed out; check the runtime before retrying"))
          (funcall start
                   (lambda (value error)
                     (when (and waiting (not done))
                       (setq result value reason error done t)))
                   (lambda () (and waiting (not done))))
          (while (not done) (accept-process-output nil 0.05))
          (when reason (user-error "%s" reason))
          result)
      (setq waiting nil))))

(defun pichat-bookmark--open (transport context file runtime-file id cwd host-cwd)
  "Reuse or independently open the exact bookmarked Pi session."
  (let* ((key (pichat--selected-file-key transport runtime-file context))
         (token (pichat--claim-selected-file key))
         handed-off)
    (unwind-protect
        (or (pichat-bookmark--live-host transport key runtime-file id)
            (progn
              (unless (file-directory-p host-cwd)
                (user-error "PiChat bookmark project directory is unavailable"))
              (pichat-bookmark--await
               (lambda (complete _active-p)
                 (pichat-sessions-open-file-independently
                  file :cwd cwd :owner-directory host-cwd
                  :launch-options (list :transport transport :persistence 'persistent :background t)
                  :readiness 'transcript-ready :expected-session-id id :display-function nil
                  :ready (lambda (session)
                           (pichat--release-selected-file key token)
                           (funcall complete session nil))
                  :error-callback
                  (lambda (response session)
                    (let* ((process (and session (pichat-session-process session)))
                           (uncertain (and process (eq (pichat-transport-kind transport) 'ssh)
                                           (not (pichat-process-lifetime-confirmed-p process)))))
                      (unless uncertain (pichat--release-selected-file key token))
                      (funcall complete nil
                               (if uncertain
                                   "PiChat SSH writer exit is unverified; confirm it before reopening from a fresh Emacs"
                                 (or (plist-get response :error) "Could not open the saved Pi session"))))))
                 ;; Keep the claim through outstanding RPCs even if the user quits waiting.
                 (setq handed-off t))
               (* 4 pichat-sessions-selection-timeout))))
      (unless handed-off (pichat--release-selected-file key token)))))

(defun pichat-bookmark--destination (session transport runtime-file id entry)
  "Return the exact SESSION chat or visible Session History row for ENTRY."
  (let ((epoch (pichat-session-diagnostic-source-generation session))
        (process (pichat-session-process session)))
    (cl-labels ((current-p ()
                  (and (pichat-session-alive-p session)
                       (eq process (pichat-session-process session))
                       (= epoch (pichat-session-diagnostic-source-generation session))
                       (equal (pichat-transport-id transport)
                              (pichat-transport-id (pichat-session-transport session)))
                       (equal runtime-file (pichat-session-session-file session))
                       (equal id (pichat-session-id session)))))
      (unless (current-p) (user-error "PiChat bookmark source changed before navigation"))
      (let ((buffer
             (if entry
                 (let ((pichat-rpc-request-timeout pichat-sessions-selection-timeout))
                   (pichat-bookmark--await
                    (lambda (complete active-p)
                      (pichat-sessions-list session entry complete
                                            (lambda () (and (funcall active-p) (current-p)))))
                    pichat-sessions-selection-timeout))
               ;; Create the view if needed, without loading the saved file again.
               (pichat-chat-ensure session (not (buffer-live-p (pichat-session-buffer session)))))))
        (unless (and (buffer-live-p buffer) (current-p))
          (user-error "PiChat bookmark source changed before navigation"))
        buffer))))

;;;###autoload
(defun pichat-bookmark-jump (bookmark)
  "Visit the saved Pi session or Session History entry recorded by BOOKMARK.
Leave the destination current for Emacs's normal bookmark display function."
  (require 'pichat)
  (condition-case condition
      (pcase-let* ((`(,transport ,context ,file ,runtime-file ,id ,cwd ,host-cwd ,entry)
                    (pichat-bookmark--resolve bookmark))
                   (session (pichat-bookmark--open transport context file runtime-file id cwd host-cwd)))
        (set-buffer (pichat-bookmark--destination session transport runtime-file id entry)))
    (error (user-error "PiChat bookmark: %s"
                       (truncate-string-to-width
                        (replace-regexp-in-string "[[:space:]]+" " " (error-message-string condition))
                        200 nil nil t)))))

(provide 'pichat-bookmark)
;;; pichat-bookmark.el ends here
