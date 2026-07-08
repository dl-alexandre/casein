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

      assert [%{workspace_id: "ws-a"}, %{workspace_id: "ws-b"}] = tree
      assert Enum.all?(tree, &(&1.sessions == nil))
      assert Enum.all?(tree, &(&1.flat_session? == false))
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
end