defmodule Casein.Agents.PreviewTools.NavigatePane do
  @moduledoc "preview_navigate_pane."

  use Jido.Action,
    name: "preview_navigate_pane",
    description: "Navigate an existing embedded preview pane by tmux pane id.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      pane_id: [type: :string, required: true],
      path: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(%{pane_id: Helpers.pane_id_param(), path: Helpers.navigate_path_param()}, [
        :pane_id,
        :path
      ])

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_navigate_pane")

  @impl Jido.Action
  def run(params, _context) do
    Impl.navigate_pane(Helpers.to_impl_args(params))
  end
end
