;;; pichat-path.el --- Host/runtime path mapping for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers for local, Docker, SSH, or other runtimes where Emacs-visible paths
;; differ from Pi-visible paths.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-view)
(require 'pichat-transport)

(declare-function pichat-session-current "pichat-session" (&optional session))

(defgroup pichat nil
  "Emacs frontend for the Pi coding agent."
  :group 'applications)

(defcustom pichat-path-mappings nil
  "Host-to-runtime path mappings.
Each element is (HOST-PREFIX . RUNTIME-PREFIX).  The longest matching host
prefix is used by `pichat-path-to-runtime'; the longest matching runtime prefix
is used by `pichat-path-from-runtime'."
  :type '(repeat (cons (directory :tag "Host prefix")
                       (directory :tag "Runtime prefix")))
  :group 'pichat)

(defun pichat--normalize-prefix (path)
  "Normalize PATH for prefix comparison without requiring it to exist."
  (when path
    (directory-file-name (expand-file-name path))))

(defun pichat--mapping-match (path mappings from-fn)
  "Return best mapping for PATH from MAPPINGS.
FROM-FN extracts the source prefix from a mapping."
  (let ((best nil)
        (best-len -1)
        (expanded (and path (expand-file-name path))))
    (dolist (mapping mappings best)
      (let* ((prefix (funcall from-fn mapping))
             (norm (pichat--normalize-prefix prefix)))
        (when (and norm expanded
                   (or (string= expanded norm)
                       (string-prefix-p (file-name-as-directory norm) expanded))
                   (> (length norm) best-len))
          (setq best mapping
                best-len (length norm)))))))

(defun pichat--replace-prefix (path old-prefix new-prefix)
  "Replace OLD-PREFIX in PATH with NEW-PREFIX."
  (let* ((expanded (expand-file-name path))
         (old (pichat--normalize-prefix old-prefix))
         (new (directory-file-name new-prefix))
         (suffix (substring expanded (length old))))
    (concat new suffix)))

(defun pichat-path--context-mappings (context)
  "Return mappings captured by CONTEXT or the compatibility global."
  (if (pichat-path-context-p context)
      (pichat-path-context-mappings context)
    pichat-path-mappings))

(defun pichat-path--strict-p (context)
  "Return non-nil when CONTEXT requires mapped paths."
  (if (pichat-path-context-p context)
      (pichat-path-context-strict-p context)
    (not (null pichat-path-mappings))))

(defun pichat--runtime-mapping-match (path &optional mappings explicit-p)
  "Return the longest runtime-prefix mapping in MAPPINGS that covers PATH.
When EXPLICIT-P is nil, a nil MAPPINGS value uses the compatibility global."
  (let ((best nil)
        (best-len -1)
        (mappings (if explicit-p mappings
                    (or mappings pichat-path-mappings))))
    (dolist (mapping mappings best)
      (let ((runtime (directory-file-name (cdr mapping))))
        (when (and path
                   (or (string= path runtime)
                       (string-prefix-p (file-name-as-directory runtime) path))
                   (> (length runtime) best-len))
          (setq best mapping
                best-len (length runtime)))))))

;;;###autoload
(defun pichat-path-to-runtime (path &optional context)
  "Translate Emacs PATH to a Pi runtime path using optional CONTEXT."
  (let ((mappings (pichat-path--context-mappings context)))
    (if-let ((mapping (pichat--mapping-match path mappings #'car)))
        (pichat--replace-prefix path (car mapping) (cdr mapping))
      path)))

;;;###autoload
(defun pichat-path-from-runtime (path &optional context)
  "Translate Pi runtime PATH to an Emacs path using optional CONTEXT."
  (let ((mappings (pichat-path--context-mappings context)))
    (if-let ((mapping (pichat--runtime-mapping-match path mappings t)))
        (concat (directory-file-name (car mapping))
                (substring path (length (directory-file-name (cdr mapping)))))
      path)))

(defun pichat-path-resolve-to-runtime (path &optional context)
  "Resolve Emacs PATH strictly for Pi using optional path CONTEXT."
  (let ((mappings (pichat-path--context-mappings context)))
    (cond
     ((not (and (stringp path) (not (string-empty-p path))))
      (list :status 'unavailable :path nil :reason "no Emacs path supplied"))
     ((and (null mappings) (not (pichat-path--strict-p context)))
      (list :status 'same-runtime :path path :reason nil))
     ((pichat--mapping-match path mappings #'car)
      (list :status 'mapped :path (pichat-path-to-runtime path context) :reason nil))
     (t
      (list :status 'unavailable :path nil
            :reason "Emacs path is not covered by the runtime mappings")))))

(defun pichat-path-resolve-from-runtime (path &optional context)
  "Resolve runtime PATH strictly for Emacs using optional path CONTEXT."
  (let ((mappings (pichat-path--context-mappings context)))
    (cond
     ((not (and (stringp path) (not (string-empty-p path))))
      (list :status 'unavailable :path nil :reason "no runtime path supplied"))
     ((and (null mappings) (not (pichat-path--strict-p context)))
      (list :status 'same-runtime :path path :reason nil))
     ((pichat--runtime-mapping-match path mappings t)
      (list :status 'mapped :path (pichat-path-from-runtime path context) :reason nil))
     (t
      (list :status 'unavailable :path nil
            :reason "runtime path is not covered by the Emacs mappings")))))

(defun pichat-path--validation-context (subject)
  "Return path context represented by SUBJECT."
  (cond
   ((pichat-path-context-p subject) subject)
   ((and subject (fboundp 'pichat-session-path-context))
    (pichat-session-path-context subject))
   ((and subject (pichat-transport-p subject))
    (pichat-transport-path-context subject pichat-path-mappings))
   (t nil)))

;;;###autoload
(defun pichat-path-validate-mappings (&optional subject)
  "Show a mapping report for session, transport, context, or global SUBJECT."
  (interactive
   (list (and (fboundp 'pichat-session-current)
              (pichat-session-current))))
  (let* ((context (pichat-path--validation-context subject))
         (mappings (pichat-path--context-mappings context)))
    (with-current-buffer (get-buffer-create "*PiChat Path Mappings*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "PiChat path mappings\n\n")
        (when (pichat-path-context-p context)
          (insert (format "Transport: %s\nStrict: %s\n\n"
                          (pichat-path-context-transport-id context)
                          (if (pichat-path-context-strict-p context) "yes" "no"))))
        (if mappings
            (dolist (mapping mappings)
              (let* ((emacs-path (car mapping))
                     (runtime (cdr mapping))
                     (sample (expand-file-name "sample" emacs-path))
                     (runtime-sample (pichat-path-to-runtime sample context)))
                (insert (format "Emacs:   %s %s %s\nRuntime: %s\nSample:  %s -> %s -> %s\n\n"
                                emacs-path
                                (if (file-directory-p emacs-path) "[exists]" "[missing]")
                                (if (file-remote-p emacs-path) "[TRAMP]" "[local]")
                                runtime sample runtime-sample
                                (pichat-path-from-runtime runtime-sample context)))))
          (insert "No mappings configured; local paths are used unchanged.\n"))
        (pichat-view-mode))
      (pop-to-buffer (current-buffer)))))

(provide 'pichat-path)
;;; pichat-path.el ends here
