;;; reading.el --- reading & content consumption -*- lexical-binding: t; -*-
;;
;;; Commentary:
;;; Web, feeds and document reading (eww, nov, elfeed, pdf).
;;; Code:

(declare-function my/emacs-local-dir "utils.el")
(declare-function my/emacs-shared-dir "utils.el")

(use-package eww
  :ensure nil
  :init
  (defvar my/browse-url-rules-alist
    '(("github\\.com" . browse-url-default-browser))
    "Alist of (REGEX . BROWSER-FUNCTION) pairs.
REGEX is matched against the URL to determine which browser function to use.")

  (defun my/browse-url-with-rules (url &optional new-window)
    "Browse URL using different browser functions based on regex rules.
The browser function is selected from `browse-url-rules-alist'.
Optional argument NEW-WINDOW is passed to the browser function."
    (interactive (browse-url-interactive-arg "URL: "))
    (let* ((matching-rule (cl-find-if (lambda (rule)
                                        (string-match-p (car rule) url))
                                      my/browse-url-rules-alist))
           (func (if matching-rule (cdr matching-rule) 'eww-browse-url)))
      (funcall func url new-window)))

  (setq eww-bookmarks-directory (my/emacs-shared-dir ""))
  (setq browse-url-browser-function 'my/browse-url-with-rules)
  (setq browse-url-secondary-browser-function 'browse-url-default-browser)
  :bind
  (([remap eww-download] . ignore)))

(use-package nov
  :mode ("\\.epub\\'" . nov-mode)
  :custom
  (nov-save-place-file (my/emacs-local-dir "nov-places")))

(use-package pdf-tools :magic ("%PDF" . pdf-view-mode))

(use-package pdf-view-restore
  :after pdf-tools
  :hook (pdf-view-mode . pdf-view-restore-mode)
  :custom
  (pdf-view-restore-filename (my/emacs-local-dir "pdf-view-restore")))

;; elfeed
(use-package elfeed
  :defer t
  :general
  (general-define-key :states 'normal :keymaps 'elfeed-show-mode-map
                      "s-<return>" 'elfeed-browse-entry-url
                      "M-<return>" 'elfeed-browse-entry-url)
  :config
  (defun elfeed-browse-entry-url (&optional external)
    (interactive "P")
    (if external
        (embark-open-externally (elfeed-entry-link elfeed-show-entry))
      (eww (elfeed-entry-link elfeed-show-entry))))

  (defun my/embark-target-elfeed-entry ()
    "Target the Elfeed search entry on the current row."
    (when (derived-mode-p 'elfeed-search-mode)
      (when-let* ((entry (elfeed-search-selected :ignore-region))
                  (url (elfeed-entry-link entry)))
        `(elfeed-entry
          ,url
          ,(line-beginning-position) . ,(line-end-position)))))

  (defun my/elfeed-copy-entry-title ()
    "Copy the title of the Elfeed entry at point."
    (interactive)
    (when-let ((entry (elfeed-search-selected :ignore-region)))
      (let ((title (or (elfeed-meta entry :title)
                       (elfeed-entry-title entry))))
        (kill-new title)
        (message "Copied: %s" title))))

  (defun my/elfeed-copy-feed-url ()
    "Copy the feed URL for the Elfeed entry at point."
    (interactive)
    (when-let* ((entry (elfeed-search-selected :ignore-region))
                (feed (elfeed-entry-feed entry))
                (url (elfeed-feed-url feed)))
      (kill-new url)
      (message "Copied: %s" url)))

  (defun my/elfeed-copy-org-link ()
    "Copy an Org link for the Elfeed entry at point."
    (interactive)
    (when-let* ((entry (elfeed-search-selected :ignore-region))
                (url (elfeed-entry-link entry)))
      (let* ((title (or (elfeed-meta entry :title)
                        (elfeed-entry-title entry)
                        url))
             (link (format "[[%s][%s]]" url title)))
        (kill-new link)
        (message "Copied: %s" link))))

  (defun my/elfeed-show-entry-info ()
    "Display useful information about the Elfeed entry at point."
    (interactive)
    (when-let* ((entry (elfeed-search-selected :ignore-region))
                (feed (elfeed-entry-feed entry)))
      (pp-display-expression
       `((title . ,(elfeed-entry-title entry))
         (url . ,(elfeed-entry-link entry))
         (date . ,(format-time-string "%F %T" (elfeed-entry-date entry)))
         (feed . ,(elfeed-feed-title feed))
         (feed-url . ,(elfeed-feed-url feed))
         (tags . ,(elfeed-entry-tags entry))
         (metadata . ,(elfeed-entry-meta entry)))
       "*Elfeed entry info*")))

  (with-eval-after-load 'embark
    (defvar-keymap my/embark-elfeed-entry-map
      :doc "Embark actions for Elfeed entries."
      :parent embark-url-map
      "RET" #'elfeed-search-show-entry
      "t" #'my/elfeed-copy-entry-title
      "f" #'my/elfeed-copy-feed-url
      "o" #'my/elfeed-copy-org-link
      "i" #'my/elfeed-show-entry-info)

    (add-to-list 'embark-keymap-alist
                 '(elfeed-entry . my/embark-elfeed-entry-map))
    (add-to-list 'embark-target-finders
                 #'my/embark-target-elfeed-entry))
  :custom
  (elfeed-search-filter "@2-day +unread")
  (elfeed-search-feed-face ":foreground #ffffff :weight bold")
  (elfeed-feeds (quote
                 (("https://hnrss.org/frontpage" hn dev)
                  ("https://lobste.rs/rss" lobster dev)
                  ("https://sachachua.com/blog/category/emacs-news/feed/" emacs-news)))))

(use-package elfeed-goodies
  :functions elfeed-goodies/setup
  :after elfeed
  :custom
  (elfeed-goodies/entry-pane-size 0.5)
  :config
  (elfeed-goodies/setup))

(provide 'user/reading)
;;; reading.el ends here
