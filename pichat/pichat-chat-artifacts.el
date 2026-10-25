;;; pichat-chat-artifacts.el --- Settled chat artifact adapter -*- lexical-binding: t; -*-
;;; Commentary:
;; Loaded after pichat-chat to avoid circular dependencies.
;;; Code:
(require 'pichat-chat)
(require 'pichat-artifacts)
(require 'pichat-artifact-runner)
(require 'cl-lib)
(defvar avy-action)
(declare-function avy-process "avy" (candidates &optional overlay-fn cleanup-fn))
(declare-function embark-act "embark" (&optional arg))

(defun pichat-chat-artifacts--runs ()
  "Return contiguous (START END NODE) settled assistant prose runs."
  (let ((start (and (markerp pichat-chat--canonical-start)
                    (marker-position pichat-chat--canonical-start)))
        (end (and (markerp pichat-chat--canonical-end)
                  (marker-position pichat-chat--canonical-end))) runs)
    (when (and start end (<= start end))
      (let ((pos start))
        (while (< pos end)
          (let* ((node (get-text-property pos 'pichat-node-key))
                 (valid (and node (eq (get-text-property pos 'pichat-node-role) 'assistant)
                             (get-text-property pos 'pichat-prose)))
                 (next (or (next-single-property-change pos 'pichat-prose nil end) end)))
            (when valid
              (setq next (min next
                              (or (next-single-property-change pos 'pichat-node-key nil end) end)
                              (or (next-single-property-change pos 'pichat-node-role nil end) end)))
              (push (list pos next node) runs))
            (setq pos (if (> next pos) next (1+ pos)))))))
    (nreverse runs)))

(defun pichat-chat-artifacts-all ()
  "Return (DESCRIPTOR START END) for settled assistant artifacts in this chat."
  (when (derived-mode-p 'pichat-chat-mode)
    (cl-loop for (start end node) in (pichat-chat-artifacts--runs)
             append (let ((source (buffer-substring-no-properties start end)))
                      (mapcar (lambda (artifact)
                                (setf (pichat-artifact-identity artifact)
                                      (list (current-buffer) (pichat-chat--source-token)
                                            node source
                                            (pichat-artifact-runner-capture-session pichat-chat-session)
                                            default-directory))
                                (list artifact (+ start (pichat-artifact-start artifact))
                                      (+ start (pichat-artifact-end artifact))))
                              (pichat-artifacts-parse source))))))

(defun pichat-chat-artifacts-at-point ()
  "Return most specific settled artifact and its positions at point."
  (unless (use-region-p)
    (car (sort (cl-remove-if-not
                (lambda (item) (and (<= (nth 1 item) (point)) (< (point) (nth 2 item))))
                (pichat-chat-artifacts-all))
               (lambda (a b) (< (- (nth 2 a) (nth 1 a))
                                (- (nth 2 b) (nth 1 b))))))))

(defun pichat-chat-artifacts-valid-bounds (artifact)
  "Return current bounds for ARTIFACT, or nil after source change or repaint."
  (pcase-let ((`(,buffer ,token ,node ,source . ,_) (pichat-artifact-identity artifact)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (equal token (pichat-chat--source-token))
          (cl-loop for (start end key) in (pichat-chat-artifacts--runs)
                   when (and (equal node key)
                             (equal source (buffer-substring-no-properties start end))
                             (<= (pichat-artifact-end artifact) (- end start)))
                   return (cons (+ start (pichat-artifact-start artifact))
                                (+ start (pichat-artifact-end artifact)))))))))

(defun pichat-chat-select-visible-artifact ()
  "Select a visible settled artifact using Avy and open its Embark actions.
Cancellation does not move point or modify the prompt."
  (interactive)
  (unless (and (require 'avy nil t) (require 'embark nil t))
    (user-error "Avy and Embark are required for artifact selection"))
  (let* ((window (selected-window))
         (items (cl-remove-if-not
                 (lambda (item) (and (>= (nth 1 item) (window-start window))
                                     (< (nth 1 item) (window-end window t))))
                 (pichat-chat-artifacts-all)))
         (positions (delete-dups (mapcar #'cadr items)))
         (original (point))
         (choice (and positions
                      (let ((avy-action (lambda (_position) nil)))
                        (avy-process positions)))))
    (when (and (integerp choice) (assoc choice (mapcar (lambda (item) (cons (cadr item) item)) items)))
      (unwind-protect
          (progn (goto-char choice) (embark-act))
        ;; Embark actions may display another buffer; never edit the chat point
        ;; just to target an artifact permanently.
        (when (eq (current-buffer) (window-buffer window)) (goto-char original))))))

(provide 'pichat-chat-artifacts)
;;; pichat-chat-artifacts.el ends here
