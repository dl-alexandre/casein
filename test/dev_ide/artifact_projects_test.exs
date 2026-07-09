defmodule DevIDE.ArtifactProjectsTest do
  use DevIDE.TestCase, async: false

  import ExUnit.CaptureIO

  alias DevIDE.ArtifactProjects
  alias DevIDE.Runtimes
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    prev_artifact_root = Application.get_env(:dev_ide, :artifact_projects_root)
    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)
    prev_launcher_enabled = Application.get_env(:dev_ide, :runtime_preview_launcher_enabled)
    prev_runtimes_adapter = Application.get_env(:dev_ide, :runtimes_adapter)
    prev_workspace_state_adapter = Application.get_env(:dev_ide, :workspace_state_adapter)

    base = tmp_dir!("artifact-projects")
    repo = Path.join(base, "repo")
    artifact_root = Path.join(base, "artifacts")

    Application.put_env(:dev_ide, :workspace_state_adapter, MemoryAdapter)
    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)
    Application.put_env(:dev_ide, :artifact_projects_root, artifact_root)
    Application.put_env(:dev_ide, :agent_worktree_roots, [])
    Application.put_env(:dev_ide, :runtime_preview_launcher_enabled, false)

    MemoryAdapter.clear()
    Runtimes.clear()
    Mix.Task.reenable("dev_ide.artifact.smoke")
    init_repo!(repo)
    seed_workspace!("ws-artifacts", repo)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      File.rm_rf!(base)

      restore_env(:artifact_projects_root, prev_artifact_root)
      restore_env(:agent_worktree_roots, prev_agent_roots)
      restore_env(:runtime_preview_launcher_enabled, prev_launcher_enabled)
      restore_env(:runtimes_adapter, prev_runtimes_adapter)
      restore_env(:workspace_state_adapter, prev_workspace_state_adapter)
    end)

    %{base: base, repo: repo, artifact_root: artifact_root}
  end

  test "create builds a runtime-backed static artifact worktree" do
    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Milk Dashboard",
               prompt: "Show daily protein orders"
             })

    assert String.starts_with?(project.id, "art-")
    assert project.runtime_id == project.id
    assert project.name == "Milk Dashboard"
    assert project.kind == "static"
    assert project.prompt_history == ["Show daily protein orders"]
    assert project.metadata["status"] == "draft"
    assert File.read!(Path.join(project.worktree_path, "index.html")) =~ "Milk Dashboard"
    assert File.read!(Path.join(project.worktree_path, "README.md")) =~ "daily protein"

    manifest =
      project.worktree_path
      |> Path.join(".devide/artifact.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["id"] == project.id
    assert manifest["prompt_history"] == ["Show daily protein orders"]

    assert %{"env" => env, "url" => url, "cwd" => cwd} = project.preview_server
    assert cwd == project.worktree_path
    assert url == project.preview_url
    assert String.starts_with?(url, "http://localhost:")
    assert env["DEVIDE_RUNTIME_PREVIEW_COMMAND"] =~ "python3 -m http.server"

    assert [listed] = ArtifactProjects.list("ws-artifacts")
    assert listed.id == project.id
  end

  test "configured artifact root is used and trusted as a runtime worktree root", %{
    artifact_root: artifact_root
  } do
    assert ArtifactProjects.root() == Path.expand(artifact_root)

    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Configured Root",
               files: %{"index.html" => "<h1>Configured</h1>\n"}
             })

    assert String.starts_with?(project.worktree_path, Path.expand(artifact_root) <> "/")
    assert {:ok, runtime} = Runtimes.get_runtime(project.id)
    assert runtime.worktree_path == project.worktree_path
  end

  test "update writes generated files, appends prompt history, and keeps preview metadata" do
    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Landing Page",
               prompt: "Draft a first pass",
               files: %{"index.html" => "<h1>Initial</h1>\n"}
             })

    assert {:ok, updated} =
             ArtifactProjects.update(project.id, %{
               prompt: "Make the hero compact",
               files: %{
                 "index.html" => "<h1>Updated</h1>\n",
                 "assets/app.js" => "console.log('artifact');\n"
               }
             })

    assert File.read!(Path.join(project.worktree_path, "index.html")) == "<h1>Updated</h1>\n"
    assert File.read!(Path.join(project.worktree_path, "assets/app.js")) =~ "artifact"
    assert updated.prompt_history == ["Draft a first pass", "Make the hero compact"]
    assert updated.preview_server["env"]["DEVIDE_RUNTIME_PREVIEW_COMMAND"] =~ "http.server"

    log = git!(project.worktree_path, ["log", "--oneline", "--format=%s"])
    assert log =~ "Update artifact project Landing Page"
    assert log =~ "Create artifact project Landing Page"
  end

  test "get and payload expose MCP-ready artifact metadata" do
    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Payload Contract",
               prompt: "Expose tool response shape"
             })

    assert {:ok, fetched} = ArtifactProjects.get(project.id)

    assert %{
             id: id,
             workspace_id: "ws-artifacts",
             runtime_id: runtime_id,
             name: "Payload Contract",
             kind: "static",
             status: status,
             worktree_path: worktree_path,
             preview_url: preview_url,
             preview_open_arguments: %{
               "workspace_id" => "ws-artifacts",
               "mode" => "app",
               "runtime_id" => runtime_id
             },
             created_at: created_at,
             updated_at: updated_at
           } = ArtifactProjects.payload(fetched)

    assert id == project.id
    assert runtime_id == project.runtime_id
    assert status in ["draft", "provisioned"]
    assert worktree_path == project.worktree_path
    assert preview_url == project.preview_url
    assert is_binary(created_at)
    assert is_binary(updated_at)
  end

  test "snapshot creates an explicit Git version marker on a clean artifact worktree" do
    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Snapshot Contract",
               files: %{"index.html" => "<h1>Snapshot</h1>\n"}
             })

    before_sha = git!(project.worktree_path, ["rev-parse", "HEAD"])

    assert {:ok, %{project_id: project_id, commit_sha: commit_sha}} =
             ArtifactProjects.snapshot(project.id, %{label: "manual checkpoint"})

    assert project_id == project.id
    assert commit_sha != before_sha

    log = git!(project.worktree_path, ["log", "-1", "--format=%s"])
    assert log == "Snapshot artifact project: manual checkpoint"
  end

  test "create rejects paths that escape the artifact worktree", %{artifact_root: artifact_root} do
    assert {:error, :invalid_artifact_path} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Bad Paths",
               files: %{"../escape.html" => "nope"}
             })

    refute File.exists?(Path.join(artifact_root, "artifact-workspace"))
  end

  test "serve is a no-op when the runtime preview launcher is disabled" do
    assert {:ok, project} =
             ArtifactProjects.create("ws-artifacts", %{
               name: "Served Artifact",
               files: %{"index.html" => "<h1>Served</h1>\n"}
             })

    assert {:ok, served} = ArtifactProjects.serve(project.id)
    assert served.id == project.id
    assert served.preview_url == project.preview_url
  end

  test "smoke mix task creates an artifact and prints preview_open arguments" do
    output =
      capture_io(fn ->
        Mix.Tasks.DevIde.Artifact.Smoke.run([
          "ws-artifacts",
          "--name",
          "Task Artifact",
          "--prompt",
          "Task generated"
        ])
      end)

    assert output =~ "Artifact project created"
    assert output =~ "Task Artifact"
    assert output =~ ~s("workspace_id" => "ws-artifacts")
    assert output =~ ~s("mode" => "app")
    assert output =~ ~s("runtime_id" => "art-)

    assert [project] = ArtifactProjects.list("ws-artifacts")
    assert project.name == "Task Artifact"
  end

  test "smoke mix task can print JSON payloads for agent handoff" do
    output =
      capture_io(fn ->
        Mix.Tasks.DevIde.Artifact.Smoke.run([
          "ws-artifacts",
          "--name",
          "JSON Task Artifact",
          "--json"
        ])
      end)

    payload = Jason.decode!(output)

    assert payload["name"] == "JSON Task Artifact"
    assert payload["workspace_id"] == "ws-artifacts"

    assert payload["preview_open_arguments"] == %{
             "workspace_id" => "ws-artifacts",
             "mode" => "app",
             "runtime_id" => payload["runtime_id"]
           }
  end

  defp seed_workspace!(id, path) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: id,
        name: "Artifact Workspace",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "artifact-test", "branch" => "main"}
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

  defp tmp_dir!(name) do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "devide-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  test "public_url prefers the dedicated artifacts origin over the cockpit origin" do
    {:ok, project} = ArtifactProjects.create("ws-artifacts", %{name: "Shareable"})

    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")

    on_exit(fn ->
      Application.delete_env(:dev_ide, :preview_app_url)
      Application.delete_env(:dev_ide, :artifact_public_url)
    end)

    # Falls back to the cockpit origin when no dedicated origin is configured.
    cockpit_url = ArtifactProjects.payload(project).public_url
    assert cockpit_url =~ "devide.example.com"
    assert String.ends_with?(cockpit_url, "/artifact-projects/ws-artifacts/#{project.id}/")

    # The dedicated artifacts origin wins when set.
    Application.put_env(:dev_ide, :artifact_public_url, "https://artifacts.example.com")

    dedicated_url = ArtifactProjects.payload(project).public_url
    assert dedicated_url =~ "artifacts.example.com"
    refute dedicated_url =~ "devide.example.com"
    assert String.ends_with?(dedicated_url, "/artifact-projects/ws-artifacts/#{project.id}/")
  end

  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
