defmodule CaseinWeb.API.MCPToolSearch do
  @moduledoc """
  Opt-in tool-discovery front-end for Casein's MCP servers.

  Casein's per-runtime MCP surface is large (terminal ~17, preview ~25, artifact,
  tidewave), and flat-injecting every tool schema into an agent's context costs
  tokens and, past ~30-50 tools, hurts tool-selection accuracy. When enabled
  (`DEV_IDE_MCP_TOOL_SEARCH=1`), `tools/list` advertises only a small always-on
  CORE set plus two meta-tools — `search_tools` and `invoke_tool`. The long tail
  is reached on demand: `search_tools(query)` returns matching tool schemas, then
  `invoke_tool(name, arguments)` runs one, dispatched through the server's normal
  scope + audit path.

  This is deliberately the **client-agnostic** design: it does NOT rely on MCP
  `tools/list_changed` re-fetching (which Casein advertises as `false` and which
  grok/codex/claude do not reliably honor), so the reduced surface + on-demand
  discovery behave identically across every client. The hot control loop
  (`terminal_list_sessions`, `terminal_topology`, `terminal_capture`,
  `terminal_send_agent_command`, `terminal_wait_agent_state`) stays in CORE, so
  an agent never needs a retrieval round-trip to drive a session.

  Disabled by default: `tools/list` returns the full set (unchanged). The two
  meta-tools are always *callable* (they route through the same auth/scope/audit
  as any tool); the flag only controls what `tools/list` advertises, so toggling
  it is purely a context optimization, never a capability change.
  """

  alias Casein.Agents.MCPError
  alias CaseinWeb.API.MCPEnvelope

  @meta_tool_names ~w(search_tools invoke_tool)

  # The Casein-authored MCP servers that share one cross-server tool catalog.
  # search_tools ranks over all of them and invoke_tool routes to the owner, so
  # an agent connected to ANY endpoint can discover and run every Casein tool.
  # Tidewave is excluded on purpose (dev-only, third-party plug — no seam).
  @surface_modules [
    {"terminal", CaseinWeb.API.TerminalMCP},
    {"preview", CaseinWeb.API.PreviewMCP},
    {"artifact", CaseinWeb.API.ArtifactMCP}
  ]

  # Always-on core per surface: the tools an agent needs every loop, which must
  # never depend on a discovery round-trip. Surfaces absent here are not filtered
  # (their handler simply doesn't call list_tools/2).
  @core_tools %{
    terminal: ~w(
      terminal_context
      terminal_list_sessions
      terminal_topology
      terminal_capture
      terminal_send_agent_command
      terminal_wait_agent_state
    ),
    preview: ~w(
      preview_surfaces
      preview_open_app
      preview_navigate
      preview_observe_live
      preview_elements
      preview_click
      preview_type
      preview_screenshot
    )
  }

  # Generic intent synonyms expand a query before lexical matching, so
  # paraphrased asks still hit ("take a picture" -> screenshot, "kill the pane"
  # -> close). Deliberately domain-generic and small; a neural embedding backend
  # is the natural upgrade if this catalog ever outgrows hand-tuned synonyms.
  @synonyms %{
    "picture" => ~w(screenshot image),
    "screenshot" => ~w(image capture),
    "image" => ~w(screenshot),
    "kill" => ~w(close stop terminate),
    "close" => ~w(kill stop),
    "stop" => ~w(close kill),
    "logs" => ~w(log output scrollback capture),
    "log" => ~w(logs output scrollback),
    "output" => ~w(capture logs scrollback),
    "scrollback" => ~w(capture output),
    "label" => ~w(name rename tag),
    "rename" => ~w(label name),
    "click" => ~w(press tap select),
    "press" => ~w(click key),
    "tap" => ~w(click),
    "type" => ~w(input fill enter text),
    "input" => ~w(type fill text),
    "fill" => ~w(type input),
    "list" => ~w(show enumerate),
    "show" => ~w(list),
    "state" => ~w(status ready done),
    "status" => ~w(state),
    "worktree" => ~w(branch checkout),
    "annotate" => ~w(annotation note comment),
    "note" => ~w(annotation annotate),
    "record" => ~w(capture video),
    "storage" => ~w(cookies localstorage),
    "navigate" => ~w(goto url visit),
    "open" => ~w(launch start)
  }

  @default_search_limit 5
  @max_search_limit 25

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:casein, :mcp_tool_search, false)

  @doc "True for the meta-tool names (`search_tools`, `invoke_tool`)."
  @spec meta_tool?(String.t()) :: boolean()
  def meta_tool?(name) when is_binary(name), do: name in @meta_tool_names
  def meta_tool?(_), do: false

  @doc """
  When enabled, reduce a server's full tool-spec list to its CORE set plus the
  two meta-tools; otherwise return it unchanged.
  """
  @spec list_tools([map()], atom()) :: [map()]
  def list_tools(specs, surface) do
    # Only reduce a surface that has a defined CORE set; a surface with no core
    # (e.g. artifact, which is small enough that flat-listing beats core+meta)
    # is returned unchanged even when the flag is on.
    case enabled?() and Map.get(@core_tools, surface) do
      core when is_list(core) ->
        Enum.filter(specs, &(spec_name(&1) in core)) ++ [search_tool_spec(), invoke_tool_spec()]

      _ ->
        specs
    end
  end

  @doc "Apply generic discovery reduction unless an exact agent capability owns the list."
  @spec list_tools([map()], atom(), keyword()) :: [map()]
  def list_tools(specs, surface, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :agent_capability), do: specs, else: list_tools(specs, surface)
  end

  @doc """
  Rank `specs` against a natural-language `query` (lexical token overlap over
  tool name + description) and return the top matches as a tool payload the
  agent can act on with `invoke_tool`.
  """
  @spec search([map()], String.t(), keyword()) :: map()
  def search(specs, query, opts \\ []) when is_binary(query) do
    limit = opts |> Keyword.get(:limit, @default_search_limit) |> clamp_limit()
    q_tokens = query |> tokenize() |> expand_tokens()
    ql = String.downcase(query)

    matches =
      specs
      |> Enum.reject(&(spec_name(&1) in @meta_tool_names))
      |> Enum.map(&{score(&1, q_tokens, ql), &1})
      |> Enum.filter(fn {score, _spec} -> score > 0 end)
      |> Enum.sort_by(fn {score, spec} -> {-score, spec_name(spec)} end)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, spec} ->
        %{
          name: spec_name(spec),
          server: Map.get(spec, :server),
          description: spec_desc(spec),
          inputSchema: Map.get(spec, :inputSchema) || Map.get(spec, "inputSchema")
        }
      end)

    %{
      query: query,
      match_count: length(matches),
      matches: matches,
      next:
        "Run any of these with invoke_tool from this same endpoint (it routes to " <>
          "the owning server): " <>
          ~s({"name": "<name above>", "arguments": {...per its inputSchema...}}.)
    }
  end

  @doc """
  The combined tool catalog across every Casein MCP server, each spec tagged
  with its owning `:server`. `search_tools` ranks over this, so an agent on any
  one endpoint can discover every Casein tool (not just its own server's).
  """
  @spec catalog() :: [map()]
  def catalog do
    for {server, mod} <- @surface_modules,
        spec <- mod.tool_specs() do
      Map.put(spec, :server, server)
    end
  end

  @doc """
  Handle a `search_tools` tool call: rank the cross-server catalog for the
  call's `query`/`limit` and wrap the result as an MCP tool payload.
  """
  @spec search_result(term(), map()) :: map()
  def search_result(id, args) when is_map(args) do
    query = to_string(Map.get(args, "query") || Map.get(args, :query) || "")

    limit_opts =
      case Map.get(args, "limit") || Map.get(args, :limit) do
        n when is_integer(n) -> [limit: n]
        _ -> []
      end

    payload = search(catalog(), query, limit_opts)

    MCPEnvelope.result(id, %{
      content: [MCPEnvelope.text(payload)],
      structuredContent: MCPEnvelope.jsonable(payload)
    })
  end

  @doc """
  Handle an `invoke_tool` tool call: find the server that owns the requested
  tool and run it through THAT server's normal scope + audit dispatch (so
  workspace scoping and audit are preserved regardless of which endpoint the
  agent called from). Refuses missing names and the meta-tools themselves, and
  returns a tool error when no server owns the name.
  """
  @spec route_invoke(term(), map(), keyword()) :: map()
  def route_invoke(id, args, opts) when is_map(args) do
    case invoke_target(args) do
      {nil, _inner} ->
        tool_error(id, :invoke_tool_requires_name)

      {name, _inner} when name in @meta_tool_names ->
        tool_error(id, :invoke_tool_cannot_call_meta_tool)

      {name, inner} ->
        case owning_module(name) do
          nil -> tool_error(id, {:invoke_tool_unknown_tool, name})
          mod -> mod.call_tool(id, %{"name" => name, "arguments" => inner}, opts)
        end
    end
  end

  @doc "The server module that owns `name`, or nil if no Casein server does."
  @spec owning_module(String.t()) :: module() | nil
  def owning_module(name) when is_binary(name) do
    Enum.find_value(@surface_modules, fn {_server, mod} ->
      if name in Enum.map(mod.tool_specs(), &spec_name/1), do: mod
    end)
  end

  defp tool_error(id, reason) do
    err = MCPError.tool_result(reason)

    MCPEnvelope.result(id, %{
      err
      | structuredContent: MCPEnvelope.jsonable(err.structuredContent)
    })
  end

  @doc """
  Extract the inner `{name, arguments}` from an `invoke_tool` call's arguments.
  Returns `{nil, %{}}` when no name is supplied.
  """
  @spec invoke_target(map()) :: {String.t() | nil, map()}
  def invoke_target(args) when is_map(args) do
    name = args |> Map.get("name", Map.get(args, :name)) |> normalize_name()
    inner = Map.get(args, "arguments") || Map.get(args, :arguments) || %{}
    {name, inner}
  end

  @doc "MCP spec for the `search_tools` meta-tool."
  @spec search_tool_spec() :: map()
  def search_tool_spec do
    %{
      name: "search_tools",
      description:
        "Find a Casein tool by natural-language intent, across ALL Casein MCP " <>
          "servers (terminal, preview, artifact) — not just this endpoint's. " <>
          "Returns matching tool names (each tagged with its `server`) + input " <>
          "schemas; then call invoke_tool with one from this same endpoint. Use " <>
          "for the long tail and for tools that live on another server.",
      inputSchema: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: ~s(What you want to do, in words — e.g. "label an agent pane".)
          },
          limit: %{
            type: "integer",
            description:
              "Max results (default #{@default_search_limit}, max #{@max_search_limit})."
          }
        },
        required: ["query"]
      },
      outputSchema: %{type: "object", additionalProperties: true},
      annotations: %{
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      }
    }
  end

  @doc "MCP spec for the `invoke_tool` meta-tool."
  @spec invoke_tool_spec() :: map()
  def invoke_tool_spec do
    %{
      name: "invoke_tool",
      description:
        "Invoke a Casein tool by name with its arguments — used to run a tool " <>
          "discovered via search_tools, including one that lives on a different " <>
          "server (invoke_tool routes to the owning server). Runs through the " <>
          "same auth, workspace scoping, and audit as a direct call.",
      inputSchema: %{
        type: "object",
        properties: %{
          name: %{type: "string", description: "The exact tool name from search_tools."},
          arguments: %{
            type: "object",
            description: "The target tool's arguments object (per its inputSchema)."
          }
        },
        required: ["name"]
      },
      outputSchema: %{type: "object", additionalProperties: true},
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      }
    }
  end

  # --- internals -------------------------------------------------------------

  defp score(spec, q_tokens, ql) do
    name = spec |> spec_name() |> String.downcase()
    desc = (spec_desc(spec) || "") |> String.downcase()
    haystack = name <> " " <> desc

    token_hits = Enum.count(q_tokens, &String.contains?(haystack, &1))
    name_hits = Enum.count(q_tokens, &String.contains?(name, &1))
    phrase_bonus = if ql != "" and String.contains?(desc, ql), do: 3, else: 0

    token_hits + name_hits * 2 + phrase_bonus
  end

  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/, trim: true)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
  end

  defp expand_tokens(tokens) do
    (tokens ++ Enum.flat_map(tokens, &Map.get(@synonyms, &1, []))) |> Enum.uniq()
  end

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_search_limit)
  defp clamp_limit(_), do: @default_search_limit

  defp spec_name(spec), do: to_string(Map.get(spec, :name) || Map.get(spec, "name"))
  defp spec_desc(spec), do: Map.get(spec, :description) || Map.get(spec, "description")

  defp normalize_name(name) when is_binary(name) and name != "", do: name
  defp normalize_name(_), do: nil
end
