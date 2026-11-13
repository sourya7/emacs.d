;;; test-overlap.el --- Per-test coverage and overlap report -*- lexical-binding: t; -*-

;;; Commentary:

;; Tooling for `run-test-overlap.sh'.  Three independent parts:
;;
;; - Collection, in an Undercover-instrumented suite run: reset every Edebug
;;   frequency counter before each test and record afterwards which stop
;;   points ("forms") the test executed.  Load-time execution is therefore
;;   not attributed to any test.
;; - Analysis, in a plain Emacs: read the records and write a Markdown report
;;   of tests whose forms are all executed by other tests, plus a TSV with one
;;   row per test.
;; - Coupling counts, read statically from the test files: references to
;;   private source symbols, `symbol-function' stubs and assertions containing
;;   a string literal.
;;
;; Per-test coverage only nominates candidates.  A test whose forms are all
;; executed elsewhere can still be the only test asserting an outcome; never
;; delete a test on this data alone.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'ert)

(defvar undercover--files)
(defvar edebug-form-data)

(defconst pichat-test-overlap--test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the PiChat test tooling.")

(defconst pichat-test-overlap--format-version 1
  "Version of the per-test record files.")

;;;; Collection

(defvar pichat-test-overlap--symbols nil
  "Instrumented symbols as a list of (SYMBOL . FILE).")

(defvar pichat-test-overlap--symbols-file-count -1
  "Number of instrumented files when `pichat-test-overlap--symbols' was built.")

(defvar pichat-test-overlap--form-ids nil
  "Hash table mapping (SYMBOL . INDEX) to a form ID.")

(defvar pichat-test-overlap--forms nil
  "Forms in ID order (reversed while collecting): (ID FILE SYMBOL INDEX).")

(defvar pichat-test-overlap--records nil
  "Per-test records, newest first: (NAME TEST-FILE RESULT IDS).")

(defun pichat-test-overlap--refresh-symbols ()
  "Rebuild the instrumented symbol list when Undercover loaded more files.
A symbol whose Edebug data belongs to another file's buffer was redefined
there; it is attributed only to the file that owns its stop points."
  (unless (= (length undercover--files) pichat-test-overlap--symbols-file-count)
    (let (symbols)
      (dolist (file undercover--files)
        (let ((buffer (find-buffer-visiting file)))
          (when buffer
            (with-current-buffer buffer
              (dolist (entry edebug-form-data)
                (let* ((symbol (car entry))
                       (start (car-safe (get symbol 'edebug))))
                  (when (and (markerp start)
                             (eq (marker-buffer start) buffer)
                             (vectorp (get symbol 'edebug-freq-count)))
                    (push (cons symbol file) symbols))))))))
      (setq pichat-test-overlap--symbols (delete-dups (nreverse symbols))
            pichat-test-overlap--symbols-file-count (length undercover--files)))))

(defun pichat-test-overlap--reset-counters ()
  "Set every instrumented frequency counter to zero, in place.
Edebug reads the vector from the symbol when a function is entered, so
in-place resets also reach functions that are running already."
  (pichat-test-overlap--refresh-symbols)
  (dolist (entry pichat-test-overlap--symbols)
    (let ((counts (get (car entry) 'edebug-freq-count)))
      (when (vectorp counts) (fillarray counts 0)))))

(defun pichat-test-overlap--form-id (symbol index file)
  "Return the form ID of stop point INDEX of SYMBOL defined in FILE."
  (let ((key (cons symbol index)))
    (or (gethash key pichat-test-overlap--form-ids)
        (let ((id (hash-table-count pichat-test-overlap--form-ids)))
          (puthash key id pichat-test-overlap--form-ids)
          (push (list id file symbol index) pichat-test-overlap--forms)
          id))))

(defun pichat-test-overlap--executed-forms ()
  "Return a sorted vector of form IDs whose counters are nonzero."
  (pichat-test-overlap--refresh-symbols)
  (let (ids)
    (dolist (entry pichat-test-overlap--symbols)
      (let ((counts (get (car entry) 'edebug-freq-count)))
        (when (vectorp counts)
          (dotimes (index (length counts))
            (unless (zerop (aref counts index))
              (push (pichat-test-overlap--form-id (car entry) index (cdr entry))
                    ids))))))
    (vconcat (sort ids #'<))))

(defun pichat-test-overlap--result-type (test)
  "Return the most recent result type of TEST as a symbol."
  (let ((result (ert-test-most-recent-result test)))
    (cond ((ert-test-passed-p result) 'passed)
          ((ert-test-skipped-p result) 'skipped)
          ((ert-test-result-expected-p test result) 'expected)
          (t 'failed))))

(defun pichat-test-overlap--run-test (original test)
  "Run TEST through ORIGINAL and record the forms it executed."
  (pichat-test-overlap--reset-counters)
  (unwind-protect (funcall original test)
    (push (list (ert-test-name test)
                (and (ert-test-file-name test)
                     (file-name-nondirectory (ert-test-file-name test)))
                (pichat-test-overlap--result-type test)
                (pichat-test-overlap--executed-forms))
          pichat-test-overlap--records)))

(defun pichat-test-overlap--form-line (symbol index)
  "Return the source line of stop point INDEX of SYMBOL, or nil."
  (let* ((data (get symbol 'edebug))
         (start (car-safe data))
         (offsets (nth 2 data)))
    (when (and (markerp start) (marker-buffer start)
               (vectorp offsets) (< index (length offsets)))
      (with-current-buffer (marker-buffer start)
        (line-number-at-pos (+ start (aref offsets index)))))))

(defun pichat-test-overlap--write-records (directory)
  "Write forms and per-test records under DIRECTORY."
  (make-directory directory t)
  (let ((print-length nil)
        (print-level nil)
        (print-escape-newlines t)
        (source-root (expand-file-name "../" pichat-test-overlap--test-directory)))
    (with-temp-file (expand-file-name "forms.eld" directory)
      (prin1 (list :version pichat-test-overlap--format-version) (current-buffer))
      (insert "\n")
      (dolist (form (reverse pichat-test-overlap--forms))
        (pcase-let ((`(,id ,file ,symbol ,index) form))
          (prin1 (list id (file-relative-name file source-root) symbol index
                       (pichat-test-overlap--form-line symbol index))
                 (current-buffer))
          (insert "\n"))))
    (with-temp-file (expand-file-name "tests.eld" directory)
      (prin1 (list :version pichat-test-overlap--format-version) (current-buffer))
      (insert "\n")
      (dolist (record (reverse pichat-test-overlap--records))
        (prin1 record (current-buffer))
        (insert "\n")))))

(defun pichat-test-overlap-collect (directory &optional selector)
  "Run tests matching SELECTOR with per-test coverage; write to DIRECTORY.
SELECTOR defaults to all tests.  Records are written even when tests fail,
but the function then signals an error so the run exits nonzero."
  (unless (and (boundp 'undercover--files) undercover--files)
    (error "No Undercover-instrumented files; call `pichat-coverage-enable' first"))
  (setq pichat-test-overlap--form-ids (make-hash-table :test #'equal)
        pichat-test-overlap--forms nil
        pichat-test-overlap--records nil
        pichat-test-overlap--symbols-file-count -1)
  (advice-add 'ert-run-test :around #'pichat-test-overlap--run-test)
  (let (stats)
    (unwind-protect
        (setq stats (ert-run-tests-batch (or selector t)))
      (advice-remove 'ert-run-test #'pichat-test-overlap--run-test)
      (pichat-test-overlap--write-records directory))
    (message "Per-test coverage: %d tests, %d forms, records in %s"
             (length pichat-test-overlap--records)
             (hash-table-count pichat-test-overlap--form-ids)
             directory)
    (unless (zerop (ert-stats-completed-unexpected stats))
      (error "Per-test coverage run had %d unexpected results"
             (ert-stats-completed-unexpected stats)))
    stats))

;;;; Reading records

(defun pichat-test-overlap--read-lines (file)
  "Return the header and the list of data forms read from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((header (read (current-buffer)))
          forms)
      (unless (equal (plist-get header :version)
                     pichat-test-overlap--format-version)
        (error "Unsupported record version in %s: %S" file header))
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(defun pichat-test-overlap-read (directory)
  "Return (FORMS . TESTS) read from the records in DIRECTORY.
FORMS is a vector indexed by form ID of (FILE SYMBOL INDEX LINE); TESTS is
a list of (NAME TEST-FILE RESULT IDS)."
  (let* ((form-lines (pichat-test-overlap--read-lines
                      (expand-file-name "forms.eld" directory)))
         (forms (make-vector (length form-lines) nil)))
    (dolist (form form-lines)
      (aset forms (car form) (cdr form)))
    (cons forms (pichat-test-overlap--read-lines
                 (expand-file-name "tests.eld" directory)))))

;;;; Analysis

(defun pichat-test-overlap-analyze-records (form-count tests)
  "Return per-test overlap data for TESTS over FORM-COUNT forms.
TESTS is a list of (NAME TEST-FILE RESULT IDS).  Only passed tests take part
in the comparison; others are returned with :result and no overlap data.
Each element is a plist with :name, :file, :result, :forms (count),
:unique (forms no other passed test executes), :contained (every form is
executed by some other passed test, and the test executes at least one)
and :containers (names of passed tests that execute every form of this
one, same test file first, then smallest; nil unless :contained)."
  (let* ((passed (seq-filter (lambda (test) (eq (nth 2 test) 'passed)) tests))
         (vectors (make-hash-table :test #'eq))
         (counts (make-vector form-count 0))
         results)
    (dolist (test passed)
      (let ((bits (make-bool-vector form-count nil)))
        (seq-doseq (id (nth 3 test))
          (aset bits id t)
          (cl-incf (aref counts id)))
        (puthash (car test) bits vectors)))
    (dolist (test tests)
      (pcase-let ((`(,name ,file ,result ,ids) test))
        (if (not (eq result 'passed))
            (push (list :name name :file file :result result
                        :forms (length ids))
                  results)
          (let* ((size (length ids))
                 (unique (seq-count (lambda (id) (= 1 (aref counts id))) ids))
                 (contained (and (> size 0) (zerop unique)))
                 (bits (gethash name vectors))
                 containers)
            (when contained
              (dolist (other passed)
                (let ((other-size (length (nth 3 other))))
                  (when (and (not (eq (car other) name))
                             (>= other-size size)
                             (bool-vector-subsetp bits (gethash (car other) vectors)))
                    (push (list (car other) (nth 1 other) other-size) containers))))
              (setq containers
                    (mapcar
                     #'car
                     (sort containers
                           (lambda (a b)
                             (let ((a-same (equal (nth 1 a) file))
                                   (b-same (equal (nth 1 b) file)))
                               (if (eq a-same b-same)
                                   (< (nth 2 a) (nth 2 b))
                                 a-same)))))))
            (push (list :name name :file file :result result :forms size
                        :unique unique :contained contained
                        :containers containers)
                  results)))))
    (nreverse results)))

;;;; Coupling counts

(defconst pichat-test-overlap--definers
  '(defun defmacro defsubst defvar defvar-local defconst defcustom
    cl-defun cl-defmacro cl-defsubst cl-defgeneric cl-defmethod define-inline
    defalias ert-deftest)
  "Forms whose second element names a definition.")

(defun pichat-test-overlap--file-forms (file)
  "Return all top-level forms read from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (forms)
      (condition-case nil
          (while t (push (read (current-buffer)) forms))
        (end-of-file nil))
      (nreverse forms))))

(defun pichat-test-overlap--walk (form function)
  "Call FUNCTION on FORM and every cons and atom inside it."
  (funcall function form)
  (cond ((consp form)
         (while (consp form)
           (pichat-test-overlap--walk (car form) function)
           (setq form (cdr form)))
         (when form (pichat-test-overlap--walk form function)))
        ((and (vectorp form) (not (stringp form)))
         (seq-doseq (element form)
           (pichat-test-overlap--walk element function)))))

(defun pichat-test-overlap--defined-symbols (files)
  "Return a hash table of symbols defined in FILES."
  (let ((defined (make-hash-table :test #'eq)))
    (dolist (file files)
      (dolist (form (pichat-test-overlap--file-forms file))
        (pichat-test-overlap--walk
         form
         (lambda (node)
           (when (and (consp node) (memq (car node) pichat-test-overlap--definers)
                      (consp (cdr node)))
             (let ((name (cadr node)))
               (when (eq (car-safe name) 'quote) (setq name (cadr name)))
               (when (symbolp name) (puthash name t defined))))))))
    defined))

(defun pichat-test-overlap--private-symbol-p (symbol test-defined)
  "Return non-nil if SYMBOL is a private PiChat source symbol.
Private symbols are named pichat...--...; symbols defined in the test files
\(TEST-DEFINED) are test helpers, not source details."
  (and (symbolp symbol)
       (not (gethash symbol test-defined))
       (let ((name (symbol-name symbol)))
         (and (string-prefix-p "pichat" name)
              (not (string-prefix-p "pichat-test" name))
              (string-search "--" name)))))

(defun pichat-test-overlap--string-inside-p (form)
  "Return non-nil if FORM contains a string literal."
  (catch 'found
    (pichat-test-overlap--walk form (lambda (node)
                                      (when (stringp node) (throw 'found t))))
    nil))

(defun pichat-test-overlap-coupling (test-file test-defined)
  "Return coupling counts for TEST-FILE as a plist.
TEST-DEFINED is a hash table of symbols defined by test files.  Keys:
:tests (ert-deftest forms), :lines, :private (references to private source
symbols, comments and strings excluded), :stubs (`symbol-function' forms)
and :string-assertions (`should' and `should-not' forms containing a string
literal)."
  (let ((tests 0) (private 0) (stubs 0) (strings 0))
    (dolist (form (pichat-test-overlap--file-forms test-file))
      (pichat-test-overlap--walk
       form
       (lambda (node)
         (cond ((consp node)
                (pcase (car node)
                  ('ert-deftest (cl-incf tests))
                  ('symbol-function (cl-incf stubs))
                  ((or 'should 'should-not)
                   (when (pichat-test-overlap--string-inside-p (cdr node))
                     (cl-incf strings)))))
               ((pichat-test-overlap--private-symbol-p node test-defined)
                (cl-incf private))))))
    (list :tests tests
          :lines (with-temp-buffer
                   (insert-file-contents test-file)
                   (count-lines (point-min) (point-max)))
          :private private :stubs stubs :string-assertions strings)))

(defun pichat-test-overlap--test-files ()
  "Return the PiChat test files."
  (directory-files pichat-test-overlap--test-directory t
                   "\\`pichat-test.*\\.el\\'"))

(defun pichat-test-overlap-coupling-table ()
  "Return ((FILE . COUNTS) ...) for every PiChat test file."
  (let* ((files (pichat-test-overlap--test-files))
         (defined (pichat-test-overlap--defined-symbols files)))
    (mapcar (lambda (file)
              (cons (file-name-nondirectory file)
                    (pichat-test-overlap-coupling file defined)))
            files)))

;;;; Report

(defun pichat-test-overlap--insert-coupling (table)
  "Insert the coupling TABLE as Markdown, most private references first."
  (insert "| Test file | Tests | Lines | Private refs | Stubs | String assertions |\n")
  (insert "|---|---:|---:|---:|---:|---:|\n")
  (let ((totals (list 0 0 0 0 0)))
    (dolist (row (sort (copy-sequence table)
                       (lambda (a b) (> (plist-get (cdr a) :private)
                                        (plist-get (cdr b) :private)))))
      (let* ((counts (cdr row))
             (values (mapcar (lambda (key) (plist-get counts key))
                             '(:tests :lines :private :stubs :string-assertions))))
        (setq totals (cl-mapcar #'+ totals values))
        (insert (apply #'format "| `%s` | %d | %d | %d | %d | %d |\n"
                       (car row) values))))
    (insert (apply #'format "| **Total** | %d | %d | %d | %d | %d |\n" totals))))

(defun pichat-test-overlap-write-coupling (output-file)
  "Write the coupling counts alone to OUTPUT-FILE as Markdown."
  (make-directory (file-name-directory (expand-file-name output-file)) t)
  (with-temp-file output-file
    (insert "# PiChat test coupling counts\n\n")
    (insert (format "Generated: `%s`\n\n"
                    (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)))
    (pichat-test-overlap--insert-coupling (pichat-test-overlap-coupling-table))
    (insert "\n")
    (pichat-test-overlap--insert-coupling-notes))
  output-file)

(defun pichat-test-overlap--insert-coupling-notes ()
  "Insert the definitions of the coupling counts."
  (insert "Counts come from the read forms of each file (comments excluded):\n\n")
  (insert "- Private refs: occurrences of symbols named `pichat…--…` (not `pichat-test…`) that no test file defines.\n")
  (insert "- Stubs: `(symbol-function …)` forms.\n")
  (insert "- String assertions: `should` / `should-not` forms containing a string literal.\n"))

(defun pichat-test-overlap--group-by-file (rows)
  "Return ((FILE . ROWS) ...) for ROWS, sorted by file name."
  (let (groups)
    (dolist (row rows)
      (let* ((file (or (plist-get row :file) "(unknown)"))
             (group (assoc file groups)))
        (if group (push row (cdr group)) (push (list file row) groups))))
    (sort (mapcar (lambda (group) (cons (car group) (nreverse (cdr group)))) groups)
          (lambda (a b) (string< (car a) (car b))))))

(defun pichat-test-overlap--containers-text (row)
  "Return the container list of ROW for the report."
  (let* ((containers (plist-get row :containers))
         (shown (seq-take containers 3))
         (more (- (length containers) (length shown))))
    (concat (mapconcat (lambda (name) (format "`%s`" name)) shown ", ")
            (if (> more 0) (format " (+%d more)" more) ""))))

(defun pichat-test-overlap--write-tsv (rows file)
  "Write one TSV line per test in ROWS to FILE."
  (with-temp-file file
    (insert "test\tfile\tresult\tforms\tunique\tcontained\tcontainers\tfirst_containers\n")
    (dolist (row rows)
      (insert (format "%s\t%s\t%s\t%d\t%s\t%s\t%d\t%s\n"
                      (plist-get row :name)
                      (or (plist-get row :file) "")
                      (plist-get row :result)
                      (plist-get row :forms)
                      (or (plist-get row :unique) "")
                      (if (plist-get row :contained) "yes" "no")
                      (length (plist-get row :containers))
                      (mapconcat #'symbol-name
                                 (seq-take (plist-get row :containers) 3) " "))))))

(defun pichat-test-overlap-analyze (directory)
  "Write report.md and tests.tsv under DIRECTORY from its records."
  (pcase-let* ((`(,forms . ,tests) (pichat-test-overlap-read directory))
               (rows (pichat-test-overlap-analyze-records (length forms) tests))
               (passed (seq-filter (lambda (row) (eq (plist-get row :result) 'passed))
                                   rows))
               (report (expand-file-name "report.md" directory)))
    (pichat-test-overlap--write-tsv rows (expand-file-name "tests.tsv" directory))
    (with-temp-file report
      (insert "# PiChat per-test coverage overlap\n\n")
      (insert (format "Generated: `%s`  \nEmacs: `%s`  \nRecords: `%s`\n\n"
                      (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                      emacs-version (abbreviate-file-name directory)))
      (insert "This report nominates review candidates. It is not evidence that a test is redundant: ")
      (insert "a test whose forms all run elsewhere can still be the only test asserting an outcome. ")
      (insert "Never remove a test on this data alone; read it and name the test that still protects the behaviour.\n\n")
      (insert "## Limits\n\n")
      (insert "- `pichat-chat.el` is not instrumented (see `coverage-setup.el`); tests of it show few or no forms and their overlap is unknown.\n")
      (insert "- Forms are Edebug stop points, not branches or assertions. Two tests can execute the same forms and check different outcomes.\n")
      (insert "- Counters are reset before each test, so code run while loading the suite is attributed to no test. Order-dependent state (lazy initialisation, caches) can shift a few forms between tests.\n")
      (insert "- Only passed tests are compared. Skipped tests are listed with their result.\n\n")
      (insert "## Summary by test file\n\n")
      (insert (format "%d tests, %d passed, %d instrumented forms executed by at least one test.\n\n"
                      (length rows) (length passed) (length forms)))
      (insert "- *No forms*: the test executes no instrumented form.\n")
      (insert "- *Unique*: the test executes a form no other passed test executes.\n")
      (insert "- *No unique*: every form also runs in some other test (but maybe spread over several).\n")
      (insert "- *In one test*: one other test alone executes every form of this test.\n\n")
      (insert "| Test file | Passed | Skipped | No forms | Unique | No unique | In one test |\n")
      (insert "|---|---:|---:|---:|---:|---:|---:|\n")
      (let ((groups (pichat-test-overlap--group-by-file rows)))
        (dolist (group groups)
          (let ((file-rows (cdr group)))
            (cl-flet ((count-if (predicate) (seq-count predicate file-rows)))
              (insert (format "| `%s` | %d | %d | %d | %d | %d | %d |\n"
                              (car group)
                              (count-if (lambda (r) (eq (plist-get r :result) 'passed)))
                              (count-if (lambda (r) (eq (plist-get r :result) 'skipped)))
                              (count-if (lambda (r) (and (eq (plist-get r :result) 'passed)
                                                         (zerop (plist-get r :forms)))))
                              (count-if (lambda (r) (> (or (plist-get r :unique) 0) 0)))
                              (count-if (lambda (r) (plist-get r :contained)))
                              (count-if (lambda (r) (plist-get r :containers))))))))
        (insert "\n## Coupling counts by test file\n\n")
        (pichat-test-overlap--insert-coupling (pichat-test-overlap-coupling-table))
        (insert "\n")
        (pichat-test-overlap--insert-coupling-notes)
        (insert "\n## Candidates by test file\n\n")
        (insert "Each test is listed with its number of forms. `⊆` lists up to three tests that each execute all of its forms (same file first, then smallest); `=` marks identical form sets.\n")
        (dolist (group groups)
          (let* ((file-rows (cdr group))
                 (single (seq-filter (lambda (r) (plist-get r :containers)) file-rows))
                 (spread (seq-filter (lambda (r) (and (plist-get r :contained)
                                                      (null (plist-get r :containers))))
                                     file-rows))
                 (empty (seq-filter (lambda (r) (and (eq (plist-get r :result) 'passed)
                                                     (zerop (plist-get r :forms))))
                                    file-rows)))
            (when (or single spread empty)
              (insert (format "\n### `%s`\n" (car group)))
              (when single
                (insert "\nContained in one other test:\n\n")
                (dolist (row single)
                  (let* ((first (car (plist-get row :containers)))
                         (first-size (cl-some (lambda (r) (and (eq (plist-get r :name) first)
                                                                (plist-get r :forms)))
                                              passed)))
                    (insert (format "- `%s` (%d) %s %s\n"
                                    (plist-get row :name) (plist-get row :forms)
                                    (if (eql first-size (plist-get row :forms)) "=" "⊆")
                                    (pichat-test-overlap--containers-text row))))))
              (when spread
                (insert "\nNo unique forms, spread over several tests:\n\n")
                (dolist (row spread)
                  (insert (format "- `%s` (%d)\n" (plist-get row :name)
                                  (plist-get row :forms)))))
              (when empty
                (insert "\nNo instrumented forms:\n\n")
                (dolist (row empty)
                  (insert (format "- `%s`\n" (plist-get row :name)))))))))
      (insert "\nPer-test numbers for every test: `tests.tsv` beside this report.\n"))
    report))

;;;; Record comparison

(defun pichat-test-overlap-diff (directory-a directory-b)
  "Print tests whose form sets differ between DIRECTORY-A and DIRECTORY-B.
Forms are compared by symbol and stop-point index, so the two runs may
number them differently.  Return the number of differing tests."
  (cl-flet ((sets (directory)
              (pcase-let ((`(,forms . ,tests) (pichat-test-overlap-read directory))
                          (table (make-hash-table :test #'eq)))
                (dolist (test tests)
                  (puthash (car test)
                           (sort (mapcar (lambda (id)
                                           (let ((form (aref forms id)))
                                             (format "%s#%d" (nth 1 form) (nth 2 form))))
                                         (append (nth 3 test) nil))
                                 #'string<)
                           table))
                table)))
    (let ((a (sets directory-a)) (b (sets directory-b)) (differing 0) (common 0))
      (maphash
       (lambda (name forms-a)
         (let ((forms-b (gethash name b 'missing)))
           (unless (eq forms-b 'missing)
             (cl-incf common)
             (unless (equal forms-a forms-b)
               (cl-incf differing)
               (message "%s: %d only in A, %d only in B: %s"
                        name
                        (length (seq-difference forms-a forms-b))
                        (length (seq-difference forms-b forms-a))
                        (string-join
                         (seq-take (append (mapcar (lambda (f) (concat "-" f))
                                                   (seq-difference forms-a forms-b))
                                           (mapcar (lambda (f) (concat "+" f))
                                                   (seq-difference forms-b forms-a)))
                                   6)
                         " "))))))
       a)
      (message "Compared %d tests present in both: %d differ" common differing)
      differing)))

(provide 'pichat-test-overlap)
;;; test-overlap.el ends here
