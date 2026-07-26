defmodule CaseinWeb.WorkspaceLive.Show.TerminalPanelTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest

  alias Casein.Terminals.Session.Info, as: SessionInfo
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM
  alias CaseinWeb.WorkspaceLive.Show.TerminalPanel

  defp shell_tab(sid, metadata) do
    SessionBarVM.session_tab(SessionInfo.new_shell("ws1", sid, metadata: metadata))
  end

  describe "mobile_nav_sheet/1 workspace scoping" do
    test "labels the current workspace and lists other workspaces from the sidebar tree" do
      home =
        shell_tab("shell-home", %{
          cwd: "/home/casein",
          git_toplevel: "/home/casein",
          git_branch: "master"
        })

      worktree =
        shell_tab("shell-abc", %{
          cwd: "/wt/fx",
          git_toplevel: "/wt/fx",
          git_common_dir: "/home/casein/.git",
          git_branch: "agent/fix-nav",
          git_worktree?: true
        })

      summaries = [
        %{id: "ws1", name: "casein", session_count: 2, sessions: []},
        %{
          id: "ws2",
          name: "reports",
          session_count: 3,
          branch: "main",
          sessions: [
            %{id: "sr1", kind: :shell, href: "/reports/a"},
            %{id: "sr2", kind: :shell, href: "/reports/b"}
          ]
        }
      ]

      tree =
        SessionBarVM.workspace_session_tree(summaries, "ws1",
          current_session_tabs: [home, worktree]
        )

      html =
        render_component(&TerminalPanel.mobile_nav_sheet/1, %{
          mobile_nav_open: true,
          workspace: %{id: "ws1", name: "casein"},
          workspace_route: "/casein",
          mobile_nav_focus: nil,
          mobile_nav_view: "sessions",
          session_tabs: [home, worktree],
          sessions_sidebar_tree: tree,
          terminal_sid: "shell-abc",
          default_terminal_sid: "shell-home",
          shell_button_label: "casein",
          shell_button_detail: ""
        })

      # Scoping is explicit: the current workspace is named, others are grouped.
      assert html =~ "this workspace"
      assert html =~ "Other workspaces"
      assert html =~ "reports"

      # The worktree row surfaces the parent repo it descends from.
      assert html =~ "casein⑂"
      assert html =~ "fix-nav"

      # Rows are single-line, and the default branch stays out of the way.
      assert html =~ "flex-row"
      refute html =~ ~s(>master<)
    end

    test "no Other-workspaces group when the tree has only the current workspace" do
      home = shell_tab("shell-home", %{cwd: "/home/casein", git_toplevel: "/home/casein"})
      summaries = [%{id: "ws1", name: "casein", session_count: 1, sessions: []}]
      tree = SessionBarVM.workspace_session_tree(summaries, "ws1", current_session_tabs: [home])

      html =
        render_component(&TerminalPanel.mobile_nav_sheet/1, %{
          mobile_nav_open: true,
          workspace: %{id: "ws1", name: "casein"},
          workspace_route: "/casein",
          mobile_nav_focus: nil,
          mobile_nav_view: "sessions",
          session_tabs: [home],
          sessions_sidebar_tree: tree,
          terminal_sid: "shell-home",
          default_terminal_sid: "shell-home",
          shell_button_label: "casein",
          shell_button_detail: ""
        })

      refute html =~ "Other workspaces"
    end
  end
end
