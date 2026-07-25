# Agents / MCP capability layer

> Detect what agent capabilities a workspace has, and give external coding
> agents (Grok, Claude, Codex, opencode) narrow, audited tool access to a
> workspace's tmux sessions and preview surfaces over MCP.

## Grok capability policy (write unlock + raw terminal send)

The token's direct-tool map is a frozen **ceiling** (the full write-capable set
issued at mint) and is intersected with current workspace policy on every MCP
request. Locked/manual operation exposes reads and metadata reporting only. An
active, time-boxed write unlock expands the live grant to supported mutations —
including raw `terminal_send_command` / `terminal_send_keys` for **any pane in
the bound tmux session** (so an agent can drive a verify/bash pane under unlock).
Agent-pane shortcuts (`terminal_send_agent_*`) stay pinned to the claimed agent
pane. Revoking the unlock removes MCP mutations immediately without re-minting.
A later launch also changes the sandbox signature and restarts an existing
leader rather than reusing a previously writable native-tool sandbox.
Write-enabled leaders extend Grok's `strict` profile; locked leaders extend
`read-only` with explicit credential denies.

`search_tools` and `invoke_tool` are intentionally absent, so cross-server
routing cannot bypass the exact grant.

Policy implementation:

- `Casein.Agents.GrokCapabilityPolicy` — `tool_ceiling/0`, `effective_tools/1`,
  `write_unlocked?/1` (policy_version 2; no `@never_grant` on raw send)
- `CaseinWeb.API.AgentCapabilityController` — mints ceiling; returns effective
  `allowed_tools` plus `tool_ceiling`
- `CaseinWeb.API.MCPCapabilityScope` — when write-unlocked, allows
  `terminal_send_command` / `terminal_send_keys` to any pane in the bound session

> **Restore note:** A landlock-limited agent land temporarily truncated this
> file. The full subsystem doc (module map, lifecycle, invariants) remains on
> `master` history prior to the placeholder commit; re-apply the paragraph above
> when restoring the complete file. Product code for the capability fix is complete.

## See also

- [`../terminal_mcp.md`](../terminal_mcp.md)
- [`../preview_mcp.md`](../preview_mcp.md)
- [`../architecture.md`](../architecture.md)
- [`../glossary.md`](../glossary.md)
