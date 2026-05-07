#!/usr/bin/env bash
# ==============================================================================
# Omni cluster bootstrap helper
# ==============================================================================
# Applies the machine classes and cluster template to your Omni instance,
# triggering Talos VM provisioning via the Proxmox infrastructure provider.
#
# Prerequisites:
#   1. Omni running and reachable (omni/docker-compose.yml is `up -d`).
#   2. Proxmox provider running and registered in Omni
#      (proxmox-provider/docker-compose.yml is `up -d`).
#   3. `omnictl` installed locally and configured to talk to your Omni
#      instance. See docs/PREREQUISITES.md.
#   4. Placeholders in machine-classes/*.yaml and cluster-template/
#      cluster-template.yaml have been substituted (run
#      `scripts/adapt-to-your-cluster.sh` from the repo root, or edit by
#      hand).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

if ! command -v omnictl &> /dev/null; then
    err "omnictl not found. Install it first:"
    err "  https://github.com/siderolabs/omni/releases"
    exit 1
fi

# Pre-flight: make sure placeholders have been substituted.
if grep -rq '__REPLACE_ME_' "$SCRIPT_DIR/machine-classes" "$SCRIPT_DIR/cluster-template"; then
    err "Placeholders detected in machine-classes/ or cluster-template/."
    err "Run scripts/adapt-to-your-cluster.sh from the repo root before bootstrapping."
    err "Offending files:"
    grep -rl '__REPLACE_ME_' "$SCRIPT_DIR/machine-classes" "$SCRIPT_DIR/cluster-template" || true
    exit 1
fi

info "Applying machine classes..."
omnictl apply -f "$SCRIPT_DIR/machine-classes/control-plane.yaml"
omnictl apply -f "$SCRIPT_DIR/machine-classes/worker.yaml"

info "Syncing cluster template..."
omnictl cluster template sync -v -f "$SCRIPT_DIR/cluster-template/cluster-template.yaml"

info ""
info "===================================="
info "  Omni bootstrap submitted."
info "===================================="
info ""
info "Next steps:"
info "  1. Watch the Omni UI — VMs should start appearing in Proxmox within ~1 minute."
info "  2. Wait for the cluster to reach \"Running\" state (3-5 minutes typical)."
info "  3. Pull the kubeconfig:"
info "       omnictl kubeconfig --cluster homelab --force"
info "  4. Verify:"
info "       kubectl get nodes"
info "  5. Move to the repo root and run scripts/bootstrap-argocd.sh"
info ""
warn "If a node gets stuck in \"Installing\", check Proxmox console output."
warn "Most failures at this stage are storage-pool or DNS related."
warn "See omni/docs/TROUBLESHOOTING.md."
