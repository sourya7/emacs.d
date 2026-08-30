;;; pichat-test-markdown-fontification.el --- Exact-source Markdown face tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests for the presentation-independent Markdown face component and
;; its settled-response projection boundary.

;;; Code:

(require 'pichat-test-support)

(defmacro pichat-test-markdown-fontification--with-stub (&rest body)
  "Evaluate BODY with deterministic Markdown fontification available."
  (declare (indent 0) (debug t))
  `(let ((original-require (symbol-function 'require)))
     (cl-letf (((symbol-function 'require)
                (lambda (feature &optional filename noerror)
                  (if (eq feature 'markdown-mode)
                      t
                    (funcall original-require feature filename noerror))))
               ((symbol-function 'markdown-mode) #'ignore)
               ((symbol-function 'font-lock-ensure)
                (lambda (&optional _beg _end)
                  (save-excursion
                    (goto-char (point-min))
                    (when (search-forward "**bold**" nil t)
                      (put-text-property (- (point) 6) (- (point) 2)
                                         'face 'font-lock-keyword-face))))))
       ,@body)))

(ert-deftest pichat-markdown-fontification-preserves-exact-markup-and-properties ()
  (pichat-test-markdown-fontification--with-stub
    (with-temp-buffer
      (insert (propertize "assistant **bold** [link](https://example.test)"
                          'pichat-prose t 'pichat-node-key "assistant"))
      (insert (propertize "\nuser **bold**" 'pichat-node-key "user"))
      (let ((exact (buffer-substring-no-properties (point-min) (point-max))))
        (should (pichat-markdown-fontification-apply-region
                 (point-min) (point-max)))
        (should (equal exact
                       (buffer-substring-no-properties
                        (point-min) (point-max))))
        (goto-char (point-min))
        (search-forward "bold")
        (should (eq 'font-lock-keyword-face
                    (get-text-property (1- (point)) 'font-lock-face)))
        (should (equal "assistant"
                       (get-text-property (1- (point)) 'pichat-node-key)))
        (search-forward "bold")
        (should-not (get-text-property (1- (point)) 'font-lock-face))
        (should-not (overlays-in (point-min) (point-max)))))))

(ert-deftest pichat-markdown-fontification-fails-open-without-dependency-or-on-error ()
  (dolist (failure '(unavailable error))
    (with-temp-buffer
      (insert (propertize "exact **bold**" 'pichat-prose t))
      (let ((exact (buffer-substring-no-properties (point-min) (point-max)))
            (original-require (symbol-function 'require)))
        (cl-letf (((symbol-function 'require)
                   (lambda (feature &optional filename noerror)
                     (if (eq feature 'markdown-mode)
                         (unless (eq failure 'unavailable) t)
                       (funcall original-require feature filename noerror))))
                  ((symbol-function 'markdown-mode) #'ignore)
                  ((symbol-function 'font-lock-ensure)
                   (lambda (&rest _)
                     (when (eq failure 'error) (error "font lock failed")))))
          (should-not (pichat-markdown-fontification-apply-region
                       (point-min) (point-max))))
        (should (equal exact
                       (buffer-substring-no-properties
                        (point-min) (point-max))))
        (should-not (text-property-not-all
                     (point-min) (point-max) 'font-lock-face nil))))))

(ert-deftest pichat-chat-fontifies-only-after-live-assistant-settles ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (pichat-chat-render-markdown t)
          buffer calls)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (cl-letf (((symbol-function
                        'pichat-markdown-fontification-apply-region)
                       (lambda (beg end)
                         (push (cons beg end) calls)
                         (put-text-property beg end 'font-lock-face
                                            'font-lock-keyword-face)
                         t)))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_update\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"**partial**\"}]}}\n")
              (with-current-buffer buffer (pichat-chat--flush-live-projection))
              (should-not calls)
              (with-current-buffer buffer
                (should-not (text-property-any
                             (marker-position pichat-chat--live-start)
                             (marker-position pichat-chat--live-end)
                             'font-lock-face 'font-lock-keyword-face)))
              (pichat-rpc--process-filter
               proc
               "{\"type\":\"message_end\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"**final**\"}]}}\n")
              (should (= 1 (length calls)))
              (with-current-buffer buffer
                (should (text-property-any
                         (marker-position pichat-chat--live-start)
                         (marker-position pichat-chat--live-end)
                         'font-lock-face 'font-lock-keyword-face)))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-live-fingerprint-is-independent-of-fontification-mode ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          buffer enabled disabled)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (pichat-pi-live-draft-apply
               pichat-chat--live-draft
               '(:type "message_end"
                 :message (:role "assistant"
                           :content ((:type "text" :text "**settled**")))))
              (let ((pichat-chat-markdown-mode t))
                (setq enabled
                      (plist-get (pichat-chat--build-live-candidate)
                                 :fingerprint)))
              (let ((pichat-chat-markdown-mode nil))
                (setq disabled
                      (plist-get (pichat-chat--build-live-candidate)
                                 :fingerprint)))
              (should (equal enabled disabled))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest pichat-chat-preserves-raw-markdown-links-and-tables ()
  (pichat-test-with-unit-session (session proc)
    (let ((pichat-chat-stop-session-on-kill nil)
          (source (concat "[label](https://example.test/path)\n\n"
                          "| Name | Value |\n|---|---|\n| raw | **bold** |"))
          buffer)
      (unwind-protect
          (progn
            (setq buffer (pichat-chat-open session))
            (with-current-buffer buffer
              (let* ((transcript
                      (pichat-transcript-create
                       :nodes
                       (list
                        (pichat-transcript-node-create
                         :kind 'message :key "raw-markdown" :role 'assistant
                         :content
                         (list
                          (pichat-transcript-content-create
                           :kind 'prose :index 0 :text source))))
                       :diagnostics nil :metadata nil))
                     (context
                      (pichat-chat--canonical-render-context transcript))
                     (fragment (pichat-render-canonical transcript context)))
                (pichat-chat--project-canonical
                 nil transcript fragment context))
              (goto-char (marker-position pichat-chat--canonical-start))
              (should (search-forward source
                                      (marker-position
                                       pichat-chat--canonical-end)
                                      t))
              (let ((end (point))
                    (beg (- (point) (length source))))
                (should (equal source
                               (buffer-substring-no-properties beg end)))
                (should-not (overlays-in beg end)))
              (dolist (key '("C-c C-l" "C-c C-a" "C-c C-<return>"))
                (should-not (lookup-key pichat-chat-mode-map (kbd key)))))
        (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(provide 'pichat-test-markdown-fontification)
;;; pichat-test-markdown-fontification.el ends here
