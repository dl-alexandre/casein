# Agent state legibility in the cockpit (#730)

Status: **implementing**
Date: 2026-08-09
Owner: worktree `agent-opencode-b6-730-agent-state-*`
Parent: epic #727
Depends on: semantic colour tokens (#729) for durable hues — this track
consumes daisyUI semantic colours (`success` / `warning` / `error` / `info` /
`base-content`) rather than inventing a parallel palette. When #729 lands,
call sites should map through those tokens without changing *shape*.

## Problem

Agent state is already resolved by `Casein.Terminals.AgentState` and exposed on
topology / session metadata. The cockpit mostly paints a single activity dot
driven by either tmux activity age or a handful of agent states. That flattens
distinctions the domain deliberately keeps separate:

1. **`ready` is ambiguous.** `PaneState` scrapes Claude title markers: a Braille
   spinner → `:working`, a heavy asterisk (`✳`) → `:ready`. Claude's own docs
   (and our module docs) say `ready` means **ready *or* awaiting input**. A
   blocked permission prompt and a finished turn look identical in the title.
2. **`stalled` has no unique look that beats a frozen spinner.** A wedged agent
   leaves its last spinner frame up; without the derived stall signal winning
   the chrome, busy and hung read the same.
3. **Runtimes without title markers fall through to silence.** Only Claude
   publishes title markers today. Codex / Grok / OpenCode report semantically
   (hooks/MCP) or not at all. Silence must render as **unknown**, not as a
   confident idle/ready.

This issue is **presentation only**. Detection
(`PaneState` heuristics, `AgentState` reports, `AgentLiveness` observation)
stays unchanged.

## Domain facts (do not re-derive)

| State | Kind | Who may claim it |
|-------|------|------------------|
| `:working` | report **or** title heuristic | hooks/MCP or Braille spinner |
| `:blocked` | **report-only** | hooks/MCP (`terminal_report_agent_state`) |
| `:done` | **report-only** | hooks/MCP |
| `:idle` | report **or** mapped from title `:ready` when a live report exists | hooks/MCP; title alone is not enough for UI enrichment |
| `:errored` | **report-only** | hooks/MCP — a claim about *cause* |
| `:stalled` | **derived-only** | liveness: looks busy + worktree quiet ≥ stall window. Never reported. |
| `:unknown` | absence | no live report and no trustworthy title claim (or title is `:ready` without a report) |

Liveness observation keeps `{:error, reason}` structurally distinct from
`{:ok, %{last_write_at: nil}}`. UI must never collapse "we could not observe"
into "quiet". `AgentState.resolve/4` already treats liveness `:unknown` / `nil`
as no evidence — chrome must not invent a stall or idle from that.

`resolve_for_display/4` deliberately returns `:unknown` for panes with no live
report (except the frozen-spinner → `:stalled` exception). A plain shell
showing Claude's `✳` must **not** read as an idle agent.

## Visual system — not a uniform badge

A single coloured pill for every state would erase the distinctions above.
Chrome uses **three channels**, composed from one presentation module
(`CaseinWeb.WorkspaceLive.Show.AgentStateChrome`):

| Channel | Where | What it carries |
|---------|-------|-----------------|
| **Dot** | window tab, session-rail window row, pane row | colour + optional pulse/ring |
| **Chip** (text) | session row (needs-you), window tab when state is report/derived and needs a word | short word: `needs input`, `done`, `stalled`, `error` |
| **Task line** | window `display_name` / `full_title`, pane label | task_summary text, optionally prefixed with a state glyph only when the state is known |

Shape rules:

- **Loud states** (`blocked`, `errored`) use filled/ringed dots + text chips.
  They outrank quiet/activity dots on the same row.
- **Derived caution** (`stalled`) is amber/warning with a *broken* pulse (not
  the smooth working pulse) so it never reads as healthy activity.
- **Progress** (`working`) is a live/success pulse — same family as "fresh
  activity", but only when semantic state says working.
- **Terminal calm** (`done`, `idle`) is info/muted, no pulse. `done` keeps a
  small chip so finished work is reviewable; `idle` is dot-only.
- **Unknown** paints **nothing agent-specific**. Fall back to ordinary tmux
  activity chrome. No "idle" label, no ready checkmark, no invented certainty.

### Per-state look

| State | Dot | Chip text | Task-summary prefix | Tooltip gist |
|-------|-----|-----------|---------------------|--------------|
| `:working` | success / live pulse | *(none — the pulse is enough)* | none (task text alone) | "Agent working" (+ message) |
| `:blocked` | error + outer ring | `needs input` | none | "Agent blocked: …" |
| `:done` | info | `done` | none | "Agent done" |
| `:idle` | muted base-content | *(none)* | none | "Agent idle" |
| `:errored` | error + outer ring | `error` | none | "Agent errored: …" |
| `:stalled` | warning + broken pulse/ring | `stalled` | none | "Looks busy but worktree idle — may be wedged" |
| `:unknown` | *(no agent override)* | *(none)* | none | ordinary activity tooltip |

### The `ready` problem (explicit)

Title heuristic `:ready` is **not** a seventh semantic state and must not get
its own confident chrome.

| Situation | Resolved semantic state | Chrome |
|-----------|-------------------------|--------|
| Live report `:blocked` (even if title is `✳`) | `:blocked` | needs-input chip + error dot |
| Live report `:done` | `:done` | done chip |
| Live report `:idle` | `:idle` | muted idle dot |
| Live report `:working` past TTL with title ready and worktree not active | `:idle` (existing resolve rule) | muted idle |
| **No report**, title `✳` | `:unknown` via `resolve_for_display` | **no agent chrome** — only tmux activity |
| Quiet-window attention (time-based, separate from AgentState) | n/a | keep existing violet/fuchsia quiet badge; do not relabel it "ready" or "done" |

Quiet badges already mean "agent went quiet, you may be needed" (`Attention`
reason `:idle`). That is the honest residual for Claude-only title readiness
when hooks never fired. We do **not** invent a "ready" chip that would lie
about blocked-vs-finished.

### `stalled` / wedged

`:stalled` exists because a frozen spinner reads as `:working`. Chrome must:

1. Prefer the resolved `:stalled` class over any working/fresh activity class.
2. Use warning (not error) — observation, not proven failure (`AgentState` docs).
3. Show the `stalled` chip so a scan of the rail does not depend on hue alone.
4. Never emit stalled from liveness unknown/error.

### Honest degradation (no title markers)

| Runtime signal | Chrome |
|----------------|--------|
| Semantic report present | full table above |
| Title spinner only (Claude, no report) | working only while not stalled; stall when liveness says so |
| Title `✳` only | unknown → no agent chrome |
| Nothing | unknown → no agent chrome |

## Single source of presentation

All three surfaces read the same helpers:

```
AgentState (resolve*) ──► window/pane.agent_state
                              │
                              ▼
                 AgentStateChrome.present(state, message)
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
     window activity dot   session chip   task_summary title
     pane row dot          (needs-you)
```

- `SessionBarVM` stops owning private `agent_state_class/label` clauses; it
  calls `AgentStateChrome`.
- `SessionBar` session badges and window indicators consume the VM fields
  (`activity_class`, `activity_label`, optional `agent_state_chip`).
- Pane chrome (`terminal_chrome` geometry + pane tabs) applies the same
  present() when `pane.agent_state` is set; otherwise keeps tmux status dots.
- `task_summary` stays the human task string; titles/tooltips append the chrome
  label rather than baking state words into the summary text itself.

## Out of scope

- New agent-state atoms or changes to `resolve/4` / `PaneState`.
- Polling or detection to fill unknown gaps.
- Replacing the attention / quiet delivery model (#695 family).
- Defining the full semantic token inventory (#729 owns that migration).

## Acceptance mapping

| Acceptance | Where |
|------------|--------|
| Design note first, all seven states, ready + stalled + unknown | this file |
| Implementation follows note; pane chrome, session-rail, task_summary same source | `AgentStateChrome` + call sites |
| PR URL on issue | PR body + `gh issue comment` |
