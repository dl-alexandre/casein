defmodule Casein.Agents.ArtifactTools.Retire do
  @moduledoc "artifact_retire: stop serving an artifact and remove its worktree."

  use Jido.Action,
    name: "artifact_retire",
    description:
      "Retire an artifact, remove its generated worktree, and retain its Git branch for restore.",
    category: "artifact",
    tags: ["artifact_project", "mutation", "lifecycle"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      artifact_id: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.ArtifactTools.Helpers
  alias Casein.ArtifactProjects
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      %{workspace_id: Helpers.workspace_id_param(), artifact_id: Helpers.artifact_id_param()},
      [:workspace_id, :artifact_id]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:high, true)

  @impl Casein.Agents.ToolAction
  def param_aliases, do: %{artifact_id: ~w(artifact_id id project_id)}

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, project} <- Helpers.get_project(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id),
         {:ok, retired} <- ArtifactProjects.retire(params.artifact_id) do
      {:ok,
       %{
         id: retired.id,
         workspace_id: retired.workspace_id,
         status: retired.status,
         retired: true,
         restorable: true
       }}
    end
  end
end
