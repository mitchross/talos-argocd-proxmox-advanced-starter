#!/usr/bin/env bash
# bootstrap-argocd.sh — install ArgoCD via Helm and apply the root
# Application that triggers the rest of the GitOps tree.
#
# Why this is in scripts/: one-shot bootstrap operation. After this
# script runs once, ArgoCD takes over its own management — every
# subsequent change goes through Git. Specifically: this gets deleted
# from your fork the day Argo CD ships a self-bootstrapping init
# container (or the cluster API itself learns to seed ArgoCD).
#
# After this finishes, you do NOT run the script again on the same
# cluster. Re-running on an existing install is idempotent (Helm
# upgrades to the same version are no-ops; root.yaml apply is
# server-side-applied), but the design intent is "this is the only
# manual step — after this, GitOps takes over."
#
# See .claude/rules/no-scripts-as-design.md for the rule.
#
# Companion scripts:
#   scripts/adapt-to-your-cluster.sh   — run BEFORE this script.
#                                        Substitutes __REPLACE_ME_*__
#                                        tokens. Bootstrap fails if any
#                                        remain.
#   scripts/seal-secret.sh             — generate the kopia password
#                                        SealedSecret. Can be run
#                                        before or after this script;
#                                        the cluster works without it
#                                        until the first PVC backup
#                                        attempt.
#
# Usage:
#   ./scripts/bootstrap-argocd.sh           # bootstrap from scratch
#   ./scripts/bootstrap-argocd.sh --force   # allow version mismatch
#   ./scripts/bootstrap-argocd.sh --help

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# Pinned ArgoCD chart version. MUST match
# infrastructure/controllers/argocd/kustomization.yaml's helmCharts
# version — Wave 0 will reconcile this controller against the chart
# version listed there. If the bootstrap installs a different version,
# Wave 0 will perform an in-place upgrade on first sync.
ARGOCD_CHART_VERSION="9.5.9"

# Pinned Cilium minimum version. The starter ships Cilium at this
# version via Helm; bootstrapping ArgoCD without Cilium first means CNI
# is missing and pod scheduling fails. Adjust if you bump
# infrastructure/networking/cilium/kustomization.yaml's version.
EXPECTED_CILIUM_VERSION="1.19.3"

FORCE="false"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# *//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE="true"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────
# Pre-flight: tools
# ─────────────────────────────────────────────────────────────────────
for tool in kubectl helm; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "ERROR: $tool is not installed." >&2
    exit 1
  fi
done

if command -v cilium > /dev/null 2>&1; then
  CILIUM_CMD="cilium"
elif command -v cilium-cli > /dev/null 2>&1; then
  CILIUM_CMD="cilium-cli"
else
  CILIUM_CMD=""
fi

# ─────────────────────────────────────────────────────────────────────
# Pre-flight: cluster reachability
# ─────────────────────────────────────────────────────────────────────
if ! kubectl get --raw='/healthz' > /dev/null 2>&1; then
  echo "ERROR: cannot reach the cluster API server." >&2
  echo "  Check kubeconfig: kubectl cluster-info" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# Pre-flight: refuse if any __REPLACE_ME_*__ tokens remain in the
# manifests this script applies. Substitution must happen before
# bootstrap or ArgoCD will try to clone repoURL=__REPLACE_ME_*__ and
# loop forever.
# ─────────────────────────────────────────────────────────────────────
echo "Pre-flight: checking for unsubstituted placeholders..."
mapfile -t REMAINING < <(
  grep -rl '__REPLACE_ME_[A-Z0-9_]\+__' \
    "$ROOT_DIR/infrastructure/controllers/argocd" 2>/dev/null \
    | sort -u
)
if [ "${#REMAINING[@]}" -gt 0 ]; then
  echo "ERROR: __REPLACE_ME_*__ tokens still present in argocd manifests:" >&2
  for f in "${REMAINING[@]}"; do
    echo "  $f" >&2
  done
  echo "" >&2
  echo "  Run scripts/adapt-to-your-cluster.sh first." >&2
  exit 1
fi
echo "  OK"

# ─────────────────────────────────────────────────────────────────────
# Pre-flight: Cilium installed + healthy. ArgoCD Wave 0 will adopt the
# Cilium install via the Helm chart in infrastructure/networking/cilium/
# — but Cilium has to be present BEFORE the ArgoCD pods themselves can
# be scheduled (no CNI = no pod networking = no controller pods).
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Pre-flight: checking Cilium..."
if [ -z "$CILIUM_CMD" ]; then
  echo "ERROR: cilium CLI not found." >&2
  echo "  Install: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/" >&2
  exit 1
fi

if ! "$CILIUM_CMD" status --wait --wait-duration 30s > /dev/null 2>&1; then
  echo "ERROR: Cilium is not healthy. Install Cilium first:" >&2
  echo "" >&2
  echo "    $CILIUM_CMD install --version $EXPECTED_CILIUM_VERSION \\" >&2
  echo "        --set cluster.name=__REPLACE_ME_CLUSTER_NAME__ \\" >&2
  echo "        --set ipam.mode=kubernetes \\" >&2
  echo "        --set kubeProxyReplacement=true \\" >&2
  echo "        --set k8sServiceHost=localhost \\" >&2
  echo "        --set k8sServicePort=7445 \\" >&2
  echo "        --set gatewayAPI.enabled=true" >&2
  echo "" >&2
  exit 1
fi
echo "  OK: Cilium reports healthy"

# ─────────────────────────────────────────────────────────────────────
# Idempotency: detect existing ArgoCD install. If it's already at the
# pinned version, exit cleanly. If it's at a different version, refuse
# unless --force is set.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Checking for existing ArgoCD install..."
EXISTING_VERSION=""
if helm get metadata argocd -n argocd > /dev/null 2>&1; then
  EXISTING_VERSION=$(helm get metadata argocd -n argocd -o json 2>/dev/null \
    | grep -o '"version":"[^"]*"' | head -1 | sed 's/.*":"\([^"]*\)"/\1/' || true)
fi

if [ -n "$EXISTING_VERSION" ]; then
  if [ "$EXISTING_VERSION" = "$ARGOCD_CHART_VERSION" ]; then
    echo "  ArgoCD $EXISTING_VERSION already installed and matches pin."
    echo "  Skipping Helm install. (Re-applying root.yaml below for"
    echo "  idempotency — server-side apply, no-op if unchanged.)"
  else
    echo "ERROR: ArgoCD $EXISTING_VERSION installed; pin is $ARGOCD_CHART_VERSION." >&2
    if [ "$FORCE" != "true" ]; then
      echo "  Refusing to upgrade automatically." >&2
      echo "  Re-run with --force to allow Helm to upgrade in place," >&2
      echo "  or uninstall first: helm uninstall argocd -n argocd" >&2
      exit 1
    fi
    echo "  --force set; proceeding with Helm upgrade."
    EXISTING_VERSION=""
  fi
else
  echo "  No existing install detected."
fi

# ─────────────────────────────────────────────────────────────────────
# Step 1: namespace
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Step 1/4: ensuring argocd namespace..."
kubectl apply -f "$ROOT_DIR/infrastructure/controllers/argocd/ns.yaml"

# ─────────────────────────────────────────────────────────────────────
# Step 2: Helm install/upgrade
# ─────────────────────────────────────────────────────────────────────
if [ -z "$EXISTING_VERSION" ]; then
  echo ""
  echo "Step 2/4: installing ArgoCD chart $ARGOCD_CHART_VERSION via Helm..."
  helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd \
    --values "$ROOT_DIR/infrastructure/controllers/argocd/values.yaml" \
    --wait \
    --timeout 10m
else
  echo ""
  echo "Step 2/4: skipping Helm install (existing version matches pin)"
fi

# ─────────────────────────────────────────────────────────────────────
# Step 3: wait for the CRDs + application-controller to be Ready
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Step 3/4: waiting for ArgoCD CRDs + application-controller..."
kubectl wait --for=condition=established --timeout=60s \
  crd/applications.argoproj.io
kubectl wait --for=condition=Available --timeout=300s \
  deployment/argocd-server -n argocd
# application-controller is a StatefulSet — wait on the underlying pod.
kubectl rollout status statefulset/argocd-application-controller \
  -n argocd --timeout=300s

# ─────────────────────────────────────────────────────────────────────
# Step 4: apply the root Application — this is the kick-off that turns
# ArgoCD into a self-managing GitOps controller. After this, ArgoCD
# discovers infrastructure/controllers/argocd/apps/, creates AppSets
# + bootstrap Applications, and the rest of the cluster comes up in
# sync-wave order.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Step 4/4: applying root Application (GitOps takeover)..."
kubectl apply -f "$ROOT_DIR/infrastructure/controllers/argocd/root.yaml"

echo ""
echo "Bootstrap complete. ArgoCD now manages itself."
echo ""
echo "Watch the sync waves come up:"
echo "  kubectl get applications -n argocd -w"
echo ""
echo "  Wave 0: Cilium adoption, sealed-secrets, ESO, AppProjects"
echo "  Wave 1: Longhorn, Snapshot Controller, VolSync, pvc-plumber"
echo "  Wave 2: pvc-plumber webhook configs (FAIL-CLOSED admission gate)"
echo "  Wave 3: CNPG Barman Plugin"
echo "  Wave 4: Infrastructure AppSet + Database AppSet"
echo "  Wave 5: Monitoring AppSet (Prometheus, Grafana, Loki)"
echo "  Wave 6: Apps AppSet (your workloads)"
echo ""
echo "ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Open: https://localhost:8080"
echo ""
echo "If you haven't sealed the kopia password yet, do it now —"
echo "PVC backups will fail until then:"
echo "  ./scripts/seal-secret.sh --kopia-password"
