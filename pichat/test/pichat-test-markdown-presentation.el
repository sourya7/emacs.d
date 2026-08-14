;;; pichat-test-markdown-presentation.el --- Pichat Test Markdown Presentation -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused PiChat ERT tests loaded by pichat-test.el.

;;; Code:

(require 'pichat-test-support)

;;; Markdown link and table presentation tests

(defun pichat-test-benchmark-markdown-rendering (&optional message-count)
  "Benchmark Markdown refresh for MESSAGE-COUNT representative prose runs."
  (require 'benchmark)
  (let ((message-count (or message-count 100)))
    (with-temp-buffer
      (setq-local pichat-chat--source-generation 1)
      (dotimes (index message-count)
        (insert (propertize
                 (format "## Response %d\n\n**bold** [source](https://example.test/%d)\n\n| A | B |\n|---|---|\n| %d | value |\n\n```elisp\n(message \"table | literal\")\n```\n\n"
                         index index index)
                 'pichat-prose t
                 'pichat-node-key (format "node-%d" index))))
      (let ((cold (benchmark-run 1
                    (pichat-markdown-presentation-refresh-buffer)))
            (warm (benchmark-run 1
                    (pichat-markdown-presentation-refresh-buffer))))
        (list :messages message-count
              :cold cold :warm warm
              :parse-cache
              (hash-table-count
               pichat-markdown-presentation--parse-cache)
              :table-cache
              (hash-table-count
               pichat-markdown-presentation--table-layout-cache)
              :overlays
              (length (overlays-in (point-min) (point-max))))))))

(ert-deftest pichat-markdown-table-inline-preview-is-bounded-and-preserves-source ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert-file-contents
     (expand-file-name "wide-markdown-table.md"
                       pichat-test-fixture-directory))
    (add-text-properties (point-min) (point-max)
                         '(pichat-prose t pichat-node-key "wide-table"))
    (let ((source (buffer-substring-no-properties (point-min) (point-max))))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-width-policy)
                 (lambda () '(72 . 72))))
        (pichat-markdown-presentation-refresh-buffer))
      (let ((rows (delq nil
                        (mapcar
                         (lambda (overlay)
                           (when (eq (overlay-get overlay
                                                 'pichat-markdown-kind)
                                     'table)
                             (overlay-get overlay 'before-string)))
                         (overlays-in (point-min) (point-max))))))
        (should rows)
        (should (cl-every
                 (lambda (row)
                   (and (not (string-match-p "\n" row))
                        (<= (string-width row) 72)))
                 rows))
        (should (seq-some (lambda (row) (string-match-p "…" row)) rows)))
      (should (equal "wide-table" (get-text-property (point-min)
                                                       'pichat-node-key)))
      (should (equal source
                     (buffer-substring-no-properties
                      (point-min) (point-max)))))))

(ert-deftest pichat-markdown-table-inline-preview-bounds-large-table-work ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize
             (concat
              "| Item | Value |\n|---|---|\n"
              (mapconcat
               (lambda (index)
                 (format "| row-%d | value-%d |" index index))
               (number-sequence 1 1000) "\n"))
             'pichat-prose t 'pichat-node-key "large-table"))
    (pichat-markdown-presentation-refresh-buffer)
    (let ((rendered-rows
           (cl-count-if
            (lambda (overlay) (overlay-get overlay 'before-string))
            (overlays-in (point-min) (point-max)))))
      (should (< rendered-rows 100))
      (should
       (seq-some
        (lambda (overlay)
          (string-match-p
           "[0-9]+ more rows"
           (or (overlay-get overlay 'before-string) "")))
        (overlays-in (point-min) (point-max)))))))

(ert-deftest pichat-markdown-table-viewer-opens-complete-read-only-org-table ()
  (let ((chat (generate-new-buffer " *pichat-table-view-test*"))
        viewer)
    (unwind-protect
        (with-current-buffer chat
          (setq-local pichat-chat--source-generation 1)
          (insert-file-contents
           (expand-file-name "wide-markdown-table.md"
                             pichat-test-fixture-directory))
          (add-text-properties (point-min) (point-max)
                               '(pichat-prose t
                                 pichat-node-key "wide-table"))
          (pichat-markdown-presentation-refresh-buffer)
          (goto-char (point-min))
          (setq viewer (pichat-chat-open-table-at-point))
          (should (buffer-live-p viewer))
          (with-current-buffer viewer
            (should (derived-mode-p 'pichat-view-mode))
            (should (derived-mode-p 'pichat-markdown-table-view-mode))
            (should buffer-read-only)
            (should truncate-lines)
            (should (bound-and-true-p orgtbl-mode))
            (goto-char (point-min))
            (should (search-forward
                     "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-unbroken-value"
                     nil t))))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(defun pichat-test--markdown-link-record (beg &optional url label)
  "Return one deterministic test link record starting at BEG."
  (let* ((url (or url "https://example.test/path"))
         (label (or label "source"))
         (source (format "[%s](%s)" label url)))
    (pichat-markdown-link-create
     :start beg :end (+ beg (length source)) :label label :url url
     :form 'inline)))

(ert-deftest pichat-markdown-compact-link-preserves-source-and-is-actionable ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 3)
    (insert (propertize "[source](https://example.test/path)"
                        'pichat-prose t 'pichat-node-key "node"))
    (let ((original (buffer-substring-no-properties (point-min) (point-max))))
      (cl-letf (((symbol-function 'pichat-markdown-presentation--extract-links)
                 (lambda (beg _end)
                   (list (pichat-test--markdown-link-record beg)))))
        (pichat-markdown-presentation-refresh-buffer)
        (let ((overlay (pichat-markdown-presentation--overlay-at-point 'link)))
          (should overlay)
          (should (equal "source" (overlay-get overlay 'display)))
          (should (eq 'compact (overlay-get overlay 'pichat-markdown-state)))
          (should (equal "https://example.test/path"
                         (overlay-get overlay 'pichat-markdown-url)))
          (should (keymapp (overlay-get overlay 'keymap)))
          (should (eq #'pichat-chat-open-link-at-point
                      (key-binding (kbd "RET")))))
        (should (equal original
                       (buffer-substring-no-properties
                        (point-min) (point-max))))))))

(ert-deftest pichat-markdown-link-is-an-embark-url-target-in-both-views ()
  (dolist (case '(("[OpenAI](https://openai.com)" "OpenAI"
                   "https://openai.com")
                  ("[Relative link](./README.md)" "Relative link"
                   "./README.md")
                  ("[Anchor link](#sample-links)" "Anchor link"
                   "#sample-links")))
    (with-temp-buffer
      (setq-local pichat-chat--source-generation 1)
      (insert (propertize (car case) 'pichat-prose t
                          'pichat-node-key "node"))
      (cl-letf (((symbol-function 'pichat-markdown-presentation--extract-links)
                 (lambda (beg _end)
                   (list (pichat-test--markdown-link-record
                          beg (nth 2 case) (nth 1 case))))))
        (pichat-markdown-presentation-refresh-buffer)
        (goto-char (point-min))
        (let ((target (pichat-markdown-presentation-embark-target)))
          (should (equal 'url (car target)))
          (should (equal (nth 2 case) (cadr target)))
          (should (= (point-min) (nth 2 target)))
          (should (= (point-max) (cdddr target))))
        (pichat-chat-toggle-link-at-point)
        (should (equal (nth 2 case)
                       (cadr (pichat-markdown-presentation-embark-target))))))))

(ert-deftest pichat-markdown-real-embark-prefers-overlay-url-to-label ()
  (skip-unless (require 'embark nil t))
  (with-temp-buffer
    (insert "[OpenAI](https://openai.com)")
    (let ((overlay (pichat-markdown-presentation--metadata-overlay
                    (point-min) (point-max) 'link 'key 'compact t)))
      (overlay-put overlay 'pichat-markdown-url "https://openai.com")
      (goto-char (+ (point-min) 2))
      (should (eq #'pichat-markdown-presentation-embark-target
                  (car embark-target-finders)))
      (let ((target (car (embark--targets))))
        (should (eq 'url (plist-get target :type)))
        (should (equal "https://openai.com"
                       (plist-get target :target)))))))

(ert-deftest pichat-markdown-link-at-point-toggle-reveals-exact-source ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize "[source](https://example.test/path)"
                        'pichat-prose t 'pichat-node-key "node"))
    (cl-letf (((symbol-function 'pichat-markdown-presentation--extract-links)
               (lambda (beg _end)
                 (list (pichat-test--markdown-link-record beg)))))
      (pichat-markdown-presentation-refresh-buffer)
      (goto-char (point-min))
      (pichat-chat-toggle-link-at-point)
      (let ((overlay (pichat-markdown-presentation--overlay-at-point 'link)))
        (should (eq 'source (overlay-get overlay 'pichat-markdown-state)))
        (should-not (overlay-get overlay 'display)))
      (should (equal "[source](https://example.test/path)"
                     (buffer-substring-no-properties
                      (point-min) (point-max))))
      (pichat-chat-toggle-link-at-point)
      (should (equal "source"
                     (overlay-get
                      (pichat-markdown-presentation--overlay-at-point 'link)
                      'display))))))

(ert-deftest pichat-markdown-link-opening-rejects-unsafe-schemes ()
  (with-temp-buffer
    (insert "unsafe")
    (let ((overlay (pichat-markdown-presentation--metadata-overlay
                    (point-min) (point-max) 'link 'key 'compact t))
          opened)
      (overlay-put overlay 'pichat-markdown-url "javascript:alert(1)")
      (goto-char (point-min))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (should-error (pichat-chat-open-link-at-point) :type 'user-error)
        (should-not opened)))))

(ert-deftest pichat-markdown-mode-link-extraction-handles-inline-and-code ()
  (skip-unless (require 'markdown-mode nil t))
  (with-temp-buffer
    (insert "[source](https://example.test/a_(b)) and `[no](https://bad.test)`")
    (let ((links (pichat-markdown-presentation--extract-links
                  (point-min) (point-max))))
      (should (= 1 (length links)))
      (should (equal "source" (pichat-markdown-link-label (car links))))
      (should (equal "https://example.test/a_(b)"
                     (pichat-markdown-link-url (car links)))))))

(ert-deftest pichat-markdown-face-and-link-consumers-share-one-parse ()
  (skip-unless (require 'markdown-mode nil t))
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize "**bold** [source](https://example.test)"
                        'pichat-prose t 'pichat-node-key "node"))
    (let ((calls 0)
          (original (symbol-function 'font-lock-ensure)))
      (cl-letf (((symbol-function 'font-lock-ensure)
                 (lambda (&rest args)
                   (cl-incf calls)
                   (apply original args))))
        (pichat-chat--markdown-fontify-run (point-min) (point-max))
        (should (= 1 (length
                      (pichat-markdown-presentation--extract-links
                       (point-min) (point-max)))))
        (should (= 1 calls))))))

(ert-deftest pichat-markdown-parse-cache-is-bounded-and-resettable ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (let ((pichat-chat-markdown-cache-max-entries 2)
          (pichat-chat-markdown-cache-max-chars 10000))
      (dolist (source '("first" "second" "third"))
        (erase-buffer)
        (insert source)
        (pichat-markdown-presentation-parse-run (point-min) (point-max)))
      (should (= 2 (hash-table-count
                    pichat-markdown-presentation--parse-cache)))
      (pichat-markdown-presentation-reset-source)
      (should (= 0 (hash-table-count
                    pichat-markdown-presentation--parse-cache))))))

(ert-deftest pichat-markdown-refresh-reuses-active-working-set-beyond-cache-limit ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (let ((pichat-chat-markdown-cache-max-entries 2)
          (pichat-chat-markdown-cache-max-chars 10000)
          (parse-calls 0))
      (dotimes (index 5)
        (insert (propertize (format "prose-%d" index)
                            'pichat-prose t
                            'pichat-node-key (format "node-%d" index)))
        (insert "\n"))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--parse-source)
                 (lambda (_source digest)
                   (cl-incf parse-calls)
                   (pichat-markdown-parsed-run-create
                    :source-digest digest))))
        (pichat-markdown-presentation-refresh-buffer)
        (should (= 5 parse-calls))
        (should (= 2 (hash-table-count
                      pichat-markdown-presentation--parse-cache)))
        ;; A bounded long-lived cache must not force unchanged visible prose to
        ;; be reparsed on every complete projection refresh.
        (pichat-markdown-presentation-refresh-buffer)
        (should (= 5 parse-calls))
        (should (= 5 (hash-table-count
                      pichat-markdown-presentation--active-parse-cache)))
        (pichat-markdown-presentation-reset-source)
        (should-not pichat-markdown-presentation--active-parse-cache)))))

(ert-deftest pichat-markdown-at-point-toggle-preserves-unrelated-overlay ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize "[one](https://one.test) [two](https://two.test)"
                        'pichat-prose t 'pichat-node-key "node"))
    (let* ((first (pichat-markdown-link-create
                   :start (point-min) :end 24 :label "one"
                   :url "https://one.test" :form 'inline))
           (second (pichat-markdown-link-create
                    :start 25 :end (point-max) :label "two"
                    :url "https://two.test" :form 'inline)))
      (cl-letf (((symbol-function 'pichat-markdown-presentation--extract-links)
                 (lambda (_beg _end) (list first second))))
        (pichat-markdown-presentation-refresh-buffer))
      (goto-char 26)
      (let ((unrelated
             (pichat-markdown-presentation--overlay-at-point 'link)))
        (goto-char (point-min))
        (pichat-chat-toggle-link-at-point)
        (should (overlay-buffer unrelated))
        (goto-char 26)
        (should (eq unrelated
                    (pichat-markdown-presentation--overlay-at-point 'link)))))))

(ert-deftest pichat-markdown-table-width-uses-buffer-window-then-max-fraction ()
  (with-temp-buffer
    (let ((pichat-max-width 120)
          (pichat-chat-table-max-width-fraction 0.9))
      (cl-letf (((symbol-function 'get-buffer-window)
                 (lambda (&rest _) 'pichat-test-window))
                ((symbol-function 'window-body-width)
                 (lambda (&optional window _pixelwise)
                   (if (eq window 'pichat-test-window) 120 169))))
        (should (equal '(169 . 108)
                       (pichat-markdown-presentation--table-width-policy)))
        (let ((pichat-max-width 100))
          (should (equal '(169 . 90)
                         (pichat-markdown-presentation--table-width-policy))))))))

(ert-deftest pichat-markdown-table-discovery-is-scoped-to-each-prose-run ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 2)
    (insert (propertize "first prose" 'pichat-prose t
                        'pichat-node-key "first"))
    (insert (propertize "\nseparator\n" 'pichat-content-kind 'tool))
    (let ((table-start (point)))
      (insert (propertize "| A |\n|---|\n| x |" 'pichat-prose t
                          'pichat-node-key "second"))
      (pichat-markdown-presentation-refresh-buffer)
      (let ((table-overlays
             (cl-remove-if-not
              (lambda (overlay)
                (eq (overlay-get overlay 'pichat-markdown-kind) 'table))
              (overlays-in (point-min) (point-max)))))
        (should (= 4 (length table-overlays)))
        (should (cl-every (lambda (overlay)
                            (>= (overlay-start overlay) table-start))
                          table-overlays))))))

(ert-deftest pichat-markdown-table-renders-toggles-and-preserves-source ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 2)
    (insert (propertize "| A | B |\n|---|---|\n| x | y |"
                        'pichat-prose t 'pichat-node-key "table-node"))
    (let ((original (buffer-substring-no-properties (point-min) (point-max)))
          (layout-calls 0)
          (allocator (symbol-function 'pichat-markdown-table-make-layout)))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-width-policy)
                 (lambda (&optional _window) '(40 . 40)))
                ((symbol-function 'pichat-markdown-table-make-layout)
                 (lambda (&rest arguments)
                   (cl-incf layout-calls)
                   (apply allocator arguments))))
        (pichat-markdown-presentation-refresh-buffer)
        (goto-char (point-min))
        (let ((overlay (pichat-markdown-presentation--overlay-at-point 'table)))
          (should overlay)
          (should (eq 'rendered (overlay-get overlay 'pichat-markdown-state))))
        (should (seq-some
                 (lambda (overlay)
                   (string-match-p
                    "│ A +│ B +│"
                    (substring-no-properties
                     (or (overlay-get overlay 'before-string) ""))))
                 (overlays-in (point-min) (point-max))))
        (pichat-chat-toggle-table-at-point)
        (should (equal original
                       (buffer-substring-no-properties
                        (point-min) (point-max))))
        (should-not
         (seq-some (lambda (overlay) (overlay-get overlay 'before-string))
                   (overlays-in (point-min) (point-max))))
        (pichat-chat-toggle-table-at-point)
        (should (seq-some
                 (lambda (overlay) (overlay-get overlay 'before-string))
                 (overlays-in (point-min) (point-max))))
        (should (= 1 layout-calls))))))

(ert-deftest pichat-markdown-width-refresh-preserves-link-and-parsed-model ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 2)
    (insert (propertize
             "| A |\n|---|\n| x |\n\n[source](https://example.test)"
             'pichat-prose t 'pichat-node-key "node"))
    (let ((layout-calls 0)
          (target-width 50)
          (allocator (symbol-function 'pichat-markdown-table-make-layout))
          (parser (symbol-function 'pichat-markdown-table-parse))
          (parse-calls 0)
          (link-start (save-excursion
                        (goto-char (point-min))
                        (search-forward "[source]")
                        (match-beginning 0))))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-width-policy)
                 (lambda (&optional _window)
                   (cons 100 target-width)))
                ((symbol-function 'pichat-markdown-table-make-layout)
                 (lambda (&rest arguments)
                   (cl-incf layout-calls)
                   (apply allocator arguments)))
                ((symbol-function 'pichat-markdown-table-parse)
                 (lambda (&rest arguments)
                   (cl-incf parse-calls)
                   (apply parser arguments)))
                ((symbol-function 'pichat-markdown-presentation--extract-links)
                 (lambda (_beg _end)
                   (list (pichat-test--markdown-link-record
                          link-start "https://example.test" "source")))))
        (pichat-markdown-presentation-refresh-buffer)
        (goto-char link-start)
        (let ((link-overlay
               (pichat-markdown-presentation--overlay-at-point 'link)))
          (setq target-width 37)
          (pichat-markdown-presentation-refresh-rendered-tables)
          (should (= 2 layout-calls))
          (should (= 1 parse-calls))
          (should (overlay-buffer link-overlay))
          (goto-char link-start)
          (should (eq link-overlay
                      (pichat-markdown-presentation--overlay-at-point
                       'link))))))))

(ert-deftest pichat-markdown-table-layout-cache-evicts-incrementally ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 3)
    (insert (propertize
             (concat "| A |\n|---|\n| first |\n\n"
                     "between\n\n"
                     "| B |\n|---|\n| second |")
             'pichat-prose t 'pichat-node-key "two-tables"))
    (let ((pichat-chat-table-layout-cache-max-entries 3)
          (target-width 40)
          (layout-calls 0)
          (allocator (symbol-function 'pichat-markdown-table-make-layout)))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-width-policy)
                 (lambda (&optional _window)
                   (cons target-width target-width)))
                ((symbol-function 'pichat-markdown-table-make-layout)
                 (lambda (&rest arguments)
                   (cl-incf layout-calls)
                   (apply allocator arguments))))
        (pichat-markdown-presentation-refresh-buffer)
        (setq target-width 30)
        (pichat-markdown-presentation-refresh-rendered-tables)
        (should (= 4 layout-calls))
        (should (= 3 (hash-table-count
                      pichat-markdown-presentation--table-layout-cache)))
        ;; Both layouts for the current width survive incremental eviction.
        (pichat-markdown-presentation-refresh-buffer)
        (should (= 4 layout-calls))
        (should (= 3 (length
                      pichat-markdown-presentation--table-layout-cache-order)))
        (pichat-markdown-presentation-reset-source)
        (should (= 0 (hash-table-count
                      pichat-markdown-presentation--table-layout-cache)))
        (should-not pichat-markdown-presentation--table-layout-cache-order)))))

(ert-deftest pichat-markdown-narrow-table-fallback-renders-after-widening ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 4)
    (insert (propertize "| A | B |\n|---|---|\n| x | y |"
                        'pichat-prose t 'pichat-node-key "node"))
    (let ((target 8))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-width-policy)
                 (lambda (&optional _window) (cons target target))))
        (pichat-markdown-presentation-refresh-buffer)
        (should-not
         (seq-some (lambda (overlay) (overlay-get overlay 'before-string))
                   (overlays-in (point-min) (point-max))))
        (goto-char (point-min))
        (should (eq 'rendered
                    (overlay-get
                     (pichat-markdown-presentation--overlay-at-point 'table)
                     'pichat-markdown-state)))
        (setq target 40)
        (pichat-markdown-presentation-refresh-rendered-tables)
        (should (seq-some
                 (lambda (overlay) (overlay-get overlay 'before-string))
                 (overlays-in (point-min) (point-max))))))))

(ert-deftest pichat-markdown-table-failure-is-isolated-from-other-tables ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 4)
    (insert (propertize
             (concat "| Broken |\n|---|\n| one |\n\n"
                     "between\n\n"
                     "| Working |\n|---|\n| two |")
             'pichat-prose t 'pichat-node-key "node"))
    (let ((allocator (symbol-function 'pichat-markdown-table-make-layout)))
      (cl-letf (((symbol-function 'pichat-markdown-table-make-layout)
                 (lambda (table &rest arguments)
                   (if (equal "Broken"
                              (pichat-markdown-table-cell-display
                               (car (pichat-markdown-table-row-cells
                                     (car (pichat-markdown-table-rows table))))))
                       (error "first table failed")
                     (apply allocator table arguments))))
                ((symbol-function 'display-warning) #'ignore))
        (pichat-markdown-presentation-refresh-buffer))
      (let ((metadata
             (cl-remove-if-not
              (lambda (overlay)
                (and (eq (overlay-get overlay 'pichat-markdown-kind) 'table)
                     (overlay-get overlay 'pichat-markdown-metadata)))
              (overlays-in (point-min) (point-max)))))
        (should (= 2 (length metadata)))
        (should (memq 'source
                      (mapcar (lambda (overlay)
                                (overlay-get overlay 'pichat-markdown-state))
                              metadata)))
        (should (seq-some
                 (lambda (overlay)
                   (string-match-p "Working"
                                   (substring-no-properties
                                    (or (overlay-get overlay 'before-string)
                                        ""))))
                 (overlays-in (point-min) (point-max))))))))

(ert-deftest pichat-markdown-presentation-failure-leaves-raw-source ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 4)
    (insert (propertize "| A |\n|---|\n| x |"
                        'pichat-prose t 'pichat-node-key "node"))
    (let ((source (buffer-substring-no-properties (point-min) (point-max)))
          (row-calls 0)
          (row-renderer
           (symbol-function
            'pichat-markdown-presentation--table-row-overlay)))
      (cl-letf (((symbol-function
                  'pichat-markdown-presentation--table-row-overlay)
                 (lambda (&rest arguments)
                   (cl-incf row-calls)
                   (if (= row-calls 2)
                       (error "forced partial overlay failure")
                     (apply row-renderer arguments))))
                ((symbol-function 'display-warning) #'ignore))
        (pichat-markdown-presentation-refresh-buffer)
        (should (equal source
                       (buffer-substring-no-properties
                        (point-min) (point-max))))
        (should-not
         (seq-some (lambda (overlay) (overlay-get overlay 'before-string))
                   (overlays-in (point-min) (point-max))))
        (goto-char (point-min))
        (should (eq 'source
                    (overlay-get
                     (pichat-markdown-presentation--overlay-at-point 'table)
                     'pichat-markdown-state)))))))

(ert-deftest pichat-markdown-pichat-renderer-never-requires-shell-maker ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize "| A | B |\n|---|---|\n| x | y |"
                        'pichat-prose t 'pichat-node-key "node"))
    (let ((original-require (symbol-function 'require))
          (shell-requires 0))
      (cl-letf (((symbol-function 'require)
                 (lambda (feature &optional filename noerror)
                   (if (memq feature
                             '(shell-maker markdown-overlays
                               markdown-overlays-tables))
                       (progn
                         (cl-incf shell-requires)
                         (error "PiChat attempted to load Shell Maker"))
                     (funcall original-require feature filename noerror)))))
        (pichat-markdown-presentation-refresh-buffer))
      (should (= 0 shell-requires)))
    (should (= 3 (cl-count-if
                  (lambda (overlay) (overlay-get overlay 'before-string))
                  (overlays-in (point-min) (point-max)))))
    (should-not
     (seq-some
      (lambda (overlay)
        (or (overlay-get overlay 'markdown-overlays-tables)
            (eq (overlay-get overlay 'category) 'markdown-overlays)))
      (overlays-in (point-min) (point-max))))
    (should (seq-some
             (lambda (overlay)
               (string-match-p "│" (or (overlay-get overlay 'before-string) "")))
             (overlays-in (point-min) (point-max))))))

(ert-deftest pichat-markdown-real-table-parser-ignores-fenced-code ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 1)
    (insert (propertize
             (concat "```\n| A | B |\n|---|---|\n| x | y |\n```\n")
             'pichat-prose t 'pichat-node-key "node"))
    (pichat-markdown-presentation-refresh-buffer)
    (should-not (seq-some
                 (lambda (overlay)
                   (eq (overlay-get overlay 'pichat-markdown-kind) 'table))
                 (overlays-in (point-min) (point-max))))))

(ert-deftest pichat-markdown-source-reset-clears-overlays-and-explicit-state ()
  (with-temp-buffer
    (insert "source")
    (pichat-markdown-presentation--ensure-state)
    (puthash '(1 node link 1 hash) 'source
             pichat-markdown-presentation--states)
    (pichat-markdown-presentation--metadata-overlay
     (point-min) (point-max) 'link '(1 node link 1 hash) 'source)
    (pichat-markdown-presentation-reset-source)
    (should (= 0 (hash-table-count pichat-markdown-presentation--states)))
    (should-not (seq-some #'pichat-markdown-presentation--owned-p
                          (overlays-in (point-min) (point-max))))))

(ert-deftest pichat-chat-canonical-presentation-survives-projection-rollback ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function 'pichat-markdown-presentation--extract-links)
                       (lambda (beg _end)
                         (list (pichat-test--markdown-link-record beg)))))
              (with-current-buffer buffer
                (let* ((transcript
                        (pichat-transcript-create
                         :nodes
                         (list
                          (pichat-transcript-node-create
                           :kind 'message :key "node" :role 'assistant
                           :content
                           (list (pichat-transcript-content-create
                                  :kind 'prose :index 0
                                  :text "[source](https://example.test/path)"))))
                         :diagnostics nil :metadata nil))
                       (context (pichat-chat--canonical-render-context transcript))
                       (fragment (pichat-render-canonical transcript context)))
                  (pichat-chat--project-canonical nil transcript fragment context)
                  (goto-char (marker-position pichat-chat--canonical-start))
                  (should (pichat-markdown-presentation--overlay-at-point 'link))
                  (should-error
                   (pichat-chat--with-projection-rollback
                     (pichat-chat--with-buffer-edit (erase-buffer))
                     (error "forced rollback")))
                  (goto-char (marker-position pichat-chat--canonical-start))
                  (should (pichat-markdown-presentation--overlay-at-point 'link))
                  (should (string-match-p
                           (regexp-quote "[source](https://example.test/path)")
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-table-presentation-survives-projection-rollback ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (source "| A | B |\n|---|---|\n| x | y |")
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-transcript-node-create
                         :kind 'message :key "node" :role 'assistant
                         :content
                         (list (pichat-transcript-content-create
                                :kind 'prose :index 0 :text source))))
                       :diagnostics nil :metadata nil))
                     (context
                      (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context)
                (should (seq-some
                         (lambda (overlay)
                           (overlay-get overlay 'before-string))
                         (overlays-in (point-min) (point-max))))
                (should-error
                 (pichat-chat--with-projection-rollback
                   (pichat-chat--with-buffer-edit (erase-buffer))
                   (error "forced rollback")))
                (should (string-match-p
                         (regexp-quote source)
                         (buffer-substring-no-properties
                          (point-min) (point-max))))
                (should (seq-some
                         (lambda (overlay)
                           (overlay-get overlay 'before-string))
                         (overlays-in (point-min) (point-max)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-presentation-waits-for-final-message ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer refreshes)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function
                        'pichat-markdown-presentation-refresh-region)
                       (lambda (beg end) (push (cons beg end) refreshes))))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"[partial](https://example.test)\"}]}}\n")
              (with-current-buffer buffer (pichat-chat--flush-live-projection))
              (should-not refreshes)
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"[final](https://example.test)\"}]}}\n")
              (should (= 1 (length refreshes)))
              (with-current-buffer buffer
                (should (equal (car refreshes)
                               (cons (marker-position pichat-chat--live-start)
                                     (marker-position pichat-chat--live-end)))))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(provide 'pichat-test-markdown-presentation)
;;; pichat-test-markdown-presentation.el ends here
