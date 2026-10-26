#!/usr/bin/env bash
# Sourced by test runners; optional integration mode fails if a dependency is
# absent instead of treating an unavailable test as a passing integration run.
pichat_optional_load_paths=()
for package in compat consult embark evil goto-chg orderless; do
  if [[ -d ".local/elpaca/builds/$package" ]]; then
    pichat_optional_load_paths+=("-L" ".local/elpaca/builds/$package")
  elif [[ -d ".local/elpaca/sources/$package" ]]; then
    pichat_optional_load_paths+=("-L" ".local/elpaca/sources/$package")
  else
    echo "optional PiChat tests require $package (Elpaca builds or sources)" >&2
    return 1
  fi
done
