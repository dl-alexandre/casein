defmodule DevIdeWeb.API.ArtifactMCP do
  @moduledoc """
  MCP JSON-RPC handler for DevIDE artifact project tools.

  This surface lets external agents create, edit, list, serve, and snapshot
  artifact project worktrees. It returns preview handoff arguments instead of
  driving browser panes directly; agents should call Preview MCP with the
  returned `preview_open_arguments` when a visible preview is needed.
  """

  @behaviour DevIdeWeb.API.MCPEnvelope

  alias DevIDE.Agents.{ArtifactTools, MCPAudit, MCPError}
  alias DevIDE.MCP.Scope
  alias DevIdeWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "DevIDE Artifact MCP Server"

  @type outcome :: MCPEnvelope.outcome()

  @doc "Handle a single decoded JSON-RPC message."
  @spec handle(map(), keyword()) :: outcome()
  def handle(message, opts \\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  @impl true
  def server_name, do: @server_name

  @impl true
  def instructions(opts) do
    MCPWorkspaceScope.scoped_instructions(
      "Artifact project tools for DevIDE workspaces. Use artifact_create to " <>
        "create an isolated Git worktree-backed static/html artifact, artifact_update " <>
        "to iterate, artifact_list/artifact_get to rediscover state, artifact_serve " <>
        "to ensure its preview server is running, and artifact_snapshot to create " <>
        "an explicit Git version marker. Tool results include preview_open_arguments; " <>
        "pass those arguments to Preview MCP preview_open to make the artifact visible.",
      MCPWorkspaceScope.default_workspace_id(opts)
    )
  end

  @impl true
  def list_tools(opts) do
    # Artifact has no MCPToolSearch core (only ~6 tools — core+meta would be
    # larger than the full list), so this returns the full set unchanged; the
    # routing is here so artifact adopts tool-search for free if it ever grows.
    tool_specs()
    |> MCPToolSearch.list_tools(:artifact)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
  end

  @doc "MCP tool specifications, mapped from ArtifactTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- ArtifactTools.definitions() do
      tool
      |> base_tool_spec()
      |> maybe_put_metadata(tool)
    end
  end

  defp base_tool_spec(tool) do
    %{name: tool.name, description: tool.description, inputSchema: tool.parameters}
  end

  defp maybe_put_metadata(spec, tool) do
    case Tool.public_metadata(tool) do
      nil -> spec
      metadata -> Map.put(spec, :metadata, metadata)
    end
  end

  @impl true
  # Meta-tools: callable here too so cross-server search/invoke work from the
  # artifact endpoint (they are not advertised in this server's tools/list —
  # artifact has no MCPToolSearch core — but stay always-callable).
  def call_tool(id, %{"name" => "search_tools"} = params, _opts),
    do: MCPToolSearch.search_result(id, Map.get(params, "arguments", %{}) || %{})

  def call_tool(id, %{"name" => "invoke_tool"} = params, opts),
    do: MCPToolSearch.route_invoke(id, Map.get(params, "arguments", %{}) || %{}, opts)

  def call_tool(id, %{"name" => name} = params, opts) do
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    args = Map.get(params, "arguments", %{}) || %{}
    audit_opts = [actor: Keyword.get(opts, :actor)]

    result =
      DevIDE.Signals.Context.with_new(fn ->
        case Scope.resolve_tool_call(name, args,
               surface: :artifact,
               default_workspace_id: default_workspace_id,
               require_workspace?: true
             ) do
          {:ok, scope} ->
            case ArtifactTools.invoke(name, scope.args) do
              {:ok, payload} = ok ->
                _ = MCPAudit.record_artifact(scope.workspace_id, name, scope.args, ok, audit_opts)
                {:ok, payload}

              {:error, reason} = err ->
                _ =
                  MCPAudit.record_artifact(scope.workspace_id, name, scope.args, err, audit_opts)

                {:error, reason}
            end

          {:error, reason} = err ->
            _ = MCPAudit.record_artifact(nil, name, args, err, audit_opts)
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
