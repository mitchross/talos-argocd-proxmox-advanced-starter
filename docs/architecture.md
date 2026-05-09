# Architecture

> Status: stub — coming soon.

TODO: walk the GitOps self-management pattern (root Application → AppSets
→ auto-discovery), the seven sync waves with the FAIL-CLOSED admission
flow at wave 2, and the directory-equals-Application convention. The
README's "Architecture in 60 seconds" section is the conversational
intro; this doc is the reference deep-dive.

For now, the closest live references are:

- [`docs/pvc-plumber-explained.md`](pvc-plumber-explained.md) — covers
  the wave 1 → wave 2 admission gate in detail.
- [`docs/cnpg-explained.md`](cnpg-explained.md) — covers the database
  AppSet's `selfHeal: false` carve-out and the GitOps DR flow.
- [`infrastructure/controllers/argocd/apps/`](../infrastructure/controllers/argocd/apps/) —
  the source of truth: every AppSet + bootstrap Application file is
  commented with its sync-wave rationale.
