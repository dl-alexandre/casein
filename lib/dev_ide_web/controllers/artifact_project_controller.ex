defmodule DevIdeWeb.ArtifactProjectController do
  @moduledoc """
  Serves an artifact project's static files directly from its git worktree, at a
  durable, login-gated URL:

      /artifact-projects/:workspace_id/:artifact_project_id/*path

  This is what makes an artifact PR-shareable. It runs under the devbox
  oauth2-proxy (forward_auth) like the rest of the DevIDE host, and additionally
  gates on workspace ownership. Unlike the artifact's ephemeral loopback preview
  server (a `python3 -m http.server` on a churny 41050-41079 port), this reads
  the worktree straight off disk, so the URL survives restarts, port
  reassignment, and deploys — it references stable ids, never a port.

  Security: identity comes from `ForwardAuth`; we verify the viewer owns the
  workspace AND that the artifact belongs to it (404, not 403, so ids don't
  leak). Paths are resolved with `DevIDE.Files.PathSafety` (traversal + symlink
  escape) plus a dotfile/`.git` denylist (PathSafety does not block dotfiles on
  read), and served under a tight CSP since the content is workspace-authored.
  """
  use DevIdeWeb, :controller

  alias DevIDE.ArtifactProjects
  alias DevIDE.Audit
  alias DevIDE.Files.PathSafety
  alias DevIDE.Workspaces

  # Workspace-authored (untrusted) content served on the cockpit origin: allow it
  # to render itself (inline styles/scripts, same-origin + data/blob media) but
  # not exfiltrate to third parties or frame the cockpit. A dedicated artifact
  # origin would be stronger isolation (deferred).
  @artifact_csp "default-src 'self'; img-src 'self' data: blob:; " <>
                  "media-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; " <>
                  "script-src 'self' 'unsafe-inline'; font-src 'self' data:; " <>
                  "connect-src 'self'; object-src 'none'; base-uri 'none'; " <>
                  "frame-ancestors 'self'"

  # The retired-artifact landing page is OUR trusted HTML (not workspace content),
  # so it locks down to just its own inline styles — no scripts, no network.
  @landing_csp "default-src 'none'; style-src 'unsafe-inline'; img-src data:; " <>
                 "base-uri 'none'; frame-ancestors 'self'"

  def show(conn, %{"workspace_id" => workspace_id, "artifact_project_id" => project_id} = params) do
    segments = Map.get(params, "path", [])

    with {:ok, _workspace} <- authorize(conn, workspace_id),
         {:ok, project} <- fetch_project(project_id, workspace_id) do
      serve_or_landing(conn, project, segments)
    else
      _ -> not_found(conn)
    end
  rescue
    _ -> not_found(conn)
  end

  # The viewer owns the workspace AND the artifact belongs to it, so a 404 here
  # would leak nothing new — we can tell the owner *why* a file is missing. A
  # retired artifact (worktree cleaned/expired/gone) gets a friendly landing
  # page; a live artifact with a merely-missing sub-path still 404s opaquely.
  defp serve_or_landing(conn, project, segments) do
    case resolve_file(project.worktree_path, segments) do
      {:ok, file} ->
        audit(conn, project, :served, %{"path" => Enum.join(segments, "/")})

        conn
        |> put_resp_header("content-security-policy", @artifact_csp)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_share_headers(project)
        |> put_resp_content_type(MIME.from_path(file))
        |> send_file(200, file)

      :error ->
        if ArtifactProjects.retired?(project) do
          audit(conn, project, :retired, %{})
          render_retired(conn, project)
        else
          not_found(conn)
        end
    end
  end

  # Mirrors PreviewArtifactController.authorize/2. 404 (via :forbidden at the call
  # site) rather than 403 so we don't reveal which workspace ids exist.
  defp authorize(conn, workspace_id) do
    viewer = conn.assigns[:current_user]
    auth = viewer && Map.get(viewer, :email)

    case Workspaces.get(workspace_id, auth) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, viewer || %{}),
          do: {:ok, workspace},
          else: :forbidden

      _ ->
        :forbidden
    end
  end

  # The artifact must exist AND belong to the authorized workspace — otherwise an
  # owner of workspace A could read workspace B's artifact by guessing its id.
  defp fetch_project(project_id, workspace_id) do
    case ArtifactProjects.get(project_id) do
      {:ok, %{workspace_id: ^workspace_id, worktree_path: root} = project}
      when is_binary(root) ->
        {:ok, project}

      _ ->
        :forbidden
    end
  end

  defp resolve_file(root, segments) do
    cond do
      not is_binary(root) -> :error
      # PathSafety guards traversal + symlink escape but NOT dotfiles; refuse them
      # so `.git/` (full history) and `.devide/artifact.json` are never served.
      Enum.any?(segments, &dotfile?/1) -> :error
      true -> do_resolve(root, relative_path(segments))
    end
  end

  defp do_resolve(root, relative) do
    case PathSafety.resolve(root, relative) do
      {:ok, abs} ->
        cond do
          File.regular?(abs) -> {:ok, abs}
          File.dir?(abs) -> resolve_index(root, relative)
          true -> :error
        end

      {:error, _} ->
        :error
    end
  end

  # Directory (or root) request → serve its index.html, re-validated under root.
  defp resolve_index(root, relative) do
    case PathSafety.resolve(root, Path.join(relative, "index.html")) do
      {:ok, abs} -> if File.regular?(abs), do: {:ok, abs}, else: :error
      {:error, _} -> :error
    end
  end

  defp relative_path([]), do: "index.html"
  defp relative_path(segments), do: Path.join(segments)

  defp dotfile?(segment), do: String.starts_with?(segment, ".")

  defp not_found(conn), do: conn |> put_status(404) |> text("not found")

  # Share metadata as response headers so a teammate (or tooling) hitting the
  # durable link learns what it is without parsing the body. Title is
  # workspace-authored, so every value is sanitized against header injection.
  defp put_share_headers(conn, project) do
    meta = ArtifactProjects.share_metadata(project)

    conn
    |> maybe_put_header("x-artifact-title", meta.title)
    |> maybe_put_header("x-artifact-branch", meta.branch)
    |> maybe_put_header("x-artifact-commit", meta.commit)
    |> maybe_put_header("x-artifact-status", meta.status)
  end

  defp maybe_put_header(conn, _name, nil), do: conn

  defp maybe_put_header(conn, name, value) do
    case sanitize_header(value) do
      "" -> conn
      clean -> put_resp_header(conn, name, clean)
    end
  end

  # Strip control chars (incl. CR/LF) so an artifact title can never split the
  # response or inject a second header; cap length to keep headers bounded.
  defp sanitize_header(value) do
    value
    |> to_string()
    |> String.replace(~r/[[:cntrl:]]/u, "")
    |> String.slice(0, 200)
    |> String.trim()
  end

  # 410 Gone: the id was valid and owned by the viewer, but the artifact's files
  # are no longer on disk. Owner-only (we already authorized), so it's safe to
  # echo the title/branch/commit back.
  defp render_retired(conn, project) do
    meta = ArtifactProjects.share_metadata(project)

    conn
    |> put_resp_header("content-security-policy", @landing_csp)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_content_type("text/html")
    |> send_resp(410, retired_html(meta))
  end

  defp retired_html(meta) do
    title = esc(meta.title)
    branch = esc(meta.branch || "—")
    commit = esc(short_sha(meta.commit))
    changed = esc(meta.updated_at || meta.created_at || "—")

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Artifact retired · #{title}</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 15px/1.5 system-ui, sans-serif; max-width: 34rem; margin: 12vh auto; padding: 0 1.25rem; }
      h1 { font-size: 1.35rem; margin: 0 0 .5rem; }
      p { color: #6b7280; margin: 0 0 1.5rem; }
      dl { display: grid; grid-template-columns: max-content 1fr; gap: .35rem 1rem; margin: 0; }
      dt { color: #9ca3af; }
      dd { margin: 0; font-variant-numeric: tabular-nums; }
    </style>
    </head>
    <body>
      <main>
        <h1>This artifact has been retired</h1>
        <p>“#{title}” is no longer available — its files were cleaned up after the workspace stopped. The link stays valid, so you can re-generate the artifact and it will reappear here.</p>
        <dl>
          <dt>Branch</dt><dd>#{branch}</dd>
          <dt>Last commit</dt><dd>#{commit}</dd>
          <dt>Last updated</dt><dd>#{changed}</dd>
        </dl>
      </main>
    </body>
    </html>
    """
  end

  # Fire-and-forget audit of every authorized serve/retired hit on the durable
  # public URL — the login-gated read path that isn't otherwise visible in MCP
  # activity. Never blocks or fails the response.
  defp audit(conn, project, event, extra) do
    viewer = conn.assigns[:current_user]

    Audit.emit!(%{
      action: "artifact_project.#{event}",
      workspace_id: project.workspace_id,
      actor_id: viewer && Map.get(viewer, :email),
      target_type: "artifact_project",
      target_ref: project.id,
      decision: :allow,
      metadata: Map.merge(%{"status" => project.status}, extra)
    })

    :ok
  end

  defp esc(nil), do: ""
  defp esc(value), do: value |> to_string() |> Plug.HTML.html_escape()

  defp short_sha(nil), do: "—"
  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
end
