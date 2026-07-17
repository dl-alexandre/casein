defmodule DevIdeWeb.API.TerminalMCP do
  @moduledoc """
  Minimal MCP (Model Context Protocol) JSON-RPC handler that exposes
  `DevIDE.Agents.TerminalTools` to external coding agents (Grok, Claude,
  Codex, opencode).

  This is the terminal sibling of `DevIdeWeb.API.PreviewMCP`: same wire shape
  (JSON-RPC 2.0 over a single HTTP POST), its own route. Where PreviewMCP lets
  agents drive a browser surface, this lets them drive tmux sessions — list
  them, read pane scrollback, and send keys/commands — which is the workflow
  that makes tmux (vs. raw terminal splits) worth running for agents at all.

  The JSON-RPC envelope (routing, `initialize`, `ping`, response helpers,
  protocol-version negotiation) lives in `DevIdeWeb.API.MCPEnvelope`; this module
  implements only the terminal-specific behaviour callbacks. The handler is pure:
  it returns `{:reply, map}` (a 200 response), `:noreply` (a notification — 202,
  no body), or `{:error, map}` (a protocol-level JSON-RPC error). The thin
  `TerminalMCPController` owns the HTTP plumbing.
  """

  @behaviour DevIdeWeb.API.MCPEnvelope

  alias DevIDE.Agents.{MCPAudit, MCPError, TerminalTools}
  alias DevIDE.MCP.Scope
  alias DevIdeWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "DevIDE Terminal MCP Server"

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
    MCPWorkspaceScope.scoped_instructions(
      "tmux control tools for DevIDE sessions. Pass workspace_id when the endpoint is not pre-scoped. " <>
        "Start with terminal_context when unsure; it returns recommended next_tool " <>
        "and next_arguments. Otherwise call terminal_list_sessions to discover a " <>
        "session name, then terminal_topology to inspect windows/panes. Apply the agent_pair " <>
        "template before mutating agent-pane shortcuts (terminal_send_agent_*). " <>
        "Use terminal_paste_agent_text for literal or multiline text. " <>
        "Target the agent pane (not the operator pane) with " <>
        "terminal_send_command / terminal_send_keys. Read output with " <>
        "terminal_capture (ansi defaults to false). When multiple workspace " <>
        "sessions match, pass session explicitly — ambiguous matches return " <>
        "candidate_sessions. Pane references anchor to the caller, not to focus: " <>
        "the session active pane follows the operator across windows, so resolve " <>
        "\"the pane beside me\" from the caller.adjacent_panes block that " <>
        "terminal_context/terminal_topology return when the caller pane is known " <>
        "(sent automatically via X-DevIDE-Caller-Pane for DevIDE-launched agents), " <>
        "and pass explicit pane ids on capture/send calls.",
      MCPWorkspaceScope.default_workspace_id(opts)
    )
  end

  @impl true
  def list_tools(opts) do
    tool_specs()
    |> MCPToolSearch.list_tools(:terminal, opts)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
  end

  @doc "MCP tool specifications, mapped from TerminalTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- TerminalTools.definitions() do
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
    args = Map.get(params, "arguments", %{}) || %{}
    audit_opts = [actor: Keyword.get(opts, :actor)]

    result =
      DevIDE.Signals.Context.with_new(fn ->
        case Scope.resolve_tool_call(name, args,
               surface: :terminal,
               default_workspace_id: default_workspace_id,
               default_caller_pane: Keyword.get(opts, :default_caller_pane)
             ) do
          {:ok, scope} ->
            case TerminalTools.invoke(name, scope.args) do
              {:ok, payload} = ok ->
                _ = MCPAudit.record_terminal(name, scope.args, ok, audit_opts)
                {:ok, payload}

              {:error, reason} = err ->
                _ = MCPAudit.record_terminal(name, scope.args, err, audit_opts)
                {:error, reason}

              :error ->
                err = {:error, :invalid_tool_arguments}
                _ = MCPAudit.record_terminal(name, scope.args, err, audit_opts)
                err
            end

          {:error, reason} = err ->
            # Scope resolution failed, so `args` (and any workspace_id inside
            # them) is untrusted — attribute the failure to the endpoint's
            # authenticated workspace, never to a caller-claimed one.
            _ =
              MCPAudit.record_terminal(
                name,
                args,
                err,
                Keyword.put(audit_opts, :workspace_id, default_workspace_id)
              )

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
