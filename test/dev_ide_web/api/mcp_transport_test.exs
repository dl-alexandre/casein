defmodule CaseinWeb.API.MCPTransportTest do
  @moduledoc """
  Streamable HTTP transport over the terminal MCP endpoint: initialize issues an
  Mcp-Session-Id, unknown ids are rejected, DELETE tears the session down, and a
  GET opens (and attaches) the server→client SSE channel.
  """
  use CaseinWeb.ConnCase, async: false

  alias Casein.Agents.MCPSessions

  @token "test-mcp-transport-token"
  @path "/api/terminals/mcp"

  setup do
    prev = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, :api_token, prev),
        else: Application.delete_env(:dev_ide, :api_token)
    end)

    :ok
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp initialize(conn) do
    conn
    |> auth()
    |> put_req_header("content-type", "application/json")
    |> post(@path, %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}})
  end

  test "initialize issues an Mcp-Session-Id and registers the session", %{conn: conn} do
    conn = initialize(conn)
    assert json_response(conn, 200)

    assert [session_id] = get_resp_header(conn, "mcp-session-id")
    assert session_id != ""
    assert {:ok, meta} = MCPSessions.fetch(session_id)
    assert meta.server == :terminal
  end

  test "a non-initialize POST does not create a session", %{conn: conn} do
    conn =
      conn
      |> auth()
      |> put_req_header("content-type", "application/json")
      |> post(@path, %{jsonrpc: "2.0", id: 2, method: "tools/list"})

    assert json_response(conn, 200)
    assert get_resp_header(conn, "mcp-session-id") == []
  end

  test "a POST with an unknown session id is rejected with 404", %{conn: conn} do
    unknown_id = "unknown-session-1"

    conn =
      conn
      |> auth()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-session-id", unknown_id)
      |> post(@path, %{jsonrpc: "2.0", id: 3, method: "tools/list"})

    assert %{
             "error" => "unknown_mcp_session",
             "code" => "unknown_mcp_session",
             "error_version" => "mcp-streamable-http-v1",
             "message" => message,
             "mcp_session_id" => ^unknown_id
           } = json_response(conn, 404)

    assert message =~ "not active"
  end

  test "DELETE tears the session down", %{conn: conn} do
    session_id = issue_session()
    assert MCPSessions.exists?(session_id)

    conn =
      conn
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> delete(@path)

    assert conn.status == 204
    refute MCPSessions.exists?(session_id)
  end

  test "DELETE without a session id is a 400", %{conn: conn} do
    conn = conn |> auth() |> delete(@path)

    assert %{
             "error" => "missing_mcp_session_id",
             "code" => "missing_mcp_session_id",
             "error_version" => "mcp-streamable-http-v1",
             "message" => message
           } = json_response(conn, 400)

    assert message =~ "required"
  end

  test "DELETE with an unknown session id is a 404", %{conn: conn} do
    unknown_id = "unknown-session-1"
    conn = conn |> auth() |> put_req_header("mcp-session-id", unknown_id) |> delete(@path)

    assert %{
             "error" => "unknown_mcp_session",
             "code" => "unknown_mcp_session",
             "error_version" => "mcp-streamable-http-v1",
             "mcp_session_id" => ^unknown_id
           } = json_response(conn, 404)
  end

  test "GET without a session id is a 400", %{conn: conn} do
    conn = conn |> auth() |> get(@path)

    assert %{
             "error" => "missing_mcp_session_id",
             "code" => "missing_mcp_session_id",
             "error_version" => "mcp-streamable-http-v1"
           } = json_response(conn, 400)
  end

  test "GET with an unknown session id is a 404", %{conn: conn} do
    unknown_id = "unknown-session-1"
    conn = conn |> auth() |> put_req_header("mcp-session-id", unknown_id) |> get(@path)

    assert %{
             "error" => "unknown_mcp_session",
             "code" => "unknown_mcp_session",
             "error_version" => "mcp-streamable-http-v1",
             "mcp_session_id" => ^unknown_id
           } = json_response(conn, 404)
  end

  test "unknown session errors redact unsafe session id values", %{conn: conn} do
    unsafe_id = "Bearer should-not-echo /data/workspaces/secret-project"

    for method <- [:post, :get, :delete] do
      conn =
        conn
        |> recycle()
        |> auth()
        |> put_req_header("mcp-session-id", unsafe_id)

      conn =
        case method do
          :post ->
            conn
            |> put_req_header("content-type", "application/json")
            |> post(@path, %{jsonrpc: "2.0", id: 3, method: "tools/list"})

          :get ->
            get(conn, @path)

          :delete ->
            delete(conn, @path)
        end

      assert %{"mcp_session_id" => "[REDACTED]"} = json_response(conn, 404)
      refute conn.resp_body =~ "should-not-echo"
      refute conn.resp_body =~ "/data/workspaces/secret-project"
    end
  end

  test "GET attaches an SSE consumer that can be notified" do
    session_id = issue_session()

    task =
      Task.async(fn ->
        build_conn()
        |> auth()
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("accept", "text/event-stream")
        |> get(@path)
      end)

    # The GET handler attaches itself then blocks in the SSE loop.
    wait_until(fn -> MCPSessions.streaming?(session_id) end)
    assert MCPSessions.streaming?(session_id)

    assert :ok =
             MCPSessions.notify(session_id, %{jsonrpc: "2.0", method: "notifications/progress"})

    Task.shutdown(task, :brutal_kill)
    wait_until(fn -> not MCPSessions.streaming?(session_id) end)
  end

  defp issue_session do
    [session_id] = build_conn() |> initialize() |> get_resp_header("mcp-session-id")
    session_id
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> flunk("condition not met in time")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
