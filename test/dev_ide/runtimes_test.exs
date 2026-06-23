defmodule DevIDE.RuntimesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Previews.EnvPorts
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.WorktreeReconciler
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  defmodule PreviewRunner do
    @behaviour DevIDE.Runtimes.PreviewLauncher

    @impl true
    def start(spec) do
      send(
        Application.fetch_env!(:dev_ide, :runtime_preview_runner_test_pid),
        {:preview_start, spec}
      )

      :ok
    end
  end

  setup do
    MemoryAdapter.clear()
    Runtimes.clear()
    WorktreeReconciler.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runtime = Application.get_env(:dev_ide, :runtimes_adapter)
    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)
    prev_reconcile_ttl = Application.get_env(:dev_ide, :worktree_reconcile_ttl_ms)
    prev_launcher_enabled = Application.get_env(:dev_ide, :runtime_preview_launcher_enabled)
    prev_runner = Application.get_env(:dev_ide, :runtime_preview_runner)
    prev_runner_pid = Application.get_env(:dev_ide, :runtime_preview_runner_test_pid)

    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      WorktreeReconciler.clear()
      DevIDE.Audit.MemoryAdapter.clear()

      restore_env(:runtimes_adapter, prev_runtime)
      restore_env(:agent_worktree_roots, prev_agent_roots)
      restore_env(:worktree_reconcile_ttl_ms, prev_reconcile_ttl)
      restore_env(:runtime_preview_launcher_enabled, prev_launcher_enabled)
      restore_env(:runtime_preview_runner, prev_runner)
      restore_env(:runtime_preview_runner_test_pid, prev_runner_pid)
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

  test "observe_worktree creates runtime preview server records in the worktree cwd" do
    root = tmp_repo!("preview-server-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = "devide_runtime_wt"

    git!(root, ["worktree", "add", "-b", "agent-preview", worktree, "main"])
    seed_workspace("ws-preview-worktree", root)

    {:ok, base_runtime} =
      RuntimeSeed.seed_runtime("ws-preview-worktree",
        runtime_id: "base-runtime",
        worktree_path: root,
        tmux_session_id: "devide_runtime_base",
        runtime_profile: %{
          "name" => "phoenix",
          "cwd" => root,
          "env" => %{"PORT" => "4000"},
          "ports" => %{"app" => 4000},
          "surfaces" => [%{"name" => "app", "port" => 4000}]
        }
      )

    assert Runtimes.runtime_profile(base_runtime)["cwd"] == root

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-preview-worktree", %{
               "worktree_path" => worktree,
               "agent" => "codex",
               "tmux_session_id" => tmux_session
             })

    {min_port, max_port} = EnvPorts.port_range()
    server = Runtimes.runtime_preview_server(runtime)

    assert server["runtime_id"] == runtime.id
    assert server["workspace_id"] == "ws-preview-worktree"
    assert server["tmux_session_id"] == tmux_session
    assert server["cwd"] == worktree
    assert server["worktree_path"] == worktree
    refute server["cwd"] == root
    assert server["status"] == "provisioned"

    assert ["bash", launcher, "--port", port_arg] = server["command"]
    assert Path.basename(launcher) == "runtime-preview-launch.sh"
    assert port_arg == Integer.to_string(server["port"])

    assert server["port"] in min_port..max_port
    refute server["port"] == 4000
    assert server["env"]["PORT"] == Integer.to_string(server["port"])
    assert server["env"]["DEVIDE_RUNTIME_ID"] == runtime.id
    assert server["env"]["DEVIDE_WORKSPACE_ID"] == "ws-preview-worktree"
    assert server["env"]["DEVIDE_TMUX_SESSION"] == tmux_session
    assert server["env"]["DEVIDE_PREVIEW_HOME"] == Path.join(root, ".devide-preview")

    socket = server["env"]["DEVIDE_RUNTIME_PREVIEW_SOCKET"]
    assert String.starts_with?(socket, Path.join([root, ".devide-preview", "sockets"]))
    assert Path.basename(socket) =~ ~r/^rt-[0-9a-z]+\.sock$/
    assert byte_size(socket) < 100

    profile = Runtimes.runtime_profile(runtime)
    assert profile["cwd"] == worktree
    assert profile["command"] == server["command"]
    assert profile["env"]["PORT"] == Integer.to_string(server["port"])
    assert profile["ports"] == %{"app" => server["port"]}

    assert [
             %{
               "runtime_id" => runtime_id,
               "surface_key" => surface_key,
               "port" => port,
               "url" => url
             }
           ] = Runtimes.runtime_preview_surfaces(runtime)

    assert runtime_id == runtime.id
    assert surface_key == "runtime:#{runtime.id}:app"
    assert port == server["port"]
    assert url == "http://localhost:#{server["port"]}"

    payload = Runtimes.payload(runtime)
    assert payload.preview_server["cwd"] == worktree
    assert [%{"port" => ^port}] = payload.preview_surfaces
  end

  test "observe_worktree starts runtime preview server from the worktree record" do
    root = tmp_repo!("preview-launch-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = "devide_runtime_launch_wt"

    git!(root, ["worktree", "add", "-b", "agent-preview", worktree, "main"])
    seed_workspace("ws-preview-launch", root)

    Application.put_env(:dev_ide, :runtime_preview_launcher_enabled, true)
    Application.put_env(:dev_ide, :runtime_preview_runner, __MODULE__.PreviewRunner)
    Application.put_env(:dev_ide, :runtime_preview_runner_test_pid, self())

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-preview-launch", %{
               "worktree_path" => worktree,
               "agent" => "codex",
               "tmux_session_id" => tmux_session
             })

    server = Runtimes.runtime_preview_server(runtime)

    assert_receive {:preview_start, spec}, 1_000
    assert spec["cwd"] == worktree
    assert spec["runtime_id"] == runtime.id
    assert spec["port"] == server["port"]
    assert spec["env"]["PORT"] == Integer.to_string(server["port"])
    assert spec["env"]["DEVIDE_TMUX_SESSION"] == tmux_session

    assert ["bash", launcher, "--port", port_arg] = spec["command"]
    assert Path.basename(launcher) == "runtime-preview-launch.sh"
    assert port_arg == Integer.to_string(server["port"])

    assert {:ok, launched} = Runtimes.get_runtime(runtime.id)
    assert Runtimes.runtime_preview_server(launched)["status"] == "starting"
  end

  test "observe_worktree reports a safe error status when a configured launcher is missing" do
    root = tmp_repo!("preview-launch-missing-parent")
    worktree = Path.join(root, "agent-worktree")

    git!(root, ["worktree", "add", "-b", "agent-preview", worktree, "main"])
    seed_workspace("ws-preview-launch-missing", root)

    Application.put_env(:dev_ide, :runtime_preview_launcher_enabled, true)
    Application.put_env(:dev_ide, :runtime_preview_runner, __MODULE__.PreviewRunner)
    Application.put_env(:dev_ide, :runtime_preview_runner_test_pid, self())
    previous = System.get_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER")
    System.put_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER", Path.join(worktree, "missing-launcher.sh"))

    on_exit(fn ->
      if previous,
        do: System.put_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER", previous),
        else: System.delete_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER")
    end)

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-preview-launch-missing", %{
               "worktree_path" => worktree,
               "agent" => "codex"
             })

    refute_receive {:preview_start, _spec}, 200

    assert {:ok, reported} = Runtimes.get_runtime(runtime.id)
    server = Runtimes.runtime_preview_server(reported)
    assert server["status"] == "failed"
    assert server["failure_reason"] =~ "runtime_preview_launcher_missing"
  end

  test "observe_worktree replaces legacy worktree-local preview command" do
    root = tmp_repo!("preview-legacy-command-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = "devide_runtime_legacy_wt"

    git!(root, ["worktree", "add", "-b", "agent-preview", worktree, "main"])
    seed_workspace("ws-preview-legacy", root)

    RuntimeSeed.seed_runtime("ws-preview-legacy",
      runtime_id: "wt-legacy-preview",
      status: "provisioned",
      worktree_path: worktree,
      tmux_session_id: tmux_session,
      isolation_mode: "worktree",
      metadata: %{
        "kind" => "agent_worktree",
        "preview_server" => %{
          "command" => ["bash", "scripts/preview-env.sh", "dirty", "--port", "41025"],
          "port" => 41_025,
          "status" => "failed"
        }
      }
    )

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-preview-legacy", %{
               "runtime_id" => "wt-legacy-preview",
               "worktree_path" => worktree,
               "tmux_session_id" => tmux_session
             })

    server = Runtimes.runtime_preview_server(runtime)
    assert ["bash", launcher, "--port", _port] = server["command"]
    assert Path.basename(launcher) == "runtime-preview-launch.sh"
  end

  test "observe_worktree replaces legacy command reported in attrs metadata" do
    root = tmp_repo!("preview-legacy-attrs-parent")
    worktree = Path.join(root, "agent-worktree")
    tmux_session = "devide_runtime_legacy_attrs_wt"

    git!(root, ["worktree", "add", "-b", "agent-preview", worktree, "main"])
    seed_workspace("ws-preview-legacy-attrs", root)

    assert {:ok, runtime} =
             Runtimes.observe_worktree("ws-preview-legacy-attrs", %{
               "runtime_id" => "wt-legacy-attrs-preview",
               "worktree_path" => worktree,
               "tmux_session_id" => tmux_session,
               "metadata" => %{
                 "preview_server" => %{
                   "command" => ["bash", "scripts/preview-env.sh", "dirty", "--port", "41025"],
                   "port" => 41_025,
                   "status" => "failed"
                 }
               }
             })

    server = Runtimes.runtime_preview_server(runtime)
    assert ["bash", launcher, "--port", _port] = server["command"]
    assert Path.basename(launcher) == "runtime-preview-launch.sh"
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

  test "discover_worktrees registers linked worktrees and skips home checkout" do
    root = tmp_repo!("discover")
    worktree = Path.join(root, "agent-discovered")
    git!(root, ["worktree", "add", "-b", "discovered-branch", worktree, "main"])
    seed_workspace("ws-discover", root)

    assert {:ok, %{observed: [runtime], expired: [], rejected: []}} =
             Runtimes.discover_worktrees("ws-discover")

    assert runtime.worktree_path == worktree
    assert runtime.branch == "discovered-branch"
    assert runtime.metadata["source"] == "git_discovery"
    assert runtime.metadata["git_worktree_list"] == true

    assert [%{path: ^worktree, source: "git_discovery"}] =
             Runtimes.list_agent_worktrees("ws-discover")
  end

  test "discover_worktrees ignores non-git home roots" do
    root = tmp_dir!("not-git")
    seed_workspace("ws-not-git", root)

    assert {:ok, %{observed: [], expired: [], rejected: []}} =
             Runtimes.discover_worktrees("ws-not-git")

    assert [] = Runtimes.list_agent_worktrees("ws-not-git")
  end

  test "discover_worktrees expires missing git-discovered worktrees only" do
    root = tmp_repo!("discover-expire")
    discovered = Path.join(root, "discovered")
    agent_reported = Path.join(root, "agent-reported")
    git!(root, ["worktree", "add", "-b", "discovered-expire", discovered, "main"])
    git!(root, ["worktree", "add", "-b", "agent-reported-expire", agent_reported, "main"])
    seed_workspace("ws-discover-expire", root)

    assert {:ok, _} = Runtimes.discover_worktrees("ws-discover-expire")

    assert {:ok, agent_runtime} =
             Runtimes.observe_worktree("ws-discover-expire", %{
               "worktree_path" => agent_reported,
               "source" => "agent_report"
             })

    git!(root, ["worktree", "remove", "--force", discovered])
    git!(root, ["worktree", "remove", "--force", agent_reported])

    assert {:ok, %{expired: [expired]}} = Runtimes.discover_worktrees("ws-discover-expire")

    assert expired.worktree_path == discovered
    assert {:ok, %{status: "provisioned"}} = Runtimes.get_runtime(agent_runtime.id)
  end

  test "worktree reconciler caches discovery until forced" do
    root = tmp_repo!("reconcile-cache")
    first = Path.join(root, "first")
    second = Path.join(root, "second")
    git!(root, ["worktree", "add", "-b", "first-cache", first, "main"])
    seed_workspace("ws-reconcile-cache", root)

    Application.put_env(:dev_ide, :worktree_reconcile_ttl_ms, 60_000)

    assert {:ok, %{observed_count: 1}} = WorktreeReconciler.reconcile("ws-reconcile-cache")
    assert [%{path: ^first}] = WorktreeReconciler.list_agent_worktrees("ws-reconcile-cache")

    git!(root, ["worktree", "add", "-b", "second-cache", second, "main"])

    assert {:ok, %{observed_count: 1}} = WorktreeReconciler.reconcile("ws-reconcile-cache")
    assert [%{path: ^first}] = WorktreeReconciler.list_agent_worktrees("ws-reconcile-cache")

    assert {:ok, %{observed_count: 2}} =
             WorktreeReconciler.reconcile("ws-reconcile-cache", force: true)

    paths =
      "ws-reconcile-cache"
      |> WorktreeReconciler.list_agent_worktrees()
      |> Enum.map(& &1.path)
      |> Enum.sort()

    assert paths == Enum.sort([first, second])
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
