defmodule Casein.Agents.PreviewTools.Observe do
  @moduledoc "preview_observe."

  use Jido.Action,
    name: "preview_observe",
    description: "Observe the current preview page with static HTTP HTML fetch.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}

  @impl Casein.Agents.ToolAction
  def parameters, do: Helpers.session_only()

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_observe")

  @impl Jido.Action
  def run(params, _context) do
    Impl.observe(Helpers.to_impl_args(params))
  end
end
