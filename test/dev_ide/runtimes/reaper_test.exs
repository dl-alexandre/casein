defmodule DevIDE.Runtimes.ReaperTest do
  use DevIDE.DataCase, async: false

  import ExUnit.CaptureLog

  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.Reaper
  alias DevIDE.Supervision.PlatformServices
  alias DevIDE.Test.RuntimeSeed
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State

  setup do
    _ = Reaper
    Runtimes.clear()
    on_exit(fn -> Runtimes.clear() end)
    :ok
  end

  test "scheduled :sweep is the PlatformServices-supervised production janitor path" do
    assert DevIDE.Runtimes.Reaper in PlatformServices.child_specs()

    reaper_pid = Process.whereis(DevIDE.Runtimes.Reaper)
    assert is_pid(reaper_pid)

    prev_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    log =
      capture_log(fn ->
        send(reaper_pid, :sweep)
        assert :sys.get_state(reaper_pid)
      end)

    IO.puts(log)

    assert log =~ "[runtime-reaper] scheduled sweep (PlatformServices-supervised janitor"
    assert log =~ "production caller for expire_stale/2 and cleanup_expired/2)"
    assert log =~ "[runtime-reaper] invoking Runtimes.expire_stale/2"
    assert log =~ "[runtime-reaper] dry-run: skipping Runtimes.cleanup_expired/2"
  end

  test "sweep_now dry-run logs would-reap lines without deleting" do
    now = ~U[2026-06-24 00:00:00Z]
    old = DateTime.add(now, -7200, :second)

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-reaper",
        runtime_id: "rt-reaper-dry-log",
        status: "provisioned",
        worktree_path: "/tmp/devide-reaper-dry-log",
        created_at: old,
        heartbeat_at: old,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "clean",
          "worktree_path" => "/tmp/devide-reaper-dry-log"
        }
      )

    prev_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    log =
      capture_log(fn ->
        result = Reaper.sweep_now(dry_run: true, ttl_seconds: 3600)

        assert result.dry_run
        assert result.reaped == 0
        assert result.cleaned_ids == []

        assert [%{runtime_id: "rt-reaper-dry-log", reason: :dry_run}] = result.skipped

        assert {:ok, expired} = Runtimes.get_runtime("rt-reaper-dry-log")
        assert expired.status == "expired"
        refute expired.status == "cleaned"
      end)

    IO.puts(log)

    assert log =~
             "[runtime-reaper] invoking Runtimes.expire_stale/2 ttl_seconds=3600 dry_run=true"

    assert log =~
             "[runtime-reaper] dry-run: would reap runtime rt-reaper-dry-log worktree=/tmp/devide-reaper-dry-log"

    assert log =~ "[runtime-reaper] dry-run: skipping Runtimes.cleanup_expired/2"
  end

  test "sweep_now dry-run expires stale runtimes but does not clean them" do
    now = ~U[2026-06-24 00:00:00Z]
    old = DateTime.add(now, -7200, :second)

    {:ok, runtime} =
      RuntimeSeed.seed_runtime("ws-reaper",
        runtime_id: "rt-reaper-dry",
        status: "provisioned",
        created_at: old,
        heartbeat_at: old,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "clean",
          "worktree_path" => "/tmp/devide-reaper-clean"
        }
      )

    result = Reaper.sweep_now(dry_run: true, ttl_seconds: 3600)

    assert result.expired == 1
    assert result.reaped == 0
    assert result.cleaned_ids == []
    assert result.dry_run

    assert [%{runtime_id: "rt-reaper-dry", reason: :dry_run}] = result.skipped

    assert {:ok, expired} = Runtimes.get_runtime(runtime.id)
    assert expired.status == "expired"
  end

  test "sweep_now skips dirty worktrees even when not dry-run" do
    now = ~U[2026-06-24 00:00:00Z]

    {:ok, _runtime} =
      RuntimeSeed.seed_runtime("ws-reaper",
        runtime_id: "rt-reaper-dirty",
        status: "expired",
        created_at: now,
        heartbeat_at: now,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "dirty",
          "worktree_path" => "/tmp/devide-reaper-dirty"
        }
      )

    result = Reaper.sweep_now(dry_run: false)

    refute "rt-reaper-dirty" in result.cleaned_ids

    assert {:ok, still_expired} = Runtimes.get_runtime("rt-reaper-dirty")
    assert still_expired.status == "expired"
  end

  test "sweep_now reaps clean expired worktrees and invokes cleanup_expired/2" do
    root = tmp_repo!("reaper-destructive")
    worktree = Path.join(root, "agent-wt")
    git!(root, ["worktree", "add", "-b", "agent-reap", worktree, "main"])
    seed_workspace!("ws-reaper-destructive", root)

    port = free_port()

    preview_server = %{
      "id" => "preview:rt-reaper-live:app",
      "runtime_id" => "rt-reaper-live",
      "workspace_id" => "ws-reaper-destructive",
      "cwd" => worktree,
      "port" => port,
      "status" => "running",
      "command" => ["bash", "priv/scripts/runtime-preview-launch.sh"],
      "env" => %{"PORT" => Integer.to_string(port)},
      "source" => "runtime_preview_server"
    }

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-reaper-destructive",
        runtime_id: "rt-reaper-live",
        status: "expired",
        worktree_path: worktree,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "clean",
          "worktree_path" => worktree,
          "preview_server" => preview_server
        }
      )

    assert File.dir?(worktree)

    prev_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    log =
      capture_log(fn ->
        result = Reaper.sweep_now(dry_run: false)

        assert result.reaped == 1
        assert result.cleaned_ids == ["rt-reaper-live"]
        refute File.exists?(worktree)

        assert {:ok, cleaned} = Runtimes.get_runtime("rt-reaper-live")
        assert cleaned.status == "cleaned"
      end)

    IO.puts(log)

    assert log =~ "[runtime-reaper] invoking Runtimes.expire_stale/2"

    assert log =~
             "[runtime-reaper] invoking Runtimes.cleanup_expired/2 only_ids=[\"rt-reaper-live\"]"
  end

  test "teardown waits for preview-port allocation lock before removing a worktree" do
    root = tmp_repo!("reaper-port-lock")
    worktree = Path.join(root, "agent-port-lock-wt")
    git!(root, ["worktree", "add", "-b", "agent-port-lock", worktree, "main"])
    seed_workspace!("ws-reaper-port-lock", root)

    {:ok, _runtime} =
      RuntimeSeed.seed_runtime("ws-reaper-port-lock",
        runtime_id: "rt-reaper-port-lock",
        status: "expired",
        worktree_path: worktree,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "clean",
          "worktree_path" => worktree
        }
      )

    parent = self()

    lock_holder =
      Task.async(fn ->
        Runtimes.with_preview_port_lock(fn ->
          send(parent, :reaper_preview_lock_held)

          receive do
            :release_reaper_preview_lock -> :ok
          after
            2_000 -> raise "preview lock was not released by the test"
          end
        end)
      end)

    assert_receive :reaper_preview_lock_held
    sweep = Task.async(fn -> Reaper.sweep_now(dry_run: false) end)

    assert Task.yield(sweep, 100) == nil
    assert File.dir?(worktree)

    send(lock_holder.pid, :release_reaper_preview_lock)
    assert :ok = Task.await(lock_holder)
    assert %{cleaned_ids: ["rt-reaper-port-lock"]} = Task.await(sweep, 5_000)
    refute File.exists?(worktree)
  end

  test "teardown kills orphaned preview registry pids" do
    root = tmp_repo!("reaper-kill")
    worktree = Path.join(root, "agent-kill-wt")
    git!(root, ["worktree", "add", "-b", "agent-kill", worktree, "main"])
    seed_workspace!("ws-reaper-kill", root)

    port = free_port()
    sleep = System.find_executable("sleep")
    orphan_port = Port.open({:spawn_executable, sleep}, [:binary, args: ["600"]])
    {:os_pid, os_pid} = Port.info(orphan_port, :os_pid)
    orphan_pid = Integer.to_string(os_pid)
    assert os_pid_alive?(orphan_pid)

    registry_dir = Path.join([worktree, ".devide-preview", "instances"])
    File.mkdir_p!(registry_dir)

    registry = Path.join(registry_dir, "rt-reaper-kill.json")

    File.write!(
      registry,
      ~s({"id":"rt-reaper-kill","pid":"#{orphan_pid}","proxy_pid":"","port":"#{port}","socket":"","status":"running"})
    )

    preview_server = %{
      "id" => "preview:rt-reaper-kill:app",
      "runtime_id" => "rt-reaper-kill",
      "workspace_id" => "ws-reaper-kill",
      "cwd" => worktree,
      "port" => port,
      "status" => "running",
      "source" => "runtime_preview_server"
    }

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-reaper-kill",
        runtime_id: "rt-reaper-kill",
        status: "expired",
        worktree_path: worktree,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_status" => "clean",
          "worktree_path" => worktree,
          "preview_server" => preview_server
        }
      )

    on_exit(fn ->
      if os_pid_alive?(orphan_pid), do: System.cmd("kill", ["-KILL", orphan_pid])
      if Port.info(orphan_port), do: Port.close(orphan_port)
    end)

    result = Reaper.sweep_now(dry_run: false)

    assert result.reaped == 1
    assert "rt-reaper-kill" in result.cleaned_ids
    assert wait_until_dead(orphan_pid)
    refute File.exists?(registry)
  end

  test "cleanup_expired/2 only_ids limits which expired runtimes are cleaned" do
    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-reaper",
        runtime_id: "rt-only-a",
        status: "expired"
      )

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-reaper",
        runtime_id: "rt-only-b",
        status: "expired"
      )

    cleaned = Runtimes.cleanup_expired(~U[2026-06-24 00:00:00Z], only_ids: ["rt-only-a"])
    assert Enum.map(cleaned, & &1.id) == ["rt-only-a"]

    assert {:ok, %{status: "cleaned"}} = Runtimes.get_runtime("rt-only-a")
    assert {:ok, %{status: "expired"}} = Runtimes.get_runtime("rt-only-b")
  end

  defp seed_workspace!(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "reaper",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "test", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

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
    path = Path.join(root, "devide-reaper-#{System.unique_integer([:positive])}-#{name}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp os_pid_alive?(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {n, _} -> os_pid_alive?(n)
      :error -> false
    end
  end

  defp os_pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp wait_until_dead(pid, attempts \\ 20) do
    cond do
      not os_pid_alive?(pid) ->
        true

      attempts <= 0 ->
        false

      true ->
        receive do
        after
          50 -> wait_until_dead(pid, attempts - 1)
        end
    end
  end
end
