# Mobile Work Actions v1

Status: implementation audit
Date: 2026-07-28

## Actionability audit

The audit uses only existing bounded dogfood records, action names, counts, and
allowlisted mobile outcome metadata. It does not inspect operator pane content,
terminal output, message bodies, credentials, or file contents.

| Recurring event | Decision needed | Authority | Safe action today | Mobile completes it? | Why desktop/PWA remains | Risk | Observed frequency |
|---|---|---|---|---|---|---|---|
| Run approval requested | Accept, deny, or request a bounded change | Run ledger + fresh review card | Approve, deny, request changes | Yes | Deeper proposal/diff work | Medium | 8 requests / 14 days |
| Exact agent blocker | Answer the agent or direct the next step | Fresh intervention card + exact role-marked pane | One bounded free-text follow-up | Usually; 4/5 recorded attempts succeeded | Composing a precise operational prompt or inspecting full terminal context | Medium | 5 recorded interventions |
| Known follow-up posture | Continue, address review, or ask for a concise blocker summary | Same refreshed intervention target | Only unstructured follow-up | Technically, but unnecessarily high-friction | User must translate a common decision into a prompt | Low/medium | Repeated in dogfood narratives; raw blocked count is intentionally not treated as distinct questions |
| Gate/check failure | Decide whether and how to repair/retry | Gate/run domain | Evidence and exact PWA route | No | No exact allowlisted retry/test-set contract | High | 8 gate failures / 14 days |
| Deploy outcome | Acknowledge, diagnose, or perform a high-risk follow-up | Deploy audit/poller | Evidence and exact PWA route | No mutation by design | Retry/deploy requires full confirmation and authoritative deploy contract | High | Noisy aggregate; not used as a human-decision denominator |
| Completed outcome | Review evidence or return to work | Lifecycle projection + evidence | Open evidence/PWA; shared viewed cursor | Partially | No explicit durable “handled” lifecycle beyond viewed state | Low | Present in soak; aggregate deploy counts are diagnostic-noisy |

### Baseline measures

- Native completion paths cover both currently server-declared decision-card
  families: run review and intervention. The nominal card-family coverage is
  therefore **2/2 (100%)**, but it overstates usefulness because intervention
  offers only a blank text box for common next-step decisions.
- Recorded intervention completion is **4/5 (80%)**. The failure was a safe,
  stale-card rejection during a deploy restart.
- Exact resume succeeded without fallback in **9/10 (90%)** recorded attempts.
- Median time-to-unblock and desktop-required rate are **not recoverable from
  historical data**. Current telemetry stores bounded duration buckets and
  desktop-required outcomes, but the older sample predates those events. V1
  must not manufacture a median.

### V1 action catalog

V1 keeps the existing bounded free-text response and adds server-declared,
revision-bound intents only when the refreshed card has an authoritative
role-marked agent target:

- **Continue task** — ask the existing agent task to proceed.
- **Address review** — ask that exact agent to address the current review and
  report the result.
- **Summarize blocker** — ask for a concise blocker and the decision required.

These are fixed server operations, not client-authored commands. The server
revalidates the origin, card, workspace, session, pane identity, and persisted
`agent` role immediately before a single idempotently claimed delivery. The
result confirms delivery to the exact agent role, not task completion; later
authoritative state remains the source of truth.

After V1, cards with a valid intervention target expose **4 bounded completion
paths instead of 1**, while run-review coverage remains unchanged. Gate retry,
deploy, proposal application, and credential/security actions remain
desktop/PWA-only because no safe authoritative contract exists.
