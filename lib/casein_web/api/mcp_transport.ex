defmodule CaseinWeb.API.MCPTransport do
  @moduledoc """
  Shared HTTP plumbing for the MCP Streamable HTTP transport, used by the
  preview, terminal, and artifact controllers.

  The base transport is a single POST (request in, JSON response out). Streamable
  HTTP layers a session on top:

    * `initialize` issues an `Mcp-Session-Id` (response header).
    * A client opens a server→client SSE channel with `GET` carrying that header;
      the server pushes `notifications/*` (e.g. progress) to it via
      `Casein.Agents.MCPSessions.notify/2`.
    * `DELETE` tears the session down.

  Sessions are optional and additive: a POST without an `Mcp-Session-Id` behaves
  exactly as the stateless transport always has, so existing clients are
  unaffected. A POST that *does* carry an unknown id gets a 404 so the client
  re-initializes (per the MCP spec).
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Casein.Agents.MCPSessions

  @session_header "mcp-session-id"
  @error_version "mcp-streamable-http-v1"
  @safe_session_id ~r/^[A-Za-z0-9_-]{16,128}$/
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
      nil ->
        {:cont, conn}

      id ->
        if authorized_session?(conn, id, server_for_path(conn.request_path)) do
          # Keep an actively used session alive against the idle sweep.
          _ = MCPSessions.touch(id)
          {:cont, conn}
        else
          {:halt, not_found(conn, id)}
        end
    end
  end

  @doc """
  When the request is an `initialize`, create a session and advertise its id on
  the response. Otherwise the connection is returned untouched.
  """
  @spec maybe_issue_session(
          Plug.Conn.t(),
          :preview | :terminal | :artifact,
          map(),
          String.t() | nil
        ) ::
          Plug.Conn.t()
  def maybe_issue_session(conn, server, %{"method" => "initialize"}, workspace_id) do
    id =
      MCPSessions.create(%{
        server: server,
        workspace_id: workspace_id,
        auth_scope: conn.assigns[:api_token_scope]
      })

    put_resp_header(conn, @session_header, id)
  end

  def maybe_issue_session(conn, _server, _message, _workspace_id), do: conn

  @doc "Open the server→client SSE channel for a session (the `GET` handler)."
  @spec stream(Plug.Conn.t(), :preview | :terminal | :artifact) :: Plug.Conn.t()
  def stream(conn, server) do
    case session_id(conn) do
      nil ->
        conn |> put_status(400) |> json(transport_error("missing_mcp_session_id"))

      id ->
        if authorized_session?(conn, id, server) do
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
  @spec terminate(Plug.Conn.t(), :preview | :terminal | :artifact) :: Plug.Conn.t()
  def terminate(conn, server) do
    case session_id(conn) do
      nil ->
        conn |> put_status(400) |> json(transport_error("missing_mcp_session_id"))

      id ->
        if authorized_session?(conn, id, server) do
          _ = MCPSessions.delete(id)
          send_resp(conn, 204, "")
        else
          not_found(conn, id)
        end
    end
  end

  defp open_stream(conn, id) do
    case MCPSessions.attach_stream(id, self()) do
      :ok -> sse_loop(conn, id)
      # Session vanished between the exists? check and attach; just close.
      {:error, _} -> conn
    end
  end

  defp authorized_session?(conn, id, server) when not is_nil(server) do
    conn = fetch_query_params(conn)
    workspace_id = conn.query_params["workspace_id"] || conn.assigns[:api_workspace_id]

    case MCPSessions.fetch(id) do
      {:ok, metadata} ->
        metadata[:server] == server and
          metadata[:workspace_id] == workspace_id and
          metadata[:auth_scope] == conn.assigns[:api_token_scope]

      :error ->
        false
    end
  end

  defp authorized_session?(_conn, _id, _server), do: false

  defp server_for_path("/api/terminals/mcp"), do: :terminal
  defp server_for_path("/api/preview/mcp"), do: :preview
  defp server_for_path("/api/artifacts/mcp"), do: :artifact
  defp server_for_path(_path), do: nil

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
    conn
    |> put_status(404)
    |> json(transport_error("unknown_mcp_session", %{mcp_session_id: session_id_echo(id)}))
  end

  defp session_id_echo(id) when is_binary(id) do
    if String.match?(id, @safe_session_id), do: id, else: "[REDACTED]"
  end

  defp session_id_echo(_id), do: "[REDACTED]"

  defp transport_error(code, extra \\ %{}) do
    %{
      error: code,
      code: code,
      message: transport_error_message(code),
      error_version: @error_version
    }
    |> Map.merge(extra)
  end

  defp transport_error_message("missing_mcp_session_id"),
    do: "Mcp-Session-Id header is required for this streamable MCP operation"

  defp transport_error_message("unknown_mcp_session"),
    do: "Mcp-Session-Id is not active; initialize a new MCP session"

  defp transport_error_message(code), do: code
end
