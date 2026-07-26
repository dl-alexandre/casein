# Sequence Diagrams

> Version: v2 (raw + MCP reality)
>
> **History:** earlier versions diagrammed the runner-assignment protocol
> (enqueue, poll, claim, report, complete, replay, lease expiry, duplicate
> reports) and coordinator-triggered immediate runs. Those subsystems were removed.
> The flows below are the ones that exist: terminal attach/reconnect,
> raw-terminal admission, agent MCP, and review-agent runs.

## Diagram 1: Terminal attach + reconnect (raw)

```text
Browser     TerminalChannel/LiveView   Ghostty.PTY        tmux
│                  │                       │                │
│ join / attach    │                       │                │
│─────────────────>│                       │                │
│                  │ start_ghostty_terminal│                │
│                  │──────────────────────>│                │
│                  │                       │ exec("tmux new-session -A -s casein_...")
│                  │                       │───────────────>│
│                  │                       │  [exists → attach, else create]
│                  │ ghostty:render (grid) │                │
│<─────────────────│                       │                │
│                  │                       │                │
│ [keypress]       │                       │                │
│─────────────────>│ PTY.write             │                │
│                  │──────────────────────>│ stdin          │
│                  │                       │───────────────>│
│ [tmux output]    │ {:data, bin}          │                │
│<─────────────────│<──────────────────────│<───────────────│
│                  │                       │                │
│ [close tab]      │ subscriber removed    │                │
│─────────────────>│                       │                │
│                  │ (tmux still running)  │                │
│ [new tab opens]  │ reattach + replay scrollback from tmux history
│─────────────────>│                       │                │
```

## Diagram 2: Raw-terminal admission

```text
Operator    Casein LiveView/Channel   Policy            Runs.Ledger
│                  │                     │                  │
│ request raw input│                     │                  │
│─────────────────>│ can_use_raw_terminal?                 │
│                  │────────────────────>│                  │
│                  │  Decision(allow|deny)│                  │
│                  │<────────────────────│                  │
│                  │ raw_session_attached(decision)         │
│                  │───────────────────────────────────────>│
│                  │                     │ run.session_attached / run.session_denied
│ [allow] raw PTY input enabled          │                  │
│<─────────────────│                     │                  │
```

## Diagram 3: Agent drives a session over MCP

```text
Agent       Terminal MCP            TerminalTools       MCPAudit / Activity   tmux
│                  │                     │                  │                  │
│ terminal_list_sessions               │                  │                  │
│─────────────────>│ list (casein_ only) │                  │                  │
│                  │────────────────────>│─────────────────────────────────────>│
│                  │ terminal_topology   │                  │                  │
│ terminal_send_command (agent pane)    │                  │                  │
│─────────────────>│────────────────────>│ send keys/command│                  │
│                  │                     │─────────────────────────────────────>│
│                  │                     │ record (audit + activity feed)        │
│                  │                     │─────────────────>│                  │
│ terminal_capture │                     │                  │                  │
│─────────────────>│ read pane scrollback│                  │                  │
│<─────────────────│<────────────────────│<─────────────────────────────────────│
```

The operator watches the same session in the cockpit and sees mutating MCP
calls reflected in the live agent-activity feed.

## Diagram 4: Review-agent run

```text
Operator    Casein              Policy        Agents.Run       Commands       Runs.Ledger
│                  │                │             │                │             │
│ start review run │ can_start_review_agent?      │                │             │
│─────────────────>│───────────────>│             │                │             │
│                  │ Decision(allow)│             │                │             │
│                  │<───────────────│             │                │             │
│                  │ Run.start (fixed ReviewCommand argv)           │             │
│                  │──────────────────────────────>│ spawn(argv)   │             │
│                  │                │             │───────────────>│             │
│                  │ run.started    │             │                │             │
│                  │───────────────────────────────────────────────────────────>│
│                  │                │             │ {:cmd_exit, code}            │
│                  │                │             │<───────────────│             │
│                  │ run.succeeded | run.failed | run.timed_out    │             │
│                  │───────────────────────────────────────────────────────────>│
```

## Diagram 5: Workspace status read

```text
Browser     Casein LiveView     Export.WorkspaceStatus    State       Runs.Ledger
│                  │                  │                     │             │
│ GET /workspaces/:id               │                     │             │
│─────────────────>│                  │                     │             │
│                  │ status/1         │                     │             │
│                  │─────────────────>│ State.get/1         │             │
│                  │                  │────────────────────>│             │
│                  │                  │ git_summary (read-only)           │
│                  │                  │ recent_runs (Ledger.recent_runs_for)
│                  │                  │────────────────────────────────────>
│                  │                  │ Sanitizer.scrub/1 (strip creds)   │
│                  │ render page      │                     │             │
│<─────────────────│                  │                     │             │
```
