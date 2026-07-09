---
name: workspace-agent-pair
description: >
  Ensure a product workspace agent runtime (OpenCode, Claude, Grok, Codex) has
  DevIDE terminal/preview/artifact MCP plus host infrastructure skills
  (preview-ui-walk, delegate-to-grok, this skill). Use when the user says pair
  opencode, share MCP/skills with a workspace agent, "tools missing", "skill not
  found outside dev_ide", run preview-ui-walk from another workspace, or
  OpenCode/Claude cannot see DevIDE MCP on a product checkout.
---

# Workspace agent pair

Host infrastructure for **product-repo** agents. DevIDE skills and MCP live with
the DevIDE host, not with OneBackend / milc-devbox / etc. This skill makes a
target workspace agent able to drive DevIDE the same way a dalexandre-devide
agent does.

**Do not** hand-copy tokens into chat. **Do not** write bearer tokens into
tracked git files (staging uses `{env:DEV_IDE_API_TOKEN}` / `${DEV_IDE_API_TOKEN}`).

## When to run

- User asks to pair OpenCode (or Claude/Grok/Codex) on a named workspace
- `preview-ui-walk` / `delegate-to-grok` missing outside the dev_ide checkout
- OpenCode `debug config` has no `devide-*-<workspace>` MCP servers
- Terminal/preview MCP tools 401 or wrong-workspace scope

## 1. Resolve the workspace

Prefer already-paired session env (tmux session for that workspace):

```bash
echo "$DEVIDE_WORKSPACE_NAME" "$DEVIDE_WORKSPACE_ID" "$DEVIDE_CHECKOUT"
# or:
source ~/.devide/agent-mcp/<workspace-name>/env.sh
```

| Var | Meaning |
|-----|---------|
| `DEVIDE_WORKSPACE_NAME` | e.g. `dalexandre-devbox`, `dalexandre-reports` |
| `DEVIDE_WORKSPACE_ID` | UUID used in MCP query strings |
| `DEVIDE_CHECKOUT` | Product tree the agent should `cd` into |
| `DEVIDE_AGENT_MCP_HOME` | `~/.devide/agent-mcp/<name>/` staging |
| `DEVIDE_TERMINAL_MCP_URL` / `PREVIEW` / `ARTIFACT` | Pre-scoped MCP URLs |
| `DEV_IDE_API_TOKEN` | Workspace-scoped bearer (never echo) |

If `~/.devide/agent-mcp/<name>/env.sh` is **missing**, this is first-time pairing —
run `scripts/refresh-devbox-agent-pairing.sh` / `setup-devbox-agent-pairing.sh` for
that workspace (needs host admin token). This skill only **reinstalls** MCP
configs + skills from existing staging.

## 2. Run the ensure script (preferred)

From any cwd (use a path that actually exists on the box):

```bash
bash /data/workspaces/dalexandre/dev_ide/scripts/ensure-workspace-agent-pair.sh \
  --workspace <name> \
  --runtime opencode \
  --verify
```

Or when session env is already set:

```bash
bash /data/workspaces/dalexandre/dev_ide/scripts/ensure-workspace-agent-pair.sh --runtime all --verify
```

What it does:

1. Sources `~/.devide/agent-mcp/<name>/env.sh`
2. Stages host skills (`DEVIDE_GLOBAL_AGENT_SKILLS`) into the runtime’s skill home
3. Writes project MCP config where that runtime discovers it
4. Optionally verifies terminal MCP `tools/list` + OpenCode skill/config

### Runtime matrix

| Runtime | Skills land in | MCP lands in | Launch |
|---------|----------------|--------------|--------|
| **OpenCode** | `~/.config/opencode/skills`, project `.opencode/skills` (+ auto-loads `~/.claude/skills`) | project `.opencode/opencode.json` from staging | `cd $DEVIDE_CHECKOUT && opencode` (restart to reload) |
| **Claude** | `~/.claude/skills` (or owner `CLAUDE_CONFIG_DIR`) | staging `.mcp.json` via `launch-devide-agent.sh claude --mcp-config` | `bash …/launch-devide-agent.sh claude` |
| **Grok** | (n/a skill loader; host skills still staged for siblings) | project `.mcp.json` (worktree preferred; ensure script can write primary) | `bash …/launch-devide-agent.sh grok` |
| **Codex** | n/a | per-launch `-c mcp_servers…` from launcher | `bash …/launch-devide-agent.sh codex` |

Default host skill allowlist: `delegate-to-grok`, `preview-ui-walk`,
`workspace-agent-pair`. Override with `DEVIDE_GLOBAL_AGENT_SKILLS="…"`.

## 3. Manual fallback (if the script is unavailable)

```bash
set -a
source ~/.devide/agent-mcp/<name>/env.sh
set +a

SKILL_SRC=/data/workspaces/dalexandre/dev_ide/.claude/skills
# shellcheck source=/dev/null
source /data/workspaces/dalexandre/dev_ide/scripts/lib/agent-skills.sh

# skills
agent_skills_install "$SKILL_SRC" "$HOME/.claude"
agent_skills_install "$SKILL_SRC" "$HOME/.config/opencode"
mkdir -p "$DEVIDE_CHECKOUT/.opencode"
agent_skills_install "$SKILL_SRC" "$DEVIDE_CHECKOUT/.opencode"

# OpenCode MCP
cp "$DEVIDE_AGENT_MCP_HOME/opencode.json" "$DEVIDE_CHECKOUT/.opencode/opencode.json"
chmod 600 "$DEVIDE_CHECKOUT/.opencode/opencode.json"
```

## 4. Verify (never print the token)

```bash
# Terminal MCP alive + scoped
# (ensure script --verify does this)
python3 - <<'PY'
# tools/list against DEVIDE_TERMINAL_MCP_URL with Authorization bearer
# expect terminal_list_sessions among tools
PY

# OpenCode sees skills + MCP (use real binary, not a shim that re-enters launch)
cd "$DEVIDE_CHECKOUT"
~/.opencode/bin/opencode debug skill   # expect preview-ui-walk, workspace-agent-pair
~/.opencode/bin/opencode debug config  # expect devide-terminal-<workspace>, preview, artifact
```

Wrong-workspace check: MCP server names / URLs must include **this**
`workspace_id` / name, not `dalexandre-devide` unless that is the target.

## 5. After pairing — do the actual work

| Goal | Next skill / action |
|------|---------------------|
| App UI smoke (any surface) | `preview-ui-walk` — product workflows under `.devide/preview-walk.json` and/or `.devide/preview-walks/<id>.json` |
| Author/improve a walk | Edit/add product manifests; do not fork the skill |
| Parallel Grok implementation | `delegate-to-grok` |
| DevIDE-itself UI check | `verify` (only inside dev_ide checkout) |

**Restart OpenCode** after pairing — config and skills are load-time, not hot-reload.

## Safety

- Workspace-scoped token only — refuse to materialize admin tokens into agent configs
  (`materialize-agent-mcp.sh` already enforces this).
- Do not commit `.opencode/opencode.json` / `.mcp.json` when they embed workspace URLs;
  prefer gitignore (ensure script appends `opencode.json` under `.opencode/.gitignore`
  when that file exists).
- Pairing does not start the product app or mock upstreams — only agent client config.

## Quick reference

```text
missing env.sh          → refresh/setup pairing (human/host)
env.sh present          → ensure-workspace-agent-pair.sh --verify
OpenCode no MCP         → --runtime opencode (rewrites .opencode/opencode.json)
skill not found         → ensure script (stages allowlist)
wrong workspace tools   → source the OTHER workspace env.sh; re-run ensure
then run walk           → skill preview-ui-walk
```
