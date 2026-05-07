# talos-argocd-proxmox-advanced-starter

A production-shaped GitOps Kubernetes starter kit for Proxmox homelabs.
Take this, point it at your cluster, and you have a self-managing
ArgoCD + storage + monitoring + a few demo apps running in under an hour.

> **Status**: bootstrapping. README + structure are scaffolded; the
> implementation is being ported from a working homelab cluster.
> See `docs/porting-plan.md` for the porting matrix.

---

## What this is

A "next step after a Hello World" GitOps starter for Proxmox + Talos.
Most starters give you `kubectl create deployment nginx` and call it done.
This one demonstrates the patterns that actually matter at scale:

- **GitOps self-managing ArgoCD**: ArgoCD manages its own configuration.
  Add a directory + a `kustomization.yaml`, ArgoCD auto-discovers and
  deploys it. No manual `Application` manifests.
- **Sync wave architecture**: applications deploy in strict order so
  storage comes up before databases come up before apps. Critical for
  cold-cluster boots.
- **PVC backup/restore via the magic `backup: hourly` label**: stateful
  apps just label their PVC and the platform does the rest — backup
  schedule, restore-on-recreate, all automatic.
- **Gateway API**: replaces Ingress, with internal/external split via
  `sectionName`.
- **Disaster recovery patterns**: documented and rehearsable, not
  aspirational.

90% inspired by [`talos-argocd-proxmox`](https://github.com/mitchross/talos-argocd-proxmox)
(a working homelab cluster). Pared down to what's reproducible without
paid services.

---

## What's NOT in this starter (and why)

Honest scope-setting:

| Excluded | Why | What you'd swap in |
|---|---|---|
| 1Password Connect | Paid service tied to a specific account | sealed-secrets (default), or HashiCorp Vault, or any ESO-supported backend |
| Cloudflare tunnel + external-DNS to Cloudflare | Paid + DNS setup specific to your domain | Internal DNS only by default; external-DNS providers documented as extension |
| GPU passthrough / AI workloads (llama-cpp, ComfyUI) | Hardware-specific, requires NVIDIA setup | Documented as an extension recipe |
| KEDA, Temporal Worker Controller | Cluster-specific use cases | Skipped; add when you need them |
| Proprietary apps (PostHog, Immich, etc.) | Each is its own onboarding | Replaced with focused demo apps that exercise the platform features |

What IS in:

- **Talos OS provisioning** via Sidero Omni on Proxmox (ported from
  [`sidero-omni-talos-proxmox-starter`](https://github.com/mitchross/sidero-omni-talos-proxmox-starter))
- **ArgoCD** (self-managing, with AppSets + ApplicationSet for app discovery)
- **Cilium** (CNI + Gateway API)
- **cert-manager** (TLS for webhook + Gateway certs)
- **Longhorn** (distributed block storage with VolumeSnapshots)
- **VolSync + Kopia** (PVC backup/restore on NFS or S3)
- **pvc-plumber operator** (the magic-label backup automation)
- **External Secrets Operator** with **sealed-secrets** as the default backend
- **Prometheus + Grafana + Loki** (monitoring + logs)
- **Demo apps**: stateless (HTTPRoute), stateful (PVC + backup label),
  CNPG database (Barman backup)

---

## Quick start

> **Prerequisites**: Proxmox VE host with ≥48GB RAM, ≥600GB storage
> for the cluster, network access to GitHub.

```bash
# 1. Clone the starter
git clone https://github.com/<you>/talos-argocd-proxmox-advanced-starter
cd talos-argocd-proxmox-advanced-starter

# 2. Adapt to your environment (edits ~10 placeholders)
./scripts/adapt-to-your-cluster.sh

# 3. Provision Talos cluster via Sidero Omni
cd omni && ./bootstrap.sh

# 4. Bootstrap ArgoCD (one-time manual apply)
./scripts/bootstrap-argocd.sh

# 5. Watch ArgoCD discover and deploy everything
kubectl get applications -n argocd -w
```

Detailed setup walkthrough: [`docs/getting-started.md`](docs/getting-started.md).

---

## Architecture at a glance

```
Manual bootstrap
   ↓
ArgoCD (self-manages)
   ↓
Root Application (points at infrastructure/controllers/argocd/apps/)
   ↓
ApplicationSets discover directories → auto-create Applications
   ↓
Applications deploy in sync wave order
```

**Sync waves**:

| Wave | Component |
|------|-----------|
| 0 | Cilium (CNI), ArgoCD, External Secrets, sealed-secrets, AppProjects |
| 1 | Longhorn, snapshot-controller, VolSync, pvc-plumber operator, cert-manager |
| 2 | pvc-plumber webhook configurations, Gateway API resources |
| 3 | CNPG operator (database operator, no clusters yet) |
| 4 | Infrastructure AppSet (everything else infra) + Database AppSet |
| 5 | Monitoring AppSet (Prometheus, Grafana, Loki) |
| 6 | Apps AppSet (your stateless + stateful demo apps) |

If you change this order, you will get cold-boot races. The order is
the architecture.

Full architecture: [`docs/architecture.md`](docs/architecture.md).

---

## Documentation

- [`docs/getting-started.md`](docs/getting-started.md) — cold-cluster walkthrough
- [`docs/architecture.md`](docs/architecture.md) — sync waves, ApplicationSet discovery, GitOps self-management
- [`docs/pvc-backup-restore.md`](docs/pvc-backup-restore.md) — the `backup: hourly` label pattern
- [`docs/secret-management.md`](docs/secret-management.md) — sealed-secrets default, swapping to other backends
- [`docs/adapting-to-your-cluster.md`](docs/adapting-to-your-cluster.md) — what to edit before you boot
- [`docs/extending.md`](docs/extending.md) — adding GPU support, swapping DNS providers, adding apps

---

## License

MIT. Use, fork, modify, redistribute. Inspired by the homelab clusters of
[mitchross/talos-argocd-proxmox](https://github.com/mitchross/talos-argocd-proxmox)
and [mitchross/talos-argocd-proxmox-starter](https://github.com/mitchross/talos-argocd-proxmox-starter).
