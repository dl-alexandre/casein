defmodule Casein.Operator.SituationDigestTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Operator.SituationDigest
  alias Casein.Runtimes
  alias Casein.Runtimes.WorktreeReconciler
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.Tmux
  alias Casein.Test.RuntimeSeed
  alias Casein.Workspace
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_runtimes_adapter = Application.get_env(:dev_ide, :runtimes_adapter)
    prev_fake_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_session_meta = TmuxCtl.Test.FakeState.get(:fake_tmux_session_meta)

    MemoryAdapter.clear()
    Runtimes.clear()
    WorktreeReconciler.clear()
    Audit.clear()
    Activity.clear()
    AgentState.clear()

    Application.put_env(:dev_ide, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :runtimes_adapter, Casein.Runtimes.MemoryAdapter)
    TmuxCtl.Test.FakeState.delete(:fake_tmux_windows)
    TmuxCtl.Test.FakeState.delete(:fake_tmux_panes)
    TmuxCtl.Test.FakeState.delete(:fake_tmux_session_meta)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runtimes.clear()
      WorktreeReconciler.clear()
      Audit.clear()
      Activity.clear()
      AgentState.clear()
      restore_app_env(:tmux_adapter, prev_tmux_adapter)
      restore_app_env(:runtimes_adapter, prev_runtimes_adapter)
      restore_fake_state(:fake_tmux_windows, prev_fake_windows)
      restore_fake_state(:fake_tmux_panes, prev_fake_panes)
      restore_fake_state(:fake_tmux_session_meta, prev_fake_session_meta)
    end)

    {:ok, _} =
      State.sync(%Workspace{
        id: "ws-digest",
        name: "digest",
        user: "alice",
        branch: "main",
        status: :running,
        path: nil,
        metadata: %{}
      })

    :ok
  end

  test "build returns an error for a non-binary workspace id" do
    assert {:error, :invalid_workspace_id} = SituationDigest.build(nil)
    assert {:error, :invalid_workspace_id} = SituationDigest.build("")
  end

  test "build composes sessions with enriched panes and detects a blocked agent" do
    session = seed_agent_session()
    :ok = AgentState.report("ws-digest", session, "%1", :blocked, "needs permission")

    assert {:ok, digest} = SituationDigest.build("ws-digest")

    assert digest.workspace_id == "ws-digest"
    assert %DateTime{} = digest.generated_at
    assert digest.freshness.sessions == 0

    assert [session_digest] = digest.sessions
    assert session_digest.tmux_session == session
    assert session_digest.agent_status == "attention"

    assert [pane] = session_digest.panes
    assert pane.id == "%1"
    assert pane.window_id == "@1"
    assert pane.role == "agent"
    assert pane.agent_state == :blocked
    assert pane.agent_state_message == "needs permission"
    assert is_integer(pane.agent_state_age_s) and pane.agent_state_age_s >= 0
    assert pane.current_command == "claude"
    assert pane.current_path == "/workspace"

    assert Enum.any?(digest.risks, &(&1.id == :agent_blocked and &1.severity == :warn))
  end

  test "build surfaces worktree risk metadata and the dirty_no_handoff risk" do
    observed_at = DateTime.utc_now() |> DateTime.add(-90, :second) |> DateTime.to_iso8601()

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-digest",
        runtime_id: "wt-digest",
        status: "provisioned",
        branch: "agent/claude/topic",
        worktree_path: "/tmp/wt-digest",
        metadata: %{
          "kind" => "agent_worktree",
          "provisioning_model" => "agent_worktree",
          "source" => "agent_report",
          "agent" => "claude",
          "branch" => "agent/claude/topic",
          "worktree_path" => "/tmp/wt-digest",
          "git_head_sha" => "abc1234",
          "upstream" => "origin/agent/claude/topic",
          "ahead" => 2,
          "behind" => 1,
          "dirty_count" => 3,
          "worktree_status" => "dirty",
          "exit_status" => "wip",
          "observed_at" => observed_at
        }
      )

    assert {:ok, digest} = SituationDigest.build("ws-digest")

    assert [worktree] = digest.worktrees
    assert worktree.path == "/tmp/wt-digest"
    assert worktree.branch == "agent/claude/topic"
    assert worktree.head_sha == "abc1234"
    assert worktree.upstream == "origin/agent/claude/topic"
    assert worktree.ahead == 2
    assert worktree.behind == 1
    assert worktree.dirty_count == 3
    assert worktree.status == "dirty"
    assert worktree.exit_status == "wip"
    assert worktree.observed_at == observed_at
    refute Map.has_key?(worktree, :handoff)

    assert is_integer(digest.freshness.worktrees) and digest.freshness.worktrees >= 90_000

    assert [risk] = Enum.filter(digest.risks, &(&1.id == :dirty_no_handoff))
    assert risk.severity == :warn
    assert risk.subject == "/tmp/wt-digest"
    assert risk.detected_at == digest.generated_at
    assert risk.evidence.dirty_count == 3

    # ahead: 2 + a reported exit_status counts as an agent that stopped
    # driving the worktree, so the unpushed commits surface as a risk too.
    assert [unpushed] = Enum.filter(digest.risks, &(&1.id == :unpushed_work))
    assert unpushed.severity == :warn
    assert unpushed.subject == "/tmp/wt-digest"
    assert unpushed.evidence.ahead == 2
  end

  test "build observes freeze sentinels under the workspace and worktree roots" do
    ws_root = tmp_dir!("frozen-ws")
    wt_root = tmp_dir!("frozen-wt")

    File.mkdir_p!(Path.join(ws_root, ".claude"))
    File.write!(Path.join(ws_root, ".claude/.freeze"), "")
    File.mkdir_p!(Path.join(wt_root, ".claude"))
    File.write!(Path.join(wt_root, ".claude/.freeze"), "lib/foo\npriv/repo\n")

    seed_workspace("ws-frozen", ws_root)

    {:ok, _} =
      RuntimeSeed.seed_runtime("ws-frozen",
        runtime_id: "wt-frozen",
        status: "provisioned",
        worktree_path: wt_root,
        metadata: %{
          "kind" => "agent_worktree",
          "worktree_path" => wt_root,
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now())
        }
      )

    assert {:ok, digest} = SituationDigest.build("ws-frozen")

    assert [ws_scope, wt_scope] = digest.frozen_scopes
    assert ws_scope.path == ws_root
    assert ws_scope.sentinel == Path.join(ws_root, ".claude/.freeze")
    # Empty sentinel = "freeze everything": no raw content survives compaction.
    refute Map.has_key?(ws_scope, :raw)

    assert wt_scope.path == wt_root
    assert wt_scope.sentinel == Path.join(wt_root, ".claude/.freeze")
    assert wt_scope.raw == "lib/foo\npriv/repo"

    risks = Enum.filter(digest.risks, &(&1.id == :frozen_scope_active))
    assert Enum.map(risks, & &1.subject) == [ws_root, wt_root]
    assert Enum.all?(risks, &(&1.severity == :info))
  end

  test "build honors configured freeze sentinel globs" do
    prev = Application.get_env(:dev_ide, :freeze_sentinel_globs)
    Application.put_env(:dev_ide, :freeze_sentinel_globs, [".devide/freeze-*"])

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :freeze_sentinel_globs, prev),
        else: Application.delete_env(:dev_ide, :freeze_sentinel_globs)
    end)

    root = tmp_dir!("frozen-globs")
    File.mkdir_p!(Path.join(root, ".devide"))
    File.write!(Path.join(root, ".devide/freeze-review"), "lib/only\n")
    # The default convention is not scanned once globs are configured.
    File.mkdir_p!(Path.join(root, ".claude"))
    File.write!(Path.join(root, ".claude/.freeze"), "")

    seed_workspace("ws-frozen-globs", root)

    assert {:ok, digest} = SituationDigest.build("ws-frozen-globs")

    assert [scope] = digest.frozen_scopes
    assert scope.sentinel == Path.join(root, ".devide/freeze-review")
    assert scope.raw == "lib/only"
  end

  test "build truncates and redacts freeze sentinel content" do
    root = tmp_dir!("frozen-raw")
    File.mkdir_p!(Path.join(root, ".claude"))

    long = String.duplicate("lib/very/long/path\n", 40)

    File.write!(
      Path.join(root, ".claude/.freeze"),
      "DATABASE_URL=postgres://u:p@localhost/db\n" <> long
    )

    seed_workspace("ws-frozen-raw", root)

    assert {:ok, digest} = SituationDigest.build("ws-frozen-raw")

    assert [scope] = digest.frozen_scopes
    assert scope.raw =~ "[REDACTED]"
    refute scope.raw =~ "u:p@localhost"
    assert String.ends_with?(scope.raw, "…")
    assert String.length(scope.raw) <= 420
  end

  test "build includes recent activity, last mutation, and deploy summary" do
    _ =
      Activity.record(%{
        workspace_id: "ws-digest",
        source: :terminal_mcp,
        tool: "terminal_capture",
        summary: "session=devide_digest_agent",
        status: :ok
      })

    Audit.emit!(%{
      workspace_id: "ws-digest",
      actor_id: "mcp",
      action: "agent.terminal_terminal_send_command",
      metadata: %{"tool" => "terminal_send_command"}
    })

    assert {:ok, digest} = SituationDigest.build("ws-digest")

    assert [entry] = digest.activity.recent
    assert entry.tool == "terminal_capture"
    assert entry.status == :ok
    assert %DateTime{} = entry.at

    assert digest.activity.last_mutation.action == "agent.terminal_terminal_send_command"
    assert is_integer(digest.freshness.activity)

    assert Map.has_key?(digest.deploy, :running_revision)
    assert Map.has_key?(digest.deploy, :drift)
    assert Map.has_key?(digest.deploy, :pipeline)
    assert Map.has_key?(digest.deploy, :actionable)
  end

  test "build redacts secret-shaped free text in exported fields" do
    session = seed_agent_session()

    :ok =
      AgentState.report(
        "ws-digest",
        session,
        "%1",
        :blocked,
        "run with DATABASE_URL=postgres://u:p@localhost/db"
      )

    assert {:ok, digest} = SituationDigest.build("ws-digest")

    assert [%{panes: [pane]}] = digest.sessions
    assert pane.agent_state_message =~ "[REDACTED]"
    refute pane.agent_state_message =~ "u:p@localhost"
  end

  test "build degrades to empty sections when the workspace is unknown" do
    assert {:ok, digest} = SituationDigest.build("ws-missing")

    assert digest.workspace_id == "ws-missing"
    assert digest.sessions == []
    assert digest.worktrees == []
    assert digest.frozen_scopes == []
    assert digest.activity.recent == []
    assert digest.activity.last_mutation == nil
    assert is_list(digest.risks)
    # A missing workspace is "actually empty", not "unreadable".
    assert digest.degraded == []
  end

  defmodule RaisingRuntimes do
    # A runtimes read failing hard must degrade the worktrees section (and
    # say so), never crash the digest build.
    def list_runtimes(_filters), do: raise("runtimes read failed")

    # Setup's on_exit cleanup runs while this adapter is still configured.
    def clear, do: :ok
  end

  test "a failing worktree read marks the section degraded instead of silently emptying it" do
    Application.put_env(:dev_ide, :runtimes_adapter, RaisingRuntimes)

    assert {:ok, digest} = SituationDigest.build("ws-digest")
    assert digest.worktrees == []
    assert :worktrees in digest.degraded
  end

  test "a clean build reports no degraded sections" do
    seed_agent_session()

    assert {:ok, digest} = SituationDigest.build("ws-digest")
    assert digest.degraded == []
  end

  defp seed_agent_session do
    session = Tmux.session_name("digest", "agent")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "agent", active: true, panes: 1, activity: 42}]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          current_command: "claude",
          current_path: "/workspace",
          role: "agent"
        }
      ]
    })

    session
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: id,
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{}
      })

    :ok
  end

  defp tmp_dir!(name) do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    path = Path.join(root, "devide-digest-#{System.unique_integer([:positive])}-#{name}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_app_env(key, value), do: Application.put_env(:dev_ide, key, value)

  defp restore_fake_state(key, nil), do: TmuxCtl.Test.FakeState.delete(key)
  defp restore_fake_state(key, value), do: TmuxCtl.Test.FakeState.put(key, value)
end
