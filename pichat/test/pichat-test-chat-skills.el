;;; pichat-test-chat-skills.el --- Skill invocation presentation tests -*- lexical-binding: t; -*-

(require 'pichat-test-chat-support)

(defconst pichat-test-skill-text
  "<skill name=\"plans\" location=\"/tmp/plans\">\nReferences are relative to /tmp/plans.\nInstructions here.\n</skill>\n\nrun this")

(defun pichat-test-skill-transcript (text &optional second)
  "Make a transcript with TEXT and optional SECOND user message."
  (pichat-transcript-create
   :nodes (cl-loop for body in (if second (list text second) (list text))
                   for id from 1
                   collect (pichat-transcript-node-create
                            :kind 'message :role 'user :key (format "entry-%s" id)
                            :content (list (pichat-transcript-content-create
                                            :kind 'prose :text body :index 0))))))

(ert-deftest pichat-skill-parser-requires-exact-anchored-shape ()
  (should (equal '("plans" "References are relative to /tmp/plans.\nInstructions here." "run this")
                 (pichat-render--skill-block pichat-test-skill-text)))
  (should (equal '("plans" "body" nil)
                 (pichat-render--skill-block
                  "<skill name=\"plans\" location=\"/tmp\">\nbody\n</skill>")))
  (dolist (text '("prefix <skill name=\"plans\" location=\"/tmp\">\nbody\n</skill>"
                  "<skill name=\"plans\" location=\"/tmp\">\nbody"
                  "<skill name=\"plans\" location=\"/tmp\">\nbody\n</skill>suffix"
                  "<skill name=\"plans\" location=\"/tmp\">\nbody\n</skill>\n"
                  "<skill name=\"plans\" location=\"/tmp\">\nbody\n</skill>\n\n"
                  "<skill name=\"bad<name\" location=\"/tmp\">\nbody\n</skill>"))
    (should-not (pichat-render--skill-block text))))

(ert-deftest pichat-skill-render-preserves-original-and-falls-back-for-mixed-content ()
  (let* ((transcript (pichat-test-skill-transcript pichat-test-skill-text))
         (node (car (pichat-transcript-nodes transcript)))
         (context (pichat-render-default-context))
         (collapsed (pichat-render-fragment-propertized-string
                     (pichat-render-canonical transcript context))))
    (should (string-match-p "\\[skill\\] plans" collapsed))
    (should (string-match-p "▌ run this" collapsed))
    (should-not (string-match-p "Instructions here" collapsed))
    (should (equal pichat-test-skill-text
                   (pichat-transcript-content-text
                    (car (pichat-transcript-node-content node)))))
    (should (string-match-p
             (regexp-quote pichat-test-skill-text)
             (pichat-chat-navigation-transcript-markdown transcript)))
    (should (eq (lookup-key pichat-render-skill-header-map (kbd "RET"))
                'pichat-chat-toggle-skill-at-point))
    (setf (pichat-render-context-skill-views context)
          (list (cons "entry-1" pichat-test-skill-text)))
    (should (string-match-p "Instructions here"
                            (pichat-render-fragment-text
                             (pichat-render-canonical transcript context))))
    (setf (pichat-transcript-content-text
           (car (pichat-transcript-node-content node)))
          "<skill name=\"plans\" location=\"/tmp\">\nnew body\n</skill>")
    (should-not (string-match-p "new body"
                                (pichat-render-fragment-text
                                 (pichat-render-canonical transcript context))))
    (setf (pichat-transcript-content-text
           (car (pichat-transcript-node-content node)))
          pichat-test-skill-text)
    (setf (pichat-transcript-node-content node)
          (append (pichat-transcript-node-content node)
                  (list (pichat-transcript-content-create :kind 'image :text "[image]"))))
    (let ((fallback (pichat-render-fragment-text
                     (pichat-render-canonical transcript context))))
      (should (string-match-p "Instructions here" fallback))
      (should (string-match-p "\\[image\\]" fallback))
      (should-not (string-match-p "\\[skill\\]" fallback)))))

(ert-deftest pichat-skill-chat-toggle-survives-repaint-but-not-source-rebind ()
  (pichat-test-with-unit-session (session proc)
    (pichat-test-with-chat-buffer (buffer session)
      (let* ((transcript (pichat-test-skill-transcript
                          pichat-test-skill-text pichat-test-skill-text))
             (context (pichat-chat--canonical-render-context transcript)))
        (pichat-chat--project-canonical nil transcript
                                        (pichat-render-canonical transcript context)
                                        context)
        (goto-char (point-min))
        (search-forward "[skill] plans")
        (beginning-of-line)
        (should (equal "entry-1" (get-text-property (point) 'pichat-skill-key)))
        (pichat-chat-copy-skill-at-point)
        (should (equal pichat-test-skill-text (current-kill 0 t)))
        (pichat-chat-toggle-skill-at-point)
        (should (string-match-p "Instructions here" (pichat-test-buffer-text buffer)))
        (should (= 1 (hash-table-count pichat-chat--skill-view-states)))
        (pichat-chat--reproject-display-options)
        (should (= 1 (hash-table-count pichat-chat--skill-view-states)))
        (should (= 1 (how-many "Instructions here" (point-min) (point-max))))
        (pichat-chat--reset-for-source "different" nil t)
        (should (= 0 (hash-table-count pichat-chat--skill-view-states)))
        (let ((context (pichat-chat--canonical-render-context transcript)))
          (pichat-chat--project-canonical
           nil transcript (pichat-render-canonical transcript context) context))
        (should-not (string-match-p "Instructions here"
                                    (pichat-test-buffer-text buffer)))))))

(provide 'pichat-test-chat-skills)
;;; pichat-test-chat-skills.el ends here
