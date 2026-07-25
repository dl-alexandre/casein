#!/usr/bin/env python3
"""Merge DevIDE MCP entries into real agent homes without replacing auth state."""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
from pathlib import Path


def workspace_slug(name: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", name).strip("-").lower()
    return slug or "workspace"


def server_keys(workspace_name: str) -> tuple[str, str, str, str]:
    slug = workspace_slug(workspace_name)
    return (
        f"casein-terminal-{slug}",
        f"casein-preview-{slug}",
        f"casein-artifact-{slug}",
        f"casein-tidewave-{slug}",
    )


def claude_mcp_payload(
    terminal_url: str,
    preview_url: str,
    artifact_url: str,
    workspace_name: str,
    tidewave_url: str | None = None,
) -> dict:
    terminal_key, preview_key, artifact_key, tidewave_key = server_keys(workspace_name)
    auth = "Bearer ${CASEIN_API_TOKEN}"
    servers: dict = {
        terminal_key: {
            "type": "http",
            "url": terminal_url,
            "headers": {
                "Authorization": auth,
                # Anchors terminal MCP pane resolution to the calling agent's
                # own pane; expanded per process from launch-casein-agent.sh's
                # export. The server ignores empty/unexpanded values.
                "X-DevIDE-Caller-Pane": "${DEVIDE_CALLER_PANE}",
            },
        },
        preview_key: {
            "type": "http",
            "url": preview_url,
            "headers": {"Authorization": auth},
        },
        artifact_key: {
            "type": "http",
            "url": artifact_url,
            "headers": {"Authorization": auth},
        },
    }
    if tidewave_url:
        servers[tidewave_key] = {"type": "http", "url": tidewave_url}
    return {"mcpServers": servers}


def write_claude_mcp_json(
    path: Path,
    terminal_url: str,
    preview_url: str,
    artifact_url: str,
    workspace_name: str,
    tidewave_url: str | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            claude_mcp_payload(
                terminal_url, preview_url, artifact_url, workspace_name, tidewave_url
            ),
            indent=2,
        )
        + "\n"
    )
    path.chmod(0o600)


def remove_devide_mcp_toml(text: str) -> str:
    lines = text.splitlines()
    kept: list[str] = []
    skip = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            skip = re.match(r"^\[mcp_servers\.devide-[^\]]+\]$", stripped) is not None

        if not skip:
            kept.append(line)

    return "\n".join(kept).rstrip()


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


def write_grok_config(path: Path) -> None:
    # The `[ui].theme` line is owned by Casein.Terminals.ToolThemes now, which
    # stamps groknight (dark) / tokyonight (light) — grokday is banned as
    # illegible in the DevIDE viewer. This helper only
    # strips stale devide-* MCP blocks and preserves everything else, theme
    # included.
    existing = path.read_text() if path.exists() else ""
    cleaned = remove_devide_mcp_toml(existing)

    output = (cleaned.rstrip() + "\n") if cleaned.strip() else ""

    if not path.exists() and not output:
        return

    current = existing if path.exists() else ""
    if output == current or (output and current.rstrip() + "\n" == output):
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    if output:
        path.write_text(output)


def remove_devide_mcp_json(path: Path) -> None:
    if not path.exists():
        return

    data = json.loads(path.read_text())
    changed = False

    for key in ("mcpServers", "mcp"):
        servers = data.get(key)
        if isinstance(servers, dict):
            for name in list(servers):
                if name.startswith("devide-"):
                    del servers[name]
                    changed = True

    if changed:
        path.write_text(json.dumps(data, indent=2) + "\n")


def cleanup_grok_project_cache(home: Path) -> None:
    projects = home / ".grok" / "projects"
    if not projects.is_dir():
        return

    for mcps_dir in projects.glob("*/mcps"):
        if not mcps_dir.is_dir():
            continue

        for child in mcps_dir.iterdir():
            if child.name.startswith("devide-") and child.is_dir():
                shutil.rmtree(child)


def main() -> int:
    terminal = os.environ.get("DEVIDE_TERMINAL_MCP_URL", "")
    preview = os.environ.get("DEVIDE_PREVIEW_MCP_URL", "")
    artifact = os.environ.get("DEVIDE_ARTIFACT_MCP_URL", "")
    home = Path(os.environ["HOME"])

    if not terminal or not preview:
        print(
            "error: DEVIDE_TERMINAL_MCP_URL and DEVIDE_PREVIEW_MCP_URL required",
            file=sys.stderr,
        )
        return 1
    artifact = artifact or preview.replace("/api/preview/mcp", "/api/artifacts/mcp")

    # DevIDE MCP is injected at launch time instead of persisted into shared
    # global agent homes. Aggregating every discovered workspace previously
    # bloated shared configs with all workspaces across all users, and Codex/
    # OpenCode can fail when a persisted server references a missing token.
    # Keep this helper as an idempotent cleanup pass for old global devide-* MCP
    # entries while preserving non-DevIDE auth/config state.
    write_grok_config(home / ".grok" / "config.toml")
    merge_toml(home / ".codex" / "config.toml", [])
    remove_devide_mcp_json(home / ".cursor" / "mcp.json")
    cleanup_grok_project_cache(home)

    for opencode_path in (
        home / ".config" / "opencode" / "opencode.json",
        home / ".opencode" / "opencode.json",
    ):
        remove_devide_mcp_json(opencode_path)

    # Claude no longer reads a shared-checkout project .mcp.json — the launcher
    # injects the workspace's isolated staging file via `claude --mcp-config`
    # (see scripts/launch-casein-agent.sh). Writing the checkout file here is
    # what accumulated every workspace's servers into one shared config, so it
    # is intentionally not done.
    return 0


def _self_test() -> int:
    # devide-* MCP blocks are stripped; the [ui].theme line (owned by
    # ToolThemes) and other sections survive untouched.
    cleaned = remove_devide_mcp_toml(
        '[ui]\ntheme = "groknight"\n\n[mcp_servers.devide-foo]\nurl = "x"\n'
    )
    assert 'theme = "groknight"' in cleaned
    assert "devide-foo" not in cleaned

    return 0


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--self-test":
        raise SystemExit(_self_test())

    if len(sys.argv) >= 2 and sys.argv[1] == "write-claude-mcp":
        if len(sys.argv) not in (5, 6):
            print(
                "usage: merge-agent-mcp.py write-claude-mcp <path> <terminal_url> <preview_url> [artifact_url]",
                file=sys.stderr,
            )
            raise SystemExit(2)
        active_workspace = os.environ.get("DEVIDE_WORKSPACE_NAME", "workspace")
        tidewave = os.environ.get("DEVIDE_TIDEWAVE_MCP_URL", "") or None
        artifact_url = (
            sys.argv[5]
            if len(sys.argv) == 6
            else sys.argv[4].replace("/api/preview/mcp", "/api/artifacts/mcp")
        )
        write_claude_mcp_json(
            Path(sys.argv[2]), sys.argv[3], sys.argv[4], artifact_url, active_workspace, tidewave
        )
        raise SystemExit(0)

    if len(sys.argv) >= 2 and sys.argv[1] == "write-grok-mcp":
        if len(sys.argv) != 6:
            print(
                "usage: merge-agent-mcp.py write-grok-mcp <path> <terminal_url> <preview_url> <artifact_url>",
                file=sys.stderr,
            )
            raise SystemExit(2)
        active_workspace = os.environ.get("DEVIDE_WORKSPACE_NAME", "workspace")
        # Managed Grok is confined by a DevIDE capability bearer. Tidewave is
        # a third-party endpoint outside that authorization boundary, so it is
        # deliberately absent from the session bundle.
        write_claude_mcp_json(
            Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], active_workspace
        )
        raise SystemExit(0)

    raise SystemExit(main())
