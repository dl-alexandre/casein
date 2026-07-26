defmodule Casein.Terminals.TmuxTopologyTest do
  use Casein.TestCase, async: false

  alias Casein.Terminals.TmuxTopology

  setup do
    prev_tmux_adapter = Application.get_env(:casein, :tmux_adapter)
    prev_fake_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_fake_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)
    prev_fake_alive_sessions = TmuxCtl.Test.FakeState.get(:fake_tmux_alive_sessions)
    prev_refresh_ms = Application.get_env(:casein, :tmux_topology_refresh_ms)

    Application.put_env(:casein, :tmux_adapter, Casein.Test.FakeTmuxAdapter)
    Application.put_env(:casein, :tmux_topology_refresh_ms, 60_000)
    Casein.Audit.MemoryAdapter.clear()

    on_exit(fn ->
      Casein.Audit.MemoryAdapter.clear()
      restore_env(:tmux_adapter, prev_tmux_adapter)
      restore_env(:fake_tmux_windows, prev_fake_windows)
      restore_env(:fake_tmux_panes, prev_fake_panes)
      restore_env(:fake_tmux_alive_sessions, prev_fake_alive_sessions)
      restore_env(:tmux_topology_refresh_ms, prev_refresh_ms)
    end)

    :ok
  end

  test "watcher snapshots and broadcasts versioned topology updates" do
    session = "topology-#{System.unique_integer([:positive])}"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/workspace",
          activity: 10,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        }
      ]
    })

    :ok = TmuxTopology.subscribe(session)

    assert %{
             session: ^session,
             active_window_id: "@1",
             active_pane_id: "%1",
             panes: [%{id: "%1", current_path: "/workspace", activity: 10, bell: false}],
             windows: [%{name: "shell", pane_list: [%{id: "%1"}]}]
           } =
             TmuxTopology.get(session)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "tests",
          active: true,
          panes: 1,
          activity: 1,
          current_command: "mix"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 100,
          height: 32,
          current_command: "mix",
          current_path: "/workspace/apps/casein",
          activity: 20,
          activity_flag: false,
          bell: true,
          unseen_changes: false
        }
      ]
    })

    assert %{windows: [%{name: "tests"}], panes: [%{current_command: "mix"}]} =
             TmuxTopology.refresh_now(session)

    assert_receive {TmuxTopology,
                    {:updated,
                     %{
                       session: ^session,
                       active_window_id: "@1",
                       active_pane_id: "%1",
                       windows: [%{name: "tests"}],
                       panes: [
                         %{current_path: "/workspace/apps/casein", activity: 20, bell: true}
                       ]
                     }}},
                   500
  end

  test "snapshots enrich pane titles into pane and window state" do
    session = "title-topology-#{System.unique_integer([:positive])}"
    ready = <<0x2733::utf8>> <> " Review tier two"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "claude",
          active: true,
          panes: 1,
          activity: 0,
          current_command: "node"
        }
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          role: "agent",
          current_command: "node",
          current_path: "/workspace",
          pane_title: ready
        }
      ]
    })

    assert %{
             panes: [%{pane_state: :ready, task_summary: "Review tier two"}],
             windows: [%{pane_state: :ready, task_summary: "Review tier two"}]
           } = TmuxTopology.snapshot(session)
  end

  test "watcher polling can be configured and stops when the tmux session dies" do
    session = "dead-topology-#{System.unique_integer([:positive])}"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{})

    :ok = TmuxTopology.subscribe(session)

    assert {:ok, pid} =
             TmuxTopology.ensure_started(session,
               refresh_ms: 10,
               enabled: false,
               workspace_id: "ws-topology"
             )

    ref = Process.monitor(pid)

    refute_receive {TmuxTopology, {:session_terminated, %{session: ^session}}}, 50
    refute_receive {:DOWN, ^ref, :process, ^pid, _reason}, 50

    assert :ok = TmuxTopology.configure(session, refresh_ms: 10, enabled: true)

    assert_receive {TmuxTopology,
                    {:session_terminated, %{session: ^session, reason: :session_not_alive}}},
                   500

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

    _ = :sys.get_state(Casein.Audit.MemoryAdapter)
    [event] = Casein.Audit.recent_for("ws-topology", 1)
    assert event.action == "tmux.session_terminated"
    assert event.actor_id == "system"
    assert event.target_type == "tmux_session"
    assert event.target_ref == session
    assert event.metadata.session == session
    assert event.metadata.reason == :session_not_alive
  end

  test "generation is stable across refreshes and changes across watcher restarts" do
    session = "gen-topology-#{System.unique_integer([:positive])}"
    put_fake_window(session, "shell")

    assert {:ok, pid} = TmuxTopology.ensure_started(session, enabled: false)

    t1 = TmuxTopology.get(session)
    assert is_integer(t1.generation)

    put_fake_window(session, "tests")
    t2 = TmuxTopology.refresh_now(session)
    assert t2.generation == t1.generation

    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    await_unregistered(session)

    assert {:ok, pid2} = TmuxTopology.ensure_started(session, enabled: false)
    assert pid2 != pid

    t3 = TmuxTopology.get(session)
    assert is_integer(t3.generation)
    assert t3.generation != t1.generation
  end

  test "switch_subscription moves the caller between session topics without double-delivery" do
    s1 = "switch-a-#{System.unique_integer([:positive])}"
    s2 = "switch-b-#{System.unique_integer([:positive])}"
    put_fake_window(s1, "shell")
    put_fake_window(s2, "shell")

    assert {:ok, %{session: ^s1, generation: g1, topology: %{session: ^s1}}} =
             TmuxTopology.switch_subscription(nil, s1, read: :get, enabled: false)

    assert is_integer(g1)

    # Subscribed to s1: an update there is delivered.
    put_fake_window(s1, "tests")
    _ = TmuxTopology.refresh_now(s1)
    assert_receive {TmuxTopology, {:updated, %{session: ^s1}}}, 500

    assert {:ok, %{session: ^s2, generation: g2, topology: %{session: ^s2}}} =
             TmuxTopology.switch_subscription(s1, s2, enabled: false)

    assert is_integer(g2)

    # After the switch, s1 updates are no longer delivered; s2 updates are.
    put_fake_window(s1, "more")
    _ = TmuxTopology.refresh_now(s1)
    refute_receive {TmuxTopology, {:updated, %{session: ^s1}}}, 100

    put_fake_window(s2, "tests")
    _ = TmuxTopology.refresh_now(s2)
    assert_receive {TmuxTopology, {:updated, %{session: ^s2}}}, 500

    # Re-switching onto the same session must not double-subscribe.
    assert {:ok, _} = TmuxTopology.switch_subscription(s2, s2, enabled: false)

    put_fake_window(s2, "again")
    _ = TmuxTopology.refresh_now(s2)
    assert_receive {TmuxTopology, {:updated, %{session: ^s2}}}, 500
    refute_receive {TmuxTopology, {:updated, %{session: ^s2}}}, 100
  end

  test "watcher stops after the idle grace when nobody watches, survives while watched" do
    session = "idle-topology-#{System.unique_integer([:positive])}"
    put_fake_window(session, "shell")

    # No registered consumer → stops after idle_stop_ms without a
    # session_terminated broadcast (the session is still alive).
    :ok = TmuxTopology.subscribe(session)
    assert {:ok, pid} = TmuxTopology.ensure_started(session, enabled: false, idle_stop_ms: 50)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    refute_receive {TmuxTopology, {:session_terminated, %{session: ^session}}}, 50
    await_unregistered(session)

    # A registered consumer keeps it alive past the grace; consumer death
    # restarts the idle clock and the watcher stops once the grace elapses.
    consumer =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    assert {:ok, pid2} = TmuxTopology.ensure_started(session, enabled: false, idle_stop_ms: 50)
    ref2 = Process.monitor(pid2)
    :ok = GenServer.call(pid2, {:watch, consumer})

    refute_receive {:DOWN, ^ref2, :process, ^pid2, _}, 150

    send(consumer, :release)
    assert_receive {:DOWN, ^ref2, :process, ^pid2, :normal}, 500
  end

  test "session_terminated carries the watcher generation" do
    session = "gen-dead-#{System.unique_integer([:positive])}"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{})
    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{})

    :ok = TmuxTopology.subscribe(session)

    assert {:ok, _pid} = TmuxTopology.ensure_started(session, refresh_ms: 10, enabled: true)

    assert_receive {TmuxTopology,
                    {:session_terminated, %{session: ^session, generation: generation}}},
                   500

    assert is_integer(generation)
  end

  defp put_fake_window(session, name) do
    TmuxCtl.Test.FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{
          id: "@1",
          index: 0,
          name: name,
          active: true,
          panes: 1,
          activity: 0,
          current_command: "bash"
        }
      ])
    end)
  end

  defp await_unregistered(session, attempts \\ 50) do
    Casein.Test.Eventually.await(
      fn ->
        case Registry.lookup(Casein.Terminals.TopologyRegistry, session) do
          [] -> :ok
          _ -> false
        end
      end,
      timeout_ms: attempts * 10,
      interval_ms: 10,
      message: "topology watcher for #{session} never unregistered"
    )
  end

  defp restore_env(:tmux_adapter, nil), do: Application.delete_env(:casein, :tmux_adapter)
  defp restore_env(:tmux_adapter, value), do: Application.put_env(:casein, :tmux_adapter, value)

  defp restore_env(:tmux_topology_refresh_ms, nil),
    do: Application.delete_env(:casein, :tmux_topology_refresh_ms)

  defp restore_env(:tmux_topology_refresh_ms, value),
    do: Application.put_env(:casein, :tmux_topology_refresh_ms, value)

  defp restore_env(key, value), do: TmuxCtl.Test.FakeState.restore(key, value)
end
