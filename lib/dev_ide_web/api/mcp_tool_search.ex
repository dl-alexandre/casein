defmodule DevIdeWeb.API.MCPToolSearch do
  @moduledoc """
  Opt-in tool-discovery front-end for DevIDE's MCP servers.

  DevIDE's per-runtime MCP surface is large (terminal ~17, preview ~25, artifact,
  tidewave), and flat-injecting every tool schema into an agent's context costs
  tokens and, past ~30-50 tools, hurts tool-selection accuracy. When enabled
  (`DEV_IDE_MCP_TOOL_SEARCH=1`), `tools/list` advertises only a small always-on
  CORE set plus two meta-tools — `search_tools` and `invoke_tool`. The long tail
  is reached on demand: `search_tools(query)` returns matching tool schemas, then
  `invoke_tool(name, arguments)` runs one, dispatched through the server's normal
  scope + audit path.

  This is deliberately the **client-agnostic** design: it does NOT rely on MCP
  `tools/list_changed` re-fetching (which DevIDE advertises as `false` and which
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

  @meta_tool_names ~w(search_tools invoke_tool)

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
    )
  }

  @default_search_limit 5
  @max_search_limit 25

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dev_ide, :mcp_tool_search, false)

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
    if enabled?() do
      core = Map.get(@core_tools, surface, [])
      Enum.filter(specs, &(spec_name(&1) in core)) ++ [search_tool_spec(), invoke_tool_spec()]
    else
      specs
    end
  end

  @doc """
  Rank `specs` against a natural-language `query` (lexical token overlap over
  tool name + description) and return the top matches as a tool payload the
  agent can act on with `invoke_tool`.
  """
  @spec search([map()], String.t(), keyword()) :: map()
  def search(specs, query, opts \\ []) when is_binary(query) do
    limit = opts |> Keyword.get(:limit, @default_search_limit) |> clamp_limit()
    q_tokens = tokenize(query)
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
          description: spec_desc(spec),
          inputSchema: Map.get(spec, :inputSchema) || Map.get(spec, "inputSchema")
        }
      end)

    %{
      query: query,
      match_count: length(matches),
      matches: matches,
      next:
        "Run one of these with invoke_tool: " <>
          ~s({"name": "<name above>", "arguments": {...per its inputSchema...}}.)
    }
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
        "Find a DevIDE tool by natural-language intent when the tool you need is " <>
          "not in the small core set. Returns matching tool names + input schemas; " <>
          "then call invoke_tool with one. Use for the long tail (annotations, agent " <>
          "labels, worktree/state reporting, preview/artifact ops).",
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
      }
    }
  end

  @doc "MCP spec for the `invoke_tool` meta-tool."
  @spec invoke_tool_spec() :: map()
  def invoke_tool_spec do
    %{
      name: "invoke_tool",
      description:
        "Invoke a DevIDE tool by name with its arguments — used to run a tool " <>
          "discovered via search_tools that is not in the core set. Runs through " <>
          "the same auth, workspace scoping, and audit as a direct call.",
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

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_search_limit)
  defp clamp_limit(_), do: @default_search_limit

  defp spec_name(spec), do: to_string(Map.get(spec, :name) || Map.get(spec, "name"))
  defp spec_desc(spec), do: Map.get(spec, :description) || Map.get(spec, "description")

  defp normalize_name(name) when is_binary(name) and name != "", do: name
  defp normalize_name(_), do: nil
end
