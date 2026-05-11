#!/usr/bin/env python3
"""
Phoenix Channel keystroke-roundtrip smoke for DevIDE's terminal flow.

Closes the only end-to-end gap left after the docker-compose stack
verification: this script literally opens a websocket against a
running DevIDE, joins the terminal channel for a workspace, sends
keystrokes as `input` events, and waits for matching bytes back as
`data` push events. If the marker text round-trips, the full
xterm.js ↔ Phoenix.Channel ↔ Session ↔ tmux flow is real on the
production Dockerfile.

Usage (assumes the dev-profile compose stack is up):

    # 1. Generate a signed user token from inside the running release.
    TOKEN=$(docker compose exec -T dev_ide /app/bin/dev_ide rpc \\
        'IO.write(DevIdeWeb.ChannelAuth.sign_user_token("smoke-user"))')

    # 2. Run the smoke.
    python3 docker/smoke/channel_smoke.py \\
        --url ws://localhost:4000/socket/websocket \\
        --token "$TOKEN" \\
        --workspace alpha

Requires: Python 3.10+ and `websockets` (pip install websockets).

Exit codes:
    0 — success: marker bytes round-tripped within the timeout
    1 — failure: marker not seen within the timeout
    2 — channel join refused or other protocol error
"""

import argparse
import asyncio
import json
import sys
import secrets
from urllib.parse import urlencode

import websockets


PROTOCOL_VSN = "2.0.0"


async def smoke(url: str, token: str, workspace: str, timeout: float) -> int:
    sid = "smoke-" + secrets.token_hex(4)
    topic = f"terminal:{workspace}:{sid}"
    marker = "SMOKE_MARK_" + secrets.token_hex(3).upper()

    qs = urlencode({"token": token, "vsn": PROTOCOL_VSN})
    full_url = f"{url}?{qs}"

    print(f"connecting {full_url}", flush=True)
    print(f"topic {topic}", flush=True)
    print(f"marker {marker}", flush=True)

    async with websockets.connect(full_url) as ws:
        # Phoenix v2 frame format: [join_ref, ref, topic, event, payload]
        join_ref = "1"

        # 1. Join the terminal channel.
        await ws.send(json.dumps([join_ref, "1", topic, "phx_join", {}]))

        # 2. Wait for the join reply.
        join_reply = await asyncio.wait_for(ws.recv(), timeout=timeout)
        msg = json.loads(join_reply)
        if not (
            len(msg) == 5
            and msg[3] == "phx_reply"
            and msg[4].get("status") == "ok"
        ):
            print(f"channel join refused: {msg}", file=sys.stderr, flush=True)
            return 2
        print(f"joined; reply payload: {msg[4].get('response')}", flush=True)

        # 3. Send keystrokes that produce our marker on stdout.
        await ws.send(
            json.dumps(
                [join_ref, "2", topic, "input", {"data": f"echo {marker}\n"}]
            )
        )

        # 4. Wait for a `data` push that contains the marker. Drain
        # everything until either we see it or we time out — tmux
        # paints the screen on attach which produces a lot of noise.
        deadline = asyncio.get_event_loop().time() + timeout
        seen = bytearray()
        while True:
            remaining = deadline - asyncio.get_event_loop().time()
            if remaining <= 0:
                preview = bytes(seen[-400:]).decode("utf-8", "replace")
                print(
                    f"timed out without seeing {marker}\n"
                    f"last 400 bytes received: {preview!r}",
                    file=sys.stderr,
                    flush=True,
                )
                return 1
            try:
                frame = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                continue
            push = json.loads(frame)
            if len(push) == 5 and push[3] == "data":
                chunk = push[4].get("data", "")
                seen.extend(chunk.encode("utf-8", "replace"))
                if marker.encode() in seen:
                    print(
                        f"OK — marker observed in channel data after "
                        f"{len(seen)} bytes",
                        flush=True,
                    )
                    return 0
            elif len(push) == 5 and push[3] == "exit":
                print(f"channel exited: {push[4]}", file=sys.stderr, flush=True)
                return 2


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Phoenix Channel keystroke-roundtrip smoke for DevIDE."
    )
    parser.add_argument("--url", required=True, help="ws:// URL of the socket endpoint")
    parser.add_argument("--token", required=True, help="signed user token")
    parser.add_argument("--workspace", required=True, help="workspace id")
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="seconds to wait for the marker (default 10)",
    )
    args = parser.parse_args()

    return asyncio.run(smoke(args.url, args.token, args.workspace, args.timeout))


if __name__ == "__main__":
    sys.exit(main())
