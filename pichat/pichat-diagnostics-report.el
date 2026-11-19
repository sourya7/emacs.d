;;; pichat-diagnostics-report.el --- Cached runtime report -*- lexical-binding: t; -*-

;;; Commentary:

;; Presentation only.  Collectors retain their own records; this buffer keeps
;; bounded display strings, never live requests or a second diagnostic store.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'seq)
(require 'pichat-session)
(require 'pichat-path)
(require 'pichat-diagnostic)

(defvar pichat-diagnostics-view-event-limit)
(defvar pichat-diagnostics-stderr-limit)
(declare-function pichat-chat-diagnostics--text "pichat-chat-diagnostics" (value))
(declare-function pichat-chat-diagnostics--print-value "pichat-chat-diagnostics" (value))
(declare-function pichat-chat-diagnostics--safe-record-line "pichat-chat-diagnostics" (record))

(defvar pichat-diagnostics-report--button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (dolist (key '("TAB" "<tab>" "RET"))
      (define-key map (kbd key) #'pichat-diagnostics-toggle-section))
    map)
  "Disclosure keys take precedence over the standard button TAB motion.")

(defvar-local pichat-diagnostics-report--overview nil)
(defvar-local pichat-diagnostics-report--evidence nil)
(defvar-local pichat-diagnostics-report--folds nil
  "Section identity to explicit or initial expansion state.
Absent sections remain in this table so reappearing sections retain choices.")

(defun pichat-diagnostics-report--text (value)
  "Return bounded single-line text for VALUE, or nil when unavailable."
  (when value
    (let ((text (replace-regexp-in-string
                 "[\n\r\t\f\v]+" " " (pichat-chat-diagnostics--text value))))
      (unless (string-empty-p text)
        (if (> (length text) 2000)
            (concat (substring text 0 2000) " [truncated by PiChat]")
          text)))))

(defun pichat-diagnostics-report--dim (text)
  "Return TEXT in the shadow face, or nil when TEXT is nil."
  (and text (propertize text 'face 'shadow)))

(defun pichat-diagnostics-report--face (text face)
  "Return TEXT in FACE when FACE is non-nil, otherwise TEXT unchanged."
  (if (and text face) (propertize text 'face face) text))

(defun pichat-diagnostics-report--row (label &rest lines)
  "Insert LABEL beside LINES, each a list of parts joined by middle dots.
LABEL is bold unless it already has a face.  Nil parts and lines without
parts are omitted; later lines are indented."
  (let ((first t)
        (label (if (get-text-property 0 'face label) label
                 (propertize label 'face 'bold)))
        (separator (pichat-diagnostics-report--dim " · ")))
    (dolist (line lines)
      (let ((parts (delq nil (copy-sequence line))))
        (when parts
          (insert (if first
                      (concat label (make-string (max 1 (- 12 (length label))) ?\s))
                    (make-string 12 ?\s))
                  (string-join parts separator) "\n")
          (setq first nil))))))

(defun pichat-diagnostics-report--path (path)
  "Return PATH with its directory dimmed so the file name stands out.
Split textually: no file name handlers run for presentation."
  (if (string-match "\\`\\(.*/\\)\\([^/]+\\)\\'" path)
      (concat (pichat-diagnostics-report--dim (match-string 1 path))
              (match-string 2 path))
    path))

(defun pichat-diagnostics-report--count (count label)
  "Return COUNT and dimmed LABEL, highlighting a nonzero COUNT as a warning."
  (concat (pichat-diagnostics-report--face (format "%d" count) (and (> count 0) 'warning))
          (pichat-diagnostics-report--dim (concat " " label))))

(defun pichat-diagnostics-report--severity-face (sections)
  "Return `error' if any record in SECTIONS has error severity, else `warning'."
  (if (seq-some (lambda (section)
                  (seq-some (lambda (record)
                              (and (listp record)
                                   (member (format "%s" (plist-get record :severity))
                                           '("error" "fatal"))))
                            (cdr section)))
                sections)
      'error 'warning))

(defun pichat-diagnostics-report--process (session)
  "Return SESSION's generation-valid local Emacs process object."
  (let ((process (pichat-session-process session)))
    (and (processp process)
         (let ((generation (process-get process 'pichat-process-generation)))
           (or (null generation)
               (equal generation (pichat-session-process-generation session))))
         process)))

(defun pichat-diagnostics-report--overview (session sections)
  "Build overview text for SESSION from cached SECTIONS only.
Missing values are collected on one Unavailable row rather than per field.
Only abnormal values are highlighted; descriptive words are dimmed."
  (let* ((pi-p (eq (pichat-session-backend-id session) 'pi))
         (process (pichat-diagnostics-report--process session))
         (status (and process (process-status process)))
         (exited (memq status '(exit signal)))
         (transport (pichat-session-transport session))
         (persistence (pichat-session-persistence session))
         unavailable recorded empty)
    (cl-flet ((need (name value &optional prefix face)
                (let ((text (pichat-diagnostics-report--text value)))
                  (if text
                      (concat (pichat-diagnostics-report--dim prefix)
                              (pichat-diagnostics-report--face text face))
                    (push name unavailable)
                    nil)))
              (dim (text) (pichat-diagnostics-report--dim text)))
      (with-temp-buffer
        (pichat-diagnostics-report--row
         "Runtime"
         (list (need "backend" (pichat-session-backend-id session))
               (need "state" (pichat-session-state session) nil
                     (pcase (pichat-session-state session)
                       ((or 'error 'failed) 'error)
                       ((or 'stopped 'retrying) 'warning)))
               (need "chat buffer" (let ((buffer (pichat-session-buffer session)))
                                     (and (buffer-live-p buffer) (buffer-name buffer))))))
        (pichat-diagnostics-report--row
         "Process"
         (list (need "process" status nil (and exited 'error))
               ;; Even a local runtime may be a wrapper. Never call this the Pi PID.
               (and process (process-id process)
                    (concat (dim "Emacs transport PID ") (format "%s" (process-id process))))
               (and exited
                    (concat (dim "exit status ")
                            (propertize (format "%s" (process-exit-status process)) 'face 'error)))
               (need "process generation" (pichat-session-process-generation session)
                     "generation ")))
        (when pi-p
          (let ((pending (pichat-session-pending-responses session))
                (open (pichat-session-rpc-ready-p session)))
            (unless (hash-table-p pending) (push "pending RPC requests" unavailable))
            (pichat-diagnostics-report--row
             "RPC"
             (list (concat (dim "send gate ")
                           (if open "open" (propertize "closed" 'face 'warning)))
                   (and (hash-table-p pending)
                        (pichat-diagnostics-report--count (hash-table-count pending) "pending"))
                   (pichat-diagnostics-report--count
                    (length (pichat-session-rpc-send-queue session)) "queued")))))
        (let* ((runtime (pichat-diagnostics-report--text (pichat-session-session-file session)))
               (emacs (and runtime
                           (pichat-diagnostics-report--text
                            (pichat-session-emacs-session-file session))))
               (translated (and emacs (not (equal runtime emacs)))))
          (unless (or runtime (memq persistence '(ephemeral memory)))
            (push "saved-session path" unavailable))
          (pichat-diagnostics-report--row
           (if pi-p "Pi session" "Session")
           (list (need "session name" (pichat-session-name session)))
           (list (need "session ID" (pichat-session-id session))
                 (pcase persistence
                   ('persistent "persistent")
                   ('ephemeral "ephemeral (--no-session)")
                   ('memory "in memory (no resumable file)")
                   (_ (need "persistence" nil))))
           (list (and runtime (concat (and translated (dim "runtime "))
                                      (pichat-diagnostics-report--path runtime))))
           (list (and translated (concat (dim "Emacs ")
                                         (pichat-diagnostics-report--path emacs))))))
        (pichat-diagnostics-report--row
         "Config"
         (list (need "model" (unless (equal (pichat-session-model-label session) "—")
                               (pichat-session-model-label session)))
               (need "thinking level" (pichat-session-thinking-level session) "thinking ")
               (need "preset" (pichat-session-preset-name session) "preset ")))
        (let* ((label (and transport (pichat-transport-label transport)))
               (kind (and transport (pichat-transport-kind transport)))
               (target (need "target" label))
               (cwd (pichat-session-runtime-cwd session))
               (owner (pichat-session-owner-directory session))
               (emacs-cwd (pichat-session-emacs-cwd session)))
          (pichat-diagnostics-report--row
           "Context"
           (list (if (and target kind (not (equal label (format "%s" kind))))
                     (concat target (dim (format " (%s)" (pichat-diagnostics-report--text kind))))
                   target)
                 (need "owner scope" (or (pichat-session-owner-scope-label session)
                                         (pichat-session-scope-label session))
                       "scope ")
                 (need "runtime working directory" cwd))
           (list (if (equal owner cwd) nil
                   (need "owner directory" owner "owner directory ")))
           (list (unless (equal cwd emacs-cwd)
                   (need "host working directory" emacs-cwd "host working directory ")))
           (list (need "configured executable"
                       (and transport (pichat-transport-pi-executable transport))
                       "executable "))))
        (dolist (section sections)
          (pcase (cdr section)
            (:unavailable (push (concat (car section) " snapshot") unavailable))
            ('nil (push (car section) empty))
            (_ (push section recorded))))
        (when unavailable
          (pichat-diagnostics-report--row
           (dim "Unavailable") (list (dim (string-join (reverse unavailable) ", ")))))
        (insert "\n")
        (setq empty (nreverse empty) recorded (nreverse recorded))
        (let ((none (dim (and empty (format "none retained (%s)" (string-join empty ", "))))))
          (if (null recorded)
              (pichat-diagnostics-report--row
               "Problems" (list (or none (dim "no current cached snapshots"))))
            (let ((face (pichat-diagnostics-report--severity-face recorded)))
              (insert (propertize "Problems" 'face (list 'bold face)) "\n")
              (dolist (section recorded)
                (insert "  " (propertize (car section) 'face face) "\n")
                (dolist (record (seq-take (cdr section) 100))
                  (insert "    " (pichat-chat-diagnostics--safe-record-line record) "\n"))
                (when (> (length (cdr section)) 100)
                  (insert "    " (dim "[additional records omitted from display]") "\n"))))
            (when none (insert "  " none "\n"))))
        (buffer-string)))))

(defun pichat-diagnostics-report--records (records &optional limit)
  "Return bounded display text for retained RECORDS, up to LIMIT (default 100)."
  (if (null records) "none (no retained records)\n"
    (concat
     (mapconcat #'pichat-chat-diagnostics--print-value (seq-take records (or limit 100)) "\n")
     (when (> (length records) (or limit 100)) "\n[additional records omitted from display]")
     "\n")))

(defun pichat-diagnostics-report--tools (session)
  "Return captured startup selections, without resolving configuration."
  (let ((selection (pichat-session-tool-selection session))
        (spec (pichat-session-preset-spec session)))
    (if (or selection spec)
        (pichat-chat-diagnostics--print-value
         (list :builtins (if selection (or (plist-get selection :builtins) :none)
                           (or (plist-get spec :tools) :none))
               :extensions (if selection (or (plist-get selection :extensions) :none)
                             :pi-configuration-unchecked)
               :mcp (if selection (or (plist-get selection :mcp) :disabled)
                      :pi-configuration-unchecked)
               :emacs (if selection (or (plist-get selection :emacs) :none)
                        :unavailable)))
      "unavailable (no captured configuration)\n")))

(defun pichat-diagnostics-report--tools-summary (session)
  "Return a short heading summary of SESSION's captured startup selections."
  (let ((selection (pichat-session-tool-selection session))
        (spec (pichat-session-preset-spec session)))
    (cl-flet ((count (label values none)
                (format "%s %s" label (if values (length values) none))))
      (cond
       (selection
        (string-join (list (count "builtins" (plist-get selection :builtins) "none")
                           (count "extensions" (plist-get selection :extensions) "none")
                           (count "mcp" (plist-get selection :mcp) "disabled")
                           (count "emacs" (plist-get selection :emacs) "none"))
                     " · "))
       (spec (count "builtins" (plist-get spec :tools) "none"))
       (t "unavailable")))))

(defun pichat-diagnostics-report--title (title &optional summary)
  "Return evidence heading TITLE with optional parenthesized SUMMARY."
  (if summary
      (concat title (pichat-diagnostics-report--dim (format " (%s)" summary)))
    title))

(defun pichat-diagnostics-report--stderr (session)
  "Return bounded stderr only from SESSION's exact process buffer."
  (let* ((process (pichat-diagnostics-report--process session))
         (buffer (pichat-session-stderr-buffer session)))
    (if (and process (process-live-p process) (buffer-live-p buffer)
             (eq buffer (process-get process 'pichat-stderr-buffer)))
        (with-current-buffer buffer
          (let* ((end (min (point-max)
                           (+ (point-min) (max 1 (min 16384 pichat-diagnostics-stderr-limit)))))
                 (text (buffer-substring-no-properties (point-min) end)))
            (concat (if (string-empty-p text) "empty (owning live stderr buffer)\n"
                      (pichat-chat-diagnostics--print-value text))
                    (when (< end (point-max)) "\n[stderr truncated by PiChat]\n"))))
      "unavailable (no owning live stderr buffer); captured stderr, if any, is in failure records\n")))

(defun pichat-diagnostics-report-install (session sections)
  "Capture SESSION and provider SECTIONS and render the unified report."
  (let* ((titles '("Runtime / transport" "Canonical transcript" "Live tail" "Session History"))
         (sections (append (mapcar (lambda (title)
                                    (or (assoc title sections) (cons title :unavailable)))
                                  titles)
                           (seq-remove (lambda (section) (member (car section) titles)) sections)))
         (first-open (null pichat-diagnostics-report--folds))
         (pi-p (eq (pichat-session-backend-id session) 'pi))
         (inspect-p (pichat-backend-capable-p session 'diagnostic-view))
         (events (and pi-p inspect-p (pichat-session-event-log session)))
         (shown (seq-take events (max 0 (min 512 pichat-diagnostics-view-event-limit))))
         (stderr (and pi-p inspect-p (pichat-diagnostics-report--stderr session))))
    (unless pichat-diagnostics-report--folds
      (setq pichat-diagnostics-report--folds (make-hash-table :test #'equal)))
    (setq header-line-format
          (concat (propertize "PiChat diagnostics" 'face 'bold)
                  (propertize (format " (%s)" (replace-regexp-in-string
                                               "%" "%%" (or (pichat-diagnostics-report--text
                                                             (pichat-session-runtime-id session))
                                                            "unknown runtime")
                                               t t))
                              'face 'shadow)))
    (setq pichat-diagnostics-report--overview (pichat-diagnostics-report--overview session sections)
          pichat-diagnostics-report--evidence
          (append
           (when (and inspect-p (pichat-session-diagnostics session))
             (list (list 'latest-failure "Latest retained runtime failure"
                         (pichat-chat-diagnostics--print-value
                          (car (pichat-session-diagnostics session))))))
           (list
            (list 'launch
                  (pichat-diagnostics-report--title
                   "Captured launch command"
                   (unless (and pi-p inspect-p (pichat-session-rpc-command session))
                     "unavailable"))
                  (if (and pi-p inspect-p)
                      (if (pichat-session-rpc-command session)
                          (pichat-chat-diagnostics--print-value (pichat-session-rpc-command session))
                        "unavailable (no captured launch argv)\n")
                    "unavailable for this backend\n"))
            (list 'tools
                  (pichat-diagnostics-report--title
                   "Startup tool selections" (pichat-diagnostics-report--tools-summary session))
                  (pichat-diagnostics-report--tools session)))
           ;; Empty and unavailable domains are already reported under Problems.
           (mapcar (lambda (section)
                     (list (list 'domain (car section))
                           (pichat-diagnostics-report--title
                            (concat (car section) " evidence")
                            (format "%d" (length (cdr section))))
                           (if inspect-p (pichat-diagnostics-report--records (cdr section))
                             "unavailable for this backend\n")))
                   (seq-filter (lambda (section) (consp (cdr section))) sections))
           (list
            (list 'stderr
                  (pichat-diagnostics-report--title
                   "Current stderr"
                   (cond ((null stderr) "unavailable")
                         ((string-prefix-p "empty" stderr) "empty")
                         ((string-prefix-p "unavailable" stderr) "unavailable")))
                  (or stderr "unavailable for this backend\n"))
            (list 'events
                  (pichat-diagnostics-report--title
                   "Retained incoming events"
                   (cond ((not (and pi-p inspect-p)) "unavailable")
                         ((null events) "none")
                         (t (format "%d of %d" (length shown) (length events)))))
                  (if (and pi-p inspect-p)
                      (pichat-diagnostics-report--records (reverse shown) 512)
                    "unavailable for this backend\n")))))
    ;; Only the first appearance chooses a default. Refresh must never reopen
    ;; a section the user collapsed, including after a new failure arrives.
    (dolist (section pichat-diagnostics-report--evidence)
      (when (eq (gethash (car section) pichat-diagnostics-report--folds 'absent) 'absent)
        (puthash (car section)
                 (and first-open (eq (car section) 'latest-failure))
                 pichat-diagnostics-report--folds)))
    (pichat-diagnostics-report--render)))

(defun pichat-diagnostics-report--render (&optional selected)
  "Render captured strings and folds, optionally returning to SELECTED section."
  (let ((inhibit-read-only t) target)
    (erase-buffer)
    (insert pichat-diagnostics-report--overview "\n")
    (dolist (section pichat-diagnostics-report--evidence)
      (let* ((id (nth 0 section))
             (open (gethash id pichat-diagnostics-report--folds)))
        (when (equal id selected) (setq target (point)))
        (insert-text-button (concat (if open "▼ " "▶ ") (nth 1 section))
                            'keymap pichat-diagnostics-report--button-map
                            'pichat-diagnostics-section id
                            'follow-link t 'action #'pichat-diagnostics-report--button)
        (insert "\n")
        (when open (insert (nth 2 section) "\n"))))
    (goto-char (or target (point-min)))))

(defun pichat-diagnostics-report--button (button)
  "Toggle the evidence section at BUTTON without acquiring anything."
  (let ((id (button-get button 'pichat-diagnostics-section)))
    (puthash id (not (gethash id pichat-diagnostics-report--folds)) pichat-diagnostics-report--folds)
    (pichat-diagnostics-report--render id)))

(defun pichat-diagnostics-toggle-section ()
  "Toggle the evidence heading at point in the retained snapshot."
  (interactive)
  (let ((button (button-at (point))))
    (unless button (user-error "No diagnostic evidence heading at point"))
    (pichat-diagnostics-report--button button)))

(provide 'pichat-diagnostics-report)
;;; pichat-diagnostics-report.el ends here
