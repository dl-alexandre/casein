defmodule Casein.Terminals.ControlPlaneErrorAdapter do
  @moduledoc false

  def list_sessions_result, do: {:error, :tmux_unavailable}
  def list_session_panes_result(_session), do: {:error, :tmux_unavailable}
end

defmodule Casein.Terminals.ControlPlaneTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.ControlPlane
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.WorkHandles
  alias TmuxCtl.Test.FakeState

  @session "casein_control_plane_u-test"
  @workspace "control-plane-workspace"

  setup do
    previous_adapter = Application.get_env(:casein, :tmux_adapter)
    previous_windows = FakeState.get(:fake_tmux_windows)
    previous_panes = FakeState.get(:fake_tmux_panes)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Casein.Terminals.AgentState.clear()
    IssueBinding.clear_all()
    WorkHandles.clear_all()

    on_exit(fn ->
      restore(:tmux_adapter, previous_adapter)
      FakeState.restore(:fake_tmux_windows, previous_windows)
      FakeState.restore(:fake_tmux_panes, previous_panes)
      Casein.Terminals.AgentState.clear()
      IssueBinding.clear_all()
      WorkHandles.clear_all()
    end)

    :ok
  end

  test "reconciles live panes and prunes stale pane state" do
    FakeState.put(:fake_tmux_windows, %{
      @session => [%{id: "@1", index: 0, name: "worker", active: true, panes: 1}]
    })

    FakeState.put(:fake_tmux_panes, %{
      @session => [
        %{id: "%2", window_id: "@1", index: 0, active: true, current_command: "opencode"}
      ]
    })

    assert {:ok, _binding} = IssueBinding.bind(@workspace, @session, "%1", 731)

    {:ok, handle} =
      WorkHandles.create(@workspace, session: @session, pane_id: "%1", status: "working")

    :ok = Casein.Terminals.AgentState.report(@workspace, @session, "%1", :working, "old")

    name = String.to_atom("control-plane-test-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      ControlPlane.start_link(name: name, adapter: Casein.Test.FakeTmuxAdapter, interval_ms: nil)

    assert {:ok, result} = GenServer.call(pid, {:reconcile, []})
    assert result.sessions == 1
    assert result.reconciled == 1
    assert result.panes_observed == 1

    # Store casts are asynchronous; the synchronous reads below flush them.
    assert IssueBinding.for_session(@session) == %{}
    assert Casein.Terminals.AgentState.for_session(@session) == %{}
    assert {:ok, resolved} = WorkHandles.get(handle.handle_id)
    assert resolved.pane == nil

    GenServer.stop(pid)
  end

  test "session termination cleanup uses the same boundary" do
    assert {:ok, _binding} = IssueBinding.bind(@workspace, @session, "%1", 732)

    {:ok, handle} =
      WorkHandles.create(@workspace, session: @session, pane_id: "%1", status: "working")

    assert :ok = ControlPlane.reconcile_session(@session, [])
    assert IssueBinding.for_session(@session) == %{}
    assert {:ok, resolved} = WorkHandles.get(handle.handle_id)
    assert resolved.pane == nil
  end

  test "a failed tmux inventory preserves state and reports degraded" do
    assert {:ok, _binding} = IssueBinding.bind(@workspace, @session, "%1", 733)

    name = String.to_atom("control-plane-error-test-#{System.unique_integer([:positive])}")

    {:ok, pid} =
      ControlPlane.start_link(
        name: name,
        adapter: Casein.Terminals.ControlPlaneErrorAdapter,
        interval_ms: nil
      )

    assert {:ok, result} = GenServer.call(pid, {:reconcile, []})
    assert [%{reason: ":tmux_unavailable"}] = result.errors
    assert IssueBinding.for_session(@session) != %{}
    assert %{state: "degraded"} = GenServer.call(pid, :status)

    GenServer.stop(pid)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
