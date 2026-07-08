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

  def show(conn, %{"workspace_id" => workspace_id, "artifact_project_id" => project_id} = params) do
    segments = Map.get(params, "path", [])

    with {:ok, _workspace} <- authorize(conn, workspace_id),
         {:ok, project} <- fetch_project(project_id, workspace_id),
         {:ok, file} <- resolve_file(project.worktree_path, segments) do
      conn
      |> put_resp_header("content-security-policy", @artifact_csp)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_content_type(MIME.from_path(file))
      |> send_file(200, file)
    else
      _ -> not_found(conn)
    end
  rescue
    _ -> not_found(conn)
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
end
