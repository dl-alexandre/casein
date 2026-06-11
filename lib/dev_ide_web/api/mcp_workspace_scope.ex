defmodule DevIdeWeb.API.MCPWorkspaceScope do
  @moduledoc false

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
    case Map.get(args, "workspace_id") || Map.get(args, :workspace_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end
end
