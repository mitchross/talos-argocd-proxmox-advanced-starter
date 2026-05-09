# Adapting the starter to your cluster

> Status: stub — coming soon.

TODO: human-facing companion to
[`scripts/adapt-to-your-cluster.sh`](../scripts/adapt-to-your-cluster.sh).
The script is interactive and prompts for each token, but a printed
reference table is useful when you're staging values in a password
manager before running it.

For now, the script's `prompt_for()` function is the source of truth
for which placeholders exist and what their hints look like. Run with
`--dry-run` to see the full list against your current repo state:

```bash
./scripts/adapt-to-your-cluster.sh --dry-run
```

The placeholder reference table from the porting plan is the closest
thing we have to the eventual content of this doc — see
[`docs/porting-plan.md`](porting-plan.md) and search for "Placeholder
reference."

## Recipe

1. Fork the repo to your GitHub account.
2. Clone your fork locally.
3. Run `./scripts/adapt-to-your-cluster.sh` from the repo root.
4. Review the diff (`git diff`) before committing — substitution is
   global, no syntax checking, so one bad value can ripple across many
   files.
5. Commit + push.
6. Continue with [`docs/getting-started.md`](getting-started.md) at
   the "install Cilium" step.

Re-running the script is safe: tokens already substituted are
no-ops. If you need to change a value after the fact, do it manually
with `git grep <old-value> | xargs sed -i 's/<old>/<new>/g'` and
review the diff carefully — the original token is gone so the script
can't help you.
