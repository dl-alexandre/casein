#!/usr/bin/env python3
"""Merge DevIDE MCP entries into real agent homes without replacing auth state."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def sanitize_token(token: str) -> str:
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "'\"":
        return token[1:-1]
    return token


def normalize_bearer_header(value: str) -> str:
    prefix = "Bearer "
    if not value.startswith(prefix):
        return value
    return f"{prefix}{sanitize_token(value[len(prefix) :])}"


def claude_mcp_payload(terminal_url: str, preview_url: str, token: str) -> dict:
    auth = f"Bearer {sanitize_token(token)}"
    return {
        "mcpServers": {
            "devide-terminal": {
                "type": "http",
                "url": terminal_url,
                "headers": {"Authorization": auth},
            },
            "devide-preview": {
                "type": "http",
                "url": preview_url,
                "headers": {"Authorization": auth},
            },
        }
    }


def write_claude_mcp_json(path: Path, terminal_url: str, preview_url: str, token: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(claude_mcp_payload(terminal_url, preview_url, token), indent=2) + "\n")
    path.chmod(0o600)


def remove_devide_mcp_toml(text: str) -> str:
    pattern = r"\n?\[mcp_servers\.devide-[^\]]+\](?:\n(?!\[)[^\n]*)*"
    return re.sub(pattern, "", text).rstrip()


def grok_mcp_block(terminal_url: str, preview_url: str) -> str:
    return f"""
[mcp_servers.devide-terminal]
url = "{terminal_url}"
enabled = true

[mcp_servers.devide-terminal.headers]
Authorization = "Bearer ${{DEV_IDE_API_TOKEN}}"

[mcp_servers.devide-preview]
url = "{preview_url}"
enabled = true

[mcp_servers.devide-preview.headers]
Authorization = "Bearer ${{DEV_IDE_API_TOKEN}}"
""".strip()


def codex_mcp_block(terminal_url: str, preview_url: str) -> str:
    return f"""
[mcp_servers.devide-terminal]
url = "{terminal_url}"
enabled = true
bearer_token_env_var = "DEV_IDE_API_TOKEN"

[mcp_servers.devide-preview]
url = "{preview_url}"
enabled = true
bearer_token_env_var = "DEV_IDE_API_TOKEN"
""".strip()


def merge_toml(path: Path, block: str) -> None:
    existing = path.read_text() if path.exists() else ""
    merged = remove_devide_mcp_toml(existing)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text((merged + "\n\n" + block + "\n") if merged else (block + "\n"))


def merge_opencode_json(path: Path, terminal_url: str, preview_url: str) -> None:
    data: dict = {}
    if path.exists():
        data = json.loads(path.read_text())
    mcp = data.setdefault("mcp", {})
    mcp["devide-terminal"] = {
        "type": "remote",
        "url": terminal_url,
        "enabled": True,
        "oauth": False,
        "headers": {"Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"},
    }
    mcp["devide-preview"] = {
        "type": "remote",
        "url": preview_url,
        "enabled": True,
        "oauth": False,
        "headers": {"Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def merge_claude_mcp_json(target: Path, staging: Path) -> None:
    staging_data = json.loads(staging.read_text())
    devide_servers = staging_data.get("mcpServers", {})
    data: dict = {"mcpServers": {}}
    if target.exists():
        data = json.loads(target.read_text())
    servers = data.setdefault("mcpServers", {})
    for key in ("devide-terminal", "devide-preview"):
        if key not in devide_servers:
            continue
        server = dict(devide_servers[key])
        headers = dict(server.get("headers") or {})
        if "Authorization" in headers:
            headers["Authorization"] = normalize_bearer_header(headers["Authorization"])
        server["headers"] = headers
        servers[key] = server
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, indent=2) + "\n")
    target.chmod(0o600)


def main() -> int:
    terminal = os.environ.get("DEVIDE_TERMINAL_MCP_URL", "")
    preview = os.environ.get("DEVIDE_PREVIEW_MCP_URL", "")
    home = Path(os.environ["HOME"])
    checkout = Path(os.environ.get("DEVIDE_CHECKOUT", home))
    staging = Path(os.environ.get("DEVIDE_AGENT_MCP_HOME", home / ".devide" / "agent-mcp"))

    if not terminal or not preview:
        print("error: DEVIDE_TERMINAL_MCP_URL and DEVIDE_PREVIEW_MCP_URL required", file=sys.stderr)
        return 1

    merge_toml(home / ".grok" / "config.toml", grok_mcp_block(terminal, preview))
    merge_toml(home / ".codex" / "config.toml", codex_mcp_block(terminal, preview))

    for opencode_path in (
        home / ".config" / "opencode" / "opencode.json",
        home / ".opencode" / "opencode.json",
    ):
        if opencode_path.exists() or opencode_path.parent.exists():
            merge_opencode_json(opencode_path, terminal, preview)
            break
    else:
        merge_opencode_json(home / ".config" / "opencode" / "opencode.json", terminal, preview)

    staging_mcp = staging / ".mcp.json"
    if staging_mcp.exists():
        merge_claude_mcp_json(checkout / ".mcp.json", staging_mcp)

    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "write-claude-mcp":
        token = sanitize_token(os.environ.get("DEV_IDE_API_TOKEN", ""))
        if len(sys.argv) != 5:
            print("usage: merge-agent-mcp.py write-claude-mcp <path> <terminal_url> <preview_url>", file=sys.stderr)
            raise SystemExit(2)
        if not token:
            print("error: DEV_IDE_API_TOKEN is required", file=sys.stderr)
            raise SystemExit(1)
        write_claude_mcp_json(Path(sys.argv[2]), sys.argv[3], sys.argv[4], token)
        raise SystemExit(0)

    raise SystemExit(main())