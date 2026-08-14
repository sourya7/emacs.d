;;; elpaca-cache-lock-records.el --- Emit lock-file source records -*- lexical-binding: t; -*-

;;; Commentary:
;; Internal helper for the Elpaca source-cache scripts.  Required inputs are
;; passed through ELPACA_CACHE_PROJECT_ROOT and ELPACA_CACHE_LOCK_FILE.

;;; Code:

(require 'cl-lib)

(defvar elpaca-directory)
(defvar elpaca-builds-directory)
(defvar elpaca-sources-directory)
(defvar elpaca-lock-file)
(defvar elpaca-menu-functions)
(defvar elpaca-menu-lock-file--cache)
(defvar elpaca--source-dirs)

(let* ((root-env (or (getenv "ELPACA_CACHE_PROJECT_ROOT")
                     (error "ELPACA_CACHE_PROJECT_ROOT is not set")))
       (root (file-name-as-directory (expand-file-name root-env)))
       (lock-file (expand-file-name
                   (or (getenv "ELPACA_CACHE_LOCK_FILE")
                       (expand-file-name "elpaca-lock.eld" root))))
       (elpaca-source (expand-file-name ".local/elpaca/sources/elpaca/" root)))
  (setq user-emacs-directory root
        elpaca-directory (expand-file-name ".local/elpaca/" root)
        elpaca-builds-directory (expand-file-name "builds/" elpaca-directory)
        elpaca-sources-directory (expand-file-name "sources/" elpaca-directory))
  (unless (file-readable-p lock-file)
    (error "Lock file is not readable: %s" lock-file))
  (unless (file-readable-p (expand-file-name "elpaca.el" elpaca-source))
    (error "Elpaca source is missing: %s" elpaca-source))
  (add-to-list 'load-path elpaca-source)
  (require 'elpaca)
  (require 'elpaca-git)
  (setq elpaca-lock-file lock-file
        elpaca-menu-functions '(elpaca-menu-lock-file)
        elpaca-menu-lock-file--cache nil
        elpaca--source-dirs nil)
  (let ((entries (elpaca-menu-lock-file 'index)))
    (unless entries
      (error "Lock file contains no package entries: %s" lock-file))
    (dolist (entry entries)
      (let* ((id (car entry))
             (locked-recipe (plist-get (cdr entry) :recipe))
             (locked-type (or (plist-get locked-recipe :type) 'unknown))
             (e (unless (eq locked-type 'file) (elpaca<-create id)))
             (recipe (if e (elpaca<-recipe e) locked-recipe))
             (type (or (plist-get recipe :type) 'unknown))
             (ref (plist-get recipe :ref))
             (source (if e
                         (elpaca<-source-dir e)
                       (file-name-directory (plist-get recipe :main)))))
        (unless source
          (error "Unable to determine source directory for %s" id))
        (princ (format "lock\t%s\t%s\t%s\t%s\n"
                       id type (file-relative-name source root) (or ref "-")))))))

;;; elpaca-cache-lock-records.el ends here
