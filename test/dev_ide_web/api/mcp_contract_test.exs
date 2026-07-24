defmodule CaseinWeb.API.MCPContractTest do
  @moduledoc """
  Cross-server HTTP contract tests for Casein MCP endpoints.

  These lock down transport/error shapes that external agents depend on without
  exercising the individual terminal/preview/artifact tool implementations.
  """

  use CaseinWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  @token "mcp-contract-token"
  @secret "Bearer should-not-echo"
  @workspace_path "/data/workspaces/secret-project"
  @paths ["/api/terminals/mcp", "/api/preview/mcp", "/api/artifacts/mcp"]

  setup do
    prev_token = Application.get_env(:casein, :api_token)
    prev_workspace_tokens = Application.get_env(:casein, :workspace_api_tokens)
    prev_mcp_max_body_bytes = Application.get_env(:casein, :mcp_max_body_bytes)

    Application.put_env(:casein, :api_token, @token)
    Application.delete_env(:casein, :workspace_api_tokens)

    on_exit(fn ->
      restore(:api_token, prev_token)
      restore(:workspace_api_tokens, prev_workspace_tokens)
      restore(:mcp_max_body_bytes, prev_mcp_max_body_bytes)
    end)

    :ok
  end

  test "auth failures have the same compact JSON shape on MCP endpoints", %{conn: conn} do
    for path <- @paths do
      response =
        conn
        |> recycle()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post(path, %{jsonrpc: "2.0", id: 1, method: "ping"})

      assert response.status == 401
      assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
      assert get_resp_header(response, "mcp-session-id") == []
    end
  end

  test "invalid JSON-RPC objects return parse errors without echoing request secrets", %{
    conn: conn
  } do
    for path <- @paths do
      response =
        conn
        |> recycle()
        |> authed()
        |> post_mcp(path, %{
          "jsonrpc" => "2.0",
          "secret" => @secret,
          "path" => @workspace_path
        })

      assert response.status == 400

      assert %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{
                 "code" => -32_600,
                 "message" => "Could not parse message",
                 "data" => %{"error_version" => "mcp-jsonrpc-v1"}
               }
             } = json_response(response, 400)

      refute response.resp_body =~ @secret
      refute response.resp_body =~ @workspace_path
    end
  end

  test "invalid JSON-RPC objects do not log request secrets", %{conn: conn} do
    for path <- @paths do
      log =
        capture_log(fn ->
          response =
            conn
            |> recycle()
            |> authed()
            |> post_mcp(path, %{
              "jsonrpc" => "2.0",
              "secret" => @secret,
              "path" => @workspace_path
            })

          assert response.status == 400
        end)

      refute log =~ @secret
      refute log =~ @workspace_path
    end
  end

  test "unknown methods return versioned JSON-RPC errors without echoing params", %{conn: conn} do
    for path <- @paths do
      response =
        conn
        |> recycle()
        |> authed()
        |> post_mcp(path, %{
          "jsonrpc" => "2.0",
          "id" => "contract-1",
          "method" => "devide/unknown",
          "params" => %{"secret" => @secret, "path" => @workspace_path}
        })

      assert response.status == 400

      assert %{
               "jsonrpc" => "2.0",
               "id" => "contract-1",
               "error" => %{
                 "code" => -32_601,
                 "message" => "Method not found",
                 "data" => %{
                   "error_version" => "mcp-jsonrpc-v1",
                   "name" => "devide/unknown"
                 }
               }
             } = json_response(response, 400)

      refute response.resp_body =~ @secret
      refute response.resp_body =~ @workspace_path
    end
  end

  test "unknown methods do not log request params", %{conn: conn} do
    for path <- @paths do
      log =
        capture_log(fn ->
          response =
            conn
            |> recycle()
            |> authed()
            |> post_mcp(path, %{
              "jsonrpc" => "2.0",
              "id" => "contract-1",
              "method" => "devide/unknown",
              "params" => %{"secret" => @secret, "path" => @workspace_path}
            })

          assert response.status == 400
        end)

      refute log =~ @secret
      refute log =~ @workspace_path
    end
  end

  test "streamable GET requires a versioned MCP session id error on both endpoints", %{
    conn: conn
  } do
    for path <- @paths do
      response =
        conn
        |> recycle()
        |> authed()
        |> put_req_header("accept", "text/event-stream")
        |> get(path)

      assert response.status == 400

      assert %{
               "error" => "missing_mcp_session_id",
               "code" => "missing_mcp_session_id",
               "error_version" => "mcp-streamable-http-v1",
               "message" => message
             } = json_response(response, 400)

      assert message =~ "Mcp-Session-Id"
    end
  end

  test "streamable DELETE requires a versioned MCP session id error on both endpoints", %{
    conn: conn
  } do
    for path <- @paths do
      response =
        conn
        |> recycle()
        |> authed()
        |> delete(path)

      assert response.status == 400

      assert %{
               "error" => "missing_mcp_session_id",
               "code" => "missing_mcp_session_id",
               "error_version" => "mcp-streamable-http-v1",
               "message" => message
             } = json_response(response, 400)

      assert message =~ "Mcp-Session-Id"
    end
  end

  test "streamable DELETE rejects unknown MCP session ids on both endpoints", %{conn: conn} do
    for path <- @paths do
      unknown_id = "unknown-session-1"

      response =
        conn
        |> recycle()
        |> authed()
        |> put_req_header("mcp-session-id", unknown_id)
        |> delete(path)

      assert response.status == 404

      assert %{
               "error" => "unknown_mcp_session",
               "code" => "unknown_mcp_session",
               "error_version" => "mcp-streamable-http-v1",
               "message" => message,
               "mcp_session_id" => ^unknown_id
             } = json_response(response, 404)

      assert message =~ "not active"
    end
  end

  test "unknown MCP session errors do not echo unsafe session ids", %{conn: conn} do
    unsafe_id = "#{@secret} #{@workspace_path}"

    for path <- @paths, method <- [:post, :get, :delete] do
      log =
        capture_log(fn ->
          response =
            conn
            |> recycle()
            |> authed()
            |> put_req_header("mcp-session-id", unsafe_id)
            |> request_unknown_session(method, path)

          assert response.status == 404

          assert %{
                   "error" => "unknown_mcp_session",
                   "code" => "unknown_mcp_session",
                   "error_version" => "mcp-streamable-http-v1",
                   "mcp_session_id" => "[REDACTED]"
                 } = json_response(response, 404)

          refute response.resp_body =~ @secret
          refute response.resp_body =~ @workspace_path
        end)

      refute log =~ @secret
      refute log =~ @workspace_path
    end
  end

  test "oversized MCP request bodies are rejected before JSON-RPC handling", %{conn: conn} do
    Application.put_env(:casein, :mcp_max_body_bytes, 96)

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "ping",
        params: %{prompt: String.duplicate("x", 200)}
      })

    for path <- @paths do
      response =
        conn
        |> recycle()
        |> authed()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-length", Integer.to_string(byte_size(body)))
        |> post(path, body)

      assert response.status == 413

      assert Jason.decode!(response.resp_body) == %{
               "error" => "request_body_too_large",
               "code" => "request_body_too_large",
               "error_version" => "mcp-streamable-http-v1",
               "message" => "MCP request body exceeds the configured maximum size",
               "max_bytes" => 96
             }

      refute response.resp_body =~ "xxxxxxxx"
      assert get_resp_header(response, "mcp-session-id") == []
    end
  end

  test "oversized MCP request bodies do not log request content", %{conn: conn} do
    Application.put_env(:casein, :mcp_max_body_bytes, 96)

    secret_prompt = "prompt includes #{@secret} at #{@workspace_path}"

    body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: "ping",
        params: %{prompt: secret_prompt <> String.duplicate("x", 200)}
      })

    for path <- @paths do
      log =
        capture_log(fn ->
          response =
            conn
            |> recycle()
            |> authed()
            |> put_req_header("content-type", "application/json")
            |> put_req_header("accept", "application/json")
            |> put_req_header("content-length", Integer.to_string(byte_size(body)))
            |> post(path, body)

          assert response.status == 413
        end)

      refute log =~ @secret
      refute log =~ @workspace_path
      refute log =~ secret_prompt
    end
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp post_mcp(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, body)
  end

  defp request_unknown_session(conn, :post, path) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post(path, %{jsonrpc: "2.0", id: "unknown-session", method: "tools/list"})
  end

  defp request_unknown_session(conn, :get, path), do: get(conn, path)
  defp request_unknown_session(conn, :delete, path), do: delete(conn, path)

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
