;;; pichat-chat-queue.el --- Pi queue projection and recall -*- lexical-binding: t; -*-

;;; Commentary:
;; Queue events and clear responses are text-only.  Retain submitted images only
;; while an ordered, unambiguous match to Pi's queue exists; never requeue input.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-backend)
(require 'pichat-attachments)

(defvar pichat-chat-session)
(defvar pichat-chat--source-generation)
(defvar pichat-chat--editor-generation)
(defvar pichat-chat--pending-attachments)
(defvar pichat-chat--recoverable-submissions)
(defvar-local pichat-chat--pi-queue nil "Projected Pi queue records, steering first.")
(defvar-local pichat-chat--queue-candidates nil "Streaming submissions awaiting queue events.")
(defvar-local pichat-chat--queue-recall nil "Identity of an outstanding recall request.")

(declare-function pichat-chat--render-extension-widgets "pichat-chat" ())
(declare-function pichat-chat--input-text "pichat-chat" ())
(declare-function pichat-chat--set-input-text "pichat-chat" (text))
(declare-function pichat-chat--set-status "pichat-chat" (key text))
(declare-function pichat-chat-draft-capture "pichat-chat" (&optional buffer source-token))
(declare-function pichat-chat-draft-current-p "pichat-chat" (target))
(declare-function pichat-chat--refresh-attachment-status "pichat-chat-input" ())
(declare-function pichat-chat--update-recovery-status "pichat-chat-input" ())

(defun pichat-chat-queue-reset ()
  "Discard source-bound queue copies and invalidate pending recall UI."
  (let ((visible pichat-chat--pi-queue))
    (setq pichat-chat--pi-queue nil pichat-chat--queue-candidates nil
          pichat-chat--queue-recall nil)
    (when visible (pichat-chat--render-extension-widgets))))

(defun pichat-chat-queue-track (record behavior &optional wire-text)
  "Register RECORD before dispatch with BEHAVIOR and optional exact WIRE-TEXT."
  (when behavior
    (let ((copy (list :text (or wire-text (string-trim (plist-get record :text)))
                      :attachments (plist-get record :attachments)
                      :behavior behavior :known t)))
      (setq pichat-chat--queue-candidates
            (append pichat-chat--queue-candidates (list copy)))
      copy)))

(defun pichat-chat-queue-finish (candidate)
  "Retire CANDIDATE after its request completes."
  (setq pichat-chat--queue-candidates (delq candidate pichat-chat--queue-candidates)))

(defun pichat-chat-queue-records (raw copies)
  "Match text-only RAW queue against ordered COPIES conservatively.
Only a contiguous ordered match with unique text retains image provenance.
Unknown entries, duplicates and mismatches remain explicitly text-only."
  (cl-loop for (key behavior) in '((:steering "steer") (:followUp "followUp"))
           append
           (let* ((texts (cl-remove-if-not #'stringp (append (plist-get raw key) nil)))
                  (pool (cl-remove-if-not
                         (lambda (r) (equal behavior (plist-get r :behavior))) copies))
                  (start (cl-position (car texts) pool :key (lambda (r) (plist-get r :text))
                                      :test #'equal))
                  (matched (and texts start
                                (cl-subseq pool start (min (length pool) (+ start (length texts))))))
                  (ordered (equal texts (mapcar (lambda (r) (plist-get r :text)) matched))))
             (cl-loop for text in texts for index from 0
                      for copy = (and ordered (nth index matched))
                      for known = (and copy (plist-get copy :known)
                                       (= 1 (cl-count text texts :test #'equal))
                                       (= 1 (cl-count text pool :key (lambda (r) (plist-get r :text))
                                                      :test #'equal)))
                      collect (list :text text :behavior behavior :known known
                                    :attachments (and known (plist-get copy :attachments)))))))

(defun pichat-chat-queue-update (raw)
  "Project authoritative RAW queue, releasing drained image copies."
  (setq pichat-chat--pi-queue
        (pichat-chat-queue-records raw (append pichat-chat--pi-queue
                                               pichat-chat--queue-candidates)))
  ;; A candidate retires at acknowledgment or its first queue event, so a
  ;; subsequent event cannot count an outstanding request's copy twice.
  (dolist (candidate pichat-chat--queue-candidates)
    (when (cl-find-if (lambda (r) (and (equal (plist-get r :text) (plist-get candidate :text))
                                      (equal (plist-get r :behavior) (plist-get candidate :behavior))))
                      pichat-chat--pi-queue)
      (pichat-chat-queue-finish candidate)))
  (pichat-chat--render-extension-widgets))

(defvar pichat-chat-queue-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'pichat-chat-recall-queue)
    (define-key map [return] #'pichat-chat-recall-queue)
    map)
  "Actions on Pi-queued items; Pi supports recall-all only, not item deletion.")

(defun pichat-chat-queue-insert-panel ()
  "Insert Pi's queue at point; the caller owns region protection."
  (when pichat-chat--pi-queue
    (insert (propertize "├ queued in Pi ───────────────────────\n" 'face 'shadow))
    (cl-loop for record in pichat-chat--pi-queue for number from 1
             for images = (length (plist-get record :attachments))
             do (insert
                 (propertize
                  (format "%d queued in Pi · %s · %s%s\n" number
                          (if (equal "steer" (plist-get record :behavior)) "steering" "follow-up")
                          (truncate-string-to-width
                           (replace-regexp-in-string "[[:space:][:cntrl:]]+" " " (plist-get record :text))
                           60 nil nil "…")
                          (cond ((> images 0) (format " [%d img]" images))
                                ((not (plist-get record :known)) " [images unknown]")
                                (t "")))
                  'keymap pichat-chat-queue-map 'mouse-face 'highlight
                  'help-echo "RET: recall all queued in Pi (not just this item)")))
    (insert (propertize "C-c C-y / RET on item: recall all queued in Pi · C-c C-k: abort\n"
                        'face 'shadow))))

;;;###autoload
(defun pichat-chat-recall-queue ()
  "Clear Pi's entire queue and recall its text and matching submitted images.
Never resend remaining items or overwrite a draft edited while RPC is pending."
  (interactive)
  (unless pichat-chat--pi-queue (user-error "No messages queued in Pi"))
  (when pichat-chat--queue-recall (user-error "Pi queue recall is already pending"))
  (unless (and (string-empty-p (pichat-chat--input-text))
               (null pichat-chat--pending-attachments))
    (user-error "Current PiChat editor is not empty"))
  (let* ((buffer (current-buffer)) (session pichat-chat-session)
         (target (pichat-chat-draft-capture))
         (source pichat-chat--source-generation)
         (editor pichat-chat--editor-generation)
         (copies pichat-chat--pi-queue)
         (token (make-symbol "queue-recall"))
         finished)
    (setq pichat-chat--queue-recall token)
    (condition-case err
        (pichat-backend-clear-session-queue
         session
         (lambda (response response-session)
           (when (and (not finished) (eq session response-session))
             (setq finished t)
             (let* ((records (pichat-chat-queue-records (plist-get response :data) copies))
                    (text (string-join (mapcar (lambda (r) (plist-get r :text)) records) "\n\n"))
                    (images (cl-loop for r in records append (plist-get r :attachments)))
                    (unknown (cl-some (lambda (r) (not (plist-get r :known))) records))
                    (recovery (list :text text :attachments images :source-generation source
                                    :editor-generation editor)))
               (if (not (buffer-live-p buffer))
                   (when records (push recovery (pichat-session-input-recovery session)))
                 (with-current-buffer buffer
                   (when (eq token pichat-chat--queue-recall)
                     (setq pichat-chat--queue-recall nil))
                   (when records
                     (if (and (pichat-chat-draft-current-p target)
                              (= editor pichat-chat--editor-generation)
                              (string-empty-p (pichat-chat--input-text))
                              (null pichat-chat--pending-attachments))
                         (progn
                           (pichat-chat--set-input-text text)
                           (setq pichat-chat--pending-attachments images)
                           (pichat-chat--refresh-attachment-status))
                       (push recovery pichat-chat--recoverable-submissions)
                       (pichat-chat--update-recovery-status))
                     (when unknown
                       (pichat-chat--set-status
                        'queue-recall "[Queue recalled as text; unmatched images were not restored]")
                       (message "PiChat: unmatched queue images were not restored"))))))))
         (lambda (_response _session)
           (unless finished
             (setq finished t)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq token pichat-chat--queue-recall)
                   (setq pichat-chat--queue-recall nil)
                   (pichat-chat--set-status 'queue-recall "[Pi queue recall failed; queue not restored]")))))))
      (error (setq pichat-chat--queue-recall nil)
             (signal (car err) (cdr err))))))

(provide 'pichat-chat-queue)
;;; pichat-chat-queue.el ends here
