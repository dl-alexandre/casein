# Artifact Projects

Artifact Projects are generated, previewable worktrees owned by DevIDE. They
are the core storage and preview layer for an artifact skill: agents can create
or update a self-contained project, DevIDE records it as a runtime, and the
existing preview stack exposes a local HTTP URL. The agent-facing MCP endpoint
is `POST /api/artifacts/mcp`.

## Responsibility

- Create one Git worktree per artifact project.
- Store artifact metadata in the runtime record under `metadata["artifact_project"]`.
- Keep generated source files in the artifact worktree, not in the main checkout.
- Build runtime preview server metadata so the existing preview launcher can
  serve static artifacts with live DevIDE preview surfaces.
- Preserve prompt history and write `.devide/artifact.json` alongside the
  generated files.

This subsystem deliberately avoids the existing `DevIDE.Previews.Artifacts`
namespace, which is used for screenshot and recording files.

## MVP Flow

`DevIDE.ArtifactProjects.create/2` accepts a workspace id plus artifact attrs.
It validates the workspace is a Git checkout, creates a branch and worktree from
the workspace `HEAD`, writes either caller supplied files or a static HTML
scaffold, commits the result, and registers the worktree through
`DevIDE.Runtimes.observe_worktree/2`.

The runtime registration is important: it gives artifacts the same isolation,
preview server metadata, preview URL shape, and runtime surface export that
agent-created worktrees already use.

`DevIDE.ArtifactProjects.update/2` writes new files, appends prompt feedback to
the stored history, refreshes `.devide/artifact.json`, commits the edit, and
re-observes the runtime so the preview metadata stays current.

`DevIDE.ArtifactProjects.snapshot/2` creates an explicit Git commit, using
`--allow-empty` when the artifact worktree is already clean. This makes
artifact snapshots durable version markers even when the user wants to save a
review checkpoint without file changes.

`DevIDE.ArtifactProjects.serve/1` delegates to
`DevIDE.Runtimes.PreviewLauncher.ensure_started/1`. Static artifacts currently
use the runtime preview launcher with `DEVIDE_RUNTIME_PREVIEW_COMMAND` set to:

```bash
python3 -m http.server "$PORT" --bind 127.0.0.1
```

## Configuration

Artifact worktrees live under `:dev_ide, :artifact_projects_root`. Releases can
set it with:

```bash
DEV_IDE_ARTIFACT_PROJECTS_ROOT=/opt/devide/artifact_projects
```

When this root is configured, `DevIDE.Runtimes` automatically accepts worktrees
under it as agent/runtime worktrees. Without this coupling, artifact creation
would succeed on disk but fail runtime preview registration when the root lives
outside the default `/tmp/devide-agent-worktrees` tree.

For a local smoke test against an already-known workspace:

```bash
mix dev_ide.artifact.smoke WORKSPACE_ID --name "Artifact Smoke" --serve
```

The task prints the same JSON-ready project payload returned by
`DevIDE.ArtifactProjects.payload/1` when run with `--json`:

```json
{
  "id": "art-...",
  "workspace_id": "workspace-id",
  "runtime_id": "art-...",
  "name": "Artifact Smoke",
  "kind": "static",
  "status": "draft",
  "worktree_path": "/opt/devide/artifact_projects/workspace/artifact-smoke",
  "preview_url": "http://localhost:4100",
  "preview_open_arguments": {
    "workspace_id": "workspace-id",
    "mode": "app",
    "runtime_id": "art-..."
  }
}
```

Agents can pass `preview_open_arguments` to the existing Preview MCP
`preview_open` tool; a separate artifact-open preview tool is not required for
static artifacts.

## Cockpit Gallery

The workspace cockpit includes an `artifacts` tab. It lists artifact projects
for the current workspace, shows their runtime/worktree metadata, refreshes the
runtime-backed list, starts the runtime preview server, and opens the artifact
through the same tmux preview-pane split used by the normal Preview tools.

The LiveView event handlers re-fetch the artifact project and verify
`project.workspace_id == socket.assigns.workspace.id` before serving or opening
it, so a cross-workspace artifact id cannot be used from another cockpit.

The gallery also has an inspect action that serves the artifact, selects it, and
opens a detail pane. The detail pane embeds the preview directly only when the
preview URL is already same-origin (`/...`); off-origin/local runtime URLs stay
on the safer preview-pane path.

## MCP Surface

`DevIdeWeb.API.ArtifactMCP` exposes the context through workspace-scoped MCP
tools. Global API tokens may initialize and list tools, but `tools/call` follows
the terminal/preview MCP rule and requires a workspace-scoped token.

| Tool | Backend call | Response |
|------|--------------|----------|
| `artifact_create` | `ArtifactProjects.create/2` | `ArtifactProjects.payload/1` |
| `artifact_update` | `ArtifactProjects.update/2` | `ArtifactProjects.payload/1` |
| `artifact_list` | `ArtifactProjects.list/1` | list of payloads |
| `artifact_get` | `ArtifactProjects.get/1` | one payload |
| `artifact_serve` | `ArtifactProjects.serve/1` | refreshed payload |
| `artifact_snapshot` | `ArtifactProjects.snapshot/2` | project id and commit SHA |

Successful project payloads also include:

- `preview_open_arguments` — pass to Preview MCP `preview_open`.
- `next_tool: "preview_open"` / `next_arguments` — a direct handoff hint for
  agents.

## Boundaries

- Supported kinds are `static` and `html`.
- Paths must be relative, must not escape the artifact root, and may not target
  `.git`.
- The generated Elixir code path is intentionally not implemented yet. LiveView
  artifacts need a stricter sandbox story before dynamically compiling code into
  the running DevIDE VM.
- Cross-workspace artifact access is rejected before mutating operations; an
  artifact id from another workspace returns `workspace_scope_mismatch`.
- The cockpit gallery is a runtime/worktree browser. It does not yet provide
  file-level editing or generated LiveView artifact sandboxes.

## Public sharing & the dedicated artifacts origin

An artifact is PR-shareable via a durable, login-gated route served straight from
its worktree:

```
GET /artifact-projects/:workspace_id/:artifact_project_id/*path
```

It runs under the devbox oauth2-proxy `forward_auth` and additionally gates on
workspace ownership (404, not 403, on any authz failure). `ArtifactProjects.payload/1`
exposes this as `public_url` (plus `commit` and `retired`), so `artifact_create/
serve/get` responses carry the shareable link directly. The link references stable
ids — not the ephemeral loopback preview port — so it survives restarts and deploys.

**Origin selection.** `public_url` is built from the first configured of:

1. `:artifact_public_url` (env `DEVIDE_ARTIFACT_URL`) — a **dedicated, isolated
   origin** for artifacts.
2. `:preview_app_url` (env `DEVIDE_URL`) — the cockpit origin (default).

Serving workspace-authored (untrusted) HTML from its own origin is stronger
isolation: a compromised artifact can't reach cockpit cookies or its same-origin
surface. The controller's CSP `frame-ancestors` is computed per request — when a
dedicated origin is configured it also allows the cockpit origin, so the workspace
viewer can still embed the artifact iframe.

**Enabling the dedicated origin (infra, outside this repo).** The DevIDE side is a
no-op until the manager routes a subdomain here:

1. DNS: point `artifacts.devbox.milcgroup.com` at the devbox.
2. TLS: a cert for that host (Caddy auto-cert or the existing wildcard).
3. Manager/Caddy: route that host through the **same** oauth2-proxy `forward_auth`
   block as `devide.devbox…`, upstreaming to the DevIDE port. A single shared
   origin — **not** per-workspace subdomains (rejected: collide with legacy/v3
   wildcard routing, which is intentionally non-OAuth).
4. Set `DEVIDE_ARTIFACT_URL=https://artifacts.devbox.milcgroup.com` in the release
   env. `public_url`s then resolve to the dedicated origin automatically.

## Next Steps

- Add file watch plus preview refresh events for tighter edit loops.
- Add same-origin preview proxy URLs for static runtime artifacts so more
  detail views can render inline without relying on direct localhost URLs.
- Add export targets once artifacts need promotion to deployment pipelines.
- Design a separate, sandboxed LiveView artifact runtime instead of mounting
  generated modules directly in the main application.
