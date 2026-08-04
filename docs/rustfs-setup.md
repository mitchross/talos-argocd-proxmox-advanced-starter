# The S3 backend (RustFS on TrueNAS — any S3 works)

Every backup in this kit lands on an S3 box that lives **outside the
cluster** — that's the entire point: it must survive the cluster ceasing to
exist. This cluster uses [RustFS](https://github.com/rustfs/rustfs) running
as a TrueNAS app; MinIO, Garage, TrueNAS-native S3, or Backblaze B2 work
identically — only the endpoint and credentials change.

Do this before `bootstrap-argocd.sh`. Two independent backup systems depend
on it:

| System | Backs up | Bucket |
|---|---|---|
| **kopiur** (Kopia) | application PVCs, file-level, restore-before-bind | `kopiur` |
| **CNPG / Barman** | Postgres, WAL + base backups | `postgres-backups` |

## 1. Install the S3 server

**Anywhere that is not this cluster.** A NAS, a spare box, a VPS, a
different cluster — the requirement is that destroying Kubernetes doesn't
destroy this.

On TrueNAS, RustFS installs from the community app catalogue. Standalone,
it's a container:

```bash
docker run -d --name rustfs \
  -p 9000:9000 -p 9001:9001 \
  -v /srv/rustfs:/data \
  -e RUSTFS_ROOT_USER=admin \
  -e RUSTFS_ROOT_PASSWORD='<something-long>' \
  rustfs/rustfs:latest
```

Any S3-compatible server works. The rest of this guide only assumes buckets,
an access key, and an endpoint.

## 2. Find the API endpoint — not the console

Note the **API** port. RustFS on TrueNAS defaults to `30292` for the API and
`30293` for the web console.

**Pointing Kubernetes at the console port is the classic dead-end** — it
serves HTML, so connections succeed and auth fails in ways that look like
credential problems. Prove you have the right one:

```bash
nc -zw5 <s3-host> <s3-api-port>
curl -s -o /dev/null -w '%{http_code}\n' http://<s3-host>:<s3-api-port>
# an S3 API answers 400/403 to an unsigned GET — HTML/200 means you found the console
```

Run this from the **node network**, not your laptop, if they differ. The
workers are what has to reach it.

## 3. Create the two buckets

```
kopiur              # Kopia repository, repo at the bucket root (prefix: "")
postgres-backups    # CNPG/Barman, one prefix per database
```

**The two backup systems never share a bucket.** Kopia treats its bucket as
an owned repository with its own index; Barman writes a WAL archive layout.
Pointing both at one bucket breaks assumptions on both sides.

Via the console UI, or with any S3 client:

```bash
aws --endpoint-url http://<s3-host>:<api-port> s3 mb s3://kopiur
aws --endpoint-url http://<s3-host>:<api-port> s3 mb s3://postgres-backups
```

## 4. Create a scoped workload key

Create **one** access key (e.g. `homelab-workload`) with read/write on
exactly those two buckets. **Never point Kubernetes at the root/admin key** —
that key can delete every bucket on the box, including the backups you are
protecting.

If your S3 server takes IAM-style policy JSON:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": ["arn:aws:s3:::kopiur", "arn:aws:s3:::postgres-backups"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::kopiur/*", "arn:aws:s3:::postgres-backups/*"]
    }
  ]
}
```

`DeleteObject` is required, not optional — both systems prune expired
backups. Without it, retention silently stops working and the bucket grows
until it fills.

## 5. Generate the Kopia repository password

Separate from the S3 credentials: this is the **encryption** password for the
Kopia repository.

```bash
openssl rand -base64 32
```

**Lose this and the backups are unrecoverable.** The S3 key controls access;
this controls decryption. One repository, one password, and it only ever
lives in 1Password.

## 6. Store the three values in 1Password

Item `rustfs` in your vault ([1password-setup.md](1password-setup.md)):

| Field | Value |
|---|---|
| `kopia_password` | step 5 |
| `rustfs-workload-access-key` | step 4 |
| `rustfs-workload-secret-key` | step 4 |

ESO fans these out — you never create these Secrets by hand
([secret-management.md](secret-management.md)).

## 7. Point the repo at your endpoint

`scripts/adapt-to-your-cluster.sh` rewrites the example values across the
tree — `192.168.10.133` → your S3 host, `30292` → your API port. Run it and
you are done ([adapting-to-your-cluster.md](adapting-to-your-cluster.md)).

### The endpoint is written two different ways

The two consumers want **different formats for the same endpoint**:

| Consumer | Field | Format | Example |
|---|---|---|---|
| kopiur `ClusterRepository` | `endpoint` | **bare `host:port`** — no scheme, no trailing slash | `192.168.10.133:30292` |
| CNPG `ObjectStore` | `endpointURL` | **full URL, scheme required** | `http://192.168.10.133:30292` |

Copying one form into the other fails in confusing ways — kopiur rejects the
scheme, Barman rejects its absence. The adapt script preserves both because
it only replaces host and port.

### Who reads which credential

| | kopiur | CNPG / Barman |
|---|---|---|
| Secret | `kopiur-rustfs` | `cnpg-s3-credentials` |
| Keys | `KOPIA_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| Namespace | `kopiur-system` **and every backed-up namespace** | `cloudnative-pg` |
| Created by | `ClusterExternalSecret` in [`controllers/kopiur/externalsecret.yaml`](../infrastructure/controllers/kopiur/externalsecret.yaml), fanned out by namespace label | `ExternalSecret` in [`cloudnative-pg-operator/s3-externalsecret.yaml`](../infrastructure/database/cloudnative-pg/cloudnative-pg-operator/s3-externalsecret.yaml) |

Both read the same 1Password `rustfs` item. The kopiur Secret **name must
match** the `ClusterRepository`'s `auth.secretRef.name` — a kopiur
requirement when credential projection is disabled, which it is here
deliberately (enabling it would need cluster-wide Secret write RBAC).

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
points at `postgres-backups` under a per-database prefix
(`s3://postgres-backups/cnpg/gitea`) with the same workload credentials.

## The mistakes that bite (all field-tested)

- **Endpoint format differs per consumer** — see the table above. The single
  most common misconfiguration.
- **Register and verify the key before you rely on it.** A past full-cluster
  rebuild proved an unregistered credential blocks *all* recovery even with
  perfect Git state. `nc -zw5 <host> <port>` + one completed Snapshot is
  your proof of end-to-end auth.
- **The workload key must have read/write on BOTH buckets** — a policy
  scoped to an older bucket lets everything look healthy while the
  `ClusterRepository` fails to connect.
- **The Kopia password is the single blast radius.** One shared repo, one
  password. Keep it only in 1Password.
- **An S3 endpoint inside the cluster you are protecting is not a backup.**
  Neither is a console port, nor an unregistered access key.

## Verify

```bash
kubectl get clusterrepository cluster-kopia -o wide   # operator connected?
kubectl -n karakeep get secret kopiur-rustfs          # creds fanned out?
kubectl -n cloudnative-pg get secret cnpg-s3-credentials
kubectl get snapshot -A                               # a Succeeded run = auth proven
```

A `Snapshot` reaching `Succeeded` with a non-zero file count is the only real
proof — it exercises endpoint, credentials, bucket policy, and the Kopia
password in one shot. For Postgres the equivalent is a completed base backup:

```bash
kubectl -n cloudnative-pg get backup
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| `ClusterRepository` not Ready, connection refused | Console port instead of the API port, or the workers cannot route to the host. Re-run the `nc` check from a node network. |
| Repo connects, `Snapshot` fails on write | Key lacks `PutObject` on `kopiur/*`. A policy naming the bucket but not the object path needs both ARNs. |
| Snapshots succeed, old ones never expire | Missing `s3:DeleteObject`. Retention fails quietly. |
| CNPG `Backup` fails, `cnpg-s3-credentials` not found | ESO has not populated it — check the `rustfs` item field names match exactly. |
| Barman errors on the endpoint while kopiur is fine | `endpointURL` is missing its `http://` scheme. |
| Everything works, restore binds an empty PVC | Not an S3 fault: a reachable repo with no snapshot for that PVC binds empty by design (`onMissingSnapshot: Continue`). See [kopiur-explained.md](kopiur-explained.md). |
