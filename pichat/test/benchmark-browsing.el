;;; benchmark-browsing.el --- Isolated transcript and file browsing profiles -*- lexical-binding: t; -*-

;;; Commentary:

;; From the checkout (no Pi, credentials, network or private session files):
;;   emacs -Q --batch -L pichat -l pichat/test/benchmark-browsing.el
;; Optional sizes/repetitions, set before loading:
;;   --eval '(setq pichat-benchmark-browsing-sizes (quote (100 1000)))'
;;
;; Synthetic settled assistant runs each contain code, link, table and LaTeX.
;; Rendering, run enumeration, parsing and point/visible lookup are timed
;; separately.  The visible viewport is modeled, not a redisplay/Avy benchmark.
;; Saved JSONL fixtures have 50 message pairs each.  Scan/sort, cold/warm summary
;; choices, completion matching and annotation are separate.  "Cold" clears only
;; PiChat's summary cache, NOT the OS page cache.  No SSH timing is simulated.
;; Wall-clock numbers are evidence, never ERT pass/fail thresholds.

;;; Code:

(require 'benchmark)
(require 'pichat-chat-artifacts)

(defvar pichat-benchmark-browsing-sizes '(100 1000))
(defvar pichat-benchmark-browsing-repetitions 3)

(defconst pichat-benchmark-browsing--prose
  "Example α.\n```sh\nprintf 'hello'\n```\n[link](https://example.org)\n| h | v |\n| --- | --- |\n| 1 | 2 |\n$x+y$\n")

(defun pichat-benchmark-browsing--measure (size label function)
  "Print SIZE and LABEL with average timing of FUNCTION; return its last value."
  (let (value)
    (garbage-collect)
    (let ((result (benchmark-call
                   (lambda () (setq value (funcall function)))
                   pichat-benchmark-browsing-repetitions)))
      (princ (format "%5d %-24s %10.6f s  %3d GC\n" size label
                     (/ (car result) pichat-benchmark-browsing-repetitions)
                     (nth 1 result))))
    value))

(defun pichat-benchmark-browsing--transcript (size)
  "Profile SIZE settled assistant prose runs without changing any live chat."
  (let* ((transcript
          (pichat-transcript-create
           :nodes (cl-loop for index below size collect
                           (pichat-transcript-node-create
                            :kind 'message :key (format "node-%d" index)
                            :role 'assistant
                            :content (list (pichat-transcript-content-create
                                            :kind 'prose :index 0
                                            :text pichat-benchmark-browsing--prose))))))
         (fragment (pichat-benchmark-browsing--measure
                    size "render-canonical"
                    (lambda () (pichat-render-canonical
                                transcript (pichat-render-default-context))))))
    (with-temp-buffer
      (pichat-chat-mode)
      (let ((inhibit-read-only t) (pichat-chat--inhibit-edit-guard t))
        (insert (pichat-render-fragment-propertized-string fragment))
        (set-marker pichat-chat--canonical-start (point-min))
        (set-marker pichat-chat--canonical-end (point-max)))
      (let* ((runs (pichat-benchmark-browsing--measure
                    size "enumerate-all-runs" #'pichat-chat-artifacts--runs))
             (run (nth (/ size 2) runs))
             (start (car run))
             (end (cadr run))
             (source (buffer-substring-no-properties start end)))
        (unless (= size (length runs)) (error "Incorrect rendered run count"))
        (pichat-benchmark-browsing--measure
         size "parse-one-run" (lambda () (pichat-artifacts-parse source)))
        (pichat-benchmark-browsing--measure size "all-artifacts" #'pichat-chat-artifacts-all)
        (goto-char start)
        (search-forward "printf")
        (let ((item (pichat-benchmark-browsing--measure
                     size "artifact-at-point" #'pichat-chat-artifacts-at-point)))
          (unless (equal "printf 'hello'\n" (pichat-artifact-payload (car item)))
            (error "Point lookup lost the exact code body")))
        (let ((real-require (symbol-function 'require)) positions)
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &rest args)
                       (if (memq feature '(avy embark)) t
                         (apply real-require feature args))))
                    ((symbol-function 'window-start) (lambda (&rest _) start))
                    ((symbol-function 'window-end) (lambda (&rest _) end))
                    ((symbol-function 'avy-process)
                     (lambda (candidates &rest _) (setq positions candidates) nil)))
            (pichat-benchmark-browsing--measure
             size "visible-artifacts" #'pichat-chat-select-visible-artifact))
          (unless (= 4 (length positions)) (error "Visible lookup lost artifacts")))))))

(defun pichat-benchmark-browsing--files (size)
  "Profile SIZE temporary saved files; always remove the fixture directory."
  (let* ((root (make-temp-file "pichat-browsing-benchmark-" t))
         (pichat-pi-session-dir root)
         (pichat-sessions--summary-cache (make-hash-table :test #'equal))
         (body (concat
                "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"first prompt\"}]}}\n"
                "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\""
                (make-string 512 ?x) "\"}]}}\n"))
         files choices)
    (unwind-protect
        (progn
          (dotimes (index size)
            (let ((directory (expand-file-name (format "project-%d" (% index 10)) root)))
              (make-directory directory t)
              (with-temp-file (expand-file-name (format "session_%08d.jsonl" index) directory)
                (insert (format "{\"type\":\"session\",\"id\":\"%08d\",\"cwd\":\"/fixture/project\"}\n" index))
                (dotimes (_ 50) (insert body))
                (insert (format "{\"type\":\"session_info\",\"name\":\"Session %d\"}\n" index)))))
          (setq files (pichat-benchmark-browsing--measure
                       size "file-scan-and-sort" #'pichat-sessions--files))
          (unless (= size (length files)) (error "Incorrect file count"))
          (setq choices
                (pichat-benchmark-browsing--measure
                 size "cold-summary-choices"
                 (lambda ()
                   (clrhash pichat-sessions--summary-cache)
                   (pichat-sessions--file-choices files root))))
          (pichat-benchmark-browsing--measure
           size "warm-summary-choices"
           (lambda () (pichat-sessions--file-choices files root)))
          (let* ((table (pichat-sessions--completion-table choices))
                 (metadata (completion-metadata "" table nil))
                 (affixation (completion-metadata-get metadata 'affixation-function)))
            (pichat-benchmark-browsing--measure
             size "completion-match"
             (lambda () (all-completions "Session" table nil)))
            (pichat-benchmark-browsing--measure
             size "annotate-20-candidates"
             (lambda () (funcall affixation (mapcar #'car (seq-take choices 20)))))))
      (delete-directory root t))))

(princ (format "Emacs %s; synthetic local browsing; repetitions=%d; gc-cons-threshold=%d\n"
               emacs-version pichat-benchmark-browsing-repetitions gc-cons-threshold))
(dolist (size pichat-benchmark-browsing-sizes)
  (pichat-benchmark-browsing--transcript size)
  (pichat-benchmark-browsing--files size))

;;; benchmark-browsing.el ends here
