#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

usage() {
  echo "usage: $0 [--full]" >&2
}

coverage_args=(--format lcov)
if [[ $# -gt 1 ]]; then
  usage
  exit 2
elif [[ $# -eq 1 ]]; then
  if [[ "$1" != "--full" ]]; then
    usage
    exit 2
  fi
  coverage_args+=(--full)
fi

coverage_dir="$repo_root/coverage"
mkdir -p "$coverage_dir"
lcov_file="$coverage_dir/lcov.info"
test_log="$coverage_dir/test-output.log"
report_file="$coverage_dir/coverage-analysis.md"

if ! PICHAT_COVERAGE_REPORT_FILE="$lcov_file" \
     "$script_dir/run-coverage.sh" "${coverage_args[@]}" \
     >"$test_log" 2>&1; then
  echo "coverage test run failed; complete log: $test_log" >&2
  cat "$test_log" >&2
  exit 1
fi

if ! PICHAT_ANALYSIS_LCOV="$lcov_file" \
     PICHAT_ANALYSIS_TEST_LOG="$test_log" \
     PICHAT_ANALYSIS_REPORT="$report_file" \
     emacs -Q --batch \
       -L "$script_dir" \
       -l "$script_dir/analyze-coverage.el" \
       --eval "(pichat-coverage-analyze\
                 (getenv \"PICHAT_ANALYSIS_LCOV\")\
                 (getenv \"PICHAT_ANALYSIS_TEST_LOG\")\
                 (getenv \"PICHAT_ANALYSIS_REPORT\"))"; then
  echo "coverage analysis failed; generated files: $coverage_dir" >&2
  exit 1
fi

cat "$report_file"
printf '\nReport: %s\n' "$report_file"
printf 'Generated artifacts: %s\n' "$coverage_dir"
