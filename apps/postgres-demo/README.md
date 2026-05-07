# postgres-demo — CloudNativePG with Barman backup/restore

A 1-replica CNPG Postgres cluster wired to an in-cluster MinIO via the
**CNPG Barman Cloud plugin**, with a `ScheduledBackup` running every 6
hours and 7-day retention. The point of this demo is to teach **database
disaster recovery end to end** — `kubectl apply`, see backups appear in
MinIO, simulate data loss, restore from backup.

> **Demo only.** This MinIO is a single-pod, single-PVC, no-replica
> object store. Production CNPG Clusters must use a real S3 backend
> (AWS, Cloudflare R2, Backblaze B2, on-prem Ceph/MinIO cluster). See
> [`docs/extending/external-s3-backend.md`](../../docs/extending/external-s3-backend.md)
> for the swap recipe — only the `objectstore.yaml` endpoint URL and
> the credentials SealedSecret change.

---

## What's in this directory

```
apps/postgres-demo/
├── README.md                       # ← this file
├── kustomization.yaml              # composes everything below
├── namespace.yaml
├── minio/                          # in-cluster S3 backend for the Barman plugin
│   ├── kustomization.yaml
│   ├── pvc.yaml                    # 10Gi longhorn PVC, backup-exempt
│   ├── deployment.yaml             # single-pod MinIO, Recreate strategy
│   ├── service.yaml                # ClusterIP, ports 9000 (S3) + 9001 (console)
│   ├── sealed-credentials.yaml     # placeholder — replace via seal-secret.sh
│   └── bootstrap-job.yaml          # creates the cnpg-backups bucket via mc
├── base/
│   ├── kustomization.yaml
│   └── cluster.yaml                # CNPG Cluster spec (NO bootstrap stanza)
├── overlays/
│   ├── initdb/                     # ACTIVE — bootstrap.initdb (fresh DB)
│   │   ├── kustomization.yaml
│   │   └── bootstrap-patch.yaml
│   └── recovery/                   # DR — bootstrap.recovery from Barman
│       ├── kustomization.yaml
│       └── bootstrap-patch.yaml
├── objectstore.yaml                # CNPG ObjectStore CR pointing at MinIO
└── scheduled-backup.yaml           # every 6h, 7-day retention
```

---

## Before first reconcile: seal the MinIO credentials

> **Note**: this is one of TWO seal-secret steps the starter requires
> before ArgoCD's first sync. The other is the Kopia repository
> password at `infrastructure/controllers/pvc-plumber/sealed-kopia-
> password.yaml` — without that, pvc-plumber's `externalsecret.yaml`
> can't unwrap the master secret and per-PVC backups in
> `apps/stateful-demo/` (and any user app with a `backup: hourly`
> label) silently no-op. `scripts/seal-secret.sh` handles both — see
> `docs/getting-started.md` for the recommended ordering.

The `minio/sealed-credentials.yaml` file ships as a stub regular Secret.
Before ArgoCD can fully sync postgres-demo, you must replace it with a
real `SealedSecret`:

```bash
# Run from the repo root, after the cluster is up + sealed-secrets is Running
./scripts/seal-secret.sh apps/postgres-demo/minio/sealed-credentials.yaml
```

The script generates two random 24-byte values (one for the access key
ID, one for the secret), kubeseal-s a Secret with all four keys
(`ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `MINIO_ROOT_USER`,
`MINIO_ROOT_PASSWORD` — same values for the matched pairs), and
overwrites the file with a `SealedSecret`. Commit and push.

---

## After first sync: verify backups are happening

Once ArgoCD shows `app-postgres-demo` as `Synced` + `Healthy`:

### 1. CNPG Cluster healthy

```bash
kubectl get cluster -n postgres-demo postgres-demo
# expected: STATUS=Cluster in healthy state
kubectl get pods -n postgres-demo -l cnpg.io/cluster=postgres-demo
# expected: postgres-demo-1 Running, READY 1/1
```

### 2. The first immediate backup completed

`scheduled-backup.yaml` carries `immediate: true`, so a base backup
fires within minutes of the cluster coming up:

```bash
kubectl get backup -n postgres-demo
# expected: a Backup resource with PHASE=completed within ~5 min
```

To follow it as it runs:

```bash
kubectl describe backup -n postgres-demo $(kubectl get backup -n postgres-demo -o name | head -1)
```

### 3. Backup objects landed in MinIO

```bash
# Port-forward MinIO's S3 API to your laptop
kubectl port-forward -n postgres-demo svc/minio 9000:9000

# In a separate terminal, list the bucket contents using mc on your laptop:
# (install mc: https://min.io/docs/minio/linux/reference/minio-mc.html)
mc alias set demo http://localhost:9000 \
  $(kubectl get secret -n postgres-demo minio-credentials -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d) \
  $(kubectl get secret -n postgres-demo minio-credentials -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)

mc ls demo/cnpg-backups
# expected: a postgres-demo/ subdirectory containing wals/ + base/ subdirectories
```

You can also browse via the MinIO console UI at
<http://localhost:9001> (use the same credentials).

### 4. Continuous WAL archiving

The plugin streams WAL segments to MinIO continuously (not just on
ScheduledBackup ticks). Watch:

```bash
mc ls demo/cnpg-backups/postgres-demo/wals/
# expected: new files appear every ~5 minutes during normal write activity
```

---

## Trigger a manual backup

If you want to verify a backup right now without waiting for the
6-hour schedule:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: postgres-demo-manual-$(date +%Y%m%d-%H%M%S)
  namespace: postgres-demo
spec:
  cluster:
    name: postgres-demo
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl get backup -n postgres-demo -w
```

---

## Simulate data loss + recover from Barman

The whole point of this demo. The flow:

### Step 1 — Insert some real data

```bash
kubectl exec -it -n postgres-demo postgres-demo-1 -c postgres -- \
  psql -U postgres -d demo -c \
  "INSERT INTO guestbook (message) VALUES ('Pre-disaster entry');"

kubectl exec -it -n postgres-demo postgres-demo-1 -c postgres -- \
  psql -U postgres -d demo -c "SELECT * FROM guestbook;"
# expected: 2 rows (initdb's "First entry" + your new "Pre-disaster entry")
```

### Step 2 — Wait for that data to land in a backup

Either wait for the next scheduled tick, or trigger a manual one (see
above). Verify with `kubectl get backup -n postgres-demo`.

### Step 3 — Simulate disaster: delete the cluster

```bash
# Delete the live Cluster CR. ArgoCD will keep recreating it from
# git, so first add the skip-reconcile annotation so it doesn't
# fight you.
kubectl annotate -n argocd application app-postgres-demo \
  argocd.argoproj.io/skip-reconcile=true

kubectl delete cluster -n postgres-demo postgres-demo
kubectl delete pvc -n postgres-demo -l cnpg.io/cluster=postgres-demo
```

The data is gone from cluster storage. The backup is still in MinIO.

### Step 4 — Switch to recovery overlay

Edit `apps/postgres-demo/kustomization.yaml`:

```yaml
resources:
  - namespace.yaml
  - minio
  - objectstore.yaml
  # - overlays/initdb         # ← was active
  - overlays/recovery         # ← swap to this
  - scheduled-backup.yaml
```

Commit + push. Then remove the skip-reconcile annotation:

```bash
kubectl annotate -n argocd application app-postgres-demo \
  argocd.argoproj.io/skip-reconcile-
```

ArgoCD picks up the new manifest, CNPG sees the recovery-mode Cluster,
the operator provisions a fresh Cluster from the latest base backup
in MinIO and replays WAL up to the latest archived segment.

### Step 5 — Verify your data came back

```bash
kubectl get cluster -n postgres-demo postgres-demo -w
# wait for STATUS=Cluster in healthy state

kubectl exec -it -n postgres-demo postgres-demo-1 -c postgres -- \
  psql -U postgres -d demo -c "SELECT * FROM guestbook;"
# expected: 2 rows including "Pre-disaster entry" — the database has
# been restored from Barman.
```

### Step 6 — Switch back to initdb overlay

Once the cluster is healthy, switch back to the initdb overlay so the
steady-state git matches the steady-state behavior. CNPG ignores the
`bootstrap.initdb` stanza on an already-bootstrapped cluster (it's
creation-time-only), so this swap is a no-op for the live cluster
but keeps git tidy.

```yaml
resources:
  - namespace.yaml
  - minio
  - objectstore.yaml
  - overlays/initdb           # ← back to active
  # - overlays/recovery       # ← deactivate
  - scheduled-backup.yaml
```

---

## Point-in-time recovery (PITR)

The recovery overlay has a commented-out `recoveryTarget.targetTime`
block. Edit `overlays/recovery/bootstrap-patch.yaml` to uncomment it
and set a timestamp BEFORE your data-loss event. CNPG will:

1. Restore the most recent base backup ≤ the targetTime
2. Replay WAL up to (but not past) targetTime
3. Stop. The Cluster is now at the exact state it was at that timestamp.

---

## Failure modes you might hit

- **Backups not appearing in MinIO**: check
  `kubectl logs -n postgres-demo postgres-demo-1 -c plugin-barman-cloud`.
  Common causes: MinIO bootstrap-job didn't create the bucket
  (`kubectl get jobs -n postgres-demo`); credentials Secret stub never
  got sealed (the postgres-demo-1 pod will be CrashLoopBackOff with
  "invalid access key" in logs).
- **Recovery overlay sync stuck**: the database AppSet uses
  `selfHeal: false` to preserve the `skip-reconcile` annotation during
  DR. If you forgot to remove the annotation after switching overlays
  in git, ArgoCD won't apply the new manifests. Drop the annotation
  and refresh.
- **WAL archiving falls behind**: usually means MinIO is full or
  unhealthy. `kubectl describe pvc -n postgres-demo minio-data` to
  check space; Longhorn web UI to inspect the volume's replicas.

For deeper DR scenarios (cluster-wide loss, cross-cluster recovery),
see [`docs/extending/disaster-recovery.md`](../../docs/extending/disaster-recovery.md).
