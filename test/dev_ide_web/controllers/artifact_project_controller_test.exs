defmodule CaseinWeb.ArtifactProjectControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.ArtifactProjects
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "ws-art-public"

  # Ownership source used by the controller's authorize gate: "owner" owns any
  # workspace id, so we can exercise the gate without the manager backend.
  defmodule OwnedSource do
    def get(id, _auth), do: {:ok, %Workspace{id: id, name: id, user: "owner", status: :running}}
  end

  setup do
    prev = %{
      artifact_root: Application.get_env(:casein, :artifact_projects_root),
      agent_roots: Application.get_env(:casein, :agent_worktree_roots),
      launcher: Application.get_env(:casein, :runtime_preview_launcher_enabled),
      runtimes: Application.get_env(:casein, :runtimes_adapter),
      wstate: Application.get_env(:casein, :workspace_state_adapter),
      source: Application.get_env(:casein, :workspace_source),
      fa: Application.get_env(:casein, :forward_auth)
    }

    base = Path.join(System.tmp_dir!(), "artifact-pub-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")

    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    Application.put_env(:casein, :artifact_projects_root, Path.join(base, "artifacts"))
    Application.put_env(:casein, :agent_worktree_roots, [])
    Application.put_env(:casein, :runtime_preview_launcher_enabled, false)
    Application.put_env(:casein, :workspace_source, OwnedSource)
    # Identity comes from the X-Auth-Request-Email header, as in prod.
    Application.put_env(:casein, :forward_auth, true)

    MemoryAdapter.clear()
    Runtimes.clear()
    Casein.Audit.MemoryAdapter.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, repo)

    {:ok, project} = ArtifactProjects.create(@workspace_id, %{name: "Smoke Report"})

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Casein.Audit.MemoryAdapter.clear()
      File.rm_rf!(base)
      Enum.each(prev, fn {k, v} -> restore(env_key(k), v) end)
    end)

    %{project_id: project.id, worktree: project.worktree_path}
  end

  test "serves the artifact index.html to the workspace owner with a tight CSP", ctx do
    conn = ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id))

    assert response(conn, 200) =~ "Smoke Report"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "frame-ancestors 'self'"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "serves a named file under the worktree", ctx do
    conn = ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id, "index.html"))
    assert response(conn, 200) =~ "Smoke Report"
  end

  test "serves the artifact to any authenticated peer (flat peer model)", ctx do
    conn = ctx.conn |> as("peer@example.com") |> get(artifact_path(ctx.project_id))

    assert response(conn, 200) =~ "Smoke Report"
  end

  test "404 when the artifact does not belong to the requested workspace", ctx do
    # Owner owns "other-ws" too (OwnedSource), but the artifact belongs to @workspace_id.
    conn =
      ctx.conn
      |> as("owner@example.com")
      |> get("/artifact-projects/other-ws/#{ctx.project_id}/")

    assert text_response(conn, 404) == "not found"
  end

  test "404 for dotfiles (.git / .devide never served)", ctx do
    conn =
      ctx.conn
      |> as("owner@example.com")
      |> get(artifact_path(ctx.project_id, ".devide/artifact.json"))

    assert text_response(conn, 404) == "not found"
  end

  test "404 for path traversal", ctx do
    conn =
      ctx.conn
      |> as("owner@example.com")
      |> get("/artifact-projects/#{@workspace_id}/#{ctx.project_id}/../../README.md")

    assert text_response(conn, 404) == "not found"
  end

  test "401 without a forwarded identity", ctx do
    conn = get(ctx.conn, artifact_path(ctx.project_id))
    assert conn.status == 401
  end

  test "a served artifact carries share-metadata headers", ctx do
    conn = ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id))

    assert response(conn, 200)
    assert get_resp_header(conn, "x-artifact-title") == ["Smoke Report"]
    # branch/commit/status are present (generated), we assert non-empty shape.
    assert [branch] = get_resp_header(conn, "x-artifact-branch")
    assert branch != ""
    assert [commit] = get_resp_header(conn, "x-artifact-commit")
    assert commit =~ ~r/^[0-9a-f]{7,40}$/
    assert [_status] = get_resp_header(conn, "x-artifact-status")
  end

  test "a dedicated artifacts origin still lets the cockpit embed the artifact", ctx do
    Application.put_env(:casein, :preview_app_url, "https://devide.example.com")
    Application.put_env(:casein, :artifact_public_url, "https://artifacts.example.com")

    on_exit(fn ->
      Application.delete_env(:casein, :preview_app_url)
      Application.delete_env(:casein, :artifact_public_url)
    end)

    conn = ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id))

    assert response(conn, 200)
    assert [csp] = get_resp_header(conn, "content-security-policy")
    # Cockpit (a different origin) must be allowed to frame the artifact viewer.
    assert csp =~ "frame-ancestors 'self' https://devide.example.com"
  end

  test "an authorized serve is audited", ctx do
    ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id))

    assert [event] =
             Casein.Audit.MemoryAdapter.recent_with_action_prefix(
               @workspace_id,
               "artifact_project.served",
               10
             )

    assert event.action == "artifact_project.served"
    assert event.actor_id == "owner@example.com"
    assert event.target_type == "artifact_project"
    assert event.target_ref == ctx.project_id
    assert event.decision == :allow
  end

  test "a retired artifact shows the owner a 410 landing page (not a 404)", ctx do
    # Simulate cleanup: the worktree files are gone but the id stays valid.
    File.rm_rf!(ctx.worktree)

    conn = ctx.conn |> as("owner@example.com") |> get(artifact_path(ctx.project_id))

    body = response(conn, 410)
    assert body =~ "retired"
    assert body =~ "Smoke Report"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'none'"

    assert [_retired] =
             Casein.Audit.MemoryAdapter.recent_with_action_prefix(
               @workspace_id,
               "artifact_project.retired",
               10
             )
  end

  test "a retired artifact shows any authenticated peer the 410 landing page", ctx do
    File.rm_rf!(ctx.worktree)

    conn = ctx.conn |> as("peer@example.com") |> get(artifact_path(ctx.project_id))
    body = response(conn, 410)
    assert body =~ "retired"
  end

  # --- helpers ---

  defp artifact_path(project_id, sub \\ ""),
    do: "/artifact-projects/#{@workspace_id}/#{project_id}/#{sub}"

  defp as(conn, email), do: put_req_header(conn, "x-auth-request-email", email)

  defp seed_workspace!(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "Artifact Workspace",
        user: "owner",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "branch" => "main"}
      })
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "--initial-branch=main"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(path, "README.md"), "# Test\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "init"])
    :ok
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(out)
  end

  defp env_key(:artifact_root), do: :artifact_projects_root
  defp env_key(:agent_roots), do: :agent_worktree_roots
  defp env_key(:launcher), do: :runtime_preview_launcher_enabled
  defp env_key(:runtimes), do: :runtimes_adapter
  defp env_key(:wstate), do: :workspace_state_adapter
  defp env_key(:source), do: :workspace_source
  defp env_key(:fa), do: :forward_auth

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)
end
