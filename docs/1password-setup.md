# 1Password Connect + External Secrets (the one-time account setup)

Every secret in this kit comes from 1Password through External Secrets
Operator. The manifests for both already ship in-tree and sync at **Wave 0** —
what this guide covers is the part that happens *outside* the cluster, on your
1Password account, before Argo CD can do anything useful.

Where this sits in the run book:

| Step | Guide |
|---|---|
| §5.2 "create the documented 1Password items" | **this guide**, then [secret-management.md](secret-management.md) for the item/field table |
| §7 "pre-seed the bootstrap secrets" | [getting-started.md](getting-started.md#7-pre-seed-the-1password-bootstrap-secrets) |

If you already run a Connect server and have `1password-credentials.json` plus
an operator token, skip straight to §7 — nothing here will be new.

## What you are building

```
1Password.com (your vault)
        │  credentials.json + access token   ← created once, by hand
        ▼
1Password Connect  (in-cluster, namespace 1passwordconnect)
        │  http://onepassword-connect...:8080
        ▼
ClusterSecretStore/1password  →  ExternalSecret  →  Kubernetes Secret  →  pod
```

Connect is a **self-hosted API** that holds a read-only replica of the vaults
you scope to it. Nothing in the cluster ever talks to 1Password.com directly,
and the token you mint can only see the vaults you name.

**Plan requirement:** Connect is part of 1Password's Secrets Automation
feature, which is on the paid business tiers rather than personal plans.
Confirm your account has "Secrets Automation" (or "Developer → Connect") in
the sidebar before going further — the rest of this guide assumes it.

## 1. Create the vault

Make one vault to hold everything this kit reads. The tree ships with
`homelab-prod` as the example name.

Whatever you name it, `scripts/adapt-to-your-cluster.sh` rewrites
`homelab-prod` across the tree — so either name your vault `homelab-prod` and
change nothing, or name it something else and let the adapt script do the
swap ([adapting-to-your-cluster.md](adapting-to-your-cluster.md)).

## 2. Create the Connect server and its two credentials

This produces the two artifacts the cluster cannot bootstrap without: a
**credentials file** (identifies the Connect server) and an **access token**
(authorizes a client to call it).

The `op` CLI is the reproducible path
([install](https://developer.1password.com/docs/cli/get-started/)):

```bash
op signin

# Creates ./1password-credentials.json and registers the server.
op connect server create homelab-connect --vaults homelab-prod

# The token ESO (and the 1Password operator) will present to Connect.
op connect token create homelab-eso \
  --server homelab-connect \
  --vaults homelab-prod
```

`server create` writes `1password-credentials.json` into the working
directory. `token create` prints the token **once** — it is not retrievable
afterward.

> The browser path is equivalent: **Developer → Connect / Secrets Automation →
> New Server**, scope it to the vault, download the credentials file, then
> issue a token. Use whichever you prefer; the two artifacts are the same.

**Both artifacts are cluster credentials — do not commit either.** The repo's
`.gitignore` already excludes runtime credential files, but
`1password-credentials.json` landing in your clone root is a real way to leak
one. Move it out of the repo, or delete it once §7 has consumed it.

## 3. Store them back in 1Password

Chicken-and-egg, resolved once: the two bootstrap artifacts live in the vault
*and* get hand-copied into Kubernetes a single time. Create these items in the
vault from step 1:

| Item | Field | Value |
|---|---|---|
| `1passwordconnect` | `1password-credentials.json` | contents of the file from step 2 |
| `1password-operator-token` | `credential` | the token string from step 2 |

These two rows are the reason §7 exists. Every *other* item in
[secret-management.md](secret-management.md) is fetched automatically by ESO
once the chain is live — only these two are ever handled by hand.

## 4. Create the remaining vault items

[secret-management.md](secret-management.md#vault-items-the-kit-expects) is the
canonical list — create the items and exact field names shown there. You do not
need all of them to bootstrap; you need them before the app that consumes each
one reaches its sync wave.

To confirm the list matches the tree you actually have:

```bash
rg -n -A2 "remoteRef:" infrastructure monitoring my-apps
```

## 5. Seed the cluster and hand off

Continue at
[getting-started.md §7](getting-started.md#7-pre-seed-the-1password-bootstrap-secrets),
which creates the three bootstrap Secrets from the two items above, then
§8 runs `bootstrap-argocd.sh`. Wave 0 brings up Connect and ESO from the
manifests already in the repo:

| Path | What syncs |
|---|---|
| `infrastructure/controllers/1passwordconnect/` | Connect API + sync + the 1Password operator |
| `infrastructure/controllers/external-secrets/` | ESO chart, `ClusterSecretStore/1password`, token self-rotation |

## 6. Verify the chain

Run these after Wave 0 reports Synced. Each one fails distinctly, so work down
the list and stop at the first failure:

```bash
# 1. Connect is running and serving.
kubectl -n 1passwordconnect get pods
kubectl -n 1passwordconnect logs deploy/onepassword-connect -c connect-api --tail=20

# 2. ESO is running.
kubectl -n external-secrets get pods

# 3. The store reached the vault. This is the real integration test.
kubectl get clustersecretstore 1password \
  -o jsonpath='{.status.conditions[*].reason}{"\n"}'
# want: Valid

# 4. A secret actually materialized.
kubectl -n external-secrets get externalsecret external-secrets
# want: STATUS=SecretSynced, READY=True
```

A `Valid` ClusterSecretStore means Connect answered, the token was accepted,
and the named vault was visible — the three things that break independently.

## Failure modes

| Symptom | Cause |
|---|---|
| `ClusterSecretStore` reason `InvalidProviderConfig`, connection refused | `connectHost` wrong. The chart names the Service **`onepassword-connect`** even though the Helm release is `1password-connect` — the store's `connectHost` must use the former. This trips almost everyone; the value in-tree is already correct, so suspect edits. |
| Store `Valid` but an ExternalSecret is `SecretSyncedError` | The vault item or field name doesn't match `remoteRef`. Field names are case- and space-sensitive; `rg -A2 remoteRef` shows exactly what's expected. |
| Connect pod `CrashLoopBackOff`, credentials error | `1password-credentials` Secret missing, or the JSON was mangled in transit (a shell that stripped newlines). Recreate it with the §7 `op read` command rather than pasting. |
| Token rejected after it previously worked | Tokens are vault-scoped. Adding a new vault means minting a new token — an existing one will not see it. |
| Everything `Valid`, one namespace has no secret | ESO only writes where an `ExternalSecret` exists. For backup credentials the fan-out is label-driven — see the `ClusterExternalSecret` note in [secret-management.md](secret-management.md#the-kopiur-credential-fan-out-the-pattern-worth-stealing). |

## A note on the 1Password operator

The Connect chart deploys the **1Password Kubernetes operator** alongside the
Connect API (`operator.create: true` in
[`values.yaml`](../infrastructure/controllers/1passwordconnect/values.yaml)),
which is what the `1password-operator-token` Secret feeds.

That operator offers a second, independent way to pull secrets: a
`OnePasswordItem` custom resource. **This kit does not use it** — every secret
in the tree goes through ESO, because ESO is backend-agnostic (swap the
`ClusterSecretStore` provider and no consuming manifest changes).

It is left enabled so the `OnePasswordItem` path is available if you want it.
If you would rather run one mechanism instead of two, set `operator.create:
false` and drop the `1password-operator-token` Secret from §7 — ESO is
unaffected. Nothing in-tree breaks either way.
