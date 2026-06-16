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

    html = view |> element(~s(#mobile-key-bar-mode-#{workspace_id})) |> render_click()
    assert html =~ ~s(id="mobile-nav-sheet-#{workspace_id}")
  end
end
