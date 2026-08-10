defmodule Casein.Terminals.FleetBoardTest do
  use ExUnit.Case, async: true

  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetBoard

  @gate_free %{
    lock_state: :free,
    depth: 0,
    waiter_count: 0,
    holder: nil,
    waiters: [],
    observed_at: nil,
    lock_path: "/tmp/casein-pr-gate.lock",
    source: :proc
  }

  @gate_held %{
    lock_state: :held,
    depth: 2,
    waiter_count: 1,
    holder: %{
      pid: 42,
      pr: 806,
      branch: "agent/opencode/demo",
      run_id: "31342726258",
      sha: "c9ea09e",
      held_for_seconds: 120
    },
    waiters: [%{pid: 99, pr: 807}],
    observed_at: nil,
    lock_path: "/tmp/casein-pr-gate.lock",
    source: :proc
  }

  # Default gate_queue free so orphan cases do not hit live /proc observation.
  defp board(tabs, opts \\ []) do
    FleetBoard.from_window_tabs(tabs, Keyword.put_new(opts, :gate_queue, @gate_free))
  end

  describe "from_window_tabs/2" do
    test "empty tabs yield empty board" do
      board = board([])
      assert board.empty?
      assert board.total == 0
      assert board.attention_count == 0
      assert board.rows == []
      assert board.gate_queue.lock_state == :free
    end

    test "drops pure shell windows when agent_only" do
      tabs = [tab("w-shell", name: "bash", agent_state: nil, quiet?: false)]
      board = board(tabs)
      assert board.empty?
    end

    test "keeps shell windows when agent_only is false" do
      tabs = [tab("w-shell", name: "bash", agent_state: nil)]
      board = board(tabs, agent_only: false)
      assert board.total == 1
      assert hd(board.rows).bucket == :unknown
    end

    test "buckets blocked/errored/stalled into needs_you with distinct reasons" do
      tabs = [
        tab("w1", agent_state: :blocked, name: "blocked-worker"),
        tab("w2", agent_state: :errored, name: "errored-worker"),
        tab("w3", agent_state: :stalled, name: "stalled-worker")
      ]

      board = board(tabs)
      assert board.attention_count == 3
      assert board.counts.needs_you == 3

      reasons =
        board.rows
        |> Enum.map(& &1.attention_reason)
        |> Enum.sort()

      assert reasons == [:blocked, :errored, :stalled]
    end

    test "working rows are not needs_you" do
      board = board([tab("w1", agent_state: :working)])
      assert board.counts.working == 1
      assert board.attention_count == 0
      refute hd(board.rows).needs_you?
    end

    test "ready_no_task is needs_you with ready_no_task reason" do
      tab =
        tab("w1",
          agent_state: :idle,
          fleet_role: :worker,
          fleet_readiness: :ready_no_task,
          ready_no_task_for_seconds: 240
        )

      board = board([tab])
      row = hd(board.rows)
      assert row.needs_you?
      assert row.bucket == :needs_you
      assert row.attention_reason == :ready_no_task
      assert row.ready_no_task_for_seconds == 240
    end

    test "quiet idle without readiness still needs you as idle" do
      board =
        board([
          tab("w1", agent_state: :idle, quiet?: true, fleet_role: :worker)
        ])

      row = hd(board.rows)
      assert row.needs_you?
      assert row.attention_reason == :idle
    end

    test "unknown agent_state is never quiet/idle" do
      board =
        board([
          tab("w1", agent_state: nil, quiet?: false, fleet_role: :worker)
        ])

      row = hd(board.rows)
      assert row.bucket == :unknown
      refute row.needs_you?
    end

    test "sorts needs_you before working and carries issue + role" do
      tabs = [
        tab("w-work", agent_state: :working, name: "z-working", fleet_role: :worker),
        tab("w-block",
          agent_state: :blocked,
          name: "a-blocked",
          issue: 384,
          issue_title: "control plane",
          fleet_role: :manager
        )
      ]

      board = board(tabs)
      assert Enum.map(board.rows, & &1.window_id) == ["w-block", "w-work"]
      lead = hd(board.rows)
      assert lead.issue == 384
      assert lead.issue_title == "control plane"
      assert lead.fleet_role == :manager
    end

    test "without claimed source orphaned_claims stays unknown, not empty-ok" do
      board = board([tab("w1", agent_state: :working, issue: 812)])
      oc = board.orphaned_claims
      assert oc.observe_state == :unknown
      assert oc.reason == :no_claimed_source
      assert oc.bound_issues == [812]
      # unknown must not inflate attention_count as if orphans were counted
      assert board.attention_count == 0
    end

    test "orphaned claims add to attention_count and stay on the board snapshot" do
      claimed = [
        %{number: 690, title: "stale a", labels: ["priority/p0"]},
        %{number: 812, title: "live", labels: ["priority/p0"]}
      ]

      board =
        board(
          [tab("w1", agent_state: :working, issue: 812)],
          claimed: claimed
        )

      assert board.orphaned_claims.observe_state == :ok
      assert board.orphaned_claims.orphan_count == 1
      assert hd(board.orphaned_claims.orphans).number == 690
      assert board.attention_count == 1
      assert FleetBoard.needs_attention?(board)
    end

    test "failed claimed observe does not count as zero orphans calm" do
      board =
        board(
          [tab("w1", agent_state: :idle, quiet?: true, fleet_role: :worker)],
          claimed: {:error, :gh_failed}
        )

      # quiet idle still needs you; orphan side is unknown and adds 0
      assert board.orphaned_claims.observe_state == :unknown
      assert board.attention_count == 1
    end

    test "carries gate_queue snapshot on the board" do
      board = board([], gate_queue: @gate_held)
      assert board.gate_queue.lock_state == :held
      assert board.gate_queue.depth == 2
      assert board.gate_queue.holder.pr == 806
      assert GateQueue.busy?(board.gate_queue)
      assert GateQueue.summary(board.gate_queue) =~ "PR #806"
    end

    test "empty/1 gate_queue is unknown not free" do
      board = FleetBoard.empty()
      assert board.gate_queue.lock_state == :unknown
      refute GateQueue.busy?(board.gate_queue)
      assert GateQueue.summary(board.gate_queue) == "gate unknown"
      assert board.orphaned_claims.observe_state == :unknown
    end
  end

  defp tab(id, opts) do
    defaults = %{
      id: id,
      name: id,
      display_name: id,
      agent_state: nil,
      quiet?: false,
      unseen_quiet?: false,
      active?: false,
      agent_pane_id: "%1"
    }

    Map.merge(defaults, Map.new(opts))
    |> then(fn m ->
      Map.put(m, :display_name, Map.get(m, :display_name) || Map.get(m, :name) || id)
    end)
  end
end
