defmodule DevIdeWeb.API.PreviewMCPControllerTest do
  @moduledoc """
  HTTP transport + auth tests for POST /api/preview/mcp.
  """
  use DevIdeWeb.ConnCase, async: false

  @token "test-preview-mcp-token"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)
    on_exit(fn -> restore(:api_token, prev) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

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

  test "notifications get a 202 with no JSON-RPC body", %{conn: conn} do
    conn = post_mcp(conn, %{jsonrpc: "2.0", method: "notifications/initialized"})
    assert conn.status == 202
    assert conn.resp_body == ""
  end

  test "GET is not allowed", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @token)
      |> get("/api/preview/mcp")

    assert conn.status == 405
  end
end
