defmodule Casein.Repo.Migrations.IndexWorkspaceRuntimesWorktreePath do
  use Ecto.Migration

  # The session picker resolves a workspace's current worktrees by
  # `(workspace_id, worktree_path)` on every directory read, and
  # `Runtimes.observe_worktree/2` uses the same lookup to decide update-vs-insert.
  # Without this index both paths fall back to the `(workspace_id, status)` index
  # and then filter, which is what let a busy workspace's lookup get slow enough
  # to matter.
  def change do
    create index(:workspace_runtimes, [:workspace_id, :worktree_path])
  end
end
