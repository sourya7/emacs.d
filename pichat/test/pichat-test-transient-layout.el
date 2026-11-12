;;; pichat-test-transient-layout.el --- PiChat menu layout by frame width -*- lexical-binding: t; -*-

;;; Commentary:

;; PiChat Transient menus stack their groups in narrow frames; other
;; packages' menus keep their layout.  Batch Emacs reports a fixed
;; `frame-width', so the tests stub it.

;;; Code:

(require 'pichat-test-support)
(require 'pichat)

(transient-define-prefix pichat-test-foreign-menu ()
  "Stand-in for another package's menu, such as Magit's."
  [["Left" ("1" "one" ignore)] ["Right" ("2" "two" ignore)]])

(defun pichat-test-transient--text ()
  "Return the text of the open Transient menu."
  (with-current-buffer (get-buffer transient--buffer-name) (buffer-string)))

(defun pichat-test-transient--same-line-p (left right)
  "Return non-nil when the open menu shows LEFT and RIGHT on one line."
  (let ((case-fold-search nil))
    (string-match-p (concat (regexp-quote left) ".*" (regexp-quote right))
                    (pichat-test-transient--text))))

(defun pichat-test-transient--exit ()
  "Leave the open Transient menu as an ordinary suffix would.
The layout is decided when the Transient buffer is created, so a menu or
buffer left behind by an earlier test must not survive into the next."
  (when transient--prefix
    (transient--pre-exit)
    (transient--post-exit))
  (when-let* ((buffer (get-buffer transient--buffer-name)))
    (kill-buffer buffer)))

(defmacro pichat-test-with-frame-width (width &rest body)
  "Run BODY with `frame-width' reporting WIDTH and no menu open before or after."
  (declare (indent 1))
  `(progn
     (pichat-test-transient--exit)
     (cl-letf (((symbol-function 'frame-width) (lambda (&rest _) ,width)))
       (unwind-protect (progn ,@body)
         (pichat-test-transient--exit)))))

(defmacro pichat-test-with-tool-picker-state (&rest body)
  "Run BODY with a minimal Tools picker draft and no discovery.
Any menu left open is closed first: its exit hook clears the picker state."
  (declare (indent 0))
  `(progn
     (pichat-test-transient--exit)
     (let ((pichat-tool-picker--state
            (list :preset (list :name 'test :tools '("read" "bash"))
                  :baseline '("read" "bash")
                  :draft (list :builtins '("read") :mcp nil :extensions nil :emacs nil)
                  :discovery nil :servers nil :loaded t :page 0
                  :emacs-catalogue nil :emacs-group nil)))
       ,@body)))

(ert-deftest pichat-transient-narrow-frame-stacks-pichat-menu-groups ()
  (pichat-test-with-tool-picker-state
    (pichat-test-with-frame-width 42
      (transient-setup 'pichat-tool-picker)
      (should (string-match-p "Built-in tools" (pichat-test-transient--text)))
      (should (string-match-p "Selection" (pichat-test-transient--text)))
      (should-not (pichat-test-transient--same-line-p "Selection" "Action"))
      ;; A group entry opens the sub-picker in place; it stays stacked.
      (setf (plist-get pichat-tool-picker--state :emacs-group) "Jobs")
      (transient-setup 'pichat-tool-picker-emacs-group)
      (should (eq 'pichat-tool-picker-emacs-group (oref transient--prefix command)))
      (should (string-match-p "Select all in group" (pichat-test-transient--text)))
      (should-not (pichat-test-transient--same-line-p "Selection" "Action")))))

(ert-deftest pichat-transient-wide-frame-keeps-pichat-menu-columns ()
  (pichat-test-with-tool-picker-state
    ;; The threshold itself (the Fold 6's 80 columns) keeps the columns.
    (dolist (width '(120 80))
      (pichat-test-with-frame-width width
        (transient-setup 'pichat-tool-picker)
        (should (pichat-test-transient--same-line-p "Selection" "Action"))
        (setf (plist-get pichat-tool-picker--state :emacs-group) "Jobs")
        (transient-setup 'pichat-tool-picker-emacs-group)
        (should (pichat-test-transient--same-line-p "Selection" "Action"))))))

(ert-deftest pichat-transient-width-option-zero-keeps-columns ()
  (pichat-test-with-tool-picker-state
    (let ((pichat-transient-single-column-width 0))
      (pichat-test-with-frame-width 42
        (transient-setup 'pichat-tool-picker)
        (should (pichat-test-transient--same-line-p "Selection" "Action"))))))

(ert-deftest pichat-transient-other-menus-keep-columns-at-any-width ()
  (should-not transient-force-single-column)
  (dolist (width '(42 120))
    (pichat-test-with-frame-width width
      (transient-setup 'pichat-test-foreign-menu)
      (should (pichat-test-transient--same-line-p "Left" "Right"))))
  ;; Also right after a stacked PiChat menu in the same session.
  (pichat-test-with-tool-picker-state
    (pichat-test-with-frame-width 42
      (transient-setup 'pichat-tool-picker)
      (should-not (pichat-test-transient--same-line-p "Selection" "Action"))
      (pichat-test-transient--exit)
      (transient-setup 'pichat-test-foreign-menu)
      (should (pichat-test-transient--same-line-p "Left" "Right"))))
  (should-not transient-force-single-column))

(provide 'pichat-test-transient-layout)
;;; pichat-test-transient-layout.el ends here
