# kopiur, explained (why deleted volumes come back full)

[kopiur](https://github.com/home-operations/kopiur) is a Kopia-native backup
operator: you declare small CRs, it runs mover Jobs, Kopia encrypts +
deduplicates + ships bytes to S3. This kit uses it for ordinary application
PVCs that need file-level recovery. CNPG uses Barman, and derived data may be
explicitly exempt. The deep narrative lives in the parent cluster's docs — start with
**[the easy guide](https://mitchross.github.io/talos-argocd-proxmox/easy-guide/)**
and poke the state machine yourself in
**[the interactive playground](https://mitchross.github.io/talos-argocd-proxmox/kopiur-playground/)**.
This page is the kit-local summary.

## The one idea that matters: restore-before-bind

A PVC whose `dataSourceRef` points at a kopiur `Restore` is **withheld from
binding** until the data is back. Exactly three outcomes exist:

| Repo state on recreate | Outcome |
|---|---|
| Snapshot exists | Mover restores it → PVC binds **with data** → app starts |
| Reachable, no snapshot yet | `onMissingSnapshot: Continue` → binds empty, backs up forward (day-zero = disaster-day) |
| **Unreachable** | Errors + retries → stays `Pending`. **Never binds empty over a dead backend** |

And the rule that bites: a PVC **without** a `dataSourceRef` recreates
**EMPTY** even though its backups still exist. CI (`validate-kopiur-coverage.py`)
hard-fails a backed-up PVC missing its `dataSourceRef`.

## The pieces in this kit

| Piece | Where | Wave |
|---|---|---|
| kopiur operator (CRDs + controller + webhook + populator) | `infrastructure/controllers/kopiur-operator/` | 2 |
| `ClusterRepository cluster-kopia` → `s3://kopiur` (RustFS, off-cluster) | `infrastructure/controllers/kopiur/` | 3 |
| `ClusterExternalSecret kopiur-rustfs` — creds fan-out to labeled namespaces | `infrastructure/controllers/kopiur/` | 3 |
| `VolumeSnapshotClass longhorn-snapclass` | `infrastructure/controllers/kopiur/` | 3 |
| Shared Kustomize component (uniform fields) | `my-apps/common/kopiur-backup/` | — |
| Per-PVC stubs (what varies: identity, cron, retention, **mover UID**) | `my-apps/<cat>/<app>/kopiur/` | 6 |

One namespace label — `kopiur.home-operations.com/repo: cluster-kopia` —
turns on both the credential fan-out and repo tenancy.

## The worked example: karakeep

`my-apps/media/karakeep/` deliberately shows **both** patterns:

- **`data-pvc`** (bookmarks, SQLite): full bundle — stub in
  `kopiur/data-pvc.yaml` (mover runs as the data owner, uid `1001`), PVC
  carries `dataSourceRef → data-pvc-restore` + the two `ServerSide*`
  annotations (`argocd.argoproj.io/compare-options: ServerSideDiff=false`,
  `argocd.argoproj.io/sync-options: ServerSideApply=false` — the
  immutable-field diff mask).
- **`meilisearch-pvc`** (search index): **deliberately exempt** — derived
  data karakeep rebuilds. Label `backup-exempt: "true"` + the
  fully-qualified `storage.vanillax.dev/backup-exempt-reason` annotation, no
  bundle, no `dataSourceRef`. It recreates empty after DR, by recorded
  decision.

Drill it (this is also getting-started's final step):

```bash
kubectl -n karakeep get snapshot                       # Completed, non-zero files
kubectl -n karakeep get secret kopiur-rustfs           # credential fan-out works
kubectl -n karakeep scale deploy/karakeep-web --replicas=0
kubectl -n karakeep delete pvc data-pvc
kubectl -n karakeep get pvc data-pvc -w                # Pending → Bound (with data)
kubectl -n karakeep scale deploy/karakeep-web --replicas=1
```

## The #1 gotcha: the mover runs as the data owner

Under baseline Pod Security the mover has **all capabilities dropped** — a
root mover cannot read non-root files (`PermissionDenied`). Set the stub's
mover `securityContext` to the uid:gid that owns the data
(`kubectl -n <ns> exec <pod> -- stat -c '%u:%g' <path>`). Full story:
[mover permissions](https://mitchross.github.io/talos-argocd-proxmox/domains/storage/kopiur-mover-permissions/).

## What kopiur is NOT for

**CNPG databases.** Postgres in this starter gets SQL-aware backups via CNPG + Barman to a
separate bucket — never kopiur filesystem snapshots. See
[cnpg-explained.md](cnpg-explained.md). One repo, two backup systems, zero
overlap.

## Add a backup to your own app (checklist)

1. Find the data owner: `stat -c '%u:%g'` inside the pod.
2. Label the namespace `kopiur.home-operations.com/repo: cluster-kopia`
   (+ the `privileged-movers` annotation only if the owner is `0`).
3. Add `kopiur/<pvc>.yaml` — `SnapshotPolicy` + `SnapshotSchedule` +
   `Restore`, mover = that uid:gid, distinct cron minute. Copy karakeep's.
4. PVC: `dataSourceRef → Restore/<pvc>-restore` + the two `ServerSide*`
   annotations.
5. Kustomization: stub under `resources:`, `../../common/kopiur-backup`
   under `components:`.
6. Verify: `kubectl -n <ns> get snapshotpolicy,snapshotschedule,restore,snapshot,secret`.
