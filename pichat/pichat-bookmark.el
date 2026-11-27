;;; pichat-bookmark.el --- Durable PiChat bookmarks -*- lexical-binding: t; -*-

;;; Commentary:

;; Chat and Session History validate their displayed source before passing it
;; here.  Records describe saved Pi sessions, not the runtimes hosting them.

;;; Code:

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

;;;###autoload
(defun pichat-bookmark-jump (_bookmark)
  "Handle an Emacs PiChat BOOKMARK.
Resolution and navigation are implemented separately from capture."
  (user-error "PiChat bookmark navigation is not implemented yet"))

(provide 'pichat-bookmark)
;;; pichat-bookmark.el ends here
