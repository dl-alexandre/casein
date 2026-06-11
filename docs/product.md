# DevIDE — Product

> Canonical articulation of what DevIDE is, who it is for, what the
> server owns, what the client owns, and why the distinction matters.
>
> When a future feature, UI surface, or runtime change is proposed, this
> document is the place to test it. Cite section numbers in tickets so
> debate stays grounded.
>
> Terms used in this document are defined in
> [`glossary.md`](glossary.md) §Architectural constraints; the
> foundational invariants this document is built on live in
> [`architecture.md`](architecture.md) §First principles
> (cited below as FP-1 … FP-10).
>
> Companion docs:
> [`architecture.md`](architecture.md) (system internals + invariants),
> [`glossary.md`](glossary.md) (binding vocabulary),
> [`state_machines.md`](state_machines.md),
> [`jx_devide.md`](jx_devide.md) (JX ↔ DevIDE protocol).

---

## 1. Definition

**DevIDE is a workspace runtime — local, remote, or fleet-coordinated —
with a programmable editor surface as its cockpit.**

The runtime is the engine: it owns sessions, decides what may execute,
records what happened, and survives disconnects. The editor surface is the
cockpit: the place a human operator (or an agent acting on their behalf)
sees the workspace, types into it, and inspects what the runtime did.

The product is the runtime. The editor is a feature of the runtime, not
the other way around.

## 2. Thesis

Existing editors are single-machine interaction tools. They optimize for
one human, one keyboard, one local filesystem, one process tree. They
treat distribution, durability, supervision, and policy as plugins or
afterthoughts.

Modern software work is no longer single-machine. It is:

- **distributed** — code runs on remote workstations, sandboxes, runners
- **durable** — sessions outlive the operator's network connection
- **agent-assisted** — work is increasingly delegated to non-human workers
- **operational** — what got executed, by whom, with what authority, must
  be inspectable after the fact

The workspace itself should become **network-native and orchestrated** —
not as an extension to an editor, but as the substrate the editor lives
on top of. That is the gap DevIDE addresses.

If the runtime is right, the cockpit can be modest. If the runtime is
wrong, no amount of editor polish recovers it.

## 3. Mental model — local / remote / fleet

DevIDE is **one product with three operating modes**. Mode is a property
of the connected backend, not a separate product line.

| Mode    | Meaning                                                                  | Example                                             |
|---------|--------------------------------------------------------------------------|-----------------------------------------------------|
| Local   | Runs on this machine                                                     | DevIDE on your laptop, attached to `~/code/myapp`   |
| Remote  | Runs against a remote workspace/server                                   | DevIDE on `cloud-1.dev`, attached from your laptop  |
| Fleet   | Coordinates many workspaces/agents/sessions across many runtime hosts    | JX scheduling work across `prod-runner-2`, `jx-east-3`, … |

The same client binary runs against all three. The same UI shape adapts.
More-capable backends light up more of the surface; less-capable backends
hide what they cannot honestly fulfill (see §11).

This is the symmetry that makes the product coherent: an operator who
learns DevIDE on their laptop can attach the same client to a
fleet-coordinated runtime on their first day at a job, and the muscle
memory transfers.

## 4. Product boundary — what the server owns vs. what the client owns

A hard separation. This is the most architecturally important section of
this document.

### The server owns

- **workspace lifecycle** — create, attach, detach, suspend, destroy
- **SSH / tmux orchestration** — session creation, pane management, PTY
- **durable sessions** — buffers that outlive the client connection
- **execution authority** — what argv may run, in what mode, by whom
- **agent execution** — assignment dispatch, lease ownership, replay
- **approvals / actions** — proposal lifecycle, mode transitions
- **telemetry** — audit log, event stream, counters
- **filesystem operations** — reads, writes, diffs (gated)
- **indexing / search** — code/symbol/log search across workspaces
- **operational safety** — allowlist enforcement, lease validation
- **multi-workspace coordination** — when in fleet mode, scheduling

### The client owns

- **editing UX** — what typing feels like, scrollback behavior
- **layout / composition** — pane arrangement, drawer placement
- **interaction model** — keyboard maps, mouse gestures, shortcuts
- **visualization** — how audit / lease / git state is *rendered*
- **keyboard workflows** — command palette, focus moves, accelerators
- **human interaction** — toasts, prompts, focus management

This separation prevents three failure modes:

1. **Browser Neovim drift** — reimplementing buffer management,
   highlight engines, motion grammars in JavaScript.
2. **Accidental IDE reimplementation** — file trees, LSP integrations,
   tabs, breadcrumbs as primary UI rather than runtime affordances.
3. **Endless UI churn** — every aesthetic study mutating the perceived
   product because the boundary is not nailed down.

If a feature crosses this line — client deciding execution policy, server
deciding pane layout — that is a smell to investigate before merging.

## 5. Differentiators

What this product offers that single-machine editors do not.

- **durable remote sessions via tmux** — close the tab, come back, your
  work is still there with replay
- **operations-aware orchestration** — every command is a governed event,
  not a fire-and-forget shell call
- **local / remote / fleet symmetry** — the same client, the same UI
  shape, three deployment surfaces
- **BEAM-native concurrency / runtime model** — the server is OTP; many
  thousands of workspaces and channels are a normal load, not a scaling
  exercise
- **agent coordination** — agents are first-class clients of the same
  runtime contract a human uses; no separate "AI plugin"
- **SSH-first architecture** — transport assumes hostile networks,
  drops, and reconnects from day one
- **workspace-as-runtime** — a workspace is a durable, addressable,
  governable thing, not a directory that happens to be open
- **approval / safety / action systems** — refusals, mode transitions,
  and proposals are part of the data model, not bolted on
- **operational visibility** — audit, lease, replay are reachable on
  every surface, not buried in a debug menu
- **programmable workflows** — the editor surface is scriptable; the
  cockpit is shaped by the operator, not the vendor

Notably *not* differentiators — and not what this product competes on:

- syntax highlighting
- tab management
- editor chrome
- generic AI chat
- file-tree polish

Those are table stakes the cockpit may eventually provide; they are not
why anyone would adopt this.

## 6. Non-goals

Explicit, scope-protecting list. Each one is a "no" being made on
purpose.

- **Not competing with full JetBrains language tooling** initially or
  near-term. Refactoring engines, deep static analysis, and language
  servers are out of scope as primary features.
- **Not reimplementing the VS Code extension ecosystem.** No marketplace,
  no extension API surface that mirrors theirs.
- **Not building a browser clone of Neovim.** Modal editing,
  vim-grammar, and motion fidelity are not goals. Use Neovim if that is
  what you want.
- **Not supporting every language equally on day one.** Language support
  emerges as the cockpit needs it; the runtime is language-agnostic.
- **Not becoming a general-purpose cloud IDE immediately.** The product
  is the runtime. Cloud-IDE features (in-browser file editing, hosted
  build pipelines, integrated previews) are downstream of getting the
  runtime contract right.
- **Not an agent framework.** Agents are clients of the runtime, not
  things the runtime defines or schedules.
- **Not a dashboard.** Operational state is reachable, not advertised.

## 7. Architecture narrative

The product is two stacks that meet at the runtime authority.

### Single-runtime stack (Local and Remote modes)

```text
UI Client            (cockpit: terminal, layout, visualization)
   ↓
Control Plane         (per-host runtime authority: DevIDE)
   ↓
Workspace Runtime     (sessions, gates, audit, replay)
   ↓
SSH · tmux · agents · filesystem · git
```

In **Local mode**, all of this collapses onto one machine. The browser
talks to a Phoenix process on `localhost`, which talks to tmux on the
same kernel. The boundary is still there architecturally — it just
happens to be a localhost socket.

In **Remote mode**, the UI client lives on the operator's machine and
the rest of the stack lives elsewhere. The session, the gate, and the
audit live on the server, not the laptop.

### Multi-runtime stack (Fleet mode)

```text
UI Client
   ↓
Fleet Coordinator     (JX: planner, scheduler, intent router)
   ↓
Multiple Workspace Runtimes   (DevIDE × N, each its own authority)
   ↓
SSH · tmux · agents · filesystem · git   (per runtime)
```

Fleet mode does not replace single-runtime mode. It composes it. JX
decides *what should happen and where*; each DevIDE authority still
decides *whether it may execute here*. JX never bypasses a runtime
gate.

The cockpit on top is the same client either way.

## 8. The user promise

What the cockpit commits to, regardless of mode.

1. **Attach from anywhere.** Open the URL, pick a workspace, get a
   terminal.
2. **The environment persists.** Closing the tab does not end the work.
   Reopening picks up where you left off.
3. **Execution is governed.** What runs is what an explicit policy lets
   run. Refusals are visible and recorded.
4. **Operational state is visible.** Audit, leases, denials, recoveries
   — reachable in one place when you want them, out of the way when you
   don't.

The first two are the everyday experience. The last two are the reasons
the first two stay true under load, under disconnect, under delegation.

## 9. UI contract

### 9.1 Connection picker

The first screen. A flat list of hosts the client knows about. Each row
shows host name, latency, and capability badges. Mode (local / remote /
fleet) is **derived from capabilities** (§11), not declared.

### 9.2 Terminal-first workspace

After attach, the default render is **terminal + status line**. Nothing
else is mandatory. Other surfaces appear only when a capability gates
them on.

### 9.3 Capability-gated left rail

A workspace context rail appears when capabilities support it. Order of
appearance, top-down:

| Element            | Capability gate     |
|--------------------|---------------------|
| Host               | always              |
| Workspace tree     | `workspaces: yes`   |
| Git status         | `git: yes`          |
| Active sessions    | `multi-attach: yes` |
| Lease badge        | `lease: yes`        |

An empty rail is not rendered. A missing capability is not mocked.

### 9.4 Audit timeline

Governed events are recorded as a single ordered audit stream: allow,
deny, lease change, mode change, replay, recovery.

The UI surfaces audit where it is actionable: run-scoped events in the
Run ledger, live agent MCP calls in the Agents panel, and the complete
per-workspace stream through the audit API.

### 9.5 Fold / depth-on-demand

The terminal is the primary surface. Anything richer — connection
metadata, lease, audit excerpt — lives behind a fold the operator pulls
open. Closed by default. The product reveals depth when asked, not at
boot.

## 10. Runtime contract

### 10.1 The server owns sessions  *(FP-1, FP-2, FP-8)*

The browser is a viewer. Session lifetime, output buffer, replay state,
and attach/resume semantics are server responsibilities. A client that
goes away does not take session state with it.

### 10.2 DevIDE decides what can execute  *(FP-1, FP-6)*

DevIDE is the **execution authority**. It evaluates argv against the
allowlist, the workspace mode, and any active leases, then either runs
the command (immediate path) or queues it for a runner (durable path).
Every decision — allow or deny — is audited.

### 10.3 JX coordinates intent when present  *(FP-4, FP-7)*

When JX is in the topology, it is the **planner and scheduler**. It
decides *what should happen and where*. It does not bypass DevIDE's
gate.

JX is optional. Local and Remote modes work without it. Fleet mode is
JX's contribution; if JX is absent, fleet capabilities are absent, and
the UI hides them.

### 10.4 Runners stay policy-dumb  *(FP-6)*

Runners are workers that poll for assignments, claim a lease, execute,
and report. They do not interpret policy. The gate is enforced before a
runner is ever offered the work. This keeps runners simple,
replaceable, and safe to scale.

### 10.5 Operational nouns and the run ledger  *(FP-1, FP-6, FP-8)*

The cockpit may show a terminal, but execution vocabulary is intentionally
small. DevIDE normalizes operational execution into four nouns:

| Noun | Meaning |
|------|---------|
| **Session** | Interactive attachment, either governed or raw |
| **Command** | Requested operation intent |
| **Run** | Execution lifecycle of a command |
| **Assignment** | Delegated ownership of a run by a runner |

Derived terms must reduce to those nouns:

- A **governed terminal** submits Commands.
- The terminal **Boundary** converts allowed Commands into Runs.
- A **safe action** is the allowlisted executable shape a Run may use.
- Fleet mode creates Assignments so runners can claim leased ownership.
- A **raw shell** is a trusted Session that bypasses the governed
  command boundary and writes directly to tmux.

The canonical operational event stream is the **run ledger**. It is backed
by audit storage, but its event names and metadata use the four-noun model:
`run.command_requested`, `run.command_denied`, `run.queued`,
`run.started`, terminal run events, approval events,
`run.assignment_claimed`, terminal assignment events, and raw-session
events. Replay and run-list reads group by `run_id` instead of loose audit
action strings; the API exposes this as
`GET /api/workspaces/:id/runs/:run_id`. The Run tab consumes the same ledger
model for its recent-run timeline, keeping UI replay aligned with the API
replay document instead of presenting run audit as isolated facts. A selected
run also exposes artifacts: capped command output for immediate local runs, and
assignment/report references for runner-backed runs. Command history remains
backing storage for local output, but it is no longer a separate primary run
browser in the UI. The product value is this governed command plane:
capability-aware, auditable, replayable, and lease-safe.

## 11. Capability detection

The UI must not assume features from a hardcoded "mode" flag. After
connection, the backend returns a capability descriptor:

```json
{
  "host": "cloud-1.dev",
  "version": "M30",
  "capabilities": {
    "tmux":         true,
    "multi-attach": true,
    "git":          true,
    "policy":       "allowlist",
    "audit":        true,
    "replay":       true,
    "lease":        true,
    "workspaces":   ["alpha", "beta", "gamma", "delta"],
    "scheduler":    "jx"
  }
}
```

UI rules derived from this:

- The picker badge is computed: `local | remote | fleet`, not declared.
- The rail elements appear only when their gating capability is `true`.
- The evidence drawer renders only the event types the backend produces.
- If `replay: false`, the resume-on-reattach UI is hidden — not stubbed.
- If `scheduler: null`, no fleet surfaces appear — not greyed out.

The rule: **hide rather than mock.** A surface that exists but cannot
tell the truth is a worse signal than no surface at all.

## 12. Demo truth table

A feature is real when these paths work end-to-end. Anything else is a
UI study, not the product.

| #  | Path               | Step                                                     | Local | Remote | Fleet |
|----|--------------------|----------------------------------------------------------|:-----:|:------:|:-----:|
| 1  | attach             | open URL, pick host, terminal appears                    |   ✓   |   ✓    |   ✓   |
| 2  | allowed run        | submit governed `mix test`, see safe-action assignment/reports |   ✓   |   ✓    |   ✓   |
| 3  | denied run         | submit governed `rm -rf priv/`, see refusal + audit row  |   ✓   |   ✓    |   ✓   |
| 4  | disconnect         | close tab mid-run                                        |   ✓   |   ✓    |   ✓   |
| 5  | resume             | reopen, see buffered output and current state            |   ✓   |   ✓    |   ✓   |
| 6  | audit inspect      | inspect Run/Agents audit or API feed in event order       |   ✓   |   ✓    |   ✓   |
| 7  | replay             | scrub backward, terminal reconstructs prior state        |   —   |   ✓    |   ✓   |
| 8  | lease visible      | active assignment shows lease holder + remaining time    |   —   |   —    |   ✓   |
| 9  | runner failover    | kill runner, lease expires, work becomes reclaimable     |   —   |   —    |   ✓   |
| 10 | cross-host attach  | switch host in picker, terminal re-attaches elsewhere    |   ✓   |   ✓    |   ✓   |

The "—" cells are not features that should be mocked. They are features
the backend mode genuinely does not provide. The UI hides them (§11).

## 13. Decision rules

When a new feature, UI surface, or runtime change is proposed, walk
this list before saying yes.

1. **If a feature increases execution authority — scrutinize it.**
   Anything that lets more argv run, weakens the gate, or escalates a
   workspace's mode is the most expensive class of change. It must
   justify itself against the user promise of governed execution
   (§8.3).

2. **If a feature improves visibility — prefer it.**
   Surfaces that make existing behavior more legible (better audit
   views, clearer lease state, more honest capability badges) are cheap
   and compounding. Default to yes.

3. **If a feature only imitates an editor — deprioritize it.**
   File trees, LSP integrations, command palettes that duplicate VS
   Code: these pull the product back toward "browser editor," which the
   architecture is not. Build them only when a concrete operator task
   is blocked without them, and even then build them as cockpit
   affordances on top of the runtime — never as the runtime itself.

4. **If fleet behavior is unavailable — hide it, don't mock it.**
   A greyed-out lease badge in local mode lies about the product. An
   absent lease badge tells the truth. The UI's honesty about its
   backend is part of the trust the runtime is asking the operator to
   extend.

5. **If a feature crosses the §4 product boundary — investigate.**
   Client deciding policy, or server deciding layout, are smells. The
   boundary is what keeps the product coherent across local, remote,
   and fleet modes. Don't cross it casually.

---

*The editor is the cockpit. The runtime is the engine. The product is
both — sold, designed, and reasoned about as a single thing — but the
order matters. Build the engine first.*
