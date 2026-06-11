defmodule DevIdeWeb.API.PreviewMCP do
  @moduledoc """
  Minimal MCP (Model Context Protocol) JSON-RPC handler that exposes
  `DevIDE.Agents.PreviewTools` to external coding agents (Grok, Claude,
  Codex, opencode).

  It speaks the same wire shape as Tidewave's MCP server — JSON-RPC 2.0 over
  a single HTTP POST endpoint — but lives in this app on its own route. That
  keeps the Tidewave dependency untouched (0.5.6 has no external-tool
  registration hook) while still giving agents a real, discoverable tool
  surface for preview control.

  The handler is intentionally pure: it takes a decoded JSON-RPC message and
  returns `{:reply, map}` (a response to send as 200), `:noreply` (a
  notification — reply 202 with no body), or `{:error, map}` (a protocol-level
  JSON-RPC error). The thin `PreviewMCPController` owns the HTTP plumbing.
  """

  alias DevIDE.Agents.{MCPAudit, PreviewTools}
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.Workspaces

  @protocol_version "2025-03-26"
  @server_name "DevIDE Preview MCP Server"

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
         "Preview control tools for the current workspace. Call preview_surfaces " <>
           "to list named surfaces and terminal-detected localhost ports, then " <>
           "preview_open_app or preview_open_localhost with workspace_id to start " <>
           "a session. Use preview_navigate for paths within the same origin. " <>
           "Use the returned session_id with preview_observe, preview_observe_live, " <>
           "preview_click/type/press/screenshot, preview_get_storage, " <>
           "preview_report_errors, and call preview_close when finished."
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

  @doc "MCP tool specifications, mapped from PreviewTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- PreviewTools.definitions() do
      %{name: tool.name, description: tool.description, inputSchema: tool.parameters}
    end
  end

  defp call_tool(id, %{"name" => name} = params) do
    args = Map.get(params, "arguments", %{}) || %{}

    workspace_id = preview_workspace_id(name, args)

    result =
      with {:ok, workspace} <- resolve_workspace(name, args),
           {:ok, payload} <- PreviewTools.invoke(name, workspace, args) do
        _ = MCPAudit.record_preview(workspace_id, name, args, {:ok, payload})
        {:ok, payload}
      else
        {:error, _reason} = err ->
          _ = MCPAudit.record_preview(workspace_id, name, args, err)
          err
      end

    case result do
      {:ok, payload} ->
        result(id, %{content: [text(payload)], structuredContent: jsonable(payload)})

      {:error, reason} ->
        result(id, %{content: [text("error: " <> inspect(reason))], isError: true})
    end
  end

  defp call_tool(id, _params) do
    error(id, -32_602, "Invalid params: tool name is required")
  end

  # Workspace-scoped tools need manager metadata and optional terminal hints.
  # Session-scoped tools resolve everything from the session id held in the
  # runtime Registry, so an empty workspace is fine for them.
  @workspace_tools ~w(
    preview_surfaces
    preview_open_app
    preview_open_localhost
  )

  defp resolve_workspace(name, args) when name in @workspace_tools do
    case Map.get(args, "workspace_id") do
      id when is_binary(id) and id != "" -> Workspaces.get(id)
      _ -> {:error, :missing_workspace_id}
    end
  end

  defp resolve_workspace(_name, _args), do: {:ok, %{}}

  defp preview_workspace_id(name, args) when name in @workspace_tools,
    do: Map.get(args, "workspace_id")

  defp preview_workspace_id(_name, %{"session_id" => session_id}) when is_integer(session_id) do
    case Registry.get(session_id) do
      %{preview: %{workspace_id: workspace_id}} -> workspace_id
      _ -> nil
    end
  end

  defp preview_workspace_id(_name, %{"session_id" => session_id}) when is_binary(session_id) do
    case Integer.parse(session_id) do
      {id, ""} -> preview_workspace_id("", %{"session_id" => id})
      _ -> nil
    end
  end

  defp preview_workspace_id(_name, %{session_id: session_id}) when is_integer(session_id),
    do: preview_workspace_id("", %{"session_id" => session_id})

  defp preview_workspace_id(_name, _args), do: nil

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

  # Tool payloads use atom keys and may carry structs; round-trip through JSON
  # so the response is plain, serializable data regardless of adapter output.
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
