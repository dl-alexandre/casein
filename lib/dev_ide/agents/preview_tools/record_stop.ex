defmodule Casein.Agents.PreviewTools.RecordStop do
  @moduledoc "preview_record_stop."

  use Jido.Action,
    name: "preview_record_stop",
    description: "Stop recording, store the webm, and show it as playback in the preview pane.",
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
  def mcp_metadata, do: Helpers.metadata("preview_record_stop")

  @impl Jido.Action
  def run(params, _context) do
    Impl.record_stop(Helpers.to_impl_args(params))
  end
end
