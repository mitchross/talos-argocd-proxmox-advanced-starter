# Adapting the kit to your cluster

The manifests ship with a concrete example profile so the relationships stay
visible. `./scripts/adapt-to-your-cluster.sh` replaces that profile
interactively; review every resulting diff before pushing.

| Mine | Yours | Where it appears |
|---|---|---|
| `vanillax.xyz` | your domain | HTTPRoutes, Grafana root_url, cert-manager, external-dns |
| `github.com/mitchross/talos-argocd-proxmox-advanced-starter` | **your fork** | `root.yaml` + all four AppSets — ArgoCD pulls from here, not your working tree |
| `192.168.10.133` + `30292` | your S3 host + API port | kopiur, CNPG, and the Cilium egress allowlist |
| `192.168.10.15` | your Technitium DNS server | RFC2136 external-dns + its egress policy |
| `192.168.10.52` + `192.168.10.32/27` | internal Gateway IP + Cilium LB pool | Gateway and L2 IPAM |
| Cilium cluster name + Talos node CIDR | yours | bootstrap/Helm identity + Omni kubelet selection |
| `homelab-prod` | your 1Password vault | `ClusterSecretStore` |
| `threadripper` | your Cloudflare tunnel name | cloudflared config |
| Omni domain + host IP | yours | self-hosted Omni endpoints and SideroLink |
| Proxmox host + storage pool | yours | provider config and both machine classes |

Recipe:

1. Fork → clone your fork.
2. `./scripts/adapt-to-your-cluster.sh` (or sed by hand from the table).
3. `git diff` — review every hunk; substitution is global.
4. Commit + **push** (ArgoCD deploys your fork's `main`, not local files).
5. Follow [getting-started.md](getting-started.md).

The script substitutes non-secret Omni and Proxmox values, but it deliberately
does not write credentials. Copy `omni/omni/omni.env.example` to the ignored
`omni.env`, copy both provider examples to `.env` and `config.yaml`, then put
the infrastructure-provider key and Proxmox API token only in those ignored
files. Configure the Technitium TSIG key, ExternalDNS owner IDs, Cloudflare
tunnel, machine sizing, and 1Password items deliberately. See
[networking.md](networking.md) and [secret-management.md](secret-management.md).

Things you may also want to change on day 2:

- **Backup schedules/retention** — per-PVC stubs under
  `my-apps/*/*/kopiur/` (`schedule.cron`, `retention`). Distinct cron
  minutes per PVC; no 3 a.m. stampede.
- **Cluster topology** — `omni/machine-classes/` + the cluster template
  (the kit assumes Proxmox with virtio-scsi: `install.disk: /dev/sda`).
- **Grafana admin password** — item referenced in
  `monitoring/prometheus-stack/values.yaml`.
