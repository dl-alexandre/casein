import base64
import json
import sys


browsers = {}


def write(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def ok(request_id, result=None):
    write({"id": request_id, "ok": True, "result": result or {}})


def error(request_id, reason):
    write({"id": request_id, "ok": False, "error": reason})


def title_for(url):
    if url == "about:blank":
        return "Blank"
    return url.split("//", 1)[-1].split("/", 1)[0]


def browser_for(ref):
    browser = browsers.get(ref)
    if browser is None or browser.get("closed"):
        return None
    return browser


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
        options = payload.get("options", {})
        url = options.get("url", "about:blank")
        ref = "external-" + browser_id

        browsers[ref] = {
            "browser_id": browser_id,
            "url": url,
            "title": title_for(url),
            "closed": False,
        }

        ok(request_id, {"browser_ref": ref})

    elif command == "navigate":
        ref = payload["browser_ref"]
        url = payload["url"]
        browser = browser_for(ref)

        if browser is None:
            error(request_id, "browser_not_found")
            continue

        browser["url"] = url
        browser["title"] = title_for(url)

        write(
            {
                "type": "event",
                "browser_id": browser["browser_id"],
                "event": ["console", "info", "navigated " + url],
            }
        )

        ok(
            request_id,
            {
                "url": browser["url"],
                "title": browser["title"],
                "status": 200,
            },
        )

    elif command == "observe":
        ref = payload["browser_ref"]
        browser = browser_for(ref)

        if browser is None:
            error(request_id, "browser_not_found")
            continue

        ok(
            request_id,
            {
                "url": browser["url"],
                "title": browser["title"],
                "status": 200,
            },
        )

    elif command == "cdp":
        ref = payload["browser_ref"]
        browser = browser_for(ref)

        if browser is None:
            error(request_id, "browser_not_found")
            continue

        ok(
            request_id,
            {
                "method": payload["method"],
                "params": payload.get("params", {}),
                "url": browser["url"],
            },
        )

    elif command == "screenshot":
        ref = payload["browser_ref"]
        browser = browser_for(ref)

        if browser is None:
            error(request_id, "browser_not_found")
            continue

        data = ("external screenshot for " + browser["url"]).encode("utf-8")

        ok(
            request_id,
            {
                "mime_type": "image/png",
                "data_base64": base64.b64encode(data).decode("ascii"),
                "url": browser["url"],
            },
        )

    elif command == "close_browser":
        ref = payload["browser_ref"]
        browser = browser_for(ref)

        if browser is None:
            error(request_id, "browser_not_found")
            continue

        browser["closed"] = True
        ok(request_id)

    else:
        error(request_id, "unknown_command")
