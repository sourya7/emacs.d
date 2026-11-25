;;; pichat-test-mcp-rpc.el --- Exact Pi MCP allowlists over RPC -*- lexical-binding: t; -*-

;;; Commentary:

;; Test Pi's installed CLI independently of PiChat's picker and launch policy.

;;; Code:

(require 'pichat-test-support)

(defconst pichat-test-mcp-rpc--fixtures
  (expand-file-name "fixtures" (file-name-directory (or load-file-name buffer-file-name))))

(defun pichat-test-mcp-rpc--config (agent-dir auto-enable)
  "Write two local fixture servers to AGENT-DIR with AUTO-ENABLE."
  (let ((python (or (executable-find "python3") (ert-fail "MCP fixture needs python3")))
        (server (expand-file-name "mcp-server.py" pichat-test-mcp-rpc--fixtures)))
    (with-temp-file (expand-file-name "mcp.json" agent-dir)
      (insert (json-serialize
               `(:autoEnableCodemode ,auto-enable
                 :mcpServers
                 (:probe (:command ,python
                          :args [,server "coded" "deferred" "direct" "other" "other_direct"]
                          :exposure "codemode"
                          :toolExposure (:deferred "deferred" :direct "direct" :other_direct "direct"))
                  :peer (:command ,python :args [,server "coded" "direct"]
                         :exposure "codemode" :toolExposure (:direct "direct"))))
               :false-object :json-false)))))

(defun pichat-test-mcp-rpc--run (session status-file)
  "Return SESSION's tool result texts after checking fake provider STATUS-FILE."
  (pichat-test-prompt-and-wait session "Check the fixture tools")
  ;; The shared consumption check alone also accepts an error on the last turn.
  (let ((status (pichat-test-provider-status status-file)))
    (should status)
    (should-not (plist-get status :error)))
  (let* ((response (pichat-test-rpc-call session "get_messages"))
         (messages (plist-get (plist-get response :data) :messages)))
    (cl-loop for msg in messages
             when (equal (plist-get msg :role) "toolResult")
             collect (progn
                       (when (eq (plist-get msg :isError) t)
                         (ert-fail (format "Fixture tool failed: %S" msg)))
                       (mapconcat (lambda (item) (or (plist-get item :text) ""))
                                  (plist-get msg :content) "\n")))))

(when pichat-test-include-integration
  (ert-deftest pichat-integration-mcp-runtime-derives-route-without-declaring-indirect-tools ()
    (pichat-test-with-presets
      (pichat-make-preset 'indirect :tools '("read") :mcp '(("probe" . "deferred")))
      (pichat-test-with-integration-session
          (session :preset 'indirect :no-session t
                   :extensions '("builtin:mcp" "builtin:codemode" "builtin:tool-search")
                   :before-start (pichat-test-mcp-rpc--config agent-dir :json-false)
                   :script '(:turns
                             [(:expectDeclaredTools ["read" "codemode"]
                               :toolCall
                               (:name "codemode" :arguments
                                (:code "const names = ALL_TOOLS.map(x => x.name).filter(n => n.startsWith('mcp__')); if (names.join(',') !== 'mcp__probe__deferred') throw Error(names.join(',')); text((await tools.mcp__probe__deferred({})).content[0].text);")))
                              (:expectDeclaredTools ["read" "codemode"] :text "done")]))
        (pcase-let ((`(,result) (pichat-test-mcp-rpc--run session status-file)))
          (should (string-match-p (regexp-quote "CALLED deferred") result)))
        (should-not (plist-get (pichat-session-tool-selection session) :extensions))
        (should (member "read,mcp__probe__deferred,codemode" (pichat-session-rpc-command session)))
        (should-not (member "--no-mcp" (pichat-session-rpc-command session))))))

  (ert-deftest pichat-integration-mcp-rpc-codemode-exact-allowlist ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :tools "codemode,mcp__probe__coded,mcp__probe__deferred,mcp__probe__direct"
                 :extensions '("builtin:mcp" "builtin:codemode")
                 :before-start (pichat-test-mcp-rpc--config agent-dir :json-false)
                 :script
                 '(:turns
                   [(:expectDeclaredTools ["codemode" "mcp__probe__direct"]
                     :toolCall
                     (:name "codemode" :arguments
                      (:code "const expected = 'mcp__probe__coded,mcp__probe__deferred,mcp__probe__direct';
const names = (items) => items.map(x => x.name).filter(n => n.startsWith('mcp__')).sort().join(',');
const all = names(ALL_TOOLS);
const ranked = names(await searchTools('fixture', { limit: 20 }));
if (all !== expected || ranked !== expected) throw Error(JSON.stringify({ all, ranked }));
for (const name of ['mcp__probe__other', 'mcp__probe__other_direct', 'mcp__peer__coded', 'mcp__peer__direct']) {
  if (name in tools) throw Error('Unexpected callable tool: ' + name);
}
for (const name of ['mcp__probe__coded', 'mcp__probe__deferred']) {
  text((await tools[name]({})).content[0].text);
}")))
                    (:expectDeclaredTools ["codemode" "mcp__probe__direct"]
                     :toolCall (:name "mcp__probe__direct"))
                    (:expectDeclaredTools ["codemode" "mcp__probe__direct"]
                     :text "done")]))
      (pcase-let ((`(,script-result ,direct-result)
                   (pichat-test-mcp-rpc--run session status-file)))
        (should (string-match-p (regexp-quote "CALLED coded") script-result))
        (should (string-match-p (regexp-quote "CALLED deferred") script-result))
        (should (equal "CALLED direct" direct-result)))))

  (ert-deftest pichat-integration-mcp-rpc-tool-search-exact-allowlist ()
    (pichat-test-with-integration-session
        (session :no-session t
                 :tools "tool_search,mcp__probe__coded,mcp__probe__deferred,mcp__probe__direct"
                 :extensions '("builtin:mcp" "builtin:tool-search" "builtin:codemode")
                 :before-start (pichat-test-mcp-rpc--config agent-dir t)
                 :script
                 '(:turns
                   [(:expectDeclaredTools ["tool_search" "mcp__probe__direct"]
                     :toolCall (:name "tool_search" :arguments (:query "fixture" :limit 20)))
                    (:expectDeclaredTools ["tool_search" "mcp__probe__direct"
                                           "mcp__probe__coded" "mcp__probe__deferred"]
                     :toolCall (:name "mcp__probe__coded"))
                    (:text "done")]))
      (pcase-let ((`(,search-result ,call-result)
                   (pichat-test-mcp-rpc--run session status-file)))
        (should (string-match-p (regexp-quote "mcp__probe__coded") search-result))
        (should (string-match-p (regexp-quote "mcp__probe__deferred") search-result))
        (should-not (string-match-p "mcp__peer__\\|mcp__probe__other" search-result))
        (should (equal "CALLED coded" call-result)))))

  (ert-deftest pichat-integration-mcp-rpc-codemode-auto-activation ()
    ;; No --tools here: distinguish MCP's auto-activation setting and capability
    ;; check from the separate effect of rejecting names outside an allowlist.
    (dolist (case '((t nil t) (:json-false nil nil) (t t nil)))
      (pcase-let* ((`(,auto-enable ,replacement ,active) case)
                   (extensions (append '("builtin:mcp" "builtin:codemode")
                                       (when replacement
                                         (list (expand-file-name "non-reaching-codemode.ts"
                                                                 pichat-test-mcp-rpc--fixtures)))))
                   (declared (vconcat (when active '("codemode"))
                                      '("mcp__peer__direct" "mcp__probe__direct"
                                        "mcp__probe__other_direct"))))
        (ert-info ((format "Auto-activation case: %S" case))
          (pichat-test-with-integration-session
              (session :no-session t :extensions extensions
                       :before-start (pichat-test-mcp-rpc--config agent-dir auto-enable)
                       :script (list :turns (vector (list :expectDeclaredTools declared :text "done"))))
            (should-not (pichat-test-mcp-rpc--run session status-file)))))))

  (ert-deftest pichat-integration-mcp-rpc-missing-or-non-reaching-route ()
    (dolist (case '(;; Naming an unavailable tool doesn't load its extension.
                    ("codemode" nil t nil)
                    ;; Neither available access tool can bypass the allowlist.
                    (nil ("builtin:codemode" "builtin:tool-search") t nil)
                    ;; An explicitly selected replacement runs its own code only.
                    ("codemode" ("builtin:codemode" :replacement) :json-false t)))
      (pcase-let* ((`(,route ,extensions ,auto-enable ,replaced) case)
                   (extensions (mapcar
                                (lambda (source)
                                  (if (eq source :replacement)
                                      (expand-file-name "non-reaching-codemode.ts"
                                                        pichat-test-mcp-rpc--fixtures)
                                    source))
                                extensions))
                   (tools (string-join (delq nil (list route "mcp__probe__coded"
                                                       "mcp__probe__direct")) ","))
                   (declared (if replaced
                                 ["codemode" "mcp__probe__direct"]
                               ["mcp__probe__direct"])))
        (ert-info ((format "Route case: %S" case))
          (pichat-test-with-integration-session
              (session :no-session t :tools tools
                       :extensions (cons "builtin:mcp" extensions)
                       :before-start (pichat-test-mcp-rpc--config agent-dir auto-enable)
                       :script (list :turns
                                     (if replaced
                                         (vector (list :expectDeclaredTools declared
                                                       :toolCall '(:name "codemode"))
                                                 (list :expectDeclaredTools declared :text "done"))
                                       (vector (list :expectDeclaredTools declared :text "done")))))
            (should (equal (when replaced '("NON_REACHING_REPLACEMENT"))
                           (pichat-test-mcp-rpc--run session status-file)))))))))

(provide 'pichat-test-mcp-rpc)
;;; pichat-test-mcp-rpc.el ends here
