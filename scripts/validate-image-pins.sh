#!/usr/bin/env bash
set -euo pipefail

errors=0

while IFS= read -r line; do
  if [[ ! "$line" =~ @sha256:[0-9a-f]{64} ]]; then
    echo "ERROR: mutable image reference: $line"
    errors=$((errors + 1))
  fi
done < <(rg -n '^[[:space:]]*(image|imageName):[[:space:]]*[^[:space:]#]+' \
  infrastructure monitoring my-apps --glob '*.yaml' --glob '*.yml')

if [ "$errors" -ne 0 ]; then
  echo "$errors image reference(s) are missing an immutable sha256 digest."
  exit 1
fi

echo "All manual image references are pinned by sha256 digest."
