defmodule Casein.Agents.PreviewTools.CompareSnapshots do
  @moduledoc "preview_compare_snapshots."

  use Jido.Action,
    name: "preview_compare_snapshots",
    description: "Diff two previously captured preview screenshots.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      artifact_a: [type: :string, required: true],
      artifact_b: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}

  @impl Casein.Agents.ToolAction
  def parameters, do: Helpers.compare_props()

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_compare_snapshots")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.compare_snapshots(workspace, Helpers.to_impl_args(params))
  end
end
