defmodule DevIdeWeb.WorkspaceLive.Show.SessionBarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM

  defp exec_info(execution_id, tmux) do
    SessionInfo.new_execution(execution_id, tmux, workspace_id: "ws-1", loc: :local)
  end

  defp window(attrs) do
    Map.merge(
      %{
        id: "@1",
        index: 0,
        name: "shell",
        active: true,
        current_command: "bash",
        activity: 0,
        pane_list: []
      },
      attrs
    )
  end

  describe "session_tabs/1" do
    test "styles the active tab from active_id without rebuilding tabs" do
      tabs = SessionBarVM.session_tabs([exec_info("ex-1", "tmux-ex-1")])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "exec_ex-1",
          shell_active?: false
        )

      assert html =~ ~s(id="active_sessions-exec_ex-1")
      assert active_tab?(html, "active_sessions-exec_ex-1")
      refute active_shell?(html)

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: "u-someone",
          shell_active?: true
        )

      refute active_tab?(html, "active_sessions-exec_ex-1")
      assert active_shell?(html)
    end

    test "renders kind label, detail, and attach payload attributes" do
      tabs = SessionBarVM.session_tabs([exec_info("ex-2", "tmux-ex-2")])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      assert html =~ "Exec"
      assert html =~ "1"
      assert html =~ ~s(phx-value-session-id="exec_ex-2")
      assert html =~ ~s(phx-value-kind="execution")
      assert html =~ ~s(phx-value-tmux-session="tmux-ex-2")
    end

    test "renders the fixed shell identity when provided" do
      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          active_id: "u-alice-bbbb2222",
          shell_active?: true,
          shell_detail: "bbbb2222",
          shell_title: "Workspace shell u-alice-bbbb2222"
        )

      assert html =~ "bbbb2222"
      assert html =~ ~s(title="Workspace shell u-alice-bbbb2222")
    end

    test "renders visible shell tabs with their tmux session suffixes" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111") |> Map.put(:tmux_session, "tmux-1"),
          SessionInfo.new_shell("ws-1", "u-alice-bbbb2222") |> Map.put(:tmux_session, "tmux-2")
        ])

      assert Enum.map(tabs, &{&1.label, &1.detail}) == [
               {"Shell", "aaaa1111"},
               {"Shell", "bbbb2222"}
             ]
    end

    test "renders visible shell tabs with cwd when available" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111", metadata: %{cwd: "/workspace/apps/web"})
          |> Map.put(:tmux_session, "tmux-1")
        ])

      assert [%{label: "Shell", detail: "apps/web", title: title}] = tabs
      assert title =~ "/workspace/apps/web"
    end
  end

  describe "window_tabs/1" do
    test "renders windows with activity state and hides mutation controls when not allowed" do
      windows =
        SessionBarVM.window_tabs([window(%{}), window(%{id: "@2", index: 1, active: false})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 7,
          mutations_allowed?: false,
          rename_window_id: nil
        )

      assert html =~ ~s(id="tmux-window--1")
      assert html =~ ~s(data-activity-state="idle")
      assert html =~ ~s(data-version="7")
      refute html =~ "tmux:new_window"
      refute html =~ "tmux:rename_start"
      refute html =~ "tmux:kill_window"
      # Refresh stays available regardless of mutation policy.
      assert html =~ "tmux:refresh_windows"
    end

    test "shows mutation controls and the inline rename form when allowed" do
      windows =
        SessionBarVM.window_tabs([window(%{}), window(%{id: "@2", index: 1, active: false})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: windows,
          mutations_allowed?: true,
          rename_window_id: "@1"
        )

      assert html =~ "tmux:new_window"
      assert html =~ ~s(id="tmux-rename-form--1")
      # The window being renamed loses its rename-start button; the other keeps it.
      assert html =~ "tmux:rename_start"
      assert html =~ "tmux:kill_window"
    end

    test "disables kill for the last remaining window" do
      one = SessionBarVM.window_tabs([window(%{})])

      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: one,
          mutations_allowed?: true,
          rename_window_id: nil
        )

      assert html =~ ~s(phx-click="tmux:kill_window")
      assert html =~ "disabled"
    end

    test "renders nothing when there are no windows" do
      html =
        render_component(&SessionBar.window_tabs/1,
          workspace_id: "ws-1",
          windows: [],
          mutations_allowed?: true,
          rename_window_id: nil
        )

      refute html =~ "tmux-window-tabs-ws-1"
    end
  end

  defp active_tab?(html, dom_id) do
    html |> element_class(dom_id) |> String.contains?("border-primary")
  end

  defp active_shell?(html) do
    html |> element_class("terminal-session-shell-ws-1") |> String.contains?("border-primary")
  end

  # Extracts the class attribute of the tag carrying the given DOM id
  # (attributes are rendered in source order, id before class).
  defp element_class(html, dom_id) do
    case Regex.run(~r/id="#{Regex.escape(dom_id)}"[^>]*class="([^"]*)"/s, html) do
      [_, class] -> class
      _ -> ""
    end
  end
end
