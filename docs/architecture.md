# Architecture

The kit is a **literal subset of a production homelab**
([talos-argocd-proxmox](https://github.com/mitchross/talos-argocd-proxmox))
— same directory shape, same sync waves, same patterns, fewer apps. The
parent's docs are therefore this kit's deep-dive shelf; links below.

## GitOps self-management: directory = Application

```
bootstrap-argocd.sh → root Application → infrastructure/controllers/argocd/apps/
  → projects + 4 ApplicationSets → auto-discovered apps
```

No hand-written `Application` manifests for apps. The AppSets scan:

| AppSet | Discovers | Wave |
|---|---|---|
| `infrastructure` | explicit path list (external-dns, cloudflared, gateway) | 4 |
| `database` | `infrastructure/database/*/*` (`selfHeal: false` — DR annotations must stick) | 4 |
| `monitoring` | `monitoring/*` | 5 |
| `my-apps` | `my-apps/*/*` | 6 |

Add a directory with a `kustomization.yaml`, push, deployed. One repo rule:
**every YAML in `infrastructure/controllers/argocd/apps/` must be listed in
that directory's `kustomization.yaml`** — unlisted files are never rendered.

## The seven waves (and why each exists)

| Wave | What | Why it must precede the next |
|---|---|---|
| **0** | Cilium (CNI + Gateway API), ArgoCD itself, 1Password Connect, External Secrets | no network → nothing schedules; no secrets engine → no credentials for anyone |
| **1** | cert-manager, Longhorn, snapshot-controller | storage + the VolumeSnapshot CRDs backups depend on; certs before cert-dependent plugins |
| **2** | **kopiur operator** | the volume populator must exist before any PVC references a `Restore` |
| **3** | **kopiur config** (ClusterRepository + creds fan-out + snapclass), CNPG Barman plugin | repo + S3 creds live before movers run; plugin before DB clusters |
| **4** | infrastructure + database AppSets | the platform layer; gitea's Postgres restores itself via Barman here |
| **5** | kube-prometheus-stack + Grafana | observability is deliberately **not** a core dependency — nothing below needs it |
| **6** | my-apps AppSet (nginx, karakeep, gitea) | by now everything a restoring PVC needs exists |

Two details that make the waves *actually wait* (most copies of this
pattern miss both):

1. **The Application health Lua** in
   [`infrastructure/controllers/argocd/values.yaml`](../infrastructure/controllers/argocd/values.yaml)
   — ArgoCD ≥1.8 doesn't assess `Application` health by default, so without
   it, app-of-apps waves are ordering theater.
2. **Restores gate the waves.** A recreated PVC holds `Pending` until its
   kopiur populator finishes → pod can't start → app stays `Progressing` →
   the wave holds. On a rebuild, data restoration literally blocks the door.

## The two backup systems (never mixed)

| | kopiur (files) | CNPG/Barman (SQL) |
|---|---|---|
| Protects | PVC contents (karakeep, gitea storage) | the Postgres database |
| Mechanism | CSI snapshot → Kopia → `s3://kopiur` | base backups + WAL → `s3://postgres-backups` |
| Restore | restore-before-bind populator ([kopiur-explained.md](kopiur-explained.md)) | `overlays/recovery` bootstrap ([cnpg-explained.md](cnpg-explained.md)) |

## Networking

Cilium Gateway API (no Ingress anywhere): `gateway-internal` (LAN, wildcard
cert via cert-manager DNS01), `gateway-external` (published through a
Cloudflare tunnel). Internal DNS records are written by external-dns into
**Technitium**; external records into Cloudflare (routes need the 3-piece
contract: `external-dns: "true"` label + target annotation +
`sectionName: https`). Services MUST name their ports (`name: http`) or
HTTPRoutes fail silently.

## Deep dives (parent docs)

[The easy guide](https://mitchross.github.io/talos-argocd-proxmox/easy-guide/) ·
[storage architecture](https://mitchross.github.io/talos-argocd-proxmox/storage-architecture/) ·
[kopiur backup architecture](https://mitchross.github.io/talos-argocd-proxmox/domains/storage/kopiur-backup-architecture/) ·
[disaster recovery](https://mitchross.github.io/talos-argocd-proxmox/disaster-recovery/) ·
[interactive playground](https://mitchross.github.io/talos-argocd-proxmox/kopiur-playground/)
