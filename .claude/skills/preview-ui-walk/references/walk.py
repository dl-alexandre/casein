#!/usr/bin/env python3
"""
preview-ui-walk driver: a READ-ONLY, manifest-driven UI smoke walk of a workspace
app via the DevIDE preview MCP, producing a self-contained HTML report + a
recording.

Structurally read-only: it ONLY calls navigate / screenshot / report_errors —
never click/type/press — so it cannot fire the app's mutating events. Honor the
manifest's safety block regardless.

Env (source the target workspace's env.sh first):
    DEVIDE_PREVIEW_MCP_URL   workspace-scoped preview MCP endpoint
    DEV_IDE_API_TOKEN        workspace-scoped bearer token

Usage:
    walk.py --manifest path/to/manifest.json --out ./run [--settle-ms 1500]

Emits: <out>/report.html, <out>/results.json, <out>/shot-*.png. Prints the webm
artifact path (open the report via the artifact MCP for the same-origin <video>).
"""
import argparse
import base64
import html
import json
import os
import sys
import time
import urllib.request

URL = os.environ.get("DEVIDE_PREVIEW_MCP_URL")
TOKEN = os.environ.get("DEV_IDE_API_TOKEN")


def die(msg, code=2):
    print(f"[preview-ui-walk] ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def mcp(tool, args):
    if not URL or not TOKEN:
        die("DEVIDE_PREVIEW_MCP_URL / DEV_IDE_API_TOKEN not set (source the workspace env.sh)")
    body = json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": tool, "arguments": args}}
    ).encode()
    req = urllib.request.Request(
        URL, data=body,
        headers={"Authorization": f"Bearer {TOKEN}",
                 "Content-Type": "application/json",
                 "Accept": "application/json, text/event-stream"},
    )
    raw = urllib.request.urlopen(req, timeout=120).read().decode()
    obj = None
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if line:
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                pass
    if obj is None:
        die(f"no JSON in MCP response for {tool}: {raw[:300]}")
    if "error" in obj:
        return {"_error": obj["error"]}
    res = obj.get("result", {})
    if isinstance(res, dict) and "content" in res:
        txt = res["content"][0].get("text", "")
        try:
            return json.loads(txt)
        except json.JSONDecodeError:
            return {"_text": txt}
    return res


def open_app(surface):
    r = mcp("preview_open_app", {"surface": surface} if surface else {})
    if "_error" in r:
        r = mcp("preview_open_app", {"surface": "base:app"})
    sid = r.get("session_id") if "_error" not in r else None
    if not sid:
        die(f"could not open/reuse app preview: {json.dumps(r)[:300]}")
    return sid, r.get("current_url")


def query(sid, path):
    """Build a path with query params already applied (login step)."""
    return mcp("preview_navigate", {"session_id": sid, "path": path})


def capture(sid):
    shot = mcp("preview_screenshot", {"session_id": sid})
    art = (shot.get("screenshot") or {}).get("artifact", "") if "_error" not in shot else ""
    errs = mcp("preview_report_errors", {"session_id": sid})
    ce = len(errs.get("console_errors", []) or []) if isinstance(errs, dict) else 0
    ne = len(errs.get("network_errors", []) or []) if isinstance(errs, dict) else 0
    return art, ce, ne


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--settle-ms", type=int, default=1500)
    a = ap.parse_args()

    m = json.load(open(a.manifest))
    os.makedirs(a.out, exist_ok=True)
    surface = m.get("app_surface", "app")

    sid, cur = open_app(surface)
    print(f"[preview-ui-walk] reusing app session {sid} -> {cur}")

    rec = mcp("preview_record_start", {"session_id": sid})
    print(f"[preview-ui-walk] recording: {rec.get('recording_id', rec)}")

    # Login (session-inject preferred). Structurally read-only — a navigate only.
    login = m.get("login", {})
    if login.get("type") == "session_inject":
        params = login.get("params", {})
        qs = "&".join(f"{k}={v}" for k, v in params.items())
        path = login["path"] + (("?" + qs) if qs else "")
        query(sid, path)
        print(f"[preview-ui-walk] session-inject login -> {path}")

    results = []
    for p in m["pages"]:
        t0 = time.monotonic()
        nav = query(sid, p["path"])
        time.sleep(a.settle_ms / 1000.0)
        art, ce, ne = capture(sid)
        elapsed = int((time.monotonic() - t0) * 1000)
        ok_load = "_error" not in nav and art.startswith("data:image/png;base64,")
        within = elapsed <= p.get("budget_ms", 15000)
        status = "PASS" if (ok_load and within and ce == 0) else "FAIL"
        shot_file = None
        if art.startswith("data:image/png;base64,"):
            shot_file = f"shot-{len(results):02d}.png"
            open(os.path.join(a.out, shot_file), "wb").write(
                base64.b64decode(art.split(",", 1)[1]))
        row = {"name": p["name"], "path": p["path"], "ms": elapsed,
               "budget_ms": p.get("budget_ms"), "console_errors": ce,
               "network_errors": ne, "status": status, "shot": art if art else None,
               "shot_file": shot_file}
        results.append(row)
        print(f"[preview-ui-walk] {status:4} {p['name']:16} {elapsed:6}ms  ce={ce} ne={ne}")

    stop = mcp("preview_record_stop", {"session_id": sid})
    webm = stop.get("url") or stop.get("artifact_path") if isinstance(stop, dict) else None
    print(f"[preview-ui-walk] recording: {webm}")

    json.dump({"session_id": sid, "webm": webm, "pages": results},
              open(os.path.join(a.out, "results.json"), "w"), indent=2)

    write_report(a.out, m, webm, results)
    passed = sum(1 for r in results if r["status"] == "PASS")
    print(f"[preview-ui-walk] {passed}/{len(results)} pages PASS -> {a.out}/report.html")
    return 0 if passed == len(results) else 1


def write_report(out, m, webm, results):
    rows = []
    for r in results:
        img = f'<img src="{r["shot"]}" width="240">' if r.get("shot") else "—"
        color = "#2ea043" if r["status"] == "PASS" else "#f85149"
        rows.append(
            f'<tr><td>{img}</td><td><b>{html.escape(r["name"])}</b><br>'
            f'<code>{html.escape(r["path"])}</code></td>'
            f'<td>{r["ms"]}ms<br><small>budget {r["budget_ms"]}</small></td>'
            f'<td>console {r["console_errors"]}<br>network {r["network_errors"]}</td>'
            f'<td style="color:{color}"><b>{r["status"]}</b></td></tr>')
    video = (f'<video src="{webm}" controls autoplay muted loop width="960"></video>'
             if webm else "<em>no recording</em>")
    doc = f"""<!doctype html><meta charset=utf-8>
<title>{html.escape(m.get('report', {}).get('name', 'preview-ui-walk'))}</title>
<style>body{{font-family:system-ui,Arial;margin:2rem;background:#0b1021;color:#e6e6e6}}
table{{border-collapse:collapse;width:100%}}td{{border-top:1px solid #333;padding:.6rem;vertical-align:top}}
code{{color:#79c0ff}}video{{max-width:100%;border:1px solid #333;border-radius:8px}}</style>
<h1>{html.escape(m.get('report', {}).get('name', 'preview-ui-walk'))}</h1>
<p>Read-only preview walk of <code>{html.escape(m.get('workspace',''))}</code>.</p>
{video}
<table><tr><th>Screen</th><th>Page</th><th>Load</th><th>Errors</th><th>Result</th></tr>
{''.join(rows)}</table>"""
    open(os.path.join(out, "report.html"), "w").write(doc)


if __name__ == "__main__":
    sys.exit(main())
