;;; pichat-command-catalog.el --- Shared Pi command discovery -*- lexical-binding: t; -*-

;;; Commentary:

;; Commands, templates and skills share discovery and completion metadata, not
;; action semantics.  Consumers own source/request freshness and decide whether
;; to edit a draft or submit.  This module owns no cache or chat state.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'pichat-rpc)

(defun pichat-command-catalog-normalize (response)
  "Return validated command records from RESPONSE in Pi order.
Keep the first record for each exact name so action keys are unambiguous.
Optional display fields must be strings; retain other provenance fields.
Malformed lists and records are ignored, never offered as actions."
  (let ((commands (plist-get (plist-get response :data) :commands))
        (seen (make-hash-table :test #'equal)))
    (when (proper-list-p commands)
      (cl-loop for command in commands
               when (and (proper-list-p command)
                         (cl-evenp (length command))
                         (stringp (plist-get command :name))
                         (not (string-empty-p (plist-get command :name)))
                         (not (string-match-p "[[:space:]]" (plist-get command :name)))
                         (not (gethash (plist-get command :name) seen)))
               collect
               (let ((record (copy-sequence command)))
                 (puthash (plist-get record :name) t seen)
                 (dolist (field '(:source :description))
                   (unless (stringp (plist-get record field))
                     (setq record (plist-put record field nil))))
                 record)))))

(defun pichat-command-catalog-fetch (session success &optional failure)
  "Discover commands for SESSION, delivering validated records to SUCCESS.
SUCCESS receives (COMMANDS RESPONSE-SESSION); FAILURE retains the RPC callback
contract.  Consumers must validate their captured context on both paths."
  (pichat-rpc-get-commands
   session
   (lambda (response response-session)
     (funcall success (pichat-command-catalog-normalize response) response-session))
   failure))

(defun pichat-command-catalog-annotation (commands name)
  "Return the source and description annotation for NAME in COMMANDS."
  (when-let* ((command (cl-find name commands
                               :key (lambda (item) (plist-get item :name))
                               :test #'equal)))
    (let ((source (plist-get command :source))
          (description (plist-get command :description)))
      (concat (if (and (stringp source) (not (string-empty-p source)))
                  (format "  [%s]" source) "")
              (if (and (stringp description) (not (string-empty-p description)))
                  (concat " " description) "")))))

(defun pichat-command-catalog-table (commands)
  "Return a completion table for COMMANDS with shared ordered metadata.
Candidates are exact names; annotations never become part of the action key."
  (let ((names (mapcar (lambda (command) (plist-get command :name)) commands))
        (annotation (apply-partially #'pichat-command-catalog-annotation commands)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          `(metadata
            (category . pichat-slash-command)
            (annotation-function . ,annotation)
            (display-sort-function . identity)
            (cycle-sort-function . identity))
        (complete-with-action action names string predicate)))))

(provide 'pichat-command-catalog)
;;; pichat-command-catalog.el ends here
