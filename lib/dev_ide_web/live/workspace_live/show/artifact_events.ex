defmodule DevIdeWeb.WorkspaceLive.Show.ArtifactEvents do
  # Artifact tab handle_event clauses extracted verbatim from
  # DevIdeWeb.WorkspaceLive.Show (pure code motion — no behavior change).
  # Show delegates every "artifact:*" event here via a prefix delegator.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias DevIDE.ArtifactProjects
  alias DevIdeWeb.WorkspaceLive.Show.PreviewPaneEvents

  def handle_event("artifact:refresh", _params, socket) do
    {:noreply, refresh_artifact_projects(socket)}
  end

  def handle_event("artifact:serve", %{"artifact-id" => artifact_id}, socket)
      when is_binary(artifact_id) do
    case artifact_project_for_workspace(socket, artifact_id) do
      {:ok, project} ->
        case ArtifactProjects.serve(project.id) do
          {:ok, _served} ->
            {:noreply, refresh_artifact_projects(socket)}

          {:error, reason} ->
            {:noreply,
             socket
             |> refresh_artifact_projects()
             |> put_flash(:error, "Could not serve artifact: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, artifact_error_message(reason))}
    end
  end

  def handle_event("artifact:inspect", %{"artifact-id" => artifact_id}, socket)
      when is_binary(artifact_id) do
    with {:ok, project} <- artifact_project_for_workspace(socket, artifact_id),
         {:ok, project} <- ArtifactProjects.serve(project.id) do
      {:noreply,
       socket
       |> assign(:artifact_selected_id, project.id)
       |> refresh_artifact_projects()}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> refresh_artifact_projects()
         |> put_flash(:error, artifact_error_message(reason))}
    end
  end

  def handle_event("artifact:open", %{"artifact-id" => artifact_id}, socket)
      when is_binary(artifact_id) do
    with {:ok, project} <- artifact_project_for_workspace(socket, artifact_id),
         {:ok, project} <- ArtifactProjects.serve(project.id),
         url when is_binary(url) and url != "" <- project.preview_url do
      case PreviewPaneEvents.split_workspace_preview(socket, url, %{"mode" => "tab"}) do
        {:ok, socket} ->
          {:noreply, refresh_artifact_projects(socket)}

        {:error, :no_tmux_session, socket} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Start a tmux terminal session before opening a preview pane"
           )}

        {:error, reason, socket} ->
          {:noreply,
           put_flash(socket, :error, "Failed to open artifact preview: #{inspect(reason)}")}
      end
    else
      nil ->
        {:noreply,
         socket
         |> refresh_artifact_projects()
         |> put_flash(:error, "Artifact preview URL is not available yet")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, artifact_error_message(reason))}
    end
  end

  def refresh_artifact_projects(socket) do
    workspace_id = socket.assigns.workspace.id
    projects = ArtifactProjects.list(workspace_id)
    selected_id = socket.assigns[:artifact_selected_id]

    socket
    |> assign(:artifact_projects, projects)
    |> assign(:artifact_projects_error, nil)
    |> assign(:artifact_selected_id, valid_artifact_selected_id(projects, selected_id))
  rescue
    error ->
      socket
      |> assign(:artifact_projects, [])
      |> assign(:artifact_projects_error, Exception.message(error))
      |> assign(:artifact_selected_id, nil)
  end

  defp valid_artifact_selected_id(projects, selected_id) when is_binary(selected_id) do
    if Enum.any?(projects, &(&1.id == selected_id)), do: selected_id
  end

  defp valid_artifact_selected_id(_projects, _selected_id), do: nil

  defp artifact_project_for_workspace(socket, artifact_id) do
    workspace_id = socket.assigns.workspace.id

    case ArtifactProjects.get(artifact_id) do
      {:ok, project} ->
        if project.workspace_id == workspace_id do
          {:ok, project}
        else
          {:error, :artifact_not_found}
        end

      :error ->
        {:error, :artifact_not_found}
    end
  end

  defp artifact_error_message(:artifact_not_found), do: "Artifact not found in this workspace"
  defp artifact_error_message(reason), do: "Artifact action failed: #{inspect(reason)}"
end
