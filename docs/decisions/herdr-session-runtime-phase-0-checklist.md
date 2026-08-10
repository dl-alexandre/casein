# Phase 0 checklist: Herdr session-runtime proof (no product code)

Companion to [`herdr-session-runtime-phase-0.md`](./herdr-session-runtime-phase-0.md).
Parent: [#822](https://github.com/dl-alexandre/casein/issues/822).

**Rules**

- Markdown checkboxes only. **No** code that links, vendors, or depends on Herdr.
- **No** `Backends.Herdr`, mix deps, or dogfood-plane install until **license ACK**
  on #822.
- Throwaway proof (if ACK = GO) uses a **non-casein user/dir/socket**, never
  `tmux -L casein` displacement.
- Sources: #822 body, `/tmp/herdr-session-runtime-opinion-memo.md` — do not invent
  product claims.

---

## A. License / AGPL go-no-go (blocks everything else)

- [ ] Owner/counsel **ACK recorded on #822** (or linked legal note)
- [ ] ACK answers: may proprietary Casein ship/link Herdr under the pin’s license?
- [ ] If pin is/were AGPL-3.0-or-later: commercial terms required? signed?
- [ ] SPDX id + `LICENSE` + `Cargo.toml` `license =` captured for the **pinned**
      Herdr commit/tag (screenshot or pasted excerpt on #822)
- [ ] Relicense residual risk acknowledged (was AGPL; changelog notes Apache-2.0)
- [ ] Named owner for re-check on every Herdr version bump
- [ ] Verdict on issue: **GO** or **NO-GO**

If **NO-GO**: stop. Do not continue B–F. Close engineering track as do-not-adopt.

If **GO**: continue. Still no product PR until B–F evidence is attached to a
follow-up issue.

---

## B. Throwaway install (only after A = GO)

- [ ] Install method documented (upstream install docs; version/tag pinned)
- [ ] Install location is throwaway (not `/opt/casein`, not fleet home)
- [ ] Binary version recorded (`herdr --version` or equivalent)
- [ ] Default socket path recorded; **custom** socket path set for isolation
- [ ] Confirmed **not** interfering with `tmux -L casein` / fleet sockets
- [ ] Uninstall / wipe steps written and dry-run once

---

## C. Socket API vs Casein MCP / Backend verb set

Map each row to Herdr socket/CLI (or mark **missing** / **won’t port**).

### Backend callbacks (23) — smoke existence only

- [ ] `session_name/2`
- [ ] `spawn_spec/2`
- [ ] `ensure_session/2`
- [ ] `attach/1`
- [ ] `session_exists?/1`
- [ ] `session_alive?/1`
- [ ] `kill/1`
- [ ] `send_keys/3`
- [ ] `capture_recent/3`
- [ ] `capture_scrollback/2`
- [ ] `resize_window/3`
- [ ] `window_size/1`
- [ ] `list_session_windows/1`
- [ ] `list_session_panes/1`
- [ ] `session_topology/1`
- [ ] `new_window/2`
- [ ] `select_window/2`
- [ ] `kill_window/2`
- [ ] `split_pane/4`
- [ ] `select_pane/2`
- [ ] `kill_pane/2`
- [ ] `resize_pane/4`
- [ ] `set_pane_role/3` (or Casein-side role overlay remains sole path)

### MCP-facing behaviours (parity intent)

- [ ] topology shape stable enough for `terminal_topology` overlays
- [ ] paste / send input
- [ ] capture pane / scrollback
- [ ] wait / blocked heuristics **as inputs only** (not truth — see agent state)
- [ ] window spawn + kill (renumber / id stability notes)
- [ ] resize cols/rows from Casein geometry (runtime learns size; does not own layout)
- [ ] Explicit **won’t-port** list drafted for owner signature

---

## D. Crash / supervision / adoption experiment

- [ ] Cold start under a dedicated systemd user/unit (or equivalent)
- [ ] **Adoption test:** start server manually, then enable unit — does
      `MainPID` become the *already running* server? (tmux: known fail)
- [ ] `Restart=` kill -9 loop: process returns; sessions recoverable?
- [ ] OOM or memory pressure simulation: durability notes
- [ ] SIGSEGV / abort (if reproducible): core file with `LimitCORE` ≠ 0
- [ ] Journal / log correlation steps written
- [ ] Orphan socket / dead path class: repro + recovery notes
- [ ] Deleted-cwd / getcwd-wedge class: repro + recovery notes vs tmux runbook

---

## E. Headless, geometry, agent state, tenancy (design proofs)

- [ ] Headless / no-TUI mode confirmed **first-class** (or blocked with evidence)
- [ ] Written commitment: Casein owns geometry (#748); Herdr layout APIs unused
- [ ] Written commitment: Casein owns `AgentState` / `AgentLiveness`
      (`:stalled` derived-only, `:errored` report-only; unknown ≠ quiet)
- [ ] No plan to collapse MCP state to Herdr sidebar heuristics
- [ ] Multi-tenant: two workspaces/sockets on one host cannot see each other’s panes
- [ ] Windows/ConPTY: in-scope with evidence, or explicit Unix-only non-goal for v1

---

## F. Dogfood-while-migrating risk (paper exercise in Phase 0)

- [ ] Inventory: which fleet scripts shell out to `tmux` today (see ADR §2 counts)
- [ ] Written dual-run bridge sketch: one MCP surface, two backends — no second
      operator manual
- [ ] Written failure mode: “Herdr canary bad while agents only speak tmux” →
      rollback steps without stranding managers
- [ ] Confirm Phase 7 (delete tmux) is **not** scheduled from Phase 0

---

## G. Compare alternatives (before any Phase 1 issue)

- [ ] Short note: which #822 pains are cheaper to **fix inside tmux**
      (`ensure-casein-tmux`, cores, socket reaper, adopt-or-kill) vs need a new runtime
- [ ] Owner reads note before authorizing Phase 1

---

## Exit from Phase 0

- [ ] License ACK = GO on #822
- [ ] B–G evidence linked from a **new** follow-up issue (not silently in chat)
- [ ] ADR status updated only by human/owner when moving past PROPOSED
- [ ] Still **no** merge of `Backends.Herdr` until that follow-up’s acceptance bar

**Phase 0 complete ≠ Herdr adopted.** It only unblocks a flagged adapter spike
proposal.
