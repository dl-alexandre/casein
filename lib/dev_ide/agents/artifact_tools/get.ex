defmodule DevIDE.Agents.ArtifactTools.Get do
  @moduledoc "artifact_get: one artifact project's metadata and preview handoff."

  use Jido.Action,
    name: "artifact_get",
    description: "Fetch one artifact project's metadata and preview handoff arguments.",
    category: "artifact",
    tags: ["artifact_project"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      artifact_id: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.ArtifactTools.Helpers
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters do
    Tool.object(
      %{workspace_id: Helpers.workspace_id_param(), artifact_id: Helpers.artifact_id_param()},
      [:workspace_id, :artifact_id]
    )
  end

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:low, false)

  @impl DevIDE.Agents.ToolAction
  def param_aliases, do: %{artifact_id: ~w(artifact_id id project_id)}

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, project} <- Helpers.get_project(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id) do
      {:ok, Helpers.project_payload(project)}
    end
  end
end
