defmodule Casein.Terminals.FleetSnapshotTest do
  use ExUnit.Case, async: false

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.FleetSnapshot

  @now ~U[2026-08-24 16:00:00Z]
  @gate_free %{
    lock_state: :free,
    depth: 0,
    waiter_count: 0,
    holder: nil,
    waiters: [],
    observed_at: @now,
    lock_path: "/tmp/casein-pr-gate.lock",
    source: :proc
  }

  defmodule FakeTmux do
    def session_topology(_session) do
      windows = [
        %{
          id: "@1",
          index: 0,
          name: "worker-384",
          manual_name: true,
          active: true,
          panes: 1,
          activity: 100,
          current_command: "opencode"
        }
      ]

      panes = [
        %{
          id: "%3",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 24,
          current_command: "opencode",
          current_path: System.tmp_dir!(),
          pane_title: "opencode",
          role: "agent",
          paired: true,
          paired_reason: "role",
          activity: 100,
          activity_flag: false,
          bell: false,
          unseen_changes: false,
          zoomed?: false,
          agent_state: :blocked,
          issue: 384,
          fleet_role: :worker,
          agent_state_message: "need unlock"
        }
      ]

      {windows, panes}
    end

    def list_session_windows(session) do
      {windows, _} = session_topology(session)
      windows
    end

    def list_session_panes(session) do
      {_, panes} = session_topology(session)
      panes
    end

    def list_sessions, do: [%{session: "casein_ws-1_main"}]
  end

  setup do
    FleetSnapshot.ensure_table!()
    FleetSnapshot.delete()
    on_exit(fn -> FleetSnapshot.delete() end)
    :ok
  end

  test "cached is nil until a snapshot lands" do
    assert FleetSnapshot.cached() == nil
  end

  test "missing snapshot is incomplete, not an empty-ok fleet" do
    status = FleetSnapshot.orchestration_status("ws-1", "casein_ws-1_main", now: @now)
    assert status.generated_at == DateTime.to_iso8601(@now)
    assert status.incomplete == true
    assert status.incomplete_reason == "snapshot_unavailable"
    assert status.rows == []
    assert status.total == 0

    list =
      FleetSnapshot.orchestration_list_workers("ws-1", "casein_ws-1_main",
        now: @now,
        needs_you_only: true
      )

    assert list.incomplete == true
    assert list.incomplete_reason == "snapshot_unavailable"
    assert list.needs_you_observe_state == "unknown"
    assert list.workers == []

    summary = FleetSnapshot.fleet_summary("ws-1")
    assert summary.incomplete == true
    assert summary.incomplete_reason == "snapshot_unavailable"
    assert summary.sessions == []
    assert is_binary(summary.generated_at)
  end

  test "build + put serves status, list, and summary from ETS" do
    snap =
      FleetSnapshot.build(
        sessions: [%{session: "casein_ws-1_main"}],
        tmux: FakeTmux,
        now: @now,
        list_claimed: fn -> {:ok, []} end,
        gate_queue: @gate_free
      )

    assert snap.generated_at == DateTime.to_iso8601(@now)
    assert snap.incomplete == false
    assert is_nil(snap.incomplete_reason)
    FleetSnapshot.put(snap)

    status = FleetSnapshot.orchestration_status("ws-1", "casein_ws-1_main", now: @now)
    assert status.incomplete == false
    assert status.total == 1
    assert hd(status.blocked).issue == 384
    assert hd(status.blocked).needs_you? == true

    list = FleetSnapshot.orchestration_list_workers("ws-1", "casein_ws-1_main")
    assert list.needs_you_observe_state == "ok"
    assert list.filtered_total == 1
    assert hd(list.workers).issue == 384

    summary = FleetSnapshot.fleet_summary(nil)
    assert summary.incomplete == false
    assert summary.generated_at == DateTime.to_iso8601(@now)
    assert summary.session_count >= 1
  end

  test "needs_you_only empty-ok is distinguishable from could-not-compute" do
    board =
      FleetBoard.from_window_tabs(
        [
          %{
            id: "w1",
            name: "w1",
            display_name: "working",
            agent_state: :working,
            agent_pane_id: "%1",
            fleet_role: :worker,
            quiet?: false,
            unseen_quiet?: false,
            active?: false
          }
        ],
        gate_queue: @gate_free,
        claimed: []
      )

    FleetSnapshot.put(%{
      generated_at: DateTime.to_iso8601(@now),
      incomplete: false,
      incomplete_reason: nil,
      boards: %{"casein_ws-1_main" => board},
      needs_you: %{"casein_ws-1_main" => []},
      totals: %{"casein_ws-1_main" => 1},
      summary: %{
        uri: "casein://fleet/summary",
        workspace_id: "ws-1",
        generated_at: DateTime.to_iso8601(@now),
        incomplete: false,
        incomplete_reason: nil,
        session_count: 1,
        pane_count: 1,
        sessions: [%{session: "casein_ws-1_main", panes: []}],
        note: "test"
      }
    })

    list =
      FleetSnapshot.orchestration_list_workers("ws-1", "casein_ws-1_main", needs_you_only: true)

    assert list.incomplete == false
    assert list.needs_you_observe_state == "ok"
    assert list.workers == []
    assert list.total == 1
    assert list.filtered_total == 0
  end

  test "needs_you_only is served from the precomputed index" do
    worker = %{
      pane_id: "%9",
      window: "worker-9",
      window_id: "@9",
      issue: 9,
      agent_state: "blocked",
      fleet_role: "worker",
      needs_you?: true
    }

    FleetSnapshot.put(%{
      generated_at: DateTime.to_iso8601(@now),
      incomplete: false,
      incomplete_reason: nil,
      boards: %{"casein_ws-1_main" => FleetBoard.empty()},
      needs_you: %{"casein_ws-1_main" => [worker]},
      totals: %{"casein_ws-1_main" => 4},
      summary: %{
        uri: "casein://fleet/summary",
        generated_at: DateTime.to_iso8601(@now),
        incomplete: false,
        incomplete_reason: nil,
        session_count: 1,
        pane_count: 4,
        sessions: [],
        note: "test"
      }
    })

    list =
      FleetSnapshot.orchestration_list_workers("ws-1", "casein_ws-1_main", needs_you_only: true)

    assert list.workers == [worker]
    assert list.total == 4
    assert list.filtered_total == 1
    assert list.needs_you_observe_state == "ok"
  end

  test "budget expiry marks incomplete and keeps scanned sessions" do
    snap =
      FleetSnapshot.build(
        sessions: [%{session: "casein_ws-1_a"}, %{session: "casein_ws-1_b"}],
        tmux: FakeTmux,
        now: @now,
        budget_ms: 0,
        list_claimed: fn -> {:ok, []} end,
        gate_queue: @gate_free
      )

    assert snap.incomplete == true
    assert snap.incomplete_reason == "refresh_budget_exceeded"
    assert snap.summary.incomplete == true
    assert snap.boards == %{}
  end

  test "unknown session in a landed snapshot is incomplete, not empty-ok" do
    FleetSnapshot.put(%{
      generated_at: DateTime.to_iso8601(@now),
      incomplete: false,
      incomplete_reason: nil,
      boards: %{},
      needs_you: %{},
      totals: %{},
      summary: %{
        uri: "casein://fleet/summary",
        generated_at: DateTime.to_iso8601(@now),
        incomplete: false,
        incomplete_reason: nil,
        session_count: 0,
        pane_count: 0,
        sessions: [],
        note: "test"
      }
    })

    status = FleetSnapshot.orchestration_status("ws-1", "casein_ws-1_missing")
    assert status.incomplete == true
    assert status.incomplete_reason == "session_not_in_snapshot"

    list =
      FleetSnapshot.orchestration_list_workers("ws-1", "casein_ws-1_missing",
        needs_you_only: true
      )

    assert list.needs_you_observe_state == "unknown"
    assert list.incomplete_reason == "session_not_in_snapshot"
  end
end
