defmodule DevIdeWeb.PageControllerTest do
  use DevIdeWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn, 302) == ~p"/workspaces"
  end
end
