defmodule DevIDE.Agents.PreviewTools.Screenshot do
  @moduledoc "preview_screenshot."

  use Jido.Action,
    name: "preview_screenshot",
    description: "Capture a screenshot artifact from the current preview page.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.session_only()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_screenshot")

  @impl Jido.Action
  def run(params, _context) do
    Impl.screenshot(Helpers.to_impl_args(params))
  end
end
