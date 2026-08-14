;;; pichat-markdown-presentation.el --- Compact links and tables for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Derived presentation for completed assistant prose.  This module never
;; rewrites Markdown source: compact links and formatted tables are overlays
;; over the canonical/live projection.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'pichat-markdown-table)

(defcustom pichat-chat-compact-links t
  "When non-nil, display Markdown links as their actionable labels."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-prettify-tables t
  "When non-nil, display Markdown pipe tables as aligned tables."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-table-unicode-borders t
  "When non-nil, use Unicode borders in formatted Markdown tables."
  :type 'boolean
  :group 'pichat)

(defcustom pichat-chat-table-max-width-fraction 0.9
  "Fraction of the available width used by formatted Markdown tables."
  :type 'number
  :group 'pichat)

(defcustom pichat-chat-link-safe-schemes '("https" "http" "mailto")
  "URL schemes that PiChat may open directly from Markdown links."
  :type '(repeat string)
  :group 'pichat)

(defcustom pichat-chat-markdown-cache-max-entries 128
  "Maximum parsed Markdown prose runs retained in one PiChat buffer."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-markdown-cache-max-chars (* 1024 1024)
  "Maximum source characters retained by PiChat's Markdown parse cache."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-table-layout-cache-max-entries 128
  "Maximum rendered table layouts retained in one PiChat buffer."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-table-preview-max-rows 40
  "Maximum data rows shown in one inline Markdown table preview."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-table-preview-max-columns 12
  "Hard maximum of real columns shown in an inline Markdown table preview."
  :type 'integer
  :group 'pichat)

(defcustom pichat-chat-table-min-column-width 3
  "Preferred minimum content width of an inline Markdown table column."
  :type 'integer
  :group 'pichat)

(defvar pichat-chat--source-generation)
(defvar pichat-max-width)

(declare-function markdown-mode "markdown-mode")
(declare-function markdown-link-at-pos "markdown-mode" (pos))
(declare-function markdown-link-url "markdown-mode" ())

(cl-defstruct (pichat-markdown-link
               (:constructor pichat-markdown-link-create)
               (:conc-name pichat-markdown-link-))
  "A Markdown link found in one assistant prose run."
  start end label url title form)

(cl-defstruct (pichat-markdown-parsed-run
               (:constructor pichat-markdown-parsed-run-create)
               (:conc-name pichat-markdown-parsed-run-))
  "Position-independent derived data for one Markdown prose run."
  source-digest face-runs links fenced-code-ranges tables)

(defconst pichat-markdown-presentation--parser-version 2)

(defvar-local pichat-markdown-presentation--parse-cache nil
  "Content-addressed cache of parsed Markdown prose runs.")

(defvar-local pichat-markdown-presentation--parse-cache-order nil
  "Oldest-last insertion order for Markdown parse cache keys.")

(defvar-local pichat-markdown-presentation--parse-cache-chars 0
  "Source characters represented by the bounded Markdown parse cache.")

(defvar-local pichat-markdown-presentation--active-parse-cache nil
  "Parsed metadata for prose runs in the current complete projection.
Unlike the bounded reuse cache, this working set follows visible canonical
content and is replaced atomically after each complete projection pass.")

(defvar pichat-markdown-presentation--parse-cycle-source nil
  "Previous active parse working set during a complete projection pass.")

(defvar pichat-markdown-presentation--parse-cycle-next nil
  "New active parse working set being built during a projection pass.")

(defmacro pichat-markdown-presentation--with-parse-cycle (&rest body)
  "Evaluate BODY while reusing and rebuilding the active parse working set.
Nested cycles contribute to the outer cycle.  Commit the replacement working
set only when BODY completes successfully."
  (declare (indent 0) (debug t))
  `(if (hash-table-p pichat-markdown-presentation--parse-cycle-next)
       (progn ,@body)
     (let ((pichat-markdown-presentation--parse-cycle-source
            (and (hash-table-p
                  pichat-markdown-presentation--active-parse-cache)
                 pichat-markdown-presentation--active-parse-cache))
           (pichat-markdown-presentation--parse-cycle-next
            (make-hash-table :test #'equal)))
       (prog1 (progn ,@body)
         (setq pichat-markdown-presentation--active-parse-cache
               pichat-markdown-presentation--parse-cycle-next)))))

(defvar-local pichat-markdown-presentation--states nil
  "Explicit presentation states keyed by stable Markdown item keys.")

(defvar-local pichat-markdown-presentation--overlays nil
  "Registry of PiChat-owned presentation overlays keyed by item key.")

(defvar-local pichat-markdown-presentation--table-layout-cache nil
  "Position-independent rendered table rows keyed by source and display policy.")

(defvar-local pichat-markdown-presentation--table-layout-cache-order nil
  "Newest-first insertion order for the bounded table layout cache.")

(defvar-local pichat-markdown-presentation--table-width nil
  "Last target width used to render tables in this PiChat buffer.")

(defvar-local pichat-markdown-presentation--width-timer nil
  "Pending debounced table-only refresh timer.")

(defvar-local pichat-markdown-presentation--warned nil
  "Derived-presentation warnings already reported in this buffer.")

(defvar pichat-markdown-presentation-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-open-link-at-point)
    ;; (define-key map [mouse-1] #'pichat-chat-open-link-at-mouse)
    ;; (define-key map (kbd "w") #'pichat-chat-copy-link-at-point)
    map)
  "Keymap used by compact PiChat Markdown links.")

(defvar pichat-markdown-presentation-table-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-open-table-at-point)
    map)
  "Keymap used by PiChat Markdown table overlays.")

(defun pichat-markdown-presentation--ensure-state ()
  "Ensure current buffer has a presentation state table."
  (unless (hash-table-p pichat-markdown-presentation--states)
    (setq pichat-markdown-presentation--states
          (make-hash-table :test #'equal))))

(defun pichat-markdown-presentation--ensure-parse-cache ()
  "Ensure current buffer has a Markdown parse cache."
  (unless (hash-table-p pichat-markdown-presentation--parse-cache)
    (setq pichat-markdown-presentation--parse-cache
          (make-hash-table :test #'equal)
          pichat-markdown-presentation--parse-cache-order nil
          pichat-markdown-presentation--parse-cache-chars 0)))

(defun pichat-markdown-presentation-clear-cache ()
  "Discard all position-independent Markdown parse data."
  (when (hash-table-p pichat-markdown-presentation--parse-cache)
    (clrhash pichat-markdown-presentation--parse-cache))
  (setq pichat-markdown-presentation--parse-cache-order nil
        pichat-markdown-presentation--parse-cache-chars 0
        pichat-markdown-presentation--active-parse-cache nil))

(defun pichat-markdown-presentation--trim-parse-cache ()
  "Keep the current Markdown parse cache within configured bounds."
  (while (and pichat-markdown-presentation--parse-cache-order
              (or (> (hash-table-count
                      pichat-markdown-presentation--parse-cache)
                     (max 1 pichat-chat-markdown-cache-max-entries))
                  (> pichat-markdown-presentation--parse-cache-chars
                     (max 1 pichat-chat-markdown-cache-max-chars))))
    (let* ((key (car (last pichat-markdown-presentation--parse-cache-order)))
           (entry (gethash key pichat-markdown-presentation--parse-cache)))
      (setq pichat-markdown-presentation--parse-cache-order
            (butlast pichat-markdown-presentation--parse-cache-order))
      (when entry
        (cl-decf pichat-markdown-presentation--parse-cache-chars (cdr entry))
        (remhash key pichat-markdown-presentation--parse-cache)))))

(defun pichat-markdown-presentation--owned-p (overlay)
  "Return non-nil when OVERLAY belongs to this presentation layer."
  (overlay-get overlay 'pichat-markdown-presentation))

(defun pichat-markdown-presentation--ensure-overlay-registry ()
  "Ensure current buffer has an owned-overlay registry."
  (unless (hash-table-p pichat-markdown-presentation--overlays)
    (setq pichat-markdown-presentation--overlays
          (make-hash-table :test #'equal))))

(defun pichat-markdown-presentation--register-overlay (key overlay)
  "Register owned OVERLAY for stable item KEY."
  (pichat-markdown-presentation--ensure-overlay-registry)
  (puthash key (cons overlay
                     (delq nil
                           (mapcar (lambda (candidate)
                                     (and (overlay-buffer candidate) candidate))
                                   (gethash key
                                            pichat-markdown-presentation--overlays))))
           pichat-markdown-presentation--overlays)
  overlay)

(defun pichat-markdown-presentation--remove-item (key)
  "Delete all registered presentation overlays for KEY."
  (pichat-markdown-presentation--ensure-overlay-registry)
  (dolist (overlay (gethash key pichat-markdown-presentation--overlays))
    (when (overlay-buffer overlay)
      (delete-overlay overlay)))
  (remhash key pichat-markdown-presentation--overlays))

(defun pichat-markdown-presentation--prune-overlay-registry ()
  "Remove dead overlays and empty keys from the owned-overlay registry."
  (pichat-markdown-presentation--ensure-overlay-registry)
  (let (empty)
    (maphash
     (lambda (key overlays)
       (let ((live (delq nil
                         (mapcar (lambda (overlay)
                                   (and (overlay-buffer overlay) overlay))
                                 overlays))))
         (if live
             (puthash key live pichat-markdown-presentation--overlays)
           (push key empty))))
     pichat-markdown-presentation--overlays)
    (dolist (key empty)
      (remhash key pichat-markdown-presentation--overlays))))

(defun pichat-markdown-presentation-remove-region (beg end)
  "Remove PiChat Markdown presentation overlays intersecting BEG..END."
  (dolist (overlay (overlays-in beg end))
    (when (pichat-markdown-presentation--owned-p overlay)
      (delete-overlay overlay)))
  (pichat-markdown-presentation--prune-overlay-registry))

(defun pichat-markdown-presentation-remove-buffer ()
  "Remove all PiChat Markdown presentation overlays in the current buffer."
  (when (hash-table-p pichat-markdown-presentation--overlays)
    (maphash (lambda (_key overlays)
               (dolist (overlay overlays)
                 (when (overlay-buffer overlay) (delete-overlay overlay))))
             pichat-markdown-presentation--overlays)
    (clrhash pichat-markdown-presentation--overlays))
  ;; Defensive cleanup covers owned overlays left by a failing presentation
  ;; application before it could register them.
  (dolist (overlay (overlays-in (point-min) (point-max)))
    (when (pichat-markdown-presentation--owned-p overlay)
      (delete-overlay overlay))))

(defun pichat-markdown-presentation-reset-source ()
  "Discard all derived Markdown presentation for a new session source."
  (pichat-markdown-presentation-remove-buffer)
  (pichat-markdown-presentation-clear-cache)
  (when (hash-table-p pichat-markdown-presentation--table-layout-cache)
    (clrhash pichat-markdown-presentation--table-layout-cache))
  (setq pichat-markdown-presentation--table-layout-cache-order nil)
  (when (hash-table-p pichat-markdown-presentation--states)
    (clrhash pichat-markdown-presentation--states))
  (when (timerp pichat-markdown-presentation--width-timer)
    (cancel-timer pichat-markdown-presentation--width-timer))
  (setq pichat-markdown-presentation--width-timer nil
        pichat-markdown-presentation--table-width nil
        pichat-markdown-presentation--warned nil))

(defun pichat-markdown-presentation--warn-once (kind message-text)
  "Report MESSAGE-TEXT once for derived-presentation problem KIND."
  (unless (memq kind pichat-markdown-presentation--warned)
    (push kind pichat-markdown-presentation--warned)
    (display-warning 'pichat message-text :warning)))

(defun pichat-markdown-presentation--overlay-at-point (&optional kind)
  "Return an owned Markdown metadata overlay at point, optionally of KIND."
  (let* ((candidates
          (append (overlays-at (point))
                  ;; At an overlay's end, point may visually still be on display.
                  (when (> (point) (point-min))
                    (overlays-at (1- (point))))))
         (matches
          (lambda (overlay)
            (and (pichat-markdown-presentation--owned-p overlay)
                 (or (null kind)
                     (eq kind (overlay-get overlay 'pichat-markdown-kind)))))))
    (or (seq-find (lambda (overlay)
                    (and (funcall matches overlay)
                         (overlay-get overlay 'pichat-markdown-metadata)))
                  candidates)
        (seq-find matches candidates))))

(defun pichat-markdown-presentation--metadata-overlay
    (beg end kind key state &optional rendered)
  "Create an owned metadata overlay over BEG..END for KIND and KEY.
STATE is the item's current presentation state.  RENDERED marks overlays that
also replace or conceal source display."
  (let ((overlay (make-overlay beg end nil nil t)))
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'pichat-markdown-presentation t)
    (overlay-put overlay 'pichat-markdown-kind kind)
    (overlay-put overlay 'pichat-markdown-key key)
    (overlay-put overlay 'pichat-markdown-state state)
    (overlay-put overlay 'pichat-markdown-rendered rendered)
    (overlay-put overlay 'pichat-markdown-metadata t)
    (pichat-markdown-presentation--register-overlay key overlay)))

(defun pichat-markdown-presentation--item-key
    (kind ordinal beg end &optional node-key)
  "Return stable presentation key for KIND item ORDINAL in BEG..END.
Optional NODE-KEY identifies the containing projected transcript node."
  (list pichat-chat--source-generation
        (or node-key (get-text-property beg 'pichat-node-key))
        kind ordinal
        (secure-hash 'sha1 (buffer-substring-no-properties beg end))))

(defun pichat-markdown-presentation--state (key default)
  "Return explicit state for KEY, or DEFAULT when there is none."
  (pichat-markdown-presentation--ensure-state)
  (let ((missing (make-symbol "missing")))
    (let ((value (gethash key pichat-markdown-presentation--states missing)))
      (if (eq value missing) default value))))

(defun pichat-markdown-presentation--set-state (key state)
  "Record explicit presentation STATE for KEY."
  (pichat-markdown-presentation--ensure-state)
  (puthash key state pichat-markdown-presentation--states))

(defun pichat-markdown-presentation--clear-kind-states (kind)
  "Remove all explicit presentation choices for KIND."
  (pichat-markdown-presentation--ensure-state)
  (let (keys)
    (maphash (lambda (key _state)
               (when (eq (nth 2 key) kind)
                 (push key keys)))
             pichat-markdown-presentation--states)
    (dolist (key keys)
      (remhash key pichat-markdown-presentation--states))))

(defun pichat-markdown-presentation--safe-url-p (url)
  "Return non-nil when URL has an explicitly allowed scheme."
  (and (stringp url)
       (let* ((parsed (ignore-errors (url-generic-parse-url url)))
              (scheme (and parsed (url-type parsed))))
         (and scheme
              (member (downcase scheme) pichat-chat-link-safe-schemes)))))

(defun pichat-markdown-presentation--link-url-at-point ()
  "Return the stored PiChat Markdown URL at point, or nil."
  (when-let ((overlay
              (pichat-markdown-presentation--overlay-at-point 'link)))
    (overlay-get overlay 'pichat-markdown-url)))

(defun pichat-markdown-presentation-embark-target ()
  "Return PiChat's Markdown link at point as an Embark URL target."
  (when-let* ((overlay
               (pichat-markdown-presentation--overlay-at-point 'link))
              (url (overlay-get overlay 'pichat-markdown-url)))
    `(url ,url ,(overlay-start overlay) . ,(overlay-end overlay))))

;; Prepending this optional finder makes the URL the primary Embark target;
;; PiChat does not otherwise depend on Embark.
(with-eval-after-load 'embark
  (add-hook 'embark-target-finders
            #'pichat-markdown-presentation-embark-target))

;;;###autoload
(defun pichat-chat-open-link-at-point ()
  "Open the safe PiChat Markdown link at point."
  (interactive)
  (let ((url (pichat-markdown-presentation--link-url-at-point)))
    (unless url (user-error "No PiChat Markdown link at point"))
    (unless (pichat-markdown-presentation--safe-url-p url)
      (user-error "PiChat will not open URL scheme: %s" url))
    (browse-url url)))

;;;###autoload
(defun pichat-chat-open-link-at-mouse (event)
  "Move to mouse EVENT and open its safe PiChat Markdown link."
  (interactive "e")
  (mouse-set-point event)
  (pichat-chat-open-link-at-point))

;;;###autoload
(defun pichat-chat-copy-link-at-point ()
  "Copy the PiChat Markdown link destination at point."
  (interactive)
  (let ((url (pichat-markdown-presentation--link-url-at-point)))
    (unless url (user-error "No PiChat Markdown link at point"))
    (kill-new url)
    (message "Copied PiChat link: %s" url)))

;;;###autoload
(defun pichat-chat-describe-link-at-point ()
  "Show the PiChat Markdown link destination at point."
  (interactive)
  (let ((url (pichat-markdown-presentation--link-url-at-point)))
    (unless url (user-error "No PiChat Markdown link at point"))
    (message "%s" url)))

(defun pichat-markdown-presentation--link-form (source text url)
  "Return a descriptive link form symbol for SOURCE, TEXT, and URL."
  (cond
   ((and text (string-prefix-p "[" source)
         (string-match-p "][[:space:]]*(" source)) 'inline)
   ((and text (string-prefix-p "[" source)) 'reference)
   ((string-prefix-p "<" source) 'angle)
   ((and url (null text)) 'plain)
   (t 'link)))

(defun pichat-markdown-presentation--parse-source (source digest)
  "Parse Markdown SOURCE once and return position-independent metadata.
DIGEST is SOURCE's precomputed identity."
  (if (not (require 'markdown-mode nil t))
      (with-temp-buffer
        (insert source)
        (let ((code-ranges
               (mapcar (lambda (range)
                         (cons (1- (car range)) (1- (cdr range))))
                       (pichat-markdown-presentation--scan-fenced-code-ranges
                        (point-min) (point-max)))))
          (pichat-markdown-parsed-run-create
           :source-digest digest
           :fenced-code-ranges code-ranges
           :tables (pichat-markdown-table-parse source code-ranges))))
    (with-temp-buffer
      (insert source)
      (delay-mode-hooks (markdown-mode))
      (font-lock-ensure (point-min) (point-max))
      (let ((pos (point-min))
            (max (point-max))
            (seen (make-hash-table :test #'equal))
            faces links)
        (while (< pos max)
          (let ((next (or (next-single-property-change pos 'face nil max) max))
                (face (get-text-property pos 'face)))
            (when face
              (push (list (1- pos) (1- next) face) faces))
            (setq pos next)))
        (setq pos (point-min))
        (while (< pos max)
          (let* ((map (get-text-property pos 'keymap))
                 (next (or (next-single-property-change pos 'keymap nil max)
                           max)))
            (when map
              (save-excursion
                (goto-char pos)
                (pcase-let* ((values (markdown-link-at-pos pos))
                             (`(,start ,finish ,text ,direct-url
                                       ,_reference ,title ,bang)
                              values)
                             (url (or direct-url
                                      (ignore-errors (markdown-link-url)))))
                  (when (and (integer-or-marker-p start)
                             (integer-or-marker-p finish)
                             (< start finish)
                             (not bang)
                             (stringp url)
                             (not (gethash (cons start finish) seen)))
                    (puthash (cons start finish) t seen)
                    (let* ((raw (buffer-substring-no-properties start finish))
                           (label (or text url raw)))
                      (push (pichat-markdown-link-create
                             :start (1- start)
                             :end (1- finish)
                             :label label
                             :url url
                             :title title
                             :form (pichat-markdown-presentation--link-form
                                    raw text url))
                            links))))))
            (setq pos (max (1+ pos) next))))
        (let ((code-ranges
               (mapcar (lambda (range)
                         (cons (1- (car range)) (1- (cdr range))))
                       (pichat-markdown-presentation--scan-fenced-code-ranges
                        (point-min) (point-max)))))
          (pichat-markdown-parsed-run-create
           :source-digest digest
           :face-runs (nreverse faces)
           :links (nreverse links)
           :fenced-code-ranges code-ranges
           :tables (pichat-markdown-table-parse source code-ranges)))))))

(defun pichat-markdown-presentation-parse-run (beg end)
  "Return cached position-independent Markdown metadata for BEG..END."
  (let* ((source (buffer-substring-no-properties beg end))
         (digest (secure-hash 'sha1 source))
         ;; Parsed data is entirely content-relative, so sharing it between live
         ;; and canonical node identities is safe within one source generation.
         (key (list (or pichat-chat--source-generation 0)
                    pichat-markdown-presentation--parser-version digest)))
    (pichat-markdown-presentation--ensure-parse-cache)
    (let* ((cycle-entry
            (or (and (hash-table-p
                      pichat-markdown-presentation--parse-cycle-next)
                     (gethash key
                              pichat-markdown-presentation--parse-cycle-next))
                (and (hash-table-p
                      pichat-markdown-presentation--parse-cycle-source)
                     (gethash key
                              pichat-markdown-presentation--parse-cycle-source))))
           (bounded-entry
            (and (null cycle-entry)
                 (gethash key pichat-markdown-presentation--parse-cache)))
           (parsed
            (or cycle-entry
                (car-safe bounded-entry)
                (let ((value
                       (pichat-markdown-presentation--parse-source
                        source digest)))
                  (puthash key (cons value (length source))
                           pichat-markdown-presentation--parse-cache)
                  (push key pichat-markdown-presentation--parse-cache-order)
                  (cl-incf pichat-markdown-presentation--parse-cache-chars
                           (length source))
                  (pichat-markdown-presentation--trim-parse-cache)
                  value))))
      (when (hash-table-p pichat-markdown-presentation--parse-cycle-next)
        (puthash key parsed pichat-markdown-presentation--parse-cycle-next))
      parsed)))

(defun pichat-markdown-presentation--extract-links (beg end)
  "Return absolute Markdown link records corresponding to source BEG..END."
  (mapcar
   (lambda (link)
     (pichat-markdown-link-create
      :start (+ beg (pichat-markdown-link-start link))
      :end (+ beg (pichat-markdown-link-end link))
      :label (pichat-markdown-link-label link)
      :url (pichat-markdown-link-url link)
      :title (pichat-markdown-link-title link)
      :form (pichat-markdown-link-form link)))
   (pichat-markdown-parsed-run-links
    (pichat-markdown-presentation-parse-run beg end))))

(defun pichat-markdown-presentation--range-contained-p (beg end ranges)
  "Return non-nil when BEG..END is contained in one of RANGES."
  (seq-some (lambda (range)
              (and (>= beg (car range)) (<= end (cdr range))))
            ranges))

(defun pichat-markdown-presentation--present-link (link key state)
  "Present LINK identified by KEY according to STATE."
  (let* ((beg (pichat-markdown-link-start link))
         (end (pichat-markdown-link-end link))
         (url (pichat-markdown-link-url link))
         (label (pichat-markdown-link-label link))
         (compact-p (eq state 'compact))
         (overlay (pichat-markdown-presentation--metadata-overlay
                   beg end 'link key state compact-p)))
    (overlay-put overlay 'pichat-markdown-url url)
    (overlay-put overlay 'pichat-markdown-title
                 (pichat-markdown-link-title link))
    (overlay-put overlay 'pichat-markdown-label label)
    (overlay-put overlay 'pichat-markdown-form
                 (pichat-markdown-link-form link))
    (when compact-p
      (overlay-put overlay 'help-echo url)
      (overlay-put overlay 'keymap pichat-markdown-presentation-link-map)
      (overlay-put overlay 'mouse-face 'highlight)
      (overlay-put overlay 'face 'link)
      (overlay-put overlay 'follow-link t)
      (overlay-put overlay 'priority 40)
      (overlay-put overlay 'display
                   (propertize label 'face 'link 'mouse-face 'highlight
                               'help-echo url)))))

(defun pichat-markdown-presentation--scan-fenced-code-ranges (beg end)
  "Return simple fenced-code ranges found directly in BEG..END."
  (let (ranges open-start open-char open-length)
    (save-excursion
      (goto-char beg)
      (while (re-search-forward
              "^[ \t]\\{0,3\\}\\(```+\\|~~~+\\).*$" end t)
        (let* ((fence (match-string-no-properties 1))
               (char (aref fence 0))
               (length (length fence)))
          (cond
           ((null open-start)
            (setq open-start (line-beginning-position)
                  open-char char
                  open-length length))
           ((and (= char open-char) (>= length open-length))
            (push (cons open-start (min end (1+ (line-end-position)))) ranges)
            (setq open-start nil open-char nil open-length nil)))))
      (when open-start
        (push (cons open-start end) ranges)))
    (nreverse ranges)))

(defun pichat-markdown-presentation--fenced-code-ranges (beg end)
  "Return cached absolute fenced-code ranges in BEG..END."
  (mapcar (lambda (range) (cons (+ beg (car range)) (+ beg (cdr range))))
          (pichat-markdown-parsed-run-fenced-code-ranges
           (pichat-markdown-presentation-parse-run beg end))))

(defun pichat-markdown-presentation--table-width-policy (&optional buffer-window)
  "Return (RENDER-WIDTH . TARGET-WIDTH) for the current PiChat buffer.
Optional BUFFER-WINDOW selects a specific displayed window.  RENDER-WIDTH is
the width observed in the current rendering context.  TARGET-WIDTH is capped
by `pichat-max-width' and then reduced by the configured table fraction."
  (let* ((render-width (max 1 (window-body-width)))
         (buffer-window (or buffer-window
                            (get-buffer-window (current-buffer) t)))
         (visible-width (max 1 (if buffer-window
                                   (window-body-width buffer-window)
                                 render-width)))
         (bounded-width (if (integerp pichat-max-width)
                            (min visible-width pichat-max-width)
                          visible-width))
         (target-width (max 1 (floor (* bounded-width
                                       pichat-chat-table-max-width-fraction)))))
    (cons render-width target-width)))

(defun pichat-markdown-presentation--ensure-table-layout-cache ()
  "Ensure current buffer has a position-independent table layout cache."
  (unless (hash-table-p pichat-markdown-presentation--table-layout-cache)
    (setq pichat-markdown-presentation--table-layout-cache
          (make-hash-table :test #'equal)
          pichat-markdown-presentation--table-layout-cache-order nil)))

(defun pichat-markdown-presentation--cache-table-layout (key layout)
  "Cache LAYOUT under KEY and evict old layouts incrementally."
  (puthash key layout pichat-markdown-presentation--table-layout-cache)
  (push key pichat-markdown-presentation--table-layout-cache-order)
  (while (> (hash-table-count
             pichat-markdown-presentation--table-layout-cache)
            (max 1 pichat-chat-table-layout-cache-max-entries))
    (let ((oldest
           (car (last
                 pichat-markdown-presentation--table-layout-cache-order))))
      (setq pichat-markdown-presentation--table-layout-cache-order
            (butlast pichat-markdown-presentation--table-layout-cache-order))
      (remhash oldest pichat-markdown-presentation--table-layout-cache)))
  layout)

(defun pichat-markdown-presentation--table-layout-key (table target-width)
  "Return layout cache key for TABLE at TARGET-WIDTH."
  (list (pichat-markdown-table-source-digest table)
        target-width
        pichat-chat-table-unicode-borders
        pichat-markdown-table-layout-policy-version
        pichat-chat-table-preview-max-rows
        pichat-chat-table-preview-max-columns
        pichat-chat-table-min-column-width
        (face-attribute 'default :family nil t)
        (face-attribute 'default :height nil t)))

(defun pichat-markdown-presentation--table-metadata
    (beg end key state table source-base)
  "Create table metadata over BEG..END for KEY and STATE.
TABLE uses positions relative to SOURCE-BASE."
  (let ((overlay (pichat-markdown-presentation--metadata-overlay
                  beg end 'table key state nil)))
    (overlay-put overlay 'pichat-markdown-table-model table)
    (overlay-put overlay 'pichat-markdown-source-base source-base)
    (overlay-put overlay 'keymap pichat-markdown-presentation-table-map)
    (overlay-put overlay 'help-echo "RET: open complete PiChat table")
    overlay))

(defun pichat-markdown-presentation--table-row-overlay
    (table-beg row key)
  "Create one rendered ROW overlay at TABLE-BEG for KEY."
  (let* ((beg (+ table-beg (pichat-markdown-table-layout-row-start row)))
         (end (+ table-beg (pichat-markdown-table-layout-row-end row)))
         (text (copy-sequence (pichat-markdown-table-layout-row-text row)))
         (line-prefix (get-text-property beg 'line-prefix))
         (wrap-prefix (get-text-property beg 'wrap-prefix))
         (overlay (make-overlay beg end nil nil t)))
    (when (> (length text) 0)
      (add-text-properties
       0 (length text)
       (list 'keymap pichat-markdown-presentation-table-map
             'help-echo "RET: open complete PiChat table")
       text)
      (when line-prefix
        (add-text-properties 0 (length text)
                             (list 'line-prefix line-prefix) text))
      (when wrap-prefix
        (add-text-properties 0 (length text)
                             (list 'wrap-prefix wrap-prefix) text)))
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'priority 30)
    (overlay-put overlay 'pichat-markdown-presentation t)
    (overlay-put overlay 'pichat-markdown-kind 'table)
    (overlay-put overlay 'pichat-markdown-key key)
    (overlay-put overlay 'pichat-markdown-state 'rendered)
    (overlay-put overlay 'pichat-markdown-rendered t)
    (overlay-put overlay 'pichat-markdown-table-row-kind
                 (pichat-markdown-table-layout-row-kind row))
    (overlay-put overlay 'keymap pichat-markdown-presentation-table-map)
    (overlay-put overlay 'help-echo "RET: open complete PiChat table")
    (overlay-put overlay 'display "")
    (overlay-put overlay 'before-string text)
    (pichat-markdown-presentation--register-overlay key overlay)))

(defun pichat-markdown-presentation--render-table (table source-base key)
  "Render parsed TABLE relative to SOURCE-BASE using stable KEY.
Return non-nil when a useful bounded layout was produced."
  (let* ((beg (+ source-base (pichat-markdown-table-start table)))
         (end (+ source-base (pichat-markdown-table-end table)))
         (target-width
          (cdr (pichat-markdown-presentation--table-width-policy)))
         (layout-key (pichat-markdown-presentation--table-layout-key
                      table target-width)))
    (setq pichat-markdown-presentation--table-width target-width)
    (pichat-markdown-presentation--ensure-table-layout-cache)
    (let ((layout
           (or (gethash layout-key
                        pichat-markdown-presentation--table-layout-cache)
               (let ((value
                      (pichat-markdown-table-make-layout
                       table target-width
                       pichat-chat-table-preview-max-rows
                       pichat-chat-table-preview-max-columns
                       pichat-chat-table-unicode-borders
                       pichat-chat-table-min-column-width)))
                 (when value
                   (pichat-markdown-presentation--cache-table-layout
                    layout-key value))))))
      (if (null layout)
          (progn
            ;; Keep the requested rendered state so a later width increase can
            ;; retry this raw-source fallback without a full projection.
            (pichat-markdown-presentation--table-metadata
             beg end key 'rendered table source-base)
            nil)
        (dolist (row (pichat-markdown-table-layout-rows layout))
          (pichat-markdown-presentation--table-row-overlay beg row key))
        (pichat-markdown-presentation--table-metadata
         beg end key 'rendered table source-base)
        t))))

(defun pichat-markdown-presentation--present-run (beg end counters)
  "Present one prose run BEG..END using item COUNTERS."
  (let* ((node-key (get-text-property beg 'pichat-node-key))
         (parsed (pichat-markdown-presentation-parse-run beg end))
         (tables (pichat-markdown-parsed-run-tables parsed))
         table-ranges)
    (dolist (table tables)
      (let* ((range (cons (+ beg (pichat-markdown-table-start table))
                          (+ beg (pichat-markdown-table-end table))))
             (counter-key (cons node-key 'table))
             (ordinal (1+ (gethash counter-key counters 0)))
             (key (pichat-markdown-presentation--item-key
                   'table ordinal (car range) (cdr range) node-key))
             (state (pichat-markdown-presentation--state
                     key (if pichat-chat-prettify-tables 'rendered 'source))))
        (puthash counter-key ordinal counters)
        (push range table-ranges)
        (condition-case err
            (if (eq state 'rendered)
                (pichat-markdown-presentation--render-table table beg key)
              (pichat-markdown-presentation--table-metadata
               (car range) (cdr range) key 'source table beg))
          (error
           (pichat-markdown-presentation--remove-item key)
           (pichat-markdown-presentation--table-metadata
            (car range) (cdr range) key 'source table beg)
           (pichat-markdown-presentation--warn-once
            'table-render
            (format "PiChat Markdown table rendering failed: %s"
                    (error-message-string err)))))))
    (dolist (link (pichat-markdown-presentation--extract-links beg end))
      (unless (pichat-markdown-presentation--range-contained-p
               (pichat-markdown-link-start link)
               (pichat-markdown-link-end link)
               table-ranges)
        (let* ((counter-key (cons node-key 'link))
               (ordinal (1+ (gethash counter-key counters 0)))
               (key (pichat-markdown-presentation--item-key
                     'link ordinal
                     (pichat-markdown-link-start link)
                     (pichat-markdown-link-end link)
                     node-key))
               (state (pichat-markdown-presentation--state
                       key (if pichat-chat-compact-links 'compact 'source))))
          (puthash counter-key ordinal counters)
          (pichat-markdown-presentation--present-link link key state))))))

(defun pichat-markdown-presentation-refresh-region (beg end)
  "Recreate derived Markdown presentation in assistant prose BEG..END."
  (when (< beg end)
    (save-restriction
      (widen)
      (setq beg (max (point-min) beg)
            end (min (point-max) end))
      (pichat-markdown-presentation-remove-region beg end)
      (let ((pos beg)
            (counters (make-hash-table :test #'equal)))
        (while (< pos end)
          (let ((next (or (next-single-property-change
                           pos 'pichat-prose nil end)
                          end)))
            (when (get-text-property pos 'pichat-prose)
              (condition-case err
                  (pichat-markdown-presentation--present-run pos next counters)
                (error
                 (pichat-markdown-presentation-remove-region pos next)
                 (pichat-markdown-presentation--warn-once
                  'refresh
                  (format "PiChat Markdown presentation disabled for a prose run: %s"
                          (error-message-string err))))))
            (setq pos next)))))))

(defun pichat-markdown-presentation--prune-states ()
  "Drop explicit states for Markdown items no longer in this projection."
  (pichat-markdown-presentation--ensure-state)
  (pichat-markdown-presentation--prune-overlay-registry)
  (let (stale)
    (maphash (lambda (key _state)
               (unless (and (hash-table-p
                             pichat-markdown-presentation--overlays)
                            (gethash key
                                     pichat-markdown-presentation--overlays))
                 (push key stale)))
             pichat-markdown-presentation--states)
    (dolist (key stale)
      (remhash key pichat-markdown-presentation--states))))

(defun pichat-markdown-presentation-refresh-buffer ()
  "Recreate Markdown presentation for all projected assistant prose."
  (interactive)
  (pichat-markdown-presentation--with-parse-cycle
    (pichat-markdown-presentation-refresh-region (point-min) (point-max))
    (pichat-markdown-presentation--prune-states)))

(defun pichat-markdown-presentation--refresh-after-toggle ()
  "Refresh presentation without allowing optional failures to escape."
  (condition-case err
      (pichat-markdown-presentation-refresh-buffer)
    (error
     (pichat-markdown-presentation-remove-buffer)
     (pichat-markdown-presentation--warn-once
      'toggle (format "PiChat Markdown toggle failed: %s"
                      (error-message-string err))))))

(defun pichat-markdown-presentation-refresh-rendered-tables ()
  "Re-render only currently rendered tables for a changed display width."
  (pichat-markdown-presentation--prune-overlay-registry)
  (let (tables)
    (when (hash-table-p pichat-markdown-presentation--overlays)
      (maphash
       (lambda (key overlays)
         (when-let ((metadata
                     (seq-find
                      (lambda (overlay)
                        (and (overlay-buffer overlay)
                             (overlay-get overlay 'pichat-markdown-metadata)
                             (eq (overlay-get overlay 'pichat-markdown-kind)
                                 'table)
                             (eq (overlay-get overlay 'pichat-markdown-state)
                                 'rendered)))
                      overlays)))
           (push (list key (overlay-start metadata) (overlay-end metadata)
                       (overlay-get metadata 'pichat-markdown-table-model)
                       (overlay-get metadata 'pichat-markdown-source-base))
                 tables)))
       pichat-markdown-presentation--overlays))
    (pcase-dolist (`(,key ,beg ,end ,table ,source-base) tables)
      (pichat-markdown-presentation--remove-item key)
      (condition-case err
          (pichat-markdown-presentation--present-table-range
           beg end key 'rendered table source-base)
        (error
         (pichat-markdown-presentation--remove-item key)
         (if table
             (pichat-markdown-presentation--table-metadata
              beg end key 'source table source-base)
           (pichat-markdown-presentation--metadata-overlay
            beg end 'table key 'source nil))
         (pichat-markdown-presentation--warn-once
          'width-refresh
          (format "PiChat Markdown table resize failed: %s"
                  (error-message-string err))))))))

(defun pichat-markdown-presentation--run-width-refresh (buffer generation)
  "Refresh rendered tables in BUFFER if GENERATION is still current."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq pichat-markdown-presentation--width-timer nil)
      (when (and (derived-mode-p 'pichat-chat-mode)
                 (= generation (or pichat-chat--source-generation 0)))
        (pichat-markdown-presentation-refresh-rendered-tables)))))

(defun pichat-markdown-presentation-handle-window-change (window)
  "Debounce a table-only refresh after a PiChat WINDOW width change."
  (when (and (derived-mode-p 'pichat-chat-mode)
             (window-live-p window))
    (let ((target (cdr (pichat-markdown-presentation--table-width-policy
                        window))))
      (unless (equal target pichat-markdown-presentation--table-width)
        (setq pichat-markdown-presentation--table-width target)
        (when (timerp pichat-markdown-presentation--width-timer)
          (cancel-timer pichat-markdown-presentation--width-timer))
        (setq pichat-markdown-presentation--width-timer
              (run-with-idle-timer
               0.15 nil
               #'pichat-markdown-presentation--run-width-refresh
               (current-buffer) (or pichat-chat--source-generation 0)))))))

;;;###autoload
(defun pichat-chat-toggle-link-at-point ()
  "Toggle the PiChat Markdown link at point between compact and source."
  (interactive)
  (let ((overlay (pichat-markdown-presentation--overlay-at-point 'link)))
    (unless overlay (user-error "No PiChat Markdown link at point"))
    (let* ((key (overlay-get overlay 'pichat-markdown-key))
           (state (if (eq (overlay-get overlay 'pichat-markdown-state) 'compact)
                      'source
                    'compact))
           (link (pichat-markdown-link-create
                  :start (overlay-start overlay)
                  :end (overlay-end overlay)
                  :label (overlay-get overlay 'pichat-markdown-label)
                  :url (overlay-get overlay 'pichat-markdown-url)
                  :title (overlay-get overlay 'pichat-markdown-title)
                  :form (overlay-get overlay 'pichat-markdown-form))))
      (pichat-markdown-presentation--set-state key state)
      (pichat-markdown-presentation--remove-item key)
      (pichat-markdown-presentation--present-link link key state))))

;;;###autoload
(defun pichat-chat-toggle-link-display ()
  "Toggle all PiChat Markdown links between compact and source display."
  (interactive)
  (setq-local pichat-chat-compact-links (not pichat-chat-compact-links))
  (pichat-markdown-presentation--clear-kind-states 'link)
  (pichat-markdown-presentation--refresh-after-toggle)
  (message "PiChat compact links: %s"
           (if pichat-chat-compact-links "enabled" "disabled")))

(defun pichat-markdown-presentation--find-table-in-range (beg end)
  "Return a parsed table occupying exactly BEG..END, or nil."
  (let* ((source (buffer-substring-no-properties beg end))
         (table (car (pichat-markdown-table-parse source))))
    (and table
         (= 0 (pichat-markdown-table-start table))
         (= (length source) (pichat-markdown-table-end table))
         table)))

(defun pichat-markdown-presentation--table-model-current-p
    (table source-base beg end)
  "Return non-nil when TABLE at SOURCE-BASE still describes BEG..END."
  (and (pichat-markdown-table-p table)
       (integer-or-marker-p source-base)
       (= beg (+ source-base (pichat-markdown-table-start table)))
       (= end (+ source-base (pichat-markdown-table-end table)))
       (equal (pichat-markdown-table-source-digest table)
              (secure-hash 'sha1
                           (buffer-substring-no-properties beg end)))))

(defun pichat-markdown-presentation--table-metadata-current-p
    (overlay key generation)
  "Return non-nil when table metadata OVERLAY still matches KEY and GENERATION."
  (and (overlayp overlay)
       (eq (overlay-buffer overlay) (current-buffer))
       (overlay-get overlay 'pichat-markdown-metadata)
       (eq (overlay-get overlay 'pichat-markdown-kind) 'table)
       (equal (overlay-get overlay 'pichat-markdown-key) key)
       (equal generation (or pichat-chat--source-generation 0))
       (equal generation (nth 0 key))
       (eq (nth 2 key) 'table)
       (integer-or-marker-p (overlay-start overlay))
       (integer-or-marker-p (overlay-end overlay))
       (< (overlay-start overlay) (overlay-end overlay))
       (equal (nth 1 key)
              (get-text-property (overlay-start overlay) 'pichat-node-key))
       (equal (nth 4 key)
              (secure-hash
               'sha1
               (buffer-substring-no-properties
                (overlay-start overlay) (overlay-end overlay))))))

(defun pichat-markdown-presentation-resolve-table-origin
    (buffer key generation origin-marker)
  "Return current table position in BUFFER for KEY and GENERATION, or nil.
ORIGIN-MARKER is used to prefer the original logical range when it remains
inside one of the recreated metadata overlays."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((overlays
              (and (hash-table-p pichat-markdown-presentation--overlays)
                   (gethash key pichat-markdown-presentation--overlays)))
             (current
              (cl-remove-if-not
               (lambda (overlay)
                 (pichat-markdown-presentation--table-metadata-current-p
                  overlay key generation))
               overlays))
             (marker-position
              (and (markerp origin-marker)
                   (eq (marker-buffer origin-marker) buffer)
                   (marker-position origin-marker)))
             (metadata
              (or (and marker-position
                       (seq-find
                        (lambda (overlay)
                          (and (<= (overlay-start overlay) marker-position)
                               (<= marker-position (overlay-end overlay))))
                        current))
                  (car current))))
        (and metadata (overlay-start metadata))))))

;;;###autoload
(defun pichat-chat-open-table-at-point ()
  "Open the complete PiChat Markdown table at point in an immutable viewer."
  (interactive)
  (let ((overlay (pichat-markdown-presentation--overlay-at-point 'table)))
    (unless overlay
      (user-error "No PiChat Markdown table at point"))
    (let* ((key (overlay-get overlay 'pichat-markdown-key))
           (generation (nth 0 key))
           (beg (overlay-start overlay))
           (end (overlay-end overlay))
           (table (overlay-get overlay 'pichat-markdown-table-model))
           (source-base (overlay-get overlay 'pichat-markdown-source-base)))
      (unless (pichat-markdown-presentation--table-metadata-current-p
               overlay key generation)
        (user-error "PiChat Markdown table at point is stale"))
      (let ((source (buffer-substring-no-properties beg end)))
        (unless (pichat-markdown-presentation--table-model-current-p
                 table source-base beg end)
          (setq table (pichat-markdown-presentation--find-table-in-range
                       beg end)))
        (unless (pichat-markdown-table-p table)
          (user-error "PiChat Markdown table at point is no longer valid"))
        (condition-case err
            (pichat-markdown-table-open-viewer
             source table (current-buffer) key generation beg
             #'pichat-markdown-presentation-resolve-table-origin)
          (error
           (user-error
            "Could not open PiChat table: %s"
            (truncate-string-to-width (error-message-string err) 160))))))))

(defun pichat-markdown-presentation--present-table-range
    (beg end key state &optional table source-base)
  "Present table BEG..END identified by KEY according to STATE.
Optional TABLE uses offsets relative to SOURCE-BASE and avoids reparsing when it
still matches the exact source range."
  (unless (pichat-markdown-presentation--table-model-current-p
           table source-base beg end)
    (setq table (pichat-markdown-presentation--find-table-in-range beg end)
          source-base beg))
  (if (null table)
      (pichat-markdown-presentation--metadata-overlay
       beg end 'table key 'source nil)
    (if (eq state 'rendered)
        (pichat-markdown-presentation--render-table table source-base key)
      (pichat-markdown-presentation--table-metadata
       beg end key 'source table source-base))))

;;;###autoload
(defun pichat-chat-toggle-table-at-point ()
  "Toggle the PiChat Markdown table at point between rendered and source."
  (interactive)
  (let ((overlay (pichat-markdown-presentation--overlay-at-point 'table)))
    (unless overlay (user-error "No PiChat Markdown table at point"))
    (let* ((key (overlay-get overlay 'pichat-markdown-key))
           (beg (overlay-start overlay))
           (end (overlay-end overlay))
           (table (overlay-get overlay 'pichat-markdown-table-model))
           (source-base (overlay-get overlay 'pichat-markdown-source-base))
           (state (if (eq (overlay-get overlay 'pichat-markdown-state) 'rendered)
                      'source
                    'rendered)))
      (pichat-markdown-presentation--set-state key state)
      (pichat-markdown-presentation--remove-item key)
      (condition-case err
          (pichat-markdown-presentation--present-table-range
           beg end key state table source-base)
        (error
         (pichat-markdown-presentation--remove-item key)
         (if table
             (pichat-markdown-presentation--table-metadata
              beg end key 'source table source-base)
           (pichat-markdown-presentation--metadata-overlay
            beg end 'table key 'source nil))
         (pichat-markdown-presentation--warn-once
          'table-toggle (format "PiChat Markdown table toggle failed: %s"
                                (error-message-string err))))))))

;;;###autoload
(defun pichat-chat-toggle-table-display ()
  "Toggle all PiChat Markdown tables between rendered and source display."
  (interactive)
  (setq-local pichat-chat-prettify-tables
              (not pichat-chat-prettify-tables))
  (pichat-markdown-presentation--clear-kind-states 'table)
  (pichat-markdown-presentation--refresh-after-toggle)
  (message "PiChat formatted tables: %s"
           (if pichat-chat-prettify-tables "enabled" "disabled")))

(provide 'pichat-markdown-presentation)
;;; pichat-markdown-presentation.el ends here
