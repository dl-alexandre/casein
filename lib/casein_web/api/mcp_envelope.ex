defmodule CaseinWeb.API.MCPEnvelope do
  @moduledoc """
  Shared JSON-RPC 2.0 envelope for Casein's MCP servers.

  `CaseinWeb.API.PreviewMCP`, `CaseinWeb.API.TerminalMCP`, and
  `CaseinWeb.API.ArtifactMCP` speak the same wire shape — JSON-RPC 2.0 over a
  single HTTP POST — and share the routing skeleton (`handle/2`, `route/2`, the
  `ping` clause) and response helpers (`result/2`, `error/4`, `parse_error/0`,
  `text/1`, `jsonable/1`, `server_version/0`). That envelope lives here once.

  A handler module implements the `MCPEnvelope` behaviour (the genuinely
  server-specific parts) and delegates routing:

      def handle(message, opts \\\\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  The behaviour callbacks are the only places the two servers differ:

    * `server_name/0` — the `serverInfo.name` advertised on `initialize`.
    * `instructions/1` — the scoped instruction string for `initialize`.
    * `list_tools/1` — the fully-scoped `tools/list` payload.
    * `call_tool/3` — the `tools/call` dispatch (workspace resolution, scoping,
      tool invocation, audit). Builds its response with the public helpers below.

  `initialize`, `ping`, `server/discover`, notification routing, unknown-method
  errors, parse errors, and protocol-version negotiation are handled here for
  every Casein MCP server.

  ## Two revisions on one endpoint

  Spec revision `2026-07-28` removed the pieces this envelope was built around:
  `initialize`, `notifications/initialized`, `ping`, and the `Mcp-Session-Id`
  header. Instead of a handshake, **every** request carries its protocol version
  and client capabilities in `params._meta`, and servers MUST implement
  `server/discover`.

  Rather than fork the module, we serve both from here and pick the behaviour per
  request:

    * A request whose `_meta` declares `2026-07-28` is a modern request — it may
      call `server/discover`, its results carry `resultType` / `_meta.serverInfo`,
      and list results carry the `CacheableResult` fields.
    * Anything else (including every request that declares no version at all) is
      a legacy request and gets a byte-identical response to what it got before
      this dual-stack landed. `initialize` and `ping` keep working.

  That last property is the compatibility contract: the agents running on this
  box speak 2025-era revisions, so new fields are **emitted only** for clients
  that asked for the revision defining them. `docs/design/mcp-2026-07-28-adoption.md`
  records the reasoning.
  """

  @default_protocol_version "2025-03-26"
  @error_version "mcp-jsonrpc-v1"

  # The revision that replaced the handshake with per-request `_meta`.
  @protocol_2026 "2026-07-28"

  # Freshness hints for `CacheableResult` results. Tool surfaces only change on
  # deploy; `server/discover` output is stable for the life of a token.
  @tools_list_ttl_ms 300_000
  @discover_ttl_ms 3_600_000

  # Reserved `_meta` keys from the 2026-07-28 core spec.
  @meta_protocol_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_capabilities "io.modelcontextprotocol/clientCapabilities"
  @meta_server_info "io.modelcontextprotocol/serverInfo"

  # Spec-allocated error codes (-32020..-32099 is reserved for the spec; our own
  # -32003 agent-capability denial stays legal in the grandfathered
  # -32000..-32019 implementation-defined range).
  @unsupported_protocol_version -32_022

  # Official extension identifiers.
  @tasks_extension "io.modelcontextprotocol/tasks"
  @ui_extension "io.modelcontextprotocol/ui"

  # The only resource mime type MCP Apps defines today.
  @ui_mime_type "text/html;profile=mcp-app"

  @resources_ttl_ms 300_000

  alias Casein.Agents.MCPTasks
  alias CaseinWeb.API.MCPCapabilityScope

  # Protocol versions this tool surface is wire-compatible with. When a client
  # asks for one of these on `initialize`, we echo it back (per the MCP spec);
  # otherwise we fall back to our default. Also the `supportedVersions` list
  # advertised by `server/discover`.
  @supported_protocol_versions [
    @protocol_2026,
    "2025-06-18",
    "2025-03-26",
    "2024-11-05"
  ]

  @type outcome :: {:reply, map()} | :noreply | {:error, map()} | {:stream, map()}
  @type revision :: :v2026 | :legacy

  @callback server_name() :: String.t()
  @callback instructions(opts :: keyword()) :: String.t()
  @callback list_tools(opts :: keyword()) :: [map()]
  @callback call_tool(id :: term(), params :: map(), opts :: keyword()) :: map()

  @doc """
  Tool names this server may run as a background task for Tasks-aware clients.

  Listing a tool here asserts two things: it can outlive an HTTP request, and it
  is safe to abandon mid-flight (see `Casein.Agents.MCPTasks` on cancellation).
  Read-only waits qualify; a mutating tool does not.
  """
  @callback task_tools() :: [String.t()]

  @doc """
  Resources this server exposes, in `resources/list` shape.

  Casein serves resources for one reason today: MCP Apps. A resource whose
  `mimeType` is `text/html;profile=mcp-app` is an interactive view a host renders
  inline, referenced from a tool's `_meta.ui.resourceUri`.
  """
  @callback list_resources(opts :: keyword()) :: [map()]

  @doc """
  Read one resource, returning `resources/read` `contents` entries.

  `{:error, :not_found}` becomes an Invalid Params error — 2026-07-28 renumbered
  resource-not-found from -32002 to -32602.
  """
  @callback read_resource(uri :: String.t(), opts :: keyword()) ::
              {:ok, [map()]} | {:error, :not_found}

  @doc """
  Handle a single decoded JSON-RPC message for `handler`.
  """
  @spec handle(map(), module(), keyword()) :: outcome()
  def handle(message, handler, opts \\ [])

  def handle(%{"jsonrpc" => "2.0"} = message, handler, opts) do
    case resolve_revision(message) do
      {:ok, revision} ->
        opts = Keyword.put(opts, :protocol_revision, revision)

        message
        |> route(handler, opts)
        |> decorate(revision, handler)

      {:error, requested} ->
        {:error,
         error(
           Map.get(message, "id"),
           @unsupported_protocol_version,
           "Unsupported protocol version",
           %{
             code: "unsupported_protocol_version",
             supportedVersions: @supported_protocol_versions,
             requested: requested
           }
         )}
    end
  end

  def handle(_, _handler, _opts), do: {:error, parse_error()}

  @doc """
  The protocol revision resolved for the in-flight request.

  Handlers receive this in `opts`; it decides whether a response may carry
  2026-07-28 fields.
  """
  @spec revision(keyword()) :: revision()
  def revision(opts), do: Keyword.get(opts, :protocol_revision, :legacy)

  @doc """
  The protocol revision a request asks for.

  A request that names no version is legacy — that fallback is load-bearing.
  `scripts/lib/agent-doctor.sh` dual-probes legacy `initialize` (empty params)
  and `server/discover` with `_meta` 2026-07-28; the empty-params path must keep
  getting the old behaviour. A request naming a version we do not know is a
  hard error (`UnsupportedProtocolVersionError`), which only reaches clients that
  opted into per-request `_meta` in the first place.
  """
  @spec resolve_revision(map()) :: {:ok, revision()} | {:error, String.t()}
  def resolve_revision(message) do
    case declared_version(message) do
      nil -> {:ok, :legacy}
      @protocol_2026 -> {:ok, :v2026}
      version when version in @supported_protocol_versions -> {:ok, :legacy}
      other -> {:error, other}
    end
  end

  @doc "The version string declared in a request's `_meta`, or nil."
  @spec declared_version(map()) :: String.t() | nil
  def declared_version(message) do
    case Map.get(request_meta(message), @meta_protocol_version) do
      version when is_binary(version) -> version
      _ -> nil
    end
  end

  @doc """
  True when a request's params declare support for `extension` in their `_meta`
  client capabilities.

  The 2026-07-28 extension framework replaced handshake-time negotiation with a
  per-request declaration, so this is the only place an extension may be
  detected. Callers MUST NOT emit extension-shaped responses without it — a
  client that never asked for Tasks must keep getting synchronous results.
  """
  @spec client_extension?(map(), String.t()) :: boolean()
  def client_extension?(params, extension) when is_binary(extension) do
    case Map.get(params_meta(params), @meta_client_capabilities) do
      %{"extensions" => extensions} when is_map(extensions) ->
        Map.has_key?(extensions, extension)

      _ ->
        false
    end
  end

  defp params_meta(params) when is_map(params) do
    case Map.get(params, "_meta") do
      %{} = meta -> meta
      _ -> %{}
    end
  end

  defp params_meta(_params), do: %{}

  defp request_meta(%{"params" => params}), do: params_meta(params)
  defp request_meta(_message), do: %{}

  # 2026-07-28 requires `resultType` on every result and asks servers to identify
  # themselves in each result's `_meta`. Both are additive fields a legacy client
  # never asked for, so they are stamped only for modern requests — that keeps
  # pre-2026 responses byte-identical. Errors carry neither.
  defp decorate({:reply, %{result: result} = response}, :v2026, handler) when is_map(result) do
    server_info = %{name: handler.server_name(), version: server_version()}

    result =
      result
      |> Map.put_new(:resultType, "complete")
      |> Map.update(:_meta, %{@meta_server_info => server_info}, fn meta ->
        Map.put_new(meta, @meta_server_info, server_info)
      end)

    {:reply, %{response | result: result}}
  end

  defp decorate(outcome, _revision, _handler), do: outcome

  # Notifications carry a method but no id; they never get a response body.
  defp route(%{"method" => "notifications/" <> _}, _handler, _opts), do: :noreply

  defp route(%{"method" => method, "id" => id} = message, handler, opts) do
    dispatch(method, id, Map.get(message, "params", %{}) || %{}, handler, opts)
  end

  # A reply to one of our requests (e.g. a ping answer) — nothing to do.
  defp route(%{"id" => _}, _handler, _opts), do: :noreply
  defp route(_, _handler, _opts), do: {:error, parse_error()}

  # `initialize` and `ping` were removed in 2026-07-28. They stay here for the
  # 2025-era clients on this box; a modern client uses `server/discover` instead.
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

  # Servers MUST implement `server/discover`. Purely additive: legacy clients
  # never call it, and before this existed it fell through to -32601.
  defp dispatch("server/discover", id, _params, handler, opts) do
    {:reply,
     result(id, %{
       supportedVersions: @supported_protocol_versions,
       capabilities: server_capabilities(handler, opts),
       instructions: handler.instructions(opts),
       ttlMs: @discover_ttl_ms,
       # Never "public": `instructions/1` embeds the endpoint's pre-scoped
       # workspace_id, so this response is caller-specific.
       cacheScope: "private"
     })}
  end

  defp dispatch("tools/list", id, _params, handler, opts) do
    tools =
      handler.list_tools(opts)
      |> MCPCapabilityScope.filter_tools(opts)
      # Deterministic order lets clients cache the list and improves prompt-cache
      # hit rates. Safe for every revision, so it is not gated.
      |> Enum.sort_by(&tool_sort_key/1)

    {:reply, result(id, cacheable(%{tools: tools}, @tools_list_ttl_ms, opts))}
  end

  # The 2026-07-28 replacement for the GET SSE channel: the notification stream
  # is the response to this POST. The controller turns `{:stream, _}` into a
  # chunked SSE response; see `MCPTransport.subscription_stream/2`.
  defp dispatch("resources/list", id, _params, handler, opts) do
    resources = handler.list_resources(opts) |> Enum.sort_by(&resource_sort_key/1)
    {:reply, result(id, cacheable(%{resources: resources}, @resources_ttl_ms, opts))}
  end

  # We publish concrete `ui://` resources, never templated ones — but the method
  # must exist for clients that probe it before `resources/list`.
  defp dispatch("resources/templates/list", id, _params, _handler, opts) do
    {:reply, result(id, cacheable(%{resourceTemplates: []}, @resources_ttl_ms, opts))}
  end

  defp dispatch("resources/read", id, params, handler, opts) do
    case Map.get(params, "uri") do
      uri when is_binary(uri) ->
        case handler.read_resource(uri, opts) do
          {:ok, contents} ->
            {:reply, result(id, cacheable(%{contents: contents}, @resources_ttl_ms, opts))}

          {:error, :not_found} ->
            {:reply,
             error(id, -32_602, "Invalid params: unknown resource uri", %{
               code: "resource_not_found",
               uri: uri
             })}
        end

      _ ->
        {:reply, error(id, -32_602, "Invalid params: uri is required")}
    end
  end

  defp dispatch("subscriptions/listen", id, params, handler, opts) do
    if revision(opts) == :v2026 and client_extension?(params, @tasks_extension) do
      {:stream, subscription(id, params, handler, opts)}
    else
      {:error, error(id, -32_601, "Method not found", %{name: "subscriptions/listen"})}
    end
  end

  defp dispatch("tasks/get", id, params, handler, opts) do
    with_task(id, params, handler, opts, fn task_id, owner ->
      case MCPTasks.get(task_id, owner) do
        {:ok, task} -> result(id, task)
        {:error, :unknown_task} -> unknown_task_error(id)
      end
    end)
  end

  defp dispatch("tasks/update", id, params, handler, opts) do
    with_task(id, params, handler, opts, fn task_id, owner ->
      responses = Map.get(params, "inputResponses", %{}) || %{}

      case MCPTasks.update(task_id, owner, responses) do
        :ok -> result(id, %{})
        {:error, :unknown_task} -> unknown_task_error(id)
      end
    end)
  end

  defp dispatch("tasks/cancel", id, params, handler, opts) do
    with_task(id, params, handler, opts, fn task_id, owner ->
      case MCPTasks.cancel(task_id, owner) do
        :ok -> result(id, %{})
        {:error, :unknown_task} -> unknown_task_error(id)
      end
    end)
  end

  defp dispatch("tools/call", id, params, handler, opts) do
    case MCPCapabilityScope.prepare_call(params, opts) do
      {:ok, scoped_params} ->
        if task_augmented?(params, handler, opts) do
          {:reply, create_task(id, scoped_params, handler, opts)}
        else
          {:reply, handler.call_tool(id, scoped_params, opts)}
        end

      {:error, reason} ->
        {:reply,
         error(id, -32_003, "Agent capability does not permit this tool call", %{
           code: "agent_capability_tool_forbidden",
           reason: Atom.to_string(reason)
         })}
    end
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

  defp server_capabilities(handler, opts) do
    extensions = %{@tasks_extension => %{}}

    # Declare the UI extension only when this server actually publishes an app
    # resource — "has resources" is not the same claim as "renders UI".
    extensions =
      if Enum.any?(handler.list_resources(opts), &(&1[:mimeType] == @ui_mime_type)),
        do: Map.put(extensions, @ui_extension, %{}),
        else: extensions

    %{
      tools: %{listChanged: false},
      resources: %{listChanged: false},
      extensions: extensions
    }
  end

  defp resource_sort_key(resource), do: Map.get(resource, :uri) || Map.get(resource, "uri") || ""

  # Task augmentation is server-directed but client-gated: the extension requires
  # that we never hand a task to a client that did not declare support. The tool
  # must also be one its handler nominated as safe to run detached.
  defp task_augmented?(params, handler, opts) do
    revision(opts) == :v2026 and
      client_extension?(params, @tasks_extension) and
      tool_name(params) in handler.task_tools()
  end

  defp create_task(id, params, handler, opts) do
    owner = task_owner(handler, opts)

    # The worker re-enters the handler exactly as a synchronous call would, then
    # unwraps the envelope: a tool-level fault is a *completed* task carrying an
    # error result, while a JSON-RPC error is a *failed* task.
    #
    # `task_augmented: true` lets a handler behave differently when detached — a
    # wait, for instance, may keep waiting instead of returning at its
    # connection-bound cap — and `task_id` lets it check for cancellation.
    work = fn task_id ->
      worker_opts =
        opts
        |> Keyword.put(:task_augmented, true)
        |> Keyword.put(:task_id, task_id)

      case handler.call_tool(id, params, worker_opts) do
        %{result: result} -> {:ok, result}
        %{error: error} -> {:error, error}
      end
    end

    {:ok, task_id} = MCPTasks.run(owner, work, status_message: "Running #{tool_name(params)}")

    result(id, %{
      resultType: "task",
      taskId: task_id,
      status: "working",
      createdAt: DateTime.utc_now() |> DateTime.to_iso8601(),
      lastUpdatedAt: DateTime.utc_now() |> DateTime.to_iso8601(),
      ttlMs: MCPTasks.ttl_ms(),
      pollIntervalMs: MCPTasks.poll_interval_ms()
    })
  end

  # Resolve the caller identity a task is bound to. Same-token, same-workspace
  # callers share an owner; that is the trust boundary they already share.
  defp task_owner(handler, opts) do
    %{
      server: handler.server_name(),
      workspace_id: Keyword.get(opts, :default_workspace_id),
      actor: Keyword.get(opts, :actor),
      capability_id:
        case Keyword.get(opts, :agent_capability) do
          %{id: id} -> id
          _ -> nil
        end
    }
  end

  # We emit exactly one notification type, so the acknowledged filter is the
  # caller's requested task ids narrowed to the ones they actually own. Every
  # other requested type is omitted — the spec reads an omission as "not
  # honoured", which is truthful here: our tool and resource lists only change
  # on deploy, so we would never fire those notifications.
  defp subscription(id, params, handler, opts) do
    owner = task_owner(handler, opts)

    task_ids =
      params
      |> Map.get("notifications", %{})
      |> case do
        %{} = filter -> Map.get(filter, "taskIds", [])
        _ -> []
      end
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and match?({:ok, _}, MCPTasks.get(&1, owner))))

    %{
      id: id,
      task_ids: task_ids,
      notifications: if(task_ids == [], do: %{}, else: %{taskIds: task_ids})
    }
  end

  defp with_task(id, params, handler, opts, fun) do
    cond do
      revision(opts) != :v2026 or not client_extension?(params, @tasks_extension) ->
        {:error, error(id, -32_601, "Method not found", %{name: "tasks/*"})}

      not is_binary(Map.get(params, "taskId")) ->
        {:reply, error(id, -32_602, "Invalid params: taskId is required")}

      true ->
        {:reply, fun.(Map.get(params, "taskId"), task_owner(handler, opts))}
    end
  end

  # Deliberately indistinguishable from "not yours", so a caller cannot probe for
  # another agent's task ids.
  defp unknown_task_error(id) do
    error(id, -32_602, "Invalid params: unknown taskId", %{code: "unknown_task"})
  end

  defp tool_name(params) when is_map(params) do
    case Map.get(params, "name") do
      name when is_binary(name) -> name
      _ -> nil
    end
  end

  defp tool_name(_params), do: nil

  # `CacheableResult`: `ttlMs` is a freshness hint; `cacheScope` decides whether
  # a shared intermediary may cache. Both are 2026-07-28 additions, so they are
  # omitted for legacy clients.
  #
  # SECURITY: `tools/list` is filtered per agent-capability token, so a scoped
  # list marked "public" could be replayed by an intermediary to a different
  # agent. Scoped ⇒ "private", always.
  defp cacheable(result, ttl_ms, opts) do
    case revision(opts) do
      :v2026 ->
        scope = if MCPCapabilityScope.scoped?(opts), do: "private", else: "public"
        Map.merge(result, %{ttlMs: ttl_ms, cacheScope: scope})

      :legacy ->
        result
    end
  end

  defp tool_sort_key(tool), do: Map.get(tool, :name) || Map.get(tool, "name") || ""

  # The Streamable HTTP transport returns an Mcp-Session-Id header on the
  # initialize response; clients may open a server→client SSE channel with that
  # id to receive notifications/* pushes.
  #
  # Reached only from `initialize`, so only legacy clients ever see it — which is
  # what we want, since 2026-07-28 removed both the header and the GET channel it
  # describes. `server/discover` deliberately returns bare `instructions/1`.
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
    err = Map.put(err, :data, error_data(data))
    %{jsonrpc: "2.0", id: id, error: err}
  end

  defp error_data(nil), do: %{error_version: @error_version}
  defp error_data(%{} = data), do: Map.put_new(data, :error_version, @error_version)

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

  @doc "The running `:casein` application version, for `serverInfo.version`."
  @spec server_version() :: String.t()
  def server_version do
    case Application.spec(:casein, :vsn) do
      vsn when is_list(vsn) -> to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
