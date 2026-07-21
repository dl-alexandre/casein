defmodule DevIDE.Runtimes.WorktreeAlarmTest do
  use DevIDE.TestCase, async: false

  import ExUnit.CaptureLog

  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.WorktreeAlarm
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.DbIsolation
  alias DevIDE.Workspaces.State

  setup do
    Runtimes.clear()
    DevIDE.Audit.MemoryAdapter.clear()

    prev_agent_roots = Application.get_env(:dev_ide, :agent_worktree_roots)

    on_exit(fn ->
      Runtimes.clear()
      restore_env(:agent_worktree_roots, prev_agent_roots)
    end)

    :ok
  end

  test "sweep_now alarms on stale unreported dirty worktrees" do
    root = tmp_repo!("alarm-unreported")
    agent_root = tmp_dir!("alarm-agent-root")
    worktree = Path.join(agent_root, "agent-grok-adhoc-stale")
    git!(root, ["worktree", "add", "-b", "agent/grok/stale", worktree, "main"])

    File.write!(Path.join(worktree, "stale.txt"), "wip\n")
    set_old_mtime!(worktree, hours_ago: 30)

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-alarm", root)

    result = WorktreeAlarm.sweep_now(emit: false, ttl_seconds: 86_400)

    assert result.alarm_count == 1
    assert [%{path: ^worktree, reported: false, dirty: true, reasons: reasons}] = result.alarms
    assert "unreported" in reasons
    assert "dirty" in reasons
  end

  test "sweep_now skips worktrees with exit_status handoff" do
    root = tmp_repo!("alarm-handoff")
    agent_root = tmp_dir!("alarm-handoff-root")
    worktree = Path.join(agent_root, "agent-grok-handoff")
    git!(root, ["worktree", "add", "-b", "agent/grok/handoff", worktree, "main"])
    set_old_mtime!(worktree, hours_ago: 30)

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-handoff", root)

    old = DateTime.add(DateTime.utc_now(), -30 * 3600, :second)

    assert {:ok, _} =
             Runtimes.observe_worktree("ws-handoff", %{
               "worktree_path" => worktree,
               "agent" => "grok",
               "exit_status" => "handoff",
               "handoff" => "PR #42 open; preview pane fix on branch",
               "heartbeat_at" => old
             })

    result = WorktreeAlarm.sweep_now(emit: false, ttl_seconds: 86_400)
    assert result.alarm_count == 0
  end

  test "sweep_now skips worktrees whose tip commit is wip:" do
    root = tmp_repo!("alarm-wip-commit")
    agent_root = tmp_dir!("alarm-wip-root")
    worktree = Path.join(agent_root, "agent-grok-wip")
    git!(root, ["worktree", "add", "-b", "agent/grok/wip", worktree, "main"])

    File.write!(Path.join(worktree, "note.txt"), "pause\n")
    git!(worktree, ["add", "note.txt"])
    git!(worktree, ["commit", "-m", "wip: pause for review"])

    set_old_mtime!(worktree, hours_ago: 30)

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-wip", root)

    result = WorktreeAlarm.sweep_now(emit: false, ttl_seconds: 86_400)
    assert result.alarm_count == 0
  end

  test "sweep_now skips fresh dirty worktrees" do
    root = tmp_repo!("alarm-fresh")
    agent_root = tmp_dir!("alarm-fresh-root")
    worktree = Path.join(agent_root, "agent-grok-fresh")
    git!(root, ["worktree", "add", "-b", "agent/grok/fresh", worktree, "main"])
    File.write!(Path.join(worktree, "fresh.txt"), "now\n")

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace("ws-fresh-#{System.unique_integer([:positive])}", root)

    result = WorktreeAlarm.sweep_now(emit: false, ttl_seconds: 86_400)
    assert result.alarm_count == 0
  end

  test "sweep_now emits audit events for alarms" do
    ws = "ws-audit-#{System.unique_integer([:positive])}"
    root = tmp_repo!("alarm-audit")
    agent_root = tmp_dir!("alarm-audit-root")
    worktree = Path.join(agent_root, "agent-grok-audit")
    git!(root, ["worktree", "add", "-b", "agent/grok/audit", worktree, "main"])
    File.write!(Path.join(worktree, "audit.txt"), "dirty\n")
    set_old_mtime!(worktree, hours_ago: 30)

    Application.put_env(:dev_ide, :agent_worktree_roots, [agent_root])
    seed_workspace(ws, root)

    prev_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: prev_level) end)

    log =
      capture_log(fn ->
        assert %{alarm_count: 1, emitted: 1} =
                 WorktreeAlarm.sweep_now(emit: true, ttl_seconds: 86_400)
      end)

    assert log =~ "[worktree-alarm]"

    assert [_event] =
             DevIDE.Audit.MemoryAdapter.recent_with_action_prefix(
               ws,
               "workspace.agent_worktree_stale",
               5
             )
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alarm",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "dev_ide", "branch" => "main"}
      })

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end

  defp set_old_mtime!(path, hours_ago: hours) do
    {_, 0} =
      System.cmd("touch", ["-d", "#{hours} hours ago", path], stderr_to_stdout: true)
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
    path = Path.join(root, "devide-alarm-#{System.unique_integer([:positive])}-#{name}")
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
