defmodule DevIDE.Terminals.TmuxTopologyTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.TmuxTopology

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_windows = Application.get_env(:dev_ide, :fake_tmux_windows)
    prev_fake_panes = Application.get_env(:dev_ide, :fake_tmux_panes)
    prev_fake_alive_sessions = Application.get_env(:dev_ide, :fake_tmux_alive_sessions)
    prev_refresh_ms = Application.get_env(:dev_ide, :tmux_topology_refresh_ms)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :tmux_topology_refresh_ms, 60_000)
    DevIDE.Audit.MemoryAdapter.clear()

    on_exit(fn ->
      DevIDE.Audit.MemoryAdapter.clear()
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

    Application.put_env(:dev_ide, :fake_tmux_windows, %{
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

    Application.put_env(:dev_ide, :fake_tmux_panes, %{
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
          current_path: "/workspace"
        }
      ]
    })

    :ok = TmuxTopology.subscribe(session)

    assert %{
             session: ^session,
             active_window_id: "@1",
             active_pane_id: "%1",
             panes: [%{id: "%1", current_path: "/workspace"}],
             windows: [%{name: "shell", pane_list: [%{id: "%1"}]}]
           } =
             TmuxTopology.get(session)

    Application.put_env(:dev_ide, :fake_tmux_windows, %{
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

    Application.put_env(:dev_ide, :fake_tmux_panes, %{
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
          current_path: "/workspace/apps/dev_ide"
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
                       panes: [%{current_path: "/workspace/apps/dev_ide"}]
                     }}},
                   500
  end

  test "watcher polling can be configured and stops when the tmux session dies" do
    session = "dead-topology-#{System.unique_integer([:positive])}"

    Application.put_env(:dev_ide, :fake_tmux_windows, %{})
    Application.put_env(:dev_ide, :fake_tmux_panes, %{})

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

    _ = :sys.get_state(DevIDE.Audit.MemoryAdapter)
    [event] = DevIDE.Audit.recent_for("ws-topology", 1)
    assert event.action == "tmux.session_terminated"
    assert event.actor_id == "system"
    assert event.target_type == "tmux_session"
    assert event.target_ref == session
    assert event.metadata.session == session
    assert event.metadata.reason == :session_not_alive
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
