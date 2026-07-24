defmodule Casein.Agents.ArtifactTools.Serve do
  @moduledoc "artifact_serve: ensure the artifact preview server is running."

  use Jido.Action,
    name: "artifact_serve",
    description:
      "Ensure the artifact preview server is starting or running, then return " <>
        "updated metadata and preview handoff arguments.",
    category: "artifact",
    tags: ["artifact_project", "mutation"],
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
  def mcp_metadata, do: Helpers.metadata(:medium, true)

  @impl Casein.Agents.ToolAction
  def param_aliases, do: %{artifact_id: ~w(artifact_id id project_id)}

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, project} <- Helpers.get_project(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id),
         {:ok, project} <- ArtifactProjects.serve(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id) do
      {:ok, Helpers.project_payload(project)}
    end
  end
end
