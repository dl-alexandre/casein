defmodule DevIdeWeb.WorkspaceHeaderChromeTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Integrations.Manager.Client
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    unique = System.unique_integer([:positive])
    workspace_id = "hdr-#{unique}"
    workspace_name = "hdr-ws-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "devide-header-live-#{unique}")
    workspace_path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:dev_ide, :workspaces_root)

    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    MemoryAdapter.clear()
    Audit.clear()

    Req.Test.stub(DevIDE.Integrations.Manager.Client, fn
      %Plug.Conn{method: "GET", path_info: ["api", "workspaces", ^workspace_id, "status"]} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => workspace_id,
            "name" => workspace_name,
            "user" => "dev",
            "status" => "stopped",
            "type" => "v3",
            "branch" => "master",
            "path" => workspace_path
          })
        )

      conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not_found"}))
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)

      if prev_root,
        do: Application.put_env(:dev_ide, :workspaces_root, prev_root),
        else: Application.delete_env(:dev_ide, :workspaces_root)
    end)

    {:ok, workspace_id: workspace_id, workspace_name: workspace_name}
  end

  test "terminal header uses responsive picker wrapper and overflow menu", %{
    conn: conn,
    workspace_id: workspace_id,
    workspace_name: workspace_name
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ "workspace-main-header"
    assert html =~ workspace_name
    # Identity text (name, status, branch) clips horizontally inside its own
    # cluster, but the header itself stays overflow-visible so session/window
    # pickers keep their rounded chip shape and dropdown panels (absolute;
    # top: 100%) are not clipped — see commit 3e0a9b6.
    assert html =~ "header-identity-cluster"

    assert html =~
             ~s(class="header-identity-cluster flex min-w-24 shrink items-center gap-1 overflow-x-clip)

    refute html =~
             ~s(class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 overflow-x-clip)

    assert html =~ "header-terminal-pickers"
    assert html =~ ~s(id="leader-prefix-button-#{workspace_id}")
    assert html =~ ~s(data-leader-prefix-button="true")
    assert has_element?(view, "#leader-prefix-button-#{workspace_id}", "C-b")
    assert html =~ "header-p-touch-show"
    assert html =~ ~s(id="session-dropdown-#{workspace_id}")
    assert html =~ ~s(id="window-dropdown-#{workspace_id}")
    # The ⋯ menu renders unconditionally — it is the canonical home for
    # secondary window/pane actions, not a responsive spillover bucket.
    assert html =~ "header-overflow"
    assert has_element?(view, ".header-overflow button[phx-click='tmux:refresh_windows']")

    # Template palette/library ids are canonical in the ⋯ menu and must render
    # exactly once (the window_dropdown footer keeps id-less copies; duplicate
    # DOM ids corrupt LiveView patching).
    assert length(String.split(html, ~s(id="tmux-template-palette-#{workspace_id}"))) == 2
    assert length(String.split(html, ~s(id="tmux-template-library-#{workspace_id}"))) == 2

    # Pruned inline chrome: these actions live in the ⋯ menu / C-b keys now.
    refute html =~ "workspace-stop-button"
    refute html =~ "hero-plus-circle"
    refute html =~ "header-terminal-chrome-right"

    # Every pruned control keeps its hidden leader-key dispatch target.
    for action <- ~w(new-window last-window next-window prev-window) do
      assert has_element?(view, "[data-leader-action='#{action}']")
    end

    refute html =~ ~s(id="terminal-mode-raw")
    assert html =~ ">stopped<"
    refute html =~ "Mode: raw"
    refute html =~ "snap all"
    refute html =~ "Snap all panes"
    refute html =~ "mobile-session-picker"
    refute html =~ "mobile-window-picker"
  end

  test "window picker toggles between dropdown and header tab strip", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # Default: compact dropdown, pickers cluster shrinks to yield header space.
    assert html =~ ~s(id="window-dropdown-#{workspace_id}")
    assert html =~ ~s(phx-hook="WindowPickerView")
    assert html =~ ~s(data-view="dropdown")

    # Palette "View: window picker as tabs" dispatches this event.
    html = render_hook(view, "view:set_window_picker", %{"view" => "tabs"})

    refute html =~ ~s(id="window-dropdown-#{workspace_id}")
    assert html =~ ~s(data-view="tabs")
    # The pickers cluster grows to use the free header width in tab view.
    assert html =~
             "header-terminal-pickers flex min-w-0 items-center pointer-coarse:hidden flex-1"

    # Template ids stay unique in tabs view too (canonical copies in ⋯ menu).
    assert length(String.split(html, ~s(id="tmux-template-palette-#{workspace_id}"))) == 2
    assert length(String.split(html, ~s(id="tmux-template-library-#{workspace_id}"))) == 2

    # And back.
    html = render_hook(view, "view:set_window_picker", %{"view" => "dropdown"})
    assert html =~ ~s(id="window-dropdown-#{workspace_id}")
    assert html =~ ~s(data-view="dropdown")

    # Unknown values are ignored, never crash the LiveView.
    html = render_hook(view, "view:set_window_picker", %{"view" => "bogus"})
    assert html =~ ~s(data-view="dropdown")
  end

  test "mobile key bar includes palette and mode chip sheet trigger", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ ~s(id="mobile-key-bar-#{workspace_id}")
    assert html =~ ~s(id="mobile-key-bar-mode-#{workspace_id}")
    assert html =~ ~s(data-keybar-key="Palette")
    assert html =~ ~s(data-keybar-key="ZoomDown")
    assert html =~ ~s(data-keybar-key="ZoomUp")
    assert html =~ ~s(data-keybar-key="ZoomReset")
    assert html =~ "phx-click=\"mobile_nav:toggle\""
    refute html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")

    # The chip must read as a session switcher (icon + "Switch session" label),
    # not a bare mode badge — otherwise sessions are undiscoverable on touch.
    assert html =~ "hero-rectangle-stack"
    assert html =~ "Switch session or window"

    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")
  end

  test "Ctrl+B leader shortcut opens the mobile nav sheet with a focus hint", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # The workspace_leader hook routes C-b s / C-b w here on touch/narrow layouts.
    html = render_hook(view, "mobile_nav:open", %{"focus" => "windows"})

    assert html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")
    # Keyboard-nav hook is mounted and told which section to focus.
    assert html =~ ~s(phx-hook="MobileNavSheet")
    assert html =~ ~s(data-mobile-nav-focus="windows")
    # No tmux windows exist here, so the windows-dominant view falls back to
    # the sessions tree (at minimum the shell row is present).
    assert html =~ ~s(data-mobile-nav-view="sessions")
    refute html =~ "Back to all sessions"
    assert html =~ "data-picker-item"
    assert html =~ ~s(data-picker-section="sessions")

    # Toggling the chip defaults focus back to the sessions section.
    view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(data-mobile-nav-focus="sessions")
  end

  test "mobile nav sheet is window-dominant with a back arrow to sessions", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # Give the attached (default shell) session tmux windows via the same
    # sessions_updated event the SessionDirectory broadcasts.
    %{socket: %{assigns: %{default_terminal_sid: sid}}} = :sys.get_state(view.pid)

    info =
      DevIDE.Terminals.Session.Info.new_shell(workspace_id, sid,
        metadata: %{
          windows: [
            %{id: "@1", index: 0, name: "editor", active: true},
            %{id: "@2", index: 1, name: "server", active: false}
          ]
        }
      )
      |> Map.put(:tmux_session, "tmux-#{workspace_id}")

    send(view.pid, {DevIDE.Terminals.SessionDirectory, {:sessions_updated, workspace_id, [info]}})
    render(view)

    # Opening from the keybar chip lands on the attached session's window list.
    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(data-mobile-nav-view="windows")
    assert html =~ ~s(data-mobile-nav-focus="windows")
    assert html =~ "Back to all sessions"
    assert html =~ ~s(data-picker-section="windows")
    assert html =~ "editor"
    assert html =~ "server"
    # The sessions tree is not rendered in the windows view.
    refute html =~ ~s(data-picker-section="sessions")

    # The back arrow hops out to the sessions tree without closing the sheet.
    html = render_hook(view, "mobile_nav:set_view", %{"view" => "sessions"})
    assert html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")
    assert html =~ ~s(data-mobile-nav-view="sessions")
    assert html =~ ~s(data-picker-section="sessions")
    refute html =~ "Back to all sessions"

    # And forward again into the window list.
    html = render_hook(view, "mobile_nav:set_view", %{"view" => "windows"})
    assert html =~ ~s(data-mobile-nav-view="windows")
    assert html =~ "Back to all sessions"
  end
end
