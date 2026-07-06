defmodule DevIDE.Agents.PreviewTools.ResolveWorkspace do
  @moduledoc "preview_resolve_workspace."

  use Jido.Action,
    name: "preview_resolve_workspace",
    description: "Resolve a workspace_id from a manager id or a folder path. Use this when a preview tool reports workspace_not_found or when working from an attached local folder.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      workspace_path: [type: :string],
      path: [type: :string],
      cwd: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(%{workspace_id: Params.preview_workspace_props(include_path: false)[:workspace_id], workspace_path: Params.workspace_path_param(), path: Params.workspace_path_param(), cwd: Params.workspace_path_param()})

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_resolve_workspace")

  @impl Jido.Action
  def run(params, context) do
    Impl.resolve_workspace(Helpers.to_impl_args(params))
  end
end
