# Casein — Product

> Canonical articulation of what Casein is, who it is for, what the
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
> **History:** earlier versions of this document described a delegated-execution
> product — local/remote/fleet operating modes, a governed-command plane, and
> runner-claimed assignments. That stack was removed. Casein is now a
> single-runtime workspace cockpit: a durable raw terminal over tmux, MCP as
> the agent interface, preview, and an audit/activity feed.
>
> **Naming compatibility:** Casein is the public product name. Stable
> implementation identifiers remain `DevIDE.*`, `:dev_ide`, and `CASEIN_*`.
>
> Companion docs:
> [`architecture.md`](architecture.md) (system internals + invariants),
> [`glossary.md`](glossary.md) (binding vocabulary),
> [`state_machines.md`](state_machines.md),
> [`terminal.md`](terminal.md) (terminal subsystem),
> [`terminal_mcp.md`](terminal_mcp.md) and [`preview_mcp.md`](preview_mcp.md)
> (the agent-facing MCP surfaces).

---

## 1. Definition

**Casein is a server-authoritative workspace where people and coding agents
work in the same durable session.**

The work runs with the workspace, not with a browser tab. Terminal processes
continue through disconnects; a person reconnects through the cockpit, while a
coding agent attaches through scoped MCP tools. Both clients act on the same
workspace; the runtime records attributable policy decisions, agent tool calls,
and execution outcomes without claiming to log every shell keystroke.

The product is continuity, shared control, and evidence around real software
work. The terminal and browser UI are how clients reach that product; they are
not the authority that keeps it alive.

## 2. Thesis

Software work now routinely outlives the client that started it. A coding agent
may run for an hour, a laptop may sleep, a browser may reload, and a second
person may need to understand the state before taking over. An editor-shaped
client cannot provide continuity if it is also the owner of the process and its
history.

That creates three product requirements:

- **Continuity** — work survives network and client failure without replaying a
  command or reconstructing a session from chat.
- **Shared control** — people and coding agents act as explicit, scoped clients
  of one workspace instead of driving separate hidden environments.
- **Durable evidence** — policy decisions, agent tool calls, and execution
  outcomes remain inspectable after the live moment has passed.

Casein makes the workspace server-authoritative so those properties are the
default, not plugins. tmux remains the authority for live process and
scrollback; workspace records own identity; Policy owns admission; Audit owns
durable evidence. The cockpit can evolve without taking any of those jobs.

## 3. Mental model — one workspace, peer clients, explicit authorities

Think of Casein as a durable workspace with two kinds of peer client:

- a **human client** uses the browser cockpit to see, type, arrange, and review;
- an **agent client** uses scoped MCP tools to inspect and act on the same
  terminal, preview, and artifact surfaces.

Neither client owns the workspace. On every attach or reconnect, the server
authenticates the principal, authorizes present access, and restores the
server-owned view. It never treats cached client state as truth and never
replays a command merely because a connection returned.

“Server-authoritative” does not mean one database reconstructs the world. Each
concern has one named authority: tmux for the live process and scrollback,
WorkspaceSource/records for identity, Policy for admission, and Audit for
durable evidence. The run ledger and agent activity feed are projections over
that evidence, not competing sources of truth.

This remains a **single-runtime product**, not a fleet. A workspace runs where
the Casein server runs; humans reach it over the web and agents over MCP. The
host underneath is an implementation detail (FP-5), not a product mode.

## 4. Product boundary — what the server owns vs. what the client owns

A hard separation. This is the most architecturally important section of
this document.

### The server owns

- **workspace lifecycle** — attach, detach, reattach
- **tmux orchestration** — session creation, pane management, PTY
- **durable sessions** — buffers that outlive the client connection
- **raw-terminal admission** — whether a session may take raw PTY input
- **agent surface** — the MCP terminal and preview tools
- **review-agent runs** — fixed, allowlisted `ReviewCommand` subprocesses
- **telemetry** — audit log, run ledger, agent activity feed
- **filesystem reads** — status, git summary (read-only)
- **operational safety** — path safety, session-name scoping

### The client owns

- **editing UX** — what typing feels like, scrollback behavior
- **layout / composition** — pane arrangement, drawer placement
- **interaction model** — keyboard maps, mouse gestures, shortcuts
- **visualization** — how audit / git / activity state is *rendered*
- **keyboard workflows** — command palette, focus moves, accelerators
- **human interaction** — toasts, prompts, focus management

This separation prevents three failure modes:

1. **Browser Neovim drift** — reimplementing buffer management,
   highlight engines, motion grammars in JavaScript.
2. **Accidental IDE reimplementation** — file trees, LSP integrations,
   tabs, breadcrumbs as primary UI rather than runtime affordances.
3. **Endless UI churn** — every aesthetic study mutating the perceived
   product because the boundary is not nailed down.

If a feature crosses this line — client deciding raw-terminal admission,
server deciding pane layout — that is a smell to investigate before merging.

## 5. Differentiators

What this product offers that single-machine editors do not.

- **durable sessions via tmux** — close the tab, come back, your work is still
  there; reattach replays scrollback from tmux history
- **agents as first-class clients** — coding agents drive the same terminal a
  human uses, through MCP; no separate "AI plugin"
- **server-authoritative terminal** — the server knows the cell grid, so it can
  snapshot a session (HTML/plain/VT) the way a client-only renderer cannot
- **BEAM-native concurrency / runtime model** — the server is OTP; many
  thousands of workspaces and channels are a normal load, not a scaling
  exercise
- **observability built in** — audit, run ledger, and a live agent-activity
  feed are reachable surfaces, not a debug menu
- **workspace-as-runtime** — a workspace is a durable, addressable thing, not a
  directory that happens to be open
- **programmable workflows** — the editor surface is scriptable; the cockpit is
  shaped by the operator, not the vendor

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
- **Not a multi-runtime fleet.** Casein coordinates one runtime. There is no
  scheduler, no cross-host placement, no runner pool.
- **Not an agent framework.** Agents are MCP clients of the runtime, not
  things the runtime defines or schedules.
- **Not a dashboard.** Operational state is reachable, not advertised.

## 7. Architecture narrative

The product is a single stack that meets at the runtime.

```text
UI Client / MCP agent   (cockpit: terminal, layout, visualization / agent tools)
   ↓
Phoenix + LiveView      (channels, terminal control plane, MCP endpoints)
   ↓
Workspace Runtime       (durable sessions, raw-terminal admission, audit)
   ↓
tmux · Ghostty PTY · filesystem · git
```

In the common case, this collapses onto one machine: the browser talks to a
Phoenix process, which talks to tmux on the same kernel. An MCP agent attaches
to the same Phoenix process and drives the same tmux sessions. The boundary
between cockpit and runtime is architectural, not physical.

An SSH-backed terminal adapter is a planned extension (one `Terminals.Adapter`
behaviour), but it does not change the model: still one runtime, still one
authority for what a session may do.

## 8. The user promise

What the cockpit commits to.

1. **Attach from anywhere.** Open the URL, pick a workspace, get a
   terminal.
2. **The environment persists.** Closing the tab does not end the work.
   Reopening picks up where you left off.
3. **Agents share your terminal honestly.** A coding agent works in a paired
   pane through MCP; what it ran is visible to you in the same session and
   recorded in the activity feed.
4. **Operational state is visible.** Audit, run ledger, and agent activity —
   reachable in one place when you want them, out of the way when you don't.

The first two are the everyday experience. The last two are the reasons the
first two stay trustworthy under disconnect and under agent delegation.

## 9. UI contract

### 9.1 Workspace picker

The first screen lists the workspaces the client knows about. The host a
workspace lives on is incidental (FP-5), not a mode selector.

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

An empty rail is not rendered. A missing capability is not mocked.

### 9.4 Audit and activity

Operational events are recorded as time-ordered streams. The UI surfaces them
where they are actionable: review-run events in the Run ledger, live agent MCP
calls in the Agents panel, and the complete per-workspace stream through the
audit API.

### 9.5 Fold / depth-on-demand

The terminal is the primary surface. Anything richer — session metadata, audit
excerpt, agent activity — lives behind a fold the operator pulls open. Closed
by default. The product reveals depth when asked, not at boot.

## 10. Runtime contract

### 10.1 The server owns sessions  *(FP-1, FP-2, FP-8)*

The browser is a viewer. Session lifetime, output buffer, replay state,
and attach/resume semantics are server responsibilities. A client that
goes away does not take session state with it. tmux is the persistence
boundary; it survives BEAM restarts.

### 10.2 The server decides raw-terminal admission  *(FP-1)*

Raw PTY input is admitted only when `Policy.can_use_raw_terminal?/1` allows it.
By default, raw shell requires a local host plus manual workspace mode.
Deployments can explicitly opt into `:raw_terminal_everywhere`, which makes raw
shell available in any workspace/mode/host. Either way, the verdict is recorded
in the run ledger as a session event.

### 10.3 Agents drive the runtime over MCP  *(FP-10)*

A coding agent is a client of three MCP surfaces: the **terminal MCP**
(`DevIDE.Agents.TerminalTools`), the **preview MCP**
(`DevIDE.Agents.PreviewTools`), and the **artifact MCP**
(`DevIDE.Agents.ArtifactTools`). Terminal tools let an agent list sessions,
read a pane's scrollback, and send keys/commands to a `devide_`-prefixed
session — the same actions a human takes from the CLI, with no arbitrary host
shell access. Artifact tools create and iterate isolated previewable worktrees.
Every mutating MCP call is audited and surfaced in the live activity feed.

### 10.4 Review-agent runs are narrow  *(FP-1, FP-10)*

`DevIDE.Agents.Run` spawns a fixed, allowlisted `DevIDE.Agents.ReviewCommand`
argv as a local subprocess, keyed one-per-workspace. It cannot run an arbitrary
command, send a prompt, or apply a patch — it only spawns, observes, and
cancels. These runs emit `run.started` and a terminal run event into the
ledger.

`Agents.Run` itself never gained a write path. A completed run's own
proposal only ever reaches the working tree through the *separate*,
policy-gated `DevIDE.Proposals.AutoApply` watcher — and only when the
workspace has an explicit, time-boxed, human-granted unlock
(`Workspaces.grant_agent_write_unlock/3`) and a deployment-wide kill switch
is on. Absent that unlock, a human reviews and applies the proposal manually
(`DevIDE.ProposalApply`, the Proposals tab — reached via the command
palette per §9.5, not always-visible chrome) — the default, and the only
path when auto-apply is off.

### 10.5 The run ledger  *(FP-1, FP-8, FP-10)*

The canonical operational event stream is the **run ledger**
(`DevIDE.Runs.Ledger`), backed by audit storage. It normalizes two nouns:

| Noun | Meaning |
|------|---------|
| **Session** | Interactive raw-terminal attachment |
| **Run** | Execution lifecycle of a review-agent run |

The ledger event names are `run.session_attached`, `run.session_denied`,
`run.started`, `run.succeeded` / `run.failed` / `run.timed_out`, and the
approval events (`run.approval_requested` / `run.approval_granted` /
`run.approval_denied`). Replay and run-list reads group by `run_id`; the API
and the Run tab consume the same ledger model so UI replay stays aligned with
the audit stream instead of presenting events as isolated facts.

## 11. Capability detection

The UI must not assume features from a hardcoded flag. After connection, the
backend returns a capability descriptor:

```json
{
  "host": "cloud-1.dev",
  "capabilities": {
    "tmux":         true,
    "multi-attach": true,
    "git":          true,
    "audit":        true,
    "workspaces":   ["alpha", "beta", "gamma", "delta"]
  }
}
```

UI rules derived from this:

- The rail elements appear only when their gating capability is `true`.
- The audit/activity surfaces render only the event types the backend produces.
- A surface that the backend cannot honestly back is **hidden, not mocked**.

The rule: **hide rather than mock.** A surface that exists but cannot tell the
truth is a worse signal than no surface at all.

## 12. Demo truth table

A feature is real when these paths work end-to-end. Anything else is a
UI study, not the product.

| #  | Path               | Step                                                     |
|----|--------------------|----------------------------------------------------------|
| 1  | attach             | open URL, pick workspace, terminal appears               |
| 2  | raw input          | type into the terminal, see it land in tmux              |
| 3  | disconnect         | close tab mid-session                                    |
| 4  | resume             | reopen, see buffered scrollback and current state        |
| 5  | multi-pane         | split, each pane an independent tmux session             |
| 6  | agent pane         | apply the agent-pair layout, agent drives its pane via MCP |
| 7  | agent activity     | watch the live MCP activity feed reflect agent calls     |
| 8  | snapshot           | capture a server-authoritative HTML/plain/VT grid        |
| 9  | audit inspect      | inspect run-ledger / agent audit or API feed in order    |
| 10 | review run         | start an allowlisted review-agent run, see it in the ledger |

## 13. Decision rules

When a new feature, UI surface, or runtime change is proposed, walk
this list before saying yes.

1. **If a feature increases execution authority — scrutinize it.**
   Anything that lets a remote client submit argv to an executor, or widens
   raw-terminal admission beyond a server policy decision, is the most
   expensive class of change. It must justify itself against the user promise
   that the server owns what a session may do (§8, §10.2).

2. **If a feature improves visibility — prefer it.**
   Surfaces that make existing behavior more legible (better audit views,
   clearer agent-activity rendering, more honest capability badges) are cheap
   and compounding. Default to yes.

3. **If a feature only imitates an editor — deprioritize it.**
   File trees, LSP integrations, command palettes that duplicate VS Code:
   these pull the product back toward "browser editor," which the architecture
   is not. Build them only when a concrete operator task is blocked without
   them, and even then as cockpit affordances on top of the runtime — never as
   the runtime itself.

4. **If a capability is unavailable — hide it, don't mock it.**
   A surface that lies about its backend erodes the trust the runtime asks the
   operator to extend.

5. **If a feature crosses the §4 product boundary — investigate.**
   Client deciding admission, or server deciding layout, are smells. The
   boundary is what keeps the product coherent.

---

*The editor is the cockpit. The runtime is the engine. The product is
both — sold, designed, and reasoned about as a single thing — but the
order matters. Build the engine first.*
