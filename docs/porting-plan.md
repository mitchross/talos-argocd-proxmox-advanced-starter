# Porting Plan — talos-argocd-proxmox-advanced-starter

> **Status**: draft, awaiting conductor sign-off on §7 questions 2–5 (Q1 — sealed-secrets-only default — pre-greenlit by the conductor 2026-05-07).
> **Author**: starter-architect (tempo-soloist).
> **Inputs studied**: `talos-argocd-proxmox` (`refactor-replace-kyverno` branch — primary source of truth, post-Kyverno architecture), `mitchross/sidero-omni-talos-proxmox-starter` (Omni + Proxmox provisioning shape), `mitchross/talos-argocd-proxmox-starter` (predecessor — used as inspiration for README shape only; its IaC layer is stale).
>
> **Core principle**: opinionated minimalism. Where the source cluster has 8 examples we ship 1; where it has paid services we swap free-tier defaults; where it has GPU/proprietary apps we ship platform-feature demos.
>
> **Source-cluster scope discipline (per conductor)**:
>
> 1. **Canonicality**: the working cluster (`talos-argocd-proxmox` on `refactor-replace-kyverno`) is the canonical source of truth. When the source cluster and either upstream starter (`sidero-omni-talos-proxmox-starter`, `talos-argocd-proxmox-starter`) disagree on Talos / machine-set / Omni / manifest / script details — **source cluster wins**. The upstream starters are stale relative to the post-Kyverno-removal architecture; the user maintains the source cluster as their working homelab. Already applied correctly to the Talos 1.13 install-disk patch (caught from source, ignored sidero-starter's lack); making it the explicit rule going forward.
> 2. **Read-only on the source**: any stale Kyverno strings I encounter in the source cluster while porting (beyond the two already known — `docs/argocd-entrypoints.md` and `scripts/bootstrap-argocd.sh` echo strings) get **flagged** in my final Phase-1 report for the conductor to sweep on `refactor-replace-kyverno`, **not** patched by me. The starter is the only artifact I write to.

---

## 1. Final directory tree

```
talos-argocd-proxmox-advanced-starter/
├── README.md                                    # already scaffolded
├── CLAUDE.md                                    # already scaffolded
├── LICENSE
├── .gitignore
│
├── omni/                                        # Sidero Omni + Proxmox provisioning (ported from sidero-starter)
│   ├── README.md                                # bootstrap walkthrough for Omni half
│   ├── omni/
│   │   ├── docker-compose.yml                   # self-hosted Omni
│   │   ├── omni.env.example                     # placeholders for SAML/JWT/etc.
│   │   └── scripts/
│   │       ├── setup-ssl.sh
│   │       └── setup-gpg.sh
│   ├── proxmox-provider/
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── config.yaml.example                  # __REPLACE_ME_PROXMOX_HOST__, __REPLACE_ME_PROXMOX_TOKEN__
│   ├── machine-classes/
│   │   ├── control-plane.yaml                   # 4c/16G/60G — fastpool
│   │   └── worker.yaml                          # 8c/32G/200G — ssdpool
│   │   # gpu-worker.yaml lives in docs/extending/ as a recipe, NOT default
│   ├── cluster-template/
│   │   └── cluster-template.yaml                # 3 CP + 2 workers, no GPU class, no Cloudflare
│   ├── bootstrap.sh                             # 1-shot: omnictl apply machine-classes + cluster-template
│   └── docs/
│       ├── PREREQUISITES.md                     # ported from sidero-starter
│       └── TROUBLESHOOTING.md                   # ported, trimmed
│
├── infrastructure/
│   ├── controllers/
│   │   ├── argocd/
│   │   │   ├── ns.yaml
│   │   │   ├── kustomization.yaml               # helm with version pin (argo-cd 9.5.x)
│   │   │   ├── values.yaml                      # global ignoreDifferences for HTTPRoute/ExternalSecret/PVC
│   │   │   ├── root.yaml                        # the manual-applied seed
│   │   │   └── apps/                            # everything below this is GitOps-managed
│   │   │       ├── kustomization.yaml
│   │   │       ├── projects.yaml                # AppProjects: infrastructure / monitoring / apps
│   │   │       ├── bootstrap/                   # Wave 0 — manually placed entrypoints
│   │   │       │   ├── argocd.yaml              # self-managed argocd Application
│   │   │       │   ├── cilium-app.yaml
│   │   │       │   ├── sealed-secrets-app.yaml  # source-of-truth secret backend
│   │   │       │   └── external-secrets-app.yaml # ESO + ClusterSecretStore (kubernetes provider)
│   │   │       ├── core-dependencies/           # Wave 1+2 — storage and backup gating
│   │   │       │   ├── longhorn-app.yaml
│   │   │       │   ├── snapshot-controller-app.yaml
│   │   │       │   ├── volsync-app.yaml
│   │   │       │   └── pvc-plumber-app.yaml
│   │   │       └── appsets/                     # Wave 4-6 — broad discovery
│   │   │           ├── infrastructure-appset.yaml
│   │   │           ├── database-appset.yaml
│   │   │           ├── monitoring-appset.yaml
│   │   │           └── apps-appset.yaml
│   │   ├── cert-manager/                        # cluster-issuer (self-signed for default starter)
│   │   ├── sealed-secrets/                      # default secret backend
│   │   ├── external-secrets/                    # ESO controller + `1password` ClusterSecretStore
│   │   │                                        #   (kubernetes provider, NOT actually 1Password —
│   │   │                                        #    operator hardcodes the name. See cluster-secret-
│   │   │                                        #    store.yaml.)
│   │   └── pvc-plumber/                         # the v2 operator (Deployment + 3 webhooks + RBAC)
│   │                                            #   plus a hand-written ExternalSecret for the
│   │                                            #   operator pod's own kopia password
│   ├── networking/
│   │   ├── cilium/                              # Helm values — gatewayAPI enabled, Hubble enabled
│   │   └── gateway/                             # internal Gateway only by default; external listed as recipe
│   ├── storage/
│   │   ├── csi-driver-nfs/                      # NFS mount support for VolSync repository
│   │   ├── snapshot-controller/                 # used as a STANDALONE app at W1 (not via AppSet)
│   │   ├── longhorn/                            # default StorageClass
│   │   └── volsync/                             # backup engine
│   └── database/
│       └── cnpg-operator/                       # CloudNativePG operator only
│           # CNPG instance for postgres-demo lives under apps/postgres-demo/, not here
│
├── monitoring/                                  # Wave 5 — discovered by AppSet
│   ├── kube-prometheus-stack/                   # Prometheus + Grafana + AlertManager
│   └── loki-stack/                              # Loki + Promtail (logs)
│
├── apps/                                        # Wave 6 — discovered by AppSet
│   ├── nginx-demo/                              # stateless app + HTTPRoute (Gateway API demo)
│   ├── stateful-demo/                           # PVC w/ backup:hourly label (pvc-plumber demo)
│   └── postgres-demo/                           # CNPG cluster + Barman backup-to-S3 (DB DR demo)
│
├── scripts/
│   ├── adapt-to-your-cluster.sh                 # the placeholder substitution script
│   ├── bootstrap-argocd.sh                      # cilium pre-flight + helm install argocd + apply root.yaml
│   ├── seal-secret.sh                           # wrapper around `kubeseal` for users
│   └── validate-cluster-health.sh               # quick smoke-check of all sync waves
│
└── docs/
    ├── porting-plan.md                          # ← this file
    ├── getting-started.md                       # cold-cluster walkthrough
    ├── architecture.md                          # sync waves, AppSet discovery, GitOps self-management
    ├── pvc-backup-restore.md                    # backup:hourly label pattern, pvc-plumber operator
    ├── secret-management.md                     # sealed-secrets default, swap to ESO/Vault recipes
    ├── adapting-to-your-cluster.md              # placeholder reference
    ├── extending/                               # recipe directory, NOT default-deployed
    │   ├── adding-gpu-support.md                # nvidia-gpu-operator + Talos system extension
    │   ├── adding-cloudflare.md                 # external-DNS + cloudflare tunnel + cert-manager DNS-01
    │   ├── swapping-secret-backend.md           # sealed-secrets → ESO+1Password / Vault
    │   ├── adding-an-app.md                     # cookbook: add a directory, label PVC, push
    │   └── disaster-recovery.md                 # restore-from-zero playbook
    └── images/                                  # diagrams (ported from source if any)
```

**What this tree omits relative to the source cluster**: `infrastructure/controllers/1passwordconnect/`, `infrastructure/controllers/external-secrets/` (out by default — promoted to extension recipe), `infrastructure/controllers/external-dns/`, `infrastructure/controllers/keda/`, `infrastructure/controllers/temporal-worker-controller/`, `infrastructure/controllers/opentelemetry-operator/`, `infrastructure/controllers/nvidia-gpu-operator/`, `infrastructure/controllers/node-feature-discovery/`, `infrastructure/controllers/gpu-priority-classes/`, `infrastructure/controllers/metrics-server/` (Talos ships this; not strictly needed for starter), `infrastructure/networking/cloudflared/`, `infrastructure/networking/cloudflare-workers/`, `infrastructure/database/redis/`, `infrastructure/database/crunchy-postgres/`, `infrastructure/storage/csi-driver-smb/`, `infrastructure/storage/local-storage/`, `infrastructure/storage/container-registry/`, `infrastructure/storage/kopia-ui/`, `infrastructure/storage/rustfs-lifecycle/`, `monitoring/k8sgpt/`, `monitoring/tempo/`, `monitoring/pod-cleanup/`, all `my-apps/` (replaced by 3 demo apps).

---

## 2. Porting matrix

| Component | Source repo | Disposition | Notes |
|---|---|---|---|
| **omni/omni/** (self-hosted Omni docker-compose) | sidero-starter | **COPY** | Add `__REPLACE_ME_DOMAIN__` to `omni.env.example`. |
| **omni/proxmox-provider/** | sidero-starter | **COPY** | Substitute `__REPLACE_ME_PROXMOX_HOST__` and `__REPLACE_ME_PROXMOX_TOKEN__` in `config.yaml.example`. |
| **omni/machine-classes/control-plane.yaml** | sidero-starter | **ADAPT** | Drop the `fastpool` storage_selector to `local-zfs` (Proxmox default) — fewer prerequisites. Document `fastpool` swap as recipe. |
| **omni/machine-classes/worker.yaml** | sidero-starter | **ADAPT** | Same as control-plane. Strip the `additional_nics` 10G storage network — homelab default is single-NIC. |
| **omni/machine-classes/gpu-worker.yaml** | sidero-starter | **SKIP** | Hardware-specific; ships in `docs/extending/adding-gpu-support.md` as a recipe. |
| **omni/cluster-template/cluster-template.yaml** | local source cluster (`omni/cluster-template/cluster-template.yaml`) | **ADAPT** | Use the source cluster's version (it has the Talos 1.13 `install-disk` patch which the sidero-starter version lacks). Drop the gpu-workers section. Strip docker-hub-auth patch (homelab-specific). Swap `192.168.10.0/24` → `__REPLACE_ME_NODE_CIDR__`. |
| **omni/cluster-template/patches/docker-hub-auth.yaml** | source | **SKIP** | Homelab-specific. Document via `omni/cluster-template/patches/docker-hub-auth.yaml.example` ported from source. |
| **omni/docs/** | sidero-starter | **COPY** | Trim TROUBLESHOOTING.md to the starter-relevant sections only. |
| **infrastructure/controllers/argocd/** (Helm + values) | source | **ADAPT** | Pin to argo-cd `9.5.x` (matches source). Remove 1Password-specific bootstrap notes from `values.yaml`. Strip the `argocd.argoproj.io/manifest-generate-paths` references that point at source-specific paths. Remove `externalsecret-webhook.yaml` (no ESO in default starter). |
| **infrastructure/controllers/argocd/apps/projects.yaml** | source | **ADAPT** | Substitute `__REPLACE_ME_GIT_REPO_URL__` for `sourceRepos`. Three projects: infrastructure / monitoring / my-apps. |
| **infrastructure/controllers/argocd/apps/bootstrap/** | source | **ADAPT** | Replace `1passwordconnect.yaml` with `sealed-secrets-app.yaml`. Drop `external-secrets.yaml`. Add `cert-manager-app.yaml` to W0 (needed by W1 plumber webhook TLS — see Sync Wave note in §5). Keep `argocd.yaml`, `cilium-app.yaml`. |
| **infrastructure/controllers/argocd/apps/core-dependencies/** | source | **COPY** | All four (longhorn, snapshot-controller, volsync, pvc-plumber). Substitute repo URL. |
| **infrastructure/controllers/argocd/apps/custom-entrypoints/** | source | **PARTIAL** | Source ships 4 standalone apps here (cnpg-barman-plugin, keda, temporal-worker-controller, opentelemetry-operator). Starter ships only **cnpg-barman-plugin** (now W3, per conductor revision 2026-05-07 — needed because postgres-demo ships Barman backups by default). KEDA, Temporal, OTEL stay SKIP — none of the demos require them. The plugin App will be added during Phase 2h alongside the postgres-demo work, not in the existing 2b commit's `apps/kustomization.yaml` resource list (which still lists only bootstrap/ and core-dependencies/longhorn-snapshot-volsync-plumber). 2h commit will add an entry to `apps/kustomization.yaml` for the plugin App and the manifests under `infrastructure/database/cnpg-barman-plugin/`. |
| **infrastructure/controllers/argocd/apps/appsets/infrastructure-appset.yaml** | source | **ADAPT** | Hand-listed paths (the source cluster intentionally lists explicit paths, not glob, to dodge a known repo-server cache loop). Reduced list: `cert-manager` (already W0; remove from here), `csi-driver-nfs`, `gateway`. That's it for the starter's W4 AppSet. |
| **infrastructure/controllers/argocd/apps/appsets/database-appset.yaml** | source | **ADAPT** | Glob `infrastructure/database/*/*` only matches `cnpg-operator/` for now. `selfHeal: false` for DR is preserved. |
| **infrastructure/controllers/argocd/apps/appsets/monitoring-appset.yaml** | source | **COPY** | Glob `monitoring/*` matches kube-prometheus-stack and loki-stack. |
| **infrastructure/controllers/argocd/apps/appsets/apps-appset.yaml** | source | **ADAPT** | Renamed from `my-apps-appset.yaml` to `apps-appset.yaml`; glob `apps/*` (not `apps/*/*` — the demo apps live one level deep, no category nesting). Drop the imagePullPolicy ignoreDifferences (was a Kyverno-mutation residue). |
| **infrastructure/controllers/cert-manager/** | source | **ADAPT** | Default ClusterIssuer is **self-signed** (not Let's Encrypt-Cloudflare). Document Cloudflare DNS-01 swap as recipe. |
| **infrastructure/controllers/sealed-secrets/** | NEW (no source) | **NEW** | Hand-written: bitnami sealed-secrets Helm chart pinned + the cluster controller. Tiny — one Helm app. |
| **infrastructure/controllers/external-secrets/** | source `infrastructure/controllers/external-secrets/` (chart + ESO mechanics) + the operator's hardcoded `secretStoreRef.name="1password"` constraint | **NEW (revised in 2c-fix per conductor 2026-05-07)** | Originally SKIP per the sealed-secrets-only architecture. **Reverted** because pvc-plumber rc1's PVC reconciler hardcodes `ExternalSecret` creation — without ESO running, per-PVC mover Jobs can't mount a kopia password and backups silently no-op. Architecture: ESO controller + `ClusterSecretStore` named `1password` (yes — operator hardcodes this name; can't change without operator code work) using the **`kubernetes` provider** pointed at `Secret/rustfs` in volsync-system (also operator-hardcoded — `remoteRef.key=rustfs`, `remoteRef.property=kopia_password`). Mirrors source's chart pin (2.4.1) + the CRD `ServerSideApply` patches. Wave 0. |
| **infrastructure/controllers/1passwordconnect/** | source | **SKIP** | Paid service, out of defaults. The ESO `1password` ClusterSecretStore in this starter is named after the contract (operator hardcodes `secretStoreRef.name=1password`) but uses the `kubernetes` provider, NOT the `onepassword` provider — so 1Password Connect is genuinely not running. The swap-backend recipe in `docs/extending/swapping-secret-backend.md` walks through replacing `kubernetes` with `onepassword` (or `vault`, `awssm`, `gcpsm`, etc.) — only the provider stanza changes, not the architecture. |
| **infrastructure/controllers/pvc-plumber/** | source | **ADAPT** | Port verbatim except: (1) replace `externalsecret.yaml` with a SealedSecret containing the Kopia password, (2) substitute `__REPLACE_ME_NFS_SERVER__` and `__REPLACE_ME_NFS_PATH__` in deployment.yaml, (3) keep the asymmetric-failurePolicy webhook config exactly as-is including the 9-namespace exclusion list (and adjust comment to reference "data-loss prevention" generically rather than the 2026-04-08 incident). Reference the operator image: `ghcr.io/mitchross/pvc-plumber:2.0.0-rc1` per kickoff. |
| **infrastructure/networking/cilium/** | source | **ADAPT** | Strip `cluster.name=talos-prod-cluster` → `__REPLACE_ME_CLUSTER_NAME__`. Strip `ipv4NativeRoutingCIDR: 10.14.0.0/16` → keep but make it a placeholder if the user customizes. Strip `bandwidthManager.bbr` and `enableIPv4BIGTCP` — too kernel-specific for a starter default; document as performance-tuning recipe. |
| **infrastructure/networking/gateway/** | source | **ADAPT** | Ship internal Gateway only. Hostname `*.__REPLACE_ME_DOMAIN__`. Address `__REPLACE_ME_GATEWAY_IP__`. Drop external Gateway + external-DNS labels (recipe). Drop the postgres TCP listener (recipe — only postgres-demo would use it, and it adds complexity). |
| **infrastructure/storage/longhorn/** | source | **COPY** | Ports cleanly. The values.yaml already has reasonable defaults; just remove any `httpRoute.yaml` reference or substitute the domain. |
| **infrastructure/storage/snapshot-controller/** | source | **COPY** | No-op port. |
| **infrastructure/storage/volsync/** | source | **ADAPT** | Strip the `kopia-maintenance-cronjob.yaml` of any 1Password ExternalSecret refs; replace with SealedSecret. |
| **infrastructure/storage/csi-driver-nfs/** | source | **COPY** | Helm chart pinned. |
| **infrastructure/database/cnpg-operator/** | source `infrastructure/database/cloudnative-pg/cloudnative-pg-operator/` | **COPY** | Just the operator install. CNPG cluster instances live in `apps/postgres-demo/`. |
| **infrastructure/database/cnpg-barman-plugin/** | source `infrastructure/database/cnpg-barman-plugin/` | **COPY** | The Barman ObjectStore plugin that postgres-demo's `Cluster` CR references for backup/recovery. Wave 3 standalone Application (`core-dependencies/cnpg-barman-plugin-app.yaml`) so it's installed before the Cluster CR comes up at W6. Per conductor revision 2026-05-07. |
| **monitoring/kube-prometheus-stack/** | source `monitoring/prometheus-stack/` | **ADAPT** | Drop the Grafana sidecar dashboard ConfigMaps that pull homelab-specific metrics. Default to no persistent storage for AlertManager (or 512Mi). Pin `kube-prometheus-stack` chart to a stable minor (84.x — the source has 82, 83, 84 charts vendored; pick 84.x). Strip 1Password-derived Grafana admin password — use sealed-secret. |
| **monitoring/loki-stack/** | source `monitoring/loki-stack/` | **ADAPT** | Default to filesystem storage (no S3). 7-day retention. |
| **monitoring/tempo/, monitoring/k8sgpt/, monitoring/pod-cleanup/** | source | **SKIP** | Out of starter scope. |
| **apps/nginx-demo/** | NEW (handcrafted) | **NEW** | See §3. |
| **apps/stateful-demo/** | NEW (handcrafted) | **NEW** | See §3. |
| **apps/postgres-demo/** | NEW (handcrafted, references source CNPG patterns) | **NEW** | See §3. |
| **scripts/bootstrap-argocd.sh** | source | **ADAPT** | Substitute repo URL placeholder. Keep cilium pre-flight. Update echo strings to match the starter's wave model (W0 W1 W2 W3 W4 — no Kyverno). |
| **scripts/adapt-to-your-cluster.sh** | NEW | **NEW** | sed-style placeholder substitution; interactive prompt. |
| **scripts/seal-secret.sh** | NEW | **NEW** | Thin wrapper around `kubeseal` for users who want to add their own secrets. |
| **scripts/validate-cluster-health.sh** | source | **ADAPT** | Trim to: ArgoCD apps synced, Cilium healthy, Longhorn nodes ready, plumber operator up. |
| **docs/getting-started.md** | source `README.md` | **ADAPT** | Cold-cluster walkthrough; sequence: prereqs → omni up → cluster created → adapt-script → bootstrap-argocd → watch syncs. |
| **docs/architecture.md** | source `docs/argocd.md` + `docs/argocd-entrypoints.md` (deduped + modernized) | **ADAPT** | Sync wave table, AppSet discovery diagram, FAIL-CLOSED admission flow. NO mentions of Kyverno. |
| **docs/pvc-backup-restore.md** | source `docs/pvc-plumber-walkthrough.md` + `docs/volsync-storage-recovery.md` | **ADAPT** | Combine into one explainer. The walkthrough doc is gold; trim the historical "what used to do this" Kyverno section to a one-paragraph "this used to be Kyverno; now it's an operator. See docs/extending/disaster-recovery.md for migration notes" pointer. |
| **docs/secret-management.md** | NEW | **NEW** | Sealed-secrets default; one short example of `seal-secret.sh`; recipe pointers to ESO+1Password / Vault. |
| **docs/adapting-to-your-cluster.md** | NEW | **NEW** | Placeholder reference table — every `__REPLACE_ME_*` and what to put. |
| **docs/extending/adding-gpu-support.md** | source `infrastructure/controllers/nvidia-gpu-operator/` + Talos extension config | **ADAPT** | Recipe form; not deployed by default. |
| **docs/extending/adding-cloudflare.md** | source `infrastructure/networking/cloudflared/` + `cloudflare-cluster-issuer` from cert-manager | **ADAPT** | Three-step recipe: cert-manager DNS-01, external-DNS Cloudflare provider, cloudflared tunnel. |
| **docs/extending/swapping-secret-backend.md** | source `infrastructure/controllers/1passwordconnect/` + ESO ClusterSecretStore | **STUB (Phase 1) → ADAPT (Phase 3)** | Phase 1 ships a one-paragraph stub. **Recipe scope reduced after 2c-fix**: ESO is now in the default starter, so swapping backends (sealed-secrets-as-source → 1Password / Vault / AWS-SM / GCP-SM / Azure-KV / Akeyless) is just **changing the provider stanza in `infrastructure/controllers/external-secrets/cluster-secret-store.yaml`** (5–10 lines), NOT "rip out sealed-secrets and add ESO." Much smaller recipe than originally scoped. The user's source-of-truth secret moves from a SealedSecret in git to whatever their backend stores; the per-PVC operator-templated ExternalSecrets keep working unchanged because they only reference the `1password` ClusterSecretStore name. |
| **docs/extending/adding-an-app.md** | NEW (cookbook) | **NEW** | Add directory + kustomization.yaml + label PVC = deployed. |
| **docs/extending/disaster-recovery.md** | source `docs/cnpg-disaster-recovery.md` + the deadlock-recovery section of `pvc-plumber-walkthrough.md` | **ADAPT** | Walkthrough: cluster lost, restore from Kopia + restore from Barman. |
| **docs/extending/external-s3-backend.md** | NEW | **NEW (Phase 3)** | Recipe — swap the in-cluster MinIO that postgres-demo's CNPG Cluster uses for AWS S3 / Cloudflare R2 / Backblaze B2 / external MinIO. Single sealed-secret swap + ObjectStore endpoint URL change. Per conductor revision 2026-05-07. |
| **docs/extending/scaling-to-ha.md** | NEW | **NEW (Phase 3)** | Recipe — go from the starter's 1 CP + 2 worker default to 3 CP + N workers HA. Cluster template count change, post-bootstrap CP join, optional drain/replace of the original CP. Already promised in README's prereq line; placeholder for it lives at `docs/extending/scaling-to-ha.md`. |
| **docs/source-cluster-comparison.md** | NEW | **NEW (Phase 3 — final deliverable)** | The "what's same / what's different / what's intentionally dropped" reference between this starter and the source homelab cluster. Sections: (1) Components in source but NOT starter (paid services, hardware-specific, proprietary, scope cuts); (2) Components in starter but NOT source (sealed-secrets, in-cluster MinIO, the 3 demo apps); (3) Patterns preserved verbatim (sync waves, AppSet directory discovery, GitOps self-management, magic `backup: hourly` label, fail-closed admission, named Service ports, Talos 1.13 install-disk patch); (4) Patterns simplified (apps-appset glob `apps/*` not `apps/*/*`, single CP + 2 workers, chart-default resources, placeholder substitution model); (5) Patterns deferred to recipes (GPU, Cloudflare, ESO+1Password, KEDA, Temporal, OpenTelemetry, in-cluster registry). Per conductor revision 2026-05-07. As I work each phase I jot quick notes to a gitignored `.compare-notes.md` so reconstructing rationale at the end is cheap. |

---

## 3. Demo apps spec

Three apps, each demonstrating exactly one platform feature.

### `apps/nginx-demo/` — Gateway API demo
- **What it shows**: stateless Deployment + Service with named port `http` + HTTPRoute that attaches to the internal Gateway via `sectionName: https`.
- **What's in it**: `deployment.yaml`, `service.yaml`, `httproute.yaml`, `kustomization.yaml`, `namespace.yaml`. Image: stock `nginx:alpine`. ConfigMap with a `<h1>Hello from the GitOps starter</h1>` index.html.
- **Why it teaches**: HTTPRoute `parentRefs` + `sectionName` is the exact pattern that fails silently with port not named or sectionName missing — the demo is intentionally minimal so the user can grep the YAML and "see the cluster's HTTPRoute pattern" in 30 seconds.
- **Source**: handcrafted. The source cluster's `my-apps/development/nginx/` is too entangled with Helm/sidecars; we want bare YAML.

### `apps/stateful-demo/` — `backup: hourly` label demo
- **What it shows**: a Deployment + a single PVC with `metadata.labels.backup: hourly`. After deploy, the user can `kubectl get replicationsource,replicationdestination,externalsecret -n stateful-demo` and watch pvc-plumber generate them.
- **What's in it**: `deployment.yaml` (a tiny `busybox` writing a timestamped file every 30s into the PVC), `pvc.yaml` (1Gi, `storageClassName: longhorn`, `backup: hourly` label), `kustomization.yaml`, `namespace.yaml`.
- **Strategy**: `Recreate` on the Deployment (RWO PVC pattern). Demonstrates the source cluster's "RollingUpdate causes Multi-Attach deadlock" rule in passing.
- **Why it teaches**: this is THE platform feature. After the user sees the PVC populate and `kubectl logs` the pvc-plumber pod showing the backup schedule, the value of the operator is obvious.
- **Source**: handcrafted. The source cluster's project-zomboid PVC pattern is the reference but we don't want a game server in the starter.

### `apps/postgres-demo/` — CNPG cluster + Barman backup demo
- **What it shows**: a 1-replica CloudNativePG `Cluster` wired to the **CNPG-Barman ObjectStore plugin** for continuous WAL archiving + scheduled base backups, with **in-cluster MinIO** as the S3 backend. Demonstrates database-native DR end-to-end.
- **Decision history**: original Phase-1 plan defaulted to `initdb`-only with a `--enable-backups` flag. **Reversed by conductor 2026-05-07** — for an *advanced* starter, initdb-only is a toy demo; CNPG-with-backup-and-restore is the platform pattern users actually need. No flag, no opt-in: backups ship by default.
- **What's in it**:
  - `namespace.yaml`
  - `minio.yaml` — single-Deployment MinIO with persistent PVC (longhorn StorageClass), Service, and a sealed-secret containing admin creds
  - `minio-bootstrap-job.yaml` — Job that runs once to create the `cnpg-backups` bucket via `mc` CLI (idempotent, ArgoCD hook annotated)
  - `cluster.yaml` — CNPG `Cluster` kind, 1 instance, 5Gi storage, longhorn StorageClass, `bootstrap.initdb` for fresh install, `backup.barmanObjectStore` (or via plugin) referencing the in-cluster MinIO
  - `scheduled-backup.yaml` — CNPG `ScheduledBackup` running every 6h with 7-day retention
  - `kustomization.yaml`
  - `README.md` — kubectl commands to verify backup completion (`kubectl get backup -n postgres-demo`), trigger a manual backup, do point-in-time recovery via `bootstrap.recovery`
- **Why it teaches**: (1) directory-discovery AppSet handles operator-CRs as cleanly as Deployments; (2) database-native DR (Barman) is a separate, complementary system to PVC-level DR (pvc-plumber/Kopia/VolSync) — the starter teaches both; (3) the ObjectStore-on-MinIO shape is the same pattern that swaps cleanly to AWS S3 / Cloudflare R2 / Backblaze B2 / external MinIO with a single env-var change (recipe: `docs/extending/external-s3-backend.md`).
- **Source**: handcrafted, referencing source `infrastructure/database/cloudnative-pg/immich/` (Cluster shape) and `infrastructure/database/cnpg-barman-plugin/` (plugin install) for patterns. Adds the in-cluster MinIO that the source homelab doesn't need (it has RustFS S3 already on TrueNAS).
- **Effort delta from original spec**: ~3 extra manifests, ~30min more work. Worth it for "advanced" starter framing.

---

## 4. Adaptation placeholders

Every placeholder lives in code/manifests; `scripts/adapt-to-your-cluster.sh` finds and substitutes them.

| Placeholder | Represents | Example value | Where it appears |
|---|---|---|---|
| `__REPLACE_ME_DOMAIN__` | DNS suffix for in-cluster apps | `homelab.example.com` | gateway hostname, HTTPRoute hostnames, omni.env, README examples |
| `__REPLACE_ME_GIT_REPO_URL__` | The user's fork URL | `https://github.com/you/talos-argocd-proxmox-advanced-starter.git` | every Application manifest's `spec.source.repoURL`, every AppSet's `spec.generators.git.repoURL`, AppProject `sourceRepos` |
| `__REPLACE_ME_GIT_BRANCH__` | The branch ArgoCD tracks | `main` | every Application/AppSet `targetRevision` (defaults to `main`; user can swap to `develop` etc.) |
| `__REPLACE_ME_CLUSTER_NAME__` | Cilium cluster name (must match `cilium install`) | `homelab` | `infrastructure/networking/cilium/values.yaml`, `scripts/bootstrap-argocd.sh` (in the example `cilium install` command) |
| `__REPLACE_ME_NODE_CIDR__` | Node IP CIDR | `192.168.1.0/24` | `omni/cluster-template/cluster-template.yaml` (longhorn-storage `validSubnets`), Cilium policy if present |
| `__REPLACE_ME_GATEWAY_IP__` | LoadBalancer IP for the internal Gateway | `192.168.1.50` | `infrastructure/networking/gateway/gw-internal.yaml` (`spec.addresses[0].value`) |
| `__REPLACE_ME_PROXMOX_HOST__` | Proxmox API endpoint | `https://192.168.1.10:8006/api2/json` | `omni/proxmox-provider/config.yaml.example` |
| `__REPLACE_ME_PROXMOX_TOKEN__` | Proxmox API token id+secret | `root@pam!iac=abc-...` | `omni/proxmox-provider/.env.example` |
| `__REPLACE_ME_PROXMOX_STORAGE_POOL__` | Proxmox storage selector for VMs | `local-zfs` | `omni/machine-classes/control-plane.yaml`, `omni/machine-classes/worker.yaml` (storage_selector CEL) |
| `__REPLACE_ME_NFS_SERVER__` | NFS server IP for VolSync repository | `192.168.1.100` | `infrastructure/controllers/pvc-plumber/deployment.yaml` (NFS volume + NFS_SERVER env), `infrastructure/storage/volsync/values.yaml` |
| `__REPLACE_ME_NFS_PATH__` | NFS export path | `/mnt/tank/k8s/volsync-kopia` | same files as above |
| `__REPLACE_ME_OMNI_ENDPOINT__` | URL of self-hosted Omni instance | `https://omni.homelab.example.com:443` | `omni/omni/omni.env.example`, `scripts/bootstrap-argocd.sh` example commands |
| `__REPLACE_ME_OMNI_HOST_IP__` | LAN IP of the host running Omni's docker-compose (used as the SideroLink WireGuard advertised address — must be an IP, not a hostname, for the WireGuard handshake) | `192.168.1.20` | `omni/omni/omni.env.example` (added during Phase 2a) |

**13 placeholders total.** The README's "edits ~10 placeholders" claim is now closer to "~13 placeholders, 5 of which the adapt script can plausibly autodetect (cluster name, branch, gateway IP from a `hostname -I` heuristic, etc.) leaving ~8 the user actually has to think about."

The adapt script will also offer to **generate** rather than substitute the Kopia password (a SealedSecret containing 32 random bytes); it does NOT use a placeholder for that — it generates, seals, and writes the YAML directly into `infrastructure/controllers/pvc-plumber/sealed-kopia-password.yaml`.

---

## 5. Sync wave assignments

The starter compresses to 6 waves (W0–W6). Cert-manager CRDs install at W0 (via the chart's `--include-crds`), the cert-manager controller installs at W4 — matching the source cluster. Pvc-plumber's webhook TLS uses a namespace-scoped `selfSigned` Issuer that resolves once the controller is up.

| Wave | Component | Notes |
|---|---|---|
| **0** | AppProjects (`projects.yaml`) | Foundational ArgoCD config |
| **0** | `bootstrap/argocd.yaml` (self-managed argo-cd Helm app) | The chicken-and-egg: argo-cd manages itself from W0 |
| **0** | `bootstrap/cilium-app.yaml` | CNI + Gateway API gatewayClass |
| **0** | `bootstrap/sealed-secrets-app.yaml` | Source-of-truth secret backend (committed SealedSecrets unwrap into regular Secrets) |
| **0** | `bootstrap/external-secrets-app.yaml` | ESO controller + `1password` ClusterSecretStore (kubernetes provider). Bridge from the master kopia Secret in volsync-system to per-app-namespace Secrets templated from operator-created ExternalSecrets. |
| **1** | `core-dependencies/longhorn-app.yaml` | Storage |
| **1** | `core-dependencies/snapshot-controller-app.yaml` | Required for Longhorn `VolumeSnapshotClass` |
| **1** | `core-dependencies/volsync-app.yaml` | Backup engine |
| **1** | `core-dependencies/pvc-plumber-app.yaml` | Operator deployment + selfSigned Issuer + Certificate (controller-runtime starts here, but webhooks are NOT yet registered) |
| **2** | `pvc-plumber/webhooks.yaml` (Mutating + Validating WebhookConfigurations) | Registered after the operator pod is healthy. **CRITICAL**: if registered at W1 alongside the deployment, a slow first-boot can deadlock everything because the webhook fails closed before the pod is ready. The source cluster solved this by putting the webhook configs at W2 — preserving. |
| **3** | `core-dependencies/cnpg-barman-plugin-app.yaml` | CNPG-Barman ObjectStore plugin. Standalone Application (not via AppSet) so it's guaranteed installed before W4 discovers the CNPG operator and W6 deploys postgres-demo's Cluster CR (which references the plugin). Per conductor revision 2026-05-07 — original plan reserved this wave empty under the "no Barman in default starter" assumption; reversed because postgres-demo now ships with backup/restore as a first-class platform demo. |
| **4** | `appsets/infrastructure-appset.yaml` | Discovers `cert-manager`, `csi-driver-nfs`, `gateway` |
| **4** | `appsets/database-appset.yaml` | Discovers `cnpg-operator/*` |
| **5** | `appsets/monitoring-appset.yaml` | Discovers `kube-prometheus-stack`, `loki-stack` |
| **6** | `appsets/apps-appset.yaml` | Discovers `apps/*` (3 demos) |

If a user adds an app to `apps/` and labels its PVC `backup: hourly`, the W6 admission flow goes through the W2-registered webhook → which calls the W1-running plumber pod → which checks the W0-installed kopia repository. All boxes fit.

---

## 6. Estimated agent help

I can do most of this myself. Here's what I'd most value a helper agent for:

| Sub-area | My recommendation | Estimated effort |
|---|---|---|
| **Phase 2a — `omni/` port** | I do it myself; mostly file copies + placeholder swaps. | ~1h |
| **Phase 2b — argocd root + AppSets + projects** | I do it myself; this is the architectural seam and benefits from one author. | ~2h |
| **Phase 2c — pvc-plumber operator manifests** | I do it myself; touch-and-go but I know the exact source. | ~1h |
| **Phase 2d — networking (Cilium + Gateway)** | I do it myself. | ~1h |
| **Phase 2e — storage (Longhorn + VolSync + snapshot-controller + csi-driver-nfs)** | **Helper agent**: a tempo-soloist can take this in parallel with my work on monitoring; the patterns are mechanical (port values.yaml, strip 1Password ESO refs, swap to SealedSecret). | ~1h, parallel-friendly |
| **Phase 2f — cert-manager + sealed-secrets** | I do it myself (small). | ~30m |
| **Phase 2g — monitoring (kube-prometheus-stack + loki-stack)** | **Helper agent**: a tempo-soloist can take this in parallel — Helm values cleanup is mechanical and easy to review. | ~1h, parallel-friendly |
| **Phase 2h — CNPG operator + postgres-demo** | I do it myself; the CNPG `Cluster` resource needs care. | ~1h |
| **Phase 2i — apps/nginx-demo + apps/stateful-demo** | I do it myself; small, handcrafted. | ~30m |
| **Phase 2j — scripts/ (bootstrap, adapt, seal, validate)** | I do it myself; the adapt script is the contract for placeholders. | ~1h |
| **Phase 3 — docs** | **tempo-liner if available** for the architecture.md and pvc-backup-restore.md long-form docs (they're heavy prose with diagrams); I'll do the smaller cookbook docs and adapt the source's existing diagrams. | ~2h, parallel-friendly |
| **Phase 4 — verify the bootstrap path on a clean Talos cluster** | **tempo-tuner**: end-to-end smoke test once the manifests land. The user has a real Proxmox host to test on (per kickoff). | ~2h |

**Suggested parallelization**: after Phase 2a–2c land, fork off helpers for 2e (storage) + 2g (monitoring) + 3 (docs) while I drive 2d / 2f / 2h / 2i / 2j. That keeps the architectural pieces under one author and parallelizes the mechanical ones.

---

## 7. Design decisions and remaining questions

### Greenlit by conductor (2026-05-07)

1. ✅ **Default secret backend = sealed-secrets only** (not ESO+sealed-secrets co-deployed). Rationale: ESO adds a controller and a ClusterSecretStore CRD just to bootstrap a single Kopia password. Sealed-secrets alone is sufficient. ESO is documented as an extension recipe (Phase-1 ships a one-paragraph stub at `docs/extending/swapping-secret-backend.md`; the full backend-swap walkthrough — Vault / 1Password / AWS Secrets Manager / GCP Secret Manager — is post-launch work).

### Still open — need conductor sign-off

2. **`postgres-demo` defaults to `initdb`-only (no Barman/MinIO)**. Confirm? Rationale: pvc-plumber demo already shows PVC-level DR. Barman+MinIO+CNPG-plugin is its own teaching unit and triples the moving pieces in the demo. A `--enable-backups` flag in the adapt script could optionally wire it in (but I'd rather call it a recipe).

3. **External Gateway not shipped by default; only internal Gateway**. Confirm? Rationale: external Gateway requires a real public IP, a domain, and a way to terminate TLS publicly (Cloudflare tunnel or LE+DNS-01). All three are user-specific. The internal Gateway demonstrates the Gateway API pattern fully; the external add-on is documented as a recipe.

4. **CNPG operator goes into `infrastructure/database/cnpg-operator/` and is discovered by the database AppSet at W4** — but in the starter it's the *only* thing the database AppSet discovers. Should I keep the database AppSet at all (overhead for one app), or just hoist CNPG into the infrastructure AppSet? **Recommendation**: keep the database AppSet — it costs nothing and demonstrates the `selfHeal: false` DR pattern that's the main point of the source's separation. Confirm.

5. **Repo push timing**: kickoff says "use `gh repo create mitchross/talos-argocd-proxmox-advanced-starter --public --source=. --remote=origin` once you have content worth pushing — coordinate with the conductor before that step." My read: I'll commit to local `main` per chunk, **NOT** push until the conductor signals the repo is ready to be public. Confirm.

---

## 8. What this plan does NOT cover yet

- **Renovate / Dependabot config**. The source cluster has Renovate; the starter probably should too, but pinning major versions for charts (kube-prometheus-stack, longhorn, cilium) per the CLAUDE.md rule. I'll add a `renovate.json` in Phase 2j alongside scripts, with major-pin rules. Flagging now so it doesn't surprise on review.
- **Tests**. The source cluster has `scripts/validate-*.sh` which I'm porting; no unit tests because there's no code to unit-test. The validate scripts are the test layer.
- **CI / GitHub Actions**. Out of scope for Phase 1; defer to Phase 4 alongside the tuner's e2e smoke. The bare minimum would be a `kubectl apply --dry-run=server` job against a kind cluster in CI, which is genuinely useful and not too heavy.

---

## Sign-off requested

Conductor — answers to the four open design questions in §7 plus a thumbs-up on the directory tree (§1) and porting matrix (§2) is enough to greenlight Phase 2.

If you want me to revise anything in §3 (demo apps), §4 (placeholders), or §5 (sync waves) before I start writing manifests, now is the time.
