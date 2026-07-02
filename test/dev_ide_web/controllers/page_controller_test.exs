defmodule DevIdeWeb.PageControllerTest do
  use DevIdeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces"
  end

  test "GET / redirects to default workspace in LAN direct mode", %{conn: conn} do
    prev_lan = Application.get_env(:dev_ide, :lan_mode)
    prev_direct = Application.get_env(:dev_ide, :lan_direct_mode)
    prev_default = Application.get_env(:dev_ide, :default_workspace)

    on_exit(fn ->
      restore_env(:lan_mode, prev_lan)
      restore_env(:lan_direct_mode, prev_direct)
      restore_env(:default_workspace, prev_default)
    end)

    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_direct_mode, true)
    Application.put_env(:dev_ide, :default_workspace, "alpha")

    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces/alpha"
  end

  test "GET / defaults to home in LAN direct mode", %{conn: conn} do
    prev_lan = Application.get_env(:dev_ide, :lan_mode)
    prev_direct = Application.get_env(:dev_ide, :lan_direct_mode)
    prev_default = Application.get_env(:dev_ide, :default_workspace)

    on_exit(fn ->
      restore_env(:lan_mode, prev_lan)
      restore_env(:lan_direct_mode, prev_direct)
      restore_env(:default_workspace, prev_default)
    end)

    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_direct_mode, true)
    Application.put_env(:dev_ide, :default_workspace, "home")

    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces/home"
  end

  test "GET / ignores LAN direct mode without a default workspace", %{conn: conn} do
    prev_lan = Application.get_env(:dev_ide, :lan_mode)
    prev_direct = Application.get_env(:dev_ide, :lan_direct_mode)
    prev_default = Application.get_env(:dev_ide, :default_workspace)

    on_exit(fn ->
      restore_env(:lan_mode, prev_lan)
      restore_env(:lan_direct_mode, prev_direct)
      restore_env(:default_workspace, prev_default)
    end)

    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_direct_mode, true)
    Application.delete_env(:dev_ide, :default_workspace)

    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces"
  end

  test "GET / ignores direct mode when LAN mode is disabled", %{conn: conn} do
    prev_lan = Application.get_env(:dev_ide, :lan_mode)
    prev_direct = Application.get_env(:dev_ide, :lan_direct_mode)
    prev_default = Application.get_env(:dev_ide, :default_workspace)

    on_exit(fn ->
      restore_env(:lan_mode, prev_lan)
      restore_env(:lan_direct_mode, prev_direct)
      restore_env(:default_workspace, prev_default)
    end)

    Application.put_env(:dev_ide, :lan_mode, false)
    Application.put_env(:dev_ide, :lan_direct_mode, true)
    Application.put_env(:dev_ide, :default_workspace, "alpha")

    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces"
  end

  defp restore_env(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore_env(key, value), do: Application.put_env(:dev_ide, key, value)
end
