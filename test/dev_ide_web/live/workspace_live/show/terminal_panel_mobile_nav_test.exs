defmodule DevIdeWeb.WorkspaceLive.Show.TerminalPanelMobileNavTest do
  # The mobile nav sheet previously listed only the CURRENT workspace's
  # sessions; these lock in the "Other workspaces" section that brings the
  # desktop rail's cross-workspace reach to touch layouts.
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIdeWeb.WorkspaceLive.Show.TerminalPanel

  defp other_node(attrs) do
    Map.merge(
      %{
        kind: nil,
        group: :other,
        workspace_id: "ws-other",
        dom_id: "sidebar-ws-other",
        label: "Reports",
        detail: "main",
        title: "Reports · main",
        live?: true,
        session_count: 2,
        expanded?: false,
        flat_session?: false,
        session: nil,
        sessions: nil
      },
      attrs
    )
  end

  defp render_sheet(tree) do
    render_component(&TerminalPanel.mobile_nav_sheet/1, %{
      workspace: %{id: "ws-current"},
      workspace_route: "/workspaces/ws-current",
      mobile_nav_open: true,
      mobile_nav_view: "sessions",
      mobile_nav_focus: "sessions",
      session_tabs: [],
      terminal_sid: nil,
      default_terminal_sid: "shell-sid",
      shell_button_label: "Shell",
      shell_button_detail: "",
      sessions_sidebar_tree: tree
    })
  end

  test "renders an Other workspaces section for :other tree nodes" do
    html = render_sheet([other_node(%{})])

    assert html =~ "Other workspaces"
    assert html =~ "This workspace"
    assert html =~ "Reports"
    # Collapsed workspace toggles via the shared sidebar event (lazy-loads).
    assert html =~ ~s(phx-click="sidebar:toggle_workspace")
    assert html =~ ~s(phx-value-workspace-id="ws-other")
  end

  test "expanded :other node navigates its session rows cross-workspace" do
    session = %{
      id: "sess-1",
      label: "claude",
      title: "claude agent",
      href: "/workspaces/ws-other?session=sess-1"
    }

    html = render_sheet([other_node(%{expanded?: true, sessions: [session]})])

    assert html =~ "claude"
    # Tapping the session navigates into the other workspace (LiveView redirect).
    assert html =~ ~s(href="/workspaces/ws-other?session=sess-1")
    assert html =~ ~s(data-phx-link="redirect")
  end

  test "omits the Other workspaces header when only the current workspace exists" do
    # Browse-tier and :this nodes must not surface as 'other'.
    tree = [
      %{kind: :browse_root, group: :other, dom_id: "browse"},
      other_node(%{group: :this, workspace_id: "ws-current"})
    ]

    html = render_sheet(tree)

    refute html =~ "Other workspaces"
    assert html =~ "Sessions &amp; windows"
  end
end
