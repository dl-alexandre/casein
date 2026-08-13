defmodule CaseinWeb.WorkspaceLive.Show.FleetPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrphanedClaims
  alias Casein.Terminals.TicketFeed
  alias CaseinWeb.WorkspaceLive.Show.FleetPanel

  test "drawer lists orphaned claims and never paints unknown as clear" do
    board =
      FleetBoard.from_window_tabs(
        [
          %{
            id: "w1",
            name: "worker-a",
            display_name: "worker-a",
            agent_state: :working,
            quiet?: false,
            issue: 812
          }
        ],
        claimed: [
          %{number: 690, title: "stale lease", labels: ["priority/p0"]},
          %{number: 812, title: "bound", labels: ["priority/p0"]}
        ]
      )

    html =
      render_component(&FleetPanel.fleet_drawer/1, %{
        board: board,
        open: true,
        workspace: %{name: "casein"},
        active_window_id: nil
      })

    assert html =~ ~s(id="fleet-orphaned-claims")
    assert html =~ "orphaned claims · 1"
    # The banner keeps the count; the claim itself is a parked ticket row, so
    # the drawer stays one continuous list instead of listing #690 twice.
    assert html =~ "stale lease"
    assert html =~ "no pane"
    assert html =~ "parked"
    refute html =~ "no orphaned claims"
  end

  test "unknown observation banner refuses calm empty copy" do
    board = %{FleetBoard.empty() | orphaned_claims: OrphanedClaims.unknown(reason: :gh_failed)}

    html =
      render_component(&FleetPanel.fleet_drawer/1, %{
        board: board,
        open: true,
        workspace: %{name: "casein"},
        active_window_id: nil
      })

    assert html =~ "orphaned claims unknown"
    assert html =~ "not the same as zero orphans"
    refute html =~ "no orphaned claims"
  end

  test "badge surfaces attention when orphans exist" do
    board =
      FleetBoard.from_window_tabs([],
        claimed: [%{number: 1, title: "x", labels: ["priority/p0"]}],
        agent_only: false
      )

    html =
      render_component(&FleetPanel.fleet_badge/1, %{
        board: board,
        open: false
      })

    assert html =~ "need you"
    assert html =~ OrphanedClaims.summary(board.orphaned_claims)
  end

  describe "ticket rows" do
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
      title: "refuse next_prompt on hook-less panes",
      url: nil,
      updated_at: ~U[2026-08-12 23:00:00Z],
      head_ref: "agent/claude/next-prompt",
      draft?: false,
      labels: [],
      priority: nil,
      repo: "dl-alexandre/casein"
    }

    defp drawer(board) do
      render_component(&FleetPanel.fleet_drawer/1, %{
        board: board,
        open: true,
        workspace: %{name: "casein"},
        active_window_id: nil
      })
    end

    defp ticket_board(tabs, tickets, branches \\ %{}) do
      FleetBoard.from_window_tabs(tabs,
        ticket_feed: TicketFeed.project(tickets, branch_by_worktree: branches),
        gate_queue: Casein.Ops.GateQueue.unknown()
      )
    end

    test "renders ISS and PR chips with distinct kind colours" do
      html =
        ticket_board(
          [
            %{
              id: "w1",
              name: "worker-a",
              display_name: "worker-a",
              agent_state: :working,
              issue: 17_070
            },
            %{
              id: "w2",
              name: "worker-b",
              display_name: "worker-b",
              agent_state: :working,
              worktree_path: "/wt/pr"
            }
          ],
          [@iss, @pr],
          %{"/wt/pr" => "agent/claude/next-prompt"}
        )
        |> drawer()

      assert html =~ "ISS"
      assert html =~ "17070"
      assert html =~ "PR"
      assert html =~ "912"
      assert html =~ "text-ticket-iss-fg"
      assert html =~ "text-ticket-pr-fg"
      # The ticket title is the row identity, not the pane name.
      assert html =~ "wire ticket feed into fleet board"
      assert html =~ "refuse next_prompt on hook-less panes"
    end

    test "a reported block is warm and lands in the live list" do
      html =
        ticket_board(
          [
            %{
              id: "w1",
              name: "blocked-worker",
              display_name: "blocked-worker",
              agent_state: :blocked,
              agent_state_message: "need unlock",
              issue: 17_070
            }
          ],
          [@iss]
        )
        |> drawer()

      assert html =~ "blocked"
      assert html =~ "text-status-warning-fg"
      assert html =~ "need unlock"
      refute html =~ ~s(id="fleet-capacity")
    end

    test "ready-no-task is slate capacity, with no warm colour anywhere" do
      html =
        ticket_board(
          [
            %{
              id: "w2",
              name: "ready-worker",
              display_name: "ready-worker",
              agent_state: :idle,
              fleet_role: :worker,
              fleet_readiness: :ready_no_task,
              ready_no_task_for_seconds: 300
            }
          ],
          [@iss]
        )
        |> drawer()

      assert html =~ ~s(id="fleet-capacity")
      assert html =~ "ready-worker"
      assert html =~ "ready, no task"
      assert html =~ "5m"
      # An idle worker is not a human lane: nothing on this drawer goes amber.
      refute html =~ "text-status-warning-fg"
      assert html =~ "text-base-content/50"
    end

    test "parked ticket renders with no WHO and does not claim a pane" do
      board =
        FleetBoard.from_window_tabs(
          [
            %{
              id: "w1",
              name: "worker-a",
              display_name: "worker-a",
              agent_state: :working,
              issue: 17_070
            }
          ],
          ticket_feed: TicketFeed.project([@iss]),
          claimed: [%{number: 690, title: "parked work", labels: ["queue/claimed"]}],
          gate_queue: Casein.Ops.GateQueue.unknown()
        )

      html = drawer(board)
      assert html =~ "parked work"
      assert html =~ "parked"
      assert html =~ "no pane"
    end

    test "footer reports the ticket feed as unknown when it has not landed" do
      html = drawer(FleetBoard.empty())
      assert html =~ "tickets unknown"
    end
  end
end
