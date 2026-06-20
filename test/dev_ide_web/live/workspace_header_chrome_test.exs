defmodule DevIdeWeb.WorkspaceHeaderChromeTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    workspace_id = "hdr-#{unique}"
    workspace_name = "hdr-ws-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "devide-header-live-#{unique}")
    workspace_path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    MemoryAdapter.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/#{workspace_id}/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => workspace_id,
          "name" => workspace_name,
          "user" => "alice",
          "status" => "stopped",
          "type" => "v3",
          "branch" => "master",
          "path" => workspace_path
        })
      )
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)

      if prev_manager,
        do: Application.put_env(:dev_ide, :manager_url, prev_manager),
        else: Application.delete_env(:dev_ide, :manager_url)

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
    {:ok, _view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ "workspace-main-header"
    assert html =~ workspace_name
    # Identity text (name, status, branch) clips horizontally inside its own
    # cluster, but the header itself stays overflow-visible so session/window
    # pickers keep their rounded chip shape and dropdown panels (absolute;
    # top: 100%) are not clipped — see commit 3e0a9b6.
    assert html =~ "header-identity-cluster"

    assert html =~
             ~s(class="header-identity-cluster flex min-w-0 flex-1 items-center gap-1 overflow-x-clip)

    refute html =~
             ~s(class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 overflow-x-clip)

    assert html =~ "header-terminal-pickers"
    assert html =~ "header-p-touch-show"
    assert html =~ ~s(id="session-dropdown-#{workspace_id}")
    assert html =~ ~s(id="window-dropdown-#{workspace_id}")
    assert html =~ "header-overflow"
    refute html =~ "mobile-session-picker"
    refute html =~ "mobile-window-picker"
  end

  test "mobile key bar includes palette and mode chip sheet trigger", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    assert html =~ ~s(id="mobile-key-bar-#{workspace_id}")
    assert html =~ ~s(id="mobile-key-bar-mode-#{workspace_id}")
    assert html =~ ~s(data-keybar-key="Palette")
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
    # Rows are navigable tree items (at minimum the shell row is present).
    assert html =~ "data-picker-item"
    assert html =~ ~s(data-picker-section="sessions")

    # Toggling the chip defaults focus back to the sessions section.
    view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(data-mobile-nav-focus="sessions")
  end
end
