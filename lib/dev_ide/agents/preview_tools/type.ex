defmodule DevIDE.Agents.PreviewTools.Type do
  @moduledoc "preview_type."

  use Jido.Action,
    name: "preview_type",
    description: "Type text into an input matched by element_id or CSS selector.",
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
      text: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(Map.merge(Helpers.visible_mutation_props(), %{selector: Params.selector(), nth: Params.nth(), text: Params.text()}), [:session_id, :text])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_type")

  @impl Jido.Action
  def run(params, context) do
    Impl.type(Helpers.to_impl_args(params))
  end
end
