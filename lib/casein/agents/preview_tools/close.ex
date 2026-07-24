defmodule Casein.Agents.PreviewTools.Close do
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

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}

  @impl Casein.Agents.ToolAction
  def parameters, do: Helpers.close_props()

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_close")

  @impl Jido.Action
  def run(params, _context) do
    Impl.close(Helpers.to_impl_args(params))
  end
end
