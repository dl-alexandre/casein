# DevIDE

DevIDE is a single-runtime workspace cockpit: a durable terminal over a
server-side runtime, with MCP as the interface coding agents use to drive it.

The runtime is the engine: it owns durable sessions and survives disconnects.
The browser is the cockpit: the place a human operator sees the workspace,
types into it, and watches what an agent did. Agents are clients of the same
runtime through MCP, not a separate plugin.

For the full product shape — thesis, server/client boundary, differentiators,
non-goals, architecture narrative, and decision rules — see
[`docs/product.md`](../product.md).

## See also

- [`docs/product.md`](../product.md) — canonical product definition; cite section numbers (e.g. §4, §13.4) in tickets
- [`docs/architecture.md`](../architecture.md) — system internals, subsystem map
- [`docs/terminal.md`](../terminal.md) — terminal subsystem (Ghostty, tmux, multi-pane)
- [`docs/terminal_mcp.md`](../terminal_mcp.md) and [`docs/preview_mcp.md`](../preview_mcp.md) — agent-facing MCP surfaces
- [`docs/state_machines.md`](../state_machines.md) — session, review-run, mode, audit lifecycles
- [`docs/sequence_diagrams.md`](../sequence_diagrams.md) — concrete flows
- [`docs/glossary.md`](../glossary.md) — vocabulary
