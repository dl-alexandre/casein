defmodule Casein.Terminals.OrchestrationListWorkersTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrchestrationListWorkers
  alias Casein.Terminals.OrchestrationStatus

  @now ~U[2026-08-11 12:00:00Z]

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

  defp board(tabs, opts \\ []) do
    FleetBoard.from_window_tabs(
      tabs,
      Keyword.merge([gate_queue: @gate_free, claimed: []], opts)
    )
  end

  defp tab(id, overrides) do
    Map.merge(
      %{
        id: id,
        name: id,
        display_name: id,
        agent_state: :working,
        agent_pane_id: "%#{id}",
        quiet?: false,
        unseen_quiet?: false,
        active?: false
      },
      Map.new(overrides)
    )
  end

  describe "project/2" do
    test "shapes compact worker rows from fleet board" do
      board =
        board([
          tab("w1",
            agent_state: :blocked,
            issue: 384,
            fleet_role: :worker,
            display_name: "worker-384",
            agent_state_message: "need unlock"
          ),
          tab("w2", agent_state: :working, fleet_role: :manager, display_name: "mgr")
        ])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert payload.workspace_id == "ws-1"
      assert payload.session == "casein_ws-1_main"
      assert payload.generated_at == DateTime.to_iso8601(@now)
      assert payload.total == 2
      assert payload.filtered_total == 2
      assert payload.filters.needs_you_only == false
      refute Map.has_key?(payload.filters, :fleet_role)
      assert payload.note =~ "M3"
      assert length(payload.workers) == 2

      blocked = Enum.find(payload.workers, &(&1.pane_id == "%w1"))
      assert blocked.window == "worker-384"
      assert blocked.window_id == "w1"
      assert blocked.issue == 384
      assert blocked.agent_state == "blocked"
      assert blocked.fleet_role == "worker"
      assert blocked.needs_you? == true
      assert blocked.blocked_on.kind == "report"
      assert blocked.blocked_on.reason == "blocked"
      assert blocked.blocked_on.detail == "need unlock"

      working = Enum.find(payload.workers, &(&1.pane_id == "%w2"))
      assert working.agent_state == "working"
      assert working.fleet_role == "manager"
      assert working.needs_you? == false
      refute Map.has_key?(working, :blocked_on)
    end

    test "fleet_role filter keeps matching rows only" do
      board =
        board([
          tab("w1", agent_state: :working, fleet_role: :worker),
          tab("w2", agent_state: :working, fleet_role: :manager),
          tab("w3", agent_state: :blocked, fleet_role: :worker, issue: 1)
        ])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "s",
          now: @now,
          fleet_role: "worker"
        )

      assert payload.total == 3
      assert payload.filtered_total == 2
      assert payload.filters.fleet_role == "worker"
      assert Enum.map(payload.workers, & &1.pane_id) |> Enum.sort() == ["%w1", "%w3"]
      assert Enum.all?(payload.workers, &(&1.fleet_role == "worker"))
    end

    test "needs_you_only filter keeps attention rows" do
      board =
        board([
          tab("w1", agent_state: :blocked, fleet_role: :worker, issue: 9),
          tab("w2", agent_state: :working, fleet_role: :worker),
          tab("w3",
            agent_state: :idle,
            fleet_role: :worker,
            fleet_readiness: :ready_no_task,
            ready_no_task_for_seconds: 200
          )
        ])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "s",
          now: @now,
          needs_you_only: true
        )

      assert payload.total == 3
      # Only the reported block. The ready-no-task worker is capacity and the
      # working one is fine, so "which of my workers need me?" answers one.
      assert payload.filtered_total == 1
      assert payload.filters.needs_you_only == true
      assert Enum.all?(payload.workers, &(&1.needs_you? == true))
      panes = Enum.map(payload.workers, & &1.pane_id) |> Enum.sort()
      assert panes == ["%w1"]
    end

    test "unknown agent state stays unknown bucket — never invented idle" do
      board =
        board([
          tab("w1", agent_state: nil, fleet_role: :worker, issue: 12)
        ])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "s",
          now: @now
        )

      assert payload.filtered_total == 1
      row = hd(payload.workers)
      assert row.pane_id == "%w1"
      # nil agent_state is omitted (reject_nils), never invented as idle
      refute Map.get(row, :agent_state) == "idle"
      refute Map.has_key?(row, :agent_state)
    end

    test "reuses tabs_from_topology + FleetBoard without a second classifier" do
      topology = %{
        windows: [
          %{id: "@1", name: "worker-384", active: true},
          %{id: "@2", name: "shell", active: false}
        ],
        panes: [
          %{
            id: "%3",
            window_id: "@1",
            role: "agent",
            agent_state: :stalled,
            issue: 384,
            fleet_role: :worker,
            liveness: %{state: :quiet, quiet_for_seconds: 900}
          },
          %{id: "%4", window_id: "@2", role: "operator", current_command: "bash"}
        ]
      }

      tabs = OrchestrationStatus.tabs_from_topology(topology)
      board = board(tabs)

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "s",
          now: @now,
          fleet_role: :worker
        )

      assert payload.filtered_total == 1
      row = hd(payload.workers)
      assert row.pane_id == "%3"
      assert row.window == "worker-384"
      assert row.issue == 384
      assert row.agent_state == "stalled"
      assert row.blocked_on.kind == "derived"
      assert row.blocked_on.reason == "stalled"
      # Derived: still reported as a blocker, still not a summons.
      assert row.needs_you? == false
    end
  end
end
