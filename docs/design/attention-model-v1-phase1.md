# Attention model v1 — phase 1 design (#697)

Status: **implemented (phase 2)** — #696 landed as `d8076afb` / PR #703.
Date: 2026-08-08
Owner: worktree `agent-opencode-oc-issue-697-attention-model-*`
Parent: epic #695

## Vocabulary locked by #696 (adopted as-is)

| Concept | Token |
|---------|--------|
| Agent went quiet → you are needed | session reason **`:idle`** (window flag still `:quiet`) |
| Suppress / inline / notify routing | Policy **`delivery_reason` / `delivery_decision` / `delivery_reaction` / `window_delivery`** |

## Modules shipped

- `lib/casein/attention.ex` — umbrella docs
- `lib/casein/attention/signal.ex` — domain signals
- `lib/casein/attention/salience.ex` — **the** ranker (from AttentionInbox)
- `lib/casein/attention/delivery.ex` — thresholds + focus table + session projection
- Projections: `AttentionInbox`, `SessionDirectory.Attention`, `Attention.Policy` (not deleted)

## Ordering (historical)

- **Phase 1:** read + design. Did **not** rename `:quiet` / `quiet_reason` / `quiet_decision`.
- **Phase 2:** rebased onto #696 vocabulary and implemented. Did not invent alternate names.

Poll:

```bash
git fetch -q origin && git log --oneline -5 origin/master
gh issue view 696 --json state
```

---

## What exists today (three independent answers)

| Module | Question | Output vocabulary |
|--------|----------|-------------------|
| `Casein.Mobile.AttentionInbox` (714) | What should the phone show first, and was it seen? | `priority`, `rank`, `reason_code`, `notify`, lifecycle, cursor |
| `Casein.Terminals.SessionDirectory.Attention` (118) | What section does this session row belong in? | `section :: :needs_you \| :working \| :recent`, `reason` |
| `Casein.Attention.Policy` (104) | Should we interrupt the operator right now? | `reaction :: :nothing \| :inline \| :notify` + focus facts |

Nothing reconciles them. Same domain fact can be "critical/notify" on phone, `:needs_you`/`:quiet` in the session rail, and `:nothing` in the browser chrome depending on focus — and those answers are derived independently, not projected from one salience.

---

## Target shape: `Casein.Attention` with three concerns

```
  domain facts / agent windows / cards / audited events
                         │
                         ▼
              ┌─────────────────────┐
              │  Casein.Attention   │
              │  .Signal            │  what happened (domain event)
              │  .Salience          │  how much it matters (ONCE)
              │  .Delivery          │  threshold + surface_state → reaction
              └─────────────────────┘
                    │         │
        projections │         │ thin wrappers (keep modules)
                    ▼         ▼
   SessionDirectory.Attention    Attention.Policy
   Mobile.AttentionInbox         (lifecycle/cursor stay mobile until #698)
```

### 1. Signal — domain events, not UI states

Signals are *what happened*. They are not picker sections, not reaction enums, not priority bands.

**Canonical signal list** (proposed; names freeze only after #696 vocabulary lands for the "agent went quiet / stalled" concept):

| Signal atom (proposed) | Sources today | Notes |
|------------------------|---------------|-------|
| `:agent_blocked` | `agent.blocked`, card type `clarification`, resume `needs_attention`+`waiting`, session `agent_state` in `blocked/attention/errored/stalled` | Highest human-need |
| `:approval_pending` | `run.approval_requested`, resume `needs_attention`+`review`, card type `needs_review` | Decision waiting |
| `:run_failed` | `run.failed`, `run.timed_out`, card/resume `failed`, session lifecycle `:error` | Terminal work failure |
| `:checks_failed` | `gate.failed` | Distinct reason_code today (`checks_failed`) but same band as failure |
| `:apply_failed` | `proposal.apply_failed` | Same failure band |
| `:deploy_failed` | `deploy.failed`, resume phase deploying + failed status | Slightly above generic failure rank today (580 vs 560) |
| `:deploy_succeeded` | `deploy.succeeded`, resume deploying+completed | Actionable outcome |
| `:run_completed` | `run.succeeded`, resume/transition `ready_to_review`/`completed` | Ready for review |
| `:went_quiet` | session window `quiet: true` (SessionDirectory) | **Name TBD by #696** — today reason `:quiet` meaning "agent went quiet, you are needed". Policy's `quiet_*` is the *opposite* polarity (suppress). |
| `:working` | `run.started`, resume/transition working, phases executing/testing/deploying, session `:working` | In progress |
| `:offline_resumable` | resume `availability != "live"` | Last-known offline |
| `:informational` | default / residual | No decision required |

**Allowlisted audited lifecycle actions** (from `AttentionInbox.@meaningful_actions` — these *feed* signals; they are not themselves the public Signal enum):

```
run.started | run.approval_requested | run.approval_granted | run.approval_denied
run.succeeded | run.failed | run.timed_out
agent.blocked | agent.state_changed
gate.passed | gate.failed
proposal.applied | proposal.apply_failed
deploy.started | deploy.succeeded | deploy.failed
```

**Not signals (stay elsewhere):**

- `surface_state` / `target_state` — delivery inputs (Policy).
- `section` / picker partition — projection over salience.
- `reaction` — delivery output.
- Read cursors / `since_viewed` — acknowledgement (#698), not salience.
- Lifecycle stage folding / completion SHA projection — stay on inbox until a later slice; do not block #697.

### 2. Salience — computed once for all surfaces

**Source of truth to generalize:** `Casein.Mobile.AttentionInbox.ranking/3` (private today) and the design contract in `docs/design/mobile-attention-inbox-v1.md`.

**Do not write a second ranker.** Lift the pure ranking function into `Casein.Attention.Salience` (name final in phase 2). `AttentionInbox.project/5` calls it; surfaces do not re-derive "important."

#### Precedence bands (from inbox + design doc)

| Band | `priority` | `rank` | `reason_code` (current strings) | `notify` | Required decision |
|------|------------|--------|----------------------------------|----------|-------------------|
| human blocked | `critical` | 700 | `human_blocked` | true | `"Respond"` |
| review requested | `critical` | 680 | `review_requested` | true | `"Review"` |
| deploy failed | `high` | 580 | `deployment_failed` | true | `"Inspect deployment"` |
| failure / checks / apply fail | `high` | 560 | `failure` or `checks_failed` | true | `"Inspect failure"` / `"Inspect checks"` |
| deploy completed | `normal` | 430 | `deployment_completed` | true | `"Review outcome"` |
| completed / ready | `normal` | 400 | `completed_ready` | true | `"Review outcome"` |
| offline resumable | `low` | 180 | `offline_resumable` | false | nil |
| working | `low` | 120 | `working` | false | nil |
| informational | `low` | 80 | `informational` | false | nil |

Within a band: newer meaningful change first, then stable origin-qualified id (design doc). Age may tweak within-band score later; it must never promote informational churn above a human blocker.

#### Salience value shape (assertable without UI)

```elixir
%Casein.Attention.Salience{
  signal: :agent_blocked,          # Signal.t()
  priority: :critical,             # :critical | :high | :normal | :low
  rank: 700,                       # integer, band-internal only
  reason_code: :human_blocked,     # or keep strings for wire compat in v1
  explanation: "Agent is blocked on you",
  required_decision: "Respond",    # or nil
  notify_eligible?: true           # "this salience band may notify" — NOT delivery
}
```

Tests in `test/casein/attention/salience_test.exs` build plain maps/cards/session windows and assert `signal/rank/priority/reason_code` — **no LiveView, no channel, no Repo required for the pure path.**

#### Input facts Salience needs (normalized once)

A single `%Casein.Attention.Facts{}` (or keyword attrs) assembled by callers:

From **cards / resume / transitions** (mobile path today):

- card `type`, `status`
- `ResumeCard` state/phase/availability
- latest transition `event_action` / `state` / `phase`
- nested `meta.source`, `meta.reason`

From **session directory windows** (picker path today):

- per-window `agent_state` (normalize blocked/attention/errored/stalled → blocked bucket)
- per-window quiet/stalled flag (**token from #696**)
- session lifecycle `status` error/failed

Phase 2 should accept either card-shaped or session-shaped facts and produce the **same** salience for equivalent situations (e.g. blocked agent → rank 700 / `:agent_blocked` whether it arrived via card or session window).

### 3. Delivery — per-surface threshold over salience + focus

Delivery never redefines importance. It answers: *given this salience and this surface context, what reaction?*

#### Inputs

- `salience` (from above)
- `surface_state` — already on `Attention.Policy`: `:focused | :visible | :hidden | :unknown`
- `target_state` — same enum; relationship of the *subject* to the operator surface
- surface id / channel: e.g. `:session_badge`, `:inline_chrome`, `:os_notify`, `:push`, `:mobile_inbox_pin`
- optional delivery-only facts: `observed_working?` (cold-ready guard), ack state later (#698)

#### Thresholds (encode today's behavior without UI change)

These are **starting thresholds** so drawer/badges/phone look the same when #697 lands. #699 may tune them.

| Surface | Delivers when | Maps today to |
|---------|---------------|---------------|
| Mobile inbox order | always order by `rank` desc | `AttentionInbox.project` sort |
| Mobile `notify` / push eligibility | `salience.notify_eligible? == true` **and** band ≥ high/critical/actionable-outcome (current `ranking.notify`) | `attention.notify` |
| Mobile `pin` / Needs Me | unresolved clarification/needs_review (status not handled) — **lifecycle pin, not pure rank** | `unresolved?` / `pin: "needs_me"` |
| Session picker `:needs_you` | salience signal in `{:agent_blocked, :approval_pending, :run_failed, :deploy_failed, :run_completed, :went_quiet, ...}` i.e. rank ≥ ~400 **or** session-only quiet signal | `SessionDirectory.Attention.classify` |
| Session picker `:working` | signal `:working` | section `:working` |
| Session picker `:recent` | else | section `:recent` |
| Browser quiet-agent **transition** | salience includes went-quiet/completed-style signal; then Policy table: | `Policy.quiet_agent_decision` |
| → reaction `:nothing` | surface focused **and** target focused **and** observed_working? | `:focused_target` |
| → reaction `:inline` | not observed_working? **or** surface focused (other target) | `:cold_ready` / `:focused_workspace` |
| → reaction `:notify` | observed_working? and surface not focused | `:background_surface` |
| Browser quiet-agent **steady chrome** | quiet/stalled flag on window → `:inline` else `:nothing` | `Policy.quiet_agent_window` |

**Key rule:** `Attention.Policy.surface_state/1` stays the normalizer; delivery *consumes* it. Policy's reaction enum becomes `Delivery.decide/1` (or Policy delegates to Delivery). Policy module is **not deleted**.

**Push vs pane badge:** same salience definition; push threshold is higher (only `notify_eligible?` bands + Policy/background rules). Badge/section threshold is lower (includes went-quiet and completed). That difference is correct and must remain threshold-only.

---

## How existing modules become projections

### `Casein.Mobile.AttentionInbox`

| Responsibility | After #697 |
|----------------|------------|
| Pure ranking (`ranking/3`, `rank/6`) | **Move core into `Casein.Attention.Salience`**; inbox calls it |
| `reason_code/3`, event→state `event_projection/2` | Signal mapping helpers beside Salience (or `Attention.Signal`) |
| Lifecycle fold, completion, transition labels | **Stay** on inbox (mobile projection / #698 adjacency) |
| Cursor / `mark_viewed` / `record_card` / prune | **Stay** (ack is #698) |
| `project/5`, `project_many/3` | Stay as mobile envelope; fill `priority/rank/reason_code/notify` from Salience |
| `@meaningful_actions`, `@event_labels` | Shared allowlist module or `Attention.Signal` |

Public API of `AttentionInbox` should keep working for `Notifications`, `Push.Dispatcher`, `MobileUserChannel` without behavior change.

### `Casein.Terminals.SessionDirectory.Attention`

| Today | After #697 |
|-------|------------|
| `classify/1` independent cond on windows | Build Facts from windows → Salience → map to `%{section, reason}` |
| `group/1` | Unchanged partition helper over `classify/1` |
| reasons `:blocked \| :error \| :completed \| :quiet \| :working \| :recent` | Keep wire/UI reason atoms; **`:quiet` renamed per #696** — projection maps signal → reason |

Do not delete the module. Call sites: `session_bar_vm.ex` (and any directory consumers).

### `Casein.Attention.Policy`

| Today | After #697 |
|-------|------------|
| `surface_state/1`, `target_state/1` | Stay (or move to `Delivery` and re-export) |
| `quiet_agent_decision/1` | Becomes delivery projection: salience + focus facts → reaction |
| `quiet_agent_transition/1`, `quiet_agent_window/1`, `reaction_label/1` | Thin wrappers; names follow #696 if it renames `quiet_*` |
| Telemetry `[:casein, :attention, :quiet_agent, :transition]` | Preserve event name until an explicit telemetry rename issue |

Call sites: `terminal_state.ex`, `session_bar_vm.ex`, `terminal_events.ex`.

---

## Module sketch (phase 2 — do not implement until #696)

```
lib/casein/attention.ex                 # umbrella moduledoc + maybe types
lib/casein/attention/signal.ex          # signal atoms, from_event/1, from_session/1
lib/casein/attention/salience.ex        # compute/1 — THE ranker
lib/casein/attention/delivery.ex        # decide/1 — thresholds + surface_state
lib/casein/attention/policy.ex          # projection / compatibility (keep)
lib/casein/terminals/session_directory/attention.ex  # projection (keep)
lib/casein/mobile/attention_inbox.ex    # uses Salience; keep lifecycle/cursor
test/casein/attention/salience_test.exs # pure, no UI
test/casein/attention/delivery_test.exs # thresholds, preserve Policy cases
```

**Forbidden in this PR:** UI changes, deleting Policy or SessionDirectory.Attention, second ranker, ack/cross-surface read state (#698), surface threshold migration that changes what users see (#699).

---

## Vocabulary dependency on #696

Do not rename anything in phase 2 until these are known from the merged #696 PR:

| Concept | Current token(s) | Owner today | #696 intent (issue text) |
|---------|------------------|-------------|---------------------------|
| Agent went quiet → you are needed | `:quiet` reason | SessionDirectory.Attention | e.g. `:stalled` or `:idle` |
| Suppress / don't page | `quiet_reason`, `quiet_decision`, `quiet_agent_*` | Attention.Policy | e.g. `:suppress` for delivery decision |
| Window flag | `quiet: true` on window metadata | SessionDirectory + Policy.quiet_agent_window | may rename with session signal |

Phase 2 signal for "agent went quiet" **must** use #696's chosen session-signal word. Delivery suppress reasons **must** use #696's delivery word. Do not keep dual meaning and do not invent a third synonym.

---

## Acceptance mapping (#697 checklist)

| Acceptance | Plan |
|------------|------|
| Signal / Salience / Delivery separation | modules above |
| Generalize AttentionInbox ranking | move `ranking/3` body into Salience; inbox delegates |
| SessionDirectory + Policy as projections | classify/decision call shared model |
| Salience assertable without UI | pure `salience_test.exs` |
| No surface-owned definition of important | only thresholds in Delivery |
| No UI change | preserve ranks, sections, reactions bit-for-bit in existing tests |
| Keep Policy + SessionDirectory.Attention | yes |
| PR + comment on #697, do not merge | phase 2 |

---

## Phase 2 implementation order (when unblocked)

1. Rebase onto `origin/master` (includes #696 vocabulary).
2. Add `Attention.Signal` + `Attention.Salience` by **moving** inbox ranking logic; leave wrappers so inbox tests still pass.
3. Point `AttentionInbox.ranking` at Salience (private delegate).
4. Express `SessionDirectory.Attention.classify` as Facts → Salience → section/reason projection; keep public reason atoms from #696.
5. Express `Policy.quiet_agent_decision` as Delivery over salience + surface_state; keep reaction enum and telemetry.
6. Add pure salience/delivery tests; run existing attention/policy/session_directory/mobile attention tests — expect zero behavior diffs.
7. `mix precommit` / targeted tests; open PR; comment URL on #697; stop.

---

## Out of scope (other issues)

- **#698** — acknowledgement as cross-surface fact (cursors, notifications.read_at).
- **#699** — migrate surfaces to thresholds (may change what users see).
- **#696** — `:quiet` rename (must land first).
