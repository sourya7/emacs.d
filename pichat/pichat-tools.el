;;; pichat-tools.el --- Emacs-defined tools for PiChat -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'pichat-approval)

(cl-defstruct (pichat-tool (:constructor pichat-tool-create))
  name label description parameters function mutating-p)

(defvar pichat-tools-registry (make-hash-table :test #'equal)
  "Registered Emacs tools keyed by tool name.")

(defun pichat-tools-register (tool)
  "Register Emacs TOOL."
  (puthash (pichat-tool-name tool) tool pichat-tools-registry)
  tool)

(defmacro pichat-define-tool (name args &rest body)
  "Define a PiChat Emacs tool NAME.
ARGS is a plist accepting :label, :description, :parameters, and :mutating."
  (declare (indent 2))
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
         :mutating-p ,(if (plist-get args :mutating) t nil))))))

(defun pichat-tools-definitions-json ()
  "Return JSON tool definitions for bridge registration."
  (let (defs)
    (maphash
     (lambda (_ tool)
       (push (list :name (pichat-tool-name tool)
                   :label (pichat-tool-label tool)
                   :description (pichat-tool-description tool)
                   :parameters (pichat-tool-parameters tool)
                   :mutating (if (pichat-tool-mutating-p tool) t :json-false))
             defs))
     pichat-tools-registry)
    (json-serialize (list :protocolVersion 1 :tools (vconcat (nreverse defs)))
                    :false-object :json-false :null-object nil)))

(defun pichat-tools-approval-required-json-p (json &optional session)
  "Return non-nil when JSON tool call requires interactive approval in SESSION.
Malformed and unknown calls return nil so the ordinary execution path can
produce its existing error response."
  (condition-case nil
      (let* ((req (json-parse-string json :object-type 'plist :array-type 'list
                                     :false-object nil :null-object nil))
             (name (plist-get req :name))
             (tool (gethash name pichat-tools-registry)))
        (and tool
             (eq 'ask
                 (pichat-approval-resolve
                  name (pichat-tool-mutating-p tool) session))))
    (error nil)))

(defun pichat-tools-call (tool params)
  "Call registered TOOL with structured PARAMS and return a result plist.
The returned plist contains =:is-error= and =:value=.  Approval is deliberately
outside this function so transports can apply their own asynchronous gate."
  (unless (pichat-tool-p tool)
    (error "Invalid Emacs tool"))
  (condition-case err
      (list :is-error nil
            :value (funcall (pichat-tool-function tool) params))
    (error
     (list :is-error t :value (error-message-string err)))))

(defun pichat-tools-result-wire (result)
  "Convert structured tool RESULT into the existing bridge wire object."
  (let ((value (plist-get result :value)))
    (append
     (when (plist-get result :is-error) (list :isError t))
     (cond
      ((stringp value)
       (list :content (vector (list :type "text" :text value))))
      ((listp value) value)
      (t
       (list :content
             (vector (list :type "text" :text (format "%S" value)))))))))

(defun pichat-tools-execute-json (json &optional session)
  "Execute tool call described by JSON for optional SESSION and return JSON."
  (let* ((req (json-parse-string json :object-type 'plist :array-type 'list
                                 :false-object nil :null-object nil))
         (name (plist-get req :name))
         (params (plist-get req :params))
         (tool (gethash name pichat-tools-registry)))
    (unless tool (error "Unknown Emacs tool: %s" name))
    (json-serialize
     (if (pichat-approval-approve-p
          name (pichat-tool-mutating-p tool) params session)
         (pichat-tools-result-wire (pichat-tools-call tool params))
       (list :isError t
             :content (vector (list :type "text" :text "Denied by user"))))
     :false-object :json-false :null-object nil)))

(pichat-define-tool echo (:label "Echo" :description "Echo input from Emacs" :parameters (:type "object" :additionalProperties t))
  (format "%S" params))

(provide 'pichat-tools)
;;; pichat-tools.el ends here
