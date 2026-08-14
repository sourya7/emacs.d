#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

include_integration=nil
format="${PICHAT_COVERAGE_FORMAT:-text}"

usage() {
  echo "usage: $0 [--full] [--format text|lcov]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)
      include_integration=t
      shift
      ;;
    --format)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      format="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$format" in
  text|lcov) ;;
  *) usage; exit 2 ;;
esac

if find pichat -maxdepth 1 -name '*.elc' -print -quit | grep -q .; then
  echo "coverage requires source files; remove pichat/*.elc before running" >&2
  exit 1
fi

load_paths=()
add_load_path() {
  if [[ -d "$1" ]]; then
    load_paths+=("-L" "$1")
  fi
}

# Normal local setup: user/pichat.el asks Elpaca to install these packages.
for package in undercover dash shut-up; do
  if [[ -d ".local/elpaca/builds/$package" ]]; then
    add_load_path ".local/elpaca/builds/$package"
  else
    add_load_path ".local/elpaca/sources/$package"
  fi
done

# CI and one-off runs can provide additional colon-separated package paths.
if [[ -n "${PICHAT_COVERAGE_LOAD_PATH:-}" ]]; then
  IFS=: read -r -a extra_load_paths <<< "$PICHAT_COVERAGE_LOAD_PATH"
  for path in "${extra_load_paths[@]}"; do
    add_load_path "$path"
  done
fi

export PI_OFFLINE="${PI_OFFLINE:-1}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"
export PI_TELEMETRY="${PI_TELEMETRY:-0}"
export PICHAT_COVERAGE_FORMAT="$format"

# Undercover's Edebug instrumentation can make Emacs report false
# underscore-argument compiler warnings while instrumented closures run.  They
# are not source byte-compilation diagnostics and can leak through `message'
# into behavior tests, so suppress compiler warnings only in this coverage run.
exec emacs -Q --batch \
  "${load_paths[@]}" \
  -L pichat -L pichat/test \
  --eval "(setq pichat-test-include-integration ${include_integration}
                 byte-compile-warnings nil)" \
  -l pichat/test/coverage-setup.el \
  -l pichat/test/pichat-test.el \
  -f ert-run-tests-batch-and-exit
