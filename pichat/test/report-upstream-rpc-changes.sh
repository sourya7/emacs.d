#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compatibility_file="$repo_root/pichat/PI_COMPATIBILITY.md"
upstream_url="https://github.com/earendil-works/pi.git"
rpc_path="packages/coding-agent/docs/rpc.md"
temporary_checkout=""

usage() {
  cat <<'EOF'
usage: pichat/test/report-upstream-rpc-changes.sh [OLD_REF] [NEW_REF]

Report upstream rpc.md commits between two Pi refs. With no OLD_REF, use the
last_reviewed_pi value in pichat/PI_COMPATIBILITY.md. With no NEW_REF, use the
version reported by pi --version.

Set PI_UPSTREAM_DIR to an existing full Pi git checkout to avoid a temporary
network clone. Set PI_EXECUTABLE to select a Pi executable.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
elif [[ $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

metadata_value() {
  local key="$1"
  awk -F ': *' -v key="$key" '$1 == key { print $2; exit }' "$compatibility_file"
}

normalize_release_ref() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'v%s\n' "$value"
  else
    printf '%s\n' "$value"
  fi
}

reviewed_version="$(metadata_value last_reviewed_pi)"
if [[ -z "$reviewed_version" || "$reviewed_version" == "null" ]]; then
  echo "error: last_reviewed_pi is not set in $compatibility_file" >&2
  exit 1
fi
old_ref="$(normalize_release_ref "${1:-$reviewed_version}")"

if [[ -n "${2:-}" ]]; then
  new_ref="$(normalize_release_ref "$2")"
else
  pi_executable="${PI_EXECUTABLE:-pi}"
  if ! version_output="$("$pi_executable" --version 2>/dev/null)"; then
    echo "error: NEW_REF was omitted and '$pi_executable --version' failed" >&2
    exit 1
  fi
  version="$(printf '%s\n' "$version_output" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ -z "$version" ]]; then
    echo "error: could not parse a semantic version from: $version_output" >&2
    exit 1
  fi
  new_ref="v$version"
fi

cleanup() {
  if [[ -n "$temporary_checkout" ]]; then
    rm -rf "$temporary_checkout"
  fi
}
trap cleanup EXIT

if [[ -n "${PI_UPSTREAM_DIR:-}" ]]; then
  upstream_dir="$PI_UPSTREAM_DIR"
  if [[ ! -d "$upstream_dir/.git" ]]; then
    echo "error: PI_UPSTREAM_DIR is not a git checkout: $upstream_dir" >&2
    exit 1
  fi
else
  temporary_checkout="$(mktemp -d "${TMPDIR:-/tmp}/pichat-pi-upstream.XXXXXX")"
  upstream_dir="$temporary_checkout/pi"
  echo "Cloning upstream Pi metadata..." >&2
  git clone --quiet --filter=blob:none --no-checkout "$upstream_url" "$upstream_dir"
fi

resolve_commit() {
  local ref="$1"
  if ! git -C "$upstream_dir" rev-parse --verify "$ref^{commit}" 2>/dev/null; then
    echo "error: upstream ref not found: $ref" >&2
    exit 1
  fi
}

old_commit="$(resolve_commit "$old_ref")"
new_commit="$(resolve_commit "$new_ref")"
old_blob="$(git -C "$upstream_dir" rev-parse "$old_commit:$rpc_path")"
new_blob="$(git -C "$upstream_dir" rev-parse "$new_commit:$rpc_path")"

cat <<EOF
Pi RPC compatibility review input

  old ref:      $old_ref
  old commit:   $old_commit
  old rpc blob: $old_blob
  new ref:      $new_ref
  new commit:   $new_commit
  new rpc blob: $new_blob
EOF

if [[ "$old_commit" == "$new_commit" ]]; then
  echo
  echo "The refs resolve to the same commit; there are no changes to review."
  exit 0
fi

if ! git -C "$upstream_dir" merge-base --is-ancestor "$old_commit" "$new_commit"; then
  echo
  echo "warning: $old_ref is not an ancestor of $new_ref; the range may not represent an upgrade" >&2
fi

changes="$(git -C "$upstream_dir" log --reverse \
  --format='%H%x09%cs%x09%s' "$old_commit..$new_commit" -- "$rpc_path")"

echo
if [[ -z "$changes" ]]; then
  echo "No upstream rpc.md commits occur in this range."
else
  echo "Upstream rpc.md commits requiring ledger dispositions:"
  echo
  while IFS=$'\t' read -r commit date subject; do
    printf -- '- %s [%s](https://github.com/earendil-works/pi/commit/%s) %s\n' \
      "$date" "$commit" "$commit" "$subject"
  done <<<"$changes"
fi

cat <<'EOF'

This report discovers candidate contract changes; it does not establish
compatibility. Add each change to pichat/PI_COMPATIBILITY.md, inspect its source
diff where necessary, and run pichat/test/run-tests.sh --full before advancing
the verified watermark.
EOF
