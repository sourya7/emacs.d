;;; pichat-process-lifetime.el --- Evidence for SSH process exit -*- lexical-binding: t; -*-

;;; Commentary:
;; A dead SSH endpoint is not evidence that its remote writer exited.  Linux
;; identities come from the actual Pi helper, not TRAMP's intermediate shell.
;; Observers never signal remote PIDs and never interpret probe failure as exit.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-transport)

(defun pichat-process-lifetime-identity (data)
  "Validate helper identity DATA, returning a detached lifetime or nil.
Unsupported hosts report nil; malformed claimed identities are errors."
  (when data
    (let ((pid (gethash "pid" data))
          (start (gethash "start" data))
          (boot (gethash "boot" data)))
      (unless (and (equal (gethash "kind" data) "linux-procfs-v1")
                   (integerp pid) (> pid 1)
                   (stringp start) (string-match-p "\\`[0-9]+\\'" start)
                   (stringp boot)
                   (string-match-p "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'" boot))
        (error "Invalid actual-Pi process identity"))
      (list :pid pid :start (copy-sequence start) :boot (copy-sequence boot)))))

(defun pichat-process-lifetime-supported-p (process)
  "Whether PROCESS has verified actual-Pi lifetime identity."
  (and (processp process) (process-get process 'pichat-lifetime)))

(defun pichat-process-lifetime-confirmed-p (process)
  "Whether exact PROCESS has validated remote exit evidence."
  (and (processp process) (process-get process 'pichat-exit-confirmed)))

(defun pichat-process-lifetime-confirm (process)
  "Record validated exit of PROCESS without doing remote file I/O."
  (process-put process 'pichat-exit-confirmed t))

(defun pichat-process-lifetime-cleanup (process)
  "Clean PROCESS's retained private helper only after validated exit.
Call outside the shutdown barrier: TRAMP file housekeeping can reconnect."
  (when-let* (((pichat-process-lifetime-confirmed-p process))
              (cleanup (process-get process 'pichat-helper-cleanup)))
    (process-put process 'pichat-helper-cleanup nil)
    ;; Cleanup is not part of exit proof and cannot revoke it.  Preserve a
    ;; failed cleanup for inspection/retry rather than claiming it succeeded.
    (condition-case err (funcall cleanup)
      ((error quit) (process-put process 'pichat-helper-cleanup cleanup)
                    (process-put process 'pichat-helper-cleanup-error err)))))

(defun pichat-process-lifetime--script (identity token seconds require-live)
  "Build a bounded Linux observer for IDENTITY, TOKEN and SECONDS.
REQUIRE-LIVE rejects an absent initial process (ordinary restart preflight)."
  (format
   "set -f
pid=%d
expected=%s
boot=%s
check() {
  b=$(cat /proc/sys/kernel/random/boot_id) || exit 2
  [ \"$b\" = \"$boot\" ] || exit 2
  cat /proc/self/stat >/dev/null || exit 2
  if [ -d /proc/$pid ]; then
    s=$(cat /proc/$pid/stat) || exit 2
    rest=${s##*) }
    [ \"$rest\" != \"$s\" ] || exit 2
    set -- $rest
    [ $# -ge 20 ] || exit 2
    shift 19
    case $1 in ''|*[!0-9]*) exit 2;; esac
    [ \"$1\" = \"$expected\" ] && return 0
  fi
  return 1
}
check
initial=$?
%s
printf 'PC-LIFETIME %s ready\\n'
i=0
while [ $i -lt %d ]; do
  if ! check; then printf 'PC-LIFETIME %s gone\\n'; exit 0; fi
  i=$((i+1))
  sleep 0.1 || exit 2
done
exit 3
"
   (plist-get identity :pid) (shell-quote-argument (plist-get identity :start))
   (shell-quote-argument (plist-get identity :boot))
   (if require-live "[ $initial -eq 0 ] || exit 2" ":")
   token (max 1 (ceiling (* 10 seconds))) token))

(defun pichat-process-lifetime-watch
    (transport cwd process seconds require-live ready callback)
  "Observe exact remote PROCESS through captured TRANSPORT and CWD.
Call READY after a verified baseline, CALLBACK with (SUCCESS REASON) on exit
confirmation/failure.  Return a cancellation function that suppresses callbacks.
SECONDS bounds observation after synchronous TRAMP connection setup.  A
successful confirmation requires a token-qualified gone record AND clean probe
exit, never transport EOF alone.  The caller owns deciding whether evidence is
still current before recording it or starting a replacement."
  (let* ((identity (copy-sequence (process-get process 'pichat-lifetime)))
         (token (substring (secure-hash 'sha256 (format "%s:%s:%s" (random) (float-time) (make-symbol "observer"))) 0 32))
         (remainder "") (bytes 0) observer timer dispatch-timer
         baseline gone finished early-exit early-error)
    (unless (and (eq (pichat-transport-kind transport) 'ssh) identity)
      (user-error "SSH runtime has no verified Linux actual-Pi identity"))
    (cl-labels
        ((cancel ()
           (setq finished t)
           (when (timerp timer) (cancel-timer timer))
           (when (timerp dispatch-timer) (cancel-timer dispatch-timer))
           (when (and observer (process-live-p observer)) (delete-process observer)))
         (finish (success reason)
           (unless finished
             (cancel)
             (funcall callback success reason)))
         (dispatch ()
           (setq dispatch-timer nil)
           (unless finished
             (condition-case err
                 (let (end)
                   (when early-error (error "%s" early-error))
                   (while (and (not finished) (setq end (string-match "\n" remainder)))
                     (let ((line (string-remove-suffix "\r" (substring remainder 0 end))))
                       (setq remainder (substring remainder (1+ end)))
                       (cond
                        ((and (not baseline) (equal line (concat "PC-LIFETIME " token " ready")))
                         (setq baseline t)
                         (funcall ready))
                        ((and baseline (not gone) (equal line (concat "PC-LIFETIME " token " gone")))
                         (setq gone t))
                        (t (error "Invalid SSH exit observer response")))))
                   (when (and early-exit (not finished))
                     (if (and baseline gone (string-empty-p remainder)
                              (eq (process-status observer) 'exit)
                              (zerop (process-exit-status observer)))
                         (finish t nil)
                       (finish nil "SSH exit observer disconnected or could not confirm old Pi exit"))))
               (error (finish nil (error-message-string err))))))
         (schedule ()
           (unless (or finished dispatch-timer)
             (setq dispatch-timer (run-at-time 0 nil #'dispatch))))
         (filter (_proc chunk)
           (unless finished
             (cl-incf bytes (string-bytes chunk))
             (if (> bytes 4096)
                 (setq early-error "SSH exit observer output exceeded its limit")
               (setq remainder (concat remainder chunk)))
             (schedule)))
         (sentinel (proc _event)
           (unless (process-live-p proc)
             (setq early-exit t)
             (schedule))))
      (condition-case err
          (progn
            (setq observer
                  (pichat-transport-make-process
                   transport cwd :name "pichat-exit-observer" :buffer nil
                   :coding 'utf-8-unix :filter #'filter :sentinel #'sentinel
                   :command (list "sh" "-c" (pichat-process-lifetime--script
                                             identity token seconds require-live))))
            (setq timer (run-at-time seconds nil
                                     (lambda () (finish nil "Timed out confirming remote Pi shutdown"))))
            (when (not (process-live-p observer)) (setq early-exit t))
            (schedule))
        ((error quit)
         (cancel)
         (signal (car err) (cdr err))))
      #'cancel)))

(provide 'pichat-process-lifetime)
;;; pichat-process-lifetime.el ends here
