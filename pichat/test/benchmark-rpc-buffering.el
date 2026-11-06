;;; benchmark-rpc-buffering.el --- Synthetic RPC framing benchmark -*- lexical-binding: t; -*-

;;; Commentary:

;; Run from the execution checkout, without Pi or private session files:
;;   emacs -Q --batch -L pichat -l pichat/test/benchmark-rpc-buffering.el
;; Override sizes (MiB) before loading for a shorter run:
;;   --eval '(setq pichat-benchmark-rpc-sizes (quote (1 4)))'
;;
;; Measures receive/framing only, excluding JSON decoding and callbacks.  Chunks
;; are allocated before timing.  The frozen pre-fix filter below provides a
;; same-process baseline; no wall-clock thresholds belong in ERT tests.

;;; Code:

(require 'pichat-rpc)
(require 'benchmark)

(defvar pichat-benchmark-rpc-sizes '(1 4 16)
  "Synthetic record sizes in MiB of characters, slightly larger in UTF-8 bytes.")

(defun pichat-benchmark-rpc--legacy-filter (process chunk)
  "Replay the pre-fix string accumulation algorithm for PROCESS and CHUNK."
  (when-let* ((session (process-get process 'pichat-session)))
    (when (pichat-rpc--current-process-p session process)
      (pichat-rpc--mark-ready session process)
      (let ((buf (concat (or (pichat-session-rpc-receive-buffer session) "") chunk))
            line)
        (while (and (pichat-rpc--current-process-p session process)
                    (string-match "\n" buf))
          (setq line (substring buf 0 (match-beginning 0))
                buf (substring buf (match-end 0)))
          (when (string-suffix-p "\r" line)
            (setq line (substring line 0 -1)))
          (unless (string-empty-p line)
            (let ((pichat-rpc--dispatch-process process))
              (pichat-rpc--handle-line session line))))
        (when (pichat-rpc--current-process-p session process)
          (setf (pichat-session-rpc-receive-buffer session) buf))))))

(defun pichat-benchmark-rpc--measure (filter session process chunks repetitions)
  "Time FILTER on SESSION/PROCESS CHUNKS, averaged over REPETITIONS."
  (let ((delivered 0)
        (expected (1- (apply #'+ (mapcar #'length chunks))))
        elapsed)
    (cl-letf (((symbol-function 'pichat-rpc--handle-line)
               (lambda (_session line)
                 (unless (= expected (length line))
                   (error "Framing changed the record length"))
                 (cl-incf delivered))))
      (garbage-collect)
      (setq elapsed
            (car (benchmark-call
                  (lambda ()
                    (setf (pichat-session-rpc-receive-buffer session) nil)
                    (dolist (chunk chunks)
                      (funcall filter process chunk)))
                  repetitions))))
    (unless (= delivered repetitions)
      (error "Expected %d records, received %d" repetitions delivered))
    (/ elapsed repetitions)))

(defun pichat-benchmark-rpc-buffering ()
  "Compare old/new framing at fixed 4 KiB and 64 KiB chunk sizes."
  (let* ((session (pichat-session-make))
         (process (make-pipe-process :name "pichat-buffering-benchmark"
                                     :noquery t)))
    (process-put process 'pichat-session session)
    (setf (pichat-session-process session) process)
    (unwind-protect
        (progn
          (princ (format "Emacs %s; synthetic multibyte get_tree record; receive-only\n"
                         emacs-version))
          (princ "MiB  chunk(KiB)  old(s)    new(s)    speedup\n")
          (dolist (mib pichat-benchmark-rpc-sizes)
            (let ((wire (concat "{\"type\":\"response\",\"command\":\"get_tree\",\"success\":true,\"data\":{\"tree\":[{\"entry\":{\"type\":\"compaction\",\"summary\":\"α"
                                (string #x2028)
                                (make-string (* mib 1024 1024) ?x)
                                "\"},\"children\":[]}]}}\n")))
              (dolist (size '(4096 65536))
                (let (chunks)
                  (cl-loop for start from 0 below (length wire) by size
                           do (push (substring wire start (min (length wire)
                                                               (+ start size)))
                                    chunks))
                  (setq chunks (nreverse chunks))
                  (let* ((old (pichat-benchmark-rpc--measure
                               #'pichat-benchmark-rpc--legacy-filter
                               session process chunks 1))
                         (new (pichat-benchmark-rpc--measure
                               #'pichat-rpc--process-filter
                               session process chunks 5)))
                    (princ (format "%3d  %10d  %8.4f  %8.4f  %7.1fx\n"
                                   mib (/ size 1024) old new (/ old new)))))))))
      (delete-process process))))

(pichat-benchmark-rpc-buffering)

;;; benchmark-rpc-buffering.el ends here
