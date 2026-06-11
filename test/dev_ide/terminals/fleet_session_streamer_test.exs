defmodule DevIDE.Terminals.FleetSessionStreamerTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.FleetSessionStreamer

  setup do
    Application.put_env(:dev_ide, :fleet_tmux_adapter, DevIDE.Test.FakeTmuxAdapter)

    on_exit(fn ->
      Application.delete_env(:dev_ide, :fleet_tmux_adapter)
      Application.delete_env(:dev_ide, :fake_tmux_alive_sessions)
    end)

    :ok
  end

  defp set_alive(sessions) do
    Application.put_env(:dev_ide, :fake_tmux_alive_sessions, MapSet.new(sessions))
  end

  test "streams capture diffs to subscribers" do
    {:ok, pid} =
      FleetSessionStreamer.start_link(tmux_session: "alive-session", subscriber: self())

    assert_receive {:term_data, "captured pane\n"}, 2_000
    FleetSessionStreamer.stop(pid)
  end

  test "refuses to start when the tmux session is not alive" do
    Process.flag(:trap_exit, true)

    assert {:error, {:tmux_session_not_found, "fleet-missing"}} =
             FleetSessionStreamer.start_link(tmux_session: "fleet-missing", subscriber: self())
  end

  test "signals term_exit and stops when the tmux session disappears" do
    set_alive(["fleet-vanishing"])

    {:ok, pid} =
      FleetSessionStreamer.start_link(tmux_session: "fleet-vanishing", subscriber: self())

    monitor = Process.monitor(pid)

    # Capture always fails for this session; while it is still alive the
    # streamer retries. Once the session vanishes, the next failed poll must
    # broadcast the exit and stop.
    set_alive([])

    assert_receive {:term_exit, :tmux_session_ended}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "gives up with capture_failed after sustained failures on a live session" do
    set_alive(["fleet-wedged"])

    {:ok, pid} =
      FleetSessionStreamer.start_link(tmux_session: "fleet-wedged", subscriber: self())

    monitor = Process.monitor(pid)

    # Accelerate the poll loop rather than waiting ~2s of real scheduling.
    for _ <- 1..10, do: send(pid, :poll)

    assert_receive {:term_exit, :capture_failed}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
  end

  test "stops when the last subscriber goes away" do
    parent = self()

    subscriber =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    {:ok, pid} =
      FleetSessionStreamer.start_link(tmux_session: "alive-session", subscriber: subscriber)

    monitor = Process.monitor(pid)

    # Let the subscribe cast land before killing the subscriber.
    _ = :sys.get_state(pid)
    send(subscriber, :release)

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2_000
    _ = parent
  end

  test "keeps streaming for remaining subscribers when one goes away" do
    other =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    {:ok, pid} =
      FleetSessionStreamer.start_link(tmux_session: "alive-session", subscriber: self())

    FleetSessionStreamer.subscribe(pid, other)
    _ = :sys.get_state(pid)

    send(other, :release)

    # Streamer must survive losing one of two subscribers.
    monitor = Process.monitor(pid)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _}, 500
    assert Process.alive?(pid)

    FleetSessionStreamer.stop(pid)
  end
end
