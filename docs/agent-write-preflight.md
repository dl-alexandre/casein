# Agent-write preflight

Managed Grok agents get MCP **mutations stripped** when workspace DB isolation
is `shared_stage`, `unsafe`, or unknown. Known-isolated workspaces
(`ephemeral` / `local`) receive `terminal_send_command` / `terminal_send_keys`.
There is no time-boxed write unlock and no chrome banner.

After #605 the bwrap sandbox base is always **`strict`**. Isolation gates the
**MCP grant only**. A locked worker can still write its worktree, run `mix`,
and commit; it cannot drive live tmux panes. Codex / Claude / OpenCode are
**not** gated the same way.

## Orchestration rules

1. Before multi-agent work (spawn workers, `terminal_send_*`, paste briefs), call
   `terminal_context` and read `agent_write`:
   - `write_enabled` / `orchestrator_ready` must be `true`
   - or `terminal_send_command` must appear in tools/list
2. If locked (`orchestrator_ready: false` or `fail_fast` set): emit **one**
   blocked report (`terminal_report_agent_state` state `blocked`), set pane label
   `blocked: workspace isolation`, and **stop**.
3. Do **not** poll for a write grant. Resolve isolation, then relaunch.
4. Fallback while locked: GitHub/docs-only audit, or implementer work via
   `spawn-agent-worker.sh` (workers advise-and-proceed under strict sandbox).

## Launch preset (orchestrator)

```bash
CASEIN_AGENT_REQUIRE_WRITE=1 bash scripts/launch-casein-agent.sh grok
```

Refuses with **exit 3** when the MCP grant is locked. Workers must **not** set
this flag — `spawn-agent-worker.sh` leaves it unset so locked implementers still
launch. Do **not** bypass with `CASEIN_GROK_SANDBOX_BASE=workspace`.

## After isolation is known

- Mutation tools expand on the next tools/list for a **new** capability freeze
  (relaunch the pane — the grant is read at leader start).
- Sandbox stays `strict` either way.

## Chrome

There is no **Read-only agents** banner and no **Unlock 30 min** control.
Isolation is the only remaining write gate for managed Grok MCP mutations.
