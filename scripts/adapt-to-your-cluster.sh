#!/usr/bin/env bash
# adapt-to-your-cluster.sh — substitute __REPLACE_ME_*__ tokens
# with your homelab's real values, in-place across the repo.
#
# Why this is in scripts/: one-shot bootstrap operation. You run it
# exactly once when you fork the starter and adapt it to your cluster.
# After commit + push, ArgoCD takes over and the script never runs
# again. Specifically: this gets deleted from your fork the moment
# you've finished substituting tokens — there's no recurring
# operational role here.
#
# See .claude/rules/no-scripts-as-design.md for the rule.
#
# Companion docs:
#   docs/adapting-to-your-cluster.md   — placeholder reference table
#   scripts/seal-secret.sh             — for the kopia password
#   scripts/bootstrap-argocd.sh        — run AFTER this script, after
#                                        you commit + push your fork
#
# Usage:
#   ./scripts/adapt-to-your-cluster.sh           # interactive
#   ./scripts/adapt-to-your-cluster.sh --dry-run # show diff, don't write
#   ./scripts/adapt-to-your-cluster.sh --help

set -euo pipefail

DRY_RUN="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="true" ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# ─────────────────────────────────────────────────────────────────────
# Safety: refuse to run on a dirty working tree. Substitution rewrites
# tracked files in-place; mixing those changes with uncommitted work
# would make `git diff` impossible to review. Stash or commit first.
# ─────────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = "false" ]; then
  if ! git -C "$ROOT_DIR" diff --quiet --exit-code 2>/dev/null \
     || ! git -C "$ROOT_DIR" diff --cached --quiet --exit-code 2>/dev/null; then
    echo "ERROR: working tree has uncommitted changes." >&2
    echo "  Stash or commit first; this script rewrites tracked files." >&2
    echo "  (Re-run with --dry-run to preview without writing.)" >&2
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# Discover all __REPLACE_ME_*__ tokens currently in the repo.
# ─────────────────────────────────────────────────────────────────────
echo "Scanning repo for __REPLACE_ME_*__ tokens..."
mapfile -t TOKENS < <(
  grep -rho '__REPLACE_ME_[A-Z0-9_]\+__' "$ROOT_DIR" \
    --include='*.yaml' --include='*.yml' --include='*.json5' \
    --include='*.md' --include='*.sh' --include='*.example' \
    --include='*.env' \
    --exclude-dir='.git' --exclude-dir='charts' 2>/dev/null \
    | sort -u
)

if [ "${#TOKENS[@]}" -eq 0 ]; then
  echo "  No __REPLACE_ME_*__ tokens found. Repo already adapted."
  exit 0
fi

echo "  Found ${#TOKENS[@]} unique token(s):"
for t in "${TOKENS[@]}"; do
  count=$(grep -rl "$t" "$ROOT_DIR" --include='*.yaml' --include='*.yml' \
    --include='*.json5' --include='*.md' --include='*.sh' \
    --include='*.example' --include='*.env' \
    --exclude-dir='.git' --exclude-dir='charts' 2>/dev/null | wc -l)
  echo "    $t  (in $count file(s))"
done

# ─────────────────────────────────────────────────────────────────────
# Prompt for each token's replacement. Env-var override is supported
# for non-interactive usage: `export __REPLACE_ME_DOMAIN__=foo.example.com`
# before running, and that value is used without prompting.
# ─────────────────────────────────────────────────────────────────────
declare -A REPLACEMENTS

prompt_for() {
  local token="$1"
  local existing="${!token:-}"
  if [ -n "$existing" ]; then
    REPLACEMENTS["$token"]="$existing"
    echo "  $token = $existing  (from env)"
    return 0
  fi
  local hint=""
  case "$token" in
    __REPLACE_ME_DOMAIN__)            hint="e.g. homelab.example.com" ;;
    __REPLACE_ME_GIT_REPO_URL__)      hint="e.g. https://github.com/you/talos-argocd-proxmox-advanced-starter.git" ;;
    __REPLACE_ME_GIT_BRANCH__)        hint="e.g. main" ;;
    __REPLACE_ME_CLUSTER_NAME__)      hint="e.g. homelab" ;;
    __REPLACE_ME_NODE_CIDR__)         hint="e.g. 192.168.1.0/24" ;;
    __REPLACE_ME_LB_IP_POOL__)        hint="e.g. 192.168.1.32/27" ;;
    __REPLACE_ME_GATEWAY_IP__)        hint="e.g. 192.168.1.50" ;;
    __REPLACE_ME_PROXMOX_HOST__)      hint="e.g. https://192.168.1.10:8006/api2/json" ;;
    __REPLACE_ME_PROXMOX_TOKEN__)     hint="e.g. root@pam!iac=abcd-1234-..." ;;
    __REPLACE_ME_PROXMOX_STORAGE_POOL__) hint="e.g. local-zfs" ;;
    __REPLACE_ME_NFS_SERVER__)        hint="e.g. 192.168.1.100" ;;
    __REPLACE_ME_NFS_PATH__)          hint="e.g. /mnt/tank/k8s/volsync-kopia" ;;
    __REPLACE_ME_OMNI_ENDPOINT__)     hint="e.g. https://omni.homelab.example.com:443" ;;
    __REPLACE_ME_OMNI_HOST_IP__)      hint="e.g. 192.168.1.20" ;;
    __REPLACE_ME_S3_ENDPOINT__)       hint="bare host or IP, no scheme; e.g. minio.minio.svc or 192.168.1.100" ;;
    __REPLACE_ME_S3_PORT__)           hint="e.g. 9000 (MinIO), 443 (TLS S3)" ;;
    __REPLACE_ME_S3_BUCKET__)         hint="e.g. volsync-kopia" ;;
    *)                                hint="(no hint registered — see docs/adapting-to-your-cluster.md)" ;;
  esac
  printf "  %s\n    %s\n    Value: " "$token" "$hint"
  local val
  read -r val
  if [ -z "$val" ]; then
    echo "    SKIPPED (empty value — token will remain unsubstituted)"
    return 0
  fi
  REPLACEMENTS["$token"]="$val"
}

echo ""
echo "Enter replacement values. Press Enter on an empty line to skip a"
echo "token (it stays as __REPLACE_ME_*__ in the repo and you'll have"
echo "to come back to it). Pre-set via env: export <TOKEN>=value."
echo ""

for t in "${TOKENS[@]}"; do
  prompt_for "$t"
done

# ─────────────────────────────────────────────────────────────────────
# Confirm before writing.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Substitutions to apply:"
for t in "${TOKENS[@]}"; do
  v="${REPLACEMENTS[$t]:-<unchanged>}"
  printf "  %-40s -> %s\n" "$t" "$v"
done
echo ""

if [ "$DRY_RUN" = "true" ]; then
  echo "(--dry-run set; not writing)"
  exit 0
fi

printf "Apply these substitutions in-place? [y/N] "
read -r answer
if [ "${answer:-N}" != "y" ] && [ "${answer:-N}" != "Y" ]; then
  echo "Aborted. No files written."
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# Apply substitutions. Per-token sed because the replacement values
# may contain characters that conflict with a unified delimiter.
# ─────────────────────────────────────────────────────────────────────
WRITTEN=0
for t in "${TOKENS[@]}"; do
  v="${REPLACEMENTS[$t]:-}"
  [ -z "$v" ] && continue
  # Escape sed-special chars in the replacement value.
  escaped=$(printf '%s' "$v" | sed -e 's/[\/&|]/\\&/g')
  while IFS= read -r f; do
    sed -i "s|$t|$escaped|g" "$f"
    WRITTEN=$((WRITTEN + 1))
  done < <(
    grep -rl "$t" "$ROOT_DIR" --include='*.yaml' --include='*.yml' \
      --include='*.json5' --include='*.md' --include='*.sh' \
      --include='*.example' --include='*.env' \
      --exclude-dir='.git' --exclude-dir='charts' 2>/dev/null
  )
done

echo ""
echo "Wrote substitutions to $WRITTEN file(s)."
echo ""
echo "Next steps:"
echo "  1. Review the diff:    git diff"
echo "  2. Commit + push:      git add . && git commit -m 'config: adapt to my cluster' && git push"
echo "  3. Bootstrap ArgoCD:   ./scripts/bootstrap-argocd.sh"
echo ""
echo "If you missed a token, re-run this script. It's idempotent:"
echo "files already substituted will pass through untouched."
