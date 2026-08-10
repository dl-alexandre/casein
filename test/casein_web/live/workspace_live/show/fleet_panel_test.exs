defmodule CaseinWeb.WorkspaceLive.Show.FleetPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.OrphanedClaims
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
    assert html =~ ~s(id="fleet-orphan-690")
    assert html =~ "stale lease"
    assert html =~ "no pane"
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
end
