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
      (should (string-match-p "All in group" (pichat-test-transient--text)))
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

(defun pichat-test-transient--move (command start)
  "Put point at START in the open menu, run COMMAND once, return point.
START is `last' (the last entry) or `first' (the first entry)."
  (with-selected-window transient--window
    (goto-char (point-min))
    (if (eq start 'last)
        (progn (goto-char (point-max)) (backward-button 1))
      (forward-button 1))
    (funcall command 1)
    (point)))

(defun pichat-test-transient--entry-bounds ()
  "Return (FIRST LAST POINT-MIN POINT-MAX) positions in the open menu."
  (with-selected-window transient--window
    (save-excursion
      (list (progn (goto-char (point-min)) (forward-button 1) (point))
            (progn (goto-char (point-max)) (backward-button 1) (point))
            (point-min) (point-max)))))

(ert-deftest pichat-transient-entry-navigation-stops-at-menu-ends ()
  ;; A swipe in a phone terminal sends <down>/<up>; wrapping to the other
  ;; end looked like the view resetting to the top.  At any width.
  (pichat-test-with-tool-picker-state
    (dolist (width '(42 120))
      (pichat-test-with-frame-width width
        (transient-setup 'pichat-tool-picker)
        (pcase-let ((`(,first ,last ,min ,max) (pichat-test-transient--entry-bounds)))
          (should (< first last))
          (should (= max (pichat-test-transient--move
                          #'transient-forward-button 'last)))
          (should (= min (pichat-test-transient--move
                          #'transient-backward-button 'first)))
          ;; Ordinary moves inside the menu still go to the next entry.
          (should (< first (pichat-test-transient--move
                            #'transient-forward-button 'first)))
          (should (> last (pichat-test-transient--move
                           #'transient-backward-button 'last))))
        ;; In-place sub-pickers share the buffer and the behavior.
        (setf (plist-get pichat-tool-picker--state :emacs-group) "Jobs")
        (transient-setup 'pichat-tool-picker-emacs-group)
        (should (= (nth 3 (pichat-test-transient--entry-bounds))
                   (pichat-test-transient--move
                    #'transient-forward-button 'last)))))))

(defun pichat-test-transient--echo-count (command)
  "Move with COMMAND from the first entry; return the number of echoes.
Navigation echo is forced on, as with `force-verbose'."
  (let ((transient-enable-menu-navigation 'force-verbose)
        (count 0))
    (cl-letf (((symbol-function 'transient--button-move-echo)
               (lambda () (setq count (1+ count)))))
      (pichat-test-transient--move command 'first))
    count))

(ert-deftest pichat-transient-entry-navigation-echoes-only-outside-pichat ()
  (pichat-test-with-tool-picker-state
    (pichat-test-with-frame-width 42
      (transient-setup 'pichat-tool-picker)
      (should (= 0 (pichat-test-transient--echo-count #'transient-forward-button)))
      (should (= 0 (pichat-test-transient--echo-count #'transient-backward-button)))
      (pichat-test-transient--exit)
      (transient-setup 'pichat-test-foreign-menu)
      (should (= 1 (pichat-test-transient--echo-count #'transient-forward-button))))))

(ert-deftest pichat-transient-other-menus-keep-wrapping-navigation ()
  (pichat-test-with-tool-picker-state
    (pichat-test-with-frame-width 42
      (transient-setup 'pichat-tool-picker)
      (pichat-test-transient--exit)
      (transient-setup 'pichat-test-foreign-menu)
      (pcase-let ((`(,first ,last . ,_) (pichat-test-transient--entry-bounds)))
        (should (= first (pichat-test-transient--move
                          #'transient-forward-button 'last)))
        (should (= last (pichat-test-transient--move
                         #'transient-backward-button 'first)))))))

(provide 'pichat-test-transient-layout)
;;; pichat-test-transient-layout.el ends here
