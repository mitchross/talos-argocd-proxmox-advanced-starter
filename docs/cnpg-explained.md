# CNPG Postgres: backup, restore & start (gitea's database)

Postgres in this kit is run by **CloudNativePG** and backed up by the
**Barman Cloud Plugin** — SQL-aware backups to S3, completely separate from
kopiur's file-level PVC backups. The demo database is gitea's, at
[`infrastructure/database/cloudnative-pg/gitea/`](../infrastructure/database/cloudnative-pg/gitea/).
(The parent cluster's
[beginner guide](https://mitchross.github.io/talos-argocd-proxmox/domains/cnpg/backup-restore-start-guide/)
covers the same ground with more diagrams.)

## How backups work

Two things run continuously:

1. **Base backup** — a full snapshot of the database, daily
   (`scheduled-backup.yaml`).
2. **WAL archiving** — the Write-Ahead Log (every change, as it happens)
   ships to S3 as segments fill.

Base backup + WAL = **point-in-time recovery**: CNPG loads the last base
backup, then replays the journal forward.

> **Never** add kopiur CRs to a CNPG PVC. A filesystem snapshot of a running
> Postgres is crash-consistent at best; Barman is transaction-aware. Two
> systems, two buckets (`postgres-backups` vs `kopiur`), zero overlap.

## serverName = the lineage

`serverName` names the S3 folder one database's backups live in. The kit
ships `gitea-database-v1`. The rule that surprises everyone: **on every
restore you read FROM lineage `vN` and write forward TO a brand-new
`vN+1`** — Postgres requires a clean WAL archive for a fresh cluster
(`Expected empty archive` otherwise), and keeping the old lineage untouched
means it stays usable for future restores.

## The one feature flag

The database's `kustomization.yaml` activates exactly one overlay:

| Overlay | When | What it does |
|---|---|---|
| `overlays/initdb` | **normal life** | fresh empty DB on first creation; no-op on a running cluster |
| `overlays/recovery` | **DR only** | restore from the prior lineage, write forward to the new one |

## Restore (the 8 steps)

1. Bump `base/cluster.yaml` `serverName` → `vN+1`.
2. Point `overlays/recovery/bootstrap-patch.yaml` externalClusters at `vN`.
3. Flip `kustomization.yaml` → `overlays/recovery`.
4. Commit + push.
5. **Delete the live Cluster AND its PVCs** (CNPG only reads
   `spec.bootstrap` at creation; skipping the PVC delete = wedged at
   "Setting up primary"):
   ```bash
   kubectl -n cloudnative-pg delete cluster gitea-database
   kubectl -n cloudnative-pg delete pvc -l cnpg.io/cluster=gitea-database
   ```
6. Sync the ArgoCD app (hard-refresh first so it doesn't recreate from a
   stale render).
7. Watch the `gitea-database-1-full-recovery-*` pod; look for
   `consistent recovery state reached`.
8. Flip back to `overlays/initdb` once healthy, and rolling-restart gitea
   so it reconnects.

## Why the database AppSet has `selfHeal: false`

During DR you annotate/patch live CNPG objects; `selfHeal: true` would
strip those manual changes mid-recovery. The trade: normal drift isn't
auto-corrected for databases — deliberate.

## Gotchas

- `recoveryTarget.targetTime` past the last archived WAL → recovery pod
  crash-loops. When unsure, omit the target (restore to latest).
- `Expected empty archive` → your forward lineage is dirty; bump again.
- Consumer apps must be restarted after a restore or they hold stale
  connections.
