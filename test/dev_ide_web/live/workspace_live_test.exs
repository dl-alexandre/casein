defmodule DevIdeWeb.WorkspaceLiveTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:dev_ide, :manager_url)
    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :manager_url, prev),
        else: Application.delete_env(:dev_ide, :manager_url)
    end)

    {:ok, bypass: bypass}
  end

  test "lists workspaces from a fake manager", %{conn: conn, bypass: bypass} do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")
    assert html =~ "alpha"
    assert html =~ "running"
  end

  test "shows actionable error when manager is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    {:ok, _view, html} = live(conn, ~p"/workspaces")
    assert html =~ "Manager is not reachable" or html =~ "Transport error"
  end

  test "renders the picker as a host-grouped list with a derived mode badge", %{
    conn: conn,
    bypass: bypass
  } do
    Bypass.expect(bypass, "GET", "/api/workspaces", fn conn ->
      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!([
          %{
            "id" => "abc",
            "name" => "alpha",
            "user" => "alice",
            "status" => "running",
            "type" => "v3",
            "branch" => "main"
          }
        ])
      )
    end)

    {:ok, _view, html} = live(conn, ~p"/workspaces")

    # product.md §9.1 — picker is the first screen.
    assert html =~ "Connect to a workspace"

    # FP-4 / §11 — mode is derived from capabilities. With no remote/fleet
    # signals registered, the synthetic host is local.
    assert html =~ "local"

    # capability chips appear (synthetic local host advertises these)
    assert html =~ "tmux"
    assert html =~ "audit"

    # workspace still renders under its host so previous behavior is preserved.
    assert html =~ "alpha"
    assert html =~ "running"
  end
end
