# CNPG (CloudNativePG), explained for homelabbers

Companion to the technical CNPG runbook. This doc is the conversational version — what's actually happening, why it works, and **what's a Git change vs. a kubectl command vs. a feature flag**.

If you've already read [`docs/pvc-plumber-explained.md`](pvc-plumber-explained.md), you already know the homelabber-doc style. Read this one when:

- You're standing up your first Postgres cluster on Kubernetes
- You're staring at a CNPG `Cluster` CR and wondering "where's the backup config and why are there two overlays"
- You need to do a real disaster recovery and want to understand each step BEFORE you type `kubectl delete cluster`

## Status — 2026-05-08 baseline

This starter ships with the **CNPG Barman Cloud Plugin** (`spec.plugins[]`), not the deprecated in-tree `spec.backup.barmanObjectStore`. The plugin path is what CNPG 1.30+ requires; the starter is set up correctly for the modern operator.

---

## TL;DR

Two layers of database state, two backup paths, **never confuse them**:

| Thing | Backed up by | Lives on |
|---|---|---|
| **Postgres data** (the actual database content — tables, rows, WAL) | Barman Cloud → S3 | Cluster CR + PVCs |
| **App-side stuff** (ExternalSecret, ScheduledBackup, Cluster YAML) | Git | The repo |

When you do a disaster recovery, you're using **Barman** to restore Postgres data into a fresh PVC. **pvc-plumber/VolSync has nothing to do with this.** The two backup systems run side-by-side and never touch each other. PVC-level kopia backups would corrupt a running Postgres mid-snapshot — that's why CNPG PVCs explicitly do NOT carry the `backup` label.

---

## The pieces in plain English

```
┌─────────────────────────────────────────────────────────────────┐
│ YOUR APP NAMESPACE                     YOUR DATABASE NAMESPACE  │
│  (e.g. <your-app>/)                     (e.g. cloudnative-pg/)  │
│                                                                 │
│   ┌──────────────────┐                  ┌────────────────────┐  │
│   │  app pods        │   psql           │  Cluster CR        │  │
│   │  (frontend,      │ ───────────────▶ │  (1 primary +      │  │
│   │   workers, etc)  │                  │   optionally       │  │
│   └──────────────────┘                  │   replicas)        │  │
│                                         │                    │  │
│                                         │  Barman plugin     │  │
│                                         │   ↓ continuous WAL │  │
│                                         │   ↓ daily base     │  │
│                                         └────────────────────┘  │
│                                                  │              │
│                                                  ▼              │
│                                   ┌────────────────────────┐    │
│                                   │  Your S3 bucket        │    │
│                                   │  cnpg-backups/         │    │
│                                   │   <app>/               │    │
│                                   │     <app>-database-vN/ │    │
│                                   │       base/    ← full  │    │
│                                   │       wals/    ← WAL   │    │
│                                   └────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

**Five pieces:**

1. **The CNPG operator** — runs in `cloudnative-pg` namespace, watches Cluster CRs, creates the Postgres pods + PVCs.
2. **The Cluster CR** — declares "I want a Postgres cluster called X with these resources, this version, this backup config." Lives in `apps/postgres-demo/base/cluster.yaml` in this starter.
3. **The Barman plugin** — sidecar that pushes WAL + base backups to S3 continuously. Configured via `spec.plugins[]` on the Cluster.
4. **The ObjectStore CR** — sibling to the Cluster CR. Holds the S3 endpoint + credentials. The plugin references it by name.
5. **The ScheduledBackup CR** — tells Barman "take a base backup every day at this time." Without this, you only have WAL (PITR works but full restore is slow).

This starter ships an **in-cluster MinIO** (under `apps/postgres-demo/minio/`) as the S3 endpoint by default, so the demo works out of the box without external S3 setup. For production use cases you'd point the ObjectStore at your real S3 (RustFS, AWS S3, Backblaze B2, MinIO on TrueNAS, etc.).

---

## How a normal day looks (steady-state operation)

Once everything's running, **nothing changes**. The Cluster's `spec.bootstrap` is no-op on a Cluster that already exists — CNPG only evaluates it on first creation.

- App pods do `INSERT/UPDATE/DELETE` against Postgres
- Postgres writes WAL records to local disk
- Barman plugin streams those WAL records to S3 every few seconds
- Once a day, ScheduledBackup runs a full base backup (`pg_basebackup` + manifest) and stores it in S3
- WAL retention: kept indefinitely on S3 (until lifecycle pruning kicks in)
- Base backups: kept per the retention policy you set

Result: at any moment, you can restore the database to **any point in time** within your WAL retention window. That's "PITR" — point-in-time recovery.

---

## Two overlays, one feature flag

This is the part that confuses people on day one. Each database directory in this starter looks like this:

```
apps/postgres-demo/
├── kustomization.yaml        ← the FEATURE FLAG (one line)
├── namespace.yaml
├── objectstore.yaml          ← S3 endpoint + creds (the ObjectStore CR)
├── scheduled-backup.yaml     ← schedule, never touched during DR
├── minio/                    ← in-cluster S3 backend (demo only)
├── base/
│   ├── kustomization.yaml
│   └── cluster.yaml          ← the Cluster CR WITHOUT bootstrap
└── overlays/
    ├── initdb/
    │   ├── kustomization.yaml
    │   └── bootstrap-patch.yaml    ← adds spec.bootstrap.initdb
    └── recovery/
        ├── kustomization.yaml
        └── bootstrap-patch.yaml    ← adds spec.bootstrap.recovery + externalClusters
```

**Why two overlays?** `spec.bootstrap.initdb` and `spec.bootstrap.recovery` are mutually exclusive. CNPG's webhook rejects a Cluster manifest with both. Keeping each in its own overlay means kustomize renders only one at a time → CNPG sees a valid Cluster.

**The feature flag** is one commented line in the root `kustomization.yaml`:

```yaml
resources:
  - overlays/initdb        # ← ACTIVE: normal operation, fresh DB
 # - overlays/recovery     # ← swap here for disaster recovery
  - objectstore.yaml
  - scheduled-backup.yaml
```

To switch modes: comment one line, uncomment the other, commit, push. **That's the entire feature flag.**

---

## What's a Git change vs kubectl vs feature flag — explicit table

This is what trips homelabbers up. CNPG DR is a hybrid procedure: some steps go through Git (because they're declarative and you want them in the audit log), and some steps are imperative (because you're forcibly mutating live cluster state to make CNPG re-evaluate).

| Step | Type | Why |
|---|---|---|
| Update `base/cluster.yaml` `serverName: vN → vN+1` | **Git commit** | New WAL writes need a clean prefix on S3. Declared in Git. |
| Update `overlays/recovery/bootstrap-patch.yaml` `externalClusters.serverName: vN-1 → vN` | **Git commit** | Recovery reads FROM the previous lineage. Declared in Git. |
| Flip root `kustomization.yaml` from `overlays/initdb` to `overlays/recovery` | **Git commit (the feature flag)** | This is the single line that switches CNPG from "fresh-init mode" to "restore mode" on next Cluster creation. |
| `git push` | nothing magic — just makes ArgoCD see the new state | |
| `kubectl annotate application <db> argocd.argoproj.io/refresh=hard` | **kubectl** | ArgoCD's manifest cache is sticky. Force it to re-render against the new commit. **Skipping this step is the #1 cause of "I committed the recovery flip but ArgoCD still spawned a fresh-init cluster" — the manifest cache served the stale pre-flip render.** |
| `kubectl delete cluster <db>` | **kubectl** | Live mutation. CNPG only evaluates `spec.bootstrap` on Cluster CREATE, never on update. To force a fresh bootstrap evaluation we MUST delete and recreate. |
| `kubectl delete pvc -l cnpg.io/cluster=<db>` | **kubectl** | CNPG leaves PVCs as data-protection. Delete them explicitly so the new Cluster doesn't reattach to the old (corrupt or empty) data. |
| Trigger ArgoCD sync via `kubectl patch application` | **kubectl** | Once Cluster + PVCs are gone, ArgoCD recreates them from the new manifest (now with `bootstrap.recovery`). |
| CNPG operator runs `barman-cloud-restore` | automatic | Pulls base backup + replays WAL until tip. |
| Restart consumer apps via `kubectl rollout restart` | **kubectl** | Existing app pods cached the old DB connection — they'll error retry until restarted. |
| (Optional) flip kustomization back to `overlays/initdb` | **Git commit** | Cosmetic. Once the Cluster exists, `spec.bootstrap` is a no-op. Both overlays are valid for steady-state declarations. |

The pattern: **Git declares intent. kubectl forces the cluster to act on the new intent.** CNPG's "bootstrap-on-create-only" rule means you can't just `kubectl apply` a recovery patch onto an existing Cluster — you have to delete + recreate. That's the imperative step the runbook can't skip.

---

## Why "lineage" — what does `-v1`, `-v2`, `-v3` mean?

CNPG requires a **clean WAL archive** for every newly-created Cluster. After a recovery, the new Cluster cannot write WAL to the same S3 directory the previous Cluster wrote to (WAL files would collide and corruption-detection would scream).

So every recovery bumps `serverName` by one:

```
s3://cnpg-backups/<your-app>/
├── <your-app>-database-v1/   ← original / day-0 lineage (long-since pruned)
├── <your-app>-database-v2/   ← lineage created after first DR (current source for restore)
│   ├── base/                  full backups
│   └── wals/                  WAL archive — append-only
└── <your-app>-database-v3/   ← lineage opened by THIS DR drill (where new WAL writes go now)
    ├── base/
    └── wals/
```

During DR, you restore FROM lineage `v(N-1)` and point new backups AT lineage `vN`. The prior lineage stays untouched as a safety net for future DR events (if `v3` itself ever needs restoring, you'd recover from `v2` and bump to `v4`).

The two `serverName` fields have to move in lockstep, IN THE SAME COMMIT:

| File | Field | Before | After |
|---|---|---|---|
| `base/cluster.yaml` | `parameters.serverName` | `<your-app>-database-v2` | `<your-app>-database-v3` |
| `overlays/recovery/bootstrap-patch.yaml` | `externalClusters.parameters.serverName` | `<your-app>-database-v1` | `<your-app>-database-v2` |

If you bump one without the other, you'll either restore from the wrong lineage OR write WAL to a serverName that doesn't exist yet, OR collide with the existing live lineage.

---

## A real DR drill — what it looks like in chronological order

Verified live on 2026-05-08 against a `temporal-database` cluster on the source cluster.

```
T+0:00  pre-flight: capture row counts (history_node=109986, executions=6384,
        namespaces=2, tasks=5)

T+0:30  verify Barman has v2 WAL on S3 (latest WAL written 2026-05-08T20:49Z)

T+1:00  GIT: edit three files:
          base/cluster.yaml         serverName  v2 → v3
          overlays/recovery/bootstrap-patch.yaml
                                    serverName  v1 → v2
          kustomization.yaml        flag        initdb → recovery
T+1:30  GIT: commit + push  (ec0335d8 in source cluster history)

T+2:00  KUBECTL: hard-refresh ArgoCD manifest cache
        verify: kubectl get app <db> -o jsonpath='...resources[?Cluster].status'
        → "OutOfSync" — proves cache picked up new manifest

T+2:30  KUBECTL: delete live Cluster + both PVCs
          kubectl delete cluster <db>
          kubectl delete pvc -l cnpg.io/cluster=<db>
        wait ~30s for PVCs to finish Terminating

T+3:30  KUBECTL: trigger ArgoCD sync. CNPG sees Cluster gone, recreates it
        from the (now recovery-overlayed) manifest

T+4:00  CNPG creates `<db>-1-full-recovery-XXXXX` pod
        running barman-cloud-restore. Two containers visible:
          - full-recovery (postgres) — running pg_wal_replay
          - plugin-barman-cloud-sidecar — pulling blobs from S3

T+4:30  pod is `Init:0/2` → `Init:1/2` → `Running` (~50s)

T+4:50  Postgres begins WAL replay. Logs show repeating:
          "restored log file 0000000100000007000000XX from archive"
          "redo in progress, elapsed time: 432s, current LSN: 7/761AA5B0"
        WAL files come from S3 one at a time, replayed sequentially.

T+5..T+12  WAL replay phase. ~1-2 sec per WAL file. Phase length depends on
        how much WAL accumulated since the last base backup. For a small
        DB with many hours of activity, this is the dominant time cost.

T+12:30  consistent recovery state reached. Pod transitions from
        full-recovery to becoming the actual primary.

T+13:00  Cluster phase transitions:
          "Setting up primary" → "Cluster in healthy state"

T+13:30  verify row counts. Should match pre-flight baseline EXCEPT for
        any rows committed AFTER the latest archived WAL (which our
        recovery couldn't replay).

T+14:00  KUBECTL: rollout-restart the consumer apps so they reconnect:
          kubectl -n <your-app> rollout restart deploy/<your-app>-frontend
          (etc. for each consumer)

DONE. Total wall-clock: 14 minutes for a 10Gi DB with ~12 hours of WAL
to replay. Most of that was WAL replay; the actual pod creation +
operator orchestration was ~2 minutes.
```

---

## Common gotchas (real, hit in past drills)

1. **Forgot to hard-refresh ArgoCD before deleting the Cluster.** ArgoCD recreates the Cluster from its CACHED manifest (still showing `bootstrap.initdb`), giving you a fresh empty database despite Git being correctly flipped to recovery. Always hard-refresh first, then verify the resource shows OutOfSync, THEN delete.

2. **`recoveryTarget.targetTime` set to a date that predates the earliest archived WAL.** Postgres FATAL: "recovery ended before configured recovery target was reached." Fix: omit the target entirely (restores to latest-WAL) OR set a target you've verified exists in S3.

3. **Deleted Cluster but forgot to delete PVCs.** New Cluster spawns, tries to attach the old (empty post-init or corrupt) PVCs, hangs in "Setting up primary" forever. Fix: `kubectl delete pvc -l cnpg.io/cluster=<db>` and wait for them to fully Terminate.

4. **Forgot to bump `serverName` in `base/cluster.yaml`.** New Cluster comes up, starts writing WAL to the OLD serverName (the same one we just restored from). Now your recovery source is being polluted by new writes. Fix: revert, bump serverName properly, redo the drill.

5. **Forgot to bump `externalClusters.serverName` in the recovery overlay.** Recovery pulls from the OLDEST lineage instead of the most recent. You restore to a much older state than expected.

6. **Consumer apps not restarted after recovery.** They cached the old DB connection (which is now invalid). They'll error connecting and won't recover until rolled. Fix: `kubectl rollout restart` everything that talks to the DB.

7. **Recovery overlay's `database` and `owner` fields missing.** CNPG defaults to `database: app, owner: app`. If your real DB owner is something else, you'll create the right lineage but the wrong role grants. Always specify both explicitly.

---

## Why this is separate from pvc-plumber

A reasonable question: pvc-plumber backs up PVCs to kopia. CNPG database files live on PVCs. Why not just label the CNPG PVCs and let pvc-plumber back them up?

Three reasons, in increasing severity:

1. **Snapshot consistency.** A kopia snapshot of a running Postgres data directory is *not* a consistent backup. The on-disk state at any moment includes half-written files, WAL not yet flushed, etc. Restoring from a CSI snapshot of running Postgres almost works, but recovery is unsafe and Postgres might not even start. Barman uses `pg_basebackup` which IS Postgres-aware and produces a consistent backup.

2. **WAL.** Postgres recovery requires both a base backup AND the WAL records that follow it. Barman archives WAL continuously. PVC snapshots don't archive WAL — they just snapshot whatever WAL was on disk at snapshot time, which could be hours old.

3. **PITR.** With Barman + WAL archiving, you can restore to any point in time within retention. With PVC snapshots, you can only restore to whenever the last snapshot was taken (default 1h or 1d).

So: CNPG PVCs are explicitly **NOT** labeled `backup: hourly|daily`. pvc-plumber's mutating webhook would refuse to inject `dataSourceRef` on those anyway (operator's `SYSTEM_NAMESPACES` excludes `cnpg`-typical namespaces if you add yours), but as defense-in-depth, the manifest convention is to omit the label.

---

## FAQ

### Where do app credentials live?

Each DB directory has a credentials Secret that ESO templates from your secret-store backend (sealed-secrets default in this starter). Apps read connection strings via `valueFrom.secretKeyRef`.

### How do I add a new CNPG database?

Copy the `apps/postgres-demo/` directory to `apps/<your-app>/`, rename names + owner + image + initdb SQL. Set `base/cluster.yaml` `serverName` to `<your-app>-database-v1`. Set `overlays/recovery/bootstrap-patch.yaml` `externalClusters.serverName` to the same `-v1` (placeholder until first DR). Commit + push. The Database AppSet auto-discovers `apps/*` — no appset edits needed.

### What if I just want a fresh DB (no recovery)?

Leave the kustomization flag on `overlays/initdb`. That's the steady-state mode. CNPG creates the Cluster fresh, runs initdb SQL, starts archiving WAL to a brand-new lineage on S3.

### How long does recovery take?

Two phases: pulling the base backup (fast, ~1-2 min for a 10Gi DB) + replaying WAL (slow, depends on how much WAL accumulated). For a small DB with hours of WAL, expect 10-15 min. For a large DB or days of WAL, hours. The progress is observable in the recovery pod's logs as `redo in progress, elapsed time: ...`.

### Can I restore to a different cluster name (test recovery without nuking prod)?

Yes — CNPG supports `bootstrap.recovery` with a different `metadata.name`. The recovery pulls FROM the lineage you specify and creates a brand-new cluster in parallel. Useful for "let me see if my backup is good" without blowing away the live one. Out of scope for the runbook above (which is destructive in-place).

### Why MinIO for the demo and not external S3?

The starter ships with an in-cluster MinIO under `apps/postgres-demo/minio/` so the demo is fully self-contained — `git clone && bootstrap` and you have working WAL archive + base backups without external dependencies. For production you'd swap the ObjectStore endpoint to point at your real S3 (RustFS / AWS S3 / Backblaze B2 / MinIO on TrueNAS / etc.) and the rest of the manifest is unchanged.

### What about lifecycle pruning of old `-vN` lineages?

Configure your S3 backend's lifecycle rules to expire objects under `cnpg-backups/<app>/<app>-database-vN/` after N days where N exceeds your worst-case "I might still need to recover from this" window. The `apps/postgres-demo/minio/bootstrap-job.yaml` shows the `mc ilm rule add --expire-days 30` pattern; for AWS S3 use a Lifecycle policy with a prefix filter; for RustFS the bucket lifecycle config CRD applies.

---

## Where to go deeper

- [docs/pvc-plumber-explained.md](pvc-plumber-explained.md) — the OTHER backup system (PVC-level, kopia, NEVER use on CNPG PVCs)
- [docs/architecture.md](architecture.md) — sync waves, ApplicationSet discovery, GitOps self-management
- CNPG operator chart docs — for in-tree → plugin migration history (if you're moving from an old setup)
