;;; pichat-test-sessions-navigation.el --- History movement/refresh tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused Phase 5 tests for visible-row selection and asynchronous ownership.

;;; Code:

(require 'pichat-test-support)
(require 'pichat-test-sessions-tree)

(defun pichat-test-sessions-navigation--linear-response ()
  "Return a three-entry linear tree response."
  (let* ((third (pichat-test-sessions-tree--message
                 "third" "assistant" "third"))
         (second (pichat-test-sessions-tree--set-children
                  (pichat-test-sessions-tree--message
                   "second" "user" "second")
                  (list third)))
         (first (pichat-test-sessions-tree--set-children
                 (pichat-test-sessions-tree--message
                  "first" "user" "first")
                 (list second))))
    (pichat-test-sessions-tree--response (list first) "third")))

(defun pichat-test-sessions-navigation--branch-response ()
  "Return a tree with two visible branch segments."
  (let* ((a-leaf (pichat-test-sessions-tree--message
                  "a-leaf" "assistant" "A result"))
         (a (pichat-test-sessions-tree--set-children
             (pichat-test-sessions-tree--message "a" "user" "A")
             (list a-leaf)))
         (b (pichat-test-sessions-tree--message "b" "user" "B"))
         (root (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "root" "user" "root")
                (list a b))))
    (pichat-test-sessions-tree--response (list root) "a-leaf")))

(defmacro pichat-test-sessions-navigation--with-history (response &rest body)
  "Install RESPONSE in a temporary history buffer and evaluate BODY."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (pichat-sessions--refresh-from-response
      ,response (pichat-session-make) (current-buffer))
     ,@body))

(ert-deftest pichat-sessions-movement-follows-visible-rows-and-boundaries ()
  (pichat-test-sessions-navigation--with-history
      (pichat-test-sessions-navigation--linear-response)
    (goto-char (point-min))
    (pichat-sessions-next-entry)
    (should (equal "first" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-next-entry)
    (should (equal "second" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-next-entry)
    (pichat-sessions-next-entry)
    (should (equal "third" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-previous-entry)
    (should (equal "second" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-first-entry)
    (pichat-sessions-previous-entry)
    (should (equal "first" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-last-entry)
    (should (equal "third" (pichat-sessions--entry-id-at-point)))))

(ert-deftest pichat-sessions-branch-movement-visits-foldable-segments ()
  (pichat-test-sessions-navigation--with-history
      (pichat-test-sessions-navigation--branch-response)
    (pichat-sessions--goto-id "root")
    (pichat-sessions-next-branch-segment)
    (should (equal "a" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-next-branch-segment)
    (should (equal "a" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-previous-branch-segment)
    (should (equal "root" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-previous-branch-segment)
    (should (equal "root" (pichat-sessions--entry-id-at-point)))))

(ert-deftest pichat-sessions-movement-handles-empty-projections ()
  (pichat-test-sessions-navigation--with-history
      (pichat-test-sessions-navigation--linear-response)
    (setq pichat-sessions--query "does-not-match-any-row")
    (pichat-sessions--rerender)
    (should-not pichat-sessions--visible-rows)
    (dolist (command '(pichat-sessions-next-entry
                       pichat-sessions-previous-entry
                       pichat-sessions-first-entry
                       pichat-sessions-last-entry
                       pichat-sessions-next-branch-segment
                       pichat-sessions-previous-branch-segment))
      (should-not (condition-case nil
                      (progn (funcall command) nil)
                    (error t))))))

(ert-deftest pichat-sessions-movement-map-retires-parent-child-workarounds ()
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "n"))
              #'pichat-sessions-next-entry))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "<down>"))
              #'pichat-sessions-next-entry))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "p"))
              #'pichat-sessions-previous-entry))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "<up>"))
              #'pichat-sessions-previous-entry))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "M-n"))
              #'pichat-sessions-next-branch-segment))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "M-p"))
              #'pichat-sessions-previous-branch-segment))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd "<"))
              #'pichat-sessions-first-entry))
  (should (eq (lookup-key pichat-sessions-mode-map (kbd ">"))
              #'pichat-sessions-last-entry))
  (should-not (lookup-key pichat-sessions-mode-map (kbd "c"))))

(ert-deftest pichat-sessions-retained-parent-child-commands-use-visible-model ()
  (pichat-test-sessions-navigation--with-history
      (pichat-test-sessions-navigation--branch-response)
    (pichat-sessions--goto-id "a")
    (pichat-sessions-parent-at-point)
    (should (equal "root" (pichat-sessions--entry-id-at-point)))
    (pichat-sessions-first-child-at-point)
    (should (equal "a" (pichat-sessions--entry-id-at-point)))))

(ert-deftest pichat-sessions-selection-falls-back-through-required-order ()
  (let* ((child (pichat-test-sessions-tree--message
                 "child" "assistant" "hidden child"))
         (root (pichat-test-sessions-tree--set-children
                (pichat-test-sessions-tree--message "root" "user" "root")
                (list child)))
         (other (pichat-test-sessions-tree--message "other" "user" "other"))
         (response (pichat-test-sessions-tree--response
                    (list other root) "child")))
    (pichat-test-sessions-navigation--with-history response
      (pichat-sessions--goto-id "child")
      (setq pichat-sessions--query "root")
      (pichat-sessions--rerender)
      (should (equal "root" (pichat-sessions--entry-id-at-point)))
      (setq pichat-sessions--selected-id "missing")
      (pichat-sessions--rerender "missing")
      (should (equal "root" (pichat-sessions--entry-id-at-point)))
      (setq pichat-sessions--query "other"
            pichat-sessions--selected-id "missing")
      (pichat-sessions--rerender "missing")
      (should (equal "other" (pichat-sessions--entry-id-at-point)))
      (setq pichat-sessions--query "absent")
      (pichat-sessions--rerender)
      (should-not (pichat-sessions--entry-id-at-point))
      (should-not pichat-sessions--selected-id))))

(defun pichat-test-sessions-navigation--kill-history-buffer ()
  "Kill the shared history buffer when present."
  (when-let ((buffer (get-buffer "*PiChat Session History*")))
    (kill-buffer buffer)))

(ert-deftest pichat-sessions-refresh-newest-callback-wins ()
  (pichat-test-sessions-navigation--kill-history-buffer)
  (let ((session (pichat-session-make :id "session" :session-file "/one"))
        requests cancelled)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                   (lambda (_session success error)
                     (let ((id (format "request-%d" (1+ (length requests)))))
                       (push (list id success error) requests)
                       id)))
                  ((symbol-function 'pichat-rpc-cancel-request)
                   (lambda (_session id) (push id cancelled) t))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (pichat-sessions-list session)
          (pichat-sessions-list session)
          (let ((newest (car requests))
                (oldest (cadr requests)))
            (funcall (nth 1 newest)
                     (pichat-test-sessions-tree--response
                      (list (pichat-test-sessions-tree--message
                             "new" "user" "new")) "new")
                     session)
            (funcall (nth 1 oldest)
                     (pichat-test-sessions-tree--response
                      (list (pichat-test-sessions-tree--message
                             "old" "user" "old")) "old")
                     session))
          (with-current-buffer "*PiChat Session History*"
            (should (equal '("new") pichat-sessions--visible-rows)))
          (should (member "request-1" cancelled)))
      (pichat-test-sessions-navigation--kill-history-buffer))))

(ert-deftest pichat-sessions-refresh-callback-after-buffer-death-is-ignored ()
  (pichat-test-sessions-navigation--kill-history-buffer)
  (let ((session (pichat-session-make :id "session")) callback)
    (cl-letf (((symbol-function 'pichat-rpc-get-tree)
               (lambda (_session success _error)
                 (setq callback success)
                 "request")))
      (pichat-sessions-list session)
      (pichat-test-sessions-navigation--kill-history-buffer)
      (should-not (condition-case nil
                      (progn
                        (funcall callback '(:data (:tree nil :leafId nil))
                                 session)
                        nil)
                    (error t)))
      (should-not (gethash 'session-rebinding
                           (pichat-session-event-handlers session))))))

(ert-deftest pichat-sessions-changing-owner-removes-old-handler-and-callback ()
  (pichat-test-sessions-navigation--kill-history-buffer)
  (let ((old-session (pichat-session-make :id "old"))
        (new-session (pichat-session-make :id "new"))
        requests)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                   (lambda (session success error)
                     (push (list session success error) requests)
                     (format "request-%d" (length requests))))
                  ((symbol-function 'pichat-rpc-cancel-request)
                   (lambda (&rest _args) t)))
          (pichat-sessions-list old-session)
          (pichat-sessions-list new-session)
          (should-not (gethash 'session-rebinding
                               (pichat-session-event-handlers old-session)))
          (should (gethash 'session-rebinding
                           (pichat-session-event-handlers new-session)))
          (let ((old-request (cl-find old-session requests :key #'car)))
            (funcall (nth 1 old-request)
                     (pichat-test-sessions-navigation--linear-response)
                     old-session))
          (with-current-buffer "*PiChat Session History*"
            (should (eq new-session pichat-sessions-session))
            (should-not pichat-sessions--visible-rows)))
      (pichat-test-sessions-navigation--kill-history-buffer))))

(ert-deftest pichat-sessions-rebinding-invalidates-refresh-and-marks-stale ()
  (pichat-test-sessions-navigation--kill-history-buffer)
  (let ((session (pichat-session-make :id "session" :session-file "/one"))
        requests)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                   (lambda (_session success error)
                     (push (list success error) requests)
                     (format "request-%d" (length requests))))
                  ((symbol-function 'pichat-rpc-cancel-request)
                   (lambda (&rest _args) t))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (pichat-sessions-list session)
          (funcall (caar requests)
                   (pichat-test-sessions-navigation--linear-response) session)
          (pichat-sessions-list session)
          (let ((before (with-current-buffer "*PiChat Session History*"
                          (buffer-string)))
                (pending (car requests)))
            (pichat-emit session 'session-rebinding :command "fork")
            (with-current-buffer "*PiChat Session History*"
              (should pichat-sessions--stale-p)
              (should (string-match-p "stale" (buffer-string))))
            (funcall (car pending)
                     (pichat-test-sessions-tree--response
                      (list (pichat-test-sessions-tree--message
                             "wrong" "user" "wrong")) "wrong")
                     session)
            (with-current-buffer "*PiChat Session History*"
              (should-not (member "wrong" pichat-sessions--visible-rows))
              (should (string-match-p
                       (regexp-quote (substring before (string-match "\n" before)))
                       (buffer-string))))
            (setf (pichat-session-id session) "new-session"
                  (pichat-session-session-file session) "/two")
            (pichat-sessions-list session)
            (funcall (caar requests)
                     (pichat-test-sessions-navigation--linear-response) session)
            (with-current-buffer "*PiChat Session History*"
              (should-not pichat-sessions--stale-p)
              (should-not (string-match-p "stale" (buffer-string))))))
      (pichat-test-sessions-navigation--kill-history-buffer))))

(ert-deftest pichat-sessions-refresh-failure-preserves-view-state ()
  (pichat-test-sessions-navigation--kill-history-buffer)
  (let ((session (pichat-session-make :id "session")) requests messages)
    (unwind-protect
        (cl-letf (((symbol-function 'pichat-rpc-get-tree)
                   (lambda (_session success error)
                     (push (list success error) requests)
                     (format "request-%d" (length requests))))
                  ((symbol-function 'pichat-rpc-cancel-request)
                   (lambda (&rest _args) t))
                  ((symbol-function 'pop-to-buffer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (&rest args) (push args messages))))
          (pichat-sessions-list session)
          (funcall (caar requests)
                   (pichat-test-sessions-navigation--linear-response) session)
          (with-current-buffer "*PiChat Session History*"
            (pichat-sessions--goto-id "second")
            (setq pichat-sessions--filter 'all
                  pichat-sessions--query "second")
            (puthash "third" t pichat-sessions--folded)
            (pichat-sessions--rerender))
          (pichat-sessions-list session)
          (let ((before (with-current-buffer "*PiChat Session History*"
                          (buffer-string)))
                (nodes (with-current-buffer "*PiChat Session History*"
                         pichat-sessions--nodes)))
            (funcall (nth 1 (car requests))
                     '(:success nil :error "tree unavailable") session)
            (with-current-buffer "*PiChat Session History*"
              (should (equal before (buffer-string)))
              (should (eq nodes pichat-sessions--nodes))
              (should (equal "second" pichat-sessions--selected-id))
              (should (eq 'all pichat-sessions--filter))
              (should (equal "second" pichat-sessions--query))
              (should (gethash "third" pichat-sessions--folded))))
          (should (cl-some (lambda (args)
                             (string-match-p "refresh failed" (car args)))
                           messages)))
      (pichat-test-sessions-navigation--kill-history-buffer))))

(provide 'pichat-test-sessions-navigation)
;;; pichat-test-sessions-navigation.el ends here
