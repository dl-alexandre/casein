import json
import sys


def write(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for raw_line in sys.stdin:
    line = raw_line.strip()

    if not line:
        continue

    request = json.loads(line)
    request_id = request["id"]
    command = request["command"]
    payload = request.get("payload", {})

    if command == "open_browser":
        browser_id = payload["browser_id"]
        write(
            {
                "id": request_id,
                "ok": True,
                "result": {"browser_ref": "external-" + browser_id},
            }
        )
    elif command == "navigate":
        sys.exit(7)
    else:
        write({"id": request_id, "ok": False, "error": "backend_unavailable"})
