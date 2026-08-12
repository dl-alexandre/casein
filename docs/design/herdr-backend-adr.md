# ADR: Herdr as a flagged `Terminals.Backend` (Phase 1 evaluation)

Status: **PROPOSED — phase-1 design; surface corrected 2026-08-12 for #896/#901**

Parent: [#822](https://github.com/dl-alexandre/casein/issues/822) —
"arch: evaluate Herdr as Terminals.Backend session runtime (replace tmux under MCP)"

Companion (phase 0):
[`docs/decisions/herdr-session-runtime-phase-0.md`](../decisions/herdr-session-runtime-phase-0.md)
and
[`docs/decisions/herdr-session-runtime-phase-0-checklist.md`](../decisions/herdr-session-runtime-phase-0-checklist.md).

Human license ACK (2026-08-10 on #822): **PROCEED** for a **flagged**
`Backends.Herdr` evaluation / dual-path only. Residual AGPL→Apache-2.0 relicense
risk is accepted **for phase 1 only** and must be restated on every follow-up PR
that touches Herdr. Promotion to default or sole backend requires a **fresh**
human ACK.

**Host posture (2026-08-11+): #822 is SPARE-ONLY.** It does not outrank the
pressure board. Phase-2 adapter work is a multi-day build; do not open a
speculative half-`Backends.Herdr` under pressure. Correct the evaluation surface
first (this doc), then wait for a host GO that budgets the displacement.

### Surface correction (#896 / #901) — read before any adapter PR

PR #857's matrix assumed **`Backend` = 23 callbacks** (pre-alignment). That is
**wrong on master after #901**:

| Fact | Value (master 2026-08-12) |
|------|---------------------------|
| `Backend.required_callbacks/0` length | **50** |
| Source of truth for adapter half | `TmuxCtl.Adapter.behaviour_info(:callbacks)` via `Backend.adapter_callbacks/0` |
| Product-only (not on Adapter) | `session_name/2`, `spawn_spec/2`, `window_size/1` |
| Contract test | `backend_contract_test` — new Adapter fn cannot ship without Backend + Fake |
| Runtime twin | `mcp_self_test` (#860/#871) |

Any Herdr evaluation or spike written against the old 23-row table **understates**
input (`paste_text/3`, `inject/3`, `send_command/3`), topology inventory, window
chrome, zoom/swap/layout, and env/server ops. §5 below is the corrected matrix.

---

## 1. Decision (this phase)

**Do** design and (in a later PR, not this one) implement
`Casein.Terminals.Backends.Herdr` as an **optional** implementation of
`Casein.Terminals.Backend`, selected only when explicitly configured.

**Do not** (phase 1):

- change the default `:terminal_backend` away from `Backends.Tmux`
- delete, freeze, or weaken the live `tmux -L casein` dogfood plane
- teach agents a second control plane (raw Herdr CLI beside MCP)
- collapse Casein `AgentState` / `AgentLiveness` / `IssueBinding` into Herdr
  sidebar / screen-heuristic state
- let Herdr own geometry or splits while #748 stands
  (`docs/design/casein-owns-geometry.md`)
- claim systemd adoption, crash forensics, or fleet soak are proven without
  attached evidence
- touch Windows / ConPTY paths (explicit non-goal for this lane)

Negative results are success criteria: if socket coverage, adoption, headless
PTY, or multi-tenant isolation fails, the spike reports **do not promote** and
leaves tmux default.

---

## 2. Layering (unchanged product shape)

```text
LiveView / API / MCP terminal_*
        → Casein semantic plane
            (AgentState, AgentLiveness, IssueBinding, FleetChrome, NextPrompt, …)
        → Casein.Terminals.Backend   (:terminal_backend)
              ├─ Backends.Tmux     ← DEFAULT, dogfood, sole production path today
              ├─ Backends.Fake     ← tests
              └─ Backends.Herdr    ← OPTIONAL, flag-only, NOT authorized as default
```

Herdr is a **session engine adapter under MCP**, never a replacement product
surface and never a second agent-facing API.

Config intent (sketch only — not shipped in this docs PR):

```elixir
# runtime / env — default remains Tmux
config :casein, :terminal_backend, Casein.Terminals.Backends.Tmux

# opt-in evaluation only (workspace-scoped selection is a later design;
# process-wide Application env is the minimum spike shape)
# CASEIN_TERMINAL_BACKEND=herdr
# config :casein, :terminal_backend, Casein.Terminals.Backends.Herdr
```

`Casein.Terminals.Backend.module/0` already resolves
`Application.get_env(:casein, :terminal_backend) || Backends.Tmux`. Phase 1 must
not invert that default.

---

## 3. License restatement (required on every Herdr PR)

| Fact | Source (checked 2026-08-11) |
|------|-----------------------------|
| Published SPDX | `Apache-2.0` (`herdrdev/herdr` license API + `LICENSE` + README badge) |
| Homepage | herdr.dev — "v0.8.0 · Apache 2.0" |
| History | CHANGELOG: relicensed **from AGPL-3.0-or-later to Apache-2.0** |

Owner ACK on #822 accepts residual flip-back risk **for phase-1 evaluation
only**. Any later phase (dogfood canary, default flip, shipping in release) needs
a **new** written ACK that re-checks SPDX + `LICENSE` + `Cargo.toml` on the
**pinned** Herdr tag/commit.

Pin policy for a future adapter PR:

1. Record exact git tag/commit + `herdr --version` + SPDX triple on the PR.
2. Refuse to start a Herdr server from an unpinned floating `master`.
3. Re-run license table on every bump.

---

## 4. Identity mapping (tmux ↔ Herdr ↔ Casein MCP)

Casein MCP and topology still speak **Casein** ids today (`pane_id` like `%3`,
window `@N`, session `casein_<ws>_<sid>`). Herdr public ids look like
`w1:p1` / `w1:t1` / workspace `w…`.

Phase-1 adapter rule:

| Casein `Backend` concept | Herdr surface (public docs 0.8.0) | Adapter duty |
|--------------------------|-----------------------------------|--------------|
| `session_id` | Herdr **workspace** (or named session socket) | Stable map; prefer one Herdr workspace per Casein session id |
| `window_id` | Herdr **tab** | Map `@N`-shaped Casein ids ↔ `w*:t*` (or opaque stable tokens returned to MCP) |
| `pane_id` | Herdr **pane** (`w1:p1`) | **Must not** leak Herdr ids into fleet scripts that assume tmux `%N` until a deliberate contract change; adapter may keep an internal bijection |
| socket isolation | `HERDR_SOCKET_PATH` / `HERDR_SESSION` / named session sockets under `~/.config/herdr/sessions/<name>/` | Mirror `TmuxServer` labels: per-env sockets (`herdr_casein`, `herdr_dev`, `herdr_test_*`) — **never** default `herdr.sock` on the dogfood host |
| topology | `session.snapshot`, `pane.list`, `tab.list`, `workspace.list` | Project into existing topology map shape expected by `AgentState.enrich_topology/2` et al. |

**Contract freeze for phase 1:** MCP tool schemas stay tmux-shaped. The adapter
translates. Renaming `pane_id` across ~2.8k `lib/` references is **out of
scope**.

---

## 5. Backend callback → Herdr method matrix (design) — **50 callbacks**

`Casein.Terminals.Backend.required_callbacks/0` is **50** entries on master
(post-#901). Mapping is from published Herdr socket/CLI docs (0.8.0) + Casein
ownership rules — **not** from an on-box soak. Every row must be proven,
**Casein-only**, or signed **won't-port** before dual-run.

Bar legend: **P** = must prove on Herdr · **C** = Casein-side only (no Herdr
truth) · **W** = likely won't-port / stub with explicit owner sign-off · **G** =
geometry-sensitive (#748 — runtime learns size, does not own layout).

### 5.1 Product-only (3)

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `session_name/2` | label / socket name only | **C** |
| `spawn_spec/2` | ensure server + workspace create / attach instructions | **P** headless |
| `window_size/1` | layout snapshot / pane area | **G** |

### 5.2 Session lifecycle (7)

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `ensure_session/2` | `workspace.create` / open + cwd | **P** idempotent; never clobber `tmux -L casein` |
| `attach/1` | headless byte source vs TUI-only attach | **P** fail closed if TUI-only |
| `session_exists?/1` | `workspace.list` / `get` | **P** |
| `session_alive?/1` | `ping` + workspace present | **P** |
| `kill/1` | `workspace.close` (**never** host-wide `server.stop`) | **P** multi-tenant |
| `apply_defaults/1` | config / options apply | **P** or **W** |
| `list_sessions/0` | `workspace.list` | **P** |

### 5.3 Input / output (7) — **grew past the old 23-row table**

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `send_keys/3` | `pane.send_keys` / `send_input` | **P** dialect translate |
| `send_command/3` | send + Casein `PaneSubmit` confirm | **P** + **C** submit |
| `paste_text/3` | `pane.send_text` (not tmux paste-buffer) | **P** — #854/#870 class |
| `inject/3` | raw inject path | **P** or **W** |
| `capture_recent/3` | `pane.read` recent | **P** |
| `capture_scrollback/2` | `pane.read` unwrapped / deep | **P**; archive still **C** |
| `tail_lines/2` | read helper | **P** or thin **C** wrapper |

### 5.4 Topology (6)

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `list_session_windows/1` | `tab.list` | **P** |
| `list_session_panes/1` | `pane.list` | **P** |
| `session_topology/1` | `session.snapshot` → Casein shape | **P**; overlays **C** |
| `directory_inventory/0` | global window/pane inventory | **P** or **W** (tmux-directory shaped) |
| `list_windows/0` | cross-session windows | **P** or **W** |
| `list_panes/0` | cross-session panes | **P** or **W** |

### 5.5 Windows (10)

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `new_window/2` | `tab.create` | **P** |
| `select_window/2` | `tab.focus` | **P** |
| `kill_window/2` | `tab.close` | **P** (renumber folklore) |
| `last_window/1` | focus previous tab | **P** or **W** |
| `cycle_window/2` | tab cycle | **P** or **W** |
| `consolidate_sessions/2` | multi-session merge | **W** unless Herdr has equivalent |
| `rename_window/3` | `tab.rename` | **P** |
| `set_session_alias/2` | workspace rename / metadata | **P** or **C** |
| `resize_window/3` | size from Casein | **G** |
| `refresh_client/1` | client refresh | **P** or **W** |

### 5.6 Panes / layout (14) — **geometry conflict zone**

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `split_pane/4` | `pane.split` only when Casein requested | **G** + **P** |
| `select_pane/2` | focus pane | **P** |
| `kill_pane/2` | `pane.close` | **P** |
| `resize_pane/4` | `pane.resize` (ratio vs cells) | **G** |
| `set_pane_role/3` | Casein role overlay preferred | **C** (Herdr metadata optional) |
| `navigate_pane/2` | neighbor / direction | **P** |
| `zoom_pane/2` | `pane.zoom` | **G** / **P** |
| `swap_pane/3` | `pane.swap` | **G** / **P** |
| `ensure_zoomed/3` | zoom on/off | **G** / **P** |
| `kill_other_panes/2` | close siblings | **P** |
| `select_layout/2` | **prefer unused** — Casein owns layout | **G** / **W** |
| `next_layout/1` | **prefer unused** | **G** / **W** |
| `resize_amount_default/0` | constant | **C** |
| `resize_amount_max/0` | constant | **C** |

### 5.7 Environment / server (3)

| Callback | Herdr lever | Bar |
|----------|-------------|-----|
| `set_environment/3` | pane/workspace env on launch / update | **P** |
| `set_environments/2` | batch env | **P** |
| `server_version/0` | `ping` / status protocol version | **P** |

### 5.8 MCP verb smoke (parity intent)

| MCP / control behaviour | Herdr lever | Notes |
|-------------------------|-------------|--------|
| `terminal_topology` | snapshot + Casein overlays | shape stability |
| `terminal_send_keys` / `send_command` | `pane.send_keys` / input | `PaneSubmit` stays Casein |
| `terminal_paste_agent_text` | `paste_text` → `pane.send_text` | restored post-#870; must stay on Backend |
| `terminal_capture` | `pane.read` | |
| spawn worker window | `tab.create` + run | scripts stay tmux until branched spawn |
| shared-worktree guard | Casein write path | independent of runtime |
| `mcp_self_test` | live Backend verbs | runtime twin of contract test |
| agent wait heuristics | `agent.wait` **input only** | never authority for `:stalled` / `:errored` |

---

## 6. What phase 1 must prove (acceptance for a future adapter PR)

Copied and tightened from the #822 human ACK and phase-0 must-prove list.
Skipping a row is not phase 1 complete. **Coverage target is the full §5
50-callback surface**, not the obsolete 23-row table from PR #857.

1. **Socket/CLI coverage** vs §5 — every **P** row green or moved to signed
   **W**/**C**; contract test + `mcp_self_test` green on the Herdr module.
2. **Supervision adoption:** start Herdr manually, enable a unit, confirm
   `MainPID` is the *already running* server (tmux known-fail). Cold-start-only
   = relocates the problem.
3. **Persistence** across detach/restart; notes under OOM/SIGSEGV.
4. **Crash forensics:** cores + journal correlation; orphan-socket and
   deleted-cwd classes vs `docs/subsystems/tmux_crash_recovery.md`.
5. **Headless PTY factory:** pure daemon usable with Casein/Ghostty as the only
   UI. If Herdr insists on owning layout/TUI on the product path → **fail** the
   spike for Casein geometry (#748). `select_layout` / `next_layout` stay **W**
   or unused.
6. **Multi-tenant isolation** on this shared box: per-env sockets; workspace A
   cannot observe workspace B panes.
7. **Agent state ownership:** Casein remains sole authority. Herdr
   `pane.report_agent` / screen detection may be **telemetry inputs** only.
   Discipline preserved: `:errored` report-only; `:stalled` derived-only;
   `{:error, _}` ≠ quiet.
8. **Dogfood non-interference:** spike installs must not displace
   `tmux -L casein` or fleet MCP. Throwaway user/dir/socket only until canary
   phase.
9. **License pin** re-checked on the tag used by the adapter PR (§3).
10. **`paste_text/3` + `send_command/3` + `inject/3`** on the Backend path (the
    #854 outage class must not recur under a second engine).

### Explicit non-proofs (do not claim)

- Fleet-scale soak (≥18 panes, multi-day) — later phase
- Default flip — later ACK
- Windows maturity — out of lane
- "Drop tmux" — never a phase-1 outcome

---

## 6b. Phase-2 cost / SPARE-ONLY scope (2026-08-12)

**Do not start a `Backends.Herdr` product PR from this issue under pressure.**
Host marked #822 spare-only; a half-build would collide with live Backend
contract work and dogfood.

### What phase 2 actually is (after #901)

| Slice | Est. effort | Touches | Displacement risk |
|-------|-------------|---------|-------------------|
| A. Throwaway Herdr install + socket schema dump vs §5 | 0.5–1 d | none in product tree | low — isolated user/dir |
| B. `Backends.Herdr` skeleton implementing all **50** callbacks (many `{:error, :not_implemented}` initially) + Fake/contract green | 2–4 d | `lib/casein/terminals/backends/herdr*.ex`, tests only | medium — Backend/Fake churn if behaviour drifts |
| C. Prove **P** rows for MCP path (paste/send/capture/topology) on one throwaway session | 2–3 d | herdr client + flag | medium |
| D. Headless attach + Ghostty/Session path decision | 2–5 d | Session/attach — **high** if wrong | **high** — dogfood PTY |
| E. Adoption / crash / multi-tenant experiments (paper + unit) | 1–2 d | docs + ops notes | low |
| **Full dual-run canary (old phase 4)** | multi-week | spawn scripts, flag, ops | **fleet-critical** |

**Minimum honest GO for “thin adapter”:** slices A–C behind flag, default Tmux,
no Session/Ghostty cutover, no spawn-script branch, no dogfood workspace. Still
roughly **one focused engineer-week**, not an overnight PR.

### What it would displace on this fleet

- Serial PR gate (~20+ min/run) capacity used by a large test surface.
- Attention on `lib/casein/terminals/backends/**` — already hot (#854/#870/#896/#901).
- Risk of another paste/submit outage class if Herdr input path is rushed.
- Zero user-visible win until dual-run canary (still spare).

### NEED (human) to leave spare and start phase 2

Record on #822 (not in chat only):

1. **Budget:** host accepts ≥1 eng-week for A–C and names what pressure work is
   deferred.
2. **Pin:** Herdr tag/commit + SPDX re-check ACK for phase-2 (phase-1 residual
   does not silently carry forward).
3. **Won't-port pre-sign (optional but saves thrash):** owner OK that
   `consolidate_sessions/2`, `select_layout/2`, `next_layout/1`, and possibly
   directory-wide `list_windows/0` / `list_panes/0` may stay **W** forever.
4. **Attach decision:** headless PTY required for GO; TUI-only Herdr = **NO-GO**
   for Casein product path (#748).

Until those four are written, the correct agent deliverable is **docs/surface
correction only** (this section) — not `Backends.Herdr`.

---

## 7. Suggested implementation shape (only after §6b NEED)

Docs-first fence continues: **surface-correction PRs ship no `lib/`**. When a
host-GO adapter PR opens, keep it thin and **contract-complete**:

```text
lib/casein/terminals/backends/herdr.ex     # @behaviour Backend — all 50 callbacks
lib/casein/terminals/backends/herdr/       # client, id_map, spawn_spec only
config / runtime env                        # opt-in; default Tmux unchanged
test/casein/terminals/backends/herdr_*_test.exs
  # must satisfy Backend.required_callbacks/0 + backend_contract_test pattern
```

Rules for that PR:

- Implement **every** `required_callbacks/0` entry on day one (stubs OK with
  `{:error, :not_implemented}` only where §5 marks **W**, and only with a
  table in the PR body).
- No edits to `lib/casein/terminals/backends/tmux.ex` unless a shared behaviour
  gap is proven (prefer extending `Backend` via Adapter alignment PRs like #901).
- No install on the dogfood plane from application start; tests use a fake
  transport.
- Feature flag off → every code path identical to today.
- Reversible: delete the module + flag; tmux remains.
- Restate license pin (§3); phase-1 residual ACK does not cover shipping.

### Dual-run sketch (phase ≥2, not authorized by this ADR alone)

1. One **non-fleet** workspace sets backend Herdr.
2. MCP still one surface; topology overlays identical.
3. Spawn scripts gain an explicit branch; default branch stays tmux.
4. Rollback = flag off + respawn workers on tmux (no data migration).

---

## 8. Risks carried forward

| Risk | Mitigation in phase 1 |
|------|------------------------|
| Dogfood cutover deadlock | Never default; never stop `tmux -L casein` |
| Socket identity bugs relocate | Casein-owned `HERDR_SOCKET_PATH` labels per env |
| Supervision theater | Adoption test is a hard gate |
| Geometry dual authority | Headless-only; ignore `layout.apply` for product path |
| Semantic state dual truth | Casein overlays only; Herdr state is non-authoritative |
| License flip back to AGPL | Pin + restated ACK every phase |
| Coupling depth (279 lib files / 48 scripts / 2838 `pane_id`) | Adapter translates; no global rename |

---

## 9. Exit criteria for *this* design ADR

- [x] Phase-1 scope fenced: flagged backend, dual-path, not default, not sole
- [x] License residual restated; fresh ACK required to promote
- [x] Callback ↔ Herdr matrix written from public 0.8.0 socket API
- [x] Must-prove list actionable for a follow-up adapter PR
- [x] No product code, no dependency, no dogfood install in this change
- [x] **2026-08-12:** matrix corrected from 23 → **50** callbacks (#896/#901);
      phase-2 cost + SPARE-ONLY NEED listed in §6b
- [ ] Human/owner reads and marks status **accepted** (or requests edits) on the
      PR / #822
- [ ] §6b NEED answered on #822 before any `Backends.Herdr` PR
- [ ] Separate issue opened for adapter implementation citing this doc **after**
      NEED

**Phase 1 design complete ≠ Herdr adopted.** Surface correction ≠ authorization
to build. SPARE-ONLY until §6b NEED is cleared.

---

## 10. References

- https://github.com/dl-alexandre/casein/issues/822
- https://herdr.dev/ · https://herdr.dev/docs/socket-api/ · https://github.com/herdrdev/herdr
- `docs/decisions/herdr-session-runtime-phase-0.md`
- `docs/decisions/herdr-session-runtime-phase-0-checklist.md`
- `docs/tmux_control_plane.md`
- `docs/design/casein-owns-geometry.md`
- `docs/subsystems/tmux_crash_recovery.md`
- `lib/casein/terminals/backend.ex`
- `lib/casein/terminals/backends/{tmux,fake}.ex` (read-only for this lane)
- `lib/casein/terminals/agent_state.ex`
- `lib/casein/terminals/agent_liveness.ex`

---

*Phase-1 architecture writeup only — no `Backends.Herdr` module, no mix dep, no
Herdr install, no default change.*
