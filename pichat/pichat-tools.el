;;; pichat-tools.el --- Emacs-defined tools for PiChat -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-approval)

(declare-function pichat-session-emacs-cwd "pichat-session" (session))

(cl-defstruct (pichat-tool (:constructor pichat-tool-create))
  name label description parameters function instructions mutating-p async-p
  native-only-p group approval-summary)

(defconst pichat-tools-default-group "Other"
  "Picker group for Emacs-defined tools registered without a group.")

(defconst pichat-tools-text-limit 300
  "Default maximum characters of one free-text field in a tool result.")

(defconst pichat-tools-approval-summary-limit 240
  "Maximum characters of a tool's approval summary.")

(defvar pichat-tools-calling-session nil
  "Runtime session whose Pi bridge called the running Emacs-defined tool.
Bound by `pichat-tools-call' (and while computing an approval summary); nil
outside bridge calls.  Tools read it to refuse acting on their own runtime.")

(defvar pichat-tools-registry (make-hash-table :test #'equal)
  "Registered Emacs tools keyed by tool name.")

(defun pichat-tools-register (tool)
  "Register synchronous Emacs TOOL after validating its contract."
  (unless (pichat-tool-p tool)
    (error "Invalid Emacs tool"))
  (when (pichat-tool-async-p tool)
    (error "Asynchronous Emacs-defined tools are unsupported: %s"
           (pichat-tool-name tool)))
  (unless (or (null (pichat-tool-instructions tool))
              (stringp (pichat-tool-instructions tool)))
    (error "Emacs tool instructions must be a string: %s"
           (pichat-tool-name tool)))
  (unless (or (null (pichat-tool-group tool))
              (and (stringp (pichat-tool-group tool))
                   (not (string-blank-p (pichat-tool-group tool)))))
    (error "Emacs tool group must be a nonblank string: %s"
           (pichat-tool-name tool)))
  (unless (or (null (pichat-tool-approval-summary tool))
              (functionp (pichat-tool-approval-summary tool)))
    (error "Emacs tool approval summary must be a function: %s"
           (pichat-tool-name tool)))
  (puthash (pichat-tool-name tool) tool pichat-tools-registry)
  tool)

(defmacro pichat-define-tool (name args &rest body)
  "Define a PiChat Emacs tool NAME.
ARGS is a plist accepting :label, :description, :parameters, :instructions,
:mutating, :async, :native-only, :group and :approval-summary.  :group names
the Tools picker group; it affects presentation and selection convenience,
never approval.  :approval-summary is evaluated to a function (for example
#\='my-summary) called with the call's params; it returns a short human
description shown in the approval prompt beside the raw arguments, or nil.
The body receives `params'; the calling runtime is
`pichat-tools-calling-session'."
  (declare (indent 2))
  (when (plist-get args :async)
    (error "Asynchronous Emacs-defined tools are unsupported: %s" name))
  (let ((fn (intern (format "pichat-tool/%s" name))))
    `(progn
       (defun ,fn (params)
         ,@body)
       (pichat-tools-register
        (pichat-tool-create
         :name ,(symbol-name name)
         :label ,(or (plist-get args :label) (symbol-name name))
         :description ,(or (plist-get args :description) "Emacs tool")
         :parameters ',(or (plist-get args :parameters) '(:type "object" :additionalProperties t))
         :function #',fn
         :instructions ,(plist-get args :instructions)
         :mutating-p ,(if (plist-get args :mutating) t nil)
         :async-p ,(if (plist-get args :async) t nil)
         :native-only-p ,(if (plist-get args :native-only) t nil)
         :group ,(plist-get args :group)
         :approval-summary ,(plist-get args :approval-summary))))))

(defun pichat-tools-bridge-tool (name)
  "Return registered bridge-exposable tool NAME, or nil."
  (let ((tool (and (stringp name) (gethash name pichat-tools-registry))))
    (and tool (not (pichat-tool-native-only-p tool)) tool)))

(defun pichat-tools-catalogue ()
  "Return detached bridge-exposable tool summaries for selection UIs.
Each entry has :name, :label, :description, :group and :mutating.  Listing a
tool never selects or exposes it."
  (let (entries)
    (maphash
     (lambda (name tool)
       (unless (pichat-tool-native-only-p tool)
         (push (list :name (copy-sequence name)
                     :label (copy-sequence (or (pichat-tool-label tool) name))
                     :description (copy-sequence (or (pichat-tool-description tool) ""))
                     :group (copy-sequence (or (pichat-tool-group tool)
                                               pichat-tools-default-group))
                     :mutating (and (pichat-tool-mutating-p tool) t))
               entries)))
     pichat-tools-registry)
    (sort entries (lambda (a b)
                    (let ((ga (plist-get a :group)) (gb (plist-get b :group)))
                      (if (equal ga gb)
                          (string< (plist-get a :name) (plist-get b :name))
                        (string< ga gb)))))))

(defun pichat-tools-definitions-json (&optional names)
  "Return JSON tool definitions for bridge registration.
NAMES restricts the result as in `pichat-tools-allowed-p': omission or
`all' includes every bridge-exposable tool, `none' includes nothing, and a
list includes only those exact registered names."
  (let (defs)
    (maphash
     (lambda (name tool)
       (unless (or (pichat-tool-native-only-p tool)
                   (not (pichat-tools-allowed-p name names)))
         (let ((instructions (pichat-tool-instructions tool)))
           (push (append (list :name (pichat-tool-name tool)
                               :label (pichat-tool-label tool)
                               :description (pichat-tool-description tool)
                               :parameters (pichat-tool-parameters tool)
                               :mutating (if (pichat-tool-mutating-p tool) t :json-false))
                         (when (and (stringp instructions)
                                    (not (string-blank-p instructions)))
                           (list :instructions instructions)))
                 defs))))
     pichat-tools-registry)
    (json-serialize (list :protocolVersion 1 :tools (vconcat (nreverse defs)))
                    :false-object :json-false :null-object nil)))

(defun pichat-tools-allowed-p (name allowed)
  "Return non-nil when tool NAME is permitted by ALLOWED.
ALLOWED is nil or `all' for unrestricted internal callers, or a list of
exact permitted names.  The empty selection is represented by `none'."
  (cond ((or (null allowed) (eq allowed 'all)) t)
        ((eq allowed 'none) nil)
        (t (and (member name allowed) t))))

(defun pichat-tools-approval-required-json-p (json &optional session allowed)
  "Return non-nil when JSON tool call requires interactive approval in SESSION.
Malformed, unknown and calls not permitted by ALLOWED (see
`pichat-tools-allowed-p') return nil so the ordinary execution path can
produce its error response without prompting."
  (condition-case nil
      (let* ((req (json-parse-string json :object-type 'plist :array-type 'list
                                     :false-object nil :null-object nil))
             (name (plist-get req :name))
             (tool (gethash name pichat-tools-registry)))
        (and tool
             (not (pichat-tool-native-only-p tool))
             (pichat-tools-allowed-p name allowed)
             (eq 'ask
                 (pichat-approval-resolve
                  name (pichat-tool-mutating-p tool) session))))
    (error nil)))

(defun pichat-tools-call (tool params &optional session)
  "Call registered TOOL with structured PARAMS and return a result plist.
The returned plist contains =:is-error= and =:value=.  When SESSION supplies an
Emacs working directory, bind it for the call.  Approval is deliberately outside
this function so transports can apply their own asynchronous gate."
  (unless (pichat-tool-p tool)
    (error "Invalid Emacs tool"))
  (when (pichat-tool-async-p tool)
    (error "Asynchronous Emacs-defined tools are unsupported: %s"
           (pichat-tool-name tool)))
  (condition-case err
      (let ((default-directory
             (or (and session
                      (fboundp 'pichat-session-emacs-cwd)
                      (pichat-session-emacs-cwd session))
                 default-directory))
            (pichat-tools-calling-session session))
        (list :is-error nil
              :value (funcall (pichat-tool-function tool) params)))
    (error
     (list :is-error t :value (error-message-string err)))))

(defun pichat-tools-approval-summary (tool params &optional session)
  "Return TOOL's bounded one-line approval summary for PARAMS, or nil.
SESSION is bound as `pichat-tools-calling-session'.  A failing summary
function yields nil, so the prompt still shows the raw arguments."
  (when-let* ((function (pichat-tool-approval-summary tool)))
    (condition-case nil
        (let ((pichat-tools-calling-session session))
          (pichat-tools-display-text (funcall function params)
                                     pichat-tools-approval-summary-limit))
      (error nil))))

;;; Helpers for tool authors

(defun pichat-tools-check-params (params allowed &optional required)
  "Validate PARAMS keys against ALLOWED and REQUIRED keywords; return PARAMS.
Enforce this in Emacs, not only through the advertised JSON schema."
  (unless (and (listp params) (cl-evenp (length params))
               (cl-loop for (key) on params by #'cddr always (keywordp key)))
    (user-error "Arguments must be a JSON object"))
  (cl-loop for (key) on params by #'cddr
           unless (memq key allowed)
           do (user-error "Unknown argument: %s" (substring (symbol-name key) 1)))
  (dolist (key required)
    (unless (plist-member params key)
      (user-error "Missing required argument: %s" (substring (symbol-name key) 1))))
  params)

(defun pichat-tools-count-param (params key default maximum &optional minimum)
  "Return integer PARAMS KEY in [MINIMUM, MAXIMUM], or DEFAULT when absent.
MINIMUM defaults to 0."
  (let ((value (if (plist-member params key) (plist-get params key) default))
        (minimum (or minimum 0)))
    (unless (and (integerp value) (<= minimum value maximum))
      (user-error "%s must be an integer from %d to %d"
                  (substring (symbol-name key) 1) minimum maximum))
    value))

(defun pichat-tools-boolean-param (params key)
  "Return t, nil or `absent' for boolean PARAMS KEY.
The bridge decodes JSON false and null as nil, so both mean false here."
  (if (not (plist-member params key)) 'absent
    (pcase (plist-get params key)
      ('t t)
      ((or 'nil :false :json-false) nil)
      (_ (user-error "%s must be true or false" (substring (symbol-name key) 1))))))

(defun pichat-tools-id-param (params key what)
  "Return PARAMS KEY as a validated record ID string described as WHAT."
  (let ((id (plist-get params key)))
    (unless (and (stringp id) (string-match-p "\\`[A-Za-z0-9_-]\\{1,128\\}\\'" id))
      (user-error "%s must be %s string" (substring (symbol-name key) 1) what))
    id))

(defun pichat-tools-display-text (value &optional limit)
  "Return string VALUE on one line, truncated to LIMIT columns, or nil.
LIMIT defaults to `pichat-tools-text-limit'.  Truncation ends with an ellipsis."
  (when (stringp value)
    (truncate-string-to-width
     (replace-regexp-in-string "[[:cntrl:]]+" " " value)
     (or limit pichat-tools-text-limit) nil nil "…")))

(defun pichat-tools-truncate (text limit)
  "Return string TEXT cut to at most LIMIT characters, keeping line breaks.
A cut text ends with an ellipsis; callers report truncation separately."
  (if (> (length text) limit)
      (concat (substring text 0 (max 0 (1- limit))) "…")
    text))

(defun pichat-tools-json (value)
  "Encode tool result VALUE as compact JSON text.
Use :null and :false for JSON null and false."
  (json-serialize value :null-object :null :false-object :false))

(defun pichat-tools--text (value)
  "Return VALUE with encoded UTF-8 strings decoded, recursively.
Tools commonly return `json-serialize' output, which is UTF-8 bytes; the
bridge reply needs character strings.  Invalid UTF-8 stays undecodable and
is reported by the bridge as a failed reply."
  (cond
   ((and (stringp value) (not (multibyte-string-p value))
         (string-match-p "[^\0-\177]" value))
    (decode-coding-string value 'utf-8))
   ((vectorp value) (vconcat (mapcar #'pichat-tools--text value)))
   ((consp value) (mapcar #'pichat-tools--text value))
   (t value)))

(defun pichat-tools-result-wire (result)
  "Convert structured tool RESULT into the existing bridge wire object."
  (let ((value (pichat-tools--text (plist-get result :value))))
    (append
     (when (plist-get result :is-error) (list :isError t))
     (cond
      ((stringp value)
       (list :content (vector (list :type "text" :text value))))
      ((listp value) value)
      (t
       (list :content
             (vector (list :type "text" :text (format "%S" value)))))))))

(cl-defun pichat-tools-execute-json (json &optional session allowed)
  "Execute tool call described by JSON for optional SESSION and return JSON.
ALLOWED restricts executable names as in `pichat-tools-allowed-p'; a call
outside it is rejected before approval or execution."
  (let* ((req (json-parse-string json :object-type 'plist :array-type 'list
                                 :false-object nil :null-object nil))
         (name (plist-get req :name))
         (params (plist-get req :params))
         (tool (gethash name pichat-tools-registry)))
    (unless (pichat-tools-allowed-p name allowed)
      ;; Answer rather than signal so the bridge request is never left pending.
      (cl-return-from pichat-tools-execute-json
        (json-serialize
         (list :isError t
               :content (vector (list :type "text"
                                      :text (format "Emacs tool is not selected for this runtime: %s"
                                                    name))))
         :false-object :json-false :null-object nil)))
    (unless tool (error "Unknown Emacs tool: %s" name))
    (when (pichat-tool-native-only-p tool)
      (error "Emacs tool is unavailable through the Pi bridge: %s" name))
    (json-serialize
     (if (pichat-approval-approve-p
          name (pichat-tool-mutating-p tool) params session
          (lambda () (pichat-tools-approval-summary tool params session)))
         (pichat-tools-result-wire (pichat-tools-call tool params session))
       (list :isError t
             :content (vector (list :type "text" :text "Denied by user"))))
     :false-object :json-false :null-object nil)))

(provide 'pichat-tools)
;;; pichat-tools.el ends here
