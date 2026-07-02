#!/usr/bin/env bash
# Interactive find-and-replace: swap the kit's live values for yours.
# The manifests ship with real, working values (docs/adapting-to-your-cluster.md
# explains why). Run from the repo root AFTER forking; review `git diff` after.
set -euo pipefail

cd "$(dirname "$0")/.."

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# current-value|prompt
SWAPS=(
  "vanillax.xyz|Your apps domain (Cloudflare-managed), e.g. lab.example.com"
  "github.com/mitchross/talos-argocd-proxmox-advanced-starter|Your fork, e.g. github.com/you/talos-argocd-proxmox-advanced-starter"
  "192.168.10.133:30292|Your S3 endpoint as bare host:port (see docs/rustfs-setup.md)"
)

files_matching() {
  grep -rl --exclude-dir=.git --exclude-dir=charts -F "$1" . 2>/dev/null || true
}

for entry in "${SWAPS[@]}"; do
  current="${entry%%|*}"
  prompt="${entry#*|}"
  matches=$(files_matching "$current" | wc -l)
  echo
  echo "── ${current}  (${matches} files)"
  echo "   ${prompt}"
  if [ "$DRY_RUN" = 1 ]; then
    files_matching "$current" | sed 's/^/     /'
    continue
  fi
  read -rp "   Replace with (empty = skip): " value
  [ -z "$value" ] && { echo "   skipped"; continue; }
  files_matching "$current" | while read -r f; do
    sed -i "s|${current}|${value}|g" "$f"
  done
  echo "   done."
done

echo
echo "Remaining manual steps (docs/adapting-to-your-cluster.md):"
echo "  - 1Password vault/item names: grep -rn remoteRef --include='externalsecret*.yaml' ."
echo "  - Cluster name + hardware in omni/cluster-template/ and omni/machine-classes/"
echo "  - Review: git diff   — substitution is global, check every hunk"
echo "  - Commit AND PUSH your fork: ArgoCD deploys the remote main, not this checkout"
