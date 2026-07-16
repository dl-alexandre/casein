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
            "usage: grok-sandbox-profile.py install <name> <read-only|strict> <deny>...",
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

    deny = sorted({value for value in sys.argv[4:] if value})
    if not deny:
        print("error: managed Grok sandbox requires a deny set", file=sys.stderr)
        return 2

    begin = f"# BEGIN DEVIDE MANAGED GROK SANDBOX {name}"
    end = f"# END DEVIDE MANAGED GROK SANDBOX {name}"
    existing = path.read_text() if path.exists() else ""
    block_re = re.compile(
        rf"(?ms)^\# BEGIN DEVIDE MANAGED GROK SANDBOX {re.escape(name)}\n.*?^\# END DEVIDE MANAGED GROK SANDBOX {re.escape(name)}\n?"
    )
    existing = block_re.sub("", existing).rstrip()
    encoded = ", ".join(json.dumps(value) for value in deny)
    block = (
        f"{begin}\n"
        f"[profiles.{name}]\n"
        f'extends = "{base}"\n'
        f"deny = [{encoded}]\n"
        f"{end}\n"
    )
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
