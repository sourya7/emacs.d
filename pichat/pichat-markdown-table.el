;;; pichat-markdown-table.el --- Markdown pipe tables and viewer -*- lexical-binding: t; -*-

;;; Commentary:

;; Position-independent parsing and bounded layout for the common Markdown pipe
;; tables emitted in PiChat responses, plus an immutable complete-table viewer.
;; This module owns no chat overlays or chat state and never rewrites its input.
;; Org is loaded only when a viewer is activated.  All model source positions
;; are zero-based half-open offsets into the string passed to
;; `pichat-markdown-table-parse'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-view)

(declare-function org-table-align "org-table" ())
(declare-function orgtbl-mode "org-table" (&optional arg))

(cl-defstruct (pichat-markdown-table
               (:constructor pichat-markdown-table-create)
               (:conc-name pichat-markdown-table-))
  "A position-independent Markdown pipe table."
  source-digest start end rows alignments column-count data-row-count)

(cl-defstruct (pichat-markdown-table-row
               (:constructor pichat-markdown-table-row-create)
               (:conc-name pichat-markdown-table-row-))
  "One source row in a `pichat-markdown-table'."
  start end kind cells leading-prefix)

(cl-defstruct (pichat-markdown-table-cell
               (:constructor pichat-markdown-table-cell-create)
               (:conc-name pichat-markdown-table-cell-))
  "One source cell in a `pichat-markdown-table-row'."
  start end source display)

(cl-defstruct (pichat-markdown-table--line
               (:constructor pichat-markdown-table--line-create))
  start end excluded)

(cl-defstruct (pichat-markdown-table--candidate
               (:constructor pichat-markdown-table--candidate-create))
  row leading-p trailing-p)

(cl-defstruct (pichat-markdown-table-layout
               (:constructor pichat-markdown-table-layout-create)
               (:conc-name pichat-markdown-table-layout-))
  "A bounded, position-independent inline layout for one table."
  rows target-width visible-column-count omitted-column-count omitted-row-count)

(cl-defstruct (pichat-markdown-table-layout-row
               (:constructor pichat-markdown-table-layout-row-create)
               (:conc-name pichat-markdown-table-layout-row-))
  "One replacement row in a `pichat-markdown-table-layout'."
  start end kind text)

(defconst pichat-markdown-table-layout-policy-version 1
  "Version of PiChat's deterministic inline table allocation policy.")

(defcustom pichat-markdown-table-view-align-max-source-chars 200000
  "Maximum snapshot characters automatically aligned in a table viewer."
  :type 'integer
  :group 'pichat)

(defcustom pichat-markdown-table-view-align-max-rows 2000
  "Maximum model rows automatically aligned in a table viewer."
  :type 'integer
  :group 'pichat)

(defvar-local pichat-markdown-table-view-source nil
  "Exact immutable Markdown snapshot owned by this table viewer.")

(defvar-local pichat-markdown-table-view-model nil
  "Position-independent table model owned by this table viewer.")

(defvar-local pichat-markdown-table-view-origin-buffer nil
  "Chat buffer from which this table viewer was opened.")

(defvar-local pichat-markdown-table-view-origin-key nil
  "Stable presentation key of this viewer's originating table.")

(defvar-local pichat-markdown-table-view-origin-generation nil
  "Source generation of this viewer's originating table.")

(defvar-local pichat-markdown-table-view-origin-marker nil
  "Marker at this viewer's original table position, when available.")

(defvar-local pichat-markdown-table-view-origin-resolver nil
  "Function used to resolve this viewer's still-current origin.")

(defvar-local pichat-markdown-table-view--normalized-text nil
  "Complete normalized Org text retained by this table viewer.")

(defvar-local pichat-markdown-table-view--raw-p nil
  "Non-nil when this viewer currently displays exact Markdown source.")

(defvar-local pichat-markdown-table-view--alignment-note nil
  "Bounded explanation of skipped or failed viewer alignment.")

(defvar pichat-markdown-table-view-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map pichat-view-mode-map)
    (define-key map (kbd "q") #'pichat-markdown-table-view-quit)
    (define-key map (kbd "t") #'pichat-markdown-table-view-return-to-origin)
    (define-key map (kbd "<") #'pichat-markdown-table-view-scroll-left)
    (define-key map (kbd ">") #'pichat-markdown-table-view-scroll-right)
    (define-key map (kbd "n") #'pichat-markdown-table-view-next-row)
    (define-key map (kbd "p") #'pichat-markdown-table-view-previous-row)
    (define-key map (kbd "g") #'pichat-markdown-table-view-reset)
    (define-key map (kbd "w") #'pichat-markdown-table-view-copy-source)
    (define-key map (kbd "s") #'pichat-markdown-table-view-toggle-source)
    (define-key map (kbd "a") #'pichat-markdown-table-view-align)
    map)
  "Keymap for immutable PiChat Markdown table viewers.")

(define-derived-mode pichat-markdown-table-view-mode
  pichat-view-mode "PiChat-Table"
  "Inspect a complete immutable Markdown table snapshot.

Keys: q closes the viewer, t returns to a current origin, < and > scroll
horizontally, n and p move by rows, g resets position, w copies exact Markdown,
s toggles normalized and raw source, and a explicitly aligns a large table."
  (unless (require 'org-table nil t)
    (error "Built-in Org table support is unavailable"))
  (orgtbl-mode 1)
  (setq-local truncate-lines t)
  (setq-local buffer-undo-list t))

(defun pichat-markdown-table-string-width (string)
  "Return the display width of STRING for inline table allocation."
  (string-width string))

(defun pichat-markdown-table--excluded-ranges (ranges source-length)
  "Return normalized RANGES bounded by SOURCE-LENGTH.
Each range uses zero-based half-open string offsets."
  (sort
   (delq nil
         (mapcar
          (lambda (range)
            (when (and (consp range)
                       (integerp (car range))
                       (integerp (cdr range)))
              (let ((start (max 0 (min source-length (car range))))
                    (end (max 0 (min source-length (cdr range)))))
                (when (< start end) (cons start end)))))
          ranges))
   (lambda (left right) (< (car left) (car right)))))

(defun pichat-markdown-table--lines (source excluded-ranges)
  "Return a vector of SOURCE lines marked by EXCLUDED-RANGES."
  (let* ((length (length source))
         (ranges (pichat-markdown-table--excluded-ranges
                  excluded-ranges length))
         lines
         (position 0))
    (while (< position length)
      (let* ((newline (string-match "\n" source position))
             (end (or newline length))
             (next (if newline (1+ newline) length)))
        (while (and ranges (<= (cdar ranges) position))
          (setq ranges (cdr ranges)))
        (push (pichat-markdown-table--line-create
               :start position
               :end end
               :excluded (and ranges
                              (< (caar ranges) next)
                              (< position (cdar ranges))))
              lines)
        (setq position next)))
    (vconcat (nreverse lines))))

(defun pichat-markdown-table--backslash-escaped-p (source position start)
  "Return non-nil when SOURCE character at POSITION is escaped after START."
  (let ((slashes 0)
        (index (1- position)))
    (while (and (>= index start) (= (aref source index) ?\\))
      (cl-incf slashes)
      (cl-decf index))
    (= 1 (% slashes 2))))

(defun pichat-markdown-table--backtick-run (source position end)
  "Return backtick run length in SOURCE from POSITION before END."
  (let ((index position))
    (while (and (< index end) (= (aref source index) ?`))
      (cl-incf index))
    (- index position)))

(defun pichat-markdown-table--pipe-delimiters (source start end)
  "Return unescaped, non-code pipe offsets in SOURCE between START and END.
Return the symbol `unterminated-code' when a code span is not closed."
  (let ((position start)
        code-run
        delimiters)
    (while (< position end)
      (let ((character (aref source position)))
        (cond
         ((and (= character ?`)
               ;; Backslash escapes apply outside code spans.  Inside a code
               ;; span, backslashes are literal and a matching run still closes.
               (or code-run
                   (not (pichat-markdown-table--backslash-escaped-p
                         source position start))))
          (let ((run (pichat-markdown-table--backtick-run
                      source position end)))
            (cond
             ((null code-run) (setq code-run run))
             ((= run code-run) (setq code-run nil)))
            (cl-incf position run)))
         ((and (= character ?|)
               (null code-run)
               (not (pichat-markdown-table--backslash-escaped-p
                     source position start)))
          (push position delimiters)
          (cl-incf position))
         (t (cl-incf position)))))
    (if code-run 'unterminated-code (nreverse delimiters))))

(defun pichat-markdown-table--trim-cell-bounds (source start end)
  "Return whitespace-trimmed bounds in SOURCE between START and END."
  (while (and (< start end) (memq (aref source start) '(?\s ?\t)))
    (cl-incf start))
  (while (and (< start end) (memq (aref source (1- end)) '(?\s ?\t)))
    (cl-decf end))
  (cons start end))

(defun pichat-markdown-table--display-cell (source)
  "Return conservative display text derived from cell SOURCE."
  (let ((position 0)
        (length (length source))
        chars)
    (while (< position length)
      (let ((character (aref source position)))
        (cond
         ((and (= character ?\\)
               (< (1+ position) length)
               (= (aref source (1+ position)) ?|))
          (push ?| chars)
          (cl-incf position 2))
         (t
          (push (if (or (= character ?\t)
                        (< character 32)
                        (= character 127))
                    ?\s
                  character)
                chars)
          (cl-incf position)))))
    (let ((display (concat (nreverse chars))))
      (if (multibyte-string-p source)
          display
        (string-make-unibyte display)))))

(defun pichat-markdown-table--cell (source start end)
  "Return a table cell for SOURCE bounds START and END."
  (pcase-let* ((`(,trimmed-start . ,trimmed-end)
                (pichat-markdown-table--trim-cell-bounds source start end))
               (cell-source
                (substring-no-properties source trimmed-start trimmed-end)))
    (pichat-markdown-table-cell-create
     :start trimmed-start
     :end trimmed-end
     :source cell-source
     :display (pichat-markdown-table--display-cell cell-source))))

(defun pichat-markdown-table--row-candidate (source line)
  "Parse LINE in SOURCE as a possible pipe-table row."
  (unless (pichat-markdown-table--line-excluded line)
    (let* ((start (pichat-markdown-table--line-start line))
           (end (pichat-markdown-table--line-end line))
           (content-start start)
           (content-end end))
      ;; Markdown permits at most three leading spaces before a pipe table.
      (while (and (< content-start content-end)
                  (= (aref source content-start) ?\s))
        (cl-incf content-start))
      (when (and (<= (- content-start start) 3)
                 (< content-start content-end)
                 (/= (aref source content-start) ?\t))
        (while (and (> content-end content-start)
                    (memq (aref source (1- content-end)) '(?\s ?\t)))
          (cl-decf content-end))
        (let ((delimiters
               (pichat-markdown-table--pipe-delimiters
                source content-start content-end)))
          (unless (or (eq delimiters 'unterminated-code)
                      (null delimiters))
            (let* ((leading-p (= (car delimiters) content-start))
                   (trailing-p (= (car (last delimiters)) (1- content-end)))
                   (cell-start (if leading-p (1+ content-start) content-start))
                   (cell-end (if trailing-p (1- content-end) content-end))
                   (internal
                    (cl-remove-if-not
                     (lambda (position)
                       (and (>= position cell-start) (< position cell-end)))
                     delimiters))
                   (boundary-start cell-start)
                   cells)
              (dolist (delimiter internal)
                (push (pichat-markdown-table--cell
                       source boundary-start delimiter)
                      cells)
                (setq boundary-start (1+ delimiter)))
              (push (pichat-markdown-table--cell
                     source boundary-start (max boundary-start cell-end))
                    cells)
              (pichat-markdown-table--candidate-create
               :leading-p leading-p
               :trailing-p trailing-p
               :row
               (pichat-markdown-table-row-create
                :start start
                :end end
                :cells (nreverse cells)
                :leading-prefix (substring-no-properties
                                 source start content-start))))))))))

(defun pichat-markdown-table--delimiter-alignment (cell)
  "Return alignment represented by delimiter CELL, or nil when malformed."
  (let ((source (pichat-markdown-table-cell-source cell)))
    (when (string-match-p "\\`:?-\\{3,\\}:?\\'" source)
      (cond
       ((and (string-prefix-p ":" source)
             (string-suffix-p ":" source))
        'center)
       ((string-suffix-p ":" source) 'right)
       (t 'left)))))

(defun pichat-markdown-table--delimiter-alignments (row)
  "Return ROW delimiter alignments, or nil when ROW is malformed."
  (let (alignments malformed)
    (dolist (cell (pichat-markdown-table-row-cells row))
      (if-let ((alignment
                (pichat-markdown-table--delimiter-alignment cell)))
          (push alignment alignments)
        (setq malformed t)))
    (unless malformed (nreverse alignments))))

(defun pichat-markdown-table--same-style-p (left right)
  "Return non-nil when row candidates LEFT and RIGHT use the same outer pipes."
  (and (eq (pichat-markdown-table--candidate-leading-p left)
           (pichat-markdown-table--candidate-leading-p right))
       (eq (pichat-markdown-table--candidate-trailing-p left)
           (pichat-markdown-table--candidate-trailing-p right))))

(defun pichat-markdown-table--pad-row (row column-count)
  "Pad semantic ROW with empty cells through COLUMN-COUNT."
  (let* ((cells (pichat-markdown-table-row-cells row))
         (missing (- column-count (length cells)))
         (position (pichat-markdown-table-row-end row)))
    (when (> missing 0)
      (setq cells
            (nconc cells
                   (cl-loop repeat missing
                            collect (pichat-markdown-table-cell-create
                                     :start position :end position
                                     :source "" :display "")))))
    (setf (pichat-markdown-table-row-cells row) cells)
    row))

(defun pichat-markdown-table--table-at (source lines index)
  "Return (TABLE . NEXT-INDEX) for SOURCE LINES at INDEX, or nil."
  (let ((line-count (length lines)))
    (when (< (1+ index) line-count)
      (let* ((header (pichat-markdown-table--row-candidate
                      source (aref lines index)))
             (delimiter (pichat-markdown-table--row-candidate
                         source (aref lines (1+ index)))))
        (when (and header delimiter
                   (pichat-markdown-table--same-style-p header delimiter))
          (let* ((header-row (pichat-markdown-table--candidate-row header))
                 (delimiter-row
                  (pichat-markdown-table--candidate-row delimiter))
                 (alignments
                  (pichat-markdown-table--delimiter-alignments delimiter-row))
                 (header-count
                  (length (pichat-markdown-table-row-cells header-row))))
            (when (and alignments
                       (= header-count (length alignments)))
              (setf (pichat-markdown-table-row-kind header-row) 'header
                    (pichat-markdown-table-row-kind delimiter-row) 'delimiter)
              (let ((rows (list delimiter-row header-row))
                    (column-count header-count)
                    (data-row-count 0)
                    (next (+ index 2))
                    collecting)
                (setq collecting t)
                (while (and collecting (< next line-count))
                  (let ((candidate
                         (pichat-markdown-table--row-candidate
                          source (aref lines next))))
                    (if (and candidate
                             (pichat-markdown-table--same-style-p
                              header candidate))
                        (let ((row (pichat-markdown-table--candidate-row
                                    candidate)))
                          (setf (pichat-markdown-table-row-kind row) 'data)
                          (cl-incf data-row-count)
                          (setq column-count
                                (max column-count
                                     (length
                                      (pichat-markdown-table-row-cells row))))
                          (push row rows)
                          (cl-incf next))
                      (setq collecting nil))))
                (setq rows
                      (mapcar
                       (lambda (row)
                         (if (eq (pichat-markdown-table-row-kind row)
                                 'delimiter)
                             row
                           (pichat-markdown-table--pad-row row column-count)))
                       (nreverse rows)))
                (when (< (length alignments) column-count)
                  (setq alignments
                        (append alignments
                                (make-list (- column-count
                                              (length alignments))
                                           'left))))
                (let* ((start (pichat-markdown-table-row-start (car rows)))
                       (end (pichat-markdown-table-row-end (car (last rows))))
                       (table
                        (pichat-markdown-table-create
                         :source-digest
                         (secure-hash 'sha1 (substring-no-properties
                                            source start end))
                         :start start
                         :end end
                         :rows rows
                         :alignments alignments
                         :column-count column-count
                         :data-row-count data-row-count)))
                  (cons table next))))))))))

(defun pichat-markdown-table-parse (source &optional excluded-ranges)
  "Return position-independent Markdown pipe tables found in SOURCE.

EXCLUDED-RANGES is a list of zero-based half-open offsets in SOURCE, typically
covering fenced code blocks.  Only common header/delimiter pipe tables are
recognized.  Malformed or ambiguous candidates are left unrecognized so callers
can display their exact source unchanged."
  (unless (stringp source)
    (signal 'wrong-type-argument (list 'stringp source)))
  (let* ((lines (pichat-markdown-table--lines source excluded-ranges))
         (line-count (length lines))
         (index 0)
         tables)
    (while (< index line-count)
      (if-let ((result (pichat-markdown-table--table-at source lines index)))
          (progn
            (push (car result) tables)
            (setq index (cdr result)))
        (cl-incf index)))
    (nreverse tables)))

(defun pichat-markdown-table--preview-rows (table maximum)
  "Return up to MAXIMUM data rows from TABLE without traversing its tail."
  (let ((remaining (cddr (pichat-markdown-table-rows table)))
        (count 0)
        rows)
    (while (and remaining (< count maximum))
      (push (car remaining) rows)
      (setq remaining (cdr remaining))
      (cl-incf count))
    (nreverse rows)))

(defun pichat-markdown-table--row-prefix-width (row)
  "Return the display width of ROW's preserved leading prefix."
  (pichat-markdown-table-string-width
   (or (pichat-markdown-table-row-leading-prefix row) "")))

(defun pichat-markdown-table--natural-widths (rows column-count)
  "Return natural cell widths in ROWS for the first COLUMN-COUNT columns."
  (let ((widths (make-vector column-count 0)))
    (dolist (row rows)
      (let ((cells (pichat-markdown-table-row-cells row))
            (index 0))
        (while (and cells (< index column-count))
          (aset widths index
                (max (aref widths index)
                     (pichat-markdown-table-string-width
                      (pichat-markdown-table-cell-display (car cells)))))
          (setq cells (cdr cells))
          (cl-incf index))))
    widths))

(defun pichat-markdown-table--minimum-width (natural minimum)
  "Return initial width for NATURAL content under MINIMUM policy."
  (min natural minimum))

(defun pichat-markdown-table--required-width
    (natural visible-columns minimum omitted-label)
  "Return minimum row width for NATURAL and VISIBLE-COLUMNS.
MINIMUM is the real-column content minimum.  OMITTED-LABEL, when non-nil, is a
synthetic final column whose complete label is reserved."
  (let ((column-count (+ visible-columns (if omitted-label 1 0)))
        (content-width 0))
    (dotimes (index visible-columns)
      (cl-incf content-width
               (pichat-markdown-table--minimum-width
                (aref natural index) minimum)))
    (when omitted-label
      (cl-incf content-width
               (pichat-markdown-table-string-width omitted-label)))
    (+ content-width (* 3 column-count) 1)))

(defun pichat-markdown-table--allocate-widths
    (natural visible-columns minimum content-budget omitted-label)
  "Allocate deterministic content widths within CONTENT-BUDGET.
NATURAL describes real columns, of which VISIBLE-COLUMNS are retained.
MINIMUM controls their initial useful width.  OMITTED-LABEL reserves a complete
synthetic final column when non-nil."
  (let* ((synthetic-p (and omitted-label t))
         (count (+ visible-columns (if synthetic-p 1 0)))
         (widths (make-vector count 0))
         (remaining content-budget))
    (dotimes (index visible-columns)
      (let ((width (pichat-markdown-table--minimum-width
                    (aref natural index) minimum)))
        (aset widths index width)
        (cl-decf remaining width)))
    (when synthetic-p
      (let ((width (pichat-markdown-table-string-width omitted-label)))
        (aset widths visible-columns width)
        (cl-decf remaining width)))
    ;; Fair round-robin water filling prevents an early verbose column from
    ;; consuming the budget while later columns still need space.
    (let ((progress t))
      (while (and (> remaining 0) progress)
        (setq progress nil)
        (dotimes (index visible-columns)
          (when (and (> remaining 0)
                     (< (aref widths index) (aref natural index)))
            (aset widths index (1+ (aref widths index)))
            (cl-decf remaining)
            (setq progress t)))))
    widths))

(defun pichat-markdown-table--truncate (string width)
  "Return STRING constrained to WIDTH columns with a visible ellipsis."
  (cond
   ((<= width 0) "")
   ((<= (pichat-markdown-table-string-width string) width) string)
   ((= width 1) "…")
   (t (concat (truncate-string-to-width string (1- width)) "…"))))

(defun pichat-markdown-table--format-cell (string width alignment &optional face)
  "Format STRING to WIDTH using ALIGNMENT and optional FACE."
  (let* ((content (pichat-markdown-table--truncate string width))
         (padding (max 0 (- width
                            (pichat-markdown-table-string-width content))))
         (left (pcase alignment
                 ('right padding)
                 ('center (/ padding 2))
                 (_ 0)))
         (right (- padding left))
         (result (concat (make-string left ?\s)
                         content
                         (make-string right ?\s))))
    (if face (propertize result 'face face) result)))

(defun pichat-markdown-table--border (string)
  "Return STRING styled as an inline table border."
  (propertize string 'face 'shadow))

(defun pichat-markdown-table--format-content-row
    (row widths alignments visible-columns omitted-label unicode-borders)
  "Format semantic ROW using WIDTHS and ALIGNMENTS.
VISIBLE-COLUMNS are real columns.  OMITTED-LABEL adds a synthetic final column;
UNICODE-BORDERS selects compact Unicode rather than ASCII separators."
  (let* ((border (if unicode-borders "│" "|"))
         (cells (pichat-markdown-table-row-cells row))
         (header-p (eq (pichat-markdown-table-row-kind row) 'header))
         (parts (list (pichat-markdown-table--border border)))
         (index 0))
    (while (< index visible-columns)
      (let ((display (if cells
                         (pichat-markdown-table-cell-display (car cells))
                       "")))
        (setq parts
              (nconc parts
                     (list " "
                           (pichat-markdown-table--format-cell
                            display (aref widths index)
                            (or (nth index alignments) 'left)
                            (and header-p 'bold))
                           " "
                           (pichat-markdown-table--border border))))
        (setq cells (cdr cells))
        (cl-incf index)))
    (when omitted-label
      (setq parts
            (nconc parts
                   (list " "
                         (pichat-markdown-table--format-cell
                          (if header-p omitted-label "…")
                          (aref widths visible-columns) 'left
                          (and header-p 'bold))
                         " "
                         (pichat-markdown-table--border border)))))
    (concat (or (pichat-markdown-table-row-leading-prefix row) "")
            (apply #'concat parts))))

(defun pichat-markdown-table--format-delimiter-row
    (row widths unicode-borders)
  "Format delimiter ROW for WIDTHS and UNICODE-BORDERS."
  (let ((left (if unicode-borders "├" "+"))
        (middle (if unicode-borders "┼" "+"))
        (right (if unicode-borders "┤" "+"))
        segments)
    (dotimes (index (length widths))
      (push (pichat-markdown-table--border
             (make-string (+ 2 (aref widths index)) ?-))
            segments))
    (concat (or (pichat-markdown-table-row-leading-prefix row) "")
            (pichat-markdown-table--border left)
            (mapconcat #'identity (nreverse segments)
                       (pichat-markdown-table--border middle))
            (pichat-markdown-table--border right))))

(defun pichat-markdown-table--layout-row (table row kind text &optional end)
  "Return one layout row for TABLE and source ROW with KIND and TEXT.
Optional END overrides ROW's relative source end for a concealed range."
  (pichat-markdown-table-layout-row-create
   :start (- (pichat-markdown-table-row-start row)
             (pichat-markdown-table-start table))
   :end (if end
            (- end (pichat-markdown-table-start table))
          (- (pichat-markdown-table-row-end row)
             (pichat-markdown-table-start table)))
   :kind kind
   :text text))

(defun pichat-markdown-table-make-layout
    (table target-width &optional maximum-data-rows maximum-columns
           unicode-borders minimum-column-width)
  "Return a bounded inline layout for TABLE within TARGET-WIDTH.

At most MAXIMUM-DATA-ROWS data rows and MAXIMUM-COLUMNS real columns are
formatted.  UNICODE-BORDERS selects compact Unicode separators.  Real columns
start with MINIMUM-COLUMN-WIDTH content columns when their natural content is
that wide.  Return nil when even one useful real column and required omission
indicators cannot fit."
  (unless (and (pichat-markdown-table-p table)
               (integerp target-width))
    (signal 'wrong-type-argument (list 'pichat-markdown-table-p table)))
  (let* ((maximum-data-rows (max 0 (or maximum-data-rows 40)))
         (maximum-columns (max 1 (or maximum-columns 12)))
         (minimum-column-width (max 1 (or minimum-column-width 3)))
         (column-count (pichat-markdown-table-column-count table))
         (rows (pichat-markdown-table-rows table))
         (header (car rows))
         (delimiter (cadr rows))
         (data-rows (pichat-markdown-table--preview-rows
                     table maximum-data-rows))
         (data-row-count (or (pichat-markdown-table-data-row-count table) 0))
         (omitted-row-count (max 0 (- data-row-count (length data-rows))))
         (first-omitted (and (> omitted-row-count 0)
                             (nth maximum-data-rows (cddr rows))))
         (candidate-columns (min column-count maximum-columns))
         (natural (pichat-markdown-table--natural-widths
                   (cons header data-rows) candidate-columns))
         (prefix-width
          (apply #'max 0
                 (mapcar #'pichat-markdown-table--row-prefix-width
                         (append (list header delimiter) data-rows
                                 (and first-omitted (list first-omitted))))))
         (body-width (- target-width prefix-width))
         (visible-columns candidate-columns)
         omitted-label)
    (when (and (> target-width 0) (> column-count 0))
      (let ((selecting t))
        (while selecting
          (setq omitted-label
                (and (< visible-columns column-count)
                     (format "… +%d columns" (- column-count visible-columns))))
          (if (<= (pichat-markdown-table--required-width
                   natural visible-columns minimum-column-width omitted-label)
                  body-width)
              (setq selecting nil)
            (if (> visible-columns 1)
                (cl-decf visible-columns)
              (setq visible-columns 0
                    selecting nil)))))
      (when (and (> visible-columns 0)
                 ;; Preserve the complete omitted-row count rather than showing
                 ;; a misleading truncated summary.
                 (or (= omitted-row-count 0)
                     (<= (+ 4 (pichat-markdown-table-string-width
                               (format "… %d more rows" omitted-row-count)))
                         body-width)))
        (let* ((rendered-column-count
                (+ visible-columns (if omitted-label 1 0)))
               (content-budget (- body-width
                                  (+ (* 3 rendered-column-count) 1)))
               (widths (pichat-markdown-table--allocate-widths
                        natural visible-columns minimum-column-width
                        content-budget omitted-label))
               (alignments (pichat-markdown-table-alignments table))
               layout-rows)
          (push (pichat-markdown-table--layout-row
                 table header 'header
                 (pichat-markdown-table--format-content-row
                  header widths alignments visible-columns omitted-label
                  unicode-borders))
                layout-rows)
          (push (pichat-markdown-table--layout-row
                 table delimiter 'delimiter
                 (pichat-markdown-table--format-delimiter-row
                  delimiter widths unicode-borders))
                layout-rows)
          (dolist (row data-rows)
            (push (pichat-markdown-table--layout-row
                   table row 'data
                   (pichat-markdown-table--format-content-row
                    row widths alignments visible-columns omitted-label
                    unicode-borders))
                  layout-rows))
          (when first-omitted
            (let* ((label (format "… %d more rows" omitted-row-count))
                   (content-width (- body-width 4))
                   (border (if unicode-borders "│" "|"))
                   (text
                    (concat
                     (or (pichat-markdown-table-row-leading-prefix
                          first-omitted) "")
                     (pichat-markdown-table--border border)
                     " "
                     (pichat-markdown-table--format-cell
                      label content-width 'left 'italic)
                     " "
                     (pichat-markdown-table--border border))))
              (push (pichat-markdown-table--layout-row
                     table first-omitted 'omitted text
                     (pichat-markdown-table-end table))
                    layout-rows)))
          (pichat-markdown-table-layout-create
           :rows (nreverse layout-rows)
           :target-width target-width
           :visible-column-count visible-columns
           :omitted-column-count (- column-count visible-columns)
           :omitted-row-count omitted-row-count))))))

(defun pichat-markdown-table--org-cell (cell)
  "Return CELL display text safe inside an Org table field."
  ;; Org does not treat backslash-pipe as an escaped field character.  Its
  ;; documented vertical-bar macro remains ordinary inert text during table
  ;; alignment and cannot create an additional column.
  (replace-regexp-in-string
   (regexp-quote "|") "\\vert{}"
   (pichat-markdown-table-cell-display cell) t t))

(defun pichat-markdown-table--org-content-row (row column-count)
  "Serialize semantic ROW with COLUMN-COUNT fields for Org."
  (let ((cells (pichat-markdown-table-row-cells row))
        fields)
    (dotimes (_index column-count)
      (push (if cells
                (pichat-markdown-table--org-cell (pop cells))
              "")
            fields))
    (concat "| " (mapconcat #'identity (nreverse fields) " | ") " |")))

(defun pichat-markdown-table--org-horizontal-rule (column-count)
  "Return an Org horizontal rule spanning COLUMN-COUNT fields."
  (concat "|" (mapconcat (lambda (_index) "---")
                          (number-sequence 1 column-count) "+") "|"))

(defun pichat-markdown-table-org-string (table)
  "Return a complete Org-compatible serialization of TABLE.

The Markdown delimiter row becomes an Org horizontal rule.  Literal cell pipes
use Org's inert vertical-bar representation so every model column remains
unambiguous.  No formula evaluation or export processing is performed."
  (unless (pichat-markdown-table-p table)
    (signal 'wrong-type-argument (list 'pichat-markdown-table-p table)))
  (let ((column-count (pichat-markdown-table-column-count table))
        lines)
    (dolist (row (pichat-markdown-table-rows table))
      (push (if (eq (pichat-markdown-table-row-kind row) 'delimiter)
                (pichat-markdown-table--org-horizontal-rule column-count)
              (pichat-markdown-table--org-content-row row column-count))
            lines))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun pichat-markdown-table-view--replace-content (text)
  "Replace the current viewer contents with TEXT without making it writable."
  (let ((inhibit-read-only t)
        (buffer-undo-list t))
    (erase-buffer)
    (insert text))
  (goto-char (point-min))
  (set-buffer-modified-p nil))

(defun pichat-markdown-table-view--set-alignment-note (note)
  "Set bounded viewer alignment NOTE and update its header."
  (setq pichat-markdown-table-view--alignment-note note
        header-line-format
        (and note (propertize note 'face 'warning))))

(defun pichat-markdown-table-view--align-current ()
  "Align the normalized table in the current viewer.
Return non-nil on success, leaving readable unaligned text on failure."
  (let ((unaligned (buffer-substring-no-properties (point-min) (point-max))))
    (condition-case err
        (progn
          (goto-char (point-min))
          (let ((inhibit-read-only t)
                (buffer-undo-list t))
            (org-table-align))
          (setq pichat-markdown-table-view--normalized-text
                (buffer-substring-no-properties (point-min) (point-max)))
          (pichat-markdown-table-view--set-alignment-note nil)
          (set-buffer-modified-p nil)
          t)
      (error
       (pichat-markdown-table-view--replace-content unaligned)
       (pichat-markdown-table-view--set-alignment-note
        (format "Org table alignment failed: %s"
                (truncate-string-to-width
                 (error-message-string err) 120 nil nil "…")))
       nil))))

(defun pichat-markdown-table-view--automatic-alignment-p ()
  "Return non-nil when the current snapshot is safe to align automatically."
  (and (<= (length pichat-markdown-table-view-source)
           (max 0 pichat-markdown-table-view-align-max-source-chars))
       (<= (length (pichat-markdown-table-rows
                    pichat-markdown-table-view-model))
           (max 0 pichat-markdown-table-view-align-max-rows))))

(defun pichat-markdown-table-view--alignment-skipped-note ()
  "Return a bounded explanation for skipped automatic alignment."
  (format "Alignment skipped for %d characters and %d rows; press a to align"
          (length pichat-markdown-table-view-source)
          (length (pichat-markdown-table-rows
                   pichat-markdown-table-view-model))))

(defun pichat-markdown-table-open-viewer
    (source table &optional origin-buffer origin-key origin-generation
            origin-marker origin-resolver)
  "Open and return an immutable complete table viewer.

SOURCE is the exact Markdown snapshot and TABLE is its parsed model.  Optional
ORIGIN-BUFFER, ORIGIN-KEY, ORIGIN-GENERATION, and ORIGIN-MARKER identify the
chat table.  ORIGIN-RESOLVER validates that identity when returning.  Built-in
Org support is loaded only while constructing this explicit viewer."
  (unless (and (stringp source) (pichat-markdown-table-p table))
    (signal 'wrong-type-argument
            (list '(and stringp pichat-markdown-table-p) source table)))
  (unless (equal (secure-hash 'sha1 source)
                 (pichat-markdown-table-source-digest table))
    (error "Table model does not match its Markdown snapshot"))
  (let ((buffer (generate-new-buffer "*PiChat Table*"))
        (snapshot (copy-sequence source))
        completed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (pichat-markdown-table-view-mode)
            (setq-local pichat-markdown-table-view-source snapshot)
            (setq-local pichat-markdown-table-view-model table)
            (setq-local pichat-markdown-table-view-origin-buffer origin-buffer)
            (setq-local pichat-markdown-table-view-origin-key origin-key)
            (setq-local pichat-markdown-table-view-origin-generation
                        origin-generation)
            (setq-local pichat-markdown-table-view-origin-marker
                        (and origin-marker (copy-marker origin-marker)))
            (setq-local pichat-markdown-table-view-origin-resolver
                        origin-resolver)
            (setq-local pichat-markdown-table-view--raw-p nil)
            (setq-local pichat-markdown-table-view--normalized-text
                        (pichat-markdown-table-org-string table))
            (pichat-markdown-table-view--replace-content
             pichat-markdown-table-view--normalized-text)
            (if (pichat-markdown-table-view--automatic-alignment-p)
                (pichat-markdown-table-view--align-current)
              (pichat-markdown-table-view--set-alignment-note
               (pichat-markdown-table-view--alignment-skipped-note)))
            (set-buffer-modified-p nil))
          (pichat-view-display buffer nil 'kill)
          (setq completed t)
          buffer)
      (unless completed
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(defun pichat-markdown-table-view-toggle-source ()
  "Toggle this viewer between normalized Org and exact Markdown source."
  (interactive)
  (unless (stringp pichat-markdown-table-view-source)
    (user-error "This buffer has no PiChat table snapshot"))
  (setq pichat-markdown-table-view--raw-p
        (not pichat-markdown-table-view--raw-p))
  (pichat-markdown-table-view--replace-content
   (if pichat-markdown-table-view--raw-p
       pichat-markdown-table-view-source
     pichat-markdown-table-view--normalized-text))
  (message "PiChat table view: %s"
           (if pichat-markdown-table-view--raw-p "exact Markdown" "normalized")))

(defun pichat-markdown-table-view-copy-source ()
  "Copy this viewer's exact Markdown snapshot."
  (interactive)
  (unless (stringp pichat-markdown-table-view-source)
    (user-error "This buffer has no PiChat table snapshot"))
  (kill-new pichat-markdown-table-view-source)
  (message "Copied exact Markdown table"))

(defun pichat-markdown-table-view-align ()
  "Explicitly align the complete normalized table in this viewer."
  (interactive)
  (unless (pichat-markdown-table-p pichat-markdown-table-view-model)
    (user-error "This buffer has no PiChat table model"))
  (setq pichat-markdown-table-view--raw-p nil
        pichat-markdown-table-view--normalized-text
        (pichat-markdown-table-org-string
         pichat-markdown-table-view-model))
  (pichat-markdown-table-view--replace-content
   pichat-markdown-table-view--normalized-text)
  (unless (pichat-markdown-table-view--align-current)
    (user-error "%s" pichat-markdown-table-view--alignment-note))
  (message "Aligned complete PiChat table"))

(defun pichat-markdown-table-view--window ()
  "Return a live window displaying the current viewer, or signal."
  (or (get-buffer-window (current-buffer) t)
      (user-error "PiChat table viewer is not displayed")))

(defun pichat-markdown-table-view-scroll-left ()
  "Scroll the current viewer left by half its window width."
  (interactive)
  (let* ((window (pichat-markdown-table-view--window))
         (amount (max 1 (/ (window-body-width window) 2))))
    (set-window-hscroll window
                        (max 0 (- (window-hscroll window) amount)))))

(defun pichat-markdown-table-view-scroll-right ()
  "Scroll the current viewer right by half its window width."
  (interactive)
  (let* ((window (pichat-markdown-table-view--window))
         (amount (max 1 (/ (window-body-width window) 2))))
    (set-window-hscroll window (+ (window-hscroll window) amount))))

(defun pichat-markdown-table-view--separator-line-p ()
  "Return non-nil when point is on an Org or Markdown delimiter row."
  (save-excursion
    (beginning-of-line)
    (looking-at-p "[ \\t]*[-+:| \\t]+[ \\t]*$")))

(defun pichat-markdown-table-view--move-row (direction)
  "Move by one semantic table row in DIRECTION, skipping delimiters."
  (let ((origin (point))
        moved)
    (beginning-of-line)
    (when (= 0 (forward-line direction))
      (while (and (not (if (> direction 0) (eobp) (bobp)))
                  (pichat-markdown-table-view--separator-line-p)
                  (= 0 (forward-line direction))))
      (unless (or (and (> direction 0) (eobp))
                  (and (< direction 0) (bobp)
                       (= origin (point-min))))
        (setq moved t)))
    (unless moved (goto-char origin))
    moved))

(defun pichat-markdown-table-view-next-row ()
  "Move to the next semantic row in this table viewer."
  (interactive)
  (pichat-markdown-table-view--move-row 1))

(defun pichat-markdown-table-view-previous-row ()
  "Move to the previous semantic row in this table viewer."
  (interactive)
  (pichat-markdown-table-view--move-row -1))

(defun pichat-markdown-table-view-reset ()
  "Return to the first table row and reset horizontal scrolling."
  (interactive)
  (goto-char (point-min))
  (set-window-hscroll (pichat-markdown-table-view--window) 0))

(defun pichat-markdown-table-view-return-to-origin ()
  "Return to this snapshot's origin when its logical table is still current."
  (interactive)
  (let ((position
         (and (functionp pichat-markdown-table-view-origin-resolver)
              (condition-case nil
                  (funcall pichat-markdown-table-view-origin-resolver
                           pichat-markdown-table-view-origin-buffer
                           pichat-markdown-table-view-origin-key
                           pichat-markdown-table-view-origin-generation
                           pichat-markdown-table-view-origin-marker)
                (error nil)))))
    (unless (and (buffer-live-p pichat-markdown-table-view-origin-buffer)
                 (integer-or-marker-p position))
      (user-error "PiChat table origin is stale"))
    (pichat-view-return pichat-markdown-table-view-origin-buffer 'quit)
    (goto-char position)))

(defun pichat-markdown-table-view-quit ()
  "Kill the current viewer and restore its display window."
  (interactive)
  (pichat-view-quit))

(provide 'pichat-markdown-table)
;;; pichat-markdown-table.el ends here
