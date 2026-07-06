defmodule DevIDE.Agents.PreviewTools.ClearStorage do
  @moduledoc "preview_clear_storage."

  use Jido.Action,
    name: "preview_clear_storage",
    description: "Clear cookies, localStorage, and sessionStorage for the current preview origin.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.session_only()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_clear_storage")

  @impl Jido.Action
  def run(params, context) do
    Impl.clear_storage(Helpers.to_impl_args(params))
  end
end
