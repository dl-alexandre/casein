# Sticky next-prompt: one deferred operator message per agent pane

Status: accepted, shipped v1

Parent: [epic #673](https://github.com/dl-alexandre/casein/issues/673) —
"Issues schedule work. Casein runs work. next-prompt steers work."

## Decision

Casein holds **at most one** operator message per `{tmux_session, pane_id}` and
injects it on the pane's next semantic-state edge. Setting a second message
replaces the first. There is no queue, no priority, and no interrupt-while-
working.

`Casein.Terminals.NextPrompt` owns the slot; `Casein.Terminals.NextPrompt.Server`
subscribes to the existing `agent_state:<workspace_id>` PubSub topic and releases
the message on `deliver_when`. Transport is `Casein.Terminals.PaneSubmit`, which
pastes through the normal prompt path and then confirms the submit landed.

MCP surface: `terminal_set_next_prompt`, `terminal_clear_next_prompt`,
`terminal_get_next_prompt`. Panes carrying a staged message are flagged
`pending_next_prompt` in `terminal_topology` and `terminal_agent_pane`.

## The problem

An orchestrator that learns something mid-turn — the branch moved, the PR
already merged, stop and rebase — had no way to say it. Typing into a working
agent pane fails in three ways at once: the text lands in a composer nobody
submits, the TUI is not reading keys, or the injection interrupts a turn that
was about to succeed. Operators worked around it by waiting and watching, which
is exactly the human keystroke bot the epic exists to delete.

## Why one slot and not a mailbox

A queue of stale instructions delivered in one burst is worse for an agent than
the newest instruction alone. When an operator sends a correction they almost
always mean it to supersede what they said thirty seconds earlier; a FIFO
faithfully replays the superseded version first and invites the agent to act on
it. Coalescing is not a simplification we will outgrow — it is the semantics.

`coalesce_key` therefore identifies *whose* message is pending so a caller can
retract its own without stepping on another orchestrator's. It does not
partition the slot.

## Why `next_idle` includes `done`

`priv/scripts/casein-agent-state.sh` maps Claude's `Stop` hook to `done` and
emits `idle` only on `SessionStart`/`SessionEnd`. A literal `next_idle` would
therefore almost never fire for the runtime this feature was built for. The
default reads as "when the agent stops working" and covers `idle` **or** `done`.
`next_done` and `next_blocked` stay literal for callers who mean them.

## Why delivery is confirmed, not assumed

`tmux send-keys … Enter` returns success once tmux writes to the pty. Whether
the TUI consumed the keypress is a separate question, and the answer is often
no — a draining paste buffer swallows the Enter, or the TUI is in a mode where
Enter means nothing. `PaneSubmit` watches for either a hook-sourced `working`
report (the runtime saying it accepted a prompt) or a changed pane capture, and
re-presses Enter once before giving up.

The staged-prompt path treats an unconfirmed submit as a failure and retries on
the pane's next qualifying edge. The pre-existing send tools report
`delivery: "not_confirmed"` but do not fail: the signals are heuristics over a
screen Casein does not control, and turning every false negative into a failed
tool call would break working orchestration to fix a silent one.

## Three channels, three jobs

| Channel | Direction | Lifetime | Answers |
|---------|-----------|----------|---------|
| **Sticky next-prompt** | operator → agent | until the next state edge | "here is what to do next" |
| **Needs Me** (`terminal_request_human_input`, `Casein.Mobile.Clarification`) | agent → human | until answered | "I am stuck, decide this" |
| **Annotations** (`annotation_propose`) | either → durable record | until reviewed | "this is worth remembering" |
| **Issues queue** (`queue/*` labels) | human → fleet | until closed | "this is a unit of work" |

They are deliberately not merged. Needs Me blocks an agent and needs a durable
answer with a request id; a sticky prompt blocks nobody and is fire-and-forget.
Annotations are a record, not a delivery. The Issues queue schedules cold work
across sessions; a sticky prompt steers a session already running. Collapsing
any pair would give one of them the other's lifetime and make it wrong.

## What v1 deliberately does not do

- **No multi-message inbox.** See above; this is a decision, not a backlog item.
- **No `interrupt_if_working`.** The value of the feature is that the operator
  speaks without having to judge whether now is a safe moment. An interrupt flag
  hands that judgement straight back.
- **No synthetic user-turn injection.** Casein pastes into a pane, with the
  limits that implies: a runtime that is not accepting keyboard input cannot be
  reached this way. A per-runtime session API (Grok ACP, Claude SDK) is the
  follow-up that would remove the limit.

## Dropped, not delivered

A staged message is discarded — with an `agent.next_prompt_dropped` audit row —
when the bound `agent_session_id` changes (the runtime restarted, so the message
is addressed to an agent that no longer exists), when the pane disappears from
its session, or when `expires_at` passes (24h default). Delivering to a recycled
pane id would drop mid-task context on a stranger.
