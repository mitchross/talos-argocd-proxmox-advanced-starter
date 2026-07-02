# Secret management (1Password Connect + External Secrets)

One flow for every secret in the kit:

```
1Password vault → 1Password Connect (in-cluster API) → ClusterSecretStore
  → ExternalSecret / ClusterExternalSecret → Kubernetes Secret → pod
```

Nothing secret is ever committed to Git — manifests reference vault items by
name. Swapping ESO's backend (Vault, AWS SM, Doppler, …) means changing the
`ClusterSecretStore` provider stanza in
[`infrastructure/controllers/external-secrets/cluster-secret-store.yaml`](../infrastructure/controllers/external-secrets/cluster-secret-store.yaml)
and recreating the same item *fields* in your backend — every consuming
manifest stays untouched.

## The two bootstrap secrets (manual, once)

ESO can't fetch credentials for the thing that serves credentials. Before
`bootstrap-argocd.sh` you pre-seed (commands in
[getting-started.md](getting-started.md) §3):

| Secret | Namespace | From 1Password item |
|---|---|---|
| `1password-credentials` | `1passwordconnect` | `1passwordconnect` → `1password-credentials.json` |
| `1password-operator-token` | `1passwordconnect` | `1password-operator-token` → `credential` |
| `1passwordconnect` | `external-secrets` | same token |

## Vault items the kit expects

Create these in one vault (referenced as `<vault>` throughout; the parent
cluster uses `homelab-prod`):

| Item | Fields | Consumed by |
|---|---|---|
| `1passwordconnect` | `1password-credentials.json` | bootstrap pre-seed |
| `1password-operator-token` | `credential` | bootstrap pre-seed |
| `rustfs` | `kopia_password`, `rustfs-workload-access-key`, `rustfs-workload-secret-key` | kopiur `ClusterExternalSecret` fan-out ([rustfs-setup.md](rustfs-setup.md)) + CNPG Barman `ObjectStore` |
| `cloudflare` | API token field(s) referenced by `infrastructure/controllers/cert-manager/` + `external-dns/` | DNS01 certs, external DNS records |
| `cloudflared` | tunnel credentials | `infrastructure/networking/cloudflared/` |
| `technitium` | API token | external-dns internal instance (`values-technitium.yaml`) |
| `gitea` | admin/app secrets referenced by `my-apps/development/gitea/externalsecret.yaml` | gitea |
| `karakeep` | app secrets referenced by `my-apps/media/karakeep/karakeep/externalsecret.yaml` | karakeep |

The authoritative field names live in each `externalsecret.yaml` — grep
`remoteRef` to enumerate exactly what your vault must contain:

```bash
grep -rn "key:\|property:" --include='externalsecret*.yaml' -A0 infrastructure my-apps | grep -A1 remoteRef
```

## The kopiur credential fan-out (the pattern worth stealing)

Backups need the same S3 credentials in *every* opted-in namespace. One
`ClusterExternalSecret` (`infrastructure/controllers/kopiur/externalsecret.yaml`)
materializes the `kopiur-rustfs` Secret into any namespace labeled
`kopiur.home-operations.com/repo: cluster-kopia` — the same label that
grants repo tenancy. Onboarding an app to backups is therefore **one label**,
never per-app credential plumbing.
