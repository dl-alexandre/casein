#!/usr/bin/env python3
"""Build and verify immutable, content-addressed Grok capability bundles."""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile


MANIFEST = (
    '{"description":"Session-scoped Casein tools, hooks, and skills",'
    '"hooks":"./hooks/hooks.json","mcpServers":"./.mcp.json",'
    '"name":"devide-grok-capabilities","skills":"./skills",'
    '"version":"1.0.0"}\n'
)
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
SKILL_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def files_under(root: Path):
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        if path.is_symlink():
            raise ValueError(f"bundle contains a symlink: {path}")
        if path.is_dir():
            continue
        if path.is_file() and stat.S_ISREG(path.stat().st_mode):
            yield path
        else:
            raise ValueError(f"bundle contains an unsupported entry: {path}")


def content_digest(root: Path) -> str:
    digest = hashlib.sha256()
    for path in files_under(root):
        relative = path.relative_to(root).as_posix().encode()
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def make_read_only(root: Path) -> None:
    for path in files_under(root):
        executable = bool(path.stat().st_mode & stat.S_IXUSR)
        path.chmod(0o555 if executable else 0o444)
    for path in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        path.chmod(0o555)
    root.chmod(0o555)


def remove_read_only_tree(root: Path) -> None:
    """Remove a temporary bundle after its files were made immutable."""
    for path in [root, *root.rglob("*")]:
        try:
            path.chmod(0o700 if path.is_dir() else 0o600)
        except OSError:
            pass
    shutil.rmtree(root, ignore_errors=True)


def verify_bundle(root: Path, expected: str | None = None) -> str:
    if root.is_symlink() or not root.is_dir():
        raise ValueError(f"bundle is not a directory: {root}")

    actual = content_digest(root)
    basename = root.name
    named = basename.removeprefix("sha256-")
    if not DIGEST_RE.fullmatch(named):
        raise ValueError(f"bundle directory is not content addressed: {basename}")
    if actual != named or (expected is not None and actual != expected):
        raise ValueError(f"bundle digest mismatch: expected {expected or named}, got {actual}")

    for path in [root, *root.rglob("*")]:
        if path.is_symlink():
            raise ValueError(f"bundle contains a symlink: {path}")
        if path.stat().st_mode & 0o222:
            raise ValueError(f"bundle path is writable: {path}")

    return actual


def copy_skill(skills_root: Path, name: str, destination: Path) -> None:
    if not SKILL_RE.fullmatch(name):
        raise ValueError(f"invalid skill name: {name}")
    source = skills_root / name
    if not source.is_dir() or source.is_symlink():
        raise ValueError(f"missing or invalid skill directory: {source}")
    for entry in source.rglob("*"):
        if entry.is_symlink():
            raise ValueError(f"skill contains a symlink: {entry}")
        if not entry.is_dir() and not (entry.is_file() and stat.S_ISREG(entry.stat().st_mode)):
            raise ValueError(f"skill contains an unsupported entry: {entry}")
    shutil.copytree(source, destination / name, symlinks=False)


def build(args: argparse.Namespace) -> tuple[Path, str]:
    bundle_root = Path(args.bundle_root).expanduser().resolve()
    bundle_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    bundle_root.chmod(0o700)
    temp = Path(tempfile.mkdtemp(prefix=".grok-bundle-", dir=bundle_root))

    try:
        (temp / "hooks").mkdir(mode=0o700)
        (temp / "skills").mkdir(mode=0o700)
        (temp / "plugin.json").write_text(MANIFEST, encoding="utf-8")
        shutil.copyfile(Path(args.mcp_config), temp / ".mcp.json")

        if args.hooks_disabled:
            (temp / "hooks" / "hooks.json").write_text('{"hooks":{}}\n', encoding="utf-8")
        else:
            shutil.copyfile(Path(args.hook_config), temp / "hooks" / "hooks.json")
            hook_script = temp / "hooks" / "casein-agent-state.sh"
            shutil.copyfile(Path(args.hook_script), hook_script)
            hook_script.chmod(0o755)

        if args.skills_root:
            skills_root = Path(args.skills_root).expanduser().resolve()
            for name in sorted(set(args.skill)):
                copy_skill(skills_root, name, temp / "skills")

        digest = content_digest(temp)
        target = bundle_root / f"sha256-{digest}"
        make_read_only(temp)

        try:
            temp.rename(target)
        except OSError as error:
            # Linux reports a directory-on-existing-nonempty-directory rename
            # as ENOTEMPTY, while other platforms use EEXIST/FileExistsError.
            # Both mean a concurrent or previous compiler won the content-
            # addressed destination. Reuse it only after full verification.
            if error.errno not in {errno.EEXIST, errno.ENOTEMPTY}:
                raise
            verify_bundle(target, digest)
            remove_read_only_tree(temp)

        verify_bundle(target, digest)
        return target, digest
    except Exception:
        if temp.exists():
            remove_read_only_tree(temp)
        raise


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    build_parser = commands.add_parser("build")
    build_parser.add_argument("--bundle-root", required=True)
    build_parser.add_argument("--mcp-config", required=True)
    build_parser.add_argument("--hook-config")
    build_parser.add_argument("--hook-script")
    build_parser.add_argument("--hooks-disabled", action="store_true")
    build_parser.add_argument("--skills-root")
    build_parser.add_argument("--skill", action="append", default=[])

    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("bundle_dir")
    verify_parser.add_argument("--digest")
    return result


def main() -> None:
    args = parser().parse_args()
    if args.command == "build":
        if not args.hooks_disabled and (not args.hook_config or not args.hook_script):
            raise SystemExit("hook config and script are required unless hooks are disabled")
        bundle_dir, digest = build(args)
        print(bundle_dir)
        print(digest)
    else:
        print(verify_bundle(Path(args.bundle_dir).expanduser().resolve(), args.digest))


if __name__ == "__main__":
    main()
