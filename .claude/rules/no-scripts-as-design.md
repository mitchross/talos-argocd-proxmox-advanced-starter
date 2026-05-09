# Rule: scripts/ is a tactical bridge, not a design surface

Operators in this cluster should self-verify and self-trigger. The
`scripts/` directory exists for one-off bootstrap operations and CI
bridges that have nowhere else to live — not for recurring operational
checks, not for "I'll just write a quick bash to verify X," and not as
a substitute for proper observability.

## Why

A `scripts/` directory tends to accrete:

- Verification scripts ("check that all RSes are healthy") that should
  be Prometheus alerts on a real metric.
- Trigger scripts ("regenerate this Secret, then bounce that pod") that
  should be controllers reconciling a CR.
- Diagnosis scripts ("find why this resource is OutOfSync") that should
  be `kubectl describe` on a CR with proper status conditions.

Each individual script feels small and harmless. After 18 months you
have 40 scripts, each owned by one person who's now half-remembered
what their dependencies are, and the actual "how does the cluster
work?" answer requires running 6 of them and parsing 600 lines of
output.

The proper response to "I keep needing this verification command" is
NOT to add another `verify-foo.sh`. The proper responses are:

1. **A Prometheus alert.** If the verification is "is X healthy?", add
   an alert that fires when it isn't. The cluster tells you proactively;
   you don't poll a script.

2. **A status condition on the relevant CR.** If the verification is
   "did Y happen successfully?", the operator owning Y should publish
   `status.conditions[].type=Ready,status=True` (or similar). `kubectl
   get <cr> -o jsonpath='{.status.conditions}'` is the universal
   verification command.

3. **A controller-runtime reconciler.** If the script is "if state is X,
   do Y," that's a controller. Build one (operator-sdk, kubebuilder,
   plain controller-runtime) — pvc-plumber itself is the canonical
   example in this repo of "I had a bash script doing this in v1, now
   it's a real operator in v2/v3."

## When `scripts/` IS the right answer

There are two narrow cases:

1. **One-shot bootstrap operations.** Things you do exactly once on a
   fresh cluster: the initial `bootstrap-argocd.sh` apply that registers
   ArgoCD with itself, the `seal-secret.sh` that turns a generated
   password into a SealedSecret committed to Git, the
   `adapt-to-your-cluster.sh` that templates this starter's placeholder
   tokens. These run once per cluster lifetime, then never again.

2. **CI bridges.** Validation that has to run in a pre-merge gate but
   has no upstream equivalent yet. The
   `scripts/validate-argocd-apps.sh` here is one of these — it catches
   duplicate Application names and sync-wave gaps that ArgoCD itself
   doesn't validate at admission time. The day Argo CD ships an
   equivalent validating webhook, the script gets deleted. Until then,
   it lives in scripts/ with a header comment explaining that.

Anything that doesn't fit one of those two patterns belongs in code
elsewhere — controller, alert, status condition, runbook.

## How to add a new file to `scripts/`

If you're about to write a `scripts/<something>.sh`, first answer:

- **Is this a controller-managed concern?** If yes, file an issue and
  build the controller. Don't ship the script as a placeholder.
- **Is this an alert-managed concern?** If yes, write the
  PrometheusRule. The alert message can include the verification
  command if a human still needs to dig in.
- **Is this a one-shot or a CI bridge?** If yes, fine. Add a header
  comment block at the top of the new script citing this rule and
  explaining which of the two narrow cases applies.

The header looks like:

```bash
#!/usr/bin/env bash
# <script-name>.sh — <one-line summary>
#
# Why this is in scripts/: <one-shot bootstrap | CI bridge>.
# Specifically: <when this gets deleted>.
#
# See .claude/rules/no-scripts-as-design.md for the rule.
```

The `<when this gets deleted>` phrasing is intentional. Every script in
`scripts/` has a deletion condition, even if it's "when the upstream
project ships X." If you can't articulate one, the script doesn't
belong in `scripts/`.

## Don't

- Don't add a `verify-<thing>.sh` script. Make it a Prometheus alert.
- Don't add a `wait-for-<thing>.sh` script. Make the operator emit a
  proper Ready condition.
- Don't add a `regenerate-<thing>.sh` script. Make a controller
  reconcile it.
- Don't add a `diagnose-<thing>.sh` script. Improve the relevant CR's
  `status.conditions[]` until `kubectl describe` is the diagnostic.
- Don't add scripts without the header block above. Future operators
  need to know which scripts are tactical bridges vs. accumulated
  toolbelt.

## Related

- `.claude/rules/always-pin-sha.md` — companion rule, similar
  disposition: don't manage churn manually when an automation can.
- `.claude/rules/no-lua-in-argocd-cm.md` — companion rule on resisting
  argocd-cm Lua escape hatches; same "stay out of the platform's
  configuration accumulators" instinct.
