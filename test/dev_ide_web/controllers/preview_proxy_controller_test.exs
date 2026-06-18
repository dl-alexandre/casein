defmodule DevIdeWeb.PreviewProxyControllerTest do
  use DevIdeWeb.ConnCase, async: true

  # Port validation happens before any workspace/authorization work, so these
  # exercise the route + first guard without touching the workspace source.
  test "rejects a non-numeric port with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/not-a-port/")
    assert response(conn, 400)
  end

  test "rejects an out-of-range port with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/99999/")
    assert response(conn, 400)
  end

  test "rejects port zero with 400", %{conn: conn} do
    conn = get(conn, "/preview-proxy/ws-1/0/")
    assert response(conn, 400)
  end
end
