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

  alias DevIDE.Agents.TerminalTools

  @protocol_version "2025-03-26"
  @server_name "DevIDE Terminal MCP Server"

  @type outcome :: {:reply, map()} | :noreply | {:error, map()}

  @doc """
  Handle a single decoded JSON-RPC message.
  """
  @spec handle(map()) :: outcome()
  def handle(%{"jsonrpc" => "2.0"} = message), do: route(message)
  def handle(_), do: {:error, parse_error()}

  # Notifications carry a method but no id; they never get a response body.
  defp route(%{"method" => "notifications/" <> _}), do: :noreply

  defp route(%{"method" => method, "id" => id} = message) do
    dispatch(method, id, Map.get(message, "params", %{}) || %{})
  end

  # A reply to one of our requests (e.g. a ping answer) — nothing to do.
  defp route(%{"id" => _}), do: :noreply
  defp route(_), do: {:error, parse_error()}

  defp dispatch("initialize", id, _params) do
    {:reply,
     result(id, %{
       protocolVersion: @protocol_version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: @server_name, version: server_version()},
       instructions:
         "tmux control tools for DevIDE sessions. Call terminal_list_sessions " <>
           "to discover a session name, then use terminal_topology to inspect " <>
           "its windows/panes, terminal_capture to read pane output, and " <>
           "terminal_send_keys / terminal_send_command to drive it."
     })}
  end

  defp dispatch("ping", id, _params), do: {:reply, result(id, %{})}

  defp dispatch("tools/list", id, _params) do
    {:reply, result(id, %{tools: tool_specs()})}
  end

  defp dispatch("tools/call", id, params), do: {:reply, call_tool(id, params)}

  defp dispatch(other, id, _params) do
    {:error, error(id, -32_601, "Method not found", %{name: other})}
  end

  @doc "MCP tool specifications, mapped from TerminalTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- TerminalTools.definitions() do
      %{name: tool.name, description: tool.description, inputSchema: tool.parameters}
    end
  end

  defp call_tool(id, %{"name" => name} = params) do
    args = Map.get(params, "arguments", %{}) || %{}

    case TerminalTools.invoke(name, args) do
      {:ok, payload} ->
        result(id, %{content: [text(payload)], structuredContent: jsonable(payload)})

      {:error, reason} ->
        result(id, %{content: [text("error: " <> inspect(reason))], isError: true})
    end
  end

  defp call_tool(id, _params) do
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
