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

(defun pichat-diagnostics-report--field (label value)
  "Insert bounded plain VALUE with LABEL; nil means unavailable."
  (insert label ": "
          (if (null value) "unavailable"
            (let ((text (pichat-chat-diagnostics--text value)))
              (if (> (length text) 2000)
                  (concat (substring text 0 2000) " [truncated by PiChat]")
                text)))
          "\n"))

(defun pichat-diagnostics-report--process (session)
  "Return SESSION's generation-valid local Emacs process object."
  (let ((process (pichat-session-process session)))
    (and (processp process)
         (let ((generation (process-get process 'pichat-process-generation)))
           (or (null generation)
               (equal generation (pichat-session-process-generation session))))
         process)))

(defun pichat-diagnostics-report--overview (session sections)
  "Build overview text for SESSION from cached SECTIONS only."
  (with-temp-buffer
    (insert "PiChat diagnostics (cached snapshot, not a live health check)\n\n"
            "Evidence may contain secrets, paths and prompt content. Review before sharing.\n"
            "Unavailable means no current cached snapshot, not necessarily a failure.\n"
            "No retained records does not establish health or successful synchronization.\n\n"
            "Runtime / process\n")
    (pichat-diagnostics-report--field "Runtime" (pichat-session-runtime-id session))
    (pichat-diagnostics-report--field "Backend" (pichat-session-backend-id session))
    (pichat-diagnostics-report--field "State" (pichat-session-state session))
    (pichat-diagnostics-report--field
     "Snapshot" (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
    (let ((process (pichat-diagnostics-report--process session)))
      (pichat-diagnostics-report--field "Process status" (and process (process-status process)))
      ;; Even a local runtime may be a wrapper. Never call this the Pi PID.
      (pichat-diagnostics-report--field "Emacs transport PID" (and process (process-id process)))
      (when (and process (memq (process-status process) '(exit signal)))
        (pichat-diagnostics-report--field "Exit status" (process-exit-status process))))
    (pichat-diagnostics-report--field "Process generation" (pichat-session-process-generation session))
    (when (eq (pichat-session-backend-id session) 'pi)
      (pichat-diagnostics-report--field
       "RPC send gate (cached; not a readiness handshake)"
       (if (pichat-session-rpc-ready-p session) "open" "closed"))
      (pichat-diagnostics-report--field
       "Pending RPC requests"
       (let ((pending (pichat-session-pending-responses session)))
         (and (hash-table-p pending) (hash-table-count pending))))
      (pichat-diagnostics-report--field "Queued RPC sends" (length (pichat-session-rpc-send-queue session))))
    (pichat-diagnostics-report--field
     "Chat buffer" (let ((buffer (pichat-session-buffer session)))
                     (and (buffer-live-p buffer) (buffer-name buffer))))
    (insert (if (eq (pichat-session-backend-id session) 'pi)
                "\nPi session (last cached state)\n" "\nSession (last cached state)\n"))
    (pichat-diagnostics-report--field "Session ID" (pichat-session-id session))
    (pichat-diagnostics-report--field "Name" (or (pichat-session-name session) "unset / unavailable"))
    (pichat-diagnostics-report--field
     "Persistence"
     (pcase (pichat-session-persistence session)
       ('persistent "enabled; cached path does not prove a file was written")
       ('ephemeral "disabled (--no-session)")
       ('memory "memory; no resumable file")))
    (let ((runtime (pichat-session-session-file session))
          (emacs (pichat-session-emacs-session-file session)))
      (pichat-diagnostics-report--field "Runtime saved-session path (cached)" runtime)
      (when (and runtime (not (equal runtime emacs)))
        (pichat-diagnostics-report--field "Emacs saved-session path (translated)" emacs)))
    (insert "\nConfiguration (cached)\n")
    (pichat-diagnostics-report--field
     "Model" (unless (equal (pichat-session-model-label session) "—")
               (pichat-session-model-label session)))
    (pichat-diagnostics-report--field "Thinking level" (pichat-session-thinking-level session))
    (pichat-diagnostics-report--field "Preset" (pichat-session-preset-name session))
    (insert "\nExecution context (retained)\n")
    (let ((transport (pichat-session-transport session)))
      (pichat-diagnostics-report--field "Target" (and transport (pichat-transport-label transport)))
      (pichat-diagnostics-report--field "Transport" (and transport (pichat-transport-kind transport)))
      (pichat-diagnostics-report--field
       "Configured executable (not running-version proof)"
       (and transport (pichat-transport-pi-executable transport))))
    (pichat-diagnostics-report--field
     "Owner scope" (or (pichat-session-owner-scope-label session)
                       (pichat-session-scope-label session)))
    (pichat-diagnostics-report--field "Owner directory" (pichat-session-owner-directory session))
    (pichat-diagnostics-report--field "Runtime CWD" (pichat-session-runtime-cwd session))
    (unless (equal (pichat-session-runtime-cwd session) (pichat-session-emacs-cwd session))
      (pichat-diagnostics-report--field "Emacs CWD" (pichat-session-emacs-cwd session)))
    (insert "\nRecorded problems\n")
    (dolist (section sections)
      (insert (car section) "\n")
      (cond
       ((eq (cdr section) :unavailable) (insert "  unavailable (no current cached snapshot)\n"))
       ((null (cdr section)) (insert "  none (no retained diagnostic records)\n"))
       (t
        (dolist (record (seq-take (cdr section) 100))
          (insert "  " (pichat-chat-diagnostics--safe-record-line record) "\n"))
        (when (> (length (cdr section)) 100)
          (insert "  [additional records omitted from display]\n")))))
    (buffer-string)))

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
    (concat
     "Startup selections, not proof of active tools or connection health.\n"
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
       "unavailable (no captured configuration)\n"))))

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
         (shown (seq-take events (max 0 (min 512 pichat-diagnostics-view-event-limit)))))
    (unless pichat-diagnostics-report--folds
      (setq pichat-diagnostics-report--folds (make-hash-table :test #'equal)))
    (setq pichat-diagnostics-report--overview (pichat-diagnostics-report--overview session sections)
          pichat-diagnostics-report--evidence
          (append
           (when (and inspect-p (pichat-session-diagnostics session))
             (list (list 'latest-failure "Latest retained runtime failure"
                         (concat "Historical retained record; may belong to an earlier source or process.\n"
                                 (pichat-chat-diagnostics--print-value
                                  (car (pichat-session-diagnostics session)))))))
           (list
            (list 'launch "Captured launch command"
                  (if (and pi-p inspect-p)
                      (if (pichat-session-rpc-command session)
                          (concat "Captured attempt; not proof of the command currently running.\n"
                                  (pichat-chat-diagnostics--print-value (pichat-session-rpc-command session)))
                        "unavailable (no captured launch argv)\n")
                    "unavailable for this backend\n"))
            (list 'tools "Startup tool selections" (pichat-diagnostics-report--tools session)))
           (mapcar (lambda (section)
                     (list (list 'domain (car section)) (concat (car section) " evidence")
                           (if (eq (cdr section) :unavailable) "unavailable (no current cached snapshot)\n"
                             (if inspect-p (pichat-diagnostics-report--records (cdr section))
                               "unavailable for this backend\n"))))
                   sections)
           (list
            (list 'stderr "Current stderr"
                  (if (and pi-p inspect-p) (pichat-diagnostics-report--stderr session)
                    "unavailable for this backend\n"))
            (list 'events "Retained incoming events"
                  (if (and pi-p inspect-p)
                      (concat
                       (format "Bounded retained subset; %d shown, %d retained events omitted from display.\n"
                               (length shown) (- (length events) (length shown)))
                       "Not a complete request/response trace; source/generation and receipt times unavailable.\n"
                       (pichat-diagnostics-report--records (reverse shown) 512))
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
    (insert pichat-diagnostics-report--overview "\nEvidence (bounded snapshots)\n\n")
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
