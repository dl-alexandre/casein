# DevIDE MCP Servers

This directory contains MCP (Model Context Protocol) servers that let AI agents and tools interact with a running DevIDE instance in a **governed, auditable way**.

## devide_server.py

The primary integration point for autonomous agents (especially Odysseus, but also Claude Desktop, Cursor, Windsurf, opencode-based agents, etc.).

It turns DevIDE's public API + allowlist into first-class tools an agent can call:

- `devide_list_workspaces`
- `devide_get_status` (rich snapshot including detected agent capabilities like opencode / fff / tidewave)
- `devide_list_commands`
- `devide_run_command` (only safe allowlisted commands — the server enforces this)
- `devide_get_recent_runs` / `devide_get_run`
- `devide_get_audit`

### Why this exists

DevIDE's whole reason for being is to be a **safe execution authority** that agents (and humans) can be clients of, without giving them unrestricted power.

By exposing it via MCP, a powerful agent like the one inside Odysseus can:
- Do real development work (`mix test`, `mix compile`, launch `opencode`, `claude`, etc.)
- Stay inside policy, workspace modes, and the full audit/dossier trail
- Use durable tmux-backed sessions when needed (via the governed path)
- Still have all the nice chat/memory/research UI from Odysseus

This is the recommended integration path instead of replacing DevIDE.

### Requirements (for the MCP server process)

- Python 3.10+
- `pip install mcp httpx`

(When used from inside an Odysseus checkout you can add `httpx` and `mcp` to `requirements-optional.txt` or the agent's environment.)

### Environment variables (required)

```bash
export DEV_IDE_BASE_URL=http://localhost:4000
export DEV_IDE_API_TOKEN="the-same-token-you-use-for-DEV_IDE_API_TOKEN-on-the-server"
# optional
export DEV_IDE_TIMEOUT=30
```

### Running it directly (for testing / Odysseus registration)

```bash
python mcp_servers/devide_server.py
```

It speaks stdio (the standard for local MCP servers).

### Registering in Odysseus

In Odysseus Settings → MCP / Tools / Servers (the exact label may vary by version):

- Add a new stdio server
- Command: `python`
- Args: absolute path to `.../dev_ide/mcp_servers/devide_server.py` (or make a small wrapper script)
- Environment: pass the two DEV_IDE_* vars above

After registration the agent should be able to discover and call the `devide_*` tools.

You can also run it under the same Python env as Odysseus if you want the agent to have it always available.

### Safety notes

- The MCP server itself does **not** decide what may run — it only forwards to DevIDE.
- DevIDE's allowlist, `Policy`, workspace `mode`, and audit system are still fully in control.
- `devide_run_command` will fail (with a clear audited denial) for anything not on the allowlist or disallowed by current policy.
- Prefer `opencode`, `claude`, `grok`, etc. command_ids when you want the agent to continue working *inside* the workspace terminal/session.

### Current allowlist (example)

See `lib/dev_ide/commands.ex` for the live definition. At the time of writing it includes the usual mix tasks plus direct entry points for several agent CLIs (`opencode`, `claude`, `grok`, ...).

### Development

- The server is deliberately thin. It does not implement the runner protocol or claim leases itself — it uses the high-level "submit run" surface that a coordinator and operators also use.
- If you add new safe commands on the Elixir side, just update the `KNOWN_ALLOWLIST` here for better descriptions (the server will still enforce the real list).

See also: `docs/odysseus_evaluation.md` for the broader "why integrate instead of replace" discussion.
