defmodule DevIdeWeb.WorkspaceLive.Show.PaletteEventsTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.PaletteEvents

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: DevIdeWeb.Endpoint,
      view: DevIdeWeb.WorkspaceLive.Show,
      root_pid: self(),
      private: %{live_temp: %{}},
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            workspace: %{id: "ws-palette"},
            host_loc: {:error, :not_set},
            flash: %{}
          },
          assigns
        )
    }
  end

  describe "search:run" do
    test "assigns no_root error when workspace root is unavailable" do
      {:noreply, socket} =
        PaletteEvents.handle_event("search:run", %{"query" => "hello"}, socket())

      assert socket.assigns.search_state == {:error, :no_root}
    end
  end
end
