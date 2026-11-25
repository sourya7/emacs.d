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

(defun pichat-test-mcp-eligibility-catalogue ()
  "Return an MCP catalogue with inherited and overridden exposures."
  (car (pichat-mcp-discovery--normalize
        (concat "{\"servers\":["
                "{\"name\":\"probe\",\"enabled\":true,\"state\":\"connected\","
                "\"exposure\":\"codemode\",\"tools\":[\"coded\",\"later\",\"direct\",\"hidden\",\"unknown\"],"
                "\"toolExposure\":{\"later\":\"deferred\",\"direct\":\"direct\",\"hidden\":\"hidden\",\"unknown\":\"unknown\"}},"
                "{\"name\":\"disabled\",\"enabled\":false,\"state\":\"connected\",\"exposure\":\"deferred\",\"tools\":[\"x\"]},"
                "{\"name\":\"offline\",\"enabled\":true,\"state\":\"failed\",\"exposure\":\"codemode\",\"tools\":[\"x\"]},"
                "{\"name\":\"a-b\",\"enabled\":true,\"state\":\"connected\",\"exposure\":\"codemode\",\"tools\":[\"x\"]},"
                "{\"name\":\"a_b\",\"enabled\":true,\"state\":\"connected\",\"exposure\":\"deferred\",\"tools\":[\"x\"]}]}"))))

(ert-deftest pichat-tool-selection-mcp-eligibility-fails-closed ()
  (let* ((servers (pichat-test-mcp-eligibility-catalogue))
         (eligible (cl-loop for server in servers
                            append (cl-loop for tool in (plist-get server :tools)
                                            when (plist-get tool :eligible)
                                            collect (plist-get tool :exposure)))))
    (should (equal eligible '("codemode" "deferred" "direct")))
    (dolist (pair '(("probe" . "hidden") ("probe" . "unknown") ("probe" . "absent")
                    ("disabled" . "x") ("offline" . "x") ("a-b" . "x") ("a_b" . "x")))
      (should-error (pichat-tool-selection-mcp-access
                     (list :mcp (list pair)) servers
                     '((:name "codemode" :eligible t :reaches-tools t)))
                    :type 'user-error))))

(ert-deftest pichat-tool-selection-mcp-access-derives-one-route-without-persisting ()
  (let* ((servers (pichat-test-mcp-eligibility-catalogue))
         (tools '((:name "tool_search" :eligible t :reaches-tools t)
                  (:name "codemode" :eligible t :reaches-tools t)))
         (snapshot '(:mcp (("probe" . "coded") ("probe" . "later") ("probe" . "direct")))))
    (should-not (pichat-tool-selection-mcp-access nil nil nil))
    (should-not (pichat-tool-selection-mcp-access '(:mcp (("probe" . "direct"))) servers nil))
    (should (equal "codemode" (pichat-tool-selection-mcp-access snapshot servers tools)))
    (should-not (pichat-tool-selection-mcp-access
                 (append snapshot '(:extensions ("tool_search"))) servers tools))
    ;; A same-name replacement that cannot reach tools does not count, even
    ;; when explicitly selected. Recheck against the destination catalogue.
    (let ((replacement '(:name "codemode" :eligible t)))
      (should (equal "tool_search"
                     (pichat-tool-selection-mcp-access
                      (append snapshot '(:extensions ("codemode"))) servers
                      (list (car tools) replacement))))
      (should-error (pichat-tool-selection-mcp-access snapshot servers (list replacement))
                    :type 'user-error))
    (should-error (pichat-tool-selection-mcp-access
                   snapshot servers '((:name "codemode" :reaches-tools t :eligible nil)))
                  :type 'user-error)
    (should (equal "tool_search"
                   (pichat-tool-selection-mcp-access
                    (append snapshot '(:emacs ("codemode"))) servers tools)))
    (should-error (pichat-tool-selection-check-catalogue snapshot servers) :type 'user-error)
    (should (equal snapshot '(:mcp (("probe" . "coded") ("probe" . "later") ("probe" . "direct")))))))

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
