defmodule DevIDE.ArtifactProjects.Project do
  @moduledoc """
  Runtime-backed generated artifact project.

  Artifact project records are projected from `DevIDE.Runtimes.Runtime`
  metadata. The generated source lives in a dedicated Git worktree; the runtime
  record owns preview server status and URL metadata.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          runtime_id: String.t(),
          name: String.t(),
          kind: String.t(),
          status: String.t(),
          worktree_path: String.t(),
          branch: String.t() | nil,
          preview_url: String.t() | nil,
          preview_server: map() | nil,
          prompt_history: [String.t()],
          metadata: map(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :workspace_id, :runtime_id, :name, :kind, :status, :worktree_path]
  defstruct [
    :id,
    :workspace_id,
    :runtime_id,
    :name,
    :kind,
    :status,
    :worktree_path,
    :branch,
    :preview_url,
    :preview_server,
    :created_at,
    :updated_at,
    prompt_history: [],
    metadata: %{}
  ]
end
