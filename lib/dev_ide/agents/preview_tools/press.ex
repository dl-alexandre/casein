defmodule DevIDE.Agents.PreviewTools.Press do
  @moduledoc "preview_press."

  use Jido.Action,
    name: "preview_press",
    description: "Press a keyboard key in the preview session.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      
      session_id: [type: {:or, [:integer, :string]}, required: true],
      element_id: [type: :string],
      selector: [type: :string],
      nth: [type: :integer],
      x: [type: {:or, [:integer, :float]}],
      y: [type: {:or, [:integer, :float]}],
      text: [type: :string],
      key: [type: :string],
      allow_headless: [type: :boolean],
      diff: [type: :boolean],
      key: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(Map.merge(Helpers.visible_mutation_props(), %{key: Params.key()}), [:session_id, :key])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_press")

  @impl Jido.Action
  def run(params, context) do
    Impl.press(Helpers.to_impl_args(params))
  end
end
