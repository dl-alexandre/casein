defmodule Casein.Terminals.FleetStateProvenanceTest do
  @moduledoc """
  OneBackend-v3#20022: provenance fields reach every fleet projection, so an
  absent agent_state is explained on worker_status and
  orchestration_list_workers alike.
  """
  use ExUnit.Case, async: true

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrchestrationListWorkers
  alias Casein.Terminals.OrchestrationStatus
  alias Casein.Terminals.WorkerStatus

  @now ~U[2026-08-30 18:00:00Z]

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

  defp expired_pane do
    %{
      id: "%25",
      window_id: "@21",
      window_name: "worker-issue-19985-locked-field-badge-recovery",
      role: "agent",
      fleet_role: :worker,
      worktree_path: "/data/casein-agent-worktrees/agent-claude-issue-19985",
      agent_state_resolution: :expired_report,
      agent_state_last_reported: :blocked,
      agent_state_reported_at: "2026-08-29T18:00:00Z",
      agent_state_age_s: 86_400,
      liveness: %{state: :quiet, quiet_for_seconds: 80_000},
      quiet?: false
    }
  end

  defp unreported_pane do
    %{
      id: "%53",
      window_id: "@30",
      window_name: "worker-issue-19888-promote-list-view",
      role: "agent",
      fleet_role: :worker,
      agent_state_resolution: :unreported,
      quiet?: false
    }
  end

  defp topology(panes) do
    windows =
      panes
      |> Enum.map(&%{id: &1.window_id, name: &1.window_name, active: false})
      |> Enum.uniq_by(& &1.id)

    %{windows: windows, panes: panes}
  end

  describe "worker_status" do
    test "an expired report is explained, with its last word and age" do
      payload =
        WorkerStatus.project(topology([expired_pane()]),
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%25",
          now: @now
        )

      refute Map.has_key?(payload, :agent_state)
      assert payload.agent_state_resolution == "expired_report"
      assert payload.agent_state_last_reported == "blocked"
      assert payload.agent_state_reported_at == "2026-08-29T18:00:00Z"
      assert payload.agent_state_age_s == 86_400
      assert payload.agent_state_note =~ "last report (blocked) is 24h old"
      assert payload.agent_state_note =~ "agent_state_last_reported"
      assert payload.note =~ "agent_state_resolution"
    end

    test "a pane that never reported is distinguishable from an expired one" do
      payload =
        WorkerStatus.project(topology([unreported_pane()]),
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%53",
          now: @now
        )

      refute Map.has_key?(payload, :agent_state)
      assert payload.agent_state_resolution == "unreported"
      refute Map.has_key?(payload, :agent_state_last_reported)
      assert payload.agent_state_note =~ "never reported"
    end

    test "a live report carries :report provenance and no note" do
      pane =
        expired_pane()
        |> Map.merge(%{
          agent_state: :blocked,
          agent_state_resolution: :report,
          agent_state_age_s: 30,
          agent_state_reported_at: "2026-08-30T17:59:30Z"
        })

      payload =
        WorkerStatus.project(topology([pane]),
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%25",
          now: @now
        )

      assert payload.agent_state == "blocked"
      assert payload.agent_state_resolution == "report"
      assert payload.agent_state_age_s == 30
      refute Map.has_key?(payload, :agent_state_note)
    end
  end

  describe "orchestration_list_workers" do
    test "rows carry provenance and the payload says which liveness it used" do
      board =
        topology([expired_pane(), unreported_pane()])
        |> OrchestrationStatus.tabs_from_topology()
        |> FleetBoard.from_window_tabs(gate_queue: @gate_free, claimed: [])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now,
          liveness_source: :observed
        )

      assert payload.liveness_source == "observed"
      assert payload.note =~ "liveness_source=observed"
      refute Map.has_key?(payload, :snapshot_generated_at)

      expired = Enum.find(payload.workers, &(&1.pane_id == "%25"))
      assert expired.agent_state_resolution == "expired_report"
      assert expired.agent_state_last_reported == "blocked"
      assert expired.agent_state_reported_at == "2026-08-29T18:00:00Z"
      assert expired.agent_state_age_s == 86_400
      refute Map.has_key?(expired, :agent_state)

      unreported = Enum.find(payload.workers, &(&1.pane_id == "%53"))
      assert unreported.agent_state_resolution == "unreported"
      refute Map.has_key?(unreported, :agent_state_last_reported)
    end

    test "the snapshot path is labelled as such, with the snapshot's generation time" do
      board = FleetBoard.from_window_tabs([], gate_queue: @gate_free, claimed: [])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now,
          liveness_source: :snapshot,
          snapshot_generated_at: "2026-08-30T17:59:00Z"
        )

      assert payload.liveness_source == "snapshot"
      assert payload.snapshot_generated_at == "2026-08-30T17:59:00Z"
      assert payload.note =~ "include_liveness=true"
    end

    test "omitting liveness_source defaults to the snapshot label" do
      board = FleetBoard.from_window_tabs([], gate_queue: @gate_free, claimed: [])

      payload =
        OrchestrationListWorkers.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert payload.liveness_source == "snapshot"
    end
  end
end
