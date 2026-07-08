defmodule DevIdeWeb.WorkspaceLive.Show.SessionBarVMTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM

  defp shell_info(sid) do
    SessionInfo.new_shell("ws-a", sid, metadata: %{})
  end

  describe "workspace_session_tree/4" do
    test "orders current workspace first and keeps collapsed rows session-free" do
      summaries = [
        %{id: "ws-b", name: "beta", session_count: 2, live?: true, sessions: [%{id: "s1"}]},
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: [%{id: "s0"}]}
      ]

      current_tabs = SessionBarVM.session_tabs([shell_info("shell-1")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(),
          current_session_tabs: current_tabs,
          sidebar_ws_sessions: %{}
        )

      assert [%{workspace_id: "ws-a", flat_session?: true}, %{workspace_id: "ws-b"}] = tree
      assert Enum.all?(tree, &(&1.sessions == nil))
      refute Enum.all?(tree, &(&1.flat_session? == false))
    end

    test "expands current workspace with live session tabs" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 2, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("shell-1"), shell_info("shell-2")])

      [node] =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-a"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      assert node.expanded?
      refute node.flat_session?
      assert length(node.sessions) == 2
      assert Enum.all?(node.sessions, &(&1.workspace_id == "ws-a"))
    end

    test "collapses a single-session workspace to one flat row" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []}
      ]

      tabs = SessionBarVM.session_tabs([shell_info("only")])

      [node] =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-a"]),
          current_session_tabs: tabs,
          sidebar_ws_sessions: %{}
        )

      assert node.flat_session?
      refute node.expanded?
      assert %{id: "only"} = node.session
      assert node.sessions == nil
    end

    test "uses lazily loaded sidebar sessions for other workspaces" do
      summaries = [
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true, sessions: []},
        %{id: "ws-b", name: "beta", session_count: 1, live?: true, sessions: []}
      ]

      other_tabs = SessionBarVM.session_tabs([shell_info("remote-shell")])

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws-a",
          expanded_workspaces: MapSet.new(["ws-b"]),
          current_session_tabs: [],
          sidebar_ws_sessions: %{"ws-b" => other_tabs}
        )

      other = Enum.find(tree, &(&1.workspace_id == "ws-b"))
      assert other.flat_session?
      assert other.session.id == "remote-shell"
    end
  end

  describe "window_tree/2" do
    defp pane(id, attrs \\ []) do
      Map.merge(
        %{
          id: id,
          dom_frag: String.trim_leading(id, "%"),
          index: 0,
          label: "pane",
          detail: "",
          title: id,
          active?: false,
          preview?: false,
          activity_state: :idle,
          activity_class: "",
          activity_label: ""
        },
        Map.new(attrs)
      )
    end

    defp window_tab(attrs) when is_map(attrs) do
      panes = Map.get(attrs, :panes, [])

      base = %{
        id: "@1",
        dom_frag: "1",
        index: 0,
        name: "main",
        display_name: "main",
        active?: true,
        attention: "none",
        activity_state: :idle,
        activity_class: "",
        activity_label: "",
        command: nil,
        full_title: "main",
        panes: panes,
        pane_count: length(panes)
      }

      Map.merge(base, Map.drop(attrs, [:panes]))
    end

    test "keeps single-pane windows flat with no pane children" do
      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: [pane("%1")]})],
          expanded_windows: MapSet.new(["@1"])
        )

      assert node.flat_window?
      refute node.expanded?
      assert node.pane.id == "%1"
      assert node.panes == nil
    end

    test "expands multi-pane windows when listed in expanded_windows" do
      panes = [pane("%1"), pane("%2", index: 1)]

      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: panes, pane_count: 2})],
          expanded_windows: MapSet.new(["@1"])
        )

      refute node.flat_window?
      assert node.expanded?
      assert length(node.panes) == 2
      assert node.pane == nil
    end

    test "collapses multi-pane windows when not expanded but keeps panes in tree data" do
      panes = [pane("%1"), pane("%2", index: 1)]

      [node] =
        SessionBarVM.window_tree(
          [window_tab(%{panes: panes, pane_count: 2})],
          expanded_windows: MapSet.new()
        )

      refute node.flat_window?
      refute node.expanded?
      assert length(node.panes) == 2
      assert node.pane_count == 2
    end
  end

  describe "sidebar sort helpers" do
    test "cycle_sort_mode rotates recency → name → liveness" do
      assert SessionBarVM.cycle_sort_mode(:recency) == :name
      assert SessionBarVM.cycle_sort_mode(:name) == :liveness
      assert SessionBarVM.cycle_sort_mode(:liveness) == :recency
    end

    test "sort_workspace_summaries_for_sidebar pins current workspace first" do
      summaries = [
        %{id: "ws-b", name: "beta", session_count: 1, live?: false},
        %{id: "ws-a", name: "alpha", session_count: 1, live?: true}
      ]

      sorted =
        SessionBarVM.sort_workspace_summaries_for_sidebar(summaries, :name, "ws-b")

      assert [%{id: "ws-b"}, %{id: "ws-a"}] = sorted
    end

    test "sort_session_tabs orders by name and liveness" do
      tabs = [
        %{label: "zebra", activity_state: :idle},
        %{label: "alpha", activity_state: :fresh}
      ]

      assert [%{label: "alpha"}, %{label: "zebra"}] =
               SessionBarVM.sort_session_tabs(tabs, :name)

      assert [%{label: "alpha"}, %{label: "zebra"}] =
               SessionBarVM.sort_session_tabs(tabs, :liveness)
    end

    test "sort_window_tree puts active window first in liveness mode" do
      nodes = [
        %{display_name: "idle", name: "idle", active?: false, activity_state: :idle, index: 0},
        %{display_name: "active", name: "active", active?: true, activity_state: :fresh, index: 1}
      ]

      assert [%{active?: true}, %{active?: false}] =
               SessionBarVM.sort_window_tree(nodes, :liveness)
    end
  end
end
