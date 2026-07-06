defmodule DevIDE.Agents.PreviewTools.DevideReloadPage do
  @moduledoc "devide_reload_page."

  use Jido.Action,
    name: "devide_reload_page",
    description: "Ask connected DevIDE viewers to reload the whole workspace page.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      actor_id: [type: :string],
      reason: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(Map.merge(Helpers.workspace_props(), %{actor_id: Params.actor_id(), reason: Helpers.reload_reason_param()}), [:workspace_id])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("devide_reload_page")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.reload_page(workspace, Helpers.to_impl_args(params))
  end
end
