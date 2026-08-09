# Mobile Action Center

> Server-side card feed, attention ranking, and fail-closed action dispatch that
> power the native companion (`casein_mob`). This is the **server half** of the
> server-to-surface gap (#737): what the phone may show and mutate is decided
> here; the companion is a pure projection consumer.

Design contracts (product acceptance, threat matrix, non-goals):

- [`docs/design/mobile-attention-inbox-v1.md`](../design/mobile-attention-inbox-v1.md)
- [`docs/design/mobile-work-actions-v1.md`](../design/mobile-work-actions-v1.md)

Related surfaces: [`push_notifications.md`](push_notifications.md) (offline
fan-out of the same cards), [`mob_dev_workflow.md`](mob_dev_workflow.md)
(on-device OTP loop), [`mob_ondevice_terminal_gate.md`](mob_ondevice_terminal_gate.md)
(terminal byte path, separate from Action Center).

## Responsibility

The Action Center turns already-authorized runtime facts into a **bounded,
origin-qualified card snapshot** for one authenticated user, ranks what needs
the human, and accepts only **server-declared** card actions under a strict
reload → validate → authorize → revalidate-target → idempotent-commit path.

It owns:

- Per-user live card observation (`UserObserver`)
- Deterministic card shaping (`Card`) and resume/evidence/intervention envelopes
- Attention ranking + durable SEEN markers (`AttentionInbox` over shared
  `Casein.Attention.*`)
- Mutating dispatch (`Actions` + `ActionOutcome`)
- The wire transport (`CaseinWeb.MobileUserChannel` topic `mobile:user:me`)

It does **not** own: OS push delivery (Push subsystem), on-device VT rendering,
web cockpit chrome, agent execution, or a second task database. Cards are a
projection; runs/agents/tmux remain sources of truth.

## End-to-end flow

```
runtime facts                         server Action Center                    companion
─────────────                         ────────────────────                    ─────────
Runs / AgentEvents /                  UserObserver (per user)
  Clarification / LiveWork  ──────▶     Card builders
  SessionDirectory / Audit              AttentionInbox.project_many
                                        ResumeCard / Intervention / Evidence
                                              │
                                              ▼
                                      cards_snapshot (ranked, sticky,
                                        attention, actions, pwa_url)
                                              │
                         Phoenix channel ─────┼──── ws ──▶ SessionClient
                         mobile:user:me       │            SessionDashboardScreen
                                              │              mark attention_viewed
                         card_action ◀────────┼──── ws ──  card_action / review
                                              ▼
                                      Actions.dispatch
                                        reload card from observer
                                        declared action only
                                        authorize workspace
                                        revalidate agent pane
                                        ActionOutcome (idempotent)
                                        Runs.Ledger / paste follow-up
```

Exactly one live origin socket per device. Inactive-origin cards may be cached
on-device as read-only; the server still refuses mutation without a live
authoritative card on the active origin.

## Module map

### Attention

| Module | File | Role |
|---|---|---|
| `Casein.Mobile.AttentionInbox` | `lib/casein/mobile/attention_inbox.ex` | Mobile envelope: lifecycle history, `since_viewed`, pin/notify bits. Ranking/salience come from `Casein.Attention.Salience` / `Delivery` — **not a second ranker**. |
| `Casein.Mobile.AttentionCursor` | `lib/casein/mobile/attention_cursor.ex` | Durable SEEN (and optional RESOLVED) row; table `mobile_attention_cursors`. Cross-surface API: `Casein.Attention.Acknowledgement`. |
| `Casein.Mobile.AttentionTransition` | `lib/casein/mobile/attention_transition.ex` | Allowlisted meaningful lifecycle facts; table `mobile_attention_transitions`. |

### Work / cards

| Module | File | Role |
|---|---|---|
| `Casein.Mobile.Card` | `lib/casein/mobile/card.ex` | Pure builders + action-spec validation. Types: needs_review, clarification, in_progress, outcome, connection_issue, workspace_idle. |
| `Casein.Mobile.UserObserver` | `lib/casein/mobile/user_observer.ex` | Per-user GenServer; owns the transient card set and versioned snapshots. |
| `Casein.Mobile.Actions` | `lib/casein/mobile/actions.ex` | Trust-boundary dispatcher for `card_action`. |
| `Casein.Mobile.ActionOutcome` | `lib/casein/mobile/action_outcome.ex` | Idempotency + race ledger (`mobile_action_outcomes`). |
| `Casein.Mobile.Intervention` | `lib/casein/mobile/intervention.ex` | Fail-closed bridge to one role-marked agent pane; server-declared intents. |
| `Casein.Mobile.Clarification` | `lib/casein/mobile/clarification.ex` | Durable Needs Me requests (clarification / direction / blocker). Clients cannot synthesize. |
| `Casein.Mobile.Evidence` | `lib/casein/mobile/evidence.ex` | Bounded read-only changed-files / diff / artifact projection. |
| `Casein.Mobile.ResumeCard` | `lib/casein/mobile/resume_card.ex` | Origin-qualified semantic state + navigation locator (never authorization). |
| `Casein.Mobile.LiveWork` | `lib/casein/mobile/live_work.ex` | Privacy-safe live agent cards from session list metadata only. |
| `Casein.Mobile.Observability` | `lib/casein/mobile/observability.ex` | Allowlisted mobile lifecycle telemetry into the audit spine. |

### Wire

| Module | File | Role |
|---|---|---|
| `CaseinWeb.MobileUserChannel` | `lib/casein_web/channels/mobile_user_channel.ex` | Joins `mobile:user:me`, pushes `cards_snapshot`, handles `card_action`, `attention_viewed`, push registration, on-device terminal leases. |

Feed timing / soak (`feed_timing*`) instrument snapshot latency; they are not
part of the product card contract.

## Public surface (channel)

Topic: `mobile:user:me` (device-link token). Explicit `mobile:user:<user_id>` is
accepted only when it matches the authenticated user.

| Direction | Event | Contract |
|---|---|---|
| server → client | `cards_snapshot` | `{user_id, version, origin, live_work, cards[]}` plus feed-timing wire context. Cards are **server-sorted** (unresolved pin → priority band → rank → recency → identity). |
| client → server | `watch_workspace` | Authorize + watch; reply is a full snapshot. |
| client → server | `card_action` | `{card_id, action, payload?, request_id?, origin_id?}`. Reply `{status, card_id, action_id, idempotent, result, snapshot}` or `{reason}`. |
| client → server | `attention_viewed` | `{origin_id, card_id, attention_key, through_marker}`. Advances SEEN with `max` semantics; reply is a fresh snapshot. |
| client → server | `mobile_observation` | Allowlisted observability enums only. |
| client → server | `register_push` / `unregister_push` | Token handoff to Push (see push_notifications.md). |

### Card wire shape (authoritative fields)

Each card in `cards_snapshot` includes at least:

- Identity: `id`, `type`/`kind`/`status`/`source`, `workspace_id`, `session_id`, `origin`
- Content: `title`, `body`, `priority`, timestamps
- `sticky` — server-owned Needs Me pin (viewing does **not** clear it)
- `attention` — full `AttentionInbox.project/5` map after `render_value/1`:
  `key`, `identity`, `priority`, `rank`, `reason_code`, `explanation`,
  `required_decision`, `unresolved?`, `pin`, `notify`, `changed_at`,
  `notification_group`, `since_viewed` (`count`, `through_marker`,
  `viewed_through_marker`, `changes[]`, `truncated?`), `lifecycle`, `completion`
- `resume` — navigation locator + semantic state
- `actions` — declarative action specs (id, label, style, input, revision, route…)
- Legacy `action` / `secondary_actions` kept for older clients
- `intervention`, `evidence`, `pwa_url` when projected

Clients must not invent actions or re-rank. Cached inactive-origin cards omit
live authority and must not dispatch mutations until the origin is activated
and refreshed.

## Data flow / invariants

### Snapshot ranking

`MobileUserChannel.render_snapshot/2` sorts with:

1. unresolved Needs Me pin (`attention.unresolved?` / Delivery threshold)
2. priority band (critical → high → normal → low)
3. within-band `attention.rank` (desc)
4. `changed_at` / card `updated_at` (newer first)
5. stable `attention.identity` (`origin_id:attention_key`)

`AttentionInbox.key/1` is workspace + task ref (or session fallback). Identical
card ids on two origins never collide because every key is origin-namespaced.

### SEEN vs RESOLVED

- **SEEN** (`attention_viewed` → `AttentionInbox.mark_viewed/5` →
  `Acknowledgement.mark_card_seen_through/5`): advances
  `through_transition_id` with atomic `max`. Shared across the user's devices.
  Only acknowledges delivery of lifecycle changes; does **not** release the
  Needs Me pin.
- **RESOLVED / handled**: authoritative card state change or removal from the
  observer (review decision, clarification resolve, live-work disappearance).
  Viewing alone never demotes unresolved work.

Marker rules: client may only submit a server-issued `through_marker`. Cross
origin/card/user markers fail closed (`attention_scope_mismatch` /
`invalid_attention_marker`).

### Action dispatch (Actions)

Order is load-bearing:

1. Ensure request origin matches the live socket origin (before idempotent replay).
2. Replay `ActionOutcome` on matching `request_id` (successes only).
3. Reload card from `UserObserver` — never trust client resource/workspace ids.
4. Action must be on the card's declared specs (or Intervention-available).
5. Revision-bound params when the spec carries a revision.
6. Authorize actor against reloaded card workspace (and pairing scope).
7. Revalidate exact agent-role pane for intervention actions (no terminal body
   in the feed path).
8. Commit outcome + side effect; audit with mobile source metadata.

Statuses on `ActionOutcome`: `processing` | `accepted` | `navigated` |
`failed` | `rejected`. Partial unique indexes prevent two devices from applying
the same mutation class twice.

### Clarification / Needs Me

`Clarification.request/1` is server- or MCP-ingress only after the exact pane is
revalidated as `role=agent`. Open requests are durable AgentEvents; the
observer projects them into clarification cards. **Filter resolved before any
newest-per-pane distinct** if you touch those queries — otherwise older open
requests starve (known mobile trap).

### Privacy

Forbidden on the wire and in push payloads: message bodies, pane output,
credentials, file bodies, full diffs beyond the bounded Evidence envelope.
Intervention feed projection never captures terminal content; `describe/1` is
desktop-only diagnostics.

## Gotchas

| Trap | Rule |
|---|---|
| Second ranker on the phone | Consume `attention.*` and server sort order; do not re-implement Salience. |
| SEEN clears Needs Me | It must not. Pin is Delivery/`unresolved?` until authoritative handle. |
| Cached action dispatch | Server requires live card; client must disable cached actions. |
| Cursor reset race | Only monotonic `max` on server-issued markers. |
| Clarification inbox query | Resolve-filter **before** `DISTINCT ON` pane, not after. |
| `gap:` in Mob layouts | No-op on both native renderers; do not rely on it for Action Center UI. |
| Device verification | OTP is embedded on-device; headless tests + a checklist, never claim hardware proof from CI. |

## Companion consumption (surface gap)

What the server already exposes vs what `native/casein_mob` uses:

| Server capability | Companion today |
|---|---|
| Ranked `cards_snapshot` + sticky | `SessionDashboardScreen` observer section (Needs Me / Live / Failed / Done filters) |
| `attention.since_viewed` | Partial (count + latest label line); full lifecycle/completion not a dedicated inbox screen |
| `attention_viewed` | Fired on card open via `SessionClient.attention_viewed/1` |
| `card_action` + review/intervention | `ReviewDecisionScreen` + dashboard action button |
| Dedicated inbox screen named/routed as inbox | **Missing** — tracked as #739 (out of this vertical) |
| Full-width action layout fix | #738 (out of this vertical) |
| Theme kit / scaffolding cleanup | #740 settled in `CaseinMob.Theme` + `mob_dev_workflow.md` (Hex `mob_themes` rejected); #741 scaffolding removal remains out of this vertical |

This document restores the **server contract** so surface work has a single
place to read. Building the dedicated inbox screen is deliberately a separate
track.

## Verifying (headless)

```bash
# Attention projection + cursor
mise exec -- mix test test/casein/mobile/attention_test.exs

# Channel wire: snapshot ranking, attention_viewed, card_action
mise exec -- mix test test/casein_web/channels/mobile_user_channel_test.exs

# Card / intervention / live work builders
mise exec -- mix test test/casein/mobile/card_test.exs \
  test/casein/mobile/intervention_contract_test.exs \
  test/casein/mobile/live_work_test.exs
```

Do **not** run the full suite from an agent pane on the shared box (Postgres
shm pressure). Device checklist belongs on the PR that touches
`native/casein_mob` screens, not on a docs-only change.

## See also

- Shared attention model: `lib/casein/attention/` (`Signal`, `Salience`,
  `Delivery`, `Acknowledgement`) — generalized from the mobile envelope
- Push offline twin: [`push_notifications.md`](push_notifications.md)
- Design freeze / slice order: [`docs/design/authority-evidence-freeze.md`](../design/authority-evidence-freeze.md)
- Parent gap issue: [#737](https://github.com/dl-alexandre/casein/issues/737)
