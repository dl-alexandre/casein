defmodule CaseinWeb.DesktopHealthControllerTest do
  use CaseinWeb.ConnCase, async: false

  alias Casein.Desktop.Status

  test "answers 404 outside the desktop profile", %{conn: conn} do
    conn = get(conn, ~p"/desktop/health")
    assert response(conn, 404)
  end

  describe "desktop profile" do
    setup do
      Application.put_env(:casein, :desktop_mode, true)
      on_exit(fn -> Application.delete_env(:casein, :desktop_mode) end)
      :ok
    end

    test "reports readiness without the status server", %{conn: conn} do
      conn = get(conn, ~p"/desktop/health")

      body = json_response(conn, 200)
      assert body["status"] == "ready"
      assert is_integer(body["uptime_ms"])
    end

    test "mirrors the published runtime.json identity", %{conn: conn} do
      path =
        Path.join(
          System.tmp_dir!(),
          "casein-health-test-#{System.unique_integer([:positive])}/runtime.json"
        )

      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      start_supervised!({Status, port: 4321, path: path})

      conn = get(conn, ~p"/desktop/health")

      body = json_response(conn, 200)
      assert body["status"] == "ready"
      assert body["port"] == 4321
      assert body["base_url"] == "http://127.0.0.1:4321"
      assert is_binary(body["version"])
      assert is_binary(body["revision"])
      assert is_integer(body["uptime_ms"])
      refute Map.has_key?(body, "pid")
    end
  end
end
