defmodule CaseinWeb.API.PreviewMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/preview/mcp.
  """
  use CaseinWeb.ConnCase, async: false

  @token "test-preview-mcp-token"

  setup do
    prev = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    Application.put_env(:casein, :api_token, @token)

    on_exit(fn ->
      restore(:api_token, prev)
      restore(:workspace_api_tokens, prev_workspace_tokens)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp post_mcp(conn, body, token \\ @token, path \\ "/api/preview/mcp") do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> then(fn c ->
      if token, do: put_req_header(c, "authorization", "Bearer " <> token), else: c
    end)
    |> post(path, body)
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, nil)
    assert conn.status == 401
  end

  test "tools/list returns preview tools with a valid token", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"})

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    assert Enum.any?(tools, &(&1["name"] == "preview_open_app"))
    assert Enum.any?(tools, &(&1["name"] == "preview_close"))
    assert Enum.any?(tools, &(&1["name"] == "preview_reload_iframe"))
    assert Enum.any?(tools, &(&1["name"] == "devide_reload_page"))
  end

  test "workspace_id query scopes preview tool schema", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        @token,
        "/api/preview/mcp?workspace_id=ws-query"
      )

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    open_app = Enum.find(tools, &(&1["name"] == "preview_open_app"))

    refute "workspace_id" in open_app["inputSchema"]["required"]
  end

  test "workspace_id query accepts tmux_session for the same workspace", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        @token,
        "/api/preview/mcp?workspace_id=ws-query&tmux_session=devide_ws-query_wt-agent"
      )

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    open_here = Enum.find(tools, &(&1["name"] == "preview_open_here"))

    refute "tmux_session" in open_here["inputSchema"]["required"]
  end

  test "workspace_id query rejects tmux_session outside workspace scope", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        @token,
        "/api/preview/mcp?workspace_id=ws-query&tmux_session=devide_other-workspace_default"
      )

    assert %{
             "error" => "invalid_tmux_session_scope",
             "workspace_id" => "ws-query",
             "tmux_session" => "devide_other-workspace_default",
             "allowed_prefixes" => prefixes
           } = json_response(conn, 400)

    assert "devide_ws-query_" in prefixes
  end

  test "workspace-scoped token injects its workspace when query is omitted", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn = post_mcp(conn, %{jsonrpc: "2.0", id: 1, method: "tools/list"}, "ws-token")

    assert %{"result" => %{"tools" => tools}} = json_response(conn, 200)
    open_app = Enum.find(tools, &(&1["name"] == "preview_open_app"))

    refute "workspace_id" in open_app["inputSchema"]["required"]
  end

  test "workspace-scoped token rejects query tmux_session outside token workspace", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        "ws-token",
        "/api/preview/mcp?tmux_session=devide_other-workspace_default"
      )

    assert %{
             "error" => "invalid_tmux_session_scope",
             "workspace_id" => "ws-scoped",
             "tmux_session" => "devide_other-workspace_default"
           } = json_response(conn, 400)
  end

  test "workspace-scoped token rejects another workspace query", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "tools/list"},
        "ws-token",
        "/api/preview/mcp?workspace_id=ws-other"
      )

    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "global token cannot call Preview MCP tools", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "preview_surfaces",
            arguments: %{workspace_id: "ws-other"}
          }
        },
        @token,
        "/api/preview/mcp?workspace_id=ws-query"
      )

    assert %{
             "error" => "workspace_scoped_token_required",
             "code" => "workspace_scoped_token_required",
             "error_version" => "mcp-auth-v1",
             "tool" => "preview_surfaces"
           } = json_response(conn, 403)
  end

  test "workspace-scoped token can call Preview MCP tools", %{conn: conn} do
    Application.put_env(:casein, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "preview_surfaces",
            arguments: %{}
          }
        },
        "ws-token"
      )

    assert %{
             "result" => %{
               "isError" => true,
               "structuredContent" => %{"error" => "workspace_not_found"}
             }
           } = json_response(conn, 200)
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"})
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "GET is the Streamable HTTP SSE channel and needs a session id", %{conn: conn} do
    # GET is no longer 405 — it opens the server→client SSE channel, which
    # requires the Mcp-Session-Id issued on initialize. Without one it is a 400.
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/api/preview/mcp")

    assert %{
             "error" => "missing_mcp_session_id",
             "code" => "missing_mcp_session_id",
             "error_version" => "mcp-streamable-http-v1",
             "message" => message
           } = json_response(conn, 400)

    assert message =~ "Mcp-Session-Id"
  end
end
