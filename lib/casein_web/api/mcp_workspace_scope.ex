defmodule CaseinWeb.API.MCPWorkspaceScope do
  @moduledoc false

  alias Casein.MCP.Scope, as: MCPScope
  alias Casein.Workspaces.Aliases, as: WorkspaceAliases

  @doc "Return a non-empty default workspace id from MCP handler opts."
  def default_workspace_id(opts) do
    case Keyword.get(opts, :default_workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc "Inject the endpoint default workspace into tools/call arguments when omitted."
  def inject_default_workspace(%{"name" => _name} = params, nil), do: params

  def inject_default_workspace(%{"name" => _name} = params, workspace_id)
      when is_binary(workspace_id) and workspace_id != "" do
    case Map.get(params, "arguments") do
      args when is_map(args) ->
        if workspace_id_present?(args) do
          params
        else
          Map.put(params, "arguments", Map.put(args, "workspace_id", workspace_id))
        end

      nil ->
        Map.put(params, "arguments", %{"workspace_id" => workspace_id})

      _other ->
        params
    end
  end

  def inject_default_workspace(params, _workspace_id), do: params

  @doc """
  Enforce a pre-scoped endpoint's workspace boundary.

  Generated MCP URLs may include `?workspace_id=...`, which makes the endpoint
  workspace-scoped. In that mode agents may omit `workspace_id`, but they may
  not override it with a different explicit value.
  """
  def scoped_call_params(%{"name" => _name} = params, nil), do: {:ok, params}

  def scoped_call_params(%{"name" => _name} = params, workspace_id)
      when is_binary(workspace_id) and workspace_id != "" do
    args = Map.get(params, "arguments", %{}) || %{}

    case workspace_id(args) do
      nil ->
        {:ok, inject_default_workspace(params, workspace_id)}

      ^workspace_id ->
        {:ok, params}

      requested ->
        cond do
          workspaces_compatible?(workspace_id, requested) ->
            {:ok, params}

          MCPScope.allow_cross_workspace?(Map.get(params, "name"), args) ->
            {:ok, params}

          true ->
            {:error, workspace_scope_mismatch(workspace_id, requested)}
        end
    end
  end

  def scoped_call_params(params, _workspace_id), do: {:ok, params}

  @doc """
  True when a pre-scoped endpoint may serve the requested workspace id.

  Manager UUIDs and folder-attached ids for the same host path are compatible.
  """
  def workspaces_compatible?(scoped_workspace_id, requested_workspace_id)
      when is_binary(scoped_workspace_id) and is_binary(requested_workspace_id) do
    scoped_workspace_id == requested_workspace_id or
      WorkspaceAliases.linked?(scoped_workspace_id, requested_workspace_id)
  end

  def workspaces_compatible?(_, _), do: false

  @doc "Return the explicit workspace_id from a tool argument map."
  def workspace_id(args) when is_map(args) do
    case Map.get(args, "workspace_id") || Map.get(args, :workspace_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def workspace_id(_args), do: nil

  @doc "Build a structured tool error for cross-workspace MCP attempts."
  def workspace_scope_mismatch(scoped_workspace_id, requested_workspace_id) do
    %{
      error: :workspace_scope_mismatch,
      scoped_workspace_id: scoped_workspace_id,
      requested_workspace_id: requested_workspace_id,
      message:
        "This MCP endpoint is pre-scoped to workspace_id #{inspect(scoped_workspace_id)}. " <>
          "Omit workspace_id on tool calls (it is injected automatically), or use an MCP URL " <>
          "scoped to #{inspect(requested_workspace_id)}. " <>
          "Cannot access #{inspect(requested_workspace_id)} from this endpoint. " <>
          "Read-only peek: pass allow_cross_workspace: true on preview_surfaces, " <>
          "preview_observe_pane, terminal_list_sessions, terminal_topology, or " <>
          "terminal_capture — that lane is audited.",
      lane: "allow_cross_workspace"
    }
  end

  @doc "Remove workspace_id from required schema fields when the endpoint supplies it."
  def tool_specs(tools, nil), do: tools

  def tool_specs(tools, workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    Enum.map(tools, &optional_workspace_id/1)
  end

  @doc "Append scoped-endpoint guidance to MCP initialize instructions."
  def scoped_instructions(instructions, nil), do: instructions

  def scoped_instructions(instructions, workspace_id)
      when is_binary(workspace_id) and workspace_id != "" do
    instructions <>
      " This endpoint is pre-scoped to workspace_id #{inspect(workspace_id)} and injects it when omitted."
  end

  defp optional_workspace_id(%{inputSchema: schema} = tool) when is_map(schema) do
    required = Map.get(schema, :required, []) |> Enum.reject(&(&1 == "workspace_id"))
    %{tool | inputSchema: Map.put(schema, :required, required)}
  end

  defp optional_workspace_id(tool), do: tool

  defp workspace_id_present?(args) do
    not is_nil(workspace_id(args))
  end
end
