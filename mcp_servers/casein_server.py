"""
casein_server.py

MCP server that exposes a Casein instance as safe, governed tools for
autonomous agents (Odysseus, Claude Desktop, Cursor, opencode, etc.).

This lets an agent use durable, policy-checked workspace execution
without getting raw unrestricted shell or filesystem power on the host.

All actions flow through Casein's allowlist, Policy, audit trail,
and (when in fleet mode) the runner lease/claim protocol.

Quick start (with a running Casein at localhost:4000):
    CASEIN_BASE_URL=http://localhost:4000 \
    CASEIN_API_TOKEN=your-secure-token \
    python mcp_servers/casein_server.py

Register in Odysseus (Settings → MCP Servers) by pointing at the
absolute path to this file (or run it as a stdio server).

Env vars (required):
    CASEIN_BASE_URL   e.g. http://localhost:4000 or https://casein.example.com
    CASEIN_API_TOKEN  the bearer token (same as CASEIN_API_TOKEN on the server)

Optional:
    CASEIN_TIMEOUT    request timeout in seconds (default 30)

Safety model (by design):
- Only command_ids from Casein.Commands.allowlist() are accepted.
- No arbitrary argv or shell strings are ever sent.
- Every run is audited server-side.
- "agent write" modes and workspace policy still apply.
- Read endpoints are redacted by the server (no secrets, capped output).

Current known safe command_ids (from the allowlist at the time of writing):
    compile, test, format, precommit, assets.build,
    claude, clauded, codex, grok, opencode
    (plus internal dogfood ones in dev)

The exact list is always available by calling list_commands or by
inspecting a workspace status (some surfaces surface detected agent CLIs).
"""

import asyncio
import os
import sys
from pathlib import Path
from typing import Any

import httpx
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL = os.environ.get("CASEIN_BASE_URL", "http://localhost:4000").rstrip("/")
API_TOKEN = os.environ.get("CASEIN_API_TOKEN")
TIMEOUT = float(os.environ.get("CASEIN_TIMEOUT", "30"))

if not API_TOKEN:
    print("ERROR: CASEIN_API_TOKEN is required", file=sys.stderr)
    sys.exit(1)

HEADERS = {
    "Authorization": f"Bearer {API_TOKEN}",
    "Content-Type": "application/json",
    "Accept": "application/json",
}

# Known stable allowlist (the server is the source of truth; this is for
# helpful descriptions and client-side validation hints).
KNOWN_ALLOWLIST = {
    "compile": "mix compile",
    "test": "mix test --color",
    "format": "mix format --check-formatted",
    "precommit": "mix precommit",
    "assets.build": "mix assets.build",
    "claude": "claude (Anthropic CLI agent)",
    "clauded": "clauded (daemon/agent variant)",
    "codex": "codex (OpenAI Codex CLI)",
    "grok": "grok (xAI CLI)",
    "opencode": "opencode (agent runtime, used by Odysseus etc.)",
}

server = Server("casein")


# ---------------------------------------------------------------------------
# HTTP helpers (always go through the governed Casein API)
# ---------------------------------------------------------------------------

async def _get(path: str, params: dict[str, Any] | None = None) -> dict[str, Any] | list[Any] | str:
    url = f"{BASE_URL}{path}"
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.get(url, headers=HEADERS, params=params)
        resp.raise_for_status()
        if resp.headers.get("content-type", "").startswith("application/json"):
            return resp.json()
        return resp.text


async def _post(path: str, json_body: dict[str, Any]) -> dict[str, Any]:
    url = f"{BASE_URL}{path}"
    async with httpx.AsyncClient(timeout=TIMEOUT) as client:
        resp = await client.post(url, headers=HEADERS, json=json_body)
        resp.raise_for_status()
        if resp.headers.get("content-type", "").startswith("application/json"):
            return resp.json()
        return {"raw": resp.text, "status_code": resp.status_code}


def _fmt_error(e: Exception) -> str:
    if isinstance(e, httpx.HTTPStatusError):
        try:
            detail = e.response.json()
        except Exception:
            detail = e.response.text[:500]
        return f"Casein error {e.response.status_code}: {detail}"
    return f"Error talking to Casein: {e}"


def _truncate(text: str, limit: int = 8000) -> str:
    if not isinstance(text, str):
        text = str(text) if text is not None else ""
    if len(text) > limit:
        return text[:limit] + f"\n... (truncated, {len(text)} chars total)"
    return text


# ---------------------------------------------------------------------------
# Tool implementations
# ---------------------------------------------------------------------------

@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="casein_list_workspaces",
            description="List all workspaces known to this Casein instance, with basic mode and capability info. Use this first to discover valid workspace_ids.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="casein_get_status",
            description="Get the full current status of a workspace: mode, git, active runs, recent history, proposals, detected agent capabilities (opencode, fff, tidewave, browser artifacts, etc.), and more. The best single snapshot for context.",
            inputSchema={
                "type": "object",
                "properties": {
                    "workspace_id": {
                        "type": "string",
                        "description": "The workspace identifier (from casein_list_workspaces or the picker)",
                    }
                },
                "required": ["workspace_id"],
            },
        ),
        Tool(
            name="casein_list_commands",
            description="List the safe, allowlisted command_ids that can be passed to casein_run_command on this Casein. These are the only commands an agent is permitted to request.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="casein_run_command",
            description=(
                "Request execution of a safe allowlisted command in a workspace. "
                "This is the primary way for an agent to *do work*. "
                "The command is validated against Casein's allowlist and policy before anything runs. "
                "Returns the immediate run record (or assignment info in fleet mode). "
                "Use casein_get_status or casein_get_recent_runs afterwards to observe progress/output."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "workspace_id": {
                        "type": "string",
                        "description": "Target workspace (must exist and be reachable by the caller)",
                    },
                    "command_id": {
                        "type": "string",
                        "description": "One of the ids from casein_list_commands (e.g. 'test', 'compile', 'opencode', 'format')",
                    },
                },
                "required": ["workspace_id", "command_id"],
            },
        ),
        Tool(
            name="casein_get_recent_runs",
            description="Recent command run history for a workspace. Good for seeing what succeeded/failed recently and obtaining run_ids for deeper inspection.",
            inputSchema={
                "type": "object",
                "properties": {
                    "workspace_id": {"type": "string"},
                    "limit": {"type": "integer", "description": "Max number of runs to return (default 20)", "default": 20},
                },
                "required": ["workspace_id"],
            },
        ),
        Tool(
            name="casein_get_run",
            description="Fetch full details + replayable output for a specific run (by run_id from casein_get_recent_runs).",
            inputSchema={
                "type": "object",
                "properties": {
                    "workspace_id": {"type": "string"},
                    "run_id": {"type": "string"},
                },
                "required": ["workspace_id", "run_id"],
            },
        ),
        Tool(
            name="casein_get_audit",
            description="Recent audit events for the workspace (policy decisions, allows, denies, mode changes, etc.). Excellent for understanding why something was or was not permitted.",
            inputSchema={
                "type": "object",
                "properties": {
                    "workspace_id": {"type": "string"},
                    "limit": {"type": "integer", "default": 50},
                },
                "required": ["workspace_id"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        if name == "casein_list_workspaces":
            data = await _get("/api/workspaces")
            if not data:
                return [TextContent(type="text", text="No workspaces found.")]
            lines = ["**Workspaces:**"]
            for ws in data:
                wid = ws.get("id") or ws.get("workspace_id") or ws.get("external_id") or "?"
                name = ws.get("name") or ""
                status = ws.get("status") or ""
                host = ws.get("host") or ws.get("host_path_present") or "local"
                label = f"`{wid}`"
                if name:
                    label += f" ({name})"
                extra = f"status={status}" if status else ""
                if host and host != "local":
                    extra = (extra + " " if extra else "") + f"host={host}"
                suffix = f"  [{extra}]" if extra else ""
                lines.append(f"- {label}{suffix}")
            return [TextContent(type="text", text="\n".join(lines))]

        if name == "casein_get_status":
            wid = arguments.get("workspace_id", "")
            if not wid:
                return [TextContent(type="text", text="Error: workspace_id is required")]
            data = await _get(f"/api/workspaces/{wid}/status")
            # The full status is rich; present the most useful parts for an agent.
            summary = {
                "workspace_id": wid,
                "mode": data.get("mode"),
                "git": data.get("git"),
                "active_run": data.get("active_run"),
                "capabilities": data.get("capabilities"),
                "detected_agents": data.get("agent_capabilities") or data.get("agents"),
                "recent_runs_count": len(data.get("recent_runs") or []),
            }
            text = f"**Status for {wid}**\n\n```json\n{_truncate(str(summary), 6000)}\n```"
            # Also surface any explicit agent/transcript hints if present at top level
            if "audit" in data:
                text += f"\n\nRecent audit entries: {len(data.get('audit', []))}"
            return [TextContent(type="text", text=text)]

        if name == "casein_list_commands":
            # Best effort: try to get from a status if a workspace is implied, else return known list.
            # For now the static list + note that server is authoritative.
            lines = ["**Safe allowlisted commands (command_id → argv):**"]
            for cid, argv in KNOWN_ALLOWLIST.items():
                lines.append(f"- `{cid}` → {argv}")
            lines.append(
                "\nNote: the live server (Casein.Commands.allowlist/0) is the source of truth. "
                "Some commands may be disabled by workspace mode or policy."
            )
            return [TextContent(type="text", text="\n".join(lines))]

        if name == "casein_run_command":
            wid = arguments.get("workspace_id", "")
            cid = arguments.get("command_id", "")
            if not wid or not cid:
                return [TextContent(type="text", text="Error: workspace_id and command_id are required")]

            if cid not in KNOWN_ALLOWLIST:
                # Still forward it — the server will reject unknown ones with a clear audit + error.
                pass

            payload = {"command_id": cid}
            result = await _post(f"/api/workspaces/{wid}/runs", payload)
            return [
                TextContent(
                    type="text",
                    text=f"Run requested for `{cid}` on `{wid}`.\n\nServer response:\n```json\n{_truncate(str(result), 4000)}\n```\n\n"
                    "Poll status with casein_get_status or casein_get_recent_runs to observe output and completion.",
                )
            ]

        if name == "casein_get_recent_runs":
            wid = arguments.get("workspace_id", "")
            limit = arguments.get("limit", 20)
            if not wid:
                return [TextContent(type="text", text="Error: workspace_id is required")]
            data = await _get(f"/api/workspaces/{wid}/runs", params={"limit": limit})
            if not data:
                return [TextContent(type="text", text=f"No runs found for {wid}.")]
            lines = [f"**Recent runs for {wid} (most recent first):**"]
            for run in data[:limit]:
                rid = run.get("id") or run.get("run_id") or "?"
                cmd = run.get("command_id") or run.get("command") or "?"
                status = run.get("status") or run.get("exit_code")
                ts = run.get("inserted_at") or run.get("at") or ""
                lines.append(f"- `{rid}`  {cmd}  status={status}  {ts}")
            return [TextContent(type="text", text="\n".join(lines))]

        if name == "casein_get_run":
            wid = arguments.get("workspace_id", "")
            rid = arguments.get("run_id", "")
            if not wid or not rid:
                return [TextContent(type="text", text="Error: workspace_id and run_id are required")]
            data = await _get(f"/api/workspaces/{wid}/runs/{rid}")
            return [TextContent(type="text", text=f"**Run {rid} on {wid}**\n\n```json\n{_truncate(str(data), 12000)}\n```")]

        if name == "casein_get_audit":
            wid = arguments.get("workspace_id", "")
            limit = arguments.get("limit", 50)
            if not wid:
                return [TextContent(type="text", text="Error: workspace_id is required")]
            data = await _get(f"/api/workspaces/{wid}/audit", params={"limit": limit})
            if not data:
                return [TextContent(type="text", text="No audit events.")]
            lines = [f"**Audit (last {min(len(data), limit)}) for {wid}:**"]
            for ev in data[:limit]:
                action = ev.get("action") or ev.get("type") or "?"
                at = ev.get("at") or ev.get("inserted_at") or ""
                wid2 = ev.get("workspace_id") or ""
                lines.append(f"- [{at}] {action}  (ws={wid2})")
                if "reason" in ev or "message" in ev:
                    msg = ev.get("reason") or ev.get("message")
                    lines.append(f"    {msg}")
            return [TextContent(type="text", text="\n".join(lines))]

        return [TextContent(type="text", text=f"Unknown tool: {name}")]

    except Exception as e:
        return [TextContent(type="text", text=_fmt_error(e))]


# ---------------------------------------------------------------------------
# Server entrypoint (stdio, the MCP standard for local tools)
# ---------------------------------------------------------------------------

async def run():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(run())
