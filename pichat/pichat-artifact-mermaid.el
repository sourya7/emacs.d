;;; pichat-artifact-mermaid.el --- Local Docker Mermaid rendering -*- lexical-binding: t; -*-
;;; Commentary:
;; Rendering is local even for an SSH Pi runtime.  Publication is separate.
;; Docker is defense in depth, not a sandbox or a Pi permission boundary.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'pichat-artifact-runner)

(defgroup pichat-artifact-mermaid nil "Local Docker Mermaid rendering."
  :group 'pichat-artifact-runner)
(defcustom pichat-artifact-mermaid-image
  "ghcr.io/mermaid-js/mermaid-cli/mermaid-cli:11.12.0"
  "Pinned Mermaid CLI image. A missing image requires consent before downloading."
  :type 'string :group 'pichat-artifact-mermaid)
(defcustom pichat-artifact-mermaid-max-bytes (* 4 1024 1024)
  "Maximum rendered PNG bytes accepted for preview and retention."
  :type 'integer :group 'pichat-artifact-mermaid)
(defcustom pichat-artifact-mermaid-max-dimension 8192
  "Maximum PNG width or height accepted from the renderer."
  :type 'integer :group 'pichat-artifact-mermaid)

(cl-defstruct (pichat-artifact-mermaid--job
               (:constructor pichat-artifact-mermaid--job-create))
  docker image endpoint workspace container session buffer process stage
  cancelled created cleanup-started)

(defun pichat-artifact-mermaid--png-size (file)
  "Validate PNG header and dimensions of FILE; return its byte size."
  (unless (and (not (file-symlink-p file)) (file-regular-p file)
               (<= 24 (file-attribute-size (file-attributes file))
                   pichat-artifact-mermaid-max-bytes))
    (error "Mermaid produced no PNG or exceeded the output byte limit"))
  (let ((bytes (with-temp-buffer
                 (set-buffer-multibyte nil)
                 (insert-file-contents-literally file nil 0 24)
                 (buffer-string))))
    (unless (and (= (length bytes) 24)
                 (equal (substring bytes 0 16)
                        (unibyte-string 137 80 78 71 13 10 26 10
                                        0 0 0 13 73 72 68 82)))
      (error "Mermaid output has an invalid PNG header"))
    (let ((width 0) (height 0))
      (dotimes (i 4)
        (setq width (+ (* 256 width) (aref bytes (+ 16 i)))
              height (+ (* 256 height) (aref bytes (+ 20 i)))))
      (unless (and (<= 1 width pichat-artifact-mermaid-max-dimension)
                   (<= 1 height pichat-artifact-mermaid-max-dimension))
        (error "Mermaid PNG dimensions exceed the preview limit"))))
  (file-attribute-size (file-attributes file)))

(defun pichat-artifact-mermaid--runtime-path (file session)
  "Return a verified Pi path for local FILE, or nil for remote SESSION.
Do not publish a local temporary filename as a remote file reference."
  (unless (and session
               (eq (pichat-transport-kind (pichat-session-transport session)) 'ssh))
    (let* ((resolved (pichat-path-resolve-to-runtime
                      file (if session (pichat-session-path-context session)
                             (pichat-transport-path-context pichat-transport-local))))
           (path (plist-get resolved :path)))
      (and (or (eq (plist-get resolved :status) 'mapped)
               (not (and session
                         (cl-some (lambda (arg)
                                    (member (file-name-nondirectory arg)
                                            '("docker" "podman")))
                                  (pichat-session-rpc-command session)))))
           (stringp path) (file-name-absolute-p path)
           (not (file-remote-p path)) path))))

(defun pichat-artifact-mermaid--note (job text)
  "Show TEXT in JOB's view, or Messages if the view has closed."
  (if (buffer-live-p (pichat-artifact-mermaid--job-buffer job))
      (with-current-buffer (pichat-artifact-mermaid--job-buffer job)
        (let ((inhibit-read-only t))
          (goto-char (point-max)) (insert "\n" text "\n")))
    (message "PiChat Mermaid: %s" text)))

(defun pichat-artifact-mermaid--collect (job)
  "Retain JOB's validated local output; remove an unsuccessful publication."
  (let ((output (expand-file-name "output.png"
                                  (pichat-artifact-mermaid--job-workspace job)))
        retained committed)
    (pichat-artifact-mermaid--png-size output)
    (unwind-protect
        (progn
          (setq retained (make-temp-file "pichat-mermaid-output-" nil ".png"))
          (copy-file output retained t)
          (set-file-modes retained #o600)
          (pichat-artifact-mermaid--png-size retained)
          (setq pichat-artifact-runner--artifact-file retained
                pichat-artifact-runner--artifact-runtime-path
                (pichat-artifact-mermaid--runtime-path
                 retained (pichat-artifact-mermaid--job-session job))
                committed t)
          (pichat-artifact-mermaid--note job (format "PNG (retained locally): %s" retained))
          (condition-case err
              (when (display-images-p)
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (insert-image (create-image retained 'png nil
                                              :max-width 900 :max-height 900)
                                "[PNG diagram]")
                  (insert "\n")))
            (error (pichat-artifact-mermaid--note
                    job (format "PNG preview unavailable: %s" (error-message-string err))))))
      (when (and retained (not committed)) (delete-file retained)))))

(defun pichat-artifact-mermaid--cleanup (job)
  "Asynchronously remove JOB's owned container, then its disposable workspace.
Creating a container is allowed to settle before removal, preventing a late
create from racing a successful removal of a not-yet-existing container."
  (unless (pichat-artifact-mermaid--job-cleanup-started job)
    (setf (pichat-artifact-mermaid--job-cleanup-started job) t)
    (let* ((workspace (pichat-artifact-mermaid--job-workspace job))
           (container (pichat-artifact-mermaid--job-container job))
           (default-directory temporary-file-directory)
           (buffer (generate-new-buffer " *PiChat Mermaid cleanup*"))
           process timer)
      (condition-case err
          (progn
            (setq process
                  (make-process
                   :name "pichat-mermaid-cleanup" :buffer buffer
                   :command (append (list (pichat-artifact-mermaid--job-docker job))
                                    (when (pichat-artifact-mermaid--job-endpoint job)
                                      (list "--host" (pichat-artifact-mermaid--job-endpoint job)))
                                    (list "rm" "--force" container))
                   :connection-type 'pipe :noquery t
                   :sentinel
                   (lambda (proc _event)
                     (when (memq (process-status proc) '(exit signal))
                       (when timer (cancel-timer timer))
                       (unwind-protect
                           (if (or (and (eq (process-status proc) 'exit)
                                        (= 0 (process-exit-status proc)))
                                   (and (not (pichat-artifact-mermaid--job-created job))
                                        (with-current-buffer buffer
                                          (string-match-p "No such container" (buffer-string)))))
                               (condition-case failure
                                   (delete-directory workspace t)
                                 (error (pichat-artifact-mermaid--note
                                         job (error-message-string failure))))
                             (pichat-artifact-mermaid--note
                              job (format "Cleanup unconfirmed: container %s; workspace %s. Remove manually."
                                          container workspace)))
                         (kill-buffer buffer))))))
            (setq timer (run-at-time 15 nil
                                     (lambda ()
                                       (when (process-live-p process)
                                         (delete-process process))))))
        (error (kill-buffer buffer)
               (pichat-artifact-mermaid--note
                job (format "Cleanup failed for %s (%s): %s"
                            container workspace (error-message-string err))))))))

(defun pichat-artifact-mermaid--stop (job)
  "Cancel JOB; wait for an outstanding create before removing its container."
  (setf (pichat-artifact-mermaid--job-cancelled job) t)
  (let ((process (pichat-artifact-mermaid--job-process job)))
    (if (and (eq (pichat-artifact-mermaid--job-stage job) 'create)
             (process-live-p process))
        ;; Keep the client alive to observe creation's definitive outcome.
        ;; If Docker is unresponsive, report uncertainty instead of pretending
        ;; a single `rm' closes the create/remove race.
        (run-at-time
         15 nil
         (lambda ()
           (when (process-live-p process)
             (set-process-sentinel process #'ignore)
             (delete-process process)
             (pichat-artifact-mermaid--note
              job (format "Creation cancellation unconfirmed: container %s; workspace %s. Inspect Docker manually."
                          (pichat-artifact-mermaid--job-container job)
                          (pichat-artifact-mermaid--job-workspace job))))))
      (when (process-live-p process)
        (set-process-sentinel process #'ignore)
        (delete-process process))
      (pichat-artifact-mermaid--cleanup job))))

(defun pichat-artifact-mermaid--timeout (job _process)
  "Mark JOB timed out and cancel its current stage."
  (when (buffer-live-p (pichat-artifact-mermaid--job-buffer job))
    (with-current-buffer (pichat-artifact-mermaid--job-buffer job)
      (setq pichat-artifact-runner--status 'timeout
            pichat-artifact-runner--terminal-reason 'timeout)
      (pichat-artifact-mermaid--note job "Timed out")
      (pichat-artifact-mermaid--stop job)
      (pichat-artifact-runner--publish))))

(defun pichat-artifact-mermaid--stage (job stage args)
  "Start asynchronous Docker STAGE with ARGS for JOB."
  (with-current-buffer (pichat-artifact-mermaid--job-buffer job)
    (when (timerp pichat-artifact-runner--timer)
      (cancel-timer pichat-artifact-runner--timer))
    (setf (pichat-artifact-mermaid--job-stage job) stage)
    (pichat-artifact-mermaid--note job (format "Docker stage: %s" stage))
    (setq pichat-artifact-runner--process
          (make-process
           :name "pichat-mermaid" :buffer (current-buffer)
           :command (append (list (pichat-artifact-mermaid--job-docker job)
                                  "--host" (pichat-artifact-mermaid--job-endpoint job))
                            args)
           :connection-type 'pipe :noquery t :coding 'utf-8-unix
           :filter #'pichat-artifact-runner--filter
           :sentinel (lambda (proc event) (pichat-artifact-mermaid--sentinel job proc event))))
    (setf (pichat-artifact-mermaid--job-process job) pichat-artifact-runner--process)
    (setq pichat-artifact-runner--timer
          (run-at-time (if (eq stage 'pull) 300 pichat-artifact-runner-timeout)
                       nil #'pichat-artifact-mermaid--timeout
                       job pichat-artifact-runner--process))))

(defun pichat-artifact-mermaid--create (job)
  "Create JOB's container without starting it, so cancellation has an owner."
  (pichat-artifact-mermaid--stage
   job 'create
   (list "create" "--name" (pichat-artifact-mermaid--job-container job)
         "--pull=never" "--network=none" "--cpus=1" "--memory=512m" "--pids-limit=128"
         "--user" (format "%s:%s" (user-uid) (group-gid))
         "--mount" (format "type=bind,src=%s,dst=/data"
                           (pichat-artifact-mermaid--job-workspace job))
         (pichat-artifact-mermaid--job-image job)
         "-i" "/data/input.mmd" "-o" "/data/output.png" "-c" "/data/config.json")))

(defun pichat-artifact-mermaid--sentinel (job process event)
  "Advance JOB on terminal PROCESS EVENT, or clean up cancelled creation."
  (when (memq (process-status process) '(exit signal))
    (setf (pichat-artifact-mermaid--job-process job) process)
    (if (or (pichat-artifact-mermaid--job-cancelled job)
            (not (buffer-live-p (process-buffer process))))
        (pichat-artifact-mermaid--cleanup job)
      (with-current-buffer (process-buffer process)
        (setf (pichat-artifact-mermaid--job-buffer job) (current-buffer))
        (when (timerp pichat-artifact-runner--timer)
          (cancel-timer pichat-artifact-runner--timer))
        (let ((success (and (eq (process-status process) 'exit)
                            (= 0 (process-exit-status process)))))
          (condition-case err
              (pcase (pichat-artifact-mermaid--job-stage job)
                ('context
                 (unless (and success
                              (string-prefix-p "unix://"
                                               (string-trim pichat-artifact-runner--captured-output)))
                   (error "Mermaid requires a local Docker daemon (Unix socket)"))
                 (setf (pichat-artifact-mermaid--job-endpoint job)
                       (string-trim pichat-artifact-runner--captured-output))
                 (pichat-artifact-mermaid--stage job 'inspect
                                               (list "image" "inspect" "--format" "{{.Id}}"
                                                     (pichat-artifact-mermaid--job-image job))))
                ('inspect
                 (if success (pichat-artifact-mermaid--create job)
                   ;; Distinguish an absent image from daemon/permission failures.
                   (pichat-artifact-mermaid--stage job 'availability
                                                 '("info" "--format" "{{.ID}}"))))
                ('availability
                 (unless success (error "Docker daemon unavailable; see diagnostics"))
                 (if (yes-or-no-p
                      (format "Download Mermaid image %s? " (pichat-artifact-mermaid--job-image job)))
                     (pichat-artifact-mermaid--stage job 'pull
                                                   (list "pull" (pichat-artifact-mermaid--job-image job)))
                   (error "Image download declined; nothing rendered")))
                ('pull
                 (unless success (error "Image download failed; see diagnostics"))
                 (pichat-artifact-mermaid--create job))
                ('create
                 (unless success (error "Container creation failed; see diagnostics"))
                 (setf (pichat-artifact-mermaid--job-created job) t)
                 (pichat-artifact-mermaid--stage job 'render
                                               (list "start" "--attach"
                                                     (pichat-artifact-mermaid--job-container job))))
                ('render (pichat-artifact-runner--finish process event)))
            ((error quit)
             (setq pichat-artifact-runner--result-error (error-message-string err))
             ;; Prevent a successful preflight from collecting a nonexistent PNG.
             (setq pichat-artifact-runner--plan
                   (plist-put pichat-artifact-runner--plan :finish nil))
             (pichat-artifact-runner--finish process event))))))))

(defun pichat-artifact-mermaid--run (code _directory session _spec)
  "Render CODE locally, independently of SESSION's execution host."
  (when (and (getenv "DOCKER_HOST") (not (string-empty-p (getenv "DOCKER_HOST"))))
    (user-error "Mermaid requires a local Docker context; unset DOCKER_HOST"))
  (let* ((default-directory (file-name-as-directory temporary-file-directory))
         (docker (or (executable-find "docker") (user-error "Local Docker is not installed")))
         (workspace (make-temp-file "pichat-mermaid-" t))
         (job (pichat-artifact-mermaid--job-create
               :docker docker :image pichat-artifact-mermaid-image
               :workspace workspace :container (file-name-nondirectory workspace)
               :session session :stage 'context)))
    (condition-case err
        (progn
          (set-file-modes workspace #o700)
          (dolist (entry `(("input.mmd" . ,code)
                           ("config.json" . "{\"securityLevel\":\"strict\",\"maxTextSize\":50000}")))
            (let ((file (expand-file-name (car entry) workspace)))
              (with-temp-file file (insert (cdr entry)))
              (set-file-modes file #o600)))
          (let ((view
                 (pichat-artifact-runner--run-process
                  code default-directory default-directory pichat-transport-local
                  session '(mermaid)
                  (list :executable docker :label "Mermaid (local Docker)"
                        :args '("context" "inspect" "--format" "{{.Endpoints.docker.Host}}")
                        :sentinel (lambda (proc event)
                                    (pichat-artifact-mermaid--sentinel job proc event))
                        :timeout (lambda (proc) (pichat-artifact-mermaid--timeout job proc))
                        :stop (lambda () (pichat-artifact-mermaid--stop job))
                        :finish (lambda () (pichat-artifact-mermaid--collect job))))))
            (setf (pichat-artifact-mermaid--job-buffer job) view
                  (pichat-artifact-mermaid--job-process job)
                  (buffer-local-value 'pichat-artifact-runner--process view))
            view))
      ((error quit)
       (delete-directory workspace t)
       (signal (car err) (cdr err))))))

(provide 'pichat-artifact-mermaid)
;;; pichat-artifact-mermaid.el ends here
