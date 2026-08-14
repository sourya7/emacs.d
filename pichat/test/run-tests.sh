#!/usr/bin/env bash
set -euo pipefail

include_integration=nil
if [[ "${1:-}" == "--full" ]]; then
  include_integration=t
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--full]" >&2
  exit 2
fi

export PI_OFFLINE="${PI_OFFLINE:-1}"
export PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}"
export PI_TELEMETRY="${PI_TELEMETRY:-0}"

exec emacs -Q --batch -L pichat -L pichat/test \
  --eval "(setq pichat-test-include-integration ${include_integration})" \
  -l pichat/test/pichat-test.el \
  -f ert-run-tests-batch-and-exit
