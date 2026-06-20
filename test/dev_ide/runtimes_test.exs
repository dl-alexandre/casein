defmodule DevIDE.RuntimesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runtimes
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runtimes.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runtime = Application.get_env(:dev_ide, :runtimes_adapter)
    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)

    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      DevIDE.Audit.MemoryAdapter.clear()

      restore_env(:runtimes_adapter, prev_runtime)
      restore_env(:agent_worktree_roots, prev_agent_roots)
    end)

    seed_workspace("ws-runtime")
    :ok
  end

  test "seeded runtime records persist with append-only lifecycle events" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        host_id: "host-a",
        repo: "onebackend-v3",
        branch: "feature/runtime",
        status: "provisioned",
        tmux_session_id: "devide_ws-runtime_rt",
        worktree_path: "/tmp/ws-runtime/.devide/runtimes/manual"
      )

    assert runtime.status == "provisioned"
    assert runtime.tmux_session_id == "devide_ws-runtime_rt"
    assert Runtimes.get_runtime(runtime.id) == {:ok, runtime}

    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ~w(runtime_requested)
    assert {:ok, "requested"} = Runtimes.project_lifecycle(events)
  end

  test "runtime profiles are persisted and exposed as runtime-scoped preview surfaces" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-preview",
        host_id: "host-a",
        status: "provisioned",
        worktree_path: "/tmp/ws-runtime/.devide/runtimes/rt-preview",
        runtime_profile: %{
          "name" => "phoenix",
          "env" => %{"PORT" => "4101"},
          "ports" => %{"app" => 4101},
          "surfaces" => [%{"name" => "app", "port" => 4101}]
        }
      )

    assert runtime.metadata["runtime_profile"]["name"] == "phoenix"
    assert runtime.metadata["runtime_profile"]["ports"] == %{"app" => 4101}

    assert [
             %{
               "name" => "app",
               "url" => "http://localhost:4101",
               "runtime_id" => "rt-preview",
               "surface_key" => "runtime:rt-preview:app"
             }
           ] = Runtimes.runtime_preview_surfaces(runtime)

    payload = Runtimes.payload(runtime)
    assert payload.runtime_profile["name"] == "phoenix"
    assert [%{"surface_key" => "runtime:rt-preview:app"}] = payload.preview_surfaces
  end

  test "decorate_assignment_metadata refreshes stale runtime projection fields" do
    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-runtime",
        runtime_id: "rt-decorate",
        host_id: "host-a",
        status: "provisioned",
        tools: ["mix"],
        tmux_session_id: "devide_ws_rt_decorate",
        worktree_path: "/tmp/ws-runtime/.devide/runtimes/rt-decorate"
      )

    decorated =
      Runtimes.decorate_assignment_metadata(%{
        "runtime_id" => runtime.id,
        "runtime" => %{"status" => "requested"}
      })

    assert decorated["runtime"]["status"] == "provisioned"
    assert decorated["runtime"]["tmux_session_id"] == "devide_ws_rt_decorate"
    assert decorated["routing"]["runtime_id"] == runtime.id
    assert decorated["routing"]["tools"] == ["mix"]
  end

  test "observe_worktree rejects reporting the main checkout as a worktree" do
    root = tmp_repo!("observe-under-root")
    seed_workspace("ws-agent-root", root)

    assert {:error, %{error: :main_checkout_not_allowed}} =
             Runtimes.observe_worktree("ws-agent-root", %{
               "worktree_path" => root,
               "agent" => "opencode",
               "runner_id" => "runner-a"
             })
  end

  test "observe_worktree accepts an external agent worktree related by git common dir" do
    root = tmp_repo!("observe-parent")
    agent_root = tmp_dir!("observe-agent-root")
    worktree = Path.join(agent_root, "opencode/feature-worktree")
    File.mkdir_p!(Path.dirname(worktree))
    git!(root, ["worktree", "add", "-b", "agent-feature", worktree, "main"])

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-agent-external", root)

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-agent-external", %{
               "worktree_path" => worktree,
               "agent" => "opencode"
             })

    assert runtime.branch == "agent-feature"
    assert runtime.metadata["git_worktree"] == true
    assert runtime.metadata["git_common_dir"] == Path.join(root, ".git")
  end

  test "observe_worktree rejects unrelated external worktrees" do
    root = tmp_repo!("observe-parent-unrelated")
    agent_root = tmp_dir!("observe-agent-unrelated")
    unrelated = Path.join(agent_root, "other")
    File.mkdir_p!(unrelated)
    init_repo!(unrelated)

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-agent-unrelated", root)

    assert {:error, :unrelated_worktree} =
             Runtimes.observe_worktree("ws-agent-unrelated", %{"worktree_path" => unrelated})
  end

  test "observe_worktree upserts by workspace and dedicated git worktree path" do
    root = tmp_repo!("observe-upsert")
    worktree = Path.join(root, "agent-worktree")
    git!(root, ["worktree", "add", "-b", "agent-branch", worktree, "main"])
    seed_workspace("ws-agent-upsert", root)

    assert {:ok, first} =
             Runtimes.observe_worktree("ws-agent-upsert", %{
               "worktree_path" => worktree,
               "agent" => "opencode"
             })

    assert {:ok, second} =
             Runtimes.observe_worktree("ws-agent-upsert", %{
               "worktree_path" => worktree,
               "agent" => "codex"
             })

    assert second.id == first.id
    assert second.metadata["agent"] == "codex"

    assert [_one] = Runtimes.list_runtimes(%{"workspace_id" => "ws-agent-upsert"})
  end

  defp seed_workspace(id, path \\ nil) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "runtime",
        user: "alice",
        branch: "main",
        status: :running,
        path: path || "/tmp/#{id}",
        metadata: %{"id" => id, "repo" => "onebackend-v3", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp tmp_repo!(name) do
    path = tmp_dir!(name)
    init_repo!(path)
    path
  end

  defp init_repo!(path) do
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
    path = Path.join(root, "devide-runtimes-#{System.unique_integer([:positive])}-#{name}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end
end
