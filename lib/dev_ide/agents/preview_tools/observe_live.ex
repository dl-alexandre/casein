defmodule DevIDE.Agents.PreviewTools.ObserveLive do
  @moduledoc "preview_observe_live."

  use Jido.Action,
    name: "preview_observe_live",
    description: "Observe the current preview page through browser automation.",
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
  def mcp_metadata, do: Helpers.metadata("preview_observe_live")

  @impl Jido.Action
  def run(params, context) do
    Impl.observe_live(Helpers.to_impl_args(params))
  end
end
