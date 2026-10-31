;;; pichat-job-launch.el --- Captured Pi job launch configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Resolve existing launch configuration once.  Persist only data, never printed
;; structs or executable Lisp.  Environment/credentials and installed extension
;; code remain live; this is not a reproducible environment or a sandbox.

;;; Code:
(require 'pichat)
(require 'pichat-job-core)

(defun pichat-job-launch--pairs (pairs)
  "Encode string PAIRS as JSON objects."
  (vconcat (mapcar (lambda (pair) (list :from (car pair) :to (cdr pair))) pairs)))

(defun pichat-job-launch--unpairs (pairs)
  "Decode JSON PAIRS without reading Lisp."
  (mapcar (lambda (pair)
            (unless (and (stringp (plist-get pair :from))
                         (stringp (plist-get pair :to)))
              (user-error "Invalid captured path/tool pair"))
            (cons (plist-get pair :from) (plist-get pair :to))) pairs))

(defun pichat-job-launch--strings (values)
  "Return a list of captured string VALUES or reject invalid data."
  (unless (and (vectorp values) (seq-every-p #'stringp values))
    (user-error "Invalid captured argument/tool list"))
  (append values nil))

(defun pichat-job-launch--preset (preset)
  "Encode resolved PRESET."
  (list :name (symbol-name (plist-get preset :name))
        :description (plist-get preset :description)
        :inherited (if (eq (plist-get preset :tools) :default) t :false)
        :tools (vconcat (unless (eq (plist-get preset :tools) :default)
                          (plist-get preset :tools)))
        :extensions (vconcat (plist-get preset :extensions))
        :system-prompt (plist-get preset :system-prompt)
        :append-system-prompt (plist-get preset :append-system-prompt)))

(defun pichat-job-launch--unpreset (preset)
  "Decode captured PRESET.  Registry definitions are not consulted."
  (unless (pichat-job--text-p (plist-get preset :name))
    (user-error "Missing captured preset name"))
  (let ((result
         (list :name (intern (plist-get preset :name))
               :description (plist-get preset :description)
               :tools (if (eq (plist-get preset :inherited) t) :default
                        (pichat-job-launch--strings (plist-get preset :tools)))
               :extensions (pichat-job-launch--strings (plist-get preset :extensions))
               :system-prompt (plist-get preset :system-prompt)
               :append-system-prompt (plist-get preset :append-system-prompt))))
    (pichat-presets--validate
     (plist-get result :name)
     (list :description (plist-get result :description)
           :tools (plist-get result :tools)
           :extensions (plist-get result :extensions)
           :system-prompt (plist-get result :system-prompt)
           :append-system-prompt (plist-get result :append-system-prompt)))
    result))

(defun pichat-job-launch--tools (tools)
  "Encode resolved TOOLS."
  (when tools
    (list :builtins (vconcat (plist-get tools :builtins))
          :mcp (pichat-job-launch--pairs (plist-get tools :mcp))
          :extensions (vconcat (plist-get tools :extensions)))))

(defun pichat-job-launch--untools (preset tools)
  "Decode TOOLS and validate against captured PRESET."
  (pichat-tool-selection-resolve
   preset (when tools
            (list :builtins (pichat-job-launch--strings (plist-get tools :builtins))
                  :mcp (pichat-job-launch--unpairs (plist-get tools :mcp))
                  :extensions (pichat-job-launch--strings (plist-get tools :extensions))))))

(defun pichat-job-launch--transport (transport)
  "Encode captured TRANSPORT, preserving private execution context."
  (let ((remote-path (pichat-transport-remote-path transport)))
    (unless (cl-every (lambda (entry) (or (stringp entry)
                                         (eq entry 'tramp-own-remote-path))) remote-path)
      (user-error "Job target has unsupported remote-path entries"))
    (list :id (format "%s" (pichat-transport-id transport))
          :kind (symbol-name (pichat-transport-kind transport))
          :label (pichat-transport-label transport)
          :prefix (pichat-transport-tramp-prefix transport)
          :executable (pichat-transport-pi-executable transport)
          :args (vconcat (pichat-transport-pi-args transport))
          :remote-path (vconcat (mapcar (lambda (entry)
                                         (if (stringp entry) (list :path entry)
                                           '(:own t))) remote-path))
          :home (pichat-transport-runtime-home-value transport)
          :mappings (pichat-job-launch--pairs (pichat-transport-mappings transport)))))

(defun pichat-job-launch--untransport (data)
  "Decode captured transport DATA, never resolving a changed target registry."
  (unless (and (pichat-job--text-p (plist-get data :id))
               (member (plist-get data :kind) '("local" "ssh"))
               (or (equal (plist-get data :kind) "local")
                   (and (stringp (plist-get data :prefix))
                        (file-remote-p (plist-get data :prefix)))))
    (user-error "Invalid captured job target"))
  (pichat-transport--create
   :id (plist-get data :id) :kind (intern (plist-get data :kind))
   :label (plist-get data :label) :tramp-prefix (plist-get data :prefix)
   :pi-executable (plist-get data :executable)
   :pi-args (pichat-job-launch--strings (plist-get data :args))
   :remote-path (mapcar (lambda (entry)
                         (cond ((eq (plist-get entry :own) t) 'tramp-own-remote-path)
                               ((stringp (plist-get entry :path)) (plist-get entry :path))
                               (t (user-error "Invalid remote search path"))))
                       (plist-get data :remote-path))
   :runtime-home-value (plist-get data :home)
   :mappings (pichat-transport--copy-mappings
              (pichat-job-launch--unpairs (plist-get data :mappings)))))

(defun pichat-job-launch-capture (title instructions directory profile &optional access)
  "Resolve prompt work into a durable spec using existing launch PROFILE.
ACCESS is write (default), read (stable files), or observe (changing files).
No runtime is registered/spawned or made current.  Model must be selected before
submission.  Complete wrappers and conversation-loading flags are unsupported."
  (when pichat-rpc-command
    (user-error "Jobs require structured Pi launch settings, not a complete wrapper"))
  (let* ((profile (pichat--normalize-launch-profile
                   (append '(:reuse new :persistence persistent) profile)))
         (model (plist-get profile :model)))
    (unless (stringp model)
      (user-error "Choose a concrete model before saving or running a job"))
    (when (plist-get profile :conversation)
      (user-error "Jobs always start a fresh independent Pi session"))
    (let* ((directory (file-name-as-directory (expand-file-name directory)))
           (session (pichat-prepare-session
                     directory nil
                     (list :preset (plist-get profile :preset)
                           :tools (plist-get profile :tools) :model model
                           :target (unless (eq (plist-get profile :target) 'inferred)
                                     (plist-get profile :target)))))
           (transport (pichat-session-transport session))
           (context (pichat-session-path-context session))
           (command (pichat-rpc-build-command session))
           (runtime-cwd (pichat-session-runtime-cwd session))
           ;; Canonicalize on the execution host, not the local mount alias.
           (canonical-directory
            (file-truename (pichat-transport-runtime-file-name transport runtime-cwd)))
           (canonical (or (pichat--project-root canonical-directory)
                          canonical-directory))
           (key (format "%s:%s"
                        (if (eq (pichat-transport-kind transport) 'ssh)
                            (pichat-transport-tramp-prefix transport) "local")
                        (or (file-remote-p canonical 'localname) canonical))))
      (dolist (arg command)
        (when (or (member arg '("--no-session" "--continue" "-c" "--resume" "-r"))
                  (string-match-p "\\`--session\\(?:=\\|\\'\\)" arg))
          (user-error "Jobs cannot disable storage or load an existing conversation")))
      (pichat-job--copy
       (pichat-job--validate-spec
        (list :title title :instructions instructions :directory directory
              :resources (vector (list :key key :access (or access "write")))
              :configuration
              (list :version 1 :command (vconcat command) :model model
                    :preset (pichat-job-launch--preset (pichat-session-preset-spec session))
                    :tools (pichat-job-launch--tools (pichat-session-tool-selection session))
                    :transport (pichat-job-launch--transport transport)
                    :runtime-directory runtime-cwd
                    :mappings (pichat-job-launch--pairs (pichat-path-context-mappings context))
                    :strict (if (pichat-path-context-strict-p context) t :false))))))))

(defun pichat-job-launch-prepare (spec)
  "Prepare captured SPEC's exact runtime without spawning or changing focus.
Return (SESSION COMMAND).  This does not consult preset or target registries."
  (pichat-job--validate-spec spec)
  (let* ((config (plist-get spec :configuration))
         (transport (pichat-job-launch--untransport (plist-get config :transport)))
         (preset (pichat-job-launch--unpreset (plist-get config :preset)))
         (tools (pichat-job-launch--untools preset (plist-get config :tools)))
         (directory (plist-get spec :directory))
         (runtime-directory (plist-get config :runtime-directory))
         (command (pichat-job-launch--strings (plist-get config :command))))
    (unless (and (eql (plist-get config :version) 1)
                 (pichat-job--text-p runtime-directory)
                 (file-name-absolute-p runtime-directory)
                 (not (file-remote-p runtime-directory)) command)
      (user-error "Invalid captured job launch configuration"))
    (let* ((scope (pichat--scope-for-directory directory nil transport))
           (session (pichat-session-make
                     :cwd directory :emacs-cwd directory :runtime-cwd runtime-directory
                     :owner-directory directory :transport transport
                     :path-context (pichat-path-context--create
                                    :transport-id (pichat-transport-id transport)
                                    :mappings (pichat-job-launch--unpairs (plist-get config :mappings))
                                    :strict-p (eq (plist-get config :strict) t))
                     :persistence 'persistent :startup-model (plist-get config :model)
                     :preset-spec preset :tool-selection tools
                     :scope-key (nth 0 scope) :scope-label (nth 2 scope)
                     :owner-scope-key (nth 0 scope) :owner-scope-label (nth 2 scope))))
      (list session command))))

(provide 'pichat-job-launch)
;;; pichat-job-launch.el ends here
