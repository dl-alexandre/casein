defmodule DevIdeWeb.API.MCPTransport do
  @moduledoc """
  Shared HTTP plumbing for the MCP Streamable HTTP transport, used by both the
  preview and terminal controllers.

  The base transport is a single POST (request in, JSON response out). Streamable
  HTTP layers a session on top:

    * `initialize` issues an `Mcp-Session-Id` (response header).
    * A client opens a server→client SSE channel with `GET` carrying that header;
      the server pushes `notifications/*` (e.g. progress) to it via
      `DevIDE.Agents.MCPSessions.notify/2`.
    * `DELETE` tears the session down.

  Sessions are optional and additive: a POST without an `Mcp-Session-Id` behaves
  exactly as the stateless transport always has, so existing clients are
  unaffected. A POST that *does* carry an unknown id gets a 404 so the client
  re-initializes (per the MCP spec).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias DevIDE.Agents.MCPSessions

  @session_header "mcp-session-id"
  # Heartbeat cadence: keeps proxies from idling the SSE socket and lets a
  # closed connection surface as a chunk error so the loop exits.
  @heartbeat_ms 25_000

  @doc "The `Mcp-Session-Id` carried on the request, or nil."
  @spec session_id(Plug.Conn.t()) :: String.t() | nil
  def session_id(conn) do
    case get_req_header(conn, @session_header) do
      [id | _] when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  Gate a POST on its session id. `{:cont, conn}` when absent (stateless) or
  known; `{:halt, conn}` with a 404 already sent when an unknown id is supplied.
  """
  @spec ensure_known_session(Plug.Conn.t()) :: {:cont, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def ensure_known_session(conn) do
    case session_id(conn) do
      nil -> {:cont, conn}
      id -> if MCPSessions.exists?(id), do: {:cont, conn}, else: {:halt, not_found(conn, id)}
    end
  end

  @doc """
  When the request is an `initialize`, create a session and advertise its id on
  the response. Otherwise the connection is returned untouched.
  """
  @spec maybe_issue_session(Plug.Conn.t(), :preview | :terminal, map(), String.t() | nil) ::
          Plug.Conn.t()
  def maybe_issue_session(conn, server, %{"method" => "initialize"}, workspace_id) do
    id = MCPSessions.create(%{server: server, workspace_id: workspace_id})
    put_resp_header(conn, @session_header, id)
  end

  def maybe_issue_session(conn, _server, _message, _workspace_id), do: conn

  @doc "Open the server→client SSE channel for a session (the `GET` handler)."
  @spec stream(Plug.Conn.t(), :preview | :terminal) :: Plug.Conn.t()
  def stream(conn, _server) do
    case session_id(conn) do
      nil ->
        conn |> put_status(400) |> json(%{error: "missing_mcp_session_id"})

      id ->
        if MCPSessions.exists?(id) do
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("x-accel-buffering", "no")
          |> send_chunked(200)
          |> open_stream(id)
        else
          not_found(conn, id)
        end
    end
  end

  @doc "Tear down a session (the `DELETE` handler)."
  @spec terminate(Plug.Conn.t()) :: Plug.Conn.t()
  def terminate(conn) do
    case session_id(conn) do
      nil ->
        conn |> put_status(400) |> json(%{error: "missing_mcp_session_id"})

      id ->
        _ = MCPSessions.delete(id)
        send_resp(conn, 204, "")
    end
  end

  defp open_stream(conn, id) do
    case MCPSessions.attach_stream(id, self()) do
      :ok -> sse_loop(conn, id)
      # Session vanished between the exists? check and attach; just close.
      {:error, _} -> conn
    end
  end

  defp sse_loop(conn, id) do
    receive do
      {:mcp_sse, message} ->
        case chunk(conn, encode_event(message)) do
          {:ok, conn} -> sse_loop(conn, id)
          {:error, _closed} -> conn
        end
    after
      @heartbeat_ms ->
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> sse_loop(conn, id)
          {:error, _closed} -> conn
        end
    end
  end

  defp encode_event(message) do
    "data: " <> Jason.encode!(message) <> "\n\n"
  end

  defp not_found(conn, id) do
    conn |> put_status(404) |> json(%{error: "unknown_mcp_session", mcp_session_id: id})
  end
end
