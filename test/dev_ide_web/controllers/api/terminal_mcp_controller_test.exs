defmodule DevIdeWeb.API.TerminalMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/terminals/mcp.
  """
  use DevIdeWeb.ConnCase, async: false

  @token "test-terminal-mcp-token"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)
    on_exit(fn -> restore(:api_token, prev) end)
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

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"}, @token)
    assert conn.status == 202
    assert conn.resp_body == ""
  end
end
