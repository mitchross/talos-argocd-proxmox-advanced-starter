# Start-to-finish cluster guide

This is the complete path from an empty Proxmox environment to a Talos cluster
that is provisioned by Omni, managed by Argo CD, observable with Prometheus and
Grafana, and able to restore application data before a PVC binds.

The order matters. Networking must work before Argo CD can schedule; secret and
storage controllers must be healthy before backup resources exist; the backup
repository must be reachable before an application PVC can safely restore.

## Tested release set (August 2026)

These are the versions pinned in this repository. “Latest” here means the
newest stable, mutually compatible set—not a collection of unrelated newest
tags. Cilium 1.20 documents Gateway API 1.6.1 support, so the CNI and CRD
bundle move together here.

| Layer | Pin |
|---|---|
| Omni / Proxmox provider | `v1.9.3` / `v0.2.0` |
| Talos / Kubernetes | `v1.13.7` / `v1.36.3` |
| Cilium / Gateway API | `1.20.0` / `v1.6.1` |
| Argo CD | chart `10.2.2`, app `v3.4.6` |
| 1Password Connect / External Secrets | chart `2.4.1` / `2.8.0` |
| cert-manager / Longhorn | `v1.21.1` / `1.12.0` |
| snapshot-controller | chart `5.2.0`, controller `v8.6.0` |
| kopiur | `0.9.2` |
| CloudNativePG / Barman plugin | chart `0.29.0` / `v0.14.0` |
| kube-prometheus-stack | `88.1.3` |
| Gitea | chart `12.7.0` |

All manually referenced container images are digest-pinned. Renovate may open
updates later; treat those as tested upgrades, not permission to float tags.

## 1. Know what you are building

The deployment chain is:

```text
Proxmox
  └─ Omni + Proxmox infrastructure provider
       └─ Talos: 1 control plane + 2 workers
            └─ Gateway API CRDs + Cilium (seeded once)
                 └─ Argo CD root Application
                      ├─ standalone platform Applications, Waves 0–3
                      ├─ infrastructure + database ApplicationSets, Wave 4
                      ├─ monitoring ApplicationSet, Wave 5
                      └─ my-apps ApplicationSet, Wave 6
```

You provide four systems that intentionally live outside the cluster:

- Proxmox and a Linux host for self-hosted Omni
- a 1Password vault and Connect credentials
- S3-compatible storage that survives deletion of the cluster
- a Cloudflare-managed domain, plus Technitium for the private DNS example

Read the [advanced contract](../README.md#the-advanced-contract) before going
further. If those external dependencies are not part of the lab you want, use
the smaller
[Omni/Proxmox starter](https://github.com/mitchross/sidero-omni-talos-proxmox-starter)
first.

Local tools used by the commands below:

```bash
git --version
kubectl version --client
helm version
cilium version --client
omnictl version
op --version
```

## 2. Fork, clone, and adapt the example profile

Argo CD reads your remote Git repository. It never sees uncommitted or unpushed
changes on your laptop.

```bash
git clone https://github.com/<you>/talos-argocd-proxmox-advanced-starter.git
cd talos-argocd-proxmox-advanced-starter
./scripts/adapt-to-your-cluster.sh
git diff --check
git diff
```

The script now covers the application domain, fork URL, S3 and DNS addresses,
Gateway/LB addresses, Cilium identity, Omni domain/host, Proxmox host/storage,
Talos node CIDR, 1Password vault, and Cloudflare tunnel name. It deliberately
does not write credentials. The full substitution table and remaining manual
choices are in [adapting-to-your-cluster.md](adapting-to-your-cluster.md).

Commit and push the adapted profile before the Argo bootstrap:

```bash
git add .
git commit -m "Adapt starter to my homelab"
git push origin main
```

## 3. Bring up Omni and its Proxmox provider

The detailed host, TLS, authentication, firewall, and Proxmox requirements are
in [`omni/docs/PREREQUISITES.md`](../omni/docs/PREREQUISITES.md). Run this part
on the Linux host that will keep Omni running.

Create the ignored runtime files from their tracked examples:

```bash
cp omni/omni/omni.env.example omni/omni/omni.env
cp omni/proxmox-provider/.env.example omni/proxmox-provider/.env
cp omni/proxmox-provider/config.yaml.example omni/proxmox-provider/config.yaml
```

Fill the runtime-only fields:

- `omni/omni/omni.env`: account UUID, initial user, auth provider, TLS paths,
  GPG key path, and persistent etcd/SQLite paths
- `omni/proxmox-provider/.env`: the Infrastructure Provider key created in Omni
- `omni/proxmox-provider/config.yaml`: Proxmox API URL and API token

Do not add these three files to Git. Generate the encryption key and TLS
certificate with the included helpers, or supply equivalent files:

```bash
cd omni/omni
./scripts/setup-gpg.sh
sudo ./scripts/setup-ssl.sh
docker compose config
docker compose up -d
docker compose ps
```

Open the Omni UI, sign in as the initial user, create an Infrastructure
Provider named `proxmox`, and copy its provider key into the ignored `.env`.
Then start the provider:

```bash
cd ../proxmox-provider
docker compose config
docker compose up -d
docker compose logs --tail=100 omni-infra-provider-proxmox
```

The provider image is pinned to `v0.2.0`; never put `latest` back into the
Compose file.

## 4. Provision Talos through Omni

From a workstation whose `omnictl` context points at the new Omni instance:

```bash
./omni/bootstrap.sh
```

That applies both machine classes and syncs
`omni/cluster-template/cluster-template.yaml`. The template creates one control
plane and two workers, disables the built-in CNI and kube-proxy, includes the
Longhorn host mount, and sets the explicit `/dev/sda` install disk required by
Talos 1.13.

Watch the Omni UI until the cluster is provisioned, then obtain credentials:

```bash
omnictl kubeconfig --cluster homelab --force
kubectl get nodes -o wide
```

The nodes may remain `NotReady` until Cilium is installed. That is expected;
Talos has no default CNI in this template.

## 5. Prepare the external data, secret, and DNS systems

Complete these three guides before handing control to Argo CD:

1. [rustfs-setup.md](rustfs-setup.md): create `kopiur` and
   `postgres-backups` on an S3 system outside the cluster, then create a scoped
   workload access key.
2. [1password-setup.md](1password-setup.md): create the vault, stand up a
   1Password Connect server, and mint its credentials file and token — then
   [secret-management.md](secret-management.md) for the documented items and
   exact fields.
3. [networking.md](networking.md): configure the Technitium RFC2136 zone/TSIG
   key and the Cloudflare API token and tunnel.

Prove the S3 API is reachable from the same network as the Talos workers:

```bash
nc -zw5 <s3-host> <s3-api-port>
```

Do not continue with a console port, unregistered access key, or an S3 endpoint
that lives inside the cluster being protected.

## 6. Seed Gateway API and Cilium

Install the Gateway API standard channel supported by Cilium 1.20:

```bash
kubectl apply --server-side -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/gateways.gateway.networking.k8s.io
```

This starter defines `HTTPRoute` resources only. If you are upgrading an older
cluster with pre-1.20 `v1alpha2` `TLSRoute` objects, follow Cilium's migration
warning before replacing those CRDs. For a new cluster, keep any additional
Gateway API CRDs on the same 1.6.1 release line.

Install Cilium from the exact values Argo CD will own at Wave 0:

```bash
cilium install --version 1.20.0 \
  --values infrastructure/networking/cilium/values.yaml \
  --wait
cilium status --wait
kubectl get nodes
```

The values file contains the Talos kubePrism endpoint, capabilities, native
routing CIDR, L2 announcements, Gateway API support, and cluster identity.
Using the same file for the seed install prevents Argo CD from fighting a
different CLI configuration a few minutes later.

Now perform an active cross-node probe. A green DaemonSet is not enough if a
firewall, route, or MTU still breaks node-to-node traffic:

```bash
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  cilium-health status --probe
```

Do not start the sync waves until every node and endpoint probe passes.

## 7. Pre-seed the 1Password bootstrap secrets

There is an unavoidable loop: External Secrets needs credentials before it can
fetch credentials. Break it once by creating three Kubernetes Secrets from the
two 1Password items:

```bash
kubectl create namespace 1passwordconnect --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic 1password-credentials -n 1passwordconnect \
  --from-literal=1password-credentials.json="$(op read 'op://<vault>/1passwordconnect/1password-credentials.json')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic 1password-operator-token -n 1passwordconnect \
  --from-literal=token="$(op read 'op://<vault>/1password-operator-token/credential')" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic 1passwordconnect -n external-secrets \
  --from-literal=token="$(op read 'op://<vault>/1password-operator-token/credential')" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The first two feed 1Password Connect; the third lets External Secrets reach
Connect. ESO replaces the third from the vault after the chain is healthy.

## 8. Hand control to Argo CD

Run the only imperative cluster bootstrap script:

```bash
./scripts/bootstrap-argocd.sh
```

The script:

1. verifies the Cilium chart version and active cross-node connectivity;
2. creates Argo CD's namespace and an idempotent Redis auth Secret;
3. installs the Argo CD chart version read from its Kustomization;
4. waits for the CRDs and server;
5. applies `infrastructure/controllers/argocd/root.yaml`.

Everything after that is reconciled from Git. The script prints the local UI
port-forward and generated initial-admin-password commands.

## 9. Understand the root Application and four ApplicationSets

The root Application renders
`infrastructure/controllers/argocd/apps/kustomization.yaml`. That file is the
index for every standalone platform Application and every ApplicationSet.
Every YAML under that directory must appear in its `resources:` list or it is
not deployed.

| Entry point | Discovery rule | What is in this starter |
|---|---|---|
| standalone bootstrap/core apps | explicit YAML files | Argo CD, Cilium, 1Password, ESO, cert-manager, Longhorn, snapshot-controller, kopiur |
| `infrastructure-appset.yaml` | explicit path list | external-dns, cloudflared, gateway |
| `database-appset.yaml` | `infrastructure/database/*/*` | CloudNativePG operator and the Gitea database; `selfHeal: false` preserves deliberate DR annotations |
| `monitoring-appset.yaml` | `monitoring/*` | kube-prometheus-stack and Grafana |
| `my-apps-appset.yaml` | `my-apps/*/*`, excluding `my-apps/common/*` | nginx, Karakeep, Gitea |

The difference is deliberate. General applications and monitoring are safe to
discover by directory. Infrastructure has an explicit list because adding a
controller is a platform decision, not an accidental side effect of creating a
folder. Shared Kustomize Components are excluded because they are mixins, not
deployable Applications.

Every generated Application has strict Go templates, `missingkey=error`,
`allowEmpty: false`, and `FailOnSharedResource=true`. A broken generator or
duplicate owner fails instead of silently producing a misleading green app.

## 10. Watch the sync waves

```bash
kubectl get applications -n argocd -w
```

For a compact view with each root wave:

```bash
kubectl get applications -n argocd \
  -o custom-columns='NAME:.metadata.name,WAVE:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

| Wave | What becomes healthy before the next wave |
|---|---|
| 0 | Cilium, Argo CD self-management, 1Password Connect, External Secrets |
| 1 | cert-manager, Longhorn, CSI snapshot-controller |
| 2 | kopiur controller, webhook, volume populator, and eight CRDs |
| 3 | kopiur repository/credential fan-out/snapshot class and CNPG Barman plugin |
| 4 | explicit infrastructure paths and database directories |
| 5 | Prometheus, Alertmanager, and Grafana |
| 6 | nginx, Karakeep, and Gitea |

The custom `Application` and kopiur `Restore` health checks in Argo CD's values
make these real health gates. Without them, waves only sort resource creation.

## 11. Verify each platform layer

Foundation and secret chain:

```bash
cilium status
kubectl get clustersecretstore 1password
kubectl get externalsecret,clusterexternalsecret -A
kubectl get secret -n karakeep kopiur-rustfs
```

Storage and backup layer:

```bash
kubectl get storageclass
kubectl -n longhorn-system get pods
kubectl get volumesnapshotclass longhorn-snapclass
kubectl get clusterrepository cluster-kopia
kubectl get snapshotpolicy,snapshotschedule,restore -A
```

Database and monitoring layer:

```bash
kubectl -n cloudnative-pg get deployment,pod
kubectl -n cloudnative-pg get deployment/barman-cloud service/barman-cloud
kubectl get objectstore -A
kubectl -n gitea get cluster.postgresql.cnpg.io
kubectl -n prometheus-stack get pod
kubectl get servicemonitor,prometheusrule -A
```

Application and routing layer:

```bash
kubectl get applications -n argocd
kubectl get httproute -A
kubectl -n gateway get gateway
dig @<technitium-ip> nginx.<domain> +short
curl -I https://nginx.<domain>
curl -I https://gitea.<domain>
```

Expected result: all Argo Applications are `Synced` and `Healthy`; the private
name returns the internal Gateway address; Gitea reaches the external Gateway
through Cloudflare; the ClusterRepository is ready.

## 12. Prove backup and restore before trusting it

Put a recognizable bookmark into Karakeep. Then create a manual Snapshot so
the test does not depend on the hourly schedule:

```bash
SNAPSHOT_NAME=$(kubectl create -n karakeep -f - -o jsonpath='{.metadata.name}' <<'EOF'
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Snapshot
metadata:
  generateName: data-pvc-manual-
spec:
  policyRef:
    name: data-pvc
  description: getting-started restore canary
EOF
)

kubectl wait -n karakeep \
  --for=jsonpath='{.status.phase}'=Succeeded \
  "snapshot/${SNAPSHOT_NAME}" --timeout=30m
kubectl -n karakeep get snapshot "${SNAPSHOT_NAME}" -o wide
```

Do not delete the PVC unless the Snapshot reached `Succeeded` with non-zero
files and bytes. Then run the destructive half of the canary:

```bash
kubectl -n karakeep scale deployment/karakeep-web --replicas=0
kubectl -n karakeep delete pvc data-pvc
kubectl -n karakeep get pvc data-pvc -w
# Pending while kopiur hydrates it, then Bound
kubectl -n karakeep scale deployment/karakeep-web --replicas=1
```

Open Karakeep and verify the bookmark is back. The important observation is
not merely that a backup object exists; it is that the replacement PVC stayed
`Pending` until its original bytes were restored. See
[kopiur-explained.md](kopiur-explained.md) for the component/stub/dataSourceRef
contract and mover identity rules.

## 13. Day-two changes

Add an ordinary application:

1. Copy `my-apps/development/nginx/` to `my-apps/<category>/<name>/`.
2. Give it a Namespace, Kustomization, named Service port, and HTTPRoute.
3. Add the kopiur bundle or the documented backup-exempt labels for every PVC.
4. Push. The `my-apps` ApplicationSet discovers the directory at Wave 6.

Add monitoring:

1. Add a directory under `monitoring/<name>/` with a Kustomization.
2. Push. The monitoring ApplicationSet discovers it at Wave 5.
3. Keep monitoring out of the dependency path for core controllers.

Add infrastructure:

1. Add the directory and Kustomization under `infrastructure/`.
2. Add its path explicitly to `infrastructure-appset.yaml`, or create a
   standalone wave-gated Application if later resources depend on it.
3. Add any new standalone YAML entrypoint to the Argo apps Kustomization.
4. Render and validate before pushing.

Run the same checks CI runs:

```bash
for d in $(find infrastructure monitoring my-apps -name kustomization.yaml -exec dirname {} \;); do
  kustomize build --enable-helm "$d" >/dev/null || echo "FAIL: $d"
done
./scripts/validate-argocd-apps.sh
./scripts/validate-image-pins.sh
```

The exact ApplicationSet mechanics, health gating, networking contract, and
backup-system boundary are expanded in [architecture.md](architecture.md).

## Troubleshooting map

| Symptom | First place to look |
|---|---|
| Omni VM stuck installing/upgrading | explicit `machine.install.disk`, storage selector, provider logs; [`omni/docs/TROUBLESHOOTING.md`](../omni/docs/TROUBLESHOOTING.md) |
| Nodes stay `NotReady` | Cilium status, Talos capabilities, kubePrism endpoint |
| Nodes ready but cross-node traffic fails | `cilium-health status --probe`, host firewall, routing, MTU |
| Root is healthy but an app never appears | AppSet discovery path; `apps/kustomization.yaml` listing rule |
| ExternalSecret is not ready | 1Password bootstrap secrets, Connect pods, exact item/field names |
| HTTPRoute accepted but traffic fails | named Service port, `parentRefs`, Gateway listener status |
| PVC waits forever | distinguish a safe backend error from a missing/misnamed `Restore` CR |
| PVC binds empty | missing snapshot is allowed on day zero; verify the S3 repo and create a restore canary before relying on DR |
| CNPG restore fails | Barman ObjectStore, prior lineage/serverName, plugin in the operator namespace; [cnpg-explained.md](cnpg-explained.md) |
