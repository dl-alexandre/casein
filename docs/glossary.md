# Product and operational glossary

> Version: v3 (authority + evidence reality)
>
> This document has two layers:
>
> - **§Architectural constraints** (below) — load-bearing terms whose
>   meaning must stay stable across UI, API, telemetry, and docs.
>   Each entry includes a "Must not mean" column. Drift here is not
>   pedantry; it is the slow path to product incoherence.
> - **§Core concepts** onward — the relationships between authority, clients,
>   sessions, policy, and evidence.
>
> **Naming:** Casein is both the public product name and the implementation
> family — `Casein.*`, `:casein`, `CASEIN_*`. The former `DevIDE.*` / `:dev_ide`
> / `DEV_IDE_*` names were migrated; the frozen `DEVIDE_*` env namespace and the
> `X-DevIDE-Caller-Pane` header are deliberate exceptions. See
> [`naming-gate.md`](naming-gate.md).
>
> **History:** delegated-execution terms such as assignment, lease, runner,
> fleet, and governed command described a removed subsystem. They are not part
> of the current product vocabulary.
>
> Cross-references: [`product.md`](product.md) §1–§7 introduces these terms in
> narrative form; [`architecture.md`](architecture.md) states the authority map
> and first principles in this vocabulary.

## Architectural constraints

The following terms are constraints, not suggestions. APIs, telemetry,
UI labels, log lines, and docs must use them as defined here.
If a new feature needs a meaning that is not in this table, add the
term — do not overload an existing one.

| Term | Means | Must not mean |
|---|---|---|
| **Casein** | The public product: a server-authoritative workspace for people and coding agents | A code namespace; a package coordinate; one UI component; one process; the CLI alone |
| **DevIDE** | The compatibility-stable implementation family (`Casein.*`, `:casein`, `CASEIN_*`) beneath Casein | A second product; a requirement that public copy use the old name; authorization for a codebase-wide rename |
| **Server-authoritative** | Each concern has one named server-side authority; clients authenticate, authorize, then observe or request effects | One database reconstructs everything; the browser is trusted state; “the backend decides somehow” |
| **Authority** | The component whose current answer is binding for one concern | Every component that stores a copy; a projection; a transport; a person with an admin title |
| **Runtime** | The server-side execution environment that hosts workspace sessions and the named authorities that govern them | The browser UI; a JavaScript loop; a fleet scheduler; a universal database |
| **Workspace** | The addressable work context: identity, rooted filesystem/git tree, sessions, mode, and evidence scope | An open tab; an arbitrary directory; a host; a bag of project metadata |
| **Cockpit** | The human-facing client: terminal plus workspace controls and views | The execution engine; an authority; anything that decides what may run |
| **Human client** | A person authenticated to a workspace and interacting through the cockpit | An all-powerful operator; an anonymous browser; an agent hidden behind a human identity |
| **Operator** | The human principal currently operating a workspace through the cockpit | A blanket admin role; an agent; the deployment's system administrator by implication |
| **Agent client** | A non-human principal using scoped MCP tools against the same workspace surfaces | The LLM itself; an in-process actor; a chatbot feature; an unsandboxed host shell |
| **Principal** | The authenticated identity requesting an action | A display label; a connection; the actor inferred later from free-form metadata |
| **Actor** | The principal or system component attributed in durable evidence for a decision, effect, or outcome | Whoever happens to own the HTTP connection; an unverified client-supplied string |
| **Transport** | HTTP, LiveView, Channels, MCP, or tmux plumbing that carries a request or state | Policy; identity; authority to execute; a domain workflow owner |
| **Policy decision** | Server-side admission result for an action, with verdict and reason | A UI checkbox; a feature flag; a client-side filter; the effect itself |
| **Effect** | The attempted state change after an allow decision | The decision, request, or evidence record |
| **Outcome** | What actually happened after an attempted effect | What policy predicted; an HTTP status without domain meaning |
| **Evidence** | Durable, attributable facts about decisions, effects, and outcomes | A complete reconstruction of live state; metrics; unstructured debug output |
| **Audit** | The canonical durable evidence store (`Audit.Event`) | A universal run ledger; tmux scrollback; a projection; a claim of tamper evidence |
| **Projection** | A purpose-specific read model derived from canonical evidence, such as Runs.Ledger or AgentEvents | An independent authority; a second canonical log; a full copy of all evidence |
| **Session** | A live, durable PTY and its workspace-scoped state, backed by tmux | An HTTP/websocket connection; a browser tab; a login; a run |
| **Run** | The execution lifecycle of one narrow review-agent command | A raw shell session; an arbitrary command; every MCP call; a browser tab |
| **Raw shell** | Direct session input into a server-side PTY, admitted by Policy | A delegated assignment; a review-agent run; an implicit permission |
| **Attach** | An authorized client connecting to an existing session | Authentication alone; starting a new session; replaying a command |
| **Reconnect** | Reauthenticate, reauthorize present access, and restore the server-owned view after a connection loss | Trust cached client state; reuse stale authorization; rerun prior input |
| **Replay** | Restore terminal state and scrollback from server/tmux history for a client | Re-execute a command; event-source the live process; redo/undo |
| **MCP** | The scoped agent-facing tool interface Casein hosts | The agent loop; a generic HTTP proxy; arbitrary host access; authority by itself |
| **Mode** | A workspace admission-policy level (`:manual`, `:review`, `:agent_write_locked`, `:shared_stage_guarded`) | Network topology; display theme; an AI toggle; identity |
| **Capability** | A runtime-advertised boolean or value that gates an available surface | A permission grant; a user role; a decision; a deployment wish |
| **Host** | The machine on which a runtime happens to execute | A workspace; an account; an organizational unit; a product mode |

The "Must not mean" column is the load-bearing one. If you find these
words being used in their forbidden senses anywhere in the codebase,
docs, or UI — fix the usage, not the glossary.

## Core concepts

### Authority and server-authoritative state

“Server-authoritative” is a rule about ownership, not a claim that one process
or database owns everything. tmux is authoritative for the live process and
scrollback; WorkspaceSource/records for workspace identity; Policy for
admission; Audit for durable evidence. Clients and projections may cache or
render those answers, but may not replace them.

### Principal and actor

A principal is authenticated before authorization. An actor is the attributable
identity written into evidence for what followed. Usually they are the same;
system outcomes may instead name the responsible runtime component. Neither is
derived from a pane label or an untrusted request field.

### Workspace

A workspace is provided by a `Casein.WorkspaceSource`, which owns lifecycle
truth. Casein maintains a redacted, denormalized `WorkspaceRecord` for fast
reads. A workspace scopes filesystem access, sessions, policy, and evidence; it
is not synonymous with its host or with a browser tab.

### Session

A session is a durable server-side PTY plus state, backed by tmux and rendered
through the Ghostty cell grid. A client attaches to it. Losing that client's
HTTP/websocket connection does not end the session, and reconnect restores
state without replaying input.

### Run

A run is the execution lifecycle of one review-agent command
(`Casein.Agents.Run`). Review runs spawn a fixed, allowlisted
`Casein.Agents.ReviewCommand` argv as a local subprocess. They are one
projection over Audit evidence, not the universal unit for terminal or MCP
activity.

### Raw shell

Raw shell is direct PTY input to a session. `Policy.can_use_raw_terminal?/1`
admits it according to deployment and workspace mode. An allow decision permits
the effect; it is not itself terminal input and it does not grant unrelated
agent-write capabilities.

### MCP tools

External coding agents use three workspace-scoped MCP surfaces:

- **Terminal MCP** (`Casein.Agents.TerminalTools`) — list sessions, read pane
  scrollback, send keys/commands to `devide_`-prefixed tmux sessions.
- **Preview MCP** (`Casein.Agents.PreviewTools`) — open/observe/screenshot a
  scoped preview session.
- **Artifact MCP** (`Casein.Agents.ArtifactTools`) — create and iterate on
  isolated artifact worktrees, returning Preview MCP handoff arguments.

Every mutating MCP call is attributed and recorded through
`Casein.Agents.MCPAudit`, then projected into the live activity feed. MCP grants
only the declared tools within the authenticated workspace scope; it is not a
generic host shell or an agent runtime.

### Evidence, Audit, and projections

`Audit.Event` is the canonical durable evidence envelope. It records who acted,
what was requested or decided, the subject and workspace, and the resulting
outcome with correlation/causation context where available. `Runs.Ledger` and
`AgentEvents` are narrower read models over evidence with their own presentation
and retention needs. They do not become authorities merely because they have a
specialized table or UI.

Append-only APIs make evidence stable to read; they do not make the underlying
storage tamper-evident. That claim requires a threat model plus mechanisms such
as signed checkpoints or hash chaining.

### Decision, effect, and outcome

The mutation order is: resolve scope, decide policy, record the decision,
perform an allowed effect, then record the outcome. A denied decision has no
effect. A permitted effect may still fail, and its outcome must say so rather
than rewriting the earlier decision.

### Mode and DB isolation

A workspace mode (`:manual`, `:review`, `:agent_write_locked`, or
`:shared_stage_guarded`) is one input to policy. DB isolation is separately
classified as `:local`, `:ephemeral`, `:shared_stage`, or `:unsafe` by
`IsolationProbe`; shared or unsafe databases force guarded behavior for agent
actors. Neither term describes network topology or client identity.

## Event taxonomy

### Run ledger events

The run ledger (`Casein.Runs.Ledger`) is stored in audit events with
`metadata.ledger == "run"`. The canonical actions are:

| Action | When | Actor | Target |
|---|---|---|---|
| `run.session_attached` | Raw session attached after explicit policy allow | operator | `session` |
| `run.session_denied` | Raw session refused by policy | operator | `session` |
| `run.started` | Review-agent run started | requester | `run` |
| `run.succeeded` | Review-agent run exited successfully | runtime | `run` |
| `run.failed` | Review-agent run exited unsuccessfully | runtime | `run` |
| `run.timed_out` | Review-agent run hit the hard timeout | runtime | `run` |
| `run.approval_requested` | Human approval requested before execution continues | requester/runtime | `run` |
| `run.approval_granted` | Human approval granted, or a review-agent run's proposal auto-applied (`metadata.auto == true`) | reviewer/operator, or `"agent:review"` | `run` |
| `run.approval_denied` | Human approval denied | reviewer/operator | `run` |

### General audit events

Paths outside the run ledger still produce general audit actions:

| Action | When | Actor | Target |
|---|---|---|---|
| `policy.blocked` | Generic policy denial outside the run ledger | original actor | the blocked target |
| agent MCP tool actions | Mutating terminal/preview/artifact MCP calls | agent | session / preview / artifact |
| `proposal.applied` | Human applied a proposal diff via the Proposals tab (`Casein.ProposalApply`) | operator | `proposal` |
| `proposal.apply_blocked` / `proposal.apply_failed` | Proposal apply refused (too large/invalid/conflict) or `git apply` failed | operator | `proposal` |
| `workspace.agent_write_unlock_granted` / `_revoked` | Agent-write unlock granted or revoked | operator | `workspace` |
| `workspace.agent_write_unlock_expired` | Passive expiry sweep revoked a stale unlock | `Casein.Workspaces.AgentWriteUnlockExpirer` | `workspace` |
| `proposals.auto_apply_authorize` | Policy decision for a review-agent run's own auto-apply attempt | `"agent:review"` | `run` |
| `proposals.auto_applied` / `proposals.auto_apply_failed` / `proposals.auto_apply_skipped` | Outcome of a review-agent run's auto-apply attempt (`Casein.Proposals.AutoApply`) | `"agent:review"` | `proposal` / `run` |

## Workspace status payload (summary)

```json
{
  "workspace": {
    "id": "my-app",
    "name": "my-app",
    "status": "running",
    "host_path_present": true,
    "manager_last_seen_at": "2024-..."
  },
  "mode": { "value": "manual", "source": "default" },
  "db_isolation": {
    "isolation": "local",
    "source": "config",
    "redacted_summary": "host=localhost db=dev",
    "detected_at": "2024-..."
  },
  "git": { "available": true, "changed_files": 3, "entries": [...] },
  "recent_runs": [...],
  "recent_audit": [...]
}
```

No credentials, no file contents, no terminal scrollback.

## Redaction keys

The following keys are stripped from outbound payloads:

- `database_url`, `postgres_url`, `pg_url`, `db_url`
- `password`, `pgpassword`, `postgres_password`
- `secret`, `token`, `api_key`, `auth`, `bearer`, `cookie`, `session_id`
- Inside `env` / `environment` arrays: values for keys matching the above are replaced with `[REDACTED]`
