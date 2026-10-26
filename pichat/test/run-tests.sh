#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
cd "$repo_root"

include_integration=nil
with_optional=false
for option in "$@"; do
  case "$option" in
    --full) include_integration=t ;;
    --with-optional) with_optional=true ;;
    *) echo "usage: $0 [--full] [--with-optional]" >&2; exit 2 ;;
  esac
done

optional_load_paths=()
optional_require=()
if [[ "$with_optional" == true ]]; then
  source "$script_dir/optional-load-paths.sh"
  optional_load_paths=("${pichat_optional_load_paths[@]}")
  optional_require=(--eval "(dolist (feature '(consult embark evil orderless)) (require feature))")
fi

export PI_OFFLINE="${PI_OFFLINE:-1}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"
export PI_TELEMETRY="${PI_TELEMETRY:-0}"

exec emacs -Q --batch "${optional_load_paths[@]}" -L pichat -L pichat/test \
  "${optional_require[@]}" \
  --eval "(setq pichat-test-include-integration ${include_integration})" \
  -l pichat/test/pichat-test.el \
  -f ert-run-tests-batch-and-exit
