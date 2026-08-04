defmodule Casein.Agents.AgentWriteLockVisibilityTest do
  @moduledoc """
  A managed Grok pane's bwrap sandbox base is chosen once, when its leader
  starts, from the workspace's agent-write unlock — and is then frozen for the
  pane's life, while the MCP grant keeps re-intersecting on every request.

  That asymmetry has repeatedly burned sessions: a pane launched while locked
  reaches a normal-looking prompt but cannot write its worktree, resolve DNS, or
  start the BEAM, and re-granting the unlock afterwards does not free it. The
  launcher already warns at spawn, but that is one stderr line that scrolls away.

  These tests pin the two surfaces that make the condition discoverable *after*
  launch: the orienting `terminal_context` call every agent makes, and the
  workspace status API that `spawn-agent-worker.sh` preflights against.
  """
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Export
  alias Casein.Terminals.Tmux
  alias Casein.Workspace
  alias Casein.Workspaces
  alias Casein.Workspaces.DbIsolation
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @workspace_id "agentwrite"

  setup do
    previous = %{
      tmux_adapter: Application.get_env(:casein, :tmux_adapter),
      fake_tmux_windows: TmuxCtl.Test.FakeState.get(:fake_tmux_windows),
      fake_tmux_panes: TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    }

    MemoryAdapter.clear()
    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)

    session = Tmux.session_name(@workspace_id, "u-dev")

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "main", active: true, panes: 1, activity: 1}]
    })

    root = Casein.TmpWorkspace.root!("agent-write-visibility")
    seed_workspace(@workspace_id, root)

    on_exit(fn ->
      TmuxCtl.Test.FakeState.restore(:fake_tmux_windows, previous.fake_tmux_windows)
      TmuxCtl.Test.FakeState.restore(:fake_tmux_panes, previous.fake_tmux_panes)

      if previous.tmux_adapter,
        do: Application.put_env(:casein, :tmux_adapter, previous.tmux_adapter),
        else: Application.delete_env(:casein, :tmux_adapter)

      MemoryAdapter.clear()
    end)

    {:ok, session: session}
  end

  test "terminal_context reports the lock and says a running pane needs a relaunch" do
    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    refute agent_write.write_enabled
    assert agent_write.unlock_status == "inactive"
    refute Map.has_key?(agent_write, :unlock_until)

    # The things a blocked agent otherwise spends minutes rediscovering: what
    # breaks, that a re-grant alone will not free a running pane, and what to
    # use instead.
    assert agent_write.note =~ "READ-ONLY"
    assert agent_write.note =~ "BEAM cannot start"
    assert agent_write.note =~ "re-granting does not free it"
    assert agent_write.note =~ "re-grant agent write in the workspace UI"
    assert agent_write.note =~ "codex"
  end

  # write_enabled can be false while the unlock is live — the workspace may not
  # be in manual mode, or its DB isolation may be shared_stage/unsafe. Pointing
  # at the unlock there sends the operator down a dead end.
  test "terminal_context does not blame the unlock when workspace policy is the blocker" do
    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")
    assert {:ok, _} = State.set_mode(@workspace_id, :review)

    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    refute agent_write.write_enabled
    assert agent_write.unlock_status == "active"
    assert agent_write.note =~ "The unlock itself is active"
    assert agent_write.note =~ "shared_stage/unsafe"
    refute agent_write.note =~ "An operator must re-grant"
  end

  test "terminal_context reports an active unlock with its deadline and no warning" do
    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    assert agent_write.write_enabled
    assert agent_write.unlock_status == "active"
    assert agent_write.unlock_until == DateTime.to_iso8601(until)
    refute Map.has_key?(agent_write, :note)
  end

  test "terminal_context distinguishes a lapsed unlock from one never granted" do
    until = DateTime.add(DateTime.utc_now(), -5, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    refute agent_write.write_enabled
    assert agent_write.unlock_status == "expired"
  end

  test "terminal_context omits agent_write when the call is not workspace-scoped" do
    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{"session" => session_name()})

    refute Map.has_key?(payload, :agent_write)
  end

  # This is what scripts/spawn-agent-worker.sh preflights, so a locked workspace
  # refuses to open a worker window instead of spawning a dead pane.
  test "workspace status API publishes the same write state the sandbox is chosen from" do
    assert {:ok, %{agent_write: locked}} = Export.status(@workspace_id)
    refute locked.write_enabled
    assert locked.unlock_status == "inactive"

    until = DateTime.add(DateTime.utc_now(), 300, :second)
    assert {:ok, _} = Workspaces.grant_agent_write_unlock(@workspace_id, until, "operator")

    assert {:ok, %{agent_write: unlocked}} = Export.status(@workspace_id)
    assert unlocked.write_enabled
    assert unlocked.unlock_status == "active"
    assert unlocked.unlock_until == DateTime.to_iso8601(until)
  end

  defp session_name, do: Tmux.session_name(@workspace_id, "u-dev")

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: id,
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id, "repo" => "casein", "branch" => "main"}
      })

    {:ok, _} = State.set_mode(id, :manual)

    {:ok, _} =
      State.persist_isolation(id, %DbIsolation{
        isolation: :local,
        source: :env_file,
        summary: "local",
        detected_at: DateTime.utc_now()
      })
  end
end
