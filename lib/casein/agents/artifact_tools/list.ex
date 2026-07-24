defmodule Casein.Agents.ArtifactTools.List do
  @moduledoc "artifact_list: active artifact projects for the workspace."

  use Jido.Action,
    name: "artifact_list",
    description: "List active artifact projects for the workspace.",
    category: "artifact",
    tags: ["artifact_project"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.ArtifactTools.Helpers
  alias Casein.ArtifactProjects
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(%{workspace_id: Helpers.workspace_id_param()}, [:workspace_id])
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:low, false)

  @impl Jido.Action
  def run(params, _context) do
    artifacts =
      params.workspace_id
      |> ArtifactProjects.list()
      |> Enum.map(&Helpers.project_payload/1)

    {:ok, %{workspace_id: params.workspace_id, count: length(artifacts), artifacts: artifacts}}
  end
end
