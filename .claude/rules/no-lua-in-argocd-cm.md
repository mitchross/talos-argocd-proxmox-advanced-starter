# Rule: No Lua in argocd-cm (custom resource health checks) by default

Don't reach for `resource.customizations.health.<group>_<kind>` Lua
scripts in `argocd-cm` ConfigMap as a default solution. Custom resource
health checks via Lua are a last-resort tool, not a first-instinct one.

## Why

Custom resource health Lua scripts in `argocd-cm`:

- Run in a sandboxed Lua interpreter inside the ArgoCD application
  controller. Bugs in the Lua are diagnosed by reading
  `kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller`,
  which is a poor UX vs. fixing problems in proper code.
- Compound: every "I'll just add one quick health check" turns into 30
  scripts over time, and the argocd-cm becomes a giant Lua monolith
  that nobody dares touch.
- Are an ArgoCD-specific solution to a problem that's usually
  better fixed upstream. The proper answer to "this CRD's status doesn't
  expose the right condition" is to file a CRD upstream issue, not to
  paper over the gap with Lua.
- Hide the actual signal. A CRD whose health is "obvious from
  kubectl describe" but unknown to ArgoCD is a CRD whose authors should
  fix the status struct. Working around it with Lua removes upstream's
  motivation to do the right thing.

This starter carries two deliberate exceptions in
`infrastructure/controllers/argocd/values.yaml`: child `Application` health
makes app-of-apps waves wait, and kopiur `Restore` health holds an application
`Progressing` until hydration finishes. Both directly enforce the ordering and
restore-before-bind safety model documented in
[`docs/architecture.md`](../../docs/architecture.md).

## The four-bar test

Before adding a custom resource health Lua check, ALL FOUR must be true:

1. **Upstream CRD provably never publishes the health condition.**
   Read the upstream operator's source code or CRD YAML and confirm
   that the `status.conditions[].type` you'd want is never set. If it
   IS set but ArgoCD's default health check doesn't read it correctly,
   the right fix is a built-in ArgoCD health check addition (file an
   upstream PR), not a Lua override.

2. **Upstream tool can't be fixed in a reasonable timeframe.** Ask:
   has anyone filed an issue upstream? Is there a maintainer response?
   Is the CRD project alive? If the answer is "yes, fix is coming in
   3 months," wait for it. If "yes, but the project is unmaintained,"
   maybe the right answer is to swap the operator, not Lua-patch its
   status reporting.

3. **Absence of the health check causes production incidents.**
   Not "is annoying" or "shows OutOfSync forever (cosmetic)." The bar
   is: real downtime or unsafe ordering traceable to ArgoCD not knowing what
   state a resource is in. The existing Application and Restore checks clear
   this bar because removing either turns sync waves into creation ordering.

4. **Heavily commented + cited.** If you do add Lua, the Lua block
   carries a header comment block citing:
   - Which upstream issue it works around (with URL)
   - When it was added and by whom
   - The four-bar test rationale (which of the criteria justify it)
   - The trigger conditions that should make a future operator REVIEW
     this Lua (e.g. "remove this when CRD adds observedGeneration in
     v2.x")

## What to do instead

When tempted to add Lua, walk through these in order:

1. **Is this a missing field in the upstream CRD's status struct?**
   If yes, file an issue upstream. Track the issue in a comment in
   your manifest. Live without the health check until the field lands.
   ArgoCD will show "Unknown" health for this resource — that's
   accurate, not broken.

2. **Can the application or operator layer remove the gap?** Prefer readiness
   conditions, fail-closed dependencies, or lazy credential reads that remove
   the race entirely. Those fixes are portable and testable and do not require
   a Lua interpreter to debug.

3. **Can a built-in ArgoCD health check be made smarter?** ArgoCD has
   built-in health checks for CronJob, Workflow, Rollout, etc. If your
   resource is similar to one of those, file an ArgoCD upstream issue
   asking for the built-in check to handle your case. PRs welcome.

4. **Is OutOfSync acceptable?** "ArgoCD says OutOfSync but the data is
   correct" is sometimes the right end state. Document it in the app's
   README and move on. Not every signal is worth a Lua escape hatch.

If you've walked through all four and the answer is still "I need
custom Lua," it'll probably pass the four-bar test. The header comment
block is non-negotiable.

## Related

- `.claude/rules/always-pin-sha.md` — companion rule on staying out of
  argocd-cm by letting Renovate handle digest churn
- `.claude/rules/no-scripts-as-design.md` — companion rule on resisting
  "just one more bash script" reflexes (same disposition, different
  surface)
- `docs/architecture.md` — why the two current health customizations are
  load-bearing for sync-wave and restore ordering
