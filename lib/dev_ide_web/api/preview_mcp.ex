defmodule DevIdeWeb.API.PreviewMCP do
  @moduledoc """
  Minimal MCP (Model Context Protocol) JSON-RPC handler that exposes
  `DevIDE.Agents.PreviewTools` to external coding agents (Grok, Claude,
  Codex, opencode).

  It speaks the same wire shape as Tidewave's MCP server — JSON-RPC 2.0 over
  a single HTTP POST endpoint — but lives in this app on its own route. DevIDE
  runs its own MCP route rather than registering tools into Tidewave, giving
  agents a real, discoverable tool surface for preview control without coupling
  to Tidewave's tool registry.

  The JSON-RPC envelope (routing, `initialize`, `ping`, response helpers,
  protocol-version negotiation) lives in `DevIdeWeb.API.MCPEnvelope`; this module
  implements only the preview-specific behaviour callbacks. The handler is pure:
  it returns `{:reply, map}` (a 200 response), `:noreply` (a notification — 202,
  no body), or `{:error, map}` (a protocol-level JSON-RPC error). The thin
  `PreviewMCPController` owns the HTTP plumbing.
  """

  @behaviour DevIdeWeb.API.MCPEnvelope

  alias DevIDE.Agents.{MCPAudit, MCPError, PreviewTools}
  alias DevIDE.MCP.Scope
  alias DevIdeWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "DevIDE Preview MCP Server"

  @type outcome :: MCPEnvelope.outcome()

  @doc """
  Handle a single decoded JSON-RPC message.
  """
  @spec handle(map(), keyword()) :: outcome()
  def handle(message, opts \\ []), do: MCPEnvelope.handle(message, __MODULE__, opts)

  @impl true
  def server_name, do: @server_name

  @impl true
  def instructions(opts) do
    workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    tmux_session = default_tmux_session(opts)

    MCPWorkspaceScope.scoped_instructions(
      "Preview control tools for the current workspace. Call preview_surfaces " <>
        "to list named surfaces (manager URLs, host loopback DevIDE, and " <>
        "terminal-detected localhost ports), then preview_open_here, preview_open_app, or " <>
        "preview_open_localhost to start a session. Loopback surfaces are liveness-probed " <>
        "at listing time: skip surfaces with server_active=false " <>
        "(server_status.liveness=\"dead\") — their registration outlived the server. " <>
        "Opens preflight the " <>
        "target URL before creating or reusing a tmux preview pane; dead " <>
        "localhost ports and HTTP 404/5xx responses return an error and " <>
        "open no pane. Reuse an existing pane by default. Use " <>
        "new_control_session only for a fresh browser runtime on that pane, " <>
        "and close an existing preview pane before opening if a truly fresh tmux pane " <>
        "is needed; open calls keep one pane per surface origin. preview_open_app on " <>
        "loopback DevIDE auto-navigates to the workspace viewer and returns " <>
        "navigated_to on success or navigation_failed when open succeeded but " <>
        "viewer navigation was blocked. Opening a session also activates that preview in " <>
        "connected DevIDE workspace viewers when the URL is embeddable. " <>
        "Do not claim a preview is visible merely because a server or tmux pane exists; " <>
        "preview_surfaces and preview_observe_pane report operator_visible/browser_loaded, " <>
        "and operator_visible=false means the user cannot see it yet. " <>
        "After preview_observe_live, call preview_elements and prefer element_id " <>
        "targets with preview_click / preview_type instead of guessing selectors. " <>
        "Pass workspace_id when the endpoint is not pre-scoped. " <>
        "Use preview_navigate for paths within the same origin. " <>
        "Headless preview_observe_live cannot drive LiveView WebSocket " <>
        "interactions — use preview_click/type/press for UI actions. " <>
        "Use the returned session_id with preview_observe, preview_observe_live, " <>
        "preview_click/type/press/screenshot, preview_get_storage, " <>
        "preview_report_errors, preview_record_start, preview_record_stop, " <>
        "preview_reload_iframe, devide_reload_page, " <>
        "and preview_playback_open for looping playback of a saved recording artifact, " <>
        "and call preview_close when finished.",
      workspace_id
    )
    |> scoped_tmux_session_instructions(tmux_session)
  end

  @impl true
  def list_tools(opts) do
    tool_specs()
    |> MCPToolSearch.list_tools(:preview)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
    |> optional_tmux_session(default_tmux_session(opts))
  end

  @doc "MCP tool specifications, mapped from PreviewTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- PreviewTools.definitions() do
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
  # Meta-tools: cross-server discovery/routing lives in MCPToolSearch so an agent
  # on this endpoint can find and run tools on any DevIDE server.
  def call_tool(id, %{"name" => "search_tools"} = params, _opts),
    do: MCPToolSearch.search_result(id, Map.get(params, "arguments", %{}) || %{})

  def call_tool(id, %{"name" => "invoke_tool"} = params, opts),
    do: MCPToolSearch.route_invoke(id, Map.get(params, "arguments", %{}) || %{}, opts)

  def call_tool(id, %{"name" => name} = params, opts) do
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    default_tmux_session = default_tmux_session(opts)
    args = Map.get(params, "arguments", %{}) || %{}
    audit_opts = [actor: Keyword.get(opts, :actor)]

    result =
      DevIDE.Signals.Context.with_new(fn ->
        case Scope.resolve_tool_call(name, args,
               surface: :preview,
               default_workspace_id: default_workspace_id,
               default_tmux_session: default_tmux_session
             ) do
          {:ok, scope} ->
            with {:ok, payload} <- PreviewTools.invoke(name, scope.workspace, scope.args) do
              _ =
                MCPAudit.record_preview(
                  scope.workspace_id,
                  name,
                  scope.args,
                  {:ok, payload},
                  audit_opts
                )

              {:ok, payload}
            else
              {:error, _reason} = err ->
                _ = MCPAudit.record_preview(scope.workspace_id, name, scope.args, err, audit_opts)
                err
            end

          {:error, reason} = err ->
            # Scope resolution failed, so `args` is untrusted — attribute the
            # failure to the endpoint's authenticated workspace (nil on
            # non-pre-scoped endpoints, which skips the durable row).
            _ = MCPAudit.record_preview(default_workspace_id, name, args, err, audit_opts)
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

  defp default_tmux_session(opts) do
    case Keyword.get(opts, :default_tmux_session) do
      session when is_binary(session) and session != "" -> session
      _ -> nil
    end
  end

  defp scoped_tmux_session_instructions(instructions, nil), do: instructions

  defp scoped_tmux_session_instructions(instructions, tmux_session) do
    instructions <>
      " This endpoint is also pre-scoped to tmux_session #{inspect(tmux_session)}; " <>
      "preview_open_here, preview_open_app, and preview_open_localhost inject it when omitted so preview panes open beside this agent."
  end

  defp optional_tmux_session(tools, nil), do: tools

  defp optional_tmux_session(tools, tmux_session)
       when is_binary(tmux_session) and tmux_session != "" do
    Enum.map(tools, fn
      %{inputSchema: schema} = tool when is_map(schema) ->
        required = Map.get(schema, :required, []) |> Enum.reject(&(&1 == "tmux_session"))
        %{tool | inputSchema: Map.put(schema, :required, required)}

      tool ->
        tool
    end)
  end
end
