# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Windows workstream A — native terminal/session and agent runtime

- **Owner:** Codex workstream A
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
- **Current slice:** add token-free native launch preflight and executable,
  version, and authentication diagnostics for Codex, Claude, Grok, OpenCode,
  and Cursor before wiring runtime-specific MCP launch arguments.
