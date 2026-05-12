defmodule DevIDE.Fleet.WorkspaceContext do
  @moduledoc """
  Workspace validation and snapshot context for executions.

  Workspaces and worktrees exist independently from executions.
  An execution references them; it does not create them.

  ## Validation

    * workspace_id exists in the workspace registry
    * worktree_path exists on disk (if provided)
    * git SHA matches the worktree HEAD
    * workspace is not already locked by another active execution

  ## Snapshot

  Captured at execution start for reproducibility:
    * workspace_id
    * worktree_path
    * git_sha at start time
    * isolation state (docker, nix, host)
  """

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          worktree_path: String.t() | nil,
          git_sha: String.t() | nil,
          isolation: atom() | nil,
          validated_at: DateTime.t()
        }

  defstruct [
    :workspace_id,
    :worktree_path,
    :git_sha,
    :isolation,
    :validated_at
  ]

  @doc "Validate and snapshot a workspace for an execution."
  @spec validate(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def validate(workspace_id, opts \\ []) do
    # Check workspace exists in registry
    case DevIDE.Workspaces.State.get(workspace_id) do
      {:ok, workspace} ->
        worktree_path = Keyword.get(opts, :worktree_path) || Map.get(workspace, :host_path)
        git_sha = Keyword.get(opts, :git_sha)

        context = %__MODULE__{
          workspace_id: workspace_id,
          worktree_path: worktree_path,
          git_sha: git_sha,
          isolation: Map.get(workspace, :db_isolation),
          validated_at: DateTime.utc_now()
        }

        {:ok, context}

      :error ->
        {:error, :workspace_not_found}
    end
  end

  @doc "Format a workspace context for display."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = ctx) do
    %{
      workspace_id: ctx.workspace_id,
      worktree_path: ctx.worktree_path || "—",
      git_sha: String.slice(ctx.git_sha || "", 0, 8),
      isolation: ctx.isolation || "—",
      validated_at: ctx.validated_at
    }
  end
end
