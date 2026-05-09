# Getting started

> Status: stub — coming soon.

TODO: cold-cluster walkthrough. Sequence is:

1. **Prereqs**: Proxmox VE host (≥64GB RAM, ≥600GB), kubectl, helm,
   cilium-cli, kubeseal installed locally.
2. **Provision the cluster**: cd `omni/`, follow `omni/README.md` to
   bring up Sidero Omni + the Proxmox provider, then deploy a 1 CP +
   2 worker cluster from `omni/cluster-template/`.
3. **Adapt the manifests**: run `./scripts/adapt-to-your-cluster.sh`.
   Substitute every `__REPLACE_ME_*__` token. Commit + push to your
   fork.
4. **Install Cilium**: `cilium install --version 1.19.3 ...` (the
   `bootstrap-argocd.sh` script prints the full command if Cilium
   isn't installed or unhealthy when you run it).
5. **Bootstrap ArgoCD**: `./scripts/bootstrap-argocd.sh`. After this
   completes, ArgoCD takes over its own management.
6. **Seal the kopia password**: `./scripts/seal-secret.sh
   --kopia-password`. Generates a random 32-byte password and seals
   it alongside your S3 admin keys. Commit + push.
7. **Watch the sync waves**: `kubectl get applications -n argocd -w`.
   When wave 6 turns Healthy, you're done.

The README's "Quick start" section is the at-a-glance version; this
doc fills in the prereq / provisioning details.
