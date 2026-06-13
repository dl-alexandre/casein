defmodule TmuxCtl.TopologyTest do
  use ExUnit.Case, async: true

  alias TmuxCtl.Topology

  setup do
    prev_windows = TmuxCtl.Test.FakeState.get(:fake_tmux_windows)
    prev_panes = TmuxCtl.Test.FakeState.get(:fake_tmux_panes)

    on_exit(fn ->
      restore_env(:fake_tmux_windows, prev_windows)
      restore_env(:fake_tmux_panes, prev_panes)
    end)

    :ok
  end

  test "snapshot attaches pane_list to windows and computes active ids" do
    session = "topology-pure-#{System.unique_integer([:positive])}"

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

    assert %{
             session: ^session,
             active_window_id: "@1",
             active_pane_id: "%1",
             windows: [%{pane_list: [%{id: "%1"}]}],
             panes: [%{current_path: "/workspace"}]
           } = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)
  end

  test "snapshot prefers the active pane in the active window" do
    session = "topology-multi-#{System.unique_integer([:positive])}"

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{id: "@1", index: 0, name: "old", active: false, panes: 1, activity: 0},
        %{id: "@2", index: 1, name: "focus", active: true, panes: 1, activity: 0}
      ]
    })

    TmuxCtl.Test.FakeState.put(:fake_tmux_panes, %{
      session => [
        %{id: "%1", window_id: "@1", index: 0, active: true},
        %{id: "%2", window_id: "@2", index: 0, active: true}
      ]
    })

    assert %{active_window_id: "@2", active_pane_id: "%2"} =
             Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)
  end

  test "structure_version ignores activity and geometry churn" do
    windows = [
      %{id: "@1", index: 0, name: "shell", active: true, panes: 1}
    ]

    panes_a = [
      %{
        id: "%1",
        window_id: "@1",
        index: 0,
        active: true,
        activity: 1,
        width: 80,
        height: 24
      }
    ]

    panes_b = [
      %{
        id: "%1",
        window_id: "@1",
        index: 0,
        active: true,
        activity: 99,
        width: 120,
        height: 40
      }
    ]

    assert Topology.structure_version(windows, panes_a) ==
             Topology.structure_version(windows, panes_b)
  end

  test "structure_version changes when active selection changes" do
    windows = [
      %{id: "@1", index: 0, name: "shell", active: true, panes: 1},
      %{id: "@2", index: 1, name: "tests", active: false, panes: 1}
    ]

    panes = [%{id: "%1", window_id: "@1", index: 0, active: true}]

    shifted_windows = [
      %{id: "@1", index: 0, name: "shell", active: false, panes: 1},
      %{id: "@2", index: 1, name: "tests", active: true, panes: 1}
    ]

    refute Topology.structure_version(windows, panes) ==
             Topology.structure_version(shifted_windows, panes)
  end

  test "read_topology uses session_topology when exported" do
    assert {[window], [pane]} =
             Topology.read_topology(TmuxCtl.TopologyTest.FakeMergedTopology, "session")

    assert window.id == "@1"
    assert pane.id == "%1"
  end

  defp restore_env(key, value), do: TmuxCtl.Test.FakeState.restore(key, value)

  defmodule FakeMergedTopology do
    @moduledoc false

    @window %{id: "@1", index: 0, name: "shell", active: true, panes: 1}
    @pane %{id: "%1", window_id: "@1", index: 0, active: true}

    def session_topology(_session), do: {[@window], [@pane]}

    def list_session_windows(_session),
      do: raise("should not list windows separately")

    def list_session_panes(_session),
      do: raise("should not list panes separately")
  end
end
