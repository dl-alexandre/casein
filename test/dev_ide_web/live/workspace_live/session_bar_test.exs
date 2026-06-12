defmodule DevIdeWeb.WorkspaceLive.Show.SessionBarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM
  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

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
      assert html =~ "workspace"
      assert html =~ ~s(title="Workspace shell u-alice-bbbb2222")
    end

    test "shell button label uses cwd and detail keeps sid suffix" do
      panes = [%{active: true, current_path: "/data/workspaces/dalexandre/dev_ide"}]

      assert TerminalChrome.shell_button_label("u-alice-aaaa1111", "u-alice-aaaa1111", panes) ==
               "dalexandre/dev_ide"

      assert TerminalChrome.shell_button_detail("u-alice-aaaa1111", "u-alice-aaaa1111", panes) ==
               "aaaa1111"
    end

    test "raw terminal session label avoids repeating the full tmux session" do
      assert TerminalChrome.terminal_session_label(
               "devide_dalexandre-integration_u-dalexandre-cj0e9ycd",
               "u-dalexandre-cj0e9ycd"
             ) == "cj0e9ycd"

      assert TerminalChrome.terminal_session_label(
               "devide_workspace_with_underscores_u-alice-abcd1234"
             ) == "abcd1234"
    end

    test "renders visible shell tabs with their tmux session suffixes" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111") |> Map.put(:tmux_session, "tmux-1"),
          SessionInfo.new_shell("ws-1", "u-alice-bbbb2222") |> Map.put(:tmux_session, "tmux-2")
        ])

      assert Enum.map(tabs, &{&1.label, &1.detail}) == [
               {"workspace", "aaaa1111"},
               {"workspace", "bbbb2222"}
             ]
    end

    test "renders visible shell tabs with cwd when available" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111",
            metadata: %{cwd: "/workspace/apps/web"}
          )
          |> Map.put(:tmux_session, "tmux-1")
        ])

      assert [%{label: "apps/web", detail: "aaaa1111", title: title}] = tabs
      assert title =~ "/workspace/apps/web"
    end

    test "renders git worktree context for shell tabs" do
      tabs =
        SessionBarVM.session_tabs([
          SessionInfo.new_shell("ws-1", "u-alice-aaaa1111",
            metadata: %{
              cwd: "/tmp/opencode/repo/apps/web",
              git_toplevel: "/tmp/opencode/repo",
              git_branch: "feature-test",
              agent: "opencode"
            }
          )
          |> Map.put(:tmux_session, "tmux-1")
        ])

      assert [
               %{
                 label: "repo/apps/web",
                 detail: "feature-test · opencode · aaaa1111",
                 title: title
               }
             ] = tabs

      assert title =~ "feature-test"
      assert title =~ "opencode"
    end

    test "renders other owned workspace sessions as navigation tabs" do
      workspace_tabs =
        SessionBarVM.workspace_session_tabs(
          [
            %{
              id: "ws-1",
              name: "alpha",
              path_label: "alice/alpha",
              sessions: [%{id: "u-alice", kind: :shell, href: "/workspaces/ws-1?session=u-alice"}]
            },
            %{
              id: "ws-2",
              name: "beta",
              path_label: "alice/beta",
              sessions: [
                %{
                  id: "u-alice-other",
                  kind: :shell,
                  label: "apps/web",
                  title: "Shell /workspace/apps/web",
                  href: "/workspaces/ws-2?session=u-alice-other"
                }
              ]
            }
          ],
          "ws-1"
        )

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          workspace_tabs: workspace_tabs,
          active_id: nil,
          shell_active?: true
        )

      refute html =~ ~s(href="/workspaces/ws-1?session=u-alice")
      assert html =~ ~s(id="workspace_sessions-ws-2-u-alice-other")
      assert html =~ ~s(href="/workspaces/ws-2?session=u-alice-other")
      assert html =~ "apps/web"
      assert html =~ "alice/beta"
    end

    test "renders orphan tmux inventory tabs without navigation" do
      workspace_tabs =
        SessionBarVM.tmux_inventory_tabs([
          %{
            id: "tmux:devide_ws-adapter_sid-adapter",
            kind: :shell,
            label: "ws-adapter",
            detail: "sid-adapter",
            title: "devide_ws-adapter_sid-adapter"
          }
        ])

      html =
        render_component(&SessionBar.session_tabs/1,
          workspace_id: "ws-1",
          tabs: [],
          workspace_tabs: workspace_tabs,
          active_id: nil,
          shell_active?: true
        )

      assert html =~ ~s(id="workspace_sessions-tmux-devide_ws-adapter_sid-adapter")
      assert html =~ ~s(disabled)
      refute html =~ ~s(href="#")
      assert html =~ "ws-adapter"
      assert html =~ "sid-adapter"
    end
  end

  describe "session_dropdown/1" do
    test "shows a window count and expandable window rows for tmux-backed tabs" do
      info =
        "ex-9"
        |> exec_info("tmux-ex-9")
        |> Map.put(:metadata, %{
          windows: [
            %{id: "@1", index: 1, name: "logs", active: true},
            %{id: "@0", index: 0, name: "build", active: false}
          ]
        })

      assert [%{window_count: 2, windows: [%{name: "build"}, %{name: "logs", active?: true}]}] =
               tabs = SessionBarVM.session_tabs([info])

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      assert html =~ ~s(title="2 windows")
      assert html =~ ~s(id="session-windows-active_sessions-exec_ex-9")
      assert html =~ ~s(phx-value-window-id="@0")
      assert html =~ ~s(phx-value-window-id="@1")
      assert html =~ "build"
      assert html =~ "logs"
    end

    test "marks sessions and windows with activity dots from window_activity metadata" do
      now = DateTime.utc_now() |> DateTime.to_unix()

      info =
        "ex-9"
        |> exec_info("tmux-ex-9")
        |> Map.put(:metadata, %{
          windows: [
            %{id: "@1", index: 1, name: "logs", active: true},
            %{id: "@0", index: 0, name: "build", active: false}
          ],
          window_activity: %{"@0" => now, "@1" => now - 3_600}
        })

      assert [tab] = tabs = SessionBarVM.session_tabs([info])

      # The session row inherits the freshest window state.
      assert tab.activity_state == :fresh

      assert [%{id: "@0", activity_state: :fresh}, %{id: "@1", activity_state: :idle}] =
               tab.windows

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      assert html =~ ~s(id="session-activity-active_sessions-exec_ex-9")
      assert html =~ ~s(data-activity-state="fresh")
    end

    test "marks quiet agent windows and badges the trigger and session row" do
      info =
        "ex-9"
        |> exec_info("tmux-ex-9")
        |> Map.put(:metadata, %{
          windows: [
            %{id: "@1", index: 1, name: "agent", active: false, quiet: true},
            %{id: "@0", index: 0, name: "build", active: true, quiet: false}
          ]
        })

      assert [tab] = tabs = SessionBarVM.session_tabs([info])
      assert tab.quiet_count == 1
      assert [%{quiet?: false}, %{id: "@1", quiet?: true}] = tab.windows

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      # Trigger badge, session-row dot, and the window-row dot all render.
      assert html =~ ~s(id="session-quiet-badge-ws-1")
      assert html =~ ~s(id="session-quiet-active_sessions-exec_ex-9")
      assert html =~ ~s(data-quiet="true")
      assert html =~ "1 quiet agent window"
      # Quiet supersedes the activity dot on the session row.
      refute html =~ ~s(id="session-activity-active_sessions-exec_ex-9")
    end

    test "omits activity dots when windows are idle" do
      info =
        "ex-9"
        |> exec_info("tmux-ex-9")
        |> Map.put(:metadata, %{
          windows: [%{id: "@1", index: 1, name: "logs", active: true}],
          window_activity: %{"@1" => 0}
        })

      assert [%{activity_state: :idle}] = tabs = SessionBarVM.session_tabs([info])

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      refute html =~ "session-activity-"
    end

    test "omits the window toggle when a session has no window metadata" do
      tabs = SessionBarVM.session_tabs([exec_info("ex-1", "tmux-ex-1")])
      assert [%{window_count: 0, windows: []}] = tabs

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      refute html =~ "session-windows-"
    end

    test "marks the attached entry with data-picker-active so the picker selection starts there" do
      tabs = SessionBarVM.session_tabs([exec_info("ex-1", "tmux-ex-1")])
      [%{id: tab_id}] = tabs

      html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: tab_id,
          shell_active?: false
        )

      active = html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-picker-active]")
      assert Enum.count(active) == 1
      assert LazyHTML.attribute(active, "phx-value-session-id") == [tab_id]

      # The shell entry takes over the selection when it is the attached tab.
      shell_html =
        render_component(&SessionBar.session_dropdown/1,
          workspace_id: "ws-1",
          tabs: tabs,
          active_id: nil,
          shell_active?: true
        )

      shell = shell_html |> LazyHTML.from_fragment() |> LazyHTML.query("[data-picker-active]")
      assert Enum.count(shell) == 1
      assert LazyHTML.attribute(shell, "id") == ["terminal-session-shell-ws-1"]
    end
  end

  describe "window_dropdown/1" do
    test "renders choose-tree picker entries with the active window selected" do
      windows =
        SessionBarVM.window_tabs([window(%{}), window(%{id: "@2", index: 1, active: false})])

      html =
        render_component(&SessionBar.window_dropdown/1,
          workspace_id: "ws-1",
          windows: windows,
          topology_version: 1,
          mutations_allowed?: true,
          rename_window_id: nil
        )

      assert html =~ ~s(phx-hook="SessionPicker")

      document = LazyHTML.from_fragment(html)

      # Every window select button is a picker entry; mutation/refresh
      # buttons are not, so hold-to-navigate can never land on them.
      items = LazyHTML.query(document, "[data-picker-item]")
      assert Enum.count(items) == 2
      assert items |> LazyHTML.attribute("phx-value-window-id") |> Enum.sort() == ["@1", "@2"]

      active = LazyHTML.query(document, "[data-picker-active]")
      assert Enum.count(active) == 1
      assert LazyHTML.attribute(active, "phx-value-window-id") == ["@1"]

      kill_items = LazyHTML.query(document, ~s([phx-click*="kill_window"][data-picker-item]))
      assert Enum.empty?(kill_items)

      # ← menu hop target and the type-to-filter readout line.
      assert html =~ ~s(data-picker-hop-left="#session-dropdown-ws-1")
      assert Enum.count(LazyHTML.query(document, "[data-picker-filter]")) == 1
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
