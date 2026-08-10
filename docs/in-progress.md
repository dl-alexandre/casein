# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Windows workstream A — native terminal/session and agent runtime

- **Owner:** OpenCode workstream A (%540 / #462)
- **Tracking:** [GitHub issue #462](https://github.com/dl-alexandre/casein/issues/462)
- **Direction:** keep the Phoenix/LiveView cockpit and shared MCP contracts;
  implement Windows-native terminal topology, ConPTY transport, Job Object
  process ownership, agent launch/worktree lifecycle, and Windows path handling
  behind product-level platform boundaries.
- **Frozen while active:** `casein_ghostty_windows/**`,
  `lib/casein/terminals/backend.ex`, Windows-native terminal/session backend
  modules and their focused tests. Coordinate before changing shared terminal
  behaviours or agent-runtime launch contracts.
- **Out of scope:** packaging/update implementation and preview-specific
  implementation. Interface changes in those areas require coordination first.
- **Landed:** PR #469 makes the existing ConPTY bridge own the complete child
  process tree with a kill-on-close Windows Job Object. PR #478 exposes stable
  product-level session/window/pane topology, roles, capture, resize, and strict
  native target validation on the application-owned PowerShell session.
- **Landed:** PR #502 adds token-free native launch preflight and executable,
  version, and authentication diagnostics for Codex, Claude, Grok, OpenCode,
  and Cursor.
- **Landed:** PR #505 creates isolated native Git worktrees with Windows-safe
  root validation and argv-only Git execution.
- **Landed:** PR #513 composes provider preflight, workspace MCP materialization,
  runtime reporting, and clean-only cleanup for native launches from those worktrees.
- **Landed:** PR #517 starts prepared provider plans through the existing
  workspace-owned PowerShell/ConPTY session and reports launch failures as handoffs.
- **Landed:** PR #530 exposes one backend launch transaction that composes prepare
  and ConPTY start while retaining the plan for explicit finish/handoff cleanup.
- **Landed:** PR #542 requires native provider input to resolve and validate the
  exact application-owned pane target before writing to ConPTY.
- **Landed:** PR #547 connects that transaction to the application-owned native
  session entry point, including agent-role topology reporting and failure handoff.
- **Landed:** PR #554 introduces independently supervised native pane owners with
  stable identity and deterministic ConPTY process-tree cleanup.
- **Landed:** PR #805 refactors `PowerShellSession` onto multiple `PowerShellPane`
  owners with stable create/close/focus topology.
- **Current slice:** native template reconciliation — apply built-in templates
  (starting with `agent_pair`) onto multipane PowerShell topology without a
  second UI. LiveView chrome wiring and real-host Job Object multi-window soak
  remain follow-ups.
