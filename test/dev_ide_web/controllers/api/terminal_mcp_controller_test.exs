defmodule DevIdeWeb.API.TerminalMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/terminals/mcp.
  """
  use DevIdeWeb.ConnCase, async: false

  @token "test-terminal-mcp-token"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    prev_workspace_tokens = Application.get_env(:dev_ide, :workspace_api_tokens)
    Application.put_env(:dev_ide, :api_token, @token)

    on_exit(fn ->
      restore(:api_token, prev)
      restore(:workspace_api_tokens, prev_workspace_tokens)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp post_mcp(conn, body, token),
    do: post_mcp(conn, body, token, "/api/terminals/mcp")

  defp post_mcp(conn, body, token, path) do
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

  test "workspace_id query is advertised in initialize instructions", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        @token,
        "/api/terminals/mcp?workspace_id=ws-query"
      )

    assert %{"result" => %{"instructions" => instructions}} = json_response(conn, 200)
    assert instructions =~ "pre-scoped"
    assert instructions =~ "ws-query"
  end

  test "workspace-scoped token injects its workspace when query is omitted", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        "ws-token"
      )

    assert %{"result" => %{"instructions" => instructions}} = json_response(conn, 200)
    assert instructions =~ "pre-scoped"
    assert instructions =~ "ws-scoped"
  end

  test "workspace-scoped token rejects another workspace query", %{conn: conn} do
    Application.put_env(:dev_ide, :workspace_api_tokens, %{"ws-token" => "ws-scoped"})

    conn =
      post_mcp(
        conn,
        %{jsonrpc: "2.0", id: 1, method: "initialize"},
        "ws-token",
        "/api/terminals/mcp?workspace_id=ws-other"
      )

    assert json_response(conn, 403) == %{"error" => "workspace_forbidden"}
  end

  test "global token reaches a different query but handler rejects body override", %{conn: conn} do
    conn =
      post_mcp(
        conn,
        %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{
            name: "terminal_list_sessions",
            arguments: %{workspace_id: "ws-other"}
          }
        },
        @token,
        "/api/terminals/mcp?workspace_id=ws-query"
      )

    assert %{
             "result" => %{
               "isError" => true,
               "structuredContent" => %{"error" => "workspace_scope_mismatch"}
             }
           } = json_response(conn, 200)
  end

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end
end
