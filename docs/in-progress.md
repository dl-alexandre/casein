# In-progress subsystems

> **Direction-of-record** for active development. While an entry exists here,
> other agents treat the listed paths as **read-only** unless coordinating with
> the owner. Remove the entry when the work lands on `master`.

See [`development-workflow.md`](development-workflow.md) for the full workflow.

## Terminal file links

| Field | Value |
|-------|-------|
| **Owner** | agent (claude adhoc-20260706204502) |
| **Branch** | `agent/claude/terminal-file-links-20260706` (pushed, PR open) |
| **Status** | Awaiting gate + merge |
| **Paths (frozen)** | `lib/dev_ide/terminals/file_link_scanner.ex`, `lib/dev_ide/file_panes/link_resolver.ex`, `lib/dev_ide_web/live/workspace_live/pane_worker.ex`, `assets/js/terminal_file_links.mjs`, `assets/js/ghostty_terminal.js` |

## Jido adoption (phases 1–2)

| Field | Value |
|-------|-------|
| **Owner** | agent (claude adhoc-20260706204502) |
| **Branch** | `agent/grok/adhoc-20260706145544` (base; rebase onto `master` pending) |
| **Status** | Reconcile with `agent/claude/adhoc-20260706055215` (audit `jido_signal` causality); then rebase + PR |
| **Paths (frozen)** | `lib/dev_ide/agents/*_action.ex`, `lib/dev_ide/agents/artifact_tools.ex`, `lib/dev_ide/agents/terminal_tools.ex`, `lib/dev_ide/agents/preview_tools.ex`, `lib/dev_ide/agents/annotation_tools.ex` |

Phase 3 (signal bus + alerts routing) not started.