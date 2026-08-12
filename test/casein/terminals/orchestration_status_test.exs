defmodule Casein.Terminals.OrchestrationStatusTest do
  use ExUnit.Case, async: true

  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrchestrationStatus
  alias Casein.Terminals.OrphanedClaims

  @now ~U[2026-08-10 04:00:00Z]

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

  @gate_held %{
    lock_state: :held,
    depth: 2,
    waiter_count: 1,
    holder: %{
      pid: 42,
      pr: 810,
      branch: "agent/demo",
      run_id: "31342726258",
      sha: "b0a4bfd",
      held_for_seconds: 90
    },
    waiters: [%{pid: 99, pr: 811}],
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
    test "shapes fleet board into wire payload with identity" do
      board =
        board([
          tab("w1", agent_state: :blocked, issue: 384, fleet_role: :worker),
          tab("w2", agent_state: :working, fleet_role: :manager)
        ])

      payload =
        OrchestrationStatus.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert payload.workspace_id == "ws-1"
      assert payload.session == "casein_ws-1_main"
      assert payload.generated_at == DateTime.to_iso8601(@now)
      assert payload.total == 2
      assert payload.attention_count == 1
      assert payload.counts["needs_you"] == 1
      assert payload.counts["working"] == 1
      assert payload.gate_queue.observe_state == "ok"
      assert payload.gate_queue.lock_state == "free"
      assert payload.gate_queue.depth == 0
      assert payload.orphaned_claims.observe_state == "ok"
      assert payload.orphaned_claims.orphan_count == 0
      assert is_binary(payload.note)
      assert payload.note =~ "M1"
      assert length(payload.blocked) == 1
      assert hd(payload.blocked).issue == 384
      assert hd(payload.blocked).blocked_on.kind == "report"
      assert hd(payload.blocked).blocked_on.reason == "blocked"

      [blocked, working] = payload.rows
      assert blocked.agent_state == "blocked"
      assert blocked.needs_you? == true
      assert blocked.issue == 384
      assert blocked.fleet_role == "worker"
      assert blocked.pane_id == "%w1"
      assert blocked.blocked_on.kind == "report"
      assert working.agent_state == "working"
      assert working.needs_you? == false
      assert is_nil(Map.get(working, :blocked_on))
    end

    test "gate held projects depth, positions, and my_position; unknown stays unknown not free" do
      held =
        board([tab("w1", agent_state: :working)], gate_queue: @gate_held)
        |> OrchestrationStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now,
          gate_identity: %{pr: 811}
        )

      assert held.gate_queue.observe_state == "ok"
      assert held.gate_queue.lock_state == "held"
      assert held.gate_queue.depth == 2
      assert held.gate_queue.waiter_count == 1
      assert held.gate_queue.holder.pr == 810
      assert held.gate_queue.holder.position == 1
      assert hd(held.gate_queue.waiters).position == 2
      assert held.gate_queue.summary =~ "gate held"
      assert held.gate_queue.my_position.status == "waiting"
      assert held.gate_queue.my_position.position == 2
      assert held.gate_queue.my_position.ahead == 1

      holding =
        board([tab("w1", agent_state: :working)], gate_queue: @gate_held)
        |> OrchestrationStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now,
          gate_identity: %{pr: 810}
        )

      assert holding.gate_queue.my_position.status == "holding"
      assert holding.gate_queue.my_position.position == 1

      unknown =
        board([tab("w1", agent_state: :working)], gate_queue: GateQueue.unknown())
        |> OrchestrationStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now,
          gate_identity: %{pr: 810}
        )

      assert unknown.gate_queue.observe_state == "unknown"
      assert unknown.gate_queue.lock_state == "unknown"
      refute unknown.gate_queue.lock_state == "free"
      assert unknown.gate_queue.summary =~ "unknown"
      # unknown observation must never look like "not in queue" / free
      assert unknown.gate_queue.my_position.status == "unknown"
      refute unknown.gate_queue.my_position[:status] == "not_in_queue"
      refute unknown.gate_queue.my_position[:status] == "free"
    end

    test "liveness unknown never becomes quiet; blocked_on distinguishes stalled" do
      board =
        board([
          tab("w1",
            agent_state: :stalled,
            agent_state_message: nil,
            liveness: %{state: :quiet, quiet_for_seconds: 900}
          ),
          tab("w2",
            agent_state: :working,
            liveness: %{state: :unknown, reason: :eacces}
          ),
          tab("w3", agent_state: :working)
        ])

      payload =
        OrchestrationStatus.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      by_pane = Map.new(payload.rows, &{&1.pane_id, &1})

      stalled = by_pane["%w1"]
      assert stalled.blocked_on.kind == "derived"
      assert stalled.blocked_on.reason == "stalled"
      assert stalled.liveness.state == "quiet"
      assert stalled.liveness.quiet_for_seconds == 900

      unknown = by_pane["%w2"]
      assert unknown.liveness.state == "unknown"
      assert unknown.liveness.reason == "eacces"
      refute unknown.liveness.state == "quiet"
      refute unknown.bucket == "idle"

      no_live = by_pane["%w3"]
      assert is_nil(Map.get(no_live, :liveness))

      assert Enum.any?(payload.blocked, &(&1.pane_id == "%w1"))
    end

    test "hook-less worker with active liveness projects working, not bare unknown (#916)" do
      board =
        board([
          tab("w1",
            agent_state: nil,
            fleet_role: :worker,
            name: "worker-s2-alive",
            display_name: "worker-s2-alive",
            liveness: %{
              state: :active,
              quiet_for_seconds: 2,
              last_write_at: "2026-08-12T18:00:00Z",
              commit_count: 5
            }
          ),
          tab("w2",
            agent_state: nil,
            fleet_role: :worker,
            name: "worker-unscanned",
            display_name: "worker-unscanned",
            liveness: %{state: :unknown, reason: :eacces}
          )
        ])

      payload =
        OrchestrationStatus.project(board,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert payload.counts["working"] == 1
      assert payload.counts["unknown"] == 1
      refute payload.counts["working"] == 0

      by_name = Map.new(payload.rows, &{&1.name, &1})
      alive = by_name["worker-s2-alive"]
      assert alive
      assert alive.bucket == "working"
      refute Map.has_key?(alive, :unknown_reason)
      assert alive.liveness.state == "active"

      unscanned = by_name["worker-unscanned"]
      assert unscanned
      assert unscanned.bucket == "unknown"
      assert unscanned.unknown_reason == "liveness_unknown:eacces"
      refute unscanned.bucket == "idle"
    end

    test "orphaned claims project list; unknown observation never looks clear" do
      claimed = [%{number: 812, title: "stale claim", priority: "p0"}]

      with_orphan =
        board([tab("w1", agent_state: :working, issue: 384)], claimed: claimed)
        |> OrchestrationStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert with_orphan.orphaned_claims.observe_state == "ok"
      assert with_orphan.orphaned_claims.orphan_count == 1
      assert hd(with_orphan.orphaned_claims.orphans).number == 812
      assert with_orphan.attention_count >= 1

      unknown =
        board([tab("w1", agent_state: :working)],
          orphaned_claims: OrphanedClaims.unknown(reason: :gh_failed)
        )
        |> OrchestrationStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          now: @now
        )

      assert unknown.orphaned_claims.observe_state == "unknown"
      assert is_nil(unknown.orphaned_claims.orphan_count)
      assert unknown.orphaned_claims.summary =~ "unknown"
    end
  end

  describe "tabs_from_topology/1" do
    test "builds board tabs from enriched topology panes" do
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
            agent_state: :blocked,
            issue: 384,
            fleet_role: :worker,
            label: "worker: #384",
            agent_state_message: "need unlock",
            liveness: %{state: :quiet, quiet_for_seconds: 42}
          },
          %{id: "%4", window_id: "@2", role: "operator", current_command: "bash"}
        ]
      }

      tabs = OrchestrationStatus.tabs_from_topology(topology)
      assert length(tabs) == 2
      assert hd(tabs).liveness.state == :quiet

      board = board(tabs)
      assert board.total == 1
      row = hd(board.rows)
      assert row.pane_id == "%3"
      assert row.issue == 384
      assert row.agent_state == :blocked
      assert row.needs_you?
      assert row.fleet_role == :worker
      assert row.blocked_on.kind == :report
      assert row.blocked_on.detail == "need unlock"
      assert row.liveness.state == :quiet
      assert row.liveness.quiet_for_seconds == 42
    end

    test "empty or malformed topology yields no tabs" do
      assert OrchestrationStatus.tabs_from_topology(%{}) == []
      assert OrchestrationStatus.tabs_from_topology(%{windows: [], panes: []}) == []
    end
  end
end
