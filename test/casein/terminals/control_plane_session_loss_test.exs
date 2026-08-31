defmodule Casein.Terminals.ControlPlaneSessionLossTest do
  @moduledoc """
  OneBackend-v3#20076: a session destroyed by something other than Casein must
  leave a durable record, and a teardown Casein performed itself must not.
  """
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Audit.MemoryAdapter
  alias Casein.Terminals.ControlPlane
  alias TmuxCtl.Test.FakeState

  @session "casein_loss-watch_u-test"
  @other "casein_loss-watch-b_u-test"
  @ops "_ops"
  @action "fleet.sessions_lost"

  setup do
    previous_adapter = Application.get_env(:casein, :tmux_adapter)
    previous_windows = FakeState.get(:fake_tmux_windows)
    previous_panes = FakeState.get(:fake_tmux_panes)
    previous_audit = Application.fetch_env!(:casein, :audit_adapter)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Application.put_env(:casein, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
      MemoryAdapter.clear()
      Application.put_env(:casein, :audit_adapter, previous_audit)

      case previous_adapter do
        nil -> Application.delete_env(:casein, :tmux_adapter)
        value -> Application.put_env(:casein, :tmux_adapter, value)
      end

      FakeState.restore(:fake_tmux_windows, previous_windows)
      FakeState.restore(:fake_tmux_panes, previous_panes)
    end)

    :ok
  end

  test "a session that vanishes with no Casein teardown is announced once, durably" do
    Phoenix.PubSub.subscribe(Casein.PubSub, "ops:health")
    pid = start_plane()

    put_sessions([@session, @other])
    assert {:ok, first} = reconcile(pid)
    assert first.sessions == 2
    assert first.sessions_lost == 0

    # Something outside Casein takes the session away.
    put_sessions([@other])
    assert {:ok, result} = reconcile(pid)

    assert result.sessions == 1
    assert result.sessions_lost == 1
    assert result.sessions_lost_unexplained == 1
    assert result.sessions_lost_expected == 0

    assert [event] = audits()
    assert event.metadata["sessions"] == [@session]
    assert event.metadata["count"] == 1
    assert event.metadata["sessions_remaining"] == 1

    assert_receive {:ops_health, :sessions_lost, :raised, risk}
    assert risk.severity == :alarm
    assert risk.evidence.sessions == [@session]
    assert risk.suggestion =~ "worktrees on disk survive"

    # The next pass has nothing new to say — one event per disappearance.
    assert {:ok, quiet} = reconcile(pid)
    assert quiet.sessions_lost == 0
    assert length(audits()) == 1
  end

  test "a teardown Casein performed itself is counted, never alerted" do
    pid = start_plane()

    put_sessions([@session])
    assert {:ok, _} = reconcile(pid)

    :ok = ControlPlane.expect_removal(@session, pid)
    put_sessions([])
    assert {:ok, result} = reconcile(pid)

    assert result.sessions_lost == 1
    assert result.sessions_lost_expected == 1
    assert result.sessions_lost_unexplained == 0
    assert audits() == []
  end

  test "an expectation is consumed, so a later unexplained loss still alerts" do
    pid = start_plane()

    put_sessions([@session])
    assert {:ok, _} = reconcile(pid)
    :ok = ControlPlane.expect_removal(@session, pid)
    put_sessions([])
    assert {:ok, _} = reconcile(pid)
    assert audits() == []

    # Same name comes back and then dies unexpectedly.
    put_sessions([@session])
    assert {:ok, _} = reconcile(pid)
    put_sessions([])
    assert {:ok, result} = reconcile(pid)

    assert result.sessions_lost_unexplained == 1
    assert [_event] = audits()
  end

  test "a failed tmux probe is never read as session loss" do
    name = :"control-plane-loss-err-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ControlPlane.start_link(
        name: name,
        adapter: Casein.Terminals.ControlPlaneErrorAdapter,
        interval_ms: nil
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, result} = reconcile(pid)
    assert result.sessions_lost == 0
    assert result.sessions_lost_unexplained == 0
    assert result.errors != []
    assert audits() == []
  end

  defp start_plane do
    name = :"control-plane-loss-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ControlPlane.start_link(name: name, adapter: Casein.Test.FakeTmuxAdapter, interval_ms: nil)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp reconcile(pid), do: GenServer.call(pid, {:reconcile, []})

  defp put_sessions(sessions) do
    FakeState.put(
      :fake_tmux_windows,
      Map.new(sessions, fn session ->
        {session, [%{id: "@1", index: 0, name: "worker", active: true, panes: 1}]}
      end)
    )

    FakeState.put(
      :fake_tmux_panes,
      Map.new(sessions, fn session ->
        {session,
         [%{id: "%1", window_id: "@1", index: 0, active: true, current_command: "claude"}]}
      end)
    )
  end

  defp audits do
    _ = :sys.get_state(MemoryAdapter)

    @ops
    |> Audit.recent_for(50)
    |> Enum.filter(&(&1.action == @action))
  end
end
