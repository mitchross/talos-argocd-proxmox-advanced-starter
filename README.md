# talos-argocd-proxmox-advanced-starter

> A production-shaped GitOps starter for Proxmox homelabs: Talos + Omni +
> self-managing ArgoCD + Cilium Gateway API + Longhorn + **kopiur**
> restore-before-bind backups + CNPG Postgres — pruned from a
> [real, battle-tested cluster](https://github.com/mitchross/talos-argocd-proxmox)
> down to three demo apps and everything they *actually* need.

Most starters give you `kubectl create deployment nginx` and call it done.
This one answers the harder question: **what does it take to run stateful
apps whose data survives anything — including deleting the whole cluster?**
The parent repo has been fully destroyed and rebuilt multiple times with
every protected volume restoring unattended
([receipts](https://mitchross.github.io/talos-argocd-proxmox/disaster-recovery/#proof-history));
this kit is that architecture, minus 40 apps.

## The advanced contract

This is the **advanced** tier — it assumes real external systems and makes
no attempt to shim them away:

| You bring | Used for |
|---|---|
| **Proxmox + [Omni](https://github.com/siderolabs/omni)** (running) | Talos cluster provisioning — new to this? Start with the no-dependencies [base starter](https://github.com/mitchross/sidero-omni-talos-proxmox-starter) |
| **1Password account** + Connect credentials | every secret, via External Secrets Operator |
| **Off-cluster S3** (RustFS/TrueNAS shown; any S3) | backups — the one thing that must outlive the cluster |
| **Cloudflare** account + a domain | DNS01 certs, external-dns, tunnel for external routes |

No sealed-secrets fallback, no in-cluster MinIO, no demo shims. Working
values (`vanillax.xyz`, a LAN S3 endpoint, DNS and Gateway addresses) ship
in-tree so you can see a real configuration; the adaptation script replaces
the complete example profile ([guide](docs/adapting-to-your-cluster.md)).

## The dependency ladder (why these three apps)

Each demo app exists to force one layer of the platform into the tree:

| App | What it teaches | What it forces you to have |
|---|---|---|
| **nginx** (`my-apps/development/nginx/`) | directory = Application | ArgoCD AppSets, namespace, named Service ports, internal HTTPRoute |
| **karakeep** (`my-apps/media/karakeep/`) | **restore-before-bind backups** — `data-pvc` has the full kopiur bundle; `meilisearch-pvc` is *deliberately* backup-exempt | Longhorn, snapshot-controller, kopiur operator + `ClusterRepository`, the shared Kustomize component, the off-cluster S3 |
| **gitea** (`my-apps/development/gitea/`) | real app with a real database + external route | CNPG + Barman plugin (SQL-aware backups — **not** kopiur), ESO secrets, Helm+Kustomize, the Helm-rendered-PVC `dataSourceRef` patch, the 3-piece external-DNS contract |

## Architecture in 60 seconds

```
bootstrap-argocd.sh (once) → root Application → projects + 4 ApplicationSets
                                                → every directory = an app
```

The ApplicationSets use strict Go templates (`missingkey=error`) and
`FailOnSharedResource=true`: malformed generator data fails closed, and two
Applications cannot silently take ownership of the same Kubernetes object.

Deployment order is governed by **sync waves** — each wave must be Synced
*and Healthy* before the next:

| Wave | What |
|---|---|
| 0 | Cilium (CNI + Gateway API), ArgoCD self-management, 1Password Connect, External Secrets |
| 1 | cert-manager, Longhorn, snapshot-controller |
| 2 | **kopiur operator** (the volume populator) |
| 3 | **kopiur config** (repo + creds fan-out + snapclass), CNPG Barman plugin |
| 4 | infrastructure + database AppSets (gitea's Postgres) |
| 5 | kube-prometheus-stack + Grafana |
| 6 | the demo apps |

The payoff: on a rebuild, every backed-up PVC is recreated **`Pending` and
held there until its data is restored** — apps cannot start on empty
volumes, and the waves wait for the restores. Day-zero install and
disaster-day rebuild are the same code path.
Full walkthrough: [docs/architecture.md](docs/architecture.md).

## Quick start

```bash
# 0. Fork, clone YOUR fork, swap in your values, push
./scripts/adapt-to-your-cluster.sh        # docs/adapting-to-your-cluster.md

# 1. One-time externals: S3 buckets + 1Password items + Cloudflare token
#    docs/rustfs-setup.md · docs/secret-management.md

# 2. Provision Talos via Omni (omni/ — note the mandatory install.disk patch)
omnictl cluster template sync -f omni/cluster-template/cluster-template.yaml

# 3. Gateway CRDs → Cilium → pre-seed 1Password secrets → hand off
#    (full commands: docs/getting-started.md)
./scripts/bootstrap-argocd.sh

# 4. Watch the waves; then PROVE it with the karakeep restore drill
kubectl -n karakeep delete pvc data-pvc   # (scale down first — see the doc)
kubectl -n karakeep get pvc data-pvc -w   # Pending → Bound WITH data
```

<details>
<summary>Manual bootstrap equivalent (what the script does)</summary>

```bash
kubectl apply -f infrastructure/controllers/argocd/ns.yaml

helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version 10.1.3 \
  --namespace argocd \
  --values infrastructure/controllers/argocd/values.yaml \
  --wait --timeout 10m

kubectl wait --for condition=established --timeout=60s crd/applications.argoproj.io
kubectl apply -f infrastructure/controllers/argocd/root.yaml
```

</details>

## Docs

| Doc | What |
|---|---|
| [getting-started.md](docs/getting-started.md) | provision → bootstrap → verify → restore drill |
| [architecture.md](docs/architecture.md) | waves, AppSets, gating, the two backup systems |
| [networking.md](docs/networking.md) | Technitium private DNS, Cloudflare public DNS/tunnel, Gateway contracts |
| [kopiur-explained.md](docs/kopiur-explained.md) | restore-before-bind, the component/stub split, the mover-UID gotcha |
| [rustfs-setup.md](docs/rustfs-setup.md) | the one-time S3 backend setup |
| [cnpg-explained.md](docs/cnpg-explained.md) | Postgres backup/restore, lineages, the one feature flag |
| [secret-management.md](docs/secret-management.md) | 1Password → ESO flow + the vault items to create |
| [adapting-to-your-cluster.md](docs/adapting-to-your-cluster.md) | the 5 values to swap |

**Interactive:** poke the backup/restore state machine in your browser —
[the kopiur playground](https://mitchross.github.io/talos-argocd-proxmox/kopiur-playground/) —
and read [the easy guide](https://mitchross.github.io/talos-argocd-proxmox/easy-guide/)
for the from-zero narrative (including an adoption ladder if you only want
kopiur without the rest of this stack).

## Version pins (2026-07)

Talos `v1.13.5` (with the mandatory `machine.install.disk` patch) · Omni
`v1.9.0` · Kubernetes `v1.36.x` · Cilium `1.19.5` · Gateway API `v1.4.1`
(intentional — don't outrun Cilium) · ArgoCD `v3.4.5` / Helm chart `10.1.3` ·
kube-prometheus-stack `87.x` · images SHA-pinned, Renovate-managed.

## Lineage

Pruned from [talos-argocd-proxmox](https://github.com/mitchross/talos-argocd-proxmox)
(the live cluster) on 2026-07-02 — same directory shape, same waves, same
patterns, so everything you learn here transfers 1:1 to the full repo. The
provisioning layer is shared with
[sidero-omni-talos-proxmox-starter](https://github.com/mitchross/sidero-omni-talos-proxmox-starter).
An earlier iteration of this kit (pvc-plumber/VolSync-based) lives in git
history before the `phase 3a` commit.

## License

MIT
