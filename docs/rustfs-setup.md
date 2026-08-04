# The S3 backend (RustFS on TrueNAS — any S3 works)

Every backup in this kit lands on an S3 box that lives **outside the
cluster** — that's the entire point: it must survive the cluster ceasing to
exist. This cluster uses [RustFS](https://github.com/rustfs/rustfs) running
as a TrueNAS app; MinIO, Garage, TrueNAS-native S3, or Backblaze B2 work
identically — only the endpoint and credentials change.

## One-time setup

1. **Install RustFS** (or your S3 of choice) somewhere that is not this
   cluster. Note the **API** endpoint (RustFS: port `30292`; the console on
   `:30293` is NOT the API — pointing Kubernetes at the console is a classic
   dead-end).
2. **Create two buckets** — the two backup systems never share one:
   - `kopiur` — the Kopia repository (file-level PVC backups; repo at the
     bucket root, `prefix: ""`)
   - `postgres-backups` — CNPG/Barman database backups
3. **Create ONE workload access key** (e.g. `homelab-workload`) with an
   allow policy scoped to exactly those two buckets. **Never point
   Kubernetes at the root/admin key.**
4. **Put the credentials in 1Password** — item `rustfs`, fields:
   `kopia_password` (generate 32 random bytes; **lose this, lose the
   backups**), `rustfs-workload-access-key`, `rustfs-workload-secret-key`.
   ESO fans them out from there ([secret-management.md](secret-management.md)).

## Wire it into the kit

The repo definition is one CR —
[`infrastructure/controllers/kopiur/clusterrepository.yaml`](../infrastructure/controllers/kopiur/clusterrepository.yaml):

```yaml
spec:
  backend:
    s3:
      bucket: kopiur
      prefix: ""
      endpoint: 192.168.10.133:30292   # ← YOURS. Bare host:port — no scheme, no slash
      region: us-east-1
      tls:
        disableTls: true               # plain-HTTP LAN S3; delete for HTTPS
      auth:
        secretRef: { name: kopiur-rustfs, namespace: kopiur-system }
  encryption:
    passwordSecretRef: { name: kopiur-rustfs, namespace: kopiur-system, key: KOPIA_PASSWORD }
  create:
    enabled: true                      # first boot creates the repo
  allowedNamespaces:
    selector:
      matchLabels:
        kopiur.home-operations.com/repo: cluster-kopia
```

CNPG's `ObjectStore` (in
[`infrastructure/database/cloudnative-pg/gitea/base/`](../infrastructure/database/cloudnative-pg/gitea/base/))
points at `postgres-backups` with the same workload credentials.

## The mistakes that bite (all field-tested)

- **Endpoint is a bare `host:port`** — `http://` prefixes or trailing
  slashes fail in confusing ways.
- **Register and verify the key before you rely on it.** A past full-cluster
  rebuild proved an unregistered credential blocks *all* recovery even with
  perfect Git state. `nc -zw5 <host> <port>` + one completed Snapshot is
  your proof of end-to-end auth.
- **The workload key must have read/write on BOTH buckets** — a policy
  scoped to an older bucket lets everything look healthy while the
  `ClusterRepository` fails to connect.
- **The Kopia password is the single blast radius.** One shared repo, one
  password. Keep it only in 1Password.

## Verify

```bash
kubectl get clusterrepository cluster-kopia -o wide   # operator connected?
kubectl -n karakeep get secret kopiur-rustfs          # creds fanned out?
kubectl get snapshot -A                               # a Succeeded run = auth proven
```
