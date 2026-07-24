# UAT scenarios

Each subdirectory is one UAT scenario:

```
priv/uat/<scenario>/
  manifest.json   # Casein.UAT.Manifest — identity, seed_cmd, tier eligibility, baselines
  trace.json      # Casein.UAT.Trace — the frozen, replayable steps + assertions
  fixtures/       # copied into the ephemeral CASEIN_WORKSPACES_ROOT (Tier A)
  baselines/      # optional screenshot baselines (visual tier-3, default-off)
priv/uat/seeds/   # deterministic app-state seed scripts referenced by seed_cmd
priv/uat/verdict_schema.json  # the agent verdict contract (Casein.UAT.Verdict)
```

`checkout/` is a **format reference**, authored against a real app surface — it
is not expected to pass against the `:memory` test adapter (whose DOM is a fixed
set of default selectors). Real scenarios are authored by the acceptance agent
(Phase 3) and frozen from its audit trail.

## Determinism contract (Tier A)

A scenario eligible for `tier_a` MUST declare a `seed_cmd`. The seed must produce
a deterministic state: frozen clock, fixed ids, no network, pinned locale. A
scenario that cannot meet this declares only `tier_b` and is skipped by the
Tier A runner instead of flaking.
