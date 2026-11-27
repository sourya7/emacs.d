;;; json-explore.el --- Read-only navigation of typed JSON -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'vui)
(require 'vui-components)
(require 'view)

(defgroup json-explore nil
  "Browse finite JSON values."
  :group 'tools)

(defface json-explore-string-face
  '((t :inherit font-lock-string-face))
  "Face for JSON string values."
  :group 'json-explore)

(defface json-explore-constant-face
  '((t :inherit font-lock-constant-face))
  "Face for JSON null and booleans."
  :group 'json-explore)

(defface json-explore-number-face
  '((t :inherit font-lock-number-face))
  "Face for JSON numbers."
  :group 'json-explore)

(defface json-explore-summary-face
  '((t :inherit shadow))
  "Face for JSON collection summaries."
  :group 'json-explore)

(defcustom json-explore-row-limit 500
  "Maximum number of rows rendered in each table (at least one)."
  :type 'natnum)

(defcustom json-explore-cell-width 40
  "Maximum display width of a cell summary (at least eight)."
  :type 'natnum)

(defconst json-explore-missing (make-symbol "json-explore-missing")
  "Sentinel for an absent object member, distinct from JSON null.")

(defun json-explore-parse (text)
  "Parse JSON TEXT, preserving objects, arrays, null and false separately."
  (json-parse-string text :object-type 'hash-table :array-type 'array
                     :null-object :null :false-object :false))

(defun json-explore--json (value)
  (json-serialize value :null-object :null :false-object :false))

(defun json-explore--width ()
  (max 8 json-explore-cell-width))

(defun json-explore--clip (text)
  (truncate-string-to-width text (json-explore--width) nil nil "…"))

(defconst json-explore--display-control-re "[\u0000-\u001f\u007f-\u009f\u2028\u2029]"
  "Control characters and Unicode line/paragraph separators.")

(defun json-explore--escaped-label (text &optional full)
  ;; Bound encoding work even for large values. Encode controls that
  ;; `json-serialize' is allowed to leave literal, too.
  (replace-regexp-in-string
   "[\u007f-\u009f\u2028\u2029]" (lambda (match) (format "\\u%04x" (aref match 0)))
   (decode-coding-string
    (json-explore--json (substring-no-properties
                        text 0 (unless full (min (length text) (json-explore--width)))))
    'utf-8)
   t t))

(defun json-explore--quote-string-p (text)
  (or (string-empty-p text)
      (member text '("null" "true" "false"))
      (string-match-p "\\`-?\\(?:0\\|[1-9][0-9]*\\)\\(?:\\.[0-9]+\\)?\\(?:[eE][+-]?[0-9]+\\)?\\'" text)
      (cl-some (lambda (c) (memq (get-char-code-property c 'general-category) '(Zs Zl Zp)))
               (list (aref text 0) (aref text (1- (length text)))))
      (string-match-p json-explore--display-control-re text)))

(defun json-explore--key-label (key)
  (json-explore--clip
   (cond ((string-empty-p key) "⟨empty key⟩")
         ((string-match-p json-explore--display-control-re key)
          (substring (json-explore--escaped-label key) 1 -1))
         (t (substring-no-properties key)))))

(defun json-explore--summary (value &optional full)
  (pcase-let
      ((`(,text . ,face)
        (cond
         ((eq value json-explore-missing) '("<missing>"))
         ((hash-table-p value)
          (cons (if (zerop (hash-table-count value)) "{}"
                  (format "{%d keys}" (hash-table-count value)))
                'json-explore-summary-face))
         ((vectorp value)
          (cons (if (zerop (length value)) "[]" (format "[%d items]" (length value)))
                'json-explore-summary-face))
         ((stringp value)
          (cons (if (json-explore--quote-string-p value)
                    (json-explore--escaped-label value full)
                  (substring-no-properties value))
                'json-explore-string-face))
         ((numberp value) (cons (json-explore--json value) 'json-explore-number-face))
         (t (cons (json-explore--json value) 'json-explore-constant-face)))))
    (let ((label (if full text (json-explore--clip text))))
      (if face (propertize label 'face face) label))))

(defun json-explore-path-string (path)
  "Return a jq expression for PATH, a list of string keys and array indices."
  (concat "." (mapconcat (lambda (part) (format "[%s]" (json-explore--json part)))
                         path "")))

;; A view owns its snapshot and its navigation state, not its rendered text.
;; Row IDs are the original array indices or object keys.  Column IDs are
;; symbols for structural columns and strings for actual object members.
(cl-defstruct (json-explore--view (:constructor json-explore--make-view))
  value path label columns rows cell start hscroll source diagnostic snapshot
  presentation tables layouts active-tables column-spec section-defaults)

(cl-defstruct (json-explore--source (:constructor json-explore--make-source))
  program argv directory label context success-codes validate columns view value)

(cl-defun json-explore-make-source (&key program argv directory label context
                                        (success-codes '(0)) validate columns view value
                                        &allow-other-keys)
  "Describe a local PROGRAM and ARGV, or a static JSON VALUE without PROGRAM.
DIRECTORY defaults to the caller's `default-directory' for commands.  LABEL
names the source; CONTEXT is opaque and retained through drill and refresh.
Only SUCCESS-CODES are parsed.  VALIDATE receives (parsed-value exit-code)
and signals an error to reject a result without replacing the last good view.
COLUMNS selects root object-array columns as (KEY HEADER [FORMATTER]); the
optional formatter receives the typed value and returns display text only.
VIEW is called with (value view-context) and returns a vui vnode or nil to
use the generic renderer.  Treat the source and its values as read-only."
  (json-explore--make-source
   :program (copy-sequence program) :argv (mapcar #'copy-sequence argv)
   :directory (if (or program directory)
                  (json-explore--local-directory (or directory default-directory))
                default-directory)
   :label (or label program "JSON") :context context
   :success-codes (copy-sequence success-codes) :validate validate
   :columns columns :view view :value value))

(defun json-explore-source-program (source)
  "Return SOURCE's executable, or nil for a static source."
  (json-explore--source-program source))

(defun json-explore-source-argv (source)
  "Return SOURCE's arguments, excluding the executable."
  (json-explore--source-argv source))

(defun json-explore-source-directory (source)
  "Return SOURCE's captured working directory."
  (json-explore--source-directory source))

(defun json-explore-source-label (source)
  "Return SOURCE's display label."
  (json-explore--source-label source))

(defun json-explore-source-context (source)
  "Return SOURCE's opaque context."
  (json-explore--source-context source))

(defun json-explore-source-success-codes (source)
  "Return SOURCE's accepted exit codes."
  (json-explore--source-success-codes source))

(defun json-explore-source-validate (source)
  "Return SOURCE's result validator, if any."
  (json-explore--source-validate source))

(defun json-explore-source-columns (source)
  "Return SOURCE's root table column specification, if any."
  (json-explore--source-columns source))

(defun json-explore-source-view (source)
  "Return SOURCE's custom view renderer, if any."
  (json-explore--source-view source))

(defun json-explore-source-value (source)
  "Return SOURCE's static value, if supplied."
  (json-explore--source-value source))

(cl-defstruct (json-explore--request (:constructor json-explore--make-request))
  process pipe stdout stderr)

(defvar-local json-explore--request nil)
(defvar-local json-explore--generation 0)
(defvar-local json-explore--view nil)
(defvar-local json-explore--back nil)
(defvar-local json-explore--forward nil)
(defvar-local json-explore--inspection nil)

(defvar json-explore-open-functions nil
  "Abnormal hook for opening a JSON cell.
Functions receive the plist from `json-explore-thing-at-point' and one of
`drill', `other-window' or `display'.  The first non-nil result wins;
otherwise the standard action runs.  No handlers run off a cell.
Use `add-hook' with LOCAL non-nil for adapter-specific handlers.")

(defvar-local json-explore-view-function nil
  "Optional fallback renderer for this buffer when its source has no :view.
Called with (value view-context), as in `json-explore-make-source'.")

(defvar json-explore-visit-functions nil
  "Abnormal hook for finding a location for `json-explore-visit'.
Functions receive the thing-at-point plist (nil off a cell).  Return nil
for no match, a live buffer, or a plist with :file (an absolute local
file) or :buffer (a live buffer) and optional :line (one-based).
Use :buffer when the handler needs to control how the file is opened.
The first non-nil result wins.")

(defun json-explore-current-source ()
  "Return the current view's source, or nil outside an explorer."
  (when json-explore--view (json-explore--view-source json-explore--view)))

(defun json-explore-current-context ()
  "Return the current source's opaque context, or nil."
  (when-let* ((source (json-explore-current-source)))
    (json-explore-source-context source)))

(defun json-explore-current-value ()
  "Return the current view's typed JSON value, or nil before a result."
  (when json-explore--view (json-explore--view-value json-explore--view)))

(defun json-explore-current-snapshot ()
  "Return the root JSON snapshot backing the current history entry."
  (when json-explore--view (json-explore--view-snapshot json-explore--view)))

(defun json-explore-current-path ()
  "Return the current view's absolute JSON path, nil at the root."
  (when json-explore--view (json-explore--view-path json-explore--view)))

(defun json-explore--breadcrumb (width)
  (let* ((label (replace-regexp-in-string "[[:cntrl:]]" " "
                                          (json-explore--view-label json-explore--view)))
         (separator " › ")
         (prefix (concat "…" separator))
         (segments
          (cons label (mapcar (lambda (part)
                                (if (and (stringp part)
                                         (string-match-p "\\`[a-zA-Z_][a-zA-Z_0-9]*\\'" part))
                                    part
                                  (format "[%s]" (json-explore--json part))))
                              (json-explore--view-path json-explore--view))))
         (full (string-join segments separator)))
    (cond
     ((<= (string-width full) width) full)
     ((or (not (cdr segments)) (<= width (string-width prefix)))
      (truncate-string-to-width (if (cdr segments) prefix label) width nil nil "…"))
     (t
      (let* ((segments (reverse (cdr segments)))
             (budget (- width (string-width prefix)))
             (tail (truncate-string-to-width (pop segments) budget nil nil "…")))
        (while (and segments
                    (<= (+ (string-width tail) (string-width separator)
                           (string-width (car segments))) budget))
          (setq tail (concat (pop segments) separator tail)))
        (concat prefix tail))))))

(defun json-explore--install-breadcrumb ()
  ;; Redisplay selects the header's window, including when VUI falls back
  ;; to this construct rather than pinning a table's column headers.
  (setq-local header-line-format
              '(:eval (replace-regexp-in-string
                       "%" "%%" (json-explore--breadcrumb (window-width))))))

(defun json-explore--object-array-p (value)
  (and (vectorp value) (> (length value) 0) (cl-every #'hash-table-p value)))

(defun json-explore--new-view (value path)
  (let (columns rows)
    (cond
     ((hash-table-p value)
      (setq columns '(key value))
      (maphash (lambda (key val)
                 (unless (json-explore--section-p val) (push key rows))) value)
      (setq rows (nreverse rows)))
     ((vectorp value)
      (setq rows (number-sequence 0 (1- (length value))))
      (if (json-explore--object-array-p value)
          (let ((seen (make-hash-table :test #'equal)))
            (cl-loop for object across value do
                     (maphash (lambda (key _val)
                                (unless (gethash key seen)
                                  (puthash key t seen)
                                  (push key columns)))
                              object))
            (setq columns (cons 'index (nreverse columns))))
        (setq columns '(index value))))
     (t (setq columns '(value) rows '(scalar))))
    (json-explore--make-view :value value :path path :columns columns :rows rows)))

(defun json-explore--section-p (value)
  (or (hash-table-p value) (vectorp value)))

(defun json-explore--lookup (view path)
  (let ((prefix (json-explore--view-path view)))
    (when (equal prefix (seq-take path (length prefix)))
      (json-explore--at-path (json-explore--view-value view)
                             (nthcdr (length prefix) path) t))))

(defun json-explore--table-view (view path)
  (if (equal path (json-explore--view-path view)) view
    (let ((cache (or (json-explore--view-tables view)
                     (setf (json-explore--view-tables view)
                           (make-hash-table :test #'equal)))))
      (or (gethash path cache)
          (puthash path (json-explore--new-view (json-explore--lookup view path) path)
                   cache)))))

(defun json-explore--cell-key (view row column)
  (list (json-explore--view-path view) row column))

(defun json-explore--cell-at (&optional pos)
  (let* ((pos (or pos (point))) (key (vui-key-at pos)))
    ;; A collapsible also puts its key on unkeyed text in its body.
    (when (and (consp key) (listp (car key))
               (or (not (eq (nth 2 key) 'section)) (button-at pos)
                   (and (save-excursion (goto-char pos) (and (eolp) (not (bolp))))
                        (button-at (1- pos)))))
      key)))

(defun json-explore--row-value (value row column)
  (cond ((eq row 'scalar) value)
        ((hash-table-p value) (gethash row value))
        ((stringp column) (gethash column (aref value row) json-explore-missing))
        (t (aref value row))))

(defun json-explore--cell-value (view cell)
  (pcase-let ((`(,path ,row ,column) cell))
    (json-explore--row-value (json-explore--lookup view path) row column)))

(defun json-explore--cell-path (cell)
  (pcase-let ((`(,path ,row ,column) cell))
    (if (eq row 'scalar) path
      (append path (list row) (when (stringp column) (list column))))))

(defun json-explore-thing-at-point ()
  "Return a plist describing the selected JSON cell, or nil off a cell.
Keys are :path (absolute), :row (original key or index, or `scalar'),
:row-value (the whole row value), :column, :value, :source and :context.
Display formatting does not change these values.  Treat them as read-only."
  (when-let* ((cell (json-explore--cell-at)))
    (pcase-let ((`(,path ,row ,column) cell))
      (list :path (json-explore--cell-path cell) :row row :column column
            :row-value (json-explore--row-value (json-explore--lookup json-explore--view path)
                                               row nil)
            :value (json-explore--cell-value json-explore--view cell)
            :source (json-explore-current-source) :context (json-explore-current-context)))))

(defun json-explore--display-value (view row column)
  (if (memq column '(key index)) row
    (json-explore--row-value (json-explore--view-value view) row column)))

(defun json-explore--sort-key (value)
  "Order by type, then by numeric value, string, or container size."
  (cond
   ((eq value json-explore-missing) '(0 . 0))
   ((eq value :null) '(1 . 0))
   ((eq value :false) '(2 . 0))
   ((eq value t) '(2 . 1))
   ((numberp value) (cons 3 value))
   ((stringp value) (cons 4 value))
   ((vectorp value) (cons 5 (length value)))
   ((hash-table-p value) (cons 6 (hash-table-count value)))))

(defun json-explore--less-p (a b)
  (if (= (car a) (car b))
      (if (= (car a) 4) (string-lessp (cdr a) (cdr b)) (< (cdr a) (cdr b)))
    (< (car a) (car b))))

(defun json-explore--visible-rows (view sort)
  (let* ((rows (json-explore--view-rows view))
         (column (car sort))
         (descending (cdr sort))
         (limit (min (length rows) (max 1 json-explore-row-limit))))
    (when column
      (setq rows
            (mapcar #'car
                    (cl-stable-sort
                     (mapcar (lambda (row)
                               (cons row (json-explore--sort-key
                                          (json-explore--display-value
                                           view row column))))
                             rows)
                     (if descending (lambda (a b) (json-explore--less-p b a))
                       #'json-explore--less-p)
                     :key #'cdr))))
    (seq-take rows limit)))

(defun json-explore--header (column)
  (pcase column
    ('key "Key") ('index "Index") ('value "Value")
    (_ (json-explore--key-label column))))

(defun json-explore--column-spec (view column)
  (assoc column (json-explore--view-column-spec view)))

(defun json-explore--column-header (view column)
  (or (nth 1 (json-explore--column-spec view column)) (json-explore--header column)))

(defun json-explore--label (view row column)
  (let ((value (json-explore--display-value view row column))
        (formatter (nth 2 (json-explore--column-spec view column))))
    (cond ((and formatter (not (eq value json-explore-missing)))
           (json-explore--clip (funcall formatter value)))
          ((eq column 'key) (json-explore--key-label value))
          (t (json-explore--summary value)))))

(defun json-explore--table (view rows)
  (let* ((columns (json-explore--view-columns view))
         (headers (mapcar (lambda (column) (json-explore--column-header view column)) columns))
         (labels (mapcar (lambda (row)
                           (mapcar (lambda (column)
                                     (json-explore--label view row column))
                                   columns))
                         rows))
         (widths (vconcat (mapcar #'string-width headers))))
    ;; Key the padding too, so native vertical motion keeps the column
    ;; even on a shorter label.  Keyed regions leave RET and TAB to the
    ;; mode maps (vui buttons bind them before Evil can see them).
    (dolist (line labels)
      (cl-loop for label in line for i from 0 do
               (aset widths i (max (aref widths i) (string-width label)))))
    (vui-table
     :sticky-header t
     :columns (cl-loop for name in headers for width across widths
                       collect (list :header name :width width))
     :rows (cl-loop for row in rows for line in labels collect
                    (cl-loop for column in columns for label in line
                             for width across widths
                             collect (vui-region :key (json-explore--cell-key view row column)
                                       (vui-text (concat label
                                                         (make-string (- width (string-width label)) ?\s)))))))))

;; Each node carries only its own presentation and that of its descendants.
;; Replacing a node leaves sibling props untouched, so their memoized
;; components don't rebuild tables. History retains immutable root nodes.
(defun json-explore--presentation ()
  (vui-get-state (vui-get-instance) :presentation))

(defun json-explore--presentation-at (path)
  (let ((node (json-explore--presentation)))
    (dolist (part (nthcdr (length (json-explore--view-path json-explore--view)) path) node)
      (setq node (cdr (assoc part (plist-get node :children)))))))

(defun json-explore--edit-presentation (node path update)
  (if (null path) (funcall update (copy-sequence node))
    (let* ((children (plist-get node :children))
           (old (assoc (car path) children))
           (new (json-explore--edit-presentation (cdr old) (cdr path) update)))
      (plist-put (copy-sequence node) :children
                 (cons (cons (car path) new) (remq old children))))))

(defun json-explore--wrap-field (text width)
  "Split TEXT into lines of WIDTH columns, preserving its faces and text.
Prefer breaks at spaces, but split long words (including file paths)."
  (let (lines)
    (dolist (line (split-string text "\n"))
      (let ((start 0) (end 0) (column 0) space)
        (while (< end (length line))
          (let* ((char (aref line end))
                 (size (max 0 (char-width char))))
            (if (and (> (+ column size) width) (> end start))
                (let ((break (or space end)))
                  (push (substring line start break) lines)
                  (setq start break end break column 0 space nil))
              (cl-incf end)
              (cl-incf column size)
              (when (eq char ?\s) (setq space end)))))
        (push (substring line start) lines)))
    (nreverse lines)))

(defun json-explore--fields (view rows width outer-indent)
  (let* ((width (- width outer-indent))
         (gap 2)
         (labels (mapcar (lambda (row)
                           (truncate-string-to-width
                            (or (nth 1 (json-explore--column-spec view row))
                                (json-explore--key-label row))
                            (max 1 (- width gap 4)) nil nil "…"))
                         rows))
         (label-width (apply #'max 0 (mapcar #'string-width labels)))
         (indent (+ label-width gap))
         (value-width (max 1 (- width indent)))
         (continuation (concat "\n" (make-string (+ outer-indent indent) ?\s))))
    (apply #'vui-vstack
           (cl-mapcar
            (lambda (row label)
              (let* ((value (json-explore--display-value view row 'value))
                     (formatter (nth 2 (json-explore--column-spec view row)))
                     (text (if formatter (funcall formatter value)
                             (json-explore--summary value t))))
                (vui-hstack :spacing gap
                  (vui-region :key (json-explore--cell-key view row 'key)
                    (vui-text (concat label (make-string (- label-width (string-width label)) ?\s))))
                  (vui-region :key (json-explore--cell-key view row 'value)
                    (vui-text (if (string-empty-p text) " "
                                (string-join (json-explore--wrap-field text value-width)
                                             continuation)))))))
            rows labels))))

(vui-defcomponent json-explore--table-component (view sort row-limit cell-width field-width)
  :memo t
  :render
  (let* ((json-explore-row-limit row-limit)
         (json-explore-cell-width cell-width)
         (sort (and (member (car sort) (json-explore--view-columns view)) sort))
         (rows (json-explore--visible-rows view sort))
         (total (length (json-explore--view-rows view)))
         (column (car sort))
         (value (json-explore--view-value view)))
    (vui-vstack
     (when column
       (vui-text (format "Sorted by %s (%s)" (json-explore--column-header view column)
                         (if (cdr sort) "descending" "ascending"))))
     (when (< (length rows) total)
       (vui-text (format "showing %d of %d" (length rows) total)))
     (cond ((and rows (hash-table-p value))
            (json-explore--fields view rows field-width
                                  (vui-use-context vui-collapsible-indent-context)))
           (rows (json-explore--table view rows))
           ((or (vectorp value) (and (hash-table-p value) (zerop (hash-table-count value))))
            (vui-text (json-explore--summary value)))))))

(defun json-explore--active-table (path)
  (or (and (json-explore--view-active-tables json-explore--view)
           (gethash path (json-explore--view-active-tables json-explore--view)))
      (json-explore--table-view json-explore--view path)))

(defun json-explore--layout-table (path spec fields)
  (let* ((view json-explore--view)
         (layouts (or (json-explore--view-layouts view)
                      (setf (json-explore--view-layouts view) (make-hash-table :test #'equal))))
         (active (or (json-explore--view-active-tables view)
                     (setf (json-explore--view-active-tables view) (make-hash-table :test #'equal))))
         (key (list path spec fields))
         (base (json-explore--table-view view path)))
    (puthash
     path
     (if (not spec) base
       (or (gethash key layouts)
           (let ((table (copy-json-explore--view base)))
             (setf (json-explore--view-column-spec table) spec)
             (cond (fields
                    (setf (json-explore--view-rows table)
                          (seq-filter (lambda (key) (gethash key (json-explore--view-value table)))
                                      (mapcar #'car spec))))
                   ((json-explore--object-array-p (json-explore--view-value table))
                    (setf (json-explore--view-columns table) (cons 'index (mapcar #'car spec)))))
             (puthash key table layouts))))
     active)))

(cl-defun json-explore-table (&key (path (json-explore-current-path)) columns &allow-other-keys)
  "Render the array at absolute PATH as a navigable vui table vnode.
Call during a source's VIEW renderer.  PATH defaults to the current view.
COLUMNS uses (KEY HEADER [FORMATTER]) for arrays of objects.  Use only one
cell layout per path.  Sorting operates on the typed values, not labels."
  (when (vectorp (json-explore--lookup json-explore--view path))
    (vui-component 'json-explore--table-component :key (list :table path)
      :view (json-explore--layout-table path columns nil)
      :field-width (and (hash-table-p (json-explore--lookup json-explore--view path))
                        (json-explore--field-window-width))
      :sort (plist-get (json-explore--presentation-at path) :sort)
      :row-limit json-explore-row-limit :cell-width json-explore-cell-width)))

(cl-defun json-explore-fields (&key (path (json-explore-current-path)) fields &allow-other-keys)
  "Render object fields at absolute PATH as a navigable vui vnode.
Call during a source's VIEW renderer.  FIELDS selects (KEY LABEL [FORMATTER])
in order, skipping absent keys.  Without FIELDS show the scalar fields."
  (when (hash-table-p (json-explore--lookup json-explore--view path))
    (vui-component 'json-explore--table-component :key (list :fields path)
      :view (json-explore--layout-table path fields t)
      :field-width (json-explore--field-window-width)
      :sort (plist-get (json-explore--presentation-at path) :sort)
      :row-limit json-explore-row-limit :cell-width json-explore-cell-width)))

(cl-defun json-explore-section (&key path title expanded body &allow-other-keys)
  "Render a fold at absolute PATH, a member of the current view's JSON.
Call during a source's VIEW renderer.  TITLE overrides the default summary;
EXPANDED is the initial state.  BODY is an optional vnode displayed when
open; by default the generic page for that value is shown.  The heading
itself is navigable and refers to the typed value at PATH."
  (when (and (not (equal path (json-explore-current-path)))
             (json-explore--lookup json-explore--view path))
    (let ((defaults (or (json-explore--view-section-defaults json-explore--view)
                        (setf (json-explore--view-section-defaults json-explore--view)
                              (make-hash-table :test #'equal)))))
      (puthash path expanded defaults))
    (vui-component 'json-explore--section :key (list :section path)
      :view json-explore--view :path path :node (json-explore--presentation-at path)
      :field-width (json-explore--field-window-width)
      :title title :body body :expanded (json-explore--fold-open-p path expanded)
      :row-limit json-explore-row-limit :cell-width json-explore-cell-width)))

(defun json-explore--page (view path node)
  (let ((table (json-explore--table-view view path)) sections)
    (when (hash-table-p (json-explore--view-value table))
      (maphash
       (lambda (key value)
         (when (json-explore--section-p value)
           (let ((section-path (append path (list key))))
             (push (vui-component 'json-explore--section :key (list :section section-path)
                     :view view :path section-path :node (cdr (assoc key (plist-get node :children)))
                     :field-width (and (hash-table-p value) (json-explore--field-window-width))
                     :expanded (json-explore--fold-open-p section-path nil)
                     :row-limit json-explore-row-limit :cell-width json-explore-cell-width)
                   sections))))
       (json-explore--view-value table)))
    (apply #'vui-vstack
           (vui-component 'json-explore--table-component :key (list :table path)
             :view table :sort (plist-get node :sort)
             :field-width (and (hash-table-p (json-explore--view-value table))
                               (json-explore--field-window-width))
             :row-limit json-explore-row-limit :cell-width json-explore-cell-width)
           (nreverse sections))))

(vui-defcomponent json-explore--section (view path node row-limit cell-width title body expanded field-width)
  ;; Propagate resize through memoized sections to any fields in the body.
  :memo t
  :render
  (let* ((json-explore-row-limit row-limit)
         (json-explore-cell-width cell-width)
         (row (car (last path)))
         (value (json-explore--lookup view path)))
    (vui-collapsible :key (list (butlast path) row 'section)
      :title (or title (concat (if (stringp row) (json-explore--key-label row)
                                (json-explore--summary row))
                              "  " (json-explore--summary value)))
      :expanded-indicator "▾" :collapsed-indicator "▸"
      :expanded expanded :on-toggle (lambda (open) (json-explore--set-fold path open))
      (when expanded (or body (json-explore--page view path node))))))

(defun json-explore--custom-page (view)
  (let* ((source (json-explore--view-source view))
         (renderer (or (and source (json-explore-source-view source))
                       json-explore-view-function)))
    (when renderer
      (funcall renderer (json-explore--view-value view)
               (list :path (json-explore--view-path view) :source source
                     :context (json-explore-current-context)
                     :snapshot (json-explore--view-snapshot view))))))

(defvar-local json-explore--rendered-width nil)

(vui-defcomponent json-explore--root ()
  :state ((presentation nil))
  :render
  (let* ((view json-explore--view)
         (commit (make-symbol "explorer-render"))
         (width (json-explore--field-window-width))
         ;; A reflow changes line text, so VUI's text-based point restoration
         ;; may land on another field. Keep the cell selected across a resize.
         (cell (and json-explore--rendered-width
                    (/= width json-explore--rendered-width)
                    (json-explore--cell-at))))
    (setf (json-explore--view-active-tables view) nil
          (json-explore--view-section-defaults view) nil)
    ;; The collapsible may be redrawn by vui itself (e.g. on resize).
    (vui-use-effect (commit)
      (setq json-explore--rendered-width width)
      (json-explore--key-table-whitespace)
      (json-explore--prepare-sections)
      (when (and cell (not (equal cell (json-explore--cell-at))))
        (vui-goto-key cell))
      nil)
    (vui-vstack
     (when json-explore--request
       (vui-text "Running command…" :face 'shadow))
     (when-let* ((diagnostic (json-explore--view-diagnostic view)))
       (apply #'vui-vstack
              (mapcar (lambda (line) (vui-text line :face 'warning))
                      (split-string diagnostic "\n"))))
     (cond ((json-explore--view-value view)
            (or (json-explore--custom-page view)
                (json-explore--page view (json-explore--view-path view) presentation)))
           ((not (json-explore--view-diagnostic view))
            (vui-text "No JSON result yet."))))))

(defun json-explore--window ()
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)
    (get-buffer-window)))

(defun json-explore--field-window-width ()
  ;; Match the window chosen by VUI's resize hook; the body excludes margins.
  (window-body-width (or (get-buffer-window nil t) (selected-window))))

(defun json-explore--save-position ()
  (setf (json-explore--view-cell json-explore--view) (json-explore--cell-at)
        (json-explore--view-presentation json-explore--view) (json-explore--presentation))
  (when-let* ((window (json-explore--window)))
    (setf (json-explore--view-start json-explore--view) (window-start window)
          (json-explore--view-hscroll json-explore--view) (window-hscroll window))))

(defun json-explore--cell-positions ()
  (let ((pos (point-min)) positions)
    (while (< pos (point-max))
      (let ((key (get-text-property pos 'vui-key)))
        (when (or (and (consp key) (listp (car key)) (not (eq (nth 2 key) 'section)))
                  (and (button-at pos) (eq (nth 2 (json-explore--cell-at pos)) 'section)))
          (push pos positions)))
      (setq pos (min (next-single-property-change pos 'vui-key nil (point-max))
                     (next-single-property-change pos 'button nil (point-max)))))
    (vconcat (nreverse positions))))

(defun json-explore-next-cell (count)
  "Move COUNT cells forward (backward if negative), wrapping at the ends."
  (interactive "p")
  (let* ((positions (json-explore--cell-positions))
         (len (length positions))
         (pos (point)))
    (unless (or (zerop count) (zerop len))
      (let* ((key (json-explore--cell-at))
             (index (cl-position-if
                     (lambda (p)
                       (and (if (> count 0) (> p pos) (< p pos))
                            (not (and key (equal key (json-explore--cell-at p))))))
                     positions :from-end (< count 0))))
        (goto-char (aref positions (mod (+ (or index (if (> count 0) 0 (1- len)))
                                           (if (> count 0) (1- count) (1+ count)))
                                        len)))))))

(defun json-explore-previous-cell (count)
  "Move COUNT cells backward, wrapping at the ends."
  (interactive "p")
  (json-explore-next-cell (- count)))

(defun json-explore--first-cell ()
  (let ((positions (json-explore--cell-positions)))
    (goto-char (if (length= positions 0) (point-min) (aref positions 0)))))

(defvar json-explore--section-mouse-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] #'push-button)
    map)
  "Let disclosure buttons handle mouse clicks, but leave keys to the mode.")

(defun json-explore--key-table-whitespace ()
  ;; VUI inserts table separators and section indentation outside the
  ;; keyed cell regions. Extend the keys after layout, without changing
  ;; widths or rebuilding memoized tables.
  (with-silent-modifications
    (save-excursion
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((key (get-text-property pos 'vui-key)))
            ;; Every data row starts with an index cell; headers don't.
            (when (and (consp key) (eq (nth 2 key) 'index))
              (goto-char pos)
              (let ((end (line-end-position))
                    (row (butlast key)))
                (skip-chars-backward " " (line-beginning-position))
                (when (bolp) (put-text-property (point) pos 'vui-key key))
                (while (< pos end)
                  (let* ((gap (next-single-property-change pos 'vui-key nil end))
                         (next (next-single-property-change gap 'vui-key nil end))
                         (next-key (get-text-property next 'vui-key)))
                    (if (and (< next end) (consp next-key)
                             (equal row (butlast next-key)))
                        (progn
                          (put-text-property gap next 'vui-key key)
                          (setq pos next key next-key))
                      (setq pos end)))))))
          (setq pos (next-single-property-change pos 'vui-key nil (point-max))))))))

(defun json-explore--prepare-sections ()
  ;; vui-collapsible uses a button whose RET and TAB would shadow the
  ;; explorer's drill and next-cell keys (including Evil overrides).
  (let ((pos (point-min)) (inhibit-read-only t))
    (with-silent-modifications
      (while (< pos (point-max))
        (let ((end (next-single-property-change pos 'button nil (point-max))))
          (when (and (button-at pos) (eq (nth 2 (json-explore--cell-at pos)) 'section))
            (put-text-property pos end 'keymap json-explore--section-mouse-map))
          (setq pos end))))))

(defun json-explore--render (&optional restore-scroll)
  (force-mode-line-update)
  (let ((presentation (json-explore--view-presentation json-explore--view)))
    (if (eq presentation (json-explore--presentation))
        (vui-refresh)
      (vui-set-state :presentation presentation (vui-get-instance))))
  (vui-flush-sync)
  (unless (and (json-explore--view-cell json-explore--view)
               (vui-goto-key (json-explore--view-cell json-explore--view)))
    (json-explore--first-cell))
  (when restore-scroll
    (when-let* ((window (json-explore--window)))
      (set-window-point window (point))
      (set-window-start window (min (point-max)
                                   (or (json-explore--view-start json-explore--view) (point-min))))
      (set-window-hscroll window (or (json-explore--view-hscroll json-explore--view) 0)))))

(defun json-explore-back ()
  "Return to the previous JSON view without refetching it."
  (interactive)
  (unless json-explore--back (user-error "No previous JSON view"))
  (json-explore--cancel-request)
  (json-explore--save-position)
  (push json-explore--view json-explore--forward)
  (setq json-explore--view (pop json-explore--back))
  (json-explore--render t))

(defun json-explore-forward ()
  "Return to the next JSON view in history."
  (interactive)
  (unless json-explore--forward (user-error "No next JSON view"))
  (json-explore--cancel-request)
  (json-explore--save-position)
  (push json-explore--view json-explore--back)
  (setq json-explore--view (pop json-explore--forward))
  (json-explore--render t))

(defun json-explore--selected-cell ()
  (or (json-explore--cell-at) (user-error "Point is not on a JSON cell")))

(defun json-explore--move-column (step)
  (pcase-let ((`(,path ,row ,column) (json-explore--selected-cell)))
    (unless (eq column 'section)
      (let* ((columns (json-explore--view-columns
                       (json-explore--active-table path)))
             (next (nth (mod (+ (cl-position column columns :test #'equal) step)
                             (length columns))
                        columns)))
        (vui-goto-key (list path row next))))))

(defun json-explore-next-column (count)
  "Move COUNT columns right within the current row, wrapping."
  (interactive "p")
  (json-explore--move-column count))

(defun json-explore-previous-column (count)
  "Move COUNT columns left within the current row, wrapping."
  (interactive "p")
  (json-explore--move-column (- count)))

(defun json-explore--update-presentation (path update)
  (json-explore--save-position)
  (setf (json-explore--view-presentation json-explore--view)
        (json-explore--edit-presentation
         (json-explore--presentation)
         (nthcdr (length (json-explore--view-path json-explore--view)) path)
         update))
  (json-explore--render))

(defun json-explore--sort-at (path)
  (let ((sort (plist-get (json-explore--presentation-at path) :sort)))
    (when (member (car sort) (json-explore--view-columns
                              (json-explore--active-table path)))
      sort)))

(defun json-explore--set-sort (reverse)
  (pcase-let ((`(,path ,_row ,column) (json-explore--selected-cell)))
    (when (eq column 'section) (user-error "Select a cell within a table or field list"))
    (let* ((old (json-explore--sort-at path))
           (sort (if reverse (cons (or (car old) column) (not (cdr old)))
                   (cons column (and (equal column (car old)) (not (cdr old)))))))
      (json-explore--update-presentation path (lambda (node) (plist-put node :sort sort))))))

(defun json-explore-sort ()
  "Sort the table at point by its selected column; toggle on repeated use."
  (interactive)
  (json-explore--set-sort nil))

(defun json-explore-reverse-sort ()
  "Reverse the sort in the table at point, using the current column if unsorted."
  (interactive)
  (json-explore--set-sort t))

(defun json-explore--section-at ()
  (pcase-let ((`(,path ,row ,column) (json-explore--selected-cell)))
    (cond ((eq column 'section) (append path (list row)))
          ((not (equal path (json-explore--view-path json-explore--view))) path)
          (t (user-error "Point is not in a foldable section")))))

(defun json-explore--set-fold (path open)
  (json-explore--update-presentation path (lambda (node) (plist-put node :open open)))
  (unless open (vui-goto-key (list (butlast path) (car (last path)) 'section))))

(defun json-explore--fold-open-p (path default)
  (let ((node (json-explore--presentation-at path))
        (root (json-explore--presentation)))
    (cond ((plist-member node :open) (plist-get node :open))
          ((plist-member root :fold-default) (plist-get root :fold-default))
          (t default))))

(defun json-explore-toggle-section ()
  "Toggle the section at or enclosing point."
  (interactive)
  (let* ((path (json-explore--section-at))
         (defaults (json-explore--view-section-defaults json-explore--view)))
    (json-explore--set-fold path (not (json-explore--fold-open-p
                                      path (and defaults (gethash path defaults)))))))

(defun json-explore-open-section ()
  "Expand the section at or enclosing point."
  (interactive)
  (json-explore--set-fold (json-explore--section-at) t))

(defun json-explore-close-section ()
  "Collapse the section at or enclosing point."
  (interactive)
  (json-explore--set-fold (json-explore--section-at) nil))

(defun json-explore--reset-folds (node)
  (cl-loop for (key value) on node by #'cddr
           unless (eq key :open) append
           (list key (if (eq key :children)
                         (mapcar (lambda (child)
                                   (cons (car child) (json-explore--reset-folds (cdr child))))
                                 value)
                       value))))

(defun json-explore--fold-all (open)
  (let ((path (json-explore-current-path))
        (cell (json-explore--cell-at)))
    (json-explore--update-presentation
     path (lambda (node) (plist-put (json-explore--reset-folds node) :fold-default open)))
    (when (and (not open) cell (not (equal (car cell) path)))
      (vui-goto-key (list path (nth (length path) (car cell)) 'section)))))

(defun json-explore-open-all-sections ()
  "Expand all sections on the current page (without drilling into table rows)."
  (interactive)
  (json-explore--fold-all t))

(defun json-explore-close-all-sections ()
  "Collapse all sections on the current page."
  (interactive)
  (json-explore--fold-all nil))

(defun json-explore-copy-path ()
  "Copy the jq path of the cell at point, or of the current view."
  (interactive)
  (let ((path (json-explore-path-string
               (if-let* ((cell (json-explore--cell-at)))
                   (json-explore--cell-path cell)
                 (json-explore--view-path json-explore--view)))))
    (kill-new path)
    (message "%s" path)))

(defun json-explore--inspect-value (value raw stay &optional text-mode-function label)
  (unless (buffer-live-p json-explore--inspection)
    (setq json-explore--inspection
          (generate-new-buffer (format "*Inspect %s*" (string-trim (buffer-name) "[*]+" "[*]+")))))
  (let ((buffer json-explore--inspection))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if raw
            (progn (funcall (or text-mode-function #'text-mode)) (insert value))
          (special-mode)
          (if (eq value json-explore-missing)
              (insert "<missing: no such object member>")
            (insert (json-explore--json value))
            (json-pretty-print-buffer)))
        (setq buffer-read-only t)
        (when label
          (setq-local header-line-format (replace-regexp-in-string "%" "%%" label)))
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (let ((window (display-buffer buffer
                                  '((display-buffer-reuse-window display-buffer-pop-up-window)
                                    (inhibit-same-window . t)))))
      (when (and window (not stay)) (select-window window)))
    buffer))

(cl-defun json-explore-inspect-text (text &key mode stay label &allow-other-keys)
  "Display TEXT read-only in this explorer's reused inspection buffer.
MODE defaults to `text-mode'; LABEL is an optional header-line label.
With STAY keep focus in the explorer.  Return the inspection buffer."
  (json-explore--inspect-value text t stay mode label))

(cl-defun json-explore-inspect-value (value &key stay &allow-other-keys)
  "Inspect typed JSON VALUE read-only and return the reused buffer.
With STAY keep focus in the explorer."
  (json-explore--inspect-value value nil stay))

(defun json-explore--value-at-point ()
  (if-let* ((cell (json-explore--cell-at))) (json-explore--cell-value json-explore--view cell)
    (or (json-explore--view-value json-explore--view)
        (user-error "No JSON result yet"))))

(defun json-explore-inspect ()
  "Inspect the full, typed JSON value in the reused companion buffer."
  (interactive)
  (json-explore-inspect-value (json-explore--value-at-point)))

(defun json-explore--run-open-handlers (action)
  (when-let* ((thing (json-explore-thing-at-point)))
    (run-hook-with-args-until-success 'json-explore-open-functions thing action)))

(defun json-explore-open-other-window ()
  "Open the full cell in another window (strings as plain text)."
  (interactive)
  (unless (json-explore--run-open-handlers 'other-window)
    (let ((value (json-explore--value-at-point)))
      (json-explore--inspect-value value (stringp value) nil))))

(defun json-explore-display-other-window ()
  "Display the full cell in another window without selecting it."
  (interactive)
  (unless (json-explore--run-open-handlers 'display)
    (let ((value (json-explore--value-at-point)))
      (json-explore--inspect-value value (stringp value) t))))

(defun json-explore--open (cell)
  (let* ((value (json-explore--cell-value json-explore--view cell))
         (path (json-explore--cell-path cell)))
    (cond
     ((eq value json-explore-missing) (user-error "No such object member"))
     ((and (stringp value)
           (or (eq (nth 1 cell) 'scalar) (string-match-p "[\r\n]" value)
               (> (length value) (json-explore--width))
               (> (string-width (json-explore--json value)) (json-explore--width))))
      (json-explore--inspect-value value t nil))
     ((eq (nth 1 cell) 'scalar) (json-explore-inspect))
     (t
      (let ((next (json-explore--new-view value path)))
        (setf (json-explore--view-label next) (json-explore--view-label json-explore--view)
              (json-explore--view-source next) (json-explore--view-source json-explore--view)
              (json-explore--view-snapshot next) (json-explore--view-snapshot json-explore--view))
        (json-explore--push-view next))))))

(defun json-explore--push-view (next)
  (json-explore--cancel-request)
  (json-explore--save-position)
  (push json-explore--view json-explore--back)
  (setq json-explore--forward nil json-explore--view next)
  (json-explore--render t))

(defun json-explore-open ()
  "Drill into the cell at point.  Use its index/key cell to open a row."
  (interactive)
  (unless (json-explore--run-open-handlers 'drill)
    (json-explore--open (json-explore--selected-cell))))

(defun json-explore-visit ()
  "Visit the first location provided by `json-explore-visit-functions'."
  (interactive)
  (let* ((location (run-hook-with-args-until-success 'json-explore-visit-functions
                                                    (json-explore-thing-at-point)))
         (line (and (listp location) (plist-get location :line)))
         (buffer
          (cond ((buffer-live-p location) location)
                ((null location) (user-error "This view has no location"))
                ((and (listp location) (plist-member location :buffer))
                 (let ((target (plist-get location :buffer)))
                   (unless (buffer-live-p target)
                     (user-error "Explorer location requires a live buffer"))
                   target))
                ((listp location)
                 (let ((file (plist-get location :file)))
                   (unless (and (stringp file) (file-name-absolute-p file)
                                (not (file-remote-p file)) (file-regular-p file))
                     (user-error "No local file at %s" file))
                   (let ((enable-local-variables nil) (enable-local-eval nil))
                     (find-file-noselect file))))
                (t (user-error "Invalid explorer location"))))
         ;; A handler can set the target buffer's point. Save it before
         ;; selecting an existing window restores that window's own point.
         (position (with-current-buffer buffer (point)))
         (line-p (and (integerp line) (> line 0))))
    (pop-to-buffer buffer)
    (view-mode 1)
    (when line-p
      (widen)
      (goto-char (point-min))
      (forward-line (1- line))
      (setq position (point)))
    (set-window-point (selected-window) position)
    (when line-p
      (message "Snapshot line %d may be stale; refresh to check" line))))

(defun json-explore--kill-inspection ()
  (when (buffer-live-p json-explore--inspection)
    (kill-buffer json-explore--inspection)))

(define-derived-mode json-explore-mode vui-mode "JSON Explore"
  "Browse JSON cells.  RET drills into a cell; K inspects full JSON.
Use TAB/backtab to move between cells, gh/gl to move within a row in
Evil, and ordinary vertical motion to move between rows.  C-o/C-i
visit history, o/O sort the current table, and Y copies the jq path.
On object pages, za/zo/zc toggle/open/close a section; zR/zM open/close
all sections in Evil.  RET drills into a section in a new history entry.  Use gr
in Evil or C-c C-r to refresh a command snapshot explicitly.  Use
ordinary Emacs or Evil search keys to find rendered text."
  (setq-local truncate-lines t)
  (setq-local bidi-paragraph-direction 'left-to-right)
  (setq-local indent-tabs-mode nil)
  (add-hook 'kill-buffer-hook #'json-explore--cancel-request nil t)
  (add-hook 'change-major-mode-hook #'json-explore--cancel-request nil t)
  (add-hook 'kill-buffer-hook #'json-explore--kill-inspection nil t))

(defvar json-explore--evil-bindings-installed nil)
(declare-function evil-normal-state-p "evil-states" ())
(declare-function evil-local-set-key "evil-core" (state key def))

(defun json-explore--terminal-motion ()
  ;; This runs after the parent vui-mode hook installs its buffer-local
  ;; terminal bindings for button/field traversal.
  (when json-explore--evil-bindings-installed
    (evil-local-set-key 'normal (kbd "g]") #'json-explore-next-cell)
    (evil-local-set-key 'normal (kbd "g[") #'json-explore-previous-cell)))

(add-hook 'json-explore-mode-hook #'json-explore--terminal-motion)

(defun json-explore--emacs-binding (command)
  ;; Do not restore a default that the Evil Collection theme moved or disabled.
  (unless (and json-explore--evil-bindings-installed
               (bound-and-true-p evil-local-mode)
               (evil-normal-state-p))
    command))

(let ((map json-explore-mode-map))
  (dolist (entry '(("RET" . json-explore-open) ("<return>" . json-explore-open)
                   ("<tab>" . json-explore-next-cell) ("TAB" . json-explore-next-cell)
                   ("<backtab>" . json-explore-previous-cell)))
    (define-key map (kbd (car entry))
      `(menu-item "" ,(cdr entry) :filter json-explore--emacs-binding)))
  (define-key map (kbd "C-c C-b") #'json-explore-back)
  (define-key map (kbd "C-c C-f") #'json-explore-forward)
  (define-key map (kbd "C-c C-r") #'json-explore-refresh)
  (define-key map (kbd "C-c C-v") #'json-explore-visit)
  (define-key map (kbd "q") #'json-explore-quit))

(with-eval-after-load 'evil-collection
  (evil-collection-inhibit-insert-state 'json-explore-mode-map)
  (evil-collection-bind 'json-explore-mode-map
    'action #'json-explore-open
    'action-other #'json-explore-open-other-window
    'action-stay #'json-explore-display-other-window
    'next-button #'json-explore-next-cell
    'previous-button #'json-explore-previous-cell
    'lookup-doc #'json-explore-inspect
    'find-file #'json-explore-visit
    'refresh #'json-explore-refresh
    'quit #'json-explore-quit
    'quit-save #'json-explore-quit
    'quit-cancel #'json-explore-evil-quit
    'describe-mode #'describe-mode)
  (evil-collection-define-key 'normal 'json-explore-mode-map
    "gh" #'json-explore-previous-column "gl" #'json-explore-next-column
    (kbd "C-o") #'json-explore-back (kbd "C-i") #'json-explore-forward
    "o" #'json-explore-sort "O" #'json-explore-reverse-sort
    "za" #'json-explore-toggle-section "zo" #'json-explore-open-section
    "zc" #'json-explore-close-section "zR" #'json-explore-open-all-sections
    "zM" #'json-explore-close-all-sections "Y" #'json-explore-copy-path)
  (setq json-explore--evil-bindings-installed t))

(defun json-explore--show-view (view buffer-name no-display &optional mode)
  (let* ((mode (or mode #'json-explore-mode))
         (existing (get-buffer buffer-name))
         (buffer (or existing (get-buffer-create buffer-name))))
    (when (and existing (not (eq (buffer-local-value 'major-mode existing) mode)))
      (user-error "Buffer %s is not in %s" buffer-name mode))
    (with-current-buffer buffer
      (unless existing (funcall mode))
      (unless (derived-mode-p 'json-explore-mode)
        (user-error "%s does not derive from json-explore-mode" mode))
      (json-explore--cancel-request)
      (unless (json-explore--view-label view)
        (setf (json-explore--view-label view) buffer-name))
      (setq json-explore--view view json-explore--back nil json-explore--forward nil)
      (json-explore--install-breadcrumb))
    (vui-mount (vui-component 'json-explore--root) buffer-name no-display)
    (with-current-buffer buffer
      (vui-rerender-on-resize)
      (json-explore--first-cell))
    buffer))

(defun json-explore--initial-view (source &optional label)
  (let* ((value (and (not (json-explore-source-program source))
                     (json-explore-source-value source)))
         (view (if value (json-explore--new-view value nil) (json-explore--make-view))))
    (setf (json-explore--view-source view) source
          (json-explore--view-label view) (or label (json-explore-source-label source))
          (json-explore--view-snapshot view) value)
    (json-explore--apply-source-columns view source)
    view))

(defun json-explore--source-name (source)
  (format "*%s [%x]*" (json-explore-source-label source)
          (sxhash-equal (list (json-explore-source-program source)
                             (json-explore-source-directory source)
                             (json-explore-source-argv source)))))

(cl-defun json-explore-open-source (source &key buffer-name mode no-display &allow-other-keys)
  "Open SOURCE at its root and return the explorer buffer immediately.
Run command sources asynchronously; display static sources directly.
MODE defaults to `json-explore-mode' and must derive from it.  Without
BUFFER-NAME, reuse the name based on the label and command identity.
NO-DISPLAY leaves windows alone.  Opening resets that buffer's history."
  (let ((buffer (json-explore--show-view (json-explore--initial-view source)
                                        (or buffer-name (json-explore--source-name source))
                                        no-display mode)))
    (when (json-explore-source-program source)
      (with-current-buffer buffer (json-explore-refresh)))
    buffer))

(cl-defun json-explore-push-source (source &key label &allow-other-keys)
  "Push SOURCE into this explorer's history and run it if it has a command.
LABEL overrides the entry's breadcrumb label.  Do not create a new buffer."
  (unless json-explore--view (user-error "No explorer view here"))
  (json-explore--push-view (json-explore--initial-view source label))
  (when (json-explore-source-program source) (json-explore-refresh)))

(cl-defun json-explore-show-message (label text &key mode buffer-name no-display &allow-other-keys)
  "Show TEXT under LABEL in a non-refreshable explorer and return the buffer.
MODE, BUFFER-NAME and NO-DISPLAY work as in `json-explore-open-source'."
  (let* ((source (json-explore-make-source :label label))
         (view (json-explore--initial-view source)))
    (setf (json-explore--view-diagnostic view) text)
    (json-explore--show-view view (or buffer-name (json-explore--source-name source)) no-display mode)))

(defun json-explore-show-value (value buffer-name &optional no-display)
  "Show parsed JSON VALUE in explorer BUFFER-NAME and return that buffer.
The caller owns the source identity and supplies one name per source.
Replace that source's history with a new root.  With NO-DISPLAY, do not
switch to the buffer."
  (json-explore-open-source (json-explore-make-source :value value :label buffer-name)
                            :buffer-name buffer-name :no-display no-display))

(defun json-explore-buffer (&optional begin end)
  "Explore a JSON snapshot of the current buffer or active region.
When BEGIN and END are provided, explore only the text between them."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let* ((origin (buffer-name))
         (region (and begin end))
         (name (format "*JSON: %s*" origin)))
    (save-restriction
      (unless region (widen))
      (json-explore-open-source
       (json-explore-make-source
        :value (json-explore-parse (buffer-substring-no-properties (or begin (point-min))
                                                                  (or end (point-max))))
        :label (if region (format "%s (region)" origin) origin))
       :buffer-name name))))

(defun json-explore--dispose-request (request)
  (dolist (process (list (json-explore--request-process request)
                        (json-explore--request-pipe request)))
    (when process
      (set-process-sentinel process #'ignore)
      (delete-process process)))
  (dolist (buffer (list (json-explore--request-stdout request)
                       (json-explore--request-stderr request)))
    (when (buffer-live-p buffer) (kill-buffer buffer))))

(defun json-explore--cancel-request ()
  (when-let* ((request json-explore--request))
    ;; Invalidate before disconnecting either sentinel.
    (setq json-explore--request nil)
    (cl-incf json-explore--generation)
    (json-explore--dispose-request request)))

(defun json-explore--cancel-and-render ()
  (when json-explore--request
    (json-explore--cancel-request)
    (json-explore--save-position)
    (json-explore--render t)))

(defun json-explore-quit ()
  "Cancel a pending request and quit the explorer window."
  (interactive)
  (json-explore--cancel-and-render)
  (quit-window))

(declare-function evil-quit "evil-commands" (force))

(defun json-explore-evil-quit ()
  "Cancel a pending request, then run `evil-quit'."
  (interactive)
  (json-explore--cancel-and-render)
  (call-interactively #'evil-quit))

(defun json-explore--local-directory (directory)
  (when (file-remote-p directory) (user-error "JSON commands run locally only"))
  (let ((directory (file-name-as-directory (expand-file-name directory))))
    (when (file-remote-p directory) (user-error "JSON commands run locally only"))
    directory))

(defun json-explore--executable (program)
  (let ((file (if (string-match-p "/" program) (expand-file-name program)
                (executable-find program))))
    (unless (and file (not (file-remote-p file))
                 (file-executable-p file) (not (file-directory-p file)))
      (error "Executable not found or not executable: %s" program))
    file))

(defun json-explore--at-path (value path &optional noerror)
  (dolist (part path value)
    (setq value
          (cond ((and (stringp part) (hash-table-p value)) (gethash part value))
                ((and (natnump part) (vectorp value) (< part (length value)))
                 (aref value part))))
    (unless (or value noerror)
      (error "Refreshed JSON has no value at %s" (json-explore-path-string path)))))

(defun json-explore--apply-source-columns (view source)
  (when (and (not (json-explore--view-path view))
             (json-explore--object-array-p (json-explore--view-value view))
             (json-explore-source-columns source))
    (let ((spec (json-explore-source-columns source)))
      (setf (json-explore--view-columns view) (cons 'index (mapcar #'car spec))
            (json-explore--view-column-spec view) spec))))

(defun json-explore--replace-snapshot (view snapshot)
  (let* ((path (json-explore--view-path view))
         (value (json-explore--at-path snapshot path))
         (source (json-explore--view-source view))
         (new (json-explore--new-view value path)))
    (json-explore--apply-source-columns new source)
    (setf (json-explore--view-label new) (json-explore--view-label view)
          (json-explore--view-cell new) (json-explore--view-cell view)
          (json-explore--view-start new) (json-explore--view-start view)
          (json-explore--view-hscroll new) (json-explore--view-hscroll view)
          (json-explore--view-source new) source
          (json-explore--view-snapshot new) snapshot
          (json-explore--view-presentation new) (json-explore--view-presentation view))
    (setq json-explore--view new)))

(defun json-explore--deliver (status code stdout stderr)
  (json-explore--save-position)
  (let* ((view json-explore--view)
         (source (json-explore--view-source view))
         (exit (pcase status ('exit (format "Exit status %d" code))
                           ('signal (format "Terminated by signal %d" code))))
         diagnostic)
    (condition-case err
        (cond
         ((eq status 'startup) (setq diagnostic stdout))
         ((not (and (eq status 'exit) (memq code (json-explore--source-success-codes source))))
          (setq diagnostic exit))
         (t
          (when (string-blank-p stdout) (error "Command produced no JSON output"))
          (let ((validate (json-explore--source-validate source))
                (value (condition-case parse-error
                           (json-explore-parse stdout)
                         (json-error (error "Invalid JSON: %s" (error-message-string parse-error))))))
            (when validate (funcall validate value code))
            (json-explore--replace-snapshot view value))
          (unless (zerop code) (setq diagnostic exit))))
      (error (setq diagnostic (concat exit ": " (error-message-string err)))))
    (unless (string-blank-p stderr)
      (setq diagnostic (concat (when diagnostic (concat diagnostic "\n"))
                               "stderr: " (string-trim-right stderr))))
    (setf (json-explore--view-diagnostic json-explore--view) diagnostic)
    (json-explore--render t)))

(defun json-explore-refresh ()
  "Rerun the current view's command and refresh only that history entry.
For a nested view, select the same JSON path in the fresh result."
  (interactive)
  (let ((source (and json-explore--view (json-explore--view-source json-explore--view))))
    (unless (and source (json-explore-source-program source))
      (user-error "This snapshot has no command to refresh"))
    (json-explore--cancel-request)
    (let* ((request (json-explore--make-request))
           (generation (cl-incf json-explore--generation))
           process-done stderr-done
           (callback
            (vui-async-callback (startup-error)
              (when (and (= generation json-explore--generation)
                         (eq request json-explore--request))
                (let* ((process (json-explore--request-process request))
                       (status (if startup-error 'startup (process-status process)))
                       (code (unless startup-error (process-exit-status process)))
                       (stdout (or startup-error
                                   (with-current-buffer (json-explore--request-stdout request)
                                     (buffer-string))))
                       (stderr (unless startup-error
                                 (with-current-buffer (json-explore--request-stderr request)
                                   (buffer-string)))))
                  (json-explore--cancel-request)
                  (json-explore--deliver status code stdout (or stderr ""))))))
           ;; Both sentinels must have run: each is notified only after its
           ;; own channel's final bytes have been passed to its filter.
           (process-sentinel (lambda (process _event)
                               (when (memq (process-status process) '(exit signal))
                                 (setq process-done t)
                                 (when stderr-done (funcall callback nil)))))
           (stderr-sentinel (lambda (pipe _event)
                              (unless (process-live-p pipe)
                                (setq stderr-done t)
                                (when process-done (funcall callback nil))))))
      (setq json-explore--request request)
      (json-explore--save-position)
      (json-explore--render t)
      (condition-case err
          (let* ((default-directory (json-explore--source-directory source))
                 (program (json-explore--executable (json-explore--source-program source))))
            (setf (json-explore--request-stdout request) (generate-new-buffer " *JSON stdout*")
                  (json-explore--request-stderr request) (generate-new-buffer " *JSON stderr*")
                  (json-explore--request-pipe request)
                  (make-pipe-process :name "JSON stderr" :buffer (json-explore--request-stderr request)
                                     :coding 'utf-8-unix :noquery t :sentinel stderr-sentinel)
                  (json-explore--request-process request)
                  (make-process :name "JSON command" :buffer (json-explore--request-stdout request)
                                :command (cons program (json-explore--source-argv source))
                                :stderr (json-explore--request-pipe request) :coding 'utf-8-unix
                                :connection-type 'pipe :noquery t :sentinel process-sentinel))
            (ignore-errors (process-send-eof (json-explore--request-process request))))
        (error (funcall callback (error-message-string err)))))))

(cl-defun json-explore-run-command (program argv &key directory buffer-name no-display context
                                           (success-codes '(0)))
  "Explore a local PROGRAM's JSON stdout, passing ARGV verbatim without a shell.
DIRECTORY defaults to the caller's `default-directory'.  Retain CONTEXT
with the command for adapters.  Accept only SUCCESS-CODES, normally (0).
Replace the root in BUFFER-NAME, or allocate a new explorer if omitted.
Return the explorer buffer immediately; NO-DISPLAY leaves windows alone."
  (interactive (list (read-string "JSON executable: ")
                     (split-string-shell-command (read-string "Arguments (quoted as needed): "))))
  (json-explore-open-source
   (json-explore-make-source :program program :argv argv :directory directory
                             :context context :success-codes success-codes)
   :buffer-name (or buffer-name (generate-new-buffer-name (format "*JSON: %s*" program)))
   :no-display no-display))

(provide 'json-explore)
;;; json-explore.el ends here
