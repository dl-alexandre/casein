# ADR: Herdr as session runtime under MCP (Phase 0)

Status: **PROPOSED — blocked on license ACK**

Parent: [#822](https://github.com/dl-alexandre/casein/issues/822) —
"arch: evaluate Herdr as Terminals.Backend session runtime (replace tmux under MCP)"

Claim evaluated (product direction from #822, verbatim):

> Yes. Herdr is the cleaner replacement. It owns the terminals, persists across
> detach/restart, tracks agent state natively, and exposes a socket/CLI surface
> agents can drive. tmux becomes unnecessary plumbing. Drop tmux; make Herdr
> the session runtime under Casein’s MCP layer.

Sources (do not invent beyond these): issue #822 body; architecture memo
`/tmp/herdr-session-runtime-opinion-memo.md` (2026-08-10); published Herdr tree
checked 2026-08-10; Casein coupling measurements on master.

**Product spike is FORBIDDEN** until a human ACK for the license questions in
§1 is recorded on #822 (or a linked legal note). That includes:
`Backends.Herdr`, mix/cargo/hex dependency on Herdr, install on the dogfood
plane, dual-run, and any default flip.

---

## 1. License / AGPL go-no-go (FIRST — above everything else)

If a proprietary Casein release cannot ship or link Herdr, the conclusion is
**do not adopt** and every engineering section below is moot. Do not bury this.

### What #822 / fleet brief assumed

Herdr published as **AGPL-3.0-or-later** (plus a commercial option). Casein is a
deployed product runtime. Under AGPL, linking or shipping Herdr as the session
engine is a counsel/owner decision, not an engineering preference.

### What the published tree shows tonight (2026-08-10) — fact, not ACK

| Source | Finding |
|--------|---------|
| GitHub `herdrdev/herdr` `license.spdx_id` | `Apache-2.0` |
| `LICENSE` on `master` | Apache License 2.0 text |
| `Cargo.toml` `license =` | `"Apache-2.0"` |
| herdr.dev homepage | `Apache 2.0` / `v0.8.0 · Apache 2.0` |
| `CHANGELOG.md` | **“Relicensed Herdr from AGPL-3.0-or-later to Apache-2.0.”** |

So the **historical** license was AGPL-3.0-or-later; the **current published**
license appears Apache-2.0. That does **not** replace a human ACK. Relicense
history is residual risk (a flip back to AGPL re-opens NO-GO).

### Questions counsel/owner must answer (ACK on #822)

Record yes/no (or commercial-terms pointer) on the issue before any spike:

1. May proprietary/deployed Casein **ship or link** Herdr under the license on
   the pinned Herdr commit/tag we would depend on?
2. If that pin is still or again **AGPL-3.0-or-later**, is that acceptable for
   Casein’s product runtime, or is a **commercial license** required/signed?
3. Who owns re-check on upgrade (SPDX + `LICENSE` + `Cargo.toml` at every Herdr
   bump)?
4. Explicit verdict to record: **GO** (may evaluate/spike under stated terms) or
   **NO-GO** (do not adopt — close engineering track).

### Gate until ACK

| State | Meaning |
|-------|---------|
| **Now** | PROPOSED. No `Backends.Herdr`, no dependency, no install on dogfood, no dual-run. |
| **ACK = GO** | Phase-0 *technical* checklist (§ checklist doc) may run; still no product default. |
| **ACK = NO-GO** | ADR conclusion becomes **do not adopt**; phases 1–7 cancelled. |

**NEED (human):** license ACK — see issue comment on #822.

---

## 2. Backend boundary (candidate backend, not big-bang delete)

Casein already has a product-level session-engine seam:

- `Casein.Terminals.Backend` — **23** callbacks (sessions/windows/panes/input/topology)
- `Casein.Terminals.Backend.SpawnSpec` — backend-owned start instructions
- `:terminal_backend` / `Casein.Terminals.Backend.module/0` — selection
- **Only implementation today:** `Casein.Terminals.Backends.Tmux`

Docs (`docs/tmux_control_plane.md`, behaviour moduledoc) already allow non-tmux
engines (e.g. ConPTY on Windows).

**Layering conclusion (only sound shape of the claim):**

```text
LiveView / API / MCP terminal_*
        → Casein semantic plane (AgentState, AgentLiveness, IssueBinding, …)
        → Casein.Terminals.Backend   (:terminal_backend)
              ├─ Backends.Tmux     (default, dogfood, sole impl)
              └─ Backends.Herdr    (NOT authorized until license ACK + must-prove)
```

Herdr, if ever adopted, is a **flagged optional backend under MCP** — never a
one-shot delete of tmux, never a second agent-facing control plane (raw Herdr
CLI taught beside MCP).

### Coupling (why not big-bang) — verified on master

| Signal | Number |
|--------|--------|
| Files under `lib/` referencing tmux | **279** |
| Scripts that shell out to tmux | **48** |
| `Backend` callbacks | **23** |
| Backend implementations | **Tmux only** |
| `pane_id` references in `lib/` | **2838** |

Deeper than the prior memo’s earlier estimate — strengthens “flagged backend,
not replacement.”

---

## 3. Must-prove list before any dual-run

Nothing here is optional after license GO. Skipping a row is not Phase 1.

| # | Must prove | Notes |
|---|------------|--------|
| **L** | License ACK recorded; pin still GO at spike start | Re-check SPDX/`LICENSE`/`Cargo.toml` |
| **1** | Persistence under OOM / SIGSEGV | vs `ScrollbackArchive` + `SessionOwner` recovery |
| **2** | Socket API completeness vs Casein MCP verb set + 23 Backend callbacks | Explicit won’t-port list signed by owner |
| **3** | systemd **adopts** a running server (MainPID, Restart=) | Not cold-start-only; tmux already fails adoption |
| **4** | Crash forensics / cores + runbook | getcwd-wedge / orphan-socket class |
| **5** | Windows / ConPTY maturity or explicit Unix-only scope | `Backend` exists partly for ConPTY; Herdr Windows is “beta” publicly |
| **6** | Headless PTY factory first-class (no Herdr TUI layout on product path) | Geometry single authority — #748 |
| **7** | Multi-tenant isolation on this shared box | Per-env sockets; no cross-workspace observe |
| **8** | Call-site audit outside `Backend` still on `Tmux`/`TmuxCtl` | Port / drop / reimplement table |
| **9** | **Agent state stays Casein-owned** | `:stalled` derived-only; `:errored` report-only; unknown ≠ quiet (`AgentLiveness`). No dual-truth with Herdr sidebar/heuristics |
| **10** | **Geometry single authority (#748)** | Casein `computeTerminalLayout`; runtime only learns cols/rows |
| **11** | **Dogfood-while-migrating** | Fleet lives in `tmux -L casein` now; cutover must not remove the plane agents need |
| **12** | Fleet-scale soak (≥18 panes class, multi-day dual-run one workspace) | Toy session ≠ acceptance |
| **13** | Compare **fix tmux** vs **replace runtime** on real pains | Socket identity, non-adoptable unit, getcwd, cores, non-idempotent `-A` |

### Three points that decide the architecture (from memo + brief)

1. **Dogfood risk is first-class.** Entire agent fleet is in `tmux -L casein`.
   A cutover removes the control plane the migrating agents need.
2. **“Tracks agent state natively” is the claim’s weakest leg.** Casein already
   separates report-only (`:errored`) from derived-only (`:stalled`, 600s) and
   keeps `{:error, _}` ≠ quiet. Screen-heuristic truth would regress; dual truth
   would flap.
3. **Geometry conflict.** #748 moved layout to Casein (one pure
   `computeTerminalLayout`, six-invariant harness). A TUI multiplexer that owns
   splits fights that directly.

---

## 4. Phased plan (0–7) — each landable and reversible

From the architecture memo. **Do not start at 7.** Default remains tmux through
all phases unless a later ADR flips it. **Phase 0 technical work waits on §1 ACK.**

| Phase | Landable outcome | Reversal |
|-------|------------------|----------|
| **0 — Proof, no product** | License ACK; throwaway install; socket API vs MCP verbs; crash/core/systemd adoption experiments; checklist in repo (this track). **No** `Backends.Herdr`. | Delete throwaway install; no product code. |
| **1 — Adapter spike behind `Backend`** | `Casein.Terminals.Backends.Herdr` implementing callbacks; flag `:terminal_backend`; tests with fake-adapter pattern. No LiveView default. | Flag off → `Backends.Tmux`. |
| **2 — Headless PTY only** | One workspace opt-in: Session/SessionOwner via Herdr PTY **without** Herdr TUI layout. Casein keeps geometry (#748). | Disable workspace flag; drain. |
| **3 — MCP parity matrix** | Golden tests: topology, paste+confirm, shared-worktree guard, issue bind, agent_state overlays, deferred close **or** signed won’t-port list. | Same flag. |
| **4 — Dogfood canary** | One manager + ~2 workers on Herdr backend for a week; spawn path gains backend branch **alongside** tmux. | Respawn workers on tmux. |
| **5 — Ops parity** | Supervising unit that truly adopts; scrollback equivalent; crash runbook; per-env sockets; janitor semantics. | Unit disable; tmux ensure scripts remain. |
| **6 — Default flip (maybe never)** | New sessions default Herdr; tmux read-only for legacy; no “drop” until N days green. | Default back. |
| **7 — Delete tmux (optional, late)** | Remove `TmuxCtl` only after zero prod tmux sessions and scripts no longer call `tmux`. | Restore from git (you will not want to). |

---

## 5. Explicit non-goals

- **Drop tmux this week** (or in this PR / Phase 0).
- **Big-bang “delete all tmux”** in one change.
- **Herdr TUI as Casein layout** — Herdr must not own splits/fit while #748 stands.
- **Collapsing agent state to Herdr sidebar / screen heuristics** — no replacing
  `AgentState` / `AgentLiveness` / `IssueBinding`.
- **Replacing Casein LiveView/MCP** with Herdr UI.
- **Teaching agents a second control plane** (raw Herdr CLI beside MCP).
- **Assuming systemd enable equals adoption** without proof.
- **Treating socket rename pain as solved** by renaming to `herdr.sock`.
- **Product dependency or `Backends.Herdr`** before license ACK on #822.

---

## 6. Agreement with prior memo

**Agree:** disagree with “drop tmux”; conditional on “runtime under MCP”; dogfood
dominant; native state weak vs Casein; geometry conflict; optional backend
tempo; hard do-nots.

**Differ:** memo flagged AGPL as unverified blocker; this ADR records the
published **Apache-2.0 relicense** as fact but **still blocks** on human ACK
(brief hard rule + relicense residual risk). Coupling cites the brief’s verified
numbers (279 / 48 / 23 / 2838). This track ships ADR + checklist only.

---

## 7. References

- https://github.com/dl-alexandre/casein/issues/822
- https://herdr.dev/ · https://github.com/herdrdev/herdr
- `/tmp/herdr-session-runtime-opinion-memo.md`
- `docs/tmux_control_plane.md`
- `docs/design/casein-owns-geometry.md` (#748)
- `docs/subsystems/tmux_crash_recovery.md`
- `docs/decisions/herdr-session-runtime-phase-0-checklist.md` (companion)
- `lib/casein/terminals/backend.ex`
- `lib/casein/terminals/backends/tmux.ex`
- `lib/casein/terminals/agent_state.ex`
- `lib/casein/terminals/agent_liveness.ex`

---

*Phase 0 writeup only — no product code, no Herdr install, no dependency.*
