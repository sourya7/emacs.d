#!/usr/bin/env bash
# Per-test coverage of the default PiChat suite and a report of tests whose
# instrumented forms all run in other tests.  The report nominates candidates
# for reading; it never justifies deleting a test on its own.
#
#   run-test-overlap.sh [--selector REGEXP] [--output DIR]
#       Instrumented run (no network, real Pi or user state), then the report.
#       Writes forms.eld, tests.eld, test-output.log, report.md and tests.tsv
#       to DIR (default: coverage/test-overlap, gitignored).
#   run-test-overlap.sh --report-only [--output DIR]
#       Rebuild report.md and tests.tsv from existing records.
#   run-test-overlap.sh --coupling [--output DIR]
#       Static coupling counts per test file only (coupling.md), no test run.
#   run-test-overlap.sh --diff DIR_A DIR_B
#       List tests whose recorded forms differ between two record sets.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

usage() {
  echo "usage: $0 [--selector REGEXP] [--output DIR] | --report-only [--output DIR]" >&2
  echo "       $0 --coupling [--output DIR] | --diff DIR_A DIR_B" >&2
}

mode=collect
selector=""
output="$repo_root/coverage/test-overlap"
diff_a=""
diff_b=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selector) [[ $# -ge 2 ]] || { usage; exit 2; }; selector="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; output="$(realpath -m -- "$2")"; shift 2 ;;
    --report-only) mode=report; shift ;;
    --coupling) mode=coupling; shift ;;
    --diff) [[ $# -ge 3 ]] || { usage; exit 2; }
            mode=diff; diff_a="$(realpath -- "$2")"; diff_b="$(realpath -- "$3")"; shift 3 ;;
    *) usage; exit 2 ;;
  esac
done
cd "$repo_root"
plain_emacs() {
  emacs -Q --batch -L pichat/test -l pichat/test/test-overlap.el "$@"
}

# Paths reach Lisp through the environment, never through string splicing.
if [[ "$mode" == diff ]]; then
  PICHAT_OVERLAP_A="$diff_a" PICHAT_OVERLAP_B="$diff_b" plain_emacs \
    --eval '(pichat-test-overlap-diff (getenv "PICHAT_OVERLAP_A") (getenv "PICHAT_OVERLAP_B"))'
  exit 0
fi

mkdir -p "$output"
export PICHAT_OVERLAP_OUTPUT="$output"

case "$mode" in
  coupling)
    plain_emacs --eval '(princ (with-temp-buffer
        (insert-file-contents (pichat-test-overlap-write-coupling
                               (expand-file-name "coupling.md" (getenv "PICHAT_OVERLAP_OUTPUT"))))
        (buffer-string)))'
    exit 0 ;;
  report)
    plain_emacs --eval '(princ (pichat-test-overlap-analyze (getenv "PICHAT_OVERLAP_OUTPUT")))'
    echo
    exit 0 ;;
esac

if find pichat -maxdepth 1 -name '*.elc' -print -quit | grep -q .; then
  echo "per-test coverage requires source files; remove pichat/*.elc first" >&2
  exit 1
fi

load_paths=()
add_load_path() {
  if [[ -d "$1" ]]; then
    load_paths+=("-L" "$1")
  fi
}
for package in undercover dash shut-up; do
  if [[ -d ".local/elpaca/builds/$package" ]]; then
    add_load_path ".local/elpaca/builds/$package"
  else
    add_load_path ".local/elpaca/sources/$package"
  fi
done
if [[ -n "${PICHAT_COVERAGE_LOAD_PATH:-}" ]]; then
  IFS=: read -r -a extra_load_paths <<< "$PICHAT_COVERAGE_LOAD_PATH"
  for path in "${extra_load_paths[@]}"; do
    add_load_path "$path"
  done
fi

export PI_OFFLINE="${PI_OFFLINE:-1}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"
export PI_TELEMETRY="${PI_TELEMETRY:-0}"
export PICHAT_COVERAGE_FORMAT=text

export PICHAT_OVERLAP_SELECTOR="$selector"

log="$output/test-output.log"
# Compiler warnings are suppressed for the same reason as in run-coverage.sh.
if ! emacs -Q --batch \
     "${load_paths[@]}" \
     -L pichat -L pichat/test \
     --eval "(setq pichat-test-include-integration nil
                   byte-compile-warnings nil)" \
     -l pichat/test/coverage-setup.el \
     --eval '(pichat-coverage-enable)' \
     -l pichat/test/pichat-test.el \
     -l pichat/test/test-overlap.el \
     --eval '(pichat-test-overlap-collect
               (getenv "PICHAT_OVERLAP_OUTPUT")
               (let ((selector (getenv "PICHAT_OVERLAP_SELECTOR")))
                 (if (string-empty-p selector) t selector)))' \
     >"$log" 2>&1; then
  echo "per-test coverage run failed; log: $log" >&2
  tail -n 40 "$log" >&2
  exit 1
fi
grep -E '^Ran [0-9]+ tests|^Per-test coverage:' "$log" || true

plain_emacs --eval '(princ (pichat-test-overlap-analyze (getenv "PICHAT_OVERLAP_OUTPUT")))'
echo
