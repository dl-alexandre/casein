#!/usr/bin/env python3
"""Merge Casein MCP entries into real agent homes without replacing auth state."""

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


# Spec key for 2026-07-28 per-request declare. Shared with
# Casein.Agents.MCPMaterializer.client_protocol_declare/0 — keep empty until a
# runtime MCP config schema accepts a per-server protocol pin / _meta field.
MCP_PROTOCOL_VERSION_META = "io.modelcontextprotocol/protocolVersion"
MCP_PROTOCOL_2026 = "2026-07-28"


def client_protocol_declare() -> dict:
    """Extra per-server MCP config fields that declare a protocol revision.

    Empty until Claude/OpenCode/Codex/Grok document a supported config key for
    `_meta` protocolVersion (or native equivalent). Do not invent keys — unknown
    fields break plain startups. Server dual-stack stays; default remains 2025.
    """
    _ = (MCP_PROTOCOL_VERSION_META, MCP_PROTOCOL_2026)
    return {}


def _with_protocol_declare(server: dict) -> dict:
    declare = client_protocol_declare()
    if not declare:
        return server
    merged = dict(server)
    merged.update(declare)
    return merged


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
        terminal_key: _with_protocol_declare(
            {
                "type": "http",
                "url": terminal_url,
                "headers": {
                    "Authorization": auth,
                    # Anchors terminal MCP pane resolution to the calling agent's
                    # own pane; expanded per process from launch-casein-agent.sh's
                    # export. The server ignores empty/unexpanded values.
                    "X-Casein-Caller-Pane": "${CASEIN_CALLER_PANE}",
                },
            }
        ),
        preview_key: _with_protocol_declare(
            {
                "type": "http",
                "url": preview_url,
                "headers": {"Authorization": auth},
            }
        ),
        artifact_key: _with_protocol_declare(
            {
                "type": "http",
                "url": artifact_url,
                "headers": {"Authorization": auth},
            }
        ),
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


def remove_casein_mcp_toml(text: str) -> str:
    lines = text.splitlines()
    kept: list[str] = []
    skip = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            skip = re.match(r"^\[mcp_servers\.casein-[^\]]+\]$", stripped) is not None

        if not skip:
            kept.append(line)

    return "\n".join(kept).rstrip()


def merge_toml(path: Path, blocks: list[str]) -> None:
    existing = path.read_text() if path.exists() else ""
    merged = remove_casein_mcp_toml(existing)
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
    # illegible in the Casein viewer. This helper only
    # strips stale casein-* MCP blocks and preserves everything else, theme
    # included.
    existing = path.read_text() if path.exists() else ""
    cleaned = remove_casein_mcp_toml(existing)

    output = (cleaned.rstrip() + "\n") if cleaned.strip() else ""

    if not path.exists() and not output:
        return

    current = existing if path.exists() else ""
    if output == current or (output and current.rstrip() + "\n" == output):
        return

    path.parent.mkdir(parents=True, exist_ok=True)
    if output:
        path.write_text(output)


def remove_casein_mcp_json(path: Path) -> None:
    if not path.exists():
        return

    data = json.loads(path.read_text())
    changed = False

    for key in ("mcpServers", "mcp"):
        servers = data.get(key)
        if isinstance(servers, dict):
            for name in list(servers):
                if name.startswith("casein-"):
                    del servers[name]
                    changed = True

    if changed:
        path.write_text(json.dumps(data, indent=2) + "\n")


def _read_json_object(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not read {path}: {exc}") from exc

    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object")

    return data


def merge_opencode_config(generated_path: Path, target_path: Path) -> None:
    """Replace Casein's OpenCode servers without replacing project config."""
    generated = _read_json_object(generated_path)
    generated_mcp = generated.get("mcp")
    if not isinstance(generated_mcp, dict):
        raise ValueError(f"{generated_path} must contain an object-valued mcp key")

    existing = _read_json_object(target_path) if target_path.exists() else {}
    existing_mcp = existing.get("mcp")
    if existing_mcp is None:
        existing_mcp = {}
    elif not isinstance(existing_mcp, dict):
        raise ValueError(f"{target_path} must contain an object-valued mcp key")

    merged = dict(existing)
    merged_mcp = {
        key: value for key, value in existing_mcp.items() if not key.startswith("casein-")
    }
    merged_mcp.update(generated_mcp)
    merged["mcp"] = merged_mcp

    if "$schema" not in merged and "$schema" in generated:
        merged["$schema"] = generated["$schema"]

    target_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = target_path.with_name(f".{target_path.name}.casein-{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(merged, indent=2) + "\n")
        temporary.chmod(0o600)
        os.replace(temporary, target_path)
    finally:
        if temporary.exists():
            temporary.unlink()


def cleanup_grok_project_cache(home: Path) -> None:
    projects = home / ".grok" / "projects"
    if not projects.is_dir():
        return

    for mcps_dir in projects.glob("*/mcps"):
        if not mcps_dir.is_dir():
            continue

        for child in mcps_dir.iterdir():
            if child.name.startswith("casein-") and child.is_dir():
                shutil.rmtree(child)


def main() -> int:
    terminal = os.environ.get("CASEIN_TERMINAL_MCP_URL", "")
    preview = os.environ.get("CASEIN_PREVIEW_MCP_URL", "")
    artifact = os.environ.get("CASEIN_ARTIFACT_MCP_URL", "")
    home = Path(os.environ["HOME"])

    if not terminal or not preview:
        print(
            "error: CASEIN_TERMINAL_MCP_URL and CASEIN_PREVIEW_MCP_URL required",
            file=sys.stderr,
        )
        return 1
    artifact = artifact or preview.replace("/api/preview/mcp", "/api/artifacts/mcp")

    # Casein MCP is injected at launch time instead of persisted into shared
    # global agent homes. Aggregating every discovered workspace previously
    # bloated shared configs with all workspaces across all users, and Codex/
    # OpenCode can fail when a persisted server references a missing token.
    # Keep this helper as an idempotent cleanup pass for old global casein-* MCP
    # entries while preserving non-Casein auth/config state.
    write_grok_config(home / ".grok" / "config.toml")
    merge_toml(home / ".codex" / "config.toml", [])
    remove_casein_mcp_json(home / ".cursor" / "mcp.json")
    cleanup_grok_project_cache(home)

    for opencode_path in (
        home / ".config" / "opencode" / "opencode.json",
        home / ".opencode" / "opencode.json",
    ):
        remove_casein_mcp_json(opencode_path)

    # Claude no longer reads a shared-checkout project .mcp.json — the launcher
    # injects the workspace's isolated staging file via `claude --mcp-config`
    # (see scripts/launch-casein-agent.sh). Writing the checkout file here is
    # what accumulated every workspace's servers into one shared config, so it
    # is intentionally not done.
    return 0


def _self_test() -> int:
    # casein-* MCP blocks are stripped; the [ui].theme line (owned by
    # ToolThemes) and other sections survive untouched.
    cleaned = remove_casein_mcp_toml(
        '[ui]\ntheme = "groknight"\n\n[mcp_servers.casein-foo]\nurl = "x"\n'
    )
    assert 'theme = "groknight"' in cleaned
    assert "casein-foo" not in cleaned

    # Protocol declare stays empty until a runtime schema allows it (#751).
    assert client_protocol_declare() == {}
    base = {"type": "http", "url": "http://example.test/mcp"}
    assert _with_protocol_declare(base) == base

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
        active_workspace = os.environ.get("CASEIN_WORKSPACE_NAME", "workspace")
        tidewave = os.environ.get("CASEIN_TIDEWAVE_MCP_URL", "") or None
        artifact_url = (
            sys.argv[5]
            if len(sys.argv) == 6
            else sys.argv[4].replace("/api/preview/mcp", "/api/artifacts/mcp")
        )
        write_claude_mcp_json(
            Path(sys.argv[2]), sys.argv[3], sys.argv[4], artifact_url, active_workspace, tidewave
        )
        raise SystemExit(0)

    if len(sys.argv) >= 2 and sys.argv[1] == "merge-opencode":
        if len(sys.argv) != 4:
            print(
                "usage: merge-agent-mcp.py merge-opencode <generated_path> <target_path>",
                file=sys.stderr,
            )
            raise SystemExit(2)
        try:
            merge_opencode_config(Path(sys.argv[2]), Path(sys.argv[3]))
        except ValueError as exc:
            print(f"error: refusing to merge OpenCode config: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        raise SystemExit(0)

    if len(sys.argv) >= 2 and sys.argv[1] == "write-grok-mcp":
        if len(sys.argv) != 6:
            print(
                "usage: merge-agent-mcp.py write-grok-mcp <path> <terminal_url> <preview_url> <artifact_url>",
                file=sys.stderr,
            )
            raise SystemExit(2)
        active_workspace = os.environ.get("CASEIN_WORKSPACE_NAME", "workspace")
        # Managed Grok is confined by a Casein capability bearer. Tidewave is
        # a third-party endpoint outside that authorization boundary, so it is
        # deliberately absent from the session bundle.
        write_claude_mcp_json(
            Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], active_workspace
        )
        raise SystemExit(0)

    raise SystemExit(main())
