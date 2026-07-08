defmodule DevIdeWeb.WorkspaceLive.Show.ArtifactEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.ArtifactEvents

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-artifacts"},
            artifact_selected_id: nil,
            flash: %{}
          },
          assigns
        )
    }
  end

  describe "artifact:refresh" do
    test "loads artifact projects for the workspace" do
      {:noreply, socket} = ArtifactEvents.handle_event("artifact:refresh", %{}, socket())

      assert is_list(socket.assigns.artifact_projects)
      assert socket.assigns.artifact_projects_error == nil
    end
  end
end
