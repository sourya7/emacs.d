((ace-link :source "elpaca-menu-lock-file" :recipe
           (:package "ace-link" :repo "abo-abo/ace-link" :fetcher
                     github :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id ace-link :type git :protocol
                     https :inherit t :depth treeless :ref
                     "d9bd4a25a02bdfde4ea56247daf3a9ff15632ea4"))
 (ace-window :source "elpaca-menu-lock-file" :recipe
             (:package "ace-window" :repo "abo-abo/ace-window"
                       :fetcher github :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id ace-window :type git
                       :protocol https :inherit t :depth treeless :ref
                       "77115afc1b0b9f633084cf7479c767988106c196"))
 (aio :source "elpaca-menu-lock-file" :recipe
      (:package "aio" :fetcher github :repo "skeeto/emacs-aio" :files
                ("aio.el" "README.md" "UNLICENSE") :source "MELPA" :id
                aio :type git :protocol https :inherit t :depth
                treeless :ref
                "0e94a06bb035953cbbb4242568b38ca15443ad4c"))
 (apheleia :source "elpaca-menu-lock-file" :recipe
           (:package "apheleia" :fetcher github :repo
                     "radian-software/apheleia" :files
                     (:defaults ("scripts" "scripts/formatters"))
                     :source "MELPA" :id apheleia :type git :protocol
                     https :inherit t :depth treeless :ref
                     "14a0bb4454fb2cc3b5b377619288b742ce117da5"))
 (avy :source "elpaca-menu-lock-file" :recipe
      (:package "avy" :repo "abo-abo/avy" :fetcher github :files
                ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
                 "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
                 "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
                 "docs/*.texinfo"
                 (:exclude ".dir-locals.el" "test.el" "tests.el"
                           "*-test.el" "*-tests.el" "LICENSE"
                           "README*" "*-pkg.el"))
                :source "MELPA" :id avy :type git :protocol https
                :inherit t :depth treeless :ref
                "933d1f36cca0f71e4acb5fac707e9ae26c536264"))
 (buffer-name-relative :source "elpaca-menu-lock-file" :recipe
                       (:package "buffer-name-relative" :fetcher
                                 codeberg :repo
                                 "ideasman42/emacs-buffer-name-relative"
                                 :files
                                 ("*.el" "*.el.in" "dir" "*.info"
                                  "*.texi" "*.texinfo" "doc/dir"
                                  "doc/*.info" "doc/*.texi"
                                  "doc/*.texinfo" "lisp/*.el"
                                  "docs/dir" "docs/*.info"
                                  "docs/*.texi" "docs/*.texinfo"
                                  (:exclude ".dir-locals.el" "test.el"
                                            "tests.el" "*-test.el"
                                            "*-tests.el" "LICENSE"
                                            "README*" "*-pkg.el"))
                                 :source "MELPA" :id
                                 buffer-name-relative :type git
                                 :protocol https :inherit t :depth
                                 treeless :ref
                                 "a2e902c04ab68ec52b7c721d89a999f8eb2daae2"))
 (bufferlo :source "elpaca-menu-lock-file" :recipe
           (:package "bufferlo" :repo
                     ("https://github.com/florommel/bufferlo"
                      . "bufferlo")
                     :tar "1.2" :host gnu :files
                     ("*" (:exclude ".git")) :source "GNU ELPA" :id
                     bufferlo :type git :protocol https :inherit t
                     :depth treeless :ref
                     "1ab597c021ee33511fdaad942cc6dd5ac064f6ba"))
 (cape :source "elpaca-menu-lock-file" :recipe
       (:package "cape" :repo "minad/cape" :fetcher github :files
                 ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
                  "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
                  "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
                  "docs/*.texinfo"
                  (:exclude ".dir-locals.el" "test.el" "tests.el"
                            "*-test.el" "*-tests.el" "LICENSE"
                            "README*" "*-pkg.el"))
                 :source "MELPA" :id cape :type git :protocol https
                 :inherit t :depth treeless :ref
                 "5a3aa3058eb47bd10ae72c8919921e3fb40952a5"))
 (casual :source "elpaca-menu-lock-file" :recipe
         (:package "casual" :fetcher github :repo
                   "kickingvegas/casual" :old-names
                   (casual-agenda casual-bookmarks casual-calc
                                  casual-dired casual-editkit
                                  casual-ibuffer casual-info
                                  casual-isearch cc-isearch-menu
                                  casual-lib casual-re-builder)
                   :files (:defaults "docs/images") :source "MELPA"
                   :id casual :type git :protocol https :inherit t
                   :depth treeless :ref
                   "cadbeab2ec45804e63a328202c9a82fbed2413c5"))
 (clipetty :source "elpaca-menu-lock-file" :recipe
           (:package "clipetty" :repo "spudlyo/clipetty" :fetcher
                     github :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id clipetty :type git :protocol
                     https :inherit t :depth treeless :ref
                     "01b39044b9b65fa4ea7d3166f8b1ffab6f740362"))
 (comint-histories :source "elpaca-menu-lock-file" :recipe
                   (:package "comint-histories" :fetcher github :repo
                             "NicholasBHubbard/comint-histories"
                             :files
                             ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                              "*.texinfo" "doc/dir" "doc/*.info"
                              "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                              "docs/dir" "docs/*.info" "docs/*.texi"
                              "docs/*.texinfo"
                              (:exclude ".dir-locals.el" "test.el"
                                        "tests.el" "*-test.el"
                                        "*-tests.el" "LICENSE"
                                        "README*" "*-pkg.el"))
                             :source "MELPA" :id comint-histories
                             :type git :protocol https :inherit t
                             :depth treeless :ref
                             "e13c5ac7f812bc6f7da57c4640600b97356bd02b"))
 (compat :source "elpaca-menu-lock-file" :recipe
         (:package "compat" :repo
                   ("https://github.com/emacs-compat/compat"
                    . "compat")
                   :tar "31.0.0.2" :host gnu :files
                   ("*" (:exclude ".git")) :source "GNU ELPA" :id
                   compat :type git :protocol https :inherit t :depth
                   treeless :ref
                   "1f3d7596173cf2851d3c4181b15d6c3573a38252"))
 (cond-let
   :source "elpaca-menu-lock-file" :recipe
   (:package "cond-let" :fetcher github :repo "tarsius/cond-let"
             :files
             ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
              "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
              "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
              "docs/*.texinfo"
              (:exclude ".dir-locals.el" "test.el" "tests.el"
                        "*-test.el" "*-tests.el" "LICENSE" "README*"
                        "*-pkg.el"))
             :source "MELPA" :id cond-let :type git :protocol https
             :inherit t :depth treeless :ref
             "c48600dfab6372670225f046cace263700c78eab"))
 (consult :source "elpaca-menu-lock-file" :recipe
          (:package "consult" :repo "minad/consult" :fetcher github
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id consult :type git :protocol
                    https :inherit t :depth treeless :ref
                    "6af0dc99ff8eb8da3ca24bf9abd9a72354dcc5e1"))
 (consult-denote :source "elpaca-menu-lock-file" :recipe
                 (:package "consult-denote" :repo
                           ("https://github.com/protesilaos/consult-denote"
                            . "consult-denote")
                           :tar "0.5.1" :host gnu :files
                           ("*" (:exclude ".git")) :source "GNU ELPA"
                           :id consult-denote :type git :protocol
                           https :inherit t :depth treeless :ref
                           "0fbd723e7f4d824902b0a4b712b92c66a1eaf97e"))
 (consult-dir :source "elpaca-menu-lock-file" :recipe
              (:package "consult-dir" :fetcher github :repo
                        "karthink/consult-dir" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id consult-dir :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "1497b46d6f48da2d884296a1297e5ace1e050eb5"))
 (consult-yasnippet :source "elpaca-menu-lock-file" :recipe
                    (:package "consult-yasnippet" :fetcher github
                              :repo "mohkale/consult-yasnippet" :files
                              ("*.el" "*.el.in" "dir" "*.info"
                               "*.texi" "*.texinfo" "doc/dir"
                               "doc/*.info" "doc/*.texi"
                               "doc/*.texinfo" "lisp/*.el" "docs/dir"
                               "docs/*.info" "docs/*.texi"
                               "docs/*.texinfo"
                               (:exclude ".dir-locals.el" "test.el"
                                         "tests.el" "*-test.el"
                                         "*-tests.el" "LICENSE"
                                         "README*" "*-pkg.el"))
                              :source "MELPA" :id consult-yasnippet
                              :type git :protocol https :inherit t
                              :depth treeless :ref
                              "89e39887c87e25d18861216a4d72e5d174f13751"))
 (corfu :source "elpaca-menu-lock-file" :recipe
        (:package "corfu" :repo "minad/corfu" :files
                  (:defaults "extensions/corfu-*.el") :fetcher github
                  :source "MELPA" :id corfu :type git :protocol https
                  :inherit t :depth treeless :ref
                  "f6306d8c5ba540e75c208c8069b3b677de48a183"))
 (corfu-terminal :source "elpaca-menu-lock-file" :recipe
                 (:package "corfu-terminal" :repo
                           ("https://codeberg.org/akib/emacs-corfu-terminal"
                            . "corfu-terminal")
                           :tar "0.7" :host nongnu :files
                           ("*" (:exclude ".git")) :source
                           "NonGNU ELPA" :id corfu-terminal :type git
                           :protocol https :inherit t :depth treeless
                           :ref
                           "501548c3d51f926c687e8cd838c5865ec45d03cc"))
 (csv-mode :source "elpaca-menu-lock-file" :recipe
           (:package "csv-mode" :repo
                     ("https://github.com/emacsmirror/gnu_elpa"
                      . "csv-mode")
                     :tar "1.27" :host gnu :branch
                     "externals/csv-mode" :files
                     ("*" (:exclude ".git")) :source "GNU ELPA" :id
                     csv-mode :type git :protocol https :inherit t
                     :depth treeless :ref
                     "3a441a41a3b1d61c2a9c9f5f091cb38ba6b45d47"))
 (dape :source "elpaca-menu-lock-file" :recipe
       (:package "dape" :repo
                 ("https://github.com/svaante/dape" . "dape") :tar
                 "0.27.1" :host gnu :files ("*" (:exclude ".git"))
                 :source "GNU ELPA" :id dape :type git :protocol https
                 :inherit t :depth treeless :ref
                 "b04e927abac6fcbef480c8a39881d69baa1bec98"))
 (dash :source "elpaca-menu-lock-file" :recipe
       (:package "dash" :fetcher github :repo "magnars/dash.el" :files
                 ("dash.el" "dash.texi") :source "MELPA" :id dash
                 :type git :protocol https :inherit t :depth treeless
                 :ref "d3a84021dbe48dba63b52ef7665651e0cf02e915"))
 (denote :source "elpaca-menu-lock-file" :recipe
         (:package "denote" :repo
                   ("https://github.com/protesilaos/denote" . "denote")
                   :tar "4.2.3" :host gnu :files
                   ("*" (:exclude ".git" "COPYING" "doclicense.texi"))
                   :source "GNU ELPA" :id denote :type git :protocol
                   https :inherit t :depth treeless :ref
                   "3718a603056985c0832705d4f41eea944ed5031e"))
 (detached :source "elpaca-menu-lock-file" :recipe
           (:package "detached" :fetcher sourcehut :repo
                     "sourya7/detached.el" :old-names (dtache) :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id detached :host github :type
                     git :protocol https :inherit t :depth treeless
                     :ref "567ab3b87a10277231f627f95879298513f24fd5"))
 (devdocs :source "elpaca-menu-lock-file" :recipe
          (:package "devdocs" :fetcher github :repo
                    "astoff/devdocs.el" :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id devdocs :type git :protocol
                    https :inherit t :depth treeless :ref
                    "25c746024ddf73570195bf42b841f761a2fee10c"))
 (diff-hl :source "elpaca-menu-lock-file" :recipe
          (:package "diff-hl" :fetcher github :repo "dgutov/diff-hl"
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id diff-hl :type git :protocol
                    https :inherit t :depth treeless :ref
                    "91fcd4fa42fef895a754e80c4435ae6314be7822"))
 (difftastic :source "elpaca-menu-lock-file" :recipe
             (:package "difftastic" :fetcher github :repo
                       "pkryger/difftastic.el" :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id difftastic :type git
                       :protocol https :inherit t :depth treeless :ref
                       "f94076985ba46bf629abc9615c9b1fefcc3390ef"))
 (diminish :source "elpaca-menu-lock-file" :recipe
           (:package "diminish" :fetcher github :repo
                     "myrjola/diminish.el" :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id diminish :type git :protocol
                     https :inherit t :depth treeless :ref
                     "fbd5d846611bad828e336b25d2e131d1bc06b83d"))
 (dired-hacks-utils :source "elpaca-menu-lock-file" :recipe
                    (:package "dired-hacks-utils" :fetcher github
                              :repo "Fuco1/dired-hacks" :files
                              ("dired-hacks-utils.el") :source "MELPA"
                              :id dired-hacks-utils :type git
                              :protocol https :inherit t :depth
                              treeless :ref
                              "de9336f4b47ef901799fe95315fa080fa6d77b48"))
 (dired-open :source "elpaca-menu-lock-file" :recipe
             (:package "dired-open" :fetcher github :repo
                       "Fuco1/dired-hacks" :files ("dired-open.el")
                       :source "MELPA" :id dired-open :type git
                       :protocol https :inherit t :depth treeless :ref
                       "de9336f4b47ef901799fe95315fa080fa6d77b48"))
 (dired-subtree :source "elpaca-menu-lock-file" :recipe
                (:package "dired-subtree" :fetcher github :repo
                          "Fuco1/dired-hacks" :files
                          ("dired-subtree.el") :source "MELPA" :id
                          dired-subtree :type git :protocol https
                          :inherit t :depth treeless :ref
                          "de9336f4b47ef901799fe95315fa080fa6d77b48"))
 (docker :source "elpaca-menu-lock-file" :recipe
         (:package "docker" :fetcher github :repo "Silex/docker.el"
                   :files
                   ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                    "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                    "doc/*.texinfo" "lisp/*.el" "docs/dir"
                    "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                    (:exclude ".dir-locals.el" "test.el" "tests.el"
                              "*-test.el" "*-tests.el" "LICENSE"
                              "README*" "*-pkg.el"))
                   :source "MELPA" :id docker :type git :protocol
                   https :inherit t :depth treeless :ref
                   "f32940100035438934d626adb99cfc63036de490"))
 (dockerfile-mode :source "elpaca-menu-lock-file" :recipe
                  (:package "dockerfile-mode" :fetcher github :repo
                            "spotify/dockerfile-mode" :files
                            ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                             "*.texinfo" "doc/dir" "doc/*.info"
                             "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                             "docs/dir" "docs/*.info" "docs/*.texi"
                             "docs/*.texinfo"
                             (:exclude ".dir-locals.el" "test.el"
                                       "tests.el" "*-test.el"
                                       "*-tests.el" "LICENSE"
                                       "README*" "*-pkg.el"))
                            :source "MELPA" :id dockerfile-mode :type
                            git :protocol https :inherit t :depth
                            treeless :ref
                            "97733ce074b1252c1270fd5e8a53d178b66668ed"))
 (doom-modeline :source "elpaca-menu-lock-file" :recipe
                (:package "doom-modeline" :repo
                          "seagle0128/doom-modeline" :fetcher github
                          :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id doom-modeline :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "017854c6484dd6a38e4b039dad04ce6dbec02f08"))
 (doom-themes :source "elpaca-menu-lock-file" :recipe
              (:package "doom-themes" :fetcher github :repo
                        "doomemacs/themes" :files
                        (:defaults "themes/*.el" "themes/*/*.el"
                                   "extensions/*.el")
                        :source "MELPA" :id doom-themes :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "cc7686783e5e6e4174a345c768047d524f0dd54f"))
 (dumb-jump :source "elpaca-menu-lock-file" :recipe
            (:package "dumb-jump" :repo "jacktasia/dumb-jump" :fetcher
                      github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id dumb-jump :type git
                      :protocol https :inherit t :depth treeless :ref
                      "cf06b4ccdce6a39346c32f05139f9ee8b77ee229"))
 (elfeed :source "elpaca-menu-lock-file" :recipe
         (:package "elfeed" :fetcher github :repo
                   "emacs-elfeed/elfeed" :files
                   (:defaults "README.md") :source "MELPA" :id elfeed
                   :type git :protocol https :inherit t :depth
                   treeless :ref
                   "bbb3cac27b0412d80b327b5cfaab83683c96a2a1"))
 (elfeed-goodies :source "elpaca-menu-lock-file" :recipe
                 (:package "elfeed-goodies" :repo
                           "jeetelongname/elfeed-goodies" :fetcher
                           github :files
                           ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                            "*.texinfo" "doc/dir" "doc/*.info"
                            "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                            "docs/dir" "docs/*.info" "docs/*.texi"
                            "docs/*.texinfo"
                            (:exclude ".dir-locals.el" "test.el"
                                      "tests.el" "*-test.el"
                                      "*-tests.el" "LICENSE" "README*"
                                      "*-pkg.el"))
                           :source "MELPA" :id elfeed-goodies :type
                           git :protocol https :inherit t :depth
                           treeless :ref
                           "544ef42ead011d960a0ad1c1d34df5d222461a6b"))
 (elisp-refs :source "elpaca-menu-lock-file" :recipe
             (:package "elisp-refs" :repo "Wilfred/elisp-refs"
                       :fetcher github :files
                       (:defaults (:exclude "elisp-refs-bench.el"))
                       :source "MELPA" :id elisp-refs :type git
                       :protocol https :inherit t :depth treeless :ref
                       "541a064c3ce27867872cf708354a65d83baf2a6d"))
 (elpaca :source
   "elpaca-menu-lock-file" :recipe
   (:source nil :package "elpaca" :id elpaca :repo
            "https://github.com/progfolio/elpaca.git" :ref
            "6530ffa73b18ccee858e7c471415ab7e0c0d8ce1" :depth 1
            :inherit ignore :files
            (:defaults "elpaca-test.el" (:exclude "extensions"))
            :build (:not elpaca-activate) :type git :protocol https))
 (elpaca-use-package :source "elpaca-menu-lock-file" :recipe
                     (:package "elpaca-use-package" :wait t :repo
                               "https://github.com/progfolio/elpaca.git"
                               :files
                               ("extensions/elpaca-use-package.el")
                               :main
                               "extensions/elpaca-use-package.el"
                               :build
                               (:not elpaca-source elpaca-build-docs)
                               :source "Elpaca extensions" :id
                               elpaca-use-package :type git :protocol
                               https :inherit t :depth treeless :ref
                               "6530ffa73b18ccee858e7c471415ab7e0c0d8ce1"))
 (embark :source "elpaca-menu-lock-file" :recipe
         (:package "embark" :repo "oantolin/embark" :fetcher github
                   :files ("embark.el" "embark-org.el" "embark.texi")
                   :source "MELPA" :id embark :type git :protocol
                   https :inherit t :depth treeless :ref
                   "350ca86924c5027e80875943fba7b912a71e5791"))
 (embark-consult :source "elpaca-menu-lock-file" :recipe
                 (:package "embark-consult" :repo "oantolin/embark"
                           :fetcher github :files
                           ("embark-consult.el") :source "MELPA" :id
                           embark-consult :type git :protocol https
                           :inherit t :depth treeless :ref
                           "350ca86924c5027e80875943fba7b912a71e5791"))
 (envrc :source "elpaca-menu-lock-file" :recipe
        (:package "envrc" :fetcher github :repo "purcell/envrc" :files
                  ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                   "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                   "doc/*.texinfo" "lisp/*.el" "docs/dir"
                   "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                   (:exclude ".dir-locals.el" "test.el" "tests.el"
                             "*-test.el" "*-tests.el" "LICENSE"
                             "README*" "*-pkg.el"))
                  :source "MELPA" :id envrc :type git :protocol https
                  :inherit t :depth treeless :ref
                  "60820285aeed4f87969d663a1c14a905c7bb763a"))
 (eshell-prompt-extras :source "elpaca-menu-lock-file" :recipe
                       (:package "eshell-prompt-extras" :fetcher
                                 github :repo
                                 "suzzvv/eshell-prompt-extras" :files
                                 ("*.el" "*.el.in" "dir" "*.info"
                                  "*.texi" "*.texinfo" "doc/dir"
                                  "doc/*.info" "doc/*.texi"
                                  "doc/*.texinfo" "lisp/*.el"
                                  "docs/dir" "docs/*.info"
                                  "docs/*.texi" "docs/*.texinfo"
                                  (:exclude ".dir-locals.el" "test.el"
                                            "tests.el" "*-test.el"
                                            "*-tests.el" "LICENSE"
                                            "README*" "*-pkg.el"))
                                 :source "MELPA" :id
                                 eshell-prompt-extras :type git
                                 :protocol https :inherit t :depth
                                 treeless :ref
                                 "36504072605a2044cf291d1c2ea987cb898c6394"))
 (eshell-syntax-highlighting :source "elpaca-menu-lock-file" :recipe
                             (:package "eshell-syntax-highlighting"
                                       :fetcher github :repo
                                       "akreisher/eshell-syntax-highlighting"
                                       :files
                                       ("*.el" "*.el.in" "dir"
                                        "*.info" "*.texi" "*.texinfo"
                                        "doc/dir" "doc/*.info"
                                        "doc/*.texi" "doc/*.texinfo"
                                        "lisp/*.el" "docs/dir"
                                        "docs/*.info" "docs/*.texi"
                                        "docs/*.texinfo"
                                        (:exclude ".dir-locals.el"
                                                  "test.el" "tests.el"
                                                  "*-test.el"
                                                  "*-tests.el"
                                                  "LICENSE" "README*"
                                                  "*-pkg.el"))
                                       :source "MELPA" :id
                                       eshell-syntax-highlighting
                                       :type git :protocol https
                                       :inherit t :depth treeless :ref
                                       "62418fd8b2380114a3f6dad699c1ba45329db1d2"))
 (esxml :source "elpaca-menu-lock-file" :recipe
        (:package "esxml" :fetcher github :repo "tali713/esxml" :files
                  ("esxml.el" "esxml-query.el") :source "MELPA" :id
                  esxml :type git :protocol https :inherit t :depth
                  treeless :ref
                  "6a375888a74b7563eb53176aad81faee8b858189"))
 (evil :source "elpaca-menu-lock-file" :recipe
       (:package "evil" :repo "emacs-evil/evil" :fetcher github :files
                 (:defaults "doc/build/texinfo/evil.texi"
                            (:exclude "evil-test-helpers.el"))
                 :source "MELPA" :id evil :type git :protocol https
                 :inherit t :depth treeless :ref
                 "6a3e1ddd04ac504a016590940d0af2a3361b9efd"))
 (evil-cleverparens :source "elpaca-menu-lock-file" :recipe
                    (:package "evil-cleverparens" :fetcher github
                              :repo "emacs-evil/evil-cleverparens"
                              :files
                              ("*.el" "*.el.in" "dir" "*.info"
                               "*.texi" "*.texinfo" "doc/dir"
                               "doc/*.info" "doc/*.texi"
                               "doc/*.texinfo" "lisp/*.el" "docs/dir"
                               "docs/*.info" "docs/*.texi"
                               "docs/*.texinfo"
                               (:exclude ".dir-locals.el" "test.el"
                                         "tests.el" "*-test.el"
                                         "*-tests.el" "LICENSE"
                                         "README*" "*-pkg.el"))
                              :source "MELPA" :id evil-cleverparens
                              :type git :protocol https :inherit t
                              :depth treeless :ref
                              "4c413a132934695b975004d429b0b0a6e3d8ca38"))
 (evil-collection :source "elpaca-menu-lock-file" :recipe
                  (:package "evil-collection" :fetcher github :repo
                            "emacs-evil/evil-collection" :files
                            (:defaults "modes") :source "MELPA" :id
                            evil-collection :type git :protocol https
                            :inherit t :depth treeless :ref
                            "fa8da0ebba4bbf2a84a78183420d8303179ef427"))
 (evil-indent-plus :source "elpaca-menu-lock-file" :recipe
                   (:package "evil-indent-plus" :fetcher github :repo
                             "TheBB/evil-indent-plus" :files
                             ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                              "*.texinfo" "doc/dir" "doc/*.info"
                              "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                              "docs/dir" "docs/*.info" "docs/*.texi"
                              "docs/*.texinfo"
                              (:exclude ".dir-locals.el" "test.el"
                                        "tests.el" "*-test.el"
                                        "*-tests.el" "LICENSE"
                                        "README*" "*-pkg.el"))
                             :source "MELPA" :id evil-indent-plus
                             :type git :protocol https :inherit t
                             :depth treeless :ref
                             "f392696e4813f1d3a92c7eeed333248914ba6dae"))
 (evil-org :source "elpaca-menu-lock-file" :recipe
           (:package "evil-org" :fetcher github :repo
                     "Somelauw/evil-org-mode" :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id evil-org :type git :protocol
                     https :inherit t :depth treeless :ref
                     "b1f309726b1326e1a103742524ec331789f2bf94"))
 (evil-surround :source "elpaca-menu-lock-file" :recipe
                (:package "evil-surround" :repo
                          "emacs-evil/evil-surround" :fetcher github
                          :old-names (surround) :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id evil-surround :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "e6548372e8359ee55e67d73ca418314086011f1a"))
 (exec-path-from-shell :source "elpaca-menu-lock-file" :recipe
                       (:package "exec-path-from-shell" :fetcher
                                 github :repo
                                 "purcell/exec-path-from-shell" :files
                                 ("*.el" "*.el.in" "dir" "*.info"
                                  "*.texi" "*.texinfo" "doc/dir"
                                  "doc/*.info" "doc/*.texi"
                                  "doc/*.texinfo" "lisp/*.el"
                                  "docs/dir" "docs/*.info"
                                  "docs/*.texi" "docs/*.texinfo"
                                  (:exclude ".dir-locals.el" "test.el"
                                            "tests.el" "*-test.el"
                                            "*-tests.el" "LICENSE"
                                            "README*" "*-pkg.el"))
                                 :source "MELPA" :id
                                 exec-path-from-shell :wait t :type
                                 git :protocol https :inherit t :depth
                                 treeless :ref
                                 "7552abf032a383ff761e7d90e6b5cbb4658a728a"))
 (f :source "elpaca-menu-lock-file" :recipe
    (:package "f" :fetcher github :repo "rejeep/f.el" :files
              ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
               "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
               "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
               "docs/*.texinfo"
               (:exclude ".dir-locals.el" "test.el" "tests.el"
                         "*-test.el" "*-tests.el" "LICENSE" "README*"
                         "*-pkg.el"))
              :source "MELPA" :id f :type git :protocol https :inherit
              t :depth treeless :ref
              "931b6d0667fe03e7bf1c6c282d6d8d7006143c52"))
 (flycheck :source "elpaca-menu-lock-file" :recipe
           (:package "flycheck" :repo "flycheck/flycheck" :fetcher
                     github :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id flycheck :type git :protocol
                     https :inherit t :depth treeless :ref
                     "62e8f1cf99ac9b67b62cf205affb0260c8838a10"))
 (general :source "elpaca-menu-lock-file" :recipe
          (:package "general" :fetcher github :repo
                    "noctuid/general.el" :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id general :wait t :type git
                    :protocol https :inherit t :depth treeless :ref
                    "a48768f85a655fe77b5f45c2880b420da1b1b9c3"))
 (git-link :source "elpaca-menu-lock-file" :recipe
           (:package "git-link" :fetcher github :repo "sshaw/git-link"
                     :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id git-link :type git :protocol
                     https :inherit t :depth treeless :ref
                     "ca01d013bd575710e2cd47001ee1ef6ee41667cf"))
 (git-timemachine :source "elpaca-menu-lock-file" :recipe
                  (:package "git-timemachine" :fetcher codeberg :repo
                            "pidu/git-timemachine" :files
                            ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                             "*.texinfo" "doc/dir" "doc/*.info"
                             "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                             "docs/dir" "docs/*.info" "docs/*.texi"
                             "docs/*.texinfo"
                             (:exclude ".dir-locals.el" "test.el"
                                       "tests.el" "*-test.el"
                                       "*-tests.el" "LICENSE"
                                       "README*" "*-pkg.el"))
                            :source "MELPA" :id git-timemachine :type
                            git :protocol https :inherit t :depth
                            treeless :ref
                            "d1346a76122595aeeb7ebb292765841c6cfd417b"))
 (go-mode :source "elpaca-menu-lock-file" :recipe
          (:package "go-mode" :repo "dominikh/go-mode.el" :fetcher
                    github :files ("go-mode.el") :source "MELPA" :id
                    go-mode :type git :protocol https :inherit t
                    :depth treeless :ref
                    "3a71d28ab47df685e54ca6046a7a3dd3e28b682c"))
 (goto-chg :source "elpaca-menu-lock-file" :recipe
           (:package "goto-chg" :repo "emacs-evil/goto-chg" :fetcher
                     github :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id goto-chg :type git :protocol
                     https :inherit t :depth treeless :ref
                     "72f556524b88e9d30dc7fc5b0dc32078c166fda7"))
 (helpful :source "elpaca-menu-lock-file" :recipe
          (:package "helpful" :repo "Wilfred/helpful" :fetcher github
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id helpful :type git :protocol
                    https :inherit t :depth treeless :ref
                    "03756fa6ad4dcca5e0920622b1ee3f70abfc4e39"))
 (hl-todo :source "elpaca-menu-lock-file" :recipe
          (:package "hl-todo" :fetcher github :repo "tarsius/hl-todo"
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id hl-todo :type git :protocol
                    https :inherit t :depth treeless :ref
                    "527d545b8c2f36243194cbe4a8d0e6ac9d50e6a7"))
 (ibuffer-vc :source "elpaca-menu-lock-file" :recipe
             (:package "ibuffer-vc" :repo "purcell/ibuffer-vc"
                       :fetcher github :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id ibuffer-vc :type git
                       :protocol https :inherit t :depth treeless :ref
                       "11f2d44a280728e963d81b28455f1c6091718120"))
 (inheritenv :source "elpaca-menu-lock-file" :recipe
             (:package "inheritenv" :fetcher github :repo
                       "purcell/inheritenv" :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id inheritenv :type git
                       :protocol https :inherit t :depth treeless :ref
                       "b9e67cc20c069539698a9ac54d0e6cc11e616c6f"))
 (inhibit-mouse :source "elpaca-menu-lock-file" :recipe
                (:package "inhibit-mouse" :fetcher github :repo
                          "jamescherti/inhibit-mouse.el" :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id inhibit-mouse :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "0bda8fe615b093b837d78ccb110d3d37e81641a8"))
 (json-mode :source "elpaca-menu-lock-file" :recipe
            (:package "json-mode" :fetcher github :repo
                      "json-emacs/json-mode" :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id json-mode :type git
                      :protocol https :inherit t :depth treeless :ref
                      "466d5b563721bbeffac3f610aefaac15a39d90a9"))
 (json-snatcher :source "elpaca-menu-lock-file" :recipe
                (:package "json-snatcher" :fetcher github :repo
                          "Sterlingg/json-snatcher" :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id json-snatcher :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "b28d1c0670636da6db508d03872d96ffddbc10f2"))
 (jsonnet-mode :source "elpaca-menu-lock-file" :recipe
               (:package "jsonnet-mode" :fetcher github :repo
                         "tminor/jsonnet-mode" :files
                         ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                          "*.texinfo" "doc/dir" "doc/*.info"
                          "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                          "docs/dir" "docs/*.info" "docs/*.texi"
                          "docs/*.texinfo"
                          (:exclude ".dir-locals.el" "test.el"
                                    "tests.el" "*-test.el"
                                    "*-tests.el" "LICENSE" "README*"
                                    "*-pkg.el"))
                         :source "MELPA" :id jsonnet-mode :type git
                         :protocol https :inherit t :depth treeless
                         :ref
                         "00229c2f04bb4be26686eb325303865dac3cabf8"))
 (just-mode :source "elpaca-menu-lock-file" :recipe
            (:package "just-mode" :repo "leon-barrett/just-mode.el"
                      :fetcher github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id just-mode :type git
                      :protocol https :inherit t :depth treeless :ref
                      "5513ab0350d2701a94deb8cafef57d3c369a5e9b"))
 (just-ts-mode :source "elpaca-menu-lock-file" :recipe
               (:package "just-ts-mode" :fetcher github :repo
                         "leon-barrett/just-ts-mode.el" :files
                         ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                          "*.texinfo" "doc/dir" "doc/*.info"
                          "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                          "docs/dir" "docs/*.info" "docs/*.texi"
                          "docs/*.texinfo"
                          (:exclude ".dir-locals.el" "test.el"
                                    "tests.el" "*-test.el"
                                    "*-tests.el" "LICENSE" "README*"
                                    "*-pkg.el"))
                         :source "MELPA" :id just-ts-mode :type git
                         :protocol https :inherit t :depth treeless
                         :ref
                         "6b4b23fcc6f0f0d0903e84c51771d43c06a00771"))
 (kdl-ts-mode :source "elpaca-menu-lock-file" :recipe
              (:source nil :package "kdl-ts-mode" :id kdl-ts-mode
                       :host github :repo "merrickluo/kdl-ts-mode"
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "90cf3a9934c066d8613dee94816aa59be3ed1d00"))
 (link-hint :source "elpaca-menu-lock-file" :recipe
            (:package "link-hint" :fetcher github :repo
                      "noctuid/link-hint.el" :version-regexp
                      "none-since-rename" :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id link-hint :type git
                      :protocol https :inherit t :depth treeless :ref
                      "8fda5dcb9caff5a3c49d22b82e570ac9e29af7dd"))
 (llama :source "elpaca-menu-lock-file" :recipe
        (:package "llama" :fetcher github :repo "tarsius/llama" :files
                  ("llama.el" ".dir-locals.el") :source "MELPA" :id
                  llama :type git :protocol https :inherit t :depth
                  treeless :ref
                  "4d4024048053b898a01521046e0f063ee47615b0"))
 (load-relative :source "elpaca-menu-lock-file" :recipe
                (:package "load-relative" :fetcher github :repo
                          "rocky/emacs-load-relative" :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id load-relative :wait t
                          :type git :protocol https :inherit t :depth
                          treeless :ref
                          "b7987c265a64435299d6b02f960ed2c894c4a145"))
 (magit :source "elpaca-menu-lock-file" :recipe
        (:package "magit" :fetcher github :repo "magit/magit" :files
                  ("lisp/magit*.el" "lisp/git-*.el" "docs/magit.texi"
                   "docs/AUTHORS.md" "LICENSE" ".dir-locals.el"
                   ("githooks" "githooks/*")
                   ("git-hooks" "git-hooks/*")
                   (:exclude "lisp/magit-section.el"))
                  :source "MELPA" :id magit :type git :protocol https
                  :inherit t :depth treeless :ref
                  "67f203853e74e926e2c99f60ed508840714f7ced"))
 (magit-section :source "elpaca-menu-lock-file" :recipe
                (:package "magit-section" :fetcher github :repo
                          "magit/magit" :files
                          ("lisp/magit-section.el"
                           "docs/magit-section.texi"
                           "magit-section-pkg.el")
                          :source "MELPA" :id magit-section :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "67f203853e74e926e2c99f60ed508840714f7ced"))
 (marginalia :source "elpaca-menu-lock-file" :recipe
             (:package "marginalia" :repo "minad/marginalia" :fetcher
                       github :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id marginalia :type git
                       :protocol https :inherit t :depth treeless :ref
                       "10b170ad8006bad535599e5b3e007e643e34345a"))
 (markdown-mode :source "elpaca-menu-lock-file" :recipe
                (:package "markdown-mode" :fetcher github :repo
                          "jrblevin/markdown-mode" :files
                          ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                           "*.texinfo" "doc/dir" "doc/*.info"
                           "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                           "docs/dir" "docs/*.info" "docs/*.texi"
                           "docs/*.texinfo"
                           (:exclude ".dir-locals.el" "test.el"
                                     "tests.el" "*-test.el"
                                     "*-tests.el" "LICENSE" "README*"
                                     "*-pkg.el"))
                          :source "MELPA" :id markdown-mode :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "f441e8bc9951e73b12c61e9198658488dd8e86e1"))
 (neotree :source "elpaca-menu-lock-file" :recipe
          (:package "neotree" :repo "jaypei/emacs-neotree" :fetcher
                    github :files (:defaults "icons") :source "MELPA"
                    :id neotree :type git :protocol https :inherit t
                    :depth treeless :ref
                    "3178805a0942696d1e5162575d9cab43d14b7970"))
 (nerd-icons :source "elpaca-menu-lock-file" :recipe
             (:package "nerd-icons" :repo
                       "rainstormstudio/nerd-icons.el" :fetcher github
                       :files (:defaults "data") :source "MELPA" :id
                       nerd-icons :type git :protocol https :inherit t
                       :depth treeless :ref
                       "674909974637ff0ec2b5ebf43f9a8aefa35d93e9"))
 (nerd-icons-completion :source "elpaca-menu-lock-file" :recipe
                        (:package "nerd-icons-completion" :repo
                                  "rainstormstudio/nerd-icons-completion"
                                  :fetcher github :files
                                  ("*.el" "*.el.in" "dir" "*.info"
                                   "*.texi" "*.texinfo" "doc/dir"
                                   "doc/*.info" "doc/*.texi"
                                   "doc/*.texinfo" "lisp/*.el"
                                   "docs/dir" "docs/*.info"
                                   "docs/*.texi" "docs/*.texinfo"
                                   (:exclude ".dir-locals.el"
                                             "test.el" "tests.el"
                                             "*-test.el" "*-tests.el"
                                             "LICENSE" "README*"
                                             "*-pkg.el"))
                                  :source "MELPA" :id
                                  nerd-icons-completion :type git
                                  :protocol https :inherit t :depth
                                  treeless :ref
                                  "45b585d972192a3eaeb239e15e55de7f46f8920a"))
 (nerd-icons-corfu :source "elpaca-menu-lock-file" :recipe
                   (:package "nerd-icons-corfu" :fetcher github :repo
                             "LuigiPiucco/nerd-icons-corfu" :files
                             ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                              "*.texinfo" "doc/dir" "doc/*.info"
                              "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                              "docs/dir" "docs/*.info" "docs/*.texi"
                              "docs/*.texinfo"
                              (:exclude ".dir-locals.el" "test.el"
                                        "tests.el" "*-test.el"
                                        "*-tests.el" "LICENSE"
                                        "README*" "*-pkg.el"))
                             :source "MELPA" :id nerd-icons-corfu
                             :type git :protocol https :inherit t
                             :depth treeless :ref
                             "f821e953b1a3dc9b381bc53486aabf366bf11cb1"))
 (nerd-icons-dired :source "elpaca-menu-lock-file" :recipe
                   (:package "nerd-icons-dired" :repo
                             "rainstormstudio/nerd-icons-dired"
                             :fetcher github :files
                             ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                              "*.texinfo" "doc/dir" "doc/*.info"
                              "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                              "docs/dir" "docs/*.info" "docs/*.texi"
                              "docs/*.texinfo"
                              (:exclude ".dir-locals.el" "test.el"
                                        "tests.el" "*-test.el"
                                        "*-tests.el" "LICENSE"
                                        "README*" "*-pkg.el"))
                             :source "MELPA" :id nerd-icons-dired
                             :type git :protocol https :inherit t
                             :depth treeless :ref
                             "104acd8879528b8115589f35f1bbcbe231ad732f"))
 (nix-mode :source "elpaca-menu-lock-file" :recipe
           (:package "nix-mode" :fetcher github :repo "NixOS/nix-mode"
                     :files
                     (:defaults
                      (:exclude "nix-company.el" "nix-mode-mmm.el"))
                     :source "MELPA" :id nix-mode :type git :protocol
                     https :inherit t :depth treeless :ref
                     "719feb7868fb567ecfe5578f6119892c771ac5e5"))
 (nix-ts-mode :source "elpaca-menu-lock-file" :recipe
              (:package "nix-ts-mode" :fetcher github :repo
                        "nix-community/nix-ts-mode" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id nix-ts-mode :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "3b69aeb8d2403ea52b60a46fa452965b7b37a50e"))
 (no-littering :source "elpaca-menu-lock-file" :recipe
               (:package "no-littering" :fetcher github :repo
                         "emacscollective/no-littering" :files
                         ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                          "*.texinfo" "doc/dir" "doc/*.info"
                          "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                          "docs/dir" "docs/*.info" "docs/*.texi"
                          "docs/*.texinfo"
                          (:exclude ".dir-locals.el" "test.el"
                                    "tests.el" "*-test.el"
                                    "*-tests.el" "LICENSE" "README*"
                                    "*-pkg.el"))
                         :source "MELPA" :id no-littering :wait t
                         :type git :protocol https :inherit t :depth
                         treeless :ref
                         "c949f327f417734005203769673e6f925877fa88"))
 (nov :source "elpaca-menu-lock-file" :recipe
      (:package "nov" :fetcher git :url
                "https://depp.brause.cc/nov.el.git" :files
                ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
                 "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
                 "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
                 "docs/*.texinfo"
                 (:exclude ".dir-locals.el" "test.el" "tests.el"
                           "*-test.el" "*-tests.el" "LICENSE"
                           "README*" "*-pkg.el"))
                :source "MELPA" :id nov :type git :protocol https
                :inherit t :depth treeless :ref
                "874daf5e4791a6d4f47741422c80e2736e907351"))
 (orderless :source "elpaca-menu-lock-file" :recipe
            (:package "orderless" :repo "oantolin/orderless" :fetcher
                      github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id orderless :type git
                      :protocol https :inherit t :depth treeless :ref
                      "0ffd9d6903714c1f6d8fcbb6a20941fb33dd7ae5"))
 (org-bullets :source "elpaca-menu-lock-file" :recipe
              (:package "org-bullets" :fetcher github :repo
                        "integral-dw/org-bullets" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id org-bullets :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "767f55feb58b840a5a04eabfc3fbbf0d257c4792"))
 (paredit :source "elpaca-menu-lock-file" :recipe
          (:package "paredit" :fetcher git :url
                    "https://paredit.org/paredit.git" :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id paredit :type git :protocol
                    https :inherit t :depth treeless :ref
                    "af075775af91f2dbc63b915d762b4aec092946c4"))
 (pdf-tools :source "elpaca-menu-lock-file" :recipe
            (:package "pdf-tools" :fetcher github :repo
                      "vedang/pdf-tools" :files
                      (:defaults "README" ("build" "Makefile")
                                 ("build" "server"))
                      :source "MELPA" :id pdf-tools :type git
                      :protocol https :inherit t :depth treeless :ref
                      "365f88238f46f9b1425685562105881800f10386"))
 (pdf-view-restore :source "elpaca-menu-lock-file" :recipe
                   (:package "pdf-view-restore" :repo
                             "007kevin/pdf-view-restore" :fetcher
                             github :files
                             ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                              "*.texinfo" "doc/dir" "doc/*.info"
                              "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                              "docs/dir" "docs/*.info" "docs/*.texi"
                              "docs/*.texinfo"
                              (:exclude ".dir-locals.el" "test.el"
                                        "tests.el" "*-test.el"
                                        "*-tests.el" "LICENSE"
                                        "README*" "*-pkg.el"))
                             :source "MELPA" :id pdf-view-restore
                             :type git :protocol https :inherit t
                             :depth treeless :ref
                             "5a1947c01a3edecc9e0fe7629041a2f53e0610c9"))
 (polymode :source "elpaca-menu-lock-file" :recipe
           (:package "polymode" :fetcher github :repo
                     "polymode/polymode" :files
                     ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                      "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                      "doc/*.texinfo" "lisp/*.el" "docs/dir"
                      "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                      (:exclude ".dir-locals.el" "test.el" "tests.el"
                                "*-test.el" "*-tests.el" "LICENSE"
                                "README*" "*-pkg.el"))
                     :source "MELPA" :id polymode :type git :protocol
                     https :inherit t :depth treeless :ref
                     "8cb72fa5dcc0d98746c680043dc121edc7621e3a"))
 (popon :source "elpaca-menu-lock-file" :recipe
        (:package "popon" :repo
                  ("https://codeberg.org/akib/emacs-popon" . "popon")
                  :tar "0.13" :host nongnu :files
                  ("*" (:exclude ".git")) :source "NonGNU ELPA" :id
                  popon :type git :protocol https :inherit t :depth
                  treeless :ref
                  "bf8174cb7e6e8fe0fe91afe6b01b6562c4dc39da"))
 (popwin :source "elpaca-menu-lock-file" :recipe
         (:package "popwin" :fetcher github :repo
                   "emacsorphanage/popwin" :files
                   ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                    "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                    "doc/*.texinfo" "lisp/*.el" "docs/dir"
                    "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                    (:exclude ".dir-locals.el" "test.el" "tests.el"
                              "*-test.el" "*-tests.el" "LICENSE"
                              "README*" "*-pkg.el"))
                   :source "MELPA" :id popwin :type git :protocol
                   https :inherit t :depth treeless :ref
                   "b67254bef763ffa5ab781460bc47d6adf6f87127"))
 (powerline :source "elpaca-menu-lock-file" :recipe
            (:package "powerline" :fetcher github :repo
                      "milkypostman/powerline" :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id powerline :type git
                      :protocol https :inherit t :depth treeless :ref
                      "c35c35bdf5ce2d992882c1f06f0f078058870d4a"))
 (rainbow-delimiters :source "elpaca-menu-lock-file" :recipe
                     (:package "rainbow-delimiters" :fetcher github
                               :repo "Fanael/rainbow-delimiters"
                               :files
                               ("*.el" "*.el.in" "dir" "*.info"
                                "*.texi" "*.texinfo" "doc/dir"
                                "doc/*.info" "doc/*.texi"
                                "doc/*.texinfo" "lisp/*.el" "docs/dir"
                                "docs/*.info" "docs/*.texi"
                                "docs/*.texinfo"
                                (:exclude ".dir-locals.el" "test.el"
                                          "tests.el" "*-test.el"
                                          "*-tests.el" "LICENSE"
                                          "README*" "*-pkg.el"))
                               :source "MELPA" :id rainbow-delimiters
                               :type git :protocol https :inherit t
                               :depth treeless :ref
                               "f40ece58df8b2f0fb6c8576b527755a552a5e763"))
 (rainbow-mode :source "elpaca-menu-lock-file" :recipe
               (:package "rainbow-mode" :repo
                         ("https://github.com/emacsmirror/gnu_elpa"
                          . "rainbow-mode")
                         :tar "1.0.6" :host gnu :branch
                         "externals/rainbow-mode" :files
                         ("*" (:exclude ".git")) :source "GNU ELPA"
                         :id rainbow-mode :type git :protocol https
                         :inherit t :depth treeless :ref
                         "f7db3b5919f70420a91eb199f8663468de3033f3"))
 (request :source "elpaca-menu-lock-file"
   :recipe
   (:package "request" :repo "tkf/emacs-request" :fetcher github
             :files ("request.el") :source "MELPA" :id request :type
             git :protocol https :inherit t :depth treeless :ref
             "c22e3c23a6dd90f64be536e176ea0ed6113a5ba6"))
 (rotate :source "elpaca-menu-lock-file" :recipe
         (:package "rotate" :fetcher github :repo
                   "daichirata/emacs-rotate" :files
                   ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                    "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                    "doc/*.texinfo" "lisp/*.el" "docs/dir"
                    "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                    (:exclude ".dir-locals.el" "test.el" "tests.el"
                              "*-test.el" "*-tests.el" "LICENSE"
                              "README*" "*-pkg.el"))
                   :source "MELPA" :id rotate :type git :protocol
                   https :inherit t :depth treeless :ref
                   "d61c7643b8dbe3fdd59f8ee40212f27bd14cfb61"))
 (s :source "elpaca-menu-lock-file" :recipe
    (:package "s" :fetcher github :repo "magnars/s.el" :files
              ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
               "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
               "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
               "docs/*.texinfo"
               (:exclude ".dir-locals.el" "test.el" "tests.el"
                         "*-test.el" "*-tests.el" "LICENSE" "README*"
                         "*-pkg.el"))
              :source "MELPA" :id s :type git :protocol https :inherit
              t :depth treeless :ref
              "7393fa6fa305403e628058c0ec78c35d610fab05"))
 (shrink-path :source "elpaca-menu-lock-file" :recipe
              (:package "shrink-path" :fetcher gitlab :repo
                        "bennya/shrink-path.el" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id shrink-path :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "c14882c8599aec79a6e8ef2d06454254bb3e1e41"))
 (shut-up
   :source "elpaca-menu-lock-file" :recipe
   (:package "shut-up" :fetcher github :repo "cask/shut-up" :files
             ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
              "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
              "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
              "docs/*.texinfo"
              (:exclude ".dir-locals.el" "test.el" "tests.el"
                        "*-test.el" "*-tests.el" "LICENSE" "README*"
                        "*-pkg.el"))
             :source "MELPA" :id shut-up :type git :protocol https
             :inherit t :depth treeless :ref
             "ed62a7fefdf04c81346061016f1bc69ca045aaf6"))
 (smart-jump :source "elpaca-menu-lock-file" :recipe
             (:package "smart-jump" :fetcher github :repo
                       "jojojames/smart-jump" :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id smart-jump :type git
                       :protocol https :inherit t :depth treeless :ref
                       "3392eb35e3cde37e6f5f2a48dc0db15ca535143c"))
 (smartparens :source "elpaca-menu-lock-file" :recipe
              (:package "smartparens" :fetcher github :repo
                        "Fuco1/smartparens" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id smartparens :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "82d2cf084a19b0c2c3812e0550721f8a61996056"))
 (string-edit-at-point :source "elpaca-menu-lock-file" :recipe
                       (:package "string-edit-at-point" :fetcher
                                 github :repo "magnars/string-edit.el"
                                 :old-names (string-edit) :files
                                 ("*.el" "*.el.in" "dir" "*.info"
                                  "*.texi" "*.texinfo" "doc/dir"
                                  "doc/*.info" "doc/*.texi"
                                  "doc/*.texinfo" "lisp/*.el"
                                  "docs/dir" "docs/*.info"
                                  "docs/*.texi" "docs/*.texinfo"
                                  (:exclude ".dir-locals.el" "test.el"
                                            "tests.el" "*-test.el"
                                            "*-tests.el" "LICENSE"
                                            "README*" "*-pkg.el"))
                                 :source "MELPA" :id
                                 string-edit-at-point :type git
                                 :protocol https :inherit t :depth
                                 treeless :ref
                                 "87936d816ae24184dd83688136531b6b6f1943fe"))
 (sudo-edit :source "elpaca-menu-lock-file" :recipe
            (:package "sudo-edit" :repo "nflath/sudo-edit" :fetcher
                      github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id sudo-edit :type git
                      :protocol https :inherit t :depth treeless :ref
                      "74eb1e6986461baed9a9269566ff838530b4379b"))
 (tablist :source "elpaca-menu-lock-file" :recipe
          (:package "tablist" :fetcher github :repo
                    "emacsorphanage/tablist" :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id tablist :type git :protocol
                    https :inherit t :depth treeless :ref
                    "01f065e387ffe6b7a41f180f257cd12551c7a9c2"))
 (toc-org :source "elpaca-menu-lock-file" :recipe
          (:package "toc-org" :fetcher github :repo "snosov1/toc-org"
                    :old-names (org-toc) :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id toc-org :type git :protocol
                    https :inherit t :depth treeless :ref
                    "69165018974a82b397d0869f0c7f0bf7d3b4ee07"))
 (transient :source "elpaca-menu-lock-file" :recipe
            (:package "transient" :fetcher github :repo
                      "magit/transient" :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id transient :type git
                      :protocol https :inherit t :depth treeless :ref
                      "9ba468bcbc7f6061c02a5319ff961f3e5ba6fa13"))
 (trashed :source "elpaca-menu-lock-file" :recipe
          (:package "trashed" :repo "shingo256/trashed" :fetcher
                    github :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id trashed :type git :protocol
                    https :inherit t :depth treeless :ref
                    "52a52a363ce53855790e7a59aed6976eec18c9ea"))
 (treesit-auto :source "elpaca-menu-lock-file" :recipe
               (:package "treesit-auto" :fetcher github :repo
                         "renzmann/treesit-auto" :files
                         ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                          "*.texinfo" "doc/dir" "doc/*.info"
                          "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                          "docs/dir" "docs/*.info" "docs/*.texi"
                          "docs/*.texinfo"
                          (:exclude ".dir-locals.el" "test.el"
                                    "tests.el" "*-test.el"
                                    "*-tests.el" "LICENSE" "README*"
                                    "*-pkg.el"))
                         :source "MELPA" :id treesit-auto :type git
                         :protocol https :inherit t :depth treeless
                         :ref
                         "31466e4ccfd4f896ce3145c95c4c1f8b59d4bfdf"))
 (undercover :source "elpaca-menu-lock-file" :recipe
             (:package "undercover" :fetcher github :repo
                       "undercover-el/undercover.el" :files
                       ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                        "*.texinfo" "doc/dir" "doc/*.info"
                        "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                        "docs/dir" "docs/*.info" "docs/*.texi"
                        "docs/*.texinfo"
                        (:exclude ".dir-locals.el" "test.el"
                                  "tests.el" "*-test.el" "*-tests.el"
                                  "LICENSE" "README*" "*-pkg.el"))
                       :source "MELPA" :id undercover :type git
                       :protocol https :inherit t :depth treeless :ref
                       "e7e280b3de48eec9db0e6044c15499a6ecb6268d"))
 (undo-fu :source "elpaca-menu-lock-file" :recipe
          (:package "undo-fu" :fetcher codeberg :repo
                    "ideasman42/emacs-undo-fu" :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "MELPA" :id undo-fu :type git :protocol
                    https :inherit t :depth treeless :ref
                    "5684ef2aef5f60176472916b21869cf221e018cc"))
 (undo-fu-session :source "elpaca-menu-lock-file" :recipe
                  (:package "undo-fu-session" :fetcher codeberg :repo
                            "ideasman42/emacs-undo-fu-session" :files
                            ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                             "*.texinfo" "doc/dir" "doc/*.info"
                             "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                             "docs/dir" "docs/*.info" "docs/*.texi"
                             "docs/*.texinfo"
                             (:exclude ".dir-locals.el" "test.el"
                                       "tests.el" "*-test.el"
                                       "*-tests.el" "LICENSE"
                                       "README*" "*-pkg.el"))
                            :source "MELPA" :id undo-fu-session :type
                            git :protocol https :inherit t :depth
                            treeless :ref
                            "92d733a5b162a70c572fac17b9f9e872426df547"))
 (vertico :source "elpaca-menu-lock-file" :recipe
          (:package "vertico" :repo "minad/vertico" :files
                    (:defaults "extensions/vertico-*.el") :fetcher
                    github :source "MELPA" :id vertico :type git
                    :protocol https :inherit t :depth treeless :ref
                    "77808caeaa658e95e04b1c6a519be1722e9f1a70"))
 (vim-tab-bar :source "elpaca-menu-lock-file" :recipe
              (:package "vim-tab-bar" :fetcher github :repo
                        "jamescherti/vim-tab-bar.el" :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id vim-tab-bar :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "c2f03438f62915e71a780ca1cb05b94fe2871a71"))
 (visual-fill-column :source "elpaca-menu-lock-file" :recipe
                     (:package "visual-fill-column" :fetcher codeberg
                               :repo "joostkremers/visual-fill-column"
                               :files
                               ("*.el" "*.el.in" "dir" "*.info"
                                "*.texi" "*.texinfo" "doc/dir"
                                "doc/*.info" "doc/*.texi"
                                "doc/*.texinfo" "lisp/*.el" "docs/dir"
                                "docs/*.info" "docs/*.texi"
                                "docs/*.texinfo"
                                (:exclude ".dir-locals.el" "test.el"
                                          "tests.el" "*-test.el"
                                          "*-tests.el" "LICENSE"
                                          "README*" "*-pkg.el"))
                               :source "MELPA" :id visual-fill-column
                               :type git :protocol https :inherit t
                               :depth treeless :ref
                               "e1be9a1545157d24454d950c0ac79553c540edb7"))
 (vterm :source "elpaca-menu-lock-file" :recipe
        (:package "vterm" :fetcher github :repo
                  "akermu/emacs-libvterm" :files
                  ("CMakeLists.txt" "elisp.c" "elisp.h"
                   "emacs-module.h" "etc" "utf8.c" "utf8.h" "vterm.el"
                   "vterm-module.c" "vterm-module.h")
                  :source "MELPA" :id vterm :type git :protocol https
                  :inherit t :depth treeless :ref
                  "70921114908ebb260d6686db8cbe2445a64f90a2"))
 (vterm-toggle :source "elpaca-menu-lock-file" :recipe
               (:package "vterm-toggle" :fetcher github :repo
                         "jixiuf/vterm-toggle" :files
                         ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                          "*.texinfo" "doc/dir" "doc/*.info"
                          "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                          "docs/dir" "docs/*.info" "docs/*.texi"
                          "docs/*.texinfo"
                          (:exclude ".dir-locals.el" "test.el"
                                    "tests.el" "*-test.el"
                                    "*-tests.el" "LICENSE" "README*"
                                    "*-pkg.el"))
                         :source "MELPA" :id vterm-toggle :type git
                         :protocol https :inherit t :depth treeless
                         :ref
                         "a0051a8b8eaa85f8df54ddb032f5710c1f62779d"))
 (vui :source "elpaca-menu-lock-file" :recipe
      (:package "vui" :fetcher github :repo "d12frosted/vui.el" :files
                ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
                 "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
                 "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
                 "docs/*.texinfo"
                 (:exclude ".dir-locals.el" "test.el" "tests.el"
                           "*-test.el" "*-tests.el" "LICENSE"
                           "README*" "*-pkg.el"))
                :source "MELPA" :id vui :type git :protocol https
                :inherit t :depth treeless :ref
                "9101db52a29c4276b45f85e63924008f0e41c39c"))
 (vundo :source "elpaca-menu-lock-file" :recipe
        (:package "vundo" :repo
                  ("https://github.com/casouri/vundo" . "vundo") :tar
                  "2.4.0" :host gnu :files
                  ("*" (:exclude ".git" "test")) :source "GNU ELPA"
                  :id vundo :type git :protocol https :inherit t
                  :depth treeless :ref
                  "e0af8c5845abf884a644215a9cac37f39c13cd5a"))
 (wgrep :source "elpaca-menu-lock-file" :recipe
        (:package "wgrep" :fetcher github :repo
                  "mhayashi1120/Emacs-wgrep" :files ("wgrep.el")
                  :source "MELPA" :id wgrep :type git :protocol https
                  :inherit t :depth treeless :ref
                  "49f09ab9b706d2312cab1199e1eeb1bcd3f27f6f"))
 (which-key :source "elpaca-menu-lock-file" :recipe
            (:package "which-key" :repo "justbur/emacs-which-key"
                      :fetcher github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id which-key :type git
                      :protocol https :inherit t :depth treeless :ref
                      "38d4308d1143b61e4004b6e7a940686784e51500"))
 (with-editor :source "elpaca-menu-lock-file"
   :recipe
   (:package "with-editor" :fetcher github :repo "magit/with-editor"
             :files
             ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
              "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
              "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
              "docs/*.texinfo"
              (:exclude ".dir-locals.el" "test.el" "tests.el"
                        "*-test.el" "*-tests.el" "LICENSE" "README*"
                        "*-pkg.el"))
             :source "MELPA" :id with-editor :type git :protocol https
             :inherit t :depth treeless :ref
             "a1f92a26e53033ec58e1d2ce9b132da7ebae816e"))
 (yaml-mode :source "elpaca-menu-lock-file" :recipe
            (:package "yaml-mode" :repo "yoshiki/yaml-mode" :fetcher
                      github :files
                      ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                       "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                       "doc/*.texinfo" "lisp/*.el" "docs/dir"
                       "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                       (:exclude ".dir-locals.el" "test.el" "tests.el"
                                 "*-test.el" "*-tests.el" "LICENSE"
                                 "README*" "*-pkg.el"))
                      :source "MELPA" :id yaml-mode :type git
                      :protocol https :inherit t :depth treeless :ref
                      "96ef0201101a7cd591febd5886633154dae8834c"))
 (yasnippet :source "elpaca-menu-lock-file" :recipe
            (:package "yasnippet" :fetcher github :repo
                      "joaotavora/yasnippet" :files
                      (:defaults ("doc" "doc/*.org")) :source "MELPA"
                      :id yasnippet :type git :protocol https :inherit
                      t :depth treeless :ref
                      "c1e6ff23e9af16b856c88dfaab9d3ad7b746ad37"))
 (zoxide :source "elpaca-menu-lock-file" :recipe
         (:package "zoxide" :fetcher sourcehut :repo
                   "vonfry/zoxide.el" :files
                   ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                    "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                    "doc/*.texinfo" "lisp/*.el" "docs/dir"
                    "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                    (:exclude ".dir-locals.el" "test.el" "tests.el"
                              "*-test.el" "*-tests.el" "LICENSE"
                              "README*" "*-pkg.el"))
                   :source "MELPA" :id zoxide :type git :protocol
                   https :inherit t :depth treeless :ref
                   "0ec359c83b041c8ffe2ec0e70b16c5d218d9bfd9")))
