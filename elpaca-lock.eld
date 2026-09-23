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
                     :source "elpaca-menu-lock-file" :id ace-link
                     :type git :protocol https :inherit t :depth
                     treeless :ref
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
                       :source "elpaca-menu-lock-file" :id ace-window
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "77115afc1b0b9f633084cf7479c767988106c196"))
 (aio :source "elpaca-menu-lock-file" :recipe
      (:package "aio" :fetcher github :repo "skeeto/emacs-aio" :files
                ("aio.el" "README.md" "UNLICENSE") :source
                "elpaca-menu-lock-file" :id aio :type git :protocol
                https :inherit t :depth treeless :ref
                "0e94a06bb035953cbbb4242568b38ca15443ad4c"))
 (apheleia :source "elpaca-menu-lock-file" :recipe
           (:package "apheleia" :fetcher github :repo
                     "radian-software/apheleia" :files
                     (:defaults ("scripts" "scripts/formatters"))
                     :source "elpaca-menu-lock-file" :id apheleia
                     :type git :protocol https :inherit t :depth
                     treeless :ref
                     "047119b7c6f18ffdbf5f88116a427f7e38653cc6"))
 (avy :source "elpaca-menu-lock-file" :recipe
      (:package "avy" :repo "abo-abo/avy" :fetcher github :files
                ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
                 "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
                 "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
                 "docs/*.texinfo"
                 (:exclude ".dir-locals.el" "test.el" "tests.el"
                           "*-test.el" "*-tests.el" "LICENSE"
                           "README*" "*-pkg.el"))
                :source "elpaca-menu-lock-file" :id avy :type git
                :protocol https :inherit t :depth treeless :ref
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
                                 :source "elpaca-menu-lock-file" :id
                                 buffer-name-relative :type git
                                 :protocol https :inherit t :depth
                                 treeless :ref
                                 "a2e902c04ab68ec52b7c721d89a999f8eb2daae2"))
 (bufferlo :source "elpaca-menu-lock-file" :recipe
           (:package "bufferlo" :repo
                     ("https://github.com/florommel/bufferlo"
                      . "bufferlo")
                     :tar "1.2" :host gnu :files
                     ("*" (:exclude ".git")) :source
                     "elpaca-menu-lock-file" :id bufferlo :type git
                     :protocol https :inherit t :depth treeless :ref
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
                 :source "elpaca-menu-lock-file" :id cape :type git
                 :protocol https :inherit t :depth treeless :ref
                 "1c543fce9151821e8400258aefcfdee2fb24920d"))
 (casual :source "elpaca-menu-lock-file" :recipe
         (:package "casual" :fetcher github :repo
                   "kickingvegas/casual" :old-names
                   (casual-agenda casual-bookmarks casual-calc
                                  casual-dired casual-editkit
                                  casual-ibuffer casual-info
                                  casual-isearch cc-isearch-menu
                                  casual-lib casual-re-builder)
                   :files (:defaults "docs/images") :source
                   "elpaca-menu-lock-file" :id casual :type git
                   :protocol https :inherit t :depth treeless :ref
                   "60259e256e34d4f6ae64ef950c740cacbe8b4d37"))
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
                     :source "elpaca-menu-lock-file" :id clipetty
                     :type git :protocol https :inherit t :depth
                     treeless :ref
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
                             :source "elpaca-menu-lock-file" :id
                             comint-histories :type git :protocol
                             https :inherit t :depth treeless :ref
                             "e13c5ac7f812bc6f7da57c4640600b97356bd02b"))
 (compat :source "elpaca-menu-lock-file" :recipe
         (:package "compat" :repo
                   ("https://github.com/emacs-compat/compat"
                    . "compat")
                   :tar "31.0.0.2" :host gnu :files
                   ("*" (:exclude ".git")) :source
                   "elpaca-menu-lock-file" :id compat :type git
                   :protocol https :inherit t :depth treeless :ref
                   "90880f81419577e1d3f68424d2a3adf31e6d663e"))
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
             :source "elpaca-menu-lock-file" :id cond-let :type git
             :protocol https :inherit t :depth treeless :ref
             "3b88187fe067d4ca3dec3ef8a329b0ce18bdb356"))
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
                    :source "elpaca-menu-lock-file" :id consult :type
                    git :protocol https :inherit t :depth treeless
                    :ref "9979fbb02e633267d0f6bc6cafa266fe87a0007f"))
 (consult-denote :source "elpaca-menu-lock-file" :recipe
                 (:package "consult-denote" :repo
                           ("https://github.com/protesilaos/consult-denote"
                            . "consult-denote")
                           :tar "0.5.1" :host gnu :files
                           ("*" (:exclude ".git")) :source
                           "elpaca-menu-lock-file" :id consult-denote
                           :type git :protocol https :inherit t :depth
                           treeless :ref
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
                        :source "elpaca-menu-lock-file" :id
                        consult-dir :type git :protocol https :inherit
                        t :depth treeless :ref
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
                              :source "elpaca-menu-lock-file" :id
                              consult-yasnippet :type git :protocol
                              https :inherit t :depth treeless :ref
                              "89e39887c87e25d18861216a4d72e5d174f13751"))
 (corfu :source "elpaca-menu-lock-file" :recipe
        (:package "corfu" :repo "minad/corfu" :files
                  (:defaults "extensions/corfu-*.el") :fetcher github
                  :source "elpaca-menu-lock-file" :id corfu :type git
                  :protocol https :inherit t :depth treeless :ref
                  "b468efac023dda39332acc943edc9895c80b5a6f"))
 (corfu-terminal :source "elpaca-menu-lock-file" :recipe
                 (:package "corfu-terminal" :repo
                           ("https://codeberg.org/akib/emacs-corfu-terminal"
                            . "corfu-terminal")
                           :tar "0.7" :host nongnu :files
                           ("*" (:exclude ".git")) :source
                           "elpaca-menu-lock-file" :id corfu-terminal
                           :type git :protocol https :inherit t :depth
                           treeless :ref
                           "501548c3d51f926c687e8cd838c5865ec45d03cc"))
 (csv-mode :source "elpaca-menu-lock-file" :recipe
           (:package "csv-mode" :repo
                     ("https://github.com/emacsmirror/gnu_elpa"
                      . "csv-mode")
                     :tar "1.27" :host gnu :branch
                     "externals/csv-mode" :files
                     ("*" (:exclude ".git")) :source
                     "elpaca-menu-lock-file" :id csv-mode :type git
                     :protocol https :inherit t :depth treeless :ref
                     "a693259ddef057eda82421b2a4410b3e35832e91"))
 (dape :source "elpaca-menu-lock-file" :recipe
       (:package "dape" :repo
                 ("https://github.com/svaante/dape" . "dape") :tar
                 "0.27.1" :host gnu :files ("*" (:exclude ".git"))
                 :source "elpaca-menu-lock-file" :id dape :type git
                 :protocol https :inherit t :depth treeless :ref
                 "b04e927abac6fcbef480c8a39881d69baa1bec98"))
 (dash :source "elpaca-menu-lock-file" :recipe
       (:package "dash" :fetcher github :repo "magnars/dash.el" :files
                 ("dash.el" "dash.texi") :source
                 "elpaca-menu-lock-file" :id dash :type git :protocol
                 https :inherit t :depth treeless :ref
                 "d746dd9edcb67a108818beb0cdc78dc1cb466832"))
 (denote :source "elpaca-menu-lock-file" :recipe
         (:package "denote" :repo
                   ("https://github.com/protesilaos/denote" . "denote")
                   :tar "4.2.3" :host gnu :files
                   ("*" (:exclude ".git" "COPYING" "doclicense.texi"))
                   :source "elpaca-menu-lock-file" :id denote :type
                   git :protocol https :inherit t :depth treeless :ref
                   "110ced99991125a0675a68dcefe8dfc3c50c5617"))
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
                     :source "elpaca-menu-lock-file" :id detached
                     :host github :type git :protocol https :inherit t
                     :depth treeless :ref
                     "567ab3b87a10277231f627f95879298513f24fd5"))
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
                    :source "elpaca-menu-lock-file" :id devdocs :type
                    git :protocol https :inherit t :depth treeless
                    :ref "25c746024ddf73570195bf42b841f761a2fee10c"))
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
                    :source "elpaca-menu-lock-file" :id diff-hl :type
                    git :protocol https :inherit t :depth treeless
                    :ref "b1ddfb3e4c68c8f6a4aee2e48e0016c3fb4c3803"))
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
                       :source "elpaca-menu-lock-file" :id difftastic
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "98c61e7dfac8d1ad4451423395da6bc14caa41df"))
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
                     :source "elpaca-menu-lock-file" :id diminish
                     :type git :protocol https :inherit t :depth
                     treeless :ref
                     "43d0b9e0d18e4d124e3f7dad9d73275fb678fa50"))
 (dired-hacks-utils :source "elpaca-menu-lock-file" :recipe
                    (:package "dired-hacks-utils" :fetcher github
                              :repo "Fuco1/dired-hacks" :files
                              ("dired-hacks-utils.el") :source
                              "elpaca-menu-lock-file" :id
                              dired-hacks-utils :type git :protocol
                              https :inherit t :depth treeless :ref
                              "de9336f4b47ef901799fe95315fa080fa6d77b48"))
 (dired-open :source "elpaca-menu-lock-file" :recipe
             (:package "dired-open" :fetcher github :repo
                       "Fuco1/dired-hacks" :files ("dired-open.el")
                       :source "elpaca-menu-lock-file" :id dired-open
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "de9336f4b47ef901799fe95315fa080fa6d77b48"))
 (dired-subtree :source "elpaca-menu-lock-file" :recipe
                (:package "dired-subtree" :fetcher github :repo
                          "Fuco1/dired-hacks" :files
                          ("dired-subtree.el") :source
                          "elpaca-menu-lock-file" :id dired-subtree
                          :type git :protocol https :inherit t :depth
                          treeless :ref
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
                   :source "elpaca-menu-lock-file" :id docker :type
                   git :protocol https :inherit t :depth treeless :ref
                   "e476b1bf73e917aaae43daab763696629d864425"))
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
                            :source "elpaca-menu-lock-file" :id
                            dockerfile-mode :type git :protocol https
                            :inherit t :depth treeless :ref
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
                          :source "elpaca-menu-lock-file" :id
                          doom-modeline :type git :protocol https
                          :inherit t :depth treeless :ref
                          "8af4db0f7ee63b9382c28f6db1f5b60e6203e0b3"))
 (doom-themes :source "elpaca-menu-lock-file" :recipe
              (:package "doom-themes" :fetcher github :repo
                        "doomemacs/themes" :files
                        (:defaults "themes/*.el" "themes/*/*.el"
                                   "extensions/*.el")
                        :source "elpaca-menu-lock-file" :id
                        doom-themes :type git :protocol https :inherit
                        t :depth treeless :ref
                        "a59202912ad55014e53a685eee6cd94130bdd4fd"))
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
                      :source "elpaca-menu-lock-file" :id dumb-jump
                      :type git :protocol https :inherit t :depth
                      treeless :ref
                      "cf06b4ccdce6a39346c32f05139f9ee8b77ee229"))
 (eglot-codelens :source "elpaca-menu-lock-file" :recipe
                 (:source "elpaca-menu-lock-file" :package
                          "eglot-codelens" :id eglot-codelens :host
                          github :repo "zsxh/eglot-codelens" :type git
                          :protocol https :inherit t :depth treeless
                          :ref
                          "a51c6c10293b5e5dc31d14a08ecd9d64f537062b"))
 (eglot-jdtls :source "elpaca-menu-lock-file" :recipe
              (:source "elpaca-menu-lock-file" :package "eglot-jdtls"
                       :id eglot-jdtls :host github :repo
                       "zsxh/eglot-jdtls" :type git :protocol https
                       :inherit t :depth treeless :ref
                       "ab4f83a5833cb9d59dc93127ef8554599cbe9622"))
 (elfeed :source "elpaca-menu-lock-file" :recipe
         (:package "elfeed" :fetcher github :repo
                   "emacs-elfeed/elfeed" :files
                   (:defaults "README.md") :source
                   "elpaca-menu-lock-file" :id elfeed :type git
                   :protocol https :inherit t :depth treeless :ref
                   "b39ca98c0ab05170cba943d6e31c5c2a3e285133"))
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
                           :source "elpaca-menu-lock-file" :id
                           elfeed-goodies :type git :protocol https
                           :inherit t :depth treeless :ref
                           "544ef42ead011d960a0ad1c1d34df5d222461a6b"))
 (elisp-refs :source "elpaca-menu-lock-file" :recipe
             (:package "elisp-refs" :repo "Wilfred/elisp-refs"
                       :fetcher github :files
                       (:defaults (:exclude "elisp-refs-bench.el"))
                       :source "elpaca-menu-lock-file" :id elisp-refs
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "541a064c3ce27867872cf708354a65d83baf2a6d"))
 (elpaca :source
   "elpaca-menu-lock-file" :recipe
   (:source "Init file" :package "elpaca" :id elpaca :repo
            "https://github.com/progfolio/elpaca.git" :ref
            "78b8e7cc98c198c8dbeb18140649e2d668126712" :depth 1
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
                               :source "elpaca-menu-lock-file" :id
                               elpaca-use-package :type git :protocol
                               https :inherit t :depth treeless :ref
                               "78b8e7cc98c198c8dbeb18140649e2d668126712"))
 (embark :source "elpaca-menu-lock-file" :recipe
         (:package "embark" :repo "oantolin/embark" :fetcher github
                   :files ("embark.el" "embark-org.el" "embark.texi")
                   :source "elpaca-menu-lock-file" :id embark :type
                   git :protocol https :inherit t :depth treeless :ref
                   "87e53827cf6659dcc4ac4e54be9af34aeca44f6e"))
 (embark-consult :source "elpaca-menu-lock-file" :recipe
                 (:package "embark-consult" :repo "oantolin/embark"
                           :fetcher github :files
                           ("embark-consult.el") :source
                           "elpaca-menu-lock-file" :id embark-consult
                           :type git :protocol https :inherit t :depth
                           treeless :ref
                           "87e53827cf6659dcc4ac4e54be9af34aeca44f6e"))
 (envrc :source "elpaca-menu-lock-file" :recipe
        (:package "envrc" :fetcher github :repo "purcell/envrc" :files
                  ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                   "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                   "doc/*.texinfo" "lisp/*.el" "docs/dir"
                   "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                   (:exclude ".dir-locals.el" "test.el" "tests.el"
                             "*-test.el" "*-tests.el" "LICENSE"
                             "README*" "*-pkg.el"))
                  :source "elpaca-menu-lock-file" :id envrc :type git
                  :protocol https :inherit t :depth treeless :ref
                  "1ecb82e01745d700578754eb35d6c1758290b869"))
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
                                 :source "elpaca-menu-lock-file" :id
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
                                       :source "elpaca-menu-lock-file"
                                       :id eshell-syntax-highlighting
                                       :type git :protocol https
                                       :inherit t :depth treeless :ref
                                       "62418fd8b2380114a3f6dad699c1ba45329db1d2"))
 (esxml :source "elpaca-menu-lock-file" :recipe
        (:package "esxml" :fetcher github :repo "tali713/esxml" :files
                  ("esxml.el" "esxml-query.el") :source
                  "elpaca-menu-lock-file" :id esxml :type git
                  :protocol https :inherit t :depth treeless :ref
                  "6a375888a74b7563eb53176aad81faee8b858189"))
 (evil :source "elpaca-menu-lock-file" :recipe
       (:package "evil" :repo "emacs-evil/evil" :fetcher github :files
                 (:defaults "doc/build/texinfo/evil.texi"
                            (:exclude "evil-test-helpers.el"))
                 :source "elpaca-menu-lock-file" :id evil :type git
                 :protocol https :inherit t :depth treeless :ref
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
                              :source "elpaca-menu-lock-file" :id
                              evil-cleverparens :type git :protocol
                              https :inherit t :depth treeless :ref
                              "4c413a132934695b975004d429b0b0a6e3d8ca38"))
 (evil-collection :source "elpaca-menu-lock-file" :recipe
                  (:package "evil-collection" :fetcher github :repo
                            "emacs-evil/evil-collection" :files
                            (:defaults "modes") :source
                            "elpaca-menu-lock-file" :id
                            evil-collection :type git :protocol https
                            :inherit t :depth treeless :ref
                            "2cca4b8e479b1e7923bcef40d3006f6b7e33d996"))
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
                             :source "elpaca-menu-lock-file" :id
                             evil-indent-plus :type git :protocol
                             https :inherit t :depth treeless :ref
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
                     :source "elpaca-menu-lock-file" :id evil-org
                     :type git :protocol https :inherit t :depth
                     treeless :ref
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
                          :source "elpaca-menu-lock-file" :id
                          evil-surround :type git :protocol https
                          :inherit t :depth treeless :ref
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
                                 :source "elpaca-menu-lock-file" :id
                                 exec-path-from-shell :wait t :type
                                 git :protocol https :inherit t :depth
                                 treeless :ref
                                 "6146fdc16e9882df270be7e58ae8d628032d6bc4"))
 (f :source "elpaca-menu-lock-file" :recipe
    (:package "f" :fetcher github :repo "rejeep/f.el" :files
              ("*.el" "*.el.in" "dir" "*.info" "*.texi" "*.texinfo"
               "doc/dir" "doc/*.info" "doc/*.texi" "doc/*.texinfo"
               "lisp/*.el" "docs/dir" "docs/*.info" "docs/*.texi"
               "docs/*.texinfo"
               (:exclude ".dir-locals.el" "test.el" "tests.el"
                         "*-test.el" "*-tests.el" "LICENSE" "README*"
                         "*-pkg.el"))
              :source "elpaca-menu-lock-file" :id f :type git
              :protocol https :inherit t :depth treeless :ref
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
                     :source "elpaca-menu-lock-file" :id flycheck
                     :type git :protocol https :inherit t :depth
                     treeless :ref
                     "9076d01a8a685bb0f03302e7bf3feaf41e6c34dc"))
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
                    :source "elpaca-menu-lock-file" :id general :wait
                    t :type git :protocol https :inherit t :depth
                    treeless :ref
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
                     :source "elpaca-menu-lock-file" :id git-link
                     :type git :protocol https :inherit t :depth
                     treeless :ref
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
                            :source "elpaca-menu-lock-file" :id
                            git-timemachine :type git :protocol https
                            :inherit t :depth treeless :ref
                            "d1346a76122595aeeb7ebb292765841c6cfd417b"))
 (go-mode :source "elpaca-menu-lock-file" :recipe
          (:package "go-mode" :repo "dominikh/go-mode.el" :fetcher
                    github :files ("go-mode.el") :source
                    "elpaca-menu-lock-file" :id go-mode :type git
                    :protocol https :inherit t :depth treeless :ref
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
                     :source "elpaca-menu-lock-file" :id goto-chg
                     :type git :protocol https :inherit t :depth
                     treeless :ref
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
                    :source "elpaca-menu-lock-file" :id helpful :type
                    git :protocol https :inherit t :depth treeless
                    :ref "03756fa6ad4dcca5e0920622b1ee3f70abfc4e39"))
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
                    :source "elpaca-menu-lock-file" :id hl-todo :type
                    git :protocol https :inherit t :depth treeless
                    :ref "527d545b8c2f36243194cbe4a8d0e6ac9d50e6a7"))
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
                       :source "elpaca-menu-lock-file" :id ibuffer-vc
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "bcdbbc0ea1b3368850fa71e853bb0806b993e8f0"))
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
                       :source "elpaca-menu-lock-file" :id inheritenv
                       :type git :protocol https :inherit t :depth
                       treeless :ref
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
                          :source "elpaca-menu-lock-file" :id
                          inhibit-mouse :type git :protocol https
                          :inherit t :depth treeless :ref
                          "0fa6082b4da1de468a014f9fd1a46165dca5fc5f"))
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
                      :source "elpaca-menu-lock-file" :id json-mode
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
                          :source "elpaca-menu-lock-file" :id
                          json-snatcher :type git :protocol https
                          :inherit t :depth treeless :ref
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
                         :source "elpaca-menu-lock-file" :id
                         jsonnet-mode :type git :protocol https
                         :inherit t :depth treeless :ref
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
                      :source "elpaca-menu-lock-file" :id just-mode
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
                         :source "elpaca-menu-lock-file" :id
                         just-ts-mode :type git :protocol https
                         :inherit t :depth treeless :ref
                         "6b4b23fcc6f0f0d0903e84c51771d43c06a00771"))
 (kdl-ts-mode :source "elpaca-menu-lock-file" :recipe
              (:source "elpaca-menu-lock-file" :package "kdl-ts-mode"
                       :id kdl-ts-mode :host github :repo
                       "merrickluo/kdl-ts-mode" :type git :protocol
                       https :inherit t :depth treeless :ref
                       "02400f0a7030f04b85ef89d769d5a58f8f10b538"))
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
                      :source "elpaca-menu-lock-file" :id link-hint
                      :type git :protocol https :inherit t :depth
                      treeless :ref
                      "8fda5dcb9caff5a3c49d22b82e570ac9e29af7dd"))
 (llama :source "elpaca-menu-lock-file" :recipe
        (:package "llama" :fetcher github :repo "tarsius/llama" :files
                  ("llama.el" ".dir-locals.el") :source
                  "elpaca-menu-lock-file" :id llama :type git
                  :protocol https :inherit t :depth treeless :ref
                  "cfea618f14bc8317f8e4947fe10000b229b9a447"))
 (llm :source "elpaca-menu-lock-file" :recipe
      (:package "llm" :repo "ahyatt/llm" :tar "0.32.1" :host github
                :files ("*" (:exclude ".git")) :source "GNU ELPA" :id
                llm :ref "9ac4111020babe5996c87ddb60d62b9cfcea28c1"
                :type git :protocol https :inherit t :depth treeless))
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
                          :source "elpaca-menu-lock-file" :id
                          load-relative :wait t :type git :protocol
                          https :inherit t :depth treeless :ref
                          "b7987c265a64435299d6b02f960ed2c894c4a145"))
 (magit :source "elpaca-menu-lock-file" :recipe
        (:package "magit" :fetcher github :repo "magit/magit" :files
                  ("lisp/magit*.el" "lisp/git-*.el" "docs/magit.texi"
                   "docs/AUTHORS.md" "LICENSE" ".dir-locals.el"
                   ("githooks" "githooks/*")
                   ("git-hooks" "git-hooks/*")
                   (:exclude "lisp/magit-section.el"))
                  :source "elpaca-menu-lock-file" :id magit :type git
                  :protocol https :inherit t :depth treeless :ref
                  "cd9117e3a8eb9b50814474d5addfd2ca92af5605"))
 (magit-section :source "elpaca-menu-lock-file" :recipe
                (:package "magit-section" :fetcher github :repo
                          "magit/magit" :files
                          ("lisp/magit-section.el"
                           "docs/magit-section.texi"
                           "magit-section-pkg.el")
                          :source "elpaca-menu-lock-file" :id
                          magit-section :type git :protocol https
                          :inherit t :depth treeless :ref
                          "cd9117e3a8eb9b50814474d5addfd2ca92af5605"))
 (majutsu :source "elpaca-menu-lock-file" :recipe
          (:source "elpaca-menu-lock-file" :package "majutsu" :id
                   majutsu :host github :repo "0WD0/majutsu" :type git
                   :protocol https :inherit t :depth treeless :ref
                   "0fdb3c2b3ab826724949cd2cc714f2eff32ec152"))
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
                       :source "elpaca-menu-lock-file" :id marginalia
                       :type git :protocol https :inherit t :depth
                       treeless :ref
                       "c5d0139012d2a84f8040219b9aee17db4e145e5c"))
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
                          :source "elpaca-menu-lock-file" :id
                          markdown-mode :type git :protocol https
                          :inherit t :depth treeless :ref
                          "76cb4ffecfdf95ee769e5cb4608e04202c3c1521"))
 (neotree :source "elpaca-menu-lock-file" :recipe
          (:package "neotree" :repo "jaypei/emacs-neotree" :fetcher
                    github :files (:defaults "icons") :source
                    "elpaca-menu-lock-file" :id neotree :type git
                    :protocol https :inherit t :depth treeless :ref
                    "3178805a0942696d1e5162575d9cab43d14b7970"))
 (nerd-icons :source "elpaca-menu-lock-file" :recipe
             (:package "nerd-icons" :repo
                       "rainstormstudio/nerd-icons.el" :fetcher github
                       :files (:defaults "data") :source
                       "elpaca-menu-lock-file" :id nerd-icons :type
                       git :protocol https :inherit t :depth treeless
                       :ref "17faac7977242b470732efd417d3bcc8eb5a830e"))
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
                                  :source "elpaca-menu-lock-file" :id
                                  nerd-icons-completion :type git
                                  :protocol https :inherit t :depth
                                  treeless :ref
                                  "f924dd490c8c4c1066fd97a76e0dc31e303fca30"))
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
                             :source "elpaca-menu-lock-file" :id
                             nerd-icons-corfu :type git :protocol
                             https :inherit t :depth treeless :ref
                             "9b089b31a810328d9b740b35a19eb796eb7a2d8a"))
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
                             :source "elpaca-menu-lock-file" :id
                             nerd-icons-dired :type git :protocol
                             https :inherit t :depth treeless :ref
                             "104acd8879528b8115589f35f1bbcbe231ad732f"))
 (nix-mode :source "elpaca-menu-lock-file" :recipe
           (:package "nix-mode" :fetcher github :repo "NixOS/nix-mode"
                     :files
                     (:defaults
                      (:exclude "nix-company.el" "nix-mode-mmm.el"))
                     :source "elpaca-menu-lock-file" :id nix-mode
                     :type git :protocol https :inherit t :depth
                     treeless :ref
                     "2c77e7e0b7540efbb20ccaee3557ef90a5dc77f0"))
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
                        :source "elpaca-menu-lock-file" :id
                        nix-ts-mode :type git :protocol https :inherit
                        t :depth treeless :ref
                        "09c89886a22b8e37ac0de9210ff5b2b79c520fd7"))
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
                         :source "elpaca-menu-lock-file" :id
                         no-littering :wait t :type git :protocol
                         https :inherit t :depth treeless :ref
                         "9bb4669400a300e9d8243916593d2455d4d63c26"))
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
                :source "elpaca-menu-lock-file" :id nov :type git
                :protocol https :inherit t :depth treeless :ref
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
                      :source "elpaca-menu-lock-file" :id orderless
                      :type git :protocol https :inherit t :depth
                      treeless :ref
                      "5806e3f9401606d16962cffae68188c92deb1272"))
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
                        :source "elpaca-menu-lock-file" :id
                        org-bullets :type git :protocol https :inherit
                        t :depth treeless :ref
                        "767f55feb58b840a5a04eabfc3fbbf0d257c4792"))
 (paredit :source "elpaca-menu-lock-file" :recipe
          (:package "paredit" :fetcher git :url
                    "https://github.com/emacsmirror/paredit.git"
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "elpaca-menu-lock-file" :id paredit :type
                    git :protocol https :inherit t :depth treeless
                    :ref "af075775af91f2dbc63b915d762b4aec092946c4"))
 (pdf-tools :source "elpaca-menu-lock-file" :recipe
            (:package "pdf-tools" :fetcher github :repo
                      "vedang/pdf-tools" :files
                      (:defaults "README" ("build" "Makefile")
                                 ("build" "server"))
                      :source "elpaca-menu-lock-file" :id pdf-tools
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
                             :source "elpaca-menu-lock-file" :id
                             pdf-view-restore :type git :protocol
                             https :inherit t :depth treeless :ref
                             "5a1947c01a3edecc9e0fe7629041a2f53e0610c9"))
 (pichat :source "elpaca-menu-lock-file" :recipe
         (:source "Init file" :package "pichat" :id pichat :type file
                  :main "/home/mojo/Dev/emacs.d/pichat/pichat.el"
                  :files ("*.el" ("bridge" "bridge/pichat-bridge.ts"))
                  :inherit nil :ref nil))
 (plz :source "elpaca-menu-lock-file"
   :recipe
   (:package "plz" :repo
             ("https://github.com/alphapapa/plz.el.git" . "plz") :tar
             "0.9.1" :host gnu :files
             ("*" (:exclude ".git" "LICENSE")) :source
             "elpaca-menu-lock-file" :id plz :type git :protocol https
             :inherit t :depth treeless :ref
             "e2d07838e3b64ee5ebe59d4c3c9011adefb7b58e"))
 (plz-event-source :source "elpaca-menu-lock-file" :recipe
                   (:package "plz-event-source" :repo
                             ("https://github.com/r0man/plz-event-source"
                              . "plz-event-source")
                             :tar "0.1.3" :host gnu :files
                             ("*" (:exclude ".git")) :source
                             "GNU ELPA" :id plz-event-source :type git
                             :protocol https :inherit t :depth
                             treeless :ref
                             "de89214ce14e2b82cbfdc30e1adcf3e77b1f250a"))
 (plz-media-type :source "elpaca-menu-lock-file" :recipe
                 (:package "plz-media-type" :repo
                           ("https://github.com/r0man/plz-media-type"
                            . "plz-media-type")
                           :tar "0.2.4" :host gnu :files
                           ("*" (:exclude ".git")) :source "GNU ELPA"
                           :id plz-media-type :type git :protocol
                           https :inherit t :depth treeless :ref
                           "b1127982d53affff082447030cda6e8ead3899cb"))
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
                     :source "elpaca-menu-lock-file" :id polymode
                     :type git :protocol https :inherit t :depth
                     treeless :ref
                     "8cb72fa5dcc0d98746c680043dc121edc7621e3a"))
 (popon :source "elpaca-menu-lock-file" :recipe
        (:package "popon" :repo
                  ("https://codeberg.org/akib/emacs-popon" . "popon")
                  :tar "0.13" :host nongnu :files
                  ("*" (:exclude ".git")) :source
                  "elpaca-menu-lock-file" :id popon :type git
                  :protocol https :inherit t :depth treeless :ref
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
                   :source "elpaca-menu-lock-file" :id popwin :type
                   git :protocol https :inherit t :depth treeless :ref
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
                      :source "elpaca-menu-lock-file" :id powerline
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
                               :source "elpaca-menu-lock-file" :id
                               rainbow-delimiters :type git :protocol
                               https :inherit t :depth treeless :ref
                               "f40ece58df8b2f0fb6c8576b527755a552a5e763"))
 (rainbow-mode :source "elpaca-menu-lock-file" :recipe
               (:package "rainbow-mode" :repo
                         ("https://github.com/emacsmirror/gnu_elpa"
                          . "rainbow-mode")
                         :tar "1.0.6" :host gnu :branch
                         "externals/rainbow-mode" :files
                         ("*" (:exclude ".git")) :source
                         "elpaca-menu-lock-file" :id rainbow-mode
                         :type git :protocol https :inherit t :depth
                         treeless :ref
                         "9d333d3a92132c2a9057d2a39e1ebd8cc575a1bb"))
 (reformatter :source "elpaca-menu-lock-file" :recipe
              (:package "reformatter" :repo
                        "purcell/emacs-reformatter" :fetcher github
                        :files
                        ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                         "*.texinfo" "doc/dir" "doc/*.info"
                         "doc/*.texi" "doc/*.texinfo" "lisp/*.el"
                         "docs/dir" "docs/*.info" "docs/*.texi"
                         "docs/*.texinfo"
                         (:exclude ".dir-locals.el" "test.el"
                                   "tests.el" "*-test.el" "*-tests.el"
                                   "LICENSE" "README*" "*-pkg.el"))
                        :source "MELPA" :id reformatter :type git
                        :protocol https :inherit t :depth treeless
                        :ref
                        "2bd8818f3f2119a3876e574a437495214c87bc81"))
 (request :source "elpaca-menu-lock-file"
   :recipe
   (:package "request" :repo "tkf/emacs-request" :fetcher github
             :files ("request.el") :source "elpaca-menu-lock-file" :id
             request :type git :protocol https :inherit t :depth
             treeless :ref "c22e3c23a6dd90f64be536e176ea0ed6113a5ba6"))
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
                   :source "elpaca-menu-lock-file" :id rotate :type
                   git :protocol https :inherit t :depth treeless :ref
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
              :source "elpaca-menu-lock-file" :id s :type git
              :protocol https :inherit t :depth treeless :ref
              "d7c04b84d03481a1ed62ee13dbe595224ccbe57c"))
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
                        :source "elpaca-menu-lock-file" :id
                        shrink-path :type git :protocol https :inherit
                        t :depth treeless :ref
                        "c14882c8599aec79a6e8ef2d06454254bb3e1e41"))
 (shut-up :source "elpaca-menu-lock-file" :recipe
          (:package "shut-up" :fetcher github :repo "cask/shut-up"
                    :files
                    ("*.el" "*.el.in" "dir" "*.info" "*.texi"
                     "*.texinfo" "doc/dir" "doc/*.info" "doc/*.texi"
                     "doc/*.texinfo" "lisp/*.el" "docs/dir"
                     "docs/*.info" "docs/*.texi" "docs/*.texinfo"
                     (:exclude ".dir-locals.el" "test.el" "tests.el"
                               "*-test.el" "*-tests.el" "LICENSE"
                               "README*" "*-pkg.el"))
                    :source "elpaca-menu-lock-file" :id shut-up :type
                    git :protocol https :inherit t :depth treeless
                    :ref "ed62a7fefdf04c81346061016f1bc69ca045aaf6"))
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
                       :source "elpaca-menu-lock-file" :id smart-jump
                       :type git :protocol https :inherit t :depth
                       treeless :ref
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
                        :source "elpaca-menu-lock-file" :id
                        smartparens :type git :protocol https :inherit
                        t :depth treeless :ref
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
                                 :source "elpaca-menu-lock-file" :id
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
                      :source "elpaca-menu-lock-file" :id sudo-edit
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
                    :source "elpaca-menu-lock-file" :id tablist :type
                    git :protocol https :inherit t :depth treeless
                    :ref "01f065e387ffe6b7a41f180f257cd12551c7a9c2"))
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
                    :source "elpaca-menu-lock-file" :id toc-org :type
                    git :protocol https :inherit t :depth treeless
                    :ref "69165018974a82b397d0869f0c7f0bf7d3b4ee07"))
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
                      :source "elpaca-menu-lock-file" :id transient
                      :type git :protocol https :inherit t :depth
                      treeless :ref
                      "a3e26414f2516f6443182e13e1d98882e1b209d6"))
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
                    :source "elpaca-menu-lock-file" :id trashed :type
                    git :protocol https :inherit t :depth treeless
                    :ref "52a52a363ce53855790e7a59aed6976eec18c9ea"))
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
                         :source "elpaca-menu-lock-file" :id
                         treesit-auto :type git :protocol https
                         :inherit t :depth treeless :ref
                         "3106c739c2a84bec2cb671997fe074e5dd5dd967"))
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
                       :source "elpaca-menu-lock-file" :id undercover
                       :type git :protocol https :inherit t :depth
                       treeless :ref
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
                    :source "elpaca-menu-lock-file" :id undo-fu :type
                    git :protocol https :inherit t :depth treeless
                    :ref "5684ef2aef5f60176472916b21869cf221e018cc"))
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
                            :source "elpaca-menu-lock-file" :id
                            undo-fu-session :type git :protocol https
                            :inherit t :depth treeless :ref
                            "92d733a5b162a70c572fac17b9f9e872426df547"))
 (vertico :source "elpaca-menu-lock-file" :recipe
          (:package "vertico" :repo "minad/vertico" :files
                    (:defaults "extensions/vertico-*.el") :fetcher
                    github :source "elpaca-menu-lock-file" :id vertico
                    :type git :protocol https :inherit t :depth
                    treeless :ref
                    "a9998a777f1d92348f84d091bb15b87df933a7a2"))
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
                        :source "elpaca-menu-lock-file" :id
                        vim-tab-bar :type git :protocol https :inherit
                        t :depth treeless :ref
                        "c2653f3bb2d102ae62901fb42da1507bdf60cff5"))
 (vterm :source "elpaca-menu-lock-file" :recipe
        (:package "vterm" :fetcher github :repo
                  "akermu/emacs-libvterm" :files
                  ("CMakeLists.txt" "elisp.c" "elisp.h"
                   "emacs-module.h" "etc" "utf8.c" "utf8.h" "vterm.el"
                   "vterm-module.c" "vterm-module.h")
                  :source "elpaca-menu-lock-file" :id vterm :type git
                  :protocol https :inherit t :depth treeless :ref
                  "6d715a93fa0e5182bc137d4db09f376e06938aa5"))
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
                         :source "elpaca-menu-lock-file" :id
                         vterm-toggle :type git :protocol https
                         :inherit t :depth treeless :ref
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
                :source "elpaca-menu-lock-file" :id vui :type git
                :protocol https :inherit t :depth treeless :ref
                "d8e76e7ccc784ab0441caab04fcf36aba73f5bdb"))
 (vundo :source "elpaca-menu-lock-file" :recipe
        (:package "vundo" :repo
                  ("https://github.com/casouri/vundo" . "vundo") :tar
                  "2.4.0" :host gnu :files
                  ("*" (:exclude ".git" "test")) :source
                  "elpaca-menu-lock-file" :id vundo :type git
                  :protocol https :inherit t :depth treeless :ref
                  "04caf7ec54e4a7861d3591a1e090adc1fb76b5d1"))
 (wgrep :source "elpaca-menu-lock-file" :recipe
        (:package "wgrep" :fetcher github :repo
                  "mhayashi1120/Emacs-wgrep" :files ("wgrep.el")
                  :source "elpaca-menu-lock-file" :id wgrep :type git
                  :protocol https :inherit t :depth treeless :ref
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
                      :source "elpaca-menu-lock-file" :id which-key
                      :type git :protocol https :inherit t :depth
                      treeless :ref
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
             :source "elpaca-menu-lock-file" :id with-editor :type git
             :protocol https :inherit t :depth treeless :ref
             "53115f978576e043e050fd04d0cb7517296727e9"))
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
                      :source "elpaca-menu-lock-file" :id yaml-mode
                      :type git :protocol https :inherit t :depth
                      treeless :ref
                      "93dba98c050e9abfc623ec66aa499dbbb46b2fe1"))
 (yasnippet :source "elpaca-menu-lock-file" :recipe
            (:package "yasnippet" :fetcher github :repo
                      "joaotavora/yasnippet" :files
                      (:defaults ("doc" "doc/*.org")) :source
                      "elpaca-menu-lock-file" :id yasnippet :type git
                      :protocol https :inherit t :depth treeless :ref
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
                   :source "elpaca-menu-lock-file" :id zoxide :type
                   git :protocol https :inherit t :depth treeless :ref
                   "0ec359c83b041c8ffe2ec0e70b16c5d218d9bfd9")))
