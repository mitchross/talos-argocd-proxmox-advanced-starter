# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this repo is

A **starter kit pruned from a live production homelab**
([talos-argocd-proxmox](https://github.com/mitchross/talos-argocd-proxmox) —
"the parent"). Same directory shape, same sync waves, same patterns. When in
doubt about a pattern, the parent repo and its docs site
(https://mitchross.github.io/talos-argocd-proxmox/) are the source of truth.

Stack: Talos (via Omni/Proxmox) + self-managing ArgoCD + Cilium Gateway API
+ Longhorn + **kopiur** (PVC backups, restore-before-bind) + CNPG/Barman
(Postgres) + 1Password/ESO (secrets) + off-cluster RustFS S3.

## Critical rules (inherited from the parent, all field-tested)

- **Directory = Application.** AppSets discover `my-apps/*/*`,
  `infrastructure/database/*/*`, `monitoring/*`; infrastructure uses an
  EXPLICIT path list in `appsets/infrastructure-appset.yaml`. Never write
  manual `Application` manifests for apps.
- **Every YAML in `infrastructure/controllers/argocd/apps/` must be listed
  in that dir's `kustomization.yaml`** — unlisted files are never deployed.
- **Sync waves 0–6** (see `docs/architecture.md`). New infra components get
  a wave; observability is never a core dependency (kube-prometheus-stack is
  the sole owner of `monitoring.coreos.com` CRDs, Wave 5).
- **Backups are kopiur.** Per-PVC stub (`kopiur/<pvc>.yaml`:
  SnapshotPolicy + SnapshotSchedule + Restore) + the shared
  `my-apps/common/kopiur-backup` component + namespace label
  `kopiur.home-operations.com/repo: cluster-kopia` + PVC
  `dataSourceRef → <pvc>-restore` with the two `ServerSide*` annotations.
  The **mover runs as the data-owner uid:gid** (baseline PSS strips
  capabilities — root movers can't read non-root data). Never resurrect
  pvc-plumber/VolSync/sealed-secrets (pre-`phase 3a` history only).
- **Exempt PVCs** carry `backup-exempt: "true"` + the fully-qualified
  `storage.vanillax.dev/backup-exempt-reason` annotation and NO
  `dataSourceRef` (a dangling one deadlocks the PVC `Pending`).
- **CNPG databases never use kopiur** — Barman → `postgres-backups` bucket.
  The database AppSet runs `selfHeal: false` on purpose (DR annotations).
- **Gateway API only** (no Ingress). Services need **named ports**
  (`name: http`) or HTTPRoutes fail silently. External routes need all
  three: `external-dns: "true"` label + `external-dns.alpha.kubernetes.io/target`
  annotation + `sectionName: https`.
- **RWO PVC deployments use `strategy: type: Recreate`** (RollingUpdate =
  Multi-Attach deadlock).
- **Jobs need ArgoCD hook annotations** (`hook: Sync` +
  `hook-delete-policy: BeforeHookCreation`) — Jobs are immutable; image
  bumps break sync otherwise. Never `Replace=true,Force=true` on Jobs.
- **Helm charts with webhooks**: prefer `certManager.enabled: true`-style
  options; never a helm hook Job for webhook certs under ArgoCD.
- **Pin image SHAs** (`@sha256:`), Renovate manages bumps.
- **Talos 1.13 needs explicit `machine.install.disk`** — the template
  carries it; removing it wedges fresh VMs in UPGRADING silently.

## Verify before claiming done

```bash
# every kustomization renders
for d in $(find infrastructure monitoring my-apps -name kustomization.yaml -exec dirname {} \;); do
  kubectl kustomize --enable-helm "$d" > /dev/null || echo "FAIL: $d"; done
# backup coverage contract
python3 scripts/validate-kopiur-coverage.py <rendered-stream>
# app-listing rule
./scripts/validate-argocd-apps.sh
```

## Reference examples in-tree

| Pattern | Where |
|---|---|
| Minimal app | `my-apps/development/nginx/` |
| kopiur backup + deliberate exempt (one app, both) | `my-apps/media/karakeep/` |
| Helm+Kustomize, external route, helm-PVC dataSourceRef patch | `my-apps/development/gitea/` |
| CNPG database (initdb/recovery overlays, lineage) | `infrastructure/database/cloudnative-pg/gitea/` |
| Shared backup component | `my-apps/common/kopiur-backup/` |
