defmodule Casein.Agents.ArtifactTools.Verify do
  @moduledoc "artifact_verify: prove registered files match the public mirror."

  use Jido.Action,
    name: "artifact_verify",
    description:
      "Verify every registered artifact file exists and is byte-identical in the durable public mirror.",
    category: "artifact",
    tags: ["artifact_project", "read"],
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
      %{
        workspace_id: Helpers.workspace_id_param(),
        artifact_id: Helpers.artifact_id_param()
      },
      [:workspace_id, :artifact_id]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:low, false)

  @impl Casein.Agents.ToolAction
  def param_aliases, do: %{artifact_id: ~w(artifact_id id project_id)}

  @impl Jido.Action
  def run(params, _context) do
    with {:ok, project} <- Helpers.get_project(params.artifact_id),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id),
         {:ok, parity} <- ArtifactProjects.verify(params.artifact_id) do
      {:ok, Map.put(parity, :workspace_id, params.workspace_id)}
    end
  end
end
