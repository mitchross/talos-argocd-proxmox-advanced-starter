# Omni — Talos provisioning on Proxmox

This directory deploys **Sidero Omni** (the Talos cluster lifecycle
platform) plus the **Omni Proxmox infrastructure provider**, which lets
Omni create and manage Talos VMs in your Proxmox cluster automatically.

The end state of running everything in this directory is: a healthy
Talos cluster registered in Omni, with a kubeconfig you can `kubectl
get nodes` against. After that, you move to the repo root and run
`scripts/bootstrap-argocd.sh` to install the GitOps stack on top.

> 90% of this content is ported from
> [`mitchross/sidero-omni-talos-proxmox-starter`](https://github.com/mitchross/sidero-omni-talos-proxmox-starter)
> with placeholders so it adapts to any Proxmox host. The
> `cluster-template/cluster-template.yaml` carries one extra patch
> (`install-disk: /dev/sda`) that's required on Talos 1.13+ — without
> it, fresh VMs silently get stuck in `maintenanceUpgrade` forever.

---

## Layout

```
omni/
├── omni/                   # Self-hosted Omni server (docker-compose)
│   ├── docker-compose.yml
│   ├── omni.env.example    # Copy to omni.env, fill in placeholders
│   └── scripts/
│       ├── setup-ssl.sh    # Cloudflare DNS-01 cert via Certbot (interactive)
│       └── setup-gpg.sh    # GPG keypair for etcd-at-rest encryption (interactive)
├── proxmox-provider/       # Proxmox infrastructure provider (docker-compose)
│   ├── docker-compose.yml
│   ├── .env.example        # Copy to .env, fill in OMNI_API_ENDPOINT + provider key
│   └── config.yaml.example # Copy to config.yaml, fill in Proxmox URL + auth
├── machine-classes/        # `omnictl apply` these to register VM specs
│   ├── control-plane.yaml  # 4c / 16G / 60G — for etcd nodes
│   └── worker.yaml         # 8c / 32G / 200G — for workloads
├── cluster-template/
│   └── cluster-template.yaml  # `omnictl cluster template sync -f` this once
├── bootstrap.sh            # Helper: apply machine-classes + cluster-template
└── docs/
    ├── PREREQUISITES.md    # Things to have set up before starting
    └── TROUBLESHOOTING.md  # Common Omni / provider / Talos failures
```

---

## High-level flow

1. **Read `docs/PREREQUISITES.md`** — Proxmox host, Docker on a Linux
   host, a domain you control, an authentication provider (Auth0 is
   easiest for a homelab), and a few network ports open.
2. **Generate the GPG key** for etcd encryption and the SSL cert for
   Omni's own UI. Two interactive scripts in `omni/scripts/` automate
   both.
3. **Bring Omni up** with `docker compose up -d` from the `omni/`
   subdirectory. Visit the URL you chose, finish initial setup, then
   create an **Infrastructure Provider** entry — copy the key it gives
   you.
4. **Bring the Proxmox provider up** from `proxmox-provider/` with
   that key in `.env` and your Proxmox API token in `config.yaml`.
5. **Apply machine classes and the cluster template** with
   `./bootstrap.sh`. Omni will create the VMs in Proxmox, install
   Talos, and assemble the cluster.
6. **Pull the kubeconfig** from the Omni UI (or via `omnictl`) and
   verify `kubectl get nodes`.
7. **Move to the repo root** and run
   `scripts/bootstrap-argocd.sh` to install ArgoCD and the rest of
   the GitOps stack.

---

## Quick reference — placeholder substitutions

These values are sprinkled across the env/config files. Run
`scripts/adapt-to-your-cluster.sh` from the repo root to substitute
them all at once, or edit by hand.

| Placeholder | Used in | Example |
|---|---|---|
| `__REPLACE_ME_DOMAIN__` | `omni/omni.env.example`, `proxmox-provider/.env.example` | `homelab.example.com` |
| `__REPLACE_ME_OMNI_ENDPOINT__` | `proxmox-provider/.env.example` | `https://omni.homelab.example.com/` |
| `__REPLACE_ME_PROXMOX_HOST__` | `proxmox-provider/config.yaml.example` | `192.168.1.10` |
| `__REPLACE_ME_PROXMOX_TOKEN__` | `proxmox-provider/config.yaml.example` | `root@pam!iac=abc123-...` |
| `__REPLACE_ME_PROXMOX_STORAGE_POOL__` | `machine-classes/*.yaml` | `local-zfs` |
| `__REPLACE_ME_NODE_CIDR__` | `cluster-template/cluster-template.yaml` | `192.168.1.0/24` |

---

## What's deliberately NOT here

- **GPU machine class** — present in the source as `gpu-worker.yaml`, lifted to
  `docs/extending/adding-gpu-support.md` as a recipe. Adds NVIDIA system
  extensions, IOMMU PCI passthrough config, and a separate worker class.
- **10G storage network** — the source's worker class includes a second
  NIC (`vmbr1`) attached to a TrueNAS over 10G DAC. The starter's worker
  class is single-NIC; if you have a separate storage network, see
  `docs/extending/` for the additional-NICs pattern.
- **Multi-disk workers** — same idea: simple by default; document the
  shape for users who need it.
- **Aggressive sysctl tuning + etcd resource bumps** — the source's
  cluster template carries `inotify.max_user_watches=1048576`,
  `quota-backend-bytes=8589934592`, and similar production-cluster
  knobs. The starter ships defaults so a homelab Proxmox host doesn't
  need pre-allocated hugepages, etc. Tuning recipe goes in
  `docs/extending/`.

---

## After this directory: ArgoCD bootstrap

Once `kubectl get nodes` shows `Ready` for every node, jump to the
repo root and continue:

```bash
cd ..
./scripts/bootstrap-argocd.sh
```

That installs Cilium, applies Gateway API CRDs, installs ArgoCD via
Helm, and applies the root Application that takes over GitOps
self-management. From there, ArgoCD discovers everything else from
the directory tree and deploys it in sync-wave order.
