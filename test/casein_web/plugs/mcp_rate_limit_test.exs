defmodule CaseinWeb.Plugs.McpRateLimitTest do
  use CaseinWeb.ConnCase, async: false

  @token "rate-limit-token"
  @workspace_token "rate-limit-workspace-token"

  setup %{conn: conn} do
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_limit = Application.get_env(:casein, CaseinWeb.Plugs.McpRateLimit)

    Application.put_env(:casein, :api_token, @token)
    Application.put_env(:casein, CaseinWeb.Plugs.McpRateLimit, scale_ms: 60_000, limit: 10)

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:casein, :api_token, prev_token),
        else: Application.delete_env(:casein, :api_token)

      if prev_workspace_tokens,
        do: Application.put_env(:casein, :workspace_api_tokens, prev_workspace_tokens),
        else: Application.delete_env(:casein, :workspace_api_tokens)

      if prev_limit,
        do: Application.put_env(:casein, CaseinWeb.Plugs.McpRateLimit, prev_limit),
        else: Application.delete_env(:casein, CaseinWeb.Plugs.McpRateLimit)
    end)

    {:ok, conn: conn}
  end

  defp authed(conn), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @token)

  defp workspace_authed(conn),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> @workspace_token)

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
    Application.put_env(:casein, CaseinWeb.Plugs.McpRateLimit, scale_ms: 60_000, limit: 2)

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

  test "keys tool calls by tool and workspace" do
    Application.put_env(:casein, CaseinWeb.Plugs.McpRateLimit, scale_ms: 60_000, limit: 1)
    Application.put_env(:casein, :workspace_api_tokens, %{@workspace_token => "alpha"})

    first =
      build_conn()
      |> workspace_authed()
      |> post("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "terminal_list_sessions",
          "arguments" => %{"workspace_id" => "alpha"}
        }
      })

    assert first.status != 429

    same_bucket =
      build_conn()
      |> workspace_authed()
      |> post("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "terminal_list_sessions",
          "arguments" => %{"workspace_id" => "alpha"}
        }
      })

    assert same_bucket.status == 429

    different_workspace =
      build_conn()
      |> workspace_authed()
      |> post("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "terminal_list_sessions",
          "arguments" => %{"workspace_id" => "beta"}
        }
      })

    assert different_workspace.status != 429

    different_tool =
      build_conn()
      |> workspace_authed()
      |> post("/api/terminals/mcp", %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "terminal_topology",
          "arguments" => %{"workspace_id" => "alpha", "session" => "devide_alpha_default"}
        }
      })

    assert different_tool.status != 429
  end
end
