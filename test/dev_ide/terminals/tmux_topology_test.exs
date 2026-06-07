defmodule DevIDE.Terminals.TmuxTopologyTest do
  use ExUnit.Case, async: false

  alias DevIDE.Terminals.TmuxTopology

  setup do
    prev_tmux_adapter = Application.get_env(:dev_ide, :tmux_adapter)
    prev_fake_windows = Application.get_env(:dev_ide, :fake_tmux_windows)
    prev_fake_panes = Application.get_env(:dev_ide, :fake_tmux_panes)
    prev_refresh_ms = Application.get_env(:dev_ide, :tmux_topology_refresh_ms)

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :tmux_topology_refresh_ms, 60_000)

    on_exit(fn ->
      restore_env(:tmux_adapter, prev_tmux_adapter)
      restore_env(:fake_tmux_windows, prev_fake_windows)
      restore_env(:fake_tmux_panes, prev_fake_panes)
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

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
