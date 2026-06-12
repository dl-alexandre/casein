defmodule DevIDE.RuntimesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Workspace
  alias DevIDE.Runners
  alias DevIDE.Runtimes
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    MemoryAdapter.clear()
    Runners.clear()
    Runtimes.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_runner = Application.get_env(:dev_ide, :runner_protocol_adapter)
    prev_runtime = Application.get_env(:dev_ide, :runtime_orchestration_adapter)
    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)

    Application.put_env(:dev_ide, :runner_protocol_adapter, DevIDE.Runners.MemoryAdapter)
    Application.put_env(:dev_ide, :runtime_orchestration_adapter, DevIDE.Runtimes.MemoryAdapter)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      Runtimes.clear()
      DevIDE.Audit.MemoryAdapter.clear()

      restore_env(:runner_protocol_adapter, prev_runner)
      restore_env(:runtime_orchestration_adapter, prev_runtime)
      restore_env(:agent_worktree_roots, prev_agent_roots)
    end)

    seed_workspace("ws-runtime")
    :ok
  end

  test "runtime records progress through lifecycle with append-only events" do
    {:ok, runtime} =
      Runtimes.request_runtime("ws-runtime", %{
        "host_id" => "host-a",
        "repo" => "onebackend-v3",
        "branch" => "feature/runtime",
        "isolation_mode" => "worktree",
        "worktree_path" => "/tmp/ws-runtime/.devide/runtimes/manual"
      })

    assert runtime.status == "requested"

    {:ok, provisioned} =
      Runtimes.provision_runtime(runtime.id, %{"tmux_session_id" => "devide_ws-runtime_rt"})

    assert provisioned.status == "provisioned"
    assert provisioned.tmux_session_id == "devide_ws-runtime_rt"

    {:ok, bound} = Runtimes.bind_runtime(runtime.id, %{"assignment_id" => "asgn-1"})
    assert bound.status == "bound"
    assert bound.active_assignments == 1

    {:ok, active} =
      Runtimes.mark_active(runtime.id, %{"assignment_id" => "asgn-1", "runner_id" => "runner-a"})

    assert active.status == "active"
    assert active.runner_id == "runner-a"

    {:ok, idle} = Runtimes.mark_idle(runtime.id, %{"assignment_id" => "asgn-1"})
    assert idle.status == "idle"
    assert idle.active_assignments == 0

    {:ok, expired} = Runtimes.expire_runtime(runtime.id, %{"reason" => "operator_expired"})
    assert expired.status == "expired"
    assert expired.failure_reason == "operator_expired"

    {:ok, cleaned} = Runtimes.cleanup_runtime(runtime.id)
    assert cleaned.status == "cleaned"

    events = Runtimes.events_for(runtime.id)
    assert Enum.map(events, & &1.event) == ~w(
             runtime_requested
             runtime_provisioned
             runtime_bound
             runtime_active
             runtime_idle
             runtime_expired
             runtime_cleaned
           )

    assert {:ok, "cleaned"} = Runtimes.project_lifecycle(events)
  end

  test "placement binds runner assignments without changing safe-action authorization" do
    {:ok, _host} =
      Runtimes.register_host(%{
        "host_id" => "host-a",
        "os" => "darwin",
        "tools" => ["mix", "git"],
        "capabilities" => ["workspace-command:v1"],
        "concurrency_limit" => 1
      })

    {:ok, queued} =
      Runners.enqueue("ws-runtime", "command:test",
        metadata: %{
          "runtime" => %{
            "host" => "host-a",
            "os" => "darwin",
            "repo" => "onebackend-v3",
            "branch" => "feature/runtime",
            "branch_isolation" => "worktree",
            "tools" => ["mix"],
            "capabilities" => ["workspace-command:v1"],
            "concurrency_limit" => 1
          }
        }
      )

    runtime_id = queued.metadata["runtime_id"]
    runtime_path = queued.metadata["runtime_path"]
    assert is_binary(runtime_id)
    assert String.starts_with?(runtime_path, "/tmp/ws-runtime/")
    assert queued.metadata["runtime"]["status"] == "bound"
    assert queued.metadata["routing"]["runtime_id"] == runtime_id

    assert :none =
             Runners.poll(%{
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1", "tool:mix"],
               "workspace_ids" => ["ws-runtime"],
               "host" => "host-b",
               "os" => "darwin",
               "repo" => "onebackend-v3",
               "branch_isolation" => "worktree",
               "runtime_id" => runtime_id,
               "runtime_path" => runtime_path
             })

    assert {:ok, claimed} =
             Runners.poll(%{
               "runner_id" => "runner-a",
               "capabilities" => ["workspace-command:v1", "tool:mix"],
               "workspace_ids" => ["ws-runtime"],
               "host" => "host-a",
               "os" => "darwin",
               "repo" => "onebackend-v3",
               "branch_isolation" => "worktree",
               "runtime_id" => runtime_id,
               "runtime_path" => runtime_path
             })

    assert claimed.id == queued.id
    assert claimed.action.argv == ["mix", "test", "--color"]
    assert claimed.metadata["runtime"]["status"] == "active"

    {:ok, runtime} = Runtimes.get_runtime(runtime_id)
    assert runtime.status == "active"
    assert runtime.runner_id == "runner-a"

    {:ok, completed, _report} =
      Runners.complete(claimed.id, %{
        "claim_token" => claimed.claim_token,
        "evidence" => %{"exit_code" => 0, "output_sha256" => "abc123"}
      })

    assert completed.status == "succeeded"

    {:ok, idle_runtime} = Runtimes.get_runtime(runtime_id)
    assert idle_runtime.status == "idle"
    assert idle_runtime.active_assignments == 0
  end

  test "stale runtime cleanup expires old runtimes and cleans only expired records" do
    now = DateTime.utc_now()
    old = DateTime.add(now, -7_200, :second)

    {:ok, runtime} =
      Runtimes.request_runtime("ws-runtime", %{
        "host_id" => "host-a",
        "created_at" => old,
        "heartbeat_at" => old,
        "worktree_path" => "/tmp/ws-runtime/.devide/runtimes/stale"
      })

    {:ok, _provisioned} = Runtimes.provision_runtime(runtime.id, %{"heartbeat_at" => old})

    assert [%{id: runtime_id, status: "expired"}] =
             Runtimes.expire_stale(now, ttl_seconds: 3_600)

    assert runtime_id == runtime.id

    assert [%{id: ^runtime_id, status: "cleaned"}] = Runtimes.cleanup_expired(now)
  end

  test "assignment placement rejects a host whose runtime capacity is exhausted" do
    {:ok, record} = State.get("ws-runtime")

    {:ok, _host} =
      Runtimes.register_host(%{
        "host_id" => "host-cap",
        "os" => "linux",
        "tools" => ["mix"],
        "capabilities" => ["workspace-command:v1"],
        "concurrency_limit" => 1
      })

    metadata = %{
      "runtime" => %{
        "host" => "host-cap",
        "os" => "linux",
        "tools" => ["mix"],
        "capabilities" => ["workspace-command:v1"],
        "concurrency_limit" => 1
      }
    }

    assert {:ok, placed} = Runtimes.place_assignment(record, metadata)
    assert placed["runtime"]["host"] == "host-cap"
    assert placed["runtime"]["status"] == "bound"
    assert placed["routing"]["runtime_id"] == placed["runtime_id"]

    assert {:error, :runtime_host_unavailable} = Runtimes.place_assignment(record, metadata)
  end

  test "decorate_assignment_metadata refreshes stale runtime projection fields" do
    {:ok, runtime} =
      Runtimes.request_runtime("ws-runtime", %{
        "runtime_id" => "rt-decorate",
        "host_id" => "host-a",
        "tools" => ["mix"],
        "worktree_path" => "/tmp/ws-runtime/.devide/runtimes/rt-decorate"
      })

    {:ok, _provisioned} =
      Runtimes.provision_runtime(runtime.id, %{"tmux_session_id" => "devide_ws_rt_decorate"})

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

  test "runtime CLI lists, shows, expires, and cleans records" do
    {:ok, runtime} =
      Runtimes.request_runtime("ws-runtime", %{
        "runtime_id" => "rt-cli",
        "host_id" => "host-a",
        "worktree_path" => "/tmp/ws-runtime/.devide/runtimes/rt-cli"
      })

    {:ok, _provisioned} = Runtimes.provision_runtime(runtime.id)

    assert {:ok, listing} = DevIDE.CLI.Runtimes.run(["ls", "--workspace", "ws-runtime"])
    assert listing =~ "rt-cli"
    assert listing =~ "ws-runtime"

    assert {:ok, shown} = DevIDE.CLI.Runtimes.run(["show", "rt-cli"])
    assert shown =~ "\"runtime_requested\""
    assert shown =~ "\"runtime_provisioned\""

    assert {:ok, expired} = DevIDE.CLI.Runtimes.run(["expire", "rt-cli"])
    assert expired == "expired\trt-cli\texpired"

    assert {:ok, cleaned} = DevIDE.CLI.Runtimes.run(["cleanup", "rt-cli"])
    assert cleaned == "cleaned\trt-cli\tcleaned"
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

    assert [_one] = Runtimes.list_agent_worktrees("ws-agent-upsert")
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
