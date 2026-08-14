# CLAUDE.md

Personal GNU Emacs configuration. `init.el` loads `core/package.el`, then `user/package.el`.

## Layout

- `core/` — machine-independent configuration
- `user/` — personal and work configuration
- `shared/` — snippets, templates, personas, and other assets
- `pichat/` — in-repo Emacs Lisp package
- `.local/` — generated/runtime state; gitignored

## Conventions

- Packages use **elpaca**, with `use-package-always-ensure` enabled.
- Modules are loaded by basename through `my/load-packages`, not with `require` or `load`. Register modules in `core/package.el` or `user/package.el`.
- Conditional module entries use `(basename . CONDITION)`.
- Build repository paths with `my/emacs-local-dir`, `my/emacs-shared-dir`, or `my/emacs-main-dir`; do not hardcode them.
- Read dependency source from `.local/elpaca/sources/<package>/` instead of guessing APIs.

## In-repo packages

Before changing these packages, read their documentation:

- `pichat/README.md` and `pichat/TESTING_GUIDELINES.md` — Pi RPC frontend and tests

Sources fetched with elpaca generally live in `.local/elpaca/sources/vui/` (eg. `.local/elpaca/sources/vui/` for `vui`).

## Verification

- `pichat/`: run `pichat/test/run-tests.sh` (`--full` enables RPC integration tests).
- Other standalone packages: byte-compile changed files with their package and dependency build directories on `load-path`.
- Verify `core/` and `user/` modules in a live Emacs session; isolated byte-compilation is unreliable.
- Do not commit generated `*.elc` files.
