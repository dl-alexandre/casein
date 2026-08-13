defmodule Casein.Terminals.FleetBoardTest do
  use ExUnit.Case, async: true

  alias Casein.Ops.GateQueue
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.TicketFeed

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

    test "report-kind blocked/errored are needs_you; derived stalled is not" do
      tabs = [
        tab("w1",
          agent_state: :blocked,
          name: "blocked-worker",
          agent_state_message: "need unlock"
        ),
        tab("w2", agent_state: :errored, name: "errored-worker"),
        tab("w3",
          agent_state: :stalled,
          name: "stalled-worker",
          liveness: %{state: :quiet, quiet_for_seconds: 700}
        )
      ]

      board = board(tabs)

      # Only what the agent REPORTED summons a human. `stalled` is derived from
      # outside observation, so it badges slate and stays out of the lane.
      assert board.attention_count == 2
      assert board.counts.needs_you == 2

      by_name = Map.new(board.rows, &{&1.name, &1})
      assert by_name["blocked-worker"].needs_you?
      assert by_name["errored-worker"].needs_you?
      refute by_name["stalled-worker"].needs_you?
      assert by_name["stalled-worker"].bucket == :idle
      assert by_name["stalled-worker"].attention_reason == :stalled

      reasons =
        board.rows
        |> Enum.map(& &1.attention_reason)
        |> Enum.sort()

      assert reasons == [:blocked, :errored, :stalled]

      by_name = Map.new(board.rows, &{&1.name, &1})

      assert by_name["blocked-worker"].blocked_on == %{
               kind: :report,
               reason: :blocked,
               detail: "need unlock"
             }

      assert by_name["stalled-worker"].blocked_on.kind == :derived
      assert by_name["stalled-worker"].blocked_on.reason == :stalled
      assert by_name["stalled-worker"].liveness.state == :quiet
    end

    test "liveness unknown keeps reason and is never quiet; missing stays nil" do
      board =
        board([
          tab("w1",
            agent_state: :working,
            liveness: %{state: :unknown, reason: :enoent}
          ),
          tab("w2", agent_state: :working)
        ])

      [unknown_row, bare] = board.rows
      # sort is stable by name when same bucket — pin by pane
      by_id = Map.new(board.rows, &{&1.window_id, &1})

      assert by_id["w1"].liveness.state == :unknown
      assert by_id["w1"].liveness.reason == :enoent
      refute by_id["w1"].liveness.state == :quiet
      assert is_nil(by_id["w2"].liveness)
      assert is_nil(unknown_row.blocked_on) or bare.bucket == :working
    end

    test "working rows are not needs_you" do
      board = board([tab("w1", agent_state: :working)])
      assert board.counts.working == 1
      assert board.attention_count == 0
      refute hd(board.rows).needs_you?
    end

    test "ready_no_task is capacity, not attention" do
      tab =
        tab("w1",
          agent_state: :idle,
          fleet_role: :worker,
          fleet_readiness: :ready_no_task,
          ready_no_task_for_seconds: 240
        )

      board = board([tab])
      row = hd(board.rows)

      # A spawned worker with nothing to do is the operator's to fill. It is not
      # an interrupt, and it must not inflate the needs-you badge.
      refute row.needs_you?
      assert row.bucket == :ready_no_task
      assert row.attention_reason == :ready_no_task
      assert row.ready_no_task_for_seconds == 240
      assert board.attention_count == 0
      assert row.capacity?
    end

    test "quiet idle is not a human lane" do
      board =
        board([
          tab("w1", agent_state: :idle, quiet?: true, fleet_role: :worker)
        ])

      row = hd(board.rows)
      refute row.needs_you?
      assert row.bucket == :idle
      assert row.attention_reason == :idle
      assert board.attention_count == 0
    end

    test "unknown agent_state without liveness is never quiet/idle and carries reason (#916)" do
      board =
        board([
          tab("w1", agent_state: nil, quiet?: false, fleet_role: :worker)
        ])

      row = hd(board.rows)
      assert row.bucket == :unknown
      assert row.unknown_reason == :agent_state_absent_liveness_not_observed
      refute row.needs_you?
      refute row.bucket == :idle
    end

    test "live worker with active liveness and no agent_state report buckets working (#916)" do
      # OpenCode / hook-less panes: fleet_role=worker, no cooperative report,
      # but worktree/process evidence says active. Must not classify unknown.
      board =
        board([
          tab("w1",
            agent_state: nil,
            fleet_role: :worker,
            name: "worker-s2-alive",
            liveness: %{
              state: :active,
              quiet_for_seconds: 3,
              last_write_at: "2026-08-12T18:00:00Z",
              commit_count: 12
            }
          )
        ])

      row = hd(board.rows)
      assert row.bucket == :working
      assert is_nil(row.unknown_reason)
      assert row.liveness.state == :active
      refute row.bucket == :unknown
      refute row.bucket == :idle
    end

    test "live worker with quiet liveness and no agent_state report buckets idle not unknown" do
      board =
        board([
          tab("w1",
            agent_state: nil,
            fleet_role: :worker,
            liveness: %{state: :quiet, quiet_for_seconds: 400}
          )
        ])

      row = hd(board.rows)
      assert row.bucket == :idle
      assert is_nil(row.unknown_reason)
      # Observed quiet ≠ unscanned unknown
      refute row.bucket == :unknown
    end

    test "unscanned liveness stays unknown with reason — never collapsed to idle" do
      board =
        board([
          tab("w1",
            agent_state: nil,
            fleet_role: :worker,
            liveness: %{state: :unknown, reason: :eacces}
          )
        ])

      row = hd(board.rows)
      assert row.bucket == :unknown
      assert row.unknown_reason == {:liveness_unknown, :eacces}
      refute row.bucket == :idle
      refute row.bucket == :working
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

      # quiet idle is not attention any more; the orphan side is unknown and
      # adds 0 — unknown must never be rendered as a calm zero.
      assert board.orphaned_claims.observe_state == :unknown
      assert board.attention_count == 0
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

  describe "join_tickets/2 — one row = one live ticket" do
    @iss %{
      kind: :issue,
      number: 17_070,
      title: "wire ticket feed into fleet board",
      url: nil,
      updated_at: ~U[2026-08-12 22:00:00Z],
      head_ref: nil,
      draft?: false,
      labels: [],
      priority: nil,
      repo: "dl-alexandre/casein"
    }

    @pr %{
      kind: :pr,
      number: 912,
      title: "refuse next_prompt on hook-less OpenCode panes",
      url: nil,
      updated_at: ~U[2026-08-12 23:00:00Z],
      head_ref: "agent/claude/next-prompt",
      draft?: false,
      labels: [],
      priority: nil,
      repo: "dl-alexandre/casein"
    }

    defp feed(tickets, branches \\ %{}) do
      TicketFeed.project(tickets, branch_by_worktree: branches, now: ~U[2026-08-12 23:30:00Z])
    end

    test "joins by issue binding" do
      board =
        board([tab("w1", agent_state: :working, issue: 17_070, fleet_role: :worker)],
          ticket_feed: feed([@iss])
        )

      row = hd(board.rows)
      assert row.ticket.number == 17_070
      assert row.ticket.kind == :issue
      assert row.ticket_match == :issue_binding
      refute row.capacity?
    end

    test "joins by #NNNN in the chrome label when there is no binding" do
      board =
        board([tab("w1", agent_state: :working, label: "worker: #17070 item 4")],
          ticket_feed: feed([@iss])
        )

      assert hd(board.rows).ticket_match == :label
    end

    @tag :join
    test "joins a PR by worktree branch — the case with no issue and no #NNNN" do
      tab =
        tab("w1",
          agent_state: :working,
          name: "worker-next-prompt",
          fleet_role: :worker,
          worktree_path: "/data/casein-agent-worktrees/agent-claude-next-prompt"
        )

      board =
        board([tab],
          ticket_feed:
            feed([@iss, @pr], %{
              "/data/casein-agent-worktrees/agent-claude-next-prompt" =>
                "agent/claude/next-prompt"
            })
        )

      row = hd(board.rows)
      assert row.ticket.kind == :pr
      assert row.ticket.number == 912
      assert row.ticket_match == :branch
      refute row.capacity?
    end

    test "a pane with no ticket is capacity, not equal to #NNNN" do
      board =
        board(
          [
            tab("w1", agent_state: :working, issue: 17_070),
            tab("w2", agent_state: :idle, fleet_role: :worker, name: "podcast")
          ],
          ticket_feed: feed([@iss])
        )

      by_name = Map.new(board.rows, &{&1.name, &1})
      refute by_name["w1"].capacity?
      assert by_name["podcast"].capacity?
      # Capacity sorts below live work rather than interleaving with it.
      assert List.last(board.rows).name == "podcast"
    end

    test "sorts as one continuous list by last ticket update" do
      tabs = [
        tab("w-iss", agent_state: :working, issue: 17_070),
        tab("w-pr",
          agent_state: :working,
          worktree_path: "/wt/pr"
        )
      ]

      board =
        board(tabs,
          ticket_feed: feed([@iss, @pr], %{"/wt/pr" => "agent/claude/next-prompt"})
        )

      # PR updated 23:00 beats issue 22:00 — not a bucket rank.
      assert Enum.map(board.rows, & &1.ticket.number) == [912, 17_070]
    end

    test "unknown feed leaves every row unjoined without claiming no work" do
      board =
        board([tab("w1", agent_state: :working, issue: 17_070)],
          ticket_feed: TicketFeed.unknown()
        )

      row = hd(board.rows)
      assert is_nil(row.ticket)
      assert board.ticket_feed_state == :unknown
    end

    test "claimed with no live pane shows as a parked ticket row with no WHO" do
      board =
        board([tab("w1", agent_state: :working, issue: 17_070)],
          ticket_feed: feed([@iss]),
          claimed: [%{number: 690, title: "parked work", labels: ["queue/claimed"]}]
        )

      parked = Enum.find(board.rows, & &1.parked?)
      assert parked.ticket.number == 690
      assert parked.ticket.kind == :issue
      assert is_nil(parked.agent_state)
      assert parked.needs_you?
      # Fleet size is agents; a parked ticket has none, so it must not inflate it.
      assert board.total == 1
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
