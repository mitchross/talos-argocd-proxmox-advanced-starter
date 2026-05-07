# CLAUDE.md

Guidance for Claude Code when working in this repo.

## Project Overview

`talos-argocd-proxmox-advanced-starter` is a GitOps Kubernetes starter
kit for Proxmox homelabs. It demonstrates the patterns that matter at
scale (sync waves, self-managing ArgoCD, PVC backup automation,
Gateway API) without the homelab-specific accidents (paid services,
GPU hardware, proprietary apps).

90% of the patterns are ported from a working homelab cluster
([`mitchross/talos-argocd-proxmox`](https://github.com/mitchross/talos-argocd-proxmox)),
adapted to be reproducible by anyone with a Proxmox host.

## Source repos

When porting patterns into this starter:

- **Working cluster** (the source of truth for "how does this actually work?"):
  `/home/vanillax/programming/talos-argocd-proxmox`
- **Talos/Omni infra base** (reference for Sidero provisioning):
  https://github.com/mitchross/sidero-omni-talos-proxmox-starter
- **Existing starter (predecessor)** (reference for the basic shape):
  https://github.com/mitchross/talos-argocd-proxmox-starter

When the source cluster has 8 different example apps and we only need 1
representative demo, **prefer simpler over more thorough**. This is a
starter — opinionated minimalism beats comprehensive.

## Critical rules (inherited from the source cluster)

### DO:
- Use directory structure for application discovery (no manual Application resources)
- Sync waves on every infrastructure component — order is the architecture
- Name Service ports for HTTPRoute compatibility (`name: http`) — fails silently otherwise
- Use Gateway API (not Ingress) — exclusively
- List ALL YAML files in each directory's `kustomization.yaml` under `resources:` — unlisted files are never deployed
- Pin Helm chart versions explicitly
- Document every "advanced extension" as a separate doc, not inline

### DON'T:
- Reference paid services (1Password Connect, Cloudflare tunnel) without a free-tier alternative documented
- Hardcode the user's IP addresses, domain names, NFS server paths — use placeholders + adaptation script
- Include proprietary or GPU-specific workloads in the default starter
- Skip sync waves for "small" infrastructure components — cold-boot races bite later
- Auto-merge major Helm chart bumps for critical infra (kube-prometheus-stack, longhorn, cilium)

## Adaptation contract

Anything that needs to be edited per-cluster goes through
`scripts/adapt-to-your-cluster.sh`. Placeholders use the form
`__REPLACE_ME_<name>__` so the adapt script can find and substitute them.
Common placeholders:

- `__REPLACE_ME_DOMAIN__` — your domain (e.g., `homelab.example.com`)
- `__REPLACE_ME_NFS_SERVER__` — NFS server IP (optional, for VolSync repository)
- `__REPLACE_ME_NFS_PATH__` — NFS export path
- `__REPLACE_ME_PROXMOX_HOST__` — Proxmox API endpoint
- `__REPLACE_ME_GIT_REPO_URL__` — your fork URL (used in ArgoCD apps)

Add new placeholders to `scripts/adapt-to-your-cluster.sh` when you
introduce one.

## Demo app contract

Demo apps live under `apps/` and are intentionally minimal. Each demo
app exists to **demonstrate one platform feature**:

- `apps/nginx-demo/` — stateless app + HTTPRoute (Gateway API demo)
- `apps/stateful-demo/` — PVC with `backup: hourly` label (pvc-plumber demo)
- `apps/postgres-demo/` — CNPG database with Barman S3 backup (database DR demo)

Don't add a 4th demo unless it teaches a meaningfully new pattern.

## Mink + memory

When introducing patterns ported from the source cluster, capture the
"why this shape" in the relevant `docs/*.md` file inline — this repo is
itself a teaching artifact. No separate Mink notes for in-repo content;
Mink stays for cross-project knowledge.
