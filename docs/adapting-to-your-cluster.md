# Adapting the kit to your cluster

The manifests ship with **my real values** (working > templated — you can
see exactly what a live configuration looks like). Adapting = swapping five
things for yours. `./scripts/adapt-to-your-cluster.sh` does the
find-and-replace interactively; this page is what it changes and why.

| Mine | Yours | Where it appears |
|---|---|---|
| `vanillax.xyz` | your domain | HTTPRoutes, Grafana root_url, cert-manager, external-dns |
| `github.com/mitchross/talos-argocd-proxmox-advanced-starter` | **your fork** | `root.yaml` + all four AppSets — ArgoCD pulls from here, not your working tree |
| `192.168.10.133:30292` | your S3 endpoint | kopiur `ClusterRepository`, CNPG `ObjectStore` |
| cluster name in `omni/cluster-template/` | yours | template metadata + kubeconfig commands |
| 1Password vault + item names | yours | every `externalsecret.yaml` (`grep -rn remoteRef`) — field list in [secret-management.md](secret-management.md) |

Recipe:

1. Fork → clone your fork.
2. `./scripts/adapt-to-your-cluster.sh` (or sed by hand from the table).
3. `git diff` — review every hunk; substitution is global.
4. Commit + **push** (ArgoCD deploys your fork's `main`, not local files).
5. Follow [getting-started.md](getting-started.md).

Things you may also want to change on day 2:

- **Backup schedules/retention** — per-PVC stubs under
  `my-apps/*/*/kopiur/` (`schedule.cron`, `retention`). Distinct cron
  minutes per PVC; no 3 a.m. stampede.
- **Cluster topology** — `omni/machine-classes/` + the cluster template
  (the kit assumes Proxmox with virtio-scsi: `install.disk: /dev/sda`).
- **Grafana admin password** — item referenced in
  `monitoring/prometheus-stack/values.yaml`.
