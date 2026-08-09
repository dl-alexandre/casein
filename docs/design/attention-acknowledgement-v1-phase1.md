# Acknowledgement as a cross-surface fact — phase 1 design (#698)

Status: **phase 2 implemented** — stacked on #697 (`PR #720` / branch
`agent/opencode/oc-issue-697-attention-model-20260808142115`).
Date: 2026-08-08
Owner: worktree `agent-opencode-oc-issue-698-ack-cross-surface-*` (pane `%354`)
Parent: epic #695
Depends on: #697 (shared Attention model: signal / salience / delivery) — open as PR #720

## Ordering

```
#696 (:quiet rename, %351) → #697 (extract model, %352) → #698 (this, %354)
```

- **Phase 1 (this note):** read the three stores, define the single fact, SEEN vs RESOLVED, surface mapping, migration. Do **not** create a third store, rename attention tokens, or touch `:quiet`.
- **Phase 2 (when #697 exists on a branch or master):** stack on #697's branch (Graphite-style) or open a **draft PR that states its base**. Implement against #697's APIs. Adopt #697's signal/salience/delivery vocabulary — **never invent a second attention vocabulary**. If #697 renames, follow.

Poll:

```bash
git fetch -q origin && git log --oneline -5 origin/master
gh issue view 696 --json state,comments --jq '{state, last: .comments[-1].body[0:200]}'
gh issue view 697 --json state,comments --jq '{state, last: .comments[-1].body[0:200]}'
# Also: coordinate with pane %352 rather than guessing APIs.
```

If still blocked: **idle is valid**. Do not guess #697 module shapes.

---

## What exists today (two durable stores + one ephemeral)

| Surface | Module / store | Question it answers | Durable? | User-scoped? | SEEN | RESOLVED |
|---------|----------------|---------------------|----------|--------------|------|----------|
| Phone inbox | `Mobile.AttentionCursor` + `AttentionTransition` (`mobile_attention_cursors` / `_transitions`) | What meaningful transitions has *this user* already viewed on this origin/card? | Yes | Yes (`user_id` + `origin_id` + `card_id`) | Yes — monotonic `through_transition_id` + `viewed_at` | **No** — Needs Me pin is card status (`unresolved?`), not cursor |
| Notifications drawer | `Notifications.mark_read` / `resolve` / `mute` on `notifications` | Has this notification row been read / closed / muted? | Yes | Yes (row is per-user; APIs require `user_id`) | Yes — `read_at` | Yes — `resolved_at` (+ `muted_at`) |
| Session rail / quiet chrome | `SessionDirectory.Attention` + LiveView `unseen_quiet_window_ids` in `terminal_state.ex` | Is this session in `:needs_you`? Has *this browser tab* already cleared the quiet badge? | **Classification only** (no seen). Unseen set is **socket assign** | No durable user key | Ephemeral only — cleared on focus/click into window | No |

### Only crossover today (not read state)

Mobile → notifications uses `attention.notification_group` (`"#{origin_id}:#{key(card)}:#{reason_code}"`) as a **push/dedupe grouping string** (`Notifications.deliver_mobile_card/2`, `Push.Dispatcher`). It does **not** share cursors or `read_at`.

### Explicit SEEN ≠ RESOLVED already in mobile code

`AttentionInbox.project/5` documents (and implements):

> Viewing only acknowledges delivery; an authoritative handled/resolved card state (or removal from the observer) is what releases a Needs Me request.

`unresolved?` / `pin: "needs_me"` is independent of the cursor. Notifications already split the same two verbs: `mark_read` vs `resolve`.

### Session rail gap (the product bug)

`SessionDirectory.Attention.classify/1` partitions sessions into `:needs_you | :working | :recent` with **no seen watermark**. Quiet-window "unseen" lives only in `socket.assigns.unseen_quiet_window_ids` and is cleared by `acknowledge_quiet_window/3` when the operator focuses that window in **this** LiveView. Reload, second device, or phone view never settles the web badge.

---

## The single acknowledgement fact

### Definition

> **Acknowledgement** is a per-viewer record that a specific **attention subject** has been **seen** and/or **resolved** by that user, independent of which surface performed the action.

It is **not** salience (how much it matters — #697).  
It is **not** delivery (whether to page now — #697 Delivery + Policy).  
It is the missing primitive Delivery may *consume* so thresholds can suppress already-settled noise (#697 design already lists "optional … ack state later (#698)").

### Subject identity (what is being acknowledged)

One subject key, stable across surfaces. Proposed shape (names final in phase 2 to match #697):

```text
subject =
  { user_id,
    origin_id,          # Casein.Origin.id(); multi-origin mobile already requires this
    kind,               # :card | :session_window | :notification  (wire/compat; prefer fewer)
    subject_id          # stable id within kind
  }
```

**Preferred convergence (fewer kinds over time):**

| Kind today | `subject_id` | How web/phone/drawer map |
|------------|--------------|---------------------------|
| Card / task attention | `AttentionInbox.key(card)` = `"#{workspace_id}:task:#{type}:#{id}"` or `"#{workspace_id}:session:#{session_id}"` | Phone cursor scope; notification `metadata.attention_key` / `source_type=mobile_card` + `source_id`; session rail when session-backed |
| Session window (quiet / needs_you without card) | `"#{workspace_id}:session:#{session_id}:window:#{window_id}"` (or session-only if window unstable) | Session-rail unseen; Policy quiet-agent chrome |
| Legacy notification-only rows | notification id **only as migration bridge** | Drawer rows with no card/session binding |

Phase 2 goal: **card/session subjects are canonical**; notification rows *project* ack from the subject they reference (via `metadata.attention_key`, `session_id`, `source_id`), not own a parallel forever-key. Pure alert notifications without a subject keep row-level ack as a thin projection of the same store (subject_id = notification id, kind = `:notification`) so we do not lose drawer semantics.

### Two concepts: SEEN and RESOLVED

**Both are required.** Saying only one would either (a) pin Needs Me forever after a glance, or (b) clear Needs Me when the operator only scrolled past a failure.

| Concept | Meaning | Product effect | Analog today |
|---------|---------|----------------|--------------|
| **SEEN** | Viewer has observed the current generation of the subject (watermark advanced past the latest meaningful signal/transition they were shown). | Clears unread dots, drawer unread badge contribution, session-rail "unseen" highlight, push re-alert for *that generation*. Does **not** drop Needs Me / unresolved pin. | `AttentionCursor.through_transition_id` / `viewed_at`; `notifications.read_at`; LiveView `unseen_quiet_window_ids` clear |
| **RESOLVED** | Viewer (or domain) has **dealt with** the subject for this generation — decision made, failure inspected and dismissed as handled, card left handled state. | Releases Needs Me pin from *ack* side when domain has not already; drawer "Resolved"; stops treating subject as open work for this user. | `notifications.resolved_at`; card status handled / removed from observer (`unresolved?` false). Mobile has no separate resolve API today — domain card state fills that role |

**Generation / watermark rule (from mobile contract — keep):**

- SEEN advances with `max(existing, marker)` against a server-issued monotonic marker (transition id today; may become signal occurrence id after #697).
- A new meaningful signal **after** the watermark re-opens SEEN (unread again) without necessarily clearing RESOLVED if domain still says handled — product default: **new failure/blocker after resolve re-opens both** (new generation). Encode in moduledoc; match mobile "transition after snapshot remains unread."

**Mute** stays a delivery preference on the notification row / preferences system for v1 (not a third ack verb), unless #697 Delivery absorbs it later.

### User scope (non-negotiable)

- Every ack row is keyed by `user_id`.
- One operator settling a subject does **not** settle it for another.
- Same user, multiple devices: SEEN **is** shared (mobile design already: "Reads are shared across the user's devices by design"). That is intentional — phone glance quiets web for *that* account.
- No implicit "workspace-wide ack" without an explicit product decision (out of scope; default deny).

---

## How each surface maps onto the single fact

```
                    ┌──────────────────────────────────────┐
                    │  Casein.Attention.Acknowledgement    │  ← ONE store (name follows #697)
                    │  seen_through / seen_at              │
                    │  resolved_at (nullable)              │
                    │  subject + user_id + origin_id       │
                    └──────────────────────────────────────┘
                      ▲                ▲                ▲
         mark_seen    │    mark_seen   │    mark_seen   │  (+ mark_resolved where UI has it)
                      │                │                │
           ┌──────────┴───┐   ┌────────┴────┐   ┌───────┴────────┐
           │ Phone card   │   │ Drawer row  │   │ Web session    │
           │ attention_   │   │ mark_read / │   │ focus / click  │
           │ viewed       │   │ resolve     │   │ into window    │
           └──────────────┘   └─────────────┘   └────────────────┘
                      │                │                │
                      ▼                ▼                ▼
           since_viewed.count    unread_count     unseen badge /
           Needs Me pin*         resolved UI      :needs_you chrome**

* Needs Me pin remains domain unresolved? OR NOT resolved_at — see below.
** Section membership stays #697 salience projection; *unseen highlight* is ack.
```

| Path | Write | Read effect elsewhere |
|------|-------|------------------------|
| Phone `attention_viewed` | `mark_seen(user, origin, subject, through_marker)` | Drawer rows for same subject show read; session-rail unseen cleared for bound session/window; badge counts drop |
| Drawer `notifications:mark_read` | `mark_seen` on subject's ack (+ keep/project `notifications.read_at` during bridge) | Phone `since_viewed` quiet; session unseen cleared |
| Drawer `notifications:resolve` | `mark_resolved` (+ project `resolved_at`) | Phone pin releases if pin is ack-gated; subject open=false for this user |
| Web click/focus session window | `mark_seen` on session_window (and card subject if linked) | Phone quiet for that session card; drawer read |
| Domain card handled / observer drop | May set resolved via existing domain path; ack should observe or dual-write so drawer matches | All surfaces |

**SessionDirectory.Attention** itself stays a **salience/section projection** (#697). This issue only adds the **seen** dimension the classifier currently lacks — e.g. VM/badge layer asks `Acknowledgement.seen?(user, subject)` so a still-`:needs_you` session can render without unread noise after ack. Do **not** bake ack into `classify/1` ranking (forbidden: ranking/thresholds are #697).

**Attention.Policy / Delivery:** after #697, Delivery may take `seen?` / `resolved?` as optional inputs so background notify does not re-fire for seen subjects. Threshold numbers stay #697/#699.

---

## Target module shape (phase 2 — attach to #697, do not invent parallel tree)

Align under `Casein.Attention` as #697 lands:

```
lib/casein/attention/acknowledgement.ex     # public API: mark_seen/mark_resolved/get/seen?/open?
lib/casein/attention/acknowledgement/store.ex  # Ecto — ONE table (or evolve one existing)
# Thin facades (keep call sites stable during migration):
lib/casein/mobile/attention_inbox.ex        # mark_viewed → Acknowledgement.mark_seen
lib/casein/notifications.ex                 # mark_read/resolve → Acknowledgement + row projection
lib/casein_web/.../terminal_state.ex        # unseen_quiet_* ← durable ack, not only MapSet
```

**Forbidden outcome:** a third independent table that both cursors and notifications keep writing without a single reader API. Intermediate dual-write is OK only as a **migration bridge** with an end state of one writer API.

### Suggested schema (illustrative — finalize with #697 subject ids)

Option A (preferred if we can migrate cleanly): **generalize** `mobile_attention_cursors` → attention acknowledgements (rename table + add `resolved_at`, generalize `card_id` → `subject_id`, keep `through_transition_id` as seen watermark). Transitions table stays the event log (mobile history / signal log); it is not "read state."

Option B: new `attention_acknowledgements` table; **copy** cursor rows and notification lifecycle timestamps in; leave old columns as generated projections until call sites move; drop dual-write in a fast follow.

Either way: **outcome is fewer stores**, not three permanent ones.

```elixir
# Conceptual row
%Acknowledgement{
  user_id: binary,
  origin_id: binary,
  subject_kind: :card | :session_window | :notification,
  subject_id: binary,
  seen_through: integer | nil,  # transition/signal marker
  seen_at: DateTime.t() | nil,
  resolved_at: DateTime.t() | nil
}
# unique (user_id, origin_id, subject_kind, subject_id)
```

Notifications rows may keep `read_at` / `resolved_at` as **cached projections** updated in the same transaction as Acknowledgement writes, so drawer SQL (`unread_count`) stays cheap without joining during the bridge. Long-term: unread_count reads ack or stays projected — pick one in phase 2 implementation notes; do not leave two independent writers.

---

## Migration plan (highest risk)

A bad migration looks like **every badge going unread at once** — the failure mode this epic exists to prevent.

### Invariants

1. Every existing `mobile_attention_cursors` row becomes a SEEN ack with the same watermark (`through_transition_id`, `viewed_at`).
2. Every `notifications.read_at` / `resolved_at` for a user becomes SEEN / RESOLVED on the best subject key we can derive:
   - Prefer `metadata["attention_key"]` or `metadata["card_id"]` + origin from metadata / default origin.
   - Else `source_type == "mobile_card"` → `source_id` mapped through card key if available.
   - Else session: `workspace_id` + `session_id` session subject.
   - Else notification-id subject (no data loss).
3. When both cursor and notification exist for the same subject:  
   `seen_through = max(cursor, notif-derived)`;  
   `seen_at = max(timestamps)`;  
   `resolved_at = notification.resolved_at` if present.
4. Session-rail ephemeral unseen does **not** invent durable unread on deploy (no rows → treated as unseen only for *new* quiet transitions after connect, same as today's baseline-on-mount behavior).
5. Migration is **additive** first; reversible `down` where practical; never `TRUNCATE` ack tables.
6. **Migration test** (required by issue): seed cursor + notification pairs; run migrate; assert counts and watermarks; assert a cross-surface read path would see quiet. Also assert "no mass unread": count of seen subjects after migrate ≥ count of pre-migrate cursors + distinct read notifications (with documented merge rules).

### Bridge sequence (phase 2)

1. Land schema + `Acknowledgement` API behind facades; dual-write from `mark_viewed` and `mark_read`/`resolve`.
2. Backfill migration (data copy) with test.
3. Switch **readers** (project `since_viewed`, `unread_count`, session unseen) to Acknowledgement.
4. Stop dual-write on old columns or make old columns pure projections.
5. Cross-surface tests green; open PR; stop (do not merge).

---

## Tests (phase 2 acceptance)

Must prove **cross-surface settling**, not per-surface isolation:

| # | Scenario | Assert |
|---|----------|--------|
| 1 | Seed subject with unread transition + notification + quiet session window; `AttentionInbox.mark_viewed` (or channel `attention_viewed`) | `Notifications.unread_count` drops for that subject's rows; session unseen/ack API reports seen for user |
| 2 | `Notifications.mark_read` on mobile-card-sourced row | Phone `project` `since_viewed.count == 0` for same attention_key |
| 3 | `Notifications.resolve` | Drawer resolved; Needs Me / open? false for user where pin is ack-aware; SEEN also set if resolve implies seen |
| 4 | Web `acknowledge_quiet_window` / focus path writing durable ack | Phone + drawer quiet for linked subject |
| 5 | User B never settles when user A acks | B still unread |
| 6 | New transition after SEEN | unread again (watermark) |
| 7 | Migration test | no mass-unread; watermarks preserved |

Pure unit tests on Acknowledgement + one integration test file e.g. `test/casein/attention/acknowledgement_cross_surface_test.exs`.

---

## Relationship to #697 (do not fork vocabulary)

From #697 phase-1 design (`docs/design/attention-model-v1-phase1.md` in the #697 worktree):

- Signal / Salience / Delivery are **not** this issue.
- Read cursors / `since_viewed` are explicitly **acknowledgement (#698), not salience**.
- Delivery may later take ack as input; we expose `seen?` / `resolved?` / `open?` for that — we do not redefine notify bands here.
- Lifecycle pin (`unresolved?`) stays domain-backed; ack RESOLVED composes with it, does not replace ranking.

When implementing, **read #697's landed module names** (`Casein.Attention.Signal` etc.) and put Acknowledgement beside them. Coordinate with pane `%352` if APIs are mid-flight.

---

## Explicit non-goals

- No third permanent read-state product.
- No ranking / threshold / `:quiet` rename (#696/#697/#699).
- No UI redesign of drawer or phone chrome beyond wiring the same fact.
- No workspace-wide or multi-user ack.
- No merge to master from this issue's PR.

---

## Phase 2 implementation order (when unblocked)

1. Confirm #697 branch/API (`git fetch`, read landed `lib/casein/attention/*`, talk to %352 if needed).
2. Branch off #697's branch (or draft PR base = that branch).
3. Implement Acknowledgement store + API; dual-write facades.
4. Data migration + migration test.
5. Point readers (inbox project, notifications unread, session unseen) at ack.
6. Cross-surface tests (table above).
7. `mise exec -- mix test` on targeted files; `mix precommit` when ready.
8. Open PR (draft OK if base is #697); comment URL on #698; **stop**.

---

## Acceptance mapping (#698 checklist)

| Acceptance | Plan |
|------------|------|
| One cross-surface acknowledgement fact | `Casein.Attention.Acknowledgement` + single store; facades only |
| Any path settles the same thing | Shared `mark_seen` / `mark_resolved`; tests 1–4 |
| SEEN vs RESOLVED | Both; moduledoc copies the table above |
| User-scoped | `user_id` on every row; test 5 |
| Migration preserves read state | Bridge + migration test 7 |
| Cross-surface tests | `acknowledgement_cross_surface_test.exs` |
| No third store / no ranking changes / no merge | Forbidden list |
| PR URL on #698 | Phase 2 |

---

## Current status (2026-08-08, phase 2)

- #696 merged as #703. #697 open as PR #720; this branch is rebased onto it.
- Implemented `Casein.Attention.Acknowledgement` (SEEN + RESOLVED) on the
  evolved `mobile_attention_cursors` table (no third store).
- Facades: `AttentionInbox.mark_viewed`, `Notifications.mark_read` /
  `resolve` / `mark_all_read`, web `acknowledge_quiet_window`.
- Backfill helper `backfill_from_notifications/0` + tests for cross-surface
  settling and no mass-unread.
- Open PR against #697 base (or master once #697 lands); do not merge.
