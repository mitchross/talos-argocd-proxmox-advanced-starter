# Rule: Always pin image SHA digests

Every image reference in this repo MUST include `@sha256:<digest>` after
the tag. No floating `:latest`, no bare `:1.27`, no chart-defaulted
tag-only references that flow through Helm. Renovate handles the
ongoing bumps; humans do not.

## Why

A floating `:latest` (or any tag without a digest) means:

- The image content can change underneath you between deploys without
  any change in the manifest. ArgoCD will not detect the drift because
  it diffs YAML, not image content.
- Identical YAML on two clusters can produce different running
  containers, breaking "GitOps as the source of truth" silently.
- The 2026-05-08 incident on the source cluster: a floating image tag
  caused a long debug session because the manifest looked identical to
  the version that worked yesterday — the image content had changed,
  upstream had pushed a regression, and there was no audit trail
  surfacing this in `git log` or `kubectl describe`.

A `@sha256:<digest>` pin means:

- The image content is content-addressed and immutable.
- Any change to the running container is preceded by a corresponding
  change in `git log` (Renovate PR bumping both tag and digest in
  lockstep).
- Cluster reproducibility is enforceable: same commit hash → identical
  running containers across all clusters.
- A registry that gets popped or re-tagged silently can't change the
  content under a digest pin (the kubelet would refuse to pull, ArgoCD
  would surface ImagePullBackOff, you'd notice).

## How to find a digest

For most public registries, `crane` is the cleanest tool:

```bash
crane digest nginx:1.31-alpine
# → sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752
```

For GHCR specifically, you can also query the GitHub API:

```bash
gh api -H "Accept: application/vnd.github+json" \
  /users/<org>/packages/container/<image>/versions \
  | jq '.[] | select(.metadata.container.tags // [] | index("<tag>")) | .name'
```

For Docker Hub:

```bash
crane digest nginxinc/nginx-unprivileged:1.27-alpine
```

If `crane` isn't available, `skopeo inspect docker://<image>:<tag> | jq -r '.Digest'` works.

If neither tool is available and you can't install one, leave a
`# TODO: pin SHA digest` comment above the image line and surface it in
your final report so an operator with registry access can complete it.
**Do not** skip pinning silently — every gap is a future incident.

## What it looks like in practice

```yaml
# Bad (floating tag, no digest)
image: nginx:1.31-alpine

# Good (tag + digest)
image: nginx:1.31-alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752
```

Helm-rendered images are pinned via the `images:` field in
`kustomization.yaml`:

```yaml
images:
  - name: docker.io/library/postgres
    newTag: "17.6"
    digest: sha256:abcdef...
```

If a Helm chart hardcodes an image tag without exposing it as a value,
the digest pin lives in a Kustomize `images:` override or a strategic-
merge patch — not in a chart fork. (Forking charts to pin one digest is
a maintenance burden that compounds; Kustomize override stays clean.)

## Renovate handles the bumps

The `.github/renovate.json5` config enables digest updates explicitly:

```json5
{
  description: 'Enable container digest updates — paired with always-pin-sha rule.',
  matchDatasources: ['docker'],
  matchUpdateTypes: ['digest'],
  enabled: true,
}
```

When upstream re-tags an image (rare but happens), Renovate opens a PR
bumping just the digest. When upstream cuts a new tag, Renovate opens a
PR bumping both tag and digest in one diff.

Humans only need to look at the digest hash to verify Renovate is
tracking the right image — the rule of thumb is "the PR title names the
expected release; the digest changed; test the rendered workload."

## Don't

- Don't ship a manifest that has `:latest` (or any tag without a digest).
- Don't add a digest pin manually for "long-term" stability — Renovate
  is the maintainer of digest pins. If you find yourself updating
  digests by hand, something is wrong with your Renovate config.
- Don't strip a digest because "Renovate kept bumping it noisily."
  That's the system working — every digest bump is audit-trail-visible
  evidence that an image changed. Lower `prHourlyLimit` if the noise
  is excessive, don't break the rule.

## Related

- `.github/renovate.json5` — Renovate config
- `docs/dockerhub-rate-limit-mitigation.md` — keeping digest checks
  under Docker Hub free-tier rate limits
- `.claude/rules/no-lua-in-argocd-cm.md` — companion rule on resisting
  "I'll just add a quick Lua patch" reflexes
