defmodule CaseinWeb.WorkspaceLive.Show.ArtifactEventsTest do
  use Casein.DataCase, async: true

  alias Casein.Test.RuntimeSeed
  alias CaseinWeb.WorkspaceLive.Show.ArtifactEvents

  # Covers artifact:refresh, the not-found path for serve/inspect/open, the
  # workspace-scoping check in artifact_project_for_workspace/2, and the
  # {:error, reason} serve branch when a same-workspace project cannot start a
  # preview. Unique ids keep MemoryAdapter records from colliding under async.

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-artifacts-#{System.unique_integer([:positive])}"},
            artifact_selected_id: nil,
            flash: %{}
          },
          assigns
        )
    }
  end

  defp artifact_metadata(id, name) do
    %{
      "id" => id,
      "name" => name,
      "kind" => "static",
      "status" => "draft",
      "version" => 1
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:casein, key)
  defp restore_env(key, value), do: Application.put_env(:casein, key, value)

  describe "artifact:refresh" do
    test "loads artifact projects for the workspace" do
      {:noreply, socket} = ArtifactEvents.handle_event("artifact:refresh", %{}, socket())

      assert is_list(socket.assigns.artifact_projects)
      assert socket.assigns.artifact_projects_error == nil
    end
  end

  describe "artifact not found" do
    test "artifact:serve with nonexistent id flashes not found" do
      {:noreply, socket} =
        ArtifactEvents.handle_event(
          "artifact:serve",
          %{"artifact-id" => "missing-#{System.unique_integer([:positive])}"},
          socket()
        )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Artifact not found in this workspace"
    end

    test "artifact:inspect with nonexistent id flashes not found" do
      {:noreply, socket} =
        ArtifactEvents.handle_event(
          "artifact:inspect",
          %{"artifact-id" => "missing-#{System.unique_integer([:positive])}"},
          socket()
        )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Artifact not found in this workspace"
    end

    test "artifact:open with nonexistent id flashes not found" do
      {:noreply, socket} =
        ArtifactEvents.handle_event(
          "artifact:open",
          %{"artifact-id" => "missing-#{System.unique_integer([:positive])}"},
          socket()
        )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Artifact not found in this workspace"
    end
  end

  describe "workspace scoping" do
    test "artifact:serve rejects an artifact owned by another workspace" do
      ws_a = "ws-art-a-#{System.unique_integer([:positive])}"
      ws_b = "ws-art-b-#{System.unique_integer([:positive])}"
      art_id = "art-#{System.unique_integer([:positive])}"

      {:ok, _runtime} =
        RuntimeSeed.seed_runtime(ws_b,
          id: art_id,
          status: "provisioned",
          metadata: %{"artifact_project" => artifact_metadata(art_id, "Other workspace")}
        )

      socket = socket(%{workspace: %{id: ws_a}})

      {:noreply, socket} =
        ArtifactEvents.handle_event(
          "artifact:serve",
          %{"artifact-id" => art_id},
          socket
        )

      # artifact_project_for_workspace/2 compares project.workspace_id to the
      # socket workspace — cross-workspace ids must look like "not found".
      assert Phoenix.Flash.get(socket.assigns.flash, :error) ==
               "Artifact not found in this workspace"
    end
  end

  describe "serve failure" do
    test "same-workspace project with no preview still refreshes the list" do
      ws_id = "ws-art-#{System.unique_integer([:positive])}"
      art_id = "art-#{System.unique_integer([:positive])}"

      prev_launcher = Application.get_env(:casein, :runtime_preview_launcher_enabled)
      Application.put_env(:casein, :runtime_preview_launcher_enabled, true)

      on_exit(fn ->
        restore_env(:runtime_preview_launcher_enabled, prev_launcher)
      end)

      # Artifact project metadata only — no preview_server / worktree means
      # ArtifactProjects.serve fails once the launcher is enabled.
      {:ok, _runtime} =
        RuntimeSeed.seed_runtime(ws_id,
          id: art_id,
          status: "provisioned",
          metadata: %{"artifact_project" => artifact_metadata(art_id, "Broken preview")}
        )

      socket = socket(%{workspace: %{id: ws_id}})

      {:noreply, socket} =
        ArtifactEvents.handle_event(
          "artifact:serve",
          %{"artifact-id" => art_id},
          socket
        )

      assert Phoenix.Flash.get(socket.assigns.flash, :error) =~ "Could not serve artifact:"
      assert is_list(socket.assigns.artifact_projects)
      assert Enum.any?(socket.assigns.artifact_projects, &(&1.id == art_id))
    end
  end
end
