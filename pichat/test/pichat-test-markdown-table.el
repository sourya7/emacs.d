;;; pichat-test-markdown-table.el --- PiChat Markdown table parser tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the position-independent Markdown pipe-table model.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-markdown-table)

(defun pichat-test-markdown-table--one (source &optional excluded-ranges)
  "Return the one table parsed from SOURCE outside EXCLUDED-RANGES."
  (let ((tables (pichat-markdown-table-parse source excluded-ranges)))
    (should (= 1 (length tables)))
    (car tables)))

(defun pichat-test-markdown-table--fixture ()
  "Return the Phase 0 wide Markdown table fixture."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "wide-markdown-table.md"
                       pichat-test-fixture-directory))
    (buffer-string)))

(ert-deftest pichat-markdown-table-parses-relative-ranges-and-alignments ()
  (let* ((source
          (concat "Before\n"
                  "| Name | Value | Status |\n"
                  "|:---|---:|:---:|\n"
                  "| item | 42 | ready |\n"
                  "After"))
         (table (pichat-test-markdown-table--one source))
         (rows (pichat-markdown-table-rows table))
         (header (car rows))
         (data (nth 2 rows)))
    (should (= (length "Before\n") (pichat-markdown-table-start table)))
    (should (= (string-match "\nAfter" source)
               (pichat-markdown-table-end table)))
    (should (= 3 (pichat-markdown-table-column-count table)))
    (should (equal '(left right center)
                   (pichat-markdown-table-alignments table)))
    (should (equal '(header delimiter data)
                   (mapcar #'pichat-markdown-table-row-kind rows)))
    (should (equal '("Name" "Value" "Status")
                   (mapcar #'pichat-markdown-table-cell-source
                           (pichat-markdown-table-row-cells header))))
    (should (equal '("item" "42" "ready")
                   (mapcar #'pichat-markdown-table-cell-display
                           (pichat-markdown-table-row-cells data))))
    (should
     (equal (secure-hash
             'sha1
             (substring source
                        (pichat-markdown-table-start table)
                        (pichat-markdown-table-end table)))
            (pichat-markdown-table-source-digest table)))))

(ert-deftest pichat-markdown-table-parses-rows-without-outer-pipes ()
  (let* ((source
          "Name | Value | State\n:--- | ---: | :---:\nfirst | 9 | ok")
         (table (pichat-test-markdown-table--one source)))
    (should (= 3 (pichat-markdown-table-column-count table)))
    (should (equal '(left right center)
                   (pichat-markdown-table-alignments table)))
    (should (equal '("first" "9" "ok")
                   (mapcar
                    #'pichat-markdown-table-cell-source
                    (pichat-markdown-table-row-cells
                     (nth 2 (pichat-markdown-table-rows table))))))))

(ert-deftest pichat-markdown-table-allows-one-sided-outer-pipes ()
  (dolist (source '("| A | B\n|---|---\n| x | y"
                    "A | B |\n---|---|\nx | y |"))
    (let ((table (pichat-test-markdown-table--one source)))
      (should (= 2 (pichat-markdown-table-column-count table)))
      (should (= 3 (length (pichat-markdown-table-rows table)))))))

(ert-deftest pichat-markdown-table-keeps-escaped-and-code-span-pipes-in-cells ()
  (let* ((source
          (concat "| Expression | Escaped | Long code |\n"
                  "|---|---|---|\n"
                  "| `alpha|beta` | left \\| right | ``value ` with | pipe`` |"))
         (table (pichat-test-markdown-table--one source))
         (cells (pichat-markdown-table-row-cells
                 (nth 2 (pichat-markdown-table-rows table)))))
    (should (= 3 (length cells)))
    (should (equal "`alpha|beta`"
                   (pichat-markdown-table-cell-source (nth 0 cells))))
    (should (equal "left \\| right"
                   (pichat-markdown-table-cell-source (nth 1 cells))))
    (should (equal "left | right"
                   (pichat-markdown-table-cell-display (nth 1 cells))))
    (should (equal "``value ` with | pipe``"
                   (pichat-markdown-table-cell-source (nth 2 cells))))))

(ert-deftest pichat-markdown-table-does-not-open-code-at-escaped-backtick ()
  (let* ((source
          "| Text | Value |\n|---|---|\n| escaped \\` tick | complete |")
         (table (pichat-test-markdown-table--one source))
         (cells (pichat-markdown-table-row-cells
                 (nth 2 (pichat-markdown-table-rows table)))))
    (should (= 2 (length cells)))
    (should (equal "escaped \\` tick"
                   (pichat-markdown-table-cell-source (car cells))))))

(ert-deftest pichat-markdown-table-pads-ragged-semantic-rows ()
  (let* ((source
          (concat "| A | B |\n"
                  "|---|---:|\n"
                  "| only-one |\n"
                  "| x | y | z |\n"
                  "| | value | |"))
         (table (pichat-test-markdown-table--one source))
         (rows (pichat-markdown-table-rows table)))
    (should (= 3 (pichat-markdown-table-column-count table)))
    (should (equal '(left right left)
                   (pichat-markdown-table-alignments table)))
    (dolist (row (cons (car rows) (cddr rows)))
      (should (= 3 (length (pichat-markdown-table-row-cells row)))))
    (should (equal '("only-one" "" "")
                   (mapcar
                    #'pichat-markdown-table-cell-source
                    (pichat-markdown-table-row-cells (nth 2 rows)))))
    (should (equal '("" "value" "")
                   (mapcar
                    #'pichat-markdown-table-cell-display
                    (pichat-markdown-table-row-cells (nth 4 rows)))))))

(ert-deftest pichat-markdown-table-recognizes-header-and-delimiter-only ()
  (let ((table
         (pichat-test-markdown-table--one "| Header |\n|---|")))
    (should (= 1 (pichat-markdown-table-column-count table)))
    (should (equal '(header delimiter)
                   (mapcar #'pichat-markdown-table-row-kind
                           (pichat-markdown-table-rows table))))))

(ert-deftest pichat-markdown-table-excludes-fenced-fixture-range ()
  (let* ((source (pichat-test-markdown-table--fixture))
         (fence-start (string-match "```markdown" source))
         (without-exclusion (pichat-markdown-table-parse source))
         (tables (pichat-markdown-table-parse
                  source (list (cons fence-start (length source)))))
         (table (car tables)))
    (should (= 2 (length without-exclusion)))
    (should (= 1 (length tables)))
    (should (= 12 (pichat-markdown-table-column-count table)))
    (should (= 7 (length (pichat-markdown-table-rows table))))
    (should (equal '(left right left center left left left left left
                         center right left)
                   (pichat-markdown-table-alignments table)))
    (let* ((data (nth 2 (pichat-markdown-table-rows table)))
           (cells (pichat-markdown-table-row-cells data)))
      (should (equal "left | right"
                     (pichat-markdown-table-cell-display (nth 7 cells))))
      (should (equal "`alpha|beta`"
                     (pichat-markdown-table-cell-source (nth 8 cells)))))))

(ert-deftest pichat-markdown-table-finds-multiple-separated-tables ()
  (let* ((first "| A |\n|---|\n| one |")
         (second "| B | C |\n|---|---|\n| two | three |")
         (source (concat first "\n\nprose\n\n" second))
         (tables (pichat-markdown-table-parse source)))
    (should (= 2 (length tables)))
    (should (= 0 (pichat-markdown-table-start (car tables))))
    (should (= (length first) (pichat-markdown-table-end (car tables))))
    (should (= (string-match (regexp-quote second) source)
               (pichat-markdown-table-start (cadr tables))))))

(ert-deftest pichat-markdown-table-allows-three-leading-spaces ()
  (let* ((source "   | A |\n   |---|\n   | value |")
         (table (pichat-test-markdown-table--one source)))
    (should
     (cl-every (lambda (row)
                 (equal "   "
                        (pichat-markdown-table-row-leading-prefix row)))
               (pichat-markdown-table-rows table)))))

(ert-deftest pichat-markdown-table-rejects-malformed-or-ambiguous-candidates ()
  (dolist (source
           '("| A | B |\n|--|---|\n| x | y |"
             "| A | B |\n|---|\n| x | y |"
             "| A | B |\n---|---\n| x | y |"
             "    | A | B |\n    |---|---|\n    | x | y |"
             "| `unterminated | B |\n|---|---|\n| x | y |"
             "| merely | one | row |"))
    (should-not (pichat-markdown-table-parse source))))

(ert-deftest pichat-markdown-table-data-row-with-unterminated-code-stops-table ()
  (let* ((source
          "| A | B |\n|---|---|\n| good | row |\n| `bad | row |\nafter")
         (table (pichat-test-markdown-table--one source)))
    (should (= 3 (length (pichat-markdown-table-rows table))))
    (should (= (string-match "\n| `bad" source)
               (pichat-markdown-table-end table)))))

(ert-deftest pichat-markdown-table-large-input-keeps-model-work-bounded ()
  (let* ((source
          (concat "| Item | Value |\n|---|---|\n"
                  (mapconcat
                   (lambda (index)
                     (format "| row-%d | value-%d |" index index))
                   (number-sequence 1 1000) "\n")))
         (table (pichat-test-markdown-table--one source)))
    (should (= 1002 (length (pichat-markdown-table-rows table))))
    (should (= 2 (pichat-markdown-table-column-count table)))
    (should (= (length source) (pichat-markdown-table-end table)))))

(ert-deftest pichat-markdown-parsed-run-caches-relative-table-records ()
  (with-temp-buffer
    (setq-local pichat-chat--source-generation 7)
    (insert "prefix outside run\n")
    (let ((beg (point))
          (source "| A | B |\n|---|---|\n| x | y |")
          (parse-calls 0)
          (original (symbol-function 'pichat-markdown-table-parse)))
      (insert source)
      (cl-letf (((symbol-function 'pichat-markdown-table-parse)
                 (lambda (&rest arguments)
                   (cl-incf parse-calls)
                   (apply original arguments))))
        (let* ((first (pichat-markdown-presentation-parse-run beg (point-max)))
               (second (pichat-markdown-presentation-parse-run beg (point-max)))
               (table (car (pichat-markdown-parsed-run-tables first))))
          (should (eq first second))
          (should (= 1 parse-calls))
          (should (= 0 (pichat-markdown-table-start table)))
          (should (= (length source) (pichat-markdown-table-end table))))))))

(ert-deftest pichat-markdown-parsed-run-builds-tables-without-markdown-mode ()
  (let* ((source
          (concat "```markdown\n| fake |\n|---|\n```\n\n"
                  "| Real |\n|---|\n| value |"))
         (digest (secure-hash 'sha1 source))
         (original-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'markdown-mode)
                     nil
                   (funcall original-require feature filename noerror)))))
      (let* ((parsed
              (pichat-markdown-presentation--parse-source source digest))
             (tables (pichat-markdown-parsed-run-tables parsed)))
        (should (= 1 (length tables)))
        (should (= (string-match (regexp-quote "| Real |") source)
                   (pichat-markdown-table-start (car tables))))))))

(ert-deftest pichat-markdown-parsed-run-builds-tables-with-markdown-mode ()
  (skip-unless (require 'markdown-mode nil t))
  (let* ((source "| A | B |\n|---|---|\n| x | y |")
         (parsed (pichat-markdown-presentation--parse-source
                  source (secure-hash 'sha1 source))))
    (should (= 1 (length (pichat-markdown-parsed-run-tables parsed))))
    (should (pichat-markdown-parsed-run-face-runs parsed))))

(defun pichat-test-markdown-table--layout-texts
    (source width &optional rows columns unicode minimum)
  "Return layout texts for SOURCE under the requested bounded policy."
  (let* ((table (pichat-test-markdown-table--one source))
         (layout (pichat-markdown-table-make-layout
                  table width rows columns unicode minimum)))
    (should layout)
    (mapcar #'pichat-markdown-table-layout-row-text
            (pichat-markdown-table-layout-rows layout))))

(ert-deftest pichat-markdown-table-layout-bounds-single-line-rows ()
  (let* ((source
          (concat "| Name | Description | Score |\n"
                  "|:---|:---:|---:|\n"
                  "| tiny | abcdefghijklmnopqrstuvwxyz | 99 |\n"
                  "| x | y | 2 |"))
         (texts (pichat-test-markdown-table--layout-texts
                 source 40 40 12 t 3)))
    (should (= 4 (length texts)))
    (dolist (text texts)
      (should-not (string-match-p "\n" text))
      (should (<= (string-width text) 40)))
    (should (equal
             '("│ Name │      Description      │ Score │"
               "├------┼-----------------------┼-------┤"
               "│ tiny │ abcdefghijklmnopqrst… │    99 │"
               "│ x    │           y           │     2 │")
             (mapcar #'substring-no-properties texts)))))

(ert-deftest pichat-markdown-table-layout-styles-header-and-borders ()
  (let* ((texts (pichat-test-markdown-table--layout-texts
                 "| Header |\n|---|\n| value |" 30 40 12 t 3))
         (header (car texts)))
    (should (eq 'shadow (get-text-property 0 'face header)))
    (should (eq 'bold (get-text-property 2 'face header)))))

(ert-deftest pichat-markdown-table-layout-preserves-short-columns-fairly ()
  (let* ((source
          (concat "| ID | Description | State |\n"
                  "|---|---|---|\n"
                  "| 7 | a-very-long-description-that-needs-space | ok |"))
         (texts (pichat-test-markdown-table--layout-texts
                 source 32 40 12 t 3))
         (header (substring-no-properties (car texts)))
         (data (substring-no-properties (nth 2 texts))))
    (should (string-match-p "ID" header))
    (should (string-match-p "State" header))
    (should (string-match-p "│ 7 " data))
    (should (string-match-p " ok " data))
    (should (string-match-p "…" data))))

(ert-deftest pichat-markdown-table-layout-omits-columns-with-explicit-count ()
  (let* ((source
          (concat "| A | B | C | D | E | F |\n"
                  "|---|---|---|---|---|---|\n"
                  "| alpha | bravo | charlie | delta | echo | foxtrot |"))
         (table (pichat-test-markdown-table--one source))
         (layout (pichat-markdown-table-make-layout table 34 40 12 t 3))
         (texts (mapcar #'pichat-markdown-table-layout-row-text
                        (pichat-markdown-table-layout-rows layout))))
    (should layout)
    (should (> (pichat-markdown-table-layout-omitted-column-count layout) 0))
    (should (string-match-p
             (regexp-quote
              (format "… +%d columns"
                      (pichat-markdown-table-layout-omitted-column-count layout)))
             (substring-no-properties (car texts))))
    (should (cl-every (lambda (text) (<= (string-width text) 34)) texts))))

(ert-deftest pichat-markdown-table-layout-omits-rows-with-explicit-count ()
  (let* ((source
          (concat "| Item | Value |\n|---|---|\n"
                  (mapconcat
                   (lambda (index) (format "| row-%d | value-%d |" index index))
                   (number-sequence 1 10) "\n")))
         (table (pichat-test-markdown-table--one source))
         (layout (pichat-markdown-table-make-layout table 50 3 12 t 3))
         (rows (pichat-markdown-table-layout-rows layout)))
    (should (= 7 (pichat-markdown-table-layout-omitted-row-count layout)))
    (should (= 6 (length rows)))
    (should (equal 'omitted
                   (pichat-markdown-table-layout-row-kind (car (last rows)))))
    (should (string-match-p "… 7 more rows"
                            (substring-no-properties
                             (pichat-markdown-table-layout-row-text
                              (car (last rows))))))))

(ert-deftest pichat-markdown-table-layout-fails-open-at-narrow-width ()
  (let ((table (pichat-test-markdown-table--one
                "| A | B |\n|---|---|\n| x | y |")))
    (should-not (pichat-markdown-table-make-layout table 8 40 12 t 3))
    (should-not (pichat-markdown-table-make-layout table 4 40 12 t 3))))

(ert-deftest pichat-markdown-table-layout-bounds-large-table-operations ()
  (let* ((source
          (concat "| A | B | C | D | E |\n|---|---|---|---|---|\n"
                  (mapconcat
                   (lambda (index)
                     (format "| a%d | b%d | c%d | d%d | e%d |"
                             index index index index index))
                   (number-sequence 1 1000) "\n")))
         (table (pichat-test-markdown-table--one source))
         (calls 0)
         (original (symbol-function 'pichat-markdown-table-cell-display)))
    (cl-letf (((symbol-function 'pichat-markdown-table-cell-display)
               (lambda (cell)
                 (cl-incf calls)
                 (funcall original cell))))
      (let ((layout (pichat-markdown-table-make-layout
                     table 50 2 3 t 3)))
        (should layout)
        (should (= 998
                   (pichat-markdown-table-layout-omitted-row-count layout)))
        (should (< calls 30))))))

(ert-deftest pichat-markdown-table-layout-handles-unicode-empty-and-indentation ()
  (let* ((source
          (concat "   | 名称 | Empty | Emoji |\n"
                  "   |:---|:---:|---:|\n"
                  "   | 東京 | | 👩🏽‍💻-value-that-is-long |"))
         (texts (pichat-test-markdown-table--layout-texts
                 source 42 40 12 nil 2)))
    (dolist (text texts)
      (should (string-prefix-p "   " (substring-no-properties text)))
      (should (<= (string-width text) 42)))
    (should (seq-some (lambda (text)
                        (string-match-p "…" (substring-no-properties text)))
                      texts))))

(provide 'pichat-test-markdown-table)
;;; pichat-test-markdown-table.el ends here
