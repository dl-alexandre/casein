defmodule CaseinWeb.API.ArtifactProjectController do
  @moduledoc """
  Bearer-authenticated artifact project lifecycle mutations.

  Artifact ids are always pinned to the workspace id in the route before any
  filesystem work is attempted.
  """

  use CaseinWeb, :controller

  require Logger

  alias Casein.ArtifactProjects
  alias Casein.Audit

  def action(conn, _opts) do
    Casein.Signals.Context.with_new(fn ->
      apply(__MODULE__, action_name(conn), [conn, conn.params])
    end)
  end

  def restore(conn, %{"workspace_id" => workspace_id, "artifact_id" => artifact_id}) do
    case ArtifactProjects.restore(workspace_id, artifact_id) do
      {:ok, project} ->
        Audit.emit!(%{
          action: "artifact.restored",
          workspace_id: workspace_id,
          actor_id: "api",
          target_type: "artifact_project",
          target_ref: artifact_id,
          metadata: %{branch: project.branch, runtime_id: project.runtime_id}
        })

        json(conn, %{
          action: "artifact_restored",
          artifact: ArtifactProjects.payload(project)
        })

      {:error, :artifact_not_found} ->
        error(conn, :not_found, "artifact_not_found")

      {:error, :workspace_not_found} ->
        error(conn, :not_found, "workspace_not_found")

      {:error, {:artifact_not_restorable, status}} ->
        error(conn, :conflict, "artifact_not_restorable", %{runtime_status: status})

      {:error, reason}
      when reason in [
             :artifact_branch_not_found,
             :artifact_worktree_path_occupied,
             :artifact_worktree_mismatch,
             :invalid_artifact_worktree_path
           ] ->
        error(conn, :conflict, Atom.to_string(reason))

      {:error, reason} ->
        Logger.warning("artifact restore failed",
          workspace_id: workspace_id,
          id: artifact_id,
          reason: inspect(reason)
        )

        error(conn, :internal_server_error, "artifact_restore_failed")

      :error ->
        error(conn, :not_found, "artifact_not_found")
    end
  end

  defp error(conn, status, code, extra \\ %{}) do
    conn
    |> put_status(status)
    |> json(Map.merge(%{error: code}, extra))
  end
end
