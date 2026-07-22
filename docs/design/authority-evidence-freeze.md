# Authority and evidence freeze

> Decision date: 2026-07-21
>
> Status: **direction of record**. Implementation lands in small vertical slices;
> no grand rewrite.

## Thesis

Buzz validates the server-authority model, peer human/agent clients, additive
contracts, and a durable evidence plane. Casein/DevIDE adopts a **universal
evidence envelope** — not a universal run ledger — and keeps **tmux as the
authority for live execution**. Events explain and audit the workspace; they do
not reconstruct or replace it.

## Authority per concern

One server-side authority per concern; **no client authority**.

| Concern | Authority |
|---|---|
| Live process and scrollback | tmux |
| Workspace identity | WorkspaceSource / records |
| Evidence | Audit storage (`Audit.Event`) |
| Admission | Policy |

Do not claim a single database or event stream can reconstruct everything.

## Evidence layering (Audit-first)

| Layer | Role |
|---|---|
| `Audit.Event` | Canonical durable evidence |
| `Runs.Ledger` | Constrained run/session projection over Audit |
| `AgentEvents` | Operational projection (own dedupe, replay, retention, privacy) |

**Invariant:** Audit is the canonical evidence log. Run ledger and agent activity
are typed projections, never independent authorities. Separate tables are fine.
Prevent duplicated facts with event IDs, correlation/causation IDs, and explicit
projection ownership.

## Decision / effect / outcome flow

Transports stay thin. Cross-subsystem workflows have one explicit application-layer
owner:

```text
LiveView / Channel / MCP
        ↓
resolve scope → decide policy → perform effect → append evidence
```

Preferred mutation shape (migrate domain by domain):

```text
execute(scope, action, input)
  → validate scope
  → decide policy
  → record decision
  → perform effect when allowed
  → record outcome
```

Dependencies remain acyclic. Do not put policy, effect, and evidence orchestration
in Phoenix or MCP handlers.

## Reconnect semantics

On reconnect:

1. **Reauthenticate** the principal.
2. **Reauthorize** current access to the workspace/session.
3. **Restore** the server-owned view and scrollback (tmux is authority).
4. **Never** replay commands or accept cached client state as truth.

Historical decisions need not be recomputed. Present access must always be rechecked.

## Explicit non-goals

- No universal run ledger (do not fold every MCP/agent lifecycle event into `run.*`).
- No new MCP protocol version; keep additive tool evolution on existing contracts.
- No premature `casein_core` domain package (mechanism `dev_ide_core` stays as-is).
- No tamper-evidence claim: append-only API ≠ tamper-evident storage. Hash chaining
  or signed checkpoints only after an explicit threat model.

## Vertical slice order

1. **MCP trusted principal attribution** (first implementation slice).
2. Audit envelope v2 (schema version, action, actor, workspace, subject,
   decision/outcome, reason, correlation, causation, timestamp).
3. Shared mutation boundaries (start with terminal admission/input).
4. Complete scope adoption + coverage matrix for mutation paths.
5. Pure policy evaluation (`evaluate(action, facts) → decision`).
6. Integrity (hash chain / signed checkpoints) only if required by threat model.

See [`../architecture.md`](../architecture.md) and
[`../subsystems/audit_activity.md`](../subsystems/audit_activity.md) for the
canonical restatement of these rules.
