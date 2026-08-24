defmodule CaseinWeb.API.TerminalMCP do
  @moduledoc """
  Minimal MCP (Model Context Protocol) JSON-RPC handler that exposes
  `Casein.Agents.TerminalTools` to external coding agents (Grok, Claude,
  Codex, opencode).

  This is the terminal sibling of `CaseinWeb.API.PreviewMCP`: same wire shape
  (JSON-RPC 2.0 over a single HTTP POST), its own route. Where PreviewMCP lets
  agents drive a browser surface, this lets them drive tmux sessions — list
  them, read pane scrollback, and send keys/commands — which is the workflow
  that makes tmux (vs. raw terminal splits) worth running for agents at all.

  The JSON-RPC envelope (routing, `initialize`, `ping`, response helpers,
  protocol-version negotiation) lives in `CaseinWeb.API.MCPEnvelope`; this module
  implements only the terminal-specific behaviour callbacks. The handler is pure:
  it returns `{:reply, map}` (a 200 response), `:noreply` (a notification — 202,
  no body), or `{:error, map}` (a protocol-level JSON-RPC error). The thin
  `TerminalMCPController` owns the HTTP plumbing.
  """

  @behaviour CaseinWeb.API.MCPEnvelope

  alias Casein.Agents.{MCPAudit, MCPError, MCPTasks, TerminalTools}
  alias Casein.MCP.Scope
  alias Casein.Terminals.FleetSummary
  alias CaseinWeb.API.{MCPEnvelope, MCPToolSearch, MCPWorkspaceScope}
  alias McpCtl.Tool

  @server_name "Casein Terminal MCP Server"
  @fleet_summary_uri FleetSummary.resource_uri()

  # One wait leg self-limits at 55s; this only has to outlast that plus the tool's
  # own setup, and exists so a wedged leg cannot hang a task forever.
  @wait_leg_timeout_ms 90_000

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
      "tmux control tools for Casein sessions. Pass workspace_id when the endpoint is not pre-scoped. " <>
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
        "(sent automatically via X-Casein-Caller-Pane for Casein-launched agents), " <>
        "and pass explicit pane ids on capture/send calls. " <>
        "For a one-shot fleet picture (sessions, panes, runtime, worktree, branch, " <>
        "commits-not-on-origin, process/CPU liveness) read the MCP resource " <>
        "casein://fleet/summary — do not topology + N capture scrapes. " <>
        "Before assigning a worker wave, call terminal_host_capacity; an unknown " <>
        "capacity probe is not spare capacity.",
      MCPWorkspaceScope.default_workspace_id(opts)
    )
  end

  @impl true
  # `terminal_wait_agent_state` is the tool whose synchronous contract is a
  # workaround: it caps itself at 55s and tells callers to re-issue. Run as a
  # task it can wait as long as the agent actually takes. Read-only, so it is
  # safe to abandon on cancel.
  def task_tools, do: ["terminal_wait_agent_state"]

  @impl true
  # Fleet summary is a concrete JSON resource (not an MCP App). Pane capture and
  # the candidate_sessions picker remain tool-shaped for now.
  def list_resources(_opts) do
    [FleetSummary.resource_descriptor()]
  end

  @impl true
  def read_resource(@fleet_summary_uri, opts) do
    workspace_id = MCPWorkspaceScope.default_workspace_id(opts)

    payload =
      cond do
        is_binary(workspace_id) ->
          FleetSummary.build(workspace_id: workspace_id)

        Application.get_env(:casein, :allow_global_mcp_tool_calls, false) ->
          FleetSummary.build([])

        true ->
          FleetSummary.build(workspace_id: nil, sessions: [])
      end

    {:ok,
     [
       %{
         uri: @fleet_summary_uri,
         mimeType: "application/json",
         text: FleetSummary.to_json(payload)
       }
     ]}
  end

  def read_resource(_uri, _opts), do: {:error, :not_found}

  @impl true
  def list_tools(opts) do
    tool_specs()
    |> MCPToolSearch.list_tools(:terminal, opts)
    |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
  end

  @doc "MCP tool specifications, mapped from TerminalTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    Enum.map(TerminalTools.definitions(), &Tool.mcp_spec/1)
  end

  @impl true
  # Meta-tools: cross-server discovery/routing lives in MCPToolSearch so an agent
  # on this endpoint can find and run tools on any Casein server.
  def call_tool(id, %{"name" => "search_tools"} = params, _opts),
    do: MCPToolSearch.search_result(id, Map.get(params, "arguments", %{}) || %{})

  def call_tool(id, %{"name" => "invoke_tool"} = params, opts),
    do: MCPToolSearch.route_invoke(id, Map.get(params, "arguments", %{}) || %{}, opts)

  # Task-augmented waits keep waiting. The underlying tool still caps a single
  # leg at 55s (a proxy limit, not a real bound on how long an agent takes), so
  # the re-issue loop its description tells clients to run moves in here — where
  # no HTTP request is held open. Each leg runs in a fresh process so its
  # AgentState subscription does not accumulate across legs.
  def call_tool(id, %{"name" => "terminal_wait_agent_state"} = params, opts) do
    if Keyword.get(opts, :task_augmented, false) do
      wait_until_settled(id, params, opts, wait_deadline())
    else
      invoke_tool_call(id, "terminal_wait_agent_state", params, opts)
    end
  end

  def call_tool(id, %{"name" => name} = params, opts),
    do: invoke_tool_call(id, name, params, opts)

  def call_tool(id, _params, _opts) do
    MCPEnvelope.error(id, -32_602, "Invalid params: tool name is required")
  end

  defp wait_until_settled(id, params, opts, deadline) do
    response =
      Task.async(fn -> invoke_tool_call(id, "terminal_wait_agent_state", params, opts) end)
      |> Task.await(@wait_leg_timeout_ms)

    cond do
      settled?(response) -> response
      System.monotonic_time(:millisecond) >= deadline -> response
      cancelled?(opts) -> response
      true -> wait_until_settled(id, params, opts, deadline)
    end
  end

  # Only keep waiting when the tool positively reports a timeout; any other shape
  # (a match, a tool error, a JSON-RPC error) ends the task.
  defp settled?(%{result: %{structuredContent: %{"timed_out" => true}}}), do: false
  defp settled?(_response), do: true

  defp cancelled?(opts) do
    case Keyword.get(opts, :task_id) do
      task_id when is_binary(task_id) -> MCPTasks.cancelled?(task_id)
      _ -> false
    end
  end

  defp wait_deadline, do: System.monotonic_time(:millisecond) + MCPTasks.ttl_ms()

  defp invoke_tool_call(id, name, params, opts) do
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    args = Map.get(params, "arguments", %{}) || %{}
    audit_opts = [actor: Keyword.get(opts, :actor)]

    result =
      Casein.Signals.Context.with_new(fn ->
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
end
