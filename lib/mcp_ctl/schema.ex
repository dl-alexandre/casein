defmodule McpCtl.Schema do
  @moduledoc """
  JSON-schema fragments shared by DevIDE MCP tool definitions.

  Encodes DevIDE workspace-scoping conventions (workspace ids, folder
  attachment paths) so every tool describes them consistently.
  """

  @preview_workspace_id_param %{
    type: "string",
    description:
      "Workspace id. Generated DevIDE MCP URLs are pre-scoped and can omit this. " <>
        "Manager workspaces use the manager UUID. Folder-attached workspaces use " <>
        "folder:<base64url-absolute-path>; prefer preview_resolve_workspace with a path " <>
        "instead of hand-encoding."
  }

  @terminal_workspace_id_param %{
    type: "string",
    description:
      "Workspace id (recommended on every call). Scopes session discovery " <>
        "and rejects sessions from other workspaces."
  }

  @workspace_path_param %{
    type: "string",
    description:
      "Absolute or allowed-root-relative workspace folder path. Use when workspace_id is unknown; " <>
        "DevIDE will attach/resolve the folder and return its folder:<base64url-path> id."
  }

  @doc false
  def workspace_id_param(:terminal), do: @terminal_workspace_id_param
  def workspace_id_param(_), do: @preview_workspace_id_param

  @doc false
  def workspace_path_param, do: @workspace_path_param

  @doc "Base object schema with optional workspace scoping properties."
  @spec workspace_object(keyword()) :: map()
  def workspace_object(opts \\ []) do
    include_path? = Keyword.get(opts, :include_path, false)
    required = Keyword.get(opts, :required, [])

    variant = Keyword.get(opts, :variant, :preview)

    properties =
      %{workspace_id: workspace_id_param(variant)}
      |> maybe_put_path(include_path?)

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  @doc "Merge extra properties into a workspace-scoped object schema."
  @spec merge_workspace_properties(map(), map()) :: map()
  def merge_workspace_properties(base, extra) when is_map(base) and is_map(extra) do
    base
    |> update_in([:properties], fn props ->
      Map.merge(props || %{}, extra)
    end)
  end

  defp maybe_put_path(props, true), do: Map.put(props, :workspace_path, @workspace_path_param)
  defp maybe_put_path(props, _), do: props
end
