# Agent-write unlock preflight

Managed Grok agents get MCP **mutations stripped** until an operator grants
**agent write unlock** (chrome banner **Unlock 30 min**, or Agents → Safety).
Unlock is operator-only (`workspace:grant_agent_write_unlock`).

After #605 the bwrap sandbox base is always **`strict`**. The unlock gates the
**MCP grant only** (`terminal_send_command` / `terminal_send_keys`). A locked
worker can still write its worktree, run `mix`, and commit; it cannot drive live
tmux panes. Codex / Claude / OpenCode are **not** gated the same way.

## Orchestration rules (Casein #593)

1. Before multi-agent work (spawn workers, `terminal_send_*`, paste briefs), call
   `terminal_context` and read `agent_write`:
   - `write_enabled` / `orchestrator_ready` must be `true`
   - or `terminal_send_command` must appear in tools/list
2. If locked (`orchestrator_ready: false` or `fail_fast` set): emit **one**
   blocked report (`terminal_report_agent_state` state `blocked`), set pane label
   `blocked: need agent-write unlock`, and **stop**.
3. Do **not** schedule 15–30 minute unlock poll loops.
4. Fallback without unlock: GitHub/docs-only audit, or implementer work via
   `spawn-agent-worker.sh` (workers advise-and-proceed under strict sandbox).

## Launch preset (orchestrator)

```bash
CASEIN_AGENT_REQUIRE_WRITE=1 bash scripts/launch-casein-agent.sh grok
```

Refuses with **exit 3** when the MCP grant is locked. Workers must **not** set
this flag — `spawn-agent-worker.sh` leaves it unset so locked implementers still
launch. Do **not** bypass with `CASEIN_GROK_SANDBOX_BASE=workspace`.

## After unlock

- Mutation tools expand on the next tools/list for a **new** capability freeze
  (relaunch the pane — the grant is read at leader start).
- Sandbox stays `strict` either way.

## Chrome

When unlock is inactive **and a capability-scoped agent is bound**, workspace
chrome shows a **Read-only agents** banner with a one-click **Unlock 30 min**
control. Bound means the workspace has a live (unrevoked, unexpired) agent
capability — only managed Grok mints one. A workspace running Claude / Codex /
OpenCode gets no banner, because those runtimes keep their mutation tools
whatever the unlock says, so the banner's claim would be false there.

The launcher never revokes on pane exit, so a closed Grok pane keeps the
workspace bound until its capability hits the 12h TTL or that leader mints a
replacement. That tail is intentional — the bearer is still usable.

Run panel → **Agent write unlock** follows the same binding rule: the grant form
appears only while a capability-scoped agent is bound. An **active** unlock always
renders regardless of binding — `Revoke now` is the kill switch and must stay
reachable after the capability it was granted for has lapsed.

Consequence: there is no pre-launch grant. Launch the Grok pane first, unlock
once it is bound, then **relaunch** it — the MCP grant is frozen at leader start,
so unlocking does not expand a live pane's tools/list.
