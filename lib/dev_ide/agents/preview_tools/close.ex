defmodule DevIDE.Agents.PreviewTools.Close do
  @moduledoc "preview_close."

  use Jido.Action,
    name: "preview_close",
    description: "Close a preview by session_id or tmux pane_id.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}],
      pane_id: [type: :string],
      tmux_session: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.close_props()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_close")

  @impl Jido.Action
  def run(params, context) do
    Impl.close(Helpers.to_impl_args(params))
  end
end
