#!/usr/bin/env python3
"""Merge DevIDE MCP entries into real agent homes without replacing auth state."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def workspace_slug(name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-").lower()
    return slug or "workspace"


def server_keys(workspace_name: str) -> tuple[str, str]:
    slug = workspace_slug(workspace_name)
    return (f"devide-terminal-{slug}", f"devide-preview-{slug}")


def claude_mcp_payload(terminal_url: str, preview_url: str, workspace_name: str) -> dict:
    terminal_key, preview_key = server_keys(workspace_name)
    auth = "Bearer ${DEV_IDE_API_TOKEN}"
    return {
        "mcpServers": {
            terminal_key: {
                "type": "http",
                "url": terminal_url,
                "headers": {"Authorization": auth},
            },
            preview_key: {
                "type": "http",
                "url": preview_url,
                "headers": {"Authorization": auth},
            },
        }
    }


def write_claude_mcp_json(
    path: Path, terminal_url: str, preview_url: str, workspace_name: str
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(claude_mcp_payload(terminal_url, preview_url, workspace_name), indent=2)
        + "\n"
    )
    path.chmod(0o600)


def remove_devide_mcp_toml(text: str) -> str:
    pattern = r"\n?\[mcp_servers\.devide-[^\]]+\](?:\n(?!\[)[^\n]*)*"
    return re.sub(pattern, "", text).rstrip()


def grok_mcp_block(terminal_url: str, preview_url: str, workspace_name: str, *, enabled: bool) -> str:
    terminal_key, preview_key = server_keys(workspace_name)
    enabled_str = "true" if enabled else "false"
    return f"""
[mcp_servers.{terminal_key}]
url = "{terminal_url}"
enabled = {enabled_str}

[mcp_servers.{terminal_key}.headers]
Authorization = "Bearer ${{DEV_IDE_API_TOKEN}}"

[mcp_servers.{preview_key}]
url = "{preview_url}"
enabled = {enabled_str}

[mcp_servers.{preview_key}.headers]
Authorization = "Bearer ${{DEV_IDE_API_TOKEN}}"
""".strip()


def codex_mcp_block(terminal_url: str, preview_url: str, workspace_name: str, *, enabled: bool) -> str:
    terminal_key, preview_key = server_keys(workspace_name)
    enabled_str = "true" if enabled else "false"
    return f"""
[mcp_servers.{terminal_key}]
url = "{terminal_url}"
enabled = {enabled_str}
bearer_token_env_var = "DEV_IDE_API_TOKEN"

[mcp_servers.{preview_key}]
url = "{preview_url}"
enabled = {enabled_str}
bearer_token_env_var = "DEV_IDE_API_TOKEN"
""".strip()


def merge_toml(path: Path, blocks: list[str]) -> None:
    existing = path.read_text() if path.exists() else ""
    merged = remove_devide_mcp_toml(existing)
    body = "\n\n".join(block for block in blocks if block)
    path.parent.mkdir(parents=True, exist_ok=True)
    if merged and body:
        path.write_text(merged + "\n\n" + body + "\n")
    elif body:
        path.write_text(body + "\n")
    elif merged:
        path.write_text(merged + "\n")


def merge_opencode_json(path: Path, workspaces: dict[str, dict[str, str]], active: str) -> None:
    data: dict = {}
    if path.exists():
        data = json.loads(path.read_text())

    mcp = data.setdefault("mcp", {})
    for key in list(mcp):
        if key.startswith("devide-"):
            del mcp[key]

    for workspace_name, urls in sorted(workspaces.items()):
        terminal_key, preview_key = server_keys(workspace_name)
        enabled = workspace_name == active
        mcp[terminal_key] = {
            "type": "remote",
            "url": urls["terminal"],
            "enabled": enabled,
            "oauth": False,
            "headers": {"Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"},
        }
        mcp[preview_key] = {
            "type": "remote",
            "url": urls["preview"],
            "enabled": enabled,
            "oauth": False,
            "headers": {"Authorization": "Bearer {env:DEV_IDE_API_TOKEN}"},
        }

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def main() -> int:
    terminal = os.environ.get("DEVIDE_TERMINAL_MCP_URL", "")
    preview = os.environ.get("DEVIDE_PREVIEW_MCP_URL", "")
    workspace_name = os.environ.get("DEVIDE_WORKSPACE_NAME", "workspace")
    home = Path(os.environ["HOME"])

    if not terminal or not preview:
        print("error: DEVIDE_TERMINAL_MCP_URL and DEVIDE_PREVIEW_MCP_URL required", file=sys.stderr)
        return 1

    # Materialize ONLY the active workspace's servers. Aggregating every
    # discovered workspace bloated the shared global homes (~/.grok, ~/.codex,
    # ~/.config/opencode) with all 56 workspaces — and because every agent runs
    # as the same OS user, that pulled in every other user's workspaces too. The
    # launcher re-runs this per launch, so the active workspace is what's written.
    workspaces = {workspace_name: {"terminal": terminal, "preview": preview}}

    grok_blocks = [
        grok_mcp_block(urls["terminal"], urls["preview"], name, enabled=(name == workspace_name))
        for name, urls in sorted(workspaces.items())
    ]
    codex_blocks = [
        codex_mcp_block(urls["terminal"], urls["preview"], name, enabled=(name == workspace_name))
        for name, urls in sorted(workspaces.items())
    ]

    merge_toml(home / ".grok" / "config.toml", grok_blocks)
    merge_toml(home / ".codex" / "config.toml", codex_blocks)

    for opencode_path in (
        home / ".config" / "opencode" / "opencode.json",
        home / ".opencode" / "opencode.json",
    ):
        if opencode_path.exists() or opencode_path.parent.exists():
            merge_opencode_json(opencode_path, workspaces, workspace_name)
            break
    else:
        merge_opencode_json(home / ".config" / "opencode" / "opencode.json", workspaces, workspace_name)

    # Claude no longer reads a shared-checkout project .mcp.json — the launcher
    # injects the workspace's isolated staging file via `claude --mcp-config`
    # (see scripts/launch-devide-agent.sh). Writing the checkout file here is
    # what accumulated every workspace's servers into one shared config, so it
    # is intentionally not done.
    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "write-claude-mcp":
        if len(sys.argv) != 5:
            print(
                "usage: merge-agent-mcp.py write-claude-mcp <path> <terminal_url> <preview_url>",
                file=sys.stderr,
            )
            raise SystemExit(2)
        active_workspace = os.environ.get("DEVIDE_WORKSPACE_NAME", "workspace")
        write_claude_mcp_json(Path(sys.argv[2]), sys.argv[3], sys.argv[4], active_workspace)
        raise SystemExit(0)

    raise SystemExit(main())