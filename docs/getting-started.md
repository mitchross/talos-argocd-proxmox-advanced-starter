# Getting started

From nothing to a GitOps cluster with self-restoring storage, in order.
Prerequisites are real external systems — see the
[README's Advanced Contract](../README.md#the-advanced-contract) before
starting: Proxmox + Omni, a 1Password account, an off-cluster S3 box, a
Cloudflare-managed domain.

## 0. Fork + adapt

Fork this repo, then swap my values (domain, repo URL, S3 endpoint,
1Password item names) for yours:
[adapting-to-your-cluster.md](adapting-to-your-cluster.md). ArgoCD pulls
from **your fork's main branch** — un-pushed local changes deploy nothing.

## 1. Provision the Talos cluster (Omni)

Everything under [`omni/`](../omni/) — machine classes, the cluster template
(with the **mandatory Talos 1.13 `machine.install.disk` patch**; without it
fresh VMs wedge in `UPGRADING` forever, with no error surfaced anywhere),
and the provisioning walkthrough. New to Omni + the Proxmox provider? Start
with the no-dependencies base kit:
[sidero-omni-talos-proxmox-starter](https://github.com/mitchross/sidero-omni-talos-proxmox-starter).

```bash
omnictl apply -f omni/machine-classes/
omnictl cluster template sync -f omni/cluster-template/cluster-template.yaml
omnictl cluster template status -f omni/cluster-template/cluster-template.yaml --wait 30m
omnictl kubeconfig --cluster <cluster-name> --service-account --user <sa-name>
kubectl get nodes    # NotReady until Cilium lands — expected
```

## 2. One-time external setup

- **S3 backend** (backups live here; it must outlive the cluster):
  [rustfs-setup.md](rustfs-setup.md) — buckets `kopiur` +
  `postgres-backups`, one workload access key scoped to both.
- **1Password**: create the vault items listed in
  [secret-management.md](secret-management.md).
- **Cloudflare**: an API token (cert-manager DNS01 + external-dns) and a
  tunnel for external routes (`infrastructure/networking/cloudflared/`).

## 3. Bootstrap the GitOps stack

Four copy-paste blocks — Gateway API CRDs, Cilium, the pre-seeded 1Password
secrets, then the hand-off script:

```bash
# Gateway API CRDs (BOTH channels — Cilium 1.19 watches experimental TLSRoute)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/experimental-install.yaml

# Cilium — version and cluster.name MUST match infrastructure/networking/cilium/
# (a mismatch makes ArgoCD fight the CLI install at Wave 0 over Hubble certs)
cilium-cli install --version 1.19.5 \
  --set cluster.name=<cluster-name> \
  --set ipam.mode=kubernetes --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost --set k8sServicePort=7445 \
  --set cgroup.autoMount.enabled=false --set cgroup.hostRoot=/sys/fs/cgroup \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set gatewayAPI.enabled=true --set gatewayAPI.enableAlpn=true \
  --set hubble.enabled=false

# Pre-seed the 1Password bootstrap secrets (names/items: secret-management.md)
kubectl create namespace 1passwordconnect
kubectl create namespace external-secrets
kubectl create secret generic 1password-credentials  -n 1passwordconnect \
  --from-literal=1password-credentials.json="$(op read 'op://<vault>/1passwordconnect/1password-credentials.json')"
kubectl create secret generic 1password-operator-token -n 1passwordconnect \
  --from-literal=token="$(op read 'op://<vault>/1password-operator-token/credential')"
kubectl create secret generic 1passwordconnect -n external-secrets \
  --from-literal=token="$(op read 'op://<vault>/1password-operator-token/credential')"

# Hand off to GitOps — ArgoCD deploys everything else from this repo
./scripts/bootstrap-argocd.sh
```

## 4. Watch the waves walk

```bash
kubectl get applications -n argocd \
  -o custom-columns=NAME:.metadata.name,WAVE:.metadata.annotations.argocd\\.argoproj\\.io/sync-wave,STATUS:.status.sync.status
```

Wave 0 (network, secrets) → 1 (certs, storage) → 2 (kopiur operator) →
3 (backup repo config + CNPG plugin) → 4 (databases) → 5 (monitoring) →
6 (the demo apps). Every wave must be Synced **and Healthy** before the
next starts — [architecture.md](architecture.md) explains the gating.

## 5. Prove it worked: the karakeep restore drill

The kit isn't "up" until a restore has succeeded. Once karakeep runs and
has a `Completed` snapshot (`kubectl -n karakeep get snapshot`):

```bash
kubectl -n karakeep scale deploy/karakeep-web --replicas=0
kubectl -n karakeep delete pvc data-pvc
kubectl -n karakeep get pvc data-pvc -w
# → holds PENDING while the kopiur populator restores, then binds WITH data
kubectl -n karakeep scale deploy/karakeep-web --replicas=1
```

Your bookmarks come back. That `Pending` hold is the whole point of the
kit — [kopiur-explained.md](kopiur-explained.md).
