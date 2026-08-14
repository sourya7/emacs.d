;;; pichat-attachments.el --- Bounded image attachments for PiChat -*- lexical-binding: t; -*-

;;; Commentary:

;; Image acquisition and bounded attachment records.  This module does not
;; depend on the chat buffer; callers own pending and in-flight collections.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup pichat-attachments nil
  "Image attachments sent through Pi RPC."
  :group 'pichat)

(defcustom pichat-attachments-max-count 8
  "Maximum number of image records retained by one chat buffer.
The same bound also applies to one submission."
  :type 'integer
  :group 'pichat-attachments)

(defcustom pichat-attachments-max-file-bytes (* 10 1024 1024)
  "Maximum unencoded bytes allowed for one image attachment."
  :type 'integer
  :group 'pichat-attachments)

(defcustom pichat-attachments-max-total-bytes (* 20 1024 1024)
  "Maximum total unencoded bytes retained for one chat buffer.
Callers pass all pending, in-flight, and recoverable records when acquiring a
new image.  The same bound also applies to one submission."
  :type 'integer
  :group 'pichat-attachments)

(defcustom pichat-attachments-allowed-mime-types
  '("image/png" "image/jpeg" "image/gif" "image/webp")
  "Image MIME types accepted by PiChat."
  :type '(repeat string)
  :group 'pichat-attachments)

(defcustom pichat-attachments-allow-image-only-prompts nil
  "When non-nil, allow submitting images without prompt text."
  :type 'boolean
  :group 'pichat-attachments)

(defcustom pichat-attachments-summary-max-chars 100
  "Maximum width of pending attachment names in compact presentation."
  :type 'integer
  :group 'pichat-attachments)

(defcustom pichat-attachments-screenshot-command
  (if (eq system-type 'darwin)
      '("/usr/sbin/screencapture" "-i")
    '("import"))
  "Command used to capture a screenshot.
The temporary output path is appended to this command."
  :type '(repeat string)
  :group 'pichat-attachments)

(defcustom pichat-attachments-clipboard-image-handlers
  '((:command "pngpaste" :arguments nil :output file)
    (:command "wl-paste" :arguments ("--type" "image/png") :output stdout)
    (:command "xclip" :arguments ("-selection" "clipboard" "-t" "image/png" "-o")
     :output stdout))
  "Commands tried when acquiring an image from the clipboard.
Each plist has :command, :arguments, and :output.  :output is either `file',
meaning the destination path is appended, or `stdout', meaning binary standard
output is written to the destination."
  :type '(repeat plist)
  :group 'pichat-attachments)

(defvar pichat-attachments--sequence 0)

(defun pichat-attachments-mime-type (path)
  "Return the supported image MIME type implied by PATH, or nil."
  (let ((extension (downcase (or (file-name-extension path) ""))))
    (cdr (assoc extension
                '(("png" . "image/png")
                  ("jpg" . "image/jpeg")
                  ("jpeg" . "image/jpeg")
                  ("gif" . "image/gif")
                  ("webp" . "image/webp"))))))

(defun pichat-attachments-total-bytes (attachments)
  "Return total raw byte size of ATTACHMENTS."
  (cl-loop for attachment in attachments
           sum (or (plist-get attachment :bytes) 0)))

(defun pichat-attachments--validate-capacity (attachments bytes)
  "Validate adding BYTES to ATTACHMENTS against configured bounds."
  (when (>= (length attachments) pichat-attachments-max-count)
    (user-error "PiChat attachment limit is %d images"
                pichat-attachments-max-count))
  (when (> bytes pichat-attachments-max-file-bytes)
    (user-error "Image is too large (%d bytes; limit %d)"
                bytes pichat-attachments-max-file-bytes))
  (let ((total (+ bytes (pichat-attachments-total-bytes attachments))))
    (when (> total pichat-attachments-max-total-bytes)
      (user-error "PiChat attachment total is too large (%d bytes; limit %d)"
                  total pichat-attachments-max-total-bytes))))

(defun pichat-attachments-read-image-file (path &optional existing)
  "Read PATH into a bounded attachment record alongside EXISTING records."
  (let* ((path (expand-file-name path))
         (mime-type (pichat-attachments-mime-type path)))
    (unless (and mime-type
                 (member mime-type pichat-attachments-allowed-mime-types))
      (user-error "Unsupported image type: %s"
                  (or (file-name-extension path) "none")))
    (unless (and (file-regular-p path) (file-readable-p path))
      (user-error "Image is not a readable regular file: %s" path))
    (let ((bytes (file-attribute-size (file-attributes path))))
      (when (zerop bytes)
        (user-error "Image file is empty: %s" path))
      (pichat-attachments--validate-capacity existing bytes)
      (list :id (format "image-%d" (cl-incf pichat-attachments--sequence))
            :type "image"
            :data (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally path)
                    (base64-encode-string (buffer-string) t))
            :mimeType mime-type
            :name (file-name-nondirectory path)
            :bytes bytes))))

(defun pichat-attachments-validate-set (attachments)
  "Validate ATTACHMENTS as one pending submission and return it."
  (when (> (length attachments) pichat-attachments-max-count)
    (user-error "PiChat attachment limit is %d images"
                pichat-attachments-max-count))
  (dolist (attachment attachments)
    (when (> (or (plist-get attachment :bytes) 0)
             pichat-attachments-max-file-bytes)
      (user-error "Image %s exceeds the %d byte limit"
                  (or (plist-get attachment :name) "image")
                  pichat-attachments-max-file-bytes)))
  (let ((total (pichat-attachments-total-bytes attachments)))
    (when (> total pichat-attachments-max-total-bytes)
      (user-error "PiChat attachment total is too large (%d bytes; limit %d)"
                  total pichat-attachments-max-total-bytes)))
  attachments)

(defun pichat-attachments-add (attachments attachment)
  "Append ATTACHMENT to ATTACHMENTS after validating configured bounds."
  (pichat-attachments-validate-set (append attachments (list attachment))))

(defun pichat-attachments-merge-unique (first second)
  "Return FIRST followed by records from SECOND with new attachment identities."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (attachment (append first second) (nreverse result))
      (let ((id (plist-get attachment :id)))
        (unless (gethash id seen)
          (puthash id t seen)
          (push attachment result))))))

(defun pichat-attachments-remove (attachments id)
  "Return ATTACHMENTS without the record identified by ID."
  (cl-remove id attachments :key (lambda (record) (plist-get record :id))
             :test #'equal))

(defun pichat-attachments-wire-images (attachments)
  "Return ATTACHMENTS in Pi RPC ImageContent vector form."
  (vconcat
   (mapcar (lambda (attachment)
             (list :type "image"
                   :data (plist-get attachment :data)
                   :mimeType (plist-get attachment :mimeType)))
           attachments)))

(defun pichat-attachments-summary (pending in-flight-count)
  "Return compact presentation for PENDING and IN-FLIGHT-COUNT, or nil."
  (when (or pending (> in-flight-count 0))
    (let ((parts nil))
      (when pending
        (push (format "%d pending: %s"
                      (length pending)
                      (truncate-string-to-width
                       (string-join
                        (mapcar (lambda (record)
                                  (or (plist-get record :name) "image"))
                                pending)
                        ", ")
                       pichat-attachments-summary-max-chars nil nil "…"))
              parts))
      (when (> in-flight-count 0)
        (push (format "%d sending" in-flight-count) parts))
      (format "[images · %s]" (string-join (nreverse parts) " · ")))))

(defun pichat-attachments--run-output-command (command arguments path)
  "Run COMMAND with ARGUMENTS and save binary standard output to PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((status (apply #'call-process command nil t nil arguments)))
      (unless (and (integerp status) (zerop status))
        (error "%s failed with status %s" command status)))
    (write-region (point-min) (point-max) path nil 'silent)))

(defun pichat-attachments-read-clipboard (existing)
  "Acquire a clipboard image and return a bounded record alongside EXISTING."
  (let ((handler
         (seq-find (lambda (candidate)
                     (executable-find (plist-get candidate :command)))
                   pichat-attachments-clipboard-image-handlers)))
    (unless handler
      (user-error "No supported clipboard image command is available"))
    (let ((path (make-temp-file "pichat-clipboard-" nil ".png")))
      (unwind-protect
          (progn
            (pcase (plist-get handler :output)
              ('file
               (let ((status
                      (apply #'call-process
                             (plist-get handler :command) nil nil nil
                             (append (plist-get handler :arguments)
                                     (list path)))))
                 (unless (and (integerp status) (zerop status))
                   (error "%s failed with status %s"
                          (plist-get handler :command) status))))
              ('stdout
               (pichat-attachments--run-output-command
                (plist-get handler :command)
                (plist-get handler :arguments) path))
              (_ (error "Invalid PiChat clipboard handler")))
            (pichat-attachments-read-image-file path existing))
        (ignore-errors (delete-file path))))))

(defun pichat-attachments-capture-screenshot (existing)
  "Capture a screenshot and return a bounded record alongside EXISTING."
  (unless (and pichat-attachments-screenshot-command
               (executable-find (car pichat-attachments-screenshot-command)))
    (user-error "Screenshot command is unavailable"))
  (let ((path (make-temp-file "pichat-screenshot-" nil ".png")))
    (unwind-protect
        (let ((status
               (apply #'call-process
                      (car pichat-attachments-screenshot-command) nil nil nil
                      (append (cdr pichat-attachments-screenshot-command)
                              (list path)))))
          (unless (and (integerp status) (zerop status))
            (user-error "Screenshot was cancelled or failed"))
          (pichat-attachments-read-image-file path existing))
      (ignore-errors (delete-file path)))))

(provide 'pichat-attachments)
;;; pichat-attachments.el ends here
