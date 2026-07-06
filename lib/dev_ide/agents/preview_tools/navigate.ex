defmodule DevIDE.Agents.PreviewTools.Navigate do
  @moduledoc "preview_navigate."

  use Jido.Action,
    name: "preview_navigate",
    description: "Navigate within the allowed preview origin (relative path or same-origin URL).",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true],
      path: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(%{session_id: Params.session_id(), path: Helpers.navigate_path_param()}, [:session_id, :path])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_navigate")

  @impl Jido.Action
  def run(params, context) do
    Impl.navigate(Helpers.to_impl_args(params))
  end
end
