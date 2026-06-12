defmodule DevIdeWeb.Plugs.McpRateLimitTest do
  use DevIdeWeb.ConnCase, async: false

  @token "rate-limit-token"

  setup %{conn: conn} do
    prev_token = Application.get_env(:dev_ide, :api_token)
    prev_limit = Application.get_env(:dev_ide, DevIdeWeb.Plugs.McpRateLimit)

    Application.put_env(:dev_ide, :api_token, @token)
    Application.put_env(:dev_ide, DevIdeWeb.Plugs.McpRateLimit, scale_ms: 60_000, limit: 10)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:dev_ide, :api_token, prev_token),
        else: Application.delete_env(:dev_ide, :api_token)

      if prev_limit,
        do: Application.put_env(:dev_ide, DevIdeWeb.Plugs.McpRateLimit, prev_limit),
        else: Application.delete_env(:dev_ide, DevIdeWeb.Plugs.McpRateLimit)
    end)

    {:ok, conn: conn}
  end

  defp authed(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  test "allows MCP requests under the configured limit", %{conn: conn} do
    for _ <- 1..3 do
      conn =
        conn
        |> authed()
        |> post("/api/terminals/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      assert conn.status != 429
    end
  end

  test "returns 429 when the MCP limit is exceeded", %{conn: conn} do
    Application.put_env(:dev_ide, DevIdeWeb.Plugs.McpRateLimit, scale_ms: 60_000, limit: 2)

    for _ <- 1..2 do
      conn =
        conn
        |> authed()
        |> post("/api/terminals/mcp", %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "ping"
        })

      assert conn.status != 429
    end

    conn =
      build_conn()
      |> authed()
      |> post("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "ping"
      })

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
    assert %{"error" => "rate_limited"} = Jason.decode!(conn.resp_body)
  end
end
