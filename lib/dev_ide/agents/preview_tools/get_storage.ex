defmodule DevIDE.Agents.PreviewTools.GetStorage do
  @moduledoc "preview_get_storage."

  use Jido.Action,
    name: "preview_get_storage",
    description: "Return localStorage and sessionStorage for the current preview origin.",
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
  def mcp_metadata, do: Helpers.metadata("preview_get_storage")

  @impl Jido.Action
  def run(params, _context) do
    Impl.get_storage(Helpers.to_impl_args(params))
  end
end
