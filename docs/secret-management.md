# Secret management

> Status: stub — coming soon.

TODO: explain the sealed-secrets default and how to swap to ESO +
1Password Connect / HashiCorp Vault / AWS Secrets Manager / GCP Secret
Manager / Azure Key Vault / Doppler / Infisical / Akeyless. The swap is
genuinely small — change the `cluster-secret-store.yaml` provider
stanza, rotate the source-of-truth Secret to your backend, delete the
in-tree SealedSecret. The pvc-plumber operator's hardcoded
`secretStoreRef.name=1password` and the three property keys
(`kopia_password`, `k8s-admin-access-key`, `k8s-admin-secret-key`)
stay stable across all backends.

For now:

- [`infrastructure/controllers/external-secrets/cluster-secret-store.yaml`](../infrastructure/controllers/external-secrets/cluster-secret-store.yaml)
  — the swap point; header comment explains the contract.
- [`infrastructure/controllers/pvc-plumber/sealed-kopia-password.yaml`](../infrastructure/controllers/pvc-plumber/sealed-kopia-password.yaml)
  — the source-of-truth Secret; replaced via `scripts/seal-secret.sh
  --kopia-password`.
- [`scripts/seal-secret.sh`](../scripts/seal-secret.sh) — the
  one-shot sealer. Header comment covers the sealed-secrets vs
  ESO+external-store decision.
