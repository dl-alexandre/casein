defmodule TmuxCtl.TopologyTest do
  use Casein.TestCase, async: true

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

  test "layout_version ignores terminal churn but changes for geometry and zoom" do
    windows = [
      %{id: "@1", index: 0, name: "shell", active: true, panes: 2, activity: 1}
    ]

    panes = [
      %{
        id: "%1",
        window_id: "@1",
        index: 0,
        active: true,
        left: 0,
        top: 0,
        width: 40,
        height: 24,
        zoomed?: false,
        current_command: "bash",
        activity: 1
      },
      %{
        id: "%2",
        window_id: "@1",
        index: 1,
        active: false,
        left: 40,
        top: 0,
        width: 40,
        height: 24,
        zoomed?: false,
        current_command: "mix",
        activity: 1
      }
    ]

    churned =
      Enum.map(
        panes,
        &Map.merge(&1, %{activity: 999, current_command: "changed", current_path: "/tmp"})
      )

    resized =
      Enum.map(panes, fn
        %{id: "%1"} = pane -> %{pane | width: 50}
        %{id: "%2"} = pane -> %{pane | left: 50, width: 30}
      end)

    zoomed =
      Enum.map(panes, fn
        %{id: "%1"} = pane -> %{pane | zoomed?: true}
        pane -> pane
      end)

    selected =
      Enum.map(panes, fn
        %{id: "%1"} = pane -> %{pane | active: false}
        %{id: "%2"} = pane -> %{pane | active: true}
      end)

    base = Topology.layout_version(windows, panes)
    assert Topology.layout_version(windows, churned) == base
    refute Topology.layout_version(windows, resized) == base
    refute Topology.layout_version(windows, zoomed) == base
    refute Topology.layout_version(windows, selected) == base
  end

  test "version is stable for activity ticks within the same 15s bucket" do
    session = "topology-activity-bucket-#{System.unique_integer([:positive])}"
    put_fake_topology(session, activity: 30, current_command: "bash")

    snap_a = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    put_fake_topology(session, activity: 31, current_command: "bash")
    snap_b = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    assert snap_a.version == snap_b.version
    # Payload keeps raw timestamps; only the version hash is bucketed.
    assert [%{activity: 30}] = snap_a.panes
    assert [%{activity: 31}] = snap_b.panes
  end

  test "version changes when activity crosses a 15s bucket boundary" do
    session = "topology-activity-cross-#{System.unique_integer([:positive])}"
    put_fake_topology(session, activity: 29, current_command: "bash")

    snap_a = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    put_fake_topology(session, activity: 31, current_command: "bash")
    snap_b = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    refute snap_a.version == snap_b.version
  end

  test "version changes when current_command changes with activity fixed" do
    session = "topology-command-#{System.unique_integer([:positive])}"
    put_fake_topology(session, activity: 42, current_command: "bash")

    snap_a = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    put_fake_topology(session, activity: 42, current_command: "mix")
    snap_b = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    refute snap_a.version == snap_b.version
  end

  test "structure_version is unaffected by activity and command changes" do
    session = "topology-structure-stable-#{System.unique_integer([:positive])}"
    put_fake_topology(session, activity: 10, current_command: "bash")

    snap_a = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    put_fake_topology(session, activity: 99, current_command: "mix")
    snap_b = Topology.snapshot(session, tmux: TmuxCtl.Test.FakeAdapter)

    assert snap_a.structure_version == snap_b.structure_version
  end

  test "structure_version changes when pane role changes" do
    windows = [
      %{id: "@1", index: 0, name: "shell", active: true, panes: 1}
    ]

    panes = [
      %{id: "%1", window_id: "@1", index: 0, active: true, role: "operator"}
    ]

    renamed = [%{hd(panes) | role: "agent"}]

    refute Topology.structure_version(windows, panes) ==
             Topology.structure_version(windows, renamed)
  end

  test "structure_version changes when pane pairing flips" do
    windows = [
      %{id: "@1", index: 0, name: "shell", active: true, panes: 1}
    ]

    panes = [
      %{id: "%1", window_id: "@1", index: 0, active: true, role: "agent", paired: true}
    ]

    flipped = [%{hd(panes) | paired: false}]

    refute Topology.structure_version(windows, panes) ==
             Topology.structure_version(windows, flipped)
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

  defp put_fake_topology(session, opts) do
    activity = Keyword.fetch!(opts, :activity)
    current_command = Keyword.fetch!(opts, :current_command)

    TmuxCtl.Test.FakeState.put(:fake_tmux_windows, %{
      session => [
        %{
          id: "@1",
          index: 0,
          name: "shell",
          active: true,
          panes: 1,
          activity: activity,
          current_command: current_command
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
          current_command: current_command,
          current_path: "/workspace",
          activity: activity,
          activity_flag: true,
          bell: false,
          unseen_changes: true
        }
      ]
    })
  end

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
