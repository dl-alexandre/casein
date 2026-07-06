# DevIDE — Crucial Improvements

> Prioritized list of improvements that directly threaten core user promises
> (durable sessions, server-authoritative admission/policy/audit, MCP scoping
> for agents, recovery after disconnect/restart) or block repeatable daily
> operator/agent dogfood use.
>
> **Generated:** 2026-06-23 · **Scope:** committed docs + `lib/` + `scripts/` +
> verification runs on a clean working tree. Not an implementation plan.
>
> **Analysis deliverable (this goal):** the commit that introduced this file
> adds **only** `docs/crucial_improvements.md`:
> `DOCS_SHA=$(git log -1 --format=%H -- docs/crucial_improvements.md)` then
> `git show "$DOCS_SHA" --stat`. That commit is analysis-only; it does **not**
> implement any listed improvement.
>
> **Branch context (not part of this deliverable):** parent `4e7b683` carries
> `scripts/deploy-poller.sh` self-update (pre-existing branch work). Grandparent
> `e3690ce` carries agent-worktree session support. Those commits predate this
> analysis file and are cited only as source material where relevant (e.g.
> Deploy P1 poller trust model).
>
> **Reproduce verification** (must pass before trusting the snapshot below).
> Use a **detached worktree** at the docs commit so concurrent editors in the
> main checkout cannot pollute the run (observed on shared devbox):

```bash
CODE_SHA=$(git log -1 --format=%H -- docs/crucial_improvements.md)^
VERIFY=/tmp/devide-verify-$$
git worktree add --detach "$VERIFY" "$CODE_SHA"
cd "$VERIFY"
mise exec -- mix deps.get    # first run only
bash scripts/pre-push-check.sh    # expect exit 0
bash scripts/hardening-audit.sh   # expect exit 0
git grep -n "TODO\|FIXME\|not_implemented\|deferred" -- lib/ docs/ scripts/ assets/ \
  | grep -v crucial_improvements.md   # expect 9 hits at CODE_SHA (9 without this file)
cd - && git worktree remove "$VERIFY"
```

> **Reproduce the analysis itself:** read the cited sources at `$DOCS_SHA`, plus
> `git log --oneline -20` for branch context.

## Verification snapshot (code tree `4e7b683`, isolated worktree)

Pre-push and hardening exercise the **code tree** the analysis read. The docs
commit adds only this markdown file; its parent `4e7b683` is the code baseline.
Captured in detached worktree at `4e7b683` (main checkout untouched):

```bash
CODE_SHA=$(git log -1 --format=%H -- docs/crucial_improvements.md)^
# → 4e7b683
```

Logs captured at analysis time in a local scratch path (no longer present).

| Check | Command | Result | Evidence |
|-------|---------|--------|----------|
| Pre-push gate | `bash scripts/pre-push-check.sh` | **PASS** (exit 0) | `{SCRATCH}/precommit.log` — 1272 tests, 71.22% coverage gate |
| Hardening audit | `bash scripts/hardening-audit.sh` | **PASS** (exit 0) | `{SCRATCH}/hardening.log` — 62 hardening-focused tests |
| Marker scan | `git grep` (reproduce block) | **9 hits** | `{SCRATCH}/marker-scan.log` |

Pre-push passes on code tree `4e7b683`. Deploy items below describe structural
risks (poller trust model, coordination), not a current red build.

---

## Freshness refresh (2026-06-26)

> **This doc was committed as a pre-implementation snapshot.** The commit that
> added it (`f24f78d`, 2026-06-24) post-dates `9b75d9c` *"Implement top-five
> crucial improvements for DevIDE trust"* (2026-06-23), which **already shipped
> four of the five P1-class items below**. Verdicts here were produced by reading
> current `lib/`, `scripts/`, and `config/` plus `git log`, not by re-running the
> suite. **Only the P1 items were re-verified**; every item without a
> `Status (2026-06-26)` row remains at the original 2026-06-23 snapshot and is
> *unconfirmed*, not implicitly still-open.

| Item | Status (2026-06-26) | One-line |
|------|---------------------|----------|
| Safety P1 — Loops bypass | 🗑️ **REMOVED** | Subsystem deleted 2026-06-26 — was dormant (no caller/UI/MCP/generator); the risk no longer exists |
| Safety P2 — raw terminal default | ✅ **CLOSED** | Raw terminal now defaults to local host + manual mode; prod raw-everywhere requires explicit env opt-in |
| Safety P4 — global token default | ✅ **CLOSED** | Pairing emits a workspace-scoped token by default + regression test |
| Durability P1 — TmuxJanitor idle GC | 🟡 **SMALLER** | Default is now disabled; "prod default 600s" was factually wrong |
| Deploy P1 — poller skips tests | ✅ **CLOSED** | Poller now re-runs the full pre-push gate and aborts on failure |

**Net:** of the doc's five "do this week" items, the remaining high-value
default-safety fix (**Safety P2**) is now closed as of 2026-06-29. The residual
items below are follow-up product decisions or opt-in hardening, not red
default behavior from this snapshot.

---

## Safety & Policy

Items where server authority, audit, or admission gates are weakened or absent.

### P1 — Loops subsystem bypasses Policy and audit (self-modifying code risk)

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide/loops/` (`Driver`, `Sandbox.Git`, `Runner`); absent from `docs/product.md`, `docs/architecture.md` |
| **Gap** | `DevIDE.Loops.Sandbox.Git` creates disposable worktrees, `git apply`s LLM-generated diffs, and runs `mix compile` + `mix test` with **no** `DevIDE.Policy` gate, **no** `Audit.emit_decision/2`, and **no** run-ledger event. A configured generator (`config :dev_ide, DevIDE.Loops, generator: …`) can mutate and execute code off the request path via `Loops.Runner.start/2`. |
| **Invariant** | **FP-1** (execution authority server-side, recorded), **FP-10** (reviewable evidence), product §13 rule 1 |
| **Verify** | `test/dev_ide/loops/driver_test.exs` exercises stubs only; grep `lib/dev_ide/loops/` for `Policy` / `Audit` → zero hits |
| **Rationale** | Highest leverage safety gap: an unaudited execution path on a product that sells server-authoritative admission. Either wire Loops through Policy + audit + allowlist, or gate boot behind an explicit experimental flag with UI hidden per product §11. |
| **Status (2026-06-26)** | 🗑️ **REMOVED — risk eliminated, not mitigated.** The entire Loops subsystem was deleted: `lib/dev_ide/loops/`, `lib/dev_ide/loops.ex`, its tests, `test/support/loops_stub_seams.ex`, `Policy.can_run_loop?/1`, and the `.claude/workflows/agent-loop-engineering-prototype.js` harness; the `loop_runs`/`loop_attempts` tables are dropped by migration `20260626120000_drop_loop_tables` (reversible `down/0`). It was dormant — disabled by default, no generator configured, **zero callers**, no web/MCP surface — so removing it has no product impact. The self-modifying-code execution path no longer exists. (Brief history: a fail-closed Policy+Audit gate had been added `9b75d9c` and ledger visibility on 2026-06-26, both moot now.) The anti-gaming design (frozen target + held-out suite + diff-derived `touched_test_files`/`added_rescue` signals) is worth remembering if autonomous code-fixing is ever revived. |

### P2 — `:raw_terminal_everywhere` defaults to permissive admission

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide/policy.ex` (`can_use_raw_terminal?/1`), `docs/product.md` §10.2, `docs/architecture.md` config table (`:raw_terminal_everywhere` default `false`) |
| **Gap** | Closed 2026-06-29. Before the fix, raw PTY input was allowed in **any** workspace, mode, and host without `Policy` recording a mode-gated deny path in production-like configs. The stricter gate (local host + `:manual` mode) was opt-in via `raw_terminal_everywhere: false`. |
| **Invariant** | **FP-1**, product §10.2, product §13 rule 1 |
| **Verify** | `test/dev_ide/terminals/mode_policy_test.exs`, `test/dev_ide_web/channels/terminal_channel_test.exs` (gate behavior when flag disabled) |
| **Rationale** | Shared devbox / multi-tenant use needs the gate **on** by default; permissive default is acceptable for single-user local dev only and should be explicit in prod `runtime.exs`. |
| **Status (2026-06-29)** | ✅ **CLOSED.** `Policy.can_use_raw_terminal?/1` and `Terminals.ModePolicy.raw_terminal_allowed?/2` now default to local host + `:manual` workspace mode. `config/runtime.exs` exposes `DEV_IDE_RAW_TERMINAL_EVERYWHERE=1|true|yes` as the explicit prod opt-in for raw-everywhere. Regression coverage lives in `test/dev_ide/policy_test.exs`, `test/dev_ide/terminals/boundary_test.exs`, and `test/dev_ide/terminals/mode_policy_test.exs`. |
| **Addendum (2026-07-02)** | The mode-gate fix above didn't fully close the door: `DevIDE.Policy.WorkspaceMode`'s default fallback was still `:review`, not `:manual` — so a workspace with no persisted/config-pinned mode silently landed in `:review` and raw terminal (and split-screen) stayed unreachable with zero user-facing feedback (`do_split/2` in `show.ex` just returned `{:noreply, socket}` on deny). Fixed by flipping the default to `:manual` (`lib/dev_ide/policy/workspace_mode.ex`). |

### P3 — Agent write and proposal apply permanently denied

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide/policy.ex` (`:not_implemented`, `:agent_write_locked`), `docs/state_machines.md` mode table, `docs/architecture.md` authority map |
| **Gap** | `can_apply_proposal?/1` always returns `:not_implemented`; `can_enable_agent_write?/1` always denies. UI may surface locked affordances with no reviewed unlock flow (`docs/hardening.md` §Permissions). |
| **Invariant** | Product §8 promise 3 ("agents share your terminal honestly") is partially met via MCP raw typing, but **governed agent write** (patch application with policy) is explicitly unimplemented |
| **Verify** | `test/dev_ide/policy_test.exs` ("can_apply_proposal? is always denied"), `test/dev_ide/audit_test.exs` |
| **Rationale** | Not a bug — intentional M10 contract — but **crucial** because daily agent dogfood eventually needs either (a) a reviewed unlock flow or (b) honest UI hiding of write/proposal surfaces per product §11 / §13 rule 4. |
| **Status (2026-07-02)** | ✅ **CLOSED — option (a), the reviewed unlock flow.** `can_apply_proposal?/1` is real logic (operator + `:manual` mode + not isolation-blocked), backing a new `DevIDE.ProposalApply` write path (shells to `git apply`, atomic across a multi-file patch) and a Proposals tab in the LiveView — the read-only `DevIDE.Proposals` discover/parse/analyze modules were deliberately left untouched (`test/dev_ide/proposals_no_apply_test.exs` rewritten, not deleted, to assert that boundary). `can_enable_agent_write?/1` is real logic too: `:manual` mode plus an explicit, time-boxed, human-granted unlock (`Workspaces.grant_agent_write_unlock/3`, revocable with no mode/isolation gate — the kill switch), backing `DevIDE.Proposals.AutoApply`, which polls a completed review-agent run (`Agents.Run.state/1`, not `subscribe/1` — that's single-subscriber) and auto-applies only a `:clean`-risk, non-`test/`-touching proposal, gated again by a deployment-wide config kill switch (default off). The anti-gaming content veto is a direct, deliberate port of the deleted `Loops` subsystem's `analyze_diff/1` signal (see `docs/crucial_improvements.md` Safety & Policy P1) — this is the informed revival that removal's rationale anticipated, with `Policy` + `Audit` + run-ledger coverage on every branch from day one, unlike the original. `DevIDE.Agents.Run` itself still cannot run an arbitrary command, send a prompt, or apply a patch directly — the write path is entirely in the new, separate modules. **Residual:** the allowlist has no real `output_kind: :proposal` `ReviewCommand` yet (`docs/hardening.md` / `AGENTS.md` still only lists the diagnostic `opencode-version` entry — no write-free upstream OpenCode review subcommand exists), so `AutoApply` is fully wired but has nothing to trigger on in practice until that follow-up lands. |

### P4 — Global admin API token is the default agent credential

| Field | Detail |
|-------|--------|
| **Source** | `docs/hardening.md` §Workspace-Scoped Tokens, `config/runtime.exs` (`DEV_IDE_WORKSPACE_API_TOKENS`), `lib/dev_ide_web/plugs/api_auth.ex` |
| **Gap** | Dogfood agents use `DEV_IDE_API_TOKEN` (admin/global) materialized into `~/.grok/config.toml` etc. Workspace-scoped tokens exist but are optional; an agent with the global token can omit `workspace_id` and see **all** `devide_*` sessions (`docs/terminal_mcp.md` §Access scope). |
| **Invariant** | **FP-10**, hardening boundary "every MCP call must be workspace-scoped" |
| **Verify** | `test/dev_ide_web/controllers/api/terminal_mcp_controller_test.exs` (scoped token rejects cross-workspace override); `scripts/verify_agent_pairing.sh` |
| **Rationale** | On a shared devbox, global tokens are the largest blast-radius misconfiguration; default agent materialization should emit workspace-scoped tokens. |
| **Status (2026-06-26)** | ✅ **CLOSED** (shipped `9b75d9c`, 2026-06-23 — before this doc was committed). The standard pairing flow already emits a scoped token by default: `setup-devbox-agent-pairing.sh` mints a per-workspace token (`scripts/lib/workspace-scoped-token.sh:60`, `secrets.token_hex(32)`), registers it server-side in `DEV_IDE_WORKSPACE_API_TOKENS` + redeploys (`:65-75`), and writes it as the agent's default `DEV_IDE_API_TOKEN` (`:127`) — the global admin token is kept only as `DEV_IDE_ADMIN_API_TOKEN` (`:128`). `materialize-agent-mcp.sh` simply propagates that already-scoped token. Cross-workspace access is blocked (`api_auth.ex:90-100`) with a regression test: scoped token → another workspace returns `403 workspace_forbidden` (`terminal_mcp_controller_test.exs:72-83`) and auto-injects its own workspace when the query is omitted (`:57`). **Residual:** agents started *outside* the pairing flow (hand-rolled env / raw global token) still get global scope — see MCP P5; the global token remains unrestricted by design for admin use. |

### P5 — Forward-auth trust chain has documented bypass matchers

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide_web/plugs/forward_auth.ex` moduledoc (OPTIONS + `/site.webmanifest` bypass), `lib/dev_ide/application.ex` (`assert_forward_auth_bind!/0`) |
| **Gap** | Caddy excludes OPTIONS and `/site.webmanifest` from forward-auth; a client-supplied `X-Auth-Request-Email` could spoof identity on those paths if Phoenix ever routes OPTIONS authentically. Prod bind misconfiguration warns but does not halt (`assert_forward_auth_bind!`). |
| **Invariant** | **FP-1** (server decides who may act), product §4 server owns operational safety |
| **Verify** | `lib/dev_ide/application.ex:115-130`; enable `DEV_IDE_FORWARD_AUTH=1` without loopback bind in dev → raises |
| **Rationale** | Load-bearing for shared devbox; needs a regression test if OPTIONS routes are added, and prod should fail closed on bind mismatch. |

---

## Durability & Recovery

Items where sessions, scrollback, or workspace attachment fail the user promise after disconnect, restart, or idle time.

### P1 — TmuxJanitor idle GC can kill unsubscribed durable sessions

| Field | Detail |
|-------|--------|
| **Source** | `docs/state_machines.md` terminal lifecycle rule 3, `lib/dev_ide/terminals/tmux_janitor.ex`, `config/runtime.exs` (`:tmux_idle_seconds`, prod default 600s) |
| **Gap** | After `:tmux_idle_seconds` with **no LiveView subscriber**, `TmuxJanitor` kills `devide_`-prefixed tmux sessions. Operator closes tab → work may be destroyed despite FP-2 "sessions durable by default." |
| **Invariant** | **FP-2**, **FP-8**, **FP-9**, product §8 promises 1–2 |
| **Verify** | `test/dev_ide/terminals/tmux_janitor_test.exs`; check prod `DEV_IDE_TMUX_IDLE_SECONDS` in `/etc/devide/devide.env` |
| **Rationale** | The persistence story (tmux survives) conflicts with idle GC policy; prod needs either disabled GC, much longer TTL, or explicit operator opt-in to kill idle sessions. |
| **Status (2026-06-26)** | 🟡 **SMALLER than described — and the "prod default 600s" claim is factually wrong.** `idle_ms/0` returns `nil` (GC **disabled**) unless `:tmux_idle_seconds` is set to a positive integer (`tmux_janitor.ex:159-164`); `runtime.exs` reads it only from `DEV_IDE_TMUX_IDLE_SECONDS` and the comment states GC is **opt-in** because durable sessions are the default. So the "tab close destroys durable work" risk does **not** exist at the default config. **Residual (real, but low-urgency):** *if* an operator enables idle GC, there is genuinely **no session-type guard** — the kill predicate fires on any `devide_`-prefixed session with no subscribers (`tmux_janitor.ex:115`), with no durable/ephemeral distinction. Defense-in-depth fix = a durable-session guard for the opt-in case, not "disable GC" (already disabled). Default-safe behavior shipped `9b75d9c`. |

### P2 — Cross-host workspace attach not configured

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide_web/live/workspace_live/show.ex` (~L131, ~L308), `test/dev_ide_web/live/workspace_live_test.exs`, `docs/audit_remote.md` CC-6 (awareness) |
| **Gap** | Attaching to a workspace whose source lives on another host returns flash: "Cross-host attach is not yet configured." Multi-host workspace picker is blocked. |
| **Invariant** | **FP-5** (operators interact with workspaces, not machines) — partially violated when workspaces span hosts |
| **Verify** | `mix test test/dev_ide_web/live/workspace_live_test.exs` (cross-host flash assertion) |
| **Rationale** | Manager integration (`docs/integrations/manager.md`) assumes on-devbox paths; any remote workspace source needs SSH/tunnel attach or honest capability hiding. |

### P3 — Agent session kind has no backend (`:agent_backend_unavailable`)

| Field | Detail |
|-------|--------|
| **Source** | `lib/dev_ide/terminals/attachment.ex` L62–63 |
| **Gap** | `Attachment.open/2` for `%Info{kind: :agent}` returns `{:error, :agent_backend_unavailable}`. Agent work today relies on shell + MCP into tmux panes, not a distinct agent attachment kind. |
| **Invariant** | Product §10.3 (agents drive runtime over MCP) works via shell panes; this gap blocks a cleaner agent/session model |
| **Verify** | Read `attachment.ex`; grep `agent_backend_unavailable` in tests |
| **Rationale** | Consolidate on MCP+tmux (document as intentional) or implement the agent backend so session directory semantics stay honest. |

### P4 — In-state replay buffer capped at 64 KiB

| Field | Detail |
|-------|--------|
| **Source** | `docs/audit_local.md` row 5, `lib/dev_ide/terminals/session.ex` (`@buffer_bytes`), `test/dev_ide/terminals/session_test.exs` |
| **Gap** | Browser disconnect replay uses a 64KB rolling tail; longer output is lost unless tmux scrollback capture succeeds (server-restart path). Heavy test runs may truncate replay on quick reconnect. |
| **Invariant** | **FP-9** ("replays exactly where you left off" — README — is approximate under cap) |
| **Verify** | `test/dev_ide/terminals/session_test.exs` ("replays buffered output…"); tmux capture test for restart path |
| **Rationale** | Operator "where was I?" friction during long agent jobs; raising cap or always preferring tmux scrollback on reattach would harden FP-9. |

### P5 — SSH-backed `Terminals.Adapter` not implemented

| Field | Detail |
|-------|--------|
| **Source** | `docs/terminal.md` §Remote hosts, `docs/architecture.md` future extension table, `docs/product.md` §7 |
| **Gap** | Only local tmux + Ghostty PTY path exists. Remote workspace sources cannot attach a raw terminal over SSH despite docs listing it as the planned extension. |
| **Invariant** | **FP-5**, **FP-8** |
| **Verify** | Grep `Terminals.Adapter` behaviour implementations → local only |
| **Rationale** | Blocks honest multi-host workspace story; until built, UI must hide remote attach (partially done via flash). |

---

## MCP / Agent Surface

Items that block or erode trust in human+agent side-by-side dogfood.

### P1 — MCP dogfood ledger has no recorded sessions

| Field | Detail |
|-------|--------|
| **Source** | `docs/dogfood_phase_2.md` §MCP side-by-side (ledger template + first targets), empty ledger |
| **Gap** | Fleet-runner dogfood entries exist (2026-05-12/13) but **zero** MCP side-by-side ledger entries. Pre-flight checklist (deploy on master, `verify_agent_pairing.sh --ci`, agent_pair layout, `:manual` mode) is documented but not evidenced in-repo. |
| **Invariant** | Product §12 demo paths 6–7 (agent pane, agent activity), **FP-10** |
| **Verify** | `source .devbox-agent.env && WORKSPACE_ID=$DEVIDE_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci` |
| **Rationale** | The current product path is MCP agents, not fleet runners; without ledger entries, friction is unknown and fixes are speculative. |

### P2 — Agent pane targeting depends on manual `agent_pair` layout

| Field | Detail |
|-------|--------|
| **Source** | `docs/terminal_mcp.md` §Agent pairing, `lib/dev_ide/agents/terminal_tools.ex` (`terminal_send_agent_*`), `AGENTS.md` friction table |
| **Gap** | `terminal_send_agent_command` refuses when agent pane cannot be identified; operators must apply template every session. Forgetting layout → agent keystrokes hit operator pane or fail closed. |
| **Invariant** | Product §8 promise 3, **FP-10** |
| **Verify** | `scripts/verify_agent_pairing.sh`; `test/dev_ide_web/api/terminal_mcp_test.exs` |
| **Rationale** | Daily dogfood friction; auto-apply on workspace enter or persistent layout state would reduce human error. |

### P3 — MCP client config hygiene on shared devbox

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` §MCP client injection (project-local and launch-time injection) |
| **Gap** | Historical global configs may still contain stale `devide-*` MCP entries until the launcher/materializer cleanup runs. New launches inject DevIDE MCP from resolved workspace env into project-local or launch-scoped config instead of global agent homes. |
| **Invariant** | Operational safety on multi-user host |
| **Verify** | Read `scripts/materialize-agent-mcp.sh`, `scripts/launch-devide-agent.sh` |
| **Rationale** | Plain agent starts should not inherit workspace-scoped MCP servers without a resolved `DEV_IDE_API_TOKEN`. |

### P4 — Preview MCP cannot drive LiveView WebSocket interactions

| Field | Detail |
|-------|--------|
| **Source** | `docs/preview_mcp.md` (headless `preview_observe_live` limitation), MCP server use instructions |
| **Gap** | Agents can screenshot DOM but cannot fully exercise LiveView push events; UI dogfood target #3 in `dogfood_phase_2.md` is partial. |
| **Invariant** | **FP-3** (UI reflects runtime truth) — agent verification of LiveView changes is weaker than server-side truth |
| **Verify** | `test/dev_ide_web/controllers/api/preview_mcp_controller_test.exs` |
| **Rationale** | Blocks automated agent verification of cockpit changes; document as known limit or add server-driven test hooks. |

### P5 — `workspace_id` scoping still operator-burdened

| Field | Detail |
|-------|--------|
| **Source** | `docs/terminal_mcp.md` §Access scope, `AGENTS.md` friction table ("workspace_id filter matched nothing") |
| **Gap** | Without pre-scoped MCP URL, agents see all `devide_*` sessions on host. Wrong id → empty results with no guided recovery. |
| **Invariant** | **FP-10**, hardening §Boundaries |
| **Verify** | `test/dev_ide_web/api/terminal_mcp_test.exs` (workspace_mismatch rejection) |
| **Rationale** | Pre-scoped URLs are generated by pairing scripts but agents started outside checkout miss them; fail-closed default should require scope. |

---

## Deploy / Ops & Ergonomics

Items that block repeatable push→deploy→dogfood loops or hide regressions.

### P1 — Self-hosted deploy poller does not re-run tests

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` §Auto-deploy, `scripts/deploy-poller.sh` |
| **Gap** | `devide-deploy.timer` builds and activates `origin/master` without running the suite; `git push --no-verify` still auto-deploys broken code. |
| **Invariant** | Product §12 "demo truth table" durability |
| **Verify** | Read `scripts/deploy-poller.sh`; compare to `.githooks/pre-push` |
| **Rationale** | Relies entirely on operator discipline; consider poller running `mix precommit.ci` in build worktree. |
| **Status (2026-06-26)** | ✅ **CLOSED.** `scripts/deploy-poller.sh` now re-runs the full pre-push gate in the detached build worktree — `( cd "$WORKTREE" && bash scripts/pre-push-check.sh )` — and **aborts the deploy on non-zero exit** (~L203-210), with the trust model documented in-script (~L15-18): a `git push --no-verify` can still *land* on master but will **not activate** until the worktree gate passes. The "builds/activates without running the suite" description is stale. |

### P2 — Uncoordinated concurrent pushes to master

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` §Coordinating concurrent agents on master |
| **Gap** | Multiple agents/humans push to `master`; poller auto-deploys HEAD; agents have undone each other's work mid-flight. No in-repo lock or direction-of-record enforcement. |
| **Invariant** | Operational safety for shared devbox |
| **Verify** | `git log origin/master` + branch status; process is doc-only today |
| **Rationale** | **Crucial** for MILC daily use; needs tracking issue / subsystem freeze conventions beyond prose. |

### P3 — GitHub Actions deploy path dormant

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` ("GitHub Actions billing-blocked"), `.github/workflows/deploy-devbox.yml` |
| **Gap** | No cloud CI gate; only self-hosted poller + optional local hook. Off-box contributors lack enforced pre-push gate unless they configure `.githooks/pre-push`. |
| **Invariant** | Deploy durability story |
| **Verify** | Inspect workflow `on:` triggers |
| **Rationale** | Single point of failure on devbox poller; billing restore or explicit secondary gate needed. |

### P4 — Three divergent Elixir/OTP toolchains

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` §Elixir version strategy, `Dockerfile`, `.tool-versions`, `.github/workflows/deploy-devbox.yml` |
| **Gap** | Local/agents 1.20+otp-28, release build 1.19.3, CI test job 1.18.4+otp-27. Syntax/feature drift (e.g. `~r/.../E` sigils) can slip through CI while failing dev or vice versa. |
| **Invariant** | Repeatable `mix precommit` |
| **Verify** | Grep versions across the four files AGENTS.md names |
| **Rationale** | Converge when convenient — until then, every syntax bump must touch all four pins. |

### P5 — Manual deploy drift is easy to miss

| Field | Detail |
|-------|--------|
| **Source** | `AGENTS.md` friction table, `lib/dev_ide/deployment/drift.ex`, `test/dev_ide/deployment/drift_test.exs` |
| **Gap** | `bash scripts/deploy-local.sh` activates checkout builds immediately, but the on-box poller redeploys `origin/master` within ~2 min and overwrites manual releases. Drift banner appears only when `/etc/devide/devide.env` SHA/label differs from `origin/master`. |
| **Invariant** | AGENTS.md "everything that must stay deployed must land in git first" |
| **Verify** | `mise exec -- mix test test/dev_ide/deployment/drift_test.exs` |
| **Rationale** | Operators dogfooding from dirty checkouts lose work silently; banner helps but prevention (push-first workflow) remains procedural. |

---

## Internal / Deferred

Explicit non-goals, polish, and experimental subsystems — **not** blocking daily dogfood but tracked for honesty.

### Deferred product surfaces (intentional non-goals)

| Item | Source | Rationale |
|------|--------|-----------|
| Syntax highlighting, file-tree-primary UI, LSP, VS Code extension ecosystem | `docs/product.md` §6 | Explicit non-goals; do not rank as crucial unless an operator task is blocked |
| Fleet scheduler / multi-runtime / delegated execution | `docs/product.md` §6, `docs/architecture.md` history | Removed; `scripts/dogfood_remote_fleet.sh` entries in `dogfood_phase_2.md` are legacy validation only |
| Hero disconnect demo GIF | `README.md` L13 TODO | Marketing polish, not runtime safety |

### Deferred terminal renderer work

| Priority | Item | Source | Gap |
|----------|------|--------|-----|
| D1 | **L5 rAF coalesce** default-OFF | `docs/subsystems/terminal_renderer_lessons.md` L5, `assets/js/terminal_canvas.js` | Shipped inert; needs browser verification before default-on |
| D2 | **L1 OffscreenCanvas + Worker** | terminal_renderer_lessons L1 | Main-thread raster; large output jank |
| D3 | **L4 Glyph atlas** | terminal_renderer_lessons L4 | Paired with L1; Canvas2D path sufficient for now |

### Deferred auth / infra

| Item | Source | Notes |
|------|--------|-------|
| CC-2 TLS turnkey | `docs/audit_remote.md` CC-2 | Documented in `deploy.md`; no code gap |
| CC-6 cross-origin channel auth | `docs/audit_remote.md` CC-6 | Defer until CDN/cross-origin cockpit |
| Collaborator role (between viewer and owner) | `lib/dev_ide/policy.ex` `workspace_role/1` comment | Only admin/owner/viewer today |

### Loops engineering (REMOVED 2026-06-26)

The experimental self-improving Loops subsystem was **deleted** — it was dormant
(disabled by default, no generator configured, zero callers, no web/MCP surface)
and carried the repo's largest safety surface for no current utility. Removed:
`lib/dev_ide/loops/`, `lib/dev_ide/loops.ex`, tests, `Policy.can_run_loop?/1`,
the `agent-loop-engineering-prototype` workflow; `loop_runs`/`loop_attempts`
dropped via `20260626120000_drop_loop_tables`. See the Safety P1 status row above.

---

## Runnable checks reference

Use these to re-validate any item above:

```bash
# Full pre-push gate (PASS on docs-commit isolated worktree — see snapshot)
bash scripts/pre-push-check.sh

# Hardening-focused MCP/policy/drain tests (62 tests, passing)
bash scripts/hardening-audit.sh

# Live devbox MCP smoke (requires env)
source .devbox-agent.env
WORKSPACE_ID=$DEVIDE_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci

# Workspace recovery bundle
source .devbox-agent.env
bash scripts/workspace-doctor.sh "$DEVIDE_WORKSPACE_ID"

# Policy denial paths
mise exec -- mix test test/dev_ide/policy_test.exs test/dev_ide/audit_test.exs

# Session durability
mise exec -- mix test test/dev_ide/terminals/session_test.exs test/dev_ide/terminals/tmux_janitor_test.exs

# Marker inventory
git grep -n "TODO\|FIXME\|not_implemented\|deferred" -- lib/ docs/ scripts/ assets/
```

---

## Suggested fix order (cross-category)

> **Superseded by the 2026-06-26 refresh.** The original five (below) are now
> mostly shipped: Safety P1 ✅, Deploy P1 ✅, Durability P1 ✅ (default-safe),
> Safety P4 ✅. **MCP P1 was not re-verified.** Re-prioritized open work:
>
> 1. ~~**Loops** (Safety P1 + its ledger residual).~~ 🗑️ **REMOVED 2026-06-26** — the whole subsystem was deleted (dormant, zero callers); the gap and its residual no longer exist.
> 2. ~~**Safety P2** — fail-safe `raw_terminal_everywhere` default in prod `runtime.exs` + deny-path regression test.~~ ✅ **CLOSED 2026-06-29** — default is local manual only; raw-everywhere is explicit prod opt-in.
> 3. **Durability P1 guard** — durable-session guard so opt-in idle GC can't reap durable sessions (low urgency; default already disabled).
> 4. **MCP P1** — re-verify, then run + log the first MCP dogfood session if still absent.
> 5. **Re-verify the un-checked items** (Safety P3/P5, Durability P2–P5, MCP P2–P5, Deploy P2–P5) before acting on any — this refresh only confirmed the P1s.

**Original list (pre-implementation snapshot — kept for history):**

1. **MCP P1** — run first MCP dogfood session; log in `dogfood_phase_2.md`.
2. **Safety P1** — Policy/audit wrapper for Loops **or** explicit experimental quarantine.
3. **Deploy P1** — poller should run `mix precommit.ci` in build worktree (or block `--no-verify` deploys).
4. **Durability P1** — review `tmux_idle_seconds` on prod devbox (disable or raise).
5. **Safety P4** — materialize workspace-scoped agent tokens by default.

---

*This document is analysis-only. Implementation tracking belongs in issues/PRs
referencing the cited sources and invariant IDs (FP-1 … FP-10).*
