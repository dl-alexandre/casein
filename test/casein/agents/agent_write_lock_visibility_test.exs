defmodule Casein.Agents.AgentWriteLockVisibilityTest do
  @moduledoc """
  Workspace DB isolation gates the managed Grok *MCP grant*
  (`terminal_send_*`), frozen at leader start. The bwrap base is always strict
  (#605). Surfaces that report the gate must stay accurate.

  These tests pin `terminal_context` and the workspace status API that
  spawn/launch preflight against.
  """
  use Casein.TestCase, async: false

  alias Casein.Agents.TerminalTools
  alias Casein.Export
  alias Casein.Terminals.Tmux
  alias Casein.Workspace
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

  test "terminal_context reports isolation lock and tells orchestrators to fail fast" do
    persist_isolation(:unknown)

    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    refute agent_write.write_enabled
    refute agent_write.orchestrator_ready
    refute Map.has_key?(agent_write, :unlock_status)
    refute Map.has_key?(agent_write, :unlock_until)

    assert agent_write.fail_fast =~ "blocked: workspace isolation"
    assert agent_write.note =~ "strict sandbox"
    assert agent_write.note =~ "terminal_send_command"
    assert agent_write.note =~ "ORCHESTRATOR FAIL-FAST"
    assert agent_write.note =~ "shared_stage, unsafe, or unknown"
    refute agent_write.note =~ "agent-write unlock"
    refute agent_write.note =~ "Unlock 30 min"
    refute agent_write.note =~ "READ-ONLY sandbox"
  end

  test "terminal_context reports write enabled for known-isolated workspaces" do
    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    assert agent_write.write_enabled
    assert agent_write.orchestrator_ready
    refute Map.has_key?(agent_write, :note)
    refute Map.has_key?(agent_write, :fail_fast)
    refute Map.has_key?(agent_write, :unlock_status)
  end

  test "terminal_context names isolation as the blocker for shared_stage" do
    persist_isolation(:shared_stage)

    assert {:ok, %{agent_write: agent_write}} =
             TerminalTools.invoke("terminal_context", %{"workspace_id" => @workspace_id})

    refute agent_write.write_enabled
    assert agent_write.note =~ "shared_stage, unsafe, or unknown"
    refute agent_write.note =~ "Unlock 30 min"
  end

  test "terminal_context omits agent_write when the call is not workspace-scoped" do
    assert {:ok, payload} =
             TerminalTools.invoke("terminal_context", %{"session" => session_name()})

    refute Map.has_key?(payload, :agent_write)
  end

  test "workspace status API publishes the same write state the MCP grant is chosen from" do
    persist_isolation(:unknown)

    assert {:ok, %{agent_write: locked}} = Export.status(@workspace_id)
    refute locked.write_enabled
    refute Map.has_key?(locked, :unlock_status)

    persist_isolation(:local)

    assert {:ok, %{agent_write: enabled}} = Export.status(@workspace_id)
    assert enabled.write_enabled
    refute Map.has_key?(enabled, :unlock_status)
    refute Map.has_key?(enabled, :unlock_until)
  end

  defp session_name, do: Tmux.session_name(@workspace_id, "u-dev")

  defp persist_isolation(isolation) do
    assert {:ok, _} =
             State.persist_isolation(@workspace_id, %DbIsolation{
               isolation: isolation,
               source: :env_file,
               summary: Atom.to_string(isolation),
               detected_at: DateTime.utc_now()
             })
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
