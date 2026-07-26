#!/usr/bin/env python3
"""Own and probe one Casein-managed Grok leader process."""

from __future__ import annotations

import json
import os
import select
import signal
import socket
import stat
import struct
import sys
import tempfile
import time
from pathlib import Path


MAX_FRAME = 64 * 1024 * 1024


class RuntimeErrorSafe(RuntimeError):
    """An expected, credential-free leader lifecycle error."""


def main() -> int:
    try:
        command = sys.argv[1] if len(sys.argv) > 1 else ""
        if command == "spawn" and len(sys.argv) >= 6:
            pid = spawn(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4], sys.argv[5:])
            print(pid)
            return 0
        if command == "identity" and len(sys.argv) == 3:
            print(validate_identity(Path(sys.argv[2])))
            return 0
        if command == "probe" and len(sys.argv) in {4, 5}:
            expected_pgid = int(sys.argv[3])
            timeout = float(sys.argv[4]) if len(sys.argv) == 5 else 2.0
            probe(Path(sys.argv[2]), expected_pgid, timeout)
            return 0
        if command == "group-live" and len(sys.argv) == 3:
            return 0 if group_live(int(sys.argv[2])) else 1
        if command == "process-starttime" and len(sys.argv) == 3:
            print(proc_identity(int(sys.argv[2]))[0])
            return 0
        if command == "resume-after-sandbox" and len(sys.argv) in {5, 6}:
            timeout = float(sys.argv[5]) if len(sys.argv) == 6 else 15.0
            resume_after_sandbox(
                Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), timeout
            )
            return 0

        print(
            "usage: grok-leader-runtime.py spawn <metadata> <log> <grok> <arg>...\n"
            "       grok-leader-runtime.py identity <metadata>\n"
            "       grok-leader-runtime.py probe <socket> <expected-pgid|0> [timeout-seconds]\n"
            "       grok-leader-runtime.py group-live <pgid>\n"
            "       grok-leader-runtime.py process-starttime <pid>\n"
            "       grok-leader-runtime.py resume-after-sandbox <metadata> <tui-pid> <tui-starttime> [timeout-seconds]",
            file=sys.stderr,
        )
        return 2
    except (RuntimeErrorSafe, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


def spawn(metadata: Path, log: Path, grok: str, args: list[str]) -> int:
    """Fork, setsid, exec Grok, and atomically record its immutable identity."""

    validate_runtime_file(metadata, allow_missing=True)
    validate_runtime_file(log, allow_missing=True)
    read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
    pid = os.fork()

    if pid == 0:
        try:
            os.close(read_fd)
            os.setsid()
            null_fd = os.open(os.devnull, os.O_RDWR)
            log_fd = os.open(
                log,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            os.dup2(null_fd, 0)
            os.dup2(null_fd, 1)
            os.dup2(log_fd, 2)
            close_unneeded_fds({0, 1, 2, write_fd})
            os.execvpe(grok, [grok, *args], os.environ.copy())
        except BaseException as error:  # child must report exec/setup failure only
            try:
                os.write(write_fd, str(error).encode("utf-8", "replace")[:1000])
            finally:
                os._exit(127)

    os.close(write_fd)
    try:
        ready, _, _ = select.select([read_fd], [], [], 5.0)
        if not ready:
            terminate_spawn(pid)
            raise RuntimeErrorSafe("timed out waiting for the Grok leader exec")
        detail = os.read(read_fd, 1001)
    finally:
        os.close(read_fd)

    if detail:
        os.waitpid(pid, 0)
        raise RuntimeErrorSafe(f"could not exec the Grok leader: {detail.decode(errors='replace')}")

    try:
        starttime, pgrp, session, state = proc_identity(pid)
        if pgrp != pid or session != pid or state == "Z":
            raise RuntimeErrorSafe("Grok leader did not enter its own live process group")
        atomic_write(metadata, f"{pid} {starttime}\n")
    except BaseException:
        terminate_spawn(pid)
        raise
    return pid


def validate_identity(metadata: Path) -> int:
    validate_runtime_file(metadata, allow_missing=False)
    fields = metadata.read_text(encoding="utf-8").split()
    if len(fields) != 2 or not all(field.isdigit() for field in fields):
        raise RuntimeErrorSafe("invalid launcher metadata")
    pid, expected_starttime = map(int, fields)
    starttime, pgrp, session, state = proc_identity(pid)
    if starttime != expected_starttime or pgrp != pid or session != pid or state == "Z":
        raise RuntimeErrorSafe("launcher process identity no longer matches")
    return pid


def proc_identity(pid: int) -> tuple[int, int, int, str]:
    starttime, _ppid, pgrp, session, state = proc_record(pid)
    return starttime, pgrp, session, state


def proc_record(pid: int) -> tuple[int, int, int, int, str]:
    try:
        value = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except FileNotFoundError as error:
        raise RuntimeErrorSafe("launcher process is not running") from error
    marker = value.rfind(") ")
    if marker < 0:
        raise RuntimeErrorSafe("invalid process stat record")
    fields = value[marker + 2 :].split()
    if len(fields) < 20:
        raise RuntimeErrorSafe("incomplete process stat record")
    # fields begin at proc field 3 (state); ppid=4, pgrp=5,
    # session=6, starttime=22.
    return int(fields[19]), int(fields[1]), int(fields[2]), int(fields[3]), fields[0]


def group_live(pgid: int) -> bool:
    if pgid <= 1:
        return False
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            _starttime, candidate_pgrp, _session, state = proc_identity(int(entry.name))
        except (RuntimeErrorSafe, OSError, ValueError):
            continue
        if candidate_pgrp == pgid and _session == pgid and state != "Z":
            return True
    return False


def resume_after_sandbox(
    metadata: Path, tui_pid: int, expected_tui_starttime: int, timeout: float
) -> None:
    """Resume a quiesced leader once the attaching TUI entered Grok's bwrap."""

    if timeout <= 0 or timeout > 120:
        raise RuntimeErrorSafe("invalid sandbox handoff timeout")
    leader_pid = validate_identity(metadata)
    leader_starttime = proc_identity(leader_pid)[0]
    deadline = time.monotonic() + timeout
    ready = False
    try:
        while time.monotonic() < deadline:
            try:
                ready = process_tree_has_marker(
                    tui_pid,
                    expected_tui_starttime,
                    b"__GROK_INSIDE_BWRAP=1\0",
                )
            except (RuntimeErrorSafe, OSError):
                break
            if ready:
                break
            time.sleep(0.02)
    finally:
        # Resume only the still-matching trusted process group. A failed TUI
        # handoff must never strand an otherwise healthy shared leader stopped.
        try:
            starttime, pgrp, session, state = proc_identity(leader_pid)
            if (
                starttime == leader_starttime
                and pgrp == leader_pid
                and session == leader_pid
                and state != "Z"
            ):
                os.killpg(leader_pid, signal.SIGCONT)
        except (RuntimeErrorSafe, OSError):
            pass
    if not ready:
        raise RuntimeErrorSafe("attaching Grok TUI did not enter its sandbox")


def process_tree_has_marker(
    root_pid: int, expected_root_starttime: int, marker: bytes
) -> bool:
    """Find an environment marker on a live process descended from root_pid.

    The npm Grok entrypoint remains as a Node parent and spawns the native
    client, so the bwrap marker is not necessarily present on the PID that the
    launcher exec'd. Parent links keep the handoff bound to that verified
    launcher tree instead of accepting a marker from an unrelated process.
    """

    root_starttime, _root_ppid, _root_pgrp, _root_session, root_state = proc_record(
        root_pid
    )
    if root_starttime != expected_root_starttime or root_state == "Z":
        raise RuntimeErrorSafe("attaching Grok TUI identity no longer matches")

    records: dict[int, int] = {}
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            if entry.stat(follow_symlinks=False).st_uid != os.getuid():
                continue
            _starttime, ppid, _pgrp, _session, state = proc_record(pid)
        except (RuntimeErrorSafe, OSError, ValueError):
            continue
        if state != "Z":
            records[pid] = ppid

    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, ppid in records.items():
            if pid not in descendants and ppid in descendants:
                descendants.add(pid)
                changed = True

    for pid in descendants:
        try:
            if marker in Path(f"/proc/{pid}/environ").read_bytes():
                return True
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return False


def probe(path: Path, expected_pgid: int, timeout: float) -> None:
    if timeout <= 0 or timeout > 120:
        raise RuntimeErrorSafe("invalid leader probe timeout")
    try:
        socket_mode = path.lstat().st_mode
    except FileNotFoundError as error:
        raise RuntimeErrorSafe("leader socket is missing") from error
    if not stat.S_ISSOCK(socket_mode) or stat.S_ISLNK(socket_mode):
        raise RuntimeErrorSafe("leader socket path is not a socket")

    deadline = time.monotonic() + timeout
    client = socket.socket(socket.AF_UNIX)
    try:
        client.settimeout(timeout)
        client.connect(str(path))
        peer_pid, peer_uid, _peer_gid = struct.unpack(
            "3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        )
        if peer_uid != os.getuid():
            raise RuntimeErrorSafe("leader socket belongs to another user")
        if expected_pgid:
            _starttime, peer_pgrp, peer_session, peer_state = proc_identity(peer_pid)
            if (
                peer_pgrp != expected_pgid
                or peer_session != expected_pgid
                or peer_state == "Z"
            ):
                raise RuntimeErrorSafe("leader socket is not owned by the trusted process group")
        send_frame(
            client,
            {
                "type": "register",
                "client_type": "devide-readiness-probe",
                "mode": "stdio",
                "capabilities": {},
            },
        )
        registered = receive_frame(client, deadline)
        if registered.get("type") != "registered":
            raise RuntimeErrorSafe("leader did not accept registration")
        if not registered.get("ready", True):
            ready = receive_frame(client, deadline)
            if ready.get("type") != "leader_ready":
                raise RuntimeErrorSafe("leader did not become ready")
        send_frame(client, {"type": "disconnect"})
    finally:
        client.close()


def send_frame(client: socket.socket, value: dict[str, object]) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    client.sendall(struct.pack(">I", len(payload)) + payload)


def receive_frame(client: socket.socket, deadline: float) -> dict[str, object]:
    header = receive_exact(client, 4, deadline)
    length = struct.unpack(">I", header)[0]
    if length > MAX_FRAME:
        raise RuntimeErrorSafe("leader sent an oversized frame")
    value = json.loads(receive_exact(client, length, deadline))
    if not isinstance(value, dict):
        raise RuntimeErrorSafe("leader sent an invalid frame")
    return value


def receive_exact(client: socket.socket, length: int, deadline: float) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeErrorSafe("leader readiness probe timed out")
        client.settimeout(remaining)
        chunk = client.recv(length - len(chunks))
        if not chunk:
            raise RuntimeErrorSafe("leader closed the readiness probe")
        chunks.extend(chunk)
    return bytes(chunks)


def validate_runtime_file(path: Path, *, allow_missing: bool) -> None:
    if not path.is_absolute() or path != Path(os.path.abspath(path)):
        raise RuntimeErrorSafe("runtime path must be absolute and normalized")
    try:
        file_stat = path.lstat()
        mode = file_stat.st_mode
    except FileNotFoundError:
        if allow_missing:
            return
        raise RuntimeErrorSafe(f"runtime file is missing: {path.name}") from None
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
        raise RuntimeErrorSafe(f"runtime path is not a regular file: {path.name}")
    if file_stat.st_uid != os.getuid() or stat.S_IMODE(mode) & 0o077:
        raise RuntimeErrorSafe(f"runtime file is not private and owned: {path.name}")


def atomic_write(path: Path, content: str) -> None:
    # The per-leader directory is intentionally model-writable. Stage trusted
    # metadata in its non-writable parent and atomically rename it into place.
    trusted_parent = path.parent.parent
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{path.parent.name}-{path.name}.", dir=trusted_parent
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def close_unneeded_fds(keep: set[int]) -> None:
    for entry in list(Path("/proc/self/fd").iterdir()):
        if not entry.name.isdigit():
            continue
        fd = int(entry.name)
        if fd > 2 and fd not in keep:
            try:
                os.close(fd)
            except OSError:
                pass


def terminate_spawn(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


if __name__ == "__main__":
    raise SystemExit(main())
