# Terminal MCP

Casein exposes tmux session control to coding agents through a narrow MCP
JSON-RPC endpoint:

```text
POST /api/terminals/mcp
```

The endpoint uses the same bearer-token gate as the rest of the API:

```text
Authorization: Bearer $CASEIN_API_TOKEN
```

Agents should discover this endpoint from the `terminal_mcp` capability. The
capability is exposed through normal agent capability detection and through
`GET /api/workspaces/:id/status` as `agent_capabilities`. It advertises the
MCP URL, `auth_type: "bearer"`, HTTP JSON-RPC transport, and current tool
names.

## Streamable HTTP transport

The endpoint supports the MCP Streamable HTTP transport in addition to plain
POST JSON-RPC:

- `initialize` returns an `Mcp-Session-Id` response header.
- `GET /api/terminals/mcp` with that `Mcp-Session-Id` header opens a
  server→client SSE stream (`text/event-stream`) for `notifications/*` pushes.
- `DELETE /api/terminals/mcp` with the header ends the session.

Sessions are optional and additive: a POST without an `Mcp-Session-Id` behaves
exactly like the stateless transport, so existing clients are unaffected. A POST
that supplies an unknown id gets `404 unknown_mcp_session`, signalling the client
to re-`initialize`. Missing or unknown streamable-session errors preserve the
top-level `error` string and include `code`, `message`, and
`error_version: "mcp-streamable-http-v1"`. Server pushes are delivered through
`Casein.Agents.MCPSessions.notify/2`.
Session ids are bound to their server, workspace, and authenticated bearer scope;
another workspace, MCP surface, or managed-agent capability receives the same
`404 unknown_mcp_session` response as an unknown id.

## Access scope

Workspace and global bearers retain their existing authority. Managed Grok uses
an expiring `grokcap_*` bearer instead: it advertises only its exact direct-tool
grant, is bound to one workspace/private leader/tmux session/agent pane, and is
intersected with current workspace mode and write-unlock policy on every request.
It cannot call `search_tools` or `invoke_tool`, use a different MCP endpoint, or
reuse another bearer's streamable session id. All terminal tools still touch only
Casein-managed tmux sessions (`casein_*` prefix), never unrelated sessions.

**Pass `workspace_id` on every call unless the MCP URL is pre-scoped.** Generated
same-host agent configs include `?workspace_id=<manager UUID>` on the MCP URL,
and the transport injects that value into tool calls when the agent omits it.
When set, discovery and mutation are scoped to that workspace's sessions. Casein
resolves both the manager UUID and the workspace **name** to tmux prefixes —
sessions are named `casein_<workspace_name>_<sid>`, not `casein_<uuid>_`.
Cross-workspace session access is rejected with `workspace_mismatch`.

Global tokens may initialize and list the available tools, but Terminal MCP
`tools/call` execution requires a workspace-scoped API token. A global token
receives `403 workspace_scoped_token_required` before the tool handler runs, so
it cannot list sessions, capture scrollback, or inject terminal input through
MCP. Prefer always scoping in production and dogfood setups.

## Command Policy

`terminal_send_command` / `terminal_send_agent_command` run arbitrary shell, so
Casein runs an allow/deny gate in front of them
(`Casein.Agents.TerminalCommandPolicy`). The default is a small denylist for
high-risk host commands such as recursive root deletes, pipe-to-shell downloads,
and `sudo`. Configure it with an allowlist or denylist of regexes matched
against the full command string:

```elixir
# config/runtime.exs (or dev.exs)
config :casein, :terminal_command_policy, {:allowlist, ["^mix ", "^git "]}
config :casein, :terminal_command_policy, {:denylist, ["rm -rf", "curl "]}
# Trusted local-only setups may opt out explicitly:
config :casein, :terminal_command_policy, :disabled
```

Releases can use the `CASEIN_TERMINAL_COMMAND_POLICY` env var instead (JSON):

```bash
CASEIN_TERMINAL_COMMAND_POLICY='{"mode":"allowlist","patterns":["^mix ","^git "]}'
```

A blocked call returns a structured `command_blocked` tool error and is recorded
in the **Live MCP activity** feed. Raw key tools (`terminal_send_keys` /
`terminal_send_agent_keys`) are never gated — they carry control keys like `C-c`
and TUI input, so gating them would break interactivity.

For ordinary workspace tokens, treat the policy as a **guardrail, not a hard
security boundary**: because the
key tools are intentionally ungated, a determined agent could still synthesize a
command by sending its characters plus an Enter key. The policy stops a
well-behaved agent (and honest mistakes) from running disallowed *commands*; the
bearer token (and optional per-workspace tokens) remains the actual trust
boundary. Managed Grok capabilities do not expose either raw terminal-input
tool; they expose agent-pane shortcuts only while write is unlocked.

## Terminal mode and MCP

Terminals are raw everywhere — there is no per-window mode and no governed
plane (see `docs/terminal.md`). Agents always interact with real tmux panes via
`terminal_send_command` / `terminal_send_keys`; the operator's LiveView chrome
never changes tmux topology or MCP behaviour.

## Agent pairing quickstart (human + external agent)

Side-by-side Casein development uses a built-in tmux template and explicit pane
targeting so operator keystrokes do not collide with agent MCP writes.

### Operator (human)

1. Open the workspace in Casein LiveView.
2. Set workspace mode to **manual** (raw multi-pane terminal).
3. **Agents → Apply Agent Pair layout** once per session.
   - Operator pane stays **focused** (human types here).
   - **Agent** pane receives MCP `terminal_send_command` / `terminal_send_keys`.
   - **Verify** pane is for `git status` / test output.
4. Watch **Agents → Live MCP activity** during agent work.

### External agent

1. Source env (devbox example):

   ```bash
   source /path/to/checkout/.devbox-agent.env
   ```

2. Always pass `workspace_id` (manager UUID or workspace name).

3. Tool flow:

   ```text
   terminal_context(workspace_id)        # returns recommended next_tool / next_arguments
     → terminal_agent_pane(workspace_id) # finds the marked agent_pair pane
     → terminal_send_agent_command(command, workspace_id)
     → terminal_capture_agent(lines: 100, ansi: false, workspace_id)
   ```

4. Prefer the `*_agent_*` shortcut tools. They refuse to mutate when the
   dedicated agent pane cannot be identified, instead of falling back to the
   operator's focused pane. Lower-level `terminal_send_command` still requires
   explicit pane targeting for safety.

5. For UI checks, use Preview MCP from the same workspace/session context
   (`preview_open_app` → observe/screenshot → `preview_close`). In worktree
   sessions, use the session-scoped Preview MCP URL so preview panes open beside
   the agent session instead of the base workspace lane. If a preview pane is
   already visible, use `preview_observe_pane` / `preview_navigate_pane` with
   that `pane_id`. See `docs/preview_mcp.md`.

### Agent-created worktrees

When an agent creates a Git worktree, it should report it back to Casein instead
of expecting it to appear as a new devbox workspace:

```text
terminal_report_worktree(
  workspace_id,
  worktree_path,
  branch?,
  agent?,
  runner_id?,
  session_id?,
  tmux_session_id?,
  ensure_preview_started?, # false by default; opt in only when this worktree needs an owned server
  exit_status?,   # "landed" | "wip" | "handoff" — call again at session end
  handoff?        # short status for the next agent/operator
)
```

Casein records the worktree as a child runtime context under the parent
workspace. The Agents panel then shows it in **Agent Worktrees** with an explicit
Attach shell action. Worktrees remain out of the main workspace picker.

When attached to a worktree session, keep Terminal MCP and Preview MCP on the
session-scoped URLs for that session. Do not open or navigate previews in the
base workspace session unless the operator explicitly asks you to inspect the
base checkout.

### Semantic agent state

Casein tracks a semantic state per agent pane — `working`, `blocked` (waiting for
input/permission), `done` (turn complete), or `idle` — surfaced as loud/calm
badges in the session bar and the workspace picker. State comes from two sources,
reconciled by staleness rules (a live title spinner always wins over a stale
report; `blocked`/`done` are never inferred from the title):

- **Explicit reports** via the MCP tool below. Launched agents report
  automatically (opt out of all of it with `CASEIN_AGENT_STATE_HOOKS=0`):
  - **Claude Code**: hooks in a materialized `--settings` file run
    `casein-agent-state.sh` on UserPromptSubmit/PreToolUse (working),
    Notification (blocked), Stop (done), SessionStart/End (idle). The
    materializer stages the script into the workspace MCP home and the hook
    resolves it via `$CASEIN_AGENT_MCP_HOME`, so it works for any paired
    project, not only the casein checkout itself.
  - **Grok**: the launcher installs a global hook file
    (`~/.grok/hooks/casein-agent-state.json`, from
    `scripts/agent-hooks/grok-casein-agent-state.json`) that runs the same
    script on the equivalent Grok events; `stop_failure` (turn died on an API
    error) also maps to blocked. Grok's camelCase `sessionId` and
    `transcriptPath` hook fields are retained as pane metadata. The hook command
    is env-guarded, so grok sessions outside Casein pairing no-op silently.
  - **Codex**: the launcher injects lifecycle hooks for SessionStart,
    UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop, and
    SubagentStart/Stop. `casein-codex-notify.sh` sends their JSON to the
    workspace-scoped Codex hook receiver; the completion-only `notify` program
    remains enabled as a transition fallback. Hooks report working, blocked,
    done, and parent/child agent state without parsing terminal scrollback.
- **Dispatch reports**: a successful `terminal_send_agent_command` (or
  `terminal_paste_agent_text` with `submit`) reports `working` for the target
  pane itself, so every runtime gets a working edge the moment work is sent.
- **Title heuristic** (`PaneState`) as a fallback when no live report exists.

```text
terminal_report_agent_state(
  workspace_id,
  state,        # "working" | "blocked" | "done" | "idle"
  message?,     # short free-text (truncated to 200 chars)
  pane?,        # defaults to the dedicated agent pane
  session?,
  transcript_path?,   # supported runtime's exact session JSONL path
  agent_session_id?,  # runtime-native session id, e.g. Grok sessionId
  source?       # "agent" | "hook"
)
```

A transition into `blocked` emits an `agent.blocked` audit event, which reaches
the in-app banner and OS push.

`terminal_agent_transcript` reads the reported path through a runtime adapter
and returns one normalized entry stream. Claude paths are restricted to the
configured Claude/auth-profile roots; Grok paths must be the exact
`~/.grok/sessions/**/updates.jsonl` shape. tmux capture is not used as the
transcript source.

An orchestrating agent can wait on another agent's state instead of polling
`terminal_capture`:

```text
terminal_wait_agent_state(
  workspace_id,
  states,        # e.g. ["blocked", "done"]
  timeout_ms?,   # default 30000, capped at 55000
  pane?,
  session?
)
```

It returns immediately if the pane is already in a target state. A timeout is not
an error — the result carries `timed_out: true` and `matched: false`; re-issue the
call to keep long-polling.

### Agent skills (cross-repo)

Casein-infrastructure skills live in the casein repo under `.claude/skills`, so
they only travel with casein checkouts. But agents routinely run in **other**
product-repo worktrees (e.g. auditing OneBackend-v3) that do not carry them — so
an orchestrator there could not invoke `delegate-to-worker` even though delegation
is host infrastructure, not app code.

On every Claude and Codex launch the launcher stages the allow-listed global skills into
the launch's resolved Claude config home (`$CLAUDE_CONFIG_DIR`, the per-owner auth
profile when the workspace uses one, else `~/.claude`) or Codex home
(`$CODEX_HOME`, else `~/.codex`), so they are available in any repo. On every
**OpenCode** launch it stages the same allowlist into
`~/.config/opencode/skills` and the project `.opencode/skills` (OpenCode also
auto-loads `~/.claude/skills` as external skills). Staging is idempotent and
refreshes when the canonical source changes (`scripts/lib/agent-skills.sh`). The
allowlist defaults to `delegate-to-worker`, `preview-ui-walk`, and
`workspace-agent-pair` (re-pair any product workspace's agent MCP + skills);
project-only skills like `verify` are excluded because they only make sense
inside the casein checkout, where the project `.claude/skills` copy already
provides them. Override with `CASEIN_GLOBAL_AGENT_SKILLS="a b c"`, or opt out
entirely with `CASEIN_AGENT_SKILLS=0`.

Staging also **prunes**. Because staging is a copy, dropping or renaming a skill
would otherwise leave the old directory in every config home forever, so agents
would see the retired skill alongside its replacement — with the stale copy
carrying the wrong instructions. Each staged copy is marked with a
`.casein-staged` file and is removed once its name leaves the allowlist. Copies
staged before that marker existed are reached by name through
`CASEIN_RETIRED_AGENT_SKILLS` (currently `delegate-to-grok`, renamed to
`delegate-to-worker`); that list can be trimmed once those copies have aged out.
A skill directory with neither the marker nor a retired name was not staged by
Casein and is never touched.

Cross-repository worker spawning must use Casein's host helper, not a launcher
path under the product checkout:

```bash
bash /data/workspaces/dalexandre/casein/scripts/spawn-agent-worker.sh \
  grok <task-slug> <casein-session>
```

The helper resolves the product's primary checkout, sources its materialized
workspace environment inside the fresh tmux window, pins the requested session,
and invokes Casein's own `launch-casein-agent.sh`. This preserves workspace MCP
pairing and stale-socket repair while forcing the worker into an isolated
product worktree; product repositories do not need to vendor Casein launch
scripts.

OpenCode MCP is injected as project `.opencode/opencode.json` from the workspace
staging tree whenever the launch is paired (`CASEIN_WORKSPACE_ID` +
`CASEIN_AGENT_MCP_HOME`) — primary checkout or agent worktree. Grok still keeps
project `.mcp.json` injection worktree-only to avoid colliding shared primary
checkouts.

**Ad-hoc re-pair (any product workspace):** skill `workspace-agent-pair` or:

```bash
bash scripts/ensure-workspace-agent-pair.sh \
  --workspace <name> --runtime opencode --verify
```

### Devbox smoke test

```bash
source .devbox-agent.env
WORKSPACE_ID=$CASEIN_WORKSPACE_ID bash scripts/verify_agent_pairing.sh --ci
```

On the milc devbox, MCP is also reachable at
`https://casein.devbox.milcgroup.com/api/terminals/mcp` (same bearer token).
Same-host agents may use `http://127.0.0.1:4000/api/terminals/mcp`.

Deploy durability: commit and push to `master` before relying on devbox
behavior — `deploy-devbox.yml` replaces `/opt/casein/release` from git. See
`AGENTS.md` (Devbox agent pairing).

## Tool Flow

1. Call `initialize`.
2. Call `tools/list`.
3. Call `terminal_context` with `workspace_id` when unsure. It returns the
   recommended session, agent pane safety, and exact `next_tool` /
   `next_arguments`.
4. Call `terminal_list_sessions` with `workspace_id` to discover session names
   (e.g. `casein_my_workspace_u-alice-abcd1234`).
5. Call `terminal_topology` with that `session` and `workspace_id` to inspect
   windows and panes (each pane carries an id like `%3`).
6. Read output with `terminal_capture` (pass `pane`, `lines` to tail,
   `ansi: false` for plain text), and drive the session with
   `terminal_send_keys` (raw keys, e.g. `C-c`) or `terminal_send_command`
   (a shell command + Enter). Target the **agent** pane explicitly.
   Prefer `terminal_paste_agent_text` for multiline/literal text.

All session-scoped tools require a `casein_`-prefixed session that currently
exists; a `pane` must belong to that session.

## Talking to a busy agent: the sticky next prompt

Pasting into a pane whose agent is mid-turn is how messages get lost. The text
lands in a composer that never submits, or the injection interrupts a turn that
was about to succeed. Use `terminal_set_next_prompt` instead: Casein holds the
message and injects it on the pane's next state edge.

```json
{"name": "terminal_set_next_prompt",
 "arguments": {"workspace_id": "ws-1", "pane": "%3",
               "text": "master moved — rebase before you push",
               "deliver_when": "next_done",
               "coalesce_key": "orchestrator-1"}}
```

Semantics worth knowing before you rely on it:

- **One slot per pane.** A second `terminal_set_next_prompt` *replaces* the
  first. This is not a queue; `coalesce_key` only tells you whether the pending
  message is still yours (and lets `terminal_clear_next_prompt` refuse to clear
  someone else's).
- **`deliver_when` defaults to `next_idle`, which covers `done` too** — read it
  as "when the agent stops working". Claude's hook emits a literal `idle` only
  at session start/end, so `next_idle` alone would rarely fire. Use `next_done`
  when you mean a completed turn and `next_blocked` for permission prompts.
- **Already-free panes get it immediately.** `status` in the response is
  `"delivered"` rather than `"pending"` when the requested edge had already
  passed, so a message is never silently held forever.
- **It is dropped, not delivered, if the agent restarts** (bound
  `agent_session_id` changes), the pane dies, or `expires_in_seconds` elapses
  (24h default).
- **Nothing interrupts a working agent.** There is no interrupt flag by design.

`terminal_topology` and `terminal_agent_pane` flag panes carrying a staged
message with `pending_next_prompt: true`, so you can see what is queued without
a per-pane call.

## Knowing whether a submit actually landed

`terminal_send_agent_command`, `terminal_send_command`, and
`terminal_paste_agent_text` (with `submit: true`) verify that the agent consumed
the Enter instead of reporting success as soon as tmux accepted the keystroke.
Responses carry `submitted`, `delivery`, `confirmation`, and `enter_presses`:

| `delivery` | Meaning |
|------------|---------|
| `delivered` | The runtime reported a new turn, or the pane visibly redrew. |
| `not_confirmed` | Two Enter presses and the pane never moved. The text may be sitting unsent — capture the pane before resending. |
| `uncertain` | The pane could not be captured, so neither signal was readable. |
| `skipped` | `confirm: false`, or there was nothing to submit. |

### Delivery contract (do not double-Enter yourself)

A single Enter often fails when it is folded into the same `paste-buffer` call
as a multiline brief: OpenCode (and similar TUIs) are still draining the paste
when the keystroke arrives, so Enter becomes a newline mid-composer rather than
a submit (#886). Casein owns that race:

1. Paste text **without** Enter (`paste-buffer` only).
2. Settle until the pane stops redrawing (paste drain finished), **then**
   snapshot the screen baseline.
3. Press Enter and watch for a hook or a post-baseline screen change.
4. If unconfirmed, re-baseline and press Enter **once more** (max two presses).
5. Return `delivery` honestly — never claim success from tmux write alone.

Operators and orchestrators should **not** send a second Enter as folklore. Call
with `submit: true` (paste) or the normal command tools and trust
`delivery: "delivered"` / `submitted: true`. If you still see
`not_confirmed`, capture the pane before resending, or use
`terminal_set_next_prompt` when the agent is mid-turn.

### Explicit pane paste (no agent_pair required)

`terminal_paste_agent_text` accepts an optional `pane` id. When `pane` is set,
the paste goes to that pane without requiring the agent_pair role marker — the
fleet path for worker briefs. When `pane` is omitted, the dedicated agent_pair
pane is still required.

An unconfirmed submit is reported, not raised on the fire-and-forget tools: the
signals are heuristics over a screen Casein does not own. Pass `confirm: false`
when the keystroke itself is the point (answering a TUI menu or a y/n prompt),
where no new turn starts and the confirmation would always read as unconfirmed.
`terminal_set_next_prompt` remains strict and retries on the next edge.

## Smoke Test

Set the base URL, token, and workspace:

```bash
export CASEIN_URL=http://localhost:4000
export CASEIN_API_TOKEN=...
export WORKSPACE_ID=my-workspace-id
```

Or run the bundled verifier:

```bash
WORKSPACE_ID=$WORKSPACE_ID bash scripts/verify_agent_pairing.sh
```

Initialize:

```bash
curl -sS -X POST "$CASEIN_URL/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {"protocolVersion": "2025-03-26"}
  }'
```

List tools:

```bash
curl -sS -X POST "$CASEIN_URL/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list"
  }'
```

List live sessions (scoped):

```bash
curl -sS -X POST "$CASEIN_URL/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "terminal_list_sessions",
      "arguments": {"workspace_id": "'"$WORKSPACE_ID"'"}
    }
  }'
```

Read the tail of a pane (plain text):

```bash
curl -sS -X POST "$CASEIN_URL/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "terminal_capture",
      "arguments": {
        "workspace_id": "'"$WORKSPACE_ID"'",
        "session": "casein_my_workspace_main",
        "pane": "%3",
        "lines": 50,
        "ansi": false
      }
    }
  }'
```

Run a command in the agent pane:

```bash
curl -sS -X POST "$CASEIN_URL/api/terminals/mcp" \
  -H "authorization: Bearer $CASEIN_API_TOKEN" \
  -H "content-type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "terminal_send_command",
      "arguments": {
        "workspace_id": "'"$WORKSPACE_ID"'",
        "session": "casein_my_workspace_main",
        "pane": "%3",
        "command": "mix test"
      }
    }
  }'
```

## Notes

`terminal_send_keys` and `terminal_send_command` inject input into a live
shell. Access control is the API token plus the `casein_` session guardrail and
workspace scoping; command execution can additionally be constrained with the
configurable [command policy](#command-policy).
Both also refuse a git command that would write a worktree another pane is
working in — `shared_worktree_mutation`, naming the tree and the other panes,
overridable per call with `allow_shared_worktree: true`. Concurrent git in one
worktree corrupts index state rather than failing cleanly, so this is the one
class of command where a `sent` receipt was worse than an error.
`terminal_capture` returns the full scrollback by default; pass `lines` to
bound what the agent reads.
When `workspace_id` is omitted, `terminal_list_sessions` omits the field from
the response instead of returning `workspace_id: null`.

Mutating terminal MCP calls are audited and appear in the workspace **Live MCP
activity** feed (Agents tab).
