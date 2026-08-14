;;; pichat-test-tool-enrichment.el --- Pure tool enrichment tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for generation-scoped, presentation-only tool metadata.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-tool-enrichment)

(ert-deftest pichat-tool-enrichment-classifies-known-heuristic-and-unknown-tools ()
  (let ((pichat-tool-enrichment-kind-alist
         '(("custom_reader" . read))))
    (should (eq 'read (pichat-tool-enrichment-classify "CUSTOM_READER")))
    (should (eq 'execute
                (pichat-tool-enrichment-classify "extension_shell_runner")))
    (should (eq 'other (pichat-tool-enrichment-classify "frobnicate")))
    (should (eq 'other (pichat-tool-enrichment-classify nil)))))

(ert-deftest pichat-tool-enrichment-normalizes-argument-variants-table ()
  (should
   (equal '(:path "a.el" :line 7 :column 3 :command "echo hi"
                  :pattern "needle" :old-text "before" :new-text "after")
          (pichat-tool-enrichment-normalize-arguments
           '(:filePath "a.el" :line_number 7 :startColumn 3 :cmd "echo hi"
             :search_term "needle" :oldText "before" :new_text "after")))))

(ert-deftest pichat-tool-enrichment-merge-is-monotonic-for-partial-reordered-updates ()
  (let* ((start (pichat-tool-enrichment-build "call" "edit" nil))
         (args (pichat-tool-enrichment-build
                "call" nil '(:file_path "/tmp/example.el" :line 12)))
         (merged (pichat-tool-enrichment-merge start args))
         (end (pichat-tool-enrichment-merge
               merged (pichat-tool-enrichment-build "call" nil nil))))
    (should (equal "edit" (plist-get end :name)))
    (should (eq 'edit (plist-get end :kind)))
    (should (equal "/tmp/example.el" (plist-get end :runtime-path)))
    (should (equal "/tmp/example.el" (plist-get end :host-path)))
    (should (= 12 (plist-get end :line)))
    (should (equal "/tmp/example.el:12" (plist-get end :title))))
  (let* ((args-first (pichat-tool-enrichment-build
                      "reordered" nil '(:filePath "later.el" :oldText "old")))
         (name-later (pichat-tool-enrichment-build
                      "reordered" "edit" nil))
         (merged (pichat-tool-enrichment-merge args-first name-later)))
    (should (eq 'edit (plist-get merged :kind)))
    (should (equal "later.el" (plist-get merged :host-path)))
    (should (equal "old" (plist-get (plist-get merged :arguments)
                                     :old-text)))))

(ert-deftest pichat-tool-enrichment-rejects-merge-across-tool-call-ids ()
  (should-error
   (pichat-tool-enrichment-merge
    (pichat-tool-enrichment-build "one" "read" nil)
    (pichat-tool-enrichment-build "two" "read" nil))))

(ert-deftest pichat-tool-enrichment-resolves-local-mapped-and-unmapped-paths ()
  (let ((pichat-path-mappings nil))
    (should
     (equal '(:status same-runtime :runtime-path "/work/a.el"
                      :host-path "/work/a.el" :reason nil)
            (pichat-tool-enrichment-resolve-runtime-path "/work/a.el"))))
  (let ((pichat-path-mappings
         '(("/home/me/project" . "/workspace")
           ("/home/me/other" . "/workspace/other"))))
    (let ((mapped
           (pichat-tool-enrichment-resolve-runtime-path
            "/workspace/other/a.el"))
          (unmapped
           (pichat-tool-enrichment-resolve-runtime-path "/container/a.el")))
      (should (eq 'mapped (plist-get mapped :status)))
      (should (equal "/home/me/other/a.el" (plist-get mapped :host-path)))
      (should (eq 'unavailable (plist-get unmapped :status)))
      (should-not (plist-get unmapped :host-path))
      (should (string-match-p "not covered" (plist-get unmapped :reason))))))

(ert-deftest pichat-tool-enrichment-derives-read-write-and-edit-argument-locations ()
  (let ((pichat-path-mappings nil))
    (let ((read (pichat-tool-enrichment-build
                 "read" "read" '(:filename "a.el" :offset 9 :column 2)))
          (write (pichat-tool-enrichment-build
                  "write" "write" '(:targetPath "b.el")))
          (edit (pichat-tool-enrichment-build
                 "edit" "edit" '(:path "c.el" :startLine 4))))
      (should (equal '("a.el" 9 2)
                     (list (plist-get read :host-path)
                           (plist-get read :line)
                           (plist-get read :column))))
      (should (= 1 (plist-get write :line)))
      (should (= 4 (plist-get edit :line))))))

(ert-deftest pichat-tool-enrichment-unmapped-runtime-path-has-no-local-location ()
  (let* ((pichat-path-mappings '(("/host/project" . "/workspace")))
         (record (pichat-tool-enrichment-build
                  "read" "read" '(:path "/remote/project/a.el" :line 8))))
    (should (eq 'unavailable (plist-get record :path-status)))
    (should-not (plist-get record :host-path))
    (should-not (plist-get record :line))
    (should (equal "/remote/project/a.el:8" (plist-get record :title)))))

(ert-deftest pichat-tool-enrichment-infers-only-unique-old-text-location ()
  (should
   (equal '(:status unique :line 2 :column 3)
          (pichat-tool-enrichment-infer-old-text-location
           "target" "first\n  target here\nlast")))
  (should
   (equal '(:status non-unique)
          (pichat-tool-enrichment-infer-old-text-location
           "same" "same then same")))
  (should
   (equal '(:status not-found)
          (pichat-tool-enrichment-infer-old-text-location
           "missing" "some text")))
  (should
   (equal '(:status unavailable)
          (pichat-tool-enrichment-infer-old-text-location "" "some text"))))

(ert-deftest pichat-tool-enrichment-build-does-not-touch-filesystem ()
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (&rest _) (error "filesystem access")))
            ((symbol-function 'file-readable-p)
             (lambda (&rest _) (error "filesystem access")))
            ((symbol-function 'insert-file-contents)
             (lambda (&rest _) (error "filesystem access"))))
    (let ((record (pichat-tool-enrichment-build
                   "call" "edit" '(:path "/tmp/a.el" :oldText "x"))))
      (should (equal "/tmp/a.el" (plist-get record :host-path))))))

(ert-deftest pichat-chat-captures-and-monotonically-updates-tool-enrichment ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_start\",\"toolCallId\":\"enriched\",\"toolName\":\"edit\",\"args\":{\"filePath\":\"a.el\",\"line\":6}}\n")
            (pichat-rpc--process-filter
             proc
             "{\"type\":\"tool_execution_update\",\"toolCallId\":\"enriched\",\"args\":{}}\n")
            (with-current-buffer buffer
              (let ((record (gethash "enriched" pichat-chat--tool-enrichments)))
                (should (eq 'edit (plist-get record :kind)))
                (should (equal "a.el" (plist-get record :host-path)))
                (should (= 6 (plist-get record :line)))
                (should (= pichat-chat--source-generation
                           (plist-get record :source-generation))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-rejects-stale-enrichment-and-clears-on-source-reset ()
  (with-temp-buffer
    (pichat-chat-mode)
    (setq pichat-chat--source-generation 3)
    (pichat-chat--capture-tool-enrichment
     '(:type "tool_execution_start" :toolCallId "current"
       :toolName "read" :args (:path "a.el"))
     3)
    (should (= 1 (hash-table-count pichat-chat--tool-enrichments)))
    (pichat-chat--capture-tool-enrichment
     '(:type "tool_execution_start" :toolCallId "stale"
       :toolName "read" :args (:path "stale.el"))
     2)
    (should-not (gethash "stale" pichat-chat--tool-enrichments))
    (pichat-chat--reset-for-source "new" nil t)
    (should (= 4 pichat-chat--source-generation))
    (should (zerop (hash-table-count pichat-chat--tool-enrichments)))))

(provide 'pichat-test-tool-enrichment)
;;; pichat-test-tool-enrichment.el ends here
