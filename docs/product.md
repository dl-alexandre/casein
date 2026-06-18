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
> **History:** earlier versions of this document described a delegated-execution
> product — local/remote/fleet operating modes, a governed-command plane, and
> runner-claimed assignments. That stack was removed. DevIDE is now a
> single-runtime workspace cockpit: a durable raw terminal over tmux, MCP as
> the agent interface, preview, and an audit/activity feed.
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

**DevIDE is a single-runtime workspace cockpit: a durable terminal over a
server-side runtime, with MCP as the interface coding agents use to drive it.**

The runtime is the engine: it owns durable sessions and survives disconnects.
The browser is the cockpit: the place a human operator sees the workspace,
types into it, and watches what an agent did. Agents are clients of the same
runtime through MCP, not a separate plugin.

The product is the durable, observable workspace session. The editor surface
is a feature of it, not the other way around.

## 2. Thesis

Existing editors are single-machine interaction tools. They optimize for
one human, one keyboard, one local filesystem, one process tree. They
treat durability, server-side state, and agent observability as plugins or
afterthoughts.

Modern software work is no longer single-machine in spirit:

- **durable** — sessions should outlive the operator's network connection
- **agent-assisted** — work is increasingly delegated to coding agents
- **observable** — what an agent did in a terminal, and what it asked for over
  MCP, must be inspectable after the fact

The workspace itself should become **server-resident and observable** — not as
an extension to an editor, but as the substrate the editor lives on top of.
That is the gap DevIDE addresses.

If the runtime is right, the cockpit can be modest. If the runtime is
wrong, no amount of editor polish recovers it.

## 3. Mental model — one runtime, one cockpit

DevIDE is **one product with one runtime**. The browser cockpit and any MCP
agent both attach to the same server-side workspace: the same durable tmux
sessions, the same audit trail.

There is no fleet, no multi-runtime topology, and no separate "remote mode"
product line. A workspace runs where the DevIDE server runs; the operator
reaches it from anywhere over the web, and an agent reaches it over MCP. The
host underneath is an implementation detail (FP-5).

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
- **Not a multi-runtime fleet.** DevIDE coordinates one runtime. There is no
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
By default (`:raw_terminal_everywhere`) raw shell is available in any workspace;
the gate can be reinstated to require a local host plus manual workspace mode.
Either way, the verdict is recorded in the run ledger as a session event.

### 10.3 Agents drive the runtime over MCP  *(FP-10)*

A coding agent is a client of two MCP surfaces: the **terminal MCP**
(`DevIDE.Agents.TerminalTools`) and the **preview MCP**
(`DevIDE.Agents.PreviewTools`). Terminal tools let an agent list sessions,
read a pane's scrollback, and send keys/commands to a `devide_`-prefixed
session — the same actions a human takes from the CLI, with no arbitrary host
shell access. Every mutating MCP call is audited and surfaced in the live
activity feed.

### 10.4 Review-agent runs are narrow  *(FP-1, FP-10)*

`DevIDE.Agents.Run` spawns a fixed, allowlisted `DevIDE.Agents.ReviewCommand`
argv as a local subprocess, keyed one-per-workspace. It cannot run an arbitrary
command, send a prompt, or apply a patch — it only spawns, observes, and
cancels. These runs emit `run.started` and a terminal run event into the
ledger.

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
