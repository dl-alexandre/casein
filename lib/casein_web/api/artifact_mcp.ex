defmodule CaseinWeb.API.ArtifactMCP do
  @moduledoc """
  MCP JSON-RPC handler for Casein artifact project tools.

  This surface lets external agents create, edit, list, serve, and snapshot
  artifact project worktrees. It returns preview handoff arguments instead of
  driving browser panes directly; agents should call Preview MCP with the
  returned `preview_open_arguments` when a visible preview is needed.
  """

  @behaviour CaseinWeb.API.MCPEnvelope

  alias Casein.Agents.{ArtifactTools, MCPAudit, MCPError}
  alias Casein.MCP.Scope
  alias CaseinWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "Casein Artifact MCP Server"

  @ui_resource_uri "ui://casein-artifact/artifact-app.html"
  @ui_mime_type "text/html;profile=mcp-app"

  # Baked in at compile time, following Casein.Terminals.ToolThemes. The view is
  # a static asset shipped with the release, so reading it per `resources/read`
  # bought nothing — and this way a missing asset fails the build instead of
  # degrading to "no such resource" in production. `@external_resource` makes an
  # edit to the HTML trigger a recompile.
  @ui_app_path Path.expand(Path.join("priv", "mcp_apps/artifact_app.html"))
  @external_resource @ui_app_path
  @ui_app_html File.read!(@ui_app_path)

  # Tools whose result describes a single artifact, so the viewer has something
  # to render. artifact_list (many) and artifact_retire (gone) do not qualify.
  @ui_tools ~w(artifact_create artifact_update artifact_get artifact_serve artifact_snapshot)

  @type outcome :: MCPEnvelope.outcome()

  @doc "Handle a single decoded JSON-RPC message."
  @spec handle(map(), keyword()) :: outcome()
  def handle(message, opts \\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  @impl true
  def server_name, do: @server_name

  @impl true
  def instructions(opts) do
    MCPWorkspaceScope.scoped_instructions(
      "Artifact project tools for Casein workspaces. Use artifact_create to " <>
        "create an isolated Git worktree-backed static/html artifact, artifact_update " <>
        "to iterate, artifact_list/artifact_get to rediscover state, artifact_serve " <>
        "to ensure its preview server is running, artifact_verify to prove public-file parity, " <>
        "and artifact_snapshot to create " <>
        "an explicit Git version marker. Tool results include preview_open_arguments; " <>
        "pass those arguments to Preview MCP preview_open to make the artifact visible. " <>
        "Hosts that support MCP Apps render the artifact viewer inline instead, so no " <>
        "preview handoff is needed there.",
      MCPWorkspaceScope.default_workspace_id(opts)
    )
  end

  @impl true
  # Artifact builds are the candidate here, but they mutate a git worktree, so
  # they are not safe to abandon on cancel without cooperative checks.
  def task_tools, do: []

  @impl true
  # The artifact viewer, rendered inline by MCP Apps hosts. Serving this is what
  # lets an artifact be *seen* without the caller having a Casein viewer open and
  # hand-carrying preview_open_arguments over to Preview MCP.
  def list_resources(_opts) do
    [
      %{
        uri: @ui_resource_uri,
        name: "Casein artifact viewer",
        description:
          "Interactive view of the artifact a tool just created, updated, or served, " <>
            "including its public URL.",
        mimeType: @ui_mime_type
      }
    ]
  end

  @impl true
  def read_resource(@ui_resource_uri, _opts) do
    {:ok, [%{uri: @ui_resource_uri, mimeType: @ui_mime_type, text: @ui_app_html}]}
  end

  def read_resource(_uri, _opts), do: {:error, :not_found}

  @impl true
  def list_tools(opts) do
    # Artifact has no MCPToolSearch core (only ~6 tools — core+meta would be
    # larger than the full list), so this returns the full set unchanged; the
    # routing is here so artifact adopts tool-search for free if it ever grows.
    tool_specs()
    |> MCPToolSearch.list_tools(:artifact, opts)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
  end

  @doc "MCP tool specifications, mapped from ArtifactTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    ArtifactTools.definitions()
    |> Enum.map(&Tool.mcp_spec/1)
    |> Enum.map(&attach_ui_template/1)
  end

  # `_meta.ui.resourceUri` is what makes a tool an MCP App: a host that supports
  # the extension preloads the resource and renders the result through it.
  # Ignored by every other client, so this is additive.
  defp attach_ui_template(%{name: name} = spec) when name in @ui_tools,
    do: Map.put(spec, :_meta, %{ui: %{resourceUri: @ui_resource_uri}})

  defp attach_ui_template(spec), do: spec

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
      Casein.Signals.Context.with_new(fn ->
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
            # Scope resolution failed, so `args` is untrusted — attribute the
            # failure to the endpoint's authenticated workspace (nil on
            # non-pre-scoped endpoints, which skips the durable row).
            _ = MCPAudit.record_artifact(default_workspace_id, name, args, err, audit_opts)
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
