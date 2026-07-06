defmodule DevIDE.Agents.ArtifactTools.Snapshot do
  @moduledoc "artifact_snapshot: explicit Git version marker commit."

  use Jido.Action,
    name: "artifact_snapshot",
    description: "Create an explicit Git version marker commit for an artifact project.",
    category: "artifact",
    tags: ["artifact_project", "mutation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      artifact_id: [type: :string, required: true],
      label: [type: :string],
      message: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.ArtifactTools.Helpers
  alias DevIDE.ArtifactProjects
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters do
    Tool.object(
      %{
        workspace_id: Helpers.workspace_id_param(),
        artifact_id: Helpers.artifact_id_param(),
        label: %{type: "string", description: "Short snapshot label."},
        message: %{type: "string", description: "Snapshot commit message suffix."}
      },
      [:workspace_id, :artifact_id]
    )
  end

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:medium, true)

  @impl DevIDE.Agents.ToolAction
  def param_aliases, do: %{artifact_id: ~w(artifact_id id project_id)}

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, project} <- Helpers.get_project(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id),
         {:ok, snapshot} <-
           ArtifactProjects.snapshot(params.artifact_id, Map.take(params, [:label, :message])) do
      {:ok, Map.put(snapshot, :workspace_id, params.workspace_id)}
    end
  end
end
