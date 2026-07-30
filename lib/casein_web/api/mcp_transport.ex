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

  alias Casein.Agents.{MCPSessions, MCPTasks}
  alias CaseinWeb.API.MCPEnvelope

  @session_header "mcp-session-id"
  @method_header "mcp-method"
  @name_header "mcp-name"
  @version_header "mcp-protocol-version"
  @subscription_id_key "io.modelcontextprotocol/subscriptionId"
  @error_version "mcp-streamable-http-v1"
  # HeaderMismatchError, from the spec-reserved -32020..-32099 range.
  @header_mismatch_code -32_020
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
  Run every pre-dispatch transport gate for a POST: session validity, then the
  2026-07-28 request headers.
  """
  @spec preflight(Plug.Conn.t(), map()) :: {:cont, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def preflight(conn, message) do
    with {:cont, conn} <- ensure_known_session(conn) do
      ensure_request_headers(conn, message)
    end
  end

  @doc """
  Check the `Mcp-Method` / `Mcp-Name` request headers against the JSON-RPC body.

  These headers became required in 2026-07-28 so intermediaries can route and
  authorize without parsing the body. We enforce them only for requests that
  declare that revision — no client on this box sends them, and rejecting a
  legacy POST for a missing header would break every agent at once.

  Within a modern request we reject a **mismatch** but tolerate **absence**. A
  mismatch is the case with teeth: it means a proxy was told one method and the
  server another, which is exactly the confusion the headers exist to prevent.
  Absence merely costs the intermediary its optimization, and failing closed
  there buys no safety.
  """
  @spec ensure_request_headers(Plug.Conn.t(), map()) ::
          {:cont, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def ensure_request_headers(conn, message) when is_map(message) do
    if MCPEnvelope.declared_version(message) == "2026-07-28" do
      check_headers(conn, message)
    else
      {:cont, conn}
    end
  end

  def ensure_request_headers(conn, _message), do: {:cont, conn}

  defp check_headers(conn, message) do
    cond do
      mismatch?(conn, @version_header, MCPEnvelope.declared_version(message)) ->
        {:halt, header_mismatch(conn, @version_header)}

      mismatch?(conn, @method_header, Map.get(message, "method")) ->
        {:halt, header_mismatch(conn, @method_header)}

      mismatch?(conn, @name_header, mcp_name(message)) ->
        {:halt, header_mismatch(conn, @name_header)}

      true ->
        {:cont, conn}
    end
  end

  defp mismatch?(conn, header, expected) do
    case get_req_header(conn, header) do
      [value | _] when is_binary(value) and value != "" -> decode_header(value) != expected
      _ -> false
    end
  end

  # Values that cannot ride in a plain ASCII header arrive Base64-wrapped in a
  # sentinel; they must be decoded before being compared to the body.
  defp decode_header("=?base64?" <> rest) do
    case String.split(rest, "?=", parts: 2) do
      [encoded, ""] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> "=?base64?" <> rest
        end

      _ ->
        "=?base64?" <> rest
    end
  end

  defp decode_header(value), do: value

  # `Mcp-Name` mirrors `params.name` for tools/call and prompts/get, and
  # `params.uri` for resources/read. Other methods carry no name.
  defp mcp_name(%{"method" => method, "params" => %{"name" => name}})
       when is_binary(name) and method in ["tools/call", "prompts/get"],
       do: name

  defp mcp_name(%{"method" => "resources/read", "params" => %{"uri" => uri}}) when is_binary(uri),
    do: uri

  defp mcp_name(_message), do: nil

  defp header_mismatch(conn, header) do
    conn
    |> put_status(400)
    |> json(%{
      jsonrpc: "2.0",
      id: nil,
      error: %{
        code: @header_mismatch_code,
        message: "MCP request header does not match the request body",
        data: %{code: "header_mismatch", header: header, error_version: @error_version}
      }
    })
  end

  @doc """
  When the request is an `initialize`, create a session and advertise its id on
  the response. Otherwise the connection is returned untouched.

  Naturally inert for 2026-07-28 clients: they never send `initialize`, so no
  session is ever minted for them — which matches the revision removing sessions
  outright.
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

  @doc """
  Serve a `subscriptions/listen` request as a long-lived SSE response stream.

  This is the 2026-07-28 replacement for the `GET` channel below: instead of a
  side channel keyed by a session id, the notification stream *is* the response
  to a POST. We honour exactly one notification type — `notifications/tasks` for
  the task ids the caller owns — because it is the only one we emit; the
  acknowledgement reflects that narrowed set.
  """
  @spec subscription_stream(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def subscription_stream(conn, subscription) do
    Enum.each(subscription.task_ids, &MCPTasks.subscribe/1)

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("x-accel-buffering", "no")
      |> send_chunked(200)

    # The acknowledgement MUST be the first message on the stream.
    case chunk(conn, encode_event(acknowledgement(subscription))) do
      {:ok, conn} -> start_subscription(conn, subscription)
      {:error, _closed} -> conn
    end
  end

  # Nothing to watch: acknowledge the empty set and close gracefully rather than
  # holding a socket open forever on a subscription we agreed to nothing for.
  defp start_subscription(conn, %{task_ids: []} = subscription),
    do: close_subscription(conn, subscription)

  defp start_subscription(conn, subscription),
    do: subscription_loop(conn, subscription, MapSet.new(subscription.task_ids))

  defp subscription_loop(conn, subscription, pending) do
    receive do
      {:mcp_task, task} ->
        message = %{
          jsonrpc: "2.0",
          method: "notifications/tasks",
          params: Map.put(task, :_meta, %{@subscription_id_key => subscription.id})
        }

        case chunk(conn, encode_event(message)) do
          {:ok, conn} ->
            pending = drop_if_terminal(pending, task)

            # Every watched task has reached a terminal state, so the stream has
            # nothing left to say.
            if MapSet.size(pending) == 0 do
              close_subscription(conn, subscription)
            else
              subscription_loop(conn, subscription, pending)
            end

          {:error, _closed} ->
            conn
        end
    after
      @heartbeat_ms ->
        case chunk(conn, ":\r\n") do
          {:ok, conn} -> subscription_loop(conn, subscription, pending)
          {:error, _closed} -> conn
        end
    end
  end

  defp drop_if_terminal(pending, %{status: status, taskId: task_id})
       when status in ["completed", "failed", "cancelled"],
       do: MapSet.delete(pending, task_id)

  defp drop_if_terminal(pending, _task), do: pending

  # Graceful closure: answer the long-lived request with an empty result so the
  # client can tell a clean end from a dropped connection.
  defp close_subscription(conn, subscription) do
    response = %{
      jsonrpc: "2.0",
      id: subscription.id,
      result: %{resultType: "complete", _meta: %{@subscription_id_key => subscription.id}}
    }

    case chunk(conn, encode_event(response)) do
      {:ok, conn} -> conn
      {:error, _closed} -> conn
    end
  end

  defp acknowledgement(subscription) do
    %{
      jsonrpc: "2.0",
      method: "notifications/subscriptions/acknowledged",
      params: %{
        _meta: %{@subscription_id_key => subscription.id},
        notifications: subscription.notifications
      }
    }
  end

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
