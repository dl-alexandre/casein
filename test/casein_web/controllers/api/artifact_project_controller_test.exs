defmodule CaseinWeb.API.ArtifactProjectControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.ArtifactProjects
  alias Casein.Audit
  alias Casein.Runtimes
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @global_token "test-artifact-restore-global-token"
  @workspace_token "test-artifact-restore-workspace-token"
  @other_workspace_token "test-artifact-restore-other-token"
  @workspace_id "ws-artifact-restore"

  setup do
    previous = %{
      api_token: Application.get_env(:casein, :api_token),
      workspace_api_tokens: Application.get_env(:casein, :workspace_api_tokens),
      artifact_projects_root: Application.get_env(:casein, :artifact_projects_root),
      agent_worktree_roots: Application.get_env(:casein, :agent_worktree_roots),
      runtime_preview_launcher_enabled:
        Application.get_env(:casein, :runtime_preview_launcher_enabled),
      runtimes_adapter: Application.get_env(:casein, :runtimes_adapter),
      workspace_state_adapter: Application.get_env(:casein, :workspace_state_adapter)
    }

    base = Path.join(System.tmp_dir!(), "artifact-restore-#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    artifact_root = Path.join(base, "artifacts")

    Application.put_env(:casein, :api_token, @global_token)

    Application.put_env(:casein, :workspace_api_tokens, %{
      @workspace_token => @workspace_id,
      @other_workspace_token => "ws-other"
    })

    Application.put_env(:casein, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:casein, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    Application.put_env(:casein, :artifact_projects_root, artifact_root)
    Application.put_env(:casein, :agent_worktree_roots, [])
    Application.put_env(:casein, :runtime_preview_launcher_enabled, false)

    MemoryAdapter.clear()
    Runtimes.clear()
    Audit.MemoryAdapter.clear()
    init_repo!(repo)
    seed_workspace!(@workspace_id, "artifact-restore", repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      Audit.MemoryAdapter.clear()
      File.rm_rf!(base)

      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
    end)

    %{base: base, repo: repo}
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post_restore(conn, @workspace_id, "art-unknown", nil)
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "global token restores a cleaned artifact and returns its payload", %{
    conn: conn,
    repo: repo
  } do
    project = cleaned_project!(repo, "Controller Restore")

    conn = post_restore(conn, @workspace_id, project.id, @global_token)

    assert %{
             "action" => "artifact_restored",
             "artifact" => %{
               "id" => artifact_id,
               "workspace_id" => @workspace_id,
               "status" => "provisioned",
               "retired" => false,
               "worktree_path" => worktree_path
             }
           } = json_response(conn, 200)

    assert artifact_id == project.id
    assert File.dir?(worktree_path)

    assert [%{action: "artifact.restored", target_ref: ^artifact_id}] =
             Audit.recent_for(@workspace_id)
  end

  test "matching workspace token may restore an expired artifact", %{conn: conn} do
    assert {:ok, project} = ArtifactProjects.create(@workspace_id, %{name: "Scoped Restore"})
    assert {:ok, _expired} = Runtimes.expire_runtime(project.id)

    conn = post_restore(conn, @workspace_id, project.id, @workspace_token)
    assert %{"artifact" => %{"id" => artifact_id, "retired" => false}} = json_response(conn, 200)
    assert artifact_id == project.id
  end

  test "workspace token cannot restore through another workspace path", %{conn: conn} do
    conn = post_restore(conn, @workspace_id, "art-unknown", @other_workspace_token)
    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "artifact id from another workspace is hidden as not found", %{conn: conn, base: base} do
    other_repo = Path.join(base, "other-repo")
    init_repo!(other_repo)
    seed_workspace!("ws-other", "other-artifacts", other_repo)

    assert {:ok, project} = ArtifactProjects.create("ws-other", %{name: "Other Artifact"})
    assert {:ok, _expired} = Runtimes.expire_runtime(project.id)

    conn = post_restore(conn, @workspace_id, project.id, @global_token)
    assert json_response(conn, 404) == %{"error" => "artifact_not_found"}
  end

  test "missing retained branch returns a stable conflict", %{conn: conn, repo: repo} do
    project = cleaned_project!(repo, "Missing Branch")
    git!(repo, ["branch", "-D", project.branch])

    conn = post_restore(conn, @workspace_id, project.id, @global_token)
    assert json_response(conn, 409) == %{"error" => "artifact_branch_not_found"}
    refute File.exists?(project.worktree_path)
  end

  defp cleaned_project!(repo, name) do
    assert {:ok, project} = ArtifactProjects.create(@workspace_id, %{name: name})
    assert {:ok, _expired} = Runtimes.expire_runtime(project.id)
    git!(repo, ["worktree", "remove", "--force", project.worktree_path])
    assert {:ok, _cleaned} = Runtimes.cleanup_runtime(project.id)
    project
  end

  defp post_restore(conn, workspace_id, artifact_id, token) do
    conn
    |> put_req_header("accept", "application/json")
    |> then(fn conn ->
      if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    end)
    |> post("/api/workspaces/#{workspace_id}/artifacts/#{artifact_id}/restore", %{})
  end

  defp seed_workspace!(id, name, repo) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: name,
        path: repo,
        status: :running,
        metadata: %{"id" => id, "name" => name}
      })
  end

  defp init_repo!(repo) do
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["config", "user.name", "Casein Test"])
    git!(repo, ["config", "user.email", "devide-test@localhost"])
    File.write!(Path.join(repo, "README.md"), "# Artifact Restore Test\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "Initial commit"])
  end

  defp git!(cwd, args) do
    case System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed with #{code}: #{output}")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)
end
