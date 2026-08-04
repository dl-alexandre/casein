# Mobile Action Center — cards, decisions, and agent instructions

What a paired phone can *do*, and where the trust boundary sits. The transport
(`mobile:user:*`) and the card projection already existed; this documents them
together with the two capabilities added on top: inline decisions and
phone-to-agent instructions.

## Surfaces

| Layer | Module | Responsibility |
|---|---|---|
| Projection | [`DevIDE.Mobile.UserObserver`](../../lib/dev_ide/mobile/user_observer.ex) | Per-user process; turns audit events into cards |
| Card shaping | [`DevIDE.Mobile.Card`](../../lib/dev_ide/mobile/card.ex) | Pure builders, ids, dedupe keys, ordering, **action specs** |
| Decisions | [`DevIDE.Mobile.Actions`](../../lib/dev_ide/mobile/actions.ex) | Reload → validate → authorize → idempotency → apply + audit |
| Instructions | [`DevIDE.Mobile.AgentInstructions`](../../lib/dev_ide/mobile/agent_instructions.ex) | Resolves the agent pane, bounds the text, delegates the paste |
| Transport | [`DevIdeWeb.MobileUserChannel`](../../lib/dev_ide_web/channels/mobile_user_channel.ex) | `watch_workspace`, `card_action`, `agent_instruction`, `agent_targets`, push registration |
| Client | [`devide_mob`](../../native/devide_mob/lib/devide_mob) | Dashboard, review screen, session detail, instruction composer |

## Card types

| Type / `kind` | Priority | Emitted from | Actions |
|---|---|---|---|
| `needs_review` / `approval_required` | high | `run.approval_requested` | `approve`, `request_changes` (note required), `deny` (note + confirmation) |
| `in_progress` | normal | `run.started` | `open` (navigation) |
| `run_failed` | high | `run.failed`, `run.timed_out` | `open` (navigation), `ask_agent_to_fix` (instruction) |
| `connection_issue` | high/normal | channel join failures | retry / pair again (navigation) |
| `workspace_idle` | low | idle workspace | `resume` (navigation) |

`run_failed` closes a real gap: before it, a failed run only *removed* the
in-progress card, so a failure left nothing behind on the phone at all. A later
`run.started` or `run.succeeded` for the same session clears it.

## Three kinds of action spec

`Actions.dispatch/2` branches on the spec, and each branch has different
authority:

1. **Navigation** (`:route`) — records intent for audit, mutates nothing.
2. **Mutation** — `approve` / `deny` / `request_changes`, applied through
   `Runs.Ledger` inside the idempotency transaction. `deny` and
   `request_changes` emit the same `run.approval_denied` event; what separates
   them is that `request_changes` also *delivers* the note (see below).
3. **Instruction** (`:instruction`) — pastes a **server-authored** prompt into
   the workspace's agent pane. The client submits only the action id plus an
   optional note; it cannot dictate the prompt text.

The client may render (1) and (3) inline on the card. Anything with a required
input or a confirmation stays behind the review screen, so a mis-tap cannot deny
a run.

## Instructing an agent

```
phone ──"agent_instruction" {workspace_id, text, submit?}──▶ MobileUserChannel
   authorize_workspace/3            (same gate as watch_workspace / card_action)
   AgentInstructions.send/3
     ├── validate: non-empty, ≤ 4000 bytes after trim
     ├── resolve: SessionDirectory.read/2 → agent pane per tmux session
     │            (a client-supplied `tmux_session` is a *hint*, honored only
     │             when it is one of that workspace's own sessions)
     └── Terminals.send_agent_prompt/4 → chunked tmux paste
             └── Audit.emit! "terminal.agent_prompt_*" + Agents.Activity entry,
                 stamped origin=mobile, device_link_id, platform
```

`agent_targets` returns the addressable panes and `max_bytes` so the client can
offer a picker and size its input. A `request_id` (the phone's outbox key)
records an `ActionOutcome`, so a retry replays instead of pasting twice.

### Request changes delivers the note

`deny` is a full stop. `request_changes` denies the run **and** pastes the note
into the agent pane, framed server-side ("Changes requested from mobile on
`<command>`. It was not approved." + the note). Without this the button
promised something the product did not do — the note reached the audit log and
nothing else, so the agent could not tell a rejection from a rejection-with-
instructions.

Delivery is **best effort and runs after the decision is recorded**: a blocked
run has often already lost its agent pane, and that must not turn a valid
decision into an error. The outcome carries `note_delivered` (plus
`note_undelivered_reason`), and the review screen says which happened rather
than a flat "accepted".

**No approval gate**, by design: a device that may already approve or deny a run
is trusted to type into that workspace's agent pane, exactly as the cockpit is
(`terminal:send_agent_text`). Every send is attributable in the ledger.

## Client behaviour

**Dashboard — attention tiers.** Three sections in one scroll, not exclusive
filter tabs, because a tab can hide a failure you needed to see:

| Tier | Contains | Ordered by |
|---|---|---|
| Needs you | approvals, blocked runs | how long you have been the bottleneck (longest first) |
| Running | work in flight | most recently updated |
| Recent | failures, settled work | priority, then recency — collapsed past 3 rows |

Blocked cards carry the **actual command** (`meta.command_id`) and a
`Waiting 2h` chip measured from `created_at`, so a one-tap approve is informed.
Input-free, confirmation-free server actions render inline; anything with a
required note or confirmation opens the review screen.

**Snooze** is device-local and self-expiring (one hour, `SessionConfig`): the
server owns what is true, the phone owns what it wants to be bothered about. A
snoozed card is never resolved — it returns on its own, and a footer offers to
bring the set back early.

**Session detail** — an "Instruct the agent" composer with quick replies and a
free-text field, shown only when the snapshot reports active agents. Below it,
runs and policy decisions merge into one reverse-chronological **work log**
rendered through `LazyList`.

**Offline** — `DevideMob.Outbox` persists instructions typed with no connection
and `DevideMob.SessionClient` flushes them when the card stream rejoins. Each
entry carries the `request_id` the server dedupes on, the queue is capped at 20
and gives up after 5 attempts, and permanent rejections (too long, unauthorized)
are dropped rather than retried.

**Review screen** — renders the server-authored action specs; never invents an
action.

## Related

- [`push_notifications.md`](push_notifications.md) — how a card reaches a
  backgrounded phone.
- [`terminals.md`](terminals.md) — tmux session/pane model the instruction path
  resolves against.
