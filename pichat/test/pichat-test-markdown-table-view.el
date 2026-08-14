;;; pichat-test-markdown-table-view.el --- PiChat table viewer tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused behavior coverage for immutable complete Markdown table viewers.

;;; Code:

(require 'pichat-test-support)

(defun pichat-test-markdown-table-view--model (source)
  "Return the one complete table model parsed from SOURCE."
  (let ((tables (pichat-markdown-table-parse source)))
    (should (= 1 (length tables)))
    (car tables)))

(defun pichat-test-markdown-table-view--open (source &optional model)
  "Open SOURCE with optional MODEL without changing the selected window."
  (cl-letf (((symbol-function 'pop-to-buffer)
             (lambda (buffer &rest _arguments) buffer)))
    (pichat-markdown-table-open-viewer
     source (or model (pichat-test-markdown-table-view--model source)))))

(defun pichat-test-markdown-table-view--chat (source)
  "Return a projected temporary chat-like buffer containing SOURCE."
  (let ((buffer (generate-new-buffer " *pichat-table-origin-test*")))
    (with-current-buffer buffer
      (setq-local pichat-chat--source-generation 7)
      (insert (propertize source
                          'pichat-prose t
                          'pichat-node-key "table-node"))
      (pichat-markdown-presentation-refresh-buffer)
      (goto-char (point-min)))
    buffer))

(ert-deftest pichat-markdown-org-load-is-viewer-only ()
  (let* ((source "| A | B |\n|---|---|\n| x | y |")
         (org-was-loaded (featurep 'org-table))
         (chat (pichat-test-markdown-table-view--chat source))
         viewer)
    (unwind-protect
        (progn
          (should (eq org-was-loaded (featurep 'org-table)))
          (with-current-buffer chat
            (setq viewer (pichat-chat-open-table-at-point)))
          (should (featurep 'org-table)))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-markdown-table-org-serialization-is-complete-and-safe ()
  (let* ((long "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
         (source
          (format (concat "| Name | Detail |\n|---|---|\n"
                          "| escaped \\| pipe | `code|span` |\n"
                          "| final | %s |")
                  long))
         (table (pichat-test-markdown-table-view--model source))
         (org-text (pichat-markdown-table-org-string table)))
    (should (= 4 (length (string-lines org-text))))
    (should (string-match-p (regexp-quote "|---+---|") org-text))
    (should (string-match-p (regexp-quote "escaped \\vert{} pipe") org-text))
    (should (string-match-p (regexp-quote "`code\\vert{}span`") org-text))
    (should (string-match-p (regexp-quote long) org-text))))

(ert-deftest pichat-markdown-table-view-activation-and-away-error ()
  (let* ((source (concat "| A | B |\n|---|---|\n| x | y |\n\n"
                         "outside"))
         (chat (pichat-test-markdown-table-view--chat source))
         viewer)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (let ((metadata
                   (pichat-markdown-presentation--overlay-at-point 'table)))
              (should metadata)
              (should (eq #'pichat-chat-open-table-at-point
                          (lookup-key (overlay-get metadata 'keymap)
                                      (kbd "RET"))))
              (should
               (seq-some
                (lambda (overlay)
                  (and (overlay-get overlay 'before-string)
                       (eq #'pichat-chat-open-table-at-point
                           (lookup-key (overlay-get overlay 'keymap)
                                       (kbd "RET")))))
                (overlays-in (point-min) (point-max)))))
            (should (eq #'pichat-chat-open-table-at-point
                        (lookup-key pichat-chat-mode-map
                                    (kbd "C-c C-<return>"))))
            (setq viewer (pichat-chat-open-table-at-point)))
          (with-current-buffer chat
            (goto-char (point-max))
            (should-error (pichat-chat-open-table-at-point)
                          :type 'user-error)))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-markdown-table-view-raw-copy-and-mode-state ()
  (let* ((source "| A | B |\n|---|---|\n| left \\| right | complete |")
         (viewer (pichat-test-markdown-table-view--open source))
         copied normalized)
    (unwind-protect
        (with-current-buffer viewer
          (should (derived-mode-p 'pichat-view-mode))
          (should (derived-mode-p 'pichat-markdown-table-view-mode))
          (should buffer-read-only)
          (should truncate-lines)
          (should (bound-and-true-p orgtbl-mode))
          (should (eq #'pichat-markdown-table-view-quit
                      (lookup-key pichat-markdown-table-view-mode-map
                                  (kbd "q"))))
          (setq normalized (buffer-substring-no-properties
                            (point-min) (point-max)))
          (should (string-match-p (regexp-quote "left \\vert{} right")
                                  normalized))
          (pichat-markdown-table-view-toggle-source)
          (should (equal source
                         (buffer-substring-no-properties
                          (point-min) (point-max))))
          (should (equal source pichat-markdown-table-view-source))
          (cl-letf (((symbol-function 'kill-new)
                     (lambda (text &rest _arguments) (setq copied text))))
            (pichat-markdown-table-view-copy-source))
          (should (equal source copied))
          (pichat-markdown-table-view-toggle-source)
          (should (equal normalized
                         (buffer-substring-no-properties
                          (point-min) (point-max))))
          (should-not (buffer-modified-p)))
      (when (buffer-live-p viewer) (kill-buffer viewer)))))

(ert-deftest pichat-markdown-table-view-quit-restores-created-window ()
  (save-window-excursion
    (delete-other-windows)
    (let ((origin (generate-new-buffer " *pichat-table-quit-origin*"))
          (source "| A | B |\n|---|---|\n| x | y |")
          viewer)
      (unwind-protect
          (progn
            (switch-to-buffer origin)
            (cl-letf (((symbol-function 'pop-to-buffer)
                       (lambda (buffer &rest _arguments) buffer)))
              (setq viewer (pichat-test-markdown-table-view--open source)))
            (let ((window
                   (display-buffer
                    viewer
                    '((display-buffer-pop-up-window)
                      (inhibit-same-window . t)))))
              (should (window-live-p window))
              (select-window window))
            (should (= 2 (count-windows)))
            (should (eq viewer (window-buffer (selected-window))))
            (with-current-buffer viewer
              (pichat-markdown-table-view-quit))
            (should-not (buffer-live-p viewer))
            (should (= 1 (count-windows)))
            (should (eq origin (window-buffer (selected-window)))))
        (when (buffer-live-p viewer) (kill-buffer viewer))
        (when (buffer-live-p origin) (kill-buffer origin))))))

(ert-deftest pichat-markdown-table-view-navigation-is-window-local ()
  (let* ((long (make-string 180 ?x))
         (source (format "| A | B |\n|---|---|\n| first | %s |\n| second | end |"
                         long))
         viewer)
    (save-window-excursion
      (setq viewer (pichat-markdown-table-open-viewer
                    source (pichat-test-markdown-table-view--model source)))
      (unwind-protect
          (with-current-buffer viewer
            (goto-char (point-min))
            (pichat-markdown-table-view-next-row)
            (should (looking-at-p "| first"))
            (pichat-markdown-table-view-previous-row)
            (should (= (point) (point-min)))
            (pichat-markdown-table-view-scroll-right)
            (should (> (window-hscroll (selected-window)) 0))
            (let ((right (window-hscroll (selected-window))))
              (pichat-markdown-table-view-scroll-left)
              (should (< (window-hscroll (selected-window)) right)))
            (set-window-hscroll (selected-window) 9)
            (goto-char (point-max))
            (pichat-markdown-table-view-reset)
            (should (= (point) (point-min)))
            (should (= 0 (window-hscroll (selected-window)))))
        (when (buffer-live-p viewer) (kill-buffer viewer))))))

(ert-deftest pichat-markdown-table-view-skips-and-explicitly-attempts-large-alignment ()
  (require 'org-table)
  (let* ((source "| A | B |\n|---|---|\n| one | two |\n| three | four |")
         (pichat-markdown-table-view-align-max-source-chars 0)
         (pichat-markdown-table-view-align-max-rows 0)
         (calls 0)
         viewer)
    (cl-letf (((symbol-function 'org-table-align)
               (lambda () (cl-incf calls))))
      (setq viewer (pichat-test-markdown-table-view--open source))
      (unwind-protect
          (with-current-buffer viewer
            (should (= 0 calls))
            (should (string-match-p "Alignment skipped"
                                    pichat-markdown-table-view--alignment-note))
            (should (string-match-p "three"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            (pichat-markdown-table-view-align)
            (should (= 1 calls))
            (should-not pichat-markdown-table-view--alignment-note))
        (when (buffer-live-p viewer) (kill-buffer viewer))))))

(ert-deftest pichat-markdown-table-view-alignment-failure-stays-readable ()
  (require 'org-table)
  (let* ((source "| A | B |\n|---|---|\n| x | y |")
         viewer)
    (cl-letf (((symbol-function 'org-table-align)
               (lambda () (error "forced alignment failure"))))
      (setq viewer (pichat-test-markdown-table-view--open source))
      (unwind-protect
          (with-current-buffer viewer
            (should (string-match-p "forced alignment failure"
                                    pichat-markdown-table-view--alignment-note))
            (should (string-match-p "| x | y |"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            (should buffer-read-only))
        (when (buffer-live-p viewer) (kill-buffer viewer))))))

(ert-deftest pichat-markdown-table-view-opening-performs-no-external-actions ()
  (require 'org-table)
  (let* ((source (concat "| Formula | Link |\n|---|---|\n"
                         "| :=1+1 | https://example.test/value |"))
         (actions 0)
         viewer)
    (cl-letf (((symbol-function 'org-table-recalculate)
               (lambda (&rest _arguments) (cl-incf actions)))
              ((symbol-function 'org-table-eval-formula)
               (lambda (&rest _arguments) (cl-incf actions)))
              ((symbol-function 'org-babel-execute-src-block)
               (lambda (&rest _arguments) (cl-incf actions))))
      (setq viewer (pichat-test-markdown-table-view--open source))
      (unwind-protect
          (with-current-buffer viewer
            (should (= 0 actions))
            (should-not
             (text-property-not-all (point-min) (point-max) 'keymap nil)))
        (when (buffer-live-p viewer) (kill-buffer viewer))))))

(ert-deftest pichat-markdown-table-view-origin-survives-reprojection-then-stales ()
  (let* ((source "| A | B |\n|---|---|\n| x | y |")
         (chat (pichat-test-markdown-table-view--chat source))
         viewer returned-buffer)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (setq viewer (pichat-chat-open-table-at-point)))
          (with-current-buffer chat
            (pichat-markdown-presentation-refresh-buffer))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buffer &rest _arguments)
                       (setq returned-buffer buffer)
                       (set-buffer buffer)
                       buffer)))
            (with-current-buffer viewer
              (pichat-markdown-table-view-return-to-origin)))
          (should (eq chat returned-buffer))
          (with-current-buffer chat
            (should (pichat-markdown-presentation--overlay-at-point 'table))
            (cl-incf pichat-chat--source-generation))
          (with-current-buffer viewer
            (let ((snapshot (buffer-substring-no-properties
                             (point-min) (point-max))))
              (should-error (pichat-markdown-table-view-return-to-origin)
                            :type 'user-error)
              (should (equal snapshot
                             (buffer-substring-no-properties
                              (point-min) (point-max)))))))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(ert-deftest pichat-markdown-table-view-remains-readable-after-origin-death ()
  (let* ((source "| A | B |\n|---|---|\n| complete | snapshot |")
         (chat (pichat-test-markdown-table-view--chat source))
         viewer)
    (unwind-protect
        (progn
          (with-current-buffer chat
            (setq viewer (pichat-chat-open-table-at-point)))
          (kill-buffer chat)
          (with-current-buffer viewer
            (should (string-match-p "complete"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            (pichat-markdown-table-view-toggle-source)
            (should (equal source
                           (buffer-substring-no-properties
                            (point-min) (point-max))))
            (should-error (pichat-markdown-table-view-return-to-origin)
                          :type 'user-error)))
      (when (buffer-live-p viewer) (kill-buffer viewer))
      (when (buffer-live-p chat) (kill-buffer chat)))))

(provide 'pichat-test-markdown-table-view)
;;; pichat-test-markdown-table-view.el ends here
