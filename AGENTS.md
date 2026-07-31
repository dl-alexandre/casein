This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- In this checkout, agent shells may not have `mix`, `elixir`, or `erl` on `PATH` even though `mise` is installed. The repo pins its toolchain in `.tool-versions` (Elixir 1.20.0-otp-28, Erlang 28.5), so a plain `mise exec -- mix ...` from inside the checkout resolves the right versions for formatting, tests, and `precommit` — no explicit version pins needed. Avoid Elixir `1.18.4-otp-27` for local work; current Phoenix dev config uses `~r"..."E` regex sigils that Elixir 1.18 rejects with `Regex.CompileError invalid_option`.
- **Elixir version strategy (three toolchains, on purpose — converge when convenient):**
  - **Local dev / agents:** 1.20.0-otp-28 + OTP 28.5 via `.tool-versions` (needs 1.19+ for the dev-config regex sigils).
  - **Release builder (`Dockerfile`):** 1.19.3 + OTP 28.5 — what actually ships to the devbox.
  - **CI test job (`deploy-devbox.yml`):** 1.18.4 + OTP 27.2 — compiles `MIX_ENV=test` only, so it never sees the dev-config sigils; kept older to catch syntax not yet available on the oldest supported runtime.
  - When bumping any of these, grep this file, `Dockerfile` (`ELIXIR_VERSION`/`OTP_VERSION` args), `.github/workflows/*.yml`, and `.tool-versions` so they don't drift silently.
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps
- For tmux topology, LiveView controls, and agent mutation endpoints, read `docs/tmux_control_plane.md` before changing terminal control-plane behavior
- For GitHub operations in this `/data/workspaces/dalexandre/casein` checkout, use the repo-local credential helper already stored in `.git/config`. Normal `git fetch` / `git push origin master` should authenticate with the dalexandre GitHub CLI config at `/home/devbox/.config/gh-dalexandre`. Do not move this helper to global Git config; it is intentionally scoped to this checkout so other workspaces/users are not affected. If the helper is missing, restore it with: `git config --local credential.https://github.com.helper '!GH_CONFIG_DIR=/home/devbox/.config/gh-dalexandre GH_TOKEN= GITHUB_TOKEN= gh auth git-credential'`.

## Devbox agent pairing (human + external agent)

On the milc devbox, Casein runs as a **systemd release** (`casein` service → `/opt/casein/release`), not `mix phx.server` from the checkout. UI is behind Caddy at `https://casein.devbox.milcgroup.com`. Canary deploys listen on `/run/casein/current.sock`; on-box agents still use `http://127.0.0.1:4000` via the `casein-loopback` socat proxy (`scripts/ensure-casein-loopback-proxy.sh`).

### Required pre-push gate

Before pushing to `master`, run the repo-local gate:

```bash
bash scripts/pre-push-check.sh
```

This mirrors the deploy workflow's blocking checks: JS hook lint (`assets/` with dev dependencies), deploy script syntax/sync, and `mix precommit.ci`. Use this instead of relying on a manual devbox deploy to prove durability. If the checkout is dirty with unrelated user/agent work, stage only your intended files and still run targeted tests plus this gate when possible; do not include unrelated dirty files in your commit.

**Enforced by committed git hooks.** Enable once per checkout (git does not auto-apply committed hooks):

```bash
git config core.hooksPath .githooks
```

- **`.githooks/pre-commit`** — refuses commits on `master` in the **primary checkout** (read-only mirror of `origin/master`). Agent linked worktrees are not gated. Bypass: `git commit --no-verify` or `CASEIN_ALLOW_MASTER_COMMIT=1`.
- **`.githooks/pre-push`** — blocks any push to `master` unless `scripts/pre-push-check.sh` passes (branch/WIP pushes are not gated). Bypass: `git push --no-verify`.

The pre-push hook is the local stand-in for CI's check job while GitHub Actions is billing-blocked (the `push` trigger in `.github/workflows/deploy-devbox.yml` is commented out — see that file).

**Sobelow suppressions: prefer inline, with a reason.** `mix precommit.ci` runs `sobelow --skip --exit`, which honours two suppression mechanisms — inline `# sobelow_skip ["Rule"]` annotations and the central `.sobelow-skips` ledger. For a *justified* false positive, suppress it with an inline annotation, not a new ledger entry: the annotation lives next to the code, travels with refactors, and is reviewable in the diff, whereas `.sobelow-skips` keys on line numbers that rot on edit. Put the reason on a comment line *above* a clean `# sobelow_skip` line, which must sit immediately above the def — sobelow parses the rest of the `sobelow_skip` line and crashes on prose after the `]`:

```elixir
# id is regex-validated by validate_id/1 before any path use.
# sobelow_skip ["Traversal.FileModule"]
def write_artifact(id, bytes), do: ...
```

Treat the ledger as legacy — don't add to it. Never suppress before confirming the finding is actually safe; for a real risk, fix the code (e.g. the traversal guard in `Casein.Previews.Storage.LocalDisk.put/4`).

**PR gate (self-hosted runner).** GitHub PR merges bypass the local `.githooks/pre-push` gate, so debt can land on `master` even though the deploy poller's re-run of the gate (below) still blocks it from *deploying*. To stop the branch tip going red via the merge button, `.github/workflows/pr-gate.yml` runs `scripts/pre-push-check.sh` on every PR into `master`, on a self-hosted runner (GitHub-hosted Actions are billing-blocked). One-time setup per box:

```bash
bash scripts/ensure-ci-runner.sh        # download + register + start the runner service
bash scripts/ensure-ci-runner.sh --remove   # unregister + tear down
```

Then make the check **Required** so it actually blocks merges (needs repo admin; the check must have run once to be selectable):

```bash
env -u GH_TOKEN gh api -X PUT repos/dl-alexandre/casein/branches/master/protection \
  -f 'required_status_checks[strict]=false' \
  -f 'required_status_checks[contexts][]=gate' \
  -F 'enforce_admins=false' -F 'required_pull_request_reviews=' -F 'restrictions='
```

**SECURITY:** the runner executes PR-branch code on the devbox, so the workflow refuses fork PRs (`head.repo.full_name == github.repository`). Until the runner is registered, the workflow is inert — until then, run `scripts/pre-push-check.sh` on a freshly-merged `master` before the next direct push, or expect to inherit any such debt.

**Why `enforce_admins=false` / `strict=false`.** The branch protection *must* let admins bypass: the canonical deploy path is a direct push to `master` (through the local pre-push gate), which carries no PR check — `enforce_admins=true` would reject it and break deploys. So the `gate` check hard-blocks red *non-admin* PR merges and is an advisory red/green signal for the owner's own merges. `strict=false` avoids forcing every PR up-to-date amid the concurrent-agent FF-race churn.

**Auto-deploy is self-hosted — no GitHub Actions.** An on-box systemd timer (`casein-deploy.timer` → `scripts/deploy-poller.sh`) polls `origin/master` every ~2 min and, when it advances, builds a release from a *clean detached worktree at that SHA* and activates it via `deploy-devbox-release.sh`. So a green push to `master` auto-deploys within a couple of minutes — no manual step required. Install/enable once per box:

```bash
bash scripts/ensure-casein-deploy-poller.sh      # install + enable + start the timer
journalctl -u casein-deploy.service -f           # watch deploys
sudo systemctl start casein-deploy.service       # force a poll now
bash scripts/ensure-casein-deploy-poller.sh --disable   # tear it down
```

The poller re-runs `scripts/pre-push-check.sh` inside the clean detached worktree
before packaging the release, so a `--no-verify` push that lands on `master` still
cannot activate until that worktree gate passes. `bash scripts/deploy-local.sh`
remains the manual override for an immediate deploy of the current checkout.

The running release also performs a deploy-drift check at boot. If `/etc/casein/casein.env` has a manual revision label or a SHA that differs from `origin/master`, Casein logs a warning and shows a **Manual deploy is not durable** banner. Treat that as a release-safety issue: commit and push the deployed change, then let GitHub's canonical deploy replace the manual release.

### Source control before deploy (required)

**Everything that must stay deployed must land in git first.** A push to `master` is picked up by the on-box poller (`casein-deploy.timer` → `scripts/deploy-poller.sh`), which builds `origin/master` from a clean worktree and runs `scripts/deploy-devbox-release.sh` — replacing `/opt/casein/release` entirely. (The GitHub Actions path in `.github/workflows/deploy-devbox.yml` does the same thing but is dormant while Actions billing is blocked.)

**Simple bug fixes are not complete until deployed.** Unless the user explicitly
asks to stop earlier, carry a straightforward fix through targeted verification,
the required pre-push gate, commit, push or merge to `master`, deployment, and a
live health/version check. Do not hand off a validated simple fix as merely
uncommitted or undeployed work.

| Do | Don't |
|----|-------|
| Commit + push to `master`, wait for CI deploy | Hand-edit files under `/opt/casein/release` |
| Use `bash scripts/setup-devbox-agent-pairing.sh` only to **validate** an uncommitted build locally | Treat a manual local deploy as durable without pushing |
| Keep product scripts and behavior in this checkout; keep MILC host configuration in the private `MILCGroup/milc-devbox/casein` overlay | Add one-off binaries or config only on the running release tree |

**Workflow that survives auto-release CI:**

1. Implement and run `mix precommit` in the checkout.
2. Commit and push to `master` (or open a PR that merges there). The pre-push gate runs the suite.
3. The on-box poller (`casein-deploy.timer`) auto-deploys `origin/master` within ~2 min — no GitHub Actions. Force it now with `sudo systemctl start casein-deploy.service`, or `bash scripts/deploy-local.sh` for an immediate manual deploy.
4. Optionally smoke-check on the box: `source .devbox-agent.env && bash scripts/verify_agent_pairing.sh`.

A manual `setup-devbox-agent-pairing.sh` run is useful for dogfooding before push, but **the next CI deploy will overwrite it** unless those commits are on `master`. The checkout at `/data/workspaces/dalexandre/casein` is for editing; `/opt/casein/release` is the ephemeral runtime artifact.

### Coordinating concurrent agents on master (required)

Read **`docs/development-workflow.md`** first (primary checkout is deploy-only;
agents launch in reported worktrees via `scripts/launch-casein-agent.sh`). Active
subsystem freezes live in **`docs/in-progress.md`**.

Multiple agents/humans push to `master` at once, and the on-box poller
auto-deploys it — so **an uncoordinated `master` is an uncoordinated prod**, and
agents have undone each other's work mid-flight (e.g. one removing a subsystem
while another commits fixes to it). Before starting non-trivial work:

- **Don't work at cross-purposes.** Check `git log origin/master` and the pinned
  "direction of record" (`docs/in-progress.md` or a tracking issue for any in-progress
  removal or large refactor) before touching a subsystem. If you're starting a
  removal or sweeping change, post the intent there first so others don't fix
  what you're deleting.
- **Land serially, small, and rebased.** Do large work on a short-lived branch,
  `git fetch origin master` + rebase right before pushing, and push promptly.
  Expect `master` to move under you; integrate rather than force a stale tree.
- **The pre-push gate is the floor, not a substitute for coordination.** Avoid
  `--no-verify` except to win a genuine race on an already-gate-green tree, and
  re-run the gate locally before deploying if you bypassed it.
- A workspace/subsystem under active large change should be treated as
  read-only by other agents until the change lands. See the shared-checkout
  hazards in the memory notes.

### Stacked pull requests (`gh stack`)

GitHub stacked PRs went to public preview on 2026-07-30 and are live for the
`dl-alexandre` account. `scripts/ensure-workspace-agent-pair.sh` installs the
`gh stack` extension as part of pairing, so a paired workspace has both halves —
the extension and the `gh-stack` skill. Install or refresh it directly with:

```bash
bash scripts/ensure-gh-stack.sh                # install/upgrade + preview probe
bash scripts/ensure-gh-stack.sh --check        # report only
bash scripts/ensure-gh-stack.sh --repo <path>  # configure that repo, not $PWD
```

**The extension is per-`HOME`, not host-wide.** gh reads extensions from
`$XDG_DATA_HOME/gh/extensions` (default `~/.local/share/gh/extensions`) — keyed
to `HOME`/`XDG_DATA_HOME`, *not* to `GH_CONFIG_DIR`. One install therefore covers
every agent-auth profile sharing this `HOME`, but not a runtime with a different
`HOME`, a different `XDG_DATA_HOME`, or a sandbox that does not bind the data
dir. `gh extension list` coming back empty in a workspace means one of those,
not a bad install. The skill is likewise staged *at launch or pair time*, so it
never appears retroactively in an already-open pane.

Use a stack when one change is genuinely layered (schema → context → LiveView)
and each layer is reviewable alone. It is the mechanism behind "land serially,
small, and rebased" above — not a reason to split unrelated work.

```bash
gh stack init schema-layer      # stack rooted on the default branch
gh stack add context-layer      # next layer up
gh stack submit --auto          # push branches + open/refresh the PRs
gh stack view --json            # inspect
gh stack sync                   # after master moves
gh stack merge --yes --squash   # merge the whole stack, bottom to top
```

**Agents must run every `gh stack` command non-interactively** — `view` without
`--json` and `submit` without `--auto` open a TUI/prompt that hangs the pane, and
`init`/`add`/`checkout` prompt unless given branch names as positional args. The
vendored `gh-stack` skill (`.claude/skills/gh-stack`, staged into every agent
config home by `scripts/lib/agent-skills.sh`) carries the full rule set.

Devbox-specific caveats:

- **The local pre-push gate does not cover a stack merge.** `.githooks/pre-push`
  only gates direct pushes to `master`; `gh stack merge` lands on `master`
  server-side, so run `bash scripts/pre-push-check.sh` on the top branch of the
  stack before merging.
- **`gh pr merge` does not work on stacked PRs** — use `gh stack merge`.
- **Auth is per profile.** `submit`/`merge` use whichever `GH_CONFIG_DIR` is
  active. The `.bashrc` hook only sets it under `/data/workspaces/dalexandre*`;
  agent worktrees under `/tmp/casein-agent-worktrees` inherit it from the
  launching pane. Check `gh auth status` first, and note that `dl-alexandre` is
  currently the only gh account configured on the box — other profiles need
  their own `gh auth login` before `gh stack submit` will work.
- **Branch pushes still use the repo-local credential helper** (see Project
  guidelines) — `gh stack push` is a plain `git push` underneath.
- **Merge queue support is still rolling out**; if `master` gets a merge queue,
  a stack is queued rather than merged atomically and the merge method you pass
  is ignored.

### Agent session exit protocol (required)

Before ending a session (or letting it go idle overnight), **every agent must
leave an explicit handoff** so stale-worktree alarms do not bury shipped-quality
work in archaeology. Pick exactly one:

1. **Land it** — push the feature branch and open a PR (or push to `master` when
   appropriate). Re-call `terminal_report_worktree` with `exit_status: "landed"`.
2. **Pause intentionally** — commit with a `wip:` prefix (`git commit -m "wip: …"`)
   and/or re-call `terminal_report_worktree` with `exit_status: "wip"` plus a
   short `handoff` message (branch name, what's done, what's blocked).
3. **Report status** — re-call `terminal_report_worktree` with
   `exit_status: "handoff"` and a `handoff` message when you cannot push yet but
   the worktree should stay discoverable.

**Never** leave a dirty worktree with no report, no process, and no handoff. The
daily `casein-worktree-alarm-sweep` timer (install:
`bash scripts/ensure-casein-worktree-alarm-sweep.sh`) emits
`workspace.agent_worktree_stale` audit events for worktrees older than 24h that
fail this protocol. Clean, reported worktrees are reaped separately by
`Casein.Runtimes.Reaper`; dirty ones are alarm-only until a human resolves them.

### Quick start after checkout changes

```bash
# Routine fast devbox deploy after committing and pushing to master
bash scripts/deploy-local.sh

# First-time pairing / MCP refresh only
bash scripts/setup-devbox-agent-pairing.sh

# Refresh agent env/MCP without redeploying (after canary deploy)
bash scripts/refresh-devbox-agent-pairing.sh

# Smoke-check MCP (source env first)
source .devbox-agent.env
WORKSPACE_ID=$CASEIN_WORKSPACE_ID bash scripts/verify_agent_pairing.sh
```

`deploy-local.sh` builds from the checkout, packages `release-out`, and runs the same activation script used by CI without redoing workspace SQL, `.devbox-agent.env`, MCP materialization, or pairing verification. It is the preferred fast path after a successful push; CI will still perform the later canonical deploy from `master` unless that workflow is changed.

Do **not** commit `.devbox-agent.env` (contains workspace-scoped `CASEIN_API_TOKEN`;
global admin is `CASEIN_ADMIN_API_TOKEN`). Host tokens live in `/etc/casein/casein.env`.
`setup-devbox-agent-pairing.sh` registers scoped tokens under
`CASEIN_WORKSPACE_API_TOKENS` and writes the scoped bearer as the default agent
`CASEIN_API_TOKEN`.

### Operator + agent model

- **Human** works in the Casein LiveView (terminal tab + preview side panel).
- **External agent** (Cursor, Grok CLI, etc.) is an MCP client — Casein does not host the agent loop.
- Apply the built-in **`agent_pair`** tmux template once per session: **Agents tab → Apply Agent Pair layout**.
  - Operator pane stays **focused** (human types here).
  - **Agent pane** is for MCP `terminal_send_command` / `terminal_send_keys`.
  - **Verify pane** is for `git status` / test output.
- Built-in template id: `agent_pair` (`lib/casein/terminals/session_template/loader.ex`).

### Definition of done (coverage matrix)

A change is not done because one happy path works on the surface you happen to
have open. Walk the axes below and mark each cell that the change *could*
touch; untested cells are open bugs. Single-surface omissions that shipped as
"done" and then regressed elsewhere: the chromeless-panes desktop/mobile CSS
split, the mobile authority flap, and the iPad scroll fix (`1e8f4ef0`).

| Axis | What to cover |
|------|----------------|
| **Surfaces** | Desktop viewer, mobile PWA, native mobile companion (`CaseinMob`), Electron/macOS + Windows desktop packages |
| **Entry points** | Keybar, command palette, context strip, mobile sheet |
| **Provider adapters** | Codex, Grok (ACP), Claude, OpenCode |
| **Reverse state flows** | open/close, attach/detach, pair/unpair, lock/unlock, dirty/clean — the axis that has bitten Casein repeatedly |
| **Connection modes** | Loopback, LAN, public HTTPS, SSH tunnel |
| **Docs** | `docs/subsystems/` entry updated when behaviour or operator procedure changed |

### MCP endpoints (wire into external agent)

| Surface | URL | Auth |
|---------|-----|------|
| Terminal MCP | `https://casein.devbox.milcgroup.com/api/terminals/mcp` | Bearer `CASEIN_API_TOKEN` |
| Preview MCP | `https://casein.devbox.milcgroup.com/api/preview/mcp` | Bearer `CASEIN_API_TOKEN` |

Same-host agents may use `http://127.0.0.1:4000/api/...` instead. Read `docs/terminal_mcp.md` and `docs/preview_mcp.md` before changing MCP behavior.

For wiring an **off-box** agent end-to-end (both transports, ready-to-paste `.mcp.json` + agent prompts, pinned vs durable/workspace-agnostic config), see **`docs/external-agent-connect.md`** and the host-side `casein-remote` skill.

**Always pass `workspace_id`** on terminal MCP calls. For `dalexandre-casein` the manager UUID is in `.devbox-agent.env` as `CASEIN_WORKSPACE_ID`. Scoping resolves both UUID and workspace **name** to tmux prefixes — sessions are named `casein_<workspace_name>_<sid>`, not `casein_<uuid>_`.

Agent workflow:

1. `terminal_list_sessions` with `workspace_id`
2. `terminal_topology` → find **agent** pane id (e.g. `%3`)
3. `terminal_send_command` with explicit `pane` — never the operator's focused pane
4. `terminal_capture` (`ansi: false`, `lines: 100`) to read output
5. `preview_open_app` (splits a tmux preview pane) → observe/screenshot → `preview_close` for UI checks

Starter prompt for external agents: `.devbox-agent-prompt.txt` (expand vars after `source .devbox-agent.env`).

### MCP client injection (Grok, Claude, Codex, OpenCode)

Casein **hosts** the MCP servers; each agent runtime must **register** them as a
client. Do not rely on repo `.grok/config.toml` alone — discovery walks up from
**cwd**, so agents started outside the checkout will miss project-scoped config.

**Pairing flow** — materialize per-workspace staging, then launch with MCP injected:

```bash
source .devbox-agent.env
bash scripts/materialize-agent-mcp.sh    # writes ~/.casein/agent-mcp/<workspace>/
bash scripts/launch-casein-agent.sh grok # or codex | claude | opencode
```

| Runtime | Injection | Cwd-independent? |
|---------|-----------|----------------|
| **Claude** | `claude --mcp-config $STAGING/.mcp.json` (additive — keeps global servers like fff); launcher `cd`s to `CASEIN_CHECKOUT` | Yes |
| **Grok** | injected by `scripts/launch-casein-agent.sh grok` into project-local `.mcp.json` (`${CASEIN_API_TOKEN}` in headers); Casein entries are not persisted in `~/.grok/config.toml` | Yes |
| **Codex** | injected by `scripts/launch-casein-agent.sh codex` with per-launch `-c mcp_servers...` overrides (`CASEIN_API_TOKEN` exported by the launcher); Casein entries are not persisted in `~/.codex/config.toml` | Yes |
| **OpenCode** | injected by `scripts/launch-casein-agent.sh opencode` into project-local `.opencode/opencode.json` (`{env:CASEIN_API_TOKEN}`); Casein entries are not persisted in global OpenCode config | Yes |
| **Cursor** | materialized `.cursor/mcp.json` in checkout (gitignored) | Opens checkout as project |

`setup-devbox-agent-pairing.sh` runs `materialize-agent-mcp.sh` after writing
`.devbox-agent.env`. Staging lives under `~/.casein/agent-mcp/<workspace_name>/`
(one tree per Casein workspace, not one global agent config).

**Why two strategies.** Claude takes its MCP from the per-workspace staging
file via `--mcp-config` (additive, fully isolated). Grok/Codex/OpenCode keep
their **auth in stateful global homes** (`~/.grok`, `~/.codex`,
`~/.local/share/opencode`) that can't be redirected without losing sessions and
credentials — `agent-doctor.sh`/`repair-tmux-env.sh` deliberately keep
`GROK_HOME`/`CODEX_HOME`/`OPENCODE_CONFIG` **unset**. Casein MCP is injected only
at launch, after the workspace token has been resolved: Claude gets
`--mcp-config`, Codex gets `-c mcp_servers...` overrides, Grok gets project
`.mcp.json`, and OpenCode gets project `.opencode/opencode.json`. The helper
`merge-agent-mcp.py` now strips stale global `casein-*` blocks rather than
writing new ones, so plain agent starts do not inherit workspace-specific MCP
servers without `CASEIN_API_TOKEN`.

### Raw terminal + workspace mode

Raw multi-pane terminal requires workspace mode **`:manual`**. Manager workspaces now default to `:manual` (`Casein.Policy.WorkspaceMode`'s fallback) so split-screen works out of the box; switch a workspace to `:review` (or another mode) explicitly via UI (**Agents → Safety → mode**) or DB if you need agent-proposal-only access instead:

```bash
# DATABASE_URL from /etc/casein/casein.env — port 15432, not 5432
PGPASSWORD=... psql -h 127.0.0.1 -p 15432 -U casein -d casein_prod \
  -c "UPDATE workspace_records SET mode='review' WHERE name='dalexandre-casein';"
```

`bin/casein rpc` for mode changes often fails with **Invalid challenge reply** (RELEASE_COOKIE drift) — prefer UI or direct SQL above.

### Process-kill safety (shared box)

This devbox is multi-tenant (multiple users, workspaces, and agent sessions).
Process hygiene mistakes here reaps *other people's* work, not just yours.

- **Never `pkill -f <pattern>`.** Pattern kills match across users and
  workspaces. Kill only by a PID you captured yourself, or by the confirmed
  port owner via `ss -H -ltnp` (then that PID).
- **Never point a dev server at the production database.** `DATABASE_URL` is
  inherited from the live release env (`/etc/casein/casein.env`).
  `config/runtime.exs` guards `MIX_ENV=test` but **not** `MIX_ENV=dev` — a
  casual `mix phx.server` can write through to prod data.
- **Before killing a "stale" instance, prove it is stale.** A live
  `SessionOwner` with one viewer and oscillating owner size is not stale;
  reaping it drops the operator mid-session. Confirm via topology/status, not
  by age alone.

### Friction we hit (save future time)

| Issue | Fix |
|-------|-----|
| Checkout edits invisible in UI | Push to `master` — the on-box poller auto-deploys within ~2 min; or run `bash scripts/deploy-local.sh` for immediate activation |
| Local deploy vanished after a while | The on-box poller redeployed `origin/master` — uncommitted or unpushed work was overwritten. Commit + push it |
| Poller not deploying after a push | `systemctl status casein-deploy.timer`; `journalctl -u casein-deploy.service`; ensure the timer is installed (`bash scripts/ensure-casein-deploy-poller.sh`) |
| `git push` says repository not found | This checkout should use the repo-local dalexandre credential helper in `.git/config`; do not rely on ambient `GH_TOKEN` |
| Agent keystrokes collide with human | Apply `agent_pair`; agent must target **agent** pane from `terminal_topology` |
| `claude: command not found` after template / `clauded` fails | Usually a missing `~/.casein/agent-shims/claude` launcher shim (siblings can still be present) or a pane that started before agent PATH was pushed. Boot + `PaneEnv` + shell-integration now self-heal shims and force `~/.casein/agent-shims` to the front of pane PATH; if it still happens, run `bash scripts/install-agent-shims.sh` or `casein agent doctor`, then open a new window. Prefer bare `claude` — palette `clauded` maps to it; Casein shim already defaults to skip-permissions. Note: the shim dir is only on PATH inside Casein contexts — in a plain terminal, agent names run the real binaries (unpaired). |
| Tab closed, tmux session vanished | Check `CASEIN_TMUX_IDLE_SECONDS` in `/etc/casein/casein.env` — leave **unset** for durable sessions (FP-2); GC is opt-in only |
| All terminal sessions empty at once (tmux server died) | See `docs/subsystems/tmux_crash_recovery.md`. ScrollbackArchive reseeds tails; SessionOwner recovers attachments; install keepalive with `bash scripts/ensure-casein-tmux.sh`. Pin binary: `bash scripts/ensure-casein-tmux.sh --reinstall-binary` (3.6b) |
| `workspace_id` filter matched nothing | Pass manager UUID; `TerminalTools` also resolves workspace **name** for tmux prefix |
| MCP verify script 400 errors | Never use `${3:-{}}` in bash — `}` closes the expansion. Use explicit `params="{}"` default (see `scripts/verify_agent_pairing.sh`) |
| Preview click/type fails | Playwright Chromium must be installed in release `priv/scripts` (deploy script does this) |
| `mix phx.server` on devbox | Wrong path for daily use — competes with systemd release; use release deploy |
| `mix: command not found` in agent shell | Use `mise exec -- mix ...` from inside the checkout — `.tool-versions` pins the toolchain; mise shims may not be on `PATH` |
| `mix test` binds :4000 / wrong DB | Shell inherited `PHX_SERVER`/`PORT` from the live release env. `config/runtime.exs` now ignores both under `MIX_ENV=test`; if you still see it, the checkout predates that guard — unset them |
| Live MCP activity invisible | Agents tab → **Live MCP activity**; mutating calls are also audited |
| `codex update` EACCES on `/usr/lib/node_modules`, or update replacing the Casein `codex` shim | Run `bash scripts/ensure-devbox-npm-prefix.sh` (also run by `setup-devbox-agent-pairing.sh`) so `npm install -g` targets a user-writable prefix under `~/.local/share/npm-global`, separate from the `~/.casein/agent-shims` launchers |
| Codex sandbox hangs / `bwrap: loopback: Failed RTM_NEWADDR` | Ubuntu 24.04+ blocks unprivileged user namespaces via AppArmor. Codex's Linux sandbox uses `bubblewrap`, which needs userns. Run `bash scripts/ensure-devbox-codex-sandbox.sh` (also in `setup-devbox-agent-pairing.sh`) to install `apparmor-profiles` and load the `bwrap-userns-restrict` profile. Canary: `bwrap --dev-bind / / --unshare-net echo ok` |

### Key files

- `scripts/deploy-poller.sh` — on-box auto-deploy poller (self-hosted CI deploy; fires from `casein-deploy.timer`)
- `scripts/ensure-casein-deploy-poller.sh` — install/enable/disable the deploy poller systemd timer+service
- `scripts/casein-deploy.{service,timer}` — systemd units for the poller (`__CHECKOUT__` substituted at install)
- `.github/workflows/deploy-devbox.yml` — dormant GitHub-Actions deploy (workflow_dispatch fallback for when billing returns)
- `scripts/deploy-local.sh` — fast local build+deploy wrapper / manual override
- `scripts/setup-devbox-agent-pairing.sh` — first-time pairing / MCP refresh wrapper around local deploy plus pairing steps
- `scripts/deploy-devbox-release.sh` — release activation (used by CI and local setup)
- `scripts/ensure-devbox-npm-prefix.sh` — user-writable npm global prefix (`~/.local/share/npm-global`) for `codex update`, separate from Casein shims in `~/.casein/agent-shims`
- `scripts/ensure-devbox-codex-sandbox.sh` — AppArmor + bubblewrap setup so Codex Linux sandbox can create user namespaces
- `scripts/materialize-agent-mcp.sh` — per-workspace MCP configs for Grok/Claude/Codex/OpenCode
- `scripts/launch-casein-agent.sh` — start an agent runtime with MCP injected
- `scripts/casein-worktree-alarm-sweep.sh` — daily stale-worktree alarm (release RPC; never deletes dirty trees)
- `scripts/ensure-casein-worktree-alarm-sweep.sh` — install/enable/disable the worktree-alarm systemd timer
- `scripts/casein-grok-janitor-sweep.sh` — daily reap of orphaned Grok leader processes (cwd deleted) + stale leader dirs/bundles across the casein and legacy casein roots; dry-run by default, `--apply` to act (systemd units alongside, installed pointing at `/opt/casein/deploy-build`)
- `lib/casein/runtimes/worktree_alarm.ex` — alarm logic (`workspace.agent_worktree_stale` audit events)
- `scripts/verify_agent_pairing.sh` — MCP smoke test
- `.devbox-agent.env` — generated token/URL/workspace ids (gitignored)
- `.devbox-agent-prompt.txt` — copy-paste prompt for external agents
- `lib/casein/agents/activity.ex` — live MCP activity feed
- `lib/casein/agents/mcp_audit.ex` — audit + activity for terminal/preview MCP
- `docs/tmux_control_plane.md` — tmux topology/templates API

### Phoenix v1.8 guidelines

- **Always** begin your LiveView templates with `<Layouts.app flash={@flash} ...>` which wraps all inner content
- The `MyAppWeb.Layouts` module is aliased in the `my_app_web.ex` file, so you can use it without needing to alias it again
- Anytime you run into errors with no `current_scope` assign:
  - You failed to follow the Authenticated Routes guidelines, or you failed to pass `current_scope` to `<Layouts.app>`
  - **Always** fix the `current_scope` error by moving your routes to the proper `live_session` and ensure you pass `current_scope` as needed
- Phoenix v1.8 moved the `<.flash_group>` component to the `Layouts` module. You are **forbidden** from calling `<.flash_group>` outside of the `layouts.ex` module
- Out of the box, `core_components.ex` imports an `<.icon name="hero-x-mark" class="w-5 h-5"/>` component for hero icons. **Always** use the `<.icon>` component for icons, **never** use `Heroicons` modules or similar
- **Always** use the imported `<.input>` component for form inputs from `core_components.ex` when available. `<.input>` is imported and using it will save steps and prevent errors
- If you override the default input classes (`<.input class="myclass px-2 py-1 rounded-lg">)`) class with your own values, no default classes are inherited, so your
custom classes must fully style the input

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason

## Test guidelines

- **Targeted tests while iterating; repo-wide gates only at pre-push (or when
  asked).** Run the files that exercise the code you changed
  (`mix test path/to/file_test.exs`). Save full-suite / `mix precommit` /
  `scripts/pre-push-check.sh` for the end of the change. This checkout is a
  **shared working tree**: other sessions leave uncommitted diffs that make
  repo-wide gates fail for reasons unrelated to your work, and attributing
  those failures costs more than the gate saves during iteration.
- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages
<!-- phoenix:elixir-end -->

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:ecto-start -->
## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
<!-- phoenix:ecto-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`**. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
         socket
         |> assign(:messages_empty?, messages == [])
         # reset the stream with the new messages
         |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @streams.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- When updating an assign that should change content inside any streamed item(s), you MUST re-stream the items
  along with the updated assign:

      def handle_event("edit_message", %{"message_id" => message_id}, socket) do
        message = Chat.get_message!(message_id)
        edit_form = to_form(Chat.change_message(message, %{content: message.content}))

        # re-insert message so @editing_message_id toggle logic takes effect for that stream item
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:editing_message_id, String.to_integer(message_id))
         |> assign(:edit_form, edit_form)}
      end

  And in the template:

      <div id="messages" phx-update="stream">
        <div :for={{id, message} <- @streams.messages} id={id} class="flex group">
          {message.username}
          <%= if @editing_message_id == message.id do %>
            <%!-- Edit mode --%>
            <.form for={@edit_form} id="edit-form-#{message.id}" phx-submit="save_edit">
              ...
            </.form>
          <% end %>
        </div>
      </div>

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView JavaScript interop

- Remember anytime you use `phx-hook="MyHook"` and that JS hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Always** provide an unique DOM id alongside `phx-hook` otherwise a compiler error will be raised

LiveView hooks come in two flavors, 1) colocated js hooks for "inline" scripts defined inside HEEx,
and 2) external `phx-hook` annotations where JavaScript object literals are defined and passed to the `LiveSocket` constructor.

#### Inline colocated js hooks

**Never** write raw embedded `<script>` tags in heex as they are incompatible with LiveView.
Instead, **always use a colocated js hook script tag (`:type={Phoenix.LiveView.ColocatedHook}`)
when writing scripts inside the template**:

    <input type="text" name="user[phone_number]" id="user-phone-number" phx-hook=".PhoneNumber" />
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PhoneNumber">
      export default {
        mounted() {
          this.el.addEventListener("input", e => {
            let match = this.el.value.replace(/\D/g, "").match(/^(\d{3})(\d{3})(\d{4})$/)
            if(match) {
              this.el.value = `${match[1]}-${match[2]}-${match[3]}`
            }
          })
        }
      }
    </script>

- colocated hooks are automatically integrated into the app.js bundle
- colocated hooks names **MUST ALWAYS** start with a `.` prefix, i.e. `.PhoneNumber`

#### External phx-hook

External JS hooks (`<div id="myhook" phx-hook="MyHook">`) must be placed in `assets/js/` and passed to the
LiveSocket constructor:

    const MyHook = {
      mounted() { ... }
    }
    let liveSocket = new LiveSocket("/live", Socket, {
      hooks: { MyHook }
    });

#### Pushing events between client and server

Use LiveView's `push_event/3` when you need to push events/data to the client for a phx-hook to handle.
**Always** return or rebind the socket on `push_event/3` when pushing events:

    # re-bind socket so we maintain event state to be pushed
    socket = push_event(socket, "my_event", %{...})

    # or return the modified socket directly:
    def handle_event("some_event", _, socket) do
      {:noreply, push_event(socket, "my_event", %{...})}
    end

Pushed events can then be picked up in a JS hook with `this.handleEvent`:

    mounted() {
      this.handleEvent("my_event", data => console.log("from server:", data));
    }

Clients can also push an event to the server and receive a reply with `this.pushEvent`:

    mounted() {
      this.el.addEventListener("click", e => {
        this.pushEvent("my_event", { one: 1 }, reply => console.log("got reply from server:", reply));
      })
    }

Where the server handled it via:

    def handle_event("my_event", %{"one" => 1}, socket) do
      {:reply, %{two: 2}, socket}
    end

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In the template, the form form assign can be passed to the `<.form>` function component:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <.input field={@form[:field]} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView, and the `<.input>` component in the template. In the template **always access forms this**:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <.input field={@form[:field]} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <.input field={@changeset[:field]} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
