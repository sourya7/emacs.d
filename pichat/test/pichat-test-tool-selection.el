;;; pichat-test-tool-selection.el --- Preset-aware tool policy -*- lexical-binding: t; -*-

(require 'pichat-test-support)
(require 'pichat-tool-picker)

(ert-deftest pichat-tool-selection-preset-baseline-disables-mcp ()
  (let ((selection (pichat-tool-selection-resolve
                    (pichat-presets-resolve 'manual))))
    (should (equal '("read" "grep" "find" "ls" "edit" "write")
                   (plist-get selection :builtins)))
    (should (equal '("--tools" "read,grep,find,ls,edit,write" "--no-mcp")
                   (pichat-tool-selection-args selection)))
    (should-not (pichat-tool-selection-resolve (pichat-presets-resolve 'standard)))))

(ert-deftest pichat-tool-selection-restricts-builtins-to-preset ()
  (let ((manual (pichat-presets-resolve 'manual))
        (review (pichat-presets-resolve 'review)))
    (should-error (pichat-tool-selection-resolve manual
                                                 '(:builtins ("bash") :mcp nil))
                  :type 'user-error)
    (should-error (pichat-tool-selection-resolve review
                                                 '(:builtins ("edit") :mcp nil))
                  :type 'user-error)
    (should (equal '("--no-tools" "--no-mcp")
                   (pichat-tool-selection-args
                    (pichat-tool-selection-resolve review
                                                   '(:builtins nil :mcp nil)))))))

(ert-deftest pichat-tool-selection-direct-mcp-is-exact ()
  (let ((selection (pichat-tool-selection-resolve
                    (pichat-presets-resolve 'review)
                    '(:builtins ("read") :mcp (("ketch" . "search"))))))
    (should (equal '("--tools" "read,mcp__ketch__search")
                   (pichat-tool-selection-args selection)))
    (should-error (pichat-tool-selection-resolve
                   (pichat-presets-resolve 'review)
                   '(:builtins ("read") :mcp (("x" . "a-b") ("x" . "a_b"))))
                  :type 'user-error)))

(ert-deftest pichat-tool-selection-discovery-handles-partial-failure-and-collisions ()
  (pcase-let* ((`(,servers . ,errors)
                (pichat-mcp-discovery--normalize
                 (concat "{\"servers\":["
                         "{\"name\":\"probe\",\"enabled\":true,\"state\":\"connected\","
                         "\"exposure\":\"direct\",\"tools\":[\"search\",\"alpha-beta\",\"alpha_beta\",\"other\"],"
                         "\"toolExposure\":{\"other\":\"hidden\"}},"
                         "{\"name\":\"bad\",\"state\":\"failed\",\"tools\":[],\"error\":\"offline\"}],"
                         "\"errors\":[\"partial\"]}")))
               (tools (plist-get (car servers) :tools)))
    (should (equal '("partial") errors))
    (should (plist-get (car tools) :eligible))
    (dolist (tool (cdr tools)) (should-not (plist-get tool :eligible)))
    (should-error
     (pichat-tool-selection-check-catalogue
      (pichat-tool-selection-resolve
       (pichat-presets-resolve 'manual)
       '(:builtins nil :mcp (("probe" . "alpha-beta"))))
      servers)
     :type 'user-error)
    (should (pichat-tool-selection-check-catalogue
             (pichat-tool-selection-resolve
              (pichat-presets-resolve 'manual)
              '(:builtins nil :mcp (("probe" . "search"))))
             servers))))

(ert-deftest pichat-tool-selection-launch-customization-forces-independent-runtime ()
  (let ((profile (pichat--launch-profile-from-arguments
                  '("--preset=default")
                  '(:directory "/tmp/" :tool-selection
                    (:builtins ("read") :mcp (("ketch" . "search")))))))
    (should (eq 'new (plist-get profile :reuse)))
    (should (equal '(("ketch" . "search"))
                   (plist-get (plist-get profile :tools) :mcp)))))

(ert-deftest pichat-tool-selection-picker-reset-and-empty-are-distinct ()
  (let ((pichat-tool-picker--state
         (list :baseline '("read" "edit")
               :draft '(:builtins ("read") :mcp nil))))
    (pichat-tool-picker--toggle :builtins "read")
    (should-not (plist-get (pichat-tool-picker--selection) :builtins))
    (pichat-tool-picker-reset)
    (should (equal '("read" "edit")
                   (plist-get (pichat-tool-picker--selection) :builtins)))))

(ert-deftest pichat-tool-selection-changing-preset-discards-confirmed-customization ()
  (let* ((scope (list :tool-selection '(:builtins ("read") :mcp nil)
                      :tool-target '("/tmp/" current inferred)))
         (transient--prefix (transient--init-prefix 'pichat-launch
                                                     (list :scope scope))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "review"))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _args) t)))
      (should (equal "review"
                     (pichat--launch-read-preset "Preset: " "manual" nil))))
    (should-not (plist-get scope :tool-selection))
    (should-not (plist-get scope :tool-target))))

(ert-deftest pichat-tool-picker-transients-render-dynamic-groups ()
  (let ((pichat-tool-picker--state
         (list :preset (pichat-presets-resolve 'manual)
               :baseline '("read" "edit")
               :draft '(:builtins ("read" "edit") :mcp nil)
               :loaded t :page 0 :server "probe"
               :servers (list (list :name "probe" :state "connected"
                                    :tools (list (list :name "search"
                                                       :exposure "direct"
                                                       :eligible t)))))))
    (dolist (prefix '(pichat-tool-picker pichat-tool-picker-server))
      (let* ((transient--prefix (transient--init-prefix prefix))
             (transient--layout (transient--init-suffixes prefix))
             (transient--suffixes (transient--flatten-suffixes transient--layout)))
        (with-temp-buffer
          (transient--insert-groups)
          (if (eq prefix 'pichat-tool-picker)
              (progn
                (should (string-match-p "\\[✓\\]" (buffer-string)))
                (should (string-match-p "probe" (buffer-string))))
            (should (string-match-p "search" (buffer-string)))))))))

(ert-deftest pichat-tool-picker-discovery-rebuilds-visible-choices-without-paging ()
  (let ((pichat-tool-picker--state
         (list :preset (pichat-presets-resolve 'manual)
               :baseline '("read" "edit")
               :draft '(:builtins ("read" "edit") :mcp nil)
               :transport (pichat-transport-resolve default-directory 'local)
               :runtime-cwd default-directory :executable "pi" :page 0))
        callback)
    (cl-letf (((symbol-function 'pichat-mcp-discovery-start)
               (lambda (_transport _cwd _executable done)
                 (setq callback done)
                 (lambda () nil))))
      (unwind-protect
          (progn
            (transient-setup 'pichat-tool-picker)
            (pichat-tool-picker--discover)
            (with-temp-buffer
              (transient--insert-groups)
              (should (string-match-p "Discovering MCP servers" (buffer-string)))
              (should-not (string-match-p "probe (connected" (buffer-string))))
            (funcall callback
                     (list (list :name "probe" :state "connected"
                                 :tools (list (list :name "search"
                                                    :exposure "direct"
                                                    :eligible t)))) nil)
            (with-temp-buffer
              (transient--insert-groups)
              (should (string-match-p "probe (connected" (buffer-string))))
            (setq pichat-tool-picker--state
                  (plist-put pichat-tool-picker--state :server "probe"))
            (transient-setup 'pichat-tool-picker-server)
            (pichat-tool-picker--discover)
            (funcall callback
                     (list (list :name "probe" :state "connected"
                                 :tools (list (list :name "search" :eligible t)
                                              (list :name "lookup" :eligible t)))) nil)
            (with-temp-buffer
              (transient--insert-groups)
              (should (string-match-p "lookup" (buffer-string)))))
        (transient-quit-all)))))

(provide 'pichat-test-tool-selection)
;;; pichat-test-tool-selection.el ends here
