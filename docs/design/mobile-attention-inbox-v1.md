# Mobile Attention Inbox v1

Status: accepted implementation contract
Date: 2026-07-28
Owner: `agent/codex/mobile-attention-inbox-v1-20260728`

## Product acceptance contract

The inbox answers, for every projected item:

1. **What needs me?** A stable origin-qualified card identity and semantic state.
2. **Why now?** A deterministic priority band, reason code, short explanation,
   and required decision.
3. **What changed?** A bounded list of meaningful lifecycle transitions strictly
   after the user's durable cursor; raw output and file bodies never participate.
4. **What can I safely do?** Only actions declared by the fresh authoritative
   card. Cached or offline copies expose navigation/activation affordances only.
5. **What happened afterward?** A bounded lifecycle and completion projection
   reports only observed run/check/review/merge/deploy evidence. Missing or
   out-of-order evidence stays explicitly unknown or partial.

### Aggregation and origin rules

- The native client may merge the one live origin snapshot with a bounded cache
  from other paired origins. There remains exactly one active socket.
- Every key is namespaced by stable `origin_id`; identical workspace/card ids on
  two origins cannot collide.
- Inactive-origin items are timestamped, stale/read-only, and cannot dispatch an
  action. Selecting one explicitly activates its trusted saved profile,
  reconnects, refreshes authoritative state, then re-resolves the card.
- Unknown or tampered origins, locators, cards, cursor markers, and action ids
  fail closed. Locators remain navigation data, never authorization.

### Ranking contract

Ranking is server-authored, deterministic, and explainable. Precedence is:

1. human-blocked or approval/clarification waiting;
2. review requested;
3. observed failure;
4. final actionable deployment outcome;
5. completed or ready outcome;
6. active work;
7. informational/offline state.

Within a band, newer meaningful change sorts first, then stable origin-qualified
card id breaks ties. Age and freshness may alter the explanation or a bounded
within-band score but never promote informational churn above a human blocker.

Each card projection includes:

- `attention.priority`: critical/high/normal/low;
- `attention.rank`: bounded integer used only within deterministic precedence;
- `attention.reason_code` and `attention.explanation`;
- `attention.required_decision`, or `null` when no decision is justified;
- `attention.notify`: boolean plus a grouping/dedupe key and explanation.

### Since-last-viewed contract

- The server persists only allowlisted meaningful transition metadata:
  origin/user/card/workspace/task references, semantic state/phase, reason code,
  event action, occurrence time, and a monotonic marker.
- A snapshot returns a bounded transition summary and `through_marker`.
- Marking viewed submits the server-issued `through_marker`. The server verifies
  ownership and origin/card scope, and advances with `max(existing, marker)`.
- An event inserted after the rendered snapshot has a greater marker and is not
  swallowed by the read. Reads are shared across the user's devices by design;
  opening on one device clears the same account/origin/card changes elsewhere.
- A missing cursor means unread from the bounded retained horizon. Retention may
  collapse older changes into an explicit count; it must not invent content.

### Lifecycle and completion contract

The projection folds only allowlisted authoritative events: run start/terminal
outcome, agent blocked/state, gate result, review request/decision, deploy
start/outcome, and explicit completion. Exact merge/deploy SHAs are shown only
when an already-authoritative correlated event supplies them. It:

- tolerates missing and out-of-order events;
- never infers tests, merge, deploy, or success from silence;
- includes exact merge/deploy SHA only when an authoritative event supplies it;
- attaches existing bounded Evidence Handoff data and authenticated PWA links;
- reports unresolved/unknown stages rather than optimistic success.

Correlation is typed and fail-closed. Run events may bind only through an
explicit run/task reference, and agent events only through the exact recorded
tmux session/pane context. Repository-wide gate/deploy events keyed only by a
git SHA remain uncorrelated and therefore unknown at card level until an
authoritative task binding exists; the projection never guesses the sole or
focused card.

### Actions and notification policy

- Existing review decisions and the bounded exact-agent-pane follow-up remain.
- V1 adds only the non-domain viewed/handled cursor operation. Unsupported retry,
  deploy, pause/resume, or command actions escalate to the exact authenticated
  PWA surface.
- Every mutating domain action remains typed, workspace-authorized, idempotent,
  audited, stale-revalidated, and exact-target constrained.
- Push is reserved for true human decisions/blockers and final actionable
  outcomes. It is origin-qualified, grouped/deduped, and contains no message
  body, pane output, credentials, file body, or evidence contents.
- Existing agent-blocked alert delivery is reused while the attention
  projection updates in place, avoiding a second OS notification for one fact.

### Usefulness instrumentation

Only bounded enums, duration buckets, counts, and opaque ids are emitted.
Production events cover attention viewed/handled, action outcome and
time-to-action, PWA/evidence escalation and desktop-required use, stale/offline
recovery, notification opens, and notification dedupe. A dismissed outcome is
allowlisted for a future explicitly declared dismissal surface, but v1 does not
invent a dismiss action or event. Message bodies, terminal output, credentials,
file bodies, and diff contents are forbidden.

## Threat and adversarial matrix

| Threat / race | Required defense | Acceptance evidence |
|---|---|---|
| Cross-origin card-id collision | Namespace all cache, cursor, and action resolution by trusted `origin_id` | Same card id on two origins ranks/renders/reads independently |
| Tampered or unknown origin | Resolve only a stored profile; never connect from payload URL | Tap/action fails without socket switch or mutation |
| Cached/offline mutation | Render cached actions disabled; server still requires live authoritative card | Forged cached action is rejected after refresh |
| Cursor reset race | Advance only to server-issued monotonic marker with `max` semantics | Transition inserted after snapshot remains unread |
| Multi-device read race | Unique user/origin/card cursor with atomic upsert | Concurrent lower/higher markers settle on higher valid marker |
| Forged marker/card scope | Verify marker ownership and exact origin/card before advance | Cross-card/user/origin marker is rejected |
| Ranking tie/non-determinism | Stable precedence, timestamp, origin-qualified id tie-break | Reordered input yields identical order |
| Missing/out-of-order lifecycle | Fold observed evidence only; mark gaps partial/unknown | Deploy-before-merge and terminal-without-start never imply missing success |
| Duplicate action/replay | Existing request-id idempotency and outcome ledger | Same request returns prior outcome without second mutation |
| Pane replacement/role mismatch | Revalidate topology and explicit `agent` role immediately before follow-up | Replacement or operator/verify target is rejected |
| Unauthorized workspace/artifact | Existing workspace auth and containment checks | Foreign workspace/path/artifact omitted or rejected |
| Notification storm | Policy allowlist plus origin/card/reason grouping and bounded dedupe window | Repeated diagnostic events produce no push; repeats group |
| Push privacy leak | Allowlisted metadata projection only | Payload test rejects bodies/output/credentials/evidence text |
| Stale completion | Show authoritative freshness and unresolved stages | Cached completion cannot mark handled or trigger domain action |
| Migration compatibility | Additive tables/indexes; reversible `down`; no card/task identity rewrite | Up/down migration and existing client snapshot tests pass |

## Explicit non-goals

No terminal UI, generic send-keys, arbitrary commands, native editing, full
diff/log/preview viewers, simultaneous live origins, silent failover, agent
launcher, opaque ranking/ML, generalized task database, or mutation of the
user's Devbox operator pane.
