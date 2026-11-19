;;; pichat-session-manager-actions.el --- Runtime manager Actions -*- lexical-binding: t; -*-

;;; Commentary:

;; Display cached choices for the exact runtime selected when Actions opens.
;; Existing manager commands own prompts, display policy and backend work.

;;; Code:

(require 'pichat)
(require 'pichat-session-manager)
(require 'pichat-transient)

(defun pichat-session-manager-actions--capture ()
  "Capture the manager buffer and any retained runtime at point."
  (unless (derived-mode-p 'pichat-session-manager-mode)
    (user-error "Open the PiChat runtime manager first"))
  (let* ((id (tabulated-list-get-id))
         (session (and id (pichat-session-by-runtime-id id))))
    (when (and id (not session))
      (user-error "Runtime row is stale; refresh the manager and reopen Actions"))
    (list :origin (current-buffer) :runtime-id id :session session
          :source (and session (pichat-session-manager--preview-source-token session))
          :process (and session (pichat-session-process session))
          :generation (and session (pichat-session-process-generation session)))))

(defun pichat-session-manager-actions--available-p (action session)
  "Return non-nil if row ACTION is offered for SESSION."
  (and session
       (pcase action
         ('stop (pichat-session-alive-p session))
         ('forget (not (pichat-session-alive-p session)))
         ('prefer (and (pichat-session-alive-p session)
                       (not (pichat-session-default-p session))))
         ('diagnostics (pichat-backend-capable-p session 'diagnostics))
         (_ t))))

(defun pichat-session-manager-actions--origin (scope)
  "Return SCOPE's manager buffer or reject the stale menu."
  (let ((origin (plist-get scope :origin)))
    (unless (and (buffer-live-p origin)
                 (with-current-buffer origin
                   (derived-mode-p 'pichat-session-manager-mode)))
      (user-error "Runtime manager changed; reopen Actions"))
    origin))

(defun pichat-session-manager-actions--current (scope action)
  "Return SCOPE's runtime after validating it for ACTION."
  (pichat-session-manager-actions--origin scope)
  (let* ((id (plist-get scope :runtime-id))
         (session (and id (pichat-session-by-runtime-id id))))
    (unless (and (eq session (plist-get scope :session))
                 (pichat-session-manager-actions--available-p action session)
                 (or (not (memq action '(stop forget prefer name)))
                     (and (eq (plist-get scope :process) (pichat-session-process session))
                          (equal (plist-get scope :generation)
                                 (pichat-session-process-generation session))))
                 (or (not (eq action 'name))
                     (equal (plist-get scope :source)
                            (pichat-session-manager--preview-source-token session))))
      (user-error "Runtime or action changed; reopen Actions"))
    session))

(defun pichat-session-manager-actions--invoke (scope action command)
  "Run COMMAND for ACTION in the manager captured by SCOPE."
  (let* ((origin (pichat-session-manager-actions--origin scope))
         (row-action (not (or (memq action '(new launch))
                              (and (eq action 'browse)
                                   (not (plist-get scope :runtime-id))))))
         (validate (lambda ()
                     (if row-action
                         (pichat-session-manager-actions--current scope action)
                       (pichat-session-manager-actions--origin scope)
                       nil)))
         (session (funcall validate)))
    ;; Establish the actual view origin for commands that open another window.
    (unless (and (eq (current-buffer) origin)
                 (eq (window-buffer) origin))
      (pop-to-buffer origin)
      (setq session (funcall validate)))
    (pcase action
      ((or 'new 'launch) (call-interactively command))
      ((or 'name 'stop) (funcall command session validate))
      (_ (funcall command session)))))

(defun pichat-session-manager-actions--suffixes (group)
  "Build GROUP's suffixes for the captured manager and runtime."
  (let* ((scope (transient-scope))
         (session (plist-get scope :session))
         (items
          (pcase group
            ('runtime
             `((open "o" "Open chat" pichat-session-manager-open-chat)
               (name "e" "Name…" pichat-session-manager-name)
               (prefer "m" "Make preferred" pichat-session-manager-make-default)
               (stop "k" ,(if (and session (pichat-session-manager--stop-prompt session))
                              "Stop…" "Stop") pichat-session-manager-stop)
               (forget "d" "Forget" pichat-session-manager-forget)))
            ('inspect
             '((preview "p" "Preview (toggle)" pichat-session-manager-toggle-preview)
               (diagnostics "D" "Diagnostics (cached)" pichat-session-manager-diagnostics)))
            ('start
             '((new "n" "New runtime in project…" pichat-session-manager-new)
               (new-in-scope "N" "New runtime in this scope" pichat-session-manager-new-in-scope)
               (launch "+" "Launch menu…" pichat-session-manager-launch)
               (browse "b" "Open saved session…" pichat-session-manager-browse-saved))))))
    (transient-parse-suffixes
     'pichat-session-manager-actions
     (cl-loop for (action key label command) in items
              when (or (memq action '(new launch browse))
                       (pichat-session-manager-actions--available-p action session))
              collect (let ((operation action) (fn command))
                        (list key label
                              (lambda () (interactive)
                                (pichat-session-manager-actions--invoke
                                 scope operation fn))))))))

;;;###autoload (autoload 'pichat-session-manager-actions "pichat-session-manager-actions" nil t)
(transient-define-prefix pichat-session-manager-actions ()
  "Show Actions for the captured runtime, or just Start if there is no row.
Opening or closing the menu does not contact the runtime."
  [["Runtime" :class transient-column
    :setup-children (lambda (_) (pichat-session-manager-actions--suffixes 'runtime))]
   ["Inspect" :class transient-column
    :setup-children (lambda (_) (pichat-session-manager-actions--suffixes 'inspect))]
   ["Start" :class transient-column
    :setup-children (lambda (_) (pichat-session-manager-actions--suffixes 'start))]]
  [("q" "Close" transient-quit-one)]
  (interactive)
  (transient-setup 'pichat-session-manager-actions nil nil
                   :scope (pichat-session-manager-actions--capture)))

(provide 'pichat-session-manager-actions)
;;; pichat-session-manager-actions.el ends here
