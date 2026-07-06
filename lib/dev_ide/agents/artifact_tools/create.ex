defmodule DevIDE.Agents.ArtifactTools.Create do
  @moduledoc "artifact_create: new artifact project in an isolated Git worktree."

  use Jido.Action,
    name: "artifact_create",
    description:
      "Create a static/html artifact project in an isolated Git worktree for this workspace. " <>
        "Returns artifact metadata plus preview_open_arguments for Preview MCP.",
    category: "artifact",
    tags: ["artifact_project", "mutation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      name: [type: :string],
      kind: [type: :string],
      prompt: [type: :string],
      # Shape-check only (object or array of objects); the domain validates
      # paths/content itself so its error shapes stay unchanged.
      files: [type: {:or, [{:map, :any, :any}, {:list, {:map, :any, :any}}]}],
      base_ref: [type: :string],
      branch: [type: :string]
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
        name: %{type: "string", description: "Human-readable artifact name."},
        kind: Helpers.kind_param(),
        prompt: Helpers.prompt_param(),
        files: Helpers.files_param(),
        base_ref: %{type: "string", description: "Git ref to create the worktree from."},
        branch: %{type: "string", description: "Optional artifact worktree branch name."}
      },
      [:workspace_id]
    )
  end

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata(:medium, true)

  @impl Jido.Action
  def run(params, _context) do
    attrs = Map.take(params, [:name, :kind, :prompt, :files, :base_ref, :branch])

    with {:ok, project} <- ArtifactProjects.create(params.workspace_id, attrs) do
      {:ok, Helpers.project_payload(project)}
    end
  end
end
