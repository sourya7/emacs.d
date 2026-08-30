;;; pichat-markdown-fontification.el --- Exact-source Markdown faces -*- lexical-binding: t; -*-

;;; Commentary:

;; Lightweight, fail-open Markdown fontification for completed assistant prose.
;; This component never parses links or tables, creates overlays, caches source,
;; or depends on `pichat-chat'.  It copies only face runs from a temporary
;; `markdown-mode' buffer onto exact projected source text.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function markdown-mode "markdown-mode" ())

(defun pichat-markdown-fontification--face-runs (source)
  "Return relative Markdown face runs for exact string SOURCE.
Return nil when `markdown-mode' is unavailable, fontification fails, or SOURCE
has no faces.  No error from this optional presentation layer escapes."
  (condition-case nil
      (when (require 'markdown-mode nil t)
        (with-temp-buffer
          (insert source)
          (delay-mode-hooks (markdown-mode))
          (font-lock-ensure (point-min) (point-max))
          (let ((position (point-min))
                (limit (point-max))
                runs)
            (while (< position limit)
              (let ((next (or (next-single-property-change
                               position 'face nil limit)
                              limit))
                    (face (get-text-property position 'face)))
                (when face
                  (push (list (1- position) (1- next) face) runs))
                (setq position next)))
            (nreverse runs))))
    (error nil)))

(defun pichat-markdown-fontification-apply-run (beg end)
  "Apply Markdown faces to exact source text in BEG..END.
Only the `font-lock-face' property is added.  Text and all unrelated properties
remain unchanged.  Return non-nil when at least one face was applied; optional
fontification failures return nil without modifying the region."
  (condition-case nil
      (let* ((source (buffer-substring-no-properties beg end))
             (runs (pichat-markdown-fontification--face-runs source))
             (run-length (- end beg)))
        (when (and runs
                   (cl-every
                    (lambda (run)
                      (pcase-let ((`(,start ,finish ,face) run))
                        (and face (integerp start) (integerp finish)
                             (<= 0 start) (< start finish)
                             (<= finish run-length))))
                    runs))
          (let ((inhibit-read-only t))
            (with-silent-modifications
              (pcase-dolist (`(,start ,finish ,face) runs)
                (put-text-property (+ beg start) (+ beg finish)
                                   'font-lock-face face))))
          t))
    (error nil)))

(defun pichat-markdown-fontification-apply-region (beg end)
  "Fontify each completed assistant prose run in BEG..END.
Runs are selected only by the projection's `pichat-prose' property.  Each run
fails open independently, leaving exact visible source untouched."
  (when (< beg end)
    (let ((position beg)
          applied)
      (while (< position end)
        (let ((next (or (next-single-property-change
                         position 'pichat-prose nil end)
                        end)))
          (when (get-text-property position 'pichat-prose)
            (setq applied
                  (or (pichat-markdown-fontification-apply-run position next)
                      applied)))
          (setq position next)))
      applied)))

(provide 'pichat-markdown-fontification)
;;; pichat-markdown-fontification.el ends here
