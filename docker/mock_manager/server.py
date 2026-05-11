#!/usr/bin/env python3
"""
Tiny stub of the milc-devbox manager — just enough to make DevIDE's
picker render a real workspace and let the show LiveView mount.

NOT a faithful implementation. NOT for use beyond the local
docker-compose smoke stack. The manager has real lifecycle behaviour
(create/start/stop/delete, SSE log streaming, etc.) — this only
returns two GET responses so the cockpit has something to mirror.

Routes served:
    GET /api/workspaces                  → list of workspace summaries
    GET /api/workspaces/<id>/status      → single workspace status

Anything else → 404.

DevIDE consumes the response shapes defined by
lib/dev_ide/devbox/workspace.ex (from_payload/1). Field names match
the manager's actual contract: id, name, user, branch, type, status,
path.
"""

import json
from http.server import BaseHTTPRequestHandler, HTTPServer

WORKSPACES = [
    {
        "id": "alpha",
        "name": "alpha",
        "user": "operator",
        "branch": "main",
        "type": "v3",
        "status": "running",
        # Path is what DevIDE.Workspaces.safe_host_path/1 validates
        # against DEV_IDE_WORKSPACES_ROOT. The compose bind-mount maps
        # ./workspaces-local/alpha → /workspaces/alpha inside the
        # dev_ide container.
        "path": "/workspaces/alpha",
    }
]


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, body):
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/api/workspaces":
            self._send_json(200, WORKSPACES)
            return
        for ws in WORKSPACES:
            if self.path == f"/api/workspaces/{ws['id']}/status":
                self._send_json(200, ws)
                return
        self._send_json(404, {"error": "not_found", "path": self.path})

    def log_message(self, fmt, *args):
        # Keep the compose logs readable.
        print(f"mock-manager {fmt % args}", flush=True)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 9000), Handler)
    print("mock-manager listening on :9000", flush=True)
    server.serve_forever()
