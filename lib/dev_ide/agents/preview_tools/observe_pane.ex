defmodule DevIDE.Agents.PreviewTools.ObservePane do
  @moduledoc "preview_observe_pane."

  use Jido.Action,
    name: "preview_observe_pane",
    description: "Observe an existing DevIDE preview pane by tmux pane id.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      pane_id: [type: :string, required: true],
      limit: [type: :integer]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          pane_id: Helpers.pane_id_param(),
          limit: Helpers.observe_pane_limit_param()
        }),
        [:workspace_id, :pane_id]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_observe_pane")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.observe_pane(workspace, Helpers.to_impl_args(params))
  end
end
