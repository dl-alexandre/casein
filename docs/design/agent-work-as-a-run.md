# Agent work as a Run

> **Success criterion.** A supervisor can answer *"what is this agent doing, and did it
> finish?"* from the ledger, without grepping tool-call rows.

## Ground truth first

Three facts, because a previous pass at this problem was built on a wrong premise and
proposed rebuilding a verb that was deliberately removed.

**Non-interactive `run:start` is retired.** The handler in
`CaseinWeb.WorkspaceLive.Show.RunEvents` routes `interactive_agent?/1` to
`launch_interactive_agent/2` and answers everything else with a flash: *"Batch command
runs were retired — open a raw terminal to run commands directly."* There is no human
"start a batch run" path for an agent path to diverge from. Both humans and agents put
commands into a PTY; humans by typing (FP-1 — the browser is never an argv source),
agents through `send_command` with an `actor_id`.

**MCP calls are audited, at the transport layer.** `Casein.Agents.MCPAudit.record_terminal/4`
is called from `CaseinWeb.Api.{TerminalMcp, PreviewMcp, ArtifactMcp}` — per tool
invocation, not per tool module. Agent work is not unaudited.

**The ledger is alive and fed at the boundary.** `Casein.Runs.Ledger` is the canonical
event ledger for operational execution, backed by `Casein.Audit`, owning two nouns —
**Session** (interactive raw terminal attachment) and **Run** (command execution
lifecycle). Its writers are `policy.ex`, `terminals/boundary.ex`, `codex/exec_run.ex`,
`mobile/actions.ex`, and `export/workspace_status.ex`.

## The problem

Work is recorded at **tool-call altitude**. Supervision needs **lifecycle altitude**.

An agent that sends twenty `send_command` calls produces twenty MCP audit rows and
**zero Runs**. Nothing converts "the agent ran the test suite" into a Run with a start,
an end, and an outcome. The supervision story does not fail because work is invisible —
it fails because the visible thing is at the wrong altitude to answer the question a
supervisor is actually asking.

This is the same shape as the attention finding (see the epic for
`Casein.Attention`): the signal exists, and nothing lifts it.

### Explicit non-goals

- Do **not** re-open retired non-interactive `run:start` so agents can use it.
- Do **not** treat MCP transport audit as the fix. It stays as the fine-grained stream;
  Runs bracket it, they do not replace it.
- Do **not** add a second "agent activity" store beside `Casein.Runs.Ledger`.
- Do **not** re-derive argv-from-browser, and do **not** make every keystroke a Run.

## The two seams that already half-do this

### 1. `codex/exec_run.ex` — the working template

One runtime already brackets execution in ledger vocabulary:

```
run_id = Keyword.get_lazy(opts, :run_id, &Ledger.new_run_id/0)   # :43
Ledger.run_started(%{...})                                        # :75
Ledger.run_finished(status, %{...})                               # :324
```

That is the whole pattern. The design question is not *how* to write a Run — it is what
generalizes: the *idea* of bracketing, not the Codex-specific path.

### 2. `terminal_report_agent_state` — the unused lifecycle signal

`Casein.Terminals.AgentState` already carries
`:working | :blocked | :done | :idle | :errored | :stalled | :unknown`, split by who may
claim them. `:blocked`, `:done`, and `:errored` are **report-only** — the title heuristic
can never produce them, because `ready` means "ready *or awaiting input*" and treating it
as `done` renders a blocked permission prompt as success.

**`agent_state.ex` contains zero references to `Ledger`.** The only ledger writer under
`terminals/` is `boundary.ex`, which records session attachment. So the one signal in the
system that already means *"I started / I am stuck / I finished"* never becomes a ledger
event.

This is the best altitude lift available: it needs no new human verb, no new agent verb,
and no change to how agents work. It converts an existing report into an existing noun.

## Ledger vocabulary available

`Casein.Runs.Ledger` already exposes what a Run needs:

| Function | Use |
|---|---|
| `new_run_id/0` | identity |
| `run_started/1` | open |
| `run_finished/2` (status, attrs) | close, with outcome |
| `approval_requested/1`, `approval_granted/1`, `approval_denied/1` | the blocked-on-a-human case |
| `raw_session_attached/2` | the Session noun |
| `recent_runs_for/2`, `timeline_for/2` | the supervisor's read |

Note `approval_*` already exists. An agent blocked on a permission prompt is not a new
concept needing invention — it is `approval_requested` that nothing currently emits from
the agent path.

## Decisions this design must force

These are the open questions. Each needs an answer before implementation, and the answers
interact.

### When does a Run open?

| Candidate | For | Against |
|---|---|---|
| First `send_command` after idle | No agent cooperation needed | Bursty; a stray command opens a Run |
| First `:working` report | Uses the existing lifecycle signal; matches "agent started work" | Runtimes differ in what they report unprompted — grok and opencode report nothing without being asked |
| Explicit "begin work" tool | Precise, intentional | A new agent verb, and unreported work becomes invisible |
| Issue claim / `terminal_bind_issue` | Aligns Run with the unit of work a supervisor cares about | Only covers claimed queue work, not ad-hoc |

**Recommendation:** `:working` as the primary open, with claim-binding as the identity
hint when present (below). Falling back to first-`send_command` for runtimes that report
nothing keeps coverage honest rather than silently excluding grok and opencode.

### When does a Run close?

`:done` and `:errored` are the clean closes. The hard cases are the ones that produce no
report at all:

- **`:blocked`** — not a close. This is `approval_requested`, and the Run stays open. A
  supervisor asking "what is this agent doing" should see *blocked*, not *finished*.
- **`:stalled` / wedged** — the state exists precisely because a frozen spinner reads as
  `:working`. A Run that never closes is worse than one closed wrongly, so this needs a
  timeout close with a distinct status, not silence.
- **Human interrupt / pane death** — pane close should close the open Run. `terminal_bind_issue`
  already clears on pane close; the same lifecycle hook applies.
- **Agent-write unlock revoked** — a policy change mid-Run. Worth deciding whether this
  closes the Run or annotates it.

### What is a Run's identity?

One Run per **claim/issue**, per **pane session**, or per **burst**?

- Per issue is the most useful to a supervisor and matches the queue's unit of work, but
  does not cover ad-hoc work.
- Per pane session is the most mechanical and always available.
- Per burst needs a definition of burst, which is where this gets arbitrary.

**Recommendation:** identity is per pane session, with an optional issue binding carried
as an attribute. That gives every Run an identity while letting the supervisor's view
group by issue when one exists.

### Who is the actor?

`actor_id` (already a `send_command` parameter, documented as *"who is sending, for audit
attribution"*) plus the pane id, plus the optional issue binding. All three already exist;
none needs inventing.

## Relation to attention (`Casein.Attention` epic)

A Run is the natural thing for salience to key off. "Run failed" and "Run blocked waiting
on you" are lifecycle facts, not UI states — which is exactly the signal layer that epic
proposes. Without Runs, attention has to infer agent status from pane titles and
heuristics; with them, it reads a ledger event.

This makes the two pieces of work mutually reinforcing rather than sequential: Runs give
attention something durable to point at, and attention gives Runs a consumer.

## Relation to `workspace_digest`

The orientation read should then **include open Runs**, alongside the risk/salience field
it already carries. That is an extension of an existing cold read — not a new orientation
noun, and not a second store.

## What this is not

A Run is a *lifecycle bracket over work that is already happening and already audited*. It
adds no gate, no permission, and no new path for an agent to execute anything. Policy
continues to be evaluated at the gate on every call; nothing here caches or grants
authority.

## Follow-on

A second, smaller page covers **snapshot consolidation** — `preview/screenshot`,
`artifact/snapshot`, and the human `action:snapshot` / `snapshot_all` / `ghostty:snapshot`
are three implementations of one shared verb across both surfaces. It is the first
candidate for "one action id, one gate, three backends," and it is easier to reason about
once Runs exist.
