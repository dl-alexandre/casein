# Codex integration

DevIDE consumes Codex as a structured agent runtime, not as an opaque terminal
program. The tmux pane remains the operator console and fallback; lifecycle,
approvals, history, subagents, and usage come from explicit protocol events.

## Canonical model

```text
Workspace → Runtime → Thread → Turn → Item
```

Every ingress path produces `%Casein.Codex.Event{}` with workspace, runtime,
thread, turn, item, request, transport, sequence, and UTC occurrence fields.
Wire-specific fields stay under payload/metadata.

```text
App Server JSON-RPC ─┐
codex exec JSONL ─────┼→ Protocol normalizer → EventSink
CLI hooks / notify ───┘                         ├→ projection store
                                                ├→ Phoenix PubSub
                                                ├→ semantic Jido signal
                                                ├→ audit ledger (approvals)
                                                └→ telemetry
```

Streaming message deltas are PubSub-only and batched by LiveView at 150 ms.
Lifecycle and item events are retained. Approval requests/resolutions are
durable and audited. Tool payloads are bounded before retention.

## Interactive App Server runtime

`Casein.Codex.Runtime` is the OTP boundary for one worktree, Codex home, and
security context. It supervises:

- `AppServer`: owns the `codex app-server --stdio` Port and JSON-RPC requests.
- `EventRouter`: orders and projects runtime events.
- `ApprovalBroker`: atomically owns pending approval resolution.

Threads, turns, and items are data, not processes. `RuntimeSupervisor` starts
runtime boundaries dynamically. A Port restart preserves the runtime sequence;
call `Runtime.resume_thread/4` with the durable thread id after recovery.

All approval surfaces must call `Runtime.resolve_approval/3`. The broker checks
pending state, claims the request, answers the owning App Server request, records
the outcome, and emits the canonical resolution event. Writing an audit record
without answering the broker is not a valid approval.

## CLI and batch transports

Paired Codex launches receive eight lifecycle hooks plus legacy `notify`. The
staged `casein-codex-notify.sh` posts JSON to:

```text
POST /api/workspaces/:workspace_id/codex/hooks
```

The endpoint accepts only a token scoped to the same workspace. CLI permission
hooks mark the thread as waiting; the local Codex prompt remains authoritative.
Remote approval cards are App Server-only because hooks cannot safely hold a
bidirectional JSON-RPC request open.

`Casein.Codex.ExecRun` runs `codex exec --json` as a cancellable background job.
It uses argv execution, a read-only sandbox by default, `approval_policy="never"`,
bounded stderr/JSONL buffers, the canonical event model, and the existing run
ledger. Workspace-write is available only when an explicit trusted caller asks
for it.

## Operator surfaces

Codex remains a structured runtime, but it does not own a separate cockpit
screen. Its primitives are distributed into the existing operator workflows:

- Notifications contains the actionable approval queue alongside other agent
  permission requests;
- History contains runtime/thread rows, subagent relationships, lifecycle and
  item events, streamed deltas, and token totals;
- Run contains the read-only `codex exec` task launcher and cancellation state;
- the terminal and header show attention-only approval signals that open
  Notifications.

This keeps the protocol boundary provider-specific while the workspace
navigation remains task-oriented. An inactive or collapsed child thread still
cannot hide an approval that requires operator attention.

## Security profiles

The paired launcher resolves the effective mode from the workspace status API
at launch (falling back to the staged mode only when unavailable), then uses
these defaults unless the operator supplies explicit Codex execution policy
arguments:

| Workspace mode | Sandbox | Approval policy |
| --- | --- | --- |
| `review`, `observe`, `locked` | `read-only` | `never` |
| `manual` (default) | `workspace-write` | `on-request` |
| explicit `DEVIDE_CODEX_DEFAULT_YOLO=1` | unrestricted | bypassed |

`shell_environment_policy.exclude` removes `CASEIN_API_TOKEN`,
`CASEIN_ADMIN_API_TOKEN`, and `CASEIN_WORKSPACE_API_TOKENS` from commands run
inside repositories. The Codex process keeps the workspace token so its MCP
client can authenticate.

## MCP annotations

All terminal, preview, artifact, and deferred-search tools emit standard MCP
`annotations` (`readOnlyHint`, `destructiveHint`, `idempotentHint`, and
`openWorldHint`) plus `outputSchema`. These are derived from `McpCtl.Tool`
metadata; add safety semantics there once rather than duplicating them in each
server.

## Capability doctor and schema drift

Run:

```bash
devide agent doctor codex
```

The doctor probes the actual binary instead of assuming a version. It checks
version output, `exec --json`/structured output, App Server schema generation
and hash, hook config parsing, plugin commands, staged hook availability,
bubblewrap isolation, and all DevIDE MCP endpoints.

## First-party plugin

The repo-local marketplace is `priv/codex-marketplace/marketplace.json`. Its
`devide` plugin bundles Terminal/Preview/Artifact MCP, lifecycle hooks, and four
skills:

- safe operator/agent pane pairing;
- operator-visible preview verification;
- durable source-control/deploy workflow;
- explicit worktree handoff.

Dynamic per-workspace endpoints and tokens continue to be injected at launch;
the plugin supplies the portable workflows and stable first-party defaults.
