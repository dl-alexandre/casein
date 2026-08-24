defmodule CaseinWeb.API.CodeMCP do
  @moduledoc """
  MCP JSON-RPC handler for Casein worktree-scoped code tools.

  Headless workers read, search, patch, and run allowlisted verifiers without
  a tmux pane. Terminal MCP stays unchanged for interactive OpenCode use.
  """

  @behaviour CaseinWeb.API.MCPEnvelope

  alias Casein.Agents.{CodeTools, MCPAudit, MCPError}
  alias Casein.MCP.Scope
  alias CaseinWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "Casein Code MCP Server"

  @type outcome :: MCPEnvelope.outcome()

  @doc "Handle a single decoded JSON-RPC message."
  @spec handle(map(), keyword()) :: outcome()
  def handle(message, opts \\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  @impl true
  def server_name, do: @server_name

  @impl true
  def instructions(opts) do
    MCPWorkspaceScope.scoped_instructions(
      "Worktree-scoped code tools for headless Casein workers. Use code_read " <>
        "for bounded file/range reads, code_search for capped text search, " <>
        "code_apply_patch for validated unified diffs, and code_exec for " <>
        "server-owned verifier ids (not a raw shell). Every call requires " <>
        "worktree_path for the assigned attempt. Absolute paths, traversal, " <>
        "backslashes, NULs, and .git are rejected.",
      MCPWorkspaceScope.default_workspace_id(opts)
    )
  end

  @impl true
  def task_tools, do: []

  @impl true
  def list_resources(_opts), do: []

  @impl true
  def read_resource(_uri, _opts), do: {:error, :not_found}

  @impl true
  def list_tools(opts) do
    tool_specs()
    |> MCPToolSearch.list_tools(:code, opts)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
  end

  @doc "MCP tool specifications, mapped from CodeTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    Enum.map(CodeTools.definitions(), &Tool.mcp_spec/1)
  end

  @impl true
  def call_tool(id, %{"name" => "search_tools"} = params, _opts),
    do: MCPToolSearch.search_result(id, Map.get(params, "arguments", %{}) || %{})

  def call_tool(id, %{"name" => "invoke_tool"} = params, opts),
    do: MCPToolSearch.route_invoke(id, Map.get(params, "arguments", %{}) || %{}, opts)

  def call_tool(id, %{"name" => name} = params, opts) do
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    args = Map.get(params, "arguments", %{}) || %{}
    audit_opts = [actor: Keyword.get(opts, :actor)]

    result =
      Casein.Signals.Context.with_new(fn ->
        case Scope.resolve_tool_call(name, args,
               surface: :code,
               default_workspace_id: default_workspace_id,
               require_workspace?: true
             ) do
          {:ok, scope} ->
            case CodeTools.invoke(name, scope.args, %{actor: Keyword.get(opts, :actor)}) do
              {:ok, payload} = ok ->
                _ = MCPAudit.record_code(scope.workspace_id, name, scope.args, ok, audit_opts)
                {:ok, payload}

              {:error, reason} = err ->
                _ = MCPAudit.record_code(scope.workspace_id, name, scope.args, err, audit_opts)
                {:error, reason}
            end

          {:error, reason} = err ->
            _ = MCPAudit.record_code(default_workspace_id, name, args, err, audit_opts)
            {:error, reason}
        end
      end)

    case result do
      {:ok, payload} ->
        MCPEnvelope.result(id, %{
          content: [MCPEnvelope.text(payload)],
          structuredContent: MCPEnvelope.jsonable(payload)
        })

      {:error, reason} ->
        err = MCPError.tool_result(reason)

        MCPEnvelope.result(id, %{
          err
          | structuredContent: MCPEnvelope.jsonable(err.structuredContent)
        })
    end
  end

  def call_tool(id, _params, _opts) do
    MCPEnvelope.error(id, -32_602, "Invalid params: tool name is required")
  end
end
