defmodule DevIDE.Agents.ArtifactTools.Update do
  @moduledoc "artifact_update: write files + prompt history, commit in the artifact worktree."

  use Jido.Action,
    name: "artifact_update",
    description:
      "Update generated artifact files and append feedback to prompt history. " <>
        "Commits the result in the artifact worktree.",
    category: "artifact",
    tags: ["artifact_project", "mutation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      artifact_id: [type: :string, required: true],
      prompt: [type: :string],
      # Shape-check only (object or array of objects); the domain validates
      # paths/content itself so its error shapes stay unchanged.
      files: [type: {:or, [{:map, :any, :any}, {:list, {:map, :any, :any}}]}]
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
        prompt: Helpers.prompt_param(),
        files: Helpers.files_param()
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
         {:ok, project} <-
           ArtifactProjects.update(params.artifact_id, Map.take(params, [:prompt, :files])),
         :ok <- Helpers.enforce_workspace(project, params.workspace_id) do
      {:ok, Helpers.project_payload(project)}
    end
  end
end
