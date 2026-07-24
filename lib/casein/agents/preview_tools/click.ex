defmodule Casein.Agents.PreviewTools.Click do
  @moduledoc "preview_click."

  use Jido.Action,
    name: "preview_click",
    description: "Click an element by element_id, CSS selector, or viewport coordinates.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}],
      element_id: [type: :string],
      selector: [type: :string],
      nth: [type: :integer],
      x: [type: {:or, [:integer, :float]}],
      y: [type: {:or, [:integer, :float]}],
      text: [type: :string],
      key: [type: :string],
      allow_headless: [type: :boolean],
      diff: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.visible_mutation_props(), %{
          selector: Params.selector(),
          nth: Params.nth(),
          x: Params.x(),
          y: Params.y()
        }),
        [:session_id]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_click")

  @impl Jido.Action
  def run(params, _context) do
    Impl.click(Helpers.to_impl_args(params))
  end
end
