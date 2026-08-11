# ADR: Herdr as a flagged `Terminals.Backend` (Phase 1 evaluation)

Status: **PROPOSED — phase-1 design only (no product code in this PR)**

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

## 5. Backend callback → Herdr method matrix (design)

`Casein.Terminals.Backend` exposes **23** callbacks. Mapping below is from
published Herdr socket/CLI docs (0.8.0), not from an on-box soak. Every row must
be proven or marked **won't-port** before dual-run.

| # | `Backend` callback | Candidate Herdr API | Phase-1 bar |
|---|--------------------|---------------------|-------------|
| 1 | `session_name/2` | Casein-side naming only (`casein_<ws>_<sid>` → Herdr workspace label / socket name) | Pure Elixir; no Herdr call |
| 2 | `spawn_spec/2` | Ensure server + `workspace.create` / attach instructions for Session/erlexec path | Headless: Casein still owns PTY **consumer**; Herdr owns durable panes |
| 3 | `ensure_session/2` | `workspace.create` or open existing; set cwd | Idempotent; must not clobber fleet tmux |
| 4 | `attach/1` | TBD: stream bytes into Ghostty path **or** Casein remains on separate PTY attach | **Prove** headless byte source; if only TUI-attach exists, spike fails closed |
| 5 | `session_exists?/1` | `workspace.list` / `workspace.get` | |
| 6 | `session_alive?/1` | `ping` + workspace present + server up | |
| 7 | `kill/1` | `workspace.close` (and never `server.stop` on shared host) | Multi-tenant safe |
| 8 | `send_keys/3` | `pane.send_keys` / `pane.send_input` | Key-combo dialect differs from tmux; adapter translates |
| 9 | `capture_recent/3` | `pane.read` `--source recent` | |
| 10 | `capture_scrollback/2` | `pane.read` recent/unwrapped with higher lines | Durability vs `ScrollbackArchive` still Casein-owned |
| 11 | `resize_window/3` | tab/workspace resize if any; else pane-level | Runtime **learns** cols/rows from Casein (#748) |
| 12 | `window_size/1` | layout snapshot / pane area | |
| 13 | `list_session_windows/1` | `tab.list` | |
| 14 | `list_session_panes/1` | `pane.list` | |
| 15 | `session_topology/1` | `session.snapshot` projected to `{windows, panes}` | Overlays stay Casein-side |
| 16 | `new_window/2` | `tab.create` (+ optional root pane command) | |
| 17 | `select_window/2` | `tab.focus` | |
| 18 | `kill_window/2` | `tab.close` | Renumber folklore differs — document |
| 19 | `split_pane/4` | `pane.split` | **Layout authority:** only when Casein requested the split; do not import Herdr layout UI |
| 20 | `select_pane/2` | focus pane | |
| 21 | `kill_pane/2` | `pane.close` | |
| 22 | `resize_pane/4` | `pane.resize` | Amount units differ (ratio vs cells) — translate carefully |
| 23 | `set_pane_role/3` | metadata token / Casein-side only | Prefer **Casein-only** role overlay (`@casein_pane_role` equivalent); do not require Herdr support |

### MCP verb smoke (parity intent, not shipped tests here)

| MCP / control behaviour | Herdr lever | Notes |
|-------------------------|-------------|--------|
| `terminal_topology` | snapshot + Casein overlays | shape stability |
| `terminal_send_keys` / send_command | `pane.send_keys` / `pane.send_input` | `PaneSubmit` confirm stays Casein |
| paste path | `pane.send_text` | Do not depend on tmux paste-buffer |
| `terminal_capture` | `pane.read` | |
| spawn worker window | `tab.create` + run | `scripts/spawn-agent-worker.sh` stays tmux until a **branched** spawn path exists |
| shared-worktree guard | Casein write path | independent of runtime |
| agent wait heuristics | `agent.wait` **input only** | never authority for `:stalled` / `:errored` |

---

## 6. What phase 1 must prove (acceptance for a future adapter PR)

Copied and tightened from the #822 human ACK and phase-0 must-prove list.
Skipping a row is not phase 1 complete.

1. **Socket/CLI coverage** vs the matrix in §5 — explicit won't-port list signed
   by owner for gaps.
2. **Supervision adoption:** start Herdr manually, enable a unit, confirm
   `MainPID` is the *already running* server (tmux known-fail). Cold-start-only
   = relocates the problem.
3. **Persistence** across detach/restart; notes under OOM/SIGSEGV.
4. **Crash forensics:** cores + journal correlation; orphan-socket and
   deleted-cwd classes vs `docs/subsystems/tmux_crash_recovery.md`.
5. **Headless PTY factory:** pure daemon usable with Casein/Ghostty as the only
   UI. If Herdr insists on owning layout/TUI on the product path → **fail** the
   spike for Casein geometry (#748).
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

### Explicit non-proofs (do not claim)

- Fleet-scale soak (≥18 panes, multi-day) — later phase
- Default flip — later ACK
- Windows maturity — out of lane
- "Drop tmux" — never a phase-1 outcome

---

## 7. Suggested implementation shape (next PR only)

Docs-first fence: **this PR ships no `lib/`**. When an adapter PR opens, keep it
thin:

```text
lib/casein/terminals/backends/herdr.ex     # @behaviour Backend
lib/casein/terminals/backends/herdr/       # client, id_map, spawn_spec only
config / runtime env                        # opt-in; default Tmux unchanged
test/casein/terminals/backends/herdr_test.exs  # Fake socket / recorded fixtures
```

Rules for that PR:

- No edits to `lib/casein/terminals/backends/tmux.ex` unless a shared behaviour
  gap is proven (prefer extending `Backend` callbacks in a separate coordinated
  change).
- No install on the dogfood plane from application start; tests use a fake
  transport.
- Feature flag off → every code path identical to today.
- Reversible: delete the module + flag; tmux remains.

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
- [ ] Human/owner reads and marks status **accepted** (or requests edits) on the
      PR / #822
- [ ] Separate issue opened for adapter implementation citing this doc

**Phase 1 design complete ≠ Herdr adopted.** It only authorizes a thin adapter
PR behind a flag after the must-prove experiments have owners and evidence
links.

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
