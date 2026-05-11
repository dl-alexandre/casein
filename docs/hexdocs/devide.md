# DevIDE

DevIDE is a workspace runtime — local, remote, or fleet-coordinated —
with a programmable editor surface as its cockpit.

The runtime is the engine: it owns sessions, decides what may execute,
records what happened, and survives disconnects. The editor surface is
the cockpit: the place a human operator (or an agent acting on their
behalf) sees the workspace, types into it, and inspects what the runtime
did.

For the full product shape — thesis, operating modes, server/client
boundary, differentiators, non-goals, architecture narrative, and
decision rules — see [`docs/product.md`](../product.md).

## See also

- [`docs/product.md`](../product.md) — canonical product definition; cite section numbers (e.g. §4, §13.4) in tickets
- [`docs/architecture.md`](../architecture.md) — system internals, subsystem map
- [`docs/jx_devide.md`](../jx_devide.md) — JX ↔ DevIDE protocol contract
- [`docs/state_machines.md`](../state_machines.md) — assignment, lease, mode, audit lifecycles
- [`docs/sequence_diagrams.md`](../sequence_diagrams.md) — concrete flows
- [`docs/glossary.md`](../glossary.md) — vocabulary
