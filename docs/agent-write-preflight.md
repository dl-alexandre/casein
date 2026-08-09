# Agent-write unlock preflight

Managed Grok agents start with MCP **mutations stripped** until an operator grants
**agent write unlock** (chrome banner **Unlock 30 min**, or Agents → Safety).
Unlock is operator-only (`workspace:grant_agent_write_unlock`).

## Orchestration rules (Casein #592 / #593)

1. Before multi-agent work (Claude spawn, `terminal_send_*`, paste briefs), check
   that `terminal_send_command` appears in tools/list.
2. If missing: emit **one** blocked report, set pane label
   `blocked: need agent-write unlock`, and **stop**.
3. Do **not** schedule 15–30 minute unlock poll loops.
4. Fallback without unlock: GitHub/docs-only audit.

## After unlock

- Mutation tools expand **live** (no capability remint).
- OS sandbox stays read-only until the agent is **relaunched** with write enabled
  (`strict` sandbox). Relaunch when worktree filesystem edits are required.

## Chrome

When unlock is inactive, workspace chrome shows a **Read-only agents** banner
with a one-click **Unlock 30 min** control.
