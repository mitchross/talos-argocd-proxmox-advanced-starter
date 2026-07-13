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
  "192.168.10.133|Your off-cluster S3 host or IP"
  "30292|Your off-cluster S3 API port"
  "192.168.10.15|Your Technitium DNS server IP"
  "192.168.10.52|The internal Gateway IP from your Cilium LoadBalancer pool"
  "192.168.10.32/27|Your Cilium LoadBalancer pool CIDR"
  "talos-singlenode-gpu-prod|Your Cilium cluster name"
  "__REPLACE_ME_NODE_CIDR__|Your Talos node CIDR, e.g. 192.168.10.0/24"
  "homelab-prod|Your 1Password vault name"
  "threadripper|Your Cloudflare tunnel name"
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
echo "  - Technitium TSIG key/item names and ExternalDNS owner IDs"
echo "  - 1Password item names, if you do not use the documented defaults"
echo "  - Omni cluster name, machine sizing, storage pool, and hardware"
echo "  - Review: git diff   — substitution is global, check every hunk"
echo "  - Commit AND PUSH your fork: ArgoCD deploys the remote main, not this checkout"
