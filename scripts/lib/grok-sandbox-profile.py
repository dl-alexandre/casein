#!/usr/bin/env python3
"""Install an immutable-at-launch sandbox profile for a managed Grok leader."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path


NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")


def main() -> int:
    if len(sys.argv) < 5 or sys.argv[1] != "install":
        print(
            "usage: grok-sandbox-profile.py install <name> <read-only|strict> "
            "[--read-only=<path>] [--read-write=<path>] <deny>...",
            file=sys.stderr,
        )
        return 2

    name, base = sys.argv[2], sys.argv[3]
    if not NAME.fullmatch(name) or base not in {"read-only", "strict"}:
        print("error: invalid managed Grok sandbox profile", file=sys.stderr)
        return 2

    home = Path(os.environ.get("GROK_HOME") or Path.home() / ".grok")
    path = home / "sandbox.toml"
    path.parent.mkdir(parents=True, exist_ok=True)

    values = [value for value in sys.argv[4:] if value]
    read_write = sorted(
        {
            value.removeprefix("--read-write=")
            for value in values
            if value.startswith("--read-write=")
            and value.removeprefix("--read-write=")
        }
    )
    read_only = sorted(
        {
            value.removeprefix("--read-only=")
            for value in values
            if value.startswith("--read-only=")
            and value.removeprefix("--read-only=")
        }
    )
    deny = sorted(
        {
            value
            for value in values
            if not value.startswith(("--read-only=", "--read-write="))
        }
    )
    if not deny:
        print("error: managed Grok sandbox requires a deny set", file=sys.stderr)
        return 2

    begin = f"# BEGIN CASEIN MANAGED GROK SANDBOX {name}"
    end = f"# END CASEIN MANAGED GROK SANDBOX {name}"
    existing = path.read_text() if path.exists() else ""
    block_re = re.compile(
        rf"(?ms)^\# BEGIN CASEIN MANAGED GROK SANDBOX {re.escape(name)}\n.*?^\# END CASEIN MANAGED GROK SANDBOX {re.escape(name)}\n?"
    )
    existing = block_re.sub("", existing).rstrip()
    encoded = ", ".join(json.dumps(value) for value in deny)
    encoded_read_only = ", ".join(json.dumps(value) for value in read_only)
    encoded_read_write = ", ".join(json.dumps(value) for value in read_write)
    block = f'{begin}\n[profiles.{name}]\nextends = "{base}"\n'
    if read_only:
        block += f"read_only = [{encoded_read_only}]\n"
    if read_write:
        block += f"read_write = [{encoded_read_write}]\n"
    block += f"deny = [{encoded}]\n{end}\n"
    content = (existing + "\n\n" if existing else "") + block

    fd, tmp_name = tempfile.mkstemp(prefix=".sandbox.toml.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass

    print(name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
