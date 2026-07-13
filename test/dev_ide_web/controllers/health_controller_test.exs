defmodule DevIdeWeb.HealthControllerTest do
  use DevIdeWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:dev_ide, :readiness_opts)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:dev_ide, :readiness_opts)
      else
        Application.put_env(:dev_ide, :readiness_opts, previous)
      end
    end)

    :ok
  end

  test "GET /healthz is unauthenticated and database-aware", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert json_response(conn, 200) == %{
             "ok" => true,
             "checks" => %{"database" => "ready"}
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /healthz returns a minimal 503 when the database is unavailable", %{conn: conn} do
    Application.put_env(:dev_ide, :readiness_opts, query: fn -> {:error, :secret_reason} end)

    conn = get(conn, "/healthz")

    assert json_response(conn, 503) == %{
             "ok" => false,
             "checks" => %{"database" => "unavailable"}
           }

    refute conn.resp_body =~ "secret_reason"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "GET /healthz ignores non-JSON Accept headers", %{conn: conn} do
    conn = conn |> put_req_header("accept", "text/plain") |> get("/healthz")

    assert json_response(conn, 200)["ok"]
  end
end
