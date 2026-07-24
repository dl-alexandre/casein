defmodule Casein.Agents.PreviewTools.Elements do
  @moduledoc "preview_elements."

  use Jido.Action,
    name: "preview_elements",
    description: "List visible clickable/typeable elements for a preview session.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true],
      query: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(%{session_id: Params.session_id(), query: Helpers.elements_query_param()}, [
        :session_id
      ])

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_elements")

  @impl Jido.Action
  def run(params, _context) do
    Impl.elements(Helpers.to_impl_args(params))
  end
end
