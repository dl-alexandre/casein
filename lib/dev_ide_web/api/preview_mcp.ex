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
  alias DevIdeWeb.API.MCPWorkspaceScope

  @protocol_version "2025-03-26"
  @server_name "DevIDE Preview MCP Server"

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
        "Preview control tools for the current workspace. Call preview_surfaces " <>
          "to list named surfaces and terminal-detected localhost ports, then " <>
          "preview_open_app or preview_open_localhost to start a session. " <>
          "Opening a session also activates that preview in connected DevIDE " <>
          "workspace viewers when the URL is embeddable. " <>
          "Pass workspace_id when the endpoint is not pre-scoped. " <>
          "Use preview_navigate for paths within the same origin. " <>
          "Use the returned session_id with preview_observe, preview_observe_live, " <>
          "preview_click/type/press/screenshot, preview_get_storage, " <>
          "preview_report_errors, preview_reload_iframe, devide_reload_page, " <>
          "and call preview_close when finished.",
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

  @doc "MCP tool specifications, mapped from PreviewTools definitions."
  @spec tool_specs() :: [map()]
  def tool_specs do
    for tool <- PreviewTools.definitions() do
      %{name: tool.name, description: tool.description, inputSchema: tool.parameters}
    end
  end

  defp call_tool(id, %{"name" => name} = params, opts) do
    params =
      MCPWorkspaceScope.inject_default_workspace(
        params,
        MCPWorkspaceScope.default_workspace_id(opts)
      )

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

  defp call_tool(id, _params, _opts) do
    error(id, -32_602, "Invalid params: tool name is required")
  end

  # Workspace-scoped tools need manager metadata and optional terminal hints.
  # Session-scoped tools resolve everything from the session id held in the
  # runtime Registry, so an empty workspace is fine for them.
  @workspace_tools ~w(
    preview_resolve_workspace
    preview_surfaces
    preview_open_current_workspace
    preview_open_app
    preview_open_localhost
    preview_reload_iframe
    devide_reload_page
  )

  defp resolve_workspace(name, args) when name in @workspace_tools do
    cond do
      id = workspace_id(args) ->
        case Workspaces.get(id) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, reason} -> {:error, workspace_id_error(id, reason)}
        end

      path = workspace_path(args) ->
        case Workspaces.attach_folder(path) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, reason} -> {:error, workspace_path_error(path, reason)}
        end

      true ->
        {:error,
         %{
           error: :missing_workspace_id,
           message:
             "Pass workspace_id or workspace_path. Generated DevIDE MCP URLs inject workspace_id automatically.",
           folder_id_format: "folder:<base64url-absolute-path>"
         }}
    end
  end

  defp resolve_workspace(_name, _args), do: {:ok, %{}}

  defp preview_workspace_id(name, args) when name in @workspace_tools,
    do: workspace_id(args)

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

  defp workspace_id(args) when is_map(args) do
    case Map.get(args, "workspace_id") || Map.get(args, :workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp workspace_path(args) when is_map(args) do
    case Map.get(args, "workspace_path") || Map.get(args, :workspace_path) ||
           Map.get(args, "path") ||
           Map.get(args, :path) || Map.get(args, "cwd") || Map.get(args, :cwd) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp workspace_id_error(id, reason) do
    %{
      error: :workspace_not_found,
      workspace_id: id,
      reason: reason,
      message:
        "Workspace #{inspect(id)} was not found. For attached folders, pass workspace_path or use folder:<base64url-absolute-path>.",
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path_error(path, reason) do
    %{
      error: :workspace_path_not_resolved,
      path: path,
      reason: reason,
      message: "Workspace path #{inspect(path)} could not be attached or is outside allowed roots"
    }
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
