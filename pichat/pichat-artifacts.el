;;; pichat-artifacts.el --- Bounded Markdown artifact detection -*- lexical-binding: t; -*-
;;; Commentary:
;; Pure, conservative parser.  Offsets are zero-based within an exact prose run.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(cl-defstruct (pichat-artifact (:constructor pichat-artifact-create))
  type source payload metadata start end identity)

(defun pichat-artifacts--lines (source)
  "Return (START END TEXT) lines from SOURCE, including final newlines in END."
  (let ((pos 0) result)
    (while (< pos (length source))
      (let* ((newline (string-match "\n" source pos))
             (end (if newline (1+ newline) (length source))))
        (push (list pos end (substring source pos (or newline end))) result)
        (setq pos end)))
    (nreverse result)))

(defun pichat-artifacts--make (type source start end payload &optional metadata)
  "Build TYPE descriptor from SOURCE at START to END with PAYLOAD and METADATA."
  (pichat-artifact-create :type type :source (substring source start end)
                          :payload payload :metadata metadata :start start :end end))

(defun pichat-artifacts--fences (source lines)
  "Find complete fenced blocks in SOURCE using LINES."
  (let (result opening)
    (dolist (line lines)
      (pcase-let ((`(,start ,end ,text) line))
        (cond
         ((null opening)
          (when (string-match "\\` \\{0,3\\}\\(`\\{3,\\}\\|~\\{3,\\}\\)\\([^`~]*\\)\\'" text)
            (let ((fence (match-string 1 text)))
              (setq opening (list start end (aref fence 0) (length fence)
                                  (string-trim (match-string 2 text)))))))
         ((and (string-match "\\` \\{0,3\\}\\([`~]+\\)[ \t]*\\'" text)
               (cl-every (lambda (char) (= char (nth 2 opening)))
                         (string-to-list (match-string 1 text)))
               (>= (length (match-string 1 text)) (nth 3 opening)))
          (push (pichat-artifacts--make
                 'code source (car opening) end
                 (substring source (nth 1 opening) start)
                 (car (split-string (nth 4 opening) "[ \t]" t))) result)
          (setq opening nil)))))
    (nreverse result)))

(defun pichat-artifacts--cells (line)
  "Return pipe-delimited cells of LINE, or nil for ambiguous inline code."
  (let ((index 0) (ticks 0) (begin 0) cells pipes)
    ;; Multiple-backtick spans need a separate delimiter stack.  Decline them.
    (unless (string-match-p "``" line)
      (while (< index (length line))
      (let ((ch (aref line index)))
        (cond
         ((and (= ch ?\\) (< (1+ index) (length line))) (setq index (1+ index)))
         ((= ch ?`) (setq ticks (if (= ticks 0) 1 0)))
         ((and (= ch ?|) (= ticks 0))
          (push (string-trim (substring line begin index)) cells)
          (setq begin (1+ index) pipes t))))
      (setq index (1+ index))))
    (when (and pipes (= ticks 0))
      (push (string-trim (substring line begin)) cells)
      (setq cells (nreverse cells))
      (when (string-empty-p (car cells)) (setq cells (cdr cells)))
      (when (string-empty-p (car (last cells))) (setq cells (butlast cells)))
      cells)))

(defun pichat-artifacts--tables (source lines fences)
  "Find conservative pipe tables in SOURCE LINES outside FENCES."
  (let ((rest lines) result)
    (while (cdr rest)
      (pcase-let* ((`(,start ,_ ,header) (car rest))
                   (`(,_ ,_ ,separator) (cadr rest))
                   (columns (pichat-artifacts--cells header))
                   (alignment (pichat-artifacts--cells separator)))
        (if (and columns (>= (length columns) 2)
                 (= (length columns) (length alignment))
                 (cl-every (lambda (cell)
                             (string-match-p "\\`:\?-\\{3,\\}:?\\'" cell)) alignment)
                 (not (cl-some (lambda (f) (<= (pichat-artifact-start f) start
                                                 (1- (pichat-artifact-end f)))) fences)))
            (let ((end (nth 1 (cadr rest))))
              (setq rest (cddr rest))
              (while (and rest
                          (let ((cells (pichat-artifacts--cells (nth 2 (car rest)))))
                            (and cells (= (length cells) (length columns)))))
                (setq end (nth 1 (car rest)) rest (cdr rest)))
              (push (pichat-artifacts--make 'table source start end
                                            (substring source start end)) result))
          (setq rest (cdr rest)))))
    (nreverse result)))

(defun pichat-artifacts--prefix-at (prefix source position)
  "Whether PREFIX appears in SOURCE at POSITION."
  (and (<= (+ position (length prefix)) (length source))
       (string= prefix (substring source position (+ position (length prefix))))))

(defun pichat-artifacts-parse (source)
  "Return immutable artifact descriptors for exact contiguous prose SOURCE.
Ambiguous and incomplete syntax is deliberately ignored."
  (let* ((lines (pichat-artifacts--lines source))
         (fences (pichat-artifacts--fences source lines))
         (result (append fences (pichat-artifacts--tables source lines fences)))
         (pos 0))
    (while (< pos (length source))
      (if (cl-some (lambda (a) (and (eq (pichat-artifact-type a) 'code)
                                    (<= (pichat-artifact-start a) pos)
                                    (< pos (pichat-artifact-end a)))) result)
          (setq pos (pichat-artifact-end
                     (cl-find-if (lambda (a) (and (eq (pichat-artifact-type a) 'code)
                                                  (<= (pichat-artifact-start a) pos)
                                                  (< pos (pichat-artifact-end a)))) result)))
        (let ((case-fold-search nil))
          (cond
           ((and (= (aref source pos) ?\[)
                 (string-match "\\`\\[\\([^]\n]+\\)\\](\\([^()\n]+\\))"
                               (substring source pos)))
            (let* ((whole (match-string 0 (substring source pos)))
                   (url (match-string 2 (substring source pos))))
              (push (pichat-artifacts--make 'link source pos (+ pos (length whole)) url url) result)
              (setq pos (+ pos (length whole)))))
           ((let* ((delimiter (cond ((pichat-artifacts--prefix-at "$$" source pos) "$$")
                                    ((pichat-artifacts--prefix-at "\\[" source pos) "\\[")
                                    ((pichat-artifacts--prefix-at "\\(" source pos) "\\(")
                                    ((and (= (aref source pos) ?$)
                                          (not (and (> pos 0) (= (aref source (1- pos)) ?\\)))
                                          (< (1+ pos) (length source))
                                          (not (memq (aref source (1+ pos)) '(?\s ?\n ?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9)))) "$")))
                  (close (pcase delimiter ("\\[" "\\]") ("\\(" "\\)") (_ delimiter)))
                  (end (and close (string-match (regexp-quote close) source (+ pos (length delimiter))))))
              (when (and end (> end (+ pos (length delimiter)))
                         (not (string-match-p "\n" (substring source pos end)))
                         (not (and (equal delimiter "$")
                                   (or (memq (aref source (1- end)) '(?\s ?\n))
                                       (and (< (+ end 1) (length source))
                                            (memq (aref source (1+ end)) '(?0 ?1 ?2 ?3 ?4 ?5 ?6 ?7 ?8 ?9)))))))
                (push (pichat-artifacts--make 'latex source pos (+ end (length close))
                                              (substring source pos (+ end (length close)))) result)
                (setq pos (+ end (length close))) t)))
           (t (setq pos (1+ pos)))))))
    (sort result (lambda (a b) (< (pichat-artifact-start a) (pichat-artifact-start b))))))

(defun pichat-artifacts-at (artifacts offset)
  "Return most specific member of ARTIFACTS containing OFFSET."
  (car (sort (cl-remove-if-not
              (lambda (a) (and (<= (pichat-artifact-start a) offset)
                                (< offset (pichat-artifact-end a))))
              (copy-sequence artifacts))
             (lambda (a b) (< (- (pichat-artifact-end a) (pichat-artifact-start a))
                              (- (pichat-artifact-end b) (pichat-artifact-start b)))))))
(provide 'pichat-artifacts)
;;; pichat-artifacts.el ends here
