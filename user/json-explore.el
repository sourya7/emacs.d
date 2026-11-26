;;; json-explore.el --- Read-only navigation of typed JSON -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'vui)

(defgroup json-explore nil
  "Browse finite JSON values."
  :group 'tools)

(defcustom json-explore-row-limit 500
  "Maximum number of rows rendered in each view (at least one)."
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

(defun json-explore--summary (value)
  (json-explore--clip
   (cond
    ((eq value json-explore-missing) "<missing>")
    ((hash-table-p value)
     (if (zerop (hash-table-count value)) "{}"
       (format "{%d keys}" (hash-table-count value))))
    ((vectorp value)
     (if (zerop (length value)) "[]" (format "[%d items]" (length value))))
    ;; Limit work before escaping, even for a very large string.
    ((and (stringp value) (> (length value) (json-explore--width)))
     (json-explore--json (substring value 0 (json-explore--width))))
    (t (json-explore--json value)))))

(defun json-explore-path-string (path)
  "Return a jq expression for PATH, a list of string keys and array indices."
  (concat "." (mapconcat (lambda (part) (format "[%s]" (json-explore--json part)))
                         path "")))

;; A view owns its snapshot and its navigation state, not its rendered text.
;; Row IDs are the original array indices or object keys.  Column IDs are
;; symbols for structural columns and strings for actual object members.
(cl-defstruct (json-explore--view (:constructor json-explore--make-view))
  value path columns rows sort descending cell start hscroll source diagnostic)

(cl-defstruct (json-explore--source (:constructor json-explore--make-source))
  program argv directory context success-codes)

(cl-defstruct (json-explore--request (:constructor json-explore--make-request))
  process pipe stdout stderr)

(defvar-local json-explore--request nil)
(defvar-local json-explore--generation 0)
(defvar-local json-explore--view nil)
(defvar-local json-explore--back nil)
(defvar-local json-explore--forward nil)
(defvar-local json-explore--inspection nil)

(defun json-explore--object-array-p (value)
  (and (vectorp value) (> (length value) 0) (cl-every #'hash-table-p value)))

(defun json-explore--new-view (value path)
  (let (columns rows)
    (cond
     ((hash-table-p value)
      (setq columns '(key value))
      (maphash (lambda (key _val) (push key rows)) value)
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

(defun json-explore--cell-value (view cell)
  (let ((value (json-explore--view-value view))
        (row (car cell)) (column (cdr cell)))
    (cond
     ((eq row 'scalar) value)
     ((hash-table-p value) (gethash row value))
     ((stringp column) (gethash column (aref value row) json-explore-missing))
     (t (aref value row)))))

(defun json-explore--cell-path (view cell)
  (let ((path (json-explore--view-path view)))
    (if (eq (car cell) 'scalar) path
      (append path (list (car cell)) (when (stringp (cdr cell)) (list (cdr cell)))))))

(defun json-explore--display-value (view cell)
  (if (memq (cdr cell) '(key index)) (car cell)
    (json-explore--cell-value view cell)))

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

(defun json-explore--visible-rows (view)
  (let* ((rows (json-explore--view-rows view))
         (column (json-explore--view-sort view))
         (descending (json-explore--view-descending view))
         (limit (min (length rows) (max 1 json-explore-row-limit))))
    (when column
      (setq rows
            (mapcar #'car
                    (cl-stable-sort
                     (mapcar (lambda (row)
                               (cons row (json-explore--sort-key
                                          (json-explore--display-value
                                           view (cons row column)))))
                             rows)
                     (if descending (lambda (a b) (json-explore--less-p b a))
                       #'json-explore--less-p)
                     :key #'cdr))))
    (seq-take rows limit)))

(defun json-explore--header (column)
  (pcase column
    ('key "Key") ('index "Index") ('value "Value")
    (_ (json-explore--summary column))))

(defun json-explore--table (view rows)
  (let* ((columns (json-explore--view-columns view))
         (headers (mapcar #'json-explore--header columns))
         (labels (mapcar (lambda (row)
                           (mapcar (lambda (column)
                                     (json-explore--summary
                                      (json-explore--display-value view (cons row column))))
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
                             collect (vui-region :key (cons row column)
                                       (vui-text (concat label
                                                         (make-string (- width (string-width label)) ?\s)))))))))

(vui-defcomponent json-explore--root ()
  :render
  (let* ((view json-explore--view)
         (rows (json-explore--visible-rows view))
         (total (length (json-explore--view-rows view)))
         (path (json-explore-path-string (json-explore--view-path view)))
         (column (json-explore--view-sort view)))
    (vui-region :sticky t
      (vui-vstack
       (vui-text path :face 'bold)
       (when json-explore--request
         (vui-text "Running command…" :face 'shadow))
       (when-let* ((diagnostic (json-explore--view-diagnostic view)))
         (apply #'vui-vstack
                (mapcar (lambda (line) (vui-text line :face 'warning))
                        (split-string diagnostic "\n"))))
       (when column
         (vui-text (format "Sorted by %s (%s)" (json-explore--header column)
                           (if (json-explore--view-descending view) "descending" "ascending"))))
       (when (< (length rows) total)
         (vui-text (format "showing %d of %d" (length rows) total)))
       (cond (rows (json-explore--table view rows))
             ((json-explore--view-value view)
              (vui-text (json-explore--summary (json-explore--view-value view))))
             (t (vui-text "No JSON result yet.")))))))

(defun json-explore--window ()
  (if (eq (window-buffer (selected-window)) (current-buffer))
      (selected-window)
    (get-buffer-window)))

(defun json-explore--save-position ()
  (setf (json-explore--view-cell json-explore--view) (vui-key-at))
  (when-let* ((window (json-explore--window)))
    (setf (json-explore--view-start json-explore--view) (window-start window)
          (json-explore--view-hscroll json-explore--view) (window-hscroll window))))

(defun json-explore--cell-positions ()
  (let ((pos (point-min)) positions)
    (while (< pos (point-max))
      (when (get-text-property pos 'vui-key) (push pos positions))
      (setq pos (next-single-property-change pos 'vui-key nil (point-max))))
    (vconcat (nreverse positions))))

(defun json-explore-next-cell (count)
  "Move COUNT cells forward (backward if negative), wrapping at the ends."
  (interactive "p")
  (let* ((positions (json-explore--cell-positions))
         (len (length positions))
         (pos (point)))
    (unless (or (zerop count) (zerop len))
      (let ((index (cl-position-if (if (> count 0) (lambda (p) (> p pos))
                                     (lambda (p) (< p pos)))
                                   positions :from-end (< count 0))))
        (goto-char (aref positions (mod (+ (or index (if (> count 0) 0 (1- len)))
                                           (if (> count 0) (1- count) (1+ count)))
                                        len)))))))

(defun json-explore-previous-cell (count)
  "Move COUNT cells backward, wrapping at the ends."
  (interactive "p")
  (json-explore-next-cell (- count)))

(defun json-explore--first-cell ()
  (goto-char (point-min))
  (json-explore-next-cell 1))

(defun json-explore--render (&optional restore-scroll)
  (vui-refresh)
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
  (or (vui-key-at) (user-error "Point is not on a JSON cell")))

(defun json-explore--move-column (step)
  (pcase-let* ((`(,row . ,column) (json-explore--selected-cell))
               (columns (json-explore--view-columns json-explore--view))
               (next (nth (mod (+ (cl-position column columns :test #'equal) step)
                               (length columns))
                          columns)))
    (vui-goto-key (cons row next))))

(defun json-explore-next-column (count)
  "Move COUNT columns right within the current row, wrapping."
  (interactive "p")
  (json-explore--move-column count))

(defun json-explore-previous-column (count)
  "Move COUNT columns left within the current row, wrapping."
  (interactive "p")
  (json-explore--move-column (- count)))

(defun json-explore-sort ()
  "Sort by the column at point; toggle direction on repeated use."
  (interactive)
  (let ((column (cdr (json-explore--selected-cell))) (view json-explore--view))
    (setf (json-explore--view-descending view)
          (and (equal column (json-explore--view-sort view))
               (not (json-explore--view-descending view)))
          (json-explore--view-sort view) column)
    (json-explore--save-position)
    (json-explore--render)))

(defun json-explore-reverse-sort ()
  "Reverse the active sort, or sort the column at point descending."
  (interactive)
  (let ((view json-explore--view))
    (unless (json-explore--view-sort view)
      (setf (json-explore--view-sort view) (cdr (json-explore--selected-cell))))
    (setf (json-explore--view-descending view) (not (json-explore--view-descending view)))
    (json-explore--save-position)
    (json-explore--render)))

(defun json-explore-copy-path ()
  "Copy the jq path of the cell at point, or of the current view."
  (interactive)
  (let ((path (json-explore-path-string
               (if-let* ((cell (vui-key-at)))
                   (json-explore--cell-path json-explore--view cell)
                 (json-explore--view-path json-explore--view)))))
    (kill-new path)
    (message "%s" path)))

(defun json-explore--inspect-value (value raw stay)
  (unless (buffer-live-p json-explore--inspection)
    (setq json-explore--inspection
          (generate-new-buffer (format "*Inspect %s*" (string-trim (buffer-name) "[*]+" "[*]+")))))
  (let ((buffer json-explore--inspection))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if raw
            (progn (text-mode) (insert value))
          (special-mode)
          (if (eq value json-explore-missing)
              (insert "<missing: no such object member>")
            (insert (json-explore--json value))
            (json-pretty-print-buffer)))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (goto-char (point-min))))
    (let ((window (display-buffer buffer
                                  '((display-buffer-reuse-window display-buffer-pop-up-window)
                                    (inhibit-same-window . t)))))
      (when (and window (not stay)) (select-window window)))))

(defun json-explore--value-at-point ()
  (if-let* ((cell (vui-key-at))) (json-explore--cell-value json-explore--view cell)
    (or (json-explore--view-value json-explore--view)
        (user-error "No JSON result yet"))))

(defun json-explore-inspect ()
  "Inspect the full, typed JSON value in the reused companion buffer."
  (interactive)
  (json-explore--inspect-value (json-explore--value-at-point) nil nil))

(defun json-explore-open-other-window ()
  "Open the full cell in another window (strings as plain text)."
  (interactive)
  (let ((value (json-explore--value-at-point)))
    (json-explore--inspect-value value (stringp value) nil)))

(defun json-explore-display-other-window ()
  "Display the full cell in another window without selecting it."
  (interactive)
  (let ((value (json-explore--value-at-point)))
    (json-explore--inspect-value value (stringp value) t)))

(defun json-explore--open (cell)
  (let* ((value (json-explore--cell-value json-explore--view cell))
         (path (json-explore--cell-path json-explore--view cell)))
    (cond
     ((eq value json-explore-missing) (user-error "No such object member"))
     ((and (stringp value)
           (or (eq (car cell) 'scalar) (string-match-p "[\r\n]" value)
               (> (length value) (json-explore--width))
               (> (string-width (json-explore--json value)) (json-explore--width))))
      (json-explore--inspect-value value t nil))
     ((eq (car cell) 'scalar) (json-explore-inspect))
     (t
      (json-explore--cancel-request)
      (json-explore--save-position)
      (let ((next (json-explore--new-view value path)))
        (setf (json-explore--view-source next) (json-explore--view-source json-explore--view))
        (push json-explore--view json-explore--back)
        (setq json-explore--forward nil json-explore--view next))
      (json-explore--render t)))))

(defun json-explore-open ()
  "Drill into the cell at point.  Use its index/key cell to open a row."
  (interactive)
  (json-explore--open (json-explore--selected-cell)))

(defun json-explore--kill-inspection ()
  (when (buffer-live-p json-explore--inspection)
    (kill-buffer json-explore--inspection)))

(define-derived-mode json-explore-mode vui-mode "JSON Explore"
  "Browse JSON cells.  RET drills into a cell; K inspects full JSON.
Use TAB/backtab to move between cells, gh/gl to move within a row in
Evil, and ordinary vertical motion to move between rows.  C-o/C-i
visit history, o/O sort, and Y copies the jq path in Evil.  Use gr
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
    'refresh #'json-explore-refresh
    'quit #'json-explore-quit
    'quit-save #'json-explore-quit
    'quit-cancel #'json-explore-evil-quit
    'describe-mode #'describe-mode)
  (evil-collection-define-key 'normal 'json-explore-mode-map
    "gh" #'json-explore-previous-column "gl" #'json-explore-next-column
    (kbd "C-o") #'json-explore-back (kbd "C-i") #'json-explore-forward
    "o" #'json-explore-sort "O" #'json-explore-reverse-sort
    "Y" #'json-explore-copy-path)
  (setq json-explore--evil-bindings-installed t))

(defun json-explore--show-view (view buffer-name no-display)
  (let ((existing (get-buffer buffer-name)))
    (when (and existing (not (provided-mode-derived-p (buffer-local-value 'major-mode existing)
                                                      'json-explore-mode)))
      (user-error "Buffer %s is not a JSON explorer" buffer-name)))
  (let ((buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'json-explore-mode) (json-explore-mode))
      (json-explore--cancel-request)
      (setq json-explore--view view json-explore--back nil json-explore--forward nil))
    (vui-mount (vui-component 'json-explore--root) buffer-name no-display)
    (with-current-buffer buffer (json-explore--first-cell))
    buffer))

(defun json-explore-show-value (value buffer-name &optional no-display)
  "Show parsed JSON VALUE in explorer BUFFER-NAME and return that buffer.
The caller owns the source identity and supplies one name per source.
Replace that source's history with a new root.  With NO-DISPLAY, do not
switch to the buffer."
  (json-explore--show-view (json-explore--new-view value nil) buffer-name no-display))

(defun json-explore-buffer (&optional begin end)
  "Explore a JSON snapshot of the current buffer or active region.
When BEGIN and END are provided, explore only the text between them."
  (interactive (when (use-region-p) (list (region-beginning) (region-end))))
  (let ((name (format "*JSON: %s*" (buffer-name))))
    (save-restriction
      (unless (and begin end) (widen))
      (json-explore-show-value
       (json-explore-parse (buffer-substring-no-properties (or begin (point-min))
                                                          (or end (point-max))))
       name))))

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

(defun json-explore--at-path (value path)
  (dolist (part path value)
    (setq value
          (cond ((and (stringp part) (hash-table-p value)) (gethash part value))
                ((and (natnump part) (vectorp value) (< part (length value)))
                 (aref value part))))
    (unless value (error "Refreshed JSON has no value at %s" (json-explore-path-string path)))))

(defun json-explore--replace-snapshot (view value)
  (let* ((new (json-explore--new-view value (json-explore--view-path view)))
         (sort (json-explore--view-sort view)))
    (setf (json-explore--view-cell new) (json-explore--view-cell view)
          (json-explore--view-start new) (json-explore--view-start view)
          (json-explore--view-hscroll new) (json-explore--view-hscroll view)
          (json-explore--view-source new) (json-explore--view-source view))
    (when (member sort (json-explore--view-columns new))
      (setf (json-explore--view-sort new) sort
            (json-explore--view-descending new) (json-explore--view-descending view)))
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
          (let ((value (condition-case parse-error
                           (json-explore-parse stdout)
                         (json-error (error "Invalid JSON: %s" (error-message-string parse-error))))))
            (json-explore--replace-snapshot
             view (json-explore--at-path value (json-explore--view-path view))))
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
    (unless source (user-error "This snapshot has no command to refresh"))
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
  (let* ((source (json-explore--make-source
                  :program (copy-sequence program) :argv (mapcar #'copy-sequence argv)
                  :directory (json-explore--local-directory (or directory default-directory))
                  :context context :success-codes (copy-sequence success-codes)))
         (name (or buffer-name (generate-new-buffer-name (format "*JSON: %s*" program))))
         (buffer (json-explore--show-view (json-explore--make-view :source source) name no-display)))
    (with-current-buffer buffer (json-explore-refresh))
    buffer))

(provide 'json-explore)
;;; json-explore.el ends here
