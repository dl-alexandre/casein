defmodule Casein.Agents.PreviewTools.RecordStart do
  @moduledoc "preview_record_start."

  use Jido.Action,
    name: "preview_record_start",
    description: "Start server-side video recording of this preview session.",
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
  def mcp_metadata, do: Helpers.metadata("preview_record_start")

  @impl Jido.Action
  def run(params, _context) do
    Impl.record_start(Helpers.to_impl_args(params))
  end
end
