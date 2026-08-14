;;; pichat-test-view-modes.el --- PiChat view mode tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the semantic parent shared by read-only PiChat buffers.

;;; Code:

(require 'pichat-test-support)

(ert-deftest pichat-view-mode-is-common-read-only-parent ()
  (with-temp-buffer
    (pichat-view-mode)
    (should (derived-mode-p 'special-mode))
    (should buffer-read-only))
  (with-temp-buffer
    (pichat-sessions-mode)
    (should (derived-mode-p 'pichat-view-mode)))
  (with-temp-buffer
    (pichat-sessions-preview-mode)
    (should (derived-mode-p 'pichat-view-mode)))
  (should (eq (keymap-parent pichat-sessions-mode-map)
              pichat-view-mode-map))
  (should (eq (keymap-parent pichat-sessions-preview-mode-map)
              pichat-view-mode-map)))

(ert-deftest pichat-path-report-uses-pichat-view-mode ()
  (let ((pichat-path-mappings nil)
        (name "*PiChat Path Mappings*"))
    (unwind-protect
        (progn
          (when-let ((buffer (get-buffer name))) (kill-buffer buffer))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (pichat-path-validate-mappings))
          (with-current-buffer name
            (should (derived-mode-p 'pichat-view-mode))
            (should buffer-read-only)))
      (when-let ((buffer (get-buffer name))) (kill-buffer buffer)))))

(provide 'pichat-test-view-modes)
;;; pichat-test-view-modes.el ends here
