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

  alias DevIDE.Agents.{MCPAudit, MCPError, PreviewTools}
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
    tmux_session = default_tmux_session(opts)

    instructions =
      MCPWorkspaceScope.scoped_instructions(
        "Preview control tools for the current workspace. Call preview_surfaces " <>
          "to list named surfaces (manager URLs, host loopback DevIDE, and " <>
          "terminal-detected localhost ports), then preview_open_here, preview_open_app, or " <>
          "preview_open_localhost to start a session. Opens preflight the " <>
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
          "Pass workspace_id when the endpoint is not pre-scoped. " <>
          "Use preview_navigate for paths within the same origin. " <>
          "Headless preview_observe_live cannot drive LiveView WebSocket " <>
          "interactions — use preview_click/type/press for UI actions. " <>
          "Use the returned session_id with preview_observe, preview_observe_live, " <>
          "preview_click/type/press/screenshot, preview_get_storage, " <>
          "preview_report_errors, preview_reload_iframe, devide_reload_page, " <>
          "and call preview_close when finished.",
        workspace_id
      )
      |> scoped_tmux_session_instructions(tmux_session)

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
      tool_specs()
      |> MCPWorkspaceScope.tool_specs(MCPWorkspaceScope.default_workspace_id(opts))
      |> optional_tmux_session(default_tmux_session(opts))

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
    default_workspace_id = MCPWorkspaceScope.default_workspace_id(opts)
    default_tmux_session = default_tmux_session(opts)

    result =
      case MCPWorkspaceScope.scoped_call_params(params, default_workspace_id) do
        {:ok, scoped_params} ->
          args =
            scoped_params
            |> Map.get("arguments", %{})
            |> Kernel.||(%{})
            |> inject_default_tmux_session(name, default_tmux_session)

          workspace_id = preview_workspace_id(name, args)

          with :ok <- enforce_session_scope(default_workspace_id, workspace_id),
               :ok <- enforce_tmux_session_scope(default_tmux_session, args),
               {:ok, workspace} <- resolve_workspace(name, args),
               {:ok, payload} <- PreviewTools.invoke(name, workspace, args) do
            _ = MCPAudit.record_preview(workspace_id, name, args, {:ok, payload})
            {:ok, payload}
          else
            {:error, _reason} = err ->
              _ = MCPAudit.record_preview(workspace_id, name, args, err)
              err
          end

        {:error, reason} = err ->
          args = Map.get(params, "arguments", %{}) || %{}
          _ = MCPAudit.record_preview(nil, name, args, err)
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

  # Workspace-scoped tools need manager metadata and optional terminal hints.
  # Session-scoped tools resolve everything from the session id held in the
  # runtime Registry, so an empty workspace is fine for them.
  @workspace_tools ~w(
    preview_resolve_workspace
    preview_surfaces
    preview_open_current_workspace
    preview_open_here
    preview_open_app
    preview_open_localhost
    preview_reload_iframe
    preview_observe_pane
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

  defp enforce_session_scope(scoped_workspace_id, requested_workspace_id) do
    cond do
      is_nil(scoped_workspace_id) or is_nil(requested_workspace_id) ->
        :ok

      MCPWorkspaceScope.workspaces_compatible?(scoped_workspace_id, requested_workspace_id) ->
        :ok

      true ->
        {:error,
         MCPWorkspaceScope.workspace_scope_mismatch(scoped_workspace_id, requested_workspace_id)}
    end
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

  defp inject_default_tmux_session(args, name, tmux_session)
       when name in [
              "preview_open_current_workspace",
              "preview_surfaces",
              "preview_open_here",
              "preview_ensure_server_here",
              "preview_open_app",
              "preview_open_localhost"
            ] and
              is_map(args) and is_binary(tmux_session) do
    if tmux_session_present?(args), do: args, else: Map.put(args, "tmux_session", tmux_session)
  end

  defp inject_default_tmux_session(args, _name, _tmux_session), do: args

  defp enforce_tmux_session_scope(nil, _args), do: :ok

  defp enforce_tmux_session_scope(scoped_tmux_session, args) when is_map(args) do
    case tmux_session(args) do
      nil -> :ok
      ^scoped_tmux_session -> :ok
      requested -> {:error, tmux_session_scope_mismatch(scoped_tmux_session, requested)}
    end
  end

  defp enforce_tmux_session_scope(_scoped_tmux_session, _args), do: :ok

  defp tmux_session(args) when is_map(args) do
    case Map.get(args, "tmux_session") || Map.get(args, :tmux_session) do
      session when is_binary(session) and session != "" -> session
      _ -> nil
    end
  end

  defp tmux_session_present?(args), do: not is_nil(tmux_session(args))

  defp tmux_session_scope_mismatch(scoped_tmux_session, requested_tmux_session) do
    %{
      error: :tmux_session_scope_mismatch,
      scoped_tmux_session: scoped_tmux_session,
      requested_tmux_session: requested_tmux_session,
      message:
        "This Preview MCP endpoint is pre-scoped to tmux_session #{inspect(scoped_tmux_session)}. " <>
          "Omit tmux_session on preview-open calls so it is injected automatically, " <>
          "or use the MCP URL for #{inspect(requested_tmux_session)}."
    }
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
