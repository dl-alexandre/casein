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

  The handler is pure: it takes a decoded JSON-RPC message and returns
  `{:reply, map}` (a 200 response), `:noreply` (a notification — 202, no body),
  or `{:error, map}` (a protocol-level JSON-RPC error). The thin
  `TerminalMCPController` owns the HTTP plumbing.
  """

  alias DevIDE.Agents.{MCPAudit, MCPError, TerminalTools}
  alias DevIdeWeb.API.MCPWorkspaceScope

  @protocol_version "2025-03-26"
  @server_name "DevIDE Terminal MCP Server"

  @type outcome :: {:reply, map()} | :noreply | {:error, map()}

  @doc """
  Handle a single decoded JSON-RPC message.
  """
  @spec handle(map(), keyword()) :: outcome()
  def handle(message, opts \\ [])
  def handle(%{"jsonrpc" => "2.0"} = message, opts), do: route(message, opts)
  def handle(_, _opts), do: {:error, parse_error()}

  # Notifications carry a method but no id; they never get a response body.
  defp route(%{"method" => "notifications/" <> _}, _opts), do: :noreply

  defp route(%{"method" => method, "id" => id} = message, opts) do
    dispatch(method, id, Map.get(message, "params", %{}) || %{}, opts)
  end

  # A reply to one of our requests (e.g. a ping answer) — nothing to do.
  defp route(%{"id" => _}, _opts), do: :noreply
  defp route(_, _opts), do: {:error, parse_error()}

  defp dispatch("initialize", id, _params, opts) do
    workspace_id = MCPWorkspaceScope.default_workspace_id(opts)

    instructions =
      MCPWorkspaceScope.scoped_instructions(
        "tmux control tools for DevIDE sessions. Pass workspace_id when the endpoint is not pre-scoped. " <>
          "Call terminal_list_sessions to discover a session name, then " <>
          "terminal_topology to inspect windows/panes. Apply the agent_pair " <>
          "template before mutating agent-pane shortcuts (terminal_send_agent_*). " <>
          "Target the agent pane (not the operator pane) with " <>
          "terminal_send_command / terminal_send_keys. Read output with " <>
          "terminal_capture (ansi defaults to false). When multiple workspace " <>
          "sessions match, pass session explicitly — ambiguous matches return " <>
          "candidate_sessions.",
        workspace_id
      )

    {:reply,
     result(id, %{
       protocolVersion: @protocol_version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: @server_name, version: server_version()},
       instructions: instructions
     })}
  end

  defp dispatch("ping", id, _params, _opts), do: {:reply, result(id, %{})}

  defp dispatch("tools/list", id, _params, opts) do
    tools =
      MCPWorkspaceScope.tool_specs(tool_specs(), MCPWorkspaceScope.default_workspace_id(opts))

    {:reply, result(id, %{tools: tools})}
  end

  defp dispatch("tools/call", id, params, opts), do: {:reply, call_tool(id, params, opts)}

  defp dispatch(other, id, _params, _opts) do
    {:error, error(id, -32_601, "Method not found", %{name: other})}
  end

  @doc "MCP tool specifications, mapped from TerminalTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- TerminalTools.definitions() do
      %{name: tool.name, description: tool.description, inputSchema: tool.parameters}
    end
  end

  defp call_tool(id, %{"name" => name} = params, opts) do
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)

    result =
      case MCPWorkspaceScope.scoped_call_params(params, default_workspace_id) do
        {:ok, scoped_params} ->
          args = Map.get(scoped_params, "arguments", %{}) || %{}

          case TerminalTools.invoke(name, args) do
            {:ok, payload} = ok ->
              _ = MCPAudit.record_terminal(name, args, ok)
              {:ok, payload}

            {:error, reason} = err ->
              _ = MCPAudit.record_terminal(name, args, err)
              {:error, reason}

            :error ->
              err = {:error, :invalid_tool_arguments}
              _ = MCPAudit.record_terminal(name, args, err)
              err
          end

        {:error, reason} = err ->
          args = Map.get(params, "arguments", %{}) || %{}
          _ = MCPAudit.record_terminal(name, args, err)
          {:error, reason}
      end

    case result do
      {:ok, payload} ->
        result(id, %{content: [text(payload)], structuredContent: jsonable(payload)})

      {:error, reason} ->
        err = MCPError.tool_result(reason)
        result(id, %{err | structuredContent: jsonable(err.structuredContent)})
    end
  end

  defp call_tool(id, _params, _opts) do
    error(id, -32_602, "Invalid params: tool name is required")
  end

  defp result(id, result) when is_map(result) do
    %{jsonrpc: "2.0", id: id, result: result}
  end

  defp error(id, code, message, data \\ nil) do
    err = %{code: code, message: message}
    err = if data, do: Map.put(err, :data, data), else: err
    %{jsonrpc: "2.0", id: id, error: err}
  end

  defp parse_error, do: error(nil, -32_600, "Could not parse message")

  defp text(payload) when is_binary(payload), do: %{type: "text", text: payload}
  defp text(payload), do: %{type: "text", text: Jason.encode!(jsonable(payload))}

  # Tool payloads use atom keys; round-trip through JSON so the response is
  # plain, serializable data regardless of adapter output.
  defp jsonable(payload) do
    payload |> Jason.encode!() |> Jason.decode!()
  end

  defp server_version do
    case Application.spec(:dev_ide, :vsn) do
      vsn when is_list(vsn) -> to_string(vsn)
      _ -> "0.0.0"
    end
  end
end
