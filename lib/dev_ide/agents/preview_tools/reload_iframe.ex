defmodule DevIDE.Agents.PreviewTools.ReloadIframe do
  @moduledoc "preview_reload_iframe."

  use Jido.Action,
    name: "preview_reload_iframe",
    description: "Ask connected DevIDE viewers to reload the active embedded preview iframe.",
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
  def mcp_metadata, do: Helpers.metadata("preview_reload_iframe")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.reload_iframe(workspace, Helpers.to_impl_args(params))
  end
end
