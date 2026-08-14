#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PICHAT_TEST_SSH_DIRECTORY:-}" ]]; then
  echo "PICHAT_TEST_SSH_DIRECTORY must name an isolated TRAMP parent directory" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

exec emacs -Q --batch -L pichat -L pichat/test \
  -l pichat/test/pichat-test-support.el \
  -l pichat/test/pichat-test-ssh.el \
  -f ert-run-tests-batch-and-exit
