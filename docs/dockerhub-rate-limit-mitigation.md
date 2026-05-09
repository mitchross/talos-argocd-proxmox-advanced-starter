# Docker Hub rate-limit mitigation

This doc explains how Renovate is configured to stay under Docker Hub's free-tier rate limits, and how to authenticate so you get the higher (still-free) limit. Also covers why this starter uses `automergeType: 'pr'` instead of `'branch'` — a 2026-05-08 lesson from the source cluster.

Companion files:
- [`.github/renovate.json5`](../.github/renovate.json5) — the actual config
- [`.claude/rules/always-pin-sha.md`](../.claude/rules/always-pin-sha.md) — why every image ref carries `@sha256:<digest>`

---

## TL;DR

Three knobs keep this starter from hitting Docker Hub rate limits:

1. **Daily schedule** for Docker Hub lookups (not every hourly Renovate run)
2. **`abortIgnoreStatusCodes: [429]`** so a rate-limit response doesn't abort the whole Renovate run
3. **Optional Docker Hub PAT** via `hostRules` to unlock 200 pulls / 6h instead of the anonymous 100 / 6h

Plus one `automergeType` decision that's about audit trail rather than rate limits but lives here because they're the same kind of "set this once and forget" knob.

---

## Docker Hub's free-tier rate limits

| Tier | Rate limit | Identification |
|---|---|---|
| Anonymous | 100 pulls / 6h | Source IP |
| Authenticated free | 200 pulls / 6h | Docker Hub username |
| Authenticated Pro+ | unlimited | Docker Hub username |

A "pull" here is **any GET to the registry's manifest or blob endpoints**, which is what Renovate does when it fetches tag lists, image manifests, and SHA digests for digest-pinning. It's not just `docker pull`.

For a homelab cluster running ~20-30 distinct Docker Hub images:
- Renovate's default schedule (`* * * * *` plus default datasource cache) can do 30+ Docker Hub lookups in a single run
- Run that hourly and you blow through 100/6h on the second run of the hour
- Result: Renovate logs fill with `Response code 429 (Too Many Requests)`, the dependency dashboard shows `no-result` for tons of deps, you get auto-merge stalls

---

## The three knobs

### 1. Daily schedule for the docker datasource

```json5
{
  description: 'Schedule Docker Hub lookups daily to avoid rate-limit blowouts.',
  matchDatasources: ['docker'],
  matchPackagePatterns: [
    '^docker\\.io/',
    '^[a-z0-9_-]+(/[a-z0-9_-]+)?$',
  ],
  schedule: ['after 9am and before 5pm every weekday'],
}
```

This restricts ALL Docker Hub lookups to one window per weekday. Anything outside the window — including hourly default Renovate runs — skips the lookup and the dependency stays at its current pinned version.

`matchPackagePatterns` includes both the explicit `docker.io/` form and the bare-name form (e.g. `nginx`, `busybox`, `redis`) because Renovate routes bare names to Docker Hub by default. Without that second pattern, an image referenced as `nginxinc/nginx-unprivileged` would NOT match the rule and would still get hit hourly.

### 2. `abortIgnoreStatusCodes: [429]`

```json5
abortOnError: false,
abortIgnoreStatusCodes: [429],
```

Default Renovate behavior on a `429 Too Many Requests` is to abort the whole run, which means even non-Docker-Hub managers (helm-values, kubernetes, custom regex managers) stop processing. With these two settings, Renovate logs the 429 and keeps going to the next dep.

This is safe because Renovate caches lookup results — a deferred lookup just means the dep stays at its current value until the next scheduled window. It's NOT silently passing through stale-and-broken state; the dependency dashboard still shows the un-bumped state.

### 3. Optional: authenticate with Docker Hub via `hostRules`

Anonymous gets 100/6h. Authenticated (any free Docker Hub account) gets 200/6h. Free of charge, just need to create a Personal Access Token.

The renovate config ships with a commented stub:

```json5
// hostRules: [
//   {
//     hostType: 'docker',
//     matchHost: 'docker.io',
//     username: 'YOUR_DOCKERHUB_USERNAME',
//     password: '{{ secrets.DOCKERHUB_PAT }}',
//   },
// ],
```

To use it:

1. Create a Docker Hub Personal Access Token at <https://hub.docker.com/settings/security> (free Docker Hub accounts can create PATs). Read-only scope is sufficient for Renovate.
2. Store the PAT as a GitHub Actions repo secret named `DOCKERHUB_PAT`.
3. Uncomment the `hostRules` block and replace `YOUR_DOCKERHUB_USERNAME`.
4. The `{{ secrets.DOCKERHUB_PAT }}` template syntax is Renovate's convention when running under the GitHub App or via `renovate-action`. If you self-host Renovate, swap for env var injection (`RENOVATE_TOKEN`, `DOCKERHUB_PASSWORD`, etc.) per your runner's pattern.

You'll know it's working when the dependency dashboard shows fewer `no-result` rows and the Renovate logs show `host-rules: matched docker.io/...`.

---

## Why `automergeType: 'pr'` and not `'branch'`

This isn't a rate-limit knob, but it's in the same config file and worth explaining once.

Renovate has two automerge paths:

| Mode | What happens | Audit trail |
|---|---|---|
| `automergeType: 'branch'` | Renovate pushes to a branch + merges directly to main when CI green. **No PR is created.** | Just commit log |
| `automergeType: 'pr'` | Renovate opens a PR + merges when CI green | PR description + reviews + commit log |

The branch path is faster (no PR overhead) but it bypasses two things:

1. **Your PR template + checks** — branch protection rules that gate "PRs to main" don't trigger on branch automerges (they only inspect actual PRs in some configurations). The 2026-05-08 source-cluster lesson: a Renovate branch-automerged image bump landed on main without running the full PR pipeline; an incident retrospective two weeks later had to dig through individual commits to reconstruct what changed and when, because there was no PR description to read.

2. **Searchability** — `gh pr list --state merged --label renovate` is the canonical "what bumps did we take?" query. Branch automerges don't show up there.

The trade-off is: PR automerge generates a tiny amount of GitHub-UI noise (a PR opens, CI runs, PR merges, all in ~5 minutes typically). For a single homelab maintainer that noise is far outweighed by the audit-trail value.

This starter pins to `'pr'` and the renovate config heavily comments why. Don't change it without reading [`.claude/rules/no-scripts-as-design.md`](../.claude/rules/no-scripts-as-design.md) first — the same "operators should self-verify" principle applies to "the audit trail should be machine-readable in one query."

---

## Dependency dashboard convention

Renovate's `dependencyDashboard: true` setting creates a long-lived issue named `Renovate Dependency Dashboard` (configurable via `dependencyDashboardTitle`). This issue:

- Lists every detected dep at its current version
- Shows pending PRs grouped by status
- Surfaces lookup failures (`no-result`, `429`, etc.) with reasons
- Gives you check-boxes to manually trigger a one-off Renovate run for a specific dep

For a homelab cluster, this issue is the single best "what's the state of the world?" view. Pin it in your repo if you're going to interact with the dashboard regularly — `gh issue pin` works.

When something looks broken (a dep stuck at "Pending" forever, or `no-result` on a registry that should be reachable), the dashboard is where you'd start debugging before touching the renovate config.

---

## What to monitor

Things to watch in the first week after enabling Renovate on a fresh fork of this starter:

| Signal | Meaning | Action |
|---|---|---|
| Dependency Dashboard shows `no-result` rows | Renovate hit a registry it can't reach OR a 429 it didn't recover from | If 429: lower `prHourlyLimit` or add the Docker Hub PAT. If unreachable: check the registry URL in the manager config. |
| Hourly Renovate runs all skip the docker datasource | Schedule restriction is working. Expected. | None. |
| Auto-merge PRs piling up un-merged | CI failing, so automerge stalls | Look at the failing CI logs. Most often: a kubeconform false positive on a new CRD that needs adding to the schema-skip list in the workflow. |
| Major bumps showing up as auto-merged | Bug in your config | Check the `matchUpdateTypes: ['major']` rule and the per-package critical-infra rules. The starter ships these correctly; if you've edited them, audit. |

---

## Related

- [Renovate docs: rate limits](https://docs.renovatebot.com/configuration-options/#prconcurrentlimit)
- [Renovate docs: hostRules](https://docs.renovatebot.com/configuration-options/#hostrules)
- [Docker Hub rate-limit policy](https://docs.docker.com/docker-hub/usage/)
- [`.claude/rules/always-pin-sha.md`](../.claude/rules/always-pin-sha.md) — companion rule for digest-pinning every image
