defmodule DevIdeWeb.API.MCPEnvelope do
  @moduledoc """
  Shared JSON-RPC 2.0 envelope for DevIDE's MCP servers.

  `DevIdeWeb.API.PreviewMCP` and `DevIdeWeb.API.TerminalMCP` speak the same wire
  shape — JSON-RPC 2.0 over a single HTTP POST — and used to each carry their own
  byte-identical copy of the routing skeleton (`handle/2`, `route/2`, the `ping`
  clause) and the response helpers (`result/2`, `error/4`, `parse_error/0`,
  `text/1`, `jsonable/1`, `server_version/0`). That envelope now lives here once.

  A handler module implements the `MCPEnvelope` behaviour (the genuinely
  server-specific parts) and delegates routing:

      def handle(message, opts \\\\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  The behaviour callbacks are the only places the two servers differ:

    * `server_name/0` — the `serverInfo.name` advertised on `initialize`.
    * `instructions/1` — the scoped instruction string for `initialize`.
    * `list_tools/1` — the fully-scoped `tools/list` payload.
    * `call_tool/3` — the `tools/call` dispatch (workspace resolution, scoping,
      tool invocation, audit). Builds its response with the public helpers below.

  `initialize`, `ping`, notification routing, unknown-method errors, parse
  errors, and protocol-version negotiation are handled here for both servers.
  """

  @default_protocol_version "2025-03-26"

  # Protocol versions this minimal tool surface is wire-compatible with. When a
  # client asks for one of these on `initialize`, we echo it back (per the MCP
  # spec); otherwise we fall back to our default.
  @supported_protocol_versions [
    "2025-06-18",
    "2025-03-26",
    "2024-11-05"
  ]

  @type outcome :: {:reply, map()} | :noreply | {:error, map()}

  @callback server_name() :: String.t()
  @callback instructions(opts :: keyword()) :: String.t()
  @callback list_tools(opts :: keyword()) :: [map()]
  @callback call_tool(id :: term(), params :: map(), opts :: keyword()) :: map()

  @doc """
  Handle a single decoded JSON-RPC message for `handler`.
  """
  @spec handle(map(), module(), keyword()) :: outcome()
  def handle(message, handler, opts \\ [])
  def handle(%{"jsonrpc" => "2.0"} = message, handler, opts), do: route(message, handler, opts)
  def handle(_, _handler, _opts), do: {:error, parse_error()}

  # Notifications carry a method but no id; they never get a response body.
  defp route(%{"method" => "notifications/" <> _}, _handler, _opts), do: :noreply

  defp route(%{"method" => method, "id" => id} = message, handler, opts) do
    dispatch(method, id, Map.get(message, "params", %{}) || %{}, handler, opts)
  end

  # A reply to one of our requests (e.g. a ping answer) — nothing to do.
  defp route(%{"id" => _}, _handler, _opts), do: :noreply
  defp route(_, _handler, _opts), do: {:error, parse_error()}

  defp dispatch("initialize", id, params, handler, opts) do
    {:reply,
     result(id, %{
       protocolVersion: negotiate_protocol_version(params),
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: handler.server_name(), version: server_version()},
       instructions: handler.instructions(opts) <> streaming_hint()
     })}
  end

  defp dispatch("ping", id, _params, _handler, _opts), do: {:reply, result(id, %{})}

  defp dispatch("tools/list", id, _params, handler, opts) do
    {:reply, result(id, %{tools: handler.list_tools(opts)})}
  end

  defp dispatch("tools/call", id, params, handler, opts) do
    {:reply, handler.call_tool(id, params, opts)}
  end

  defp dispatch(other, id, _params, _handler, _opts) do
    {:error, error(id, -32_601, "Method not found", %{name: other})}
  end

  @doc """
  Resolve the protocol version to advertise on `initialize`.

  Echoes the client's requested `protocolVersion` when it is one we support,
  otherwise falls back to #{@default_protocol_version}.
  """
  @spec negotiate_protocol_version(map() | any()) :: String.t()
  def negotiate_protocol_version(params) when is_map(params) do
    case Map.get(params, "protocolVersion") || Map.get(params, :protocolVersion) do
      version when version in @supported_protocol_versions -> version
      _ -> @default_protocol_version
    end
  end

  def negotiate_protocol_version(_), do: @default_protocol_version

  # The Streamable HTTP transport returns an Mcp-Session-Id header on the
  # initialize response; clients may open a server→client SSE channel with that
  # id to receive notifications/* pushes.
  defp streaming_hint do
    " This endpoint supports the MCP Streamable HTTP transport: the initialize " <>
      "response carries an Mcp-Session-Id header. Send that header on a GET to " <>
      "the same URL to open a server-sent-events channel; the server pushes any " <>
      "notifications/* over it as tools emit them (the channel otherwise just " <>
      "keeps alive). Send the header on a DELETE to end the session. Plain POST " <>
      "JSON-RPC keeps working without a session."
  end

  @doc "Build a JSON-RPC 2.0 success response."
  @spec result(term(), map()) :: map()
  def result(id, result) when is_map(result) do
    %{jsonrpc: "2.0", id: id, result: result}
  end

  @doc "Build a JSON-RPC 2.0 error response."
  @spec error(term(), integer(), String.t(), map() | nil) :: map()
  def error(id, code, message, data \\ nil) do
    err = %{code: code, message: message}
    err = if data, do: Map.put(err, :data, data), else: err
    %{jsonrpc: "2.0", id: id, error: err}
  end

  @doc "The standard JSON-RPC parse/invalid-request error."
  @spec parse_error() :: map()
  def parse_error, do: error(nil, -32_600, "Could not parse message")

  @doc "Wrap a tool payload as MCP text content."
  @spec text(term()) :: map()
  def text(payload) when is_binary(payload), do: %{type: "text", text: payload}
  def text(payload), do: %{type: "text", text: Jason.encode!(jsonable(payload))}

  @doc """
  Round-trip a payload through JSON so the response is plain, serializable data
  regardless of atom keys or structs in adapter output.
  """
  @spec jsonable(term()) :: term()
  def jsonable(payload) do
    payload |> Jason.encode!() |> Jason.decode!()
  end

  @doc "The running `:dev_ide` application version, for `serverInfo.version`."
  @spec server_version() :: String.t()
  def server_version do
    case Application.spec(:dev_ide, :vsn) do
      vsn when is_list(vsn) -> to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
