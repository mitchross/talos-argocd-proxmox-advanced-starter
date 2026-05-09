# talos-argocd-proxmox-advanced-starter

A production-shaped GitOps Kubernetes starter kit for Proxmox homelabs.
Take this, point it at your cluster, and you have a self-managing
ArgoCD + storage + monitoring + a few demo apps running in under an hour.

> **Status**: ready for review and demo. Phase 2 port is complete —
> pvc-plumber v3.1.0, S3 backup backend, CNPG with Barman plugin,
> Renovate + CI, and the homelabber explainer docs all in tree. See
> [`docs/porting-plan.md`](docs/porting-plan.md) for the full porting
> matrix.

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

## Architecture in 60 seconds

The killer feature is `backup: hourly` on a PVC label, which gets you
restore-on-create automatically the next time that PVC is recreated.
Four pieces wired together by a small operator:

```
┌──────────────────────┐     ┌──────────────────────┐
│  YOUR PVC            │────▶│  pvc-plumber webhook │ ── inject dataSourceRef
│  labels:             │     │  (mutate-pvc)        │    if kopia has data
│    backup: hourly    │     └──────────────────────┘
└──────────────────────┘                │
                                        ▼
                            ┌──────────────────────┐
                            │  pvc-plumber         │ ── creates ES + RS + RD
                            │  reconciler          │    per backup-labeled PVC
                            └──────────────────────┘
                                        │
                                        ▼
                            ┌──────────────────────┐
                            │  VolSync mover Job   │ ── on schedule, snapshots
                            │  + kopia binary      │    PVC, encrypts, ships
                            └──────────────────────┘    to your S3
                                        │
                                        ▼
                            ┌──────────────────────┐
                            │  Your S3 bucket      │ ── content-addressed,
                            │  (MinIO/Rust/AWS/B2) │    deduplicated, encrypted
                            └──────────────────────┘
```

You delete the PVC. You re-apply the manifest. Data restores
automatically — the mutating webhook detects the existing kopia
snapshot and tells Kubernetes to populate the volume from it before
any pod can mount it. No manual restore step. No "oh wait I forgot to
restore the database" the morning after a cluster rebuild.

The condensed deep-dive lives in [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md).

---

## Quick start

> **Prerequisites**: Proxmox VE host with ≥64GB RAM, ≥600GB storage,
> network access to GitHub. To upgrade to a 3 CP + N worker HA cluster
> after the starter is up, see
> [`docs/extending/scaling-to-ha.md`](docs/extending/scaling-to-ha.md).

```bash
# 1. Clone the starter (your fork, not the upstream — you'll commit
#    placeholder substitutions in step 3).
git clone https://github.com/<you>/talos-argocd-proxmox-advanced-starter
cd talos-argocd-proxmox-advanced-starter

# 2. Adapt to your environment (edits ~10 placeholders: NFS server,
#    domain, S3 endpoint, git repo URL, etc.).
./scripts/adapt-to-your-cluster.sh

# 3. Commit the substitutions to your fork.
git add . && git commit -m "config: adapt to my cluster" && git push

# 4. Provision Talos cluster via Sidero Omni.
cd omni && ./bootstrap.sh

# 5. Bootstrap ArgoCD (one-time manual apply).
./scripts/bootstrap-argocd.sh

# 6. Watch ArgoCD discover and deploy everything in sync-wave order.
kubectl get applications -n argocd -w
```

When wave 6 turns Healthy, you're done. The demo apps under `apps/`
should be Running, the monitoring stack reachable, and a stateful-demo
PVC has its first kopia snapshot in your S3 bucket within ~5 minutes.

Detailed walkthrough: [`docs/getting-started.md`](docs/getting-started.md).

---

## What this teaches

Each pattern below maps to a section in the explainer docs. Read the
linked section to understand the **why**, not just the what.

- **GitOps self-management** — ArgoCD manages its own configuration
  via a Root Application + ApplicationSets. Add a directory =
  ArgoCD discovers it. See [`docs/architecture.md`](docs/architecture.md).
- **Sync waves** — strict deployment order to prevent cold-boot races.
  Wave 0 → Cilium + secrets backend, Wave 1 → storage + pvc-plumber, …,
  Wave 6 → your apps. See [`docs/architecture.md`](docs/architecture.md).
- **Label-as-intent backups** — one label on a PVC, all backup
  machinery follows. See [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md)
  "TL;DR" + "What happens when a PVC is created."
- **Restore-on-create** — delete the PVC, re-apply the manifest, data
  shows up. The mutating webhook detects existing kopia snapshots and
  injects `dataSourceRef`. See
  [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md)
  "The killer feature: re-create after delete."
- **CNPG + Barman PITR** — Postgres clusters with continuous WAL
  archiving + base backups to S3, point-in-time recovery to any
  moment in your retention window. See
  [`docs/cnpg-explained.md`](docs/cnpg-explained.md) "TL;DR" + "How
  a normal day looks."
- **GitOps disaster recovery** — flip a feature-flag line in
  `kustomization.yaml`, commit, run two `kubectl delete`s, and CNPG
  recovers from S3 into a fresh lineage. See
  [`docs/cnpg-explained.md`](docs/cnpg-explained.md) "What's a Git
  change vs kubectl vs feature flag."
- **Webhook deadlock prevention** — admission webhooks with
  `failurePolicy: Fail` are dangerous; the namespaceSelector exclusion
  list keeps the bootstrap from deadlocking itself. See
  [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md)
  "Why the bootstrap doesn't deadlock itself."
- **Renovate + audit-trail discipline** — auto-merge minor/patch via
  PR (not branch — different audit-trail outcome) with sensible
  rate-limit handling for Docker Hub free tier. See
  [`docs/dockerhub-rate-limit-mitigation.md`](docs/dockerhub-rate-limit-mitigation.md).

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

- **Talos OS provisioning** via Sidero Omni on Proxmox
- **ArgoCD** (self-managing, with AppSets + ApplicationSet for app discovery)
- **Cilium** (CNI + Gateway API)
- **cert-manager** (TLS for webhook + Gateway certs)
- **Longhorn** (distributed block storage with VolumeSnapshots)
- **VolSync + Kopia** (PVC backup/restore on S3)
- **pvc-plumber operator v3.1.0** (the magic-label backup automation)
- **External Secrets Operator** with **sealed-secrets** as the default backend
- **CloudNativePG** with Barman Cloud Plugin and an in-cluster MinIO
- **Prometheus + Grafana + Loki** (monitoring + logs)
- **Demo apps**: stateless (HTTPRoute), stateful (PVC + backup label),
  CNPG database (Barman backup)
- **Renovate config** + **CI workflow** out of the box

---

<details>
<summary><b>Recording suggestions for YouTube</b></summary>

Talk-points for each major demo. Approximate runtimes per segment in
parentheses; use them as planning anchors, not strict gates.

### The pvc-plumber restore-on-create demo (15-20 min)

Best opening because it's visually concrete and demonstrates the killer
feature in under 5 minutes of actual cluster time.

1. **Show the manifest.** Open `apps/stateful-demo/pvc.yaml`, point at
   the `backup: hourly` label, say "this is the entire interface."
2. **Apply it.** `kubectl apply -f apps/stateful-demo/`. Show the
   pod creating, mounting, the heartbeat.log starting to grow.
3. **Wait one backup cycle.** Don't actually wait on camera — cut to
   "an hour later." Show `kubectl get rs -A` with one Running.
4. **The reveal.** `kubectl delete pvc stateful-demo-data`. Watch the
   pod terminate. `kubectl apply -f apps/stateful-demo/pvc.yaml` again.
   Show the new pod come up — `kubectl exec` and `cat /data/heartbeat.log`
   shows the OLD log lines still there. The data restored on its own.
5. **The architecture.** Pull up
   [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md),
   walk the four-piece ASCII diagram. Talk about the mutating webhook,
   the kopia repo, VolSync's populator. ~5 min on the architecture.
6. **The sharp edges.** "What if pvc-plumber is down?" → fail closed,
   ArgoCD retries, no silent data loss. "What about CNPG PVCs?" →
   different system, point at `docs/cnpg-explained.md`.

### The CNPG GitOps DR drill (20-30 min)

Slow, methodical, the talk-point payoff is "you can rehearse this
before you need it." Best as a follow-up video, not the opener.

1. **Set the scene.** Show the `apps/postgres-demo/` directory layout,
   point at the kustomization.yaml feature flag (`overlays/initdb` vs
   `overlays/recovery`). 2 min.
2. **Show steady-state.** A row in the Postgres demo, count rows,
   confirm Barman is archiving WAL (`kubectl logs barman-cloud-sidecar`).
   3 min.
3. **The flip.** Live-edit the three files
   ([`docs/cnpg-explained.md`](docs/cnpg-explained.md) "Why 'lineage'"
   table is the cheat-sheet), commit, push.
4. **The forced re-evaluation.** Hard-refresh ArgoCD, delete the
   Cluster, delete the PVCs, watch CNPG re-create. Talk through each
   `kubectl` command and why CNPG can't just `kubectl apply` the patch
   onto the running Cluster.
5. **The recovery.** Watch `kubectl get pods -n postgres-demo` cycle
   through `Init:0/2` → `Running` with the recovery container. Tail the
   logs to show `restored log file ...`.
6. **The verification.** Re-count rows in Postgres, match pre-flight.
   Restart consumer apps, confirm they reconnect.

### The webhook-deadlock-prevention talk (10-15 min, theory-only)

This is the "advanced" segment for viewers who got through the first
two videos. No live cluster work; just a whiteboard or screen-share of
the explainer docs.

1. **Set the riddle.** "Webhook says deny PVC creation if I'm down. But
   the operator IS a PVC. How does this not deadlock?"
2. **Walk the namespaceSelector exclusion.** Show
   [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md)
   "Why the bootstrap doesn't deadlock itself" diagram. The list has to
   stay in sync between the webhook and the deployment env var.
3. **The 2026-04-08 incident.** A Kyverno crash with the same
   `failurePolicy: Fail` + missing namespace caused a real cluster
   wedge on the source cluster. Show the corresponding `kyverno`
   marker in the starter's exclusion list — defensive forward-compat.
4. **The four-bar test.** Pull up
   [`.claude/rules/no-lua-in-argocd-cm.md`](.claude/rules/no-lua-in-argocd-cm.md)
   and walk the four-bar test for when Lua is justified. Tie it back
   to the ESO race fix being operator-side, not Lua-side.

### The Renovate + CI walkthrough (8-10 min)

Light, fast, good shorts material. No live demo; just walk the config.

1. Show `.github/renovate.json5`, point at `automergeType: 'pr'`. Tell
   the audit-trail story (the 2026-05-08 source cluster lesson).
2. Show the `prHourlyLimit: 3` + `abortIgnoreStatusCodes: [429]` +
   daily-docker-schedule package rules. Reference
   [`docs/dockerhub-rate-limit-mitigation.md`](docs/dockerhub-rate-limit-mitigation.md)
   for the math.
3. Show the no-major-auto-merge rules for kube-prometheus-stack /
   longhorn / cilium. Cite the v82→v83 outage as the reason.
4. Show the CI workflow. Three jobs: structure validation (the
   one-shot bash script), kustomize render + kubeconform, shellcheck.
   Talk about why the structure validator lives in scripts/ vs why it
   isn't a Renovate-managed thing.

</details>

---

## Documentation

- [`docs/getting-started.md`](docs/getting-started.md) — cold-cluster walkthrough
- [`docs/architecture.md`](docs/architecture.md) — sync waves, ApplicationSet discovery, GitOps self-management
- [`docs/pvc-plumber-explained.md`](docs/pvc-plumber-explained.md) — homelabber's deep-dive on the `backup: hourly` system
- [`docs/cnpg-explained.md`](docs/cnpg-explained.md) — homelabber's deep-dive on CNPG + Barman + GitOps DR
- [`docs/dockerhub-rate-limit-mitigation.md`](docs/dockerhub-rate-limit-mitigation.md) — Renovate + Docker Hub free-tier
- [`docs/secret-management.md`](docs/secret-management.md) — sealed-secrets default, swapping to other backends
- [`docs/adapting-to-your-cluster.md`](docs/adapting-to-your-cluster.md) — what to edit before you boot
- [`docs/extending.md`](docs/extending.md) — adding GPU support, swapping DNS providers, adding apps

---

## License

MIT. Use, fork, modify, redistribute. Inspired by the homelab clusters of
[mitchross/talos-argocd-proxmox](https://github.com/mitchross/talos-argocd-proxmox)
and [mitchross/talos-argocd-proxmox-starter](https://github.com/mitchross/talos-argocd-proxmox-starter).
