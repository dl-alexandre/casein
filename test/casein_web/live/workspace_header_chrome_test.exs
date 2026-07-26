defmodule CaseinWeb.WorkspaceHeaderChromeTest do
  use CaseinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Casein.Audit
  alias Casein.Workspaces.State.MemoryAdapter

  setup do
    unique = System.unique_integer([:positive])
    workspace_id = "hdr-#{unique}"
    workspace_name = "hdr-ws-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "casein-header-live-#{unique}")
    workspace_path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(workspace_path)

    prev_root = Application.get_env(:casein, :workspaces_root)

    Application.put_env(:casein, :workspaces_root, workspace_root)

    MemoryAdapter.clear()
    Audit.clear()

    Req.Test.stub(Casein.Integrations.Manager.Client, fn
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
        do: Application.put_env(:casein, :workspaces_root, prev_root),
        else: Application.delete_env(:casein, :workspaces_root)
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
    # Desktop leader is keyboard-only; the C-b chip lives on the mobile keybar.
    refute html =~ ~s(id="leader-prefix-button-#{workspace_id}")
    assert html =~ ~s(data-leader-prefix-button="true")
    assert html =~ "header-p-touch-show"
    assert html =~ ~s(id="attention-surface-#{workspace_id}")
    # Left session chip opens the sessions rail; admin gear / display zoom /
    # header focus chevron stay gone.
    assert has_element?(view, "#session-header-indicator-#{workspace_id}")

    assert has_element?(
             view,
             "#session-header-indicator-#{workspace_id}[phx-click='sidebar:toggle_sessions']"
           )

    refute html =~ ~s(id="workspace-admin-bell-#{workspace_id}")
    refute html =~ "hero-magnifying-glass-minus"
    refute html =~ "hero-magnifying-glass-plus"
    refute html =~ ">100%<"
    refute html =~ "Hide header for a terminal-only view"
    refute html =~ ~s(id="session-dropdown-#{workspace_id}")
    assert html =~ ~s(id="header-terminal-pickers-#{workspace_id}")
    refute html =~ ~s(id="window-dropdown-#{workspace_id}")
    # The ⋯ menu renders unconditionally — it is the canonical home for
    # secondary window/pane actions, not a responsive spillover bucket.
    assert html =~ "header-overflow"
    assert html =~ ~s(id="header-overflow-#{workspace_id}")
    assert html =~ ~s(phx-hook="HeaderOverflow")
    assert has_element?(view, ".header-overflow button[phx-click='tmux:refresh_windows']")
    # Desktop sizing lives in the ⋯ menu (font + display zoom).
    assert has_element?(view, ~s(.header-overflow button[data-keybar-key="FontUp"]))
    assert has_element?(view, ~s(.header-overflow button[data-keybar-key="FontDown"]))
    assert has_element?(view, ~s(.header-overflow button[data-keybar-key="ZoomUp"]))
    assert has_element?(view, ~s(.header-overflow button[data-keybar-key="ZoomDown"]))
    assert has_element?(view, ~s(.header-overflow button[data-keybar-key="ZoomReset"]))
    # Notifications, command palette, and help now live at the foot of the ⋯
    # menu (the standalone header bell + connect-agent button were folded in —
    # connect now lives in the help overlay's Agents tab).
    refute has_element?(view, "#notifications-bell-#{workspace_id}")
    refute has_element?(view, "#connect-agent-button-#{workspace_id}")
    refute has_element?(view, "#agent-operations-button-#{workspace_id}")
    assert has_element?(view, ".header-overflow button[phx-click='notifications:toggle']")
    assert has_element?(view, ".header-overflow button[phx-click='palette:open']")

    # Template palette/library ids are canonical in the ⋯ menu and must render
    # exactly once (duplicate DOM ids corrupt LiveView patching).
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

    # Split/zoom/swap keep their hidden C-b dispatch targets; the visible % / z
    # highlight controls now live inside the selected window tab (rendered only
    # when a window is active), not the header cluster.
    for action <- ~w(split-right split-down zoom pane-swap-previous pane-swap-next) do
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

  test "window tab bar is default and transient sidebar opens on demand", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ ~s(id="header-terminal-pickers-#{workspace_id}")
    refute html =~ ~s(id="window-dropdown-#{workspace_id}")
    refute html =~ ~s(phx-hook="WindowPickerView")
    refute html =~ ~s(id="window-sidebar-#{workspace_id}")

    assert html =~
             "header-terminal-pickers flex min-w-0 flex-1 items-center pointer-coarse:hidden"

    render_hook(view, "sidebar:open", %{"mode" => "windows"})
    assert :sys.get_state(view.pid).socket.assigns.window_sidebar_open?
    assert :sys.get_state(view.pid).socket.assigns.sidebar_mode == :windows_only

    # Rail DOM is gated on tmux windows; a stopped workspace may have none yet.
    html = render_hook(view, "sidebar:close", %{})
    refute :sys.get_state(view.pid).socket.assigns.window_sidebar_open?
    refute html =~ ~s(id="window-sidebar-#{workspace_id}")
  end

  test "sessions sidebar opens in both-column mode", %{conn: conn, workspace_id: workspace_id} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    render_hook(view, "sidebar:open", %{"mode" => "both"})

    state = :sys.get_state(view.pid).socket.assigns
    assert state.sidebar_mode == :both
    assert state.sessions_sidebar_open?
    assert state.window_sidebar_open?
    assert is_list(state.sessions_sidebar_tree)
    assert MapSet.member?(state.sidebar_expanded_workspaces, workspace_id)
  end

  test "restore_sort applies a client-persisted sort mode per column", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")
    render_hook(view, "sidebar:open", %{"mode" => "both"})

    assigns = fn -> :sys.get_state(view.pid).socket.assigns end
    assert assigns.().sessions_sidebar_sort == :recency
    assert assigns.().windows_sidebar_sort == :recency

    render_hook(view, "sidebar:restore_sort", %{"col" => "sessions", "mode" => "name"})
    assert assigns.().sessions_sidebar_sort == :name

    render_hook(view, "sidebar:restore_sort", %{"col" => "windows", "mode" => "liveness"})
    assert assigns.().windows_sidebar_sort == :liveness

    # Unknown mode falls back to :recency; unknown column is a no-op.
    render_hook(view, "sidebar:restore_sort", %{"col" => "sessions", "mode" => "bogus"})
    assert assigns.().sessions_sidebar_sort == :recency

    render_hook(view, "sidebar:restore_sort", %{"col" => "nope", "mode" => "name"})
    assert assigns.().windows_sidebar_sort == :liveness

    # The chosen order survives a close (persisted, not reset).
    render_hook(view, "sidebar:close", %{})
    assert assigns.().windows_sidebar_sort == :liveness
  end

  test "header session chip toggles the sessions sidebar", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    refute :sys.get_state(view.pid).socket.assigns.sessions_sidebar_open?

    view
    |> element("#session-header-indicator-#{workspace_id}")
    |> render_click()

    state = :sys.get_state(view.pid).socket.assigns
    assert state.sessions_sidebar_open?
    assert state.sidebar_mode == :both

    view
    |> element("#session-header-indicator-#{workspace_id}")
    |> render_click()

    refute :sys.get_state(view.pid).socket.assigns.sessions_sidebar_open?
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

    # The chip shows the active window number in place of the old window icon,
    # while still reading as a session/window switcher rather than a mode badge.
    chip_html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render()
    assert chip_html =~ "data-mobile-window-number"
    refute chip_html =~ "hero-rectangle-stack"
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
    assert html =~ ~s(data-mobile-nav-sheet="true")
    assert html =~ ~s(data-mobile-nav-focus="windows")
    # No tmux windows exist here, so the windows-dominant view falls back to
    # the sessions tree (at minimum the shell row is present).
    assert html =~ ~s(data-mobile-nav-view="sessions")
    refute html =~ "Back to all sessions"
    assert html =~ "data-picker-item"
    assert html =~ ~s(data-picker-section="sessions")

    # Toggling the chip focuses the rendered section: usually the window list
    # once the attached session's windows arrive, otherwise the sessions fallback.
    view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")

    assert [_, focus] = Regex.run(~r/data-mobile-nav-focus="([^"]+)"/, html)
    assert [_, nav_view] = Regex.run(~r/data-mobile-nav-view="([^"]+)"/, html)
    assert focus == nav_view
    assert focus in ~w(sessions windows)
  end

  test "mobile nav sheet is window-dominant with a back arrow to sessions", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    # Give the attached session tmux windows via the same sessions_updated
    # event the SessionDirectory broadcasts. The sheet keys its window list off
    # the *currently attached* terminal_sid, which can switch asynchronously
    # after mount, and a genuine directory broadcast can clobber the injected
    # windows before the click — so re-read the sid and re-inject on each
    # attempt, and only stop once the injected windows actually rendered.
    windows_for = fn sid ->
      Casein.Terminals.Session.Info.new_shell(workspace_id, sid,
        metadata: %{
          windows: [
            %{id: "@1", index: 0, name: "editor", active: true},
            %{id: "@2", index: 1, name: "server", active: false}
          ]
        }
      )
      |> Map.put(:tmux_session, "tmux-#{workspace_id}")
    end

    html =
      Enum.reduce_while(1..10, nil, fn _attempt, _acc ->
        %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)
        sid = assigns[:terminal_sid] || assigns.default_terminal_sid

        send(
          view.pid,
          {Casein.Terminals.SessionDirectory,
           {:sessions_updated, workspace_id, [windows_for.(sid)]}}
        )

        render(view)

        # Opening from the keybar chip lands on the attached session's window list.
        html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()

        if html =~ ~s(data-mobile-nav-view="windows") and html =~ "editor" do
          {:halt, html}
        else
          # Close the sheet again before retrying; the chip toggles.
          view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
          {:cont, html}
        end
      end)

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
